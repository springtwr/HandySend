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
    /// 取消令牌（停止时触发，终止已接受的连接）
    cancel: tokio_util::sync::CancellationToken,
    /// 服务器上下文（停止时据此关闭未消费的发送 fd）
    ctx: Arc<MtaContext>,
}

/// 全局运行中的服务器（同一时刻至多一个）。
static RUNNING: StdMutex<Option<RunningServer>> = StdMutex::new(None);

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
/// 不再预打包 ZIP：下载响应体按文件清单流式生成，起服同步预计算完成后立即就绪。
/// 重复调用会先停止旧服务器。文本会话的临时文件不在此处删除（由 ArkTS 清理）。
///
/// fd 所有权：config 解析成功起，清单内全部 fd（fd_crc/fd_send）的所有权即移交
/// Rust——无论启动成败均由其负责关闭。失败路径在任一退出点前关闭全部未消费
/// fd（见 `close_unconsumed_fds`）；成功路径把未消费 fd_send 的跟踪登记进
/// `MtaContext.fds_consumed`，由下载消费或 `stop_server` 收尾。ArkTS 侧移交后
/// 不再触碰任何 fd。
pub async fn start_server(
    state: &Arc<StdMutex<BridgeState>>,
    config_json: &str,
) -> anyhow::Result<u16> {
    stop_server();

    let config: MtaServerConfig = serde_json::from_str(config_json)
        .map_err(|e| anyhow::anyhow!("解析 MtaServerConfig 失败: {e}"))?;

    // 所有权移交点：自此 config.files 携带的全部 fd 归 Rust，任一失败退出点返回前
    // 都必须关闭全部未消费 fd。`crc_consumed` 逐文件标记 fd_crc 是否已被预计算消费。
    let mut crc_consumed = vec![false; config.files.len()];
    if config.task_id.is_empty() {
        close_unconsumed_fds(&config.files, &crc_consumed);
        anyhow::bail!("taskId 不能为空");
    }
    if config.files.is_empty() {
        close_unconsumed_fds(&config.files, &crc_consumed);
        anyhow::bail!("files 不能为空");
    }

    log::debug!(
        "MTA 启动服务器请求 taskId={} 文件数={}",
        config.task_id,
        config.files.len()
    );

    // 1) 起服同步 CRC 预计算：逐文件从 fd_crc（或回退路径）顺序读一遍，crc32fast
    //    累计 CRC 与大小。读盘为阻塞 IO，经 spawn_blocking 在专用线程执行，避免
    //    长时间占用 async worker（CRC 期间 runtime 仍可处理事件转发/accept 等）。
    //    fd_crc 以 OwnedFd 显式移入闭包（满足 'static），读毕/出错均由 File drop
    //    关闭——所有权仍在 start_server 调用内收尾，不参与发送阶段；某条目预计算
    //    失败立即终止，其后未消费的 fd_crc 由失败收尾关闭（见 close_unconsumed_fds）。
    let mut crc_results: Vec<(u32, u64)> = Vec::with_capacity(config.files.len());
    for (i, f) in config.files.iter().enumerate() {
        let fd_crc = f.fd_crc;
        let path = f.path.clone();
        let r = tokio::task::spawn_blocking(move || compute_entry_crc(fd_crc, path))
            .await
            .unwrap_or_else(|e| Err(anyhow::anyhow!("CRC 预计算任务异常退出: {e}")))
            .and_then(|(crc, size)| {
                if size > u32::MAX as u64 {
                    anyhow::bail!("单条目超过 ZIP32 上限 {}", f.entry_name);
                }
                Ok((crc, size))
            })
            .map_err(|e| format!("{e:#}"));
        // 无论成败，compute_entry_crc 都已消费本条目 fd_crc（读毕/错误后 File drop 关闭）
        crc_consumed[i] = true;
        match r {
            Ok(v) => crc_results.push(v),
            Err(msg) => {
                close_unconsumed_fds(&config.files, &crc_consumed);
                anyhow::bail!("{msg}");
            }
        }
    }

    // 把预计算结果回填进文件清单（crc32/size_bytes），并据此求源总大小
    let mut files: Vec<MtaFileEntry> = Vec::with_capacity(config.files.len());
    let mut total_size: u64 = 0;
    for (i, entry) in config.files.iter().enumerate() {
        let mut filled = entry.clone();
        let (crc, size) = crc_results[i];
        filled.crc32 = crc;
        filled.size_bytes = size;
        total_size = total_size.checked_add(size).ok_or_else(|| {
            close_unconsumed_fds(&config.files, &crc_consumed);
            anyhow::anyhow!("源文件总大小溢出")
        })?;
        files.push(filled);
    }
    let file_count = files.len();

    // 2) 运行时自签名证书 → rustls ServerConfig
    let tls_config = server::build_tls_config().map_err(|e| {
        close_unconsumed_fds(&config.files, &crc_consumed);
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
                    close_unconsumed_fds(&config.files, &crc_consumed);
                    anyhow::anyhow!("绑定端口失败: {e:#}")
                })?
        }
    };
    let port = listener
        .local_addr()
        .map_err(|e| {
            close_unconsumed_fds(&config.files, &crc_consumed);
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

/// 计算单条目 (crc, size)：`fd >= 0` 时接管该 fd 顺序读到 EOF（读毕关闭），
/// 否则按路径打开（防御回退）。在 spawn_blocking 线程执行，fd 所有权随参数移入、
/// 读毕/出错由 File drop 关闭，调用方不再触碰。
fn compute_entry_crc(fd: i32, path: String) -> anyhow::Result<(u32, u64)> {
    use std::os::fd::FromRawFd;
    let mut file = if fd >= 0 {
        // SAFETY：fd 由 ArkTS 打开并移交；本函数读毕（EOF/错误）时关闭，调用方不再触碰
        let owned = unsafe { std::os::fd::OwnedFd::from_raw_fd(fd) };
        std::fs::File::from(owned)
    } else {
        std::fs::File::open(&path).map_err(|e| anyhow::anyhow!("打开待发送文件失败 {path}: {e}"))?
    };
    use std::io::Read;
    let mut buffer = vec![0u8; 256 * 1024];
    let mut hasher = crc32fast::Hasher::new();
    let mut total: u64 = 0;
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|e| anyhow::anyhow!("读取待发送文件失败 {path}: {e}"))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        total += read as u64;
    }
    Ok((hasher.finalize(), total))
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

/// 关闭尚未移交下载消费的发送 fd（消费过的由下载路径负责关闭，防止双关）。
fn close_unconsumed_send_fds(ctx: &MtaContext) {
    use std::os::fd::FromRawFd;
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

/// 关闭一批尚未消费的发送 fd（`start_server` 失败收尾专用）。
///
/// 仅在 `start_server` 的失败退出点调用一次：此时这些 fd 的所有权已归 Rust，
/// 但尚未被任何消费路径关闭——`crc_consumed[i]` 为 true 表示该条目 fd_crc 已由
/// 预计算读毕关闭，无需重复处理；fd_send 在起服失败时必然未被消费，一律关闭。
/// 调用后不得再有其他路径触碰这些 fd。
fn close_unconsumed_fds(files: &[MtaFileEntry], crc_consumed: &[bool]) {
    use std::os::fd::FromRawFd;
    for (i, entry) in files.iter().enumerate() {
        if entry.fd_crc >= 0 && !crc_consumed[i] {
            // SAFETY：fd_crc 尚未被预计算消费，关闭后不再有路径触碰
            let _ = unsafe { std::fs::File::from_raw_fd(entry.fd_crc) };
        }
        if entry.fd_send >= 0 {
            // SAFETY：fd_send 尚未移交下载消费，属唯一关闭点
            let _ = unsafe { std::fs::File::from_raw_fd(entry.fd_send) };
        }
    }
}

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

    /// 失败收尾函数语义：仅关闭未消费的 fd，已消费标记的 fd_crc 绝不被重复关闭。
    #[test]
    fn close_unconsumed_fds_closes_only_unconsumed() {
        use std::fs::File;
        use std::os::fd::{FromRawFd, IntoRawFd};

        let dir = std::env::temp_dir().join(format!("mta_close_fds_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let p = dir.join("a.bin");
        std::fs::write(&p, b"fd").unwrap();

        // 三个条目的 fd 组合：已消费 fd_crc + 未消费 fd_send；未消费 fd_crc；仅未消费 fd_send
        let fd_consumed_crc = File::open(&p).unwrap().into_raw_fd();
        let fd_unconsumed_crc = File::open(&p).unwrap().into_raw_fd();
        let fd_send_a = File::open(&p).unwrap().into_raw_fd();
        let fd_send_c = File::open(&p).unwrap().into_raw_fd();

        let files = vec![
            MtaFileEntry {
                fd_crc: fd_consumed_crc,
                fd_send: fd_send_a,
                path: String::new(),
                entry_name: "1/a".into(),
                last_modified_ms: None,
                crc32: 0,
                size_bytes: 2,
            },
            MtaFileEntry {
                fd_crc: fd_unconsumed_crc,
                fd_send: -1,
                path: String::new(),
                entry_name: "2/b".into(),
                last_modified_ms: None,
                crc32: 0,
                size_bytes: 2,
            },
            MtaFileEntry {
                fd_crc: -1,
                fd_send: fd_send_c,
                path: String::new(),
                entry_name: "3/c".into(),
                last_modified_ms: None,
                crc32: 0,
                size_bytes: 2,
            },
        ];
        let crc_consumed = vec![true, false, false];

        close_unconsumed_fds(&files, &crc_consumed);

        // 已消费标记的 fd_crc 不被关闭（防双关），其余未消费 fd 全部关闭
        assert!(
            fd_is_open(fd_consumed_crc),
            "已消费标记的 fdCrc 不应被收尾重复关闭"
        );
        assert!(!fd_is_open(fd_send_a), "未消费的 fdSend 应被关闭");
        assert!(!fd_is_open(fd_unconsumed_crc), "未消费的 fdCrc 应被关闭");
        assert!(!fd_is_open(fd_send_c), "未消费的 fdSend 应被关闭");

        // 手动关闭保持打开的那个 fd，避免测试进程泄漏句柄
        let _ = unsafe { std::fs::File::from_raw_fd(fd_consumed_crc) };
        let _ = std::fs::remove_dir_all(&dir);
    }
}
