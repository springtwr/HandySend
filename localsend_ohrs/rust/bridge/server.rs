//! 服务器生命周期 + 传输决策 + WebSend。
//!
//! 核心函数接收 `Arc<Mutex<BridgeState>>` 参数，事件通过
//! `state.event_tx`（mpsc::Sender<BridgeEvent>）输出。
//! runtime 由调用方提供（NAPI 层 NapiEnv 或测试的 tokio runtime），本模块不创建。
//!
//! 事件循环：spawn 后 JoinHandle 存入 `state.server_event_task`，
//! `stop_server` 时 abort，确保快速 stop→start 无 task 泄漏。

use crate::bridge::lock;
use std::collections::HashMap;
use std::os::fd::FromRawFd;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::sync::{mpsc, oneshot};

use localsend::http::server::internal::{InternalConfig, InternalEvent};
use localsend::http::server::v2::ServerEventV2;
use localsend::http::server::web::WebConfig;
use localsend::http::server::{self, ServerConfigV2, TlsConfig};
use localsend::http::state::ClientInfo;
use localsend::model::discovery::PROTOCOL_VERSION_V2;

use crate::bridge::adapter::server::adapt_server_event;
use crate::bridge::engine::apply_actions;
use crate::bridge::event::{send_event, BridgeError, BridgeEvent};
use crate::bridge::identity;
use crate::bridge::state::{BridgeState, PendingRequest, WebSendFile};
use crate::bridge::throttle::ProgressThrottle;

/// 从 BridgeState 克隆 event_tx（注入 spawned task）。
fn clone_event_tx(state: &Mutex<BridgeState>) -> Option<mpsc::Sender<BridgeEvent>> {
    lock(&state).event_tx.clone()
}

// ── 服务器生命周期 ────────────────────────────────────────────────────

/// 启动服务器。
///
/// - 重复调用返回 `BridgeError::AlreadyRunning`
/// - 返回实际绑定端口
/// - 注入 event_tx，spawn 事件循环并存储 JoinHandle
pub async fn start_server(
    state: Arc<Mutex<BridgeState>>,
    port: u16,
    use_https: bool,
    verify_checksums: bool,
    pin: Option<String>,
    mut web_config: Option<WebConfig>,
    external_show_token: Option<String>,
) -> Result<u16, BridgeError> {
    {
        let mut s = lock(&state);
        // handle 空窗期（入口到注册完成）用 starting 标志互斥，
        // 防止并发 start_server 双启动（检查与写回之间存在 TOCTOU 窗口）
        if s.server_handle.is_some() || s.server_starting {
            // 守卫命中说明存在并发注册（调用方时序问题），warn 级便于暴露
            log::warn!("start_server: already running (guard hit)");
            return Err(BridgeError::AlreadyRunning);
        }
        s.server_starting = true;
    }

    let event_tx = clone_event_tx(&state);
    let (event_tx_server, mut event_rx) = mpsc::channel::<ServerEventV2>(64);
    let (stop_tx, stop_rx) = oneshot::channel::<()>();

    // 为 InternalConfig 展示令牌（重试间保持稳定）
    let show_token = external_show_token.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    {
        let mut s = lock(&state);
        s.show_token = Some(show_token.clone());
    }

    let (alias, device_type, device_model, fingerprint, cert_pem, key_pem) = {
        let s = lock(&state);
        (
            s.local_alias.clone(),
            s.device_type.clone(),
            s.device_model.clone(),
            s.fingerprint.clone(),
            s.cert_pem.clone(),
            s.key_pem.clone(),
        )
    };

    // 尝试启动服务器，若端口仍被占用则重试一次。
    // web_config 不可 Clone（包含 mpsc::Sender），因此仅无 web_config 时重试。
    let mut current_stop_tx = stop_tx;
    let mut current_stop_rx = stop_rx;
    let mut handle: Option<server::ServerHandle> = None;
    let mut internal_event_rx_option: Option<mpsc::Receiver<InternalEvent>> = None;

    let max_attempts = if web_config.is_some() { 1 } else { 2 };

    for attempt in 0..max_attempts {
        let cfg = ServerConfigV2 {
            pin: pin.clone(),
            verify_checksums,
            event_tx: event_tx_server.clone(),
        };

        let (internal_event_tx, internal_event_rx) = mpsc::channel::<InternalEvent>(16);
        if attempt == 0 {
            internal_event_rx_option = Some(internal_event_rx);
        }
        let internal_config = InternalConfig {
            show_token: show_token.clone(),
            event_tx: internal_event_tx,
        };

        let tls = if use_https {
            Some(TlsConfig {
                cert: cert_pem.clone(),
                private_key: key_pem.clone(),
            })
        } else {
            None
        };
        let info = ClientInfo {
            alias: alias.clone(),
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: Some(device_model.clone()),
            device_type: Some(device_type.clone()),
            token: fingerprint.clone(),
        };

        match server::start_with_port(
            port,
            tls,
            info,
            Some(internal_config),
            Some(cfg),
            web_config.take(),
            current_stop_rx,
        )
        .await
        {
            Ok(h) => {
                handle = Some(h);
                break;
            }
            Err(e) => {
                let err_msg = format!("{e:#}");
                if attempt == 0
                    && (err_msg.contains("in use")
                        || err_msg.contains("Address already")
                        || err_msg.contains("EADDRINUSE"))
                {
                    log::warn!(
                        "Port {} still in use (err: {}), waiting 500ms and retrying...",
                        port,
                        err_msg
                    );
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    let (retry_tx, retry_rx) = oneshot::channel::<()>();
                    current_stop_tx = retry_tx;
                    current_stop_rx = retry_rx;
                } else {
                    // 非 in-use 失败打出真实错误文本（此前会被静默吞掉）
                    log::warn!(
                        "start_server: attempt {} failed on port {}: {}",
                        attempt,
                        port,
                        err_msg
                    );
                    lock(&state).server_starting = false;
                    return Err(BridgeError::Upstream(anyhow::anyhow!("{e:#}")));
                }
            }
        }
    }

    let handle = match handle {
        Some(h) => h,
        None => {
            lock(&state).server_starting = false;
            return Err(BridgeError::Upstream(anyhow::anyhow!(
                "Server failed to start after retry"
            )));
        }
    };

    let local_port = handle
        .local_addresses()
        .first()
        .map(|a| a.port())
        .unwrap_or(port);

    let save_dir = lock(&state).save_dir.clone();

    // 服务器事件循环：收 ServerEventV2 → 适配 → apply 状态变更 → 发送桥接事件
    let state_for_spawn = state.clone();
    let event_loop = {
        let event_tx = event_tx.clone();
        tokio::spawn(async move {
            while let Some(event) = event_rx.recv().await {
                let (bridge_event, actions) = adapt_server_event(event);
                {
                    let mut s = lock(&state_for_spawn);
                    apply_actions(&mut s, actions);
                }

                // 会话终态（结束/中止/对方取消）后关闭该会话未消费的预注册 fd，
                // 避免已注册但从未开始上传的文件描述符泄漏
                if let Some(ev) = &bridge_event {
                    let terminal_sid: Option<String> = match ev {
                        BridgeEvent::SessionEnd { session_id, .. }
                        | BridgeEvent::PrepareUploadAborted { session_id }
                        | BridgeEvent::CancelReceived { session_id, .. } => {
                            Some(session_id.clone())
                        }
                        _ => None,
                    };
                    if let Some(sid) = terminal_sid {
                        close_unconsumed_recv_fds(&state_for_spawn, &sid);
                    }
                }

                // FileUpload 自动保存应答（使用 state 中存储的 target_tx）
                if let Some(BridgeEvent::FileUpload {
                    session_id,
                    file_id,
                    file_name,
                    size,
                }) = &bridge_event
                {
                    handle_file_upload(
                        &state_for_spawn,
                        session_id,
                        file_id,
                        file_name,
                        *size,
                        &save_dir,
                        &event_tx,
                    )
                    .await;
                }

                if let Some(ev) = bridge_event {
                    send_event(&event_tx, ev).await;
                }
            }
            log::debug!("Server event loop task ended");
        })
    };

    // InternalEvent 监听（show 端点）
    if let Some(mut internal_event_rx) = internal_event_rx_option {
        tokio::spawn(async move {
            while let Some(event) = internal_event_rx.recv().await {
                match event {
                    InternalEvent::Show { args } => {
                        log::debug!("Show requested with args: {:?}", args);
                    }
                }
            }
        });
    }

    {
        let mut s = lock(&state);
        s.server_handle = Some(handle);
        s.server_starting = false;
        s.server_stop_tx = Some(current_stop_tx);
        s.server_event_task = Some(event_loop);
        s.local_port = local_port;
        s.use_https = use_https;
        s.verify_checksums = verify_checksums;
        s.receive_pin = pin.clone();
        // 注册成功打点：排查端口占用/意外注册类问题的关键线索
        log::debug!("server registered on port {}", local_port);
    }

    // 推送 ServerStarted 事件（关键事件）
    send_event(&event_tx, BridgeEvent::ServerStarted { port: local_port }).await;

    Ok(local_port)
}

/// 接收方向进度推送节流器。
///
/// 上游写盘每约 16KiB 产生一条进度消息，高速接收时每秒可达上千条，
/// 全量转发会跨 FFI 洪泛 UI 线程。与发送方向（client.rs 上传进度闭包）
/// 的既有 20ms 惯例对齐：距上次推送不足 20ms 的消息直接跳过、不缓存
/// 不补偿。进度事件为尽力送达语义，节流不反向阻塞写盘路径。
/// 处理 FileUpload：取回存储的 target_tx，应答直写目标（预注册 fd 优先），跟踪进度。
///
/// 目标选择规则（无沙箱回退）：
/// - ArkTS 已在 respondTransfer 前经 register_recv_file_fd 预注册该文件 → `Fd` 直写最终位置；
/// - 未预注册（异常时序/目标准备失败被拒绝的会话残留）→ 丢弃 target_tx 使上传失败，不落沙箱。
async fn handle_file_upload(
    state: &Mutex<BridgeState>,
    session_id: &str,
    file_id: &str,
    file_name: &str,
    size: u64,
    save_dir: &str,
    event_tx: &Option<mpsc::Sender<BridgeEvent>>,
) {
    let target_tx = {
        let mut s = lock(&state);
        s.pending_file_uploads
            .remove(&(session_id.to_string(), file_id.to_string()))
    };
    let Some(target_tx) = target_tx else {
        log::warn!(
            "FileUpload: no pending target for session={} file={}",
            session_id,
            file_id
        );
        return;
    };

    let (progress_tx, mut progress_rx) = mpsc::channel::<u64>(16);
    let (result_tx, result_rx) = oneshot::channel();

    // ohos/android 生产路径：只消费预注册 fd 直写目标，无沙箱回退；
    // 其他宿主（如桌面测试构建）不存在 Fd 变体，保留原沙箱 Path 行为以便编译与单测。
    #[cfg(any(target_os = "android", all(target_os = "linux", target_env = "ohos")))]
    let target = {
        // 消费预注册的直写目标（若存在）；未注册则丢弃 target_tx 让本次上传失败
        let registered = lock(state)
            .recv_target_fds
            .remove(&(session_id.to_string(), file_id.to_string()));
        match registered {
            Some(recv_fd) => {
                log::debug!(
                    "recv: fd-direct save: session={} file={} path={}",
                    session_id,
                    file_id,
                    recv_fd.path
                );
                // fd 所有权随 from_raw_fd 移交，写入完成后关闭
                localsend::http::server::common::save::FileUploadTarget::Fd {
                    fd: recv_fd.fd,
                    result_tx,
                    progress_tx: Some(progress_tx),
                }
            }
            None => {
                log::warn!(
                    "FileUpload: no registered target fd for session={} file={}, failing (no sandbox fallback)",
                    session_id,
                    file_id
                );
                drop(target_tx);
                return;
            }
        }
    };
    #[cfg(not(any(target_os = "android", all(target_os = "linux", target_env = "ohos"))))]
    let target = {
        // 非 ohos/android 宿主：fallback 到沙箱路径写入（仅测试/桌面构建使用）
        let save_path = format!("{}{}", save_dir, file_name);
        log::debug!("recv: save_path={}", save_path);
        localsend::http::server::common::save::FileUploadTarget::Path {
            path: std::path::PathBuf::from(&save_path),
            result_tx,
            progress_tx: Some(progress_tx),
        }
    };
    let _ = target_tx.send(target);

    let sid = session_id.to_string();
    let fid = file_id.to_string();
    let total = size;
    // ohos 生产路径不使用 file_name/save_dir（非 ohos 宿主回退分支使用），
    // 此处兜底避免未使用警告
    let _ = file_name;
    let _ = save_dir;

    // 流式进度：钳制上报不超过 total-1，100% 仅由结果跟踪任务上报
    let event_tx_progress = event_tx.clone();
    let sid_progress = sid.clone();
    let fid_progress = fid.clone();
    tokio::spawn(async move {
        let mut last_reported: u64 = 0;
        // 20ms 时间节流：距上次推送不足 20ms 的消息跳过；
        // 100% 完成事件由下方结果跟踪任务发送，不受此节流限制
        let mut throttle = ProgressThrottle::new();
        while let Some(bytes_written) = progress_rx.recv().await {
            let reported = if total > 0 {
                bytes_written.min(total - 1)
            } else {
                0
            };
            last_reported = reported;
            if !throttle.allow(std::time::Instant::now()) {
                continue;
            }
            let progress = if total > 0 {
                reported as f64 / total as f64
            } else {
                0.0
            };
            send_event(
                &event_tx_progress,
                BridgeEvent::UploadProgress {
                    session_id: sid_progress.clone(),
                    file_id: fid_progress.clone(),
                    direction: "recv".to_string(),
                    progress,
                    speed: 0.0,
                },
            )
            .await;
        }
        log::debug!(
            "recv-progress: Stream ended: session={} file={} last={}/{}",
            sid_progress,
            fid_progress,
            last_reported,
            total
        );
    });

    // 结果跟踪：写入成功才上报 100%
    let event_tx_result = event_tx.clone();
    tokio::spawn(async move {
        match result_rx.await {
            Ok(Ok(())) => {
                send_event(
                    &event_tx_result,
                    BridgeEvent::UploadProgress {
                        session_id: sid.clone(),
                        file_id: fid.clone(),
                        direction: "recv".to_string(),
                        progress: 1.0,
                        speed: 0.0,
                    },
                )
                .await;
                log::debug!("recv-progress: File saved OK: session={} file={}", sid, fid);
            }
            Ok(Err(err)) => {
                log::error!(
                    "recv-progress: File save failed: session={} file={} error={}",
                    sid,
                    fid,
                    err
                );
            }
            Err(_) => {
                log::debug!(
                    "recv-progress: File upload cancelled: session={} file={}",
                    sid,
                    fid
                );
            }
        }
    });
}

/// 停止服务器（幂等，abort 事件循环 task）。
///
/// - 未启动时调用幂等返回 Ok
/// - 清理所有中间状态
pub fn stop_server(state: &Mutex<BridgeState>) {
    let mut s = lock(&state);
    if let Some(stop_tx) = s.server_stop_tx.take() {
        let _ = stop_tx.send(());
    }
    if let Some(task) = s.server_event_task.take() {
        task.abort();
    }
    s.server_handle.take();
    s.show_token.take();
    for (_key, cancel) in s.active_transfers.drain() {
        cancel.cancel();
    }
    lock(&s.pending_requests).clear();
    s.pending_decisions.clear();
    s.web_send_event_tx.take();
    clear_web_send_files(&s.web_send_files);
    s.web_download_decisions.clear();
    s.pending_file_uploads.clear();
    s.pending_file_downloads.clear();
    // 服务器停止：关闭所有尚未消费的接收直写 fd
    for (_key, recv_fd) in s.recv_target_fds.drain() {
        let _ = unsafe { std::fs::File::from_raw_fd(recv_fd.fd) };
    }
    s.session_peers.clear();
}

// ── 传输决策（两阶段交互）────────────────────────────────────────────

/// 接受传输——取出 pending decision 并发送 Accept 决策。
///
/// 会话已被清理（用户未响应时对方取消）时返回 `BridgeError::SessionExpired`。
pub fn accept_transfer(
    state: &Mutex<BridgeState>,
    session_id: &str,
    file_ids: &[String],
) -> Result<(), BridgeError> {
    let mut s = lock(&state);
    if let Some(sender) = s.pending_decisions.remove(session_id) {
        let file_set: std::collections::HashSet<String> = file_ids.iter().cloned().collect();
        let decision = localsend::http::server::v2::PrepareUploadDecisionV2::Accept(file_set);
        let _ = sender.send(decision);
        lock(&s.pending_requests).retain(|r| r.session_id != session_id);
        Ok(())
    } else {
        Err(BridgeError::SessionExpired(session_id.to_string()))
    }
}

/// 拒绝传输——取出 pending decision 并发送 Decline 决策。
///
/// 会话已被清理时返回 `BridgeError::SessionExpired`。
pub fn decline_transfer(state: &Mutex<BridgeState>, session_id: &str) -> Result<(), BridgeError> {
    let mut s = lock(&state);
    if let Some(sender) = s.pending_decisions.remove(session_id) {
        let decision = localsend::http::server::v2::PrepareUploadDecisionV2::Decline;
        let _ = sender.send(decision);
        lock(&s.pending_requests).retain(|r| r.session_id != session_id);
        Ok(())
    } else {
        Err(BridgeError::SessionExpired(session_id.to_string()))
    }
}

/// 预注册接收文件的直写目标 fd（ArkTS 侧在 respondTransfer 前逐文件调用）。
///
/// 注册后 fd 所有权移交 Rust：FileUpload 到达时经 `from_raw_fd` 消费并关闭；
/// 若该文件最终未上传（拒绝/会话取消/发送方中止），由会话终态清理关闭。
pub fn register_recv_file_fd(
    state: &Mutex<BridgeState>,
    session_id: &str,
    file_id: &str,
    fd: i32,
    path: &str,
) -> Result<(), BridgeError> {
    let mut s = lock(&state);
    s.recv_target_fds.insert(
        (session_id.to_string(), file_id.to_string()),
        crate::bridge::state::RecvTargetFd {
            fd,
            path: path.to_string(),
        },
    );
    Ok(())
}

/// 关闭某个会话名下尚未被消费的预注册 fd（会话终态清理用）。
///
/// 已消费（handle_file_upload 取出并写入）的 fd 由写入完成路径关闭，
/// 此处只处理遗留项，避免 fd 泄漏。
pub fn close_unconsumed_recv_fds(state: &Mutex<BridgeState>, session_id: &str) {
    let keys: Vec<(String, String)> = {
        let s = lock(&state);
        s.recv_target_fds
            .keys()
            .filter(|(sid, _)| sid == session_id)
            .cloned()
            .collect()
    };
    for key in keys {
        let entry = lock(&state).recv_target_fds.remove(&key);
        if let Some(recv_fd) = entry {
            // 将裸 fd 包装进 File 并立即释放即完成关闭（不依赖 libc/nix）
            let _ = unsafe { std::fs::File::from_raw_fd(recv_fd.fd) };
        }
    }
}

/// 丢弃某个会话已注册但尚未开始上传的直写目标（respond 失败/回滚时由 ArkTS 调用）。
///
/// 与 [`close_unconsumed_recv_fds`] 等价，提供独立 NAPI 入口供回滚路径使用。
pub fn discard_recv_file_fds(state: &Mutex<BridgeState>, session_id: &str) {
    close_unconsumed_recv_fds(state, session_id);
}

/// 清空 Web 分享内容源表（停止/重建分享时调用）。
///
/// fd 所有权归 ArkTS：原始 fd 由 ArkTS 持有并在分享结束时关闭，
/// 此处仅清空映射，不关闭 fd。
fn clear_web_send_files(web_send_files: &Arc<Mutex<HashMap<String, WebSendFile>>>) {
    lock(&web_send_files).clear();
}

// ── 服务器状态与查询 ────────────────────────────────────────────────────

/// 获取服务器状态 JSON（{"running", "activeSession", "fingerprint"}）。
pub fn get_server_status(state: &BridgeState) -> String {
    let running = state.server_handle.is_some();
    let fingerprint = state.fingerprint.clone();
    let active_session = {
        let reqs = lock(&state.pending_requests);
        reqs.first().map(|r| r.session_id.clone())
    };

    json!({
        "running": running,
        "activeSession": active_session,
        "fingerprint": fingerprint,
    })
    .to_string()
}

/// 获取当前发送会话 ID。
pub fn get_current_send_session_id(state: &BridgeState) -> String {
    let sid = lock(&state.current_send_session_id);
    sid.clone()
}

/// 轮询待处理请求。
pub fn poll_pending_requests(state: &BridgeState) -> Vec<PendingRequest> {
    let reqs = lock(&state.pending_requests);
    reqs.clone()
}

/// 取消本地会话——触发取消令牌、清理中间状态、向发送方发 /cancel（尽力而为）。
pub fn cancel_local_session(state: &Mutex<BridgeState>, session_id: &str) {
    let event_tx;
    let peer_info = {
        let s = lock(&state);
        if let Some(cancel) = s.active_transfers.get(session_id) {
            cancel.cancel();
        }
        drop(s);

        let mut s = lock(&state);
        s.active_transfers.remove(session_id);
        lock(&s.pending_requests).retain(|r| r.session_id != session_id);
        s.pending_decisions.remove(session_id);

        // 清理待处理文件上传目标——使未开始的上传返回 500
        let keys_to_remove: Vec<(String, String)> = s
            .pending_file_uploads
            .keys()
            .filter(|(sid, _)| sid == session_id)
            .cloned()
            .collect();
        for k in keys_to_remove {
            s.pending_file_uploads.remove(&k);
        }

        let peer = s.session_peers.remove(session_id);
        let cert_pem = s.cert_pem.clone();
        let key_pem = s.key_pem.clone();
        event_tx = s.event_tx.clone();

        peer.map(|(ip, port, protocol)| (ip, port, protocol, cert_pem, key_pem))
    };

    // 关键事件（会话终态）尽力投递：channel 满时转后台阻塞发送，
    // 不能像进度事件那样静默丢弃，否则 UI 永远收不到取消终态
    if let Some(event_tx) = event_tx {
        let sid = session_id.to_string();
        let ev = BridgeEvent::SessionEnd {
            session_id: sid.clone(),
            reason: crate::bridge::event::SessionEndReason::Cancelled,
        };
        if event_tx.try_send(ev).is_err() {
            std::thread::spawn(move || {
                let rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build();
                if let Ok(rt) = rt {
                    rt.block_on(async {
                        let _ = event_tx
                            .send(BridgeEvent::SessionEnd {
                                session_id: sid,
                                reason: crate::bridge::event::SessionEndReason::Cancelled,
                            })
                            .await;
                    });
                }
            });
        }
    }

    // 取消会话：关闭该会话已注册但未消费的直写 fd
    close_unconsumed_recv_fds(state, session_id);

    // 向发送方发送 /cancel 请求（尽力而为）
    if let Some((peer_ip, peer_port, peer_protocol, cert_pem, key_pem)) = peer_info {
        let sid = session_id.to_string();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build();
            if let Ok(rt) = rt {
                rt.block_on(async {
                    let client = match localsend::http::client::LsHttpClient::new(
                        &key_pem,
                        &cert_pem,
                        localsend::http::client::LsHttpClientVersion::V2,
                        None,
                        Some(std::time::Duration::from_secs(5)),
                    ) {
                        Ok(c) => c,
                        Err(_) => return,
                    };
                    let _ = client
                        .cancel(peer_protocol, &peer_ip, peer_port, &sid)
                        .await;
                    log::debug!(
                        "cancel-local-session: Sent /cancel to sender {}:{}, session={}",
                        peer_ip,
                        peer_port,
                        sid
                    );
                });
            }
        });
    }
}

// ── 高级 API ──────────────────────────────────────────────────────────

/// 从 JSON 配置创建服务器（含身份初始化）。
pub async fn create_server(
    state: Arc<Mutex<BridgeState>>,
    config_json: &str,
) -> Result<String, BridgeError> {
    let config: Value = serde_json::from_str(config_json)
        .map_err(|e| BridgeError::InvalidArgument(format!("配置 JSON 解析失败: {e}")))?;

    let alias = config["alias"].as_str().unwrap_or("HarmonyOS").to_string();
    let device_type_str = config["deviceType"].as_str().unwrap_or("mobile");
    let device_model = config["deviceModel"]
        .as_str()
        .unwrap_or("HarmonyOS")
        .to_string();
    let port = config["port"].as_u64().unwrap_or(53317) as u16;
    let use_https = config["useHttps"].as_bool().unwrap_or(true);
    let pin = config["pin"].as_str().map(|s| s.to_string());
    let verify_checksums = config["verifyChecksums"].as_bool().unwrap_or(true);
    let save_dir = config["saveDir"].as_str().unwrap_or("").to_string();
    let show_token = config["showToken"].as_str().map(|s| s.to_string());

    log::debug!(
        "create_server: alias={} use_https={} port={} save_dir={}",
        alias,
        use_https,
        port,
        save_dir
    );

    identity::init_with_persisted_identity(
        &state,
        alias.clone(),
        identity::parse_device_type(device_type_str),
        &save_dir,
    )?;

    {
        let mut s = lock(&state);
        if !device_model.is_empty() {
            s.device_model = device_model;
        }
        // 先设置 save_dir/verify_checksums 再启动服务器：
        // 服务器事件循环在启动时捕获 state.save_dir（handle_file_upload
        // 拼接保存路径），若在 start_server 之后才设置会捕获到空值，
        // 导致接收文件写入错误路径。
        if !save_dir.ends_with('/') {
            s.save_dir = save_dir + "/";
        } else {
            s.save_dir = save_dir;
        }
        s.verify_checksums = verify_checksums;
    }

    start_server(
        state.clone(),
        port,
        use_https,
        verify_checksums,
        pin,
        None,
        show_token,
    )
    .await?;

    let (fingerprint, actual_port) = {
        let s = lock(&state);
        (s.fingerprint.clone(), s.local_port)
    };

    Ok(json!({
        "fingerprint": fingerprint,
        "port": actual_port,
    })
    .to_string())
}

/// 获取当前协议类型（根据 use_https 状态）。
pub fn current_protocol(state: &BridgeState) -> localsend::model::discovery::ProtocolType {
    if state.use_https {
        localsend::model::discovery::ProtocolType::Https
    } else {
        localsend::model::discovery::ProtocolType::Http
    }
}

/// 将协议字符串解析为 ProtocolType。
pub fn parse_protocol(s: &str) -> localsend::model::discovery::ProtocolType {
    identity::parse_protocol(s)
}

/// 将设备类型字符串解析为 DeviceType。
pub fn parse_device_type(s: &str) -> localsend::model::discovery::DeviceType {
    identity::parse_device_type(s)
}

// ── WebSend（统一纳入 adapter + engine）──────────────────────────────

/// 以 `pread` 显式偏移从 fd 副本读取全部内容并推入 channel（Web 分享下载用）。
///
/// - 独立 task 运行：每次下载一份副本、一条 channel，互不影响，
///   支持同一文件的重复与并发下载
/// - 使用 `pread` 而非顺序 read：副本与原始 fd 共享文件 offset，
///   顺序 read 在重复/并发下载时会读到空内容或交错数据
/// - 读毕（EOF/错误/接收端关闭）经 `from_raw_fd` 包装后 drop 关闭副本
///
/// dup/pread 为 POSIX 标准 API，普通 Linux（开发机）同样编译此分支，
/// 使 host 集成测试能覆盖与真机一致的 fd 内容提供路径。
#[cfg(any(target_os = "android", target_os = "linux"))]
fn spawn_fd_content_task(
    fd: libc::c_int,
    content_tx: oneshot::Sender<localsend::model::transfer::FileContent>,
) {
    const READ_BUF_SIZE: usize = 512 * 1024;
    const CHANNEL_CAPACITY: usize = 16;

    let (tx, rx) = mpsc::channel::<bytes::Bytes>(CHANNEL_CAPACITY);
    tokio::task::spawn_blocking(move || {
        let mut offset: libc::off_t = 0;
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
            if n <= 0 {
                break;
            }
            let n = n as usize;
            offset += n as libc::off_t;
            buf.truncate(n);
            if tx.blocking_send(buf.into()).is_err() {
                break;
            }
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
                                spawn_fd_content_task(dup_fd, content_tx);
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
    let mut s = lock(&state);
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
    let mut s = lock(&state);
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
    let mut s = lock(&state);

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

/// 将待处理的文件上传标记为失败（丢弃发送端导致 500 响应）。
pub fn fail_file_upload(
    state: &Mutex<BridgeState>,
    session_id: &str,
    file_id: &str,
) -> Result<(), BridgeError> {
    let mut s = lock(&state);

    if s.pending_file_uploads
        .remove(&(session_id.to_string(), file_id.to_string()))
        .is_some()
    {
        return Ok(());
    }

    if let Some(cancel) = s.active_transfers.get(session_id) {
        cancel.cancel();
    }

    Err(BridgeError::SessionExpired(format!(
        "无待处理的文件上传 session={}, file={}",
        session_id, file_id
    )))
}

/// 启动 WebSend 上传模式服务器。
///
/// 停止当前服务器，以 upload WebConfig 重启，返回实际端口。
pub async fn start_web_upload(state: Arc<Mutex<BridgeState>>) -> Result<u16, BridgeError> {
    log::debug!("start_web_upload: stopping current server");
    // 停止当前服务器并等待端口释放
    let wait_stopped_fut = {
        let mut s = lock(&state);
        log::debug!(
            "start_web_upload: stopping old server (stop_tx={}, handle={})",
            s.server_stop_tx.is_some(),
            s.server_handle.is_some()
        );
        if let Some(stop_tx) = s.server_stop_tx.take() {
            let _ = stop_tx.send(());
        }
        if let Some(task) = s.server_event_task.take() {
            task.abort();
        }
        s.server_handle.take()
    };

    if let Some(handle) = wait_stopped_fut {
        handle.wait_stopped().await;
        log::debug!("start_web_upload: old server fully stopped");
    }

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
    let wait_stopped_fut = {
        let mut s = lock(&state);
        log::debug!(
            "create_share_link: stopping old server (stop_tx={}, handle={})",
            s.server_stop_tx.is_some(),
            s.server_handle.is_some()
        );
        if let Some(stop_tx) = s.server_stop_tx.take() {
            let _ = stop_tx.send(());
        }
        if let Some(task) = s.server_event_task.take() {
            task.abort();
        }
        s.server_handle.take()
    };

    let (port, use_https, verify_checksums) = {
        let s = lock(&state);
        (s.local_port, s.use_https, s.verify_checksums)
    };

    if let Some(handle) = wait_stopped_fut {
        handle.wait_stopped().await;
        log::debug!("create_share_link: old server fully stopped");
    }

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
    {
        let s = lock(&state);
        *lock(&s.share_link_info) = Some(crate::bridge::state::ShareLinkState {
            url: url.clone(),
            port: actual_port,
            session_id: session_id.clone(),
        });
    }

    Ok(json!({
        "url": url,
        "port": actual_port,
        "sessionId": session_id,
    })
    .to_string())
}

/// 停止分享服务器（清除 WebSend 状态并以正常模式重启服务器）。
pub async fn stop_share_server(state: Arc<Mutex<BridgeState>>) {
    let wait_stopped_fut = {
        let mut s = lock(&state);
        log::debug!(
            "stop_share_server: stopping old server (stop_tx={}, handle={})",
            s.server_stop_tx.is_some(),
            s.server_handle.is_some()
        );
        if let Some(stop_tx) = s.server_stop_tx.take() {
            let _ = stop_tx.send(());
        }
        if let Some(task) = s.server_event_task.take() {
            task.abort();
        }
        if let Some(task) = s.web_send_event_task.take() {
            task.abort();
        }
        let handle = s.server_handle.take();
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
        *lock(&s.share_link_info) = None;
        handle
    };

    let (port, use_https, verify_checksums, current_pin) = {
        let s = lock(&state);
        (
            s.local_port,
            s.use_https,
            s.verify_checksums,
            s.receive_pin.clone(),
        )
    };

    if let Some(handle) = wait_stopped_fut {
        handle.wait_stopped().await;
        log::debug!("stop_share_server: old server fully stopped");
    }

    let _ = start_server(
        state.clone(),
        port,
        use_https,
        verify_checksums,
        current_pin,
        None,
        None,
    )
    .await;
}

// ── 单元测试 ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bridge::state::{PendingFile, RecvTargetFd};

    fn new_state_with_event_tx() -> (Arc<Mutex<BridgeState>>, mpsc::Receiver<BridgeEvent>) {
        let (event_tx, event_rx) = mpsc::channel::<BridgeEvent>(64);
        let state = Arc::new(Mutex::new(BridgeState::new()));
        lock(&state).event_tx = Some(event_tx);
        (state, event_rx)
    }

    #[test]
    fn test_start_server_twice_returns_already_running() {
        // 真实启动验证（port 0 → OS 分配，零外部网络依赖），
        // 覆盖 start_server 重复启动 → AlreadyRunning 的幂等语义。
        let state = Arc::new(Mutex::new(BridgeState::new()));
        identity::init_with_persisted_identity(
            &state,
            "HandySend-Test".to_string(),
            localsend::model::discovery::DeviceType::Mobile,
            "",
        )
        .unwrap();

        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let port = start_server(state.clone(), 0, false, true, None, None, None)
                .await
                .expect("首次启动失败");
            assert!(port > 0);

            // 重复启动 → AlreadyRunning
            let err = start_server(state.clone(), 0, false, true, None, None, None)
                .await
                .expect_err("重复启动应返回 AlreadyRunning");
            assert!(matches!(err, BridgeError::AlreadyRunning));

            // stop 后重新启动成功（快速 stop→start 无残留）
            stop_server(&state);
            let port2 = start_server(state.clone(), 0, false, true, None, None, None)
                .await
                .expect("stop 后重新启动失败");
            assert!(port2 > 0);

            stop_server(&state);
        });
    }

    #[test]
    fn test_stop_server_idempotent() {
        let state = Mutex::new(BridgeState::new());
        // 未启动时调用 stop_server 应幂等返回 Ok（不 panic）
        stop_server(&state);
        stop_server(&state);
    }

    #[test]
    fn test_stop_server_clears_state() {
        let mut bs = BridgeState::new();
        let cancel = tokio_util::sync::CancellationToken::new();
        bs.active_transfers
            .insert("transfer-1".to_string(), cancel.clone());
        let state = Mutex::new(bs);

        stop_server(&state);

        let s = state.lock().unwrap();
        assert!(s.server_handle.is_none());
        assert!(s.server_stop_tx.is_none());
        assert!(s.server_event_task.is_none());
        assert!(s.active_transfers.is_empty());
        assert!(s.pending_decisions.is_empty());
        assert!(cancel.is_cancelled(), "活跃传输的取消令牌应被触发");
    }

    #[test]
    fn test_accept_transfer_no_pending_decision_returns_session_expired() {
        let state = Mutex::new(BridgeState::new());
        let result = accept_transfer(&state, "nonexistent", &[]);
        assert!(matches!(result, Err(BridgeError::SessionExpired(_))));
    }

    #[test]
    fn test_decline_transfer_no_pending_decision_returns_session_expired() {
        let state = Mutex::new(BridgeState::new());
        let result = decline_transfer(&state, "nonexistent");
        assert!(matches!(result, Err(BridgeError::SessionExpired(_))));
    }

    #[test]
    fn test_accept_transfer_with_pending_decision() {
        let state = Mutex::new(BridgeState::new());
        let (tx, mut rx) = oneshot::channel();
        {
            let mut s = state.lock().unwrap();
            s.pending_decisions.insert("session-1".to_string(), tx);
        }

        let result = accept_transfer(&state, "session-1", &["file-a".to_string()]);
        assert!(result.is_ok());

        let decision = rx.try_recv().unwrap();
        match decision {
            localsend::http::server::v2::PrepareUploadDecisionV2::Accept(ids) => {
                assert!(ids.contains("file-a"));
            }
            localsend::http::server::v2::PrepareUploadDecisionV2::Decline => panic!("期望 Accept"),
        }
    }

    #[test]
    fn test_decline_transfer_with_pending_decision() {
        let state = Mutex::new(BridgeState::new());
        let (tx, mut rx) = oneshot::channel();
        {
            let mut s = state.lock().unwrap();
            s.pending_decisions.insert("session-2".to_string(), tx);
        }

        let result = decline_transfer(&state, "session-2");
        assert!(result.is_ok());

        let decision = rx.try_recv().unwrap();
        assert!(matches!(
            decision,
            localsend::http::server::v2::PrepareUploadDecisionV2::Decline
        ));
    }

    #[test]
    fn test_accept_transfer_removes_pending_request() {
        let state = Mutex::new(BridgeState::new());
        let (tx, _rx) = oneshot::channel();
        {
            let mut s = state.lock().unwrap();
            s.pending_decisions.insert("s".to_string(), tx);
            s.pending_requests.lock().unwrap().push(PendingRequest {
                session_id: "s".to_string(),
                sender_alias: "A".to_string(),
                sender_fingerprint: "fp".to_string(),
                sender_protocol: "https".to_string(),
                files: vec![PendingFile {
                    file_id: "f1".to_string(),
                    file_name: "a.txt".to_string(),
                    size: 10,
                    file_type: "text/plain".to_string(),
                    preview: None,
                    sha256: None,
                }],
            });
        }

        accept_transfer(&state, "s", &[]).unwrap();
        assert!(state
            .lock()
            .unwrap()
            .pending_requests
            .lock()
            .unwrap()
            .is_empty());
        assert!(state.lock().unwrap().pending_decisions.is_empty());
    }

    #[test]
    fn test_get_server_status_not_running() {
        let state = BridgeState::new();
        let status = get_server_status(&state);
        let parsed: Value = serde_json::from_str(&status).unwrap();
        assert!(!parsed["running"].as_bool().unwrap());
        assert_eq!(parsed["fingerprint"], "");
    }

    #[test]
    fn test_get_current_send_session_id_default() {
        let state = BridgeState::new();
        let sid = get_current_send_session_id(&state);
        assert!(sid.is_empty());
    }

    #[test]
    fn test_poll_pending_requests_empty() {
        let state = BridgeState::new();
        assert!(poll_pending_requests(&state).is_empty());
    }

    #[test]
    fn test_cancel_local_session_cleans_state() {
        let (state, mut event_rx) = new_state_with_event_tx();
        {
            let mut s = state.lock().unwrap();
            s.session_peers.insert(
                "s".to_string(),
                (
                    "192.168.1.5".to_string(),
                    53317,
                    localsend::model::discovery::ProtocolType::Https,
                ),
            );
        }

        cancel_local_session(&state, "s");

        let s = state.lock().unwrap();
        assert!(s.session_peers.is_empty());
        // 应推送 SessionEnd(Cancelled) 事件
        let ev = event_rx.try_recv().unwrap();
        assert!(matches!(
            ev,
            BridgeEvent::SessionEnd {
                reason: crate::bridge::event::SessionEndReason::Cancelled,
                ..
            }
        ));
    }

    #[test]
    fn test_cancel_local_session_nonexistent_no_panic() {
        let state = Mutex::new(BridgeState::new());
        cancel_local_session(&state, "nonexistent");
    }

    #[test]
    fn test_create_server_invalid_json() {
        let state = Arc::new(Mutex::new(BridgeState::new()));
        let result = tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(async { create_server(state, "not json").await });
        assert!(result.is_err());
    }

    #[test]
    fn test_current_protocol_https_default() {
        let state = BridgeState::new();
        assert_eq!(
            current_protocol(&state),
            localsend::model::discovery::ProtocolType::Https
        );
    }

    #[test]
    fn test_current_protocol_http_when_disabled() {
        let mut state = BridgeState::new();
        state.use_https = false;
        assert_eq!(
            current_protocol(&state),
            localsend::model::discovery::ProtocolType::Http
        );
    }

    // ── WebSend 决策测试（T042）──

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
    fn test_fail_file_upload_drops_pending() {
        let state = Mutex::new(BridgeState::new());
        let (tx, mut rx) =
            oneshot::channel::<localsend::http::server::common::save::FileUploadTarget>();
        {
            let mut s = state.lock().unwrap();
            s.pending_file_uploads
                .insert(("s-1".to_string(), "f-1".to_string()), tx);
        }
        fail_file_upload(&state, "s-1", "f-1").unwrap();
        assert!(rx.try_recv().is_err());
        assert!(state.lock().unwrap().pending_file_uploads.is_empty());
    }

    #[test]
    fn test_fail_file_upload_no_pending_errors() {
        let state = Mutex::new(BridgeState::new());
        let result = fail_file_upload(&state, "s-none", "f-none");
        assert!(result.is_err());
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

    // ── 接收进度节流测试 ──
    // 纯节流逻辑测试见 bridge/throttle.rs；此处保留跨层集成测试

    #[test]
    #[cfg(any(target_os = "android", all(target_os = "linux", target_env = "ohos")))]
    fn test_handle_file_upload_throttles_progress_but_not_completion() {
        // 行为级验证（真实时钟）：高频进度消息下跨层中间进度事件数
        // 远小于消息数；结果跟踪任务的 100% 完成事件不经过节流器、
        // 必然送达
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (state, mut event_rx) = new_state_with_event_tx();
            let (target_tx, target_rx) = oneshot::channel();
            {
                let mut s = state.lock().unwrap();
                s.pending_file_uploads
                    .insert(("s-th".to_string(), "f-th".to_string()), target_tx);
            }

            // 注册一个真实文件的写 fd（直写目标），驱动 handle_file_upload 走 Fd 分支
            let tmp_path =
                std::env::temp_dir().join(format!("handysend-throttle-{}.bin", std::process::id()));
            let tmp_file = std::fs::File::create(&tmp_path).unwrap();
            let raw_fd = std::os::fd::IntoRawFd::into_raw_fd(tmp_file);
            {
                let mut s = state.lock().unwrap();
                s.recv_target_fds.insert(
                    ("s-th".to_string(), "f-th".to_string()),
                    RecvTargetFd {
                        fd: raw_fd,
                        path: tmp_path.display().to_string(),
                    },
                );
            }

            // 不解构 Fd 写盘，仅驱动 handle_file_upload 创建的
            // progress/result 通道，模拟上游写盘行为
            let save_dir = format!("{}/handysend-throttle/", std::env::temp_dir().display());
            let event_tx = state.lock().unwrap().event_tx.clone();
            handle_file_upload(
                &state, "s-th", "f-th", "th.bin", 3_200_000, &save_dir, &event_tx,
            )
            .await;

            let target = target_rx.await.expect("应收到 FileUploadTarget");
            let localsend::http::server::common::save::FileUploadTarget::Fd {
                fd,
                result_tx,
                progress_tx,
                ..
            } = target
            else {
                panic!("应为 Fd 变体");
            };
            // 测试不再写盘：回收 fd（包装进 File 即关闭）并清理临时文件
            let _ = unsafe { std::fs::File::from_raw_fd(fd) };
            let _ = std::fs::remove_file(&tmp_path);
            let progress_tx = progress_tx.expect("应携带进度通道");

            // 高频进度消息（send().await 保证全部送达消费端）
            const MSG_COUNT: u64 = 200;
            for i in 1..=MSG_COUNT {
                let bytes = i * 16 * 1024;
                progress_tx.send(bytes).await.expect("进度消息应被消费");
            }
            drop(progress_tx);
            result_tx.send(Ok(())).expect("应报告写盘成功");

            // 收集事件直到 100% 完成事件到达
            let mut intermediate = 0usize;
            let mut completion = false;
            while let Some(ev) = event_rx.recv().await {
                match ev {
                    BridgeEvent::UploadProgress { progress, .. } => {
                        if progress >= 1.0 {
                            completion = true;
                            break;
                        } else {
                            intermediate += 1;
                        }
                    }
                    _ => {}
                }
            }
            assert!(completion, "100% 完成事件必须不受节流限制、及时送达");
            assert!(
                intermediate * 10 < MSG_COUNT as usize,
                "高频进度消息下推送的中间进度事件应远小于消息数，实际 {intermediate}/{MSG_COUNT}"
            );
        });
    }

    #[test]
    fn test_register_and_discard_recv_fd() {
        // fd 注册表生命周期：注册后存在，discard 时关闭未消费 fd 并清空
        let state = Mutex::new(BridgeState::new());
        let tmp = std::env::temp_dir().join(format!("handysend-fdreg-{}.bin", std::process::id()));
        let file = std::fs::File::create(&tmp).unwrap();
        let raw_fd = std::os::fd::IntoRawFd::into_raw_fd(file);
        register_recv_file_fd(&state, "s-fd", "f-fd", raw_fd, "/tmp/target.bin").unwrap();
        assert!(state
            .lock()
            .unwrap()
            .recv_target_fds
            .contains_key(&("s-fd".to_string(), "f-fd".to_string())));
        discard_recv_file_fds(&state, "s-fd");
        assert!(state.lock().unwrap().recv_target_fds.is_empty());
        let _ = std::fs::remove_file(&tmp);
    }

    #[test]
    #[cfg(any(target_os = "android", all(target_os = "linux", target_env = "ohos")))]
    fn test_handle_file_upload_without_registered_fd_fails() {
        // 未预注册直写 fd 的文件上传应按失败处理：target_tx 被丢弃、无 Path 落盘回退
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (state, _event_rx) = new_state_with_event_tx();
            let (target_tx, mut target_rx) = oneshot::channel();
            {
                let mut s = state.lock().unwrap();
                s.pending_file_uploads
                    .insert(("s-nofd".to_string(), "f-nofd".to_string()), target_tx);
            }
            let event_tx = state.lock().unwrap().event_tx.clone();
            handle_file_upload(
                &state,
                "s-nofd",
                "f-nofd",
                "x.bin",
                100,
                "/tmp/unused/",
                &event_tx,
            )
            .await;
            // 未注册 fd：target_tx 应被丢弃（无 Path/Fd 应答），上传方收 RecvError
            let result = target_rx.try_recv();
            assert!(result.is_err(), "应无 FileUploadTarget 应答（失败路径）");
        });
    }
}
