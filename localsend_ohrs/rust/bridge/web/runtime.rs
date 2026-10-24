//! 自研 web 服务运行时（生命周期归属桥接层，NAPI 只做薄封装）。
//!
//! - 全局单例（`OnceLock`）：服务状态 + 服务任务 + 转发任务句柄；
//! - `start` 按配置建表并起服（0.0.0.0:0 动态端口，与 LocalSend
//!   服务端口独立），`stop` 幂等收尾；
//! - 转发任务把 `ProgressEvent` 译为 `BridgeEvent` 经统一事件通道
//!   推送（下载复用既有 `WebSend*` 变体，`sessionId` 即 token；
//!   上传用新增 `WebUpload*` 变体）。

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::mpsc;

use crate::bridge::event::{send_event, BridgeEvent};
use crate::bridge::lock;
use crate::bridge::server::clone_event_tx;
use crate::bridge::state::bridge;
use crate::bridge::web::caps::ShareState;
use crate::bridge::web::server::{ProgressEvent, WebServiceState};
use crate::bridge::web::session::{FileSource, SharedFile, SharedFileTable};
use crate::bridge::web::upload::UploadStore;

/// 服务配置（ArkTS 传 JSON，由调用方按 camelCase 组装）。
#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebServiceConfig {
    /// 本机别名（文件表响应携带，供浏览器页展示）。
    #[serde(default)]
    pub alias: String,
    /// 浏览器需携带的 PIN（`None` 表示免 PIN）。
    #[serde(default)]
    pub pin: Option<String>,
    /// 浏览器上传入口是否开放。
    #[serde(default)]
    pub upload_enabled: bool,
    /// 是否使用自签证书 HTTPS（跟随全局加密开关）。
    #[serde(default)]
    pub use_https: bool,
    /// 上传落盘目录（生产由 ArkTS 传入接收目录）。
    #[serde(default)]
    pub upload_dir: String,
    /// 挂载的分享文件。
    #[serde(default)]
    pub files: Vec<WebServiceFile>,
}

/// 单个挂载文件（字段名与旧 `NativeFileToSend` 对齐，便于 ArkTS 复用）。
#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebServiceFile {
    /// 对外文件标识。
    #[serde(default)]
    pub file_id: String,
    /// 文件名。
    #[serde(default)]
    pub file_name: String,
    /// MIME 类型。
    #[serde(default)]
    pub file_type: String,
    /// 字节数。
    #[serde(default)]
    pub size: u64,
    /// 读 fd（`>=0` 有效；ArkTS 持有原始句柄，Rust 只 dup 副本）。
    #[serde(default = "default_fd")]
    pub fd: i32,
    /// 文件路径（fd 无效时回退直读）。
    #[serde(default)]
    pub file_path: String,
    /// 文本预览（手动输入文本）。
    #[serde(default)]
    pub preview: Option<String>,
    /// 校验和（展示用）。
    #[serde(default)]
    pub sha256: Option<String>,
}

fn default_fd() -> i32 {
    -1
}

/// 运行时句柄（全局单例持有）。
struct WebRuntime {
    state: Option<Arc<WebServiceState>>,
    server_task: Option<tokio::task::JoinHandle<()>>,
    forward_task: Option<tokio::task::JoinHandle<()>>,
}

fn runtime() -> &'static Mutex<WebRuntime> {
    static RUNTIME: OnceLock<Mutex<WebRuntime>> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        Mutex::new(WebRuntime {
            state: None,
            server_task: None,
            forward_task: None,
        })
    })
}

/// 当前服务状态（无服务时 `None`）。
pub fn current_state() -> Option<Arc<WebServiceState>> {
    lock(runtime()).state.clone()
}

/// 启动自研 web 服务，返回实际绑定端口。
pub async fn start(config_json: &str) -> anyhow::Result<u16> {
    let config: WebServiceConfig = serde_json::from_str(config_json)
        .map_err(|e| anyhow::anyhow!("服务配置 JSON 解析失败: {e}"))?;
    let mut files: HashMap<String, SharedFile> = HashMap::new();
    for entry in config.files.iter() {
        if entry.file_id.is_empty() {
            continue;
        }
        let source = if entry.fd >= 0 {
            FileSource::Fd(entry.fd)
        } else if entry.file_path.is_empty() {
            continue;
        } else {
            FileSource::Path(entry.file_path.clone())
        };
        files.insert(
            entry.file_id.clone(),
            SharedFile {
                file: localsend::model::transfer::FileDto {
                    id: entry.file_id.clone(),
                    file_name: entry.file_name.clone(),
                    size: entry.size,
                    file_type: entry.file_type.clone(),
                    sha256: entry.sha256.clone(),
                    preview: entry.preview.clone(),
                    metadata: None,
                },
                source,
            },
        );
    }
    let mut table = SharedFileTable::empty();
    table.replace(files);
    let (progress_tx, progress_rx) = mpsc::channel::<ProgressEvent>(64);
    let state = Arc::new(WebServiceState {
        caps: Arc::new(Mutex::new(crate::bridge::web::caps::CapsSnapshot {
            has_download: !table.files.is_empty(),
            file_revision: table.revision,
            upload_enabled: config.upload_enabled,
            share_state: ShareState::Active,
            https_hint: config.use_https,
        })),
        alias: Arc::new(Mutex::new(config.alias)),
        share_id: Arc::new(Mutex::new(format!(
            "web_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis())
                .unwrap_or(0)
        ))),
        expected_pin: Arc::new(Mutex::new(config.pin)),
        files: Arc::new(Mutex::new(table)),
        retained: Arc::new(Mutex::new(HashMap::new())),
        sessions: Arc::new(Mutex::new(
            crate::bridge::web::session::SessionStore::default(),
        )),
        uploads: Arc::new(Mutex::new(UploadStore::default())),
        upload_dir: Arc::new(Mutex::new(std::path::PathBuf::from(config.upload_dir))),
        pin_attempts: Arc::new(Mutex::new(HashMap::new())),
        progress_tx: Some(progress_tx),
    });
    let listener = tokio::net::TcpListener::bind("0.0.0.0:0")
        .await
        .map_err(|e| anyhow::anyhow!("监听失败: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| anyhow::anyhow!("取端口失败: {e}"))?
        .port();
    stop_internal();
    let server_state = Arc::clone(&state);
    let server_task = tokio::spawn(async move {
        crate::bridge::web::server::run_server(listener, server_state).await;
    });
    let forward_state = Arc::clone(&state);
    let forward_task = tokio::spawn(async move {
        forward_events(forward_state, progress_rx).await;
    });
    let mut runtime = lock(runtime());
    runtime.state = Some(state);
    runtime.server_task = Some(server_task);
    runtime.forward_task = Some(forward_task);
    Ok(port)
}

/// 停止自研 web 服务（幂等）。
pub fn stop() {
    stop_internal();
}

fn stop_internal() {
    let mut runtime = lock(runtime());
    if let Some(task) = runtime.server_task.take() {
        task.abort();
    }
    if let Some(task) = runtime.forward_task.take() {
        task.abort();
    }
    runtime.state = None;
}

/// 就地替换分享文件表（版本号 +1；返回生效文件数）。
pub fn update_files(files_json: &str) -> anyhow::Result<u32> {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct FileEntry {
        #[serde(default)]
        file_id: String,
        #[serde(default)]
        file_name: String,
        #[serde(default)]
        file_type: String,
        #[serde(default)]
        size: u64,
        #[serde(default = "default_fd")]
        fd: i32,
        #[serde(default)]
        file_path: String,
        #[serde(default)]
        preview: Option<String>,
        #[serde(default)]
        sha256: Option<String>,
    }
    let entries: Vec<FileEntry> = serde_json::from_str(files_json)
        .map_err(|e| anyhow::anyhow!("文件 JSON 解析失败: {e}"))?;
    let mut files: HashMap<String, SharedFile> = HashMap::new();
    for entry in entries.iter() {
        if entry.file_id.is_empty() {
            continue;
        }
        let source = if entry.fd >= 0 {
            FileSource::Fd(entry.fd)
        } else if entry.file_path.is_empty() {
            continue;
        } else {
            FileSource::Path(entry.file_path.clone())
        };
        files.insert(
            entry.file_id.clone(),
            SharedFile {
                file: localsend::model::transfer::FileDto {
                    id: entry.file_id.clone(),
                    file_name: entry.file_name.clone(),
                    size: entry.size,
                    file_type: entry.file_type.clone(),
                    sha256: entry.sha256.clone(),
                    preview: entry.preview.clone(),
                    metadata: None,
                },
                source,
            },
        );
    }
    let state = current_state().ok_or_else(|| anyhow::anyhow!("网页服务未运行"))?;
    state.update_files(files);
    Ok(entries.len() as u32)
}

/// 设置浏览器上传入口开关。
pub fn set_upload_enabled(enabled: bool) -> anyhow::Result<()> {
    let state = current_state().ok_or_else(|| anyhow::anyhow!("网页服务未运行"))?;
    lock(&state.caps).upload_enabled = enabled;
    Ok(())
}

/// 接受待确认会话（下载/上传两侧都试）。
pub fn accept(token: &str) -> anyhow::Result<()> {
    let state = current_state().ok_or_else(|| anyhow::anyhow!("网页服务未运行"))?;
    let now = std::time::Instant::now();
    if lock(&state.sessions).accept(token, now).is_ok() {
        return Ok(());
    }
    lock(&state.uploads)
        .accept(token, now)
        .map_err(|_| anyhow::anyhow!("会话不存在或已过期: {token}"))?;
    Ok(())
}

/// 拒绝待确认会话（下载/上传两侧都试）。
pub fn decline(token: &str) -> anyhow::Result<()> {
    let state = current_state().ok_or_else(|| anyhow::anyhow!("网页服务未运行"))?;
    if lock(&state.sessions).decline(token) {
        return Ok(());
    }
    let removed = lock(&state.uploads).decline(token);
    match removed {
        Some(session) => {
            crate::bridge::web::server::remove_tmp_files(&session);
            Ok(())
        }
        None => Err(anyhow::anyhow!("会话不存在或已过期: {token}")),
    }
}

/// 令待确认会话过期（下载/上传两侧都试；浏览器收 408）。
pub fn expire(token: &str) -> anyhow::Result<()> {
    let state = current_state().ok_or_else(|| anyhow::anyhow!("网页服务未运行"))?;
    if lock(&state.sessions).expire(token) {
        return Ok(());
    }
    if lock(&state.uploads).expire(token) {
        return Ok(());
    }
    Err(anyhow::anyhow!("会话不存在或已过期: {token}"))
}

/// 设置浏览器上传的落盘目标（确认前调用；返回实际生效条目数）。
pub fn set_upload_targets(token: &str, targets_json: &str) -> anyhow::Result<u32> {
    #[derive(serde::Deserialize)]
    struct Target {
        #[serde(rename = "fileId", default)]
        file_id: String,
        #[serde(default)]
        path: String,
    }
    let targets: Vec<Target> = serde_json::from_str(targets_json)
        .map_err(|e| anyhow::anyhow!("落盘目标解析失败: {e}"))?;
    let state = current_state().ok_or_else(|| anyhow::anyhow!("网页服务未运行"))?;
    let pairs: Vec<(String, String)> = targets
        .into_iter()
        .map(|t| (t.file_id, t.path))
        .collect();
    let applied = lock(&state.uploads).set_targets(token, &pairs);
    Ok(applied as u32)
}

/// 触发全量惰性打扫（供 ArkTS 侧超时驱动调用）。
pub async fn sweep() -> anyhow::Result<()> {
    let state = current_state().ok_or_else(|| anyhow::anyhow!("网页服务未运行"))?;
    state.sweep_all(std::time::Instant::now()).await;
    Ok(())
}

/// 进度事件 → 桥接事件转发（下载复用既有 `WebSend*` 变体，
/// `sessionId` 即 token；上传用新增 `WebUpload*` 变体）。
async fn forward_events(
    state: Arc<WebServiceState>,
    mut progress_rx: mpsc::Receiver<ProgressEvent>,
) {
    let event_tx = clone_event_tx(bridge());
    while let Some(event) = progress_rx.recv().await {
        let bridge_event = match event {
            ProgressEvent::PrepareDownloadRequested {
                token,
                ip,
                user_agent,
                files: _,
            } => BridgeEvent::WebSendPrepareDownload {
                session_id: token,
                ip,
                user_agent,
            },
            ProgressEvent::PrepareUploadRequested {
                token,
                ip,
                user_agent,
                files,
            } => BridgeEvent::WebUploadPrepare {
                token,
                ip,
                user_agent,
                files,
            },
            ProgressEvent::Progress {
                token,
                file_id,
                sent_bytes,
                total_bytes,
            } => BridgeEvent::WebSendProgress {
                session_id: token,
                file_id,
                sent_bytes,
                total_bytes,
            },
            ProgressEvent::Done {
                token,
                file_id,
                total_bytes,
            } => BridgeEvent::WebSendProgress {
                session_id: token,
                file_id,
                sent_bytes: total_bytes,
                total_bytes,
            },
            ProgressEvent::UploadProgress {
                token,
                file_id,
                received_bytes,
                total_bytes,
            } => BridgeEvent::WebUploadProgress {
                token,
                file_id,
                received_bytes,
                total_bytes,
            },
            ProgressEvent::UploadDone {
                token,
                file_id,
                path,
            } => BridgeEvent::WebUploadDone {
                token,
                file_id,
                path,
            },
            ProgressEvent::Finished { token } => BridgeEvent::WebSendSessionEnd {
                session_id: token,
            },
        };
        send_event(&event_tx, bridge_event).await;
    }
}
