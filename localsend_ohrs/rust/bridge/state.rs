//! 保存所有 LocalSend 运行时句柄的桥接状态。
//!
//! 通过 `std::sync::OnceLock` 作为全局单例管理，以便所有
//! NAPI 入口点共享同一状态。

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use localsend::http::server::v2::PrepareUploadDecisionV2;
use localsend::http::server::ServerHandle;
use localsend::http::server::web::WebSendEvent;
use localsend::discovery::DiscoveryHandle;
use localsend::model::discovery::DeviceType;
use localsend::model::transfer::FileContent;
use localsend::http::server::common::save::FileUploadTarget;

use crate::bridge::callback::EventCallback;

#[derive(Clone, Debug)]
pub struct ProgressEntry {
    pub session_id: String,
    pub file_id: String,
    pub bytes_sent: u64,
    pub total_bytes: u64,
    pub file_path: String,
}

#[derive(Clone, Debug)]
pub struct PendingRequest {
    pub session_id: String,
    pub sender_alias: String,
    pub sender_fingerprint: String,
    pub sender_protocol: String,
    pub files: Vec<PendingFile>,
}

#[derive(Clone, Debug)]
pub struct PendingFile {
    pub file_id: String,
    pub file_name: String,
    pub size: u64,
    pub file_type: String,
    pub preview: Option<String>,
    pub sha256: Option<String>,
}

#[derive(Clone, Debug, Default)]
pub struct ShareLinkState {
    pub url: String,
    pub port: u16,
    pub session_id: String,
}

// ── 桥接状态 ─────────────────────────────────────────────────────────────

pub struct BridgeState {
    pub runtime: Option<tokio::runtime::Runtime>,

    pub server_handle: Option<ServerHandle>,
    pub server_stop_tx: Option<tokio::sync::oneshot::Sender<()>>,

    pub discovery_handle: Option<Arc<DiscoveryHandle>>,

    pub discovery_stop_tx: Option<tokio::sync::oneshot::Sender<()>>,

    pub discovery_event_task: Option<tokio::task::JoinHandle<()>>,

    pub event_tx: Option<tokio::sync::mpsc::Sender<localsend::http::server::v2::ServerEventV2>>,

    pub callback: Option<EventCallback>,

    pub local_alias: String,
    pub device_type: DeviceType,
    pub device_model: String,

    pub cert_pem: String,
    pub key_pem: String,
    pub fingerprint: String,

    pub local_port: u16,
    pub use_https: bool,

    pub active_transfers: HashMap<String, tokio_util::sync::CancellationToken>,

    /// 以 UUID id 为键的取消令牌，用于对哈希/上传操作进行细粒度取消。
    pub cancel_tokens: HashMap<String, tokio_util::sync::CancellationToken>,

    pub pending_decisions: HashMap<String, tokio::sync::oneshot::Sender<PrepareUploadDecisionV2>>,

    pub send_progress: Arc<Mutex<HashMap<String, ProgressEntry>>>,

    pub recv_progress: Arc<Mutex<HashMap<String, ProgressEntry>>>,

    pub current_send_session_id: Arc<Mutex<String>>,

    pub pending_requests: Arc<Mutex<Vec<PendingRequest>>>,

    pub debug_log: Arc<Mutex<Vec<String>>>,

    pub share_link_info: Arc<Mutex<Option<ShareLinkState>>>,

    /// WebSend 事件通道发送端（Web 发送模式激活时设置）
    pub web_send_event_tx: Option<tokio::sync::mpsc::Sender<WebSendEvent>>,

    /// Web 发送文件 ID → 文件路径映射（供 FileDownload 内容查找）
    pub web_send_files: Arc<Mutex<HashMap<String, String>>>,

    /// 待处理的 Web 下载决策：session_id → oneshot 发送端（true=接受，false=拒绝）
    pub web_download_decisions: HashMap<String, tokio::sync::oneshot::Sender<bool>>,

    /// 待处理的文件上传目标：(session_id, file_id) → oneshot 发送端
    /// 存储起来，使 fail_file_upload 可以丢弃发送端（导致 500 响应）
    pub pending_file_uploads: HashMap<(String, String), tokio::sync::oneshot::Sender<FileUploadTarget>>,

    /// 待处理的文件下载内容：(session_id, file_id) → oneshot 发送端
    /// 存储起来，使 fail_file_download 可以丢弃发送端（导致 500 响应）
    pub pending_file_downloads: HashMap<(String, String), tokio::sync::oneshot::Sender<FileContent>>,

    /// 当前接收 PIN（由 start_server 设置，供 create_share_link/start_web_upload 使用）
    pub receive_pin: Option<String>,

    /// 内部 show 端点的令牌（服务器启动时设置）
    pub show_token: Option<String>,

    pub recv_diag_drain_count: Arc<Mutex<u64>>,

    pub save_dir: String,

    /// 本设备是否支持 Download API（通过发现广播）。
    pub download: bool,
}

impl BridgeState {
    pub fn new() -> Self {
        Self {
            runtime: None,
            server_handle: None,
            server_stop_tx: None,
            discovery_handle: None,
            discovery_stop_tx: None,
            discovery_event_task: None,
            event_tx: None,
            callback: None,
            local_alias: String::from("HarmonyOS"),
            device_type: DeviceType::Mobile,
            device_model: String::from("HarmonyOS"),
            cert_pem: String::new(),
            key_pem: String::new(),
            fingerprint: String::new(),
            local_port: 53317,
            use_https: true,
            active_transfers: HashMap::new(),
            cancel_tokens: HashMap::new(),
            pending_decisions: HashMap::new(),
            send_progress: Arc::new(Mutex::new(HashMap::new())),
            recv_progress: Arc::new(Mutex::new(HashMap::new())),
            current_send_session_id: Arc::new(Mutex::new(String::new())),
            pending_requests: Arc::new(Mutex::new(Vec::new())),
            debug_log: Arc::new(Mutex::new(Vec::new())),
            share_link_info: Arc::new(Mutex::new(None)),
            web_send_event_tx: None,
            web_send_files: Arc::new(Mutex::new(HashMap::new())),
            web_download_decisions: HashMap::new(),
            pending_file_uploads: HashMap::new(),
            pending_file_downloads: HashMap::new(),
            receive_pin: None,
            show_token: None,
            recv_diag_drain_count: Arc::new(Mutex::new(0)),
            save_dir: String::from("/data/local/tmp/localsend/"),
            download: true,
        }
    }
}

// ── 全局单例 ─────────────────────────────────────────────────────────

static BRIDGE: OnceLock<Mutex<BridgeState>> = OnceLock::new();

pub fn bridge() -> &'static Mutex<BridgeState> {
    BRIDGE.get_or_init(|| Mutex::new(BridgeState::new()))
}
