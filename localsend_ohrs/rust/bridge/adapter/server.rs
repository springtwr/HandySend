//! ServerEventV2 / WebSendEvent / InternalEvent → 桥接层事件适配。
//!
//! 纯函数：`adapt_server_event(event) -> (Option<BridgeEvent>, Vec<StateAction>)`，
//! 不接收 state、无 IO、无 runtime，由调用方（server.rs 事件循环）apply 状态变更
//! 并发送事件。
//!
//! 上游 ServerEventV2 变更时只需修改本文件，match 穷尽检查引导适配。

use localsend::http::server::v2::ServerEventV2;
use localsend::model::discovery::ProtocolType;

use crate::bridge::adapter::types::{
    file_dto_from_upstream, protocol_to_string, sender_info_to_dto,
    session_end_reason_from_upstream,
};
use crate::bridge::engine::StateAction;
use crate::bridge::event::BridgeEvent;
use crate::bridge::state::PendingRequest;

/// 将上游 ServerEventV2 适配为桥接层事件 + 状态变更动作。
///
/// 返回 `(Option<BridgeEvent>, Vec<StateAction>)`：事件由调用方按分类
/// （关键 send / 可丢弃 try_send）发送，状态变更由调用方 apply。
pub fn adapt_server_event(event: ServerEventV2) -> (Option<BridgeEvent>, Vec<StateAction>) {
    match event {
        ServerEventV2::Register { ip, info } => {
            let dto = sender_info_to_dto(&info);
            (
                Some(BridgeEvent::Register {
                    ip: ip.to_string(),
                    info: dto,
                }),
                Vec::new(),
            )
        }

        ServerEventV2::PrepareUpload {
            session_id,
            ip,
            info,
            cert_fingerprint,
            files,
            decision_tx,
        } => {
            // 协议推断：HTTPS 注册时上游提供证书指纹；否则为 HTTP。
            let protocol = if cert_fingerprint
                .as_ref()
                .map(|s| !s.is_empty())
                .unwrap_or(false)
            {
                ProtocolType::Https
            } else {
                ProtocolType::Http
            };

            let file_list: Vec<_> = files.values().map(file_dto_from_upstream).collect();

            let peer_protocol_str = protocol_to_string(&protocol);
            // 与 BridgeEvent::PrepareUpload.sender_fingerprint 同口径：取设备身份指纹
            // （info.fingerprint），供 ArkTS 侧收藏匹配；TLS 证书指纹走 cert_fingerprint
            let request = PendingRequest {
                session_id: session_id.clone(),
                sender_alias: info.alias.clone(),
                sender_fingerprint: info.fingerprint.clone(),
                sender_protocol: peer_protocol_str.to_string(),
                files: files
                    .iter()
                    .map(|(id, f)| crate::bridge::state::PendingFile {
                        file_id: id.clone(),
                        file_name: f.file_name.clone(),
                        size: f.size,
                        file_type: f.file_type.clone(),
                        preview: f.preview.clone(),
                        sha256: f.sha256.clone(),
                    })
                    .collect(),
            };

            let event = BridgeEvent::PrepareUpload {
                session_id: session_id.clone(),
                sender_ip: ip.to_string(),
                sender_alias: info.alias.clone(),
                sender_fingerprint: info.fingerprint.clone(),
                sender_device_type: info
                    .device_type
                    .as_ref()
                    .map(|dt| crate::bridge::identity::device_type_to_string(dt).to_string())
                    .unwrap_or_default(),
                sender_device_model: info.device_model.clone().unwrap_or_default(),
                cert_fingerprint: cert_fingerprint.unwrap_or_default(),
                files: file_list,
            };

            let actions = vec![
                StateAction::StoreDecision {
                    session_id: session_id.clone(),
                    decision_tx,
                },
                StateAction::PushPendingRequest { request },
                StateAction::StorePeer {
                    session_id: session_id.clone(),
                    ip: ip.to_string(),
                    port: info.port,
                    protocol,
                },
            ];
            (Some(event), actions)
        }

        ServerEventV2::FileUpload {
            session_id,
            file_id,
            file,
            target_tx,
        } => {
            let event = BridgeEvent::FileUpload {
                session_id: session_id.clone(),
                file_id: file_id.clone(),
                file_name: file.file_name.clone(),
                size: file.size,
            };
            // 先存储 target_tx，使 fail_file_upload 可以在应答前丢弃发送端
            // （导致 500 响应）。事件循环随后取回应答。
            let actions = vec![StateAction::StorePendingFileUpload {
                key: (session_id, file_id),
                tx: target_tx,
            }];
            (Some(event), actions)
        }

        ServerEventV2::SessionEnd { session_id, reason } => {
            let event = BridgeEvent::SessionEnd {
                session_id: session_id.clone(),
                reason: session_end_reason_from_upstream(reason),
            };
            // 会话结束清理所有中间状态
            let actions = vec![StateAction::ClearSession { session_id }];
            (Some(event), actions)
        }

        ServerEventV2::PrepareUploadAborted { session_id } => {
            let event = BridgeEvent::PrepareUploadAborted {
                session_id: session_id.clone(),
            };
            // 清理 pending decision，用户后续 accept/decline 将返回 SessionExpired
            let actions = vec![StateAction::ClearSession { session_id }];
            (Some(event), actions)
        }

        ServerEventV2::CancelReceived { ip, session_id } => {
            let event = BridgeEvent::CancelReceived {
                ip: ip.to_string(),
                session_id: session_id.clone(),
            };
            let actions = vec![StateAction::ClearSession { session_id }];
            (Some(event), actions)
        }
    }
}

/// 将 WebSendEvent 适配为桥接层事件 + 状态变更动作。
///
/// WebSend 事件与其他事件走同一条 adapter + engine 路径。
pub fn adapt_web_send_event(
    event: localsend::http::server::web::WebSendEvent,
) -> (Option<BridgeEvent>, Vec<StateAction>) {
    use localsend::http::server::web::WebSendEvent;

    match event {
        WebSendEvent::PrepareDownload {
            ip,
            session_id,
            user_agent,
            decision_tx,
        } => {
            let event = BridgeEvent::WebSendPrepareDownload {
                session_id: session_id.clone(),
                ip: ip.to_string(),
                user_agent,
            };
            let actions = vec![StateAction::StoreWebDownloadDecision {
                session_id,
                tx: decision_tx,
            }];
            (Some(event), actions)
        }

        WebSendEvent::FileDownload {
            session_id,
            file_id,
            file,
            content_tx,
        } => {
            let event = BridgeEvent::WebSendFileDownload {
                session_id: session_id.clone(),
                file_id: file_id.clone(),
                file_name: file.file_name.clone(),
                size: file.size,
            };
            // 存储 content_tx，使 fail_file_download 可以丢弃发送端（导致 500 响应）
            let actions = vec![StateAction::StorePendingFileDownload {
                key: (session_id, file_id),
                tx: content_tx,
            }];
            (Some(event), actions)
        }
    }
}

// ── 单元测试 ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    use crate::bridge::adapter::types::SenderInfoDto;
    use crate::bridge::event::SessionEndReason;
    use localsend::http::dto_v2::RegisterDtoV2;
    use localsend::http::server::v2::SessionEndReasonV2;
    use localsend::http::server::PeerIp;
    use localsend::model::discovery::DeviceType;
    use localsend::model::transfer::FileDto as UpstreamFileDto;
    use tokio::sync::oneshot;

    fn peer_ipv4(a: u8, b: u8, c: u8, d: u8) -> PeerIp {
        PeerIp {
            ip: std::net::IpAddr::from(std::net::Ipv4Addr::new(a, b, c, d)),
            scope_id: None,
        }
    }

    fn register_info() -> RegisterDtoV2 {
        RegisterDtoV2 {
            alias: "Sender".to_string(),
            version: "2.2".to_string(),
            device_model: Some("Model".to_string()),
            device_type: Some(DeviceType::Mobile),
            fingerprint: "sender-fp".to_string(),
            port: 53317,
            protocol: ProtocolType::Http,
            download: false,
        }
    }

    fn sample_files() -> HashMap<String, UpstreamFileDto> {
        let mut files = HashMap::new();
        files.insert(
            "f1".to_string(),
            UpstreamFileDto {
                id: "f1".to_string(),
                file_name: "test.txt".to_string(),
                size: 100,
                file_type: "text/plain".to_string(),
                sha256: Some("abc123".to_string()),
                preview: None,
                metadata: None,
            },
        );
        files
    }

    #[test]
    fn adapt_register() {
        let ip = peer_ipv4(192, 168, 1, 5);
        let (event, actions) = adapt_server_event(ServerEventV2::Register {
            ip,
            info: register_info(),
        });
        let event = event.unwrap();
        match event {
            BridgeEvent::Register { ip, info } => {
                assert_eq!(ip, "192.168.1.5");
                assert_eq!(info.alias, "Sender");
                assert_eq!(info.fingerprint, "sender-fp");
                assert_eq!(info.protocol, "http");
            }
            _ => panic!("期望 Register 事件"),
        }
        assert!(actions.is_empty());
    }

    #[test]
    fn adapt_prepare_upload_http() {
        let (tx, _rx) = oneshot::channel();
        let ip = peer_ipv4(10, 0, 0, 1);
        let (event, actions) = adapt_server_event(ServerEventV2::PrepareUpload {
            session_id: "sess-1".to_string(),
            ip,
            info: register_info(),
            cert_fingerprint: None,
            files: sample_files(),
            decision_tx: tx,
        });
        let event = event.unwrap();
        match event {
            BridgeEvent::PrepareUpload {
                session_id,
                sender_ip,
                sender_alias,
                sender_fingerprint,
                sender_device_type,
                sender_device_model,
                cert_fingerprint,
                files,
            } => {
                assert_eq!(session_id, "sess-1");
                assert_eq!(sender_ip, "10.0.0.1");
                assert_eq!(sender_alias, "Sender");
                assert_eq!(sender_fingerprint, "sender-fp");
                assert_eq!(sender_device_type, "mobile");
                assert_eq!(sender_device_model, "Model");
                assert_eq!(cert_fingerprint, "");
                assert_eq!(files.len(), 1);
                assert_eq!(files[0].id, "f1");
                assert_eq!(files[0].file_name, "test.txt");
                assert_eq!(files[0].sha256.as_deref(), Some("abc123"));
            }
            _ => panic!("期望 PrepareUpload 事件"),
        }
        // 应有 StoreDecision + PushPendingRequest + StorePeer
        assert_eq!(actions.len(), 3);
        assert!(
            matches!(&actions[0], StateAction::StoreDecision { session_id, .. } if session_id == "sess-1")
        );
        assert!(
            matches!(&actions[1], StateAction::PushPendingRequest { request } if request.session_id == "sess-1")
        );
        assert!(
            matches!(&actions[2], StateAction::StorePeer { protocol, .. } if *protocol == ProtocolType::Http)
        );
    }

    #[test]
    fn adapt_prepare_upload_https_protocol_inferred() {
        let (tx, _rx) = oneshot::channel();
        let ip = peer_ipv4(10, 0, 0, 1);
        let (_, actions) = adapt_server_event(ServerEventV2::PrepareUpload {
            session_id: "sess-2".to_string(),
            ip,
            info: register_info(),
            cert_fingerprint: Some("CERTFP123".to_string()),
            files: sample_files(),
            decision_tx: tx,
        });
        assert!(
            matches!(&actions[2], StateAction::StorePeer { protocol, .. } if *protocol == ProtocolType::Https)
        );
    }

    #[test]
    fn adapt_file_upload() {
        let (tx, _rx) = oneshot::channel();
        let (event, actions) = adapt_server_event(ServerEventV2::FileUpload {
            session_id: "sess-up".to_string(),
            file_id: "f1".to_string(),
            file: UpstreamFileDto {
                id: "f1".to_string(),
                file_name: "doc.pdf".to_string(),
                size: 999,
                file_type: "application/pdf".to_string(),
                sha256: None,
                preview: None,
                metadata: None,
            },
            target_tx: tx,
        });
        let event = event.unwrap();
        match event {
            BridgeEvent::FileUpload {
                session_id,
                file_id,
                file_name,
                size,
            } => {
                assert_eq!(session_id, "sess-up");
                assert_eq!(file_id, "f1");
                assert_eq!(file_name, "doc.pdf");
                assert_eq!(size, 999);
            }
            _ => panic!("期望 FileUpload 事件"),
        }
        assert!(
            matches!(&actions[0], StateAction::StorePendingFileUpload { key, .. } if key == &("sess-up".to_string(), "f1".to_string()))
        );
    }

    #[test]
    fn adapt_session_end_finished() {
        let (event, actions) = adapt_server_event(ServerEventV2::SessionEnd {
            session_id: "sess-3".to_string(),
            reason: SessionEndReasonV2::Finished,
        });
        match event.unwrap() {
            BridgeEvent::SessionEnd { session_id, reason } => {
                assert_eq!(session_id, "sess-3");
                assert_eq!(reason, SessionEndReason::Finished);
            }
            _ => panic!("期望 SessionEnd 事件"),
        }
        assert!(
            matches!(&actions[0], StateAction::ClearSession { session_id } if session_id == "sess-3")
        );
    }

    #[test]
    fn adapt_session_end_cancelled() {
        let (event, actions) = adapt_server_event(ServerEventV2::SessionEnd {
            session_id: "sess-4".to_string(),
            reason: SessionEndReasonV2::Cancelled,
        });
        assert!(matches!(
            event,
            Some(BridgeEvent::SessionEnd {
                reason: SessionEndReason::Cancelled,
                ..
            })
        ));
        assert_eq!(actions.len(), 1);
    }

    #[test]
    fn adapt_prepare_upload_aborted() {
        let (event, actions) = adapt_server_event(ServerEventV2::PrepareUploadAborted {
            session_id: "sess-abort".to_string(),
        });
        match event.unwrap() {
            BridgeEvent::PrepareUploadAborted { session_id } => {
                assert_eq!(session_id, "sess-abort");
            }
            _ => panic!("期望 PrepareUploadAborted 事件"),
        }
        assert!(
            matches!(&actions[0], StateAction::ClearSession { session_id } if session_id == "sess-abort")
        );
    }

    #[test]
    fn adapt_cancel_received() {
        let ip = peer_ipv4(127, 0, 0, 1);
        let (event, actions) = adapt_server_event(ServerEventV2::CancelReceived {
            ip,
            session_id: "sess-cancel".to_string(),
        });
        match event.unwrap() {
            BridgeEvent::CancelReceived { ip, session_id } => {
                assert_eq!(ip, "127.0.0.1");
                assert_eq!(session_id, "sess-cancel");
            }
            _ => panic!("期望 CancelReceived 事件"),
        }
        assert_eq!(actions.len(), 1);
    }

    #[test]
    fn adapt_web_send_prepare_download() {
        use localsend::http::server::web::WebSendEvent;
        let (tx, _rx) = oneshot::channel();
        let ip = peer_ipv4(192, 168, 1, 9);
        let (event, actions) = adapt_web_send_event(WebSendEvent::PrepareDownload {
            ip,
            session_id: "web-1".to_string(),
            user_agent: Some("Mozilla".to_string()),
            decision_tx: tx,
        });
        match event.unwrap() {
            BridgeEvent::WebSendPrepareDownload {
                session_id,
                ip,
                user_agent,
            } => {
                assert_eq!(session_id, "web-1");
                assert_eq!(ip, "192.168.1.9");
                assert_eq!(user_agent.as_deref(), Some("Mozilla"));
            }
            _ => panic!("期望 WebSendPrepareDownload 事件"),
        }
        assert!(
            matches!(&actions[0], StateAction::StoreWebDownloadDecision { session_id, .. } if session_id == "web-1")
        );
    }

    #[test]
    fn adapt_web_send_file_download() {
        use localsend::http::server::web::WebSendEvent;
        let (tx, _rx) = oneshot::channel();
        let (event, actions) = adapt_web_send_event(WebSendEvent::FileDownload {
            session_id: "web-2".to_string(),
            file_id: "f1".to_string(),
            file: UpstreamFileDto {
                id: "f1".to_string(),
                file_name: "a.pdf".to_string(),
                size: 100,
                file_type: "application/pdf".to_string(),
                sha256: None,
                preview: None,
                metadata: None,
            },
            content_tx: tx,
        });
        match event.unwrap() {
            BridgeEvent::WebSendFileDownload {
                session_id,
                file_id,
                file_name,
                size,
            } => {
                assert_eq!(session_id, "web-2");
                assert_eq!(file_id, "f1");
                assert_eq!(file_name, "a.pdf");
                assert_eq!(size, 100);
            }
            _ => panic!("期望 WebSendFileDownload 事件"),
        }
        assert!(
            matches!(&actions[0], StateAction::StorePendingFileDownload { key, .. } if key == &("web-2".to_string(), "f1".to_string()))
        );
    }

    #[test]
    fn sender_info_dto_serializes_sender_info() {
        let dto = SenderInfoDto {
            alias: "A".into(),
            version: "2.2".into(),
            device_model: None,
            device_type: Some("mobile".into()),
            fingerprint: "fp".into(),
            download: true,
            port: 53317,
            protocol: "http".into(),
        };
        let json = serde_json::to_value(&dto).unwrap();
        assert_eq!(json["alias"], "A");
        assert_eq!(json["deviceType"], "mobile");
    }
}
