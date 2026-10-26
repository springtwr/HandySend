//! Token 会话与文件表（一浏览器一 token，多标签不互踢）。
//!
//! 取代旧按 IP 单槽：token 区分同 IP 的不同浏览器/标签页，
//! token 绑定创建时的对端 IP（换 IP 视为新客户端）。
//! 换表只影响新会话：建会话时冻结当时文件表快照，被删文件的
//! 内容源为活跃会话保留到宽限结束；快照 metadata 随会话走，
//! 服务端只按快照提供内容。
//!
//! 超时分三段（与 ArkTS 侧旧口径对齐）：待确认 60s、已授首包
//! 120s、传输中无数据 120s；只终结会话，不碰分享。线上用默认
//! 值，测试注入短值。

use std::collections::HashMap;
use std::time::{Duration, Instant};

use localsend::model::transfer::FileDto;
use tokio::sync::oneshot;

/// 会话状态：待确认（持有决策发送端）/ 已接受。
pub enum SessionState {
    /// 待确认：持有决策通道发送端；发送端被丢弃即 408。
    Pending {
        decision_tx: Option<oneshot::Sender<bool>>,
    },
    /// 已接受：可按快照下载。
    Accepted,
}

impl std::fmt::Debug for SessionState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Pending { .. } => write!(f, "Pending"),
            Self::Accepted => write!(f, "Accepted"),
        }
    }
}

/// 建会话时冻结的单文件快照（含当时元数据与内容源）。
#[derive(Clone, Debug)]
pub struct OfferedFile {
    /// 对外文件标识（换表时按路径复用，见 ArkTS 侧同名逻辑）。
    pub file_id: String,
    /// 建会话时冻结的文件表版本。
    pub file_revision: u64,
    /// 冻结时的文件元数据（文件名/大小/类型，后续换表不影响）。
    pub file: FileDto,
}

/// Token 会话。
#[derive(Debug)]
pub struct TokenSession {
    /// 浏览器 UUID（首访服务端下发，`sessionStorage` 复用）。
    pub token: String,
    /// 归属分享标识（`shareId` 外键，一分享多任务）。
    pub share_id: String,
    /// 创建时的对端 IP（换 IP 视为新客户端，需重新建会话）。
    pub peer_ip: String,
    /// 浏览器标识（诊断用）。
    pub user_agent: Option<String>,
    /// 建会话时刻。
    pub created_at: Instant,
    /// 最近文件活动时刻（首包/字节进度/完成回执刷新）。
    pub last_activity: Instant,
    /// 当前状态。
    pub state: SessionState,
    /// 是否已开始下载（首个文件请求到达后为真）。
    pub download_started: bool,
    /// 建会话时出示的文件快照。
    pub offered_files: HashMap<String, OfferedFile>,
    /// 建会话时冻结的文件表版本。
    pub file_revision: u64,
}

/// 可配置的超时（线上默认，测试注入短值）。
#[derive(Clone, Copy, Debug)]
pub struct SessionTimeouts {
    /// 待确认超时（默认 60s，先结束原生决策通道，浏览器收 408）。
    pub pending: Duration,
    /// 已授首包超时（默认 120s，对方始终没请求任何文件）。
    pub wait_first_file: Duration,
    /// 传输中无数据超时（默认 120s，已开始后又没了数据；页面心跳可续期）。
    pub idle: Duration,
}

impl Default for SessionTimeouts {
    fn default() -> Self {
        Self {
            pending: Duration::from_secs(60),
            wait_first_file: Duration::from_secs(120),
            idle: Duration::from_secs(120),
        }
    }
}

/// 文件内容源。
///
/// fd 所有权分两种：
/// - 共享文件表里的 fd 归 ArkTS 所有（分享期间长期有效），Rust 每次下载
///   先 `dup` 副本再消费；
/// - 被删文件保留区里的 fd 是 `update_files` 时 `dup` 出来的副本，
///   由 [`RetainedFile`] 的 `Drop` 负责关闭。
#[derive(Clone, Debug)]
pub enum FileSource {
    /// 读 fd（消费方负责关闭自己持有的副本）。
    Fd(i32),
    /// 文件路径（fd 不可用时回退直读）。
    Path(String),
}

impl FileSource {
    /// 复制一个可独立消费的内容源：fd 走 `dup`，路径直接克隆。
    /// fd 复制失败时返回 `None`（调用方按内容缺失处理，避免读错 fd）。
    pub fn duplicate(&self) -> Option<Self> {
        match self {
            Self::Fd(fd) => {
                let dup = unsafe { libc::dup(*fd) };
                if dup < 0 {
                    log::warn!(
                        "web 内容源 dup 失败 fd={fd}: {}",
                        std::io::Error::last_os_error()
                    );
                    None
                } else {
                    Some(Self::Fd(dup))
                }
            }
            Self::Path(path) => Some(Self::Path(path.clone())),
        }
    }

    /// 关闭本副本持有的 fd（仅 `Fd` 有效；`Path` 无操作）。
    pub fn close(&self) {
        if let Self::Fd(fd) = self {
            unsafe {
                libc::close(*fd);
            }
        }
    }
}

/// 共享文件表条目（共享表与快照共用）。
#[derive(Clone, Debug)]
pub struct SharedFile {
    /// 文件元数据。
    pub file: FileDto,
    /// 内容源。
    pub source: FileSource,
}

/// 共享文件表（`revision` 单调增；换表返回被删条目供保留）。
#[derive(Clone, Debug, Default)]
pub struct SharedFileTable {
    /// 当前版本（每次换表 +1，首版为 1）。
    pub revision: u64,
    /// 文件标识 → 条目。
    pub files: HashMap<String, SharedFile>,
}

impl SharedFileTable {
    /// 建空表（版本为 0，占位）。
    pub fn empty() -> Self {
        Self {
            revision: 0,
            files: HashMap::new(),
        }
    }

    /// 就地换表：版本号 +1，返回被删条目（调用方转入保留区）。
    pub fn replace(&mut self, next: HashMap<String, SharedFile>) -> Vec<SharedFile> {
        let mut removed: Vec<SharedFile> = Vec::new();
        for (id, old) in self.files.iter() {
            if !next.contains_key(id) {
                removed.push(old.clone());
            }
        }
        self.files = next;
        self.revision += 1;
        removed
    }
}

/// 被删文件的保留条目（供已建会话按快照下完，宽限后释放）。
///
/// `file.source` 若是 fd，则是换表时 `dup` 出来的私有副本：
/// 原 fd 在换表返回后会被 ArkTS 关闭，保留区必须自己持有副本，
/// 并在条目释放时关闭，避免读到已关闭或被复用的 fd。
#[derive(Debug)]
pub struct RetainedFile {
    /// 被删时的条目。
    pub file: SharedFile,
    /// 保留截止时刻（到期释放）。
    pub deadline: Instant,
}

impl Drop for RetainedFile {
    fn drop(&mut self) {
        self.file.source.close();
    }
}

/// 会话终结原因（供路由映射状态码与 ArkTS 侧终态）。
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionEndReason {
    /// 用户拒绝。
    Declined,
    /// 待确认超时（浏览器收 408）。
    PendingTimeout,
    /// 已授但对方始终未请求任何文件。
    PeerNoDownload,
    /// 传输中无数据。
    PeerIdle,
}

/// 会话存储（token → 会话；调用方持锁，见服务状态）。
#[derive(Debug, Default)]
pub struct SessionStore {
    /// 活跃会话表。
    pub sessions: HashMap<String, TokenSession>,
    /// 超时配置。
    pub timeouts: SessionTimeouts,
}

impl SessionStore {
    /// 登记待确认会话（token 由调用方经 UUID 生成）。
    pub fn insert_pending(&mut self, session: TokenSession) {
        self.sessions.insert(session.token.clone(), session);
    }

    /// 按 token 取会话（是否存在）。
    pub fn contains(&self, token: &str) -> bool {
        self.sessions.contains_key(token)
    }

    /// 接受：待确认会话转已接受并刷新活动时刻；
    /// 已接受会话重复接受视为幂等成功（只刷新时刻）。
    pub fn accept(&mut self, token: &str, now: Instant) -> Result<(), SessionEndReason> {
        let Some(session) = self.sessions.get_mut(token) else {
            return Err(SessionEndReason::PendingTimeout);
        };
        match &mut session.state {
            SessionState::Pending { decision_tx } => {
                if let Some(tx) = decision_tx.take() {
                    let _ = tx.send(true);
                }
                session.state = SessionState::Accepted;
                session.last_activity = now;
                Ok(())
            }
            SessionState::Accepted => {
                session.last_activity = now;
                Ok(())
            }
        }
    }

    /// 拒绝：发送拒绝并移除会话。
    pub fn decline(&mut self, token: &str) -> bool {
        let Some(mut session) = self.sessions.remove(token) else {
            return false;
        };
        if let SessionState::Pending { decision_tx } = &mut session.state {
            if let Some(tx) = decision_tx.take() {
                let _ = tx.send(false);
            }
        }
        true
    }

    /// 过期：移除会话并丢弃决策发送端（等待方收 408）。
    pub fn expire(&mut self, token: &str) -> bool {
        self.sessions.remove(token).is_some()
    }

    /// 刷新活动时刻（首包/字节进度/完成回执到达时调用）。
    pub fn touch(&mut self, token: &str, now: Instant) {
        if let Some(session) = self.sessions.get_mut(token) {
            session.last_activity = now;
        }
    }

    /// 标记已开始下载（首个文件请求到达时调用；传输中空闲仍由
    /// 字节进度侧判定，此处只区分“从未开始”与“已开始”）。
    pub fn mark_download_started(&mut self, token: &str) {
        if let Some(session) = self.sessions.get_mut(token) {
            session.download_started = true;
        }
    }

    /// 终结超时会话并返回（token，原因）：
    /// 待确认超 `pending`，已接受且从未开始下载超 `wait_first_file`。
    /// 传输中空闲（已开始后又超时）由字节进度侧判定，此处不收。
    /// 移除即丢弃待确认决策发送端，等待方收 408。
    pub fn sweep(&mut self, now: Instant) -> Vec<(String, SessionEndReason)> {
        let mut ended: Vec<(String, SessionEndReason)> = Vec::new();
        let timeouts = self.timeouts;
        let expired: Vec<(String, SessionEndReason)> = self
            .sessions
            .iter()
            .filter_map(|(token, session)| {
                let reason = match &session.state {
                    SessionState::Pending { .. }
                        if now.duration_since(session.created_at) >= timeouts.pending =>
                    {
                        Some(SessionEndReason::PendingTimeout)
                    }
                    SessionState::Accepted
                        if !session.download_started
                            && now.duration_since(session.last_activity)
                                >= timeouts.wait_first_file =>
                    {
                        Some(SessionEndReason::PeerNoDownload)
                    }
                    // 已开始下载后长时间没有请求/字节活动：清理服务端会话。
                    // 页面打开期间由 heartbeat 续期，下载过程中由字节进度续期。
                    SessionState::Accepted
                        if session.download_started
                            && now.duration_since(session.last_activity) >= timeouts.idle =>
                    {
                        Some(SessionEndReason::PeerIdle)
                    }
                    _ => None,
                };
                reason.map(|reason| (token.clone(), reason))
            })
            .collect();
        for (token, reason) in expired {
            self.sessions.remove(&token);
            ended.push((token, reason));
        }
        ended
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file_dto(id: &str) -> FileDto {
        FileDto {
            id: id.to_string(),
            file_name: format!("{id}.txt"),
            size: 10,
            file_type: "text/plain".to_string(),
            sha256: None,
            preview: None,
            metadata: None,
        }
    }

    fn pending_session(token: &str) -> (TokenSession, oneshot::Receiver<bool>) {
        let (tx, rx) = oneshot::channel();
        let now = Instant::now();
        let session = TokenSession {
            token: token.to_string(),
            share_id: "share-1".to_string(),
            peer_ip: "192.168.1.2".to_string(),
            user_agent: None,
            created_at: now,
            last_activity: now,
            state: SessionState::Pending {
                decision_tx: Some(tx),
            },
            download_started: false,
            offered_files: HashMap::new(),
            file_revision: 1,
        };
        (session, rx)
    }

    #[test]
    fn test_accept_pending_session_notifies_true() {
        let mut store = SessionStore::default();
        let (session, mut rx) = pending_session("tok-1");
        store.insert_pending(session);
        store.accept("tok-1", Instant::now()).unwrap();
        assert_eq!(rx.try_recv().unwrap(), true);
        assert!(matches!(
            store.sessions["tok-1"].state,
            SessionState::Accepted
        ));
    }

    #[test]
    fn test_decline_pending_session_notifies_false_and_removes() {
        let mut store = SessionStore::default();
        let (session, mut rx) = pending_session("tok-2");
        store.insert_pending(session);
        assert!(store.decline("tok-2"));
        assert_eq!(rx.try_recv().unwrap(), false);
        assert!(!store.contains("tok-2"));
    }

    #[test]
    fn test_expire_drops_decision_sender() {
        let mut store = SessionStore::default();
        let (session, mut rx) = pending_session("tok-3");
        store.insert_pending(session);
        assert!(store.expire("tok-3"));
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn test_sweep_pending_timeout() {
        let mut store = SessionStore {
            timeouts: SessionTimeouts {
                pending: Duration::from_millis(10),
                ..Default::default()
            },
            ..Default::default()
        };
        let (session, _rx) = pending_session("tok-4");
        store.insert_pending(session);
        std::thread::sleep(Duration::from_millis(20));
        let ended = store.sweep(Instant::now());
        assert_eq!(
            ended,
            vec![("tok-4".to_string(), SessionEndReason::PendingTimeout)]
        );
        assert!(!store.contains("tok-4"));
    }

    #[test]
    fn test_sweep_peer_no_download_only_without_activity() {
        let mut store = SessionStore {
            timeouts: SessionTimeouts {
                wait_first_file: Duration::from_millis(10),
                ..Default::default()
            },
            ..Default::default()
        };
        let (mut session, _rx) = pending_session("tok-5");
        session.state = SessionState::Accepted;
        session.last_activity = Instant::now();
        session.download_started = true;
        store.insert_pending(session);
        // 有持续活动（heartbeat/字节进度）的不收
        let ended = store.sweep(Instant::now());
        assert!(ended.is_empty());
        // 已开始下载但长时间无活动：按传输空闲收尾
        store.sessions.get_mut("tok-5").unwrap().last_activity =
            Instant::now() - Duration::from_secs(3600);
        let ended = store.sweep(Instant::now());
        assert_eq!(
            ended,
            vec![("tok-5".to_string(), SessionEndReason::PeerIdle)]
        );
        // 从未开始下载且长时间无活动：按对方未下载收尾
        let (mut session, _rx) = pending_session("tok-6");
        session.state = SessionState::Accepted;
        session.last_activity = Instant::now() - Duration::from_secs(3600);
        session.download_started = false;
        store.insert_pending(session);
        let ended = store.sweep(Instant::now());
        assert_eq!(
            ended,
            vec![("tok-6".to_string(), SessionEndReason::PeerNoDownload)]
        );
    }

    #[test]
    fn test_table_replace_returns_removed_and_bumps_revision() {
        let mut table = SharedFileTable::empty();
        let mut first: HashMap<String, SharedFile> = HashMap::new();
        first.insert(
            "a".to_string(),
            SharedFile {
                file: file_dto("a"),
                source: FileSource::Path("/tmp/a".to_string()),
            },
        );
        first.insert(
            "b".to_string(),
            SharedFile {
                file: file_dto("b"),
                source: FileSource::Path("/tmp/b".to_string()),
            },
        );
        assert!(table.replace(first).is_empty());
        assert_eq!(table.revision, 1);
        let mut second: HashMap<String, SharedFile> = HashMap::new();
        second.insert(
            "b".to_string(),
            SharedFile {
                file: file_dto("b"),
                source: FileSource::Path("/tmp/b".to_string()),
            },
        );
        let removed = table.replace(second);
        assert_eq!(table.revision, 2);
        assert_eq!(removed.len(), 1);
        assert_eq!(removed[0].file.id, "a");
    }
}
