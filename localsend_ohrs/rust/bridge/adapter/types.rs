//! 上游↔桥接层 DTO 转换。
//!
//! 定义桥接层自己的 DTO 类型（FileDto / DeviceDto / SenderInfoDto），
//! 并实现上游类型到 DTO 的纯函数转换。上游类型只出现在本文件
//! （及 adapter/ 其他文件），桥接层其余代码只操作 DTO / BridgeEvent / StateAction。

use serde::{Deserialize, Serialize};

use localsend::discovery::StatefulDevice;
use localsend::http::dto_v2::RegisterDtoV2;
use localsend::http::server::v2::SessionEndReasonV2;
use localsend::model::discovery::ProtocolType;

use crate::bridge::event::SessionEndReason;
use crate::bridge::identity::device_type_to_string;

// ── 桥接层 DTO ────────────────────────────────────────────────────────

/// 文件元数据 DTO。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FileDto {
    pub id: String,
    pub file_name: String,
    pub size: u64,
    pub file_type: String,
    pub preview: Option<String>,
    pub sha256: Option<String>,
}

/// 设备 DTO（携带完整设备信息，事件消费者拿到即可使用）。
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DeviceDto {
    pub alias: String,
    pub fingerprint: String,
    pub version: String,
    pub device_model: Option<String>,
    pub device_type: Option<String>,
    pub download: bool,
    pub host: String,
    pub port: u16,
    pub protocol: String,
    pub channels: Vec<DeviceChannelDto>,
}

/// 设备可达通道 DTO。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DeviceChannelDto {
    pub host: String,
    pub port: u16,
    pub protocol: String,
}

/// 发送方信息 DTO（来自上游 RegisterDtoV2）。
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SenderInfoDto {
    pub alias: String,
    pub version: String,
    pub device_model: Option<String>,
    pub device_type: Option<String>,
    pub fingerprint: String,
    pub download: bool,
    pub port: u16,
    pub protocol: String,
}

// ── 基础字符串转换 ────────────────────────────────────────────────────

/// ProtocolType → 协议字符串（"http" / "https"）。
pub fn protocol_to_string(p: &ProtocolType) -> &'static str {
    match p {
        ProtocolType::Http => "http",
        ProtocolType::Https => "https",
    }
}

// ── 上游 → DTO 转换 ───────────────────────────────────────────────────

/// StatefulDevice → DeviceDto（含全部 HTTP 通道）。
pub fn device_to_dto(d: &StatefulDevice) -> DeviceDto {
    let http = d.device.http();
    let channels: Vec<DeviceChannelDto> = d
        .get_ranked_channels()
        .iter()
        .filter_map(|ch| ch.http())
        .map(|h| DeviceChannelDto {
            host: h.host.clone(),
            port: h.port,
            protocol: protocol_to_string(&h.protocol).to_string(),
        })
        .collect();

    DeviceDto {
        alias: d.device.alias.clone(),
        fingerprint: d.device.fingerprint.clone(),
        version: d.device.version.clone(),
        device_model: d.device.device_model.clone(),
        device_type: d
            .device
            .device_type
            .as_ref()
            .map(|dt| device_type_to_string(dt).to_string()),
        download: d.device.download,
        host: http.map(|h| h.host.clone()).unwrap_or_default(),
        port: http.map(|h| h.port).unwrap_or(0),
        protocol: http
            .map(|h| protocol_to_string(&h.protocol).to_string())
            .unwrap_or_default(),
        channels,
    }
}

/// 上游 FileDto → 桥接层 FileDto。
pub fn file_dto_from_upstream(f: &localsend::model::transfer::FileDto) -> FileDto {
    FileDto {
        id: f.id.clone(),
        file_name: f.file_name.clone(),
        size: f.size,
        file_type: f.file_type.clone(),
        preview: f.preview.clone(),
        sha256: f.sha256.clone(),
    }
}

/// 上游 RegisterDtoV2 → SenderInfoDto。
pub fn sender_info_to_dto(info: &RegisterDtoV2) -> SenderInfoDto {
    SenderInfoDto {
        alias: info.alias.clone(),
        version: info.version.clone(),
        device_model: info.device_model.clone(),
        device_type: info
            .device_type
            .as_ref()
            .map(|dt| device_type_to_string(dt).to_string()),
        fingerprint: info.fingerprint.clone(),
        download: info.download,
        port: info.port,
        protocol: protocol_to_string(&info.protocol).to_string(),
    }
}

/// 上游 SessionEndReasonV2 → 桥接层 SessionEndReason。
pub fn session_end_reason_from_upstream(r: SessionEndReasonV2) -> SessionEndReason {
    match r {
        SessionEndReasonV2::Finished => SessionEndReason::Finished,
        SessionEndReasonV2::Cancelled => SessionEndReason::Cancelled,
    }
}

// ── 单元测试 ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use localsend::discovery::{ChannelStatus, DeviceChannel, DiscoveredDevice, HttpChannel};
    use localsend::model::discovery::DeviceType;
    use std::collections::HashMap;

    fn sample_stateful_device() -> StatefulDevice {
        let discovered = DiscoveredDevice {
            alias: "TestPhone".to_string(),
            version: "2.2".to_string(),
            device_model: Some("Pixel".to_string()),
            device_type: Some(DeviceType::Mobile),
            fingerprint: "fp-abc".to_string(),
            channel: DeviceChannel::Http(HttpChannel {
                host: "192.168.1.10".to_string(),
                port: 53317,
                protocol: ProtocolType::Http,
            }),
            download: true,
        };
        StatefulDevice {
            device: discovered,
            channels: HashMap::from([(
                DeviceChannel::Http(HttpChannel {
                    host: "192.168.1.10".to_string(),
                    port: 53317,
                    protocol: ProtocolType::Http,
                }),
                ChannelStatus::Available,
            )]),
            logs: vec![],
        }
    }

    #[test]
    fn test_protocol_to_string_all_variants() {
        assert_eq!(protocol_to_string(&ProtocolType::Http), "http");
        assert_eq!(protocol_to_string(&ProtocolType::Https), "https");
    }

    #[test]
    fn test_device_to_dto_full() {
        let dto = device_to_dto(&sample_stateful_device());
        assert_eq!(dto.alias, "TestPhone");
        assert_eq!(dto.fingerprint, "fp-abc");
        assert_eq!(dto.version, "2.2");
        assert_eq!(dto.device_model.as_deref(), Some("Pixel"));
        assert_eq!(dto.device_type.as_deref(), Some("mobile"));
        assert!(dto.download);
        assert_eq!(dto.host, "192.168.1.10");
        assert_eq!(dto.port, 53317);
        assert_eq!(dto.protocol, "http");
        assert_eq!(dto.channels.len(), 1);
        assert_eq!(dto.channels[0].host, "192.168.1.10");
        assert_eq!(dto.channels[0].protocol, "http");
    }

    #[test]
    fn test_device_to_dto_no_device_type() {
        let discovered = DiscoveredDevice {
            alias: "Unknown".to_string(),
            version: "2.0".to_string(),
            device_model: None,
            device_type: None,
            fingerprint: "fp-none".to_string(),
            channel: DeviceChannel::Http(HttpChannel {
                host: "10.0.0.1".to_string(),
                port: 53317,
                protocol: ProtocolType::Https,
            }),
            download: false,
        };
        let stateful = StatefulDevice {
            device: discovered,
            channels: HashMap::new(),
            logs: vec![],
        };
        let dto = device_to_dto(&stateful);
        assert!(dto.device_type.is_none());
        assert!(dto.device_model.is_none());
        assert_eq!(dto.protocol, "https");
    }

    #[test]
    fn test_file_dto_from_upstream() {
        let up = localsend::model::transfer::FileDto {
            id: "f1".to_string(),
            file_name: "test.txt".to_string(),
            size: 100,
            file_type: "text/plain".to_string(),
            sha256: Some("abc123".to_string()),
            preview: None,
            metadata: None,
        };
        let dto = file_dto_from_upstream(&up);
        assert_eq!(dto.id, "f1");
        assert_eq!(dto.file_name, "test.txt");
        assert_eq!(dto.size, 100);
        assert_eq!(dto.sha256.as_deref(), Some("abc123"));
        assert!(dto.preview.is_none());
    }

    #[test]
    fn test_sender_info_to_dto() {
        let info = RegisterDtoV2 {
            alias: "Sender".to_string(),
            version: "2.2".to_string(),
            device_model: None,
            device_type: None,
            fingerprint: "sender-fp".to_string(),
            port: 53317,
            protocol: ProtocolType::Http,
            download: false,
        };
        let dto = sender_info_to_dto(&info);
        assert_eq!(dto.alias, "Sender");
        assert_eq!(dto.fingerprint, "sender-fp");
        assert_eq!(dto.port, 53317);
        assert_eq!(dto.protocol, "http");
        assert!(dto.device_type.is_none());
    }

    #[test]
    fn test_sender_info_to_dto_with_device_type() {
        let info = RegisterDtoV2 {
            alias: "PC".to_string(),
            version: "2.2".to_string(),
            device_model: Some("Windows".to_string()),
            device_type: Some(DeviceType::Desktop),
            fingerprint: "fp".to_string(),
            port: 53317,
            protocol: ProtocolType::Https,
            download: true,
        };
        let dto = sender_info_to_dto(&info);
        assert_eq!(dto.device_type.as_deref(), Some("desktop"));
        assert_eq!(dto.device_model.as_deref(), Some("Windows"));
        assert_eq!(dto.protocol, "https");
        assert!(dto.download);
    }

    #[test]
    fn test_session_end_reason_from_upstream() {
        assert_eq!(
            session_end_reason_from_upstream(SessionEndReasonV2::Finished),
            SessionEndReason::Finished
        );
        assert_eq!(
            session_end_reason_from_upstream(SessionEndReasonV2::Cancelled),
            SessionEndReason::Cancelled
        );
    }

    #[test]
    fn test_dto_serialize_camel_case() {
        let dto = DeviceDto {
            alias: "A".into(),
            fingerprint: "fp".into(),
            version: "2.2".into(),
            device_model: None,
            device_type: Some("mobile".into()),
            download: true,
            host: "192.168.1.1".into(),
            port: 53317,
            protocol: "https".into(),
            channels: vec![],
        };
        let json = serde_json::to_value(&dto).unwrap();
        assert_eq!(json["deviceModel"], serde_json::Value::Null);
        assert_eq!(json["deviceType"], "mobile");
        assert_eq!(json["host"], "192.168.1.1");
        let s = serde_json::to_string(&dto).unwrap();
        assert!(s.contains("\"deviceType\""));
        assert!(s.contains("\"fingerprint\""));
    }
}
