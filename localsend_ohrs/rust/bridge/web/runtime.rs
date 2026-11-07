//! 自研 web 服务运行时（生命周期归属桥接层，NAPI 只做薄封装）。
//!
//! - 全局单例（`OnceLock`）：服务状态 + 服务任务 + 转发任务句柄；
//! - `start` 按配置建表并起服（0.0.0.0 监听全部网卡，优先配置端口、
//!   被占用时回退随机端口，与 LocalSend 服务端口独立），`stop` 幂等收尾；
//! - 转发任务把 `ProgressEvent` 译为 `BridgeEvent` 经统一事件通道
//!   推送（下载复用既有 `WebSend*` 变体，`sessionId` 即 token；
//!   上传用新增 `WebUpload*` 变体）。

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use tokio::sync::mpsc;
use tokio_rustls::TlsAcceptor;

use crate::bridge::event::{send_event, BridgeEvent};
use crate::bridge::lock;
use crate::bridge::server::clone_event_tx;
use crate::bridge::state::bridge;
use crate::bridge::web::caps::ShareState;
use crate::bridge::web::server::{FileTableChange, ProgressEvent, ShutdownSignal, WebServiceState};
use crate::bridge::web::session::{FileSource, SharedFile, SharedFileTable};
use crate::bridge::web::upload::UploadStore;

/// 服务配置（ArkTS 传 JSON，由调用方按 camelCase 组装）。
#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebServiceConfig {
    /// 本机别名（文件表响应携带，供浏览器页展示）。
    #[serde(default)]
    pub alias: String,
    /// 本次分享的 6 位访问码（裸地址手动输入时使用；`None`/空串表示旧调用的免访问码模式）。
    #[serde(default)]
    pub pin: Option<String>,
    /// 二维码/URL 能力令牌（`None`/空串表示不启用能力门禁）。
    #[serde(default)]
    pub capability: Option<String>,
    /// 浏览器上传入口是否开放。
    #[serde(default)]
    pub upload_enabled: bool,
    /// 是否使用自签证书 HTTPS（跟随网页独立加密开关）。
    #[serde(default)]
    pub use_https: bool,
    /// 首选监听端口（0 表示由系统随机分配）；被占用时回退随机端口。
    #[serde(default)]
    pub port: u16,
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
    /// 源文件修改时间（Unix 毫秒；供 ZIP 条目时间还原）。
    #[serde(default)]
    pub last_modified: Option<u64>,
}

fn default_fd() -> i32 {
    -1
}

/// 运行时句柄（全局单例持有）。
struct WebRuntime {
    state: Option<Arc<WebServiceState>>,
    server_task: Option<tokio::task::JoinHandle<()>>,
    forward_task: Option<tokio::task::JoinHandle<()>>,
    // 周期惰性打扫：无新请求时也要终结过期会话并清临时文件
    sweep_task: Option<tokio::task::JoinHandle<()>>,
}

fn runtime() -> &'static Mutex<WebRuntime> {
    static RUNTIME: OnceLock<Mutex<WebRuntime>> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        Mutex::new(WebRuntime {
            state: None,
            server_task: None,
            forward_task: None,
            sweep_task: None,
        })
    })
}

/// 当前服务状态（无服务时 `None`）。
pub fn current_state() -> Option<Arc<WebServiceState>> {
    lock(runtime()).state.clone()
}

/// 绑定网页监听端口：优先使用首选端口，被占用时回退系统随机端口。
/// 调用方须先停掉旧实例（`start` 内完成），这里不处理自占用。
async fn bind_listener(preferred: u16) -> anyhow::Result<tokio::net::TcpListener> {
    if preferred > 0 {
        match tokio::net::TcpListener::bind(("0.0.0.0", preferred)).await {
            Ok(listener) => return Ok(listener),
            Err(e) => log::warn!("首选端口被占用 port={preferred}: {e}"),
        }
    }
    tokio::net::TcpListener::bind("0.0.0.0:0")
        .await
        .map_err(|e| anyhow::anyhow!("监听失败: {e}"))
}

/// 用桥接层共享的 TLS 身份构建浏览器可用的 HTTPS acceptor。
fn build_tls_acceptor() -> anyhow::Result<TlsAcceptor> {
    let (cert_pem, key_pem) = {
        let state = lock(bridge());
        (state.cert_pem.clone(), state.key_pem.clone())
    };
    if cert_pem.is_empty() || key_pem.is_empty() {
        return Err(anyhow::anyhow!("TLS 身份为空"));
    }
    let certs = vec![CertificateDer::from_pem_slice(cert_pem.as_bytes())?];
    let key = PrivateKeyDer::from_pem_slice(key_pem.as_bytes())?;
    // 网页服务可能先于 LocalSend 服务器启动，需自行确保 crypto provider 就绪
    let _ = rustls::crypto::ring::default_provider().install_default();
    let config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)?;
    Ok(TlsAcceptor::from(Arc::new(config)))
}

/// 访问码规则（与 ArkTS 侧 `WebAccessCode` 对齐）：6 位数字。
/// 空串表示兼容旧调用/测试的免访问码模式，服务端不在此强制。
fn validate_pin(pin: &str) -> anyhow::Result<()> {
    if pin.is_empty() {
        return Ok(());
    }
    if pin.len() != 6 || !pin.bytes().all(|b| b.is_ascii_digit()) {
        return Err(anyhow::anyhow!("访问码必须为 6 位数字"));
    }
    Ok(())
}

/// 启动自研 web 服务，返回实际绑定端口。
pub async fn start(config_json: &str) -> anyhow::Result<u16> {
    let config: WebServiceConfig = serde_json::from_str(config_json)
        .map_err(|e| anyhow::anyhow!("服务配置 JSON 解析失败: {e}"))?;
    if let Some(pin) = config.pin.as_deref() {
        validate_pin(pin)?;
    }
    let mut files: HashMap<String, SharedFile> = HashMap::new();
    let mut file_order: Vec<String> = Vec::new();
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
        file_order.push(entry.file_id.clone());
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
                last_modified_ms: entry.last_modified,
            },
        );
    }
    let mut table = SharedFileTable::empty();
    table.replace(files);
    let file_count: usize = table.files.len();
    let has_access_code: bool = config.pin.as_deref().is_some_and(|pin| !pin.is_empty());
    let upload_enabled: bool = config.upload_enabled;
    let use_https: bool = config.use_https;
    let (progress_tx, progress_rx) = mpsc::channel::<ProgressEvent>(64);
    let (file_events, _) = tokio::sync::broadcast::channel::<FileTableChange>(16);
    let (session_events, _) = tokio::sync::broadcast::channel::<String>(16);
    let (caps_events, _) = tokio::sync::broadcast::channel::<()>(16);
    let state = Arc::new(WebServiceState {
        caps: Arc::new(Mutex::new(crate::bridge::web::caps::CapsSnapshot {
            has_download: !table.files.is_empty(),
            file_revision: table.revision,
            upload_enabled: config.upload_enabled,
            share_state: ShareState::Active,
            https_hint: config.use_https,
            share_id: String::new(),
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
        capability: Arc::new(Mutex::new(
            config.capability.filter(|token| !token.is_empty()),
        )),
        auth_sessions: Arc::new(Mutex::new(HashMap::new())),
        cap_sessions: Arc::new(Mutex::new(HashMap::new())),
        files: Arc::new(Mutex::new(table)),
        file_order: Arc::new(Mutex::new(file_order)),
        retained: Arc::new(Mutex::new(HashMap::new())),
        sessions: Arc::new(Mutex::new(
            crate::bridge::web::session::SessionStore::default(),
        )),
        uploads: Arc::new(Mutex::new(UploadStore::default())),
        upload_dir: Arc::new(Mutex::new(std::path::PathBuf::from(config.upload_dir))),
        pin_attempts: Arc::new(Mutex::new(HashMap::new())),
        progress_tx: Some(progress_tx),
        file_events: Some(file_events),
        session_events: Some(session_events),
        pending_batches: Arc::new(Mutex::new(HashMap::new())),
        active_batches: Arc::new(Mutex::new(HashMap::new())),
        closing: Arc::new(Mutex::new(HashMap::new())),
        caps_events: Some(caps_events),
        shutdown: Arc::new(ShutdownSignal::default()),
    });
    let listener = {
        // 先停旧实例并等其任务退出：监听套接字释放后再绑定首选端口，
        // 避免同端口重启时被自己占住而误回退到随机端口
        stop_internal_async().await;
        bind_listener(config.port).await?
    };
    let port = listener
        .local_addr()
        .map_err(|e| anyhow::anyhow!("取端口失败: {e}"))?
        .port();
    // HTTPS 与 HTTP 共用端口；证书身份来自桥接层（与 LocalSend 共用证书，开关独立）
    let tls_acceptor = if config.use_https {
        Some(build_tls_acceptor()?)
    } else {
        None
    };
    let server_state = Arc::clone(&state);
    let server_task = tokio::spawn(async move {
        crate::bridge::web::server::run_server_with_tls(listener, server_state, tls_acceptor).await;
    });
    let forward_task = tokio::spawn(async move {
        forward_events(progress_rx).await;
    });
    let sweep_state = Arc::clone(&state);
    let sweep_task = tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(2));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            interval.tick().await;
            sweep_state.sweep_all(std::time::Instant::now()).await;
        }
    });
    let mut runtime = lock(runtime());
    runtime.state = Some(state);
    runtime.server_task = Some(server_task);
    runtime.forward_task = Some(forward_task);
    runtime.sweep_task = Some(sweep_task);
    log::info!("网页服务已启动");
    log::debug!(
        "网页服务参数 port={port} https={use_https} files={file_count} upload={upload_enabled} 访问码={}",
        if has_access_code { "开" } else { "关" }
    );
    Ok(port)
}

/// 停止分享但保留服务 30 秒左右的结束态（仅标记状态，不关闭监听）。
///
/// 由 ArkTS 在停止网页服务时先调用：已打开页面经 SSE caps 事件立即切到
/// “分享已结束”，短时间内刷新也能拿到 stopped 页面；随后再硬停止服务。
pub fn mark_stopped() {
    if let Some(state) = current_state() {
        state.mark_stopped();
        log::info!("已进入停止态，等待页面收尾");
    }
}

/// 停止自研 web 服务（幂等）。
pub fn stop() {
    stop_internal();
}

/// 停止旧实例并等待任务真正退出，确保监听套接字已释放。
/// 仅用于 `start` 的同端口重建；同步 `stop` 保持非阻塞语义。
async fn stop_internal_async() {
    let (state, server_task, forward_task, sweep_task) = {
        let mut runtime = lock(runtime());
        (
            runtime.state.take(),
            runtime.server_task.take(),
            runtime.forward_task.take(),
            runtime.sweep_task.take(),
        )
    };
    // 先关闭所有已建立连接：浏览器复用旧 keep-alive 连接时会落到新服务上，
    // 不会继续读到旧（停止态）快照。
    if state.is_some() {
        log::info!("服务已停止");
    }
    if let Some(state) = state {
        state.shutdown.trigger();
    }
    if let Some(task) = server_task {
        task.abort();
        let _ = task.await;
    }
    if let Some(task) = forward_task {
        task.abort();
        let _ = task.await;
    }
    if let Some(task) = sweep_task {
        task.abort();
        let _ = task.await;
    }
}

fn stop_internal() {
    let (state, server_task, forward_task, sweep_task) = {
        let mut runtime = lock(runtime());
        (
            runtime.state.take(),
            runtime.server_task.take(),
            runtime.forward_task.take(),
            runtime.sweep_task.take(),
        )
    };
    if state.is_some() {
        log::info!("服务已停止");
    }
    if let Some(state) = state {
        state.shutdown.trigger();
    }
    if let Some(task) = server_task {
        task.abort();
    }
    if let Some(task) = forward_task {
        task.abort();
    }
    if let Some(task) = sweep_task {
        task.abort();
    }
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
        #[serde(default)]
        last_modified: Option<u64>,
    }
    let entries: Vec<FileEntry> =
        serde_json::from_str(files_json).map_err(|e| anyhow::anyhow!("文件 JSON 解析失败: {e}"))?;
    let mut files: HashMap<String, SharedFile> = HashMap::new();
    let mut file_order: Vec<String> = Vec::new();
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
        file_order.push(entry.file_id.clone());
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
                last_modified_ms: entry.last_modified,
            },
        );
    }
    let state = current_state().ok_or_else(|| anyhow::anyhow!("网页服务未运行"))?;
    let count = files.len() as u32;
    *lock(&state.file_order) = file_order;
    state.update_files(files);
    log::debug!("文件表已更新 files={count}");
    Ok(count)
}

/// 设置浏览器上传入口开关。
pub fn set_upload_enabled(enabled: bool) -> anyhow::Result<()> {
    let state = current_state().ok_or_else(|| anyhow::anyhow!("网页服务未运行"))?;
    lock(&state.caps).upload_enabled = enabled;
    if let Some(tx) = &state.caps_events {
        let _ = tx.send(());
    }
    log::debug!("上传入口已切换 enabled={enabled}");
    Ok(())
}

/// 接受待确认上传会话（下载已无待确认状态）。
pub fn accept(token: &str) -> anyhow::Result<()> {
    let state = current_state().ok_or_else(|| anyhow::anyhow!("网页服务未运行"))?;
    let now = std::time::Instant::now();
    lock(&state.uploads)
        .accept(token, now)
        .map_err(|_| anyhow::anyhow!("上传会话不存在或已过期: {token}"))?;
    Ok(())
}

/// 拒绝待确认上传会话（下载已无待确认状态）。
pub fn decline(token: &str) -> anyhow::Result<()> {
    let state = current_state().ok_or_else(|| anyhow::anyhow!("网页服务未运行"))?;
    let removed = lock(&state.uploads).decline(token);
    match removed {
        Some(session) => {
            crate::bridge::web::server::remove_tmp_files(&session);
            Ok(())
        }
        None => Err(anyhow::anyhow!("上传会话不存在或已过期: {token}")),
    }
}

/// 令待确认上传会话过期（浏览器收 408）。
pub fn expire(token: &str) -> anyhow::Result<()> {
    let state = current_state().ok_or_else(|| anyhow::anyhow!("网页服务未运行"))?;
    if lock(&state.uploads).expire(token) {
        state.broadcast_session_end(token);
        return Ok(());
    }
    Err(anyhow::anyhow!("上传会话不存在或已过期: {token}"))
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
    let targets: Vec<Target> =
        serde_json::from_str(targets_json).map_err(|e| anyhow::anyhow!("落盘目标解析失败: {e}"))?;
    let state = current_state().ok_or_else(|| anyhow::anyhow!("网页服务未运行"))?;
    let pairs: Vec<(String, String)> = targets.into_iter().map(|t| (t.file_id, t.path)).collect();
    let applied = lock(&state.uploads).set_targets(token, &pairs);
    log::debug!("上传落盘目标已设置 applied={applied} total={}", pairs.len());
    Ok(applied as u32)
}

/// 取消指定下载批次：设置取消标志，写循环在下个读块停止。
pub fn cancel_download(batch_id: &str) -> anyhow::Result<()> {
    let state = current_state().ok_or_else(|| anyhow::anyhow!("网页服务未运行"))?;
    let flag = lock(&state.active_batches)
        .get(batch_id)
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("下载批次不存在或已结束: {batch_id}"))?;
    flag.store(true, std::sync::atomic::Ordering::Relaxed);
    log::debug!("下载批次已取消 batch={batch_id}");
    Ok(())
}

/// 触发全量惰性打扫（供 ArkTS 侧超时驱动调用）。
pub async fn sweep() -> anyhow::Result<()> {
    let state = current_state().ok_or_else(|| anyhow::anyhow!("网页服务未运行"))?;
    state.sweep_all(std::time::Instant::now()).await;
    Ok(())
}

/// 进度事件 → 桥接事件转发（下载用批次事件，上传沿用既有 `WebUpload*`）。
async fn forward_events(mut progress_rx: mpsc::Receiver<ProgressEvent>) {
    let event_tx = clone_event_tx(bridge());
    while let Some(event) = progress_rx.recv().await {
        let bridge_event = match event {
            ProgressEvent::WebAccess {
                ip,
                user_agent,
                file_count,
            } => BridgeEvent::WebAccess {
                ip,
                user_agent,
                file_count,
            },
            ProgressEvent::DownloadStarted {
                batch_id,
                ip,
                user_agent,
                files,
            } => BridgeEvent::WebDownloadStarted {
                batch_id,
                ip,
                user_agent,
                files,
            },
            ProgressEvent::DownloadProgress {
                batch_id,
                file_id,
                sent_bytes,
                total_bytes,
            } => BridgeEvent::WebDownloadProgress {
                batch_id,
                file_id,
                sent_bytes,
                total_bytes,
            },
            ProgressEvent::DownloadFileDone {
                batch_id,
                file_id,
                total_bytes,
            } => BridgeEvent::WebDownloadFileDone {
                batch_id,
                file_id,
                total_bytes,
            },
            ProgressEvent::DownloadEnded {
                batch_id,
                outcome,
                error,
            } => BridgeEvent::WebDownloadEnded {
                batch_id,
                outcome: outcome.as_str().to_string(),
                error,
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
            ProgressEvent::Finished { token } => {
                BridgeEvent::WebSendSessionEnd { session_id: token }
            }
        };
        send_event(&event_tx, bridge_event).await;
    }
}

#[cfg(test)]
mod tests {
    use super::{bind_listener, start, stop, WebServiceConfig};

    #[tokio::test]
    async fn bind_listener_uses_preferred_port_when_free() {
        let probe = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("探测端口绑定失败");
        let preferred = probe.local_addr().expect("探测端口读取失败").port();
        drop(probe);
        let listener = bind_listener(preferred).await.expect("网页端口绑定失败");
        assert_eq!(
            listener.local_addr().expect("监听地址读取失败").port(),
            preferred
        );
    }

    #[tokio::test]
    async fn bind_listener_falls_back_when_preferred_occupied() {
        let occupied = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("占用端口绑定失败");
        let preferred = occupied.local_addr().expect("占用端口读取失败").port();
        let listener = bind_listener(preferred).await.expect("网页端口绑定失败");
        assert_ne!(
            listener.local_addr().expect("监听地址读取失败").port(),
            preferred
        );
    }

    #[test]
    fn config_port_defaults_to_zero() {
        let config: WebServiceConfig = serde_json::from_str("{}").expect("空配置解析失败");
        assert_eq!(config.port, 0);
    }

    #[test]
    fn validate_pin_enforces_six_digits() {
        assert!(super::validate_pin("").is_ok());
        assert!(super::validate_pin("123456").is_ok());
        assert!(super::validate_pin("000123").is_ok());
        assert!(super::validate_pin("12345").is_err());
        assert!(super::validate_pin("1234567").is_err());
        assert!(super::validate_pin("12345a").is_err());
        assert!(super::validate_pin("123 56").is_err());
    }

    #[tokio::test]
    async fn restart_reuses_preferred_port() {
        // 模拟“开启网页服务后选择文件”触发的同端口重建：
        // 旧实例仍监听首选端口，重建必须等旧任务退出后继续使用同一端口，
        // 而不是被自己占住后回退到临时端口
        let first = start(r#"{"port":0,"uploadDir":""}"#)
            .await
            .expect("首次启动失败");
        assert!(first > 0);
        let config = format!(r#"{{"port":{first},"uploadDir":""}}"#);
        let second = start(&config).await.expect("同端口重启失败");
        assert_eq!(second, first);
        stop();
    }
}
