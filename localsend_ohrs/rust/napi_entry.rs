// ── 版本信息 ──────────────────────────────────────────────────────────────

/// 返回原生库版本（来自 Cargo.toml）
#[napi]
pub fn get_native_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
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

/// 网络接口信息——包含接口名、IPv4 地址和前缀长度。
#[napi(object)]
pub struct NetworkInterfaceInfo {
    /// 接口名（如 "wlan0"、"ancowlan0"、"rmnet0"）
    pub name: String,
    /// IPv4 地址（如 "192.168.1.5"）
    pub ip: String,
    /// 前缀长度（如 24）
    pub prefix_length: u32,
}

// ── 初始化 / 销毁 ──────────────────────────────────────────────────────────

#[napi]
pub fn init(alias: String, device_type: String, _log_level: Option<String>) -> Result<()> {
    facade::init_hilog_logger();
    let dt = facade::parse_device_type(&device_type);

    facade::init(alias, dt).map_err(|e| Error::from_reason(format!("Init failed: {e:#}")))?;

    log::debug!("Bridge initialized");
    Ok(())
}

// ── 事件回调 ───────────────────────────────────────────────────────────

#[napi]
pub fn register_event_listener(callback: ThreadsafeFunction<String>) -> Result<()> {
    let cb = bridge::callback::NapiEventCallback::new(callback);
    let mut state = bridge_state().lock().unwrap();
    state.callback = Some(std::sync::Arc::new(cb));
    log::debug!("Event listener registered");
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
pub async fn discovery_discover_staged(
    channels: String,
    interface_ips: String,
    port: u16,
    protocol: String,
    grace_ms: u32,
) -> Result<()> {
    bridge::discovery_facade::discovery_discover_staged(
        &channels,
        &interface_ips,
        port,
        &protocol,
        grace_ms,
    )
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
    bridge::discovery_facade::discovery_set_answer_announcements(answer).map_err(|e| {
        Error::from_reason(format!("Discovery set_answer_announcements failed: {e:#}"))
    })?;
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
pub fn discovery_get_device(fingerprint: String) -> String {
    bridge::discovery_facade::discovery_get_device(&fingerprint)
}

#[napi]
pub fn discovery_multicast_error() -> String {
    bridge::discovery_facade::discovery_multicast_error()
}

// ── 查询 ────────────────────────────────────────────────────────────────────

#[napi]
pub fn get_local_addresses() -> Vec<String> {
    facade::get_local_addresses()
}

/// 枚举所有非回环 IPv4 网络接口，返回结构化信息列表。
/// 主数据源用于统一 ArkTS 层接口枚举。
#[napi]
pub fn get_network_interfaces() -> Vec<NetworkInterfaceInfo> {
    facade::get_network_interfaces()
}

// ── 接收 / 拒绝 ─────────────────────────────────────────────────────────

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
    bridge::client_facade::prepare_send(
        &target_ip,
        port,
        target_protocol,
        &files_json,
        pin,
        expected_fingerprint,
        public_key,
    )
    .await
    .map_err(|e| Error::from_reason(format!("Prepare send failed: {e:#}")))
}

// ── 取消 ───────────────────────────────────────────────────────────────────

#[napi]
pub fn cancel_transfer(session_id: String) -> Result<()> {
    log::debug!("[NAPI] cancel_transfer called, session_id={}", session_id);
    bridge::client_facade::cancel_transfer(&session_id);
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
pub async fn send_files(target: String, sender_alias: String, files: String) -> Result<SendResult> {
    let json_str = bridge::client_facade::send_files(&target, &sender_alias, &files)
        .await
        .map_err(|e| Error::from_reason(format!("Send files failed: {e:#}")))?;
    serde_json::from_str(&json_str)
        .map_err(|e| Error::from_reason(format!("Parse SendResult failed: {e:#}")))
}

// ── 发现注册（支持 mTLS） ────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
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
pub async fn client_info(protocol: String, ip: String, port: u16) -> Result<String> {
    let protocol_enum = facade::parse_protocol_helper(&protocol);
    bridge::client_facade::client_info(protocol_enum, &ip, port)
        .await
        .map_err(|e| Error::from_reason(format!("Client info failed: {e:#}")))
}

// ── 下载 API ──

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
        &target_ip,
        port,
        protocol_enum,
        &session_id,
        &file_id,
        &save_path,
        public_key,
    )
    .await
    .map_err(|e| Error::from_reason(format!("Download file failed: {e:#}")))?;
    Ok(bytes as f64)
}

// ── 缓冲区上传 ──

#[allow(clippy::too_many_arguments)]
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
        &target_ip,
        port,
        protocol_enum,
        &session_id,
        &file_id,
        &token,
        data,
        public_key,
        cancel_id,
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
pub fn poll_debug_log() -> Vec<String> {
    facade::poll_debug_log()
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

// ── 加密 / 安全 ─────────────────────────────────────────────────────────

// ── 取消令牌 ───────────────────────────────────────────────────────────────

/// 创建一个 CancellationToken 并返回其 UUID id。
/// 该令牌可传给 hash_file_stream 或 upload_from_buffer 用于取消。
#[napi]
pub fn create_cancel_token() -> String {
    facade::create_cancel_token()
}

// ── 加密 / 安全 ─────────────────────────────────────────────────────────

#[napi(object)]
pub struct SecurityContext {
    pub private_key: String,
    pub public_key: String,
    pub certificate: String,
    pub certificate_hash: String,
}

/// 获取当前生效的安全上下文（私钥/公钥/证书/指纹）。
/// 公钥从当前生效证书的 DER 中提取；证书尚未生成时返回空公钥。
#[napi]
pub fn get_security_context() -> Result<SecurityContext> {
    let ctx = facade::get_security_context()
        .map_err(|e| Error::from_reason(format!("Get security context failed: {e:#}")))?;
    Ok(SecurityContext {
        private_key: ctx.private_key,
        public_key: ctx.public_key,
        certificate: ctx.certificate,
        certificate_hash: ctx.certificate_hash,
    })
}

/// 重置安全上下文：生成新的 RSA-2048 自签名证书与私钥，
/// 覆盖持久化身份文件并更新全局生效状态（指纹随之变化）。
/// 写盘失败时内存与磁盘均保持旧值。
#[napi]
pub fn reset_security_context() -> Result<SecurityContext> {
    let ctx = facade::reset_security_context()
        .map_err(|e| Error::from_reason(format!("Reset security context failed: {e:#}")))?;
    Ok(SecurityContext {
        private_key: ctx.private_key,
        public_key: ctx.public_key,
        certificate: ctx.certificate,
        certificate_hash: ctx.certificate_hash,
    })
}

/// 计算文件的 SHA-256 哈希，带流式进度事件。
/// 返回计算出的 SHA-256 哈希值（十六进制字符串）；取消时返回空字符串。
/// 进度、完成、错误和取消事件通过 EventCallback 推送。
#[napi]
pub async fn hash_file_stream(path: String, cancel_id: Option<String>) -> Result<String> {
    facade::hash_file_stream(&path, cancel_id)
        .await
        .map_err(|e| Error::from_reason(format!("Hash file stream failed: {e:#}")))
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
