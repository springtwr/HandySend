//! 纯逻辑转换函数——不依赖 BridgeState 或 NAPI 运行时。
//!
//! 所有函数均为纯函数，可直接在 `#[cfg(test)]` 中测试。
//! 门面模块（facade / client_facade）委托本模块，保持自身聚焦于有状态逻辑。

use localsend::crypto;
use localsend::discovery::StatefulDevice;
use localsend::http::client::ClientError;
use localsend::http::server::v2::ServerEventV2;
use localsend::http::server::web::WebI18n;
use localsend::model::discovery::{DeviceType, ProtocolType};
use serde_json::{json, Value};

pub fn parse_protocol(s: &str) -> ProtocolType {
    match s.to_lowercase().as_str() {
        "http" => ProtocolType::Http,
        _ => ProtocolType::Https,
    }
}

pub fn parse_device_type(s: &str) -> DeviceType {
    match s.to_lowercase().as_str() {
        "desktop" | "pc" => DeviceType::Desktop,
        "web" | "browser" => DeviceType::Web,
        "headless" => DeviceType::Headless,
        "server" => DeviceType::Server,
        _ => DeviceType::Mobile,
    }
}

pub fn device_type_to_string(dt: &DeviceType) -> &'static str {
    match dt {
        DeviceType::Mobile => "mobile",
        DeviceType::Desktop => "desktop",
        DeviceType::Web => "web",
        DeviceType::Headless => "headless",
        DeviceType::Server => "server",
    }
}

pub fn protocol_to_string(p: &ProtocolType) -> &'static str {
    match p {
        ProtocolType::Http => "http",
        ProtocolType::Https => "https",
    }
}

pub fn device_to_json(d: &StatefulDevice) -> Value {
    let http = d.device.http();
    let channels: Vec<Value> = d
        .get_ranked_channels()
        .iter()
        .filter_map(|ch| ch.http())
        .map(|h| {
            json!({
                "host": h.host,
                "port": h.port,
                "protocol": protocol_to_string(&h.protocol),
            })
        })
        .collect();

    json!({
        "alias": d.device.alias,
        "fingerprint": d.device.fingerprint,
        "version": d.device.version,
        "deviceModel": d.device.device_model,
        "deviceType": d.device.device_type.as_ref().map(|dt| device_type_to_string(dt)),
        "download": d.device.download,
        "host": http.map(|h| &h.host),
        "port": http.map(|h| h.port),
        "protocol": http.map(|h| protocol_to_string(&h.protocol)),
        "channels": channels,
    })
}

pub fn server_event_to_json(event: &ServerEventV2) -> String {
    match event {
        ServerEventV2::Register { ip, info } => json!({
            "type": "register",
            "ip": ip.to_string(),
            "info": {
                "alias": info.alias,
                "version": info.version,
                "deviceModel": info.device_model,
                "deviceType": info.device_type.as_ref().map(|dt| device_type_to_string(dt)),
                "fingerprint": info.fingerprint,
                "download": info.download,
                "port": info.port,
                "protocol": protocol_to_string(&info.protocol),
            },
        })
        .to_string(),

        ServerEventV2::PrepareUpload {
            session_id,
            ip,
            info,
            cert_fingerprint,
            files,
            ..
        } => {
            let file_list: Vec<Value> = files
                .iter()
                .map(|(id, f)| {
                    let mut obj = json!({
                        "id": id,
                        "fileName": f.file_name,
                        "size": f.size,
                        "fileType": f.file_type,
                    });
                    if let Some(ref preview) = f.preview {
                        obj["preview"] = json!(preview);
                    }
                    if let Some(ref sha256) = f.sha256 {
                        obj["sha256"] = json!(sha256);
                    }
                    obj
                })
                .collect();
            json!({
                "type": "prepare_upload",
                "sessionId": session_id,
                "ip": ip.to_string(),
                "info": {
                    "alias": info.alias,
                    "version": info.version,
                    "deviceModel": info.device_model,
                    "deviceType": info.device_type.as_ref().map(|dt| device_type_to_string(dt)),
                    "fingerprint": info.fingerprint,
                    "download": info.download,
                    "port": info.port,
                },
                "certFingerprint": cert_fingerprint,
                "files": file_list,
            })
            .to_string()
        }

        ServerEventV2::FileUpload {
            session_id,
            file_id,
            file,
            ..
        } => json!({
            "type": "file_upload",
            "sessionId": session_id,
            "fileId": file_id,
            "file": {
                "fileName": file.file_name,
                "size": file.size,
                "fileType": file.file_type,
            },
        })
        .to_string(),

        ServerEventV2::SessionEnd { session_id, reason } => json!({
            "type": "session_end",
            "sessionId": session_id,
            "reason": format!("{reason:?}"),
        })
        .to_string(),

        ServerEventV2::PrepareUploadAborted { session_id } => json!({
            "type": "prepare_upload_aborted",
            "sessionId": session_id,
        })
        .to_string(),

        ServerEventV2::CancelReceived { ip, session_id } => json!({
            "type": "cancel_received",
            "ip": ip.to_string(),
            "sessionId": session_id,
        })
        .to_string(),
    }
}

pub fn client_error_to_json(e: &ClientError) -> Value {
    match e {
        ClientError::StatusCode(se) => json!({
            "kind": "statusCode",
            "status": se.status,
            "message": se.message,
        }),
        ClientError::Reqwest(re) => json!({
            "kind": "reqwest",
            "message": format!("{re:#}"),
        }),
        ClientError::Json(je) => json!({
            "kind": "json",
            "message": je.to_string(),
        }),
        ClientError::Io(ie) => json!({
            "kind": "io",
            "message": ie.to_string(),
        }),
        ClientError::Other(ae) => json!({
            "kind": "other",
            "message": format!("{ae:#}"),
        }),
        ClientError::Cancelled => json!({
            "kind": "cancelled",
            "message": "Operation cancelled",
        }),
    }
}

pub fn hash_buffer(data: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(data);
    hex::encode(hasher.finalize())
}

pub fn extract_der_from_pem(pem_str: &str) -> Vec<u8> {
    use std::io::Cursor;
    match x509_parser::pem::Pem::read(Cursor::new(pem_str.as_bytes())) {
        Ok((pem, _)) => pem.contents.to_vec(),
        Err(_) => Vec::new(),
    }
}

pub fn compute_fingerprint_hash(combined: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(combined.as_bytes());
    let result = hasher.finalize();
    hex::encode(result)
}

pub fn build_web_i18n() -> WebI18n {
    WebI18n {
        waiting: "等待响应…".to_string(),
        enter_pin: "输入PIN".to_string(),
        invalid_pin: "PIN错误".to_string(),
        too_many_attempts: "尝试次数过多".to_string(),
        rejected: "已拒绝".to_string(),
        upload_rejected: "接收方已拒绝请求。".to_string(),
        busy: "接收方正忙。".to_string(),
        files: "文件".to_string(),
        file_name: "文件名".to_string(),
        size: "大小".to_string(),
        download_all: "全部下载".to_string(),
        download: "下载".to_string(),
        select_files: "选择文件".to_string(),
        upload: "上传".to_string(),
        uploading: "正在上传".to_string(),
        upload_complete: "上传完成".to_string(),
        remove: "移除".to_string(),
        cancel: "取消".to_string(),
        confirm: "确定".to_string(),
        shared_by: "来自".to_string(),
        network_error: "网络错误".to_string(),
        retry: "重试".to_string(),
    }
}

pub fn public_key_from_cert_pem(cert_pem: &str) -> String {
    crypto::cert::public_key_from_cert_der(&extract_der_from_pem(cert_pem)).unwrap_or_default()
}

pub fn fingerprint_from_cert_pem(cert_pem: &str) -> String {
    crypto::cert::fingerprint_from_cert_der(&extract_der_from_pem(cert_pem))
}

#[cfg(test)]
mod tests {
    use super::*;
    use localsend::http::dto_v2::RegisterDtoV2;
    use localsend::http::server::PeerIp;
    use localsend::model::discovery::DeviceType;
    use localsend::model::transfer::FileDto;
    use std::collections::HashMap;

    fn peer_ipv4(a: u8, b: u8, c: u8, d: u8) -> PeerIp {
        PeerIp {
            ip: std::net::IpAddr::from(std::net::Ipv4Addr::new(a, b, c, d)),
            scope_id: None,
        }
    }

    #[test]
    fn parse_protocol_http() {
        assert!(matches!(parse_protocol("http"), ProtocolType::Http));
    }

    #[test]
    fn parse_protocol_https() {
        assert!(matches!(parse_protocol("https"), ProtocolType::Https));
    }

    #[test]
    fn parse_protocol_case_insensitive() {
        assert!(matches!(parse_protocol("HTTP"), ProtocolType::Http));
        assert!(matches!(parse_protocol("Https"), ProtocolType::Https));
    }

    #[test]
    fn parse_protocol_unknown_defaults_https() {
        assert!(matches!(parse_protocol("ftp"), ProtocolType::Https));
        assert!(matches!(parse_protocol(""), ProtocolType::Https));
    }

    #[test]
    fn parse_device_type_variants() {
        assert!(matches!(parse_device_type("mobile"), DeviceType::Mobile));
        assert!(matches!(parse_device_type("desktop"), DeviceType::Desktop));
        assert!(matches!(parse_device_type("pc"), DeviceType::Desktop));
        assert!(matches!(parse_device_type("web"), DeviceType::Web));
        assert!(matches!(parse_device_type("browser"), DeviceType::Web));
        assert!(matches!(
            parse_device_type("headless"),
            DeviceType::Headless
        ));
        assert!(matches!(parse_device_type("server"), DeviceType::Server));
    }

    #[test]
    fn parse_device_type_unknown_defaults_mobile() {
        assert!(matches!(parse_device_type("tablet"), DeviceType::Mobile));
        assert!(matches!(parse_device_type(""), DeviceType::Mobile));
    }

    #[test]
    fn device_type_to_string_roundtrip() {
        for dt in &[
            DeviceType::Mobile,
            DeviceType::Desktop,
            DeviceType::Web,
            DeviceType::Headless,
            DeviceType::Server,
        ] {
            let s = device_type_to_string(dt);
            let parsed = parse_device_type(s);
            assert_eq!(parsed, *dt, "roundtrip failed for {:?}", dt);
        }
    }

    #[test]
    fn protocol_to_string_roundtrip() {
        for p in &[ProtocolType::Http, ProtocolType::Https] {
            let s = protocol_to_string(p);
            let parsed = parse_protocol(s);
            assert_eq!(parsed, *p, "roundtrip failed for {:?}", p);
        }
    }

    #[test]
    fn hash_buffer_known_value() {
        let empty = hash_buffer(&[]);
        assert_eq!(empty.len(), 64);
        assert_eq!(
            empty,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );

        let hello = hash_buffer(b"hello");
        assert_eq!(
            hello,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn compute_fingerprint_hash_known_value() {
        // 空输入
        let empty = compute_fingerprint_hash("");
        assert_eq!(
            empty,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        // 拼接输入
        let hash = compute_fingerprint_hash("fp1|fp2");
        assert_eq!(
            hash,
            "455d623607d040d959540809aaa43092013fa4b9af6ad951996b44ce69b04e43"
        );
    }

    #[test]
    fn extract_der_from_pem_invalid() {
        let result = extract_der_from_pem("not a pem");
        assert!(result.is_empty());
    }

    #[test]
    fn extract_der_from_pem_empty() {
        let result = extract_der_from_pem("");
        assert!(result.is_empty());
    }

    #[test]
    fn extract_der_from_pem_valid() {
        // 最小合法 PEM：一个自签名证书的 PEM
        let cert = localsend::crypto::cert::generate_self_signed().unwrap();
        let der = extract_der_from_pem(&cert.certificate_pem);
        assert!(!der.is_empty(), "合法 PEM 应返回非空 DER");
        // DER 应以 SEQUENCE 标签 0x30 开头
        assert_eq!(der[0], 0x30, "DER 应以 SEQUENCE 标签开头");
    }

    #[test]
    fn server_event_register_to_json() {
        let ip = peer_ipv4(192, 168, 1, 5);
        let event = ServerEventV2::Register {
            ip,
            info: RegisterDtoV2 {
                alias: "TestDevice".to_string(),
                version: "2.2".to_string(),
                device_model: Some("Model".to_string()),
                device_type: Some(DeviceType::Mobile),
                fingerprint: "fp123".to_string(),
                port: 53317,
                protocol: ProtocolType::Http,
                download: false,
            },
        };

        let json_str = server_event_to_json(&event);
        let parsed: Value = serde_json::from_str(&json_str).unwrap();
        assert_eq!(parsed["type"], "register");
        assert_eq!(parsed["ip"], "192.168.1.5");
        assert_eq!(parsed["info"]["alias"], "TestDevice");
        assert_eq!(parsed["info"]["deviceType"], "mobile");
        assert_eq!(parsed["info"]["fingerprint"], "fp123");
    }

    #[test]
    fn server_event_prepare_upload_to_json() {
        let ip = peer_ipv4(10, 0, 0, 1);
        let mut files = HashMap::new();
        files.insert(
            "f1".to_string(),
            FileDto {
                id: "f1".to_string(),
                file_name: "test.txt".to_string(),
                size: 100,
                file_type: "text/plain".to_string(),
                sha256: Some("abc123".to_string()),
                preview: None,
                metadata: None,
            },
        );

        let event = ServerEventV2::PrepareUpload {
            session_id: "sess-1".to_string(),
            ip,
            info: RegisterDtoV2 {
                alias: "Sender".to_string(),
                version: "2.2".to_string(),
                device_model: None,
                device_type: None,
                fingerprint: "sender-fp".to_string(),
                port: 53317,
                protocol: ProtocolType::Http,
                download: false,
            },
            cert_fingerprint: Some("cert-fp".to_string()),
            files,
            decision_tx: {
                let (tx, _rx) = tokio::sync::oneshot::channel();
                tx
            },
        };

        let json_str = server_event_to_json(&event);
        let parsed: Value = serde_json::from_str(&json_str).unwrap();
        assert_eq!(parsed["type"], "prepare_upload");
        assert_eq!(parsed["sessionId"], "sess-1");
        assert_eq!(parsed["certFingerprint"], "cert-fp");
        let files_arr = parsed["files"].as_array().unwrap();
        assert_eq!(files_arr.len(), 1);
        assert_eq!(files_arr[0]["id"], "f1");
        assert_eq!(files_arr[0]["fileName"], "test.txt");
        assert_eq!(files_arr[0]["sha256"], "abc123");
        // preview 为 None 时不应出现在 JSON 中
        assert!(files_arr[0].get("preview").is_none());
    }

    #[test]
    fn server_event_prepare_upload_with_preview() {
        let ip = peer_ipv4(10, 0, 0, 1);
        let mut files = HashMap::new();
        files.insert(
            "img1".to_string(),
            FileDto {
                id: "img1".to_string(),
                file_name: "photo.jpg".to_string(),
                size: 2048,
                file_type: "image/jpeg".to_string(),
                sha256: None,
                preview: Some("data:image/jpeg;base64,...".to_string()),
                metadata: None,
            },
        );

        let event = ServerEventV2::PrepareUpload {
            session_id: "sess-preview".to_string(),
            ip,
            info: RegisterDtoV2 {
                alias: "Sender".to_string(),
                version: "2.2".to_string(),
                device_model: None,
                device_type: None,
                fingerprint: "fp".to_string(),
                port: 53317,
                protocol: ProtocolType::Http,
                download: false,
            },
            cert_fingerprint: None,
            files,
            decision_tx: {
                let (tx, _rx) = tokio::sync::oneshot::channel();
                tx
            },
        };

        let json_str = server_event_to_json(&event);
        let parsed: Value = serde_json::from_str(&json_str).unwrap();
        let files_arr = parsed["files"].as_array().unwrap();
        assert_eq!(files_arr[0]["preview"], "data:image/jpeg;base64,...");
        // sha256 为 None 时不应出现在 JSON 中
        assert!(files_arr[0].get("sha256").is_none());
    }

    #[test]
    fn server_event_file_upload_to_json() {
        let event = ServerEventV2::FileUpload {
            session_id: "sess-up".to_string(),
            file_id: "f1".to_string(),
            file: FileDto {
                id: "f1".to_string(),
                file_name: "doc.pdf".to_string(),
                size: 999,
                file_type: "application/pdf".to_string(),
                sha256: None,
                preview: None,
                metadata: None,
            },
            target_tx: {
                let (tx, _rx) = tokio::sync::oneshot::channel();
                tx
            },
        };

        let json_str = server_event_to_json(&event);
        let parsed: Value = serde_json::from_str(&json_str).unwrap();
        assert_eq!(parsed["type"], "file_upload");
        assert_eq!(parsed["sessionId"], "sess-up");
        assert_eq!(parsed["fileId"], "f1");
        assert_eq!(parsed["file"]["fileName"], "doc.pdf");
        assert_eq!(parsed["file"]["size"], 999);
    }

    #[test]
    fn server_event_prepare_upload_aborted_to_json() {
        let event = ServerEventV2::PrepareUploadAborted {
            session_id: "sess-abort".to_string(),
        };
        let json_str = server_event_to_json(&event);
        let parsed: Value = serde_json::from_str(&json_str).unwrap();
        assert_eq!(parsed["type"], "prepare_upload_aborted");
        assert_eq!(parsed["sessionId"], "sess-abort");
    }

    #[test]
    fn server_event_session_end_to_json() {
        let event = ServerEventV2::SessionEnd {
            session_id: "sess-2".to_string(),
            reason: localsend::http::server::v2::SessionEndReasonV2::Finished,
        };
        let json_str = server_event_to_json(&event);
        let parsed: Value = serde_json::from_str(&json_str).unwrap();
        assert_eq!(parsed["type"], "session_end");
        assert_eq!(parsed["sessionId"], "sess-2");
    }

    #[test]
    fn server_event_cancel_received_to_json() {
        let ip = peer_ipv4(127, 0, 0, 1);
        let event = ServerEventV2::CancelReceived {
            ip,
            session_id: "sess-3".to_string(),
        };
        let json_str = server_event_to_json(&event);
        let parsed: Value = serde_json::from_str(&json_str).unwrap();
        assert_eq!(parsed["type"], "cancel_received");
        assert_eq!(parsed["sessionId"], "sess-3");
    }

    #[test]
    fn client_error_status_code_to_json() {
        let err = ClientError::StatusCode(localsend::http::StatusCodeError {
            status: 403,
            message: Some("Forbidden".to_string()),
        });
        let json = client_error_to_json(&err);
        assert_eq!(json["kind"], "statusCode");
        assert_eq!(json["status"], 403);
    }

    #[test]
    fn client_error_cancelled_to_json() {
        let err = ClientError::Cancelled;
        let json = client_error_to_json(&err);
        assert_eq!(json["kind"], "cancelled");
    }

    #[test]
    fn build_web_i18n_has_all_fields() {
        let i18n = build_web_i18n();
        assert!(!i18n.waiting.is_empty(), "waiting 为空");
        assert!(!i18n.enter_pin.is_empty(), "enter_pin 为空");
        assert!(!i18n.invalid_pin.is_empty(), "invalid_pin 为空");
        assert!(!i18n.too_many_attempts.is_empty(), "too_many_attempts 为空");
        assert!(!i18n.rejected.is_empty(), "rejected 为空");
        assert!(!i18n.upload_rejected.is_empty(), "upload_rejected 为空");
        assert!(!i18n.busy.is_empty(), "busy 为空");
        assert!(!i18n.files.is_empty(), "files 为空");
        assert!(!i18n.file_name.is_empty(), "file_name 为空");
        assert!(!i18n.size.is_empty(), "size 为空");
        assert!(!i18n.download_all.is_empty(), "download_all 为空");
        assert!(!i18n.download.is_empty(), "download 为空");
        assert!(!i18n.select_files.is_empty(), "select_files 为空");
        assert!(!i18n.upload.is_empty(), "upload 为空");
        assert!(!i18n.uploading.is_empty(), "uploading 为空");
        assert!(!i18n.upload_complete.is_empty(), "upload_complete 为空");
        assert!(!i18n.remove.is_empty(), "remove 为空");
        assert!(!i18n.cancel.is_empty(), "cancel 为空");
        assert!(!i18n.confirm.is_empty(), "confirm 为空");
        assert!(!i18n.shared_by.is_empty(), "shared_by 为空");
        assert!(!i18n.network_error.is_empty(), "network_error 为空");
        assert!(!i18n.retry.is_empty(), "retry 为空");
    }

    #[test]
    fn device_to_json_basic() {
        use localsend::discovery::{
            ChannelStatus, DeviceChannel, DiscoveredDevice, StatefulDevice,
        };
        use std::time::SystemTime;

        let discovered = DiscoveredDevice {
            alias: "TestPhone".to_string(),
            version: "2.2".to_string(),
            device_model: Some("Pixel".to_string()),
            device_type: Some(DeviceType::Mobile),
            fingerprint: "fp-abc".to_string(),
            channel: DeviceChannel::Http(localsend::discovery::HttpChannel {
                host: "192.168.1.10".to_string(),
                port: 53317,
                protocol: ProtocolType::Http,
            }),
            download: true,
        };

        let stateful = StatefulDevice {
            device: discovered,
            channels: HashMap::from([(
                DeviceChannel::Http(localsend::discovery::HttpChannel {
                    host: "192.168.1.10".to_string(),
                    port: 53317,
                    protocol: ProtocolType::Http,
                }),
                ChannelStatus::Available,
            )]),
            logs: vec![localsend::discovery::DeviceLog {
                timestamp: SystemTime::UNIX_EPOCH,
                kind: localsend::discovery::DeviceLogKind::Discovered,
                channel: DeviceChannel::Http(localsend::discovery::HttpChannel {
                    host: "192.168.1.10".to_string(),
                    port: 53317,
                    protocol: ProtocolType::Http,
                }),
            }],
        };

        let json = device_to_json(&stateful);
        assert_eq!(json["alias"], "TestPhone");
        assert_eq!(json["fingerprint"], "fp-abc");
        assert_eq!(json["version"], "2.2");
        assert_eq!(json["deviceModel"], "Pixel");
        assert_eq!(json["deviceType"], "mobile");
        assert_eq!(json["download"], true);
        assert_eq!(json["host"], "192.168.1.10");
        assert_eq!(json["port"], 53317);
        assert_eq!(json["protocol"], "http");

        let channels = json["channels"].as_array().unwrap();
        assert_eq!(channels.len(), 1);
        assert_eq!(channels[0]["host"], "192.168.1.10");
        assert_eq!(channels[0]["port"], 53317);
        assert_eq!(channels[0]["protocol"], "http");
    }

    #[test]
    fn device_to_json_no_device_type_defaults_null() {
        use localsend::discovery::{DeviceChannel, DiscoveredDevice, StatefulDevice};

        let discovered = DiscoveredDevice {
            alias: "Unknown".to_string(),
            version: "2.0".to_string(),
            device_model: None,
            device_type: None,
            fingerprint: "fp-none".to_string(),
            channel: DeviceChannel::Http(localsend::discovery::HttpChannel {
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

        let json = device_to_json(&stateful);
        assert!(json["deviceType"].is_null(), "无 deviceType 时应为 null");
        assert!(json["deviceModel"].is_null(), "无 deviceModel 时应为 null");
    }
}
