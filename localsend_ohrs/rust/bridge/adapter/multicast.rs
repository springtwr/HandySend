//! DiscoveryEvent → 桥接层事件适配。
//!
//! 纯函数：`adapt_discovery_event` 返回
//! `(Option<BridgeEvent>, Vec<StateAction>)`，无 IO、无 runtime。
//!
//! - `DiscoveryEvent`：上游发现层事件（由 discovery 事件循环消费，
//!   multicast 层已被 discovery 封装）

use localsend::discovery::{DiscoveredDevice, DiscoveryEvent, StatefulDevice};

use crate::bridge::adapter::types::{
    device_to_dto, protocol_to_string, DeviceChannelDto, DeviceDto,
};
use crate::bridge::engine::StateAction;
use crate::bridge::event::BridgeEvent;
use crate::bridge::identity::device_type_to_string;

/// 将上游 DiscoveryEvent 适配为桥接层事件。
///
/// `full_device` 为编排层从 DiscoveryHandle 查询到的完整设备状态
/// （含全部通道）；`None` 时退化为仅携带确认时通道的信息。
pub fn adapt_discovery_event(
    event: &DiscoveryEvent,
    full_device: Option<&StatefulDevice>,
) -> (Option<BridgeEvent>, Vec<StateAction>) {
    let device = match full_device {
        Some(sd) => device_to_dto(sd),
        None => match event {
            DiscoveryEvent::Discovered { device } | DiscoveryEvent::Updated { device } => {
                device_dto_from_discovered(device)
            }
        },
    };
    (Some(BridgeEvent::DeviceFound { device }), Vec::new())
}

/// 从单通道 DiscoveredDevice 构造 DeviceDto（无完整状态时的退化路径）。
fn device_dto_from_discovered(device: &DiscoveredDevice) -> DeviceDto {
    let http = device.http();
    let protocol = http
        .map(|h| protocol_to_string(&h.protocol).to_string())
        .unwrap_or_default();
    DeviceDto {
        alias: device.alias.clone(),
        fingerprint: device.fingerprint.clone(),
        version: device.version.clone(),
        device_model: device.device_model.clone(),
        device_type: device
            .device_type
            .as_ref()
            .map(|dt| device_type_to_string(dt).to_string()),
        download: device.download,
        host: http.map(|h| h.host.clone()).unwrap_or_default(),
        port: http.map(|h| h.port).unwrap_or(0),
        protocol,
        channels: http
            .map(|h| {
                vec![DeviceChannelDto {
                    host: h.host.clone(),
                    port: h.port,
                    protocol: protocol_to_string(&h.protocol).to_string(),
                }]
            })
            .unwrap_or_default(),
    }
}

// ── 单元测试 ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use localsend::discovery::{DeviceChannel, HttpChannel};
    use localsend::model::discovery::{DeviceType, ProtocolType};

    #[test]
    fn adapt_discovery_event_discovered() {
        let device = DiscoveredDevice {
            alias: "Phone".to_string(),
            version: "2.2".to_string(),
            device_model: None,
            device_type: None,
            fingerprint: "fp-1".to_string(),
            channel: DeviceChannel::Http(HttpChannel {
                host: "10.0.0.2".to_string(),
                port: 53317,
                protocol: ProtocolType::Http,
            }),
            download: false,
        };
        let event = DiscoveryEvent::Discovered {
            device: device.clone(),
        };
        let (bridge_event, actions) = adapt_discovery_event(&event, None);
        assert!(actions.is_empty());
        match bridge_event.unwrap() {
            BridgeEvent::DeviceFound { device } => {
                assert_eq!(device.alias, "Phone");
                assert_eq!(device.fingerprint, "fp-1");
                assert_eq!(device.host, "10.0.0.2");
                assert_eq!(device.protocol, "http");
            }
            _ => panic!("期望 DeviceFound 事件"),
        }
    }

    #[test]
    fn adapt_discovery_event_updated() {
        let device = DiscoveredDevice {
            alias: "PC".to_string(),
            version: "2.0".to_string(),
            device_model: Some("Windows".to_string()),
            device_type: Some(DeviceType::Desktop),
            fingerprint: "fp-2".to_string(),
            channel: DeviceChannel::Http(HttpChannel {
                host: "192.168.1.9".to_string(),
                port: 53317,
                protocol: ProtocolType::Https,
            }),
            download: true,
        };
        let event = DiscoveryEvent::Updated {
            device: device.clone(),
        };
        let (bridge_event, _) = adapt_discovery_event(&event, None);
        match bridge_event.unwrap() {
            BridgeEvent::DeviceFound { device } => {
                assert_eq!(device.device_type.as_deref(), Some("desktop"));
                assert_eq!(device.protocol, "https");
            }
            _ => panic!("期望 DeviceFound 事件"),
        }
    }

    #[test]
    fn adapt_discovery_event_with_full_device() {
        // full_device 来自 handle 时，DeviceDto 使用完整通道信息
        let discovered = DiscoveredDevice {
            alias: "Full".to_string(),
            version: "2.2".to_string(),
            device_model: None,
            device_type: None,
            fingerprint: "fp-3".to_string(),
            channel: DeviceChannel::Http(HttpChannel {
                host: "192.168.1.1".to_string(),
                port: 53317,
                protocol: ProtocolType::Http,
            }),
            download: false,
        };
        let stateful = StatefulDevice {
            device: discovered.clone(),
            channels: std::collections::HashMap::from([(
                DeviceChannel::Http(HttpChannel {
                    host: "192.168.1.1".to_string(),
                    port: 53317,
                    protocol: ProtocolType::Http,
                }),
                localsend::discovery::ChannelStatus::Available,
            )]),
            logs: vec![],
        };
        let event = DiscoveryEvent::Discovered { device: discovered };
        let (bridge_event, _) = adapt_discovery_event(&event, Some(&stateful));
        match bridge_event.unwrap() {
            BridgeEvent::DeviceFound { device } => {
                assert_eq!(device.alias, "Full");
                assert_eq!(device.channels.len(), 1);
            }
            _ => panic!("期望 DeviceFound 事件"),
        }
    }

    #[test]
    fn adapt_multicast_message_serializes() {
        let dto = DeviceDto {
            alias: "A".into(),
            fingerprint: "fp".into(),
            version: "2.2".into(),
            device_model: None,
            device_type: Some("mobile".into()),
            download: true,
            host: "192.168.1.1".into(),
            port: 53317,
            protocol: "http".into(),
            channels: vec![],
        };
        let json = serde_json::to_value(&dto).unwrap();
        assert_eq!(json["host"], "192.168.1.1");
        assert_eq!(json["deviceType"], "mobile");
        assert_eq!(json["port"], 53317);
    }
}
