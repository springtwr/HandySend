//! 发送 / 接收 / 取消 / 注册 NAPI 入口。
//!
//! 保持与旧 napi_entry.rs 相同的函数签名（ArkTS 侧调用不变）。

use crate::bridge::lock;
use napi_derive_ohos::napi;

use napi_ohos::bindgen_prelude::*;

use crate::bridge::client;
use crate::bridge::identity;
use crate::napi::env::NapiEnv;
use crate::napi::SendResult;

/// 发送文件到目标设备。
#[napi]
pub async fn send_files(target: String, sender_alias: String, files: String) -> Result<SendResult> {
    let env = NapiEnv::global();
    // 确保事件通道存在（幂等）——发送进度事件（UploadProgress）依赖它
    env.ensure_event_channel();
    let state = env.state;
    let json_str = client::send_files(state, &target, &sender_alias, &files)
        .await
        .map_err(|e| Error::from_reason(format!("Send files failed: {e:#}")))?;
    serde_json::from_str(&json_str)
        .map_err(|e| Error::from_reason(format!("Parse SendResult failed: {e:#}")))
}

/// 本地取消：触发 CancellationToken。
#[napi]
pub fn cancel_transfer(session_id: String) -> Result<()> {
    log::debug!("cancel_transfer called, session_id={}", session_id);
    let state = NapiEnv::global().state;
    let s = lock(state);
    client::cancel_transfer(&s, &session_id);
    Ok(())
}

/// 向远端发送取消请求。
#[napi]
pub async fn cancel_transfer_remote(target: String, session_id: String) -> Result<()> {
    let state = NapiEnv::global().state;
    client::cancel_transfer_remote(state, &target, &session_id)
        .await
        .map_err(|e| Error::from_reason(format!("Cancel transfer remote failed: {e:#}")))
}

/// 通过 HTTP/HTTPS 向远程设备注册本设备（支持 mTLS）。
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
    let state = NapiEnv::global().state;
    client::register_device(
        state,
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

/// 从远程设备获取设备信息。
#[napi]
pub async fn client_info(protocol: String, ip: String, port: u16) -> Result<String> {
    let protocol_enum = identity::parse_protocol(&protocol);
    let state = NapiEnv::global().state;
    client::client_info(state, protocol_enum, &ip, port)
        .await
        .map_err(|e| Error::from_reason(format!("Client info failed: {e:#}")))
}
