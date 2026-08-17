//! Discovery facade — handles all discovery (UDP multicast + HTTP register) operations.
//!
//! This module wraps the upstream `localsend::discovery` module and exposes
//! a complete discovery API through NAPI, replacing the old simplified
//! `start_discovery(port)` / `stop_discovery()` in facade.rs.
//!
//! Reference: FRB discovery.rs (`localsend_isolates/rust/src/api/discovery.rs`)

use std::net::Ipv4Addr;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use serde_json::{json, Value};

use localsend::discovery::{self, DeviceChannel, DeviceIdentity, DiscoveredDevice, DiscoveryConfig, DiscoveryEvent, DiscoveryHandle, StatefulDevice};
use localsend::model::discovery::{DeviceType, ProtocolType, PROTOCOL_VERSION_V2};
use localsend::multicast::{self, MulticastDevice};
use localsend::util::interface::InterfaceFilter;

use crate::bridge::callback::EventCallback;
use crate::bridge::facade::{device_to_json, device_type_to_string, parse_device_type, protocol_to_string};
use crate::bridge::state::bridge;

// ── Discovery Lifecycle ──────────────────────────────────────────────────────

/// Start discovery with full configuration.
///
/// Replaces the old `start_discovery(port)`. Accepts a JSON config string with:
/// - alias, fingerprint, port, protocol, multicastGroup
/// - networkWhitelist/networkBlacklist (optional)
/// - discoveryTimeoutMs
///
/// Hot-restart: stops any previous discovery instance before starting a new one,
/// matching the FRB `RUNNING_DISCOVERY` pattern.
pub async fn start_discovery_v2(config_json: &str) -> Result<()> {
    log::info!("[DBG-DISC] start_discovery_v2: config={}", config_json.chars().take(200).collect::<String>());
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

    // Hot-restart: stop old discovery if running
    {
        let mut state = bridge().lock().unwrap();
        if state.discovery_handle.is_some() {
            log::info!("Hot-restart: stopping previous discovery instance");
            // Cancel event task
            if let Some(event_task) = state.discovery_event_task.take() {
                event_task.abort();
            }
            // Send stop signal
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

    let whitelist = config["networkWhitelist"]
        .as_array()
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect::<Vec<String>>());
    let blacklist = config["networkBlacklist"]
        .as_array()
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect::<Vec<String>>());
    let timeout_ms = config["discoveryTimeoutMs"].as_u64().unwrap_or(3000);

    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    let (event_tx, event_rx) = tokio::sync::mpsc::channel::<DiscoveryEvent>(16);

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
        // IPv6 multicast is disabled: peers would discover this device via its
        // IPv6 address (link-local fe80:: or the global address), but the
        // IPv6 path is not reliably reachable on HarmonyOS, which breaks both
        // sending and receiving. IPv4 discovery is fully functional.
        group_v6: None,
        port: multicast::DEFAULT_PORT,
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

    // Start event listener task
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

/// Start the event listener task that forwards discovery events to ArkTS via callback.
pub fn start_event_listener_with_callback(
    mut event_rx: tokio::sync::mpsc::Receiver<DiscoveryEvent>,
    callback: Option<EventCallback>,
    handle: Arc<DiscoveryHandle>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        while let Some(event) = event_rx.recv().await {
            match event {
                DiscoveryEvent::Discovered { ref device } => {
                    log::info!("[DBG-DISC-EVT] Discovered: fp={} alias={}",
                        device.fingerprint.chars().take(8).collect::<String>(),
                        device.alias);
                    // Send only the newly discovered device (not the full store),
                    // matching LocalSend Flutter's RegisterDeviceAction pattern.
                    // ArkTS handles merging into the local list.
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
                    log::info!("[DBG-DISC-EVT] Updated: fp={} alias={}",
                        device.fingerprint.chars().take(8).collect::<String>(),
                        device.alias);
                    // Send only the updated device
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
        log::info!("Discovery event listener task ended");
    })
}

/// Send an announcement burst to the network.
pub async fn discovery_announce() -> Result<()> {
    log::info!("[DBG-DISC] discovery_announce called");
    let handle = {
        let state = bridge().lock().unwrap();
        state.discovery_handle.clone()
    };
    match handle {
        Some(h) => {
            h.announce().await;
            Ok(())
        }
        None => Err(anyhow::anyhow!("Discovery not running")),
    }
}

/// Discover devices in stages: announce → probe known channels → wait grace period → fallback subnet scan.
pub async fn discovery_discover_staged(
    channels_json: &str,
    interface_ips_json: &str,
    port: u16,
    protocol: &str,
    grace_ms: u32,
) -> Result<()> {
    log::info!("[DBG-DISC] discovery_discover_staged: port={} protocol={} grace_ms={}", port, protocol, grace_ms);
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

    handle
        .discover_staged(
            known_channels,
            interface_ips,
            port,
            protocol_enum,
            Duration::from_millis(grace_ms as u64),
        )
        .await
        .map_err(|e| anyhow::anyhow!("discover_staged failed: {e:#}"))?;

    Ok(())
}

/// Scan the /24 subnet of a specific interface.
pub async fn discovery_scan_subnet(
    interface_ip: &str,
    port: u16,
    protocol: &str,
) -> Result<()> {
    log::info!("[DBG-DISC] discovery_scan_subnet: ip={} port={} protocol={}", interface_ip, port, protocol);
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

    handle
        .scan_subnet(ip, port, protocol_enum)
        .await
        .map_err(|e| anyhow::anyhow!("scan_subnet failed: {e:#}"))?;

    Ok(())
}

/// Add a device confirmed outside of discovery (e.g. from server register event) into the store.
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
        device_type: dev["deviceType"].as_str().map(|s| parse_device_type(s)),
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

/// Set whether to answer announcements of other devices.
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

/// Stop discovery and release all sockets.
pub fn discovery_stop() -> Result<()> {
    let mut state = bridge().lock().unwrap();
    // Cancel event task
    if let Some(event_task) = state.discovery_event_task.take() {
        event_task.abort();
    }
    // Send stop signal
    if let Some(stop_tx) = state.discovery_stop_tx.take() {
        let _ = stop_tx.send(());
    }
    state.discovery_handle.take();
    log::info!("Discovery stopped");
    Ok(())
}

/// Discover devices in stages with a specific discovery handle.
pub async fn discovery_discover_staged_with_handle(
    handle: &Arc<DiscoveryHandle>,
    channels_json: &str,
    interface_ips_json: &str,
    port: u16,
    protocol: &str,
    grace_ms: u32,
) -> Result<()> {
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

    handle
        .discover_staged(
            known_channels,
            interface_ips,
            port,
            protocol_enum,
            Duration::from_millis(grace_ms as u64),
        )
        .await
        .map_err(|e| anyhow::anyhow!("discover_staged failed: {e:#}"))?;

    Ok(())
}

/// Scan the /24 subnet with a specific discovery handle.
pub async fn discovery_scan_subnet_with_handle(
    handle: &Arc<DiscoveryHandle>,
    interface_ip: &str,
    port: u16,
    protocol: &str,
) -> Result<()> {
    let ip: Ipv4Addr = interface_ip
        .parse()
        .map_err(|_| anyhow::anyhow!("Invalid interface IP: {interface_ip}"))?;
    let protocol_enum = match protocol.to_lowercase().as_str() {
        "http" => ProtocolType::Http,
        _ => ProtocolType::Https,
    };

    handle
        .scan_subnet(ip, port, protocol_enum)
        .await
        .map_err(|e| anyhow::anyhow!("scan_subnet failed: {e:#}"))?;

    Ok(())
}

/// Add a device with a specific discovery handle.
pub async fn discovery_add_device_with_handle(
    handle: &Arc<DiscoveryHandle>,
    device_json: &str,
) -> Result<()> {
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
        device_type: dev["deviceType"].as_str().map(|s| parse_device_type(s)),
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

/// Get device logs with a specific discovery handle.
pub fn device_logs_with_handle(handle: &Arc<DiscoveryHandle>, fingerprint: &str) -> String {
    match handle.device_by_fingerprint(fingerprint) {
        Some(device) => {
            let logs: Vec<Value> = device.logs.iter().map(|log| {
                let kind_str = match log.kind {
                    localsend::discovery::DeviceLogKind::Discovered => "discovered",
                    localsend::discovery::DeviceLogKind::Updated => "updated",
                };
                let channel_json = match &log.channel {
                    localsend::discovery::DeviceChannel::Http(ch) => json!({
                        "host": ch.host,
                        "port": ch.port,
                        "protocol": crate::bridge::facade::protocol_to_string(&ch.protocol),
                    }),
                };
                let millis = log.timestamp
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis() as u64;
                json!({
                    "timestampMillis": millis,
                    "kind": kind_str,
                    "channel": channel_json,
                })
            }).collect();
            serde_json::to_string(&logs).unwrap_or_else(|_| "[]".into())
        }
        None => "[]".to_string(),
    }
}

/// Get all discovered devices as JSON.
pub fn discovery_get_devices() -> String {
    let state = bridge().lock().unwrap();
    let devices: Vec<Value> = match state.discovery_handle.as_ref() {
        Some(h) => {
            let devs = h.devices();
            log::info!("[DBG-DISC-GET] discovery_get_devices: returning {} devices from Rust DeviceStore", devs.len());
            devs.iter().map(device_to_json).collect()
        }
        None => {
            log::info!("[DBG-DISC-GET] discovery_get_devices: no discovery_handle, returning []");
            vec![]
        }
    };
    drop(state);
    serde_json::to_string(&devices).unwrap_or_else(|_| "[]".into())
}

/// Get a single device by fingerprint as JSON.
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

/// Get the multicast error, if any.
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

/// Get device confirmation logs by fingerprint.
/// Returns a JSON array of log entries with timestampMillis, kind, and channel.
pub fn discovery_device_logs(fingerprint: &str) -> String {
    let state = bridge().lock().unwrap();
    match state.discovery_handle.as_ref() {
        Some(h) => match h.device_by_fingerprint(fingerprint) {
            Some(device) => {
                let logs: Vec<Value> = device.logs.iter().map(|log| {
                    let kind_str = match log.kind {
                        localsend::discovery::DeviceLogKind::Discovered => "discovered",
                        localsend::discovery::DeviceLogKind::Updated => "updated",
                    };
                    let channel_json = match &log.channel {
                        localsend::discovery::DeviceChannel::Http(ch) => json!({
                            "host": ch.host,
                            "port": ch.port,
                            "protocol": crate::bridge::facade::protocol_to_string(&ch.protocol),
                        }),
                    };
                    let millis = log.timestamp
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis() as u64;
                    json!({
                        "timestampMillis": millis,
                        "kind": kind_str,
                        "channel": channel_json,
                    })
                }).collect();
                serde_json::to_string(&logs).unwrap_or_else(|_| "[]".into())
            }
            None => "[]".to_string(),
        },
        None => "[]".to_string(),
    }
}
