//! MTA 发送端桥接模块。
//!
//! Rust 侧承载发送端 TLS/WS/HTTP/ZIP 服务器：同一 TLS 端口同时提供
//! WebSocket 协商（`/websocket`）与 HTTPS 下载（`/download?taskId=`）；
//! ArkTS 侧负责 BLE/GATT、WiFi P2P 建组、凭据加解密与流程编排。
//!
//! 子模块职责：
//! - `protocol`：应用层消息纯函数（构造/解析/JSON 序列化）
//! - `zip_stream`：按文件清单预打包 ZIP
//! - `ws`：WS 连接上的 MTA 状态机
//! - `server`：hyper + rustls TLS 服务器
//!
//! 本模块提供服务器生命周期（start/stop）与事件发射，NAPI 层只是薄封装。

pub mod protocol;
pub mod server;
pub mod ws;
pub mod zip_stream;

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};

use serde::Deserialize;
use tokio::sync::watch;

use crate::bridge::event::{send_event, BridgeEvent};
use crate::bridge::state::BridgeState;

pub use zip_stream::{display_name, MtaFileEntry};

/// `nativeMtaStartServer` 的 JSON 配置。
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MtaServerConfig {
    /// 绑定地址（绑定失败时回退 `0.0.0.0`）
    pub bind_ip: String,
    /// 端口（0 = 由系统随机分配）
    pub port: u16,
    /// 任务 ID
    pub task_id: String,
    /// 发送方 ID
    pub sender_id: String,
    /// 发送方名称
    pub sender_name: String,
    /// 待发送文件清单
    pub files: Vec<MtaFileEntry>,
    /// 预打包 ZIP 输出路径
    pub zip_path: String,
    /// MTA 原生文本内容（可选，JSON `textContent`）；缺省时行为不变
    #[serde(default)]
    pub text_content: Option<String>,
    /// 模拟品牌标识（可选，JSON `senderBrandId`）；缺省时行为不变
    #[serde(default)]
    pub sender_brand_id: Option<u8>,
    /// 模拟品牌名称（可选，JSON `senderBrand`）；缺省时行为不变
    #[serde(default)]
    pub sender_brand: Option<String>,
}

/// 下载阶段（`/download` 处理与 WS 状态机通过 watch 通道共享）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DownloadPhase {
    /// 尚未开始
    Idle,
    /// 对端已开始下载
    Started,
    /// 下载已完成
    Completed,
}

/// 一次 MTA 发送会话的运行时上下文（HTTP 与 WS 处理共享）。
pub struct MtaContext {
    /// 任务 ID
    pub task_id: String,
    /// 发送方 ID
    pub sender_id: String,
    /// 发送方名称
    pub sender_name: String,
    /// 预打包 ZIP 路径
    pub zip_path: PathBuf,
    /// ZIP 大小（Content-Length）
    pub zip_size: u64,
    /// 主文件名（sendRequest 展示用）
    pub file_name: String,
    /// 文件 MIME 类型
    pub mime_type: String,
    /// 文件数
    pub file_count: usize,
    /// 源文件总字节数
    pub total_size: u64,
    /// MTA 原生文本内容（可选，供 ws.rs 构造 sendRequest 携带 `catShareText`）
    pub text_content: Option<String>,
    /// 模拟品牌标识（可选，供 ws.rs 构造 sendRequest 携带 `senderBrandId`）
    pub sender_brand_id: Option<u8>,
    /// 模拟品牌名称（可选，供 ws.rs 构造 sendRequest 携带 `senderBrand`）
    pub sender_brand: Option<String>,
    /// 桥接事件发送端（可为空）
    pub event_tx: Option<tokio::sync::mpsc::Sender<BridgeEvent>>,
    /// 下载阶段广播（供 ws.rs 订阅）
    pub phase_tx: watch::Sender<DownloadPhase>,
    /// 是否已有 WS 连接（防止重复协商）
    pub ws_connected: AtomicBool,
}

impl MtaContext {
    /// 标记已有 WS 连接（首次返回 true）。
    pub fn mark_ws_connected(&self) -> bool {
        !self.ws_connected.swap(true, Ordering::SeqCst)
    }
}

/// 运行中的服务器句柄。
struct RunningServer {
    /// accept 循环任务句柄（停止时 abort）
    abort: tokio::task::AbortHandle,
    /// 实际绑定端口
    port: u16,
}

/// 全局运行中的服务器（同一时刻至多一个）。
static RUNNING: StdMutex<Option<RunningServer>> = StdMutex::new(None);

/// 当前服务器是否运行中。
pub fn is_running() -> bool {
    RUNNING.lock().map(|g| g.is_some()).unwrap_or(false)
}

/// 启动 MTA 服务器：预打包 ZIP → 绑定 TLS 端口 → 起 accept 循环，返回实际端口。
///
/// 重复调用会先停止旧服务器。ZIP 文件不在此处删除（由 ArkTS 清理）。
pub async fn start_server(
    state: &Arc<StdMutex<BridgeState>>,
    config_json: &str,
) -> anyhow::Result<u16> {
    stop_server();

    let config: MtaServerConfig = serde_json::from_str(config_json)
        .map_err(|e| anyhow::anyhow!("解析 MtaServerConfig 失败: {e}"))?;
    if config.task_id.is_empty() {
        anyhow::bail!("taskId 不能为空");
    }
    if config.files.is_empty() {
        anyhow::bail!("files 不能为空");
    }

    log::debug!(
        "MTA 启动服务器请求 taskId={} 文件数={}",
        config.task_id,
        config.files.len()
    );

    // 1) 预打包 ZIP（提供 Content-Length 与准确进度）
    let pack = zip_stream::pack_zip(&config.zip_path, &config.files)?;
    log::debug!(
        "MTA 打包结果 zip={} zip字节={} 源总字节={} 条目数={}",
        config.zip_path,
        pack.zip_size,
        pack.total_size,
        pack.entry_count
    );

    // 2) 运行时自签名证书 → rustls ServerConfig
    let tls_config = server::build_tls_config()?;

    // 3) 绑定端口（bind_ip 失败回退 0.0.0.0）
    let bind_ip: std::net::IpAddr = config
        .bind_ip
        .parse()
        .unwrap_or_else(|_| "0.0.0.0".parse().expect("0.0.0.0 合法"));
    let listener = match tokio::net::TcpListener::bind((bind_ip, config.port)).await {
        Ok(listener) => listener,
        Err(e) => {
            log::warn!("绑定 {bind_ip}:{} 失败（{e}），回退 0.0.0.0", config.port);
            tokio::net::TcpListener::bind(("0.0.0.0", config.port)).await?
        }
    };
    let port = listener.local_addr()?.port();
    log::debug!("MTA 服务器监听已就绪 bindIp={bind_ip} port={port}");

    // 4) 组装上下文并起 accept 循环
    let event_tx = state.lock().map(|s| s.event_tx.clone()).unwrap_or(None);
    let file_name = config
        .files
        .first()
        .map(|f| display_name(&f.entry_name))
        .unwrap_or_else(|| config.task_id.clone());
    let (phase_tx, _phase_rx) = watch::channel(DownloadPhase::Idle);
    let ctx = Arc::new(MtaContext {
        task_id: config.task_id,
        sender_id: config.sender_id,
        sender_name: config.sender_name,
        zip_path: PathBuf::from(&config.zip_path),
        zip_size: pack.zip_size,
        file_name,
        mime_type: "application/zip".to_string(),
        file_count: pack.entry_count,
        total_size: pack.total_size,
        text_content: config.text_content,
        sender_brand_id: config.sender_brand_id,
        sender_brand: config.sender_brand,
        event_tx: event_tx.clone(),
        phase_tx,
        ws_connected: AtomicBool::new(false),
    });

    let accept_ctx = Arc::clone(&ctx);
    let handle = tokio::spawn(async move {
        server::run_server(listener, tls_config, accept_ctx).await;
    });

    if let Ok(mut guard) = RUNNING.lock() {
        *guard = Some(RunningServer {
            abort: handle.abort_handle(),
            port,
        });
    }

    // 5) 通知服务器已启动
    send_event(&event_tx, BridgeEvent::MtaServerStarted { port }).await;

    log::info!("MTA 服务器已启动 port={port} zip={} bytes", pack.zip_size);
    Ok(port)
}

/// 停止 MTA 服务器（幂等；不删除 ZIP 文件）。
pub fn stop_server() {
    let taken = match RUNNING.lock() {
        Ok(mut guard) => guard.take(),
        Err(_) => None,
    };
    if let Some(server) = taken {
        server.abort.abort();
        log::info!("MTA 服务器已停止 port={}", server.port);
    }
}
