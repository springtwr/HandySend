//! 自研 Web 服务路由（token 会话，取代上游 `web.rs`）。
//!
//! 与旧链路的关键差异：
//! - 会话键是浏览器 UUID token（多标签不互踢），token 绑定创建时
//!   对端 IP（换 IP 视为新客户端）；旧按 IP 单槽只留过渡。
//! - `GET /caps` 只读快照，绝不创建会话（旧进页 `POST` 即建挂起
//!   是被替代的根因）；文件表 `revision` 单调增，换表只影响新会话，
//!   被删文件为活跃会话保留到宽限结束。
//! - 终态判定权在调用方（ArkTS 适配器沿用静默/空闲窗口）：服务端做
//!   待确认超时、从未开始的 accepted 会话与长时间无活动的会话回收
//!   （页面心跳 / 字节进度会续期），并周期打扫临时文件。
//! - TLS 复用桥接层共享身份/证书（与 LocalSend 共用证书，开关独立）；
//!   `use_https` 决定连接层是否套 TLS，同时进入 caps 提示位。

use std::collections::hash_map::DefaultHasher;
use std::collections::HashMap;
use std::convert::Infallible;
use std::fs::File;
use std::hash::{Hash, Hasher};
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::{IpAddr, SocketAddr};
use std::os::fd::FromRawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::body::{Frame, Incoming};
use hyper::header::{CACHE_CONTROL, CONTENT_DISPOSITION, CONTENT_LENGTH, CONTENT_TYPE};
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use tokio::net::TcpListener;
use tokio::sync::{mpsc, oneshot, Notify};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::bridge::adapter::types::FileDto as AdapterFileDto;
use crate::bridge::lock;
use crate::bridge::throttle::ProgressThrottle;
use crate::bridge::web::caps::{CapsSnapshot, ShareState};
use crate::bridge::web::i18n::web_page_i18n;
use crate::bridge::web::session::{
    FileSource, OfferedFile, RetainedFile, SessionEndReason, SessionStore, SharedFile,
    SharedFileTable, TokenSession,
};
use crate::bridge::web::upload::{part_path, UploadFile, UploadSession, UploadState, UploadStore};
use crate::bridge::web::zip_plan;

/// 响应体类型（统一装箱，便于在同一路由返回空体与流式体）。
type BoxBody = http_body_util::combinators::BoxBody<Bytes, std::io::Error>;

/// 单页 HTML（与服务同仓，改文案改 JS 只动主仓）。
const SINGLE_HTML: &str = include_str!("assets/single.html");

/// 访问码错误上限（窗口内超过后 429）。
const MAX_PIN_ATTEMPTS: u32 = 3;
/// 访问码错误计数窗口：窗口结束后重新计数，避免永久锁死。
const PIN_ATTEMPT_WINDOW: Duration = Duration::from_secs(60);
/// 浏览器通过访问码后获得的 Cookie 名。
const AUTH_COOKIE: &str = "handysend_web_auth";
/// 浏览器用二维码/URL 能力令牌换取的 Cookie 名。
const CAPABILITY_COOKIE: &str = "handysend_web_cap";
/// 访问码授权有效期（服务重启或访问码变更后全部失效）。
const AUTH_TTL: Duration = Duration::from_secs(24 * 60 * 60);
/// 页面关闭后的结束宽限：刷新会在宽限内重新心跳并取消关闭。
/// 留足重新加载（含文案与快照请求）的时间，避免刷新被误判为关闭。
const LEAVE_GRACE: Duration = Duration::from_secs(15);
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

/// 下载批次终态。
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DownloadOutcome {
    Succeeded,
    Failed,
    Cancelled,
}

impl DownloadOutcome {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
        }
    }
}

/// 进度与终结事件（生产由 ArkTS 侧接入统一注册表；测试直接断言）。
#[derive(Clone, Debug)]
pub enum ProgressEvent {
    /// 网页访问（仅新建 token 时发；只用于日志与后台保活，不建任务）。
    WebAccess {
        ip: String,
        user_agent: Option<String>,
        file_count: usize,
    },
    /// 下载批次开始（第一个 body chunk 成功入队后发）。
    DownloadStarted {
        batch_id: String,
        ip: String,
        user_agent: Option<String>,
        files: Vec<AdapterFileDto>,
    },
    /// 单文件下载进度（zip 内逐条目，单文件即该文件）。
    DownloadProgress {
        batch_id: String,
        file_id: String,
        sent_bytes: u64,
        total_bytes: u64,
    },
    /// 单文件下载完成。
    DownloadFileDone {
        batch_id: String,
        file_id: String,
        total_bytes: u64,
    },
    /// 下载批次结束（成功/失败/取消，只发一次）。
    DownloadEnded {
        batch_id: String,
        outcome: DownloadOutcome,
        error: Option<String>,
    },
    /// 上传待确认（浏览器建会话，等待用户决策；NAPI 侧转确认弹窗）。
    PrepareUploadRequested {
        token: String,
        ip: String,
        user_agent: Option<String>,
        files: Vec<AdapterFileDto>,
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
    /// 上传会话结束（完成回执/终结，调用方按终态收口）。
    Finished { token: String },
}

/// 文件表变化摘要（SSE 推给浏览器；不再只推 revision 数字）。
#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileTableChange {
    pub revision: u64,
    pub added: Vec<AdapterFileDto>,
    pub removed: Vec<String>,
    pub changed: Vec<String>,
}

fn adapter_file_dto(file: &localsend::model::transfer::FileDto) -> AdapterFileDto {
    AdapterFileDto {
        id: file.id.clone(),
        file_name: file.file_name.clone(),
        size: file.size,
        file_type: file.file_type.clone(),
        preview: file.preview.clone(),
        sha256: file.sha256.clone(),
    }
}

/// 访问码错误计数条目（窗口内累计）。
#[derive(Clone, Copy, Debug)]
pub struct PinAttempt {
    /// 窗口内错误次数。
    pub count: u32,
    /// 窗口起点。
    pub first_at: Instant,
}

/// 客户端绑定（能力令牌/访问码 Cookie 共用）：IP + User-Agent 摘要 + 过期时刻。
///
/// Cookie 被复制到其他客户端时，IP 或 UA 不一致即视为无效，
/// 需要在原浏览器重新扫码/输入访问码。
#[derive(Clone, Copy, Debug)]
pub struct ClientBinding {
    /// 绑定的对端 IP。
    pub peer_ip: IpAddr,
    /// 绑定的 User-Agent 摘要。
    pub ua_hash: u64,
    /// 授权过期时刻。
    pub expires_at: Instant,
}

impl ClientBinding {
    /// 请求是否与该绑定一致（IP 与 UA 摘要都必须匹配）。
    fn matches(&self, peer_ip: IpAddr, ua_hash: u64) -> bool {
        self.peer_ip == peer_ip && self.ua_hash == ua_hash
    }
}

/// 连接关闭信号：硬停止或重启服务时通知所有已建立连接退出，
/// 避免浏览器复用旧 keep-alive/SSE 连接继续读到旧状态。
#[derive(Debug, Default)]
pub struct ShutdownSignal {
    closed: AtomicBool,
    notify: Notify,
}

impl ShutdownSignal {
    /// 标记关闭并唤醒所有等待中的连接任务。
    pub fn trigger(&self) {
        self.closed.store(true, Ordering::SeqCst);
        self.notify.notify_waiters();
    }

    /// 是否已触发关闭。
    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    /// 等待关闭信号；信号已触发时立即返回。
    pub async fn wait(&self) {
        if self.is_closed() {
            return;
        }
        let notified = self.notify.notified();
        tokio::pin!(notified);
        // 先注册等待再复查，避免复查与触发之间的丢失唤醒。
        notified.as_mut().enable();
        if self.is_closed() {
            return;
        }
        notified.await;
    }
}

/// 多选下载的待开始批次（POST 登记，GET 消费；不建应用任务）。
#[derive(Clone, Debug)]
pub struct PendingZipBatch {
    pub token: String,
    pub peer_ip: String,
    pub file_ids: Vec<String>,
    pub all: bool,
    pub created_at: Instant,
    pub expires_at: Instant,
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
    /// 本次访问码（`None`/空串表示免访问码）。
    pub expected_pin: Arc<Mutex<Option<String>>>,
    /// 二维码/URL 能力令牌（`None` 表示不启用能力门禁，兼容旧调用与测试）。
    pub capability: Arc<Mutex<Option<String>>>,
    /// 已授权的浏览器 Cookie token → 客户端绑定（访问码）。
    pub auth_sessions: Arc<Mutex<HashMap<String, ClientBinding>>>,
    /// 能力令牌换取的浏览器 Cookie token → 客户端绑定（IP/UA 绑定）。
    pub cap_sessions: Arc<Mutex<HashMap<String, ClientBinding>>>,
    /// 当前分享文件表（换表版本号单调增）。
    pub files: Arc<Mutex<SharedFileTable>>,
    /// 文件展示顺序（与 ArkTS 暂存列表一致；仅用于浏览器列表排序，不参与内容定位）。
    pub file_order: Arc<Mutex<Vec<String>>>,
    /// 被删文件的保留区（宽限内已建会话仍可下）。
    pub retained: Arc<Mutex<HashMap<String, RetainedFile>>>,
    /// 下载会话表。
    pub sessions: Arc<Mutex<SessionStore>>,
    /// 上传会话表（每客户端独立槽，不吃 v2 全局单槽）。
    pub uploads: Arc<Mutex<UploadStore>>,
    /// 上传落盘目录（测试用临时目录；生产接线时 ArkTS 指定接收目录）。
    pub upload_dir: Arc<Mutex<std::path::PathBuf>>,
    /// 访问码错误计数（IP → 窗口内次数与起点）。
    pub pin_attempts: Arc<Mutex<HashMap<IpAddr, PinAttempt>>>,
    /// 进度事件出口（`None` 时不发射，纯传输）。
    pub progress_tx: Option<mpsc::Sender<ProgressEvent>>,
    /// 文件表变化广播（浏览器 SSE 订阅；`None` 时不提供推送，兼容测试）。
    pub file_events: Option<tokio::sync::broadcast::Sender<FileTableChange>>,
    /// 上传会话结束广播（浏览器 SSE 订阅；携带浏览器 token）。
    pub session_events: Option<tokio::sync::broadcast::Sender<String>>,
    /// 多选下载待开始批次（POST 登记，GET 消费；60s 过期）。
    pub pending_batches: Arc<Mutex<HashMap<String, PendingZipBatch>>>,
    /// 活动下载批次的取消标志（应用取消时置位）。
    pub active_batches: Arc<Mutex<HashMap<String, Arc<AtomicBool>>>>,
    /// 上传页关闭宽限：token → 到期时刻；上传进度会移除。
    pub closing: Arc<Mutex<HashMap<String, Instant>>>,
    /// 能力快照变更广播（上传入口开关等；SSE 通知页面刷新 caps）。
    pub caps_events: Option<tokio::sync::broadcast::Sender<()>>,
    /// 服务硬停止/重启时通知已建立连接退出（旧连接不得继续用旧状态应答）。
    pub shutdown: Arc<ShutdownSignal>,
}

impl WebServiceState {
    /// 向浏览器广播会话结束（应用结束任务或服务端超时回收）。
    pub fn broadcast_session_end(&self, token: &str) {
        if let Some(tx) = &self.session_events {
            let _ = tx.send(token.to_string());
        }
    }

    /// 就地换表：版本号 +1；被删条目转入保留区（宽限后释放）；
    /// 同时计算新增/删除/变更摘要供浏览器 SSE 使用。
    pub fn update_files(&self, next: HashMap<String, SharedFile>) {
        let now = Instant::now();
        let deadline = now + RETAIN_GRACE;
        let change = {
            let mut files = lock(&self.files);
            let old = files.files.clone();
            let added: Vec<AdapterFileDto> = next
                .iter()
                .filter(|(id, _)| !old.contains_key(*id))
                .map(|(_, entry)| adapter_file_dto(&entry.file))
                .collect();
            let changed: Vec<String> = next
                .iter()
                .filter(|(id, entry)| {
                    old.get(*id).is_some_and(|previous| {
                        previous.file.file_name != entry.file.file_name
                            || previous.file.size != entry.file.size
                            || previous.file.file_type != entry.file.file_type
                    })
                })
                .map(|(id, _)| id.clone())
                .collect();
            let removed_ids: Vec<String> = old
                .keys()
                .filter(|id| !next.contains_key(*id))
                .cloned()
                .collect();
            let removed = files.replace(next);
            let change = FileTableChange {
                revision: files.revision,
                added,
                removed: removed_ids,
                changed,
            };
            (change, removed)
        };
        let mut retained = lock(&self.retained);
        retained.retain(|_, entry| entry.deadline > now);
        for file in change.1 {
            // ArkTS 在 native 调用返回后立即关闭旧句柄：保留区必须先
            // dup 一份私有 fd，否则宽限期内按旧表下载会读到已关闭/被复用的 fd。
            let Some(source) = file.source.duplicate() else {
                continue;
            };
            let file_id = file.file.id.clone();
            retained.insert(
                file_id,
                RetainedFile {
                    file: SharedFile {
                        file: file.file,
                        source,
                        last_modified_ms: file.last_modified_ms,
                    },
                    deadline,
                },
            );
        }
        if let Some(tx) = &self.file_events {
            let _ = tx.send(change.0);
        }
    }

    /// 停止分享但保留服务进程：清空文件/会话/批次并广播 stopped 状态，
    /// 供已打开的网页立即显示“分享已结束”，也允许短暂内刷新看到结束页。
    pub fn mark_stopped(&self) {
        {
            let mut caps = lock(&self.caps);
            caps.share_state = ShareState::Stopped;
            caps.has_download = false;
            caps.upload_enabled = false;
        }
        {
            let mut files = lock(&self.files);
            files.files.clear();
            files.revision = files.revision.saturating_add(1);
        }
        lock(&self.file_order).clear();
        lock(&self.sessions).sessions.clear();
        lock(&self.pending_batches).clear();
        let active = {
            let mut batches = lock(&self.active_batches);
            std::mem::take(&mut *batches)
        };
        for (_, cancel) in active {
            cancel.store(true, Ordering::SeqCst);
        }
        let uploads = {
            let mut store = lock(&self.uploads);
            std::mem::take(&mut store.sessions)
        };
        for session in uploads.values() {
            remove_tmp_files(session);
        }
        lock(&self.closing).clear();
        lock(&self.retained).clear();
        if let Some(tx) = &self.caps_events {
            let _ = tx.send(());
        }
    }

    /// 标记上传页面关闭：宽限内没有新上传活动则清理上传会话。
    pub fn mark_page_leave(&self, token: &str, peer: SocketAddr) -> bool {
        let known = {
            let uploads = lock(&self.uploads);
            uploads
                .sessions
                .get(token)
                .map(|session| session.peer_ip == peer.ip().to_string())
                .unwrap_or(false)
        };
        if known {
            lock(&self.closing).insert(token.to_string(), Instant::now() + LEAVE_GRACE);
        }
        known
    }

    /// 打扫保留区、待下载批次与过期下载会话；不发应用事件。
    pub fn sweep_retained(&self, now: Instant) {
        lock(&self.retained).retain(|_, entry| entry.deadline > now);
        lock(&self.pending_batches).retain(|_, batch| batch.expires_at > now);
        lock(&self.sessions).cleanup(now);
    }

    /// 惰性打扫上传侧：返回被终结的完整会话，调用方负责清理
    /// 临时文件并上报 `Finished`（同步函数内不做异步发射）。
    pub fn sweep_uploads(&self, now: Instant) -> Vec<(UploadSession, SessionEndReason)> {
        lock(&self.uploads).sweep(now)
    }

    /// 全量惰性打扫（各请求入口调用）：上传超时终结（清临时文件并上报
    /// `Finished`）+ 保留区过期释放 + 上传关闭宽限 + 待下载批次过期。
    pub(crate) async fn sweep_all(&self, now: Instant) {
        self.sweep_retained(now);
        let closed: Vec<String> = {
            let mut closing = lock(&self.closing);
            let expired: Vec<String> = closing
                .iter()
                .filter(|(_, deadline)| **deadline <= now)
                .map(|(token, _)| token.clone())
                .collect();
            for token in &expired {
                closing.remove(token);
            }
            expired
        };
        for token in closed {
            let upload = { lock(&self.uploads).sessions.remove(&token) };
            if let Some(session) = upload {
                remove_tmp_files(&session);
                self.broadcast_session_end(&token);
                self.emit(ProgressEvent::Finished { token }).await;
            }
        }
        for (session, _reason) in self.sweep_uploads(now) {
            self.broadcast_session_end(&session.token);
            remove_tmp_files(&session);
            self.emit(ProgressEvent::Finished {
                token: session.token.clone(),
            })
            .await;
        }
    }

    /// 当前访问码（空串按未设置处理）。
    fn password(&self) -> Option<String> {
        lock(&self.expected_pin)
            .clone()
            .filter(|pin| !pin.is_empty())
    }

    /// 是否需要访问码。
    pub fn auth_required(&self) -> bool {
        self.password().is_some()
    }

    /// 访问码锁定剩余秒数（用于 429 的 Retry-After；无锁定返回 0）。
    fn pin_retry_after(&self, ip: IpAddr) -> u64 {
        let now = Instant::now();
        let attempts = lock(&self.pin_attempts);
        attempts
            .get(&ip)
            .map(|entry| {
                PIN_ATTEMPT_WINDOW
                    .saturating_sub(now.duration_since(entry.first_at))
                    .as_secs()
                    .max(1)
            })
            .unwrap_or(0)
    }

    /// 是否需要二维码/URL 能力令牌门禁。
    pub fn capability_required(&self) -> bool {
        lock(&self.capability).is_some()
    }

    fn capability_token(&self) -> Option<String> {
        lock(&self.capability).clone()
    }

    /// Cookie 会话是否仍有效且与当前客户端（IP + UA）绑定一致。
    fn cookie_session_valid(
        &self,
        sessions: &Arc<Mutex<HashMap<String, ClientBinding>>>,
        cookie_name: &str,
        headers: &hyper::HeaderMap,
        peer: SocketAddr,
    ) -> bool {
        let Some(token) = cookie_value(headers, cookie_name) else {
            return false;
        };
        let now = Instant::now();
        let ua_hash = user_agent_hash(headers);
        let mut sessions = lock(sessions);
        sessions.retain(|_, binding| binding.expires_at > now);
        sessions
            .get(token)
            .map(|binding| binding.matches(peer.ip(), ua_hash))
            .unwrap_or(false)
    }

    /// 请求是否已通过能力令牌门禁（未启用能力令牌时恒为真）。
    pub fn has_capability(&self, headers: &hyper::HeaderMap, peer: SocketAddr) -> bool {
        if !self.capability_required() {
            return true;
        }
        self.cookie_session_valid(&self.cap_sessions, CAPABILITY_COOKIE, headers, peer)
    }

    /// 请求是否已通过访问码门禁（未设置访问码时恒为真）。
    pub fn is_password_authorized(&self, headers: &hyper::HeaderMap, peer: SocketAddr) -> bool {
        if !self.auth_required() {
            return true;
        }
        self.cookie_session_valid(&self.auth_sessions, AUTH_COOKIE, headers, peer)
    }

    /// 请求是否通过页面门禁：能力令牌与访问码并列，任一通过即可。
    /// 未启用能力令牌（旧调用/测试）时仍只认访问码。
    pub fn is_authorized(&self, headers: &hyper::HeaderMap, peer: SocketAddr) -> bool {
        if !self.capability_required() {
            return self.is_password_authorized(headers, peer);
        }
        self.has_capability(headers, peer) || self.is_password_authorized(headers, peer)
    }

    /// 校验二维码/URL 能力令牌并发放绑定当前 IP/UA 的 Cookie token。
    /// 调用方须先确认 `capability_required()`；令牌错误返回 `None`。
    fn exchange_capability(
        &self,
        presented: &str,
        headers: &hyper::HeaderMap,
        peer: SocketAddr,
    ) -> Option<String> {
        let expected = self.capability_token()?;
        if !constant_time_eq(presented.as_bytes(), expected.as_bytes()) {
            return None;
        }
        let now = Instant::now();
        let token = uuid::Uuid::new_v4().to_string();
        let mut sessions = lock(&self.cap_sessions);
        sessions.retain(|_, binding| binding.expires_at > now);
        sessions.insert(
            token.clone(),
            ClientBinding {
                peer_ip: peer.ip(),
                ua_hash: user_agent_hash(headers),
                expires_at: now + AUTH_TTL,
            },
        );
        Some(token)
    }

    /// 校验访问码并发放新的浏览器授权 token（绑定当前 IP/UA）。
    /// 窗口内连续错误达到上限回 429；成功清零。
    fn login(
        &self,
        candidate: &str,
        ip: IpAddr,
        headers: &hyper::HeaderMap,
    ) -> Result<String, StatusCode> {
        let Some(expected) = self.password() else {
            return Ok(String::new());
        };
        let now = Instant::now();
        {
            let mut attempts = lock(&self.pin_attempts);
            let entry = attempts.get(&ip).copied();
            if let Some(entry) = entry {
                if now.duration_since(entry.first_at) < PIN_ATTEMPT_WINDOW
                    && entry.count >= MAX_PIN_ATTEMPTS
                {
                    return Err(StatusCode::TOO_MANY_REQUESTS);
                }
            }
            if !constant_time_eq(candidate.as_bytes(), expected.as_bytes()) {
                let next = match entry {
                    Some(entry) if now.duration_since(entry.first_at) < PIN_ATTEMPT_WINDOW => {
                        PinAttempt {
                            count: entry.count + 1,
                            first_at: entry.first_at,
                        }
                    }
                    _ => PinAttempt {
                        count: 1,
                        first_at: now,
                    },
                };
                attempts.insert(ip, next);
                return Err(StatusCode::UNAUTHORIZED);
            }
            attempts.remove(&ip);
        }
        let token = uuid::Uuid::new_v4().to_string();
        let mut sessions = lock(&self.auth_sessions);
        sessions.retain(|_, binding| binding.expires_at > now);
        sessions.insert(
            token.clone(),
            ClientBinding {
                peer_ip: ip,
                ua_hash: user_agent_hash(headers),
                expires_at: now + AUTH_TTL,
            },
        );
        Ok(token)
    }

    /// 在当前表或保留区内定位内容源，并返回一份可独立消费的副本：
    /// fd 在持锁期间 `dup`，内容源后续被换表/回收也不影响正在进行的响应。
    fn locate_source(&self, file_id: &str, now: Instant) -> Option<FileSource> {
        if let Some(found) = lock(&self.files).files.get(file_id).cloned() {
            return found.source.duplicate();
        }
        let retained = lock(&self.retained);
        if let Some(entry) = retained.get(file_id) {
            if entry.deadline > now {
                return entry.file.source.duplicate();
            }
        }
        None
    }

    /// 刷新上传会话的活动时刻（字节进度）。
    pub fn touch_upload(&self, token: &str) {
        lock(&self.uploads).touch(token, Instant::now());
        lock(&self.closing).remove(token);
    }

    /// 上传会话是否仍存在（取消/回收后用于中止正在写入的请求体）。
    pub fn upload_session_active(&self, token: &str) -> bool {
        lock(&self.uploads).contains(token)
    }

    /// 发射进度事件（无出口时静默跳过）。
    async fn emit(&self, event: ProgressEvent) {
        if let Some(tx) = &self.progress_tx {
            let _ = tx.send(event).await;
        }
    }
}

/// User-Agent 摘要（Cookie 会话的身份绑定因子；缺失按空串参与摘要）。
fn user_agent_hash(headers: &hyper::HeaderMap) -> u64 {
    let user_agent: &str = headers
        .get(hyper::header::USER_AGENT)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("");
    let mut hasher = DefaultHasher::new();
    user_agent.hash(&mut hasher);
    hasher.finish()
}

/// 解析请求 Cookie 中的指定项。
fn cookie_value<'a>(headers: &'a hyper::HeaderMap, name: &str) -> Option<&'a str> {
    for value in headers.get_all(hyper::header::COOKIE) {
        let Ok(text) = value.to_str() else {
            continue;
        };
        for pair in text.split(';') {
            let Some((key, value)) = pair.trim().split_once('=') else {
                continue;
            };
            if key.trim() == name {
                return Some(value.trim());
            }
        }
    }
    None
}

/// 常量时间比较，避免访问码逐字节时序泄漏。
fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    let mut diff: usize = left.len() ^ right.len();
    let length = left.len().min(right.len());
    for index in 0..length {
        diff |= (left[index] ^ right[index]) as usize;
    }
    diff == 0
}

/// 删除上传会话未完成的临时文件（终结/拒绝/过期路径统一调用）。
///
/// 只删应用保留临时区里的半成品：已完成条目已被改名为最终交付文件，
/// 会话终结不能删除用户已经收到的内容。
pub(crate) fn remove_tmp_files(session: &UploadSession) {
    for file in session.files.values() {
        if !file.done {
            let _ = std::fs::remove_file(part_path(&file.path));
        }
    }
}

/// 在已绑定的监听器上提供 HTTP/1 服务，直到任务被 abort。
pub async fn run_server(listener: TcpListener, state: Arc<WebServiceState>) {
    run_server_with_tls(listener, state, None).await;
}

/// 在已绑定的监听器上提供 HTTP/1 或 HTTPS 服务（TLS acceptor 由运行时按配置构建）。
pub async fn run_server_with_tls(
    listener: TcpListener,
    state: Arc<WebServiceState>,
    tls_acceptor: Option<tokio_rustls::TlsAcceptor>,
) {
    loop {
        let (stream, peer) = match listener.accept().await {
            Ok(pair) => pair,
            Err(e) => {
                log::debug!("自研 web accept 失败: {e}");
                continue;
            }
        };
        log::debug!("自研 web 接收到连接: {peer}");
        let acceptor = tls_acceptor.clone();
        let conn_state = Arc::clone(&state);
        tokio::spawn(async move {
            if let Some(acceptor) = acceptor {
                match acceptor.accept(stream).await {
                    Ok(tls_stream) => {
                        serve_io(TokioIo::new(tls_stream), conn_state, peer).await;
                    }
                    Err(e) => {
                        log::debug!("自研 web TLS 握手失败: {e}");
                    }
                }
            } else {
                serve_io(TokioIo::new(stream), conn_state, peer).await;
            }
        });
    }
}

/// 在单个连接上跑 hyper HTTP/1（HTTP 与 TLS 共用）。
async fn serve_io<I>(io: TokioIo<I>, state: Arc<WebServiceState>, peer: SocketAddr)
where
    I: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    let shutdown = Arc::clone(&state.shutdown);
    let service = service_fn(move |req: Request<Incoming>| {
        let req_state = Arc::clone(&state);
        async move { handle(req, req_state, peer).await }
    });
    let conn = hyper::server::conn::http1::Builder::new().serve_connection(io, service);
    tokio::pin!(conn);
    if shutdown.is_closed() {
        return;
    }
    tokio::select! {
        biased;
        _ = shutdown.wait() => {
            // 硬停止/重启：直接丢弃连接，关闭旧 TCP/SSE，避免浏览器复用旧状态连接。
            log::debug!("自研 web 旧连接因服务停止而关闭: {peer}");
        }
        result = conn.as_mut() => {
            if let Err(e) = result {
                log::debug!("自研 web 连接结束: {e}");
            }
        }
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
    // 公开路由：单页壳（含能力令牌换取）、文案与访问码登录本身。其余路由统一走
    // 页面门禁（能力令牌或访问码，任一通过），未授权时返回 401。
    match (method.as_str(), path.as_str()) {
        ("GET", "/") => return Ok(page_response(&state, &req, &query, peer, "/")),
        ("GET", "/upload") => return Ok(page_response(&state, &req, &query, peer, "/upload")),
        ("GET", "/i18n.json") => return Ok(i18n_response(&query)),
        ("POST", "/web/auth") => return Ok(login_response(req, &state, peer).await),
        _ => {}
    }
    if !state.is_authorized(req.headers(), peer) {
        // 浏览器直接打开下载链接时给可刷新的友好错误页；
        // 页面内接口仍用文本，由前端按状态码分流（未授权回访问码页）。
        if method.as_str() == "GET" && path.as_str() == "/web/download" {
            return Ok(download_error_response(
                &req,
                StatusCode::UNAUTHORIZED,
                &web_page_i18n(accept_language(&req)).access_ended_reload,
            ));
        }
        return Ok(text_response(StatusCode::UNAUTHORIZED, "需要访问码"));
    }
    match (method.as_str(), path.as_str()) {
        ("GET", "/caps") => Ok(caps_response(&state)),
        ("GET", "/web/events") => Ok(events_response(&state)),
        // 上传地址与下载地址同页（单页按 caps 条件渲染两段）：`/upload`
        // 打开即定位上传段，浏览器扫上传码直达。
        ("POST", "/web/prepare-download") => {
            let user_agent = req
                .headers()
                .get("user-agent")
                .and_then(|v| v.to_str().ok())
                .map(str::to_string);
            Ok(prepare_download(&query, state, peer, user_agent).await)
        }
        ("GET", "/web/download") => Ok(start_download(&req, &query, state, peer).await),
        ("POST", "/web/download-batch") => {
            let body = read_body_capped(req.into_body(), 64 * 1024).await;
            match body {
                Ok(bytes) => Ok(prepare_download_batch(&bytes, &query, state, peer).await),
                Err(_) => Ok(text_response(StatusCode::BAD_REQUEST, "请求体过大")),
            }
        }
        ("GET", "/web/download-batch") => Ok(download_batch(&req, &query, state, peer).await),
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
        ("POST", "/web/leave") => Ok(leave_response(&query, &state, peer)),
        _ => Ok(text_response(StatusCode::NOT_FOUND, "未知路径")),
    }
}

/// `POST /web/auth`：校验访问码并下发 HttpOnly Cookie。
/// 访问码正确后单页直接进入；错误 401、窗口内错误过多 429。
async fn login_response(
    req: Request<Incoming>,
    state: &WebServiceState,
    peer: SocketAddr,
) -> Response<BoxBody> {
    #[derive(serde::Deserialize)]
    struct LoginBody {
        #[serde(default)]
        password: String,
    }
    // 访问码是独立入口：裸地址（书签/手动输入）可直接提交访问码，
    // 不必先持能力 Cookie；错误次数仍按 IP 限速。
    let headers = req.headers().clone();
    let raw = match read_body_capped(req.into_body(), 16 * 1024).await {
        Ok(raw) => raw,
        Err(_) => return text_response(StatusCode::BAD_REQUEST, "请求体过大"),
    };
    let body: LoginBody = match serde_json::from_slice(&raw) {
        Ok(body) => body,
        Err(_) => return text_response(StatusCode::BAD_REQUEST, "请求体不是合法 JSON"),
    };
    match state.login(&body.password, peer.ip(), &headers) {
        Ok(token) => {
            let cookie = cookie_header(AUTH_COOKIE, &token, is_secure(state));
            let mut response = json_response(StatusCode::OK, "{\"ok\":true}");
            if let Ok(value) = hyper::header::HeaderValue::from_str(&cookie) {
                response
                    .headers_mut()
                    .insert(hyper::header::SET_COOKIE, value);
            }
            response
        }
        Err(StatusCode::TOO_MANY_REQUESTS) => {
            let retry_after = state.pin_retry_after(peer.ip()).max(1);
            let mut response = text_response(StatusCode::TOO_MANY_REQUESTS, "尝试次数过多");
            if let Ok(value) = hyper::header::HeaderValue::from_str(&retry_after.to_string()) {
                response
                    .headers_mut()
                    .insert(hyper::header::RETRY_AFTER, value);
            }
            response
        }
        Err(_) => text_response(StatusCode::UNAUTHORIZED, "访问码错误"),
    }
}

/// 当前连接是否使用 HTTPS（决定 Cookie 是否带 `Secure`）。
fn is_secure(state: &WebServiceState) -> bool {
    lock(&state.caps).https_hint
}

/// 构造 HttpOnly Cookie 头。
fn cookie_header(name: &str, token: &str, secure: bool) -> String {
    let secure_flag: &str = if secure { "; Secure" } else { "" };
    format!(
        "{name}={token}; Path=/; HttpOnly; SameSite=Lax; Max-Age={}{secure_flag}",
        AUTH_TTL.as_secs()
    )
}

/// `POST /web/heartbeat?token=`：页面打开期间为已接受的下载会话续期，
/// 避免「页面开着但长时间没点下载」被空闲回收后链接全部失效。
/// `POST /web/leave?token=`：页面关闭信号。仅在宽限内无新心跳时结束会话；
/// 刷新页面会在宽限内重新心跳，从而取消关闭。
fn leave_response(
    query: &HashMap<String, String>,
    state: &WebServiceState,
    peer: SocketAddr,
) -> Response<BoxBody> {
    let Some(token) = query.get("token") else {
        return text_response(StatusCode::BAD_REQUEST, "缺少 token");
    };
    if state.mark_page_leave(token, peer) {
        json_response(StatusCode::OK, "{\"ok\":true}")
    } else {
        text_response(StatusCode::NOT_FOUND, "会话已失效")
    }
}

/// 单页/上传页：二维码能力令牌与访问码是并列入口。
/// 带令牌时换取 HttpOnly Cookie；裸地址在设置了访问码时渲染访问码页，
/// 未设置访问码时给出「请扫码」提示页。
fn page_response(
    state: &WebServiceState,
    req: &Request<Incoming>,
    query: &HashMap<String, String>,
    peer: SocketAddr,
    path: &'static str,
) -> Response<BoxBody> {
    if state.capability_required() {
        if let Some(presented) = query.get("t") {
            match state.exchange_capability(presented, req.headers(), peer) {
                Some(token) => {
                    let cookie = cookie_header(CAPABILITY_COOKIE, &token, is_secure(state));
                    return redirect_with_cookie(path, &cookie);
                }
                None => {
                    let i18n = web_page_i18n(accept_language(req));
                    return friendly_error_page(
                        req,
                        StatusCode::FORBIDDEN,
                        &i18n.access_link_invalid,
                        None,
                    );
                }
            }
        }
        if !state.has_capability(req.headers(), peer) && !state.auth_required() {
            let i18n = web_page_i18n(accept_language(req));
            return friendly_error_page(
                req,
                StatusCode::FORBIDDEN,
                &i18n.access_link_required,
                None,
            );
        }
    }
    html_response(state, req, peer)
}

/// 能力令牌换取成功：带 Cookie 重定向到去掉令牌的干净地址，
/// 避免令牌停留在地址栏、历史记录与后续请求的 Referer 中。
fn redirect_with_cookie(path: &'static str, cookie: &str) -> Response<BoxBody> {
    let mut response = full_response(StatusCode::FOUND, "text/plain; charset=utf-8", "");
    if let Ok(value) = hyper::header::HeaderValue::from_str(path) {
        response
            .headers_mut()
            .insert(hyper::header::LOCATION, value);
    }
    if let Ok(value) = hyper::header::HeaderValue::from_str(cookie) {
        response
            .headers_mut()
            .insert(hyper::header::SET_COOKIE, value);
    }
    response
}

/// 单页 HTML：按当前请求是否已通过页面门禁注入 `data-auth`。
/// 持能力 Cookie 即视为已通过（扫码免访问码）；否则设置了访问码时展示访问码页。
fn html_response(
    state: &WebServiceState,
    req: &Request<Incoming>,
    peer: SocketAddr,
) -> Response<BoxBody> {
    let capability_passed =
        state.capability_required() && state.has_capability(req.headers(), peer);
    let locked = state.auth_required()
        && !state.is_password_authorized(req.headers(), peer)
        && !capability_passed;
    let body = SINGLE_HTML.replace("{{AUTH_STATE}}", if locked { "locked" } else { "open" });
    html_full_response(StatusCode::OK, &body)
}

/// `GET /web/events`：单页 SSE。先发当前文件表版本，随后推送换表版本号、
/// 上传入口开关变更（caps）与会话结束事件；页面据此即时刷新，不必高频轮询。
fn events_response(state: &WebServiceState) -> Response<BoxBody> {
    let Some(tx) = &state.file_events else {
        return text_response(StatusCode::NOT_IMPLEMENTED, "推送未启用");
    };
    let rx = tx.subscribe();
    let initial = FileTableChange {
        revision: lock(&state.files).revision,
        added: Vec::new(),
        removed: Vec::new(),
        changed: Vec::new(),
    };
    let interval = tokio::time::interval(Duration::from_secs(25));
    let file_stream = futures_util::stream::unfold(
        (rx, interval, Some(initial)),
        |(mut rx, mut interval, initial)| async move {
            if let Some(initial) = initial {
                // `retry` 让浏览器（尤其 Safari）在断线后按固定短间隔重连；
                // 单页实例同时负责在 CLOSED 状态下显式重建，双重兜底。
                let chunk = format!(
                    "retry: 3000\ndata: {}\n\n",
                    serde_json::to_string(&initial).unwrap_or_else(|_| "{}".to_string())
                );
                return Some((
                    Ok::<_, std::io::Error>(Frame::data(Bytes::from(chunk))),
                    (rx, interval, None),
                ));
            }
            loop {
                tokio::select! {
                    result = rx.recv() => match result {
                        Ok(change) => {
                            let chunk = format!(
                                "data: {}\n\n",
                                serde_json::to_string(&change).unwrap_or_else(|_| "{}".to_string())
                            );
                            return Some((
                                Ok::<_, std::io::Error>(Frame::data(Bytes::from(chunk))),
                                (rx, interval, None),
                            ));
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => return None,
                    },
                    _ = interval.tick() => {
                        // 命名事件而非注释帧：页面可据此判断连接仍然存活（注释帧不触发 JS 事件）。
                        return Some((
                            Ok::<_, std::io::Error>(Frame::data(Bytes::from_static(
                                b"event: ping\ndata: {}\n\n",
                            ))),
                            (rx, interval, None),
                        ));
                    }
                }
            }
        },
    );
    let (dummy_tx, dummy_rx) = tokio::sync::broadcast::channel::<String>(1);
    drop(dummy_tx);
    let session_rx = state
        .session_events
        .as_ref()
        .map(|tx| tx.subscribe())
        .unwrap_or(dummy_rx);
    let session_stream = futures_util::stream::unfold(session_rx, |mut rx| async move {
        rx.recv().await.ok().map(|token| {
            let chunk = format!("event: session-end\ndata: {token}\n\n");
            (Ok::<_, std::io::Error>(Frame::data(Bytes::from(chunk))), rx)
        })
    });
    // 能力快照变更（上传入口开关等）：页面收到后重新拉 /caps。
    let (dummy_caps_tx, dummy_caps_rx) = tokio::sync::broadcast::channel::<()>(1);
    drop(dummy_caps_tx);
    let caps_rx = state
        .caps_events
        .as_ref()
        .map(|tx| tx.subscribe())
        .unwrap_or(dummy_caps_rx);
    let caps_stream = futures_util::stream::unfold(caps_rx, |mut rx| async move {
        rx.recv().await.ok().map(|()| {
            (
                Ok::<_, std::io::Error>(Frame::data(Bytes::from_static(
                    b"event: caps\ndata: refresh\n\n",
                ))),
                rx,
            )
        })
    });
    let body = http_body_util::StreamBody::new(futures_util::stream::select(
        futures_util::stream::select(file_stream, session_stream),
        caps_stream,
    ));
    let mut response = Response::new(body.boxed());
    let headers = response.headers_mut();
    headers.insert(
        CONTENT_TYPE,
        hyper::header::HeaderValue::from_static("text/event-stream"),
    );
    // no-cache 与 no-store 同时发送：部分 Safari 版本对 SSE 只认 no-cache。
    headers.insert(
        CACHE_CONTROL,
        hyper::header::HeaderValue::from_static("no-cache, no-store"),
    );
    headers.insert(
        hyper::header::CONNECTION,
        hyper::header::HeaderValue::from_static("keep-alive"),
    );
    response
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

/// 文件表响应体（token 会话建立/复用时下发）。
#[derive(serde::Serialize)]
struct FileListResponse {
    token: String,
    #[serde(rename = "shareId")]
    share_id: String,
    revision: u64,
    alias: String,
    files: HashMap<String, localsend::model::transfer::FileDto>,
    /// 文件展示顺序（与 ArkTS 暂存列表一致；浏览器据此渲染列表）。
    #[serde(rename = "fileOrder")]
    file_order: Vec<String>,
}

/// `POST /web/prepare-download?token=`：
/// - token 有效（已接受、同 IP）→ 刷新文件表后直接回表（免重复确认）；
/// - 同 IP 有待确认会话 → 409 + `X-Handysend-Token`（可重试，不堆决策）；
/// - 否则建会话：设置了访问码（请求已过页面门禁，扫码或访问码均可）时直接置为
///   已接受并回表；未设置访问码时等待应用确认：接受回表 / 拒绝回 403 / 决策通道丢弃回 408。
///
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
    // 生产环境总有能力令牌/访问码；无门禁仅测试/旧调用，直接放行并告警，
    // 不再走应用确认（确认链路已删除）。
    if !state.auth_required() && !state.capability_required() {
        log::warn!("网页分享未启用访问门禁，测试/旧调用直接放行");
    }
    let peer_ip: String = peer.ip().to_string();
    if let Some(token) = query.get("token") {
        let (revision, offered) = current_offered(&state);
        let mut session_error: Option<Response<BoxBody>> = None;
        {
            let order = current_order(&state, &offered);
            let mut sessions = lock(&state.sessions);
            match sessions.sessions.get_mut(token) {
                Some(session) if session.peer_ip == peer_ip => {
                    // 页面点击下载前会 prepare：刷新快照并下发当前文件表。
                    session.offered_files = offered;
                    session.offer_order = order;
                    session.file_revision = revision;
                    session.last_used = now;
                }
                Some(_) => {
                    session_error = Some(text_response(StatusCode::FORBIDDEN, "无效 token"));
                }
                None => {}
            }
        }
        if let Some(error) = session_error {
            return error;
        }
        if lock(&state.sessions).contains(token) {
            return file_list_response(&state, token);
        }
    }
    // 新建 token：冻结当前文件表；不产生应用任务。
    let token: String = uuid::Uuid::new_v4().to_string();
    let (revision, offered) = current_offered(&state);
    let order = current_order(&state, &offered);
    let file_count = offered.len();
    {
        let mut sessions = lock(&state.sessions);
        sessions.insert(TokenSession {
            token: token.clone(),
            share_id: lock(&state.share_id).clone(),
            peer_ip: peer_ip.clone(),
            user_agent: user_agent.clone(),
            created_at: now,
            last_used: now,
            offered_files: offered,
            offer_order: order,
            file_revision: revision,
        });
    }
    log::info!(
        "网页访问 ip={} files={} ua={}",
        peer_ip,
        file_count,
        user_agent.as_deref().unwrap_or("")
    );
    state
        .emit(ProgressEvent::WebAccess {
            ip: peer_ip,
            user_agent,
            file_count,
        })
        .await;
    file_list_response(&state, &token)
}

/// 当前文件表 → 会话快照（版本号与文件清单一次性取出）。
fn current_offered(state: &WebServiceState) -> (u64, HashMap<String, OfferedFile>) {
    let files = lock(&state.files);
    let mut offered: HashMap<String, OfferedFile> = HashMap::new();
    for (id, entry) in files.files.iter() {
        offered.insert(
            id.clone(),
            OfferedFile {
                file_id: id.clone(),
                file_revision: files.revision,
                file: entry.file.clone(),
                last_modified_ms: entry.last_modified_ms,
            },
        );
    }
    (files.revision, offered)
}

/// 当前展示顺序：按 ArkTS 下发的顺序过滤出快照内文件；旧调用缺顺序时按文件名兜底。
fn current_order(state: &WebServiceState, offered: &HashMap<String, OfferedFile>) -> Vec<String> {
    let configured = lock(&state.file_order);
    let mut result: Vec<String> = Vec::new();
    let mut seen: HashMap<String, bool> = HashMap::new();
    for id in configured.iter() {
        if offered.contains_key(id) && !seen.contains_key(id) {
            seen.insert(id.clone(), true);
            result.push(id.clone());
        }
    }
    if result.len() < offered.len() {
        let mut rest: Vec<String> = offered
            .keys()
            .filter(|id| !seen.contains_key(*id))
            .cloned()
            .collect();
        rest.sort_by(|a, b| {
            offered[a]
                .file
                .file_name
                .cmp(&offered[b].file.file_name)
                .then_with(|| a.cmp(b))
        });
        result.extend(rest);
    }
    result
}

/// 按 token 下发表（会话缺失时回 403，页面重新 prepare 即建新会话）。
fn file_list_response(state: &WebServiceState, token: &str) -> Response<BoxBody> {
    let sessions = lock(&state.sessions);
    let Some(session) = sessions.sessions.get(token) else {
        return text_response(StatusCode::FORBIDDEN, "会话已失效");
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
        file_order: session.offer_order.clone(),
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
    let i18n = web_page_i18n(accept_language(req));
    let ended_message: &str = &i18n.access_ended_reload;
    let updated_message: &str = &i18n.share_updated_retry;
    let Some(token) = query.get("token") else {
        return download_error_response(req, StatusCode::FORBIDDEN, ended_message);
    };
    let Some(file_id) = query.get("fileId") else {
        return download_error_response(req, StatusCode::BAD_REQUEST, ended_message);
    };
    // 文本预览只是页面内联读取，不计入下载任务/进度，避免预览把任务写成失败。
    let preview: bool = query
        .get("preview")
        .map(|value| value == "1")
        .unwrap_or(false);
    // 校验会话与快照归属（先释放会话锁，避免与 retained→sessions 的打扫锁序冲突）。
    let snapshot_file = {
        let mut sessions = lock(&state.sessions);
        let Some(session) = sessions.sessions.get_mut(token) else {
            return download_error_response(req, StatusCode::FORBIDDEN, ended_message);
        };
        if session.peer_ip != peer.ip().to_string() {
            return download_error_response(req, StatusCode::FORBIDDEN, ended_message);
        }
        session.last_used = now;
        session
            .offered_files
            .get(file_id)
            .map(|offered| offered.file.clone())
    };
    let meta_file = match snapshot_file {
        Some(file) => file,
        None if preview => {
            // 文本预览是页面内联读取：允许读取建会话后新增的当前文件表条目；
            // 真实下载仍严格限制在会话快照内，避免使用旧 token 下载新文件。
            let files = lock(&state.files);
            match files.files.get(file_id) {
                Some(entry) => entry.file.clone(),
                None => {
                    return download_error_response(req, StatusCode::FORBIDDEN, updated_message)
                }
            }
        }
        None => return download_error_response(req, StatusCode::FORBIDDEN, updated_message),
    };
    let total = meta_file.size;
    // 内容源按快照定位：现表优先，保留区兜底（宽限内）。
    // `locate_source` 返回独立副本（fd 已 dup），即使随后换表也不受影响。
    let source = match state.locate_source(file_id, now) {
        Some(found) => found,
        None => return download_error_response(req, StatusCode::GONE, updated_message),
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
        RangeRequest::Partial { start, end } => (start, end + 1, StatusCode::PARTIAL_CONTENT),
        RangeRequest::Unsatisfiable => {
            let mut response = text_response(StatusCode::RANGE_NOT_SATISFIABLE, "范围超出文件大小");
            response.headers_mut().insert(
                hyper::header::CONTENT_RANGE,
                hyper::header::HeaderValue::from_str(&format!("bytes */{total}"))
                    .unwrap_or(hyper::header::HeaderValue::from_static("bytes */*")),
            );
            return response;
        }
    };
    let progress_tx = state.progress_tx.clone();
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
    let (batch, cancel) = if preview {
        (None, None)
    } else {
        let batch_id = uuid::Uuid::new_v4().to_string();
        let cancel = Arc::new(AtomicBool::new(false));
        lock(&state.active_batches).insert(batch_id.clone(), Arc::clone(&cancel));
        (
            Some(BatchEmit {
                batch_id,
                ip: peer.ip().to_string(),
                user_agent: None,
                files: vec![adapter_file_dto(&meta_file)],
            }),
            Some(cancel),
        )
    };
    let serve_state = Arc::clone(&state);
    tokio::spawn(async move {
        serve_content(
            source,
            file_id_owned,
            total,
            start,
            end_exclusive,
            body_tx,
            progress_tx,
            serve_state,
            batch,
            cancel,
            !preview,
        )
        .await;
    });
    let file_name = meta_file.file_name.replace('/', "-");
    let mut response = Response::new(body.boxed());
    *response.status_mut() = status;
    let headers = response.headers_mut();
    headers.insert(
        CONTENT_TYPE,
        hyper::header::HeaderValue::from_static("application/octet-stream"),
    );
    headers.insert(
        CONTENT_DISPOSITION,
        hyper::header::HeaderValue::from_str(&format!(
            "attachment; filename=\"{}\"; filename*=UTF-8''{}",
            percent_encode_attr(&file_name),
            percent_encode_attr(&file_name)
        ))
        .unwrap_or(hyper::header::HeaderValue::from_static("attachment")),
    );
    headers.insert(CONTENT_LENGTH, hyper::header::HeaderValue::from(length));
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
    headers.insert(
        hyper::header::CACHE_CONTROL,
        hyper::header::HeaderValue::from_static("no-store"),
    );
    response
}

/// 一个下载批次的事件上下文（单文件或 zip 共用）。
#[derive(Clone, Debug)]
struct BatchEmit {
    batch_id: String,
    ip: String,
    user_agent: Option<String>,
    files: Vec<AdapterFileDto>,
}

/// 流式 ZIP 响应写入器：把 ZIP 字节块送入 HTTP 响应体通道。
struct ZipResponseWriter {
    tx: mpsc::Sender<Bytes>,
    client_gone: Arc<AtomicBool>,
}

/// 一个待写出的 ZIP 条目：名称、声明大小、源与 Zip64 标记。
struct ZipBatchEntry {
    file_id: String,
    entry_name: String,
    size: u64,
    last_modified_ms: Option<u64>,
    large: bool,
    source: FileSource,
}

/// 阻塞 ZIP 写出的结果。
struct ZipWriteResult {
    outcome: DownloadOutcome,
    error: Option<String>,
}

impl Write for ZipResponseWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.tx
            .blocking_send(Bytes::copy_from_slice(buf))
            .map_err(|_| {
                self.client_gone.store(true, Ordering::Relaxed);
                std::io::Error::new(std::io::ErrorKind::BrokenPipe, "客户端已断开")
            })?;
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// 打开 ZIP 条目的内容源并定位到起点；fd 源由 File 接管关闭。
fn open_zip_source(source: FileSource) -> anyhow::Result<File> {
    match source {
        FileSource::Fd(fd) => {
            let mut file = unsafe { File::from_raw_fd(fd) };
            file.seek(SeekFrom::Start(0))?;
            Ok(file)
        }
        FileSource::Path(path) => Ok(File::open(path)?),
    }
}

/// ZIP 条目名去重：同名文件按 `name_2.ext` 递增，避免覆盖。
fn unique_zip_name(name: &str, used: &mut HashMap<String, usize>) -> String {
    let base = sanitize_file_name(name);
    let count = used.entry(base.clone()).or_insert(0);
    *count += 1;
    if *count == 1 {
        return base;
    }
    let (stem, ext) = base
        .rsplit_once('.')
        .map(|(stem, ext)| (stem.to_string(), format!(".{ext}")))
        .unwrap_or_else(|| (base.clone(), String::new()));
    format!("{stem}_{count}{ext}")
}

fn emit_blocking(tx: &Option<mpsc::Sender<ProgressEvent>>, event: ProgressEvent) -> bool {
    match tx {
        Some(tx) => tx.blocking_send(event).is_ok(),
        None => true,
    }
}

/// 阻塞写出流式 ZIP：数据边读边送响应体，不预打包、不落临时文件。
///
/// 条目名称、大小与 `large` 标记由调用方预先布局；本函数只按布局写出，
/// 并严格校验每个源文件读出的字节数等于声明大小。
fn write_zip_stream(
    tx: mpsc::Sender<Bytes>,
    files: Vec<ZipBatchEntry>,
    force_zip64: bool,
    batch: BatchEmit,
    progress_tx: Option<mpsc::Sender<ProgressEvent>>,
    cancel: Arc<AtomicBool>,
) -> ZipWriteResult {
    let client_gone = Arc::new(AtomicBool::new(false));
    let mut zip = ZipWriter::new_stream(ZipResponseWriter {
        tx,
        client_gone: Arc::clone(&client_gone),
    });
    if force_zip64 {
        // 恰好 4GB 边界时 zip crate 的 `>` 判断会漏掉 Zip64 EOCD；
        // 空 extensible data sector 会强制它写出完整 Zip64 尾部。
        zip.set_raw_zip64_extensible_data_sector(Box::new([]));
    }
    if !emit_blocking(
        &progress_tx,
        ProgressEvent::DownloadStarted {
            batch_id: batch.batch_id.clone(),
            ip: batch.ip.clone(),
            user_agent: batch.user_agent.clone(),
            files: batch.files.clone(),
        },
    ) {
        return ZipWriteResult {
            outcome: DownloadOutcome::Cancelled,
            error: Some("进度通道已关闭".to_string()),
        };
    }
    let mut buffer = vec![0u8; 64 * 1024];
    for entry in files {
        if cancel.load(Ordering::Relaxed) || client_gone.load(Ordering::Relaxed) {
            return ZipWriteResult {
                outcome: DownloadOutcome::Cancelled,
                error: Some("下载已取消".to_string()),
            };
        }
        let options = SimpleFileOptions::default()
            .compression_method(CompressionMethod::Stored)
            .large_file(entry.large)
            .last_modified_time(zip_plan::entry_date_time(entry.last_modified_ms));
        if let Err(e) = zip.start_file(&entry.entry_name, options) {
            return ZipWriteResult {
                outcome: DownloadOutcome::Failed,
                error: Some(format!("创建 zip 条目失败: {e}")),
            };
        }
        let mut file = match open_zip_source(entry.source) {
            Ok(value) => value,
            Err(e) => {
                return ZipWriteResult {
                    outcome: DownloadOutcome::Failed,
                    error: Some(format!("打开源文件失败: {e}")),
                };
            }
        };
        let mut remaining = entry.size;
        let mut sent: u64 = 0;
        let mut throttle = ProgressThrottle::new();
        while remaining > 0 {
            if cancel.load(Ordering::Relaxed) || client_gone.load(Ordering::Relaxed) {
                return ZipWriteResult {
                    outcome: DownloadOutcome::Cancelled,
                    error: Some("下载已取消".to_string()),
                };
            }
            let want = remaining.min(buffer.len() as u64) as usize;
            let read = match file.read(&mut buffer[..want]) {
                Ok(value) => value,
                Err(e) => {
                    return ZipWriteResult {
                        outcome: DownloadOutcome::Failed,
                        error: Some(format!("读取源文件失败: {e}")),
                    };
                }
            };
            if read == 0 {
                return ZipWriteResult {
                    outcome: DownloadOutcome::Failed,
                    error: Some(format!(
                        "zip 源文件长度不足 file={} 声明={} 剩余={}",
                        entry.file_id, entry.size, remaining
                    )),
                };
            }
            if let Err(e) = zip.write_all(&buffer[..read]) {
                let cancelled =
                    cancel.load(Ordering::Relaxed) || client_gone.load(Ordering::Relaxed);
                return ZipWriteResult {
                    outcome: if cancelled {
                        DownloadOutcome::Cancelled
                    } else {
                        DownloadOutcome::Failed
                    },
                    error: Some(format!("写出 zip 失败: {e}")),
                };
            }
            remaining -= read as u64;
            sent += read as u64;
            if throttle.allow(Instant::now())
                && !emit_blocking(
                    &progress_tx,
                    ProgressEvent::DownloadProgress {
                        batch_id: batch.batch_id.clone(),
                        file_id: entry.file_id.clone(),
                        sent_bytes: sent,
                        total_bytes: entry.size,
                    },
                )
            {
                return ZipWriteResult {
                    outcome: DownloadOutcome::Cancelled,
                    error: Some("进度通道已关闭".to_string()),
                };
            }
        }
        // 声明大小之外还有内容：说明源文件在传输期间变化，无法保证
        // Content-Length 与内容一致，直接失败。
        let mut extra = [0u8; 1];
        match file.read(&mut extra) {
            Ok(0) => {}
            Ok(_) => {
                return ZipWriteResult {
                    outcome: DownloadOutcome::Failed,
                    error: Some(format!(
                        "zip 源文件长度超过声明 file={} 声明={}",
                        entry.file_id, entry.size
                    )),
                };
            }
            Err(e) => {
                return ZipWriteResult {
                    outcome: DownloadOutcome::Failed,
                    error: Some(format!("校验源文件长度失败: {e}")),
                };
            }
        }
        if !emit_blocking(
            &progress_tx,
            ProgressEvent::DownloadFileDone {
                batch_id: batch.batch_id.clone(),
                file_id: entry.file_id.clone(),
                total_bytes: entry.size,
            },
        ) {
            return ZipWriteResult {
                outcome: DownloadOutcome::Cancelled,
                error: Some("进度通道已关闭".to_string()),
            };
        }
    }
    if let Err(e) = zip.finish() {
        let cancelled = cancel.load(Ordering::Relaxed) || client_gone.load(Ordering::Relaxed);
        return ZipWriteResult {
            outcome: if cancelled {
                DownloadOutcome::Cancelled
            } else {
                DownloadOutcome::Failed
            },
            error: Some(format!("完成 zip 失败: {e}")),
        };
    }
    ZipWriteResult {
        outcome: DownloadOutcome::Succeeded,
        error: None,
    }
}

/// `POST /web/download-batch?token=`：登记多选下载清单，返回 batchId（不建任务）。
#[derive(serde::Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct DownloadBatchRequest {
    #[serde(default)]
    files: Vec<String>,
    #[serde(default)]
    all: bool,
}

async fn prepare_download_batch(
    body: &[u8],
    query: &HashMap<String, String>,
    state: Arc<WebServiceState>,
    peer: SocketAddr,
) -> Response<BoxBody> {
    let now = Instant::now();
    state.sweep_all(now).await;
    let Some(token) = query.get("token") else {
        return text_response(StatusCode::FORBIDDEN, "无效 token");
    };
    let request: DownloadBatchRequest = match serde_json::from_slice(body) {
        Ok(value) => value,
        Err(_) => return text_response(StatusCode::BAD_REQUEST, "请求体格式错误"),
    };
    let peer_ip = peer.ip().to_string();
    let (file_ids, total_bytes) = {
        let mut sessions = lock(&state.sessions);
        let Some(session) = sessions.sessions.get_mut(token) else {
            return text_response(StatusCode::FORBIDDEN, "会话已失效");
        };
        if session.peer_ip != peer_ip {
            return text_response(StatusCode::FORBIDDEN, "无效 token");
        }
        session.last_used = now;
        let mut ids: Vec<String> = if request.all {
            let mut offered: Vec<&OfferedFile> = session.offered_files.values().collect();
            offered.sort_by(|a, b| {
                a.file
                    .file_name
                    .cmp(&b.file.file_name)
                    .then_with(|| a.file_id.cmp(&b.file_id))
            });
            offered
                .into_iter()
                .map(|item| item.file_id.clone())
                .collect()
        } else {
            request.files
        };
        if ids.is_empty() {
            return text_response(StatusCode::BAD_REQUEST, "未选择文件");
        }
        let mut unique: Vec<String> = Vec::with_capacity(ids.len());
        for id in ids.drain(..) {
            if !unique.contains(&id) {
                if !session.offered_files.contains_key(&id) {
                    return text_response(StatusCode::GONE, "分享内容已更新，请刷新");
                }
                unique.push(id);
            }
        }
        let total: u64 = unique
            .iter()
            .filter_map(|id| session.offered_files.get(id))
            .map(|item| item.file.size)
            .sum();
        (unique, total)
    };
    let batch_id = uuid::Uuid::new_v4().to_string();
    {
        let mut batches = lock(&state.pending_batches);
        batches.insert(
            batch_id.clone(),
            PendingZipBatch {
                token: token.clone(),
                peer_ip,
                file_ids: file_ids.clone(),
                all: request.all,
                created_at: now,
                expires_at: now + Duration::from_secs(60),
            },
        );
    }
    let response = serde_json::json!({
        "batchId": batch_id,
        "fileCount": file_ids.len(),
        "totalBytes": total_bytes,
    });
    json_response(StatusCode::OK, &response.to_string())
}

/// `GET /web/download-batch?batch=`：消费待下载批次并流式下发 ZIP。
async fn download_batch(
    req: &Request<Incoming>,
    query: &HashMap<String, String>,
    state: Arc<WebServiceState>,
    peer: SocketAddr,
) -> Response<BoxBody> {
    let now = Instant::now();
    state.sweep_all(now).await;
    let i18n = web_page_i18n(accept_language(req));
    let ended_message: &str = &i18n.access_ended_reload;
    let updated_message: &str = &i18n.share_updated_retry;
    let Some(batch_id) = query.get("batch") else {
        return download_error_response(req, StatusCode::BAD_REQUEST, ended_message);
    };
    let pending = { lock(&state.pending_batches).remove(batch_id) };
    let Some(pending) = pending else {
        return download_error_response(req, StatusCode::GONE, updated_message);
    };
    if pending.peer_ip != peer.ip().to_string() {
        return download_error_response(req, StatusCode::FORBIDDEN, ended_message);
    }
    let (offered, user_agent) = {
        let sessions = lock(&state.sessions);
        let Some(session) = sessions.get(&pending.token) else {
            return download_error_response(req, StatusCode::FORBIDDEN, ended_message);
        };
        let offered: Vec<OfferedFile> = if pending.all {
            let mut all: Vec<OfferedFile> = session.offered_files.values().cloned().collect();
            all.sort_by(|a, b| {
                a.file
                    .file_name
                    .cmp(&b.file.file_name)
                    .then_with(|| a.file_id.cmp(&b.file_id))
            });
            all
        } else {
            let mut selected: Vec<OfferedFile> = Vec::new();
            for id in &pending.file_ids {
                let Some(item) = session.offered_files.get(id) else {
                    return download_error_response(req, StatusCode::GONE, updated_message);
                };
                selected.push(item.clone());
            }
            selected
        };
        (offered, session.user_agent.clone())
    };
    let (entries, total_len, force_zip64, batch) = {
        if offered.is_empty() {
            return download_error_response(req, StatusCode::GONE, updated_message);
        }
        let mut used: HashMap<String, usize> = HashMap::new();
        let mut planned: Vec<(String, String, u64, Option<u64>, FileSource)> = Vec::new();
        let mut batch_files: Vec<AdapterFileDto> = Vec::new();
        for item in offered.into_iter() {
            let entry_name = unique_zip_name(&item.file.file_name, &mut used);
            let Some(source) = state.locate_source(&item.file_id, now) else {
                return download_error_response(req, StatusCode::GONE, updated_message);
            };
            batch_files.push(adapter_file_dto(&item.file));
            planned.push((
                item.file_id,
                entry_name,
                item.file.size,
                item.last_modified_ms,
                source,
            ));
        }
        let sizes: Vec<zip_plan::SizeEntry> = planned
            .iter()
            .map(|item| zip_plan::SizeEntry {
                name_len: item.1.len(),
                size: item.2,
            })
            .collect();
        let layout = match zip_plan::layout(&sizes) {
            Ok(value) => value,
            Err(e) => {
                log::error!("网页 zip 长度计算失败: {e}");
                return download_error_response(
                    req,
                    StatusCode::INTERNAL_SERVER_ERROR,
                    updated_message,
                );
            }
        };
        let entries: Vec<ZipBatchEntry> = planned
            .into_iter()
            .enumerate()
            .map(
                |(index, (file_id, entry_name, size, last_modified_ms, source))| ZipBatchEntry {
                    file_id,
                    entry_name,
                    size,
                    last_modified_ms,
                    large: layout.entries[index].large,
                    source,
                },
            )
            .collect();
        (
            entries,
            layout.total_len,
            layout.force_zip64,
            BatchEmit {
                batch_id: batch_id.clone(),
                ip: peer.ip().to_string(),
                user_agent,
                files: batch_files,
            },
        )
    };
    let cancel = Arc::new(AtomicBool::new(false));
    lock(&state.active_batches).insert(batch_id.clone(), Arc::clone(&cancel));
    let progress_tx = state.progress_tx.clone();
    let (body_tx, body_rx) = mpsc::channel::<Bytes>(BODY_CHANNEL_CAPACITY);
    // 响应体流超时后丢弃接收端，让阻塞写线程的 blocking_send 失败退出。
    let body = http_body_util::StreamBody::new(futures_util::stream::unfold(
        body_rx,
        |mut rx| async move {
            match tokio::time::timeout(Duration::from_secs(30), rx.recv()).await {
                Ok(Some(chunk)) => Some((Ok::<_, std::io::Error>(Frame::data(chunk)), rx)),
                Ok(None) | Err(_) => None,
            }
        },
    ));
    let serve_state = Arc::clone(&state);
    let batch_for_events = batch.clone();
    tokio::spawn(async move {
        let result = tokio::task::spawn_blocking(move || {
            write_zip_stream(
                body_tx,
                entries,
                force_zip64,
                batch,
                progress_tx,
                Arc::clone(&cancel),
            )
        })
        .await;
        let (outcome, error) = match result {
            Ok(ZipWriteResult { outcome, error }) => (outcome, error),
            Err(e) => (DownloadOutcome::Failed, Some(format!("zip 任务失败: {e}"))),
        };
        let tx = serve_state.progress_tx.clone();
        if let Some(tx) = tx {
            let _ = tx
                .send(ProgressEvent::DownloadEnded {
                    batch_id: batch_for_events.batch_id.clone(),
                    outcome,
                    error,
                })
                .await;
        }
        lock(&serve_state.active_batches).remove(&batch_for_events.batch_id);
    });
    let zip_name = zip_plan::zip_file_name();
    let mut response = Response::new(body.boxed());
    let headers = response.headers_mut();
    headers.insert(
        CONTENT_TYPE,
        hyper::header::HeaderValue::from_static("application/zip"),
    );
    if let Ok(value) =
        hyper::header::HeaderValue::from_str(&format!("attachment; filename=\"{zip_name}\""))
    {
        headers.insert(CONTENT_DISPOSITION, value);
    }
    headers.insert(CONTENT_LENGTH, hyper::header::HeaderValue::from(total_len));
    headers.insert(
        hyper::header::CACHE_CONTROL,
        hyper::header::HeaderValue::from_static("no-store"),
    );
    response
}

/// `POST /web/finish?token=`：上传完成回执（幂等 advisory）。
/// 下载已完成批次收口，不再使用该接口；未知 token 仍回 200（网络重试安全）。
async fn finish_session(
    query: &HashMap<String, String>,
    state: Arc<WebServiceState>,
    peer: SocketAddr,
) -> Response<BoxBody> {
    let Some(token) = query.get("token") else {
        return text_response(StatusCode::FORBIDDEN, "无效 token");
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
    if removed_upload {
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
    /// 文本消息内容（仅手动输入的文本携带；接收端据此识别单条文本消息）。
    #[serde(default)]
    preview: Option<String>,
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
/// 409 响应：带上待确认上传会话 token，页面据此恢复轮询。
fn token_conflict(token: &str) -> Response<BoxBody> {
    let mut response = text_response(StatusCode::CONFLICT, "等待对方确认中");
    if let Ok(value) = hyper::header::HeaderValue::from_str(token) {
        response.headers_mut().insert("x-handysend-token", value);
    }
    response
}

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
    // 复用：token 有效、已接受、同 IP → 直接回表。
    // 这是页面在响应丢失后带 token 重试的通道；会话仍按原声明提供服务。
    if let Some(token) = query.get("token") {
        let uploads = lock(&state.uploads);
        if let Some(session) = uploads.sessions.get(token) {
            if session.peer_ip == peer.ip().to_string() {
                if matches!(session.state, UploadState::Accepted) {
                    drop(uploads);
                    lock(&state.uploads).touch(token, Instant::now());
                    return upload_list_response(&state, token);
                }
                return token_conflict(token);
            }
            return text_response(StatusCode::FORBIDDEN, "无效 token");
        }
    }
    // 同 IP 有待确认上传：不堆决策，带上 token 供页面恢复轮询。
    {
        let uploads = lock(&state.uploads);
        let waiting = uploads
            .sessions
            .values()
            .find(|session| {
                session.peer_ip == peer.ip().to_string()
                    && matches!(session.state, UploadState::Pending { .. })
            })
            .map(|session| session.token.clone());
        if let Some(token) = waiting {
            return token_conflict(&token);
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
        log::warn!(
            "自研 web 创建上传目录失败 dir={} {e:?}",
            upload_dir.display()
        );
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
                preview: entry.preview.clone(),
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
                    preview: entry.preview.clone(),
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
            let _ = lock(&state.uploads).accept(&token, Instant::now());
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
            part_path(&entry.path),
            entry.path.clone(),
            entry.size,
            token.clone(),
            file_id.clone(),
        )
    };
    let outcome = stream_upload_body(
        req.into_body(),
        &tmp_path,
        total,
        &state,
        &token_owned,
        &file_id_owned,
    )
    .await;
    // 收尾（锁内短操作，只做记账与决策；发射与返回在锁外）。
    enum UploadFinish {
        Gone(&'static str),
        Done { received: u64 },
        Overflow,
        Short { received: u64 },
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
        UploadFinish::Overflow => text_response(StatusCode::PAYLOAD_TOO_LARGE, "内容超出声明大小"),
        UploadFinish::Short { received } => text_response(
            StatusCode::BAD_REQUEST,
            &format!("内容长度不符，已收 {received}，声明 {total}"),
        ),
    }
}

/// 上传流式写入结果。
enum UploadOutcome {
    /// 交付完整（字节数 == 声明）。
    Complete { received: u64 },
    /// 超出声明（已删临时文件）。
    Overflow,
    /// 提前结束（已删临时文件）。
    Short { received: u64 },
    /// 请求体读取失败。
    BodyError,
}

/// 请求体流式追加到临时文件（上限为声明大小；进度按绝对字节上报）。
async fn stream_upload_body(
    body: Incoming,
    tmp_path: &std::path::Path,
    total: u64,
    state: &WebServiceState,
    token: &str,
    file_id: &str,
) -> UploadOutcome {
    use http_body_util::BodyExt;
    use tokio::io::AsyncWriteExt;
    let mut body = body;
    // 目标目录下的应用保留临时区：进程被强制终止时只会留下这里的半成品，
    // 下次接受上传时由 UploadStore::set_targets 安全清理。
    if let Some(parent) = tmp_path.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            log::warn!(
                "自研 web 创建上传临时目录失败 path={}: {e}",
                parent.display()
            );
            return UploadOutcome::BodyError;
        }
    }
    let mut file = match tokio::fs::File::create(tmp_path).await {
        Ok(file) => file,
        Err(e) => {
            log::warn!(
                "自研 web 创建上传临时文件失败 path={}: {e}",
                tmp_path.display()
            );
            return UploadOutcome::BodyError;
        }
    };
    let mut received: u64 = 0;
    let mut throttle = ProgressThrottle::new();
    loop {
        // 应用侧结束任务会移除上传会话：立即停止写入并清理 `.part`。
        if !state.upload_session_active(token) {
            return UploadOutcome::BodyError;
        }
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
            state.touch_upload(token);
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
#[allow(clippy::too_many_arguments)]
async fn serve_content(
    source: FileSource,
    file_id: String,
    total: u64,
    start: u64,
    end_exclusive: u64,
    body_tx: mpsc::Sender<Bytes>,
    progress_tx: Option<mpsc::Sender<ProgressEvent>>,
    state: Arc<WebServiceState>,
    batch: Option<BatchEmit>,
    cancel: Option<Arc<AtomicBool>>,
    emit_events: bool,
) {
    async fn emit(progress_tx: &Option<mpsc::Sender<ProgressEvent>>, event: ProgressEvent) {
        if let Some(tx) = progress_tx {
            let _ = tx.send(event).await;
        }
    }
    let mut started = false;
    let mut outcome = DownloadOutcome::Succeeded;
    let mut error: Option<String> = None;
    let mut delivered: u64 = 0;
    let expected: u64 = end_exclusive.saturating_sub(start);

    let emit_started = |batch: &BatchEmit| ProgressEvent::DownloadStarted {
        batch_id: batch.batch_id.clone(),
        ip: batch.ip.clone(),
        user_agent: batch.user_agent.clone(),
        files: batch.files.clone(),
    };
    let emit_file_done = |batch: &BatchEmit| ProgressEvent::DownloadFileDone {
        batch_id: batch.batch_id.clone(),
        file_id: file_id.clone(),
        total_bytes: total,
    };
    let emit_progress = |batch: &BatchEmit, sent: u64| ProgressEvent::DownloadProgress {
        batch_id: batch.batch_id.clone(),
        file_id: file_id.clone(),
        sent_bytes: sent,
        total_bytes: total,
    };
    let emit_ended = |batch: &BatchEmit, outcome: DownloadOutcome, error: Option<String>| {
        ProgressEvent::DownloadEnded {
            batch_id: batch.batch_id.clone(),
            outcome,
            error,
        }
    };

    // 已由 `locate_source` 复制好的内容源：fd 副本在任务结束时关闭。
    struct OwnedFd(libc::c_int);
    impl Drop for OwnedFd {
        fn drop(&mut self) {
            unsafe {
                libc::close(self.0);
            }
        }
    }

    match source {
        FileSource::Fd(fd) => {
            let dup_fd = OwnedFd(fd);
            let raw_fd: libc::c_int = dup_fd.0;
            let mut offset: libc::off_t = start as libc::off_t;
            let mut sent: u64 = start;
            let mut throttle = ProgressThrottle::new();
            loop {
                if sent >= end_exclusive
                    || cancel
                        .as_ref()
                        .is_some_and(|flag| flag.load(Ordering::Relaxed))
                {
                    break;
                }
                let want: usize = ((end_exclusive - sent).min(READ_BUF_SIZE as u64)) as usize;
                let mut buf = vec![0u8; want];
                let chunk = tokio::task::spawn_blocking(move || {
                    let n = unsafe {
                        libc::pread(
                            raw_fd,
                            buf.as_mut_ptr().cast::<libc::c_void>(),
                            want,
                            offset,
                        )
                    };
                    (n, buf, offset)
                })
                .await;
                let Ok((n, mut buf, read_offset)) = chunk else {
                    outcome = DownloadOutcome::Failed;
                    error = Some("读文件任务失败".to_string());
                    break;
                };
                if n <= 0 {
                    outcome = DownloadOutcome::Failed;
                    error = Some("源文件读取不足".to_string());
                    break;
                }
                offset = read_offset + n as libc::off_t;
                sent += n as u64;
                delivered += n as u64;
                buf.truncate(n as usize);
                if emit_events && throttle.allow(Instant::now()) {
                    if !started {
                        if let Some(batch) = &batch {
                            emit(&progress_tx, emit_started(batch)).await;
                            started = true;
                        }
                    }
                    if let Some(batch) = &batch {
                        emit(
                            &progress_tx,
                            emit_progress(batch, sent.saturating_sub(start)),
                        )
                        .await;
                    }
                }
                match tokio::time::timeout(Duration::from_secs(30), body_tx.send(Bytes::from(buf)))
                    .await
                {
                    Ok(Ok(())) => {}
                    Ok(Err(_)) | Err(_) => {
                        outcome = DownloadOutcome::Cancelled;
                        error = Some("客户端已断开".to_string());
                        break;
                    }
                }
            }
        }
        FileSource::Path(path) => {
            let mut file_opt = tokio::fs::File::open(&path).await.ok();
            if file_opt.is_none() {
                outcome = DownloadOutcome::Failed;
                error = Some("打开源文件失败".to_string());
            }
            if let Some(mut file) = file_opt.take() {
                {
                    use std::io::SeekFrom;
                    use tokio::io::AsyncSeekExt;
                    if file.seek(SeekFrom::Start(start)).await.is_err() {
                        outcome = DownloadOutcome::Failed;
                        error = Some("定位源文件失败".to_string());
                    } else {
                        let mut sent: u64 = start;
                        let mut throttle = ProgressThrottle::new();
                        loop {
                            use tokio::io::AsyncReadExt;
                            if sent >= end_exclusive
                                || cancel
                                    .as_ref()
                                    .is_some_and(|flag| flag.load(Ordering::Relaxed))
                            {
                                break;
                            }
                            let want: usize =
                                ((end_exclusive - sent).min(READ_BUF_SIZE as u64)) as usize;
                            let mut buf = vec![0u8; want];
                            let n = match file.read(&mut buf).await {
                                Ok(n) => n,
                                Err(_) => {
                                    outcome = DownloadOutcome::Failed;
                                    error = Some("读取源文件失败".to_string());
                                    break;
                                }
                            };
                            if n == 0 {
                                outcome = DownloadOutcome::Failed;
                                error = Some("源文件读取不足".to_string());
                                break;
                            }
                            sent += n as u64;
                            delivered += n as u64;
                            buf.truncate(n);
                            if emit_events && throttle.allow(Instant::now()) {
                                if !started {
                                    if let Some(batch) = &batch {
                                        emit(&progress_tx, emit_started(batch)).await;
                                        started = true;
                                    }
                                }
                                if let Some(batch) = &batch {
                                    emit(
                                        &progress_tx,
                                        emit_progress(batch, sent.saturating_sub(start)),
                                    )
                                    .await;
                                }
                            }
                            match tokio::time::timeout(
                                Duration::from_secs(30),
                                body_tx.send(Bytes::from(buf)),
                            )
                            .await
                            {
                                Ok(Ok(())) => {}
                                Ok(Err(_)) | Err(_) => {
                                    outcome = DownloadOutcome::Cancelled;
                                    error = Some("客户端已断开".to_string());
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // 0 字节文件也要产生任务并正常收口。
    if emit_events && !started {
        if let Some(batch) = &batch {
            emit(&progress_tx, emit_started(batch)).await;
        }
    }
    if delivered != expected {
        if outcome == DownloadOutcome::Succeeded {
            outcome = DownloadOutcome::Failed;
            error = Some("下发长度不符".to_string());
        }
        log::warn!(
            "自研 web 下发长度不符 file={} 交付={} 期望={}",
            file_id,
            delivered,
            expected
        );
    } else if end_exclusive != total {
        outcome = DownloadOutcome::Cancelled;
        error = Some("分片下载未完成完整文件".to_string());
    } else if emit_events {
        if let Some(batch) = &batch {
            emit(&progress_tx, emit_file_done(batch)).await;
        }
    }
    if let Some(batch) = &batch {
        emit(&progress_tx, emit_ended(batch, outcome, error)).await;
        lock(&state.active_batches).remove(&batch.batch_id);
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
    const UNRESERVED: &[u8] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~!$&'()*+,;=:@";
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

/// 请求首选语言（取 `Accept-Language` 首项，缺失回落简体中文）。
fn accept_language(req: &Request<Incoming>) -> &str {
    req.headers()
        .get(hyper::header::ACCEPT_LANGUAGE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(',').next())
        .map(str::trim)
        .unwrap_or("")
}

/// 浏览器直接打开下载链接失败时的友好错误页。
///
/// 任务结束后心跳窗口内的直链、分享换表后的失效链接等都以浏览器导航方式到达，
/// 纯文本响应会让用户停在无法操作的错误文本页；这里统一给出「刷新页面」入口，
/// 刷新后重新走单页建会话流程（应用侧据此重新确认）。
fn download_error_response(
    req: &Request<Incoming>,
    status: StatusCode,
    message: &str,
) -> Response<BoxBody> {
    let i18n = web_page_i18n(accept_language(req));
    friendly_error_page(req, status, message, Some(("/", &i18n.refresh_page)))
}

/// 统一友好错误页（能力令牌失效、下载链接失效等）。
///
/// `action` 提供可点击出口（如刷新页面）；纯提示场景传 `None`，
/// 避免给出无法解决问题的按钮。
fn friendly_error_page(
    req: &Request<Incoming>,
    status: StatusCode,
    message: &str,
    action: Option<(&'static str, &str)>,
) -> Response<BoxBody> {
    let i18n = web_page_i18n(accept_language(req));
    let action_html: String = match action {
        Some((href, label)) => format!(r#"<a class="action" href="{href}">{label}</a>"#),
        None => String::new(),
    };
    let body: String = format!(
        r#"<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{app}</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{
    margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
    padding: 24px; box-sizing: border-box; font-family: system-ui, -apple-system, "HarmonyOS Sans", sans-serif;
    background: #f2f3f5; color: #1a1a1a;
  }}
  .card {{
    width: 100%; max-width: 360px; padding: 28px 24px; border-radius: 20px;
    background: #ffffff; text-align: center; box-shadow: 0 8px 32px rgba(0, 0, 0, 0.08);
  }}
  .brand {{ font-size: 14px; opacity: 0.55; margin-bottom: 12px; }}
  .message {{ font-size: 16px; line-height: 1.6; margin: 0 0 24px; }}
  .action {{
    display: inline-block; padding: 12px 28px; border-radius: 999px;
    background: #0a59f7; color: #ffffff; font-size: 15px; text-decoration: none;
  }}
  @media (prefers-color-scheme: dark) {{
    body {{ background: #121212; color: #f5f5f5; }}
    .card {{ background: #1e1e1e; box-shadow: none; }}
    .action {{ background: #317af7; }}
  }}
</style>
</head>
<body>
<div class="card">
<div class="brand">{app}</div>
<p class="message">{message}</p>
{action}
</div>
</body>
</html>"#,
        app = i18n.app_name,
        message = message,
        action = action_html,
    );
    html_full_response(status, &body)
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
    let headers = response.headers_mut();
    headers.insert(
        CONTENT_TYPE,
        hyper::header::HeaderValue::from_str(content_type)
            .unwrap_or(hyper::header::HeaderValue::from_static("text/plain")),
    );
    // 网页内容与接口都随分享状态实时变化，禁止浏览器缓存旧页面/旧文件表。
    headers.insert(
        hyper::header::CACHE_CONTROL,
        hyper::header::HeaderValue::from_static("no-store"),
    );
    headers.insert(
        hyper::header::X_CONTENT_TYPE_OPTIONS,
        hyper::header::HeaderValue::from_static("nosniff"),
    );
    response
}

/// 测试用：在回环地址上绑定空闲端口（调用方取 `local_addr` 得实际端口）。
pub async fn bind_loopback() -> std::io::Result<(TcpListener, SocketAddr)> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let addr: SocketAddr = listener.local_addr()?;
    Ok((listener, addr))
}
