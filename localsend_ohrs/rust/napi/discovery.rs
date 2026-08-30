//! 发现 NAPI 入口。
//!
//! 保持与旧 napi_entry.rs 相同的函数签名（ArkTS 侧调用不变）。

use napi_derive_ohos::napi;

use std::sync::Arc;

use napi_ohos::bindgen_prelude::*;

use crate::bridge::discovery;
use crate::bridge::identity;
use crate::napi::env::NapiEnv;

/// 以完整配置启动发现。
#[napi]
pub async fn start_discovery_v2(config: String) -> Result<()> {
    identity::init_hilog_logger();
    // 确保事件通道存在（幂等）——发现事件（DeviceFound/DeviceLost）依赖它
    let env = NapiEnv::global();
    env.ensure_event_channel();
    let state = Arc::clone(env.state);
    discovery::start_discovery_v2(state, &config)
        .await
        .map_err(|e| Error::from_reason(format!("Start discovery v2 failed: {e:#}")))?;
    log::info!("Discovery v2 started");
    Ok(())
}

/// 分阶段发现设备。
#[napi]
pub async fn discovery_discover_staged(
    channels: String,
    interface_ips: String,
    port: u16,
    protocol: String,
    grace_ms: u32,
) -> Result<()> {
    let state = NapiEnv::global().state;
    discovery::discovery_discover_staged(
        state,
        &channels,
        &interface_ips,
        port,
        &protocol,
        grace_ms,
    )
    .await
    .map_err(|e| Error::from_reason(format!("Discovery discover_staged failed: {e:#}")))?;
    Ok(())
}

/// 扫描指定网卡的 /24 子网。
#[napi]
pub async fn discovery_scan_subnet(
    interface_ip: String,
    port: u16,
    protocol: String,
) -> Result<()> {
    let state = NapiEnv::global().state;
    discovery::discovery_scan_subnet(state, &interface_ip, port, &protocol)
        .await
        .map_err(|e| Error::from_reason(format!("Discovery scan_subnet failed: {e:#}")))?;
    Ok(())
}

/// 将发现流程之外确认的设备加入存储。
#[napi]
pub async fn discovery_add_device(device: String) -> Result<()> {
    let state = NapiEnv::global().state;
    discovery::discovery_add_device(state, &device)
        .await
        .map_err(|e| Error::from_reason(format!("Discovery add_device failed: {e:#}")))?;
    Ok(())
}

/// 设置是否应答其他设备的广播。
#[napi]
pub fn discovery_set_answer_announcements(answer: bool) -> Result<()> {
    let state = NapiEnv::global().state;
    let s = state.lock().unwrap();
    discovery::discovery_set_answer_announcements(&s, answer).map_err(|e| {
        Error::from_reason(format!("Discovery set_answer_announcements failed: {e:#}"))
    })?;
    Ok(())
}

/// 停止发现并释放所有套接字。
#[napi]
pub fn discovery_stop() -> Result<()> {
    let state = NapiEnv::global().state;
    discovery::stop_discovery(state);
    log::info!("Discovery stopped");
    Ok(())
}

/// 按指纹以 JSON 获取单个设备。
#[napi]
pub fn discovery_get_device(fingerprint: String) -> String {
    let state = NapiEnv::global().state;
    let s = state.lock().unwrap();
    discovery::discovery_get_device(&s, &fingerprint)
}

/// 获取组播错误（若有）。
#[napi]
pub fn discovery_multicast_error() -> String {
    let state = NapiEnv::global().state;
    let s = state.lock().unwrap();
    discovery::discovery_multicast_error(&s)
}
