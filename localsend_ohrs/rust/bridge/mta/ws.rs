//! MTA WS 连接上的发送端状态机。
//!
//! 对端（接收端）连入本机 TLS 端口并升级为 WebSocket 后，发送端主动：
//! 发 `versionNegotiation` → 等 ack → 发 `sendRequest` → 等 ack →
//! 等 `/download` 开始与完成 → 等对端 `status`（type=1 成功 / type=3 拒绝）。
//! 任一步超时或连接中断即发 `MtaSendFailed`。进度由下载 body 直接上报，本处不重复。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::protocol::Role;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;

use crate::bridge::event::{send_event, BridgeEvent};
use crate::bridge::mta::protocol::{self, SendRequestPayload, StatusKind};
use crate::bridge::mta::{DownloadPhase, MtaContext};

/// versionNegotiation 消息 ID
const VERSION_ID: u32 = 0;
/// sendRequest 消息 ID
const SEND_REQUEST_ID: u32 = 1;
/// 等待版本协商 ack 超时
const VERSION_ACK_TIMEOUT: Duration = Duration::from_secs(10);
/// 等待 sendRequest ack 超时
const SEND_REQUEST_ACK_TIMEOUT: Duration = Duration::from_secs(10);
/// 等待对端传输状态超时（含下载耗时）
const STATUS_WAIT_TIMEOUT: Duration = Duration::from_secs(180);
/// 发送完成后等待对端关闭连接的宽限时间（避免抢先断开被对端判定为中断）
const STATUS_CLOSE_GRACE: Duration = Duration::from_secs(2);
/// 对端中途取消（下载连接断开）时对外发射的可读失败原因
const PEER_ABORT_REASON: &str = "对端已取消（下载连接中断）";

/// WS 连接占位守卫：持有期间 `ws_connected` 为 true，run_ws 结束
/// （正常收尾 / 出错 / 取消 / panic，即任何 return 与 unwinding）时
/// 由 Drop 复位，允许对端断开后重连。
struct WsSlotGuard<'a>(&'a AtomicBool);

impl Drop for WsSlotGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

/// 在已升级的 WS 连接上执行 MTA 发送端状态机。
pub async fn run_ws<S>(stream: S, ctx: Arc<MtaContext>)
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    if !ctx.mark_ws_connected() {
        log::warn!("MTA 已存在 WS 连接，忽略重复连接");
        return;
    }
    let _slot = WsSlotGuard(&ctx.ws_connected);
    let mut ws = WebSocketStream::from_raw_socket(stream, Role::Server, None).await;
    // 升级握手期间服务器可能已被停止：立即退出，不再发起协商
    if ctx.cancel.is_cancelled() {
        log::info!("MTA WS 升级完成但服务器已取消，直接关闭");
        let _ = ws.close(None).await;
        return;
    }
    send_event(&ctx.event_tx, BridgeEvent::MtaWsConnected).await;

    // 1) 版本协商
    let negotiation = protocol::build_message(
        "action",
        VERSION_ID,
        "versionNegotiation",
        Some(&protocol::version_negotiation_payload()),
    );
    log::debug!(
        "MTA 发送版本协商 type=action id={VERSION_ID} name=versionNegotiation version={}",
        protocol::PROTOCOL_VERSION
    );
    if let Err(e) = ws.send(Message::text(negotiation)).await {
        fail_ws(&ctx, format!("发送版本协商失败: {e}")).await;
        return;
    }
    let version_ack = match wait_ack(&ctx, &mut ws, "versionNegotiation", VERSION_ACK_TIMEOUT).await
    {
        AckOutcome::Ack(payload) => payload,
        AckOutcome::StatusTerminated => {
            // 等待确认期间即收到对端 status：终态事件已发射，按收尾语义关闭连接后结束
            wait_peer_close(&mut ws, STATUS_CLOSE_GRACE).await;
            let _ = ws.close(None).await;
            return;
        }
        AckOutcome::Failed(reason) => {
            fail_ws(&ctx, reason).await;
            return;
        }
    };
    // 校验对端选定版本（宽松策略：ack 未携带 version 时视为兼容，与接收端一致）
    if let Some(reason) = check_version_ack(version_ack.as_deref()) {
        fail_ws(&ctx, reason).await;
        return;
    }
    send_event(
        &ctx.event_tx,
        BridgeEvent::MtaVersionNegotiated {
            version: protocol::PROTOCOL_VERSION,
        },
    )
    .await;

    // 2) 发送 sendRequest
    let payload = SendRequestPayload {
        task_id: ctx.task_id.clone(),
        id: ctx.task_id.clone(),
        sender_id: ctx.sender_id.clone(),
        sender_name: ctx.sender_name.clone(),
        file_name: ctx.file_name.clone(),
        mime_type: ctx.mime_type.clone(),
        file_count: ctx.file_count,
        total_size: ctx.total_size,
        cat_share_text: ctx.text_content.clone(),
        sender_brand_id: ctx.sender_brand_id,
        sender_brand: ctx.sender_brand.clone(),
    };
    let request = protocol::build_message(
        "action",
        SEND_REQUEST_ID,
        "sendRequest",
        Some(&protocol::send_request_json(&payload)),
    );
    log::debug!(
        "MTA 发送接收请求 type=action id={SEND_REQUEST_ID} name=sendRequest taskId={} fileCount={} totalSize={}",
        ctx.task_id,
        ctx.file_count,
        ctx.total_size
    );
    if let Err(e) = ws.send(Message::text(request)).await {
        fail_ws(&ctx, format!("发送 sendRequest 失败: {e}")).await;
        return;
    }
    match wait_ack(&ctx, &mut ws, "sendRequest", SEND_REQUEST_ACK_TIMEOUT).await {
        AckOutcome::Ack(_) => {}
        AckOutcome::StatusTerminated => {
            // 确认到达前先收到拒绝/成功状态：终态已定，不再等待下载与后续状态
            wait_peer_close(&mut ws, STATUS_CLOSE_GRACE).await;
            let _ = ws.close(None).await;
            return;
        }
        AckOutcome::Failed(reason) => {
            fail_ws(&ctx, reason).await;
            return;
        }
    }
    send_event(
        &ctx.event_tx,
        BridgeEvent::MtaSendRequestSent {
            task_id: ctx.task_id.clone(),
        },
    )
    .await;

    // 3) 等待下载开始/完成与对端 status
    let mut phase_rx = ctx.phase_tx.subscribe();
    // 订阅时下载可能已开始（对端在 ack 后立即发起 /download）；也可能已因对端断开而中止
    let initial_phase = *phase_rx.borrow();
    if initial_phase == DownloadPhase::PeerAborted {
        fail_ws(&ctx, PEER_ABORT_REASON.to_string()).await;
        return;
    }
    let mut download_started = initial_phase != DownloadPhase::Idle;
    if download_started {
        send_event(
            &ctx.event_tx,
            BridgeEvent::MtaDownloadStarted {
                task_id: ctx.task_id.clone(),
            },
        )
        .await;
    }
    let deadline = tokio::time::Instant::now() + STATUS_WAIT_TIMEOUT;
    loop {
        tokio::select! {
            biased;
            // 本地停止服务器：直接关闭 WS，不发送失败事件
            // （取消是本地主动行为，UI 已退出传输页）
            _ = ctx.cancel.cancelled() => {
                log::info!("MTA WS 状态机收到取消，关闭连接");
                let _ = ws.close(None).await;
                return;
            }
            changed = phase_rx.changed() => {
                if changed.is_err() {
                    break;
                }
                let phase = *phase_rx.borrow();
                if phase == DownloadPhase::PeerAborted {
                    // 对端中途取消：下载连接已断开，立即终结发送状态机，
                    // 不再等待不会到来的 status（避免空等到状态等待超时）
                    fail_ws(&ctx, PEER_ABORT_REASON.to_string()).await;
                    return;
                }
                if phase == DownloadPhase::Started && !download_started {
                    download_started = true;
                    send_event(
                        &ctx.event_tx,
                        BridgeEvent::MtaDownloadStarted { task_id: ctx.task_id.clone() },
                    ).await;
                }
            }
            maybe = ws.next() => {
                match maybe {
                    Some(Ok(frame)) => {
                        match frame_text(&frame) {
                            Some(text) => {
                                if let TextOutcome::Status =
                                    dispatch_text(&ctx, &mut ws, text.as_str(), None).await
                                {
                                    // 收到 status 后不抢先关闭：对端通常还会自行收尾，
                                    // 若发送端先断开，对端会在「完成」之后又记为「中断」。
                                    wait_peer_close(&mut ws, STATUS_CLOSE_GRACE).await;
                                    let _ = ws.close(None).await;
                                    return;
                                }
                            }
                            None => {
                                if matches!(frame, Message::Close(_)) {
                                    fail_ws(&ctx, "对端关闭了连接".to_string()).await;
                                    return;
                                }
                                // 非文本帧（Ping/Pong/其它）原样忽略；记日志以免"收到却无痕"
                                log::debug!("MTA 收到非文本 WS 帧，忽略");
                            }
                        }
                    }
                    None => {
                        fail_ws(&ctx, "对端关闭了连接".to_string()).await;
                        return;
                    }
                    Some(Err(e)) => {
                        fail_ws(&ctx, format!("WS 读取错误: {e}")).await;
                        return;
                    }
                }
            }
            _ = tokio::time::sleep_until(deadline) => {
                fail_ws(&ctx, "等待对端传输状态超时".to_string()).await;
                return;
            }
        }
    }
    fail_ws(&ctx, "对端连接已结束但未回送状态".to_string()).await;
}

/// 处理对端 status 消息并发射完成/拒绝/失败事件。
async fn handle_status(ctx: &MtaContext, payload: &str) {
    let kind = protocol::classify_status(payload);
    log::debug!(
        "MTA 对端状态 type={:?} reason={}",
        kind,
        protocol::status_reason(payload)
    );
    match kind {
        StatusKind::Ok => {
            send_event(
                &ctx.event_tx,
                BridgeEvent::MtaSendCompleted {
                    task_id: ctx.task_id.clone(),
                },
            )
            .await;
        }
        StatusKind::Refused => {
            let raw = protocol::status_reason(payload);
            let reason = if raw.is_empty() {
                "对方拒绝".to_string()
            } else {
                raw
            };
            send_event(&ctx.event_tx, BridgeEvent::MtaSendRejected { reason }).await;
        }
        StatusKind::Other => {
            send_event(
                &ctx.event_tx,
                BridgeEvent::MtaSendFailed {
                    reason: format!("对端返回未知状态: {payload}"),
                },
            )
            .await;
        }
    }
}

/// [`wait_ack`] 的等待结果。
enum AckOutcome {
    /// 收到匹配 name 的确认报文（payload 可能为空串）
    Ack(Option<String>),
    /// 等待期间收到对端 status 并已发射终态事件：调用方应立即收尾，不再推进状态机
    StatusTerminated,
    /// 等待失败（超时 / 对端关闭 / 读取错误），携带可读原因
    Failed(String),
}

/// 一条收到的文本报文经 [`dispatch_text`] 处理后的归类。
enum TextOutcome {
    /// 命中期望的确认报文，携带其 payload
    Expected(String),
    /// 收到对端 status 并已发射终态事件：调用方应立即收尾
    Status,
    /// 其它报文（已按需回 ack 或忽略）
    Other,
}

/// 取 WS 帧承载的文本：Text 原样返回；Binary 按 UTF-8 解码（少数实现以二进制帧承载文本）；
/// Close/Ping/Pong 等无文本帧返回 None。
fn frame_text(message: &Message) -> Option<String> {
    match message {
        Message::Text(text) => Some(text.as_str().to_string()),
        Message::Binary(bytes) => std::str::from_utf8(&bytes[..]).ok().map(|s| s.to_string()),
        _ => None,
    }
}

/// 处理一条收到的 WS 文本报文（确认等待与状态等待两处共用）：
/// 对任意动作类消息回送确认（部分厂商接收端等待确认后才收尾）；
/// 收到 `status` 时调用 [`handle_status`] 并返回 [`TextOutcome::Status`]；
/// 命中 `expect_name` 返回 [`TextOutcome::Expected`]；无法解析的报文记日志后按
/// [`TextOutcome::Other`] 处理——避免"收到却无痕"导致问题不可诊断。
async fn dispatch_text<S>(
    ctx: &MtaContext,
    ws: &mut WebSocketStream<S>,
    text: &str,
    expect_name: Option<&str>,
) -> TextOutcome
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let message = match protocol::parse_message(text) {
        Some(message) => message,
        None => {
            log::debug!("MTA 收到未识别的 WS 报文，忽略: {text}");
            return TextOutcome::Other;
        }
    };
    log::debug!(
        "MTA 收到 WS 报文 {}:{}:{} payload={}",
        message.msg_type,
        message.id,
        message.name,
        message.payload
    );
    if let Some(ack) = protocol::build_ack(&message) {
        log::debug!(
            "MTA 发送确认 type=ack id={} name={}",
            message.id,
            message.name
        );
        if let Err(e) = ws.send(Message::text(ack)).await {
            log::warn!("MTA 回送 ack 失败: {e}");
        }
    }
    if message.name == "status" {
        handle_status(ctx, &message.payload).await;
        return TextOutcome::Status;
    }
    if let Some(want) = expect_name {
        if message.name == want {
            return TextOutcome::Expected(message.payload);
        }
    }
    TextOutcome::Other
}

/// 等待指定 name 的 ack 消息（type 不限定）。
///
/// 等待期间到达的报文按主循环同款语义处理：对任意动作类消息回送确认（部分厂商接收端等待
/// 确认后才收尾）；一旦收到对端 `status` 即调用 [`handle_status`] 并返回
/// [`AckOutcome::StatusTerminated`]——快速拒绝时状态常与 `sendRequest` 确认几乎同时到达、
/// 先后不定，若在此处丢弃状态，发送端将空等到状态等待超时（用户长时间无反馈）。
async fn wait_ack<S>(
    ctx: &MtaContext,
    ws: &mut WebSocketStream<S>,
    name: &str,
    timeout: Duration,
) -> AckOutcome
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        tokio::select! {
            maybe = ws.next() => {
                match maybe {
                    Some(Ok(frame)) => {
                        match frame_text(&frame) {
                            Some(text) => {
                                match dispatch_text(ctx, ws, text.as_str(), Some(name)).await {
                                    TextOutcome::Expected(payload) => {
                                        return AckOutcome::Ack(Some(payload))
                                    }
                                    TextOutcome::Status => return AckOutcome::StatusTerminated,
                                    TextOutcome::Other => {}
                                }
                            }
                            None => {
                                if matches!(frame, Message::Close(_)) {
                                    return AckOutcome::Failed("对端关闭了连接".to_string());
                                }
                                log::debug!("MTA 收到非文本 WS 帧，忽略");
                            }
                        }
                    }
                    None => return AckOutcome::Failed("对端关闭了连接".to_string()),
                    Some(Err(e)) => return AckOutcome::Failed(format!("WS 读取错误: {e}")),
                }
            }
            _ = tokio::time::sleep_until(deadline) => {
                return AckOutcome::Failed(format!("等待 {name} 确认超时"));
            }
        }
    }
}

/// 校验版本协商 ack：payload 携带 version 且与本端协议版本不一致时返回错误文本。
/// 宽松策略：payload 缺失、为空、解析失败或无 version 字段均视为兼容（老对端不受影响）。
fn check_version_ack(payload: Option<&str>) -> Option<String> {
    let payload = payload?;
    if payload.is_empty() {
        return None;
    }
    #[derive(serde::Deserialize)]
    struct VersionAck {
        version: Option<i64>,
    }
    match serde_json::from_str::<VersionAck>(payload) {
        Ok(ack) => match ack.version {
            Some(v) if v != protocol::PROTOCOL_VERSION => Some(format!(
                "对端选定协议版本 {v} 与本端 {} 不兼容",
                protocol::PROTOCOL_VERSION
            )),
            _ => None,
        },
        Err(_) => None,
    }
}

/// 记录并发射发送失败事件。
async fn fail_ws(ctx: &MtaContext, reason: String) {
    log::error!("MTA 发送失败: {reason}");
    send_event(&ctx.event_tx, BridgeEvent::MtaSendFailed { reason }).await;
}

/// 等待对端关闭 WS 连接（或超时）后再返回，避免发送端抢先断开被对端判定为中断。
async fn wait_peer_close<S>(ws: &mut WebSocketStream<S>, timeout: Duration)
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        tokio::select! {
            maybe = ws.next() => {
                match maybe {
                    Some(Ok(Message::Close(_))) | None | Some(Err(_)) => return,
                    _ => {}
                }
            }
            _ = tokio::time::sleep_until(deadline) => return,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 下载因对端断开被置为 PeerAborted 时，WS 状态机须立即终结并发射发送失败事件，
    /// 不再空等到状态等待超时。以内存双向流模拟已升级的 WS 连接。
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn peer_abort_phase_terminates_ws_state_machine() {
        use crate::bridge::mta::MtaFileEntry;
        use tokio::sync::watch;

        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(32);
        let (phase_tx, _phase_rx) = watch::channel(DownloadPhase::Idle);
        let ctx = Arc::new(MtaContext {
            task_id: "t-abort".to_string(),
            sender_id: "s1".to_string(),
            sender_name: "tester".to_string(),
            files: Vec::<MtaFileEntry>::new(),
            file_name: "a.txt".to_string(),
            mime_type: "application/zip".to_string(),
            file_count: 0,
            total_size: 0,
            text_content: None,
            sender_brand_id: None,
            sender_brand: None,
            event_tx: Some(event_tx),
            phase_tx: phase_tx.clone(),
            ws_connected: AtomicBool::new(false),
            cancel: tokio_util::sync::CancellationToken::new(),
            fds_consumed: Arc::new(std::sync::Mutex::new(Vec::new())),
        });

        let (server_io, client_io) = tokio::io::duplex(32 * 1024);
        let task = tokio::spawn(async move { run_ws(server_io, ctx).await });
        let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;

        // 版本协商 → 回 ack
        let negotiation = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(negotiation.contains("versionNegotiation"));
        client
            .send(Message::text("ack:0:versionNegotiation?{\"version\":1}"))
            .await
            .unwrap();
        // sendRequest → 回空 ack
        let request = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(request.contains("sendRequest"));
        client
            .send(Message::text("ack:1:sendRequest"))
            .await
            .unwrap();

        // 对端中途取消：下载阶段转终止态
        phase_tx.send_replace(DownloadPhase::PeerAborted);

        let finished = tokio::time::timeout(Duration::from_secs(5), task).await;
        assert!(finished.is_ok(), "对端中止后 WS 状态机应立即结束");

        let mut failed_reason: Option<String> = None;
        while let Ok(event) = event_rx.try_recv() {
            if let BridgeEvent::MtaSendFailed { reason } = event {
                failed_reason = Some(reason);
            }
        }
        let reason = failed_reason.expect("应发射 MtaSendFailed");
        assert!(reason.contains("取消"), "失败原因应可读: {reason}");
    }

    /// 对端在 `sendRequest` 确认之前先回送拒绝状态（快速拒绝时确认与状态几乎同时到达、
    /// 先后不定）：状态机须立即以 `MtaSendRejected` 终结，不得丢弃状态后空等状态超时。
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn status_before_send_request_ack_terminates_with_rejection() {
        use crate::bridge::mta::MtaFileEntry;
        use tokio::sync::watch;

        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(32);
        let (phase_tx, _phase_rx) = watch::channel(DownloadPhase::Idle);
        let ctx = Arc::new(MtaContext {
            task_id: "t-reject".to_string(),
            sender_id: "s1".to_string(),
            sender_name: "tester".to_string(),
            files: Vec::<MtaFileEntry>::new(),
            file_name: "a.txt".to_string(),
            mime_type: "application/zip".to_string(),
            file_count: 0,
            total_size: 0,
            text_content: None,
            sender_brand_id: None,
            sender_brand: None,
            event_tx: Some(event_tx),
            phase_tx: phase_tx.clone(),
            ws_connected: AtomicBool::new(false),
            cancel: tokio_util::sync::CancellationToken::new(),
            fds_consumed: Arc::new(std::sync::Mutex::new(Vec::new())),
        });

        let (server_io, client_io) = tokio::io::duplex(32 * 1024);
        let task = tokio::spawn(async move { run_ws(server_io, ctx).await });
        let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;

        // 版本协商 → 回 ack
        let negotiation = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(negotiation.contains("versionNegotiation"));
        client
            .send(Message::text("ack:0:versionNegotiation?{\"version\":1}"))
            .await
            .unwrap();
        // sendRequest → 不回确认，直接回拒绝状态（模拟状态先于确认到达）
        let request = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(request.contains("sendRequest"));
        client
            .send(Message::text(
                "action:99:status?{\"taskId\":\"t-reject\",\"type\":3,\"reason\":\"user refuse\"}",
            ))
            .await
            .unwrap();

        let finished = tokio::time::timeout(Duration::from_secs(5), task).await;
        assert!(finished.is_ok(), "确认前先收到拒绝状态时应立即结束状态机");

        let mut rejected_reason: Option<String> = None;
        while let Ok(event) = event_rx.try_recv() {
            if let BridgeEvent::MtaSendRejected { reason } = event {
                rejected_reason = Some(reason);
            }
        }
        assert_eq!(rejected_reason.as_deref(), Some("user refuse"));
    }

    /// 少数实现以二进制帧承载文本：`status` 以 Binary 帧到达时也应被识别并立即以拒绝终结。
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn binary_status_frame_terminates_with_rejection() {
        use crate::bridge::mta::MtaFileEntry;
        use bytes::Bytes;
        use tokio::sync::watch;

        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(32);
        let (phase_tx, _phase_rx) = watch::channel(DownloadPhase::Idle);
        let ctx = Arc::new(MtaContext {
            task_id: "t-bin".to_string(),
            sender_id: "s1".to_string(),
            sender_name: "tester".to_string(),
            files: Vec::<MtaFileEntry>::new(),
            file_name: "a.txt".to_string(),
            mime_type: "application/zip".to_string(),
            file_count: 0,
            total_size: 0,
            text_content: None,
            sender_brand_id: None,
            sender_brand: None,
            event_tx: Some(event_tx),
            phase_tx: phase_tx.clone(),
            ws_connected: AtomicBool::new(false),
            cancel: tokio_util::sync::CancellationToken::new(),
            fds_consumed: Arc::new(std::sync::Mutex::new(Vec::new())),
        });

        let (server_io, client_io) = tokio::io::duplex(32 * 1024);
        let task = tokio::spawn(async move { run_ws(server_io, ctx).await });
        let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;

        // 版本协商 → 回 ack；sendRequest → 回空 ack
        let negotiation = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(negotiation.contains("versionNegotiation"));
        client
            .send(Message::text("ack:0:versionNegotiation?{\"version\":1}"))
            .await
            .unwrap();
        let request = client.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(request.contains("sendRequest"));
        client
            .send(Message::text("ack:1:sendRequest"))
            .await
            .unwrap();
        // 以二进制帧发送 status（载荷为文本，仅帧类型不同）
        client
            .send(Message::Binary(Bytes::from_static(
                b"action:99:status?{\"taskId\":\"t-bin\",\"type\":3,\"reason\":\"user refuse\"}",
            )))
            .await
            .unwrap();

        let finished = tokio::time::timeout(Duration::from_secs(5), task).await;
        assert!(
            finished.is_ok(),
            "二进制帧承载的拒绝状态应被识别并立即结束状态机"
        );

        let mut rejected_reason: Option<String> = None;
        while let Ok(event) = event_rx.try_recv() {
            if let BridgeEvent::MtaSendRejected { reason } = event {
                rejected_reason = Some(reason);
            }
        }
        assert_eq!(rejected_reason.as_deref(), Some("user refuse"));
    }

    // 版本协商 ack 校验：宽松兼容 + 不兼容版本拒绝
    #[test]
    fn check_version_ack_lenient() {
        assert_eq!(check_version_ack(None), None);
        assert_eq!(check_version_ack(Some("")), None);
        // 解析失败或无 version 字段视为兼容
        assert_eq!(check_version_ack(Some("not-json")), None);
        assert_eq!(check_version_ack(Some("{}")), None);
        assert_eq!(check_version_ack(Some("{\"threadLimit\":5}")), None);
    }

    #[test]
    fn check_version_ack_rejects_mismatch() {
        // 对端选定不同版本：拒绝
        assert!(check_version_ack(Some("{\"version\":2,\"threadLimit\":5}")).is_some());
        // 对端选定本端版本：通过
        assert_eq!(
            check_version_ack(Some("{\"version\":1,\"threadLimit\":5}")),
            None
        );
    }
}
