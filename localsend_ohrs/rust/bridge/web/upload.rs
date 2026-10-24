//! 上传会话（浏览器 → 本机，每客户端独立槽）。
//!
//! 与下载对称：token 键代替旧 v2 全局单槽，多浏览器同传不 409。
//! 字节落盘由服务端直接写暂存目录（测试）/接收目录（生产接线时
//! ArkTS 指定）；完成路径经进度事件上报，由 ArkTS 归档到
//! Download 与接收历史。接受即全量（不再逐文件挑）。

use std::collections::HashMap;
use std::time::{Duration, Instant};

use tokio::sync::oneshot;

use crate::bridge::web::session::{SessionEndReason, SessionTimeouts};

/// 上传会话状态：待确认（持有决策发送端）/ 已接受。
#[derive(Debug)]
pub enum UploadState {
    /// 待确认。
    Pending {
        decision_tx: Option<oneshot::Sender<bool>>,
    },
    /// 已接受：可按文件清单逐个上传。
    Accepted,
}

/// 单个待上传文件（服务端落盘进度）。
#[derive(Clone, Debug)]
pub struct UploadFile {
    /// 客户端侧文件标识（浏览器生成，上传 URL 复用它）。
    pub file_id: String,
    /// 文件名（落盘时清洗分隔符）。
    pub file_name: String,
    /// 声明类型（展示用）。
    pub file_type: String,
    /// 声明大小（字节；超量即 413）。
    pub size: u64,
    /// 已接收字节。
    pub received: u64,
    /// 最终落盘路径（确认前由 ArkTS 指定；缺省为上传目录）。
    /// 完成前写同名 `.part` 临时文件，完成后改名（同目录原子操作）。
    pub path: String,
    /// 是否已完成。
    pub done: bool,
    /// 是否有请求正在写入（同文件并发上传回 409，避免交错写坏）。
    pub uploading: bool,
}

/// 上传会话（一浏览器一 token，与下载会话相互独立）。
#[derive(Debug)]
pub struct UploadSession {
    /// 浏览器 UUID。
    pub token: String,
    /// 归属分享标识。
    pub share_id: String,
    /// 创建时的对端 IP。
    pub peer_ip: String,
    /// 浏览器标识（诊断用）。
    pub user_agent: Option<String>,
    /// 建会话时刻。
    pub created_at: Instant,
    /// 最近文件活动时刻。
    pub last_activity: Instant,
    /// 当前状态。
    pub state: UploadState,
    /// 本次允许上传的文件表。
    pub files: HashMap<String, UploadFile>,
    /// 是否已开始上传（任一文件收到首字节）。
    pub download_started: bool,
}

/// 上传会话存储（token → 会话）。
#[derive(Debug, Default)]
pub struct UploadStore {
    /// 活跃会话表。
    pub sessions: HashMap<String, UploadSession>,
    /// 超时配置（与下载同口径）。
    pub timeouts: SessionTimeouts,
}

impl UploadStore {
    /// 登记待确认会话。
    pub fn insert_pending(&mut self, session: UploadSession) {
        self.sessions.insert(session.token.clone(), session);
    }

    /// 是否存在会话。
    pub fn contains(&self, token: &str) -> bool {
        self.sessions.contains_key(token)
    }

    /// 接受：待确认转已接受并刷新时刻；已接受幂等成功。
    pub fn accept(&mut self, token: &str, now: Instant) -> Result<(), SessionEndReason> {
        let Some(session) = self.sessions.get_mut(token) else {
            return Err(SessionEndReason::PendingTimeout);
        };
        match &mut session.state {
            UploadState::Pending { decision_tx } => {
                if let Some(tx) = decision_tx.take() {
                    let _ = tx.send(true);
                }
                session.state = UploadState::Accepted;
                session.last_activity = now;
                Ok(())
            }
            UploadState::Accepted => {
                session.last_activity = now;
                Ok(())
            }
        }
    }

    /// 拒绝：发送拒绝并移除会话（调用方负责清理已落盘的临时文件）。
    pub fn decline(&mut self, token: &str) -> Option<UploadSession> {
        let mut session = self.sessions.remove(token)?;
        if let UploadState::Pending { decision_tx } = &mut session.state {
            if let Some(tx) = decision_tx.take() {
                let _ = tx.send(false);
            }
        }
        Some(session)
    }

    /// 过期：移除会话、清理临时文件并丢弃决策发送端（等待方收 408）。
    pub fn expire(&mut self, token: &str) -> bool {
        let Some(session) = self.sessions.remove(token) else {
            return false;
        };
        for file in session.files.values() {
            let tmp = format!("{}.part", file.path);
            let _ = std::fs::remove_file(&tmp);
            let _ = std::fs::remove_file(&file.path);
        }
        true
    }

    /// 刷新活动时刻。
    pub fn touch(&mut self, token: &str, now: Instant) {
        if let Some(session) = self.sessions.get_mut(token) {
            session.last_activity = now;
        }
    }

    /// 标记已开始上传。
    pub fn mark_started(&mut self, token: &str) {
        if let Some(session) = self.sessions.get_mut(token) {
            session.download_started = true;
        }
    }

    /// 设置落盘目标（确认前由 ArkTS 指定最终路径；未知条目忽略）。
    /// 返回实际生效条目数（调用方可据此发现标识漂移）。
    pub fn set_targets(&mut self, token: &str, targets: &[(String, String)]) -> usize {
        let Some(session) = self.sessions.get_mut(token) else {
            return 0;
        };
        let mut applied: usize = 0;
        for (file_id, path) in targets {
            if path.is_empty() {
                continue;
            }
            if let Some(entry) = session.files.get_mut(file_id) {
                if !entry.done {
                    entry.path = path.clone();
                    applied += 1;
                }
            }
        }
        applied
    }

    /// 终结超时会话并返回（会话，原因）：待确认超 `pending`，
    /// 已接受且从未开始上传超 `wait_first_file`。
    /// 返回完整会话，调用方负责清理临时文件。
    pub fn sweep(&mut self, now: Instant) -> Vec<(UploadSession, SessionEndReason)> {        let timeouts = self.timeouts;
        let expired: Vec<(String, SessionEndReason)> = self
            .sessions
            .iter()
            .filter_map(|(token, session)| {
                let reason = match &session.state {
                    UploadState::Pending { .. }
                        if now.duration_since(session.created_at) >= timeouts.pending =>
                    {
                        Some(SessionEndReason::PendingTimeout)
                    }
                    UploadState::Accepted
                        if !session.download_started
                            && now.duration_since(session.last_activity)
                                >= timeouts.wait_first_file =>
                    {
                        Some(SessionEndReason::PeerNoDownload)
                    }
                    _ => None,
                };
                reason.map(|reason| (token.clone(), reason))
            })
            .collect();
        let mut ended: Vec<(UploadSession, SessionEndReason)> = Vec::new();
        for (token, reason) in expired {
            if let Some(session) = self.sessions.remove(&token) {
                ended.push((session, reason));
            }
        }
        ended
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pending_session(token: &str) -> (UploadSession, oneshot::Receiver<bool>) {
        let (tx, rx) = oneshot::channel();
        let now = Instant::now();
        let session = UploadSession {
            token: token.to_string(),
            share_id: "share-1".to_string(),
            peer_ip: "192.168.1.2".to_string(),
            user_agent: None,
            created_at: now,
            last_activity: now,
            state: UploadState::Pending {
                decision_tx: Some(tx),
            },
            files: HashMap::new(),
            download_started: false,
        };
        (session, rx)
    }

    #[test]
    fn test_accept_pending_upload_notifies_true() {
        let mut store = UploadStore::default();
        let (session, mut rx) = pending_session("up-1");
        store.insert_pending(session);
        store.accept("up-1", Instant::now()).unwrap();
        assert_eq!(rx.try_recv().unwrap(), true);
        assert!(store.contains("up-1"));
    }

    #[test]
    fn test_decline_upload_notifies_false_and_removes() {
        let mut store = UploadStore::default();
        let (session, mut rx) = pending_session("up-2");
        store.insert_pending(session);
        assert!(store.decline("up-2").is_some());
        assert_eq!(rx.try_recv().unwrap(), false);
        assert!(!store.contains("up-2"));
    }

    #[test]
    fn test_expire_upload_drops_decision_sender() {
        let mut store = UploadStore::default();
        let (session, mut rx) = pending_session("up-3");
        store.insert_pending(session);
        assert!(store.expire("up-3"));
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn test_set_targets_applies_known_files_only() {
        let mut store = UploadStore::default();
        let (mut session, _rx) = pending_session("up-4");
        session.files.insert(
            "f1".to_string(),
            UploadFile {
                file_id: "f1".to_string(),
                file_name: "a.txt".to_string(),
                file_type: "text/plain".to_string(),
                size: 3,
                received: 0,
                path: "/tmp/staging/a.txt".to_string(),
                done: false,
                uploading: false,
            },
        );
        store.insert_pending(session);
        let applied = store.set_targets(
            "up-4",
            &[
                ("f1".to_string(), "/dl/a.txt".to_string()),
                ("nope".to_string(), "/dl/x".to_string()),
                ("f1".to_string(), "".to_string()),
            ],
        );
        assert_eq!(applied, 1);
        assert_eq!(
            store.sessions["up-4"].files["f1"].path,
            "/dl/a.txt".to_string()
        );
        assert_eq!(store.set_targets("missing", &[]), 0);
    }

    #[test]
    fn test_sweep_pending_upload_timeout() {        let mut store = UploadStore {
            timeouts: SessionTimeouts {
                pending: Duration::from_millis(10),
                ..Default::default()
            },
            ..Default::default()
        };
        let (session, _rx) = pending_session("up-4");
        store.insert_pending(session);
        std::thread::sleep(Duration::from_millis(20));
        let ended = store.sweep(Instant::now());
        assert_eq!(ended.len(), 1);
        assert_eq!(ended[0].0.token, "up-4");
        assert_eq!(ended[0].1, SessionEndReason::PendingTimeout);
    }
}
