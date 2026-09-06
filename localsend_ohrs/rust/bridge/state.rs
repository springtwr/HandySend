//! 桥接层业务状态（纯数据）。
//!
//! 关键设计：
//! - 不持有 `runtime`——runtime 由 NAPI 层 NapiEnv 管理
//! - 事件经 `event_tx`（mpsc channel）输出
//! - `server_event_task` / `web_send_event_task` 存储事件循环 task 的
//!   JoinHandle，`stop_server` 时 abort
//! - `initialized` 标志判断首次初始化
//!
//! `BridgeState` 本身不依赖 NAPI——可在测试中直接构造。

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use localsend::discovery::DiscoveryHandle;
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::PrepareUploadDecisionV2;
use localsend::http::server::web::WebSendEvent;
use localsend::http::server::ServerHandle;
use localsend::model::discovery::DeviceType;
use localsend::model::transfer::FileContent;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;

use crate::bridge::event::BridgeEvent;

/// 待处理的传输请求（PrepareUpload 决策等待用户响应）。
#[derive(Clone, Debug)]
pub struct PendingRequest {
    pub session_id: String,
    pub sender_alias: String,
    pub sender_fingerprint: String,
    pub sender_protocol: String,
    pub files: Vec<PendingFile>,
}

/// 待处理请求中的单个文件。
#[derive(Clone, Debug)]
pub struct PendingFile {
    pub file_id: String,
    pub file_name: String,
    pub size: u64,
    pub file_type: String,
    pub preview: Option<String>,
    pub sha256: Option<String>,
}

/// Web 分享链接状态。
#[derive(Clone, Debug, Default)]
pub struct ShareLinkState {
    pub url: String,
    pub port: u16,
    pub session_id: String,
}

/// 接收文件预注册的写入目标（ArkTS 侧直写最终位置时使用）。
///
/// - `fd`：ArkTS 已打开的目标文件写描述符；交由 Rust 消费（写入完成后关闭）。
/// - `path`：目标文件真实路径（供 ArkTS 记账/历史记录，Rust 不执行路径语义）。
#[derive(Clone, Debug)]
pub struct RecvTargetFd {
    pub fd: i32,
    pub path: String,
}

/// Web 分享文件的存储内容源。
///
/// - `path`：源定位（picker URI 或沙箱路径），保留用于日志/回退。
/// - `fd`：已打开的内容读描述符（fd-direct 场景）；被下载消费一次后置 None。
#[derive(Clone, Debug)]
pub struct WebSendFile {
    pub path: String,
    pub fd: Option<i32>,
}

// ── 桥接状态 ─────────────────────────────────────────────────────────────

pub struct BridgeState {
    // ── 身份（纯数据）──
    /// 首次初始化标志（用 initialized 判断而非 runtime.is_none()）。
    pub initialized: bool,
    pub local_alias: String,
    pub device_type: DeviceType,
    pub device_model: String,
    pub fingerprint: String,
    pub cert_pem: String,
    pub key_pem: String,

    // ── 服务器 ──
    pub server_handle: Option<ServerHandle>,
    pub server_stop_tx: Option<oneshot::Sender<()>>,
    /// 服务器事件循环 task 的 JoinHandle（stop 时 abort）。
    pub server_event_task: Option<JoinHandle<()>>,
    pub local_port: u16,
    pub use_https: bool,
    pub verify_checksums: bool,
    pub receive_pin: Option<String>,
    pub show_token: Option<String>,

    // ── 发现 ──
    pub discovery_handle: Option<Arc<DiscoveryHandle>>,
    pub discovery_stop_tx: Option<oneshot::Sender<()>>,
    pub discovery_event_task: Option<JoinHandle<()>>,

    // ── 事件输出 ──
    /// 唯一事件出口：桥接层函数通过参数注入 event_tx，
    /// 消费者（NAPI / 测试）持有 receiver 端。
    pub event_tx: Option<tokio::sync::mpsc::Sender<BridgeEvent>>,

    // ── 传输决策 ──
    /// 待决策的 PrepareUpload 会话：session_id → oneshot 发送端。
    pub pending_decisions: HashMap<String, oneshot::Sender<PrepareUploadDecisionV2>>,
    /// 进行中的传输取消令牌（发送侧与接收侧共用）。
    pub active_transfers: HashMap<String, tokio_util::sync::CancellationToken>,
    /// 以 UUID id 为键的取消令牌，用于对哈希/上传操作进行细粒度取消。
    pub cancel_tokens: HashMap<String, tokio_util::sync::CancellationToken>,
    pub pending_requests: Arc<Mutex<Vec<PendingRequest>>>,
    /// 会话对端信息：(ip, port, protocol)，用于接收方取消时向发送方发 /cancel。
    pub session_peers: HashMap<String, (String, u16, localsend::model::discovery::ProtocolType)>,

    // ── WebSend ──
    /// WebSend 事件通道发送端（Web 发送模式激活时设置）。
    pub web_send_event_tx: Option<tokio::sync::mpsc::Sender<WebSendEvent>>,
    /// Web 发送文件 ID → 内容源（路径 + 可选 fd，供 FileDownload 内容查找）。
    pub web_send_files: Arc<Mutex<HashMap<String, WebSendFile>>>,
    /// 待处理的 Web 下载决策：session_id → oneshot 发送端（true=接受，false=拒绝）。
    pub web_download_decisions: HashMap<String, oneshot::Sender<bool>>,
    /// 待处理的文件上传目标：(session_id, file_id) → oneshot 发送端。
    pub pending_file_uploads: HashMap<(String, String), oneshot::Sender<FileUploadTarget>>,
    /// 接收文件预注册的直写目标：(session_id, file_id) → fd 与真实路径。
    /// ArkTS 在 respondTransfer 前逐文件注册；handle_file_upload 消费（取出即移除）。
    pub recv_target_fds: HashMap<(String, String), RecvTargetFd>,
    /// 待处理的文件下载内容：(session_id, file_id) → oneshot 发送端。
    pub pending_file_downloads: HashMap<(String, String), oneshot::Sender<FileContent>>,
    /// WebSend 事件循环 task 的 JoinHandle（stop 时 abort）。
    pub web_send_event_task: Option<JoinHandle<()>>,

    // ── 其他 ──
    pub current_send_session_id: Arc<Mutex<String>>,
    pub debug_log: Arc<Mutex<Vec<String>>>,
    pub share_link_info: Arc<Mutex<Option<ShareLinkState>>>,
    pub recv_diag_drain_count: Arc<Mutex<u64>>,
    pub save_dir: String,
}

impl BridgeState {
    pub fn new() -> Self {
        Self {
            initialized: false,
            local_alias: String::from("HarmonyOS"),
            device_type: DeviceType::Mobile,
            device_model: String::from("HarmonyOS"),
            fingerprint: String::new(),
            cert_pem: String::new(),
            key_pem: String::new(),
            server_handle: None,
            server_stop_tx: None,
            server_event_task: None,
            local_port: 53317,
            use_https: true,
            verify_checksums: true,
            receive_pin: None,
            show_token: None,
            discovery_handle: None,
            discovery_stop_tx: None,
            discovery_event_task: None,
            event_tx: None,
            pending_decisions: HashMap::new(),
            active_transfers: HashMap::new(),
            cancel_tokens: HashMap::new(),
            pending_requests: Arc::new(Mutex::new(Vec::new())),
            session_peers: HashMap::new(),
            web_send_event_tx: None,
            web_send_files: Arc::new(Mutex::new(HashMap::new())),
            web_download_decisions: HashMap::new(),
            pending_file_uploads: HashMap::new(),
            recv_target_fds: HashMap::new(),
            pending_file_downloads: HashMap::new(),
            web_send_event_task: None,
            current_send_session_id: Arc::new(Mutex::new(String::new())),
            debug_log: Arc::new(Mutex::new(Vec::new())),
            share_link_info: Arc::new(Mutex::new(None)),
            recv_diag_drain_count: Arc::new(Mutex::new(0)),
            save_dir: String::new(),
        }
    }
}

impl Default for BridgeState {
    fn default() -> Self {
        Self::new()
    }
}

// ── 全局单例 ─────────────────────────────────────────────────────────

static BRIDGE: OnceLock<Arc<Mutex<BridgeState>>> = OnceLock::new();

/// 全局单例——NAPI 生产环境使用。
/// 返回 `&'static Arc<Mutex<BridgeState>>`，调用方可用
/// `Arc::clone(bridge())` 获得 `'static` Arc 传给 spawned task。
/// 测试不依赖此单例，直接构造自己的 `BridgeState`。
pub fn bridge() -> &'static Arc<Mutex<BridgeState>> {
    BRIDGE.get_or_init(|| Arc::new(Mutex::new(BridgeState::new())))
}
