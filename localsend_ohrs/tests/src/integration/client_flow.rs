//! 客户端流程管道测试（US3）。
//!
//! 通过 event_tx/event_rx 直接消费事件流（FR-017）：注册服务器作为目标设备，
//! 验证 register_device / client_info 返回正确信息。无 mock、无轮询。

#![cfg(test)]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use localsend::http::server::{start_with_port, ServerConfigV2};
use localsend::http::state::ClientInfo;
use localsend::model::discovery::{DeviceType, ProtocolType, PROTOCOL_VERSION_V2};
use tokio::sync::{mpsc, oneshot};

use localsend_core::bridge::client;
use localsend_core::bridge::event::BridgeEvent;
use localsend_core::bridge::identity;
use localsend_core::bridge::state::BridgeState;

/// 启动一个注册服务器（作为目标设备）。
async fn start_target_server() -> (u16, oneshot::Sender<()>) {
    let (event_tx, _event_rx) = mpsc::channel(16);
    let (stop_tx, stop_rx) = oneshot::channel();

    let handle = start_with_port(
        0,
        None,
        ClientInfo {
            alias: "Target-Phone".to_string(),
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: Some("Pixel".to_string()),
            device_type: Some(DeviceType::Mobile),
            token: "target-fingerprint".to_string(),
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
    .expect("启动目标服务器失败");

    (handle.port(), stop_tx)
}

/// 构造带身份和 event_tx 的 BridgeState。
fn init_state() -> (Arc<Mutex<BridgeState>>, mpsc::Receiver<BridgeEvent>) {
    let (event_tx, event_rx) = mpsc::channel::<BridgeEvent>(64);
    let state = Arc::new(Mutex::new(BridgeState::new()));
    state.lock().unwrap().event_tx = Some(event_tx);
    identity::init_with_persisted_identity(
        &state,
        "HandySend-Client".to_string(),
        DeviceType::Mobile,
        "",
    )
    .unwrap();
    (state, event_rx)
}

/// US3 管道验证：client_info 获取目标设备信息。
#[tokio::test]
async fn test_client_info() {
    let (port, _stop) = start_target_server().await;
    let (state, _event_rx) = init_state();

    let info_json = client::client_info(&state, ProtocolType::Http, "127.0.0.1", port)
        .await
        .expect("client_info 失败");

    let info: serde_json::Value = serde_json::from_str(&info_json).unwrap();
    assert_eq!(info["alias"], "Target-Phone");
    assert_eq!(info["fingerprint"], "target-fingerprint");
    assert_eq!(info["deviceModel"], "Pixel");
    assert_eq!(info["deviceType"], "mobile");
    assert_eq!(info["protocol"], "http");
}

/// US3 管道验证：register_device 注册到目标设备并获取对端信息。
#[tokio::test]
async fn test_client_register_device() {
    let (port, _stop) = start_target_server().await;
    let (state, _event_rx) = init_state();

    let result = client::register_device(
        &state,
        "127.0.0.1",
        port,
        "HandySend-Client",
        "handysend-fp",
        "http",
        "HarmonyOS",
        "mobile",
        53317,
        "127.0.0.1",
    )
    .await
    .expect("register_device 失败");

    let info: serde_json::Value = serde_json::from_str(&result).unwrap();
    assert_eq!(info["alias"], "Target-Phone");
    assert_eq!(info["fingerprint"], "target-fingerprint");
    assert_eq!(info["protocol"], "http");
}
