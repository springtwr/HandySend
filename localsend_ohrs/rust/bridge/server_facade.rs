//! 服务器门面——处理所有服务器相关逻辑。
//!
//! 从 facade.rs 抽出，保持各门面模块职责聚焦：
//! - facade.rs：公共工具（初始化、解析辅助、加密等）
//! - server_facade.rs：HTTP 服务器生命周期与事件处理
//! - client_facade.rs：HTTP 客户端操作
//! - discovery_facade.rs：UDP 组播发现

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Result;
use serde_json::{json, Value};

use localsend::http::server::internal::{InternalConfig, InternalEvent};
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2};
use localsend::http::server::web::{WebConfig, WebSendEvent};
use localsend::http::server::{self, ServerConfigV2, TlsConfig};
use localsend::http::state::ClientInfo;
use localsend::model::discovery::PROTOCOL_VERSION_V2;
use localsend::model::transfer::FileContent;

use crate::bridge::facade::{device_type_to_string, server_event_to_json};
use crate::bridge::state::{bridge, PendingFile, PendingRequest, ProgressEntry};

// ── 服务器生命周期 ─────────────────────────────────────────────────────────

pub async fn start_server(
    port: u16,
    use_https: bool,
    verify_checksums: bool,
    pin: Option<String>,
    web_config: Option<WebConfig>,
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
    log::debug!(
        "[DBG-SRV] start_server: port={} use_https={} has_web_config={} has_pin={}",
        port,
        use_https,
        web_config.is_some(),
        pin.is_some()
    );
    let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<ServerEventV2>(64);
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();

    // 为 InternalConfig 展示令牌（重试间保持稳定）
    // 优先使用外部提供的令牌，否则生成一个
    let show_token = external_show_token.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());

    // 存储 show_token，以便之后取回
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

    // 尝试启动服务器，若端口仍被占用则重试一次
    // 注意：web_config 不可 Clone（包含 mpsc::Sender），因此仅重试
    // 当没有 web_config 时（正常模式）发生。
    let mut current_stop_tx = stop_tx;
    let mut current_stop_rx = stop_rx;
    let mut handle: Option<server::ServerHandle> = None;

    // 我们需要循环外的内部事件接收器
    let mut internal_event_rx_option: Option<tokio::sync::mpsc::Receiver<InternalEvent>> = None;

    let max_attempts = if web_config.is_some() { 1 } else { 2 };

    for attempt in 0..max_attempts {
        // 每次尝试都重新构建 v2_config（ServerConfigV2 不可 Clone）
        let cfg = ServerConfigV2 {
            pin: pin.clone(),
            verify_checksums,
            event_tx: event_tx.clone(),
        };

        // 每次尝试都重新构建 internal_config（InternalConfig 不可 Clone）
        let (internal_event_tx, internal_event_rx) =
            tokio::sync::mpsc::channel::<InternalEvent>(16);
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
                if attempt == 0
                    && (err_msg.contains("in use")
                        || err_msg.contains("Address already")
                        || err_msg.contains("EADDRINUSE"))
                {
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

    let local_port = handle
        .local_addresses()
        .first()
        .map(|a| a.port())
        .unwrap_or(port);

    let callback = {
        let state = bridge().lock().unwrap();
        state.callback.clone()
    };
    // 克隆 InternalEvent 监听器的回调（原回调将被移入主事件循环任务）
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
                    log::debug!("[DBG-SRV-EVT] PrepareUpload: session={} ip={} alias={} files_count={} cert_fp={}",
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
                        let protocol = if cert_fingerprint.is_some()
                            && !cert_fingerprint
                                .as_ref()
                                .map(|s| s.is_empty())
                                .unwrap_or(true)
                        {
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
                    log::debug!(
                        "[DBG-SRV-EVT] FileUpload: session={} file={} size={}",
                        session_id,
                        file_id,
                        file.size
                    );
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

            // 处理需要移出的自有事件
            match event {
                ServerEventV2::PrepareUpload {
                    session_id,
                    decision_tx,
                    ip,
                    info,
                    cert_fingerprint,
                    ..
                } => {
                    store_pending_decision(session_id.clone(), decision_tx);
                    // 存储对端信息，用于接收方取消时向发送方发 /cancel
                    let peer_protocol = if cert_fingerprint.is_some() {
                        localsend::model::discovery::ProtocolType::Https
                    } else {
                        localsend::model::discovery::ProtocolType::Http
                    };
                    let mut state = bridge().lock().unwrap();
                    state
                        .session_peers
                        .insert(session_id, (ip.to_string(), info.port, peer_protocol));
                }
                ServerEventV2::FileUpload {
                    session_id,
                    file_id,
                    file,
                    target_tx,
                } => {
                    log::debug!(
                        "[DBG-SRV-EVT] FileUpload: session={} file={} size={}",
                        session_id,
                        file_id,
                        file.size
                    );
                    let save_dir = {
                        let state = bridge().lock().unwrap();
                        state.save_dir.clone()
                    };
                    let save_path = format!("{}{}", save_dir, file.file_name);
                    log::debug!("[DBG-SRV-EVT]   save_path={}", save_path);

                    // 自动接收：构建上传目标并直接发送
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

                    // 流式进度跟踪：钳制上报的 bytes_sent 不超过 total-1，
                    // 防止上传中断时误报 100%。100% 仅由结果跟踪任务在写入
                    // 成功确认后上报。
                    let mut last_reported: u64 = 0;
                    tokio::spawn(async move {
                        while let Some(bytes_written) = progress_rx.recv().await {
                            // 钳制：流式进度最高上报 total-1
                            let reported = if total > 0 {
                                bytes_written.min(total - 1)
                            } else {
                                0
                            };
                            last_reported = reported;
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
                            if should_update || bytes_written >= total {
                                let mut map = fp2.lock().unwrap();
                                let key = format!("{}:{}", sid, fid);
                                map.insert(
                                    key,
                                    ProgressEntry {
                                        session_id: sid.clone(),
                                        file_id: fid.clone(),
                                        bytes_sent: reported,
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
                                        "bytesSent": reported,
                                        "totalBytes": total,
                                        "filePath": fp_path,
                                    });
                                    cb.call(payload.to_string());
                                }
                            }
                        }
                        // progress_tx 被 drop，说明写入端已结束（成功或中断）。
                        // 不在此处设 100%——由结果跟踪任务根据 result_rx 判断。
                        // 如果写入中断（last_reported < total），保持最后已知值。
                        log::debug!(
                            "[RECV-PROGRESS] Stream ended: session={} file={} last_reported={}/{}",
                            sid,
                            fid,
                            last_reported,
                            total
                        );
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
                    // 结果跟踪任务：仅在写入成功确认后才上报 100%。
                    // 写入失败（发送方取消、网络断开、校验和不匹配等）
                    // 时不上报 100%，避免 UI 显示"传输完成"的错误反馈。
                    tokio::spawn(async move {
                        match result_rx.await {
                            Ok(Ok(())) => {
                                // 写入成功（含校验和验证通过）
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
                                log::debug!(
                                    "[RECV-PROGRESS] File saved OK: session={} file={} size={}",
                                    sid2,
                                    fid2,
                                    total
                                );
                            }
                            Ok(Err(err)) => {
                                // 写入失败（磁盘错误、大小不匹配等）
                                log::warn!(
                                    "[RECV-PROGRESS] File save failed: session={} file={} error={}",
                                    sid2,
                                    fid2,
                                    err
                                );
                            }
                            Err(_) => {
                                // oneshot 被 drop（上传中断/取消），不报 100%
                                log::debug!(
                                    "[RECV-PROGRESS] File upload cancelled: session={} file={}",
                                    sid2,
                                    fid2
                                );
                            }
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

    // 为 Show 事件派生 InternalEvent 监听器
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
        state.verify_checksums = verify_checksums;
        state.receive_pin = pin.clone();
    }

    Ok(())
}

pub fn stop_server() {
    log::debug!("[DBG-SRV] stop_server called");
    let mut state = bridge().lock().unwrap();
    // 向服务器任务发送停止信号——触发优雅关闭
    if let Some(stop_tx) = state.server_stop_tx.take() {
        let _ = stop_tx.send(());
    }
    // 丢弃句柄——分离任务，但停止信号已请求关闭
    state.server_handle.take();
    state.event_tx.take();
    state.show_token.take();
    // 取消并清空进行中的传输
    for (_key, cancel) in state.active_transfers.drain() {
        cancel.cancel();
    }
    // 清除待处理状态
    state.pending_requests.lock().unwrap().clear();
    state.pending_decisions.clear();
    state.recv_progress.lock().unwrap().clear();
    state.send_progress.lock().unwrap().clear();
    // 清除 Web 发送状态
    state.web_send_event_tx.take();
    state.web_send_files.lock().unwrap().clear();
    state.web_download_decisions.clear();
    state.pending_file_uploads.clear();
    state.pending_file_downloads.clear();
    state.session_peers.clear();
}

// ── 接收 / 拒绝 ─────────────────────────────────────────────────────────

pub fn accept_transfer(session_id: &str, file_ids: &[String]) -> Result<()> {
    log::debug!(
        "[DBG-SRV] accept_transfer: session={} file_count={}",
        session_id,
        file_ids.len()
    );
    let mut state = bridge().lock().unwrap();
    if let Some(sender) = state.pending_decisions.remove(session_id) {
        let file_set: std::collections::HashSet<String> = file_ids.iter().cloned().collect();
        let decision = PrepareUploadDecisionV2::Accept(file_set);
        let _ = sender.send(decision);

        let mut reqs = state.pending_requests.lock().unwrap();
        reqs.retain(|r| r.session_id != session_id);

        Ok(())
    } else {
        log::warn!(
            "[DBG-SRV] accept_transfer: NO pending decision for session={}",
            session_id
        );
        Err(anyhow::anyhow!(
            "No pending decision for session: {}",
            session_id
        ))
    }
}

pub fn decline_transfer(session_id: &str) -> Result<()> {
    log::debug!("[DBG-SRV] decline_transfer: session={}", session_id);
    let mut state = bridge().lock().unwrap();
    if let Some(sender) = state.pending_decisions.remove(session_id) {
        let decision = PrepareUploadDecisionV2::Decline;
        let _ = sender.send(decision);

        let mut reqs = state.pending_requests.lock().unwrap();
        reqs.retain(|r| r.session_id != session_id);

        Ok(())
    } else {
        log::warn!(
            "[DBG-SRV] decline_transfer: NO pending decision for session={}",
            session_id
        );
        Err(anyhow::anyhow!(
            "No pending decision for session: {}",
            session_id
        ))
    }
}

pub fn store_pending_decision(
    session_id: String,
    sender: tokio::sync::oneshot::Sender<PrepareUploadDecisionV2>,
) {
    let mut state = bridge().lock().unwrap();
    state.pending_decisions.insert(session_id, sender);
}

pub fn respond_transfer(
    session_id: &str,
    accept: bool,
    accepted_file_ids: &[String],
) -> Result<()> {
    if accept {
        accept_transfer(session_id, accepted_file_ids)
    } else {
        decline_transfer(session_id)
    }
}

// ── 服务器状态与查询 ────────────────────────────────────────────────────

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
    // 取消本地 CancellationToken
    let state = bridge().lock().unwrap();
    if let Some(cancel) = state.active_transfers.get(session_id) {
        cancel.cancel();
    }
    drop(state);

    let mut state = bridge().lock().unwrap();
    state.active_transfers.remove(session_id);

    // 清理进度
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

    // 清理待处理请求和决策
    {
        let mut reqs = state.pending_requests.lock().unwrap();
        reqs.retain(|r| r.session_id != session_id);
    }
    state.pending_decisions.remove(session_id);

    // 清理待处理文件上传目标——使未开始的上传返回 500
    {
        let keys_to_remove: Vec<(String, String)> = state
            .pending_file_uploads
            .keys()
            .filter(|(sid, _)| sid == session_id)
            .cloned()
            .collect();
        for k in keys_to_remove {
            // drop 发送端，使等待中的 upload handler 收到 RecvError
            state.pending_file_uploads.remove(&k);
        }
    }

    // 提取对端信息用于取消通知
    let peer_info = state.session_peers.remove(session_id);
    let cert_pem = state.cert_pem.clone();
    let key_pem = state.key_pem.clone();

    // 通过 event_tx 发出 SessionEnd(Cancelled) 事件
    if let Some(event_tx) = state.event_tx.as_ref() {
        let _ = event_tx.try_send(ServerEventV2::SessionEnd {
            session_id: session_id.to_string(),
            reason: localsend::http::server::v2::SessionEndReasonV2::Cancelled,
        });
    }

    drop(state);

    // 向发送方发送 /cancel 请求（尽力而为）
    if let Some((peer_ip, peer_port, peer_protocol)) = peer_info {
        let sid = session_id.to_string();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build();
            if let Ok(rt) = rt {
                rt.block_on(async {
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
                    let _ = client
                        .cancel(peer_protocol, &peer_ip, peer_port, &sid)
                        .await;
                    log::debug!(
                        "[CANCEL-LOCAL-SESSION] Sent /cancel to sender {}:{}, session={}",
                        peer_ip,
                        peer_port,
                        sid
                    );
                });
            }
        });
    }
}

// ── 高级 API ──────────────────────────────────────────────────────────

pub async fn create_server(config_json: &str) -> Result<String> {
    let config: Value = serde_json::from_str(config_json)?;

    let alias = config["alias"].as_str().unwrap_or("HarmonyOS").to_string();
    let device_type_str = config["deviceType"].as_str().unwrap_or("mobile");
    let device_model = config["deviceModel"]
        .as_str()
        .unwrap_or("HarmonyOS")
        .to_string();
    let port = config["port"].as_u64().unwrap_or(53317) as u16;
    let use_https = config["useHttps"].as_bool().unwrap_or(true);
    let pin = config["pin"].as_str().map(|s| s.to_string());
    let verify_checksums = config["verifyChecksums"].as_bool().unwrap_or(true);
    let save_dir = config["saveDir"]
        .as_str()
        .unwrap_or("/data/local/tmp/localsend/")
        .to_string();
    let show_token = config["showToken"].as_str().map(|s| s.to_string());

    log::debug!(
        "[DBG-SRV] create_server: alias={} use_https={} port={} save_dir={}",
        alias,
        use_https,
        port,
        save_dir
    );

    // 持久化 TLS 身份（密钥 + 自签名证书），使设备
    // 指纹在重启间保持稳定。对端（例如桌面端
    // LocalSend）按证书指纹记住设备；每次生成新的
    // 每次启动都更换证书会导致旧设备以以下错误拒绝我们
    // "证书指纹不匹配"并在其设备列表中重复显示
    // 列表（每份证书一条）。
    crate::bridge::facade::init_with_persisted_identity(
        alias.clone(),
        crate::bridge::facade::parse_device_type(device_type_str),
        &save_dir,
    )?;

    // 存储真实设备模型，使服务器/发现/客户端负载
    // 广播它而不是硬编码的回退值。
    {
        let mut state = crate::bridge::state::bridge().lock().unwrap();
        if !device_model.is_empty() {
            state.device_model = device_model;
        }
    }

    start_server_with_show_token(port, use_https, verify_checksums, pin, None, show_token).await?;

    {
        let mut state = bridge().lock().unwrap();
        // 确保 save_dir 以 '/' 结尾
        if !save_dir.ends_with('/') {
            state.save_dir = save_dir + "/";
        } else {
            state.save_dir = save_dir;
        }
        // 持久化 verify_checksums，供 Web 分享等场景重启服务器时读取
        state.verify_checksums = verify_checksums;
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

// ── 进度轮询 ─────────────────────────────────────────────────────────

pub fn poll_pending_requests() -> Vec<PendingRequest> {
    let state = bridge().lock().unwrap();
    let reqs = state.pending_requests.lock().unwrap();
    reqs.clone()
}

// ── WebSendEvent 处理 ──────────────────────────────────────────────────────

/// 派生一个任务处理来自 Rust 核心的 WebSendEvent。
/// 将 PrepareDownload 和 FileDownload 事件桥接到 ArkTS 回调。
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
                    // 向 ArkTS 推送回调事件
                    if let Some(ref cb) = callback {
                        let payload = json!({
                            "type": "web_prepare_download",
                            "sessionId": session_id,
                            "ip": ip.to_string(),
                            "userAgent": user_agent,
                        });
                        cb.call(payload.to_string());
                    }

                    // 存储决策 oneshot，供之后接受/拒绝
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
                    // 向 ArkTS 推送回调事件（用于日志/UI）
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

                    // 将 content_tx 存入 pending_file_downloads，使 fail_file_download 能拒绝它
                    {
                        let mut state = bridge().lock().unwrap();
                        state
                            .pending_file_downloads
                            .insert((session_id.clone(), file_id.clone()), content_tx);
                    }

                    // 自动接收：从映射中查找文件路径并提供 FileContent::Path
                    let file_path = {
                        let state = bridge().lock().unwrap();
                        let map = state.web_send_files.lock().unwrap();
                        map.get(&file_id).cloned()
                    };

                    // 取回并应答 content_tx
                    let content_tx = {
                        let mut state = bridge().lock().unwrap();
                        state
                            .pending_file_downloads
                            .remove(&(session_id.clone(), file_id.clone()))
                    };

                    if let Some(content_tx) = content_tx {
                        if let Some(path) = file_path {
                            let _ =
                                content_tx.send(FileContent::Path(std::path::PathBuf::from(path)));
                        } else {
                            // 未找到文件路径——丢弃 content_tx 会导致 500 响应
                            log::warn!("FileDownload: no path found for file_id={}", file_id);
                            drop(content_tx);
                        }
                    }
                }
            }
        }
    });
}

// ── Web 下载接受 / 拒绝 ─────────────────────────────────────────────

pub fn accept_web_download(session_id: &str) -> Result<()> {
    let mut state = bridge().lock().unwrap();
    if let Some(sender) = state.web_download_decisions.remove(session_id) {
        let _ = sender.send(true);
        Ok(())
    } else {
        Err(anyhow::anyhow!(
            "No pending web download decision for session: {}",
            session_id
        ))
    }
}

pub fn decline_web_download(session_id: &str) -> Result<()> {
    let mut state = bridge().lock().unwrap();
    if let Some(sender) = state.web_download_decisions.remove(session_id) {
        let _ = sender.send(false);
        Ok(())
    } else {
        Err(anyhow::anyhow!(
            "No pending web download decision for session: {}",
            session_id
        ))
    }
}

// ── Web 上传 ─────────────────────────────────────────────────────────────────

/// 将待处理的文件下载标记为失败，使 Web 下载请求
/// 返回错误响应。若下载已被应答则不执行任何操作。
pub fn fail_file_download(session_id: &str, file_id: &str) -> Result<()> {
    let mut state = bridge().lock().unwrap();

    // 尝试丢弃待处理的 FileDownload content_tx（导致 500 响应）
    if state
        .pending_file_downloads
        .remove(&(session_id.to_string(), file_id.to_string()))
        .is_some()
    {
        return Ok(());
    }

    // 尝试拒绝待处理的 PrepareDownload 决策（导致拒绝）
    if state.web_download_decisions.remove(session_id).is_some() {
        // 直接丢弃发送端而不发送会导致 500 响应
        return Ok(());
    }

    Err(anyhow::anyhow!(
        "No pending file download for session={}, file={}",
        session_id,
        file_id
    ))
}

/// 将待处理的文件上传标记为失败，使上传请求
/// 返回错误响应。若上传已被应答则不执行任何操作。
pub fn fail_file_upload(session_id: &str, file_id: &str) -> Result<()> {
    let mut state = bridge().lock().unwrap();

    // 尝试丢弃待处理的 FileUpload target_tx（导致 500 响应）
    if state
        .pending_file_uploads
        .remove(&(session_id.to_string(), file_id.to_string()))
        .is_some()
    {
        return Ok(());
    }

    // 同时取消该会话的进行中传输
    if let Some(cancel) = state.active_transfers.get(session_id) {
        cancel.cancel();
    }

    Err(anyhow::anyhow!(
        "No pending file upload for session={}, file={}",
        session_id,
        file_id
    ))
}

pub async fn start_web_upload() -> Result<u16> {
    log::debug!("[DBG-WEB-UP] start_web_upload: stopping current server");
    // 停止当前服务器
    crate::bridge::server_facade::stop_server();

    // 获取重启所需的状态值
    let (port, use_https, verify_checksums, current_pin) = {
        let state = bridge().lock().unwrap();
        (
            state.local_port,
            state.use_https,
            state.verify_checksums,
            state.receive_pin.clone(),
        )
    };

    // 为上传模式构建 WebConfig
    let i18n = crate::bridge::facade::build_web_i18n();
    let web_config = WebConfig {
        send: None,
        upload: true,
        i18n,
    };

    // 清除 Web 发送状态（上传模式不适用）
    {
        let mut state = bridge().lock().unwrap();
        state.web_send_event_tx.take();
        state.web_send_files.lock().unwrap().clear();
        state.web_download_decisions.clear();
    }

    // 停止后等待端口释放
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;

    // 以上传 WebConfig 重启服务器（直接 await——我们已在异步上下文中）
    crate::bridge::server_facade::start_server(
        port,
        use_https,
        verify_checksums,
        current_pin,
        Some(web_config),
    )
    .await?;

    // 获取实际端口
    let actual_port = {
        let state = bridge().lock().unwrap();
        state.local_port
    };

    log::debug!(
        "[DBG-WEB-UP] start_web_upload: server started on port={}",
        actual_port
    );
    Ok(actual_port)
}
