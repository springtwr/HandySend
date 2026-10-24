//! 服务器 / 传输决策 NAPI 入口（设备对设备 v2；网页走独立 `web` 服务）。
//!
//! 保持与旧 napi_entry.rs 相同的函数签名（ArkTS 侧调用不变）。

use crate::bridge::lock;
use napi_derive_ohos::napi;

use std::sync::Arc;

use napi_ohos::bindgen_prelude::*;

use crate::bridge::server;
use crate::napi::env::NapiEnv;
use crate::napi::{ServerHandle, ServerStatus, TransferRequest};

/// 从 JSON 配置创建服务器（含身份初始化）。
#[napi]
pub async fn create_server(config: String) -> Result<ServerHandle> {
    let env = NapiEnv::global();
    // 确保事件通道存在（幂等）——桥接层事件循环依赖 state.event_tx
    env.ensure_event_channel();
    let state = Arc::clone(env.state);
    let json_str = server::create_server(state, &config)
        .await
        .map_err(|e| Error::from_reason(format!("Create server failed: {e:#}")))?;
    serde_json::from_str(&json_str)
        .map_err(|e| Error::from_reason(format!("Parse ServerHandle failed: {e:#}")))
}

/// 停止服务器（幂等）。
#[napi]
pub fn stop_server() -> Result<()> {
    let state = NapiEnv::global().state;
    server::stop_server(state);
    log::info!("服务器已停止");
    Ok(())
}

/// 响应传输（接受或拒绝）。
///
/// ArkTS 侧统一通过 `respondTransfer(sessionId, accept, fileIds)` 响应
/// PrepareUpload——`accept=true` 接受全部/部分文件，`accept=false` 拒绝。
/// （桥接层内部使用 accept_transfer/decline_transfer 两个专用函数，NAPI
/// 层收敛为单一入口，避免冗余导出。）
#[napi]
pub fn respond_transfer(
    session_id: String,
    accept: bool,
    accepted_file_ids: Vec<String>,
) -> Result<()> {
    let state = NapiEnv::global().state;
    if accept {
        server::accept_transfer(state, &session_id, &accepted_file_ids)
    } else {
        server::decline_transfer(state, &session_id)
    }
    .map_err(|e| Error::from_reason(format!("Respond transfer failed: {e:#}")))?;
    Ok(())
}

/// 预注册接收文件的直写目标 fd（ArkTS 在 respondTransfer 前逐文件调用）。
#[napi]
pub fn register_recv_file_fd(
    session_id: String,
    file_id: String,
    fd: i32,
    path: String,
) -> Result<()> {
    let state = NapiEnv::global().state;
    server::register_recv_file_fd(state, &session_id, &file_id, fd, &path)
        .map_err(|e| Error::from_reason(format!("Register recv file fd failed: {e:#}")))?;
    Ok(())
}

/// 丢弃某会话已注册但未开始上传的直写 fd（respond 失败/回滚时调用，关闭 fd）。
#[napi]
pub fn discard_recv_file_fds(session_id: String) -> Result<()> {
    let state = NapiEnv::global().state;
    server::discard_recv_file_fds(state, &session_id);
    Ok(())
}

/// 获取服务器状态。
#[napi]
pub fn get_server_status() -> ServerStatus {
    let state = NapiEnv::global().state;
    let s = lock(state);
    let json_str = server::get_server_status(&s);
    serde_json::from_str(&json_str).unwrap_or(ServerStatus {
        running: false,
        active_session: None,
        fingerprint: None,
    })
}

/// 获取当前发送会话 ID。
#[napi]
pub fn get_current_send_session_id() -> String {
    let state = NapiEnv::global().state;
    let s = lock(state);
    server::get_current_send_session_id(&s)
}

/// 轮询待处理请求。
#[napi]
pub fn poll_pending_requests() -> Vec<TransferRequest> {
    let state = NapiEnv::global().state;
    let s = lock(state);
    let requests = server::poll_pending_requests(&s);
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
                .map(|f| crate::napi::TransferFileInfo {
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

/// 取消本地会话。
#[napi]
pub fn cancel_local_session(session_id: String) -> Result<()> {
    let env = NapiEnv::global();
    server::cancel_local_session(&env.runtime, env.state, &session_id);
    Ok(())
}

/// 将待处理的文件上传标记为失败（导致 500 响应）。
#[napi]
pub fn fail_file_upload(session_id: String, file_id: String) -> Result<()> {
    let state = NapiEnv::global().state;
    server::fail_file_upload(state, &session_id, &file_id)
        .map_err(|e| Error::from_reason(format!("Fail file upload failed: {e:#}")))?;
    Ok(())
}
