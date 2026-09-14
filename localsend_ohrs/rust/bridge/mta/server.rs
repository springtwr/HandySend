//! MTA 发送端 TLS 服务器。
//!
//! 基于 `tokio-rustls` + `hyper`，单个 TLS 端口同时承载：
//! - `GET /websocket`（带 `Upgrade: websocket`）：升级后交由 [`crate::bridge::mta::ws`] 执行状态机；
//! - `GET /download?taskId=<id>`：按文件清单流式生成 ZIP（`Stored`、chunked、无 `Content-Length`）
//!   写入响应体并上报发送进度。
//!
//! 服务端证书在启动时用核心 `rcgen` 运行时生成（不落盘、不入库）。

use std::convert::Infallible;
use std::io::Write;
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
use crate::bridge::mta::zip_stream;
use crate::bridge::mta::{ws, DownloadPhase, MtaContext};

/// 进度上报节流间隔
const PROGRESS_INTERVAL: Duration = Duration::from_millis(200);
/// 响应体分块通道容量（块）
const BODY_CHANNEL_CAPACITY: usize = 8;

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
        // 传输 WS 小控制帧时避免 Nagle 算法引入额外延迟（低风险，不改变 HTTP/协议行为）
        if let Err(e) = stream.set_nodelay(true) {
            log::debug!("MTA 设置 TCP_NODELAY 失败 ({peer}): {e}");
        }
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
/// 响应体按文件清单流式生成 ZIP（`Stored`，本地头写真实 CRC/大小），采用 chunked
/// （不设 `Content-Length`）。一次性下载使用 `Connection: close`：让对端在接收完 ZIP
/// 后立即关闭连接，避免 keep-alive 连接在服务器/群组拆除时被强制中断、触发 shutdown
/// 错误。发送 fd 在本函数首次消费（移交 `zip_stream`），后续重复下载请求不再可用。
async fn build_download_response(ctx: &MtaContext, task_id: Option<&str>) -> Response<BoxBody> {
    if task_id != Some(ctx.task_id.as_str()) {
        log::warn!(
            "MTA 下载 taskId 不匹配 期望={} 实际={:?}",
            ctx.task_id,
            task_id
        );
        return text_response(StatusCode::NOT_FOUND, "taskId 不匹配");
    }
    // 首次下载即消费全部发送 fd（所有权移交 zip_stream，读毕/失败关闭）；
    // 标记防 stop_server 重复关闭；重复下载请求将因 fd 已消费而读取失败。
    {
        let mut consumed = ctx.fds_consumed.lock().unwrap();
        for flag in consumed.iter_mut() {
            *flag = true;
        }
    }

    // 通知 WS 状态机下载已开始
    log::debug!(
        "MTA 下载开始 taskId={} 文件数={} 源总字节={}",
        ctx.task_id,
        ctx.file_count,
        ctx.total_size
    );
    ctx.phase_tx.send_replace(DownloadPhase::Started);

    let (tx, rx) =
        tokio::sync::mpsc::channel::<Result<Bytes, std::io::Error>>(BODY_CHANNEL_CAPACITY);
    // CRC 与大小已由起服预计算回填到 ctx.files，直接用于写出
    let files = ctx.files.clone();
    let reporter = ProgressReporter {
        event_tx: ctx.event_tx.clone(),
        phase_tx: ctx.phase_tx.clone(),
        task_id: ctx.task_id.clone(),
        total: ctx.total_size,
        last_report: Instant::now(),
        logged_milestone: 0,
    };
    // ZIP 生成与源文件读取为阻塞操作，走 spawn_blocking 避免占死 tokio worker
    tokio::task::spawn_blocking(move || {
        let mut writer = ChannelWriter { tx };
        let mut reporter = reporter;
        match zip_stream::write_zip_stream(&mut writer, &files, |sent| {
            reporter.on_source_bytes(sent);
        }) {
            Ok(result) => reporter.complete(result.total_size),
            Err(e) if is_peer_disconnect_error(&e) => {
                // 对端中途取消：下载连接断开导致写出失败。
                // 置下载阶段为 PeerAborted，供 WS 状态机立即终结本次发送，
                // 不再等待对端 status（否则将空等到状态等待超时）。
                log::warn!("MTA 下载被对端中止 taskId={}: {e:#}", reporter.task_id);
                reporter.peer_aborted();
            }
            Err(e) => {
                // 读取失败/取消等其他错误：不挂起，直接结束响应体（连接随之收尾）
                log::warn!("MTA 流式生成 ZIP 失败 taskId={}: {e:#}", reporter.task_id);
            }
        }
    });

    Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "application/zip")
        .header("connection", "close")
        .header(
            "content-disposition",
            format!("attachment; filename=\"{}\"", ctx.file_name),
        )
        .body(ZipStreamBody { rx }.boxed())
        .unwrap_or_else(|_| text_response(StatusCode::INTERNAL_SERVER_ERROR, "构造下载响应失败"))
}

/// 流式 ZIP 响应体：从生产者任务按块接收 ZIP 字节，长度未知（chunked）。
struct ZipStreamBody {
    rx: tokio::sync::mpsc::Receiver<Result<Bytes, std::io::Error>>,
}

impl http_body::Body for ZipStreamBody {
    type Data = Bytes;
    type Error = std::io::Error;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<http_body::Frame<Bytes>, std::io::Error>>> {
        let this = self.get_mut();
        match this.rx.poll_recv(cx) {
            Poll::Ready(Some(Ok(chunk))) => Poll::Ready(Some(Ok(http_body::Frame::data(chunk)))),
            Poll::Ready(Some(Err(e))) => Poll::Ready(Some(Err(e))),
            Poll::Ready(None) => Poll::Ready(None),
            Poll::Pending => Poll::Pending,
        }
    }

    fn size_hint(&self) -> http_body::SizeHint {
        // 长度未知 → hyper 使用分块传输编码
        http_body::SizeHint::default()
    }
}

/// 把写出的 ZIP 字节块送入响应体通道；对端断开时返回写入错误以上游停止生成。
struct ChannelWriter {
    tx: tokio::sync::mpsc::Sender<Result<Bytes, std::io::Error>>,
}

impl Write for ChannelWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let chunk = Bytes::copy_from_slice(buf);
        self.tx
            .blocking_send(Ok(chunk))
            .map_err(|_| std::io::Error::new(std::io::ErrorKind::BrokenPipe, "下载连接已关闭"))?;
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// 发送进度上报：按时间节流上报"已读源字节"，结束时无条件上报终值。
struct ProgressReporter {
    event_tx: Option<tokio::sync::mpsc::Sender<BridgeEvent>>,
    phase_tx: watch::Sender<DownloadPhase>,
    task_id: String,
    total: u64,
    last_report: Instant,
    /// 已记录的下载进度里程碑（25% 步进），避免逐块刷屏
    logged_milestone: u32,
}

impl ProgressReporter {
    /// 条目数据写出过程中回调（节流）。
    fn on_source_bytes(&mut self, sent: u64) {
        let now = Instant::now();
        if now.duration_since(self.last_report) < PROGRESS_INTERVAL {
            return;
        }
        self.last_report = now;
        self.report(sent, false);
    }

    /// 结束：无条件上报终值并置下载阶段为 Completed。
    fn complete(&mut self, sent: u64) {
        self.report(sent, true);
        self.phase_tx.send_replace(DownloadPhase::Completed);
    }

    /// 对端断开/中止下载连接：置下载阶段为 PeerAborted，供 WS 状态机立即收尾。
    fn peer_aborted(&self) {
        self.phase_tx.send_replace(DownloadPhase::PeerAborted);
    }

    /// 上报一次进度并记录 25% 里程碑。
    fn report(&mut self, sent: u64, finished: bool) {
        let percent = if self.total > 0 {
            sent as f64 / self.total as f64 * 100.0
        } else {
            0.0
        };
        if let Some(tx) = &self.event_tx {
            let _ = tx.try_send(BridgeEvent::MtaSendProgress {
                sent_bytes: sent,
                total_bytes: self.total,
                percent,
            });
        }
        let milestone = (percent / 25.0) as u32 * 25;
        if finished || milestone > self.logged_milestone {
            self.logged_milestone = milestone;
            log::debug!(
                "MTA 发送进度 taskId={} sent={} total={} percent={:.1}",
                self.task_id,
                sent,
                self.total,
                percent
            );
        }
    }
}

/// 判断流式写出错误是否源于对端断开/中止下载连接。
///
/// 写入响应体通道时对端断开会使 [`ChannelWriter::write`] 返回 `BrokenPipe`；
/// 沿错误链查找 `std::io::Error` 并比对断连类错误码，避免把源文件读取失败
/// 等本端错误也误判为对端取消。
fn is_peer_disconnect_error(err: &anyhow::Error) -> bool {
    for cause in err.chain() {
        if let Some(io_err) = cause.downcast_ref::<std::io::Error>() {
            if matches!(
                io_err.kind(),
                std::io::ErrorKind::BrokenPipe
                    | std::io::ErrorKind::ConnectionReset
                    | std::io::ErrorKind::ConnectionAborted
            ) {
                return true;
            }
        }
    }
    false
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
    use crate::bridge::mta::zip_stream::MtaFileEntry;
    use std::sync::atomic::AtomicBool;

    /// 构造一个最小可用的 MtaContext（持单条源文件清单；CRC/size 由测试直填真实值）。
    fn test_ctx(task_id: &str, mut files: Vec<MtaFileEntry>, total_size: u64) -> MtaContext {
        let (phase_tx, _phase_rx) = watch::channel(DownloadPhase::Idle);
        // 与起服预计算等价：同步算每文件 CRC/size 回填（生产路径由 start_server 完成）
        for f in files.iter_mut() {
            if let Ok(data) = std::fs::read(&f.path) {
                let mut hasher = crc32fast::Hasher::new();
                hasher.update(&data);
                f.crc32 = hasher.finalize();
                f.size_bytes = data.len() as u64;
            }
        }
        let file_count = files.len();
        MtaContext {
            task_id: task_id.to_string(),
            sender_id: "s1".to_string(),
            sender_name: "tester".to_string(),
            files,
            file_name: "a.txt".to_string(),
            mime_type: "application/zip".to_string(),
            file_count,
            total_size,
            text_content: None,
            sender_brand_id: None,
            sender_brand: None,
            event_tx: None,
            phase_tx,
            ws_connected: AtomicBool::new(false),
            cancel: tokio_util::sync::CancellationToken::new(),
            fds_consumed: Arc::new(std::sync::Mutex::new(vec![false; file_count])),
        }
    }

    /// 下载响应应为 chunked（无 Content-Length）并显式声明 Connection: close，
    /// 且响应体是可按标准读取器解开的 ZIP。
    #[tokio::test]
    async fn download_response_streams_valid_chunked_zip() {
        let dir = std::env::temp_dir().join(format!("mta_server_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let source = dir.join("a.txt");
        std::fs::write(&source, b"hello server").unwrap();
        let files = vec![MtaFileEntry {
            fd_crc: -1,
            fd_send: -1,
            path: source.to_string_lossy().to_string(),
            entry_name: "1/a.txt".into(),
            last_modified_ms: None,
            crc32: 0,
            size_bytes: 0,
        }];
        let ctx = test_ctx("task-1", files, 12);

        let resp = build_download_response(&ctx, Some("task-1")).await;
        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(resp.headers().get("connection").unwrap(), "close");
        assert_eq!(
            resp.headers().get("content-type").unwrap(),
            "application/zip"
        );
        assert!(resp.headers().get("content-length").is_none());

        let body = resp.into_body().collect().await.unwrap().to_bytes();
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(body.to_vec())).unwrap();
        assert_eq!(archive.len(), 1);
        let mut entry = archive.by_index(0).unwrap();
        assert_eq!(entry.name(), "1/a.txt");
        let mut content = String::new();
        use std::io::Read as _;
        entry.read_to_string(&mut content).unwrap();
        assert_eq!(content, "hello server");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// taskId 不匹配时应返回 404，且不启动流式生成。
    #[tokio::test]
    async fn download_response_rejects_mismatched_task() {
        let dir = std::env::temp_dir().join(format!("mta_server_test_bad_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let source = dir.join("a.txt");
        std::fs::write(&source, b"x").unwrap();
        let files = vec![MtaFileEntry {
            fd_crc: -1,
            fd_send: -1,
            path: source.to_string_lossy().to_string(),
            entry_name: "1/a.txt".into(),
            last_modified_ms: None,
            crc32: 0,
            size_bytes: 0,
        }];
        let ctx = test_ctx("task-1", files, 1);

        let resp = build_download_response(&ctx, Some("other")).await;
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 断连类 io 错误应被识别为对端断开，本端读取类错误不误判。
    #[test]
    fn detects_peer_disconnect_errors_only() {
        let broken = anyhow::Error::new(std::io::Error::new(
            std::io::ErrorKind::BrokenPipe,
            "下载连接已关闭",
        ));
        assert!(is_peer_disconnect_error(&broken));
        let reset = anyhow::Error::new(std::io::Error::new(
            std::io::ErrorKind::ConnectionReset,
            "reset",
        ));
        assert!(is_peer_disconnect_error(&reset));
        // 源文件读取失败等本端错误不应被当作对端取消
        assert!(!is_peer_disconnect_error(&anyhow::anyhow!(
            "读取待发送文件失败"
        )));
    }

    /// 对端中途放弃下载（响应体被丢弃）应把下载阶段置为 PeerAborted，
    /// 供 WS 状态机立即收尾，而不是静默等待状态超时。
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn peer_disconnect_marks_download_phase_aborted() {
        let dir = std::env::temp_dir().join(format!("mta_server_abort_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let source = dir.join("big.bin");
        // 大于响应体通道容量（8 × 256KiB），确保写出持续到对端断开
        std::fs::write(&source, vec![7u8; 4 * 1024 * 1024]).unwrap();
        let files = vec![MtaFileEntry {
            fd_crc: -1,
            fd_send: -1,
            path: source.to_string_lossy().to_string(),
            entry_name: "1/big.bin".into(),
            last_modified_ms: None,
            crc32: 0,
            size_bytes: 0,
        }];
        let ctx = test_ctx("task-abort", files, 4 * 1024 * 1024);
        let mut phase_rx = ctx.phase_tx.subscribe();

        let resp = build_download_response(&ctx, Some("task-abort")).await;
        // 立即丢弃响应体：等价于对端断开下载连接（无人再消费 ZIP 字节）
        drop(resp);

        let waited = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if *phase_rx.borrow() == DownloadPhase::PeerAborted {
                    break true;
                }
                if phase_rx.changed().await.is_err() {
                    break false;
                }
            }
        })
        .await;
        assert_eq!(waited, Ok(true), "对端断开应置下载阶段为 PeerAborted");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
