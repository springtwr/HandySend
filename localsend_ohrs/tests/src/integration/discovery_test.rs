#![cfg(test)]

use localsend::crypto::cert::generate_self_signed;
use localsend::discovery::{
    self, DeviceIdentity, DiscoveryConfig, DiscoveryEvent, DiscoveryHandle,
};
use localsend::http::server::{start_with_port, ServerConfigV2};
use localsend::http::state::ClientInfo;
use localsend::model::discovery::{DeviceType, ProtocolType, PROTOCOL_VERSION_V2};
use localsend::multicast::MulticastDevice;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::sync::atomic::{AtomicU16, Ordering};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

const TEST_GROUP: Ipv4Addr = Ipv4Addr::new(224, 0, 0, 170);
const TEST_GROUP_V6: Ipv6Addr = Ipv6Addr::new(0xff12, 0, 0, 0, 0, 0, 0xfd3a, 0xe423);

const RECEIVE_TIMEOUT: Duration = Duration::from_secs(5);

static NEXT_MULTICAST_PORT: AtomicU16 = AtomicU16::new(56317);

fn announce_port() -> u16 {
    static PORT_COUNTER: AtomicU16 = AtomicU16::new(42551);
    PORT_COUNTER.fetch_add(1, Ordering::Relaxed)
}

async fn start_register_server(
    alias: &str,
    fingerprint: &str,
) -> (u16, oneshot::Sender<()>) {
    let _ = tracing_subscriber::fmt().with_test_writer().try_init();

    let (event_tx, _) = mpsc::channel(16);
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
    .expect("启动服务器失败");

    (handle.port(), stop_tx)
}

struct TestInstance {
    handle: DiscoveryHandle,
    events: mpsc::Receiver<DiscoveryEvent>,
    _stop_tx: oneshot::Sender<()>,
}

impl TestInstance {
    async fn next_discovery(
        &mut self,
        fingerprint: &str,
    ) -> Option<localsend::discovery::DiscoveredDevice> {
        let deadline = tokio::time::Instant::now() + RECEIVE_TIMEOUT;
        loop {
            let event = tokio::time::timeout_at(deadline, self.events.recv())
                .await
                .ok()??;
            let DiscoveryEvent::Discovered { device } = event else {
                continue;
            };
            if device.fingerprint == fingerprint {
                return Some(device);
            }
        }
    }
}

async fn start_instance(
    alias: &str,
    multicast_port: u16,
    server_port: u16,
) -> Option<TestInstance> {
    let cert = generate_self_signed().expect("生成证书失败");
    let (event_tx, events) = mpsc::channel(32);
    let (stop_tx, stop_rx) = oneshot::channel();

    let handle = discovery::start(
        DiscoveryConfig {
            group: TEST_GROUP,
            group_v6: Some(TEST_GROUP_V6),
            port: multicast_port,
            interface_filter: Default::default(),
            device: MulticastDevice {
                alias: alias.to_string(),
                version: PROTOCOL_VERSION_V2.to_string(),
                device_model: Some("HarmonyOS".to_string()),
                device_type: Some(DeviceType::Mobile),
                fingerprint: cert.fingerprint.clone(),
                port: server_port,
                protocol: ProtocolType::Http,
                download: false,
            },
            identity: DeviceIdentity {
                cert_pem: cert.certificate_pem,
                private_key_pem: cert.private_key_pem,
            },
            timeout: discovery::DEFAULT_DISCOVERY_TIMEOUT,
            event_tx: Some(event_tx),
        },
        stop_rx,
    )
    .await;
    if handle.multicast_error().is_some() {
        return None;
    }

    Some(TestInstance {
        handle,
        events,
        _stop_tx: stop_tx,
    })
}

fn skip(reason: &str) {
    eprintln!("跳过发现测试: {reason}");
}

#[tokio::test]
async fn test_handysend_targeted_discovery() {
    let multicast_port = NEXT_MULTICAST_PORT.fetch_add(1, Ordering::Relaxed);
    let (server_port, _server_stop) =
        start_register_server("HandySend-Target", "handysend-target-fp").await;

    let Some(mut instance) = start_instance("HandySend-Finder", multicast_port, announce_port()).await else {
        return skip("无可用的组播网络接口");
    };

    let device = instance
        .handle
        .discover("127.0.0.1", server_port, ProtocolType::Http)
        .await
        .expect("定向发现失败")
        .expect("目标不应被误判为自身");

    assert_eq!(device.device.alias, "HandySend-Target");
    assert_eq!(device.device.fingerprint, "handysend-target-fp");

    let stored = instance
        .handle
        .device_by_fingerprint("handysend-target-fp")
        .expect("发现的设备应被存储");
    assert_eq!(stored.device.alias, "HandySend-Target");

    let emitted = instance
        .next_discovery("handysend-target-fp")
        .await
        .expect("发现的设备应被通知");
    assert_eq!(emitted.alias, "HandySend-Target");
}

#[tokio::test]
async fn test_handysend_subnet_scan() {
    let multicast_port = NEXT_MULTICAST_PORT.fetch_add(1, Ordering::Relaxed);
    let (server_port, _server_stop) =
        start_register_server("HandySend-ScanTarget", "handysend-scan-fp").await;

    let Some(mut instance) = start_instance("HandySend-Scanner", multicast_port, announce_port()).await else {
        return skip("无可用的组播网络接口");
    };

    let found = instance
        .handle
        .scan_subnet(
            Ipv4Addr::new(127, 0, 0, 99),
            server_port,
            ProtocolType::Http,
        )
        .await
        .expect("子网扫描失败");

    assert!(!found.is_empty(), "扫描应发现回环地址上的服务器");
    assert!(found
        .iter()
        .all(|device| device.device.fingerprint == "handysend-scan-fp"));

    let emitted = instance
        .next_discovery("handysend-scan-fp")
        .await
        .expect("扫描到的设备应被通知");
    assert_eq!(emitted.alias, "HandySend-ScanTarget");
}

#[tokio::test]
async fn test_handysend_discovery_without_multicast() {
    let (server_port, _server_stop) =
        start_register_server("HandySend-Target", "handysend-target-fp").await;

    let cert = generate_self_signed().expect("生成证书失败");
    let (stop_tx, stop_rx) = oneshot::channel();
    let handle = discovery::start(
        DiscoveryConfig {
            group: TEST_GROUP,
            group_v6: Some(TEST_GROUP_V6),
            port: NEXT_MULTICAST_PORT.fetch_add(1, Ordering::Relaxed),
            interface_filter: localsend::util::interface::InterfaceFilter {
                whitelist: Some(vec!["203.0.113.1".to_string()]),
                blacklist: None,
            },
            device: MulticastDevice {
                alias: "NoMulticast".to_string(),
                version: PROTOCOL_VERSION_V2.to_string(),
                device_model: Some("HarmonyOS".to_string()),
                device_type: Some(DeviceType::Mobile),
                fingerprint: cert.fingerprint.clone(),
                port: announce_port(),
                protocol: ProtocolType::Http,
                download: false,
            },
            identity: DeviceIdentity {
                cert_pem: cert.certificate_pem,
                private_key_pem: cert.private_key_pem,
            },
            timeout: discovery::DEFAULT_DISCOVERY_TIMEOUT,
            event_tx: None,
        },
        stop_rx,
    )
    .await;

    assert!(
        handle.multicast_error().is_some(),
        "无匹配接口时组播应不可用"
    );

    handle.announce().await;
    let device = handle
        .discover("127.0.0.1", server_port, ProtocolType::Http)
        .await
        .expect("定向发现失败")
        .expect("目标不应被误判为自身");
    assert_eq!(device.device.alias, "HandySend-Target");

    drop(stop_tx);
    handle.wait_stopped().await;
}
