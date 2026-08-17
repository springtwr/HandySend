//! Server facade — handles all server-related logic.
//!
//! Extracted from facade.rs to keep the facade modules focused:
//! - facade.rs: public utilities (init, parse helpers, crypto, etc.)
//! - server_facade.rs: HTTP server lifecycle and event handling
//! - client_facade.rs: HTTP client operations
//! - discovery_facade.rs: UDP multicast discovery

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Result;
use serde_json::{json, Value};

use localsend::crypto;
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2};
use localsend::http::server::{self, ServerConfigV2, TlsConfig};
use localsend::http::server::internal::{InternalConfig, InternalEvent};
use localsend::http::server::web::{WebConfig, WebSendConfig, WebSendEvent, WebI18n};
use localsend::http::state::ClientInfo;
use localsend::model::discovery::{DeviceType, ProtocolType, PROTOCOL_VERSION_V2};
use localsend::model::transfer::FileContent;

use crate::bridge::facade::{current_protocol, device_type_to_string, server_event_to_json};
use crate::bridge::state::{bridge, PendingFile, PendingRequest, ProgressEntry};

// ── Server Lifecycle ─────────────────────────────────────────────────────────

pub async fn start_server(
    port: u16,
    use_https: bool,
    verify_checksums: bool,
    pin: Option<String>,
    mut web_config: Option<WebConfig>,
) -> Result<()> {
    start_server_with_show_token(port, use_https, verify_checksums, pin, web_config, None).await
}

pub async fn start_server_with_show_token(
    port: u16,
    use_https: bool,
    verify_checksums: bool,
    pin: Option<String>,
    mut web_config: Option<WebConfig>,
    external_show_token: Option<String>,
) -> Result<()> {
    log::info!("[DBG-SRV] start_server: port={} use_https={} has_web_config={} has_pin={}",
        port, use_https, web_config.is_some(), pin.is_some());
    let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<ServerEventV2>(64);
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();

    // Show token for InternalConfig (stable across retries)
    // Use externally provided token if available, otherwise generate one
    let show_token = external_show_token.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());

    // Store the show_token so it can be retrieved later
    {
        let mut state = bridge().lock().unwrap();
        state.show_token = Some(show_token.clone());
    }

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

    // Attempt to start the server, retrying once if the port is still in use
    // Note: web_config cannot be Clone (contains mpsc::Sender), so retry only
    // happens when no web_config is present (normal mode).
    let mut current_stop_tx = stop_tx;
    let mut current_stop_rx = stop_rx;
    let mut handle: Option<server::ServerHandle> = None;

    // We need the internal event receiver outside the loop
    let mut internal_event_rx_option: Option<tokio::sync::mpsc::Receiver<InternalEvent>> = None;

    let max_attempts = if web_config.is_some() { 1 } else { 2 };

    for attempt in 0..max_attempts {
        // Build v2_config fresh each attempt (ServerConfigV2 is not Clone)
        let cfg = ServerConfigV2 {
            pin: pin.clone(),
            verify_checksums,
            event_tx: event_tx.clone(),
        };

        // Build internal_config fresh each attempt (InternalConfig is not Clone)
        let (internal_event_tx, internal_event_rx) = tokio::sync::mpsc::channel::<InternalEvent>(16);
        if attempt == 0 {
            internal_event_rx_option = Some(internal_event_rx);
        }
        let internal_config = InternalConfig {
            show_token: show_token.clone(),
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
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: Some(device_model.clone()),
            device_type: Some(device_type.clone()),
            token: fingerprint.clone(),
        };

        match server::start_with_port(
            port,
            tls,
            info,
            Some(internal_config),
            Some(cfg),
            web_config.take(),
            current_stop_rx,
        )
        .await
        {
            Ok(h) => {
                handle = Some(h);
                break;
            }
            Err(e) => {
                let err_msg = format!("{e:#}");
                if attempt == 0 && (err_msg.contains("in use") || err_msg.contains("Address already") || err_msg.contains("EADDRINUSE")) {
                    log::warn!("Port {} still in use, waiting 500ms and retrying...", port);
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    let (retry_tx, retry_rx) = tokio::sync::oneshot::channel::<()>();
                    current_stop_tx = retry_tx;
                    current_stop_rx = retry_rx;
                } else {
                    return Err(e);
                }
            }
        }
    }

    let handle = handle.ok_or_else(|| anyhow::anyhow!("Server failed to start after retry"))?;

    let local_port = handle.local_addresses().first().map(|a| a.port()).unwrap_or(port);

    let callback = {
        let state = bridge().lock().unwrap();
        state.callback.clone()
    };
    // Clone callback for the InternalEvent listener (the original will be moved into the main event loop spawn)
    let internal_callback = callback.clone();

    let recv_progress = {
        let state = bridge().lock().unwrap();
        state.recv_progress.clone()
    };
    let pending_requests = {
        let state = bridge().lock().unwrap();
        state.pending_requests.clone()
    };
    let debug_log = {
        let state = bridge().lock().unwrap();
        state.debug_log.clone()
    };
    let recv_diag_drain_count = {
        let state = bridge().lock().unwrap();
        state.recv_diag_drain_count.clone()
    };

    tokio::spawn(async move {
        while let Some(event) = event_rx.recv().await {
            let json = match &event {
                ServerEventV2::PrepareUpload {
                    session_id,
                    ip,
                    info,
                    cert_fingerprint,
                    files,
                    decision_tx,
                    ..
                } => {
                    log::info!("[DBG-SRV-EVT] PrepareUpload: session={} ip={} alias={} files_count={} cert_fp={}",
                        session_id, ip, info.alias, files.len(),
                        cert_fingerprint.as_ref().map(|s| s.chars().take(8).collect::<String>()).unwrap_or_default());
                    let _ = decision_tx;
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

                    {
                        let protocol = if cert_fingerprint.is_some() && !cert_fingerprint.as_ref().map(|s| s.is_empty()).unwrap_or(true) {
                            "https"
                        } else {
                            "http"
                        };
                        let mut reqs = pending_requests.lock().unwrap();
                        reqs.push(PendingRequest {
                            session_id: session_id.clone(),
                            sender_alias: info.alias.clone(),
                            sender_fingerprint: cert_fingerprint.clone().unwrap_or_default(),
                            sender_protocol: protocol.to_string(),
                            files: files
                                .iter()
                                .map(|(id, f)| PendingFile {
                                    file_id: id.clone(),
                                    file_name: f.file_name.clone(),
                                    size: f.size,
                                    file_type: f.file_type.clone(),
                                    preview: f.preview.clone(),
                                    sha256: f.sha256.clone(),
                                })
                                .collect(),
                        });
                    }

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
                } => {
                    log::info!("[DBG-SRV-EVT] FileUpload: session={} file={} size={}", session_id, file_id, file.size);
                    json!({
                        "type": "file_upload",
                        "sessionId": session_id,
                        "fileId": file_id,
                        "file": {
                            "fileName": file.file_name,
                            "size": file.size,
                            "fileType": file.file_type,
                        },
                    })
                    .to_string()
                }
                other => server_event_to_json(other),
            };

            // Handle owned events that need move-out
            match event {
                ServerEventV2::PrepareUpload {
                    session_id,
                    decision_tx,
                    ..
                } => {
                    store_pending_decision(session_id, decision_tx);
                }
                ServerEventV2::FileUpload {
                    session_id,
                    file_id,
                    file,
                    target_tx,
                } => {
                    log::info!("[DBG-SRV-EVT] FileUpload: session={} file={} size={}", session_id, file_id, file.size);
                    let save_dir = {
                        let state = bridge().lock().unwrap();
                        state.save_dir.clone()
                    };
                    let save_path = format!("{}{}", save_dir, file.file_name);
                    log::info!("[DBG-SRV-EVT]   save_path={}", save_path);

                    // Auto-accept: build the upload target and send it directly
                    let (progress_tx, mut progress_rx) = tokio::sync::mpsc::channel::<u64>(16);

                    let fp = recv_progress.clone();
                    let sid = session_id.clone();
                    let fid = file_id.clone();
                    let total = file.size;
                    let fp_path = save_path.clone();
                    let last_update = Arc::new(std::sync::Mutex::new(Instant::now()));
                    let last_update_clone = last_update.clone();
                    let fp2 = fp.clone();
                    let cb_progress = callback.clone();

                    tokio::spawn(async move {
                        while let Some(bytes_written) = progress_rx.recv().await {
                            let should_update = {
                                let mut last = last_update_clone.lock().unwrap();
                                let now = Instant::now();
                                if now.duration_since(*last) >= Duration::from_millis(20) {
                                    *last = now;
                                    true
                                } else {
                                    false
                                }
                            };
                            if should_update {
                                let mut map = fp2.lock().unwrap();
                                let key = format!("{}:{}", sid, fid);
                                map.insert(
                                    key,
                                    ProgressEntry {
                                        session_id: sid.clone(),
                                        file_id: fid.clone(),
                                        bytes_sent: bytes_written,
                                        total_bytes: total,
                                        file_path: fp_path.clone(),
                                    },
                                );
                                drop(map);
                                if let Some(ref cb) = cb_progress {
                                    let payload = json!({
                                        "type": "progress_update",
                                        "direction": "recv",
                                        "sessionId": sid,
                                        "fileId": fid,
                                        "bytesSent": bytes_written,
                                        "totalBytes": total,
                                        "filePath": fp_path,
                                    });
                                    cb.call(payload.to_string());
                                }
                            }
                        }
                        {
                            let mut map = fp.lock().unwrap();
                            let key = format!("{}:{}", sid, fid);
                            map.insert(
                                key,
                                ProgressEntry {
                                    session_id: sid.clone(),
                                    file_id: fid.clone(),
                                    bytes_sent: total,
                                    total_bytes: total,
                                    file_path: fp_path.clone(),
                                },
                            );
                            drop(map);
                            if let Some(ref cb) = cb_progress {
                                let payload = json!({
                                    "type": "progress_update",
                                    "direction": "recv",
                                    "sessionId": sid,
                                    "fileId": fid,
                                    "bytesSent": total,
                                    "totalBytes": total,
                                    "filePath": fp_path,
                                });
                                cb.call(payload.to_string());
                            }
                        }
                    });

                    let (result_tx, result_rx) = tokio::sync::oneshot::channel();
                    let target = localsend::http::server::common::save::FileUploadTarget::Path {
                        path: std::path::PathBuf::from(&save_path),
                        result_tx,
                        progress_tx: Some(progress_tx),
                    };
                    let _ = target_tx.send(target);

                    let rp = recv_progress.clone();
                    let sid2 = session_id.clone();
                    let fid2 = file_id.clone();
                    let fp_path2 = save_path.clone();
                    let cb_result = callback.clone();
                    tokio::spawn(async move {
                        let _ = result_rx.await;
                        let mut map = rp.lock().unwrap();
                        let key = format!("{}:{}", sid2, fid2);
                        map.insert(
                            key,
                            ProgressEntry {
                                session_id: sid2.clone(),
                                file_id: fid2.clone(),
                                bytes_sent: total,
                                total_bytes: total,
                                file_path: fp_path2.clone(),
                            },
                        );
                        drop(map);
                        if let Some(ref cb) = cb_result {
                            let payload = json!({
                                "type": "progress_update",
                                "direction": "recv",
                                "sessionId": sid2,
                                "fileId": fid2,
                                "bytesSent": total,
                                "totalBytes": total,
                                "filePath": fp_path2,
                            });
                            cb.call(payload.to_string());
                        }
                    });

                    {
                        let mut log = debug_log.lock().unwrap();
                        log.push(format!(
                            "FileUpload: session={} file={} size={}",
                            session_id, file_id, file.size
                        ));
                    }
                    *recv_diag_drain_count.lock().unwrap() += 1;
                }
                _ => {}
            }

            if let Some(ref cb) = callback {
                cb.call(json);
            }
        }
    });

    // Spawn InternalEvent listener for Show events
    if let Some(mut internal_event_rx) = internal_event_rx_option {
        tokio::spawn(async move {
            while let Some(event) = internal_event_rx.recv().await {
                match event {
                    InternalEvent::Show { args } => {
                        if let Some(ref cb) = internal_callback {
                            let payload = json!({
                                "type": "show",
                                "args": args,
                            });
                            cb.call(payload.to_string());
                        }
                    }
                }
            }
        });
    }

    {
        let mut state = bridge().lock().unwrap();
        state.server_handle = Some(handle);
        state.server_stop_tx = Some(current_stop_tx);
        state.event_tx = Some(event_tx);
        state.local_port = local_port;
        state.use_https = use_https;
        state.receive_pin = pin.clone();
    }

    Ok(())
}

pub fn stop_server() {
    log::info!("[DBG-SRV] stop_server called");
    let mut state = bridge().lock().unwrap();
    // Send stop signal to the server task — triggers graceful shutdown
    if let Some(stop_tx) = state.server_stop_tx.take() {
        let _ = stop_tx.send(());
    }
    // Drop the handle — detaches the task but the stop signal already requested shutdown
    state.server_handle.take();
    state.event_tx.take();
    state.show_token.take();
    // Cancel and clear active transfers
    for (_key, cancel) in state.active_transfers.drain() {
        cancel.cancel();
    }
    // Clear pending state
    state.pending_requests.lock().unwrap().clear();
    state.pending_decisions.clear();
    state.recv_progress.lock().unwrap().clear();
    state.send_progress.lock().unwrap().clear();
    // Clear web send state
    state.web_send_event_tx.take();
    state.web_send_files.lock().unwrap().clear();
    state.web_download_decisions.clear();
    state.pending_file_uploads.clear();
    state.pending_file_downloads.clear();
}

// ── Accept / Decline ─────────────────────────────────────────────────────────

pub fn accept_transfer(session_id: &str, file_ids: &[String]) -> Result<()> {
    log::info!("[DBG-SRV] accept_transfer: session={} file_count={}", session_id, file_ids.len());
    let mut state = bridge().lock().unwrap();
    if let Some(sender) = state.pending_decisions.remove(session_id) {
        let file_set: std::collections::HashSet<String> = file_ids.iter().cloned().collect();
        let decision = PrepareUploadDecisionV2::Accept(file_set);
        let _ = sender.send(decision);

        let mut reqs = state.pending_requests.lock().unwrap();
        reqs.retain(|r| r.session_id != session_id);

        Ok(())
    } else {
        log::warn!("[DBG-SRV] accept_transfer: NO pending decision for session={}", session_id);
        Err(anyhow::anyhow!("No pending decision for session: {}", session_id))
    }
}

pub fn decline_transfer(session_id: &str) -> Result<()> {
    log::info!("[DBG-SRV] decline_transfer: session={}", session_id);
    let mut state = bridge().lock().unwrap();
    if let Some(sender) = state.pending_decisions.remove(session_id) {
        let decision = PrepareUploadDecisionV2::Decline;
        let _ = sender.send(decision);

        let mut reqs = state.pending_requests.lock().unwrap();
        reqs.retain(|r| r.session_id != session_id);

        Ok(())
    } else {
        log::warn!("[DBG-SRV] decline_transfer: NO pending decision for session={}", session_id);
        Err(anyhow::anyhow!("No pending decision for session: {}", session_id))
    }
}

pub fn store_pending_decision(
    session_id: String,
    sender: tokio::sync::oneshot::Sender<PrepareUploadDecisionV2>,
) {
    let mut state = bridge().lock().unwrap();
    state.pending_decisions.insert(session_id, sender);
}

pub fn respond_transfer(session_id: &str, accept: bool, accepted_file_ids: &[String]) -> Result<()> {
    if accept {
        accept_transfer(session_id, accepted_file_ids)
    } else {
        decline_transfer(session_id)
    }
}

// ── Server Status & Query ────────────────────────────────────────────────────

pub fn get_server_status() -> String {
    let state = bridge().lock().unwrap();
    let running = state.server_handle.is_some();
    let fingerprint = state.fingerprint.clone();
    let active_session = {
        let reqs = state.pending_requests.lock().unwrap();
        reqs.first().map(|r| r.session_id.clone())
    };
    drop(state);

    json!({
        "running": running,
        "activeSession": active_session,
        "fingerprint": fingerprint,
    })
    .to_string()
}

pub fn get_current_send_session_id() -> String {
    let state = bridge().lock().unwrap();
    let sid = state.current_send_session_id.lock().unwrap();
    sid.clone()
}

pub fn cancel_local_session(session_id: &str) {
    let state = bridge().lock().unwrap();
    if let Some(cancel) = state.active_transfers.get(session_id) {
        cancel.cancel();
    }
    drop(state);

    let mut state = bridge().lock().unwrap();
    state.active_transfers.remove(session_id);

    {
        let mut map = state.send_progress.lock().unwrap();
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
        let mut map = state.recv_progress.lock().unwrap();
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
        let mut reqs = state.pending_requests.lock().unwrap();
        reqs.retain(|r| r.session_id != session_id);
    }
}

// ── High-level API ──────────────────────────────────────────────────────────

pub async fn create_server(config_json: &str) -> Result<String> {
    let config: Value = serde_json::from_str(config_json)?;

    let alias = config["alias"].as_str().unwrap_or("HarmonyOS").to_string();
    let device_type_str = config["deviceType"].as_str().unwrap_or("mobile");
    let device_model = config["deviceModel"].as_str().unwrap_or("HarmonyOS").to_string();
    let port = config["port"].as_u64().unwrap_or(53317) as u16;
    let use_https = config["useHttps"].as_bool().unwrap_or(true);
    let pin = config["pin"].as_str().map(|s| s.to_string());
    let verify_checksums = config["verifyChecksums"].as_bool().unwrap_or(true);
    let save_dir = config["saveDir"].as_str().unwrap_or("/data/local/tmp/localsend/").to_string();
    let show_token = config["showToken"].as_str().map(|s| s.to_string());

    log::info!("[DBG-SRV] create_server: alias={} use_https={} port={} save_dir={}", alias, use_https, port, save_dir);

    // Persist the TLS identity (key + self-signed cert) so the device
    // fingerprint stays stable across restarts. Peers (e.g. the desktop
    // LocalSend) remember a device by its certificate fingerprint; a fresh
    // certificate on every start makes old peers reject us with
    // "certificate fingerprint mismatch" and duplicates the device in their
    // list (one entry per certificate).
    crate::bridge::facade::init_with_persisted_identity(
        alias.clone(),
        crate::bridge::facade::parse_device_type(device_type_str),
        &save_dir,
    )?;

    // Store the real device model so that server/discovery/client payloads
    // advertise it instead of the hardcoded fallback.
    {
        let mut state = crate::bridge::state::bridge().lock().unwrap();
        if !device_model.is_empty() {
            state.device_model = device_model;
        }
    }

    start_server_with_show_token(port, use_https, verify_checksums, pin, None, show_token).await?;

    {
        let mut state = bridge().lock().unwrap();
        // Ensure save_dir ends with '/'
        if !save_dir.ends_with('/') {
            state.save_dir = save_dir + "/";
        } else {
            state.save_dir = save_dir;
        }
    }

    let (fingerprint, actual_port) = {
        let state = bridge().lock().unwrap();
        (state.fingerprint.clone(), state.local_port)
    };

    Ok(json!({
        "fingerprint": fingerprint,
        "port": actual_port,
    })
    .to_string())
}

// ── Progress Polling ─────────────────────────────────────────────────────────

pub fn poll_pending_requests() -> Vec<PendingRequest> {
    let state = bridge().lock().unwrap();
    let reqs = state.pending_requests.lock().unwrap();
    reqs.clone()
}

// ── WebSendEvent Handling ──────────────────────────────────────────────────────

/// Spawn a task to handle WebSendEvent from the Rust core.
/// Bridges PrepareDownload and FileDownload events to the ArkTS callback.
pub fn spawn_web_send_event_task(
    mut event_rx: tokio::sync::mpsc::Receiver<WebSendEvent>,
    callback: Option<crate::bridge::callback::EventCallback>,
) {
    tokio::spawn(async move {
        while let Some(event) = event_rx.recv().await {
            match event {
                WebSendEvent::PrepareDownload {
                    ip,
                    session_id,
                    user_agent,
                    decision_tx,
                } => {
                    // Push callback event to ArkTS
                    if let Some(ref cb) = callback {
                        let payload = json!({
                            "type": "web_prepare_download",
                            "sessionId": session_id,
                            "ip": ip.to_string(),
                            "userAgent": user_agent,
                        });
                        cb.call(payload.to_string());
                    }

                    // Store the decision oneshot for later accept/decline
                    {
                        let mut state = bridge().lock().unwrap();
                        state.web_download_decisions.insert(session_id, decision_tx);
                    }
                }
                WebSendEvent::FileDownload {
                    session_id,
                    file_id,
                    file,
                    content_tx,
                } => {
                    // Push callback event to ArkTS (for logging/UI)
                    if let Some(ref cb) = callback {
                        let payload = json!({
                            "type": "web_file_download",
                            "sessionId": session_id,
                            "fileId": file_id,
                            "fileName": file.file_name,
                            "size": file.size,
                            "fileType": file.file_type,
                        });
                        cb.call(payload.to_string());
                    }

                    // Store the content_tx in pending_file_downloads so fail_file_download can reject it
                    {
                        let mut state = bridge().lock().unwrap();
                        state.pending_file_downloads.insert(
                            (session_id.clone(), file_id.clone()),
                            content_tx,
                        );
                    }

                    // Auto-accept: look up the file path from our mapping and provide FileContent::Path
                    let file_path = {
                        let state = bridge().lock().unwrap();
                        let map = state.web_send_files.lock().unwrap();
                        map.get(&file_id).cloned()
                    };

                    // Retrieve and answer the content_tx
                    let content_tx = {
                        let mut state = bridge().lock().unwrap();
                        state.pending_file_downloads.remove(&(session_id.clone(), file_id.clone()))
                    };

                    if let Some(content_tx) = content_tx {
                        if let Some(path) = file_path {
                            let _ = content_tx.send(FileContent::Path(std::path::PathBuf::from(path)));
                        } else {
                            // File path not found — dropping content_tx causes 500 response
                            log::warn!("FileDownload: no path found for file_id={}", file_id);
                            drop(content_tx);
                        }
                    }
                }
            }
        }
    });
}

// ── Web Download Accept / Decline ─────────────────────────────────────────────

pub fn accept_web_download(session_id: &str) -> Result<()> {
    let mut state = bridge().lock().unwrap();
    if let Some(sender) = state.web_download_decisions.remove(session_id) {
        let _ = sender.send(true);
        Ok(())
    } else {
        Err(anyhow::anyhow!("No pending web download decision for session: {}", session_id))
    }
}

pub fn decline_web_download(session_id: &str) -> Result<()> {
    let mut state = bridge().lock().unwrap();
    if let Some(sender) = state.web_download_decisions.remove(session_id) {
        let _ = sender.send(false);
        Ok(())
    } else {
        Err(anyhow::anyhow!("No pending web download decision for session: {}", session_id))
    }
}

// ── Web Upload ─────────────────────────────────────────────────────────────────

/// Mark a pending file download as failed, causing the web download request to
/// return an error response. Does nothing if the download was already answered.
pub fn fail_file_download(session_id: &str, file_id: &str) -> Result<()> {
    let mut state = bridge().lock().unwrap();

    // Try to drop a pending FileDownload content_tx (causes 500 response)
    if state.pending_file_downloads.remove(&(session_id.to_string(), file_id.to_string())).is_some() {
        return Ok(());
    }

    // Try to decline a pending PrepareDownload decision (causes rejection)
    if state.web_download_decisions.remove(session_id).is_some() {
        // Dropping the sender without sending causes 500 response
        return Ok(());
    }

    Err(anyhow::anyhow!(
        "No pending file download for session={}, file={}",
        session_id, file_id
    ))
}

/// Mark a pending file upload as failed, causing the upload request to
/// return an error response. Does nothing if the upload was already answered.
pub fn fail_file_upload(session_id: &str, file_id: &str) -> Result<()> {
    let mut state = bridge().lock().unwrap();

    // Try to drop a pending FileUpload target_tx (causes 500 response)
    if state.pending_file_uploads.remove(&(session_id.to_string(), file_id.to_string())).is_some() {
        return Ok(());
    }

    // Also cancel any active transfer for this session
    if let Some(cancel) = state.active_transfers.get(session_id) {
        cancel.cancel();
    }

    Err(anyhow::anyhow!(
        "No pending file upload for session={}, file={}",
        session_id, file_id
    ))
}

pub async fn start_web_upload() -> Result<u16> {
    log::info!("[DBG-WEB-UP] start_web_upload: stopping current server");
    // Stop the current server
    crate::bridge::server_facade::stop_server();

    // Get state values needed for restart
    let (port, use_https, verify_checksums, current_pin) = {
        let state = bridge().lock().unwrap();
        (state.local_port, state.use_https, true, state.receive_pin.clone())
    };

    // Build WebConfig for upload mode
    let i18n = crate::bridge::facade::build_web_i18n();
    let web_config = WebConfig {
        send: None,
        upload: true,
        i18n,
    };

    // Clear web send state (not applicable in upload mode)
    {
        let mut state = bridge().lock().unwrap();
        state.web_send_event_tx.take();
        state.web_send_files.lock().unwrap().clear();
        state.web_download_decisions.clear();
    }

    // Wait for port to be released after stop
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;

    // Restart server with upload WebConfig (await directly — we are already in async context)
    crate::bridge::server_facade::start_server(
        port,
        use_https,
        verify_checksums,
        current_pin,
        Some(web_config),
    )
    .await?;

    // Get the actual port
    let actual_port = {
        let state = bridge().lock().unwrap();
        state.local_port
    };

    log::info!("[DBG-WEB-UP] start_web_upload: server started on port={}", actual_port);
    Ok(actual_port)
}
