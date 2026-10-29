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

/// 下载 token 会话：只作为授权与文件快照缓存，不参与应用任务生命周期。
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
    /// 最近使用时刻（仅用于 LRU 淘汰）。
    pub last_used: Instant,
    /// 建会话时出示的文件快照。
    pub offered_files: HashMap<String, OfferedFile>,
    /// 建会话时的展示顺序（与 ArkTS 暂存列表一致）。
    pub offer_order: Vec<String>,
    /// 建会话时冻结的文件表版本。
    pub file_revision: u64,
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
    /// 源文件修改时间（Unix 毫秒；供 ZIP 条目时间还原）。
    pub last_modified_ms: Option<u64>,
}

/// 可配置的上传超时（线上默认，测试注入短值）。
///
/// 下载会话已改为绝对 TTL，不再使用这套活动超时；类型保留给上传复用。
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
    /// 源文件修改时间（Unix 毫秒；缺省时写入当前本地时间）。
    pub last_modified_ms: Option<u64>,
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

/// 下载会话存储：token → 快照缓存。
///
/// 下载不再有“待确认/已接受”状态，也没有活动超时；会话只有绝对 TTL，
/// 页面在每次下载前重新 prepare，TTL 到期后自然换新 token。
#[derive(Debug)]
pub struct SessionStore {
    /// 活跃会话表。
    pub sessions: HashMap<String, TokenSession>,
    /// 绝对 TTL（不随活动滑动）。
    pub ttl: Duration,
    /// 最大会话数，超出按 `last_used` 淘汰。
    pub max_sessions: usize,
}

impl Default for SessionStore {
    fn default() -> Self {
        Self {
            sessions: HashMap::new(),
            ttl: Duration::from_secs(2 * 60 * 60),
            max_sessions: 32,
        }
    }
}

impl SessionStore {
    /// 插入/替换会话；超出上限时淘汰最久未用会话。
    pub fn insert(&mut self, session: TokenSession) {
        self.sessions.insert(session.token.clone(), session);
        while self.sessions.len() > self.max_sessions {
            let Some(oldest) = self
                .sessions
                .values()
                .min_by_key(|item| item.last_used)
                .map(|item| item.token.clone())
            else {
                break;
            };
            self.sessions.remove(&oldest);
        }
    }

    /// 按 token 取会话。
    pub fn get(&self, token: &str) -> Option<&TokenSession> {
        self.sessions.get(token)
    }

    /// 按 token 取可变会话。
    pub fn get_mut(&mut self, token: &str) -> Option<&mut TokenSession> {
        self.sessions.get_mut(token)
    }

    /// 是否存在会话。
    pub fn contains(&self, token: &str) -> bool {
        self.sessions.contains_key(token)
    }

    /// 移除会话。
    pub fn remove(&mut self, token: &str) -> Option<TokenSession> {
        self.sessions.remove(token)
    }

    /// 刷新最近使用时刻（仅用于 LRU）。
    pub fn touch(&mut self, token: &str, now: Instant) {
        if let Some(session) = self.sessions.get_mut(token) {
            session.last_used = now;
        }
    }

    /// 清理过期会话；返回被移除的 token（仅诊断/日志，不发应用事件）。
    pub fn cleanup(&mut self, now: Instant) -> Vec<String> {
        let ttl = self.ttl;
        let expired: Vec<String> = self
            .sessions
            .iter()
            .filter(|(_, session)| now.duration_since(session.created_at) >= ttl)
            .map(|(token, _)| token.clone())
            .collect();
        for token in &expired {
            self.sessions.remove(token);
        }
        expired
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

    fn session(token: &str, now: Instant) -> TokenSession {
        TokenSession {
            token: token.to_string(),
            share_id: "share-1".to_string(),
            peer_ip: "192.168.1.2".to_string(),
            user_agent: None,
            created_at: now,
            last_used: now,
            offered_files: HashMap::new(),
            offer_order: Vec::new(),
            file_revision: 1,
        }
    }

    #[test]
    fn test_session_ttl_cleanup() {
        let now = Instant::now();
        let mut store = SessionStore {
            ttl: Duration::from_millis(10),
            ..Default::default()
        };
        store.insert(session("tok-1", now));
        assert!(store.contains("tok-1"));
        std::thread::sleep(Duration::from_millis(20));
        let removed = store.cleanup(Instant::now());
        assert_eq!(removed, vec!["tok-1".to_string()]);
        assert!(!store.contains("tok-1"));
    }

    #[test]
    fn test_session_lru_eviction() {
        let now = Instant::now();
        let mut store = SessionStore {
            max_sessions: 2,
            ..Default::default()
        };
        store.insert(session("old", now));
        store.insert(session("new", now + Duration::from_secs(1)));
        store.touch("old", now + Duration::from_secs(2));
        store.insert(session("newest", now + Duration::from_secs(3)));
        assert!(store.contains("old"));
        assert!(!store.contains("new"));
        assert!(store.contains("newest"));
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
                last_modified_ms: None,
            },
        );
        first.insert(
            "b".to_string(),
            SharedFile {
                file: file_dto("b"),
                source: FileSource::Path("/tmp/b".to_string()),
                last_modified_ms: None,
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
                last_modified_ms: None,
            },
        );
        let removed = table.replace(second);
        assert_eq!(table.revision, 2);
        assert_eq!(removed.len(), 1);
        assert_eq!(removed[0].file.id, "a");
    }
}
