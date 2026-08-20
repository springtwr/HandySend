//! Client facade — handles all client-side operations (send, upload, register, cancel).
//!
//! Extracted from facade.rs to keep the facade modules focused.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Result;
use futures_util::StreamExt;
use serde_json::{json, Value};
use tokio::io::AsyncWriteExt;

use localsend::crypto;
use localsend::http::client::{LsHttpClient, LsHttpClientVersion, LsHttpClientV2, ClientError};
use localsend::http::dto::{PrepareUploadRequestDto, RegisterDto};
use localsend::model::discovery::{DeviceType, ProtocolType, PROTOCOL_VERSION_V2};
use localsend::model::transfer::{FileContent, FileDto};

use crate::bridge::facade::{current_protocol, parse_protocol_helper};
use crate::bridge::state::{bridge, ProgressEntry};

fn client_error_to_json(e: &ClientError) -> Value {
    match e {
        ClientError::StatusCode(se) => json!({
            "kind": "statusCode",
            "status": se.status,
            "message": se.message,
        }),
        ClientError::Reqwest(re) => json!({
            "kind": "reqwest",
            "message": format!("{re:#}"),
        }),
        ClientError::Json(je) => json!({
            "kind": "json",
            "message": je.to_string(),
        }),
        ClientError::Io(ie) => json!({
            "kind": "io",
            "message": ie.to_string(),
        }),
        ClientError::Other(ae) => json!({
            "kind": "other",
            "message": format!("{ae:#}"),
        }),
        ClientError::Cancelled => json!({
            "kind": "cancelled",
            "message": "Operation cancelled",
        }),
    }
}

// ── Send Operations ──────────────────────────────────────────────────────────

pub async fn prepare_send(
    target_ip: &str,
    target_port: u16,
    target_protocol: ProtocolType,
    files_json: &str,
    pin: Option<String>,
    expected_fingerprint: Option<String>,
    public_key: Option<String>,
) -> Result<String> {
    log::info!("[DBG-SEND] prepare_send: ip={} port={} proto={:?} has_fp={} has_pk={}",
        target_ip, target_port, target_protocol,
        expected_fingerprint.is_some(), public_key.is_some());
    let (alias, device_type, device_model, fingerprint, cert_pem, key_pem) = {
        let state = bridge().lock().unwrap();
        (
            state.local_alias.clone(),
            state.device_type.clone(),
            state.device_model.clone(),
            state.fingerprint.clone(),
            state.cert_pem.clone(),
            state.key_pem.clone(),
        )
    };
    log::info!("[DBG-SEND]   cert_pem.len={} key_pem.len={} local_fp={}",
        cert_pem.len(), key_pem.len(), fingerprint.chars().take(8).collect::<String>());

    let files: Vec<FileDto> = serde_json::from_str(files_json)?;
    let files_map: HashMap<String, FileDto> = files
        .into_iter()
        .map(|f| (f.id.clone(), f))
        .collect();
    log::info!("[DBG-SEND]   files_count={}", files_map.len());

    let payload = PrepareUploadRequestDto {
        info: RegisterDto {
            alias: alias.clone(),
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: Some(device_model),
            device_type: Some(device_type),
            token: fingerprint.clone(),
            port: target_port,
            protocol: current_protocol(),
            has_web_interface: false,
        },
        files: files_map,
    };
    log::info!("[DBG-SEND]   payload.info.protocol={:?}", payload.info.protocol);

    let client = LsHttpClient::new(
        &key_pem,
        &cert_pem,
        LsHttpClientVersion::V2,
        expected_fingerprint,
        Some(Duration::from_secs(10)),
    )?;
    log::info!("[DBG-SEND]   LsHttpClient created OK");

    let cancel = tokio_util::sync::CancellationToken::new();

    let temp_key = format!("prepare_{}", target_ip);
    {
        let mut state = bridge().lock().unwrap();
        state.active_transfers.insert(temp_key.clone(), cancel.clone());
    }

    let result = client
        .prepare_upload(
            target_protocol,
            target_ip,
            target_port,
            public_key,
            payload,
            pin.as_deref(),
            cancel,
        )
        .await;

    // Always clean up the prepare_ temp key (success or error)
    {
        let mut state = bridge().lock().unwrap();
        state.active_transfers.remove(&temp_key);
    }

    let result = result.map_err(|e| {
        log::error!("[DBG-SEND]   prepare_upload FAILED: {e:#}");
        // Use Error::from to preserve the original ClientError type,
        // so that downcast_ref in send_files can recover it for structured error reporting.
        anyhow::Error::from(e)
    })?;

    log::info!("[DBG-SEND]   prepare_upload OK: status={}", result.status_code);

    match result.response {
        Some(resp) => {
            let session_cancel = tokio_util::sync::CancellationToken::new();
            {
                let mut state = bridge().lock().unwrap();
                state.active_transfers.insert(resp.session_id.clone(), session_cancel);
            }

            Ok(json!({
                "sessionId": resp.session_id,
                "files": resp.files,
                "statusCode": result.status_code,
            })
            .to_string())
        }
        None => Ok(json!({
            "statusCode": result.status_code,
        })
        .to_string()),
    }
}

pub async fn upload_file(
    target_ip: &str,
    target_port: u16,
    target_protocol: ProtocolType,
    session_id: &str,
    file_id: &str,
    token: &str,
    file_path: &str,
    expected_fingerprint: Option<String>,
    public_key: Option<String>,
    cancel_id: Option<String>,
) -> Result<()> {
    log::info!("[DBG-UPLOAD] upload_file: ip={} port={} proto={:?} session={} file_id={} path={}",
        target_ip, target_port, target_protocol, session_id, file_id, file_path);
    let (cert_pem, key_pem, send_progress, current_send_session_id, callback) = {
        let state = bridge().lock().unwrap();
        (
            state.cert_pem.clone(),
            state.key_pem.clone(),
            state.send_progress.clone(),
            state.current_send_session_id.clone(),
            state.callback.clone(),
        )
    };

    {
        let mut sid = current_send_session_id.lock().unwrap();
        *sid = session_id.to_string();
    }

    let client = LsHttpClient::new(
        &key_pem,
        &cert_pem,
        LsHttpClientVersion::V2,
        expected_fingerprint,
        Some(Duration::from_secs(300)),
    )?;

    let file_meta = std::fs::metadata(file_path);
    let total_bytes = file_meta.map(|m| m.len()).unwrap_or(0);

    let content = FileContent::Path(std::path::PathBuf::from(file_path));
    let cancel = match cancel_id {
        Some(id) => {
            let state = bridge().lock().unwrap();
            match state.cancel_tokens.get(&id) {
                Some(t) => t.clone(),
                None => tokio_util::sync::CancellationToken::new(),
            }
        }
        None => tokio_util::sync::CancellationToken::new(),
    };

    {
        let mut state = bridge().lock().unwrap();
        state.active_transfers.insert(session_id.to_string(), cancel.clone());
    }

    let sp = send_progress.clone();
    let sid = session_id.to_string();
    let fid = file_id.to_string();
    let fp = file_path.to_string();
    let total = total_bytes;
    let last_update = Arc::new(std::sync::Mutex::new(Instant::now()));
    let cb_progress = callback.clone();

    let progress = move |sent: u64| {
        let should_update = {
            let mut last = last_update.lock().unwrap();
            let now = Instant::now();
            if now.duration_since(*last) >= Duration::from_millis(20) {
                *last = now;
                true
            } else {
                false
            }
        };
        if should_update || sent >= total {
            let mut map = sp.lock().unwrap();
            let key = format!("{}:{}", sid, fid);
            map.insert(
                key,
                ProgressEntry {
                    session_id: sid.clone(),
                    file_id: fid.clone(),
                    bytes_sent: sent,
                    total_bytes: total,
                    file_path: fp.clone(),
                },
            );
            drop(map);
            // Push progress_update event via callback
            if let Some(ref cb) = cb_progress {
                let payload = json!({
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
        .upload(
            target_protocol,
            target_ip,
            target_port,
            public_key,
            session_id,
            file_id,
            token,
            content,
            progress,
            cancel,
        )
        .await;

    // Clean up active transfer entry after completion
    {
        let mut state = bridge().lock().unwrap();
        state.active_transfers.remove(session_id);
    }

    match _result {
        Ok(_) => {
            {
                let mut map = send_progress.lock().unwrap();
                let key = format!("{}:{}", session_id, file_id);
                map.insert(
                    key,
                    ProgressEntry {
                        session_id: session_id.to_string(),
                        file_id: file_id.to_string(),
                        bytes_sent: total_bytes,
                        total_bytes: total_bytes,
                        file_path: file_path.to_string(),
                    },
                );
                drop(map);
                // Push final progress_update event (100% complete, upload finished)
                if let Some(ref cb) = callback {
                    let payload = json!({
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
            }

            // Push upload_finished event
            if let Some(ref cb) = callback {
                let payload = json!({
                    "type": "upload_finished",
                    "sessionId": session_id,
                    "fileId": file_id,
                });
                cb.call(payload.to_string());
            }

            Ok(())
        }
        Err(e) => {
            let err_msg = format!("{e}");

            // Push upload_failed event
            if let Some(ref cb) = callback {
                let payload = json!({
                    "type": "upload_failed",
                    "sessionId": session_id,
                    "fileId": file_id,
                    "error": err_msg,
                });
                cb.call(payload.to_string());
            }

            Err(anyhow::anyhow!("{e}"))
        }
    }
}

pub fn cancel_transfer(session_id: &str) {
    let mut state = bridge().lock().unwrap();
    if let Some(cancel) = state.active_transfers.remove(session_id) {
        cancel.cancel();
    }
}

// ── High-level API ──────────────────────────────────────────────────────────

pub async fn send_files(
    target_json: &str,
    _sender_alias: &str,
    files_json: &str,
) -> Result<String> {
    log::info!("[DBG-SEND-FILES] send_files: target_json={} files_count={}",
        target_json.chars().take(100).collect::<String>(),
        serde_json::from_str::<Vec<Value>>(files_json).map(|v| v.len()).unwrap_or(0));
    let target: Value = serde_json::from_str(target_json)?;
    let target_ip = target["ip"].as_str().unwrap_or("").to_string();
    let target_port = target["port"].as_u64().unwrap_or(53317) as u16;
    let target_protocol = parse_protocol_helper(target["protocol"].as_str().unwrap_or("https"));
    let target_fingerprint = target["fingerprint"].as_str()
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string());

    let files: Vec<Value> = serde_json::from_str(files_json)?;

    let files_for_prepare: Vec<FileDto> = files
        .iter()
        .map(|f| FileDto {
            id: f["fileId"].as_str().unwrap_or("").to_string(),
            file_name: f["fileName"].as_str().unwrap_or("").to_string(),
            size: f["size"].as_u64().unwrap_or(0),
            file_type: f["fileType"].as_str().unwrap_or("").to_string(),
            sha256: f["sha256"].as_str().map(|s| s.to_string()),
            preview: f["preview"].as_str().map(|s| s.to_string()),
            metadata: None,
        })
        .collect();

    let files_json_str = serde_json::to_string(&files_for_prepare)?;

    let pin = target["pin"].as_str().map(|s| s.to_string());
    let target_public_key = target["publicKey"].as_str()
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string());

    let prepare_result = match prepare_send(&target_ip, target_port, target_protocol, &files_json_str, pin, target_fingerprint.clone(), target_public_key.clone()).await {
        Ok(r) => r,
        Err(e) => {
            let error_json = if let Some(ce) = e.downcast_ref::<ClientError>() {
                client_error_to_json(ce)
            } else {
                json!({
                    "kind": "other",
                    "message": format!("{e:#}"),
                })
            };
            return Ok(json!({
                "sessionId": "",
                "success": false,
                "failedFiles": [],
                "error": error_json,
            }).to_string());
        }
    };
    let prepare_data: Value = serde_json::from_str(&prepare_result)?;

    let session_id = prepare_data["sessionId"]
        .as_str()
        .unwrap_or("")
        .to_string();
    let file_tokens = &prepare_data["files"];

    let current_send_session_id = {
        let state = bridge().lock().unwrap();
        state.current_send_session_id.clone()
    };
    {
        let mut sid = current_send_session_id.lock().unwrap();
        *sid = session_id.clone();
    }

    let mut failed_files: Vec<String> = Vec::new();

    for file in &files {
        let file_id = file["fileId"].as_str().unwrap_or("");
        let file_path = file["filePath"].as_str().unwrap_or("");

        let token = match file_tokens.get(file_id) {
            Some(t) => t.as_str().unwrap_or("").to_string(),
            None => {
                failed_files.push(file_id.to_string());
                continue;
            }
        };

        match upload_file(&target_ip, target_port, target_protocol, &session_id, file_id, &token, file_path, target_fingerprint.clone(), target_public_key.clone(), None).await {
            Ok(()) => {}
            Err(e) => {
                log::warn!("Upload failed for file {}: {e:#}", file_id);
                failed_files.push(file_id.to_string());
            }
        }
    }

    let success = failed_files.is_empty();
    let error_json = if success { Value::Null } else {
        json!({
            "kind": "partialFailure",
            "message": format!("{} of {} files failed", failed_files.len(), files.len()),
        })
    };

    Ok(json!({
        "sessionId": session_id,
        "success": success,
        "failedFiles": failed_files,
        "error": error_json,
    })
    .to_string())
}

// ── Remote Cancel ────────────────────────────────────────────────────────────

pub async fn cancel_transfer_remote(target_json: &str, session_id: &str) -> Result<()> {
    let target: Value = serde_json::from_str(target_json)?;
    let target_ip = target["ip"].as_str().unwrap_or("").to_string();
    let target_port = target["port"].as_u64().unwrap_or(53317) as u16;
    let target_protocol = parse_protocol_helper(target["protocol"].as_str().unwrap_or("https"));

    let (cert_pem, key_pem) = {
        let state = bridge().lock().unwrap();
        (state.cert_pem.clone(), state.key_pem.clone())
    };

    let client = LsHttpClient::new(
        &key_pem,
        &cert_pem,
        LsHttpClientVersion::V2,
        None,
        Some(Duration::from_secs(5)),
    )?;

    client
        .cancel(target_protocol, &target_ip, target_port, session_id)
        .await
        .map_err(|e| anyhow::anyhow!("{e}"))?;

    Ok(())
}

// ── Discovery Register (mTLS-capable) ────────────────────────────────────────

/// Register this device with a remote device via HTTP/HTTPS.
///
/// This is the Rust-side equivalent of the ArkTS `tryTcpRegister` / `scanSubnetOnInterface`
/// register calls, but with proper mTLS support. The ArkTS HTTP client cannot provide
/// client certificates, so all HTTPS register requests must go through this function.
///
/// Tries both HTTPS and HTTP protocols (order determined by `our_protocol` preference).
/// Returns JSON with the remote device's info on success, or an error string on failure.
pub async fn register_device(
    target_ip: &str,
    target_port: u16,
    our_alias: &str,
    our_fingerprint: &str,
    our_protocol: &str,
    our_device_model: &str,
    our_device_type: &str,
    our_port: u16,
    our_ip: &str,
) -> Result<String> {
    let (cert_pem, key_pem, fingerprint) = {
        let state = bridge().lock().unwrap();
        (
            state.cert_pem.clone(),
            state.key_pem.clone(),
            state.fingerprint.clone(),
        )
    };

    let protocol_enum = parse_protocol_helper(our_protocol);

    // Build the register payload
    let payload = RegisterDto {
        alias: our_alias.to_string(),
        version: PROTOCOL_VERSION_V2.to_string(),
        device_model: if our_device_model.is_empty() {
            None
        } else {
            Some(our_device_model.to_string())
        },
        device_type: Some(crate::bridge::facade::parse_device_type(our_device_type)),
        token: our_fingerprint.to_string(),
        port: our_port,
        protocol: protocol_enum,
        has_web_interface: false,
    };

    // Try protocols: prefer our_protocol first, then fallback to the other
    let protocols_to_try: Vec<ProtocolType> = match protocol_enum {
        ProtocolType::Https => vec![ProtocolType::Https, ProtocolType::Http],
        ProtocolType::Http => vec![ProtocolType::Http, ProtocolType::Https],
    };

    // Create the client once — it's protocol-agnostic and can handle both HTTP and HTTPS
    let client = match LsHttpClient::new(
        &key_pem,
        &cert_pem,
        LsHttpClientVersion::V2,
        None, // Don't pin expected fingerprint for discovery/register
        Some(Duration::from_secs(5)),
    ) {
        Ok(c) => c,
        Err(e) => return Err(anyhow::anyhow!("Client creation failed: {e:#}")),
    };

    let mut last_error = String::from("No protocol attempted");

    for proto in &protocols_to_try {
        match client.register(*proto, target_ip, target_port, payload.clone()).await {
            Ok(result) => {
                let resp = result.body;
                let resp_protocol = proto.as_str();
                let cert_fp = result.cert_fingerprint.unwrap_or_default();
                let pub_key = result.public_key.unwrap_or_default();
                let ret = json!({
                    "alias": resp.alias,
                    "version": resp.version,
                    "deviceModel": resp.device_model.unwrap_or_default(),
                    "deviceType": format!("{:?}", resp.device_type.unwrap_or(DeviceType::Desktop)).to_lowercase(),
                    "fingerprint": resp.token,
                    "protocol": resp_protocol,
                    "certFingerprint": cert_fp,
                    "publicKey": pub_key,
                });
                log::info!(
                    "Register OK: {} at {}:{} via {} (cert_fp={})",
                    resp.alias, target_ip, target_port, resp_protocol,
                    if cert_fp.is_empty() { "N/A" } else { &cert_fp[..10.min(cert_fp.len())] }
                );
                return Ok(ret.to_string());
            }
            Err(e) => {
                last_error = format!("{proto:?} register to {target_ip}:{target_port} failed: {e:#}");
                log::debug!("{}", last_error);
                continue;
            }
        }
    }

    Err(anyhow::anyhow!("Register failed to {target_ip}:{target_port}: {last_error}"))
}

// ── Client Info ──────────────────────────────────────────────────────────────

/// Get device info from a remote device via HTTP/HTTPS.
/// Calls GET /api/localsend/v2/info on the target.
pub async fn client_info(
    protocol: ProtocolType,
    ip: &str,
    port: u16,
) -> Result<String> {
    let (cert_pem, key_pem) = {
        let state = bridge().lock().unwrap();
        (state.cert_pem.clone(), state.key_pem.clone())
    };

    let client = LsHttpClientV2::try_new(
        &key_pem,
        &cert_pem,
        None,
        Some(Duration::from_secs(5)),
    )?;

    let resp = client
        .info(protocol, ip, port)
        .await
        .map_err(|e| anyhow::anyhow!("Client info failed: {e:#}"))?;

    let ret = json!({
        "alias": resp.alias,
        "version": resp.version,
        "deviceModel": resp.device_model.unwrap_or_default(),
        "deviceType": resp.device_type.as_ref().map(|dt| crate::bridge::facade::device_type_to_string(dt)).unwrap_or("desktop"),
        "fingerprint": resp.fingerprint,
        "download": resp.download,
        "protocol": protocol.as_str(),
    });
    Ok(ret.to_string())
}

// ── Download API ────────────────────────────────────────────────────────────

/// Prepare a download session from a remote device (Download API).
/// Calls POST /api/localsend/v2/prepare-download.
/// Returns JSON with sender info, sessionId, and files map.
pub async fn prepare_download(
    target_ip: &str,
    target_port: u16,
    target_protocol: ProtocolType,
    session_id: Option<String>,
    pin: Option<String>,
) -> Result<String> {
    let (cert_pem, key_pem) = {
        let state = bridge().lock().unwrap();
        (state.cert_pem.clone(), state.key_pem.clone())
    };

    let client = LsHttpClientV2::try_new(
        &key_pem,
        &cert_pem,
        None,
        Some(Duration::from_secs(10)),
    )?;

    let resp = client
        .prepare_download(
            target_protocol,
            target_ip,
            target_port,
            session_id.as_deref(),
            pin.as_deref(),
        )
        .await
        .map_err(|e| anyhow::anyhow!("Prepare download failed: {e:#}"))?;

    let ret = json!({
        "info": {
            "alias": resp.info.alias,
            "version": resp.info.version,
            "deviceModel": resp.info.device_model.unwrap_or_default(),
            "deviceType": resp.info.device_type.as_ref().map(|dt| crate::bridge::facade::device_type_to_string(dt)).unwrap_or("desktop"),
            "fingerprint": resp.info.fingerprint,
            "download": resp.info.download,
        },
        "sessionId": resp.session_id,
        "files": resp.files,
    });
    Ok(ret.to_string())
}

/// Download a file from a remote device to a local path (Download API).
/// Calls GET /api/localsend/v2/download?sessionId=...&fileId=...
/// Streams the response body to the specified file path.
/// Uses Content-Length header for totalBytes in progress callbacks.
pub async fn download_file(
    target_ip: &str,
    target_port: u16,
    target_protocol: ProtocolType,
    session_id: &str,
    file_id: &str,
    save_path: &str,
    public_key: Option<String>,
) -> Result<u64> {
    let (cert_pem, key_pem, callback) = {
        let state = bridge().lock().unwrap();
        (
            state.cert_pem.clone(),
            state.key_pem.clone(),
            state.callback.clone(),
        )
    };

    let client = LsHttpClientV2::try_new(
        &key_pem,
        &cert_pem,
        None,
        Some(Duration::from_secs(300)),
    )?;

    // Get the response first to extract Content-Length
    let response = client
        .download(target_protocol, target_ip, target_port, session_id, file_id)
        .await
        .map_err(|e| anyhow::anyhow!("Download request failed: {e:#}"))?;

    // Extract Content-Length for progress reporting
    let total_bytes_from_header = response
        .headers()
        .get(localsend::reqwest::header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(0);

    let file = tokio::fs::File::create(save_path).await
        .map_err(|e| anyhow::anyhow!("Failed to create file {}: {e:#}", save_path))?;
    let mut writer = tokio::io::BufWriter::new(file);

    let sp = bridge().lock().unwrap().send_progress.clone();
    let sid = session_id.to_string();
    let fid = file_id.to_string();
    let fp = save_path.to_string();
    let last_update = Arc::new(std::sync::Mutex::new(Instant::now()));
    let cb_progress = callback.clone();
    let total_bytes = total_bytes_from_header;

    let progress = move |received: u64, total: u64| {
        let should_update = {
            let mut last = last_update.lock().unwrap();
            let now = Instant::now();
            if now.duration_since(*last) >= Duration::from_millis(20) {
                *last = now;
                true
            } else {
                false
            }
        };
        if should_update || received >= total {
            if let Some(ref cb) = cb_progress {
                let payload = json!({
                    "type": "progress_update",
                    "direction": "recv",
                    "sessionId": sid,
                    "fileId": fid,
                    "bytesSent": received,
                    "totalBytes": total,
                    "filePath": fp,
                });
                cb.call(payload.to_string());
            }
        }
    };

    // Stream the response body manually to track progress
    let mut stream = response.bytes_stream();
    let mut bytes_written: u64 = 0;

    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| anyhow::anyhow!("Download stream error: {e:#}"))?;
        writer.write_all(&chunk).await
            .map_err(|e| anyhow::anyhow!("Download write error: {e:#}"))?;
        bytes_written += chunk.len() as u64;
        progress(bytes_written, total_bytes);
    }

    writer.flush().await
        .map_err(|e| anyhow::anyhow!("Download flush error: {e:#}"))?;

    // Final progress event with actual total
    let final_total = if total_bytes > 0 { total_bytes } else { bytes_written };
    if let Some(ref cb) = callback {
        let payload = json!({
            "type": "progress_update",
            "direction": "recv",
            "sessionId": session_id,
            "fileId": file_id,
            "bytesSent": bytes_written,
            "totalBytes": final_total,
            "filePath": save_path,
        });
        cb.call(payload.to_string());
    }

    log::info!("Downloaded: {file_id} -> {save_path} ({bytes_written} bytes)");
    Ok(bytes_written)
}

// ── Buffer Upload ───────────────────────────────────────────────────────────

/// Upload file content from an in-memory buffer.
/// Creates a single-chunk stream from the buffer data.
pub async fn upload_from_buffer(
    target_ip: &str,
    target_port: u16,
    target_protocol: ProtocolType,
    session_id: &str,
    file_id: &str,
    token: &str,
    buffer: Vec<u8>,
    public_key: Option<String>,
    cancel_id: Option<String>,
) -> Result<()> {
    let (cert_pem, key_pem, send_progress, current_send_session_id, callback) = {
        let state = bridge().lock().unwrap();
        (
            state.cert_pem.clone(),
            state.key_pem.clone(),
            state.send_progress.clone(),
            state.current_send_session_id.clone(),
            state.callback.clone(),
        )
    };

    {
        let mut sid = current_send_session_id.lock().unwrap();
        *sid = session_id.to_string();
    }

    let client = LsHttpClient::new(
        &key_pem,
        &cert_pem,
        LsHttpClientVersion::V2,
        None,
        Some(Duration::from_secs(300)),
    )?;

    let total_bytes = buffer.len() as u64;
    let (tx, rx) = tokio::sync::mpsc::channel(1);
    tx.send(bytes::Bytes::from(buffer)).await
        .map_err(|e| anyhow::anyhow!("Failed to send buffer to stream: {e:#}"))?;
    drop(tx);

    let content = FileContent::Stream(rx);

    let cancel = match cancel_id {
        Some(id) => {
            let state = bridge().lock().unwrap();
            match state.cancel_tokens.get(&id) {
                Some(t) => t.clone(),
                None => tokio_util::sync::CancellationToken::new(),
            }
        }
        None => tokio_util::sync::CancellationToken::new(),
    };

    {
        let mut state = bridge().lock().unwrap();
        state.active_transfers.insert(session_id.to_string(), cancel.clone());
    }

    let sp = send_progress.clone();
    let sid = session_id.to_string();
    let fid = file_id.to_string();
    let fp = format!("buffer:{}", file_id);
    let total = total_bytes;
    let last_update = Arc::new(std::sync::Mutex::new(Instant::now()));
    let cb_progress = callback.clone();

    let progress = move |sent: u64| {
        let should_update = {
            let mut last = last_update.lock().unwrap();
            let now = Instant::now();
            if now.duration_since(*last) >= Duration::from_millis(20) {
                *last = now;
                true
            } else {
                false
            }
        };
        if should_update || sent >= total {
            let mut map = sp.lock().unwrap();
            let key = format!("{}:{}", sid, fid);
            map.insert(
                key,
                ProgressEntry {
                    session_id: sid.clone(),
                    file_id: fid.clone(),
                    bytes_sent: sent,
                    total_bytes: total,
                    file_path: fp.clone(),
                },
            );
            drop(map);
            if let Some(ref cb) = cb_progress {
                let payload = json!({
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

    let _public_key = public_key;
    let _result = client
        .upload(
            target_protocol,
            target_ip,
            target_port,
            None,
            session_id,
            file_id,
            token,
            content,
            progress,
            cancel,
        )
        .await;

    {
        let mut state = bridge().lock().unwrap();
        state.active_transfers.remove(session_id);
    }

    match _result {
        Ok(_) => {
            {
                let mut map = send_progress.lock().unwrap();
                let key = format!("{}:{}", session_id, file_id);
                map.insert(
                    key,
                    ProgressEntry {
                        session_id: session_id.to_string(),
                        file_id: file_id.to_string(),
                        bytes_sent: total_bytes,
                        total_bytes: total_bytes,
                        file_path: format!("buffer:{}", file_id),
                    },
                );
                drop(map);
                // Push final progress_update event (100% complete)
                if let Some(ref cb) = callback {
                    let payload = json!({
                        "type": "progress_update",
                        "direction": "send",
                        "sessionId": session_id,
                        "fileId": file_id,
                        "bytesSent": total_bytes,
                        "totalBytes": total_bytes,
                        "filePath": format!("buffer:{}", file_id),
                    });
                    cb.call(payload.to_string());
                }
            }

            // Push upload_finished event
            if let Some(ref cb) = callback {
                let payload = json!({
                    "type": "upload_finished",
                    "sessionId": session_id,
                    "fileId": file_id,
                });
                cb.call(payload.to_string());
            }

            log::info!("Buffer uploaded: {} -> {}", file_id, session_id);
            Ok(())
        }
        Err(e) => {
            let err_msg = format!("{e:#}");

            // Push upload_failed event (consistent with upload_file behavior)
            if let Some(ref cb) = callback {
                let payload = json!({
                    "type": "upload_failed",
                    "sessionId": session_id,
                    "fileId": file_id,
                    "error": err_msg,
                });
                cb.call(payload.to_string());
            }

            Err(anyhow::anyhow!("Buffer upload failed: {e:#}"))
        }
    }
}
