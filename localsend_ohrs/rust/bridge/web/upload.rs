//! 上传会话（浏览器 → 本机，每客户端独立槽）。
//!
//! 与下载对称：token 键代替旧 v2 全局单槽，多浏览器同传不 409。
//! 字节落盘由服务端直接写暂存目录（测试）/接收目录（生产接线时
//! ArkTS 指定）；完成路径经进度事件上报，由 ArkTS 归档到
//! Download 与接收历史。接受即全量（不再逐文件挑）。
//!
//! 未完成的字节写在目标目录下的应用保留子目录
//! `.handysend-temp/web/`，完成后同目录原子改名。会话终结时删除未完成文件并
//! 移除已空的子目录；网页协议子目录由本应用独占，进程被强制终止时遗留的
//! 半成品在下次接受上传时清理，不会触碰其他协议临时文件或用户文件。旧名
//! `.handysend-upload-part/` 作为 legacy 目录 best-effort 清理。

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::Instant;

use tokio::sync::oneshot;

use crate::bridge::temp_workspace;
use crate::bridge::web::session::{SessionEndReason, SessionTimeouts};

/// 未完成上传的临时目录（网页协议子目录；与最终文件同父目录，保证原子改名）。
pub(crate) fn part_dir(final_path: &str) -> PathBuf {
    temp_workspace::temp_dir(final_path, temp_workspace::TEMP_SUBDIR_WEB)
}

/// 未完成上传的临时文件路径（文件名与最终文件同名，父目录为网页协议子目录）。
pub(crate) fn part_path(final_path: &str) -> PathBuf {
    temp_workspace::temp_path(final_path, temp_workspace::TEMP_SUBDIR_WEB)
}

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
    /// 文本消息内容（仅手动输入的文本携带；普通文件为空）。
    pub preview: Option<String>,
    /// 声明大小（字节；超量即 413）。
    pub size: u64,
    /// 已接收字节。
    pub received: u64,
    /// 最终落盘路径（确认前由 ArkTS 指定；缺省为上传目录）。
    /// 完成前写保留子目录中的同名临时文件，完成后改名（同目录原子操作）。
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
    /// 页面实例标识（同标签页刷新保留；关闭/新标签页不同）。
    pub client_id: String,
    /// 建会话声明清单的指纹（同 client 重试时用于判断是否同一批文件）。
    pub batch_key: String,
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
    /// 建会话时声明的文件数（文件条目可能因 413/落盘失败被移除，用于判定清单是否完整）。
    pub declared_files: usize,
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

    /// 过期：移除会话、清理未完成的临时文件并移除空临时目录，
    /// 丢弃决策发送端（等待方收 408）。
    pub fn expire(&mut self, token: &str) -> bool {
        let Some(session) = self.sessions.remove(token) else {
            return false;
        };
        // 只清理未完成的临时文件：已完成条目已改名为最终交付文件，
        // 不能因为会话过期把用户已收到的文件删掉。
        cleanup_session_parts(&session);
        true
    }

    /// 刷新活动时刻。
    pub fn touch(&mut self, token: &str, now: Instant) {
        if let Some(session) = self.sessions.get_mut(token) {
            session.last_activity = now;
        }
    }

    /// 设置落盘目标（确认前由 ArkTS 指定最终路径；未知条目忽略）。
    /// 返回实际生效条目数（调用方可据此发现标识漂移）。
    ///
    /// 接受新一批上传前顺带清理目标目录内应用保留临时区的遗留文件：
    /// 进程被强制终止时这些半成品不会走到过期/拒绝路径，只能在此兜底；
    /// 清理范围仅限网页协议子目录 `.handysend-temp/web/` 内且不属于任何
    /// 活跃上传会话的文件，不会删除最终交付文件、其他协议临时文件或用户文件。
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
        // 收集仍需保留的活跃临时文件，避免清理正在上传的其他会话。
        let active: HashSet<PathBuf> = self
            .sessions
            .values()
            .flat_map(|session| session.files.values())
            .filter(|file| !file.done)
            .map(|file| part_path(&file.path))
            .collect();
        let mut dirs: HashSet<PathBuf> = HashSet::new();
        for (_, path) in targets {
            if !path.is_empty() {
                if let Some(parent) = Path::new(path).parent() {
                    dirs.insert(parent.to_path_buf());
                }
            }
        }
        for dir in dirs {
            // 只清理网页协议自己的临时子目录与旧版本 legacy 目录，
            // 不触碰 LocalSend/MTA 正在写入的临时文件。
            temp_workspace::cleanup_namespace(&dir, temp_workspace::TEMP_SUBDIR_WEB, &active);
            temp_workspace::cleanup_legacy(&dir, &active);
            // 旧版协议子目录（如 local-send）新版本不再写入，升级后一并清掉。
            temp_workspace::cleanup_legacy_subdirs(&dir);
        }
        applied
    }

    /// 终结超时会话并返回（会话，原因）：待确认超 `pending`，
    /// 已接受且从未开始上传超 `wait_first_file`。
    /// 返回完整会话，调用方负责清理临时文件。
    pub fn sweep(&mut self, now: Instant) -> Vec<(UploadSession, SessionEndReason)> {
        let timeouts = self.timeouts;
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
                    // 已开始上传后长时间无活动：清理服务端会话。正在写盘的
                    // 文件请求（`uploading`）不算空闲，避免把大文件传到一半收掉。
                    UploadState::Accepted
                        if session.download_started
                            && !session.files.values().any(|file| file.uploading)
                            && now.duration_since(session.last_activity) >= timeouts.idle =>
                    {
                        Some(SessionEndReason::PeerIdle)
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

/// 清理会话未完成的临时文件，并尝试移除已空的临时目录。
///
/// 已完成条目已改名为最终交付文件，不能删除；目录非空说明同目录
/// 还有其他活跃上传，删除失败时保留，由最后一个结束的会话清理。
pub(crate) fn cleanup_session_parts(session: &UploadSession) {
    let mut dirs: HashSet<PathBuf> = HashSet::new();
    for file in session.files.values() {
        if file.path.is_empty() {
            continue;
        }
        if !file.done {
            let _ = std::fs::remove_file(part_path(&file.path));
        }
        dirs.insert(part_dir(&file.path));
    }
    for dir in dirs {
        let _ = std::fs::remove_dir(&dir);
        if let Some(root) = dir.parent() {
            let _ = std::fs::remove_dir(root);
        }
    }
}

/// 删除未完成的临时文件，并尝试移除已空的临时目录。
///
/// 用于上传失败分支：文件条目可能随后被移出会话，届时无法再从清单
/// 反推临时目录，因此在这里顺手清理。
pub(crate) fn remove_part_file_and_dir(path: &Path) {
    temp_workspace::remove_temp_file(path);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn pending_session(token: &str) -> (UploadSession, oneshot::Receiver<bool>) {
        let (tx, rx) = oneshot::channel();
        let now = Instant::now();
        let session = UploadSession {
            token: token.to_string(),
            client_id: "client-1".to_string(),
            batch_key: "batch-1".to_string(),
            share_id: "share-1".to_string(),
            peer_ip: "192.168.1.2".to_string(),
            user_agent: None,
            created_at: now,
            last_activity: now,
            state: UploadState::Pending {
                decision_tx: Some(tx),
            },
            files: HashMap::new(),
            declared_files: 0,
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
                preview: None,
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

    fn upload_file(file_id: &str, path: &str) -> UploadFile {
        UploadFile {
            file_id: file_id.to_string(),
            file_name: "a.txt".to_string(),
            file_type: "text/plain".to_string(),
            preview: None,
            size: 3,
            received: 0,
            path: path.to_string(),
            done: false,
            uploading: false,
        }
    }

    #[test]
    fn test_part_path_stays_in_reserved_dir() {
        let expected_dir = PathBuf::from("/dl/dir")
            .join(temp_workspace::TEMP_DIR_NAME)
            .join(temp_workspace::TEMP_SUBDIR_WEB);
        assert_eq!(part_path("/dl/dir/a.txt"), expected_dir.join("a.txt"));
        assert_eq!(part_dir("/dl/dir/a.txt"), expected_dir);
    }

    #[test]
    fn test_cleanup_session_parts_removes_empty_dir() {
        let root = std::env::temp_dir().join(format!(
            "handysend-part-cleanup-empty-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let final_path = root.join("a.txt").to_string_lossy().into_owned();
        let part = part_path(&final_path);
        std::fs::create_dir_all(part.parent().unwrap()).unwrap();
        std::fs::write(&part, b"half").unwrap();

        let (mut session, _rx) = pending_session("up-clean-empty");
        session
            .files
            .insert("f1".to_string(), upload_file("f1", &final_path));
        cleanup_session_parts(&session);

        assert!(!part.exists(), "未完成临时文件应被删除");
        assert!(!part_dir(&final_path).exists(), "空临时目录应被删除");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_cleanup_session_parts_keeps_non_empty_dir() {
        let root = std::env::temp_dir().join(format!(
            "handysend-part-cleanup-nonempty-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let final_path = root.join("a.txt").to_string_lossy().into_owned();
        let dir = part_dir(&final_path);
        std::fs::create_dir_all(&dir).unwrap();
        let mine = part_path(&final_path);
        let other = dir.join("other.txt");
        std::fs::write(&mine, b"half").unwrap();
        std::fs::write(&other, b"inflight").unwrap();

        let (mut session, _rx) = pending_session("up-clean-nonempty");
        session
            .files
            .insert("f1".to_string(), upload_file("f1", &final_path));
        cleanup_session_parts(&session);

        assert!(!mine.exists(), "本会话的临时文件应被删除");
        assert!(other.exists(), "其他活跃上传的临时文件不能删");
        assert!(dir.exists(), "目录非空时应保留");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_cleanup_session_parts_keeps_delivered_file() {
        let root = std::env::temp_dir().join(format!(
            "handysend-part-cleanup-done-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let final_path = root.join("a.txt").to_string_lossy().into_owned();
        std::fs::write(&final_path, b"done").unwrap();

        let (mut session, _rx) = pending_session("up-clean-done");
        let mut file = upload_file("f1", &final_path);
        file.done = true;
        session.files.insert("f1".to_string(), file);
        cleanup_session_parts(&session);

        assert!(
            std::path::Path::new(&final_path).exists(),
            "已交付文件不能删"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn test_set_targets_cleans_stale_parts_only() {
        let dir = std::env::temp_dir().join(format!("handysend-part-clean-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let web_temp = part_dir(&dir.join("probe.txt").to_string_lossy());
        std::fs::create_dir_all(&web_temp).unwrap();
        // 上轮进程遗留的半成品、另一活跃会话的半成品、用户自己的文件。
        let orphan = web_temp.join("orphan.txt");
        let other_final = dir.join("keep.txt").to_string_lossy().into_owned();
        let active = part_path(&other_final);
        let user = dir.join("user.txt");
        std::fs::write(&orphan, b"stale").unwrap();
        std::fs::write(&active, b"inflight").unwrap();
        std::fs::write(&user, b"mine").unwrap();

        let mut store = UploadStore::default();
        let (mut current, _rx) = pending_session("up-current");
        current.files.insert(
            "f1".to_string(),
            upload_file("f1", &dir.join("new.txt").to_string_lossy()),
        );
        store.insert_pending(current);
        let (mut other, _rx) = pending_session("up-other");
        other
            .files
            .insert("f1".to_string(), upload_file("f1", &other_final));
        store.insert_pending(other);

        let target = dir.join("new.txt").to_string_lossy().into_owned();
        assert_eq!(
            store.set_targets("up-current", &[("f1".to_string(), target)]),
            1
        );
        assert!(!orphan.exists(), "上轮遗留的半成品应被清理");
        assert!(active.exists(), "正在上传的临时文件不能删");
        assert!(user.exists(), "目标目录里的用户文件不能删");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_set_targets_keeps_other_protocol_temp() {
        let dir = std::env::temp_dir().join(format!(
            "handysend-part-cross-protocol-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let final_path = dir.join("new.txt").to_string_lossy().into_owned();
        let web_temp = part_dir(&final_path);
        std::fs::create_dir_all(&web_temp).unwrap();
        let orphan = web_temp.join("orphan.txt");
        std::fs::write(&orphan, b"stale").unwrap();
        // LocalSend/MTA 正在写入的临时文件，网页清理不能触碰。
        let local_temp =
            temp_workspace::temp_dir(&final_path, temp_workspace::TEMP_SUBDIR_LOCAL_SEND);
        let mta_temp = temp_workspace::temp_dir(&final_path, temp_workspace::TEMP_SUBDIR_MTA);
        std::fs::create_dir_all(&local_temp).unwrap();
        std::fs::create_dir_all(&mta_temp).unwrap();
        let local_file = local_temp.join("new.txt");
        let mta_file = mta_temp.join("new.txt");
        std::fs::write(&local_file, b"inflight").unwrap();
        std::fs::write(&mta_file, b"inflight").unwrap();
        // 升级前旧协议子目录（local-send）中的残留，新版本不再写入。
        let legacy_dir = dir
            .join(temp_workspace::TEMP_DIR_NAME)
            .join(temp_workspace::LEGACY_TEMP_SUBDIRS[0]);
        std::fs::create_dir_all(&legacy_dir).unwrap();
        let legacy_file = legacy_dir.join("old.txt");
        std::fs::write(&legacy_file, b"old").unwrap();

        let mut store = UploadStore::default();
        let (mut current, _rx) = pending_session("up-cross-protocol");
        current
            .files
            .insert("f1".to_string(), upload_file("f1", &final_path));
        store.insert_pending(current);

        assert_eq!(
            store.set_targets("up-cross-protocol", &[("f1".to_string(), final_path)]),
            1
        );
        assert!(!orphan.exists(), "网页协议自身的遗留半成品应被清理");
        assert!(local_file.exists(), "LocalSend 正在写入的临时文件不能删");
        assert!(mta_file.exists(), "MTA 正在写入的临时文件不能删");
        assert!(!legacy_file.exists(), "旧版协议子目录的残留应被清理");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_sweep_pending_upload_timeout() {
        let mut store = UploadStore {
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
