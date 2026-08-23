//! 客户端门面——处理所有客户端操作（发送、上传、注册、取消）。
//!
//! 从 facade.rs 抽出，保持各门面模块职责聚焦。

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

// ── 发送操作 ──────────────────────────────────────────────────────────

pub async fn prepare_send(
    target_ip: &str,
    target_port: u16,
    target_protocol: ProtocolType,
    files_json: &str,
    pin: Option<String>,
    expected_fingerprint: Option<String>,
    public_key: Option<String>,
) -> Result<String> {
    log::debug!("[DBG-SEND] prepare_send: ip={} port={} proto={:?} has_fp={} has_pk={}",
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
    log::debug!("[DBG-SEND]   cert_pem.len={} key_pem.len={} local_fp={}",
        cert_pem.len(), key_pem.len(), fingerprint.chars().take(8).collect::<String>());

    let files: Vec<FileDto> = serde_json::from_str(files_json)?;
    let files_map: HashMap<String, FileDto> = files
        .into_iter()
        .map(|f| (f.id.clone(), f))
        .collect();
    log::debug!("[DBG-SEND]   files_count={}", files_map.len());

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
    log::debug!("[DBG-SEND]   payload.info.protocol={:?}", payload.info.protocol);

    let client = LsHttpClient::new(
        &key_pem,
        &cert_pem,
        LsHttpClientVersion::V2,
        expected_fingerprint,
        Some(Duration::from_secs(10)),
    )?;
    log::debug!("[DBG-SEND]   LsHttpClient created OK");

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

    // 无论成功或失败，始终清理 prepare_ 临时键
    {
        let mut state = bridge().lock().unwrap();
        state.active_transfers.remove(&temp_key);
    }

    let result = result.map_err(|e| {
        log::error!("[DBG-SEND]   prepare_upload FAILED: {e:#}");
        // 使用 Error::from 保留原始 ClientError 类型，
        // 以便 send_files 中的 downcast_ref 能恢复它用于结构化错误上报。
        anyhow::Error::from(e)
    })?;

    log::debug!("[DBG-SEND]   prepare_upload OK: status={}", result.status_code);

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
    log::debug!("[DBG-UPLOAD] upload_file: ip={} port={} proto={:?} session={} file_id={} path={}",
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

    // 进度闭包：钳制上报的 bytes_sent 不超过 total-1，
    // 防止小文件在 HTTP 请求完成前就上报 100%。
    // 100% 仅由 upload 成功后的最终 ProgressEntry 报告。
    let progress = move |sent: u64| {
        let reported = if total > 0 { sent.min(total - 1) } else { 0 };
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
                    bytes_sent: reported,
                    total_bytes: total,
                    file_path: fp.clone(),
                },
            );
            drop(map);
            // 通过回调推送 progress_update 事件
            if let Some(ref cb) = cb_progress {
                let payload = json!({
                    "type": "progress_update",
                    "direction": "send",
                    "sessionId": sid,
                    "fileId": fid,
                    "bytesSent": reported,
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

    // 完成后清理进行中的传输条目
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
                // 推送最终 progress_update 事件（100% 完成，上传结束）
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

            // 推送 upload_finished 事件
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

            // 推送 upload_failed 事件
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

// ── 高级 API ──────────────────────────────────────────────────────────

pub async fn send_files(
    target_json: &str,
    _sender_alias: &str,
    files_json: &str,
) -> Result<String> {
    log::debug!("[DBG-SEND-FILES] send_files: target_json={} files_count={}",
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

// ── 远程取消 ────────────────────────────────────────────────────────────

pub async fn cancel_transfer_remote(target_json: &str, session_id: &str) -> Result<()> {
    let target: Value = serde_json::from_str(target_json)?;
    let target_ip = target["ip"].as_str().unwrap_or("").to_string();
    let target_port = target["port"].as_u64().unwrap_or(53317) as u16;
    let target_protocol = parse_protocol_helper(target["protocol"].as_str().unwrap_or("https"));

    log::debug!(
        "[CANCEL] Sending cancel to {}://{}:{} session_id={:?}",
        target_protocol.as_str(),
        target_ip,
        target_port,
        session_id,
    );

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

    let result = client
        .cancel(target_protocol, &target_ip, target_port, session_id)
        .await;

    match &result {
        Ok(()) => log::debug!("[CANCEL] Cancel request succeeded"),
        Err(e) => log::debug!("[CANCEL] Cancel request failed: {e}"),
    }

    result.map_err(|e| anyhow::anyhow!("{e}"))?;

    Ok(())
}

// ── 发现注册（支持 mTLS） ────────────────────────────────────────

/// 通过 HTTP/HTTPS 向远程设备注册本设备。
///
/// 这是 ArkTS `tryTcpRegister` / `scanSubnetOnInterface` 的 Rust 侧等价实现
/// 注册调用，但具备完整的 mTLS 支持。ArkTS HTTP 客户端无法提供
/// 客户端证书，因此所有 HTTPS 注册请求都必须经过此函数。
///
/// 依次尝试 HTTPS 和 HTTP 协议（顺序由 `our_protocol` 偏好决定）。
/// 成功时返回包含远程设备信息的 JSON，失败时返回错误字符串。
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

    // 构建注册请求负载
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

    // 尝试协议：优先 our_protocol，再回退到另一种
    let protocols_to_try: Vec<ProtocolType> = match protocol_enum {
        ProtocolType::Https => vec![ProtocolType::Https, ProtocolType::Http],
        ProtocolType::Http => vec![ProtocolType::Http, ProtocolType::Https],
    };

    // 只创建一次客户端——它与协议无关，可同时处理 HTTP 和 HTTPS
    let client = match LsHttpClient::new(
        &key_pem,
        &cert_pem,
        LsHttpClientVersion::V2,
        None, // 发现/注册时不固定期望指纹
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

// ── 客户端信息 ──────────────────────────────────────────────────────────────

/// 通过 HTTP/HTTPS 从远程设备获取设备信息。
/// 对目标调用 GET /api/localsend/v2/info。
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

/// 从远程设备准备一个下载会话（Download API）。
/// 调用 POST /api/localsend/v2/prepare-download。
/// 返回包含发送方信息、sessionId 和文件映射的 JSON。
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

/// 从远程设备下载文件到本地路径（Download API）。
/// 调用 GET /api/localsend/v2/download?sessionId=...&fileId=...
/// 将响应体流式写入指定文件路径。
/// 在进度回调中使用 Content-Length 头作为 totalBytes。
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

    // 先获取响应以提取 Content-Length
    let response = client
        .download(target_protocol, target_ip, target_port, session_id, file_id)
        .await
        .map_err(|e| anyhow::anyhow!("Download request failed: {e:#}"))?;

    // 提取 Content-Length 用于进度上报
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

    // 手动流式处理响应体以跟踪进度
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

    // 带实际总量的最终进度事件
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

    log::debug!("Downloaded: {file_id} -> {save_path} ({bytes_written} bytes)");
    Ok(bytes_written)
}

// ── 缓冲区上传 ───────────────────────────────────────────────────────────

/// 上传内存缓冲区中的文件内容。
/// 从缓冲区数据创建一个单块流。
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

    // 进度闭包：钳制上报的 bytes_sent 不超过 total-1，
    // 防止小文件在 HTTP 请求完成前就上报 100%。
    // 100% 仅由 upload 成功后的最终 ProgressEntry 报告。
    let progress = move |sent: u64| {
        let reported = if total > 0 { sent.min(total - 1) } else { 0 };
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
                    bytes_sent: reported,
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
                    "bytesSent": reported,
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
                // 推送最终 progress_update 事件（100% 完成）
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

            // 推送 upload_finished 事件
            if let Some(ref cb) = callback {
                let payload = json!({
                    "type": "upload_finished",
                    "sessionId": session_id,
                    "fileId": file_id,
                });
                cb.call(payload.to_string());
            }

            log::debug!("Buffer uploaded: {} -> {}", file_id, session_id);
            Ok(())
        }
        Err(e) => {
            let err_msg = format!("{e:#}");

            // 推送 upload_failed 事件（与 upload_file 行为一致）
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
