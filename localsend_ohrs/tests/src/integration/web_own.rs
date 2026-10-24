//! 自研 Web 服务集成测试（`bridge/web`）：路由与无副作用查询。
//!
//! 不经过 NAPI，直接起服 + 裸 TCP 断言。刻意不用 reqwest：
//! 一是 loopback 直连不受代理环境变量影响（reqwest 会读代理，
//! 沙箱 shell 下局域网 IP 会被送进代理拿 502），
//! 二是不依赖全局 rustls provider（`rustls-no-provider` 下
//! `Client::new` 会 panic，老用例靠执行顺序碰巧装好，不可学）。

use std::net::SocketAddr;
use std::sync::Arc;

use localsend_core::bridge::web::caps::{CapsSnapshot, ShareState};
use localsend_core::bridge::web::server::{bind_loopback, run_server, WebServiceState};

/// 起服并返回句柄与地址（调用方负责 abort JoinHandle）。
async fn spawn_test_server(caps: CapsSnapshot) -> (tokio::task::JoinHandle<()>, SocketAddr) {
    let state = Arc::new(WebServiceState {
        caps: Arc::new(std::sync::Mutex::new(caps)),
    });
    let (listener, addr) = bind_loopback().await.expect("回环绑定失败");
    let handle = tokio::spawn(run_server(listener, state));
    (handle, addr)
}

/// 裸 TCP 发起最小 HTTP/1.1 GET，返回（状态码，响应头，响应体）。
async fn http_get(addr: SocketAddr, path: &str) -> (u16, Vec<(String, String)>, String) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut stream = tokio::net::TcpStream::connect(addr)
        .await
        .expect("回环连接失败");
    let request: String =
        format!("GET {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\n\r\n");
    stream
        .write_all(request.as_bytes())
        .await
        .expect("请求写入失败");
    let mut raw: Vec<u8> = Vec::new();
    stream
        .read_to_end(&mut raw)
        .await
        .expect("响应读取失败");
    let text: String = String::from_utf8_lossy(&raw).into_owned();
    let (head, body) = text.split_once("\r\n\r\n").expect("响应缺头体分隔");
    let mut lines = head.lines();
    let status_line: &str = lines.next().expect("响应缺状态行");
    let status: u16 = status_line
        .split_whitespace()
        .nth(1)
        .expect("状态行缺状态码")
        .parse()
        .expect("状态码非数字");
    let mut headers: Vec<(String, String)> = Vec::new();
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            headers.push((name.trim().to_ascii_lowercase(), value.trim().to_string()));
        }
    }
    (status, headers, body.to_string())
}

/// 按名取响应头（大小写不敏感后的小写名）。
fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.as_str())
}

#[tokio::test]
async fn test_caps_four_states_without_side_effects() {
    let cases: Vec<(CapsSnapshot, &str, &str)> = vec![
        (
            CapsSnapshot {
                share_state: ShareState::Stopped,
                ..Default::default()
            },
            "\"shareState\":\"stopped\"",
            "\"hasDownload\":false",
        ),
        (
            CapsSnapshot {
                has_download: true,
                file_revision: 3,
                share_state: ShareState::Active,
                ..Default::default()
            },
            "\"fileRevision\":3",
            "\"uploadEnabled\":false",
        ),
        (
            CapsSnapshot {
                upload_enabled: true,
                share_state: ShareState::Active,
                ..Default::default()
            },
            "\"uploadEnabled\":true",
            "\"hasDownload\":false",
        ),
        (
            CapsSnapshot {
                has_download: true,
                file_revision: 9,
                upload_enabled: true,
                share_state: ShareState::Active,
                https_hint: true,
            },
            "\"httpsHint\":true",
            "\"shareState\":\"active\"",
        ),
    ];
    for (caps, expect_a, expect_b) in cases {
        let (handle, addr) = spawn_test_server(caps).await;
        let (status, headers, body) = http_get(addr, "/caps").await;
        assert_eq!(status, 200);
        assert!(
            header(&headers, "content-type")
                .unwrap_or("")
                .contains("application/json"),
            "caps 应为 JSON 响应"
        );
        assert!(body.contains(expect_a), "缺 {expect_a}，实际 {body}");
        assert!(body.contains(expect_b), "缺 {expect_b}，实际 {body}");
        handle.abort();
    }
}

#[tokio::test]
async fn test_single_page_and_unknown_path() {
    let (handle, addr) = spawn_test_server(CapsSnapshot {
        share_state: ShareState::Active,
        ..Default::default()
    })
    .await;
    let (status, headers, body) = http_get(addr, "/").await;
    assert_eq!(status, 200);
    assert!(
        header(&headers, "content-type")
            .unwrap_or("")
            .contains("text/html"),
        "单页应为 HTML 响应"
    );
    assert!(body.contains("id=\"app\""), "单页应含挂载点");
    assert!(
        body.contains("data-section=\"download\""),
        "单页应含下载段"
    );
    assert!(
        body.contains("data-section=\"upload\""),
        "单页应含上传段"
    );
    assert!(
        body.contains("/caps"),
        "单页应按 caps 条件渲染"
    );
    let (missing_status, _, _) = http_get(addr, "/nope").await;
    assert_eq!(missing_status, 404);
    handle.abort();
}
