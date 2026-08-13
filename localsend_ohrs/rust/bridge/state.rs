//! Bridge state holding all LocalSend runtime handles.
//!
//! Managed as a global singleton via `std::sync::OnceLock` so that all
//! NAPI entry points share the same state.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use localsend::http::server::v2::PrepareUploadDecisionV2;
use localsend::http::server::ServerHandle;
use localsend::discovery::DiscoveryHandle;
use localsend::model::discovery::DeviceType;

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

// ── Bridge State ─────────────────────────────────────────────────────────────

pub struct BridgeState {
    pub runtime: Option<tokio::runtime::Runtime>,

    pub server_handle: Option<ServerHandle>,
    pub server_stop_tx: Option<tokio::sync::oneshot::Sender<()>>,

    pub discovery_handle: Option<Arc<DiscoveryHandle>>,

    pub discovery_stop_tx: Option<tokio::sync::oneshot::Sender<()>>,

    pub event_tx: Option<tokio::sync::mpsc::Sender<localsend::http::server::v2::ServerEventV2>>,

    pub callback: Option<EventCallback>,

    pub local_alias: String,
    pub device_type: DeviceType,

    pub cert_pem: String,
    pub key_pem: String,
    pub fingerprint: String,

    pub local_port: u16,
    pub use_https: bool,

    pub active_transfers: HashMap<String, tokio_util::sync::CancellationToken>,

    pub pending_decisions: HashMap<String, tokio::sync::oneshot::Sender<PrepareUploadDecisionV2>>,

    pub send_progress: Arc<Mutex<HashMap<String, ProgressEntry>>>,

    pub recv_progress: Arc<Mutex<HashMap<String, ProgressEntry>>>,

    pub current_send_session_id: Arc<Mutex<String>>,

    pub pending_requests: Arc<Mutex<Vec<PendingRequest>>>,

    pub debug_log: Arc<Mutex<Vec<String>>>,

    pub share_link_info: Arc<Mutex<Option<ShareLinkState>>>,

    pub recv_diag_drain_count: Arc<Mutex<u64>>,

    pub save_dir: String,
}

impl BridgeState {
    pub fn new() -> Self {
        Self {
            runtime: None,
            server_handle: None,
            server_stop_tx: None,
            discovery_handle: None,
            discovery_stop_tx: None,
            event_tx: None,
            callback: None,
            local_alias: String::from("HarmonyOS"),
            device_type: DeviceType::Mobile,
            cert_pem: String::new(),
            key_pem: String::new(),
            fingerprint: String::new(),
            local_port: 53317,
            use_https: true,
            active_transfers: HashMap::new(),
            pending_decisions: HashMap::new(),
            send_progress: Arc::new(Mutex::new(HashMap::new())),
            recv_progress: Arc::new(Mutex::new(HashMap::new())),
            current_send_session_id: Arc::new(Mutex::new(String::new())),
            pending_requests: Arc::new(Mutex::new(Vec::new())),
            debug_log: Arc::new(Mutex::new(Vec::new())),
            share_link_info: Arc::new(Mutex::new(None)),
            recv_diag_drain_count: Arc::new(Mutex::new(0)),
            save_dir: String::from("/data/local/tmp/localsend/"),
        }
    }
}

// ── Global singleton ─────────────────────────────────────────────────────────

static BRIDGE: OnceLock<Mutex<BridgeState>> = OnceLock::new();

pub fn bridge() -> &'static Mutex<BridgeState> {
    BRIDGE.get_or_init(|| Mutex::new(BridgeState::new()))
}
