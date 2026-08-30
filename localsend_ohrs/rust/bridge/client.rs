//! 客户端操作——发送 / 接收 / 取消 / 注册。
//!
//! 核心函数接收 `&Mutex<BridgeState>` 参数，错误通过 `Result<_, BridgeError>` 返回，
//! 进度通过 `state.event_tx` 推送 `BridgeEvent::UploadProgress`（可丢弃事件）。

use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use localsend::http::client::{ClientError, LsHttpClient, LsHttpClientV2, LsHttpClientVersion};
use localsend::http::dto::RegisterDto;
use localsend::model::discovery::{DeviceType, PROTOCOL_VERSION_V2};
use localsend::model::transfer::{FileContent, FileDto};

use crate::bridge::adapter::client::{adapt_client_error, client_error_to_json};
use crate::bridge::event::{send_event, BridgeError, BridgeEvent};
use crate::bridge::identity;
use crate::bridge::state::BridgeState;

// ── 发送操作 ──────────────────────────────────────────────────────────

/// 发送 prepare-upload 请求，返回包含 sessionId 和文件 token 的 JSON。
#[allow(clippy::too_many_arguments)]
pub async fn prepare_send(
    state: &Mutex<BridgeState>,
    target_ip: &str,
    target_port: u16,
    target_protocol: localsend::model::discovery::ProtocolType,
    files_json: &str,
    pin: Option<String>,
    expected_fingerprint: Option<String>,
    public_key: Option<String>,
) -> Result<String, BridgeError> {
    log::debug!(
        "[DBG-SEND] prepare_send: ip={} port={} proto={:?} has_fp={} has_pk={}",
        target_ip,
        target_port,
        target_protocol,
        expected_fingerprint.is_some(),
        public_key.is_some()
    );
    let (alias, device_type, device_model, fingerprint, cert_pem, key_pem, protocol) = {
        let s = state.lock().unwrap();
        (
            s.local_alias.clone(),
            s.device_type.clone(),
            s.device_model.clone(),
            s.fingerprint.clone(),
            s.cert_pem.clone(),
            s.key_pem.clone(),
            identity::current_protocol(&s),
        )
    };

    let files: Vec<FileDto> = serde_json::from_str(files_json)
        .map_err(|e| BridgeError::InvalidArgument(format!("文件 JSON 解析失败: {e}")))?;
    let files_map: std::collections::HashMap<String, FileDto> =
        files.into_iter().map(|f| (f.id.clone(), f)).collect();

    let payload = localsend::http::dto::PrepareUploadRequestDto {
        info: RegisterDto {
            alias: alias.clone(),
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: Some(device_model),
            device_type: Some(device_type),
            token: fingerprint.clone(),
            port: target_port,
            protocol,
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
    )
    .map_err(|e| adapt_client_error(&e))?;

    let cancel = tokio_util::sync::CancellationToken::new();

    // 临时键使准备阶段可取消（prepare_ 前缀）
    let temp_key = format!("prepare_{}", target_ip);
    {
        let mut s = state.lock().unwrap();
        s.active_transfers.insert(temp_key.clone(), cancel.clone());
        let mut sid = s.current_send_session_id.lock().unwrap();
        *sid = temp_key.clone();
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
        .await
        .map_err(|e| adapt_client_error(&e));

    // 无论成功或失败，始终清理 prepare_ 临时键
    {
        let mut s = state.lock().unwrap();
        s.active_transfers.remove(&temp_key);
    }

    let result = result?;

    match result.response {
        Some(resp) => {
            let session_cancel = tokio_util::sync::CancellationToken::new();
            {
                let mut s = state.lock().unwrap();
                s.active_transfers
                    .insert(resp.session_id.clone(), session_cancel);
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

/// 发送文件到目标设备（prepare-upload → 逐文件上传 → 汇总结果）。
pub async fn send_files(
    state: &Mutex<BridgeState>,
    target_json: &str,
    _sender_alias: &str,
    files_json: &str,
) -> Result<String, BridgeError> {
    let target: Value = serde_json::from_str(target_json)
        .map_err(|e| BridgeError::InvalidArgument(format!("目标 JSON 解析失败: {e}")))?;
    let target_ip = target["ip"].as_str().unwrap_or("").to_string();
    let target_port = target["port"].as_u64().unwrap_or(53317) as u16;
    let target_protocol = identity::parse_protocol(target["protocol"].as_str().unwrap_or("https"));
    let target_fingerprint = target["fingerprint"]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string());

    let files: Vec<Value> = serde_json::from_str(files_json)
        .map_err(|e| BridgeError::InvalidArgument(format!("文件 JSON 解析失败: {e}")))?;

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

    let files_json_str = serde_json::to_string(&files_for_prepare)
        .map_err(|e| BridgeError::InvalidArgument(format!("文件序列化失败: {e}")))?;

    let pin = target["pin"].as_str().map(|s| s.to_string());
    let target_public_key = target["publicKey"]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string());

    let prepare_result = match prepare_send(
        state,
        &target_ip,
        target_port,
        target_protocol,
        &files_json_str,
        pin,
        target_fingerprint.clone(),
        target_public_key.clone(),
    )
    .await
    {
        Ok(r) => r,
        Err(e) => {
            let error_json = match e {
                BridgeError::Upstream(inner) => {
                    if let Some(ce) = inner.downcast_ref::<ClientError>() {
                        client_error_to_json(ce)
                    } else {
                        json!({
                            "kind": "other",
                            "message": format!("{inner:#}"),
                        })
                    }
                }
                other => json!({
                    "kind": "other",
                    "message": format!("{other}"),
                }),
            };
            return Ok(json!({
                "sessionId": "",
                "success": false,
                "failedFiles": [],
                "error": error_json,
            })
            .to_string());
        }
    };
    let prepare_data: Value = serde_json::from_str(&prepare_result)
        .map_err(|e| BridgeError::InvalidArgument(format!("prepare 结果解析失败: {e}")))?;

    let session_id = prepare_data["sessionId"].as_str().unwrap_or("").to_string();
    let file_tokens = &prepare_data["files"];

    {
        let s = state.lock().unwrap();
        let mut sid = s.current_send_session_id.lock().unwrap();
        *sid = session_id.clone();
    }

    // 会话级取消令牌：所有文件共享
    let session_cancel = tokio_util::sync::CancellationToken::new();
    {
        let mut s = state.lock().unwrap();
        s.active_transfers
            .insert(session_id.clone(), session_cancel.clone());
    }

    let mut cancelled = false;
    let mut failed_files: Vec<String> = Vec::new();
    let total_files = files.len();

    for (idx, file) in files.iter().enumerate() {
        if session_cancel.is_cancelled() {
            log::debug!(
                "[SEND-FILES] Cancelled before file {}/{}, breaking loop",
                idx + 1,
                total_files
            );
            cancelled = true;
            break;
        }

        let file_id = file["fileId"].as_str().unwrap_or("");
        let file_path = file["filePath"].as_str().unwrap_or("");

        let token = match file_tokens.get(file_id) {
            Some(t) => t.as_str().unwrap_or("").to_string(),
            None => {
                failed_files.push(file_id.to_string());
                continue;
            }
        };

        match upload_file_with_cancel(
            state,
            &target_ip,
            target_port,
            target_protocol,
            &session_id,
            file_id,
            &token,
            file_path,
            target_fingerprint.clone(),
            target_public_key.clone(),
            &session_cancel,
        )
        .await
        {
            Ok(()) => {}
            Err(e) => {
                if session_cancel.is_cancelled() {
                    cancelled = true;
                    failed_files.push(file_id.to_string());
                    break;
                }
                log::warn!(
                    "[SEND-FILES] Upload failed for file {}/{} ({}): {e}",
                    idx + 1,
                    total_files,
                    file_id
                );
                failed_files.push(file_id.to_string());
            }
        }
    }

    // 清理会话级取消令牌
    {
        let mut s = state.lock().unwrap();
        s.active_transfers.remove(&session_id);
    }

    let success = !cancelled && failed_files.is_empty();
    let error_json = if success {
        Value::Null
    } else if cancelled {
        json!({
            "kind": "cancelled",
            "message": "Transfer cancelled".to_string(),
        })
    } else {
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

/// 上传单个文件（使用会话级取消令牌）。
#[allow(clippy::too_many_arguments)]
async fn upload_file_with_cancel(
    state: &Mutex<BridgeState>,
    target_ip: &str,
    target_port: u16,
    target_protocol: localsend::model::discovery::ProtocolType,
    session_id: &str,
    file_id: &str,
    token: &str,
    file_path: &str,
    expected_fingerprint: Option<String>,
    public_key: Option<String>,
    session_cancel: &tokio_util::sync::CancellationToken,
) -> Result<(), BridgeError> {
    let (cert_pem, key_pem) = {
        let s = state.lock().unwrap();
        (s.cert_pem.clone(), s.key_pem.clone())
    };

    {
        let s = state.lock().unwrap();
        let mut sid = s.current_send_session_id.lock().unwrap();
        *sid = session_id.to_string();
    }

    let client = LsHttpClient::new(
        &key_pem,
        &cert_pem,
        LsHttpClientVersion::V2,
        expected_fingerprint,
        Some(Duration::from_secs(300)),
    )
    .map_err(|e| adapt_client_error(&e))?;

    let file_meta = std::fs::metadata(file_path);
    let total_bytes = file_meta.map(|m| m.len()).unwrap_or(0);

    let content = FileContent::Path(std::path::PathBuf::from(file_path));
    let cancel = session_cancel.clone();

    if cancel.is_cancelled() {
        return Err(BridgeError::Upstream(anyhow::anyhow!("传输已在上传前取消")));
    }

    let event_tx = state.lock().unwrap().event_tx.clone();
    let sid = session_id.to_string();
    let fid = file_id.to_string();
    let total = total_bytes;
    let last_update = std::sync::Arc::new(std::sync::Mutex::new(Instant::now()));

    // 进度闭包：钳制上报不超过 total-1，100% 仅由上传成功后的最终事件报告。
    // UploadProgress 为可丢弃事件，直接 try_send（同步，不阻塞上传循环）。
    let event_tx_progress = event_tx.clone();
    let sid_progress = sid.clone();
    let fid_progress = fid.clone();
    let last_update_ref = last_update.clone();
    let progress = move |sent: u64| {
        let reported = if total > 0 { sent.min(total - 1) } else { 0 };
        let should_update = {
            let mut last = last_update_ref.lock().unwrap();
            let now = Instant::now();
            if now.duration_since(*last) >= Duration::from_millis(20) {
                *last = now;
                true
            } else {
                false
            }
        };
        if should_update || sent >= total {
            if let Some(tx) = &event_tx_progress {
                let progress = if total > 0 {
                    reported as f64 / total as f64
                } else {
                    0.0
                };
                let _ = tx.try_send(BridgeEvent::UploadProgress {
                    session_id: sid_progress.clone(),
                    file_id: fid_progress.clone(),
                    direction: "send".to_string(),
                    progress,
                    speed: 0.0,
                });
            }
        }
    };

    let result = client
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

    // 上传成功：推送 100% 进度 + 完成（关键事件用 send）
    match result {
        Ok(_) => {
            send_event(
                &event_tx,
                BridgeEvent::UploadProgress {
                    session_id: sid.clone(),
                    file_id: fid.clone(),
                    direction: "send".to_string(),
                    progress: 1.0,
                    speed: 0.0,
                },
            )
            .await;
            Ok(())
        }
        Err(e) => {
            let msg = format!("{e}");
            send_event(
                &event_tx,
                BridgeEvent::Error {
                    context: format!("upload:{session_id}:{file_id}"),
                    message: msg.clone(),
                },
            )
            .await;
            Err(BridgeError::Upstream(anyhow::anyhow!("{msg}")))
        }
    }
}

// ── 远程取消 ────────────────────────────────────────────────────────────

/// 向远端发送取消请求。
pub async fn cancel_transfer_remote(
    state: &Mutex<BridgeState>,
    target_json: &str,
    session_id: &str,
) -> Result<(), BridgeError> {
    let target: Value = serde_json::from_str(target_json)
        .map_err(|e| BridgeError::InvalidArgument(format!("目标 JSON 解析失败: {e}")))?;
    let target_ip = target["ip"].as_str().unwrap_or("").to_string();
    let target_port = target["port"].as_u64().unwrap_or(53317) as u16;
    let target_protocol = identity::parse_protocol(target["protocol"].as_str().unwrap_or("https"));

    let (cert_pem, key_pem) = {
        let s = state.lock().unwrap();
        (s.cert_pem.clone(), s.key_pem.clone())
    };

    let client = LsHttpClient::new(
        &key_pem,
        &cert_pem,
        LsHttpClientVersion::V2,
        None,
        Some(Duration::from_secs(5)),
    )
    .map_err(|e| adapt_client_error(&e))?;

    client
        .cancel(target_protocol, &target_ip, target_port, session_id)
        .await
        .map_err(|e| adapt_client_error(&e))?;

    Ok(())
}

/// 本地取消：触发指定会话的 CancellationToken（不向远端发请求）。
pub fn cancel_transfer(state: &BridgeState, session_id: &str) {
    if let Some(cancel) = state.active_transfers.get(session_id) {
        log::debug!("[CANCEL] Triggering cancel for session={}", session_id);
        cancel.cancel();
    } else {
        log::debug!(
            "[CANCEL] No active_transfers entry for session={}",
            session_id
        );
    }
}

// ── 发现注册（支持 mTLS）────────────────────────────────────────

/// 通过 HTTP/HTTPS 向远程设备注册本设备（支持 mTLS）。
#[allow(clippy::too_many_arguments)]
pub async fn register_device(
    state: &Mutex<BridgeState>,
    target_ip: &str,
    target_port: u16,
    our_alias: &str,
    our_fingerprint: &str,
    our_protocol: &str,
    our_device_model: &str,
    our_device_type: &str,
    our_port: u16,
    _our_ip: &str,
) -> Result<String, BridgeError> {
    let (cert_pem, key_pem) = {
        let s = state.lock().unwrap();
        (s.cert_pem.clone(), s.key_pem.clone())
    };

    let protocol_enum = identity::parse_protocol(our_protocol);

    let payload = RegisterDto {
        alias: our_alias.to_string(),
        version: PROTOCOL_VERSION_V2.to_string(),
        device_model: if our_device_model.is_empty() {
            None
        } else {
            Some(our_device_model.to_string())
        },
        device_type: Some(identity::parse_device_type(our_device_type)),
        token: our_fingerprint.to_string(),
        port: our_port,
        protocol: protocol_enum,
        has_web_interface: false,
    };

    // 优先 our_protocol，再回退到另一种
    let protocols_to_try: Vec<localsend::model::discovery::ProtocolType> = match protocol_enum {
        localsend::model::discovery::ProtocolType::Https => vec![
            localsend::model::discovery::ProtocolType::Https,
            localsend::model::discovery::ProtocolType::Http,
        ],
        localsend::model::discovery::ProtocolType::Http => vec![
            localsend::model::discovery::ProtocolType::Http,
            localsend::model::discovery::ProtocolType::Https,
        ],
    };

    let client = LsHttpClient::new(
        &key_pem,
        &cert_pem,
        LsHttpClientVersion::V2,
        None,
        Some(Duration::from_secs(5)),
    )
    .map_err(|e| BridgeError::Upstream(anyhow::anyhow!("客户端创建失败: {e:#}")))?;

    let mut last_error = String::from("No protocol attempted");

    for proto in &protocols_to_try {
        match client
            .register(*proto, target_ip, target_port, payload.clone())
            .await
        {
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
                    "Register OK: {} at {}:{} via {}",
                    resp.alias,
                    target_ip,
                    target_port,
                    resp_protocol
                );
                return Ok(ret.to_string());
            }
            Err(e) => {
                last_error =
                    format!("{proto:?} register to {target_ip}:{target_port} failed: {e:#}");
                log::debug!("{}", last_error);
                continue;
            }
        }
    }

    Err(BridgeError::Upstream(anyhow::anyhow!(
        "Register failed to {target_ip}:{target_port}: {last_error}"
    )))
}

// ── 客户端信息 ──────────────────────────────────────────────────────────

/// 从远程设备获取设备信息（GET /api/localsend/v2/info）。
pub async fn client_info(
    state: &Mutex<BridgeState>,
    protocol: localsend::model::discovery::ProtocolType,
    ip: &str,
    port: u16,
) -> Result<String, BridgeError> {
    let (cert_pem, key_pem) = {
        let s = state.lock().unwrap();
        (s.cert_pem.clone(), s.key_pem.clone())
    };

    let client = LsHttpClientV2::try_new(&key_pem, &cert_pem, None, Some(Duration::from_secs(5)))
        .map_err(|e| adapt_client_error(&e))?;

    let resp = client
        .info(protocol, ip, port)
        .await
        .map_err(|e| adapt_client_error(&e))?;

    let ret = json!({
        "alias": resp.alias,
        "version": resp.version,
        "deviceModel": resp.device_model.unwrap_or_default(),
        "deviceType": resp.device_type.as_ref().map(identity::device_type_to_string).unwrap_or("desktop"),
        "fingerprint": resp.fingerprint,
        "download": resp.download,
        "protocol": protocol.as_str(),
    });
    Ok(ret.to_string())
}

// ── 下载 API ────────────────────────────────────────────────────────────

/// 从远程设备准备一个下载会话（POST /api/localsend/v2/prepare-download）。
pub async fn prepare_download(
    state: &Mutex<BridgeState>,
    target_ip: &str,
    target_port: u16,
    target_protocol: localsend::model::discovery::ProtocolType,
    session_id: Option<String>,
    pin: Option<String>,
) -> Result<String, BridgeError> {
    let (cert_pem, key_pem) = {
        let s = state.lock().unwrap();
        (s.cert_pem.clone(), s.key_pem.clone())
    };

    let client = LsHttpClientV2::try_new(&key_pem, &cert_pem, None, Some(Duration::from_secs(10)))
        .map_err(|e| adapt_client_error(&e))?;

    let resp = client
        .prepare_download(
            target_protocol,
            target_ip,
            target_port,
            session_id.as_deref(),
            pin.as_deref(),
        )
        .await
        .map_err(|e| adapt_client_error(&e))?;

    let ret = json!({
        "info": {
            "alias": resp.info.alias,
            "version": resp.info.version,
            "deviceModel": resp.info.device_model.unwrap_or_default(),
            "deviceType": resp.info.device_type.as_ref().map(identity::device_type_to_string).unwrap_or("desktop"),
            "fingerprint": resp.info.fingerprint,
            "download": resp.info.download,
        },
        "sessionId": resp.session_id,
        "files": resp.files,
    });
    Ok(ret.to_string())
}

/// 从远程设备下载文件到本地路径（GET /api/localsend/v2/download）。
#[allow(clippy::too_many_arguments)]
pub async fn download_file(
    state: &Mutex<BridgeState>,
    target_ip: &str,
    target_port: u16,
    target_protocol: localsend::model::discovery::ProtocolType,
    session_id: &str,
    file_id: &str,
    save_path: &str,
    _public_key: Option<String>,
) -> Result<u64, BridgeError> {
    let (cert_pem, key_pem) = {
        let s = state.lock().unwrap();
        (s.cert_pem.clone(), s.key_pem.clone())
    };

    let client = LsHttpClientV2::try_new(&key_pem, &cert_pem, None, Some(Duration::from_secs(300)))
        .map_err(|e| adapt_client_error(&e))?;

    let response = client
        .download(target_protocol, target_ip, target_port, session_id, file_id)
        .await
        .map_err(|e| adapt_client_error(&e))?;

    let total_bytes_from_header = response
        .headers()
        .get(localsend::reqwest::header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(0);

    let file = tokio::fs::File::create(save_path)
        .await
        .map_err(BridgeError::Io)?;
    let mut writer = tokio::io::BufWriter::new(file);

    let event_tx = state.lock().unwrap().event_tx.clone();
    let sid = session_id.to_string();
    let fid = file_id.to_string();
    let last_update = std::sync::Arc::new(std::sync::Mutex::new(Instant::now()));
    let total_bytes = total_bytes_from_header;

    let event_tx_progress = event_tx.clone();
    let sid_progress = sid.clone();
    let fid_progress = fid.clone();
    let last_update_ref = last_update.clone();
    let mut bytes_written: u64 = 0;

    {
        let mut stream = response.bytes_stream();
        while let Some(chunk) = futures_util::StreamExt::next(&mut stream).await {
            let chunk =
                chunk.map_err(|e| BridgeError::Upstream(anyhow::anyhow!("下载流错误: {e}")))?;
            tokio::io::AsyncWriteExt::write_all(&mut writer, &chunk)
                .await
                .map_err(BridgeError::Io)?;
            bytes_written += chunk.len() as u64;

            let reported = bytes_written;
            let should_update = {
                let mut last = last_update_ref.lock().unwrap();
                let now = Instant::now();
                if now.duration_since(*last) >= Duration::from_millis(20) {
                    *last = now;
                    true
                } else {
                    false
                }
            };
            if should_update || reported >= total_bytes {
                let progress = if total_bytes > 0 {
                    reported as f64 / total_bytes as f64
                } else {
                    0.0
                };
                let event_tx_send = event_tx_progress.clone();
                let sid_clone = sid_progress.clone();
                let fid_clone = fid_progress.clone();
                tokio::spawn(async move {
                    send_event(
                        &event_tx_send,
                        BridgeEvent::UploadProgress {
                            session_id: sid_clone,
                            file_id: fid_clone,
                            direction: "send".to_string(),
                            progress,
                            speed: 0.0,
                        },
                    )
                    .await;
                });
            }
        }
    }

    tokio::io::AsyncWriteExt::flush(&mut writer)
        .await
        .map_err(BridgeError::Io)?;

    // 最终进度事件（100%）
    send_event(
        &event_tx,
        BridgeEvent::UploadProgress {
            session_id: sid.clone(),
            file_id: fid.clone(),
            direction: "send".to_string(),
            progress: 1.0,
            speed: 0.0,
        },
    )
    .await;

    log::debug!("Downloaded: {file_id} -> {save_path} ({bytes_written} bytes)");
    Ok(bytes_written)
}

// ── 缓冲区上传 ───────────────────────────────────────────────────────────

/// 上传内存缓冲区中的文件内容。
#[allow(clippy::too_many_arguments)]
pub async fn upload_from_buffer(
    state: &Mutex<BridgeState>,
    target_ip: &str,
    target_port: u16,
    target_protocol: localsend::model::discovery::ProtocolType,
    session_id: &str,
    file_id: &str,
    token: &str,
    buffer: Vec<u8>,
    _public_key: Option<String>,
    cancel_id: Option<String>,
) -> Result<(), BridgeError> {
    let (cert_pem, key_pem) = {
        let s = state.lock().unwrap();
        (s.cert_pem.clone(), s.key_pem.clone())
    };

    {
        let s = state.lock().unwrap();
        let mut sid = s.current_send_session_id.lock().unwrap();
        *sid = session_id.to_string();
    }

    let client = LsHttpClient::new(
        &key_pem,
        &cert_pem,
        LsHttpClientVersion::V2,
        None,
        Some(Duration::from_secs(300)),
    )
    .map_err(|e| adapt_client_error(&e))?;

    let total_bytes = buffer.len() as u64;
    let (tx, rx) = tokio::sync::mpsc::channel(1);
    tx.send(bytes::Bytes::from(buffer))
        .await
        .map_err(|e| BridgeError::Upstream(anyhow::anyhow!("缓冲区发送到流失败: {e}")))?;
    drop(tx);

    let content = FileContent::Stream(rx);

    let cancel = match cancel_id {
        Some(id) => {
            let s = state.lock().unwrap();
            match s.cancel_tokens.get(&id) {
                Some(t) => t.clone(),
                None => tokio_util::sync::CancellationToken::new(),
            }
        }
        None => tokio_util::sync::CancellationToken::new(),
    };

    {
        let mut s = state.lock().unwrap();
        s.active_transfers
            .insert(session_id.to_string(), cancel.clone());
    }

    let event_tx = state.lock().unwrap().event_tx.clone();
    let sid = session_id.to_string();
    let fid = file_id.to_string();
    let total = total_bytes;
    let last_update = std::sync::Arc::new(std::sync::Mutex::new(Instant::now()));

    let event_tx_progress = event_tx.clone();
    let sid_progress = sid.clone();
    let fid_progress = fid.clone();
    let last_update_ref = last_update.clone();
    let progress = move |sent: u64| {
        let reported = if total > 0 { sent.min(total - 1) } else { 0 };
        let should_update = {
            let mut last = last_update_ref.lock().unwrap();
            let now = Instant::now();
            if now.duration_since(*last) >= Duration::from_millis(20) {
                *last = now;
                true
            } else {
                false
            }
        };
        if should_update || sent >= total {
            let progress = if total > 0 {
                reported as f64 / total as f64
            } else {
                0.0
            };
            let event_tx_send = event_tx_progress.clone();
            let sid_clone = sid_progress.clone();
            let fid_clone = fid_progress.clone();
            tokio::spawn(async move {
                send_event(
                    &event_tx_send,
                    BridgeEvent::UploadProgress {
                        session_id: sid_clone,
                        file_id: fid_clone,
                        direction: "send".to_string(),
                        progress,
                        speed: 0.0,
                    },
                )
                .await;
            });
        }
    };

    let result = client
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
        let mut s = state.lock().unwrap();
        s.active_transfers.remove(session_id);
    }

    match result {
        Ok(_) => {
            send_event(
                &event_tx,
                BridgeEvent::UploadProgress {
                    session_id: sid.clone(),
                    file_id: fid.clone(),
                    direction: "send".to_string(),
                    progress: 1.0,
                    speed: 0.0,
                },
            )
            .await;
            Ok(())
        }
        Err(e) => {
            let msg = format!("{e:#}");
            send_event(
                &event_tx,
                BridgeEvent::Error {
                    context: format!("upload_buffer:{session_id}:{file_id}"),
                    message: msg.clone(),
                },
            )
            .await;
            Err(BridgeError::Upstream(anyhow::anyhow!(
                "缓冲区上传失败: {msg}"
            )))
        }
    }
}

// ── 单元测试 ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bridge::state::BridgeState;

    #[test]
    fn test_cancel_transfer_existing_session() {
        let mut state = BridgeState::new();
        let cancel = tokio_util::sync::CancellationToken::new();
        state
            .active_transfers
            .insert("session-1".to_string(), cancel.clone());
        cancel_transfer(&state, "session-1");
        assert!(cancel.is_cancelled());
    }

    #[test]
    fn test_cancel_transfer_nonexistent_session() {
        let state = BridgeState::new();
        // 不应 panic
        cancel_transfer(&state, "nonexistent");
    }

    #[test]
    fn test_prepare_send_invalid_files_json() {
        let state = Mutex::new(BridgeState::new());
        let result = tokio::runtime::Runtime::new().unwrap().block_on(async {
            prepare_send(
                &state,
                "192.168.1.5",
                53317,
                localsend::model::discovery::ProtocolType::Http,
                "not json",
                None,
                None,
                None,
            )
            .await
        });
        assert!(matches!(result, Err(BridgeError::InvalidArgument(_))));
    }

    #[test]
    fn test_send_files_invalid_target_json() {
        let state = Mutex::new(BridgeState::new());
        let result = tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(async { send_files(&state, "not json", "alias", "[]").await });
        assert!(matches!(result, Err(BridgeError::InvalidArgument(_))));
    }

    #[test]
    fn test_register_device_invalid_protocol_falls_back() {
        let state = Mutex::new(BridgeState::new());
        // 未初始化身份时创建客户端失败 → Upstream 错误
        let result = tokio::runtime::Runtime::new().unwrap().block_on(async {
            register_device(
                &state,
                "192.168.1.5",
                53317,
                "alias",
                "fp",
                "https",
                "model",
                "mobile",
                53317,
                "192.168.1.1",
            )
            .await
        });
        assert!(result.is_err());
    }

    #[test]
    fn test_cancel_transfer_remote_invalid_target() {
        let state = Mutex::new(BridgeState::new());
        let result = tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(async { cancel_transfer_remote(&state, "not json", "sess").await });
        assert!(matches!(result, Err(BridgeError::InvalidArgument(_))));
    }
}
