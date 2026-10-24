//! 自研 Web 服务（与上游 `web.rs` 解耦，不再复用它）。
//!
//! 独立 hyper 服务（仿 `mta::server::run_server` 的 accept 循环），
//! 自有端口，只复用设备别名/证书/PIN/HTTPS 开关等身份配置。
//! TLS 随内容链路接入；先调通 HTTP 路由与无副作用查询。

use std::convert::Infallible;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use bytes::Bytes;
use http_body_util::Full;
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use tokio::net::TcpListener;

use crate::bridge::lock;
use crate::bridge::web::caps::CapsSnapshot;

/// 单页 HTML（与服务同仓，改文案改 JS 只动主仓）。
const SINGLE_HTML: &str = include_str!("assets/single.html");

/// 自研 web 服务配置（与上游 `WebConfig` 解耦，不再复用它）。
#[derive(Clone, Debug, Default)]
pub struct WebServiceConfig {
    /// 自有监听端口（与 LocalSend 服务端口独立，重启互不影响）。
    pub port: u16,
    /// 是否使用自签证书 HTTPS（跟随全局加密开关，不另起证书；
    /// TLS 接入随内容链路，路由调通阶段仅 HTTP）。
    pub use_https: bool,
}

/// 服务共享状态（只读快照 + 文件表等运行态，C2 起逐步接入）。
#[derive(Clone, Debug, Default)]
pub struct WebServiceState {
    /// 当前能力快照（`GET /caps` 原子读取，绝不创建会话）。
    pub caps: Arc<Mutex<CapsSnapshot>>,
}

/// 在已绑定的监听器上提供 HTTP/1 服务，直到任务被 abort。
pub async fn run_server(listener: TcpListener, state: Arc<WebServiceState>) {
    loop {
        let (stream, peer) = match listener.accept().await {
            Ok(pair) => pair,
            Err(e) => {
                log::debug!("自研 web accept 失败: {e}");
                continue;
            }
        };
        log::debug!("自研 web 接收到连接: {peer}");
        let conn_state = Arc::clone(&state);
        tokio::spawn(async move {
            let io = TokioIo::new(stream);
            let service = service_fn(move |req: Request<Incoming>| {
                let req_state = Arc::clone(&conn_state);
                async move { handle(req, req_state).await }
            });
            if let Err(e) = hyper::server::conn::http1::Builder::new()
                .serve_connection(io, service)
                .await
            {
                log::debug!("自研 web 连接结束: {e}");
            }
        });
    }
}

/// 路由分发（`Infallible`：未知路径按 404 文本回，不抛错）。
async fn handle(
    req: Request<Incoming>,
    state: Arc<WebServiceState>,
) -> Result<Response<Full<Bytes>>, Infallible> {
    let path = req.uri().path();
    match path {
        "/caps" => Ok(caps_response(&state)),
        "/" => Ok(html_response()),
        _ => Ok(text_response(StatusCode::NOT_FOUND, "未知路径")),
    }
}

/// `GET /caps`：只读快照，无副作用（不建会话、不碰决策通道）。
fn caps_response(state: &WebServiceState) -> Response<Full<Bytes>> {
    let snapshot: CapsSnapshot = lock(&state.caps).clone();
    let body: String = serde_json::to_string(&snapshot).unwrap_or_else(|_| "{}".to_string());
    json_response(StatusCode::OK, &body)
}

/// `GET /`：单页（按 caps 条件渲染两段）。
fn html_response() -> Response<Full<Bytes>> {
    html_full_response(StatusCode::OK, SINGLE_HTML)
}

fn text_response(status: StatusCode, text: &str) -> Response<Full<Bytes>> {
    full_response(status, "text/plain; charset=utf-8", text)
}

fn json_response(status: StatusCode, body: &str) -> Response<Full<Bytes>> {
    full_response(status, "application/json", body)
}

fn html_full_response(status: StatusCode, body: &str) -> Response<Full<Bytes>> {
    full_response(status, "text/html; charset=utf-8", body)
}

fn full_response(status: StatusCode, content_type: &str, body: &str) -> Response<Full<Bytes>> {
    let mut response = Response::new(Full::new(Bytes::from(body.to_string())));
    *response.status_mut() = status;
    response.headers_mut().insert(
        hyper::header::CONTENT_TYPE,
        hyper::header::HeaderValue::from_str(content_type)
            .unwrap_or(hyper::header::HeaderValue::from_static("text/plain")),
    );
    response
}

/// 测试用：在回环地址上绑定空闲端口（调用方取 `local_addr` 得实际端口）。
pub async fn bind_loopback() -> std::io::Result<(TcpListener, SocketAddr)> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let addr: SocketAddr = listener.local_addr()?;
    Ok((listener, addr))
}
