//! 发送 / 接收 / 取消 NAPI 入口。
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
pub async fn send_files(
    target: String,
    sender_alias: String,
    files: String,
    send_key: String,
) -> Result<SendResult> {
    let env = NapiEnv::global();
    // 确保事件通道存在（幂等）——发送进度事件（UploadProgress）依赖它
    env.ensure_event_channel();
    let state = env.state;
    let json_str = client::send_files(state, &target, &sender_alias, &files, &send_key)
        .await
        .map_err(|e| Error::from_reason(format!("Send files failed: {e:#}")))?;
    serde_json::from_str(&json_str)
        .map_err(|e| Error::from_reason(format!("Parse SendResult failed: {e:#}")))
}

/// 本地取消：按取消键触发 CancellationToken。
///
/// 局域网发送传会话专属 sendKey（与 `send_files` 下传的键一致），
/// 其他场景传对应的会话标识。
#[napi]
pub fn cancel_transfer(cancel_key: String) -> Result<()> {
    log::debug!("本地取消已调用 取消键={}", cancel_key);
    let state = NapiEnv::global().state;
    let s = lock(state);
    client::cancel_transfer(&s, &cancel_key);
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

/// 从远程设备获取设备信息。
#[napi]
pub async fn client_info(protocol: String, ip: String, port: u16) -> Result<String> {
    let protocol_enum = identity::parse_protocol(&protocol);
    let state = NapiEnv::global().state;
    client::client_info(state, protocol_enum, &ip, port)
        .await
        .map_err(|e| Error::from_reason(format!("Client info failed: {e:#}")))
}
