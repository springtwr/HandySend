//! 显式状态变更动作（StateAction）与应用函数（apply_actions）。
//!
//! 事件处理拆为两步：
//! 1. `adapter::adapt_xxx(event)` 纯函数把上游事件转为 `(Option<BridgeEvent>, Vec<StateAction>)`
//! 2. `engine::apply_actions(&mut BridgeState, Vec<StateAction>)` 应用显式状态变更
//!
//! 两者均为纯函数（无 IO、无 runtime），可直接单元测试——测试可断言
//! StateAction 列表，状态变更显式可查。

use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::PrepareUploadDecisionV2;
use localsend::http::server::ServerHandle;
use localsend::model::discovery::ProtocolType;
use localsend::model::transfer::FileContent;
use tokio::sync::oneshot;

use crate::bridge::lock;
use crate::bridge::state::{BridgeState, PendingRequest};

/// 状态变更动作。
pub enum StateAction {
    /// 存储 PrepareUpload 决策发送端（等待用户响应）。
    StoreDecision {
        session_id: String,
        decision_tx: oneshot::Sender<PrepareUploadDecisionV2>,
    },
    /// 清理会话关联的中间状态（决策、pending_requests、peer 等）。
    ClearSession { session_id: String },

    /// 设置服务器句柄。
    SetServerHandle { handle: ServerHandle },
    /// 记录服务器实际绑定端口。
    SetServerPort { port: u16 },
    /// 清除服务器句柄。
    ClearServerHandle,

    /// 存储会话对端信息（用于接收方取消时向发送方发 /cancel）。
    StorePeer {
        session_id: String,
        ip: String,
        port: u16,
        protocol: ProtocolType,
    },
    /// 清除会话对端信息。
    ClearPeer { session_id: String },

    /// 存储 Web 下载决策发送端。
    StoreWebDownloadDecision {
        session_id: String,
        tx: oneshot::Sender<bool>,
    },
    /// 清除 Web 下载决策。
    ClearWebDownloadDecision { session_id: String },

    /// 存储待处理文件上传目标。
    StorePendingFileUpload {
        key: (String, String),
        tx: oneshot::Sender<FileUploadTarget>,
    },
    /// 清除待处理文件上传目标。
    ClearPendingFileUpload { key: (String, String) },

    /// 存储待处理文件下载内容。
    StorePendingFileDownload {
        key: (String, String),
        tx: oneshot::Sender<FileContent>,
    },
    /// 清除待处理文件下载内容。
    ClearPendingFileDownload { key: (String, String) },

    /// 推入一个待处理请求。
    PushPendingRequest { request: PendingRequest },
    /// 按 session_id 移除待处理请求。
    RemovePendingRequest { session_id: String },
}

/// 应用一批状态变更动作到 `state`。
///
/// 纯函数：无 IO、无 runtime、无事件发送。事件发送由调用方（adapter 调用点）
/// 在 apply_actions 之后通过 event_tx 完成。
pub fn apply_actions(state: &mut BridgeState, actions: Vec<StateAction>) {
    for action in actions {
        apply_action(state, action);
    }
}

fn apply_action(state: &mut BridgeState, action: StateAction) {
    match action {
        StateAction::StoreDecision {
            session_id,
            decision_tx,
        } => {
            state.pending_decisions.insert(session_id, decision_tx);
        }
        StateAction::ClearSession { session_id } => {
            state.pending_decisions.remove(&session_id);
            lock(&state.pending_requests).retain(|r| r.session_id != session_id);
            state.session_peers.remove(&session_id);
        }
        StateAction::SetServerHandle { handle } => {
            state.server_handle = Some(handle);
        }
        StateAction::SetServerPort { port } => {
            state.local_port = port;
        }
        StateAction::ClearServerHandle => {
            state.server_handle.take();
        }
        StateAction::StorePeer {
            session_id,
            ip,
            port,
            protocol,
        } => {
            state.session_peers.insert(session_id, (ip, port, protocol));
        }
        StateAction::ClearPeer { session_id } => {
            state.session_peers.remove(&session_id);
        }
        StateAction::StoreWebDownloadDecision { session_id, tx } => {
            state.web_download_decisions.insert(session_id, tx);
        }
        StateAction::ClearWebDownloadDecision { session_id } => {
            state.web_download_decisions.remove(&session_id);
        }
        StateAction::StorePendingFileUpload { key, tx } => {
            state.pending_file_uploads.insert(key, tx);
        }
        StateAction::ClearPendingFileUpload { key } => {
            state.pending_file_uploads.remove(&key);
        }
        StateAction::StorePendingFileDownload { key, tx } => {
            state.pending_file_downloads.insert(key, tx);
        }
        StateAction::ClearPendingFileDownload { key } => {
            state.pending_file_downloads.remove(&key);
        }
        StateAction::PushPendingRequest { request } => {
            lock(&state.pending_requests).push(request);
        }
        StateAction::RemovePendingRequest { session_id } => {
            lock(&state.pending_requests).retain(|r| r.session_id != session_id);
        }
    }
}

// ── 单元测试 ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::oneshot;

    use localsend::http::server::v2::PrepareUploadDecisionV2;

    fn new_state() -> BridgeState {
        BridgeState::new()
    }

    #[test]
    fn test_store_and_clear_decision() {
        let mut state = new_state();
        let (tx, _rx) = oneshot::channel();
        apply_actions(
            &mut state,
            vec![StateAction::StoreDecision {
                session_id: "s-1".into(),
                decision_tx: tx,
            }],
        );
        assert!(state.pending_decisions.contains_key("s-1"));

        apply_actions(
            &mut state,
            vec![StateAction::ClearSession {
                session_id: "s-1".into(),
            }],
        );
        assert!(!state.pending_decisions.contains_key("s-1"));
    }

    #[test]
    fn test_set_server_handle_and_port() {
        let mut state = new_state();
        // 无法轻易构造 ServerHandle（上游私有字段），验证 port 与 ClearServerHandle
        apply_actions(&mut state, vec![StateAction::SetServerPort { port: 54321 }]);
        assert_eq!(state.local_port, 54321);
        assert!(state.server_handle.is_none());
        apply_actions(&mut state, vec![StateAction::ClearServerHandle]);
        assert!(state.server_handle.is_none());
    }

    #[test]
    fn test_store_peer_and_clear_peer() {
        let mut state = new_state();
        apply_actions(
            &mut state,
            vec![StateAction::StorePeer {
                session_id: "s-1".into(),
                ip: "192.168.1.5".into(),
                port: 53317,
                protocol: ProtocolType::Https,
            }],
        );
        assert_eq!(state.session_peers.len(), 1);
        let (ip, port, proto) = &state.session_peers["s-1"];
        assert_eq!(ip, "192.168.1.5");
        assert_eq!(*port, 53317);
        assert_eq!(*proto, ProtocolType::Https);

        apply_actions(
            &mut state,
            vec![StateAction::ClearPeer {
                session_id: "s-1".into(),
            }],
        );
        assert!(state.session_peers.is_empty());
    }

    #[test]
    fn test_push_and_remove_pending_request() {
        let mut state = new_state();
        let request = PendingRequest {
            session_id: "s-1".into(),
            sender_alias: "Phone".into(),
            sender_fingerprint: "fp".into(),
            sender_protocol: "https".into(),
            files: vec![],
        };
        apply_actions(
            &mut state,
            vec![StateAction::PushPendingRequest { request }],
        );
        assert_eq!(state.pending_requests.lock().unwrap().len(), 1);

        apply_actions(
            &mut state,
            vec![StateAction::RemovePendingRequest {
                session_id: "s-1".into(),
            }],
        );
        assert!(state.pending_requests.lock().unwrap().is_empty());
    }

    #[test]
    fn test_clear_session_removes_requests_and_peers() {
        let mut state = new_state();
        let request = PendingRequest {
            session_id: "s-2".into(),
            sender_alias: "Phone".into(),
            sender_fingerprint: "fp".into(),
            sender_protocol: "https".into(),
            files: vec![],
        };
        let (tx, _rx) = oneshot::channel();
        apply_actions(
            &mut state,
            vec![
                StateAction::StoreDecision {
                    session_id: "s-2".into(),
                    decision_tx: tx,
                },
                StateAction::PushPendingRequest { request },
                StateAction::StorePeer {
                    session_id: "s-2".into(),
                    ip: "10.0.0.2".into(),
                    port: 53317,
                    protocol: ProtocolType::Http,
                },
            ],
        );
        assert_eq!(state.pending_decisions.len(), 1);
        assert_eq!(state.session_peers.len(), 1);

        apply_actions(
            &mut state,
            vec![StateAction::ClearSession {
                session_id: "s-2".into(),
            }],
        );
        assert!(state.pending_decisions.is_empty());
        assert!(state.session_peers.is_empty());
        assert!(state.pending_requests.lock().unwrap().is_empty());
    }

    #[test]
    fn test_web_download_decision_store_and_clear() {
        let mut state = new_state();
        let (tx, _rx) = oneshot::channel();
        apply_actions(
            &mut state,
            vec![StateAction::StoreWebDownloadDecision {
                session_id: "w-1".into(),
                tx,
            }],
        );
        assert!(state.web_download_decisions.contains_key("w-1"));
        apply_actions(
            &mut state,
            vec![StateAction::ClearWebDownloadDecision {
                session_id: "w-1".into(),
            }],
        );
        assert!(state.web_download_decisions.is_empty());
    }

    #[test]
    fn test_pending_file_upload_store_and_clear() {
        let mut state = new_state();
        let (tx, _rx) = oneshot::channel();
        let key = ("s-1".to_string(), "f-1".to_string());
        apply_actions(
            &mut state,
            vec![StateAction::StorePendingFileUpload {
                key: key.clone(),
                tx,
            }],
        );
        assert!(state.pending_file_uploads.contains_key(&key));
        apply_actions(
            &mut state,
            vec![StateAction::ClearPendingFileUpload { key: key.clone() }],
        );
        assert!(state.pending_file_uploads.is_empty());
    }

    #[test]
    fn test_pending_file_download_store_and_clear() {
        let mut state = new_state();
        let (tx, _rx) = oneshot::channel();
        let key = ("s-1".to_string(), "f-1".to_string());
        apply_actions(
            &mut state,
            vec![StateAction::StorePendingFileDownload {
                key: key.clone(),
                tx,
            }],
        );
        assert!(state.pending_file_downloads.contains_key(&key));
        apply_actions(
            &mut state,
            vec![StateAction::ClearPendingFileDownload { key: key.clone() }],
        );
        assert!(state.pending_file_downloads.is_empty());
    }

    #[test]
    fn test_accept_decision_semantics_via_direct_state() {
        // 验证 StoreDecision 后，oneshot 发送端可用于发出 Accept 决策
        let mut state = new_state();
        let (tx, mut rx) = oneshot::channel();
        apply_actions(
            &mut state,
            vec![StateAction::StoreDecision {
                session_id: "s-3".into(),
                decision_tx: tx,
            }],
        );
        let sender = state.pending_decisions.remove("s-3").unwrap();
        let file_ids: std::collections::HashSet<String> = ["a".to_string()].into_iter().collect();
        sender
            .send(PrepareUploadDecisionV2::Accept(file_ids))
            .unwrap();
        match rx.try_recv().unwrap() {
            PrepareUploadDecisionV2::Accept(ids) => assert!(ids.contains("a")),
            PrepareUploadDecisionV2::Decline => panic!("期望 Accept"),
        }
    }

    #[test]
    fn test_apply_actions_handles_empty_and_mixed() {
        let mut state = new_state();
        apply_actions(&mut state, vec![]);
        assert_eq!(state.local_port, 53317);

        let (tx, _rx) = oneshot::channel::<FileContent>();
        let actions: Vec<StateAction> = vec![
            StateAction::SetServerPort { port: 1111 },
            StateAction::StorePendingFileDownload {
                key: ("a".into(), "b".into()),
                tx,
            },
            StateAction::ClearServerHandle,
        ];
        apply_actions(&mut state, actions);
        assert_eq!(state.local_port, 1111);
        assert!(state
            .pending_file_downloads
            .contains_key(&("a".to_string(), "b".to_string())));
    }
}
