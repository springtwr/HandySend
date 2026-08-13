//! LocalSend NAPI bridge for HarmonyOS — napi-rs entry points.
//!
//! All functions are registered via `#[napi]` macros, which automatically
//! generate `napi_register_module_v1` and `napi_define_properties` entries.
//!
//! The bridge wraps the upstream [`localsend`] protocol implementation through
//! the Facade layer, ensuring the NAPI layer never directly imports upstream
//! internal types.

mod bridge;

use bridge::facade;
use bridge::state::bridge;

use localsend::model::discovery::PROTOCOL_VERSION_V2;
use napi_ohos::bindgen_prelude::*;
use napi_ohos::threadsafe_function::ThreadsafeFunction;
use napi_derive_ohos::napi;

// ── Version Info ──────────────────────────────────────────────────────────────

/// Returns the native library version (from Cargo.toml)
#[napi]
pub fn get_native_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Returns the native library name
#[napi]
pub fn get_native_name() -> String {
    env!("CARGO_PKG_NAME").to_string()
}

/// Returns the LocalSend protocol version implemented by this library (e.g. "2.2")
#[napi]
pub fn get_protocol_version() -> String {
    PROTOCOL_VERSION_V2.to_string()
}

// ── NAPI Object Structs ──────────────────────────────────────────────────────

#[napi(object)]
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProgressInfo {
    pub session_id: String,
    pub file_id: String,
    pub bytes_sent: i64,
    pub total_bytes: i64,
    pub file_path: String,
}

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
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SendResult {
    pub session_id: String,
    pub success: bool,
    pub failed_files: Vec<String>,
}

#[napi(object)]
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShareLinkInfo {
    pub url: String,
    pub port: u16,
    pub session_id: String,
}

// ── Init / Teardown ──────────────────────────────────────────────────────────

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
    state.discovery_handle.take();
    state.event_tx.take();
    state.callback.take();
    state.pending_decisions.clear();
    state.active_transfers.clear();
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

// ── Event Callback ───────────────────────────────────────────────────────────

#[napi]
pub fn register_event_listener(callback: ThreadsafeFunction<String>) -> Result<()> {
    let cb = bridge::callback::EventCallback::new(callback);
    let mut state = bridge().lock().unwrap();
    state.callback = Some(cb);
    log::info!("Event listener registered");
    Ok(())
}

// ── Server ───────────────────────────────────────────────────────────────────

#[napi]
pub async fn start_server(
    port: u16,
    use_https: bool,
    verify_checksums: bool,
    pin: Option<String>,
) -> Result<()> {
    facade::start_server(port, use_https, verify_checksums, pin)
        .await
        .map_err(|e| Error::from_reason(format!("Start server failed: {e:#}")))?;
    log::info!("Server started on port {port}");
    Ok(())
}

#[napi]
pub fn stop_server() -> Result<()> {
    facade::stop_server();
    log::info!("Server stopped");
    Ok(())
}

// ── Discovery ────────────────────────────────────────────────────────────────

#[napi]
pub async fn start_discovery(port: u16) -> Result<()> {
    facade::start_discovery(port)
        .await
        .map_err(|e| Error::from_reason(format!("Start discovery failed: {e:#}")))?;
    log::info!("Discovery started");
    Ok(())
}

#[napi]
pub fn stop_discovery() -> Result<()> {
    facade::stop_discovery();
    log::info!("Discovery stopped");
    Ok(())
}

// ── Query ────────────────────────────────────────────────────────────────────

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

#[napi]
pub fn get_devices_json() -> String {
    facade::get_devices_json()
}

// ── Accept / Decline ─────────────────────────────────────────────────────────

#[napi]
pub fn accept_transfer(session_id: String, file_ids: Vec<String>) -> Result<()> {
    facade::accept_transfer(&session_id, &file_ids)
        .map_err(|e| Error::from_reason(format!("Accept transfer failed: {e:#}")))?;
    log::info!("Transfer accepted: {session_id}");
    Ok(())
}

#[napi]
pub fn decline_transfer(session_id: String) -> Result<()> {
    facade::decline_transfer(&session_id)
        .map_err(|e| Error::from_reason(format!("Decline transfer failed: {e:#}")))?;
    log::info!("Transfer declined: {session_id}");
    Ok(())
}

// ── Send ─────────────────────────────────────────────────────────────────────

#[napi]
pub async fn prepare_send(
    target_ip: String,
    port: u16,
    protocol: String,
    files_json: String,
    pin: Option<String>,
    expected_fingerprint: Option<String>,
) -> Result<String> {
    let target_protocol = facade::parse_protocol_helper(&protocol);
    facade::prepare_send(&target_ip, port, target_protocol, &files_json, pin, expected_fingerprint)
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
) -> Result<()> {
    let target_protocol = facade::parse_protocol_helper(&protocol);
    facade::upload_file(&target_ip, port, target_protocol, &session_id, &file_id, &token, &file_path, expected_fingerprint)
        .await
        .map_err(|e| Error::from_reason(format!("Upload failed: {e:#}")))?;
    log::info!("Uploaded: {file_path} -> {session_id}");
    Ok(())
}

// ── Cancel ───────────────────────────────────────────────────────────────────

#[napi]
pub fn cancel_transfer(session_id: String) -> Result<()> {
    facade::cancel_transfer(&session_id);
    log::info!("Transfer cancelled: {session_id}");
    Ok(())
}

// ── High-level API ───────────────────────────────────────────────────────────

#[napi]
pub async fn create_server(config: String) -> Result<ServerHandle> {
    let json_str = facade::create_server(&config)
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
    let json_str = facade::send_files(&target, &sender_alias, &files)
        .await
        .map_err(|e| Error::from_reason(format!("Send files failed: {e:#}")))?;
    serde_json::from_str(&json_str)
        .map_err(|e| Error::from_reason(format!("Parse SendResult failed: {e:#}")))
}

// ── Discovery Register (mTLS-capable) ────────────────────────────────────────

/// Register this device with a remote device via HTTP/HTTPS with mTLS support.
///
/// Unlike the ArkTS HTTP client, this function uses the Rust LsHttpClient which
/// carries client certificates for proper mTLS handshakes. This is essential for
/// registering with HTTPS-only servers.
///
/// Tries `our_protocol` first, then the alternative. Returns remote device info on success.
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
    facade::register_device(
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

#[napi]
pub fn poll_send_progress() -> Vec<ProgressInfo> {
    let entries = facade::poll_send_progress();
    entries
        .into_iter()
        .map(|e| ProgressInfo {
            session_id: e.session_id,
            file_id: e.file_id,
            bytes_sent: e.bytes_sent as i64,
            total_bytes: e.total_bytes as i64,
            file_path: e.file_path,
        })
        .collect()
}

#[napi]
pub fn poll_progress() -> Vec<ProgressInfo> {
    let entries = facade::poll_progress();
    entries
        .into_iter()
        .map(|e| ProgressInfo {
            session_id: e.session_id,
            file_id: e.file_id,
            bytes_sent: e.bytes_sent as i64,
            total_bytes: e.total_bytes as i64,
            file_path: e.file_path,
        })
        .collect()
}

#[napi]
pub fn poll_pending_requests() -> Vec<TransferRequest> {
    let requests = facade::poll_pending_requests();
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
    facade::respond_transfer(&session_id, accept, &accepted_file_ids)
        .map_err(|e| Error::from_reason(format!("Respond transfer failed: {e:#}")))?;
    Ok(())
}

#[napi]
pub fn get_server_status() -> ServerStatus {
    let json_str = facade::get_server_status();
    serde_json::from_str(&json_str).unwrap_or(ServerStatus {
        running: false,
        active_session: None,
        fingerprint: None,
    })
}
#[napi]
pub fn get_current_send_session_id() -> String {
    facade::get_current_send_session_id()
}

#[napi]
pub async fn cancel_transfer_remote(target: String, session_id: String) -> Result<()> {
    facade::cancel_transfer_remote(&target, &session_id)
        .await
        .map_err(|e| Error::from_reason(format!("Cancel transfer remote failed: {e:#}")))
}

#[napi]
pub fn cancel_local_session(session_id: String) -> Result<()> {
    facade::cancel_local_session(&session_id);
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

#[napi]
pub async fn create_share_link(files: String, alias: String) -> Result<ShareLinkInfo> {
    let json_str = facade::create_share_link(&files, &alias)
        .map_err(|e| Error::from_reason(format!("Create share link failed: {e:#}")))?;
    serde_json::from_str(&json_str)
        .map_err(|e| Error::from_reason(format!("Parse ShareLinkInfo failed: {e:#}")))
}

#[napi]
pub fn stop_share_server() -> Result<()> {
    facade::stop_share_server();
    Ok(())
}

#[napi]
pub fn poll_share_progress() -> Vec<ProgressInfo> {
    let entries = facade::poll_share_progress();
    entries
        .into_iter()
        .map(|e| ProgressInfo {
            session_id: e.session_id,
            file_id: e.file_id,
            bytes_sent: e.bytes_sent as i64,
            total_bytes: e.total_bytes as i64,
            file_path: e.file_path,
        })
        .collect()
}

#[napi]
pub fn get_recv_diag() -> RecvDiag {
    let json_str = facade::get_recv_diag();
    serde_json::from_str(&json_str).unwrap_or(RecvDiag {
        drain_count: 0,
        queued_events: 0,
    })
}

// ── Crypto / Security ─────────────────────────────────────────────────────────

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

/// Verify that a PEM certificate matches an expected public key.
/// Used for trust-on-first-use (TOFU) security model.
#[napi]
pub fn verify_cert(cert_pem: String, public_key: String) -> Result<()> {
    facade::verify_cert(&cert_pem, &public_key)
        .map_err(|e| Error::from_reason(format!("Verify cert failed: {e:#}")))
}

/// Generate an Ed25519 key pair for device authentication tokens.
#[napi]
pub fn generate_key_pair() -> Result<KeyPair> {
    let kp = facade::generate_key_pair()
        .map_err(|e| Error::from_reason(format!("Generate key pair failed: {e:#}")))?;
    Ok(KeyPair {
        private_key: kp.private_key,
        public_key: kp.public_key,
    })
}

/// Generate a full security context: RSA-2048 key pair, self-signed certificate,
/// and SHA-256 fingerprint. Used for TLS device identity.
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

/// Compute the SHA-256 hash of a file at the given path.
/// Returns the hex-encoded hash string.
#[napi]
pub async fn hash_file(path: String) -> Result<String> {
    facade::hash_file(&path)
        .await
        .map_err(|e| Error::from_reason(format!("Hash file failed: {e:#}")))
}

/// Compute SHA-256 hash of a combined fingerprint string.
/// Returns the hex-encoded hash string (lowercase, 64 chars).
/// Used for verification page icon mapping.
#[napi]
pub fn compute_fingerprint_hash(combined: String) -> String {
    facade::compute_fingerprint_hash(&combined)
}

// ── File Name Utilities ───────────────────────────────────────────────────────

/// Rewrite `name` into a file name that is legal on the current platform,
/// replacing illegal characters with `_`.
#[napi]
pub fn sanitize_file_name(name: String) -> String {
    facade::sanitize_file_name(name)
}

/// Whether `name` is a legal file name on the current platform.
#[napi]
pub fn is_valid_file_name(name: String) -> bool {
    facade::is_valid_file_name(name)
}

// ── File Metadata ─────────────────────────────────────────────────────────────

#[napi(object)]
pub struct FileMetadataResult {
    pub last_modified: Option<String>,
    pub last_accessed: Option<String>,
}

/// Read file timestamps (last modified, last accessed) as
/// RFC 3339 strings with nanosecond precision.
#[napi]
pub fn read_file_metadata(path: String) -> Option<FileMetadataResult> {
    facade::read_file_metadata(&path).map(|m| FileMetadataResult {
        last_modified: m.last_modified,
        last_accessed: m.last_accessed,
    })
}
