//! 发现门面——处理所有发现（UDP 组播 + HTTP 注册）操作。
//!
//! 本模块包装上游 `localsend::discovery` 模块并暴露
//! 通过 NAPI 提供完整的发现 API。
//!
//! 参考：FRB discovery.rs（`localsend_isolates/rust/src/api/discovery.rs`）

use std::net::Ipv4Addr;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use serde_json::{json, Value};

use localsend::discovery::{
    self, DeviceChannel, DeviceIdentity, DiscoveredDevice, DiscoveryConfig, DiscoveryEvent,
    DiscoveryHandle,
};
use localsend::model::discovery::{ProtocolType, PROTOCOL_VERSION_V2};
use localsend::multicast::MulticastDevice;
use localsend::util::interface::InterfaceFilter;

use crate::bridge::callback::EventCallback;
use crate::bridge::facade::{device_to_json, parse_device_type};
use crate::bridge::state::bridge;

// ── 发现生命周期 ──────────────────────────────────────────────────────

/// 以完整配置启动发现。
///
/// 接受 JSON 配置字符串，包含：
/// - alias、fingerprint、port、protocol、multicastGroup
/// - networkWhitelist/networkBlacklist（可选）
/// - discoveryTimeoutMs
///
/// 热重启：启动新实例前先停止之前的发现实例，
/// 与 FRB 的 `RUNNING_DISCOVERY` 模式一致。
pub async fn start_discovery_v2(config_json: &str) -> Result<()> {
    crate::bridge::facade::init_hilog_logger();
    {
        let state = bridge().lock().unwrap();
        log::debug!(
            "[DISC] TLS 身份: cert_len={} key_len={} fingerprint_len={}",
            state.cert_pem.len(),
            state.key_pem.len(),
            state.fingerprint.len()
        );
    }
    log::debug!(
        "[DBG-DISC] start_discovery_v2: config={}",
        config_json.chars().take(200).collect::<String>()
    );
    let config: Value = serde_json::from_str(config_json)?;

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

    // 热重启：如果旧发现正在运行则先停止
    {
        let mut state = bridge().lock().unwrap();
        if state.discovery_handle.is_some() {
            log::debug!("Hot-restart: stopping previous discovery instance");
            // 取消事件任务
            if let Some(event_task) = state.discovery_event_task.take() {
                event_task.abort();
            }
            // 发送停止信号
            if let Some(stop_tx) = state.discovery_stop_tx.take() {
                let _ = stop_tx.send(());
            }
            state.discovery_handle.take();
        }
    }

    let port = config["port"].as_u64().unwrap_or(53317) as u16;
    let protocol_str = config["protocol"].as_str().unwrap_or("https");
    let protocol = match protocol_str.to_lowercase().as_str() {
        "http" => ProtocolType::Http,
        _ => ProtocolType::Https,
    };
    let multicast_group = config["multicastGroup"].as_str().unwrap_or("224.0.0.167");
    let download = config["download"].as_bool().unwrap_or(true);

    let whitelist = config["networkWhitelist"].as_array().map(|arr| {
        arr.iter()
            .filter_map(|v| v.as_str().map(|s| s.to_string()))
            .collect::<Vec<String>>()
    });
    let blacklist = config["networkBlacklist"].as_array().map(|arr| {
        arr.iter()
            .filter_map(|v| v.as_str().map(|s| s.to_string()))
            .collect::<Vec<String>>()
    });
    let timeout_ms = config["discoveryTimeoutMs"].as_u64().unwrap_or(3000);

    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    let (event_tx, event_rx) = tokio::sync::mpsc::channel::<DiscoveryEvent>(128);

    let device = MulticastDevice {
        alias,
        version: PROTOCOL_VERSION_V2.to_string(),
        device_model: Some(device_model),
        device_type: Some(device_type),
        fingerprint: fingerprint.clone(),
        port,
        protocol,
        download,
    };

    let identity = DeviceIdentity {
        cert_pem,
        private_key_pem: key_pem,
    };

    let group = multicast_group
        .parse()
        .map_err(|_| anyhow::anyhow!("Invalid multicast group: {multicast_group}"))?;

    let config = DiscoveryConfig {
        group,
        // IPv6 组播已禁用：对端会通过其
        // IPv6 地址（链路本地 fe80:: 或全局地址），但
        // IPv6 路径在 HarmonyOS 上不可靠，导致
        // 发送和接收。IPv4 发现完全可用。
        group_v6: None,
        // 组播 socket 端口跟随配置端口（与官方 LocalSend 一致：
        // 官方将“端口”设置同时作用于 HTTP server 与 UDP 组播）。
        // 若固定 53317，则双方改为同一非默认端口后组播端口错位，
        // 互相收不到 announce，导致无法发现设备。
        port,
        interface_filter: InterfaceFilter {
            whitelist,
            blacklist,
        },
        device,
        identity,
        timeout: Duration::from_millis(timeout_ms),
        event_tx: Some(event_tx),
    };

    let handle = Arc::new(discovery::start(config, stop_rx).await);

    // 启动事件监听任务
    let callback = {
        let state = bridge().lock().unwrap();
        state.callback.clone()
    };

    let event_task = start_event_listener_with_callback(event_rx, callback, handle.clone());

    {
        let mut state = bridge().lock().unwrap();
        state.discovery_handle = Some(handle);
        state.discovery_stop_tx = Some(stop_tx);
        state.discovery_event_task = Some(event_task);
    }

    Ok(())
}

/// 启动事件监听任务，通过回调将发现事件转发给 ArkTS。
pub fn start_event_listener_with_callback(
    mut event_rx: tokio::sync::mpsc::Receiver<DiscoveryEvent>,
    callback: Option<EventCallback>,
    handle: Arc<DiscoveryHandle>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        while let Some(event) = event_rx.recv().await {
            match event {
                DiscoveryEvent::Discovered { ref device } => {
                    log::debug!(
                        "[DBG-DISC-EVT] Discovered: fp={} alias={}",
                        device.fingerprint.chars().take(8).collect::<String>(),
                        device.alias
                    );
                    // 只发送新发现的设备（而非完整列表），
                    // 与 LocalSend Flutter 的 RegisterDeviceAction 模式一致。
                    // 由 ArkTS 侧负责合并到本地列表。
                    if let Some(stored) = handle.device_by_fingerprint(&device.fingerprint) {
                        let device_json = device_to_json(&stored);
                        let payload = json!({
                            "type": "device_found",
                            "device": device_json,
                        });
                        if let Some(ref cb) = callback {
                            cb.call(payload.to_string());
                        }
                    }
                }
                DiscoveryEvent::Updated { ref device } => {
                    log::debug!(
                        "[DBG-DISC-EVT] Updated: fp={} alias={}",
                        device.fingerprint.chars().take(8).collect::<String>(),
                        device.alias
                    );
                    // 只发送更新的设备
                    if let Some(stored) = handle.device_by_fingerprint(&device.fingerprint) {
                        let device_json = device_to_json(&stored);
                        let payload = json!({
                            "type": "device_found",
                            "device": device_json,
                        });
                        if let Some(ref cb) = callback {
                            cb.call(payload.to_string());
                        }
                    }
                }
            }
        }
        log::debug!("Discovery event listener task ended");
    })
}

/// 分阶段发现设备：广播 → 探测已知通道 → 等待宽限期 → 回退子网扫描。
pub async fn discovery_discover_staged(
    channels_json: &str,
    interface_ips_json: &str,
    port: u16,
    protocol: &str,
    grace_ms: u32,
) -> Result<()> {
    log::debug!("[DISC] discover_staged: channels={channels_json} interface_ips={interface_ips_json} port={port} protocol={protocol} grace_ms={grace_ms}");
    let t0 = std::time::Instant::now();
    let handle = {
        let state = bridge().lock().unwrap();
        state.discovery_handle.clone()
    };
    let handle = handle.ok_or_else(|| anyhow::anyhow!("Discovery not running"))?;

    let channels: Vec<Value> = serde_json::from_str(channels_json)?;
    let known_channels: Vec<localsend::discovery::HttpChannel> = channels
        .iter()
        .filter_map(|ch| {
            let host = ch["host"].as_str()?.to_string();
            let port = ch["port"].as_u64()? as u16;
            let protocol = match ch["protocol"].as_str().unwrap_or("https") {
                "http" => ProtocolType::Http,
                _ => ProtocolType::Https,
            };
            Some(localsend::discovery::HttpChannel {
                host,
                port,
                protocol,
            })
        })
        .collect();

    let interface_ips: Vec<String> = serde_json::from_str(interface_ips_json)?;
    let interface_ips: Vec<Ipv4Addr> = interface_ips
        .into_iter()
        .filter_map(|ip| ip.parse().ok())
        .collect();

    let protocol_enum = match protocol.to_lowercase().as_str() {
        "http" => ProtocolType::Http,
        _ => ProtocolType::Https,
    };

    let before = handle.devices().len();
    let before_fps: Vec<String> = handle
        .devices()
        .iter()
        .map(|d| d.device.fingerprint.chars().take(8).collect())
        .collect();
    log::debug!(
        "[DISC] discover_staged 开始: known_channels={} interface_ips={} 当前设备={} [{}]",
        known_channels.len(),
        interface_ips.len(),
        before,
        before_fps.join(",")
    );

    let result = handle
        .discover_staged(
            known_channels,
            interface_ips,
            port,
            protocol_enum,
            Duration::from_millis(grace_ms as u64),
        )
        .await;

    let elapsed = t0.elapsed().as_millis();
    match &result {
        Ok(()) => {
            let after = handle.devices().len();
            let after_fps: Vec<String> = handle
                .devices()
                .iter()
                .map(|d| d.device.fingerprint.chars().take(8).collect())
                .collect();
            log::debug!(
                "[DISC] discover_staged 完成: 耗时={elapsed}ms 设备 {before} → {after} [{}]",
                after_fps.join(",")
            );
        }
        Err(e) => {
            log::error!("[DISC] discover_staged 失败: 耗时={elapsed}ms 错误={e:#}");
        }
    }

    result.map_err(|e| anyhow::anyhow!("discover_staged failed: {e:#}"))
}

/// 扫描指定网卡的 /24 子网。
pub async fn discovery_scan_subnet(interface_ip: &str, port: u16, protocol: &str) -> Result<()> {
    log::debug!("[DISC] scan_subnet: ip={interface_ip} port={port} protocol={protocol}");
    let t0 = std::time::Instant::now();
    let handle = {
        let state = bridge().lock().unwrap();
        state.discovery_handle.clone()
    };
    let handle = handle.ok_or_else(|| anyhow::anyhow!("Discovery not running"))?;

    let ip: Ipv4Addr = interface_ip
        .parse()
        .map_err(|_| anyhow::anyhow!("Invalid interface IP: {interface_ip}"))?;
    let protocol_enum = match protocol.to_lowercase().as_str() {
        "http" => ProtocolType::Http,
        _ => ProtocolType::Https,
    };

    let before = handle.devices().len();
    let result = handle.scan_subnet(ip, port, protocol_enum).await;
    let elapsed = t0.elapsed().as_millis();
    let after = handle.devices().len();
    log::debug!("[DISC] scan_subnet 完成: ip={interface_ip} 耗时={elapsed}ms 设备 {before} → {after} 结果={}",
        match &result { Ok(v) => format!("{} 台", v.len()), Err(e) => format!("Err:{e:#}") });
    let _ = result?;
    Ok(())
}

/// 将发现流程之外确认的设备（例如来自服务器注册事件）加入存储。
pub async fn discovery_add_device(device_json: &str) -> Result<()> {
    let handle = {
        let state = bridge().lock().unwrap();
        state.discovery_handle.clone()
    };
    let handle = handle.ok_or_else(|| anyhow::anyhow!("Discovery not running"))?;

    let dev: Value = serde_json::from_str(device_json)?;

    let host = dev["host"].as_str().unwrap_or("").to_string();
    let port = dev["port"].as_u64().unwrap_or(53317) as u16;
    let protocol = match dev["protocol"].as_str().unwrap_or("https") {
        "http" => ProtocolType::Http,
        _ => ProtocolType::Https,
    };

    let device = DiscoveredDevice {
        alias: dev["alias"].as_str().unwrap_or("").to_string(),
        version: dev["version"].as_str().unwrap_or("2.0").to_string(),
        device_model: dev["deviceModel"].as_str().map(|s| s.to_string()),
        device_type: dev["deviceType"].as_str().map(parse_device_type),
        fingerprint: dev["fingerprint"].as_str().unwrap_or("").to_string(),
        channel: DeviceChannel::Http(localsend::discovery::HttpChannel {
            host,
            port,
            protocol,
        }),
        download: dev["download"].as_bool().unwrap_or(false),
    };

    handle.add_device(device).await;
    Ok(())
}

/// 设置是否应答其他设备的广播。
pub fn discovery_set_answer_announcements(answer: bool) -> Result<()> {
    let handle = {
        let state = bridge().lock().unwrap();
        state.discovery_handle.clone()
    };
    match handle {
        Some(h) => {
            h.set_answer_announcements(answer);
            Ok(())
        }
        None => Err(anyhow::anyhow!("Discovery not running")),
    }
}

/// 停止发现并释放所有套接字。
pub fn discovery_stop() -> Result<()> {
    let mut state = bridge().lock().unwrap();
    // 取消事件任务
    if let Some(event_task) = state.discovery_event_task.take() {
        event_task.abort();
    }
    // 发送停止信号
    if let Some(stop_tx) = state.discovery_stop_tx.take() {
        let _ = stop_tx.send(());
    }
    state.discovery_handle.take();
    log::debug!("Discovery stopped");
    Ok(())
}

/// 按指纹以 JSON 获取单个设备。
pub fn discovery_get_device(fingerprint: &str) -> String {
    let state = bridge().lock().unwrap();
    match state.discovery_handle.as_ref() {
        Some(h) => match h.device_by_fingerprint(fingerprint) {
            Some(d) => device_to_json(&d).to_string(),
            None => "null".to_string(),
        },
        None => "null".to_string(),
    }
}

/// 获取组播错误（若有）。
pub fn discovery_multicast_error() -> String {
    let state = bridge().lock().unwrap();
    match state.discovery_handle.as_ref() {
        Some(h) => match h.multicast_error() {
            Some(e) => format!("{e:#}"),
            None => String::new(),
        },
        None => String::new(),
    }
}
