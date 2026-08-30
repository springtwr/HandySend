//! 发现流程管道测试（US2）。
//!
//! 通过 event_tx/event_rx 直接消费事件流（FR-017）：启动桥接层发现 +
//! 注册服务器，定向扫描验证 DeviceFound 事件到达。无 mock、无轮询。

#![cfg(test)]

use std::net::Ipv4Addr;
use std::sync::atomic::{AtomicU16, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use localsend::http::server::{start_with_port, ServerConfigV2};
use localsend::http::state::ClientInfo;
use localsend::model::discovery::{DeviceType, PROTOCOL_VERSION_V2};
use tokio::sync::{mpsc, oneshot};

use localsend_core::bridge::discovery as bridge_discovery;
use localsend_core::bridge::event::BridgeEvent;
use localsend_core::bridge::identity;
use localsend_core::bridge::state::BridgeState;

/// 测试专用组播组（与真实网络隔离）。
const TEST_GROUP: Ipv4Addr = Ipv4Addr::new(224, 0, 0, 170);

/// 事件等待超时（子网扫描探测 255 个主机，串行超时累加）。
const RECEIVE_TIMEOUT: Duration = Duration::from_secs(20);

static NEXT_MULTICAST_PORT: AtomicU16 = AtomicU16::new(56317);

fn next_multicast_port() -> u16 {
    NEXT_MULTICAST_PORT.fetch_add(2, Ordering::Relaxed)
}

/// 启动一个注册服务器（作为目标设备的 HTTP 服务）。
async fn start_register_server(alias: &str, fingerprint: &str) -> (u16, oneshot::Sender<()>) {
    let (event_tx, _event_rx) = mpsc::channel(16);
    let (stop_tx, stop_rx) = oneshot::channel();

    let handle = start_with_port(
        0,
        None,
        ClientInfo {
            alias: alias.to_string(),
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: Some("HarmonyOS".to_string()),
            device_type: Some(DeviceType::Mobile),
            token: fingerprint.to_string(),
        },
        None,
        Some(ServerConfigV2 {
            pin: None,
            verify_checksums: true,
            event_tx,
        }),
        None,
        stop_rx,
    )
    .await
    .expect("启动注册服务器失败");

    (handle.port(), stop_tx)
}

/// 构造一个带 event_tx 的 BridgeState。
fn new_state_with_event_tx() -> (Arc<Mutex<BridgeState>>, mpsc::Receiver<BridgeEvent>) {
    let (event_tx, event_rx) = mpsc::channel::<BridgeEvent>(64);
    let state = Arc::new(Mutex::new(BridgeState::new()));
    state.lock().unwrap().event_tx = Some(event_tx);
    (state, event_rx)
}

/// 从事件流中等待匹配谓词的桥接事件。
async fn wait_for_event(
    event_rx: &mut mpsc::Receiver<BridgeEvent>,
    predicate: impl Fn(&BridgeEvent) -> bool,
) -> BridgeEvent {
    loop {
        let event = event_rx
            .recv()
            .await
            .expect("事件流已关闭，等待事件失败");
        if predicate(&event) {
            return event;
        }
    }
}

/// US2 管道验证：启动桥接层发现 + 注册服务器，定向扫描 127.0.0.0/24
/// 命中回环地址上的服务器，验证 DeviceFound 事件（不依赖组播接口）。
#[tokio::test]
async fn test_discovery_device_found() {
    // 目标设备：注册服务器（绑定 127.0.0.1）
    let (server_port, _stop_server) =
        start_register_server("Peer-Server", "peer-fingerprint").await;

    // 桥接层设备（本机）
    let (state, mut event_rx) = new_state_with_event_tx();
    identity::init_with_persisted_identity(
        &state,
        "HandySend-Discovery".to_string(),
        DeviceType::Mobile,
        "",
    )
    .unwrap();

    let multicast_port = next_multicast_port();
    let config = serde_json::json!({
        "port": multicast_port,
        "protocol": "http",
        "multicastGroup": TEST_GROUP.to_string(),
        "discoveryTimeoutMs": 2000,
        "download": true,
    })
    .to_string();

    bridge_discovery::start_discovery_v2(state.clone(), &config)
        .await
        .expect("启动发现失败");

    // 定向扫描 127.0.0.0/24（127.0.0.99 所在子网包含 127.0.0.1 的目标服务器）
    bridge_discovery::discovery_scan_subnet(&state, "127.0.0.99", server_port, "http")
        .await
        .expect("子网扫描失败");

    // 等待 DeviceFound 事件（扫描确认后到达）
    let found = tokio::time::timeout(
        RECEIVE_TIMEOUT,
        wait_for_event(&mut event_rx, |e| matches!(e, BridgeEvent::DeviceFound { .. })),
    )
    .await
    .expect("超时未收到 DeviceFound 事件");

    match found {
        BridgeEvent::DeviceFound { device } => {
            assert_eq!(device.alias, "Peer-Server");
            assert_eq!(device.fingerprint, "peer-fingerprint");
            assert_eq!(device.port, server_port);
        }
        _ => unreachable!(),
    }

    // 清理
    bridge_discovery::stop_discovery(&state);
}
