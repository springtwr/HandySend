//! MTA 发送端桥接模块。
//!
//! Rust 侧承载发送端 TLS/WS/HTTP/ZIP 服务器：同一 TLS 端口同时提供
//! WebSocket 协商（`/websocket`）与 HTTPS 下载（`/download?taskId=`）；
//! ArkTS 侧负责 BLE/GATT、WiFi P2P 建组、凭据加解密与流程编排。
//!
//! 子模块职责：
//! - `protocol`：应用层消息纯函数（构造/解析/JSON 序列化）
//! - `zip_stream`：按文件清单流式写出 ZIP（下载响应体）
//! - `unzip_stream`：可复用的 ZIP 流式解析/解压核心
//! - `receive`：接收端 Rust 主导下载（reqwest + 流式解压 + 直接写目标目录）
//! - `ws`：WS 连接上的 MTA 状态机
//! - `server`：hyper + rustls TLS 服务器
//!
//! 本模块提供服务器生命周期（start/stop）与事件发射，NAPI 层只是薄封装。

pub mod protocol;
pub mod receive;
pub mod server;
pub mod unzip_stream;
pub mod ws;
pub mod zip_stream;

use std::os::fd::FromRawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};

use serde::Deserialize;
use tokio::sync::watch;

use crate::bridge::event::{send_event, BridgeEvent};
use crate::bridge::state::BridgeState;

pub use receive::{ReceiveTimeouts, ReceivedEntry};
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
    /// MTA 原生文本内容（可选，JSON `textContent`）
    #[serde(default)]
    pub text_content: Option<String>,
    /// 模拟品牌标识（可选，JSON `senderBrandId`）
    #[serde(default)]
    pub sender_brand_id: Option<u8>,
    /// 模拟品牌名称（可选，JSON `senderBrand`）
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
    /// 下载因对端断开/中止连接而失败（对端取消），供 WS 状态机立即收尾
    PeerAborted,
}

/// 一次 MTA 发送会话的运行时上下文（HTTP 与 WS 处理共享）。
pub struct MtaContext {
    /// 任务 ID
    pub task_id: String,
    /// 发送方 ID
    pub sender_id: String,
    /// 发送方名称
    pub sender_name: String,
    /// 待发送文件清单（fd 读取源或回退路径、条目名与源修改时间）
    pub files: Vec<MtaFileEntry>,
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
    /// 服务器取消令牌：stop_server 时触发，accept 循环、已接受连接
    /// （HTTP/WS）感知后立即收尾，保证停止后不再继续对外服务
    pub cancel: tokio_util::sync::CancellationToken,
    /// 发送 fd 是否已移交下载消费（`stop_server` 据此关闭未消费的 `fd_send`，避免双关）
    pub fds_consumed: Arc<std::sync::Mutex<Vec<bool>>>,
    /// 下载响应是否已构造过：fd 所有权单次移交，重复请求直接拒绝（防 fd 复用错乱）
    pub download_served: AtomicBool,
    /// 是否已收到「向对端回送取消」的意图（本地取消时置位；与停服令牌语义分离）
    pub reject_pending: AtomicBool,
    /// 唤醒正在等待的 WS 状态机，使其立即响应取消意图
    pub reject_notify: tokio::sync::Notify,
}

impl MtaContext {
    /// 标记已有 WS 连接（首次返回 true）。
    pub fn mark_ws_connected(&self) -> bool {
        !self.ws_connected.swap(true, Ordering::SeqCst)
    }

    /// 置位「向对端回送取消」意图并唤醒等待中的 WS 状态机。
    ///
    /// 用 `notify_one`：即使唤醒发生在 WS 状态机注册等待之前，许可也会留存，
    /// 避免「置位与首次等待」之间的窗口丢失通知（意图本身以原子标志为准）。
    pub fn mark_reject_pending(&self) {
        self.reject_pending.store(true, Ordering::SeqCst);
        self.reject_notify.notify_one();
    }

    /// 是否已登记「向对端回送取消」意图。
    pub fn is_reject_pending(&self) -> bool {
        self.reject_pending.load(Ordering::SeqCst)
    }
}

/// 运行中的服务器句柄。
struct RunningServer {
    /// accept 循环任务句柄（停止时 abort）
    abort: tokio::task::AbortHandle,
    /// 实际绑定端口
    port: u16,
    /// 取消令牌（停止时触发，终止已接受的连接）
    cancel: tokio_util::sync::CancellationToken,
    /// 服务器上下文（停止时据此关闭未消费的发送 fd）
    ctx: Arc<MtaContext>,
}

/// 全局运行中的服务器（同一时刻至多一个）。
static RUNNING: StdMutex<Option<RunningServer>> = StdMutex::new(None);

/// 起服互斥锁：`start_server` 全程持锁，防止并发起服交错时
/// 先完成登记的服务器被后来者覆盖而永不停止（端口与 fd 泄漏）。
static START_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// 取 RUNNING 锁，中毒时恢复访问并记日志。
///
/// guard 持有期均为无跨语句不变量的短临界区（读/写/替换整个 Option），
/// 中毒不代表数据损坏；若放弃访问，服务器将永久失控：
/// is_running 恒 false、stop_server 恒空转、start_server 无法登记新实例。
fn running_lock() -> std::sync::MutexGuard<'static, Option<RunningServer>> {
    match RUNNING.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            log::error!("RUNNING 锁中毒，恢复访问以避免服务器失控");
            poisoned.into_inner()
        }
    }
}

/// 当前服务器是否运行中。
pub fn is_running() -> bool {
    running_lock().is_some()
}

/// 启动 MTA 服务器：绑定 TLS 端口 → 起 accept 循环，返回实际端口。
///
/// 不再预打包 ZIP：下载响应体按文件清单流式生成，起服仅完成配置解析与端口绑定。
/// 重复调用会先停止旧服务器。文本会话的临时文件不在此处删除（由 ArkTS 清理）。
///
/// fd 所有权：config 解析成功起，清单内全部 fd（fd_send）的所有权即移交
/// Rust——无论启动成败均由其负责关闭。失败路径在任一退出点前关闭全部未消费
/// fd（见 `close_unconsumed_fds`）；成功路径把未消费 fd_send 的跟踪登记进
/// `MtaContext.fds_consumed`，由下载消费或 `stop_server` 收尾。ArkTS 侧移交后
/// 不再触碰任何 fd。
pub async fn start_server(
    state: &Arc<StdMutex<BridgeState>>,
    config_json: &str,
) -> anyhow::Result<u16> {
    // 起服全程互斥：stop 旧服与登记新服之间有多个 await 点，
    // 并发 start 交错会覆盖先登记者且不停止它（见 START_LOCK 注释）
    let _start_guard = START_LOCK.lock().await;
    stop_server();

    let config: MtaServerConfig = serde_json::from_str(config_json)
        .map_err(|e| anyhow::anyhow!("解析 MtaServerConfig 失败: {e}"))?;

    // 所有权移交点：自此 config.files 携带的全部 fd 归 Rust，任一失败退出点返回前
    // 都必须关闭全部未消费 fd。
    let close_all = |files: &[MtaFileEntry]| {
        for entry in files {
            if entry.fd_send >= 0 {
                // SAFETY：fd_send 尚未被消费路径关闭，关闭后不再有路径触碰
                let _ = unsafe { std::fs::File::from_raw_fd(entry.fd_send) };
            }
        }
    };
    if config.task_id.is_empty() {
        close_all(&config.files);
        anyhow::bail!("taskId 不能为空");
    }
    if config.files.is_empty() {
        close_all(&config.files);
        anyhow::bail!("files 不能为空");
    }

    log::debug!(
        "MTA 启动服务器请求 taskId={} 文件数={}",
        config.task_id,
        config.files.len()
    );

    // 1) 起服合法性校验：大小/条目数来自 ArkTS statSync（不再起服预读计算 CRC，
    //    对端 MTA 设备同样不依赖预读，CRC 由 zip crate 写出时自动计算）。总大小
    //    checked_add 防溢出；单条目上限与条目数上限由 ArkTS 打包前校验兜底。
    let mut total_size: u64 = 0;
    for entry in &config.files {
        total_size = total_size.checked_add(entry.size_bytes).ok_or_else(|| {
            close_all(&config.files);
            anyhow::anyhow!("源文件总大小溢出")
        })?;
    }
    let files: Vec<MtaFileEntry> = config.files.clone();
    let file_count = files.len();

    // 2) 运行时自签名证书 → rustls ServerConfig
    let tls_config = server::build_tls_config().map_err(|e| {
        close_all(&config.files);
        anyhow::anyhow!("构建 TLS 配置失败: {e:#}")
    })?;

    // 3) 绑定端口（bind_ip 失败回退 0.0.0.0）
    let bind_ip: std::net::IpAddr = config
        .bind_ip
        .parse()
        .unwrap_or_else(|_| "0.0.0.0".parse().expect("0.0.0.0 合法"));
    let listener = match tokio::net::TcpListener::bind((bind_ip, config.port)).await {
        Ok(listener) => listener,
        Err(e) => {
            log::warn!("绑定 {bind_ip}:{} 失败（{e}），回退 0.0.0.0", config.port);
            tokio::net::TcpListener::bind(("0.0.0.0", config.port))
                .await
                .map_err(|e| {
                    close_all(&config.files);
                    anyhow::anyhow!("绑定端口失败: {e:#}")
                })?
        }
    };
    let port = listener
        .local_addr()
        .map_err(|e| {
            close_all(&config.files);
            anyhow::anyhow!("获取监听端口失败: {e:#}")
        })?
        .port();
    log::debug!("MTA 服务器监听已就绪 bindIp={bind_ip} port={port}");

    // 4) 组装上下文并起 accept 循环
    let event_tx = state.lock().map(|s| s.event_tx.clone()).unwrap_or(None);
    let file_name = files
        .first()
        .map(|f| display_name(&f.entry_name))
        .unwrap_or_else(|| config.task_id.clone());
    let (phase_tx, _phase_rx) = watch::channel(DownloadPhase::Idle);
    let cancel = tokio_util::sync::CancellationToken::new();
    let fds_consumed: Arc<std::sync::Mutex<Vec<bool>>> =
        Arc::new(std::sync::Mutex::new(vec![false; files.len()]));
    let ctx = Arc::new(MtaContext {
        task_id: config.task_id,
        sender_id: config.sender_id,
        sender_name: config.sender_name,
        files,
        file_name,
        mime_type: "application/zip".to_string(),
        file_count,
        total_size,
        text_content: config.text_content,
        sender_brand_id: config.sender_brand_id,
        sender_brand: config.sender_brand,
        event_tx: event_tx.clone(),
        phase_tx,
        ws_connected: AtomicBool::new(false),
        cancel: cancel.clone(),
        fds_consumed,
        download_served: AtomicBool::new(false),
        reject_pending: AtomicBool::new(false),
        reject_notify: tokio::sync::Notify::new(),
    });

    let accept_ctx = Arc::clone(&ctx);
    let handle = tokio::spawn(async move {
        server::run_server(listener, tls_config, accept_ctx).await;
    });

    *running_lock() = Some(RunningServer {
        abort: handle.abort_handle(),
        port,
        cancel,
        ctx,
    });

    // 5) 通知服务器已启动
    send_event(&event_tx, BridgeEvent::MtaServerStarted { port }).await;

    log::info!("MTA 服务器已启动 port={port} 文件数={file_count} 源总字节={total_size}");
    Ok(port)
}

/// 停止 MTA 服务器（幂等；不删除文本会话的暂存文件）。
///
/// 取消令牌触发后：accept 循环退出、已接受的 HTTP/WS 连接收尾，
/// 正在进行的下载被截断——用户取消分享后对端不能继续完整下载。
/// 同时关闭尚未移交下载消费的发送 fd（`fd_send`），避免 fd 泄漏。
pub fn stop_server() {
    let taken = running_lock().take();
    if let Some(server) = taken {
        server.cancel.cancel();
        server.abort.abort();
        close_unconsumed_send_fds(&server.ctx);
        log::info!("MTA 服务器已停止 port={}", server.port);
    }
}

/// 向当前运行中的发送服务器登记「向对端回送取消」意图。
///
/// 仅登记意图：不停服、不触发取消令牌——服务器与 P2P 群组保持监听，使尚未接入
/// 会话通道的对端仍可连入并拿到取消状态（响应点见 `ws::run_ws`）。
/// 服务器不存在（更早的发送阶段，对端尚无凭据）时为空操作，按「未能通知对端」处理。
pub fn reject_peer() {
    let guard = running_lock();
    match guard.as_ref() {
        Some(server) => {
            log::info!("MTA 登记回送取消意图 taskId={}", server.ctx.task_id);
            server.ctx.mark_reject_pending();
        }
        None => log::debug!("MTA 登记回送取消意图时服务器未运行，按未通知处理"),
    }
}

/// 关闭尚未移交下载消费的发送 fd（消费过的由下载路径负责关闭，防止双关）。
fn close_unconsumed_send_fds(ctx: &MtaContext) {
    let mut consumed = ctx.fds_consumed.lock().unwrap();
    for (i, entry) in ctx.files.iter().enumerate() {
        if !consumed[i] && entry.fd_send >= 0 {
            // SAFETY：该 fd 尚未移交下载消费，且此处是唯一关闭点（消费前），
            // 关闭后置位防重复。
            let _ = unsafe { std::fs::File::from_raw_fd(entry.fd_send) };
            consumed[i] = true;
        }
    }
}

/// fd 收尾语义测试直接调用 [`close_unconsumed_send_fds`]（生产调用点为
/// [`stop_server`]）：未移交下载消费的 fd_send 一律关闭，已消费的防双关。
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_running_lock_recovers_from_poison() {
        // 故意在持锁时 panic 使锁中毒
        let _ = std::thread::spawn(|| {
            let _guard = RUNNING.lock().unwrap();
            panic!("故意中毒");
        })
        .join();
        // 中毒后各入口应恢复访问而不是静默失控
        assert!(!is_running(), "中毒后 is_running 应正常应答");
        stop_server(); // 幂等且不 panic
        assert!(!is_running());
    }

    /// host 测试目标为 Linux：fcntl(F_GETFD) 在 fd 已关闭时返回 EBADF。
    /// SAFETY：F_GETFD 仅查询描述符标志，无副作用。
    fn fd_is_open(fd: i32) -> bool {
        (unsafe { libc::fcntl(fd, libc::F_GETFD) }) >= 0
    }

    /// fd 语义测试串行执行：并行测试 open 文件会复用刚关闭的 fd 号，
    /// 干扰 fd_is_open 断言（误把复用后的同号 fd 判为未关闭）。
    static FD_TEST_MUTEX: StdMutex<()> = StdMutex::new(());

    /// 失败收尾语义：调用生产函数 [`close_unconsumed_send_fds`]，
    /// 未移交下载消费的 fd_send 一律关闭；已消费的不重复关闭（防双关）。
    #[test]
    fn close_all_closes_unconsumed_send_fds() {
        use std::fs::File;
        use std::os::fd::IntoRawFd;

        let _serial = FD_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

        let dir = std::env::temp_dir().join(format!("mta_close_fds_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let p = dir.join("a.bin");
        std::fs::write(&p, b"fd").unwrap();

        let fd_send_a = File::open(&p).unwrap().into_raw_fd();
        let fd_send_b = File::open(&p).unwrap().into_raw_fd();
        let fd_consumed = File::open(&p).unwrap().into_raw_fd();

        let files = vec![
            MtaFileEntry {
                fd_send: fd_send_a,
                path: String::new(),
                entry_name: "1/a".into(),
                last_modified_ms: None,
                size_bytes: 2,
            },
            MtaFileEntry {
                fd_send: fd_send_b,
                path: String::new(),
                entry_name: "2/b".into(),
                last_modified_ms: None,
                size_bytes: 2,
            },
            MtaFileEntry {
                fd_send: fd_consumed,
                path: String::new(),
                entry_name: "3/c".into(),
                last_modified_ms: None,
                size_bytes: 2,
            },
        ];
        let file_count = files.len();
        let (phase_tx, _phase_rx) = watch::channel(DownloadPhase::Idle);
        let ctx = MtaContext {
            task_id: "t-close".into(),
            sender_id: "s1".into(),
            sender_name: "tester".into(),
            files,
            file_name: "a.bin".into(),
            mime_type: "application/octet-stream".into(),
            file_count,
            total_size: 6,
            text_content: None,
            sender_brand_id: None,
            sender_brand: None,
            event_tx: None,
            phase_tx,
            ws_connected: AtomicBool::new(false),
            cancel: tokio_util::sync::CancellationToken::new(),
            // 第三个 fd 标记为已消费（模拟下载路径已接管关闭责任）
            fds_consumed: Arc::new(StdMutex::new(vec![false, false, true])),
            download_served: AtomicBool::new(false),
            reject_pending: AtomicBool::new(false),
            reject_notify: tokio::sync::Notify::new(),
        };

        close_unconsumed_send_fds(&ctx);

        assert!(!fd_is_open(fd_send_a), "未消费的 fdSend 应被关闭");
        assert!(!fd_is_open(fd_send_b), "未消费的 fdSend 应被关闭");
        assert!(fd_is_open(fd_consumed), "已消费的 fdSend 不应被重复关闭");
        assert!(
            ctx.fds_consumed.lock().unwrap().iter().all(|c| *c),
            "关闭后应置位防重复"
        );

        // 幂等：重复调用不应 panic、不应触碰已消费 fd
        close_unconsumed_send_fds(&ctx);
        assert!(fd_is_open(fd_consumed), "重复收尾仍不应触碰已消费 fd");

        // 清理已消费 fd（所有权归本测试）
        let _ = unsafe { std::fs::File::from_raw_fd(fd_consumed) };

        let _ = std::fs::remove_dir_all(&dir);
    }
}
