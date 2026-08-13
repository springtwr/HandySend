//! Facade layer — the single entry point for interacting with the upstream
//! LocalSend core crate.
//!
//! All NAPI functions in `lib.rs` MUST go through this module. The facade
//! converts upstream internal types into JSON-friendly DTOs so that the
//! NAPI layer never directly depends on upstream internal types.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Result;
use serde_json::{json, Value};

use localsend::crypto;
use localsend::discovery::{self, DeviceIdentity, DiscoveryConfig, StatefulDevice};
use localsend::http::client::{LsHttpClient, LsHttpClientVersion};
use localsend::http::dto::{PrepareUploadRequestDto, RegisterDto};
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2};
use localsend::http::server::{self, ServerConfigV2, TlsConfig};
use localsend::http::state::ClientInfo;
use localsend::model::discovery::{DeviceType, ProtocolType, PROTOCOL_VERSION_V2};
use localsend::model::transfer::{FileContent, FileDto};
use localsend::multicast::{self, MulticastDevice};
use localsend::util::interface::InterfaceFilter;

use crate::bridge::state::{bridge, PendingFile, PendingRequest, ProgressEntry};

// ── Public Facade API ────────────────────────────────────────────────────────

/// Get the current protocol type based on `use_https` state.
fn current_protocol() -> ProtocolType {
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
    let mut state = bridge().lock().unwrap();

    // Only generate cert and runtime on first call
    if state.runtime.is_none() {
        let cert = crypto::cert::generate_self_signed()?;
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

pub async fn start_server(
    port: u16,
    use_https: bool,
    verify_checksums: bool,
    pin: Option<String>,
) -> Result<()> {
    let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<ServerEventV2>(64);
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();

    let (alias, device_type, fingerprint, cert_pem, key_pem) = {
        let state = bridge().lock().unwrap();
        (
            state.local_alias.clone(),
            state.device_type.clone(),
            state.fingerprint.clone(),
            state.cert_pem.clone(),
            state.key_pem.clone(),
        )
    };

    // Attempt to start the server, retrying once if the port is still in use
    let mut current_stop_tx = stop_tx;
    let mut current_stop_rx = stop_rx;
    let mut handle: Option<server::ServerHandle> = None;

    for attempt in 0..2 {
        // Build v2_config fresh each attempt (ServerConfigV2 is not Clone)
        let cfg = ServerConfigV2 {
            pin: pin.clone(),
            verify_checksums,
            event_tx: event_tx.clone(),
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
            device_model: Some("HarmonyOS".to_string()),
            device_type: Some(device_type.clone()),
            token: fingerprint.clone(),
        };

        match server::start_with_port(
            port,
            tls,
            info,
            None,
            Some(cfg),
            None,
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
                    let _ = decision_tx;
                    let file_list: Vec<Value> = files
                        .iter()
                        .map(|(id, f)| {
                            json!({
                                "id": id,
                                "fileName": f.file_name,
                                "size": f.size,
                            })
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
                    let save_dir = {
                        let state = bridge().lock().unwrap();
                        state.save_dir.clone()
                    };
                    let save_path = format!("{}{}", save_dir, file.file_name);

                    let (progress_tx, mut progress_rx) = tokio::sync::mpsc::channel::<u64>(16);

                    let fp = recv_progress.clone();
                    let sid = session_id.clone();
                    let fid = file_id.clone();
                    let total = file.size;
                    let fp_path = save_path.clone();
                    let last_update = Arc::new(std::sync::Mutex::new(Instant::now()));
                    let last_update_clone = last_update.clone();
                    let fp2 = fp.clone();

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
                                file_path: fp_path2,
                            },
                        );
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

    {
        let mut state = bridge().lock().unwrap();
        state.server_handle = Some(handle);
        state.server_stop_tx = Some(current_stop_tx);
        state.event_tx = Some(event_tx);
        state.local_port = local_port;
        state.use_https = use_https;
    }

    Ok(())
}

pub fn stop_server() {
    let mut state = bridge().lock().unwrap();
    // Send stop signal to the server task — triggers graceful shutdown
    if let Some(stop_tx) = state.server_stop_tx.take() {
        let _ = stop_tx.send(());
    }
    // Drop the handle — detaches the task but the stop signal already requested shutdown
    state.server_handle.take();
    state.event_tx.take();
    // Cancel and clear active transfers
    for (_key, cancel) in state.active_transfers.drain() {
        cancel.cancel();
    }
    // Clear pending state
    state.pending_requests.lock().unwrap().clear();
    state.pending_decisions.clear();
    state.recv_progress.lock().unwrap().clear();
    state.send_progress.lock().unwrap().clear();
}

pub async fn start_discovery(port: u16) -> Result<()> {
    let (alias, device_type, fingerprint, cert_pem, key_pem) = {
        let state = bridge().lock().unwrap();
        (
            state.local_alias.clone(),
            state.device_type.clone(),
            state.fingerprint.clone(),
            state.cert_pem.clone(),
            state.key_pem.clone(),
        )
    };

    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();

    let device = MulticastDevice {
        alias,
        version: PROTOCOL_VERSION_V2.to_string(),
        device_model: Some("HarmonyOS".to_string()),
        device_type: Some(device_type),
        fingerprint: fingerprint.clone(),
        port,
        protocol: current_protocol(),
        download: false,
    };

    let identity = DeviceIdentity {
        cert_pem,
        private_key_pem: key_pem,
    };

    let config = DiscoveryConfig {
        group: multicast::DEFAULT_MULTICAST_GROUP,
        group_v6: Some(multicast::DEFAULT_MULTICAST_GROUP_V6),
        port: multicast::DEFAULT_PORT,
        interface_filter: InterfaceFilter::default(),
        device,
        identity,
        timeout: discovery::DEFAULT_DISCOVERY_TIMEOUT,
        event_tx: None,
    };

    let handle = Arc::new(discovery::start(config, stop_rx).await);

    let callback = {
        let state = bridge().lock().unwrap();
        state.callback.clone()
    };

    if let Some(cb) = callback {
        let handle_clone = Arc::clone(&handle);
        tokio::spawn(async move {
            let mut last_count = 0;
            loop {
                tokio::time::sleep(Duration::from_secs(1)).await;
                let devices = handle_clone.devices();
                if devices.len() != last_count {
                    last_count = devices.len();
                    let devices_json: Vec<Value> = devices.iter().map(device_to_json).collect();
                    let payload = json!({
                        "type": "devices_update",
                        "devices": devices_json,
                    });
                    cb.call(payload.to_string());
                }
            }
        });
    }

    {
        let mut state = bridge().lock().unwrap();
        state.discovery_handle = Some(handle);
        state.discovery_stop_tx = Some(stop_tx);
    }

    Ok(())
}

pub fn stop_discovery() {
    let mut state = bridge().lock().unwrap();
    state.discovery_stop_tx.take();
    state.discovery_handle.take();
}

pub fn get_devices_json() -> String {
    let state = bridge().lock().unwrap();
    let devices: Vec<Value> = match state.discovery_handle.as_ref() {
        Some(h) => h.devices().iter().map(device_to_json).collect(),
        None => vec![],
    };
    drop(state);
    serde_json::to_string(&devices).unwrap_or_else(|_| "[]".into())
}

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

pub fn accept_transfer(session_id: &str, file_ids: &[String]) -> Result<()> {
    let mut state = bridge().lock().unwrap();
    if let Some(sender) = state.pending_decisions.remove(session_id) {
        let file_set: std::collections::HashSet<String> = file_ids.iter().cloned().collect();
        let decision = PrepareUploadDecisionV2::Accept(file_set);
        let _ = sender.send(decision);

        let mut reqs = state.pending_requests.lock().unwrap();
        reqs.retain(|r| r.session_id != session_id);

        Ok(())
    } else {
        Err(anyhow::anyhow!("No pending decision for session: {}", session_id))
    }
}

pub fn decline_transfer(session_id: &str) -> Result<()> {
    let mut state = bridge().lock().unwrap();
    if let Some(sender) = state.pending_decisions.remove(session_id) {
        let decision = PrepareUploadDecisionV2::Decline;
        let _ = sender.send(decision);

        let mut reqs = state.pending_requests.lock().unwrap();
        reqs.retain(|r| r.session_id != session_id);

        Ok(())
    } else {
        Err(anyhow::anyhow!("No pending decision for session: {}", session_id))
    }
}

pub async fn prepare_send(
    target_ip: &str,
    target_port: u16,
    target_protocol: ProtocolType,
    files_json: &str,
    pin: Option<String>,
    expected_fingerprint: Option<String>,
) -> Result<String> {
    let (alias, device_type, fingerprint, cert_pem, key_pem) = {
        let state = bridge().lock().unwrap();
        (
            state.local_alias.clone(),
            state.device_type.clone(),
            state.fingerprint.clone(),
            state.cert_pem.clone(),
            state.key_pem.clone(),
        )
    };

    let files: Vec<FileDto> = serde_json::from_str(files_json)?;
    let files_map: HashMap<String, FileDto> = files
        .into_iter()
        .map(|f| (f.id.clone(), f))
        .collect();

    let payload = PrepareUploadRequestDto {
        info: RegisterDto {
            alias: alias.clone(),
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: Some("HarmonyOS".to_string()),
            device_type: Some(device_type),
            token: fingerprint.clone(),
            port: target_port,
            protocol: current_protocol(),
            has_web_interface: false,
        },
        files: files_map,
    };

    let client = LsHttpClient::new(
        &key_pem,
        &cert_pem,
        LsHttpClientVersion::V2,
        expected_fingerprint,
        Some(Duration::from_secs(10)),
    )?;

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
            None,
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

    let result = result.map_err(|e| anyhow::anyhow!("{e}"))?;

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
) -> Result<()> {
    let (cert_pem, key_pem, send_progress, current_send_session_id) = {
        let state = bridge().lock().unwrap();
        (
            state.cert_pem.clone(),
            state.key_pem.clone(),
            state.send_progress.clone(),
            state.current_send_session_id.clone(),
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
    let cancel = tokio_util::sync::CancellationToken::new();

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
        }
    };

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
        .await
        .map_err(|e| anyhow::anyhow!("{e}"))?;

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
    }

    // Clean up active transfer entry after completion
    {
        let mut state = bridge().lock().unwrap();
        state.active_transfers.remove(session_id);
    }

    Ok(())
}

pub fn cancel_transfer(session_id: &str) {
    let mut state = bridge().lock().unwrap();
    if let Some(cancel) = state.active_transfers.remove(session_id) {
        cancel.cancel();
    }
}

pub fn store_pending_decision(
    session_id: String,
    sender: tokio::sync::oneshot::Sender<PrepareUploadDecisionV2>,
) {
    let mut state = bridge().lock().unwrap();
    state.pending_decisions.insert(session_id, sender);
}

// ── High-level API ──────────────────────────────────────────────────────────

pub async fn create_server(config_json: &str) -> Result<String> {
    let config: Value = serde_json::from_str(config_json)?;

    let alias = config["alias"].as_str().unwrap_or("HarmonyOS").to_string();
    let device_type_str = config["deviceType"].as_str().unwrap_or("mobile");
    let port = config["port"].as_u64().unwrap_or(53317) as u16;
    let use_https = config["useHttps"].as_bool().unwrap_or(true);
    let pin = config["pin"].as_str().map(|s| s.to_string());
    let verify_checksums = config["verifyChecksums"].as_bool().unwrap_or(true);
    let save_dir = config["saveDir"].as_str().unwrap_or("/data/local/tmp/localsend/").to_string();

    init(alias.clone(), parse_device_type(device_type_str))?;

    start_server(port, use_https, verify_checksums, pin).await?;

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

pub async fn send_files(
    target_json: &str,
    _sender_alias: &str,
    files_json: &str,
) -> Result<String> {
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

    let prepare_result = prepare_send(&target_ip, target_port, target_protocol, &files_json_str, pin, target_fingerprint.clone()).await?;
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

        match upload_file(&target_ip, target_port, target_protocol, &session_id, file_id, &token, file_path, target_fingerprint.clone()).await {
            Ok(()) => {}
            Err(e) => {
                log::warn!("Upload failed for file {}: {e:#}", file_id);
                failed_files.push(file_id.to_string());
            }
        }
    }

    let success = failed_files.is_empty();

    Ok(json!({
        "sessionId": session_id,
        "success": success,
        "failedFiles": failed_files,
    })
    .to_string())
}

pub fn poll_send_progress() -> Vec<ProgressEntry> {
    let state = bridge().lock().unwrap();
    let map = state.send_progress.lock().unwrap();
    map.values().cloned().collect()
}

pub fn poll_progress() -> Vec<ProgressEntry> {
    let state = bridge().lock().unwrap();
    let map = state.recv_progress.lock().unwrap();
    map.values().cloned().collect()
}

pub fn poll_pending_requests() -> Vec<PendingRequest> {
    let state = bridge().lock().unwrap();
    let reqs = state.pending_requests.lock().unwrap();
    reqs.clone()
}

pub fn respond_transfer(session_id: &str, accept: bool, accepted_file_ids: &[String]) -> Result<()> {
    if accept {
        accept_transfer(session_id, accepted_file_ids)
    } else {
        decline_transfer(session_id)
    }
}

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

pub fn poll_debug_log() -> Vec<String> {
    let state = bridge().lock().unwrap();
    let mut log = state.debug_log.lock().unwrap();
    let entries: Vec<String> = log.drain(..).collect();
    entries
}

pub fn create_share_link(_files_json: &str, _alias: &str) -> Result<String> {
    Ok(json!({
        "url": "",
        "port": 0,
        "sessionId": "",
    })
    .to_string())
}

pub fn stop_share_server() {
    // no-op for now
}

pub fn poll_share_progress() -> Vec<ProgressEntry> {
    Vec::new()
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

// ── Internal DTO Conversion ─────────────────────────────────────────────────

fn device_type_to_string(dt: &DeviceType) -> &'static str {
    match dt {
        DeviceType::Mobile => "mobile",
        DeviceType::Desktop => "desktop",
        DeviceType::Web => "web",
        DeviceType::Headless => "headless",
        DeviceType::Server => "server",
    }
}

fn protocol_to_string(p: &ProtocolType) -> &'static str {
    match p {
        ProtocolType::Http => "http",
        ProtocolType::Https => "https",
    }
}

fn device_to_json(d: &StatefulDevice) -> Value {
    let http = d.device.http();
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
            },
        })
        .to_string(),

        ServerEventV2::PrepareUpload { .. } => String::new(),

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
        device_type: Some(parse_device_type(our_device_type)),
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

    let mut last_error = String::from("No protocol attempted");

    for proto in &protocols_to_try {
        // For HTTPS, use the full mTLS client; for HTTP, also use it (it works without TLS too)
        let client = match LsHttpClient::new(
            &key_pem,
            &cert_pem,
            LsHttpClientVersion::V2,
            None, // Don't pin expected fingerprint for discovery/register
            Some(Duration::from_secs(5)),
        ) {
            Ok(c) => c,
            Err(e) => {
                last_error = format!("Client creation failed: {e:#}");
                continue;
            }
        };

        match client.register(*proto, target_ip, target_port, payload.clone()).await {
            Ok(result) => {
                let resp = result.body;
                let resp_protocol = proto.as_str();
                let cert_fp = result.cert_fingerprint.unwrap_or_default();
                let ret = json!({
                    "alias": resp.alias,
                    "version": resp.version,
                    "deviceModel": resp.device_model.unwrap_or_default(),
                    "deviceType": format!("{:?}", resp.device_type.unwrap_or(DeviceType::Desktop)).to_lowercase(),
                    "fingerprint": resp.token,
                    "protocol": resp_protocol,
                    "certFingerprint": cert_fp,
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
