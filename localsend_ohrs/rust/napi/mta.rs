//! MTA 发送端服务器 NAPI 入口。
//!
//! 仅暴露 ArkTS 实际使用的两个函数：`nativeMtaStartServer` / `nativeMtaStopServer`。
//! 服务器事件（`mta*`）经统一的 event_forwarder 推送到 ArkTS。

use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::*;

use crate::bridge::mta;
use crate::napi::env::NapiEnv;

/// 启动 MTA 发送端服务器（含 ZIP 预打包），返回 `{"port":<实际绑定端口>}` JSON 文本。
#[napi]
pub async fn native_mta_start_server(config_json: String) -> Result<String> {
    let env = NapiEnv::global();
    // 确保事件通道存在（Mta* 事件依赖 state.event_tx）
    env.ensure_event_channel();
    let port = mta::start_server(env.state, &config_json)
        .await
        .map_err(|e| Error::from_reason(format!("启动 MTA 服务器失败: {e:#}")))?;
    Ok(format!("{{\"port\":{port}}}"))
}

/// 停止 MTA 发送端服务器（幂等；不删除 ZIP 文件）。
#[napi]
pub fn native_mta_stop_server() -> Result<()> {
    mta::stop_server();
    Ok(())
}
