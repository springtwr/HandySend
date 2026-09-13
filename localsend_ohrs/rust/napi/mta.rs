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

/// 读取 ZIP 中央目录中各条目的修改时间，返回 JSON 文本 `[{entryName, modifiedUnixMs}]`。
///
/// 解析失败时返回空数组并记日志，不抛出到 ArkTS 接收主流程。
#[napi]
pub fn native_mta_read_zip_entry_times(zip_path: String) -> Result<String> {
    match mta::read_zip_entry_times(&zip_path) {
        Ok(json) => Ok(json),
        Err(e) => {
            log::warn!("读取 ZIP 条目时间失败 {zip_path}: {e:#}");
            Ok("[]".to_string())
        }
    }
}
