//! Facade layer — public utility functions shared across all facade modules.
//!
//! After the module split, this file contains only:
//! - Protocol/device type parsing helpers
//! - Init/teardown
//! - Device/server JSON serialization helpers
//! - Crypto/security utilities
//! - File name/metadata utilities
//! - Debug/share link diagnostics
//!
//! Server logic → server_facade.rs
//! Client logic → client_facade.rs
//! Discovery logic → discovery_facade.rs

use anyhow::Result;
use serde_json::{json, Value};

use localsend::crypto;
use localsend::discovery::StatefulDevice;
use localsend::http::server::v2::ServerEventV2;
use localsend::http::server::web::{WebConfig, WebSendConfig, WebSendEvent, WebI18n};
use localsend::model::discovery::{DeviceType, ProtocolType};
use localsend::model::transfer::{FileContent, FileDto};

use crate::bridge::state::bridge;

// ── Public Facade API ────────────────────────────────────────────────────────

/// Get the current protocol type based on `use_https` state.
pub fn current_protocol() -> ProtocolType {
    let state = bridge().lock().unwrap();
    if state.use_https {
        ProtocolType::Https
    } else {
        ProtocolType::Http
    }
}

/// Parse a protocol string ("https" / "http") into ProtocolType.
/// Defaults to Https if unrecognized.
pub fn parse_protocol_helper(s: &str) -> ProtocolType {
    match s.to_lowercase().as_str() {
        "http" => ProtocolType::Http,
        _ => ProtocolType::Https,
    }
}

pub fn parse_device_type(s: &str) -> DeviceType {
    match s.to_lowercase().as_str() {
        "desktop" | "pc" => DeviceType::Desktop,
        "web" | "browser" => DeviceType::Web,
        "headless" => DeviceType::Headless,
        "server" => DeviceType::Server,
        _ => DeviceType::Mobile,
    }
}

pub fn init(alias: String, device_type: DeviceType) -> Result<()> {
    // Use the save_dir from BridgeState as persistence directory.
    // This keeps certificate fingerprint stable across app restarts.
    let save_dir = {
        let state = bridge().lock().unwrap();
        state.save_dir.clone()
    };
    init_with_persisted_identity(alias, device_type, &save_dir)
}

/// Like [`init`], but first tries to load a previously persisted TLS identity
/// (private key + certificate) from `persist_dir`, and saves a freshly
/// generated one there when none exists. This keeps the certificate
/// fingerprint stable across app restarts.
///
/// An empty `persist_dir` disables persistence (fresh identity every start).
pub fn init_with_persisted_identity(
    alias: String,
    device_type: DeviceType,
    persist_dir: &str,
) -> Result<()> {
    log::info!("[DBG-INIT] init_with_persisted_identity: alias={} persist_dir={}", alias, persist_dir);
    let mut state = bridge().lock().unwrap();

    // Only generate cert and runtime on first call
    if state.runtime.is_none() {
        let persist_dir = if persist_dir.is_empty() { None } else { Some(persist_dir) };
        let loaded = persist_dir.and_then(|dir| load_persisted_identity(dir).ok().flatten());
        log::info!("[DBG-INIT]   loaded_persisted={}", loaded.is_some());

        let cert = match loaded {
            Some((key_pem, cert_pem)) => {
                // Reuse the persisted identity and derive the fingerprint from it.
                let fingerprint = crypto::cert::fingerprint_from_cert_der(&extract_der_from_pem(&cert_pem));
                localsend::crypto::cert::SelfSignedCert {
                    private_key_pem: key_pem,
                    public_key_pem: String::new(),
                    certificate_pem: cert_pem,
                    fingerprint,
                }
            }
            None => {
                let cert = crypto::cert::generate_self_signed()?;
                if let Some(dir) = persist_dir {
                    let _ = save_persisted_identity(dir, &cert.private_key_pem, &cert.certificate_pem);
                }
                cert
            }
        };

        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(2)
            .thread_name("localsend")
            .build()?;

        state.cert_pem = cert.certificate_pem;
        state.key_pem = cert.private_key_pem;
        state.fingerprint = cert.fingerprint;
        state.runtime = Some(rt);
    }

    state.local_alias = alias;
    state.device_type = device_type;
    Ok(())
}

/// Identity files stored next to the server's save directory.
const IDENTITY_KEY_FILE: &str = "identity.key";
const IDENTITY_CERT_FILE: &str = "identity.pem";

fn load_persisted_identity(dir: &str) -> Result<Option<(String, String)>> {
    use std::path::Path;
    let key_path = Path::new(dir).join(IDENTITY_KEY_FILE);
    let cert_path = Path::new(dir).join(IDENTITY_CERT_FILE);
    if !key_path.exists() || !cert_path.exists() {
        return Ok(None);
    }
    let key = std::fs::read_to_string(&key_path)?;
    let cert = std::fs::read_to_string(&cert_path)?;
    if key.trim().is_empty() || cert.trim().is_empty() {
        return Ok(None);
    }
    Ok(Some((key, cert)))
}

fn save_persisted_identity(dir: &str, key_pem: &str, cert_pem: &str) -> Result<()> {
    use std::path::Path;
    std::fs::create_dir_all(dir)?;
    let key_path = Path::new(dir).join(IDENTITY_KEY_FILE);
    let cert_path = Path::new(dir).join(IDENTITY_CERT_FILE);
    std::fs::write(&key_path, key_pem)?;
    std::fs::write(&cert_path, cert_pem)?;
    Ok(())
}

/// Cancel a hash operation by its cancel_id. Does NOT remove the token from the map
/// (hash_file_stream will clean it up after the operation completes).
pub fn cancel_hash(cancel_id: &str) -> Result<()> {
    let state = bridge().lock().unwrap();
    if let Some(token) = state.cancel_tokens.get(cancel_id) {
        token.cancel();
        Ok(())
    } else {
        Err(anyhow::anyhow!("Cancel token not found for hash: {}", cancel_id))
    }
}

// ── Cancel Token ─────────────────────────────────────────────────────────────

/// Create a new CancellationToken and return its UUID id.
pub fn create_cancel_token() -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let token = tokio_util::sync::CancellationToken::new();
    let mut state = bridge().lock().unwrap();
    state.cancel_tokens.insert(id.clone(), token);
    id
}

/// Cancel a token by id. Removes it from the map after cancellation.
pub fn cancel_token_cancel(id: &str) -> Result<()> {
    let mut state = bridge().lock().unwrap();
    if let Some(token) = state.cancel_tokens.remove(id) {
        token.cancel();
        Ok(())
    } else {
        Err(anyhow::anyhow!("Cancel token not found: {}", id))
    }
}

// ── Query Utilities ──────────────────────────────────────────────────────────

pub fn get_local_device_json() -> String {
    let state = bridge().lock().unwrap();
    let json = json!({
        "alias": state.local_alias,
        "deviceType": format!("{:?}", state.device_type),
        "fingerprint": state.fingerprint,
        "port": state.local_port,
        "certPem": state.cert_pem,
    });
    json.to_string()
}

pub fn get_local_addresses() -> Vec<String> {
    let state = bridge().lock().unwrap();
    state
        .server_handle
        .as_ref()
        .map(|h| h.local_addresses().iter().map(|a| a.to_string()).collect())
        .unwrap_or_default()
}

// ── Internal DTO Conversion ─────────────────────────────────────────────────

pub fn device_type_to_string(dt: &DeviceType) -> &'static str {
    match dt {
        DeviceType::Mobile => "mobile",
        DeviceType::Desktop => "desktop",
        DeviceType::Web => "web",
        DeviceType::Headless => "headless",
        DeviceType::Server => "server",
    }
}

pub fn protocol_to_string(p: &ProtocolType) -> &'static str {
    match p {
        ProtocolType::Http => "http",
        ProtocolType::Https => "https",
    }
}

pub fn device_to_json(d: &StatefulDevice) -> Value {
    let http = d.device.http();
    // Build channels array from the device's ranked channels
    let channels: Vec<Value> = d
        .get_ranked_channels()
        .iter()
        .filter_map(|ch| ch.http())
        .map(|h| {
            json!({
                "host": h.host,
                "port": h.port,
                "protocol": protocol_to_string(&h.protocol),
            })
        })
        .collect();

    json!({
        "alias": d.device.alias,
        "fingerprint": d.device.fingerprint,
        "version": d.device.version,
        "deviceModel": d.device.device_model,
        "deviceType": d.device.device_type.as_ref().map(|dt| device_type_to_string(dt)),
        "download": d.device.download,
        "host": http.map(|h| &h.host),
        "port": http.map(|h| h.port),
        "protocol": http.map(|h| protocol_to_string(&h.protocol)),
        "channels": channels,
    })
}

pub fn server_event_to_json(event: &ServerEventV2) -> String {
    match event {
        ServerEventV2::Register { ip, info } => json!({
            "type": "register",
            "ip": ip.to_string(),
            "info": {
                "alias": info.alias,
                "version": info.version,
                "deviceModel": info.device_model,
                "deviceType": info.device_type.as_ref().map(|dt| device_type_to_string(dt)),
                "fingerprint": info.fingerprint,
                "download": info.download,
                "port": info.port,
                "protocol": protocol_to_string(&info.protocol),
            },
        })
        .to_string(),

        ServerEventV2::PrepareUpload {
            session_id,
            ip,
            info,
            cert_fingerprint,
            files,
            ..
        } => {
            let file_list: Vec<Value> = files
                .iter()
                .map(|(id, f)| {
                    let mut obj = json!({
                        "id": id,
                        "fileName": f.file_name,
                        "size": f.size,
                        "fileType": f.file_type,
                    });
                    if let Some(ref preview) = f.preview {
                        obj["preview"] = json!(preview);
                    }
                    if let Some(ref sha256) = f.sha256 {
                        obj["sha256"] = json!(sha256);
                    }
                    obj
                })
                .collect();
            json!({
                "type": "prepare_upload",
                "sessionId": session_id,
                "ip": ip.to_string(),
                "info": {
                    "alias": info.alias,
                    "version": info.version,
                    "deviceModel": info.device_model,
                    "deviceType": info.device_type.as_ref().map(|dt| device_type_to_string(dt)),
                    "fingerprint": info.fingerprint,
                    "download": info.download,
                    "port": info.port,
                },
                "certFingerprint": cert_fingerprint,
                "files": file_list,
            })
            .to_string()
        }

        ServerEventV2::FileUpload {
            session_id,
            file_id,
            file,
            ..
        } => json!({
            "type": "file_upload",
            "sessionId": session_id,
            "fileId": file_id,
            "file": {
                "fileName": file.file_name,
                "size": file.size,
                "fileType": file.file_type,
            },
        })
        .to_string(),

        ServerEventV2::SessionEnd {
            session_id,
            reason,
        } => json!({
            "type": "session_end",
            "sessionId": session_id,
            "reason": format!("{reason:?}"),
        })
        .to_string(),

        ServerEventV2::PrepareUploadAborted { session_id } => json!({
            "type": "prepare_upload_aborted",
            "sessionId": session_id,
        })
        .to_string(),

        ServerEventV2::CancelReceived { ip, session_id } => json!({
            "type": "cancel_received",
            "ip": ip.to_string(),
            "sessionId": session_id,
        })
        .to_string(),
    }
}

// ── Crypto / Security ────────────────────────────────────────────────────────

pub struct KeyPairDto {
    pub private_key: String,
    pub public_key: String,
}

pub struct SecurityContextDto {
    pub private_key: String,
    pub public_key: String,
    pub certificate: String,
    pub certificate_hash: String,
}

pub struct FileMetadataDto {
    pub last_modified: Option<String>,
    pub last_accessed: Option<String>,
}

/// Verify that a PEM certificate matches an expected public key.
pub fn verify_cert(cert_pem: &str, public_key: &str) -> Result<()> {
    crypto::cert::verify_cert_from_pem(cert_pem.to_string(), Some(public_key))
}

/// Generate an Ed25519 key pair for device authentication tokens.
pub fn generate_key_pair() -> Result<KeyPairDto> {
    let signing_key = crypto::token::generate_key();
    let private_key = crypto::token::export_private_key(&signing_key)?;
    let public_key = crypto::token::export_public_key(&signing_key)?;

    Ok(KeyPairDto {
        private_key: private_key.to_string(),
        public_key,
    })
}

/// Generate a full security context: RSA-2048 key pair, self-signed certificate,
/// and SHA-256 fingerprint.
pub fn generate_security_context() -> Result<SecurityContextDto> {
    let cert = crypto::cert::generate_self_signed()?;

    Ok(SecurityContextDto {
        private_key: cert.private_key_pem,
        public_key: cert.public_key_pem,
        certificate: cert.certificate_pem,
        certificate_hash: cert.fingerprint,
    })
}

/// Compute the SHA-256 hash of a file at the given path.
/// Returns the hex-encoded hash string.
pub async fn hash_file(path: &str) -> Result<String> {
    let content = localsend::model::transfer::FileContent::Path(std::path::PathBuf::from(path));
    let cancel = tokio_util::sync::CancellationToken::new();

    let hash = crypto::hash::sha256_file_content(content, &cancel, |_progress| {})
        .await
        .map_err(|e| anyhow::anyhow!("{e}"))?;

    Ok(hash)
}

/// Compute the SHA-256 hash of a file with stream progress events and cancellation support.
/// Returns the cancel_id used for this operation.
pub async fn hash_file_stream(path: &str, cancel_id: Option<String>) -> Result<String> {
    let content = localsend::model::transfer::FileContent::Path(std::path::PathBuf::from(path));

    // Get or create the CancellationToken
    let (cancel_id, cancel_token) = {
        let mut state = bridge().lock().unwrap();
        match cancel_id {
            Some(id) => {
                if let Some(token) = state.cancel_tokens.get(&id) {
                    (id, token.clone())
                } else {
                    let token = tokio_util::sync::CancellationToken::new();
                    state.cancel_tokens.insert(id.clone(), token.clone());
                    (id, token)
                }
            }
            None => {
                let id = uuid::Uuid::new_v4().to_string();
                let token = tokio_util::sync::CancellationToken::new();
                state.cancel_tokens.insert(id.clone(), token.clone());
                (id, token)
            }
        }
    };

    let callback = {
        let state = bridge().lock().unwrap();
        state.callback.clone()
    };

    let cid = cancel_id.clone();
    let cb = callback.clone();

    let result = crypto::hash::sha256_file_content(content, &cancel_token, move |bytes| {
        if let Some(ref cb) = cb {
            let payload = json!({
                "type": "hash_progress",
                "cancelId": cid,
                "bytes": bytes,
            });
            cb.call(payload.to_string());
        }
    })
    .await;

    // Remove the cancel token after operation completes
    {
        let mut state = bridge().lock().unwrap();
        state.cancel_tokens.remove(&cancel_id);
    }

    match result {
        Ok(hash) => {
            if let Some(ref cb) = callback {
                let payload = json!({
                    "type": "hash_done",
                    "cancelId": cancel_id,
                    "hash": hash,
                });
                cb.call(payload.to_string());
            }
            Ok(cancel_id)
        }
        Err(localsend::crypto::hash::HashError::Cancelled) => {
            if let Some(ref cb) = callback {
                let payload = json!({
                    "type": "hash_cancelled",
                    "cancelId": cancel_id,
                });
                cb.call(payload.to_string());
            }
            Ok(cancel_id)
        }
        Err(e) => {
            if let Some(ref cb) = callback {
                let payload = json!({
                    "type": "hash_error",
                    "cancelId": cancel_id,
                    "error": format!("{e}"),
                });
                cb.call(payload.to_string());
            }
            Err(anyhow::anyhow!("{e}"))
        }
    }
}

/// Compute SHA-256 hash of a file with a CancellationToken object.
/// Returns a generated cancel_id for progress tracking.
pub async fn hash_file_stream_with_token(
    path: &str,
    cancel_token: tokio_util::sync::CancellationToken,
) -> Result<String> {
    let content = localsend::model::transfer::FileContent::Path(std::path::PathBuf::from(path));

    let cancel_id = uuid::Uuid::new_v4().to_string();

    let callback = {
        let state = bridge().lock().unwrap();
        state.callback.clone()
    };

    let cid = cancel_id.clone();
    let cb = callback.clone();

    let result = crypto::hash::sha256_file_content(content, &cancel_token, move |bytes| {
        if let Some(ref cb) = cb {
            let payload = json!({
                "type": "hash_progress",
                "cancelId": cid,
                "bytes": bytes,
            });
            cb.call(payload.to_string());
        }
    })
    .await;

    match result {
        Ok(hash) => {
            if let Some(ref cb) = callback {
                let payload = json!({
                    "type": "hash_done",
                    "cancelId": cancel_id,
                    "hash": hash,
                });
                cb.call(payload.to_string());
            }
            Ok(cancel_id)
        }
        Err(localsend::crypto::hash::HashError::Cancelled) => {
            if let Some(ref cb) = callback {
                let payload = json!({
                    "type": "hash_cancelled",
                    "cancelId": cancel_id,
                });
                cb.call(payload.to_string());
            }
            Ok(cancel_id)
        }
        Err(e) => {
            if let Some(ref cb) = callback {
                let payload = json!({
                    "type": "hash_error",
                    "cancelId": cancel_id,
                    "error": format!("{e}"),
                });
                cb.call(payload.to_string());
            }
            Err(anyhow::anyhow!("{e}"))
        }
    }
}

/// Compute SHA-256 hash of an in-memory buffer.
pub fn hash_buffer(data: &[u8]) -> String {
    use sha2::{Sha256, Digest};
    let mut hasher = Sha256::new();
    hasher.update(data);
    hex::encode(hasher.finalize())
}

pub fn compute_fingerprint(cert_pem: &str) -> String {
    let cert_der = extract_der_from_pem(cert_pem);
    crypto::cert::fingerprint_from_cert_der(&cert_der)
}

fn extract_der_from_pem(pem_str: &str) -> Vec<u8> {
    use std::io::Cursor;
    match x509_parser::pem::Pem::read(Cursor::new(pem_str.as_bytes())) {
        Ok((pem, _)) => pem.contents.to_vec(),
        Err(_) => Vec::new(),
    }
}

pub fn verify_fingerprint(cert_pem: &str, expected: &str) -> bool {
    let actual = compute_fingerprint(cert_pem);
    actual.eq_ignore_ascii_case(expected)
}

/// Compute SHA-256 hash of a combined fingerprint string.
/// Returns the hex-encoded hash string (lowercase, 64 chars).
/// Used for the verification page icon mapping.
pub fn compute_fingerprint_hash(combined: &str) -> String {
    use sha2::{Sha256, Digest};
    let mut hasher = Sha256::new();
    hasher.update(combined.as_bytes());
    let result = hasher.finalize();
    hex::encode(result)
}

// ── File Name Utilities ──────────────────────────────────────────────────────

/// Rewrite `name` into a file name that is legal on the current platform,
/// replacing illegal characters with `_`.
pub fn sanitize_file_name(name: String) -> String {
    localsend::util::filename::sanitize(&name, localsend::util::filename::Rules::current())
}

/// Whether `name` is a legal file name on the current platform.
pub fn is_valid_file_name(name: String) -> bool {
    localsend::util::filename::is_valid(&name, localsend::util::filename::Rules::current())
}

// ── File Metadata ────────────────────────────────────────────────────────────

/// Read file timestamps as RFC 3339 strings.
pub fn read_file_metadata(path: &str) -> Option<FileMetadataDto> {
    use localsend::model::transfer::FileMetadata;

    let meta = FileMetadata::from_path(std::path::Path::new(path))?;

    Some(FileMetadataDto {
        last_modified: meta.modified,
        last_accessed: meta.accessed,
    })
}

// ── Debug / Diagnostics ──────────────────────────────────────────────────────

pub fn poll_debug_log() -> Vec<String> {
    let state = bridge().lock().unwrap();
    let mut log = state.debug_log.lock().unwrap();
    let entries: Vec<String> = log.drain(..).collect();
    entries
}

/// Enable debug-level logging for the Rust layer.
pub fn enable_debug_logging() -> Result<()> {
    log::set_max_level(log::LevelFilter::Debug);
    log::info!("Debug logging enabled");
    Ok(())
}

pub async fn create_share_link(files_json: &str, _alias: &str) -> Result<String> {
    // Parse the files JSON array
    let files: Vec<Value> = serde_json::from_str(files_json)
        .map_err(|e| anyhow::anyhow!("Failed to parse files JSON: {e:#}"))?;

    if files.is_empty() {
        return Err(anyhow::anyhow!("No files provided for share link"));
    }

    // Build FileDto HashMap and fileId→filePath mapping
    let mut file_dtos: std::collections::HashMap<String, FileDto> = std::collections::HashMap::new();
    let mut file_paths: std::collections::HashMap<String, String> = std::collections::HashMap::new();

    for f in &files {
        let file_id = f["fileId"].as_str().unwrap_or("").to_string();
        let file_name = f["fileName"].as_str().unwrap_or("").to_string();
        let size = f["size"].as_u64().unwrap_or(0);
        let file_type = f["fileType"].as_str().unwrap_or("").to_string();
        let file_path = f["filePath"].as_str().unwrap_or("").to_string();
        let preview = f["preview"].as_str().map(|s| s.to_string());
        let sha256 = f["sha256"].as_str().map(|s| s.to_string());

        if file_id.is_empty() || file_path.is_empty() {
            continue;
        }

        file_dtos.insert(
            file_id.clone(),
            FileDto {
                id: file_id.clone(),
                file_name: file_name.clone(),
                size,
                file_type: file_type.clone(),
                sha256: sha256.clone(),
                preview: preview.clone(),
                metadata: None,
            },
        );
        file_paths.insert(file_id.clone(), file_path);
    }

    if file_dtos.is_empty() {
        return Err(anyhow::anyhow!("No valid files provided for share link"));
    }

    // Read the receive PIN from state
    let current_pin: Option<String> = {
        let state = bridge().lock().unwrap();
        state.receive_pin.clone()
    };

    // Create the WebSend event channel
    let (web_send_event_tx, web_send_event_rx) =
        tokio::sync::mpsc::channel::<WebSendEvent>(64);

    // Stop the current server and wait for the port to be released
    let wait_stopped_fut = {
        let mut state = bridge().lock().unwrap();
        // Send stop signal
        if let Some(stop_tx) = state.server_stop_tx.take() {
            let _ = stop_tx.send(());
        }
        // Take the handle so we can wait for graceful shutdown
        state.server_handle.take()
    };

    // Get state values needed for restart
    let (port, use_https, verify_checksums, callback) = {
        let state = bridge().lock().unwrap();
        (
            state.local_port,
            state.use_https,
            true, // verify_checksums
            state.callback.clone(),
        )
    };

    // Wait for the server task to complete (port released) instead of fixed sleep
    if let Some(handle) = wait_stopped_fut {
        handle.wait_stopped().await;
    }

    // Build WebConfig with WebSendConfig
    let i18n = build_web_i18n();
    let web_send_config = WebSendConfig {
        files: file_dtos,
        pin: current_pin.clone(),
        event_tx: web_send_event_tx.clone(),
    };
    let web_config = WebConfig {
        send: Some(web_send_config),
        upload: false,
        i18n,
    };

    // Store web send state in BridgeState
    {
        let mut state = bridge().lock().unwrap();
        state.web_send_event_tx = Some(web_send_event_tx);
        *state.web_send_files.lock().unwrap() = file_paths;
    }

    // Restart server with WebConfig (await directly — we are already in async context)
    crate::bridge::server_facade::start_server(
        port,
        use_https,
        verify_checksums,
        current_pin,
        Some(web_config),
    )
    .await?;

    // Spawn the WebSendEvent handler task
    crate::bridge::server_facade::spawn_web_send_event_task(web_send_event_rx, callback.clone());

    // Get the actual port and IP from the restarted server
    let (actual_port, local_ip) = {
        let state = bridge().lock().unwrap();
        let port = state.local_port;
        // Get the first non-loopback IP from server handle
        let ip = state
            .server_handle
            .as_ref()
            .and_then(|h| {
                h.local_addresses()
                    .iter()
                    .find(|a| !a.ip().is_loopback())
                    .map(|a| a.ip().to_string())
            })
            .unwrap_or_else(|| "0.0.0.0".to_string());
        (port, ip)
    };

    // Build the share URL
    let protocol = if use_https { "https" } else { "http" };
    let url = if local_ip == "0.0.0.0" {
        // Fallback: just use the port
        format!("{}://0.0.0.0:{}", protocol, actual_port)
    } else {
        format!("{}://{}:{}", protocol, local_ip, actual_port)
    };

    // Store ShareLinkState
    let session_id = format!("web_send_{}", std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis());
    {
        let mut state = bridge().lock().unwrap();
        *state.share_link_info.lock().unwrap() = Some(crate::bridge::state::ShareLinkState {
            url: url.clone(),
            port: actual_port,
            session_id: session_id.clone(),
        });
    }

    Ok(json!({
        "url": url,
        "port": actual_port,
        "sessionId": session_id,
    })
    .to_string())
}

pub async fn stop_share_server() {
    // Stop the current server and take the handle for graceful shutdown
    let wait_stopped_fut = {
        let mut state = bridge().lock().unwrap();
        // Send stop signal
        if let Some(stop_tx) = state.server_stop_tx.take() {
            let _ = stop_tx.send(());
        }
        let handle = state.server_handle.take();
        // Clear web send state
        state.web_send_event_tx.take();
        state.web_send_files.lock().unwrap().clear();
        state.web_download_decisions.clear();
        state.pending_file_uploads.clear();
        state.pending_file_downloads.clear();
        *state.share_link_info.lock().unwrap() = None;
        handle
    };

    // Get state values needed for restart
    let (port, use_https, verify_checksums, current_pin) = {
        let state = bridge().lock().unwrap();
        (state.local_port, state.use_https, true, state.receive_pin.clone())
    };

    // Wait for the server task to complete (port released) instead of fixed sleep
    if let Some(handle) = wait_stopped_fut {
        handle.wait_stopped().await;
    }

    // Restart server in normal mode (no WebConfig)
    let _ = crate::bridge::server_facade::start_server(
        port,
        use_https,
        verify_checksums,
        current_pin,
        None, // No web config → normal mode
    )
    .await;
}

pub fn get_recv_diag() -> String {
    let state = bridge().lock().unwrap();
    let drain_count = *state.recv_diag_drain_count.lock().unwrap();
    let queued_events = {
        let log = state.debug_log.lock().unwrap();
        log.len() as u64
    };
    drop(state);

    json!({
        "drainCount": drain_count,
        "queuedEvents": queued_events,
    })
    .to_string()
}

pub fn clear_completed_send_progress() {
    let state = bridge().lock().unwrap();
    let mut map = state.send_progress.lock().unwrap();
    let completed: Vec<String> = map
        .iter()
        .filter(|(_, v)| v.bytes_sent >= v.total_bytes)
        .map(|(k, _)| k.clone())
        .collect();
    for k in completed {
        map.remove(&k);
    }
}

pub fn clear_completed_recv_progress() {
    let state = bridge().lock().unwrap();
    let mut map = state.recv_progress.lock().unwrap();
    let completed: Vec<String> = map
        .iter()
        .filter(|(_, v)| v.bytes_sent >= v.total_bytes)
        .map(|(k, _)| k.clone())
        .collect();
    for k in completed {
        map.remove(&k);
    }
}

/// Build WebI18n with Chinese translations for web share pages.
pub fn build_web_i18n() -> WebI18n {
    WebI18n {
        waiting: "等待响应…".to_string(),
        enter_pin: "输入PIN".to_string(),
        invalid_pin: "PIN错误".to_string(),
        too_many_attempts: "尝试次数过多".to_string(),
        rejected: "已拒绝".to_string(),
        upload_rejected: "接收方已拒绝请求。".to_string(),
        busy: "接收方正忙。".to_string(),
        files: "文件".to_string(),
        file_name: "文件名".to_string(),
        size: "大小".to_string(),
    }
}
