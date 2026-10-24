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
use crate::bridge::web::caps::{CapsSnapshot, ShareState};
use crate::bridge::web::session::{
    FileSource, OfferedFile, RetainedFile, SessionEndReason, SessionState, SessionStore,
    SharedFile, SharedFileTable, TokenSession,
};

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
    /// 字节进度（节流，可丢弃语义由消费方定）。
    Progress {
        token: String,
        file_id: String,
        sent_bytes: u64,
        total_bytes: u64,
    },
    /// 文件下发完毕（终值，关键事件）。
    Done {
        token: String,
        file_id: String,
        total_bytes: u64,
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
    /// 会话表。
    pub sessions: Arc<Mutex<SessionStore>>,
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

    /// 惰性打扫：会话超时终结 + 保留区过期释放。
    /// 返回被终结的（token，原因），调用方按终态收口。
    pub fn sweep(&self, now: Instant) -> Vec<(String, SessionEndReason)> {
        lock(&self.retained).retain(|_, entry| entry.deadline > now);
        lock(&self.sessions).sweep(now)
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
    let path = req.uri().path().to_string();
    let query = parse_query(req.uri().query().unwrap_or(""));
    match (req.method().as_str(), path.as_str()) {
        ("GET", "/caps") => Ok(caps_response(&state)),
        ("GET", "/") => Ok(html_response()),
        ("POST", "/web/prepare-download") => Ok(prepare_download(&query, state, peer).await),
        ("GET", "/web/download") => Ok(start_download(&req, &query, state, peer).await),
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
) -> Response<BoxBody> {
    let now = Instant::now();
    state.sweep(now);
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
            user_agent: None,
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
    match decision_rx.await {
        Ok(true) => {
            // 接受方已把会话置接受并刷新时刻；此处幂等确认后下发表。
            lock(&state.sessions).accept(&token, Instant::now());
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
    state.sweep(now);
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
    if removed {
        state
            .emit(ProgressEvent::Finished {
                token: token.clone(),
            })
            .await;
    }
    json_response(StatusCode::OK, "{\"ok\":true}")
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
