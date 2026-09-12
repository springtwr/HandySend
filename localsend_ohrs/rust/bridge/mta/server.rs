//! MTA 发送端 TLS 服务器。
//!
//! 基于 `tokio-rustls` + `hyper`，单个 TLS 端口同时承载：
//! - `GET /websocket`（带 `Upgrade: websocket`）：升级后交由 [`crate::bridge::mta::ws`] 执行状态机；
//! - `GET /download?taskId=<id>`：以 `application/zip` + `Content-Length` 流式响应并上报进度。
//!
//! 服务端证书在启动时用核心 `rcgen` 运行时生成（不落盘、不入库）。

use std::convert::Infallible;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use tokio::io::AsyncRead;
use tokio::net::TcpListener;
use tokio::sync::watch;
use tokio_rustls::rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio_rustls::rustls::ServerConfig;
use tokio_rustls::TlsAcceptor;

use crate::bridge::event::{send_event, BridgeEvent};
use crate::bridge::mta::{ws, DownloadPhase, MtaContext};

/// 下载流分块大小（字节）
const CHUNK_SIZE: usize = 64 * 1024;
/// 进度上报节流间隔
const PROGRESS_INTERVAL: Duration = Duration::from_millis(200);

/// 响应体类型（统一装箱，便于在同一路由返回空体与流式体）。
type BoxBody = http_body_util::combinators::BoxBody<Bytes, std::io::Error>;

/// 用运行时生成的自签名证书构造 rustls 服务端配置。
pub fn build_tls_config() -> anyhow::Result<Arc<ServerConfig>> {
    let cert = localsend::crypto::cert::generate_self_signed()?;
    let certs: Vec<CertificateDer<'static>> = {
        let mut reader = std::io::BufReader::new(cert.certificate_pem.as_bytes());
        rustls_pemfile::certs(&mut reader)?
            .into_iter()
            .map(CertificateDer::from)
            .collect()
    };
    if certs.is_empty() {
        anyhow::bail!("自签名证书为空");
    }
    let key: PrivateKeyDer<'static> = {
        let mut reader = std::io::BufReader::new(cert.private_key_pem.as_bytes());
        let mut keys = rustls_pemfile::pkcs8_private_keys(&mut reader)?;
        if keys.is_empty() {
            anyhow::bail!("自签名证书未包含 PKCS#8 私钥");
        }
        PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(keys.remove(0)))
    };
    let config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)?;
    Ok(Arc::new(config))
}

/// 接受 TLS 连接并逐个升级为 HTTP/1 连接（支持 upgrade），直到任务被 abort
/// 或取消令牌触发。
pub async fn run_server(
    listener: TcpListener,
    tls_config: Arc<ServerConfig>,
    ctx: Arc<MtaContext>,
) {
    let acceptor = TlsAcceptor::from(tls_config);
    loop {
        let (stream, peer) = tokio::select! {
            biased;
            _ = ctx.cancel.cancelled() => {
                log::debug!("MTA accept 循环收到取消，退出");
                return;
            }
            accepted = listener.accept() => match accepted {
                Ok(pair) => pair,
                Err(e) => {
                    log::warn!("MTA accept 失败: {e}");
                    continue;
                }
            },
        };
        log::info!("MTA 接收到连接: {peer}");
        let acceptor = acceptor.clone();
        let conn_ctx = Arc::clone(&ctx);
        tokio::spawn(async move {
            // TLS 握手 + 连接服务全程感知取消：stop_server 时连接
            // future 被 drop，底层 TLS/TCP 流随之关闭，下载立即截断
            tokio::select! {
                biased;
                _ = conn_ctx.cancel.cancelled() => {
                    log::debug!("MTA 连接任务收到取消，关闭连接 peer={peer}");
                }
                result = async {
                    match acceptor.accept(stream).await {
                        Ok(tls_stream) => serve_connection(tls_stream, conn_ctx.clone()).await,
                        Err(e) => log::warn!("MTA TLS 握手失败 ({peer}): {e}"),
                    }
                } => result,
            }
        });
    }
}

/// 在单个 TLS 连接上提供 HTTP/1 服务（开启 upgrade 支持）。
async fn serve_connection<S>(stream: S, ctx: Arc<MtaContext>)
where
    S: AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    let io = TokioIo::new(stream);
    let service = service_fn(move |req: Request<Incoming>| {
        let req_ctx = Arc::clone(&ctx);
        async move { handle(req, req_ctx).await }
    });
    if let Err(e) = hyper::server::conn::http1::Builder::new()
        .serve_connection(io, service)
        .with_upgrades()
        .await
    {
        // 对端/网络拆除时，优雅关闭底层 IO 可能失败（hyper Kind::Shutdown），
        // 属正常收尾而非传输故障，仅以 trace 记录，避免发送页日志出现误导性错误。
        if e.is_shutdown() {
            log::trace!("MTA 连接收尾: {e}");
        } else {
            log::debug!("MTA 连接结束: {e}");
        }
    }
}

/// 路由分发。
async fn handle(
    req: Request<Incoming>,
    ctx: Arc<MtaContext>,
) -> Result<Response<BoxBody>, Infallible> {
    let path = req.uri().path();
    match path {
        "/websocket" => Ok(handle_websocket(req, ctx).await),
        "/download" => Ok(handle_download(req, ctx).await),
        _ => Ok(text_response(StatusCode::NOT_FOUND, "未知路径")),
    }
}

/// `/websocket`：完成握手响应并把升级后的连接交给 WS 状态机。
async fn handle_websocket(req: Request<Incoming>, ctx: Arc<MtaContext>) -> Response<BoxBody> {
    let key = match req.headers().get("sec-websocket-key") {
        Some(value) => value.as_bytes().to_vec(),
        None => return text_response(StatusCode::BAD_REQUEST, "缺少 Sec-WebSocket-Key"),
    };
    let accept = tokio_tungstenite::tungstenite::handshake::derive_accept_key(&key);
    let upgrade_ctx = Arc::clone(&ctx);
    tokio::spawn(async move {
        match hyper::upgrade::on(req).await {
            Ok(upgraded) => {
                log::debug!("MTA WS 升级成功");
                let io = TokioIo::new(upgraded);
                ws::run_ws(io, upgrade_ctx).await;
            }
            Err(e) => {
                send_event(
                    &upgrade_ctx.event_tx,
                    BridgeEvent::MtaSendFailed {
                        reason: format!("WebSocket 升级失败: {e}"),
                    },
                )
                .await;
            }
        }
    });
    Response::builder()
        .status(StatusCode::SWITCHING_PROTOCOLS)
        .header("connection", "Upgrade")
        .header("upgrade", "websocket")
        .header("sec-websocket-accept", accept)
        .body(empty_body())
        .unwrap_or_else(|_| text_response(StatusCode::INTERNAL_SERVER_ERROR, "构造升级响应失败"))
}

/// `/download?taskId=`：校验任务并构造流式下载响应。
async fn handle_download(req: Request<Incoming>, ctx: Arc<MtaContext>) -> Response<BoxBody> {
    let task_id = query_param(req.uri().query().unwrap_or(""), "taskId");
    build_download_response(&ctx, task_id.as_deref()).await
}

/// 构造下载响应。
///
/// 一次性下载使用 `Connection: close`：让对端在接收完 ZIP 后立即关闭连接，
/// 避免 keep-alive 连接在服务器/群组拆除时被强制中断、触发 shutdown 错误。
async fn build_download_response(ctx: &MtaContext, task_id: Option<&str>) -> Response<BoxBody> {
    if task_id != Some(ctx.task_id.as_str()) {
        log::warn!(
            "MTA 下载 taskId 不匹配 期望={} 实际={:?}",
            ctx.task_id,
            task_id
        );
        return text_response(StatusCode::NOT_FOUND, "taskId 不匹配");
    }
    let file = match tokio::fs::File::open(&ctx.zip_path).await {
        Ok(file) => file,
        Err(e) => {
            log::warn!("MTA 下载打开 ZIP 失败 path={:?}: {e}", ctx.zip_path);
            return text_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("打开 ZIP 失败: {e}"),
            );
        }
    };
    // 通知 WS 状态机下载已开始
    log::debug!(
        "MTA 下载开始 taskId={} zip字节={} 文件数={}",
        ctx.task_id,
        ctx.zip_size,
        ctx.file_count
    );
    ctx.phase_tx.send_replace(DownloadPhase::Started);
    let body = ZipFileBody {
        file,
        remaining: ctx.zip_size,
        sent: 0,
        total: ctx.zip_size,
        event_tx: ctx.event_tx.clone(),
        phase_tx: ctx.phase_tx.clone(),
        buffer: vec![0u8; CHUNK_SIZE],
        last_report: Instant::now(),
        logged_milestone: 0,
    };
    Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "application/zip")
        .header("content-length", ctx.zip_size.to_string())
        .header("connection", "close")
        .header(
            "content-disposition",
            format!("attachment; filename=\"{}\"", ctx.file_name),
        )
        .body(body.boxed())
        .unwrap_or_else(|_| text_response(StatusCode::INTERNAL_SERVER_ERROR, "构造下载响应失败"))
}

/// ZIP 流式响应体：按块读取预打包文件，节流上报进度并在结束时置下载阶段为 Completed。
struct ZipFileBody {
    file: tokio::fs::File,
    remaining: u64,
    sent: u64,
    total: u64,
    event_tx: Option<tokio::sync::mpsc::Sender<BridgeEvent>>,
    phase_tx: watch::Sender<DownloadPhase>,
    buffer: Vec<u8>,
    last_report: Instant,
    /// 已记录的下载进度里程碑（25% 步进），避免逐块刷屏
    logged_milestone: u32,
}

impl http_body::Body for ZipFileBody {
    type Data = Bytes;
    type Error = std::io::Error;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<http_body::Frame<Bytes>, std::io::Error>>> {
        let this = self.get_mut();
        if this.remaining == 0 {
            return Poll::Ready(None);
        }
        let want = std::cmp::min(this.remaining, this.buffer.len() as u64) as usize;
        let read = {
            let mut read_buf = tokio::io::ReadBuf::new(&mut this.buffer[..want]);
            match Pin::new(&mut this.file).poll_read(cx, &mut read_buf) {
                Poll::Ready(Ok(())) => read_buf.filled().len(),
                Poll::Ready(Err(e)) => return Poll::Ready(Some(Err(e))),
                Poll::Pending => return Poll::Pending,
            }
        };
        if read == 0 {
            // 文件提前结束：视为读取完成，避免 body 挂起
            log::warn!(
                "MTA 下载文件提前结束 sent={} total={}",
                this.sent,
                this.total
            );
            this.remaining = 0;
            this.phase_tx.send_replace(DownloadPhase::Completed);
            return Poll::Ready(None);
        }
        this.remaining -= read as u64;
        this.sent += read as u64;
        let chunk = Bytes::copy_from_slice(&this.buffer[..read]);
        let finished = this.remaining == 0;
        let now = Instant::now();
        if finished || now.duration_since(this.last_report) >= PROGRESS_INTERVAL {
            this.last_report = now;
            let percent = if this.total > 0 {
                this.sent as f64 / this.total as f64 * 100.0
            } else {
                0.0
            };
            if let Some(tx) = &this.event_tx {
                let _ = tx.try_send(BridgeEvent::MtaSendProgress {
                    sent_bytes: this.sent,
                    total_bytes: this.total,
                    percent,
                });
            }
            // 仅按 25% 里程碑记录进度，禁止逐块输出
            let milestone = (percent / 25.0) as u32 * 25;
            if finished || milestone > this.logged_milestone {
                this.logged_milestone = milestone;
                log::debug!(
                    "MTA 下载进度 sent={} total={} percent={:.1}",
                    this.sent,
                    this.total,
                    percent
                );
            }
            if finished {
                log::debug!("MTA 下载完成 sent={} total={}", this.sent, this.total);
                this.phase_tx.send_replace(DownloadPhase::Completed);
            }
        }
        Poll::Ready(Some(Ok(http_body::Frame::data(chunk))))
    }

    fn size_hint(&self) -> http_body::SizeHint {
        http_body::SizeHint::with_exact(self.total)
    }
}

/// 构造空体响应。
fn empty_body() -> BoxBody {
    full_body(Bytes::new())
}

/// 构造指定字节的完整响应体。
fn full_body(bytes: Bytes) -> BoxBody {
    Full::new(bytes).map_err(std::io::Error::other).boxed()
}

/// 文本响应。
fn text_response(status: StatusCode, message: &str) -> Response<BoxBody> {
    Response::builder()
        .status(status)
        .header("content-type", "text/plain; charset=utf-8")
        .body(full_body(Bytes::from(message.to_string())))
        .unwrap_or_else(|_| Response::new(empty_body()))
}

/// 解析查询参数（第一个匹配项）。
fn query_param(query: &str, key: &str) -> Option<String> {
    for pair in query.split('&') {
        if let Some((k, v)) = pair.split_once('=') {
            if k == key {
                return Some(v.to_string());
            }
        } else if pair == key {
            return Some(String::new());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicBool;

    /// 构造一个最小可用的 MtaContext（ZIP 为已写入指定内容的临时文件）。
    fn test_ctx(task_id: &str, zip_path: std::path::PathBuf, zip_size: u64) -> MtaContext {
        let (phase_tx, _phase_rx) = watch::channel(DownloadPhase::Idle);
        MtaContext {
            task_id: task_id.to_string(),
            sender_id: "s1".to_string(),
            sender_name: "tester".to_string(),
            zip_path,
            zip_size,
            file_name: "a.zip".to_string(),
            mime_type: "application/zip".to_string(),
            file_count: 1,
            total_size: zip_size,
            text_content: None,
            sender_brand_id: None,
            sender_brand: None,
            event_tx: None,
            phase_tx,
            ws_connected: AtomicBool::new(false),
            cancel: tokio_util::sync::CancellationToken::new(),
        }
    }

    /// 下载响应应显式声明 `Connection: close`，使对端收完后立即关闭连接。
    #[tokio::test]
    async fn download_response_sets_connection_close() {
        let dir = std::env::temp_dir().join(format!("mta_server_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let zip_path = dir.join("out.zip");
        let bytes = b"PK\x03\x04zip-bytes";
        std::fs::write(&zip_path, bytes).unwrap();
        let ctx = test_ctx("task-1", zip_path, bytes.len() as u64);

        let resp = build_download_response(&ctx, Some("task-1")).await;
        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(resp.headers().get("connection").unwrap(), "close");
        assert_eq!(
            resp.headers().get("content-length").unwrap(),
            bytes.len().to_string().as_str()
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// taskId 不匹配时应返回 404，且不打开 ZIP。
    #[tokio::test]
    async fn download_response_rejects_mismatched_task() {
        let dir = std::env::temp_dir().join(format!("mta_server_test_bad_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let zip_path = dir.join("out.zip");
        std::fs::write(&zip_path, b"x").unwrap();
        let ctx = test_ctx("task-1", zip_path, 1);

        let resp = build_download_response(&ctx, Some("other")).await;
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
