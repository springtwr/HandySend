//! 自研 Web 服务路由（token 会话，取代上游 `web.rs`）。
//!
//! 与旧链路的关键差异：
//! - 会话键是浏览器 UUID token（多标签不互踢），token 绑定创建时
//!   对端 IP（换 IP 视为新客户端）；旧按 IP 单槽只留过渡。
//! - `GET /caps` 只读快照，绝不创建会话（旧进页 `POST` 即建挂起
//!   是被替代的根因）；文件表 `revision` 单调增，换表只影响新会话，
//!   被删文件为活跃会话保留到宽限结束。
//! - 终态判定权在调用方（ArkTS 适配器沿用静默/空闲窗口）：服务端只做
//!   待确认超时与从未开始的 accepted 会话回收（请求进入时惰性打扫），
//!   传输中空闲仍由字节进度侧判定。
//! - TLS 随 ArkTS 接线时接入（复用全局身份/证书），路由与链路先行
//!   HTTP 验证；`use_https` 仅影响 caps 提示位。

use std::collections::HashMap;
use std::convert::Infallible;
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::body::{Frame, Incoming};
use hyper::header::{CONTENT_DISPOSITION, CONTENT_LENGTH, CONTENT_TYPE};
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use tokio::net::TcpListener;
use tokio::sync::{mpsc, oneshot};

use crate::bridge::lock;
use crate::bridge::throttle::ProgressThrottle;
use crate::bridge::adapter::types::FileDto as AdapterFileDto;
use crate::bridge::web::caps::{CapsSnapshot, ShareState};
use crate::bridge::web::i18n::web_page_i18n;
use crate::bridge::web::session::{
    FileSource, OfferedFile, RetainedFile, SessionEndReason, SessionState, SessionStore,
    SharedFile, SharedFileTable, TokenSession,
};
use crate::bridge::web::upload::{UploadFile, UploadSession, UploadState, UploadStore};

/// 响应体类型（统一装箱，便于在同一路由返回空体与流式体）。
type BoxBody = http_body_util::combinators::BoxBody<Bytes, std::io::Error>;

/// 单页 HTML（与服务同仓，改文案改 JS 只动主仓）。
const SINGLE_HTML: &str = include_str!("assets/single.html");

/// PIN 错误上限（与上游口径一致：3 次后 429）。
const MAX_PIN_ATTEMPTS: u32 = 3;
/// 被删文件保留宽限（供已建会话按快照下完）。
const RETAIN_GRACE: Duration = Duration::from_secs(30);
/// 内容下发读块（与旧 fd 内容源同量级）。
const READ_BUF_SIZE: usize = 512 * 1024;
/// 进度通道容量（块）。
const BODY_CHANNEL_CAPACITY: usize = 16;

/// 自研 web 服务配置（与上游 `WebConfig` 解耦，不再复用它）。
#[derive(Clone, Debug, Default)]
pub struct WebServiceConfig {
    /// 自有监听端口（与 LocalSend 服务端口独立，重启互不影响）。
    pub port: u16,
    /// 是否使用自签证书 HTTPS（跟随全局加密开关，不另起证书）。
    pub use_https: bool,
}

/// 进度与终结事件（生产由 ArkTS 侧接入统一注册表；测试直接断言）。
#[derive(Clone, Debug)]
pub enum ProgressEvent {
    /// 下载待确认（浏览器建会话，等待用户决策；NAPI 侧转确认弹窗）。
    PrepareDownloadRequested {
        token: String,
        ip: String,
        user_agent: Option<String>,
        files: Vec<AdapterFileDto>,
    },
    /// 上传待确认（浏览器建会话，等待用户决策；NAPI 侧转确认弹窗）。
    PrepareUploadRequested {
        token: String,
        ip: String,
        user_agent: Option<String>,
        files: Vec<AdapterFileDto>,
    },
    /// 下载字节进度（节流，可丢弃语义由消费方定）。
    Progress {
        token: String,
        file_id: String,
        sent_bytes: u64,
        total_bytes: u64,
    },
    /// 下载文件下发完毕（终值，关键事件）。
    Done {
        token: String,
        file_id: String,
        total_bytes: u64,
    },
    /// 上传字节进度（节流）。
    UploadProgress {
        token: String,
        file_id: String,
        received_bytes: u64,
        total_bytes: u64,
    },
    /// 上传文件落盘完毕（终值，携带最终路径）。
    UploadDone {
        token: String,
        file_id: String,
        path: String,
    },
    /// 会话结束（完成回执/终结，调用方按终态收口）。
    Finished {
        token: String,
    },
}

/// 服务共享状态（调用方持锁；`caps` 展示字段由生产方维护，
/// `has_download`/`file_revision` 在 `/caps` 应答时以文件表为准）。
#[derive(Clone, Debug, Default)]
pub struct WebServiceState {
    /// 能力快照展示字段（`upload_enabled`/`share_state`/`https_hint`）。
    pub caps: Arc<Mutex<CapsSnapshot>>,
    /// 本机别名（文件表响应携带，供浏览器页展示）。
    pub alias: Arc<Mutex<String>>,
    /// 当前分享标识（一分享多任务的外键）。
    pub share_id: Arc<Mutex<String>>,
    /// 要求浏览器携带的 PIN（`None` 表示免 PIN）。
    pub expected_pin: Arc<Mutex<Option<String>>>,
    /// 当前分享文件表（换表版本号单调增）。
    pub files: Arc<Mutex<SharedFileTable>>,
    /// 被删文件的保留区（宽限内已建会话仍可下）。
    pub retained: Arc<Mutex<HashMap<String, RetainedFile>>>,
    /// 下载会话表。
    pub sessions: Arc<Mutex<SessionStore>>,
    /// 上传会话表（每客户端独立槽，不吃 v2 全局单槽）。
    pub uploads: Arc<Mutex<UploadStore>>,
    /// 上传落盘目录（测试用临时目录；生产接线时 ArkTS 指定接收目录）。
    pub upload_dir: Arc<Mutex<std::path::PathBuf>>,
    /// PIN 错误计数（IP → 次数，成功清零）。
    pub pin_attempts: Arc<Mutex<HashMap<IpAddr, u32>>>,
    /// 进度事件出口（`None` 时不发射，纯传输）。
    pub progress_tx: Option<mpsc::Sender<ProgressEvent>>,
}

impl WebServiceState {
    /// 就地换表：版本号 +1；被删条目转入保留区（宽限后释放）；
    /// 同时打扫过期的保留条目。
    pub fn update_files(&self, next: HashMap<String, SharedFile>) {
        let now = Instant::now();
        let deadline = now + RETAIN_GRACE;
        let removed = lock(&self.files).replace(next);
        let mut retained = lock(&self.retained);
        retained.retain(|_, entry| entry.deadline > now);
        for file in removed {
            retained.insert(
                file.file.id.clone(),
                RetainedFile {
                    file,
                    deadline,
                },
            );
        }
    }

    /// 惰性打扫下载侧：会话超时终结 + 保留区过期释放。
    /// 返回被终结的（token，原因），调用方按终态收口。
    pub fn sweep(&self, now: Instant) -> Vec<(String, SessionEndReason)> {
        lock(&self.retained).retain(|_, entry| entry.deadline > now);
        lock(&self.sessions).sweep(now)
    }

    /// 惰性打扫上传侧：返回被终结的完整会话，调用方负责清理
    /// 临时文件并上报 `Finished`（同步函数内不做异步发射）。
    pub fn sweep_uploads(&self, now: Instant) -> Vec<(UploadSession, SessionEndReason)> {
        lock(&self.uploads).sweep(now)
    }

    /// 全量惰性打扫（各请求入口调用）：下载超时终结 + 上传超时终结
    /// （清临时文件并上报 `Finished`）+ 保留区过期释放。
    pub(crate) async fn sweep_all(&self, now: Instant) {
        for (token, _reason) in self.sweep(now) {
            self.emit(ProgressEvent::Finished { token }).await;
        }
        for (session, _reason) in self.sweep_uploads(now) {
            remove_tmp_files(&session);
            self.emit(ProgressEvent::Finished {
                token: session.token.clone(),
            })
            .await;
        }
    }

    /// PIN 校验（上游口径：3 次错后 429；对错都计次，成功清零）。
    fn check_pin(&self, query_pin: Option<&str>, ip: IpAddr) -> Result<(), StatusCode> {
        let expected = lock(&self.expected_pin).clone();
        let Some(expected) = expected else {
            return Ok(());
        };
        let mut attempts = lock(&self.pin_attempts);
        let count: u32 = attempts.get(&ip).copied().unwrap_or(0);
        if count >= MAX_PIN_ATTEMPTS {
            return Err(StatusCode::TOO_MANY_REQUESTS);
        }
        if query_pin == Some(expected.as_str()) {
            attempts.remove(&ip);
            Ok(())
        } else {
            attempts.insert(ip, count + 1);
            Err(StatusCode::UNAUTHORIZED)
        }
    }

    /// 在当前表或保留区内定位内容源（快照元数据已由调用方校验）。
    fn locate_source(&self, file_id: &str, now: Instant) -> Option<SharedFile> {
        if let Some(found) = lock(&self.files).files.get(file_id).cloned() {
            return Some(found);
        }
        let mut retained = lock(&self.retained);
        if let Some(entry) = retained.get(file_id) {
            if entry.deadline > now {
                return Some(entry.file.clone());
            }
        }
        retained.remove(file_id);
        None
    }

    /// 发射进度事件（无出口时静默跳过）。
    async fn emit(&self, event: ProgressEvent) {
        if let Some(tx) = &self.progress_tx {
            let _ = tx.send(event).await;
        }
    }
}

/// 删除上传会话全部临时文件（终结/拒绝/过期路径统一调用）。
pub(crate) fn remove_tmp_files(session: &UploadSession) {
    for file in session.files.values() {
        let tmp = tmp_path(&file.path);
        let _ = std::fs::remove_file(&tmp);
        let _ = std::fs::remove_file(&file.path);
    }
}

/// 临时文件后缀（完成前 `.part`，完成后改名）。
fn tmp_path(final_path: &str) -> String {
    format!("{final_path}.part")
}

/// 在已绑定的监听器上提供 HTTP/1 服务，直到任务被 abort。
pub async fn run_server(listener: TcpListener, state: Arc<WebServiceState>) {
    loop {
        let (stream, peer) = match listener.accept().await {
            Ok(pair) => pair,
            Err(e) => {
                log::debug!("自研 web accept 失败: {e}");
                continue;
            }
        };
        log::debug!("自研 web 接收到连接: {peer}");
        let conn_state = Arc::clone(&state);
        tokio::spawn(async move {
            let io = TokioIo::new(stream);
            let service = service_fn(move |req: Request<Incoming>| {
                let req_state = Arc::clone(&conn_state);
                async move { handle(req, req_state, peer).await }
            });
            if let Err(e) = hyper::server::conn::http1::Builder::new()
                .serve_connection(io, service)
                .await
            {
                log::debug!("自研 web 连接结束: {e}");
            }
        });
    }
}

/// 路由分发（`Infallible`：未知路径按 404 文本回，不抛错）。
async fn handle(
    req: Request<Incoming>,
    state: Arc<WebServiceState>,
    peer: SocketAddr,
) -> Result<Response<BoxBody>, Infallible> {
    let method = req.method().clone();
    let path = req.uri().path().to_string();
    let query = parse_query(req.uri().query().unwrap_or(""));
    match (method.as_str(), path.as_str()) {
        ("GET", "/caps") => Ok(caps_response(&state)),
        ("GET", "/i18n.json") => Ok(i18n_response(&query)),
        ("GET", "/") => Ok(html_response()),
        ("POST", "/web/prepare-download") => {
            let user_agent = req
                .headers()
                .get("user-agent")
                .and_then(|v| v.to_str().ok())
                .map(str::to_string);
            Ok(prepare_download(&query, state, peer, user_agent).await)
        }
        ("GET", "/web/download") => Ok(start_download(&req, &query, state, peer).await),
        ("POST", "/web/prepare-upload") => {
            let user_agent = req
                .headers()
                .get("user-agent")
                .and_then(|v| v.to_str().ok())
                .map(str::to_string);
            Ok(prepare_upload(req.into_body(), &query, state, peer, user_agent).await)
        }
        ("POST", "/web/upload") => Ok(receive_upload(req, &query, state, peer).await),
        ("POST", "/web/finish") => Ok(finish_session(&query, state, peer).await),
        _ => Ok(text_response(StatusCode::NOT_FOUND, "未知路径")),
    }
}

/// `GET /caps`：只读快照，无副作用（不建会话、不碰决策通道）；
/// `has_download` 与 `file_revision` 以文件表实时值为准。
fn caps_response(state: &WebServiceState) -> Response<BoxBody> {
    let mut snapshot: CapsSnapshot = lock(&state.caps).clone();
    let files = lock(&state.files);
    snapshot.has_download = !files.files.is_empty();
    snapshot.file_revision = files.revision;
    let body: String = serde_json::to_string(&snapshot).unwrap_or_else(|_| "{}".to_string());
    json_response(StatusCode::OK, &body)
}

/// `GET /i18n.json?lang=`：单页文案（无参回退简体中文）。
fn i18n_response(query: &HashMap<String, String>) -> Response<BoxBody> {
    let locale: &str = query.get("lang").map(String::as_str).unwrap_or("");
    let body: String =
        serde_json::to_string(&web_page_i18n(locale)).unwrap_or_else(|_| "{}".to_string());
    json_response(StatusCode::OK, &body)
}

/// `GET /`：单页（按 caps 条件渲染两段）。
fn html_response() -> Response<BoxBody> {
    html_full_response(StatusCode::OK, SINGLE_HTML)
}

/// 文件表响应体（token 会话建立/复用时下发）。
#[derive(serde::Serialize)]
struct FileListResponse {
    token: String,
    #[serde(rename = "shareId")]
    share_id: String,
    revision: u64,
    alias: String,
    files: HashMap<String, localsend::model::transfer::FileDto>,
}

/// `POST /web/prepare-download?token=&pin=`：
/// - token 有效（已接受、同 IP）→ 直接回文件表（免 PIN，与上游同口径）；
/// - 同 IP 有待确认会话 → 409 等待（可重试，不堆决策）；
/// - 否则建挂起会话并等待决策：接受回表 / 拒绝回 403 /
///   决策通道被丢弃（超时或过期）回 408。
/// 分享停止或无可下载文件时回 404（不建会话）。
async fn prepare_download(
    query: &HashMap<String, String>,
    state: Arc<WebServiceState>,
    peer: SocketAddr,
    user_agent: Option<String>,
) -> Response<BoxBody> {
    let now = Instant::now();
    state.sweep_all(now).await;
    // 分享停止或无可下载文件：不建会话。
    if lock(&state.caps).share_state == ShareState::Stopped {
        return text_response(StatusCode::NOT_FOUND, "分享已结束");
    }
    if lock(&state.files).files.is_empty() {
        return text_response(StatusCode::NOT_FOUND, "分享无可下载文件");
    }
    // 复用：token 有效、已接受、同 IP → 直接回表（免 PIN）。
    if let Some(token) = query.get("token") {
        let sessions = lock(&state.sessions);
        if let Some(session) = sessions.sessions.get(token) {
            if session.peer_ip == peer.ip().to_string() {
                if matches!(session.state, SessionState::Accepted) {
                    drop(sessions);
                    lock(&state.sessions).touch(token, Instant::now());
                    return file_list_response(&state, token);
                }
                return text_response(StatusCode::CONFLICT, "等待对方确认中");
            }
            return text_response(StatusCode::FORBIDDEN, "无效 token");
        }
    }
    // PIN 校验（新会话必经；复用通道已在上分支返回）。
    if let Err(status) = state.check_pin(query.get("pin").map(String::as_str), peer.ip()) {
        let message = if status == StatusCode::TOO_MANY_REQUESTS {
            "尝试次数过多"
        } else {
            "PIN 错误"
        };
        return text_response(status, message);
    }
    // 同 IP 已有待确认会话：不堆决策，回 409 可重试。
    {
        let sessions = lock(&state.sessions);
        let waiting = sessions.sessions.values().any(|session| {
            session.peer_ip == peer.ip().to_string()
                && matches!(session.state, SessionState::Pending { .. })
        });
        if waiting {
            return text_response(StatusCode::CONFLICT, "等待对方确认中");
        }
    }
    // 建挂起会话：快照当前文件表。
    let token: String = uuid::Uuid::new_v4().to_string();
    let (decision_tx, decision_rx) = oneshot::channel();
    let (revision, offered) = {
        let files = lock(&state.files);
        let mut offered: HashMap<String, OfferedFile> = HashMap::new();
        for (id, entry) in files.files.iter() {
            offered.insert(
                id.clone(),
                OfferedFile {
                    file_id: id.clone(),
                    file_revision: files.revision,
                    file: entry.file.clone(),
                },
            );
        }
        (files.revision, offered)
    };
    {
        let mut sessions = lock(&state.sessions);
        sessions.insert_pending(TokenSession {
            token: token.clone(),
            share_id: lock(&state.share_id).clone(),
            peer_ip: peer.ip().to_string(),
            user_agent: user_agent.clone(),
            created_at: now,
            last_activity: now,
            state: SessionState::Pending {
                decision_tx: Some(decision_tx),
            },
            offered_files: offered,
            file_revision: revision,
            download_started: false,
        });
    }
    // 待确认事件（NAPI 侧转确认弹窗；文件清单随事件下发）。
    let pending_files: Option<Vec<AdapterFileDto>> = {
        let sessions = lock(&state.sessions);
        sessions.sessions.get(&token).map(|session| {
            session
                .offered_files
                .values()
                .map(|offered| AdapterFileDto {
                    id: offered.file_id.clone(),
                    file_name: offered.file.file_name.clone(),
                    size: offered.file.size,
                    file_type: offered.file.file_type.clone(),
                    preview: offered.file.preview.clone(),
                    sha256: offered.file.sha256.clone(),
                })
                .collect()
        })
    };
    if let Some(files) = pending_files {
        state
            .emit(ProgressEvent::PrepareDownloadRequested {
                token: token.clone(),
                ip: peer.ip().to_string(),
                user_agent,
                files,
            })
            .await;
    }
    match decision_rx.await {
        Ok(true) => {
            // 接受方已把会话置接受并刷新时刻；此处幂等确认后下发表。
            let _ = lock(&state.sessions).accept(&token, Instant::now());
            file_list_response(&state, &token)
        }
        Ok(false) => {
            lock(&state.sessions).expire(&token);
            text_response(StatusCode::FORBIDDEN, "对方已拒绝")
        }
        Err(_) => {
            // 决策通道被丢弃（超时或过期）：会话已由终结方移除。
            lock(&state.sessions).expire(&token);
            text_response(StatusCode::REQUEST_TIMEOUT, "等待确认超时")
        }
    }
}

/// 按 token 下发表（会话缺失时回 408，调用方刷新重试即建新会话）。
fn file_list_response(state: &WebServiceState, token: &str) -> Response<BoxBody> {
    let sessions = lock(&state.sessions);
    let Some(session) = sessions.sessions.get(token) else {
        return text_response(StatusCode::REQUEST_TIMEOUT, "等待确认超时");
    };
    let mut files: HashMap<String, localsend::model::transfer::FileDto> = HashMap::new();
    for (id, offered) in session.offered_files.iter() {
        files.insert(id.clone(), offered.file.clone());
    }
    let body = FileListResponse {
        token: token.to_string(),
        share_id: session.share_id.clone(),
        revision: session.file_revision,
        alias: lock(&state.alias).clone(),
        files,
    };
    let text: String = serde_json::to_string(&body).unwrap_or_else(|_| "{}".to_string());
    json_response(StatusCode::OK, &text)
}

/// `GET /web/download?token=&fileId=`：
/// 校验（会话存在/已接受/同 IP/文件在快照内），定位内容源后流式下发。
/// 内容缺失（保留期外被删）回 410；其余非法回 403。
async fn start_download(
    req: &Request<Incoming>,
    query: &HashMap<String, String>,
    state: Arc<WebServiceState>,
    peer: SocketAddr,
) -> Response<BoxBody> {
    let now = Instant::now();
    state.sweep_all(now).await;
    let Some(token) = query.get("token") else {
        return text_response(StatusCode::FORBIDDEN, "无效 token");
    };
    let Some(file_id) = query.get("fileId") else {
        return text_response(StatusCode::BAD_REQUEST, "缺少 fileId");
    };
    // 校验会话与快照归属。
    let (meta_file, total, source) = {
        let mut sessions = lock(&state.sessions);
        let Some(session) = sessions.sessions.get_mut(token) else {
            return text_response(StatusCode::FORBIDDEN, "无效 token");
        };
        if session.peer_ip != peer.ip().to_string() {
            return text_response(StatusCode::FORBIDDEN, "无效 token");
        }
        if !matches!(session.state, SessionState::Accepted) {
            return text_response(StatusCode::FORBIDDEN, "会话未接受");
        }
        let Some(offered) = session.offered_files.get(file_id) else {
            return text_response(StatusCode::FORBIDDEN, "无效 fileId");
        };
        let meta = offered.file.clone();
        let total = meta.size;
        session.download_started = true;
        session.last_activity = now;
        // 内容源按快照定位：现表优先，保留区兜底（宽限内）。
        match state.locate_source(file_id, now) {
            Some(found) => (meta, total, found.source),
            None => return text_response(StatusCode::GONE, "分享已更新，请刷新"),
        }
    };
    // Range：起点越界回 416，其余按分片下发（200/206）。
    let range = parse_range(
        req.headers()
            .get(hyper::header::RANGE)
            .and_then(|v| v.to_str().ok()),
        total,
    );
    let (start, end_exclusive, status) = match range {
        RangeRequest::Full => (0, total, StatusCode::OK),
        RangeRequest::Partial { start, end } => {
            (start, end + 1, StatusCode::PARTIAL_CONTENT)
        }
        RangeRequest::Unsatisfiable => {
            let mut response =
                text_response(StatusCode::RANGE_NOT_SATISFIABLE, "范围超出文件大小");
            response.headers_mut().insert(
                hyper::header::CONTENT_RANGE,
                hyper::header::HeaderValue::from_str(&format!("bytes */{total}"))
                    .unwrap_or(hyper::header::HeaderValue::from_static("bytes */*")),
            );
            return response;
        }
    };
    let progress_tx = state.progress_tx.clone();
    let token_owned = token.clone();
    let file_id_owned = file_id.clone();
    let length = end_exclusive - start;
    let (body_tx, body_rx) = mpsc::channel::<Bytes>(BODY_CHANNEL_CAPACITY);
    let body = http_body_util::StreamBody::new(futures_util::stream::unfold(
        body_rx,
        |mut rx| async move {
            rx.recv()
                .await
                .map(|chunk| (Ok::<_, std::io::Error>(Frame::data(chunk)), rx))
        },
    ));
    tokio::spawn(async move {
        serve_content(
            source,
            token_owned,
            file_id_owned,
            total,
            start,
            end_exclusive,
            body_tx,
            progress_tx,
        )
        .await;
    });
    let file_name = meta_file.file_name.replace('/', "-");
    let mut response = Response::new(body.boxed());
    *response.status_mut() = status;
    let headers = response.headers_mut();
    headers.insert(CONTENT_TYPE, hyper::header::HeaderValue::from_static("application/octet-stream"));
    headers.insert(
        CONTENT_DISPOSITION,
        hyper::header::HeaderValue::from_str(&format!(
            "attachment; filename=\"{}\"; filename*=UTF-8''{}",
            percent_encode_attr(&file_name),
            percent_encode_attr(&file_name)
        ))
        .unwrap_or(hyper::header::HeaderValue::from_static("attachment")),
    );
    headers.insert(
        CONTENT_LENGTH,
        hyper::header::HeaderValue::from(length),
    );
    if status == StatusCode::PARTIAL_CONTENT {
        headers.insert(
            hyper::header::CONTENT_RANGE,
            hyper::header::HeaderValue::from_str(&format!(
                "bytes {}-{}/{}",
                start,
                end_exclusive - 1,
                total
            ))
            .unwrap_or(hyper::header::HeaderValue::from_static("bytes */*")),
        );
    }
    response
}

/// `POST /web/finish?token=`：完成回执（幂等 advisory）。
/// 已知会话移除并记终结；未知 token 仍回 200（网络重试安全）。
async fn finish_session(
    query: &HashMap<String, String>,
    state: Arc<WebServiceState>,
    peer: SocketAddr,
) -> Response<BoxBody> {
    let Some(token) = query.get("token") else {
        return text_response(StatusCode::FORBIDDEN, "无效 token");
    };
    let removed = {
        let mut sessions = lock(&state.sessions);
        match sessions.sessions.get(token) {
            Some(session) if session.peer_ip == peer.ip().to_string() => {
                sessions.sessions.remove(token).is_some()
            }
            _ => false,
        }
    };
    let removed_upload = {
        let mut uploads = lock(&state.uploads);
        match uploads.sessions.remove(token) {
            Some(session) if session.peer_ip == peer.ip().to_string() => {
                remove_tmp_files(&session);
                true
            }
            Some(session) => {
                // IP 不符：放回，不属该客户端。
                let keep_token = session.token.clone();
                uploads.sessions.insert(keep_token, session);
                false
            }
            None => false,
        }
    };
    if removed || removed_upload {
        state
            .emit(ProgressEvent::Finished {
                token: token.clone(),
            })
            .await;
    }
    json_response(StatusCode::OK, "{\"ok\":true}")
}

/// 上传建会话请求体（浏览器生成文件标识）。
#[derive(serde::Deserialize)]
struct UploadPrepareBody {
    #[serde(default)]
    files: Vec<UploadPrepareFile>,
}

#[derive(serde::Deserialize)]
struct UploadPrepareFile {
    #[serde(default)]
    id: String,
    #[serde(rename = "fileName", default)]
    file_name: String,
    #[serde(default)]
    size: u64,
    #[serde(rename = "fileType", default)]
    file_type: String,
}

/// 上传建会话响应体。
#[derive(serde::Serialize)]
struct UploadListResponse {
    token: String,
    #[serde(rename = "shareId")]
    share_id: String,
    files: HashMap<String, UploadFileMeta>,
}

#[derive(serde::Serialize)]
struct UploadFileMeta {
    #[serde(rename = "fileName")]
    file_name: String,
    size: u64,
}

/// 建会话请求体上限（JSON 小包，防刷）。
const PREPARE_BODY_LIMIT: usize = 1024 * 1024;
/// 单次建会话文件数上限。
const MAX_UPLOAD_FILES: usize = 64;

/// 读请求体并设上限（超限即错，不读完）。
async fn read_body_capped(body: Incoming, limit: usize) -> Result<Vec<u8>, ()> {
    use http_body_util::BodyExt;
    let mut body = body;
    let mut buf: Vec<u8> = Vec::new();
    loop {
        match body.frame().await {
            None => return Ok(buf),
            Some(Ok(frame)) => {
                if let Some(data) = frame.data_ref() {
                    if buf.len() + data.len() > limit {
                        return Err(());
                    }
                    buf.extend_from_slice(data);
                }
            }
            Some(Err(_)) => return Err(()),
        }
    }
}

/// 文件名清洗（去分隔符，空名回退）。
fn sanitize_file_name(name: &str) -> String {
    let cleaned: String = name.replace(['/', '\\'], "-").trim().to_string();
    if cleaned.is_empty() {
        "unnamed".to_string()
    } else {
        cleaned
    }
}

/// `POST /web/prepare-upload`（请求体 JSON）：与下载对称——
/// token 有效（已接受、同 IP）直接回表；同 IP 有待确认回 409；
/// 否则建挂起会话并等待决策：接受回文件表 / 拒绝回 403 /
/// 决策通道被丢弃回 408。上传未开放或分享停止回 404。
/// 接受即全量（不再逐文件挑）。
async fn prepare_upload(
    body: Incoming,
    query: &HashMap<String, String>,
    state: Arc<WebServiceState>,
    peer: SocketAddr,
    user_agent: Option<String>,
) -> Response<BoxBody> {
    let now = Instant::now();
    state.sweep_all(now).await;
    if lock(&state.caps).share_state == ShareState::Stopped {
        return text_response(StatusCode::NOT_FOUND, "分享已结束");
    }
    if !lock(&state.caps).upload_enabled {
        return text_response(StatusCode::NOT_FOUND, "上传未开放");
    }
    // 复用：token 有效、已接受、同 IP → 直接回表（免 PIN）。
    if let Some(token) = query.get("token") {
        let uploads = lock(&state.uploads);
        if let Some(session) = uploads.sessions.get(token) {
            if session.peer_ip == peer.ip().to_string() {
                if matches!(session.state, UploadState::Accepted) {
                    drop(uploads);
                    lock(&state.uploads).touch(token, Instant::now());
                    return upload_list_response(&state, token);
                }
                return text_response(StatusCode::CONFLICT, "等待对方确认中");
            }
            return text_response(StatusCode::FORBIDDEN, "无效 token");
        }
    }
    // PIN 校验（新会话必经）。
    if let Err(status) = state.check_pin(query.get("pin").map(String::as_str), peer.ip()) {
        let message = if status == StatusCode::TOO_MANY_REQUESTS {
            "尝试次数过多"
        } else {
            "PIN 错误"
        };
        return text_response(status, message);
    }
    // 同 IP 待确认：不堆决策。
    {
        let uploads = lock(&state.uploads);
        let waiting = uploads.sessions.values().any(|session| {
            session.peer_ip == peer.ip().to_string()
                && matches!(session.state, UploadState::Pending { .. })
        });
        if waiting {
            return text_response(StatusCode::CONFLICT, "等待对方确认中");
        }
    }
    // 请求体：文件清单。
    let raw = match read_body_capped(body, PREPARE_BODY_LIMIT).await {
        Ok(raw) => raw,
        Err(_) => return text_response(StatusCode::BAD_REQUEST, "请求体过大"),
    };
    let prepared: UploadPrepareBody = match serde_json::from_slice(&raw) {
        Ok(prepared) => prepared,
        Err(_) => return text_response(StatusCode::BAD_REQUEST, "请求体不是合法 JSON"),
    };
    if prepared.files.is_empty() || prepared.files.len() > MAX_UPLOAD_FILES {
        return text_response(StatusCode::BAD_REQUEST, "文件数量非法");
    }
    for entry in prepared.files.iter() {
        if entry.id.is_empty() || sanitize_file_name(&entry.file_name).is_empty() {
            return text_response(StatusCode::BAD_REQUEST, "文件名非法");
        }
    }
    // 建挂起会话：落盘路径去重命名。
    let token: String = uuid::Uuid::new_v4().to_string();
    let (decision_tx, decision_rx) = oneshot::channel();
    let upload_dir = lock(&state.upload_dir).clone();
    if let Err(e) = std::fs::create_dir_all(&upload_dir) {
        log::warn!("自研 web 创建上传目录失败 dir={} {e:?}", upload_dir.display());
        return text_response(StatusCode::INTERNAL_SERVER_ERROR, "上传目录不可用");
    }
    let mut files: HashMap<String, UploadFile> = HashMap::new();
    for entry in prepared.files.iter() {
        let stem = sanitize_file_name(&entry.file_name);
        let mut candidate = upload_dir.join(&stem);
        let mut serial: u32 = 1;
        while candidate.exists() && serial < 1000 {
            let suffixed = format!(
                "{}_{serial}",
                stem.rsplit_once('.')
                    .map(|(head, ext)| format!("{head}.{ext}"))
                    .unwrap_or_else(|| stem.clone())
            );
            candidate = upload_dir.join(suffixed);
            serial += 1;
        }
        files.insert(
            entry.id.clone(),
            UploadFile {
                file_id: entry.id.clone(),
                file_name: stem,
                file_type: entry.file_type.clone(),
                size: entry.size,
                received: 0,
                path: candidate.to_string_lossy().into_owned(),
                done: false,
                uploading: false,
            },
        );
    }
    {
        let mut uploads = lock(&state.uploads);
        uploads.insert_pending(UploadSession {
            token: token.clone(),
            share_id: lock(&state.share_id).clone(),
            peer_ip: peer.ip().to_string(),
            user_agent: user_agent.clone(),
            created_at: now,
            last_activity: now,
            state: UploadState::Pending {
                decision_tx: Some(decision_tx),
            },
            files,
            download_started: false,
        });
    }
    // 待确认事件（NAPI 侧转确认弹窗；文件清单随事件下发）。
    let pending_files: Option<Vec<AdapterFileDto>> = {
        let uploads = lock(&state.uploads);
        uploads.sessions.get(&token).map(|session| {
            session
                .files
                .values()
                .map(|entry| AdapterFileDto {
                    id: entry.file_id.clone(),
                    file_name: entry.file_name.clone(),
                    size: entry.size,
                    file_type: entry.file_type.clone(),
                    preview: None,
                    sha256: None,
                })
                .collect()
        })
    };
    if let Some(files) = pending_files {
        state
            .emit(ProgressEvent::PrepareUploadRequested {
                token: token.clone(),
                ip: peer.ip().to_string(),
                user_agent,
                files,
            })
            .await;
    }
    match decision_rx.await {
        Ok(true) => {
            lock(&state.uploads).accept(&token, Instant::now());
            upload_list_response(&state, &token)
        }
        Ok(false) => {
            if let Some(session) = lock(&state.uploads).decline(&token) {
                remove_tmp_files(&session);
            }
            text_response(StatusCode::FORBIDDEN, "对方已拒绝")
        }
        Err(_) => {
            lock(&state.uploads).expire(&token);
            text_response(StatusCode::REQUEST_TIMEOUT, "等待确认超时")
        }
    }
}

/// 按 token 下发表（会话缺失时回 408，调用方刷新重试即建新会话）。
fn upload_list_response(state: &WebServiceState, token: &str) -> Response<BoxBody> {
    let uploads = lock(&state.uploads);
    let Some(session) = uploads.sessions.get(token) else {
        return text_response(StatusCode::REQUEST_TIMEOUT, "等待确认超时");
    };
    let mut files: HashMap<String, UploadFileMeta> = HashMap::new();
    for (id, entry) in session.files.iter() {
        files.insert(
            id.clone(),
            UploadFileMeta {
                file_name: entry.file_name.clone(),
                size: entry.size,
            },
        );
    }
    let body = UploadListResponse {
        token: token.to_string(),
        share_id: session.share_id.clone(),
        files,
    };
    let text: String = serde_json::to_string(&body).unwrap_or_else(|_| "{}".to_string());
    json_response(StatusCode::OK, &text)
}

/// `POST /web/upload?token=&fileId=`：请求体即文件字节，流式追加落盘。
/// 超声明回 413（删临时文件并摘除该文件条目）；短包回 400；
/// 完成改名 + `UploadDone`；同文件并发回 409。
async fn receive_upload(
    req: Request<Incoming>,
    query: &HashMap<String, String>,
    state: Arc<WebServiceState>,
    peer: SocketAddr,
) -> Response<BoxBody> {
    let now = Instant::now();
    state.sweep_all(now).await;
    let Some(token) = query.get("token") else {
        return text_response(StatusCode::FORBIDDEN, "无效 token");
    };
    let Some(file_id) = query.get("fileId") else {
        return text_response(StatusCode::BAD_REQUEST, "缺少 fileId");
    };
    // 占位：校验 + 置并发守卫（锁内短操作，IO 在锁外）。
    let (tmp_path, final_path, total, token_owned, file_id_owned) = {
        let mut uploads = lock(&state.uploads);
        let Some(session) = uploads.sessions.get_mut(token) else {
            return text_response(StatusCode::FORBIDDEN, "无效 token");
        };
        if session.peer_ip != peer.ip().to_string() {
            return text_response(StatusCode::FORBIDDEN, "无效 token");
        }
        if !matches!(session.state, UploadState::Accepted) {
            return text_response(StatusCode::FORBIDDEN, "会话未接受");
        }
        let Some(entry) = session.files.get_mut(file_id) else {
            return text_response(StatusCode::FORBIDDEN, "无效 fileId");
        };
        if entry.done {
            return text_response(StatusCode::CONFLICT, "文件已上传");
        }
        if entry.uploading {
            return text_response(StatusCode::CONFLICT, "文件正在上传中");
        }
        entry.uploading = true;
        session.download_started = true;
        session.last_activity = now;
        (
            tmp_path(&entry.path),
            entry.path.clone(),
            entry.size,
            token.clone(),
            file_id.clone(),
        )
    };
    let outcome = stream_upload_body(req.into_body(), &tmp_path, total, &state, &token_owned,
        &file_id_owned)
    .await;
    // 收尾（锁内短操作，只做记账与决策；发射与返回在锁外）。
    enum UploadFinish {
        Gone(&'static str),
        Done {
            received: u64,
        },
        Overflow,
        Short {
            received: u64,
        },
    }
    let action = {
        let mut uploads = lock(&state.uploads);
        let Some(session) = uploads.sessions.get_mut(&token_owned) else {
            let _ = std::fs::remove_file(&tmp_path);
            return text_response(StatusCode::FORBIDDEN, "无效 token");
        };
        let Some(entry) = session.files.get_mut(&file_id_owned) else {
            let _ = std::fs::remove_file(&tmp_path);
            return text_response(StatusCode::FORBIDDEN, "无效 fileId");
        };
        entry.uploading = false;
        session.last_activity = Instant::now();
        match outcome {
            UploadOutcome::Complete { received } => {
                if std::fs::rename(&tmp_path, &final_path).is_err() {
                    let _ = std::fs::remove_file(&tmp_path);
                    session.files.remove(&file_id_owned);
                    UploadFinish::Gone("落盘失败")
                } else {
                    entry.done = true;
                    entry.received = received;
                    UploadFinish::Done { received }
                }
            }
            UploadOutcome::Overflow => {
                let _ = std::fs::remove_file(&tmp_path);
                session.files.remove(&file_id_owned);
                UploadFinish::Overflow
            }
            UploadOutcome::Short { received } => {
                entry.received = received;
                let _ = std::fs::remove_file(&tmp_path);
                UploadFinish::Short { received }
            }
            UploadOutcome::BodyError => {
                let _ = std::fs::remove_file(&tmp_path);
                UploadFinish::Gone("请求体读取失败")
            }
        }
    };
    match action {
        UploadFinish::Gone(message) => {
            let status = if message == "落盘失败" {
                StatusCode::INTERNAL_SERVER_ERROR
            } else {
                StatusCode::BAD_REQUEST
            };
            text_response(status, message)
        }
        UploadFinish::Done { received } => {
            state
                .emit(ProgressEvent::UploadDone {
                    token: token_owned,
                    file_id: file_id_owned,
                    path: final_path,
                })
                .await;
            json_response(
                StatusCode::OK,
                &format!("{{\"ok\":true,\"received\":{received}}}"),
            )
        }
        UploadFinish::Overflow => {
            text_response(StatusCode::PAYLOAD_TOO_LARGE, "内容超出声明大小")
        }
        UploadFinish::Short { received } => text_response(
            StatusCode::BAD_REQUEST,
            &format!("内容长度不符，已收 {received}，声明 {total}"),
        ),
    }
}

/// 上传流式写入结果。
enum UploadOutcome {
    /// 交付完整（字节数 == 声明）。
    Complete {
        received: u64,
    },
    /// 超出声明（已删临时文件）。
    Overflow,
    /// 提前结束（已删临时文件）。
    Short {
        received: u64,
    },
    /// 请求体读取失败。
    BodyError,
}

/// 请求体流式追加到临时文件（上限为声明大小；进度按绝对字节上报）。
async fn stream_upload_body(
    body: Incoming,
    tmp_path: &str,
    total: u64,
    state: &WebServiceState,
    token: &str,
    file_id: &str,
) -> UploadOutcome {
    use http_body_util::BodyExt;
    use tokio::io::AsyncWriteExt;
    let mut body = body;
    let mut file = match tokio::fs::File::create(tmp_path).await {
        Ok(file) => file,
        Err(e) => {
            log::warn!("自研 web 创建上传临时文件失败 path={tmp_path}: {e}");
            return UploadOutcome::BodyError;
        }
    };
    let mut received: u64 = 0;
    let mut throttle = ProgressThrottle::new();
    loop {
        let chunk = match body.frame().await {
            None => break,
            Some(Ok(frame)) => {
                if let Some(data) = frame.data_ref() {
                    data.clone()
                } else {
                    continue;
                }
            }
            Some(Err(_)) => return UploadOutcome::BodyError,
        };
        if received + chunk.len() as u64 > total {
            return UploadOutcome::Overflow;
        }
        if file.write_all(&chunk).await.is_err() {
            return UploadOutcome::BodyError;
        }
        received += chunk.len() as u64;
        if throttle.allow(Instant::now()) {
            state
                .emit(ProgressEvent::UploadProgress {
                    token: token.to_string(),
                    file_id: file_id.to_string(),
                    received_bytes: received,
                    total_bytes: total,
                })
                .await;
        }
    }
    if received == total {
        UploadOutcome::Complete { received }
    } else {
        UploadOutcome::Short { received }
    }
}

/// 内容下发（fd 走 dup+pread 副本直读，路径走文件流式读）。
/// `start` 为绝对偏移；进度按绝对字节上报；仅当分片覆盖到文件末尾
/// （`end_exclusive == total`）且交付完整时发终值 `Done`——
/// 中途分片只给 `Progress`，由调用方续拉剩余部分。
async fn serve_content(
    source: FileSource,
    token: String,
    file_id: String,
    total: u64,
    start: u64,
    end_exclusive: u64,
    body_tx: mpsc::Sender<Bytes>,
    progress_tx: Option<mpsc::Sender<ProgressEvent>>,
) {
    async fn emit(
        progress_tx: &Option<mpsc::Sender<ProgressEvent>>,
        event: ProgressEvent,
    ) {
        if let Some(tx) = progress_tx {
            let _ = tx.send(event).await;
        }
    }
    match source {
        FileSource::Fd(fd) => {
            // fd 所有权归 ArkTS：dup 副本消费，读毕关闭副本。
            let dup_fd: libc::c_int = unsafe { libc::dup(fd) };
            if dup_fd < 0 {
                log::warn!("自研 web 下载 dup 失败 fd={fd}: {}", std::io::Error::last_os_error());
                return;
            }
            let mut offset: libc::off_t = start as libc::off_t;
            let mut sent: u64 = start;
            let mut throttle = ProgressThrottle::new();
            loop {
                if sent >= end_exclusive {
                    break;
                }
                let want: usize =
                    ((end_exclusive - sent).min(READ_BUF_SIZE as u64)) as usize;
                let mut buf = vec![0u8; want];
                let chunk = tokio::task::spawn_blocking(move || {
                    let n = unsafe {
                        libc::pread(
                            dup_fd,
                            buf.as_mut_ptr().cast::<libc::c_void>(),
                            want,
                            offset,
                        )
                    };
                    (n, buf, offset)
                })
                .await;
                let Ok((n, mut buf, read_offset)) = chunk else {
                    break;
                };
                if n <= 0 {
                    break;
                }
                offset = read_offset + n as libc::off_t;
                sent += n as u64;
                buf.truncate(n as usize);
                if throttle.allow(Instant::now()) {
                    emit(
                        &progress_tx,
                        ProgressEvent::Progress {
                            token: token.clone(),
                            file_id: file_id.clone(),
                            sent_bytes: sent,
                            total_bytes: total,
                        },
                    )
                    .await;
                }
                if body_tx.send(Bytes::from(buf)).await.is_err() {
                    // 接收端关闭（浏览器取消下载）：属预期，不记失败。
                    break;
                }
            }
            unsafe {
                libc::close(dup_fd);
            }
            let delivered: u64 = sent.saturating_sub(start);
            let expected: u64 = end_exclusive.saturating_sub(start);
            if delivered != expected {
                log::warn!("自研 web 下发长度不符 file={file_id} 交付={delivered} 期望={expected}");
            }
            // 仅分片覆盖到文件末尾且交付完整时发终值。
            if end_exclusive == total && delivered == expected {
                emit(
                    &progress_tx,
                    ProgressEvent::Done {
                        token,
                        file_id,
                        total_bytes: total,
                    },
                )
                .await;
            }
        }
        FileSource::Path(path) => {
            let mut file = match tokio::fs::File::open(&path).await {
                Ok(file) => file,
                Err(e) => {
                    log::warn!("自研 web 打开文件失败 path={path}: {e}");
                    return;
                }
            };
            {
                use tokio::io::AsyncSeekExt;
                use std::io::SeekFrom;
                if file.seek(SeekFrom::Start(start)).await.is_err() {
                    log::warn!("自研 web 定位失败 path={path} 偏移={start}");
                    return;
                }
            }
            let mut sent: u64 = start;
            let mut throttle = ProgressThrottle::new();
            loop {
                use tokio::io::AsyncReadExt;
                if sent >= end_exclusive {
                    break;
                }
                let want: usize =
                    ((end_exclusive - sent).min(READ_BUF_SIZE as u64)) as usize;
                let mut buf = vec![0u8; want];
                let n = match file.read(&mut buf).await {
                    Ok(n) => n,
                    Err(_) => break,
                };
                if n == 0 {
                    break;
                }
                sent += n as u64;
                buf.truncate(n);
                if throttle.allow(Instant::now()) {
                    emit(
                        &progress_tx,
                        ProgressEvent::Progress {
                            token: token.clone(),
                            file_id: file_id.clone(),
                            sent_bytes: sent,
                            total_bytes: total,
                        },
                    )
                    .await;
                }
                if body_tx.send(Bytes::from(buf)).await.is_err() {
                    break;
                }
            }
            let delivered: u64 = sent.saturating_sub(start);
            let expected: u64 = end_exclusive.saturating_sub(start);
            if delivered != expected {
                log::warn!("自研 web 下发长度不符 file={file_id} 交付={delivered} 期望={expected}");
            }
            // 仅分片覆盖到文件末尾且交付完整时发终值。
            if end_exclusive == total && delivered == expected {
                emit(
                    &progress_tx,
                    ProgressEvent::Done {
                        token,
                        file_id,
                        total_bytes: total,
                    },
                )
                .await;
            }
        }
    }
}

/// 范围请求（`Range` 头解析结果）。
enum RangeRequest {
    /// 从头下发（无头或非法头）。
    Full,
    /// 从偏移下发到末尾或指定末端（含）。
    Partial { start: u64, end: u64 },
    /// 起点超出声明大小。
    Unsatisfiable,
}

/// 解析 `Range` 头：支持 `bytes=start-`/`bytes=start-end`/
/// `bytes=-suffix`；非法格式回落整包，起点越界判不可满足。
fn parse_range(header: Option<&str>, total: u64) -> RangeRequest {
    let header = match header {
        Some(header) => header.trim(),
        None => return RangeRequest::Full,
    };
    let spec = match header.strip_prefix("bytes=") {
        Some(spec) => spec.trim(),
        None => return RangeRequest::Full,
    };
    let (start_text, end_text) = match spec.split_once('-') {
        Some(pair) => pair,
        None => return RangeRequest::Full,
    };
    if start_text.is_empty() {
        // 后缀形式：最后 N 字节。
        if let Ok(suffix) = end_text.trim().parse::<u64>() {
            if suffix == 0 || total == 0 {
                return RangeRequest::Full;
            }
            let start = total.saturating_sub(suffix);
            return RangeRequest::Partial {
                start,
                end: total - 1,
            };
        }
        return RangeRequest::Full;
    }
    let Ok(start) = start_text.trim().parse::<u64>() else {
        return RangeRequest::Full;
    };
    if start >= total {
        return RangeRequest::Unsatisfiable;
    }
    if end_text.trim().is_empty() {
        return RangeRequest::Partial {
            start,
            end: total - 1,
        };
    }
    match end_text.trim().parse::<u64>() {
        Ok(end) if end >= start => RangeRequest::Partial {
            start,
            end: end.min(total - 1),
        },
        _ => RangeRequest::Full,
    }
}
/// 查询串解析（`+` 视为空格，`%XX` 解码；非法序列原样保留）。
fn parse_query(query: &str) -> HashMap<String, String> {
    let mut out: HashMap<String, String> = HashMap::new();
    for pair in query.split('&') {
        if pair.is_empty() {
            continue;
        }
        let (key, value) = match pair.split_once('=') {
            Some((key, value)) => (key, value),
            None => (pair, ""),
        };
        out.insert(percent_decode(key), percent_decode(value));
    }
    out
}

/// 百分号解码（`+` 为空格）。
fn percent_decode(input: &str) -> String {
    let mut out: Vec<u8> = Vec::with_capacity(input.len());
    let bytes = input.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                let hex = &input[i + 1..i + 3];
                if let Ok(byte) = u8::from_str_radix(hex, 16) {
                    out.push(byte);
                    i += 3;
                } else {
                    out.push(b'%');
                    i += 1;
                }
            }
            byte => {
                out.push(byte);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// 文件名编码（RFC 5987 attr 字符集之外转 `%XX`，`/` 已在外层替换）。
fn percent_encode_attr(name: &str) -> String {
    const UNRESERVED: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~!$&'()*+,;=:@";
    let mut out = String::with_capacity(name.len());
    for byte in name.as_bytes() {
        if UNRESERVED.contains(byte) {
            out.push(*byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

fn text_response(status: StatusCode, text: &str) -> Response<BoxBody> {
    full_response(status, "text/plain; charset=utf-8", text)
}

fn json_response(status: StatusCode, body: &str) -> Response<BoxBody> {
    full_response(status, "application/json", body)
}

fn html_full_response(status: StatusCode, body: &str) -> Response<BoxBody> {
    full_response(status, "text/html; charset=utf-8", body)
}

fn full_response(status: StatusCode, content_type: &str, body: &str) -> Response<BoxBody> {
    let body = Full::new(Bytes::from(body.to_string()))
        .map_err(|never| match never {})
        .boxed();
    let mut response = Response::new(body);
    *response.status_mut() = status;
    response.headers_mut().insert(
        CONTENT_TYPE,
        hyper::header::HeaderValue::from_str(content_type)
            .unwrap_or(hyper::header::HeaderValue::from_static("text/plain")),
    );
    response
}

/// 测试用：在回环地址上绑定空闲端口（调用方取 `local_addr` 得实际端口）。
pub async fn bind_loopback() -> std::io::Result<(TcpListener, SocketAddr)> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let addr: SocketAddr = listener.local_addr()?;
    Ok((listener, addr))
}
