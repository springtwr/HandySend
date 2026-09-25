//! Web 分享（WebSend）/ 网页上传能力：分享链接、网页下载决策、fd 内容源。
//!
//! 与 `server` 模块共用 `start_server` 与 BridgeState：
//! - 分享/上传模式均为"停止当前服务器 → 以 WebConfig 重启"的完整重建；
//! - 事件经 `adapt_web_send_event` 适配后走统一 engine 路径；
//! - fd 所有权归 ArkTS：原始 fd 分享期间长期有效，每次下载 dup 副本消费。

use std::collections::HashMap;
use std::os::fd::FromRawFd;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use serde_json::{json, Value};
use tokio::sync::{mpsc, oneshot};

use localsend::http::server::web::WebConfig;

use crate::bridge::engine::apply_actions;
use crate::bridge::event::{send_event, BridgeError, BridgeEvent};
use crate::bridge::identity;
use crate::bridge::lock;
use crate::bridge::server::{clone_event_tx, start_server};
use crate::bridge::state::{BridgeState, WebSendFile};
use crate::bridge::throttle::ProgressThrottle;

/// 清空 Web 分享内容源表（停止/重建分享时调用）。
///
/// fd 所有权归 ArkTS：原始 fd 由 ArkTS 持有并在分享结束时关闭，
/// 此处仅清空映射，不关闭 fd。
pub(crate) fn clear_web_send_files(web_send_files: &Arc<Mutex<HashMap<String, WebSendFile>>>) {
    lock(web_send_files).clear();
}

// fd 内容源下发（Web 分享下载用）：
// - 独立 task 运行：每次下载一份副本、一条 channel，互不影响，支持同一文件的重复与并发下载；
// - 以 `pread` 显式偏移读取：副本与原始 fd 共享文件 offset，顺序 read 在重复/并发下载时
//   会读到空内容或交错数据；
// - 读毕（EOF/错误/接收端关闭）经 `from_raw_fd` 包装后 drop 关闭副本；
// - dup/pread 为 POSIX 标准 API，普通 Linux（开发机）同样编译此分支，
//   使 host 集成测试能覆盖与真机一致的 fd 内容提供路径；
// - 读取过程中按节流发射 `WebSendProgress` 桥接事件（sessionId/fileId/sentBytes/totalBytes），
//   供 ArkTS 侧呈现字节级下载进度；该事件为可丢弃事件，channel 满时丢弃不影响内容传输。

/// 描述 fd 的类型与可定位性（诊断用：区分普通文件与不可随机读的内容提供方 fd）。
#[cfg(any(target_os = "android", target_os = "linux"))]
fn describe_fd(fd: libc::c_int) -> String {
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(fd, &mut st) } != 0 {
        return format!("fstat 失败 errno={}", std::io::Error::last_os_error());
    }
    let kind = match st.st_mode & libc::S_IFMT {
        libc::S_IFREG => "普通文件",
        libc::S_IFIFO => "管道",
        libc::S_IFSOCK => "套接字",
        libc::S_IFDIR => "目录",
        _ => "其它",
    };
    format!("类型={} 大小={}", kind, st.st_size)
}

#[cfg(any(target_os = "android", target_os = "linux"))]
fn spawn_fd_content_task(
    fd: libc::c_int,
    session_id: String,
    file_id: String,
    total_bytes: u64,
    event_tx: Option<mpsc::Sender<BridgeEvent>>,
    content_tx: oneshot::Sender<localsend::model::transfer::FileContent>,
) {
    const READ_BUF_SIZE: usize = 512 * 1024;
    const CHANNEL_CAPACITY: usize = 16;

    let (tx, rx) = mpsc::channel::<bytes::Bytes>(CHANNEL_CAPACITY);
    let diag_session = session_id.clone();
    let diag_file = file_id.clone();
    tokio::task::spawn_blocking(move || {
        let started = Instant::now();
        let mut offset: libc::off_t = 0;
        let mut sent: u64 = 0;
        let mut chunks: u64 = 0;
        // 提前中止原因（诊断用）：eof / read_error / receiver_closed
        let stop_reason: &str;
        let mut throttle = ProgressThrottle::new();
        log::debug!(
            "WebSend 内容下发开始: session={} file={} 声明大小={} 读块={} fd信息={}",
            diag_session,
            diag_file,
            total_bytes,
            READ_BUF_SIZE,
            describe_fd(fd)
        );
        loop {
            let mut buf = vec![0u8; READ_BUF_SIZE];
            let n = unsafe {
                libc::pread(
                    fd,
                    buf.as_mut_ptr().cast::<libc::c_void>(),
                    READ_BUF_SIZE,
                    offset,
                )
            };
            if n < 0 {
                stop_reason = "read_error";
                log::warn!(
                    "WebSend 内容读取失败: session={} file={} 偏移={} 已读={} errno={}",
                    diag_session,
                    diag_file,
                    offset,
                    sent,
                    std::io::Error::last_os_error()
                );
                break;
            }
            if n == 0 {
                stop_reason = "eof";
                break;
            }
            let n = n as usize;
            offset += n as libc::off_t;
            sent += n as u64;
            chunks += 1;
            // 按节流发射下载进度（可丢弃，不阻塞内容读取）
            if let Some(tx) = &event_tx {
                if throttle.allow(Instant::now()) {
                    let _ = tx.try_send(BridgeEvent::WebSendProgress {
                        session_id: session_id.clone(),
                        file_id: file_id.clone(),
                        sent_bytes: sent,
                        total_bytes,
                    });
                }
            }
            buf.truncate(n);
            if tx.blocking_send(buf.into()).is_err() {
                stop_reason = "receiver_closed";
                break;
            }
        }
        // 读取结束：补发一条终值进度，确保进度到达终值（channel 满时丢弃可接受）
        if let Some(tx) = &event_tx {
            let _ = tx.try_send(BridgeEvent::WebSendProgress {
                session_id: session_id.clone(),
                file_id: file_id.clone(),
                sent_bytes: sent,
                total_bytes,
            });
        }
        // 诊断：本次下发的分块数、累计字节与声明大小的关系（长度不符是浏览器中断的直接嫌疑）。
        // 接收端主动关闭（浏览器取消下载）时内容未发完属预期，按 debug 记录，不计为长度不符。
        if sent == total_bytes {
            log::debug!(
                "WebSend 内容下发完成: session={} file={} 交付={} 声明={} 分块={} 原因={} 耗时={}ms",
                diag_session,
                diag_file,
                sent,
                total_bytes,
                chunks,
                stop_reason,
                started.elapsed().as_millis()
            );
        } else if stop_reason == "receiver_closed" {
            log::debug!(
                "WebSend 内容下发中止（接收端关闭）: session={} file={} 交付={} 声明={} 分块={} 耗时={}ms",
                diag_session,
                diag_file,
                sent,
                total_bytes,
                chunks,
                started.elapsed().as_millis()
            );
        } else {
            log::warn!(
                "WebSend 内容下发长度不符: session={} file={} 交付={} 声明={} 差值={} 分块={} 原因={} 耗时={}ms",
                diag_session,
                diag_file,
                sent,
                total_bytes,
                sent as i64 - total_bytes as i64,
                chunks,
                stop_reason,
                started.elapsed().as_millis()
            );
        }
        // 读取结束：包装后 drop 即关闭副本 fd
        let _ = unsafe { std::fs::File::from_raw_fd(fd) };
    });
    // Stream 变体：上游 into_receiver 直接返回该 channel
    let _ = content_tx.send(localsend::model::transfer::FileContent::Stream(rx));
}

/// 派生 WebSendEvent 消费任务。
///
/// 事件循环：收 WebSendEvent → adapt_web_send_event → apply 状态变更 →
/// 特殊处理 FileDownload 应答（从 web_send_files 查找内容源提供内容）→ 发送桥接事件。
/// JoinHandle 存入 `state.web_send_event_task`（stop_share_server 时 abort；
/// stop_server 仅移除 web_send_event_tx，发送端全部释放后任务自然退出）。
pub fn spawn_web_send_event_task(
    state: Arc<Mutex<BridgeState>>,
    mut event_rx: mpsc::Receiver<localsend::http::server::web::WebSendEvent>,
) {
    let event_tx = clone_event_tx(&state);
    let state_for_task = state.clone();
    let task = tokio::spawn(async move {
        while let Some(event) = event_rx.recv().await {
            let (bridge_event, actions) =
                crate::bridge::adapter::server::adapt_web_send_event(event);
            {
                let mut s = lock(&state_for_task);
                apply_actions(&mut s, actions);
            }

            // FileDownload：查找内容源并应答 content_tx（提供文件内容）
            if let Some(BridgeEvent::WebSendFileDownload {
                session_id,
                file_id,
                size,
                ..
            }) = &bridge_event
            {
                let wf = {
                    let s = lock(&state_for_task);
                    let map = lock(&s.web_send_files);
                    map.get(file_id).cloned()
                };
                let content_tx = {
                    let mut s = lock(&state_for_task);
                    s.pending_file_downloads
                        .remove(&(session_id.clone(), file_id.clone()))
                };
                if let Some(content_tx) = content_tx {
                    #[cfg(any(target_os = "android", target_os = "linux"))]
                    {
                        let fd_opt = wf.as_ref().and_then(|w| w.fd);
                        if let Some(fd) = fd_opt {
                            // fd 所有权归 ArkTS：原始 fd 分享期间长期有效，
                            // 每次下载 dup 独立副本交给 spawn_fd_content_task
                            // 读取（读毕自动关闭副本），支持重复/并发下载；
                            // 不修改 web_send_files 条目，Rust 从不关闭原始 fd
                            let dup_fd = unsafe { libc::dup(fd) };
                            if dup_fd >= 0 {
                                spawn_fd_content_task(
                                    dup_fd,
                                    session_id.clone(),
                                    file_id.clone(),
                                    *size,
                                    event_tx.clone(),
                                    content_tx,
                                );
                            } else {
                                // dup 失败：丢弃发送端使浏览器得 500，不悬挂请求
                                log::warn!(
                                    "WebSend FileDownload: dup(fd={}) failed for file_id={}: {}",
                                    fd,
                                    file_id,
                                    std::io::Error::last_os_error()
                                );
                                drop(content_tx);
                            }
                        } else if let Some(wfs) = &wf {
                            let _ = content_tx.send(localsend::model::transfer::FileContent::Path(
                                std::path::PathBuf::from(&wfs.path),
                            ));
                        } else {
                            log::warn!(
                                "WebSend FileDownload: no source found for file_id={}",
                                file_id
                            );
                            drop(content_tx);
                        }
                    }
                    #[cfg(not(any(target_os = "android", target_os = "linux")))]
                    {
                        if let Some(wfs) = &wf {
                            let _ = content_tx.send(localsend::model::transfer::FileContent::Path(
                                std::path::PathBuf::from(&wfs.path),
                            ));
                        } else {
                            log::warn!(
                                "WebSend FileDownload: no source found for file_id={}",
                                file_id
                            );
                            drop(content_tx);
                        }
                    }
                }
            }

            if let Some(ev) = bridge_event {
                send_event(&event_tx, ev).await;
            }
        }
        log::debug!("WebSend event loop task ended");
    });

    let mut s = lock(&state);
    s.web_send_event_task = Some(task);
}

/// 接受 Web 下载决策（发送 true）。
pub fn accept_web_download(
    state: &Mutex<BridgeState>,
    session_id: &str,
) -> Result<(), BridgeError> {
    let mut s = lock(state);
    if let Some(sender) = s.web_download_decisions.remove(session_id) {
        let _ = sender.send(true);
        Ok(())
    } else {
        Err(BridgeError::SessionExpired(session_id.to_string()))
    }
}

/// 拒绝 Web 下载决策（发送 false）。
pub fn decline_web_download(
    state: &Mutex<BridgeState>,
    session_id: &str,
) -> Result<(), BridgeError> {
    let mut s = lock(state);
    if let Some(sender) = s.web_download_decisions.remove(session_id) {
        let _ = sender.send(false);
        Ok(())
    } else {
        Err(BridgeError::SessionExpired(session_id.to_string()))
    }
}

/// 将待处理的文件下载标记为失败（丢弃发送端导致 500 响应）。
pub fn fail_file_download(
    state: &Mutex<BridgeState>,
    session_id: &str,
    file_id: &str,
) -> Result<(), BridgeError> {
    let mut s = lock(state);

    if s.pending_file_downloads
        .remove(&(session_id.to_string(), file_id.to_string()))
        .is_some()
    {
        return Ok(());
    }

    if s.web_download_decisions.remove(session_id).is_some() {
        return Ok(());
    }

    Err(BridgeError::SessionExpired(format!(
        "无待处理的文件下载 session={}, file={}",
        session_id, file_id
    )))
}

/// 停止当前服务器并等待端口完全释放。
///
/// 同一锁临界区内：发送停止信号、abort 服务器事件循环 task、执行
/// `extra_cleanup` 额外清理、取出 `server_handle`；随后锁外等待服务器
/// 完全停止。各"停止旧服务器并重启"的调用路径共用。
async fn stop_server_and_wait<F>(state: &Mutex<BridgeState>, tag: &str, extra_cleanup: F)
where
    F: FnOnce(&mut BridgeState),
{
    let handle = {
        let mut s = lock(state);
        log::debug!(
            "{}: stopping old server (stop_tx={}, handle={})",
            tag,
            s.server_stop_tx.is_some(),
            s.server_handle.is_some()
        );
        if let Some(stop_tx) = s.server_stop_tx.take() {
            let _ = stop_tx.send(());
        }
        if let Some(task) = s.server_event_task.take() {
            task.abort();
        }
        extra_cleanup(&mut s);
        s.server_handle.take()
    };

    if let Some(handle) = handle {
        handle.wait_stopped().await;
        log::debug!("{}: old server fully stopped", tag);
    }
}

/// 启动 WebSend 上传模式服务器。
///
/// 停止当前服务器，以 upload WebConfig 重启，返回实际端口。
pub async fn start_web_upload(state: Arc<Mutex<BridgeState>>) -> Result<u16, BridgeError> {
    log::debug!("start_web_upload: stopping current server");
    // 停止当前服务器并等待端口释放
    stop_server_and_wait(&state, "start_web_upload", |_| {}).await;

    let (port, use_https, verify_checksums, current_pin) = {
        let s = lock(&state);
        (
            s.local_port,
            s.use_https,
            s.verify_checksums,
            s.receive_pin.clone(),
        )
    };

    // 上传模式 WebConfig
    let i18n = identity::build_web_i18n();
    let web_config = Some(WebConfig {
        send: None,
        upload: true,
        i18n,
    });

    // 清除 Web 发送状态（上传模式不适用）
    {
        let mut s = lock(&state);
        s.web_send_event_tx.take();
        clear_web_send_files(&s.web_send_files);
        s.web_download_decisions.clear();
    }

    start_server(
        state.clone(),
        port,
        use_https,
        verify_checksums,
        current_pin,
        web_config,
        None,
    )
    .await?;

    let actual_port = lock(&state).local_port;
    log::debug!("start_web_upload: server started on port={}", actual_port);
    Ok(actual_port)
}

/// 创建分享链接（WebSend 下载模式）。
pub async fn create_share_link(
    state: Arc<Mutex<BridgeState>>,
    files_json: &str,
    _alias: &str,
) -> Result<String, BridgeError> {
    use serde_json::json;

    let files: Vec<Value> = serde_json::from_str(files_json)
        .map_err(|e| BridgeError::InvalidArgument(format!("文件 JSON 解析失败: {e}")))?;

    if files.is_empty() {
        return Err(BridgeError::InvalidArgument(
            "分享链接需要至少一个文件".into(),
        ));
    }

    let mut file_dtos: std::collections::HashMap<String, localsend::model::transfer::FileDto> =
        std::collections::HashMap::new();
    let mut file_sources: std::collections::HashMap<String, WebSendFile> =
        std::collections::HashMap::new();

    for f in &files {
        let file_id = f["fileId"].as_str().unwrap_or("").to_string();
        let file_name = f["fileName"].as_str().unwrap_or("").to_string();
        let size = f["size"].as_u64().unwrap_or(0);
        let file_type = f["fileType"].as_str().unwrap_or("").to_string();
        let file_path = f["filePath"].as_str().unwrap_or("").to_string();
        let preview = f["preview"].as_str().map(|s| s.to_string());
        let sha256 = f["sha256"].as_str().map(|s| s.to_string());
        let fd = f["fd"].as_i64().map(|v| v as i32).filter(|v| *v >= 0);

        if file_id.is_empty() || file_path.is_empty() {
            continue;
        }

        file_dtos.insert(
            file_id.clone(),
            localsend::model::transfer::FileDto {
                id: file_id.clone(),
                file_name: file_name.clone(),
                size,
                file_type: file_type.clone(),
                sha256: sha256.clone(),
                preview: preview.clone(),
                metadata: None,
            },
        );
        // fd ≥ 0 时内容源为该 fd（原始 fd 分享期间长期有效，每次下载 dup
        // 副本消费，由 ArkTS 持有并关闭）；否则回退 filePath
        file_sources.insert(
            file_id.clone(),
            WebSendFile {
                path: file_path,
                fd,
            },
        );
    }

    if file_dtos.is_empty() {
        return Err(BridgeError::InvalidArgument("分享链接没有有效文件".into()));
    }

    let current_pin = lock(&state).receive_pin.clone();

    // 创建 WebSend 事件通道
    let (web_send_event_tx, web_send_event_rx) =
        mpsc::channel::<localsend::http::server::web::WebSendEvent>(64);

    // 停止当前服务器并等待端口释放
    stop_server_and_wait(&state, "create_share_link", |_| {}).await;

    let (port, use_https, verify_checksums) = {
        let s = lock(&state);
        (s.local_port, s.use_https, s.verify_checksums)
    };

    // WebSendConfig + WebConfig
    let i18n = identity::build_web_i18n();
    let web_send_config = localsend::http::server::web::WebSendConfig {
        files: file_dtos,
        pin: current_pin.clone(),
        event_tx: web_send_event_tx.clone(),
    };
    let web_config = WebConfig {
        send: Some(web_send_config),
        upload: false,
        i18n,
    };

    {
        let mut s = lock(&state);
        s.web_send_event_tx = Some(web_send_event_tx);
        *lock(&s.web_send_files) = file_sources;
    }

    start_server(
        state.clone(),
        port,
        use_https,
        verify_checksums,
        current_pin,
        Some(web_config),
        None,
    )
    .await?;

    // 派生 WebSendEvent 消费任务
    spawn_web_send_event_task(state.clone(), web_send_event_rx);

    // 从重启后的服务器获取实际端口和 IP
    let (actual_port, local_ip) = {
        let s = lock(&state);
        let port = s.local_port;
        let ip = s
            .server_handle
            .as_ref()
            .and_then(|h| {
                h.local_addresses()
                    .iter()
                    .find(|a| !a.ip().is_loopback())
                    .map(|a| a.ip().to_string())
            })
            .unwrap_or_else(|| "0.0.0.0".to_string());
        (port, ip)
    };

    let protocol = if use_https { "https" } else { "http" };
    let url = if local_ip == "0.0.0.0" {
        format!("{}://0.0.0.0:{}", protocol, actual_port)
    } else {
        format!("{}://{}:{}", protocol, local_ip, actual_port)
    };

    let session_id = format!(
        "web_send_{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
    );

    Ok(json!({
        "url": url,
        "port": actual_port,
        "sessionId": session_id,
    })
    .to_string())
}

/// 停止分享服务器（清除 WebSend 状态并以正常模式重启服务器）。
pub async fn stop_share_server(state: Arc<Mutex<BridgeState>>) {
    stop_server_and_wait(&state, "stop_share_server", |s| {
        if let Some(task) = s.web_send_event_task.take() {
            task.abort();
        }
        s.web_send_event_tx.take();
        clear_web_send_files(&s.web_send_files);
        s.web_download_decisions.clear();
        s.pending_file_uploads.clear();
        s.pending_file_downloads.clear();
        // 与 stop_server 的清理集保持一致：取消活跃传输令牌、清空待决策
        // 会话与请求，避免分享服务器停止后残留累积（直到下次 stop_server
        // 才被清空），期间 UI 轮询还会收到已死的过期请求
        for (_key, cancel) in s.active_transfers.drain() {
            cancel.cancel();
        }
        lock(&s.pending_requests).clear();
        s.pending_decisions.clear();
        s.session_peers.clear();
        // 关闭所有尚未消费的接收直写 fd
        for (_key, recv_fd) in s.recv_target_fds.drain() {
            let _ = unsafe { std::fs::File::from_raw_fd(recv_fd.fd) };
        }
    })
    .await;

    let (port, use_https, verify_checksums, current_pin) = {
        let s = lock(&state);
        (
            s.local_port,
            s.use_https,
            s.verify_checksums,
            s.receive_pin.clone(),
        )
    };

    if let Err(e) = start_server(
        state.clone(),
        port,
        use_https,
        verify_checksums,
        current_pin,
        None,
        None,
    )
    .await
    {
        // 正常模式重启失败：服务器将保持停止。调用方（stopShareLink）只按 Ok 返回，
        // 故此处必须留痕，否则「停止分享后服务器应恢复」的故障无从排查
        log::error!("stop_share_server: 正常模式重启失败: {e}");
    }
}

// ── 单元测试 ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::oneshot;

    // ── Web 下载决策测试 ──

    #[test]
    fn test_accept_web_download_with_pending_decision() {
        let state = Mutex::new(BridgeState::new());
        let (tx, mut rx) = oneshot::channel();
        {
            let mut s = state.lock().unwrap();
            s.web_download_decisions.insert("web-1".to_string(), tx);
        }
        accept_web_download(&state, "web-1").unwrap();
        let decision = rx.try_recv().unwrap();
        assert!(decision, "应发送 true（接受）");
    }

    #[test]
    fn test_accept_web_download_no_pending_returns_session_expired() {
        let state = Mutex::new(BridgeState::new());
        let result = accept_web_download(&state, "nonexistent");
        assert!(matches!(result, Err(BridgeError::SessionExpired(_))));
    }

    #[test]
    fn test_decline_web_download_with_pending_decision() {
        let state = Mutex::new(BridgeState::new());
        let (tx, mut rx) = oneshot::channel();
        {
            let mut s = state.lock().unwrap();
            s.web_download_decisions.insert("web-2".to_string(), tx);
        }
        decline_web_download(&state, "web-2").unwrap();
        let decision = rx.try_recv().unwrap();
        assert!(!decision, "应发送 false（拒绝）");
    }

    #[test]
    fn test_fail_file_download_drops_pending() {
        let state = Mutex::new(BridgeState::new());
        let (tx, mut rx) = oneshot::channel::<localsend::model::transfer::FileContent>();
        {
            let mut s = state.lock().unwrap();
            s.pending_file_downloads
                .insert(("s-1".to_string(), "f-1".to_string()), tx);
        }
        fail_file_download(&state, "s-1", "f-1").unwrap();
        // content_tx 被丢弃 → 等待方收到 RecvError
        assert!(rx.try_recv().is_err());
        assert!(state.lock().unwrap().pending_file_downloads.is_empty());
    }

    #[test]
    fn test_fail_file_download_no_pending_errors() {
        let state = Mutex::new(BridgeState::new());
        let result = fail_file_download(&state, "s-none", "f-none");
        assert!(result.is_err());
    }

    #[test]
    fn test_web_download_decision_cleared_on_accept() {
        let state = Mutex::new(BridgeState::new());
        let (tx, _rx) = oneshot::channel();
        {
            let mut s = state.lock().unwrap();
            s.web_download_decisions.insert("web-3".to_string(), tx);
        }
        accept_web_download(&state, "web-3").unwrap();
        assert!(state.lock().unwrap().web_download_decisions.is_empty());
    }
}
