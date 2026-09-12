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
    if let Err(reason) = wait_ack(&mut ws, "versionNegotiation", VERSION_ACK_TIMEOUT).await {
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
    if let Err(reason) = wait_ack(&mut ws, "sendRequest", SEND_REQUEST_ACK_TIMEOUT).await {
        fail_ws(&ctx, reason).await;
        return;
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
    // 订阅时下载可能已开始（对端在 ack 后立即发起 /download），先补发一次开始事件
    let mut download_started = *phase_rx.borrow() != DownloadPhase::Idle;
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
                    Some(Ok(Message::Text(text))) => {
                        if let Some(message) = protocol::parse_message(text.as_str()) {
                            log::debug!(
                                "MTA 收到 WS 报文 {}:{}:{} payload={}",
                                message.msg_type,
                                message.id,
                                message.name,
                                message.payload
                            );
                            // 对任意动作类消息回送确认：部分厂商接收端会等待确认后才收尾，
                            // 等不到会把已完成的传输记为中断。发送失败不改变状态判定。
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
                                handle_status(&ctx, &message.payload).await;
                                // 收到 status 后不抢先关闭：对端通常还会自行收尾，
                                // 若发送端先断开，对端会在「完成」之后又记为「中断」。
                                wait_peer_close(&mut ws, STATUS_CLOSE_GRACE).await;
                                let _ = ws.close(None).await;
                                return;
                            }
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => {
                        fail_ws(&ctx, "对端关闭了连接".to_string()).await;
                        return;
                    }
                    Some(Err(e)) => {
                        fail_ws(&ctx, format!("WS 读取错误: {e}")).await;
                        return;
                    }
                    _ => {}
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

/// 等待指定 name 的 ack 消息（type 不限定），超时或连接异常返回错误文本。
async fn wait_ack<S>(
    ws: &mut WebSocketStream<S>,
    name: &str,
    timeout: Duration,
) -> Result<(), String>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        tokio::select! {
            maybe = ws.next() => {
                match maybe {
                    Some(Ok(Message::Text(text))) => {
                        if let Some(message) = protocol::parse_message(text.as_str()) {
                            log::debug!(
                                "MTA 收到 WS 报文 {}:{}:{} payload={}",
                                message.msg_type,
                                message.id,
                                message.name,
                                message.payload
                            );
                            if message.name == name {
                                return Ok(());
                            }
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => return Err("对端关闭了连接".to_string()),
                    Some(Err(e)) => return Err(format!("WS 读取错误: {e}")),
                    _ => {}
                }
            }
            _ = tokio::time::sleep_until(deadline) => {
                return Err(format!("等待 {name} 确认超时"));
            }
        }
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
