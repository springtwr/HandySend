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
    stream
        .read_to_end(&mut raw)
        .await
        .expect("响应读取失败");
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

/// 按名取响应头（调用方已转小写）。
fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.as_str())
}

/// 等待出现待确认会话并返回其 token（超时即失败，避免用例 hanging）。
async fn wait_pending_token(state: &Arc<WebServiceState>) -> String {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let token: Option<String> = {
            let sessions = state.sessions.lock().unwrap();
            sessions
                .sessions
                .iter()
                .find(|(_, session)| {
                    matches!(
                        session.state,
                        localsend_core::bridge::web::session::SessionState::Pending { .. }
                    )
                })
                .map(|(token, _)| token.clone())
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
    state
        .caps
        .lock()
        .unwrap()
        .share_state = ShareState::Active;
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
    assert_eq!(list["files"]["f1"]["fileName"], serde_json::json!("hello.txt"));
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
    while let Ok(event) =
        tokio::time::timeout(Duration::from_secs(5), progress_rx.recv()).await
    {
        match event.expect("进度通道关闭") {
            ProgressEvent::Done { token: done_token, .. } if done_token == token => {
                saw_done = true;
                break;
            }
            _ => {}
        }
    }
    assert!(saw_done, "应收到文件终值事件");
    // 完成回执：会话移除，再下回 403。
    let (finish_status, _, _) = http_post(addr, &format!("/web/finish?token={token}")).await;
    assert_eq!(finish_status, 200);
    assert!(!state.sessions.lock().unwrap().contains(&token));
    let (gone_status, _, _) =
        http_get(addr, &format!("/web/download?token={token}&fileId=f1")).await;
    assert_eq!(gone_status, 403);
    handle.abort();
}

/// 拒绝与过期：403/408 与会话收口。
#[tokio::test]
async fn test_decline_and_expire_paths() {
    let (handle, addr, state, _rx, _ctx) =
        spawn_with_files(vec![("f1", "a.txt", b"abc")]).await;
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

/// PIN：错一次 401，三次错后 429，对了放行。
#[tokio::test]
async fn test_pin_gate() {
    let (handle, addr, state, _rx, _ctx) =
        spawn_with_files(vec![("f1", "a.txt", b"abc")]).await;
    *state.expected_pin.lock().unwrap() = Some("1234".to_string());
    let (wrong_status, _, _) = http_post(addr, "/web/prepare-download?pin=0000").await;
    assert_eq!(wrong_status, 401);
    let (wrong_status, _, _) = http_post(addr, "/web/prepare-download?pin=0000").await;
    assert_eq!(wrong_status, 401);
    let (wrong_status, _, _) = http_post(addr, "/web/prepare-download?pin=0000").await;
    assert_eq!(wrong_status, 401);
    let (locked_status, _, _) = http_post(addr, "/web/prepare-download?pin=1234").await;
    assert_eq!(locked_status, 429);
    handle.abort();
    // 新服务免 PIN 计数干扰：重置计数后正确 PIN 放行。
    let (handle, addr, state, _rx, _ctx) =
        spawn_with_files(vec![("f1", "a.txt", b"abc")]).await;
    *state.expected_pin.lock().unwrap() = Some("1234".to_string());
    let prepare = tokio::spawn(http_post(addr, "/web/prepare-download?pin=1234"));
    let token = wait_pending_token(&state).await;
    state
        .sessions
        .lock()
        .unwrap()
        .accept(&token, std::time::Instant::now())
        .unwrap();
    let (status, _, body) = tokio::time::timeout(Duration::from_secs(5), prepare)
        .await
        .expect("正确 PIN 应答超时")
        .unwrap();
    assert_eq!(status, 200);
    assert!(body.contains(&token));
    handle.abort();
}

/// 同 IP 已有待确认会话：第二个建会话请求回 409，不堆决策。
#[tokio::test]
async fn test_duplicate_pending_conflict() {
    let (handle, addr, state, _rx, _ctx) =
        spawn_with_files(vec![("f1", "a.txt", b"abc")]).await;
    let prepare = tokio::spawn(http_post(addr, "/web/prepare-download"));
    let token = wait_pending_token(&state).await;
    let (conflict_status, _, _) = http_post(addr, "/web/prepare-download").await;
    assert_eq!(conflict_status, 409);
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
    let (handle, addr, state, _rx, _ctx) = spawn_with_files(vec![
        ("a", "a.txt", b"AAA"),
        ("b", "b.txt", b"BBB"),
    ])
    .await;
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
    // 保留过期后，A 下 a 回 410。
    state.retained.lock().unwrap().clear();
    let (gone_status, _, _) =
        http_get(addr, &format!("/web/download?token={token_a}&fileId=a")).await;
    assert_eq!(gone_status, 410);
    let _ = std::fs::remove_file(&path_c);
    handle.abort();
}

/// 未知 token / 未知文件一律 403；分享停止回 404。
#[tokio::test]
async fn test_invalid_token_and_stopped_share() {
    let (handle, addr, state, _rx, _ctx) =
        spawn_with_files(vec![("f1", "a.txt", b"abc")]).await;
    let (unknown_status, _, _) =
        http_get(addr, "/web/download?token=nope&fileId=f1").await;
    assert_eq!(unknown_status, 403);
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
    assert_eq!(
        header(&headers, "content-range"),
        Some("bytes 4-17/18")
    );
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
    // 覆盖到末尾的分片发终值。
    let (status, _, _) =
        http_request_with_headers(addr, "GET", &base, &[("Range", "bytes=10-")]).await;
    assert_eq!(status, 206);
    let mut saw_done = false;
    while let Ok(event) =
        tokio::time::timeout(Duration::from_secs(5), progress_rx.recv()).await
    {
        if let Some(ProgressEvent::Done { .. }) = event {
            saw_done = true;
            break;
        }
    }
    assert!(saw_done, "到末尾的分片应发终值");
    handle.abort();
}
