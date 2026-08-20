//! HarmonyOS 的 LocalSend NAPI 桥接——napi-rs 入口点。
//!
//! 所有函数均通过 `#[napi]` 宏注册，自动
//! 生成 `napi_register_module_v1` 和 `napi_define_properties` 条目。
//!
//! 桥接层通过以下方式包装上游 [`localsend`] 协议实现：
//! 门面层，确保 NAPI 层绝不直接导入上游
//! 内部类型。

mod bridge;

use bridge::facade;
use bridge::state::bridge;

use localsend::model::discovery::PROTOCOL_VERSION_V2;
use localsend::http::client::ClientError;
use napi_ohos::bindgen_prelude::*;
use napi_ohos::threadsafe_function::ThreadsafeFunction;
use napi_derive_ohos::napi;

fn client_error_to_http_error(e: &ClientError) -> HttpError {
    match e {
        ClientError::StatusCode(se) => HttpError {
            kind: "statusCode".to_string(),
            status: Some(se.status),
            message: se.message.clone(),
        },
        ClientError::Reqwest(re) => HttpError {
            kind: "reqwest".to_string(),
            status: None,
            message: Some(format!("{re:#}")),
        },
        ClientError::Json(je) => HttpError {
            kind: "json".to_string(),
            status: None,
            message: Some(je.to_string()),
        },
        ClientError::Io(ie) => HttpError {
            kind: "io".to_string(),
            status: None,
            message: Some(ie.to_string()),
        },
        ClientError::Other(ae) => HttpError {
            kind: "other".to_string(),
            status: None,
            message: Some(format!("{ae:#}")),
        },
        ClientError::Cancelled => HttpError {
            kind: "cancelled".to_string(),
            status: None,
            message: Some("Operation cancelled".to_string()),
        },
    }
}

// ── 版本信息 ──────────────────────────────────────────────────────────────

/// 返回原生库版本（来自 Cargo.toml）
#[napi]
pub fn get_native_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// 返回原生库名称
#[napi]
pub fn get_native_name() -> String {
    env!("CARGO_PKG_NAME").to_string()
}

/// 返回本库实现的 LocalSend 协议版本（例如 "2.2"）
#[napi]
pub fn get_protocol_version() -> String {
    PROTOCOL_VERSION_V2.to_string()
}

// ── NAPI 对象结构 ──────────────────────────────────────────────────────

#[napi(object)]
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferFileInfo {
    pub file_id: String,
    pub file_name: String,
    pub size: i64,
    pub file_type: String,
    pub preview: Option<String>,
    pub sha256: Option<String>,
}

#[napi(object)]
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferRequest {
    pub session_id: String,
    pub sender_alias: String,
    pub sender_fingerprint: String,
    pub sender_protocol: String,
    pub files: Vec<TransferFileInfo>,
}

#[napi(object)]
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerStatus {
    pub running: bool,
    pub active_session: Option<String>,
    pub fingerprint: Option<String>,
}

#[napi(object)]
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecvDiag {
    pub drain_count: i64,
    pub queued_events: i64,
}

#[napi(object)]
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerHandle {
    pub fingerprint: String,
    pub port: u16,
}

#[napi(object)]
#[derive(serde::Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct HttpError {
    pub kind: String,
    pub status: Option<u16>,
    pub message: Option<String>,
}

#[napi(object)]
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SendResult {
    pub session_id: String,
    pub success: bool,
    pub failed_files: Vec<String>,
    pub error: Option<HttpError>,
}

#[napi(object)]
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShareLinkInfo {
    pub url: String,
    pub port: u16,
    pub session_id: String,
}

// ── 初始化 / 销毁 ──────────────────────────────────────────────────────────

#[napi]
pub fn init(alias: String, device_type: String, _log_level: Option<String>) -> Result<()> {
    let dt = facade::parse_device_type(&device_type);

    facade::init(alias, dt).map_err(|e| Error::from_reason(format!("Init failed: {e:#}")))?;

    log::info!("Bridge initialized");
    Ok(())
}

#[napi]
pub fn deinit() -> Result<()> {
    let mut state = bridge().lock().unwrap();
    state.server_handle.take();
    state.discovery_stop_tx.take();
    state.discovery_event_task.take();
    state.discovery_handle.take();
    state.event_tx.take();
    state.show_token.take();
    state.callback.take();
    state.pending_decisions.clear();
    state.active_transfers.clear();
    state.cancel_tokens.clear();
    state.pending_file_uploads.clear();
    state.pending_file_downloads.clear();
    state.send_progress.lock().unwrap().clear();
    state.recv_progress.lock().unwrap().clear();
    state.pending_requests.lock().unwrap().clear();
    state.debug_log.lock().unwrap().clear();
    *state.current_send_session_id.lock().unwrap() = String::new();
    *state.share_link_info.lock().unwrap() = None;
    *state.recv_diag_drain_count.lock().unwrap() = 0;
    if let Some(rt) = state.runtime.take() {
        rt.shutdown_background();
    }
    log::info!("Bridge deinitialized");
    Ok(())
}

// ── 事件回调 ───────────────────────────────────────────────────────────

#[napi]
pub fn register_event_listener(callback: ThreadsafeFunction<String>) -> Result<()> {
    let cb = bridge::callback::EventCallback::new(callback);
    let mut state = bridge().lock().unwrap();
    state.callback = Some(cb);
    log::info!("Event listener registered");
    Ok(())
}

// ── 服务器 ───────────────────────────────────────────────────────────────────

#[napi]
pub async fn start_server(
    port: u16,
    use_https: bool,
    verify_checksums: bool,
    pin: Option<String>,
) -> Result<()> {
    bridge::server_facade::start_server(port, use_https, verify_checksums, pin, None)
        .await
        .map_err(|e| Error::from_reason(format!("Start server failed: {e:#}")))?;
    log::info!("Server started on port {port}");
    Ok(())
}

#[napi]
pub fn stop_server() -> Result<()> {
    bridge::server_facade::stop_server();
    log::info!("Server stopped");
    Ok(())
}

// ── 发现 ────────────────────────────────────────────────────────────────

#[napi]
pub async fn start_discovery_v2(config: String) -> Result<()> {
    bridge::discovery_facade::start_discovery_v2(&config)
        .await
        .map_err(|e| Error::from_reason(format!("Start discovery v2 failed: {e:#}")))?;
    log::info!("Discovery v2 started");
    Ok(())
}

#[napi]
pub async fn discovery_announce() -> Result<()> {
    bridge::discovery_facade::discovery_announce()
        .await
        .map_err(|e| Error::from_reason(format!("Discovery announce failed: {e:#}")))?;
    Ok(())
}

#[napi]
pub async fn discovery_discover_staged(
    channels: String,
    interface_ips: String,
    port: u16,
    protocol: String,
    grace_ms: u32,
) -> Result<()> {
    bridge::discovery_facade::discovery_discover_staged(&channels, &interface_ips, port, &protocol, grace_ms)
        .await
        .map_err(|e| Error::from_reason(format!("Discovery discover_staged failed: {e:#}")))?;
    Ok(())
}

#[napi]
pub async fn discovery_scan_subnet(
    interface_ip: String,
    port: u16,
    protocol: String,
) -> Result<()> {
    bridge::discovery_facade::discovery_scan_subnet(&interface_ip, port, &protocol)
        .await
        .map_err(|e| Error::from_reason(format!("Discovery scan_subnet failed: {e:#}")))?;
    Ok(())
}

#[napi]
pub async fn discovery_add_device(device: String) -> Result<()> {
    bridge::discovery_facade::discovery_add_device(&device)
        .await
        .map_err(|e| Error::from_reason(format!("Discovery add_device failed: {e:#}")))?;
    Ok(())
}

#[napi]
pub fn discovery_set_answer_announcements(answer: bool) -> Result<()> {
    bridge::discovery_facade::discovery_set_answer_announcements(answer)
        .map_err(|e| Error::from_reason(format!("Discovery set_answer_announcements failed: {e:#}")))?;
    Ok(())
}

#[napi]
pub fn discovery_stop() -> Result<()> {
    bridge::discovery_facade::discovery_stop()
        .map_err(|e| Error::from_reason(format!("Discovery stop failed: {e:#}")))?;
    log::info!("Discovery stopped");
    Ok(())
}

#[napi]
pub fn discovery_get_devices() -> String {
    bridge::discovery_facade::discovery_get_devices()
}

#[napi]
pub fn discovery_get_device(fingerprint: String) -> String {
    bridge::discovery_facade::discovery_get_device(&fingerprint)
}

#[napi]
pub fn discovery_multicast_error() -> String {
    bridge::discovery_facade::discovery_multicast_error()
}

/// 按指纹获取设备确认日志。
/// 返回日志条目的 JSON 数组。
#[napi]
pub fn discovery_device_logs(fingerprint: String) -> String {
    bridge::discovery_facade::discovery_device_logs(&fingerprint)
}

// ── 查询 ────────────────────────────────────────────────────────────────────

#[napi]
pub fn get_local_device() -> String {
    facade::get_local_device_json()
}

#[napi]
pub fn get_fingerprint() -> String {
    let state = bridge().lock().unwrap();
    state.fingerprint.clone()
}

#[napi]
pub fn get_local_addresses() -> Vec<String> {
    facade::get_local_addresses()
}

// ── 接收 / 拒绝 ─────────────────────────────────────────────────────────

#[napi]
pub fn accept_transfer(session_id: String, file_ids: Vec<String>) -> Result<()> {
    bridge::server_facade::accept_transfer(&session_id, &file_ids)
        .map_err(|e| Error::from_reason(format!("Accept transfer failed: {e:#}")))?;
    log::info!("Transfer accepted: {session_id}");
    Ok(())
}

#[napi]
pub fn decline_transfer(session_id: String) -> Result<()> {
    bridge::server_facade::decline_transfer(&session_id)
        .map_err(|e| Error::from_reason(format!("Decline transfer failed: {e:#}")))?;
    log::info!("Transfer declined: {session_id}");
    Ok(())
}

// ── 发送 ─────────────────────────────────────────────────────────────────────

#[napi]
pub async fn prepare_send(
    target_ip: String,
    port: u16,
    protocol: String,
    files_json: String,
    pin: Option<String>,
    expected_fingerprint: Option<String>,
    public_key: Option<String>,
) -> Result<String> {
    let target_protocol = facade::parse_protocol_helper(&protocol);
    bridge::client_facade::prepare_send(&target_ip, port, target_protocol, &files_json, pin, expected_fingerprint, public_key)
        .await
        .map_err(|e| Error::from_reason(format!("Prepare send failed: {e:#}")))
}

#[napi]
pub async fn upload_file(
    target_ip: String,
    port: u16,
    protocol: String,
    session_id: String,
    file_id: String,
    token: String,
    file_path: String,
    expected_fingerprint: Option<String>,
    public_key: Option<String>,
    cancel_id: Option<String>,
) -> Result<()> {
    let target_protocol = facade::parse_protocol_helper(&protocol);
    bridge::client_facade::upload_file(&target_ip, port, target_protocol, &session_id, &file_id, &token, &file_path, expected_fingerprint, public_key, cancel_id)
        .await
        .map_err(|e| Error::from_reason(format!("Upload failed: {e:#}")))?;
    log::info!("Uploaded: {file_path} -> {session_id}");
    Ok(())
}

// ── 取消 ───────────────────────────────────────────────────────────────────

#[napi]
pub fn cancel_transfer(session_id: String) -> Result<()> {
    bridge::client_facade::cancel_transfer(&session_id);
    log::info!("Transfer cancelled: {session_id}");
    Ok(())
}

// ── 高级 API ───────────────────────────────────────────────────────────

#[napi]
pub async fn create_server(config: String) -> Result<ServerHandle> {
    let json_str = bridge::server_facade::create_server(&config)
        .await
        .map_err(|e| Error::from_reason(format!("Create server failed: {e:#}")))?;
    serde_json::from_str(&json_str)
        .map_err(|e| Error::from_reason(format!("Parse ServerHandle failed: {e:#}")))
}

#[napi]
pub async fn send_files(
    target: String,
    sender_alias: String,
    files: String,
) -> Result<SendResult> {
    let json_str = bridge::client_facade::send_files(&target, &sender_alias, &files)
        .await
        .map_err(|e| Error::from_reason(format!("Send files failed: {e:#}")))?;
    serde_json::from_str(&json_str)
        .map_err(|e| Error::from_reason(format!("Parse SendResult failed: {e:#}")))
}

// ── 发现注册（支持 mTLS） ────────────────────────────────────────

#[napi]
pub async fn register_device(
    target_ip: String,
    target_port: u16,
    our_alias: String,
    our_fingerprint: String,
    our_protocol: String,
    our_device_model: Option<String>,
    our_device_type: Option<String>,
    our_port: u16,
    our_ip: Option<String>,
) -> Result<String> {
    let model = our_device_model.unwrap_or_default();
    let dtype = our_device_type.unwrap_or_else(|| "mobile".to_string());
    let ip = our_ip.unwrap_or_default();
    bridge::client_facade::register_device(
        &target_ip,
        target_port,
        &our_alias,
        &our_fingerprint,
        &our_protocol,
        &model,
        &dtype,
        our_port,
        &ip,
    )
    .await
    .map_err(|e| Error::from_reason(format!("Register device failed: {e:#}")))
}

// ── 客户端信息 ──────────────────────────────────────────────────────────────

#[napi]
pub async fn client_info(
    protocol: String,
    ip: String,
    port: u16,
) -> Result<String> {
    let protocol_enum = facade::parse_protocol_helper(&protocol);
    bridge::client_facade::client_info(protocol_enum, &ip, port)
        .await
        .map_err(|e| Error::from_reason(format!("Client info failed: {e:#}")))
}

// ── Download API ──

#[napi]
pub async fn prepare_download(
    target_ip: String,
    port: u16,
    protocol: String,
    session_id: Option<String>,
    pin: Option<String>,
) -> Result<String> {
    let protocol_enum = facade::parse_protocol_helper(&protocol);
    bridge::client_facade::prepare_download(&target_ip, port, protocol_enum, session_id, pin)
        .await
        .map_err(|e| Error::from_reason(format!("Prepare download failed: {e:#}")))
}

#[napi]
pub async fn download_file(
    target_ip: String,
    port: u16,
    protocol: String,
    session_id: String,
    file_id: String,
    save_path: String,
    public_key: Option<String>,
) -> Result<f64> {
    let protocol_enum = facade::parse_protocol_helper(&protocol);
    let bytes = bridge::client_facade::download_file(
        &target_ip, port, protocol_enum, &session_id, &file_id, &save_path, public_key,
    )
        .await
        .map_err(|e| Error::from_reason(format!("Download file failed: {e:#}")))?;
    Ok(bytes as f64)
}

// ── 缓冲区上传 ──

#[napi]
pub async fn upload_from_buffer(
    target_ip: String,
    port: u16,
    protocol: String,
    session_id: String,
    file_id: String,
    token: String,
    buffer: Buffer,
    public_key: Option<String>,
    cancel_id: Option<String>,
) -> Result<()> {
    let protocol_enum = facade::parse_protocol_helper(&protocol);
    let data: Vec<u8> = buffer.to_vec();
    bridge::client_facade::upload_from_buffer(
        &target_ip, port, protocol_enum, &session_id, &file_id, &token, data, public_key, cancel_id,
    )
        .await
        .map_err(|e| Error::from_reason(format!("Upload from buffer failed: {e:#}")))?;
    Ok(())
}

/// 将待处理的文件下载标记为失败（导致 500 响应）。
#[napi]
pub fn fail_file_download(session_id: String, file_id: String) -> Result<()> {
    bridge::server_facade::fail_file_download(&session_id, &file_id)
        .map_err(|e| Error::from_reason(format!("Fail file download failed: {e:#}")))
}

/// 将待处理的文件上传标记为失败（导致 500 响应）。
#[napi]
pub fn fail_file_upload(session_id: String, file_id: String) -> Result<()> {
    bridge::server_facade::fail_file_upload(&session_id, &file_id)
        .map_err(|e| Error::from_reason(format!("Fail file upload failed: {e:#}")))
}

#[napi]
pub fn poll_pending_requests() -> Vec<TransferRequest> {
    let requests = bridge::server_facade::poll_pending_requests();
    requests
        .into_iter()
        .map(|r| TransferRequest {
            session_id: r.session_id,
            sender_alias: r.sender_alias,
            sender_fingerprint: r.sender_fingerprint,
            sender_protocol: r.sender_protocol,
            files: r
                .files
                .into_iter()
                .map(|f| TransferFileInfo {
                    file_id: f.file_id,
                    file_name: f.file_name,
                    size: f.size as i64,
                    file_type: f.file_type,
                    preview: f.preview,
                    sha256: f.sha256,
                })
                .collect(),
        })
        .collect()
}

#[napi]
pub async fn respond_transfer(
    session_id: String,
    accept: bool,
    accepted_file_ids: Vec<String>,
) -> Result<()> {
    bridge::server_facade::respond_transfer(&session_id, accept, &accepted_file_ids)
        .map_err(|e| Error::from_reason(format!("Respond transfer failed: {e:#}")))?;
    Ok(())
}

#[napi]
pub fn get_server_status() -> ServerStatus {
    let json_str = bridge::server_facade::get_server_status();
    serde_json::from_str(&json_str).unwrap_or(ServerStatus {
        running: false,
        active_session: None,
        fingerprint: None,
    })
}
#[napi]
pub fn get_current_send_session_id() -> String {
    bridge::server_facade::get_current_send_session_id()
}

#[napi]
pub async fn cancel_transfer_remote(target: String, session_id: String) -> Result<()> {
    bridge::client_facade::cancel_transfer_remote(&target, &session_id)
        .await
        .map_err(|e| Error::from_reason(format!("Cancel transfer remote failed: {e:#}")))
}

#[napi]
pub fn cancel_local_session(session_id: String) -> Result<()> {
    bridge::server_facade::cancel_local_session(&session_id);
    Ok(())
}

#[napi]
pub fn compute_fingerprint(cert_pem: String) -> String {
    facade::compute_fingerprint(&cert_pem)
}

#[napi]
pub fn verify_fingerprint(cert_pem: String, expected: String) -> bool {
    facade::verify_fingerprint(&cert_pem, &expected)
}

#[napi]
pub fn poll_debug_log() -> Vec<String> {
    facade::poll_debug_log()
}

/// 为 Rust 层启用调试级日志。
#[napi]
pub fn enable_debug_logging() -> Result<()> {
    facade::enable_debug_logging()
        .map_err(|e| Error::from_reason(format!("Enable debug logging failed: {e:#}")))
}

#[napi]
pub async fn create_share_link(files: String, alias: String) -> Result<ShareLinkInfo> {
    let json_str = facade::create_share_link(&files, &alias)
        .await
        .map_err(|e| Error::from_reason(format!("Create share link failed: {e:#}")))?;
    serde_json::from_str(&json_str)
        .map_err(|e| Error::from_reason(format!("Parse ShareLinkInfo failed: {e:#}")))
}

#[napi]
pub async fn stop_share_server() -> Result<()> {
    facade::stop_share_server().await;
    Ok(())
}

#[napi]
pub fn accept_web_download(session_id: String) -> Result<()> {
    bridge::server_facade::accept_web_download(&session_id)
        .map_err(|e| Error::from_reason(format!("Accept web download failed: {e:#}")))?;
    Ok(())
}

#[napi]
pub fn decline_web_download(session_id: String) -> Result<()> {
    bridge::server_facade::decline_web_download(&session_id)
        .map_err(|e| Error::from_reason(format!("Decline web download failed: {e:#}")))?;
    Ok(())
}

#[napi]
pub async fn start_web_upload() -> Result<u16> {
    bridge::server_facade::start_web_upload()
        .await
        .map_err(|e| Error::from_reason(format!("Start web upload failed: {e:#}")))
}



#[napi]
pub fn get_recv_diag() -> RecvDiag {
    let json_str = facade::get_recv_diag();
    serde_json::from_str(&json_str).unwrap_or(RecvDiag {
        drain_count: 0,
        queued_events: 0,
    })
}

// ── 加密 / 安全 ─────────────────────────────────────────────────────────

// ── 取消令牌 ───────────────────────────────────────────────────────────────

/// 创建一个 CancellationToken 并返回其 UUID id。
/// 该令牌可传给 hash_file_stream 或 upload_file 用于取消。
#[napi]
pub fn create_cancel_token() -> String {
    facade::create_cancel_token()
}

/// 按 id 取消一个 CancellationToken。
#[napi]
pub fn cancel_token_cancel(id: String) -> Result<()> {
    facade::cancel_token_cancel(&id)
        .map_err(|e| Error::from_reason(format!("Cancel token failed: {e:#}")))
}

// ── NAPI 类对象 ────────────────────────────────────────────────────────

/// RsCancellationToken——面向对象的取消令牌。
///
/// 取代旧的基于 id 的取消令牌体系。每个令牌是独立的
/// 可在多个操作间共享的对象。调用 `cancel()`
/// 触发所有使用该令牌的操作的取消。
#[napi]
pub struct RsCancellationToken {
    inner: tokio_util::sync::CancellationToken,
}

// SAFETY: CancellationToken 是 Send + Sync，因此 RsCancellationToken 也是。
unsafe impl Send for RsCancellationToken {}
unsafe impl Sync for RsCancellationToken {}

#[napi]
impl RsCancellationToken {
    /// 取消令牌。所有使用该令牌的操作都将被中断。
    #[napi]
    pub fn cancel(&self) -> Result<()> {
        self.inner.cancel();
        Ok(())
    }

    /// 检查令牌是否已被取消。
    #[napi]
    pub fn is_cancelled(&self) -> bool {
        self.inner.is_cancelled()
    }
}

/// 创建一个新的 RsCancellationToken 实例。
#[napi]
pub fn create_cancellation_token() -> Result<RsCancellationToken> {
    Ok(RsCancellationToken {
        inner: tokio_util::sync::CancellationToken::new(),
    })
}

// ── RsHttpServer ──────────────────────────────────────────────────────────────

/// RsHttpServer——面向对象的 HTTP 服务器。
///
/// 每个实例持有自己的服务器句柄、事件通道和状态，
/// 独立于全局 BridgeState 单例。事件仍然
/// 通过全局 `registerEventListener` 回调推送。
pub struct RsHttpServerInner {
    pub handle: Option<localsend::http::server::ServerHandle>,
    pub stop_tx: Option<tokio::sync::oneshot::Sender<()>>,
    pub event_tx: Option<tokio::sync::mpsc::Sender<localsend::http::server::v2::ServerEventV2>>,
    pub callback: Option<crate::bridge::callback::EventCallback>,
    pub pending_decisions: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<String, tokio::sync::oneshot::Sender<localsend::http::server::v2::PrepareUploadDecisionV2>>>>,
    pub web_send_files: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<String, String>>>,
    pub receive_pin: Option<String>,
    pub show_token: Option<String>,
    pub save_dir: String,
    pub recv_progress: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<String, crate::bridge::state::ProgressEntry>>>,
    pub pending_requests: std::sync::Arc<std::sync::Mutex<Vec<crate::bridge::state::PendingRequest>>>,
    pub debug_log: std::sync::Arc<std::sync::Mutex<Vec<String>>>,
    pub recv_diag_drain_count: std::sync::Arc<std::sync::Mutex<u64>>,
    pub web_send_event_tx: Option<tokio::sync::mpsc::Sender<localsend::http::server::web::WebSendEvent>>,
    pub web_download_decisions: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<String, tokio::sync::oneshot::Sender<bool>>>>,
    pub pending_file_uploads: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<(String, String), tokio::sync::oneshot::Sender<localsend::http::server::common::save::FileUploadTarget>>>>,
    pub pending_file_downloads: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<(String, String), tokio::sync::oneshot::Sender<localsend::model::transfer::FileContent>>>>,
    pub send_progress: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<String, crate::bridge::state::ProgressEntry>>>,
    pub current_send_session_id: std::sync::Arc<std::sync::Mutex<String>>,
    pub active_transfers: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<String, tokio_util::sync::CancellationToken>>>,
    /// TLS 证书 PEM——cancelSession 创建临时 LsHttpClient 所需
    pub cert_pem: String,
    /// TLS 私钥 PEM——cancelSession 创建临时 LsHttpClient 所需
    pub key_pem: String,
    /// 设备别名——cancelSession 注册信息所需
    pub alias: String,
    /// 会话对端信息：session_id → (ip, port, protocol)，用于取消通知
    pub session_peers: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<String, (String, u16, localsend::model::discovery::ProtocolType)>>>,
}

#[napi]
pub struct RsHttpServer {
    inner: std::sync::Mutex<RsHttpServerInner>,
}

unsafe impl Send for RsHttpServer {}

#[napi]
impl RsHttpServer {
    /// 通过接受指定文件 ID 响应 prepare-upload 请求。
    /// 传入空列表或 None 以拒绝整个请求。
    #[napi]
    pub fn respond_prepare_upload(&self, accepted_file_ids: Option<Vec<String>>) -> Result<()> {
        let mut inner = self.inner.lock().unwrap();
        let mut pd = inner.pending_decisions.lock().unwrap();
        // 查找并移除第一个待处理决策
        let session_id = pd.keys().next().cloned();
        match session_id {
            Some(sid) => {
                if let Some(sender) = pd.remove(&sid) {
                    match accepted_file_ids {
                        Some(ids) if !ids.is_empty() => {
                            let file_set: std::collections::HashSet<String> = ids.iter().cloned().collect();
                            let decision = localsend::http::server::v2::PrepareUploadDecisionV2::Accept(file_set);
                            let _ = sender.send(decision);
                            // 同时从待处理请求中移除
                            let mut reqs = inner.pending_requests.lock().unwrap();
                            reqs.retain(|r| r.session_id != sid);
                        }
                        _ => {
                            let decision = localsend::http::server::v2::PrepareUploadDecisionV2::Decline;
                            let _ = sender.send(decision);
                            let mut reqs = inner.pending_requests.lock().unwrap();
                            reqs.retain(|r| r.session_id != sid);
                        }
                    }
                    Ok(())
                } else {
                    Err(Error::from_reason("No pending decision found".to_string()))
                }
            }
            None => Err(Error::from_reason("No pending prepare-upload request".to_string())),
        }
    }

    /// 通过接受指定文件 ID 响应指定会话的 prepare-upload 请求。
    #[napi]
    pub fn respond_prepare_upload_session(&self, session_id: String, accepted_file_ids: Option<Vec<String>>) -> Result<()> {
        let mut inner = self.inner.lock().unwrap();
        let mut pd = inner.pending_decisions.lock().unwrap();
        if let Some(sender) = pd.remove(&session_id) {
            match accepted_file_ids {
                Some(ids) if !ids.is_empty() => {
                    let file_set: std::collections::HashSet<String> = ids.iter().cloned().collect();
                    let decision = localsend::http::server::v2::PrepareUploadDecisionV2::Accept(file_set);
                    let _ = sender.send(decision);
                    let mut reqs = inner.pending_requests.lock().unwrap();
                    reqs.retain(|r| r.session_id != session_id);
                }
                _ => {
                    let decision = localsend::http::server::v2::PrepareUploadDecisionV2::Decline;
                    let _ = sender.send(decision);
                    let mut reqs = inner.pending_requests.lock().unwrap();
                    reqs.retain(|r| r.session_id != session_id);
                }
            }
            Ok(())
        } else {
            Err(Error::from_reason(format!("No pending decision for session: {session_id}")))
        }
    }

    /// 通过提供保存路径响应文件上传请求。
    /// 在自动保存模式（默认）下，事件循环已发送 FileUploadTarget::Path
    /// 发送到 target_tx，因此本方法适用于调用方手动/高级路径
    /// 想要覆盖保存位置。
    #[napi]
    pub fn respond_file_upload(&self, session_id: String, file_id: String, file_path: String, file_size: i64) -> Result<()> {
        let inner = self.inner.lock().unwrap();
        let key = (session_id.clone(), file_id.clone());
        let pfu = inner.pending_file_uploads.clone();
        let rp = inner.recv_progress.clone();
        let cb = inner.callback.clone();
        drop(inner);

        let target_tx_opt = pfu.lock().unwrap().remove(&key);
        if let Some(target_tx) = target_tx_opt {
            let (result_tx, _result_rx) = tokio::sync::oneshot::channel();
            let (progress_tx, mut progress_rx) = tokio::sync::mpsc::channel::<u64>(16);
            let total = file_size as u64;

            // 派生一个进度跟踪任务
            let sid = session_id.clone();
            let fid = file_id.clone();
            let fp = file_path.clone();
            tokio::spawn(async move {
                while let Some(bytes_written) = progress_rx.recv().await {
                    let mut map = rp.lock().unwrap();
                    let key = format!("{}:{}", sid, fid);
                    map.insert(key, crate::bridge::state::ProgressEntry {
                        session_id: sid.clone(),
                        file_id: fid.clone(),
                        bytes_sent: bytes_written,
                        total_bytes: total,
                        file_path: fp.clone(),
                    });
                    drop(map);
                    if let Some(ref cb) = cb {
                        let payload = serde_json::json!({
                            "type": "progress_update",
                            "direction": "recv",
                            "sessionId": sid,
                            "fileId": fid,
                            "bytesSent": bytes_written,
                            "totalBytes": total,
                            "filePath": fp,
                        });
                        cb.call(payload.to_string());
                    }
                }
            });

            let target = localsend::http::server::common::save::FileUploadTarget::Path {
                path: std::path::PathBuf::from(&file_path),
                result_tx,
                progress_tx: Some(progress_tx),
            };
            let _ = target_tx.send(target);
            Ok(())
        } else {
            // 自动保存模式下，target_tx 已被事件循环消费。
            // 这不是错误——文件正在被自动保存。
            Ok(())
        }
    }

    /// 响应 Web prepare-download 请求（接受或拒绝）。
    #[napi]
    pub fn respond_prepare_download(&self, session_id: String, accept: bool) -> Result<()> {
        let inner = self.inner.lock().unwrap();
        let mut wdd = inner.web_download_decisions.lock().unwrap();
        if let Some(sender) = wdd.remove(&session_id) {
            let _ = sender.send(accept);
            Ok(())
        } else {
            Err(Error::from_reason(format!("No pending web download decision for session: {session_id}")))
        }
    }

    /// 通过提供文件内容路径响应 Web 文件下载请求。
    #[napi]
    pub fn respond_file_download(&self, session_id: String, file_id: String, file_path: String) -> Result<()> {
        let inner = self.inner.lock().unwrap();
        let mut pfd = inner.pending_file_downloads.lock().unwrap();
        if let Some(content_tx) = pfd.remove(&(session_id.clone(), file_id.clone())) {
            let _ = content_tx.send(localsend::model::transfer::FileContent::Path(std::path::PathBuf::from(file_path)));
            Ok(())
        } else {
            Err(Error::from_reason(format!("No pending file download for session={session_id}, file={file_id}")))
        }
    }

    /// 将待处理的文件下载标记为失败（导致 500 响应）。
    #[napi]
    pub fn fail_file_download(&self, session_id: String, file_id: String) -> Result<()> {
        let inner = self.inner.lock().unwrap();
        // 尝试丢弃待处理的 FileDownload content_tx
        let mut pfd = inner.pending_file_downloads.lock().unwrap();
        if pfd.remove(&(session_id.to_string(), file_id.to_string())).is_some() {
            return Ok(());
        }
        drop(pfd);
        // 尝试拒绝待处理的 PrepareDownload 决策
        let mut wdd = inner.web_download_decisions.lock().unwrap();
        if wdd.remove(&session_id).is_some() {
            return Ok(());
        }
        Err(Error::from_reason(format!("No pending file download for session={session_id}, file={file_id}")))
    }

    /// 将待处理的文件上传标记为失败（导致 500 响应）。
    #[napi]
    pub fn fail_file_upload(&self, session_id: String, file_id: String) -> Result<()> {
        let inner = self.inner.lock().unwrap();
        let pfu = inner.pending_file_uploads.clone();
        let at = inner.active_transfers.clone();
        drop(inner);

        let removed = pfu.lock().unwrap().remove(&(session_id.to_string(), file_id.to_string()));
        if removed.is_some() {
            // 成功移除待处理上传——丢弃 oneshot 发送端
            // 导致服务器向上传方返回 500。
            return Ok(());
        }
        // 未找到 pending_file_uploads 条目，但仍取消进行中的传输
        let cancel_token = at.lock().unwrap().get(&session_id).cloned();
        if let Some(cancel) = cancel_token {
            cancel.cancel();
        }
        Err(Error::from_reason(format!("No pending file upload for session={session_id}, file={file_id}")))
    }

    /// 按会话 ID 取消会话。同时通过 HTTP cancel 通知远端。
    #[napi]
    pub fn cancel_session(&self, session_id: String) -> Result<()> {
        let inner = self.inner.lock().unwrap();
        if let Some(cancel) = inner.active_transfers.lock().unwrap().remove(&session_id) {
            cancel.cancel();
        }
        // 若存在则移除待处理决策
        {
            let mut pd = inner.pending_decisions.lock().unwrap();
            pd.remove(&session_id);
        }
        // 清理进度
        {
            let mut map = inner.send_progress.lock().unwrap();
            let keys_to_remove: Vec<String> = map
                .keys()
                .filter(|k| k.starts_with(&format!("{}:", session_id)))
                .cloned()
                .collect();
            for k in keys_to_remove {
                map.remove(&k);
            }
        }
        {
            let mut map = inner.recv_progress.lock().unwrap();
            let keys_to_remove: Vec<String> = map
                .keys()
                .filter(|k| k.starts_with(&format!("{}:", session_id)))
                .cloned()
                .collect();
            for k in keys_to_remove {
                map.remove(&k);
            }
        }
        {
            let mut reqs = inner.pending_requests.lock().unwrap();
            reqs.retain(|r| r.session_id != session_id);
        }

        // 提取对端信息用于取消通知
        let peer_info = inner.session_peers.lock().unwrap().remove(&session_id);
        let cert_pem = inner.cert_pem.clone();
        let key_pem = inner.key_pem.clone();
        drop(inner); // 发起异步调用前释放锁

        // 向远端发送取消请求（尽力而为）
        if let Some((peer_ip, peer_port, peer_protocol)) = peer_info {
            let sid = session_id.clone();
            std::thread::spawn(move || {
                let rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build();
                if let Ok(rt) = rt {
                    let _ = rt.block_on(async {
                        let client = match localsend::http::client::LsHttpClient::new(
                            &key_pem,
                            &cert_pem,
                            localsend::http::client::LsHttpClientVersion::V2,
                            None,
                            Some(std::time::Duration::from_secs(5)),
                        ) {
                            Ok(c) => c,
                            Err(_) => return,
                        };
                        let _ = client.cancel(peer_protocol, &peer_ip, peer_port, &sid).await;
                    });
                }
            });
        }

        Ok(())
    }

    /// 停止 HTTP 服务器并释放端口。
    #[napi]
    pub fn stop(&self) -> Result<()> {
        let mut inner = self.inner.lock().unwrap();
        // 发送停止信号
        if let Some(stop_tx) = inner.stop_tx.take() {
            let _ = stop_tx.send(());
        }
        inner.handle.take();
        inner.event_tx.take();
        inner.show_token.take();
        // 取消并清空进行中的传输
        for (_key, cancel) in inner.active_transfers.lock().unwrap().drain() {
            cancel.cancel();
        }
        inner.pending_requests.lock().unwrap().clear();
        inner.pending_decisions.lock().unwrap().clear();
        inner.recv_progress.lock().unwrap().clear();
        inner.send_progress.lock().unwrap().clear();
        inner.web_send_event_tx.take();
        inner.web_send_files.lock().unwrap().clear();
        inner.web_download_decisions.lock().unwrap().clear();
        inner.pending_file_uploads.lock().unwrap().clear();
        inner.pending_file_downloads.lock().unwrap().clear();
        Ok(())
    }
}

/// 工厂函数：创建一个 RsHttpServer 实例。
///
/// 这是 `start_server` 自由函数的面向对象替代。
/// 服务器实例持有自己的状态，独立于全局 BridgeState。
#[napi]
pub async fn start_server_instance(
    port: u16,
    use_https: bool,
    verify_checksums: bool,
    pin: Option<String>,
    alias: String,
    version: Option<String>,
    device_model: Option<String>,
    device_type: Option<String>,
    fingerprint: String,
    show_token: Option<String>,
    save_dir: Option<String>,
    web_send_files: Option<String>,
    web_pin: Option<String>,
) -> Result<RsHttpServer> {
    use crate::bridge::facade::parse_device_type;
    use localsend::http::server::v2::ServerEventV2;
    use localsend::http::server::{self, ServerConfigV2, TlsConfig};
    use localsend::http::server::internal::{InternalConfig, InternalEvent};
    use localsend::http::state::ClientInfo;
    use localsend::model::discovery::PROTOCOL_VERSION_V2;

    let dt = parse_device_type(device_type.as_deref().unwrap_or("mobile"));
    let dm = device_model.unwrap_or_else(|| "HarmonyOS".to_string());
    let ver = version.unwrap_or_else(|| PROTOCOL_VERSION_V2.to_string());

    // 初始化身份（若尚未完成）。
    // 使用 save_dir 进行证书持久化，使设备指纹
    // 在应用重启间保持稳定（与 createServer 的做法相同）。
    {
        let state = bridge::state::bridge().lock().unwrap();
        if state.runtime.is_none() {
            let save_dir = state.save_dir.clone();
            drop(state);
            crate::bridge::facade::init_with_persisted_identity(alias.clone(), dt.clone(), &save_dir)?;
        }
    }

    // 从全局状态获取 TLS 配置（共享身份）
    let (cert_pem, key_pem, actual_fingerprint) = {
        let state = bridge::state::bridge().lock().unwrap();
        // 如果指纹参数为空，则使用状态中的指纹
        let fp = if fingerprint.is_empty() {
            state.fingerprint.clone()
        } else {
            fingerprint
        };
        (state.cert_pem.clone(), state.key_pem.clone(), fp)
    };

    // 从全局状态获取回调
    let callback = {
        let state = bridge::state::bridge().lock().unwrap();
        state.callback.clone()
    };

    let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<ServerEventV2>(64);
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();

    // 使用提供的 show_token，否则生成一个
    let actual_show_token = show_token.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());

    let cfg = ServerConfigV2 {
        pin: pin.clone(),
        verify_checksums,
        event_tx: event_tx.clone(),
    };

    let (internal_event_tx, mut internal_event_rx) = tokio::sync::mpsc::channel::<InternalEvent>(16);
    let internal_config = InternalConfig {
        show_token: actual_show_token.clone(),
        event_tx: internal_event_tx,
    };

    let tls = if use_https {
        Some(TlsConfig {
            cert: cert_pem.clone(),
            private_key: key_pem.clone(),
        })
    } else {
        None
    };

    let info = ClientInfo {
        alias: alias.clone(),
        version: ver,
        device_model: Some(dm.clone()),
        device_type: Some(dt),
        token: actual_fingerprint.clone(),
    };

    // 如果提供了 web_send_files，则构建 WebConfig
    let (web_send_event_tx_opt, web_send_event_rx_opt, web_file_map) = match web_send_files {
        Some(ref files_json) if !files_json.is_empty() => {
            // 解析 fileId → filePath 的 JSON 映射
            let file_path_map: std::collections::HashMap<String, String> = serde_json::from_str(files_json)
                .map_err(|e| Error::from_reason(format!("Invalid web_send_files JSON: {e:#}")))?;

            // 根据文件路径构建 FileDto 映射（读取元数据获取大小）
            let mut file_dto_map: std::collections::HashMap<String, localsend::model::transfer::FileDto> = std::collections::HashMap::new();
            for (file_id, file_path) in &file_path_map {
                let file_name = std::path::Path::new(file_path)
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_else(|| file_id.clone());
                let size = std::fs::metadata(file_path).map(|m| m.len()).unwrap_or(0);
                file_dto_map.insert(file_id.clone(), localsend::model::transfer::FileDto {
                    id: file_id.clone(),
                    file_name,
                    size,
                    file_type: String::new(),
                    sha256: None,
                    preview: None,
                    metadata: None,
                });
            }

            // 创建 WebSendEvent 通道
            let (web_event_tx, web_event_rx) = tokio::sync::mpsc::channel::<localsend::http::server::web::WebSendEvent>(16);

            let i18n = crate::bridge::facade::build_web_i18n();
            (Some(web_event_tx), Some(web_event_rx), Some((file_path_map, file_dto_map, i18n)))
        }
        _ => (None, None, None),
    };

    // 在消费 web_file_map 构建 web_config 之前，先为 WebSendEvent 监听器提取 path_map
    let web_send_files_map = match web_file_map {
        Some((ref path_map, _, _)) => std::sync::Arc::new(std::sync::Mutex::new(path_map.clone())),
        None => std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashMap::new())),
    };

    let web_config = match web_file_map {
        Some((_, file_dto_map, i18n)) => {
            Some(localsend::http::server::web::WebConfig {
                send: Some(localsend::http::server::web::WebSendConfig {
                    files: file_dto_map,
                    pin: web_pin.clone(),
                    event_tx: web_send_event_tx_opt.unwrap(),
                }),
                upload: false,
                i18n,
            })
        }
        None => None,
    };

    let handle = server::start_with_port(
        port,
        tls,
        info,
        Some(internal_config),
        Some(cfg),
        web_config,
        stop_rx,
    )
    .await
    .map_err(|e| Error::from_reason(format!("Start server instance failed: {e:#}")))?;

    let local_port = handle.local_addresses().first().map(|a| a.port()).unwrap_or(port);

    // 克隆内部事件监听器的回调
    let internal_callback = callback.clone();

    // 创建进度/请求跟踪结构
    let recv_progress = std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashMap::new()));
    let pending_requests = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let debug_log = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let recv_diag_drain_count = std::sync::Arc::new(std::sync::Mutex::new(0u64));
    let send_progress = std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashMap::new()));
    let current_send_session_id = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
    let save_dir = {
        let mut dir = save_dir.unwrap_or_else(|| String::from("/data/local/tmp/localsend/"));
        if !dir.ends_with('/') {
            dir.push('/');
        }
        dir
    };
    let save_dir_clone = save_dir.clone();

    let rp_clone = recv_progress.clone();
    let pr_clone = pending_requests.clone();
    let dl_clone = debug_log.clone();
    let rdc_clone = recv_diag_drain_count.clone();

    // 创建共享的 pending_decisions 映射用于跨任务通信
    let pending_decisions_shared: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<String, tokio::sync::oneshot::Sender<localsend::http::server::v2::PrepareUploadDecisionV2>>>> = std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashMap::new()));
    let pd_clone = pending_decisions_shared.clone();

    // 创建共享的 session_peers 映射用于取消通知
    let session_peers_shared: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<String, (String, u16, localsend::model::discovery::ProtocolType)>>> = std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashMap::new()));
    let sp_clone = session_peers_shared.clone();

    // 派生主事件监听器
    let cb_for_events = callback.clone();
    tokio::spawn(async move {
        while let Some(event) = event_rx.recv().await {
            let json = crate::bridge::facade::server_event_to_json(&event);

            // 处理自有事件
            match event {
                ServerEventV2::PrepareUpload {
                    session_id,
                    decision_tx,
                    files,
                    info,
                    ip,
                    cert_fingerprint,
                    ..
                } => {
                    // 构建待处理请求
                    let mut reqs = pr_clone.lock().unwrap();
                    reqs.push(crate::bridge::state::PendingRequest {
                        session_id: session_id.clone(),
                        sender_alias: info.alias.clone(),
                        sender_fingerprint: cert_fingerprint.clone().unwrap_or_default(),
                        sender_protocol: if cert_fingerprint.is_some() { "https" } else { "http" }.to_string(),
                        files: files.iter().map(|(id, f)| crate::bridge::state::PendingFile {
                            file_id: id.clone(),
                            file_name: f.file_name.clone(),
                            size: f.size,
                            file_type: f.file_type.clone(),
                            preview: f.preview.clone(),
                            sha256: f.sha256.clone(),
                        }).collect(),
                    });
                    drop(reqs);
                    // 将 decision_tx 存入共享的 pending_decisions 映射，以便
                    // respondPrepareUpload / respondPrepareUploadSession 可在之后接受/拒绝。
                    // 这与自由函数 start_server（server_facade::store_pending_decision）的模式相同。
                    pd_clone.lock().unwrap().insert(session_id.clone(), decision_tx);
                    // 存储对端信息用于取消通知
                    let peer_protocol = if cert_fingerprint.is_some() {
                        localsend::model::discovery::ProtocolType::Https
                    } else {
                        localsend::model::discovery::ProtocolType::Http
                    };
                    let peer_port = info.port;
                    sp_clone.lock().unwrap().insert(session_id.clone(), (ip.to_string(), peer_port, peer_protocol));
                }
                ServerEventV2::FileUpload {
                    session_id,
                    file_id,
                    file,
                    target_tx,
                } => {
                    // 自动接收：发送文件目标
                    let sp = rp_clone.clone();
                    let sd = save_dir_clone.clone();
                    let save_path = format!("{}{}", sd, file.file_name);
                    let total = file.size;

                    let (progress_tx, mut progress_rx) = tokio::sync::mpsc::channel::<u64>(16);
                    let fp2 = sp.clone();
                    let sid = session_id.clone();
                    let fid = file_id.clone();
                    let fp_path = save_path.clone();
                    let cb_prog = cb_for_events.clone();

                    tokio::spawn(async move {
                        while let Some(bytes_written) = progress_rx.recv().await {
                            let mut map = fp2.lock().unwrap();
                            let key = format!("{}:{}", sid, fid);
                            map.insert(key, crate::bridge::state::ProgressEntry {
                                session_id: sid.clone(),
                                file_id: fid.clone(),
                                bytes_sent: bytes_written,
                                total_bytes: total,
                                file_path: fp_path.clone(),
                            });
                        }
                    });

                    let (result_tx, result_rx) = tokio::sync::oneshot::channel();
                    let target = localsend::http::server::common::save::FileUploadTarget::Path {
                        path: std::path::PathBuf::from(&save_path),
                        result_tx,
                        progress_tx: Some(progress_tx),
                    };
                    let _ = target_tx.send(target);

                    let rp2 = sp.clone();
                    let sid2 = session_id.clone();
                    let fid2 = file_id.clone();
                    let fp2 = save_path.clone();
                    let cb_res = cb_for_events.clone();
                    tokio::spawn(async move {
                        let _ = result_rx.await;
                        let mut map = rp2.lock().unwrap();
                        let key = format!("{}:{}", sid2, fid2);
                        map.insert(key, crate::bridge::state::ProgressEntry {
                            session_id: sid2.clone(),
                            file_id: fid2.clone(),
                            bytes_sent: total,
                            total_bytes: total,
                            file_path: fp2.clone(),
                        });
                    });

                    *rdc_clone.lock().unwrap() += 1;
                }
                _ => {}
            }

            if let Some(ref cb) = cb_for_events {
                cb.call(json);
            }
        }
    });

    // 派生 InternalEvent 监听器
    tokio::spawn(async move {
        while let Some(event) = internal_event_rx.recv().await {
            match event {
                InternalEvent::Show { args } => {
                    if let Some(ref cb) = internal_callback {
                        let payload = serde_json::json!({
                            "type": "show",
                            "args": args,
                        });
                        cb.call(payload.to_string());
                    }
                }
            }
        }
    });

    // 若 Web 发送已启用，派生 WebSendEvent 监听器
    let web_send_files_for_inner = web_send_files_map.clone();
    let web_download_decisions: std::collections::HashMap<String, tokio::sync::oneshot::Sender<bool>> = std::collections::HashMap::new();
    let web_download_decisions_shared = std::sync::Arc::new(std::sync::Mutex::new(web_download_decisions));
    let web_download_decisions_for_inner = web_download_decisions_shared.clone();
    let pending_file_downloads: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<(String, String), tokio::sync::oneshot::Sender<localsend::model::transfer::FileContent>>>> = std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashMap::new()));
    let pending_file_downloads_for_inner = pending_file_downloads.clone();

    if let Some(mut web_event_rx) = web_send_event_rx_opt {
        let cb_web = callback.clone();
        let wsf = web_send_files_map.clone();
        let wdd = web_download_decisions_shared.clone();
        let pfd = pending_file_downloads.clone();
        tokio::spawn(async move {
            while let Some(event) = web_event_rx.recv().await {
                match event {
                    localsend::http::server::web::WebSendEvent::PrepareDownload {
                        ip,
                        session_id,
                        user_agent,
                        decision_tx,
                    } => {
                        if let Some(ref cb) = cb_web {
                            let payload = serde_json::json!({
                                "type": "web_prepare_download",
                                "sessionId": session_id,
                                "ip": ip.to_string(),
                                "userAgent": user_agent,
                            });
                            cb.call(payload.to_string());
                        }
                        wdd.lock().unwrap().insert(session_id, decision_tx);
                    }
                    localsend::http::server::web::WebSendEvent::FileDownload {
                        session_id,
                        file_id,
                        file,
                        content_tx,
                    } => {
                        if let Some(ref cb) = cb_web {
                            let payload = serde_json::json!({
                                "type": "web_file_download",
                                "sessionId": session_id,
                                "fileId": file_id,
                                "fileName": file.file_name,
                                "size": file.size,
                                "fileType": file.file_type,
                            });
                            cb.call(payload.to_string());
                        }
                        // 将 content_tx 存入 pending_file_downloads
                        pfd.lock().unwrap().insert((session_id.clone(), file_id.clone()), content_tx);
                        // 自动接收：查找文件路径并提供 FileContent::Path
                        let file_path = wsf.lock().unwrap().get(&file_id).cloned();
                        let content_tx_opt = pfd.lock().unwrap().remove(&(session_id.clone(), file_id.clone()));
                        if let Some(tx) = content_tx_opt {
                            if let Some(path) = file_path {
                                let _ = tx.send(localsend::model::transfer::FileContent::Path(std::path::PathBuf::from(path)));
                            } else {
                                drop(tx);
                            }
                        }
                    }
                }
            }
        });
    }

    Ok(RsHttpServer {
        inner: std::sync::Mutex::new(RsHttpServerInner {
            handle: Some(handle),
            stop_tx: Some(stop_tx),
            event_tx: Some(event_tx),
            callback,
            pending_decisions: pending_decisions_shared,
            web_send_files: web_send_files_for_inner,
            receive_pin: pin,
            show_token: Some(actual_show_token),
            save_dir,
            recv_progress,
            pending_requests,
            debug_log,
            recv_diag_drain_count,
            web_send_event_tx: None, // event_tx 已移入 WebConfig
            web_download_decisions: web_download_decisions_for_inner,
            pending_file_uploads: std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashMap::new())),
            pending_file_downloads: pending_file_downloads_for_inner,
            send_progress,
            current_send_session_id,
            active_transfers: std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashMap::new())),
            cert_pem: cert_pem.clone(),
            key_pem: key_pem.clone(),
            alias: alias.clone(),
            session_peers: session_peers_shared,
        }),
    })
}

// ── RsDiscovery ───────────────────────────────────────────────────────────────

/// RsDiscovery——面向对象的设备发现。
///
/// 每个实例持有自己的发现句柄、停止通道和事件任务，
/// 独立于全局 BridgeState 单例。
pub struct RsDiscoveryInner {
    pub handle: Option<std::sync::Arc<localsend::discovery::DiscoveryHandle>>,
    pub stop_tx: Option<tokio::sync::oneshot::Sender<()>>,
    pub event_task: Option<tokio::task::JoinHandle<()>>,
    pub callback: Option<crate::bridge::callback::EventCallback>,
    pub cert_pem: String,
    pub key_pem: String,
    pub fingerprint: String,
}

#[napi]
pub struct RsDiscovery {
    inner: std::sync::Mutex<RsDiscoveryInner>,
}

unsafe impl Send for RsDiscovery {}

#[napi]
impl RsDiscovery {
    /// 向网络发送一组广播报文。
    #[napi]
    pub async fn announce(&self) -> Result<()> {
        let handle = {
            let inner = self.inner.lock().unwrap();
            inner.handle.as_ref()
                .ok_or_else(|| Error::from_reason("Discovery not running".to_string()))?
                .clone()
        };
        handle.announce().await;
        Ok(())
    }

    /// 分阶段发现设备：广播 → 探测已知通道 → 等待宽限期 → 回退子网扫描。
    #[napi]
    pub async fn discover_staged(
        &self,
        channels: String,
        interface_ips: String,
        port: u16,
        protocol: String,
        grace_ms: u32,
    ) -> Result<()> {
        let handle = {
            let inner = self.inner.lock().unwrap();
            inner.handle.as_ref()
                .ok_or_else(|| Error::from_reason("Discovery not running".to_string()))?
                .clone()
        };

        crate::bridge::discovery_facade::discovery_discover_staged_with_handle(
            &handle, &channels, &interface_ips, port, &protocol, grace_ms,
        )
            .await
            .map_err(|e| Error::from_reason(format!("discover_staged failed: {e:#}")))?;
        Ok(())
    }

    /// 扫描指定网卡的 /24 子网。
    #[napi]
    pub async fn scan_subnet(&self, interface_ip: String, port: u16, protocol: String) -> Result<()> {
        let handle = {
            let inner = self.inner.lock().unwrap();
            inner.handle.as_ref()
                .ok_or_else(|| Error::from_reason("Discovery not running".to_string()))?
                .clone()
        };

        crate::bridge::discovery_facade::discovery_scan_subnet_with_handle(
            &handle, &interface_ip, port, &protocol,
        )
            .await
            .map_err(|e| Error::from_reason(format!("scan_subnet failed: {e:#}")))?;
        Ok(())
    }

    /// 将发现流程之外确认的设备加入存储。
    #[napi]
    pub async fn add_device(&self, device_json: String) -> Result<()> {
        let handle = {
            let inner = self.inner.lock().unwrap();
            inner.handle.as_ref()
                .ok_or_else(|| Error::from_reason("Discovery not running".to_string()))?
                .clone()
        };

        crate::bridge::discovery_facade::discovery_add_device_with_handle(&handle, &device_json)
            .await
            .map_err(|e| Error::from_reason(format!("add_device failed: {e:#}")))?;
        Ok(())
    }

    /// 设置是否应答其他设备的广播。
    #[napi]
    pub fn set_answer_announcements(&self, answer: bool) -> Result<()> {
        let inner = self.inner.lock().unwrap();
        match inner.handle.as_ref() {
            Some(h) => {
                h.set_answer_announcements(answer);
                Ok(())
            }
            None => Err(Error::from_reason("Discovery not running".to_string())),
        }
    }

    /// 按指纹获取设备确认日志。
    /// 返回日志条目的 JSON 数组。
    #[napi]
    pub fn device_logs(&self, fingerprint: String) -> String {
        let inner = self.inner.lock().unwrap();
        match inner.handle.as_ref() {
            Some(h) => crate::bridge::discovery_facade::device_logs_with_handle(h, &fingerprint),
            None => "[]".to_string(),
        }
    }

    /// 获取组播错误（若有）。
    #[napi]
    pub fn multicast_error(&self) -> String {
        let inner = self.inner.lock().unwrap();
        match inner.handle.as_ref() {
            Some(h) => match h.multicast_error() {
                Some(e) => format!("{e:#}"),
                None => String::new(),
            },
            None => String::new(),
        }
    }

    /// 停止发现并释放所有套接字。
    #[napi]
    pub fn stop(&self) -> Result<()> {
        let mut inner = self.inner.lock().unwrap();
        if let Some(event_task) = inner.event_task.take() {
            event_task.abort();
        }
        if let Some(stop_tx) = inner.stop_tx.take() {
            let _ = stop_tx.send(());
        }
        inner.handle.take();
        Ok(())
    }
}

/// 工厂函数：创建一个 RsDiscovery 实例。
#[napi]
pub async fn start_discovery_instance(config_json: String) -> Result<RsDiscovery> {
    let config: serde_json::Value = serde_json::from_str(&config_json)
        .map_err(|e| Error::from_reason(format!("Invalid config JSON: {e:#}")))?;

    let (alias, device_type, device_model, fingerprint, cert_pem, key_pem) = {
        let state = bridge::state::bridge().lock().unwrap();
        (
            state.local_alias.clone(),
            state.device_type.clone(),
            state.device_model.clone(),
            state.fingerprint.clone(),
            state.cert_pem.clone(),
            state.key_pem.clone(),
        )
    };

    let port = config["port"].as_u64().unwrap_or(53317) as u16;
    let protocol_str = config["protocol"].as_str().unwrap_or("https");
    let protocol = match protocol_str.to_lowercase().as_str() {
        "http" => localsend::model::discovery::ProtocolType::Http,
        _ => localsend::model::discovery::ProtocolType::Https,
    };
    let multicast_group = config["multicastGroup"].as_str().unwrap_or("224.0.0.167");
    let download = config["download"].as_bool().unwrap_or(true);

    let whitelist = config["networkWhitelist"]
        .as_array()
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect::<Vec<String>>());
    let blacklist = config["networkBlacklist"]
        .as_array()
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect::<Vec<String>>());
    let timeout_ms = config["discoveryTimeoutMs"].as_u64().unwrap_or(3000);

    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    let (event_tx, event_rx) = tokio::sync::mpsc::channel::<localsend::discovery::DiscoveryEvent>(16);

    let device = localsend::multicast::MulticastDevice {
        alias,
        version: localsend::model::discovery::PROTOCOL_VERSION_V2.to_string(),
        device_model: Some(device_model),
        device_type: Some(device_type),
        fingerprint: fingerprint.clone(),
        port,
        protocol,
        download,
    };

    let identity = localsend::discovery::DeviceIdentity {
        cert_pem: cert_pem.clone(),
        private_key_pem: key_pem.clone(),
    };

    let group = multicast_group
        .parse()
        .map_err(|_| Error::from_reason(format!("Invalid multicast group: {multicast_group}")))?;

    let disc_config = localsend::discovery::DiscoveryConfig {
        group,
        group_v6: None,
        port: localsend::multicast::DEFAULT_PORT,
        interface_filter: localsend::util::interface::InterfaceFilter {
            whitelist,
            blacklist,
        },
        device,
        identity,
        timeout: std::time::Duration::from_millis(timeout_ms),
        event_tx: Some(event_tx),
    };

    let handle = std::sync::Arc::new(localsend::discovery::start(disc_config, stop_rx).await);

    let callback = {
        let state = bridge::state::bridge().lock().unwrap();
        state.callback.clone()
    };

    let event_task = crate::bridge::discovery_facade::start_event_listener_with_callback(
        event_rx, callback.clone(), handle.clone(),
    );

    Ok(RsDiscovery {
        inner: std::sync::Mutex::new(RsDiscoveryInner {
            handle: Some(handle),
            stop_tx: Some(stop_tx),
            event_task: Some(event_task),
            callback,
            cert_pem,
            key_pem,
            fingerprint,
        }),
    })
}

// ── RsHttpClient ──────────────────────────────────────────────────────────────

/// RsHttpClient——面向对象的 HTTP 客户端。
///
/// 每个实例持有自己的 LsHttpClient 和 TLS 配置，
/// 允许多个请求间复用并独立配置。
pub struct RsHttpClientInner {
    pub key_pem: String,
    pub cert_pem: String,
    pub fingerprint: String,
    pub device_type: localsend::model::discovery::DeviceType,
    pub device_model: String,
    pub alias: String,
    pub expected_fingerprint: Option<String>,
    pub timeout_ms: Option<u64>,
    pub send_progress: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<String, crate::bridge::state::ProgressEntry>>>,
    pub current_send_session_id: std::sync::Arc<std::sync::Mutex<String>>,
    pub callback: Option<crate::bridge::callback::EventCallback>,
    pub active_transfers: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<String, tokio_util::sync::CancellationToken>>>,
}

#[napi]
pub struct RsHttpClient {
    inner: std::sync::Mutex<RsHttpClientInner>,
}

unsafe impl Send for RsHttpClient {}

#[napi]
impl RsHttpClient {
    /// 根据存储的 TLS 配置创建一个新的 LsHttpClient。
    /// 由于 LsHttpClient 未实现 Clone，每次都会新建客户端。
    fn create_client(&self) -> Result<localsend::http::client::LsHttpClient> {
        let inner = self.inner.lock().unwrap();
        let timeout = inner.timeout_ms.map(|ms| std::time::Duration::from_millis(ms));
        localsend::http::client::LsHttpClient::new(
            &inner.key_pem,
            &inner.cert_pem,
            localsend::http::client::LsHttpClientVersion::V2,
            inner.expected_fingerprint.clone(),
            timeout,
        )
        .map_err(|e| Error::from_reason(format!("Client creation failed: {e:#}")))
    }

    /// 向远程设备准备一次上传。
    /// 返回包含 sessionId 和文件令牌的 JSON。
    #[napi]
    pub async fn prepare_upload(
        &self,
        protocol: String,
        ip: String,
        port: u16,
        files_json: String,
        public_key: Option<String>,
        pin: Option<String>,
        cancel_token: Option<&RsCancellationToken>,
    ) -> Result<String> {
        let target_protocol = crate::bridge::facade::parse_protocol_helper(&protocol);

        // 提取负载所需状态（短暂加锁）
        let (alias, device_type, device_model, fingerprint) = {
            let inner = self.inner.lock().unwrap();
            (inner.alias.clone(), inner.device_type.clone(), inner.device_model.clone(), inner.fingerprint.clone())
        };

        let client = self.create_client()?;

        let files: std::collections::HashMap<String, localsend::model::transfer::FileDto> =
            serde_json::from_str(&files_json)
                .map_err(|e| Error::from_reason(format!("Invalid files JSON: {e:#}")))?;

        let payload = localsend::http::dto::PrepareUploadRequestDto {
            info: localsend::http::dto::RegisterDto {
                alias,
                version: localsend::model::discovery::PROTOCOL_VERSION_V2.to_string(),
                device_model: Some(device_model),
                device_type: Some(device_type),
                token: fingerprint,
                port,
                protocol: target_protocol,
                has_web_interface: false,
            },
            files,
        };

        let cancel = match cancel_token {
            Some(ct) => ct.inner.clone(),
            None => tokio_util::sync::CancellationToken::new(),
        };

        let result = client
            .prepare_upload(target_protocol, &ip, port, public_key, payload, pin.as_deref(), cancel)
            .await
            .map_err(|e| Error::from_reason(format!("Prepare upload failed: {e:#}")))?;

        match result.response {
            Some(resp) => {
                let session_cancel = tokio_util::sync::CancellationToken::new();
                let inner = self.inner.lock().unwrap();
                inner.active_transfers.lock().unwrap().insert(resp.session_id.clone(), session_cancel);

                Ok(serde_json::json!({
                    "sessionId": resp.session_id,
                    "files": resp.files,
                    "statusCode": result.status_code,
                })
                .to_string())
            }
            None => Ok(serde_json::json!({
                "statusCode": result.status_code,
            })
            .to_string()),
        }
    }

    /// 向远程设备注册本设备。
    /// 返回包含远程设备信息的 JSON。
    #[napi]
    pub async fn register(
        &self,
        protocol: String,
        ip: String,
        port: u16,
        payload_json: String,
    ) -> Result<String> {
        let target_protocol = crate::bridge::facade::parse_protocol_helper(&protocol);
        let client = self.create_client()?;

        let payload: localsend::http::dto::RegisterDto = serde_json::from_str(&payload_json)
            .map_err(|e| Error::from_reason(format!("Invalid payload JSON: {e:#}")))?;

        let protocols_to_try: Vec<localsend::model::discovery::ProtocolType> = match target_protocol {
            localsend::model::discovery::ProtocolType::Https => {
                vec![localsend::model::discovery::ProtocolType::Https, localsend::model::discovery::ProtocolType::Http]
            }
            localsend::model::discovery::ProtocolType::Http => {
                vec![localsend::model::discovery::ProtocolType::Http, localsend::model::discovery::ProtocolType::Https]
            }
        };

        let mut last_error = String::from("No protocol attempted");

        for proto in &protocols_to_try {
            match client.register(*proto, &ip, port, payload.clone()).await {
                Ok(result) => {
                    let resp = result.body;
                    let resp_protocol = proto.as_str();
                    let cert_fp = result.cert_fingerprint.unwrap_or_default();
                    let pub_key = result.public_key.unwrap_or_default();
                    let ret = serde_json::json!({
                        "alias": resp.alias,
                        "version": resp.version,
                        "deviceModel": resp.device_model.unwrap_or_default(),
                        "deviceType": format!("{:?}", resp.device_type.unwrap_or(localsend::model::discovery::DeviceType::Desktop)).to_lowercase(),
                        "fingerprint": resp.token,
                        "protocol": resp_protocol,
                        "certFingerprint": cert_fp,
                        "publicKey": pub_key,
                    });
                    return Ok(ret.to_string());
                }
                Err(e) => {
                    last_error = format!("{proto:?} register failed: {e:#}");
                    continue;
                }
            }
        }

        Err(Error::from_reason(format!("Register failed: {last_error}")))
    }

    /// 向远程设备上传文件。
    #[napi]
    pub async fn upload(
        &self,
        protocol: String,
        ip: String,
        port: u16,
        session_id: String,
        file_id: String,
        token: String,
        file_path: String,
        public_key: Option<String>,
        cancel_token: Option<&RsCancellationToken>,
    ) -> Result<()> {
        let target_protocol = crate::bridge::facade::parse_protocol_helper(&protocol);
        let client = self.create_client()?;

        let (send_progress, current_send_session_id, callback) = {
            let inner = self.inner.lock().unwrap();
            (inner.send_progress.clone(), inner.current_send_session_id.clone(), inner.callback.clone())
        };

        {
            let mut sid = current_send_session_id.lock().unwrap();
            *sid = session_id.clone();
        }

        let file_meta = std::fs::metadata(&file_path);
        let total_bytes = file_meta.map(|m| m.len()).unwrap_or(0);

        let content = localsend::model::transfer::FileContent::Path(std::path::PathBuf::from(&file_path));
        let cancel = match cancel_token {
            Some(ct) => ct.inner.clone(),
            None => tokio_util::sync::CancellationToken::new(),
        };

        {
            let inner = self.inner.lock().unwrap();
            inner.active_transfers.lock().unwrap().insert(session_id.clone(), cancel.clone());
        }

        let sp = send_progress.clone();
        let sid = session_id.clone();
        let fid = file_id.clone();
        let fp = file_path.clone();
        let total = total_bytes;
        let last_update = std::sync::Arc::new(std::sync::Mutex::new(std::time::Instant::now()));
        let cb_progress = callback.clone();

        let progress = move |sent: u64| {
            let should_update = {
                let mut last = last_update.lock().unwrap();
                let now = std::time::Instant::now();
                if now.duration_since(*last) >= std::time::Duration::from_millis(20) {
                    *last = now;
                    true
                } else {
                    false
                }
            };
            if should_update || sent >= total {
                let mut map = sp.lock().unwrap();
                let key = format!("{}:{}", sid, fid);
                map.insert(key, crate::bridge::state::ProgressEntry {
                    session_id: sid.clone(),
                    file_id: fid.clone(),
                    bytes_sent: sent,
                    total_bytes: total,
                    file_path: fp.clone(),
                });
                drop(map);
                if let Some(ref cb) = cb_progress {
                    let payload = serde_json::json!({
                        "type": "progress_update",
                        "direction": "send",
                        "sessionId": sid,
                        "fileId": fid,
                        "bytesSent": sent,
                        "totalBytes": total,
                        "filePath": fp,
                    });
                    cb.call(payload.to_string());
                }
            }
        };

        let _result = client
            .upload(target_protocol, &ip, port, public_key, &session_id, &file_id, &token, content, progress, cancel)
            .await;

        {
            let inner = self.inner.lock().unwrap();
            inner.active_transfers.lock().unwrap().remove(&session_id);
        }

        match _result {
            Ok(_) => {
                {
                    let mut map = send_progress.lock().unwrap();
                    let key = format!("{}:{}", session_id, file_id);
                    map.insert(key, crate::bridge::state::ProgressEntry {
                        session_id: session_id.clone(),
                        file_id: file_id.clone(),
                        bytes_sent: total_bytes,
                        total_bytes: total_bytes,
                        file_path: file_path.clone(),
                    });
                }
                if let Some(ref cb) = callback {
                    let payload = serde_json::json!({
                        "type": "progress_update",
                        "direction": "send",
                        "sessionId": session_id,
                        "fileId": file_id,
                        "bytesSent": total_bytes,
                        "totalBytes": total_bytes,
                        "filePath": file_path,
                    });
                    cb.call(payload.to_string());
                }
                if let Some(ref cb) = callback {
                    let payload = serde_json::json!({
                        "type": "upload_finished",
                        "sessionId": session_id,
                        "fileId": file_id,
                    });
                    cb.call(payload.to_string());
                }
                Ok(())
            }
            Err(e) => {
                if let Some(ref cb) = callback {
                    let payload = serde_json::json!({
                        "type": "upload_failed",
                        "sessionId": session_id,
                        "fileId": file_id,
                        "error": format!("{e}"),
                    });
                    cb.call(payload.to_string());
                }
                Err(Error::from_reason(format!("Upload failed: {e:#}")))
            }
        }
    }

    /// 取消一个远程传输会话。
    #[napi]
    pub async fn cancel(&self, protocol: String, ip: String, port: u16, session_id: String) -> Result<()> {
        let target_protocol = crate::bridge::facade::parse_protocol_helper(&protocol);
        let client = self.create_client()?;

        client
            .cancel(target_protocol, &ip, port, &session_id)
            .await
            .map_err(|e| Error::from_reason(format!("Cancel failed: {e:#}")))?;

        Ok(())
    }
}

/// 工厂函数：创建一个 RsHttpClient 实例。
#[napi]
pub fn create_client_instance(
    private_key: String,
    cert: String,
    expected_fingerprint: Option<String>,
    timeout_ms: Option<u32>,
    alias: Option<String>,
    device_type: Option<String>,
    device_model: Option<String>,
) -> Result<RsHttpClient> {
    let (key_pem, cert_pem, fingerprint, dt, dm, al, callback) = {
        let state = bridge::state::bridge().lock().unwrap();
        let key = if private_key.is_empty() { state.key_pem.clone() } else { private_key };
        let cert_val = if cert.is_empty() { state.cert_pem.clone() } else { cert };
        let fp = expected_fingerprint.unwrap_or_else(|| state.fingerprint.clone());
        let dev_type = crate::bridge::facade::parse_device_type(device_type.as_deref().unwrap_or("mobile"));
        let dev_model = device_model.unwrap_or_else(|| state.device_model.clone());
        let al_val = alias.unwrap_or_else(|| state.local_alias.clone());
        (key, cert_val, fp, dev_type, dev_model, al_val, state.callback.clone())
    };

    Ok(RsHttpClient {
        inner: std::sync::Mutex::new(RsHttpClientInner {
            key_pem,
            cert_pem,
            fingerprint: fingerprint.clone(),
            device_type: dt,
            device_model: dm,
            alias: al,
            expected_fingerprint: Some(fingerprint),
            timeout_ms: timeout_ms.map(|ms| ms as u64),
            send_progress: std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashMap::new())),
            current_send_session_id: std::sync::Arc::new(std::sync::Mutex::new(String::new())),
            callback,
            active_transfers: std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashMap::new())),
        }),
    })
}

// ── 加密 / 安全 ─────────────────────────────────────────────────────────

#[napi(object)]
pub struct KeyPair {
    pub private_key: String,
    pub public_key: String,
}

#[napi(object)]
pub struct SecurityContext {
    pub private_key: String,
    pub public_key: String,
    pub certificate: String,
    pub certificate_hash: String,
}

/// 校验 PEM 证书与期望的公钥匹配。
/// 用于信任首次使用（TOFU）安全模型。
#[napi]
pub fn verify_cert(cert_pem: String, public_key: String) -> Result<()> {
    facade::verify_cert(&cert_pem, &public_key)
        .map_err(|e| Error::from_reason(format!("Verify cert failed: {e:#}")))
}

/// 生成用于设备认证令牌的 Ed25519 密钥对。
#[napi]
pub fn generate_key_pair() -> Result<KeyPair> {
    let kp = facade::generate_key_pair()
        .map_err(|e| Error::from_reason(format!("Generate key pair failed: {e:#}")))?;
    Ok(KeyPair {
        private_key: kp.private_key,
        public_key: kp.public_key,
    })
}

/// 生成完整的安全上下文：RSA-2048 密钥对、自签名证书、
/// 以及 SHA-256 指纹。用于 TLS 设备身份标识。
#[napi]
pub fn generate_security_context() -> Result<SecurityContext> {
    let ctx = facade::generate_security_context()
        .map_err(|e| Error::from_reason(format!("Generate security context failed: {e:#}")))?;
    Ok(SecurityContext {
        private_key: ctx.private_key,
        public_key: ctx.public_key,
        certificate: ctx.certificate,
        certificate_hash: ctx.certificate_hash,
    })
}

/// 计算指定路径文件的 SHA-256 哈希。
/// 返回十六进制编码的哈希字符串。
#[napi]
pub async fn hash_file(path: String) -> Result<String> {
    facade::hash_file(&path)
        .await
        .map_err(|e| Error::from_reason(format!("Hash file failed: {e:#}")))
}

/// 计算文件的 SHA-256 哈希，带流式进度事件。
/// 返回本次操作使用的 cancel_id。
/// 进度、完成、错误和取消事件通过 EventCallback 推送。
#[napi]
pub async fn hash_file_stream(path: String, cancel_id: Option<String>) -> Result<String> {
    facade::hash_file_stream(&path, cancel_id)
        .await
        .map_err(|e| Error::from_reason(format!("Hash file stream failed: {e:#}")))
}

/// 计算文件的 SHA-256 哈希，带流式进度事件。
/// 接受一个 RsCancellationToken 对象以支持取消操作。
/// 进度、完成、错误和取消事件通过 EventCallback 推送。
#[napi]
pub async fn hash_file_stream_with_token(path: String, cancel_token: Option<&RsCancellationToken>) -> Result<String> {
    let cancel_token = match cancel_token {
        Some(ct) => ct.inner.clone(),
        None => tokio_util::sync::CancellationToken::new(),
    };
    facade::hash_file_stream_with_token(&path, cancel_token)
        .await
        .map_err(|e| Error::from_reason(format!("Hash file stream with token failed: {e:#}")))
}

/// 按 cancel_id 取消一次哈希操作。
#[napi]
pub fn cancel_hash(cancel_id: String) -> Result<()> {
    facade::cancel_hash(&cancel_id)
        .map_err(|e| Error::from_reason(format!("Cancel hash failed: {e:#}")))
}

/// 计算内存缓冲区的 SHA-256 哈希（同步）。
#[napi]
pub fn hash_buffer(buffer: Buffer) -> String {
    facade::hash_buffer(&buffer)
}

/// 计算组合指纹字符串的 SHA-256 哈希。
/// 返回十六进制编码的哈希字符串（小写，64 个字符）。
/// 用于验证页面的图标映射。
#[napi]
pub fn compute_fingerprint_hash(combined: String) -> String {
    facade::compute_fingerprint_hash(&combined)
}

// ── 文件名工具 ───────────────────────────────────────────────────────

/// 将 `name` 重写为当前平台合法的文件名，
/// 将非法字符替换为 `_`。
#[napi]
pub fn sanitize_file_name(name: String) -> String {
    facade::sanitize_file_name(name)
}

/// 判断 `name` 是否为当前平台合法的文件名。
#[napi]
pub fn is_valid_file_name(name: String) -> bool {
    facade::is_valid_file_name(name)
}

// ── 文件元数据 ─────────────────────────────────────────────────────────────

#[napi(object)]
pub struct FileMetadataResult {
    pub last_modified: Option<String>,
    pub last_accessed: Option<String>,
}

/// 以 RFC 3339 字符串读取文件时间戳（最后修改、最后访问）
/// RFC 3339 字符串，纳秒精度。
#[napi]
pub fn read_file_metadata(path: String) -> Option<FileMetadataResult> {
    facade::read_file_metadata(&path).map(|m| FileMetadataResult {
        last_modified: m.last_modified,
        last_accessed: m.last_accessed,
    })
}
