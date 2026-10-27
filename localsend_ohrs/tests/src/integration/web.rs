//! 自研 Web 服务集成测试（`bridge/web`）：路由与无副作用查询。
//!
//! 不经过 NAPI，直接起服 + 裸 TCP 断言。刻意不用 reqwest：
//! 一是 loopback 直连不受代理环境变量影响（reqwest 会读代理，
//! 沙箱 shell 下局域网 IP 会被送进代理拿 502），
//! 二是不依赖全局 rustls provider（`rustls-no-provider` 下
//! `Client::new` 会 panic，老用例靠执行顺序碰巧装好，不可学）。

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use localsend_core::bridge::web::caps::{CapsSnapshot, ShareState};
use localsend_core::bridge::web::server::{
    bind_loopback, run_server, ProgressEvent, WebServiceState,
};
use localsend_core::bridge::web::session::{FileSource, SharedFile};
use tokio::sync::mpsc;

/// 起服并返回句柄、地址与进度接收端（调用方负责 abort）。
async fn spawn_test_server(
    build: impl FnOnce(&mut WebServiceState, &mut TestContext),
) -> (
    tokio::task::JoinHandle<()>,
    SocketAddr,
    Arc<WebServiceState>,
    mpsc::Receiver<ProgressEvent>,
    TestContext,
) {
    let (progress_tx, progress_rx) = mpsc::channel::<ProgressEvent>(64);
    let mut ctx = TestContext::default();
    let mut state = WebServiceState {
        progress_tx: Some(progress_tx),
        ..Default::default()
    };
    build(&mut state, &mut ctx);
    let state = Arc::new(state);
    let (listener, addr) = bind_loopback().await.expect("回环绑定失败");
    let handle = tokio::spawn(run_server(listener, Arc::clone(&state)));
    (handle, addr, state, progress_rx, ctx)
}

/// 测试上下文：临时文件目录（`Drop` 时清理）。
#[derive(Default)]
struct TestContext {
    dir: std::path::PathBuf,
}

impl TestContext {
    fn fresh() -> Self {
        let dir = std::env::temp_dir().join(format!(
            "handysend-web-own-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        Self { dir }
    }

    fn write_file(&self, name: &str, content: &[u8]) -> std::path::PathBuf {
        let path = self.dir.join(name);
        std::fs::write(&path, content).unwrap();
        path
    }
}

impl Drop for TestContext {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn test_file_dto(id: &str, name: &str, size: u64) -> localsend::model::transfer::FileDto {
    localsend::model::transfer::FileDto {
        id: id.to_string(),
        file_name: name.to_string(),
        size,
        file_type: "text/plain".to_string(),
        sha256: None,
        preview: None,
        metadata: None,
    }
}

/// 最小 HTTP/1.1 请求（空体必带 `Content-Length: 0`，
/// 否则服务端会等待请求体；`extra_headers` 追加自定义头），
/// 返回（状态码，响应头，响应体）。
async fn http_request_with_headers(
    addr: SocketAddr,
    method: &str,
    path: &str,
    extra_headers: &[(&str, &str)],
) -> (u16, Vec<(String, String)>, String) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut stream = tokio::net::TcpStream::connect(addr)
        .await
        .expect("回环连接失败");
    let mut request: String = format!(
        "{method} {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\nContent-Length: 0\r\n"
    );
    for (name, value) in extra_headers {
        request.push_str(&format!("{name}: {value}\r\n"));
    }
    request.push_str("\r\n");
    stream
        .write_all(request.as_bytes())
        .await
        .expect("请求写入失败");
    let mut raw: Vec<u8> = Vec::new();
    stream.read_to_end(&mut raw).await.expect("响应读取失败");
    let text: String = String::from_utf8_lossy(&raw).into_owned();
    let (head, body) = text.split_once("\r\n\r\n").expect("缺头体分隔");
    let mut lines = head.lines();
    let status_line: &str = lines.next().expect("缺状态行");
    let status: u16 = status_line
        .split_whitespace()
        .nth(1)
        .expect("缺状态码")
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

async fn http_request(
    addr: SocketAddr,
    method: &str,
    path: &str,
) -> (u16, Vec<(String, String)>, String) {
    http_request_with_headers(addr, method, path, &[]).await
}

async fn http_get(addr: SocketAddr, path: &str) -> (u16, Vec<(String, String)>, String) {
    http_request(addr, "GET", path).await
}

async fn http_post(addr: SocketAddr, path: &str) -> (u16, Vec<(String, String)>, String) {
    http_request(addr, "POST", path).await
}

async fn http_post_bytes(
    addr: SocketAddr,
    path: &str,
    body: &[u8],
    extra_headers: &[(&str, &str)],
) -> (u16, Vec<(String, String)>, String) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut stream = tokio::net::TcpStream::connect(addr)
        .await
        .expect("回环连接失败");
    let mut request: String = format!(
        "POST {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\nContent-Length: {}\r\n",
        body.len()
    );
    for (name, value) in extra_headers {
        request.push_str(&format!("{name}: {value}\r\n"));
    }
    request.push_str("\r\n");
    stream
        .write_all(request.as_bytes())
        .await
        .expect("请求写入失败");
    stream.write_all(body).await.expect("请求体写入失败");
    let mut raw: Vec<u8> = Vec::new();
    stream.read_to_end(&mut raw).await.expect("响应读取失败");
    let text: String = String::from_utf8_lossy(&raw).into_owned();
    let (head, resp_body) = text.split_once("\r\n\r\n").expect("缺头体分隔");
    let mut lines = head.lines();
    let status_line: &str = lines.next().expect("缺状态行");
    let status: u16 = status_line
        .split_whitespace()
        .nth(1)
        .expect("缺状态码")
        .parse()
        .expect("状态码非数字");
    let mut headers: Vec<(String, String)> = Vec::new();
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            headers.push((name.trim().to_ascii_lowercase(), value.trim().to_string()));
        }
    }
    (status, headers, resp_body.to_string())
}

/// 按名取响应头（调用方已转小写）。
fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.as_str())
}

/// 等待出现待确认会话（下载/上传任一存储）并返回其 token，
/// 超时即失败，避免用例 hanging。
async fn wait_pending_token(state: &Arc<WebServiceState>) -> String {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let token: Option<String> = {
            let sessions = state.sessions.lock().unwrap();
            let found = sessions
                .sessions
                .iter()
                .find(|(_, session)| {
                    matches!(
                        session.state,
                        localsend_core::bridge::web::session::SessionState::Pending { .. }
                    )
                })
                .map(|(token, _)| token.clone());
            if found.is_some() {
                found
            } else {
                state
                    .uploads
                    .lock()
                    .unwrap()
                    .sessions
                    .iter()
                    .find(|(_, session)| {
                        matches!(
                            session.state,
                            localsend_core::bridge::web::upload::UploadState::Pending { .. }
                        )
                    })
                    .map(|(token, _)| token.clone())
            }
        };
        if let Some(token) = token {
            return token;
        }
        if tokio::time::Instant::now() >= deadline {
            panic!("等不到待确认会话");
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// 带挂载文件的测试服务（Path 内容源）。
async fn spawn_with_files(
    files: Vec<(&str, &str, &[u8])>,
) -> (
    tokio::task::JoinHandle<()>,
    SocketAddr,
    Arc<WebServiceState>,
    mpsc::Receiver<ProgressEvent>,
    TestContext,
) {
    let ctx = TestContext::fresh();
    let mut table: HashMap<String, SharedFile> = HashMap::new();
    for (id, name, content) in files {
        let path = ctx.write_file(name, content);
        table.insert(
            id.to_string(),
            SharedFile {
                file: test_file_dto(id, name, content.len() as u64),
                source: FileSource::Path(path.to_string_lossy().into_owned()),
            },
        );
    }
    let (progress_tx, progress_rx) = mpsc::channel::<ProgressEvent>(64);
    let state = WebServiceState {
        progress_tx: Some(progress_tx),
        ..Default::default()
    };
    state.caps.lock().unwrap().share_state = ShareState::Active;
    *state.alias.lock().unwrap() = "TestDevice".to_string();
    *state.share_id.lock().unwrap() = "share-1".to_string();
    state.files.lock().unwrap().replace(table);
    let state = Arc::new(state);
    let (listener, addr) = bind_loopback().await.expect("回环绑定失败");
    let handle = tokio::spawn(run_server(listener, Arc::clone(&state)));
    (handle, addr, state, progress_rx, ctx)
}

#[tokio::test]
async fn test_caps_four_states_without_side_effects() {
    // 每组：换表次数（决定 revision）+ 挂载文件 + 展示字段 → 期望片段。
    // `has_download` 与 `file_revision` 取文件表实时值，不取展示字段。
    let placeholder = || SharedFile {
        file: test_file_dto("f", "f.txt", 1),
        source: FileSource::Path("/tmp/f".to_string()),
    };
    let cases: Vec<(usize, bool, CapsSnapshot, &str, &str)> = vec![
        (
            0,
            false,
            CapsSnapshot {
                share_state: ShareState::Stopped,
                ..Default::default()
            },
            "\"shareState\":\"stopped\"",
            "\"hasDownload\":false",
        ),
        (
            3,
            true,
            CapsSnapshot {
                share_state: ShareState::Active,
                ..Default::default()
            },
            "\"fileRevision\":3",
            "\"uploadEnabled\":false",
        ),
        (
            0,
            false,
            CapsSnapshot {
                upload_enabled: true,
                share_state: ShareState::Active,
                ..Default::default()
            },
            "\"uploadEnabled\":true",
            "\"hasDownload\":false",
        ),
        (
            2,
            true,
            CapsSnapshot {
                upload_enabled: true,
                share_state: ShareState::Active,
                https_hint: true,
                ..Default::default()
            },
            "\"httpsHint\":true",
            "\"shareState\":\"active\"",
        ),
    ];
    for (replaces, mount, caps, expect_a, expect_b) in cases {
        let (handle, addr, state, _rx, _ctx) = spawn_test_server(|_, _| {}).await;
        for _ in 0..replaces {
            let mut table: HashMap<String, SharedFile> = HashMap::new();
            if mount {
                table.insert("f".to_string(), placeholder());
            }
            state.files.lock().unwrap().replace(table);
        }
        *state.caps.lock().unwrap() = caps;
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
    let (handle, addr, _state, _rx, _ctx) = spawn_test_server(|state, _ctx| {
        state.caps.lock().unwrap().share_state = ShareState::Active;
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
    assert!(body.contains("id=\"gate\""), "单页应含访问密码页");
    assert!(
        body.contains("data-auth=\"open\""),
        "未设置密码时首帧应直接展示内容页"
    );
    assert!(
        !body.contains("{{AUTH_STATE}}"),
        "服务端应替换访问密码门禁占位"
    );
    assert!(
        !body.contains("pin-modal"),
        "下载时 PIN 弹窗应已被入口密码页取代"
    );
    assert!(body.contains("data-section=\"download\""), "单页应含下载段");
    assert!(body.contains("data-section=\"upload\""), "单页应含上传段");
    assert!(body.contains("/caps"), "单页应按 caps 条件渲染");
    assert!(body.contains("id=\"upload-picker\""), "单页应含上传入口");
    assert!(body.contains("prepare-upload"), "单页应含上传建会话逻辑");
    assert!(
        body.contains("handysend_dl_token"),
        "下载与上传 token 应分键存储"
    );
    assert!(body.contains("/i18n.json"), "单页应先拉取文案");
    assert!(body.contains("message.txt"), "单页应支持文本发送");
    assert!(
        body.contains("shareUpdatedRetry"),
        "单页应分流 410（分享已更新请刷新）"
    );
    assert!(
        body.contains("location.protocol"),
        "单页应按协议判定展示 HTTPS 自签提示"
    );
    assert!(body.contains("/web/finish"), "单页应上报完成回执");
    // 上传地址与下载地址同页：`/upload` 应返回同一单页。
    let (up_status, up_headers, up_body) = http_get(addr, "/upload").await;
    assert_eq!(up_status, 200);
    assert!(
        header(&up_headers, "content-type")
            .unwrap_or("")
            .contains("text/html"),
        "上传地址应为 HTML 响应"
    );
    assert!(up_body.contains("upload-section"), "上传地址应含上传段");
    let (missing_status, _, _) = http_get(addr, "/nope").await;
    assert_eq!(missing_status, 404);
    handle.abort();
}

/// fd 内容源：dup 副本直读，重复/并发下载内容一致。
#[tokio::test]
async fn test_download_fd_source_repeatable() {
    use std::os::fd::AsRawFd;
    let ctx = TestContext::fresh();
    let path = ctx.write_file("fd.bin", b"fd-content-12345");
    let held = std::fs::File::open(&path).expect("打开源文件");
    let mut table: HashMap<String, SharedFile> = HashMap::new();
    table.insert(
        "f".to_string(),
        SharedFile {
            file: test_file_dto("f", "fd.bin", 17),
            source: FileSource::Fd(held.as_raw_fd()),
        },
    );
    let (progress_tx, _progress_rx) = mpsc::channel::<ProgressEvent>(64);
    let state = WebServiceState {
        progress_tx: Some(progress_tx),
        ..Default::default()
    };
    state.caps.lock().unwrap().share_state = ShareState::Active;
    state.files.lock().unwrap().replace(table);
    let state = Arc::new(state);
    let (listener, addr) = bind_loopback().await.expect("回环绑定失败");
    let handle = tokio::spawn(run_server(listener, Arc::clone(&state)));
    let token = prepare_accepted(addr, &state).await;
    for _ in 0..2 {
        let (status, _, body) =
            http_get(addr, &format!("/web/download?token={token}&fileId=f")).await;
        assert_eq!(status, 200);
        assert_eq!(body.as_bytes(), b"fd-content-12345");
    }
    drop(held);
    handle.abort();
}

/// 文案下发：按语言返回对应文案集，无参回退简体中文。
#[tokio::test]
async fn test_i18n_by_language() {
    let (handle, addr, _state, _rx, _ctx) = spawn_test_server(|_, _| {}).await;
    let (status, headers, body) = http_get(addr, "/i18n.json?lang=en-US").await;
    assert_eq!(status, 200);
    assert!(header(&headers, "content-type")
        .unwrap_or("")
        .contains("application/json"));
    assert!(
        body.contains("\"downloadAll\":\"Download all\""),
        "英文文案缺失: {body}"
    );
    let (status, _, body_tw) = http_get(addr, "/i18n.json?lang=zh-TW").await;
    assert_eq!(status, 200);
    assert!(body_tw.contains("下載"), "繁体中文缺失");
    assert!(body.contains("shareUpdatedRetry"), "缺 410 分流文案键");
    assert!(body.contains("httpsHint"), "缺 HTTPS 提示文案键");
    assert!(body.contains("refreshPage"), "缺错误页刷新按钮文案键");
    let (status, _, body_default) = http_get(addr, "/i18n.json").await;
    assert_eq!(status, 200);
    assert!(body_default.contains("全部下载"), "缺省应为简体中文");
    handle.abort();
}

/// 完整链路：建会话→接受→复用→下载字节→进度与终值→完成回执。
#[tokio::test]
async fn test_prepare_accept_download_finish_flow() {
    let content: &[u8] = b"hello web download";
    let (handle, addr, state, mut progress_rx, _ctx) =
        spawn_with_files(vec![("f1", "hello.txt", content)]).await;
    // 建会话（挂起，等待决策）。
    let prepare = tokio::spawn(http_post(addr, "/web/prepare-download"));
    let token = wait_pending_token(&state).await;
    state
        .sessions
        .lock()
        .unwrap()
        .accept(&token, std::time::Instant::now())
        .unwrap();
    let (status, _, body) = tokio::time::timeout(Duration::from_secs(5), prepare)
        .await
        .expect("建会话超时")
        .unwrap();
    assert_eq!(status, 200);
    let list: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(list["token"], serde_json::json!(token));
    assert_eq!(
        list["files"]["f1"]["fileName"],
        serde_json::json!("hello.txt")
    );
    // 待确认事件已发射（NAPI 侧转确认弹窗用）。
    let mut saw_prepare = false;
    while let Ok(event) = tokio::time::timeout(Duration::from_secs(5), progress_rx.recv()).await {
        match event.expect("进度通道关闭") {
            ProgressEvent::PrepareDownloadRequested {
                token: event_token, ..
            } if event_token == token => {
                saw_prepare = true;
                break;
            }
            _ => {}
        }
    }
    assert!(saw_prepare, "应收到待确认事件");
    // 复用：同 token 同 IP 直接回表，不建新会话。
    let (reuse_status, _, reuse_body) =
        http_post(addr, &format!("/web/prepare-download?token={token}")).await;
    assert_eq!(reuse_status, 200);
    assert!(reuse_body.contains(&token));
    assert_eq!(state.sessions.lock().unwrap().sessions.len(), 1);
    // 下载：字节一致，头齐全。
    let (dl_status, dl_headers, dl_body) =
        http_get(addr, &format!("/web/download?token={token}&fileId=f1")).await;
    assert_eq!(dl_status, 200);
    assert_eq!(dl_body.as_bytes(), content);
    assert_eq!(
        header(&dl_headers, "content-length"),
        Some(content.len().to_string().as_str())
    );
    assert!(header(&dl_headers, "content-disposition").is_some());
    // 进度与终值事件。
    let mut saw_done = false;
    while let Ok(event) = tokio::time::timeout(Duration::from_secs(5), progress_rx.recv()).await {
        match event.expect("进度通道关闭") {
            ProgressEvent::Done {
                token: done_token, ..
            } if done_token == token => {
                saw_done = true;
                break;
            }
            _ => {}
        }
    }
    assert!(saw_done, "应收到文件终值事件");
    // 完成回执：会话移除，再下回友好错误页（不是纯文本）。
    let (finish_status, _, _) = http_post(addr, &format!("/web/finish?token={token}")).await;
    assert_eq!(finish_status, 200);
    assert!(!state.sessions.lock().unwrap().contains(&token));
    let (gone_status, gone_headers, gone_body) =
        http_get(addr, &format!("/web/download?token={token}&fileId=f1")).await;
    assert_eq!(gone_status, 403);
    assert!(
        header(&gone_headers, "content-type")
            .unwrap_or("")
            .contains("text/html"),
        "直链失效应回 HTML 错误页"
    );
    assert!(
        gone_body.contains("本次网页访问已结束"),
        "应给出可读的结束提示：{gone_body}"
    );
    assert!(gone_body.contains("href=\"/\""), "应给出刷新入口");
    handle.abort();
}

/// 拒绝与过期：403/408 与会话收口。
#[tokio::test]
async fn test_decline_and_expire_paths() {
    let (handle, addr, state, _rx, _ctx) = spawn_with_files(vec![("f1", "a.txt", b"abc")]).await;
    // 拒绝。
    let prepare = tokio::spawn(http_post(addr, "/web/prepare-download"));
    let token = wait_pending_token(&state).await;
    assert!(state.sessions.lock().unwrap().decline(&token));
    let (status, _, _) = tokio::time::timeout(Duration::from_secs(5), prepare)
        .await
        .expect("拒绝应答超时")
        .unwrap();
    assert_eq!(status, 403);
    assert!(!state.sessions.lock().unwrap().contains(&token));
    // 过期（决策通道被丢弃）。
    let prepare = tokio::spawn(http_post(addr, "/web/prepare-download"));
    let token = wait_pending_token(&state).await;
    assert!(state.sessions.lock().unwrap().expire(&token));
    let (status, _, _) = tokio::time::timeout(Duration::from_secs(5), prepare)
        .await
        .expect("过期应答超时")
        .unwrap();
    assert_eq!(status, 408);
    assert!(!state.sessions.lock().unwrap().contains(&token));
    handle.abort();
}

/// 访问密码门禁：未登录只给密码页，接口 401；窗口内错误过多 429；
/// 登录成功后 Cookie 放行 caps / 单页 / 建会话，且建会话不再需要 PIN 参数。
#[tokio::test]
async fn test_pin_gate() {
    let (handle, addr, state, _rx, _ctx) = spawn_with_files(vec![("f1", "a.txt", b"abc")]).await;
    *state.expected_pin.lock().unwrap() = Some("1234".to_string());
    // 单页首帧即锁定，不展示文件内容。
    let (page_status, _, page) = http_get(addr, "/").await;
    assert_eq!(page_status, 200);
    assert!(page.contains("data-auth=\"locked\""));
    // 未登录接口一律 401。
    let (caps_status, _, _) = http_get(addr, "/caps").await;
    assert_eq!(caps_status, 401);
    let (prepare_status, _, _) = http_post(addr, "/web/prepare-download").await;
    assert_eq!(prepare_status, 401);
    // 连续三次错误后进入窗口锁，正确密码也回 429。
    for _ in 0..3 {
        let (wrong_status, _, _) = http_post_bytes(
            addr,
            "/web/auth",
            b"{\"password\":\"0000\"}",
            &[("Content-Type", "application/json")],
        )
        .await;
        assert_eq!(wrong_status, 401);
    }
    let (locked_status, _, _) = http_post_bytes(
        addr,
        "/web/auth",
        b"{\"password\":\"1234\"}",
        &[("Content-Type", "application/json")],
    )
    .await;
    assert_eq!(locked_status, 429);
    handle.abort();
    // 新服务重新计数：正确密码换取 Cookie 后放行。
    let (handle, addr, state, _rx, _ctx) = spawn_with_files(vec![("f1", "a.txt", b"abc")]).await;
    *state.expected_pin.lock().unwrap() = Some("1234".to_string());
    let (login_status, login_headers, _) = http_post_bytes(
        addr,
        "/web/auth",
        b"{\"password\":\"1234\"}",
        &[("Content-Type", "application/json")],
    )
    .await;
    assert_eq!(login_status, 200);
    let cookie = header(&login_headers, "set-cookie")
        .expect("登录应下发 Cookie")
        .split(';')
        .next()
        .expect("Cookie 格式非法")
        .to_string();
    assert!(cookie.starts_with("handysend_web_auth="));
    let (caps_status, _, _) =
        http_request_with_headers(addr, "GET", "/caps", &[("Cookie", cookie.as_str())]).await;
    assert_eq!(caps_status, 200);
    let (_, _, page) =
        http_request_with_headers(addr, "GET", "/", &[("Cookie", cookie.as_str())]).await;
    assert!(page.contains("data-auth=\"open\""));
    // 已授权后建下载会话：密码即授权，服务端直接回文件表，不再等待应用确认。
    let (status, _, body) = http_request_with_headers(
        addr,
        "POST",
        "/web/prepare-download",
        &[("Cookie", cookie.as_str())],
    )
    .await;
    assert_eq!(status, 200);
    let json: serde_json::Value = serde_json::from_str(&body).expect("文件表应为 JSON");
    let token: String = json["token"].as_str().expect("应下发 token").to_string();
    assert!(
        matches!(
            state.sessions.lock().unwrap().sessions[&token].state,
            localsend_core::bridge::web::session::SessionState::Accepted
        ),
        "访问密码正确时应直接置为已接受"
    );
    // 同一浏览器/同 IP 的再次 prepare（如页面响应丢失后重试）复用刚接受的会话，
    // 不重复建任务；返回同一 token。
    let (again_status, _, again_body) = http_request_with_headers(
        addr,
        "POST",
        "/web/prepare-download",
        &[("Cookie", cookie.as_str())],
    )
    .await;
    assert_eq!(again_status, 200);
    let again_json: serde_json::Value =
        serde_json::from_str(&again_body).expect("复用响应应为 JSON");
    assert_eq!(
        again_json["token"].as_str().unwrap(),
        token,
        "不应重复创建下载会话"
    );
    // 下载链接同样受 Cookie 门禁保护：未带 Cookie 401，带 Cookie 200。
    let download_path = format!("/web/download?token={token}&fileId=f1");
    let (no_cookie, _, _) = http_get(addr, &download_path).await;
    assert_eq!(no_cookie, 401);
    let (with_cookie, _, content) =
        http_request_with_headers(addr, "GET", &download_path, &[("Cookie", cookie.as_str())])
            .await;
    assert_eq!(with_cookie, 200);
    assert_eq!(content.as_bytes(), b"abc");
    handle.abort();
}

/// 同 IP 已有待确认会话：第二个建会话请求回 409，不堆决策。
#[tokio::test]
async fn test_duplicate_pending_conflict() {
    let (handle, addr, state, _rx, _ctx) = spawn_with_files(vec![("f1", "a.txt", b"abc")]).await;
    let prepare = tokio::spawn(http_post(addr, "/web/prepare-download"));
    let token = wait_pending_token(&state).await;
    let (conflict_status, conflict_headers, _) = http_post(addr, "/web/prepare-download").await;
    assert_eq!(conflict_status, 409);
    assert_eq!(
        header(&conflict_headers, "x-handysend-token"),
        Some(token.as_str()),
        "409 应带出待确认 token 供页面恢复"
    );
    state
        .sessions
        .lock()
        .unwrap()
        .accept(&token, std::time::Instant::now())
        .unwrap();
    let (status, _, _) = tokio::time::timeout(Duration::from_secs(5), prepare)
        .await
        .expect("首个会话应答超时")
        .unwrap();
    assert_eq!(status, 200);
    handle.abort();
}

/// revision 隔离：A 取旧表，换表后 B 取新表，并发互不串；
/// 保留期内旧文件可下，过期后 410。
#[tokio::test]
async fn test_revision_isolation_with_retained_files() {
    let (handle, addr, state, _rx, _ctx) =
        spawn_with_files(vec![("a", "a.txt", b"AAA"), ("b", "b.txt", b"BBB")]).await;
    // A 建会话（快照 rev1：a/b）。
    let prepare_a = tokio::spawn(http_post(addr, "/web/prepare-download"));
    let token_a = wait_pending_token(&state).await;
    state
        .sessions
        .lock()
        .unwrap()
        .accept(&token_a, std::time::Instant::now())
        .unwrap();
    let (status_a, _, _) = tokio::time::timeout(Duration::from_secs(5), prepare_a)
        .await
        .expect("A 建会话超时")
        .unwrap();
    assert_eq!(status_a, 200);
    // 换表为 b/c（rev2）。
    let mut next: HashMap<String, SharedFile> = HashMap::new();
    let dir = state
        .files
        .lock()
        .unwrap()
        .files
        .get("b")
        .and_then(|entry| match &entry.source {
            FileSource::Path(path) => Some(path.clone()),
            _ => None,
        })
        .expect("b 应在现表");
    let path_c = {
        let c_path = std::env::temp_dir().join(format!(
            "handysend-web-own-c-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::write(&c_path, b"CCC").unwrap();
        c_path.to_string_lossy().into_owned()
    };
    next.insert(
        "b".to_string(),
        SharedFile {
            file: test_file_dto("b", "b.txt", 3),
            source: FileSource::Path(dir),
        },
    );
    next.insert(
        "c".to_string(),
        SharedFile {
            file: test_file_dto("c", "c.txt", 3),
            source: FileSource::Path(path_c.clone()),
        },
    );
    state.update_files(next);
    assert_eq!(state.files.lock().unwrap().revision, 2);
    // B 建会话（快照 rev2：b/c）。
    let prepare_b = tokio::spawn(http_post(addr, "/web/prepare-download"));
    let token_b = wait_pending_token(&state).await;
    assert_ne!(token_a, token_b);
    state
        .sessions
        .lock()
        .unwrap()
        .accept(&token_b, std::time::Instant::now())
        .unwrap();
    let (status_b, _, _) = tokio::time::timeout(Duration::from_secs(5), prepare_b)
        .await
        .expect("B 建会话超时")
        .unwrap();
    assert_eq!(status_b, 200);
    // A 下 a（保留期内，200）；A 下 c（不在快照，403）。
    let (a_old_status, _, a_old_body) =
        http_get(addr, &format!("/web/download?token={token_a}&fileId=a")).await;
    assert_eq!(a_old_status, 200);
    assert_eq!(a_old_body.as_bytes(), b"AAA");
    let (a_new_status, _, _) =
        http_get(addr, &format!("/web/download?token={token_a}&fileId=c")).await;
    assert_eq!(a_new_status, 403);
    // B 下 c（200）；B 下 a（不在快照，403）。
    let (b_new_status, _, b_new_body) =
        http_get(addr, &format!("/web/download?token={token_b}&fileId=c")).await;
    assert_eq!(b_new_status, 200);
    assert_eq!(b_new_body.as_bytes(), b"CCC");
    let (b_old_status, _, _) =
        http_get(addr, &format!("/web/download?token={token_b}&fileId=a")).await;
    assert_eq!(b_old_status, 403);
    // 保留过期后，A 下 a 回 410 友好错误页。
    state.retained.lock().unwrap().clear();
    let (gone_status, gone_headers, gone_body) =
        http_get(addr, &format!("/web/download?token={token_a}&fileId=a")).await;
    assert_eq!(gone_status, 410);
    assert!(
        header(&gone_headers, "content-type")
            .unwrap_or("")
            .contains("text/html"),
        "内容失效的直链应为 HTML 错误页"
    );
    assert!(
        gone_body.contains("分享内容已更新"),
        "应提示分享内容已更新：{gone_body}"
    );
    let _ = std::fs::remove_file(&path_c);
    handle.abort();
}

/// 同一已授权会话在换表后再次 prepare：文件表刷新为新版本，
/// 不重复弹确认，也不再提供已撤下的文件。
#[tokio::test]
async fn test_accepted_session_refreshes_on_revision() {
    let (handle, addr, state, mut progress_rx, ctx) =
        spawn_with_files(vec![("a", "a.txt", b"AAA")]).await;
    let prepare = tokio::spawn(http_post(addr, "/web/prepare-download"));
    let token = wait_pending_token(&state).await;
    state
        .sessions
        .lock()
        .unwrap()
        .accept(&token, std::time::Instant::now())
        .unwrap();
    let (status, _, body) = tokio::time::timeout(Duration::from_secs(5), prepare)
        .await
        .expect("建会话超时")
        .unwrap();
    assert_eq!(status, 200);
    assert!(body.contains("a.txt"));
    // 换表：撤下 a，挂上 b。
    let path_b = ctx.write_file("b.txt", b"BBB");
    let mut next: HashMap<String, SharedFile> = HashMap::new();
    next.insert(
        "b".to_string(),
        SharedFile {
            file: test_file_dto("b", "b.txt", 3),
            source: FileSource::Path(path_b.to_string_lossy().into_owned()),
        },
    );
    state.update_files(next);
    // 带原 token 再次 prepare：同一会话、返回新表。
    let (reuse_status, _, reuse_body) =
        http_post(addr, &format!("/web/prepare-download?token={token}")).await;
    assert_eq!(reuse_status, 200);
    assert!(reuse_body.contains("b.txt"));
    assert!(!reuse_body.contains("a.txt"));
    // 文件表刷新应通知应用侧同步任务文件清单（不重建会话）。
    let mut saw_update = false;
    while let Ok(event) = tokio::time::timeout(Duration::from_secs(1), progress_rx.recv()).await {
        match event.expect("进度通道关闭") {
            ProgressEvent::FilesUpdated {
                token: event_token,
                files,
            } if event_token == token => {
                assert_eq!(files.len(), 1);
                assert_eq!(files[0].file_name, "b.txt");
                saw_update = true;
                break;
            }
            _ => {}
        }
    }
    assert!(saw_update, "换表后应收到 FilesUpdated 事件");
    // 新文件可下载；已撤下文件不再出现在会话快照里。
    let (b_status, _, b_body) =
        http_get(addr, &format!("/web/download?token={token}&fileId=b")).await;
    assert_eq!(b_status, 200);
    assert_eq!(b_body.as_bytes(), b"BBB");
    let (a_status, _, _) = http_get(addr, &format!("/web/download?token={token}&fileId=a")).await;
    assert_eq!(a_status, 403);
    handle.abort();
}

/// 页面心跳为已授权会话续期；未知 token 回 404。
#[tokio::test]
async fn test_heartbeat_extends_accepted_session() {
    let (handle, addr, state, mut progress_rx, _ctx) =
        spawn_with_files(vec![("f1", "a.txt", b"abc")]).await;
    let prepare = tokio::spawn(http_post(addr, "/web/prepare-download"));
    let token = wait_pending_token(&state).await;
    state
        .sessions
        .lock()
        .unwrap()
        .accept(&token, std::time::Instant::now())
        .unwrap();
    let (status, _, _) = tokio::time::timeout(Duration::from_secs(5), prepare)
        .await
        .expect("建会话超时")
        .unwrap();
    assert_eq!(status, 200);
    // 模拟长时间未下载：活动时刻拨回 30 秒前。
    {
        let mut sessions = state.sessions.lock().unwrap();
        sessions.sessions.get_mut(&token).unwrap().last_activity =
            Instant::now() - Duration::from_secs(30);
    }
    let (beat_status, _, _) = http_post(addr, &format!("/web/heartbeat?token={token}")).await;
    assert_eq!(beat_status, 200);
    let mut saw_heartbeat = false;
    while let Ok(event) = tokio::time::timeout(Duration::from_secs(1), progress_rx.recv()).await {
        match event.expect("进度通道关闭") {
            ProgressEvent::Heartbeat { token: event_token } if event_token == token => {
                saw_heartbeat = true;
                break;
            }
            _ => {}
        }
    }
    assert!(saw_heartbeat, "页面心跳应通知应用侧续期任务");
    {
        let sessions = state.sessions.lock().unwrap();
        let session = sessions.sessions.get(&token).expect("会话应在");
        assert!(
            session.last_activity.elapsed() < Duration::from_secs(1),
            "心跳应刷新活动时刻"
        );
    }
    let (unknown_status, _, _) = http_post(addr, "/web/heartbeat?token=nope").await;
    assert_eq!(unknown_status, 404);
    // 应用侧结束任务：移除会话后下载链接与心跳立即失效，
    // 直链回可读的结束页（不再让用户停在纯文本 403）。
    state.sessions.lock().unwrap().expire(&token);
    let (cancelled_status, cancelled_headers, cancelled_body) =
        http_get(addr, &format!("/web/download?token={token}&fileId=f1")).await;
    assert_eq!(cancelled_status, 403);
    assert!(
        header(&cancelled_headers, "content-type")
            .unwrap_or("")
            .contains("text/html"),
        "结束后的直链应为 HTML 错误页"
    );
    assert!(
        cancelled_body.contains("刷新页面"),
        "应提示刷新页面重新访问"
    );
    let (cancelled_beat, _, _) = http_post(addr, &format!("/web/heartbeat?token={token}")).await;
    assert_eq!(cancelled_beat, 404);
    // 刷新页面重新访问：建新会话（旧 token 不复用），应用侧重新确认。
    let refresh = tokio::spawn(http_post(addr, "/web/prepare-download"));
    let fresh_token = wait_pending_token(&state).await;
    assert_ne!(fresh_token, token, "刷新后应建立新的访问会话");
    state
        .sessions
        .lock()
        .unwrap()
        .accept(&fresh_token, Instant::now())
        .unwrap();
    let (refresh_status, _, refresh_body) = tokio::time::timeout(Duration::from_secs(5), refresh)
        .await
        .expect("刷新后建会话超时")
        .unwrap();
    assert_eq!(refresh_status, 200);
    assert!(refresh_body.contains(&fresh_token));
    handle.abort();
}

/// fd 内容源：换表后 ArkTS 会关闭旧句柄，保留区必须持有 dup 副本，
/// 宽限内旧会话仍能读回正确内容，而不是已关闭/被复用的 fd。
#[tokio::test]
async fn test_retained_fd_survives_handle_close() {
    use std::os::fd::AsRawFd;
    let ctx = TestContext::fresh();
    let path_a = ctx.write_file("a.bin", b"AAA");
    let path_b = ctx.write_file("b.bin", b"BBB");
    let held_a = std::fs::File::open(&path_a).expect("打开 a");
    let held_b = std::fs::File::open(&path_b).expect("打开 b");
    let mut table: HashMap<String, SharedFile> = HashMap::new();
    table.insert(
        "a".to_string(),
        SharedFile {
            file: test_file_dto("a", "a.bin", 3),
            source: FileSource::Fd(held_a.as_raw_fd()),
        },
    );
    table.insert(
        "b".to_string(),
        SharedFile {
            file: test_file_dto("b", "b.bin", 3),
            source: FileSource::Fd(held_b.as_raw_fd()),
        },
    );
    let (progress_tx, progress_rx) = mpsc::channel::<ProgressEvent>(64);
    let state = WebServiceState {
        progress_tx: Some(progress_tx),
        ..Default::default()
    };
    state.caps.lock().unwrap().share_state = ShareState::Active;
    state.files.lock().unwrap().replace(table);
    let state = Arc::new(state);
    let (listener, addr) = bind_loopback().await.expect("回环绑定失败");
    let handle = tokio::spawn(run_server(listener, Arc::clone(&state)));
    // A 会话快照包含 a/b。
    let prepare = tokio::spawn(http_post(addr, "/web/prepare-download"));
    let token = wait_pending_token(&state).await;
    state
        .sessions
        .lock()
        .unwrap()
        .accept(&token, std::time::Instant::now())
        .unwrap();
    let (status, _, _) = tokio::time::timeout(Duration::from_secs(5), prepare)
        .await
        .expect("建会话超时")
        .unwrap();
    assert_eq!(status, 200);
    // 换表只保留 b（新句柄），随后关闭旧句柄（模拟 ArkTS 交接）。
    drop(progress_rx);
    let held_b2 = std::fs::File::open(&path_b).expect("重新打开 b");
    let mut next: HashMap<String, SharedFile> = HashMap::new();
    next.insert(
        "b".to_string(),
        SharedFile {
            file: test_file_dto("b", "b.bin", 3),
            source: FileSource::Fd(held_b2.as_raw_fd()),
        },
    );
    state.update_files(next);
    drop(held_a);
    drop(held_b);
    // 保留区内的 a 仍可下完。
    let (a_status, _, a_body) =
        http_get(addr, &format!("/web/download?token={token}&fileId=a")).await;
    assert_eq!(a_status, 200);
    assert_eq!(a_body.as_bytes(), b"AAA");
    // 宽限结束后 a 不再可用。
    state.retained.lock().unwrap().clear();
    let (gone_status, _, _) =
        http_get(addr, &format!("/web/download?token={token}&fileId=a")).await;
    assert_eq!(gone_status, 410);
    drop(held_b2);
    handle.abort();
}

/// 未知 token / 未知文件一律 403；分享停止回 404。
#[tokio::test]
async fn test_invalid_token_and_stopped_share() {
    let (handle, addr, state, _rx, _ctx) = spawn_with_files(vec![("f1", "a.txt", b"abc")]).await;
    let (unknown_status, unknown_headers, unknown_body) =
        http_get(addr, "/web/download?token=nope&fileId=f1").await;
    assert_eq!(unknown_status, 403);
    assert!(
        header(&unknown_headers, "content-type")
            .unwrap_or("")
            .contains("text/html"),
        "未知 token 的直链应回 HTML 错误页"
    );
    assert!(unknown_body.contains("刷新页面"), "应给出刷新入口");
    // 错误页文案跟随 Accept-Language。
    let (_, _, english_body) = http_request_with_headers(
        addr,
        "GET",
        "/web/download?token=nope&fileId=f1",
        &[("Accept-Language", "en-US,en;q=0.9")],
    )
    .await;
    assert!(
        english_body.contains("Refresh the page"),
        "英文请求应回英文结束提示：{english_body}"
    );
    // 建有效会话后下未知文件。
    let prepare = tokio::spawn(http_post(addr, "/web/prepare-download"));
    let token = wait_pending_token(&state).await;
    state
        .sessions
        .lock()
        .unwrap()
        .accept(&token, std::time::Instant::now())
        .unwrap();
    let (status, _, _) = tokio::time::timeout(Duration::from_secs(5), prepare)
        .await
        .expect("建会话超时")
        .unwrap();
    assert_eq!(status, 200);
    let (bad_file_status, _, _) =
        http_get(addr, &format!("/web/download?token={token}&fileId=nope")).await;
    assert_eq!(bad_file_status, 403);
    // 分享停止后新建会话回 404；未知 token 的完成回执仍 200（幂等）。
    state.caps.lock().unwrap().share_state = ShareState::Stopped;
    let (stopped_status, _, _) = http_post(addr, "/web/prepare-download").await;
    assert_eq!(stopped_status, 404);
    let (finish_unknown_status, _, _) = http_post(addr, "/web/finish?token=nope").await;
    assert_eq!(finish_unknown_status, 200);
    handle.abort();
}

/// 建会话并接受，返回 token（各下载用例的前置）。
async fn prepare_accepted(addr: SocketAddr, state: &Arc<WebServiceState>) -> String {
    let prepare = tokio::spawn(http_post(addr, "/web/prepare-download"));
    let token = wait_pending_token(state).await;
    state
        .sessions
        .lock()
        .unwrap()
        .accept(&token, Instant::now())
        .unwrap();
    let (status, _, _) = tokio::time::timeout(Duration::from_secs(5), prepare)
        .await
        .expect("建会话超时")
        .unwrap();
    assert_eq!(status, 200);
    token
}

/// Range 分片：起止/后缀/越界三种形态与终值语义。
#[tokio::test]
async fn test_range_partial_content() {
    // "hello web download" 共 18 字节。
    let content: &[u8] = b"hello web download";
    assert_eq!(content.len(), 18);
    let (handle, addr, state, mut progress_rx, _ctx) =
        spawn_with_files(vec![("f1", "a.txt", content)]).await;
    let token = prepare_accepted(addr, &state).await;
    let base = format!("/web/download?token={token}&fileId=f1");
    // 起止分片：bytes=0-4 → "hello"；中途分片不发终值。
    let (status, headers, body) =
        http_request_with_headers(addr, "GET", &base, &[("Range", "bytes=0-4")]).await;
    assert_eq!(status, 206);
    assert_eq!(body.as_bytes(), b"hello");
    assert_eq!(header(&headers, "content-range"), Some("bytes 0-4/18"));
    let deadline = tokio::time::Instant::now() + Duration::from_millis(200);
    while tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_millis(50), progress_rx.recv()).await {
            Ok(Some(ProgressEvent::Done { .. })) => {
                panic!("中途分片不应发终值");
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }
    // 起始分片：bytes=4- → "o web download"，206。
    let (status, headers, body) =
        http_request_with_headers(addr, "GET", &base, &[("Range", "bytes=4-")]).await;
    assert_eq!(status, 206);
    assert_eq!(body.as_bytes(), b"o web download");
    assert_eq!(header(&headers, "content-length"), Some("14"));
    assert_eq!(header(&headers, "content-range"), Some("bytes 4-17/18"));
    // 后缀分片：bytes=-5 → "nload"。
    let (status, _, body) =
        http_request_with_headers(addr, "GET", &base, &[("Range", "bytes=-5")]).await;
    assert_eq!(status, 206);
    assert_eq!(body.as_bytes(), b"nload");
    // 越界：416 + 可恢复标记。
    let (status, headers, _) =
        http_request_with_headers(addr, "GET", &base, &[("Range", "bytes=99-")]).await;
    assert_eq!(status, 416);
    assert_eq!(header(&headers, "content-range"), Some("bytes */18"));
    // 文本预览（preview=1）只读内容，不把会话标记为已开始下载。
    state
        .sessions
        .lock()
        .unwrap()
        .sessions
        .get_mut(&token)
        .unwrap()
        .download_started = false;
    let (preview_status, _, preview_body) = http_request_with_headers(
        addr,
        "GET",
        &format!("{base}&preview=1"),
        &[("Range", "bytes=0-4")],
    )
    .await;
    assert_eq!(preview_status, 206);
    assert_eq!(preview_body.as_bytes(), b"hello");
    assert!(
        !state.sessions.lock().unwrap().sessions[&token].download_started,
        "预览不应改变会话的下载已开始状态"
    );
    // 覆盖到末尾的分片发终值。
    let (status, _, _) =
        http_request_with_headers(addr, "GET", &base, &[("Range", "bytes=10-")]).await;
    assert_eq!(status, 206);
    let mut saw_done = false;
    while let Ok(event) = tokio::time::timeout(Duration::from_secs(5), progress_rx.recv()).await {
        if let Some(ProgressEvent::Done { .. }) = event {
            saw_done = true;
            break;
        }
    }
    assert!(saw_done, "到末尾的分片应发终值");
    handle.abort();
}

/// 上传建会话并接受，返回 token。
async fn prepare_upload_accepted(
    addr: SocketAddr,
    state: &Arc<WebServiceState>,
    files_json: &str,
) -> String {
    let body: Vec<u8> = files_json.as_bytes().to_vec();
    let prepare =
        tokio::spawn(async move { http_post_bytes(addr, "/web/prepare-upload", &body, &[]).await });
    let token = wait_pending_token(state).await;
    state
        .uploads
        .lock()
        .unwrap()
        .accept(&token, Instant::now())
        .unwrap();
    let (status, _, resp_body) = tokio::time::timeout(Duration::from_secs(5), prepare)
        .await
        .expect("上传建会话超时")
        .unwrap();
    assert_eq!(status, 200);
    assert!(resp_body.contains(&token));
    token
}

/// 起上传专用服务（上传目录为临时目录）。
async fn spawn_upload_server() -> (
    tokio::task::JoinHandle<()>,
    SocketAddr,
    Arc<WebServiceState>,
    mpsc::Receiver<ProgressEvent>,
    TestContext,
) {
    let ctx = TestContext::fresh();
    let (progress_tx, progress_rx) = mpsc::channel::<ProgressEvent>(64);
    let state = WebServiceState {
        progress_tx: Some(progress_tx),
        ..Default::default()
    };
    state.caps.lock().unwrap().share_state = ShareState::Active;
    state.caps.lock().unwrap().upload_enabled = true;
    *state.alias.lock().unwrap() = "TestDevice".to_string();
    *state.share_id.lock().unwrap() = "share-up".to_string();
    *state.upload_dir.lock().unwrap() = ctx.dir.clone();
    let state = Arc::new(state);
    let (listener, addr) = bind_loopback().await.expect("回环绑定失败");
    let handle = tokio::spawn(run_server(listener, Arc::clone(&state)));
    (handle, addr, state, progress_rx, ctx)
}

/// 上传全链路：建会话→接受→分片上传→落盘一致→终值→完成回执。
#[tokio::test]
async fn test_upload_flow_to_disk() {
    let (handle, addr, state, mut progress_rx, _ctx) = spawn_upload_server().await;
    let content: &[u8] = b"upload content here";
    let token = prepare_upload_accepted(
        addr,
        &state,
        &format!(
            "{{\"files\":[{{\"id\":\"u1\",\"fileName\":\"up.txt\",\"size\":{},\"fileType\":\"text/plain\",\"preview\":\"hello\"}}]}}",
            content.len()
        ),
    )
    .await;
    // 待确认事件已发射（NAPI 侧转确认弹窗用）。
    let mut saw_prepare = false;
    while let Ok(event) = tokio::time::timeout(Duration::from_secs(5), progress_rx.recv()).await {
        match event.expect("进度通道关闭") {
            ProgressEvent::PrepareUploadRequested {
                token: event_token,
                files,
                ..
            } if event_token == token => {
                assert_eq!(files.len(), 1, "待确认事件应携带一个文件");
                assert_eq!(
                    files[0].preview.as_deref(),
                    Some("hello"),
                    "文本消息 preview 应透传"
                );
                saw_prepare = true;
                break;
            }
            _ => {}
        }
    }
    assert!(saw_prepare, "应收到上传待确认事件");
    // 复用：同 token 直接回表。
    let (reuse_status, _, _) = http_post(addr, &format!("/web/prepare-upload?token={token}")).await;
    assert_eq!(reuse_status, 200);
    // 上传字节。
    let (up_status, _, up_body) = http_post_bytes(
        addr,
        &format!("/web/upload?token={token}&fileId=u1"),
        content,
        &[],
    )
    .await;
    assert_eq!(up_status, 200);
    assert!(up_body.contains("\"ok\":true"));
    // 落盘一致。
    let landed = state.upload_dir.lock().unwrap().join("up.txt");
    assert_eq!(std::fs::read(&landed).unwrap(), content);
    // 终值携带最终路径。
    let mut saw_done = false;
    while let Ok(event) = tokio::time::timeout(Duration::from_secs(5), progress_rx.recv()).await {
        match event.expect("进度通道关闭") {
            ProgressEvent::UploadDone {
                token: done_token,
                path,
                ..
            } if done_token == token => {
                assert!(path.ends_with("up.txt"));
                saw_done = true;
                break;
            }
            _ => {}
        }
    }
    assert!(saw_done, "应收到上传终值");
    // 重复上传同一文件回 409。
    let (dup_status, _, _) = http_post_bytes(
        addr,
        &format!("/web/upload?token={token}&fileId=u1"),
        content,
        &[],
    )
    .await;
    assert_eq!(dup_status, 409);
    // 完成回执回收会话，但不得删除已经交付的最终文件。
    let (finish_status, _, _) = http_post(addr, &format!("/web/finish?token={token}")).await;
    assert_eq!(finish_status, 200);
    assert!(!state.uploads.lock().unwrap().contains(&token));
    assert!(landed.exists(), "完成回执不应删除已落盘文件");
    assert_eq!(std::fs::read(&landed).unwrap(), content);
    handle.abort();
}

/// 上传拒绝与过期：403/408，临时文件清理。
#[tokio::test]
async fn test_upload_decline_and_expire() {
    let (handle, addr, state, _rx, _ctx) = spawn_upload_server().await;
    let files = "{\"files\":[{\"id\":\"u1\",\"fileName\":\"a.txt\",\"size\":3}]}";
    let body: Vec<u8> = files.as_bytes().to_vec();
    // 拒绝。
    let prepare =
        tokio::spawn(async move { http_post_bytes(addr, "/web/prepare-upload", &body, &[]).await });
    let token = wait_pending_token(&state).await;
    let removed = state.uploads.lock().unwrap().decline(&token);
    assert!(removed.is_some());
    let (status, _, _) = tokio::time::timeout(Duration::from_secs(5), prepare)
        .await
        .expect("拒绝应答超时")
        .unwrap();
    assert_eq!(status, 403);
    // 过期。
    let files = "{\"files\":[{\"id\":\"u1\",\"fileName\":\"a.txt\",\"size\":3}]}";
    let body: Vec<u8> = files.as_bytes().to_vec();
    let prepare =
        tokio::spawn(async move { http_post_bytes(addr, "/web/prepare-upload", &body, &[]).await });
    let token = wait_pending_token(&state).await;
    assert!(state.uploads.lock().unwrap().expire(&token));
    let (status, _, _) = tokio::time::timeout(Duration::from_secs(5), prepare)
        .await
        .expect("过期应答超时")
        .unwrap();
    assert_eq!(status, 408);
    handle.abort();
}

/// 上传长度校验：超声明 413，短包 400。
#[tokio::test]
async fn test_upload_size_enforcement() {
    let (handle, addr, state, _rx, _ctx) = spawn_upload_server().await;
    let token = prepare_upload_accepted(
        addr,
        &state,
        "{\"files\":[{\"id\":\"u1\",\"fileName\":\"a.txt\",\"size\":3}]}",
    )
    .await;
    // 超声明。
    let (status, _, _) = http_post_bytes(
        addr,
        &format!("/web/upload?token={token}&fileId=u1"),
        b"toolong",
        &[],
    )
    .await;
    assert_eq!(status, 413);
    // 短包。
    let token = prepare_upload_accepted(
        addr,
        &state,
        "{\"files\":[{\"id\":\"u2\",\"fileName\":\"b.txt\",\"size\":10}]}",
    )
    .await;
    let (status, _, _) = http_post_bytes(
        addr,
        &format!("/web/upload?token={token}&fileId=u2"),
        b"short",
        &[],
    )
    .await;
    assert_eq!(status, 400);
    handle.abort();
}

/// 双浏览器并发上传：互不 409，进度各算各的。
#[tokio::test]
async fn test_concurrent_browsers_upload() {
    let (handle, addr, state, mut progress_rx, _ctx) = spawn_upload_server().await;
    let content_a: &[u8] = b"browser A file";
    let content_b: &[u8] = b"browser B file!!";
    let token_a = prepare_upload_accepted(
        addr,
        &state,
        &format!(
            "{{\"files\":[{{\"id\":\"a\",\"fileName\":\"a.txt\",\"size\":{}}}]}}",
            content_a.len()
        ),
    )
    .await;
    let token_b = prepare_upload_accepted(
        addr,
        &state,
        &format!(
            "{{\"files\":[{{\"id\":\"b\",\"fileName\":\"b.txt\",\"size\":{}}}]}}",
            content_b.len()
        ),
    )
    .await;
    assert_ne!(token_a, token_b);
    let path_a = format!("/web/upload?token={token_a}&fileId=a");
    let path_b = format!("/web/upload?token={token_b}&fileId=b");
    let up_a = tokio::spawn(async move { http_post_bytes(addr, &path_a, content_a, &[]).await });
    let up_b = tokio::spawn(async move { http_post_bytes(addr, &path_b, content_b, &[]).await });
    let (res_a, res_b) = tokio::join!(up_a, up_b);
    let (status_a, _, _) = res_a.unwrap();
    let (status_b, _, _) = res_b.unwrap();
    assert_eq!(status_a, 200);
    assert_eq!(status_b, 200);
    assert_eq!(
        std::fs::read(state.upload_dir.lock().unwrap().join("a.txt")).unwrap(),
        content_a
    );
    assert_eq!(
        std::fs::read(state.upload_dir.lock().unwrap().join("b.txt")).unwrap(),
        content_b
    );
    // 两会话各收到自己的终值。
    let mut done_tokens: Vec<String> = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while done_tokens.len() < 2 && tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_millis(100), progress_rx.recv()).await {
            Ok(Some(ProgressEvent::UploadDone { token, .. })) => done_tokens.push(token),
            Ok(_) => {}
            Err(_) => break,
        }
    }
    assert!(done_tokens.contains(&token_a), "A 应收到终值");
    assert!(done_tokens.contains(&token_b), "B 应收到终值");
    handle.abort();
}

/// 上传未开放与分享停止：404，不建会话。
#[tokio::test]
async fn test_upload_not_enabled_and_stopped() {
    let (handle, addr, state, _rx, _ctx) = spawn_upload_server().await;
    state.caps.lock().unwrap().upload_enabled = false;
    let files = "{\"files\":[{\"id\":\"u1\",\"fileName\":\"a.txt\",\"size\":3}]}";
    let body: Vec<u8> = files.as_bytes().to_vec();
    let (status, _, _) = http_post_bytes(addr, "/web/prepare-upload", &body, &[]).await;
    assert_eq!(status, 404);
    assert!(!state
        .uploads
        .lock()
        .unwrap()
        .sessions
        .values()
        .any(|_| true));
    state.caps.lock().unwrap().upload_enabled = true;
    state.caps.lock().unwrap().share_state = ShareState::Stopped;
    let (status, _, _) = http_post_bytes(addr, "/web/prepare-upload", &body, &[]).await;
    assert_eq!(status, 404);
    handle.abort();
}

/// 已接受但从未上传：按等待首包超时收尾并清理。
#[tokio::test]
async fn test_upload_peer_no_upload_sweep() {
    let (handle, addr, state, _rx, _ctx) = spawn_upload_server().await;
    state.uploads.lock().unwrap().timeouts =
        localsend_core::bridge::web::session::SessionTimeouts {
            pending: Duration::from_secs(60),
            wait_first_file: Duration::from_millis(10),
            idle: Duration::from_secs(30),
        };
    let token = prepare_upload_accepted(
        addr,
        &state,
        "{\"files\":[{\"id\":\"u1\",\"fileName\":\"a.txt\",\"size\":3}]}",
    )
    .await;
    std::thread::sleep(Duration::from_millis(30));
    let ended = state
        .uploads
        .lock()
        .unwrap()
        .sweep(std::time::Instant::now());
    assert_eq!(ended.len(), 1);
    assert_eq!(ended[0].0.token, token);
    assert!(!state.uploads.lock().unwrap().contains(&token));
    handle.abort();
}
