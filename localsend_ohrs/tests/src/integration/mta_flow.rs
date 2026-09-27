//! MTA 跨层流程集成测试（host 目标可直接运行）。
//!
//! 覆盖：
//! - 应用层消息构造/解析、sendRequest JSON、status 分类（纯函数）；
//! - 发送端流式写出 ZIP（Stored、fd 直读（path 回退））→ 接收端流式解析/落盘的往返与条目元数据；
//! - 接收端 Rust 主导下载（HTTPS + 跳过证书校验）端到端往返；
//! - 服务器生命周期（`start_server` 绑定端口、不预打包，`stop_server` 清理）；起服失败路径 fd 收尾；
//! - 发送端 WS 会话终止：以**连接终止**结束会话（不发 WebSocket 关闭帧）、结束类指示在终止前
//!   已写出、对端主动先行关闭走快路径、取消/失败路径有界退出；
//! - 尺寸一致性：声明与句柄内容不符时不产生截断载荷（挂载点：本文件；ArkTS 侧尺寸契约见
//!   `entry/src/ohosTest/ets/test/service/MtaSendProtocolTest.test.ets` 的
//!   `send_entry_size_source_matches_handle_content`）。

use std::fs::File;
use std::os::fd::IntoRawFd;
use std::sync::Arc;

use localsend_core::bridge::mta::protocol::{
    self, classify_status, send_request_json, SendRequestPayload, StatusKind,
};
use localsend_core::bridge::mta::receive::{self, extract_zip_to_dir};
use localsend_core::bridge::mta::unzip_stream::ZipParseOptions;
use localsend_core::bridge::mta::{self, zip_stream};
use localsend_core::bridge::BridgeEvent;
use tokio_util::sync::CancellationToken;

/// MTA 服务器为全局单例：串行化所有会启停服务器的用例，避免相互打断。
/// 用异步锁使 guard 可跨 await 存活（多线程 runtime 下要求 future 为 Send）。
static SERVER_TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// 构造一个独立临时目录。
fn temp_dir(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("mta_flow_{tag}_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("创建临时目录失败");
    dir
}

#[test]
fn protocol_message_and_status_flow() {
    let raw = protocol::build_message(
        "action",
        0,
        "versionNegotiation",
        Some(&protocol::version_negotiation_payload()),
    );
    assert_eq!(
        raw,
        "action:0:versionNegotiation?{\"version\":1,\"versions\":[1]}"
    );
    let parsed = protocol::parse_message(&raw).expect("应可解析");
    assert_eq!(parsed.msg_type, "action");
    assert_eq!(parsed.name, "versionNegotiation");

    let payload = SendRequestPayload {
        task_id: "t1".into(),
        id: "t1".into(),
        sender_id: "aa".into(),
        sender_name: "HandySend".into(),
        file_name: "a.zip".into(),
        mime_type: "application/zip".into(),
        file_count: 1,
        total_size: 8,
        thumbnail: None,
        thumbnail_width: None,
        thumbnail_height: None,
        cat_share_text: None,
        sender_brand_id: None,
        sender_brand: None,
    };
    let json = send_request_json(&payload);
    assert!(json.contains("\"taskId\":\"t1\""));
    // 任务 ID 同时镜像到 id 字段
    assert!(json.contains("\"id\":\"t1\""));
    // 文本与品牌缺省时不携带对应字段
    assert!(!json.contains("catShareText"));
    assert!(!json.contains("senderBrand"));

    assert_eq!(classify_status("{\"type\":1}"), StatusKind::Ok);
    assert_eq!(
        classify_status("{\"type\":3,\"reason\":\"user refuse\"}"),
        StatusKind::Refused
    );
    assert_eq!(classify_status("{}"), StatusKind::Other);
}

#[test]
fn zip_stream_written_bytes_extract_with_metadata() {
    let dir = temp_dir("zip");
    let source = dir.join("hello.txt");
    std::fs::write(&source, b"hello mta").unwrap();
    let files = vec![zip_stream::MtaFileEntry {
        fd_send: -1,
        path: source.to_string_lossy().to_string(),
        entry_name: "1/hello.txt".into(),
        last_modified_ms: Some(1_600_000_000_000),
        size_bytes: 9,
    }];

    let mut zip_bytes: Vec<u8> = Vec::new();
    let result = zip_stream::write_zip_stream(&mut zip_bytes, &files, |_| {}).unwrap();
    assert_eq!(result.entry_count, 1);
    assert_eq!(result.total_size, 9);
    assert_eq!(&zip_bytes[0..4], b"PK\x03\x04");

    // 发送端流式写出 → 接收端流式解压并落盘：条目名（仅文件名）、大小、时间与内容均一致
    let out_dir = dir.join("out");
    let progress = std::sync::atomic::AtomicU64::new(0);
    let written = std::sync::atomic::AtomicU64::new(0);
    let options = ZipParseOptions::new(16, 1024 * 1024, 0, Arc::new(|| false));
    let entries = extract_zip_to_dir(
        std::io::Cursor::new(&zip_bytes),
        &out_dir,
        &options,
        &progress,
        &written,
    )
    .unwrap();

    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].name, "hello.txt");
    assert_eq!(entries[0].size, 9);
    assert_eq!(entries[0].modified_unix_ms, 1_600_000_000_000);
    assert_eq!(
        entries[0].saved_path,
        out_dir.join("hello.txt").to_string_lossy()
    );
    assert_eq!(
        std::fs::read(out_dir.join("hello.txt")).unwrap(),
        b"hello mta"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// 尺寸一致性：声明与句柄内容一致时流式成功；不一致时不产生截断载荷
/// （仍按实际读取字节产出完整 ZIP，后续条目与中央目录完整）。
#[test]
fn zip_stream_size_mismatch_does_not_truncate_payload() {
    let dir = temp_dir("size_consistency");
    let a_path = dir.join("a.bin");
    let b_path = dir.join("b.txt");
    let a_content = vec![0x11u8; 4096];
    let b_content = b"tail entry payload".to_vec();
    std::fs::write(&a_path, &a_content).unwrap();
    std::fs::write(&b_path, &b_content).unwrap();

    let files = vec![
        zip_stream::MtaFileEntry {
            fd_send: -1,
            path: a_path.to_string_lossy().to_string(),
            entry_name: "1/a.bin".into(),
            last_modified_ms: None,
            size_bytes: a_content.len() as u64,
        },
        zip_stream::MtaFileEntry {
            fd_send: -1,
            path: b_path.to_string_lossy().to_string(),
            entry_name: "2/b.txt".into(),
            last_modified_ms: None,
            size_bytes: b_content.len() as u64,
        },
    ];

    // 情形一：声明与句柄内容一致 → 流式成功，逐条目还原一致
    let mut zip_ok: Vec<u8> = Vec::new();
    let result = zip_stream::write_zip_stream(&mut zip_ok, &files, |_| {}).unwrap();
    assert_eq!(
        result.total_size,
        (a_content.len() + b_content.len()) as u64
    );
    assert_eq!(result.entry_count, 2);
    let out_ok = dir.join("out_ok");
    let options = ZipParseOptions::new(16, 64 * 1024 * 1024, 0, Arc::new(|| false));
    let progress = std::sync::atomic::AtomicU64::new(0);
    let written = std::sync::atomic::AtomicU64::new(0);
    let entries = extract_zip_to_dir(
        std::io::Cursor::new(&zip_ok),
        &out_ok,
        &options,
        &progress,
        &written,
    )
    .unwrap();
    assert_eq!(entries.len(), 2);
    assert_eq!(std::fs::read(out_ok.join("a.bin")).unwrap(), a_content);
    assert_eq!(std::fs::read(out_ok.join("b.txt")).unwrap(), b_content);

    // 情形二：声明尺寸小于实际 → 不得中断写出，按实际字节产出完整载荷
    let mut mismatched = files.clone();
    mismatched[0].size_bytes = 128;
    let mut zip_bad: Vec<u8> = Vec::new();
    let result = zip_stream::write_zip_stream(&mut zip_bad, &mismatched, |_| {})
        .expect("声明与实际不一致不得中断写出（否则载荷被截断）");
    assert_eq!(
        result.total_size,
        (a_content.len() + b_content.len()) as u64
    );
    assert_eq!(result.entry_count, 2);
    let out_bad = dir.join("out_bad");
    let progress_bad = std::sync::atomic::AtomicU64::new(0);
    let written_bad = std::sync::atomic::AtomicU64::new(0);
    let entries = extract_zip_to_dir(
        std::io::Cursor::new(&zip_bad),
        &out_bad,
        &options,
        &progress_bad,
        &written_bad,
    )
    .unwrap();
    assert_eq!(entries.len(), 2, "后续条目不应因前一条目尺寸不符而丢失");
    assert_eq!(std::fs::read(out_bad.join("a.bin")).unwrap(), a_content);
    assert_eq!(std::fs::read(out_bad.join("b.txt")).unwrap(), b_content);

    let _ = std::fs::remove_dir_all(&dir);
}

/// 端到端：本地起 MTA 发送端服务器 → Rust 直接 HTTPS 下载（跳过证书校验）→ 落盘。
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn receive_download_roundtrip_over_https() {
    let _guard = SERVER_TEST_LOCK.lock().await;
    let dir = temp_dir("recv_roundtrip");
    let source = dir.join("payload.txt");
    let payload = "roundtrip payload ".repeat(1000).into_bytes();
    std::fs::write(&source, &payload).unwrap();
    let source_modified_ms: u64 = 1_600_000_000_000;

    let config_json = serde_json::json!({
        "bindIp": "127.0.0.1",
        "port": 0,
        "taskId": "mta-recv-1",
        "senderId": "abcd",
        "senderName": "HandySendTest",
        "files": [{
            "path": source.to_string_lossy(),
            "entryName": "1/payload.txt",
            "lastModifiedMs": source_modified_ms,
        }],
    })
    .to_string();

    let state = localsend_core::bridge::state::bridge();
    let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(1024);
    {
        let mut s = state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        s.event_tx = Some(event_tx);
    }

    let port = mta::start_server(state, &config_json)
        .await
        .expect("服务器应成功启动");
    assert!(port > 0);

    let target = dir.join("out");
    let options = ZipParseOptions::new(16, 64 * 1024 * 1024, 0, Arc::new(|| false));
    let cancel = CancellationToken::new();
    let entries = receive::receive_download(
        state,
        "127.0.0.1",
        port,
        "mta-recv-1",
        target.to_string_lossy().as_ref(),
        payload.len() as u64,
        options,
        cancel,
        receive::ReceiveTimeouts::default(),
    )
    .await
    .expect("接收应成功");

    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].name, "payload.txt");
    assert_eq!(entries[0].size, payload.len() as u64);
    assert_eq!(entries[0].modified_unix_ms, source_modified_ms as i64);
    assert_eq!(std::fs::read(target.join("payload.txt")).unwrap(), payload);

    // 应至少上报过一次接收进度事件
    let mut got_progress = false;
    while let Ok(event) = event_rx.try_recv() {
        if matches!(event, BridgeEvent::MtaReceiveProgress { .. }) {
            got_progress = true;
        }
    }
    assert!(got_progress, "接收过程应上报 mtaReceiveProgress 事件");

    mta::stop_server();
    let _ = std::fs::remove_dir_all(&dir);
}

/// 等待响应头超时：对端建立 TCP 连接后不返回响应头，接收必须在阈值内失败并清理。
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn receive_download_fails_on_header_timeout() {
    let dir = temp_dir("header_timeout");
    // 裸 TCP 监听：接受连接但永不返回响应头，模拟对端在响应头阶段停滞
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("绑定监听失败");
    let port = listener.local_addr().expect("读取本地地址失败").port();
    let hold = tokio::spawn(async move {
        if let Ok((stream, _)) = listener.accept().await {
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
            drop(stream);
        }
    });

    let state = localsend_core::bridge::state::bridge();
    let target = dir.join("out");
    let options = ZipParseOptions::new(16, 64 * 1024 * 1024, 0, Arc::new(|| false));
    let cancel = CancellationToken::new();
    let timeouts = receive::ReceiveTimeouts {
        header: std::time::Duration::from_millis(300),
        ..receive::ReceiveTimeouts::default()
    };

    let result = receive::receive_download(
        state,
        "127.0.0.1",
        port,
        "mta-header-timeout",
        target.to_string_lossy().as_ref(),
        0,
        options,
        cancel,
        timeouts,
    )
    .await;

    assert!(result.is_err(), "对端不返回响应头时接收应失败");
    let message = format!("{:#}", result.unwrap_err());
    assert!(
        message.contains("响应头超时"),
        "错误应包含响应头超时: {message}"
    );
    // 失败后目标目录不应残留半成品
    let leftover = std::fs::read_dir(&target)
        .map(|mut it| it.next().is_some())
        .unwrap_or(false);
    assert!(!leftover, "响应头超时后不应残留文件");
    hold.abort();
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn server_lifecycle_start_and_stop() {
    let _guard = SERVER_TEST_LOCK.lock().await;
    let dir = temp_dir("server");
    let source = dir.join("payload.bin");
    std::fs::write(&source, b"payload-data").unwrap();

    let config_json = serde_json::json!({
        "bindIp": "127.0.0.1",
        "port": 0,
        "taskId": "mta-test-1",
        "senderId": "abcd",
        "senderName": "HandySendTest",
        "files": [{ "path": source.to_string_lossy(), "entryName": "1/payload.bin" }],
    })
    .to_string();

    assert!(!mta::is_running());
    let state = localsend_core::bridge::state::bridge();
    let port = mta::start_server(state, &config_json)
        .await
        .expect("服务器应成功启动");
    assert!(port > 0, "应返回实际绑定端口");
    assert!(mta::is_running());

    mta::stop_server();
    assert!(!mta::is_running());
    // 幂等
    mta::stop_server();
    assert!(!mta::is_running());

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn server_config_rejects_empty_task() {
    let _guard = SERVER_TEST_LOCK.blocking_lock();
    let config_json = serde_json::json!({
        "bindIp": "127.0.0.1",
        "port": 0,
        "taskId": "",
        "senderId": "a",
        "senderName": "b",
        "files": [{ "path": "/tmp/x", "entryName": "1/x" }],
    })
    .to_string();
    let state = localsend_core::bridge::state::bridge();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let result = runtime.block_on(mta::start_server(state, &config_json));
    assert!(result.is_err(), "空 taskId 应被拒绝");
}

/// 端到端 fd 直读：模拟 ArkTS 每文件 `openSync` 打开读取入口（fdSend）
/// 随配置 JSON 移交 Rust，经 `start_server` → `receive_download` 完成整链往返，
/// 断言落盘产物的名称/大小/内容/修改时间与源文件逐项一致。fd 移交后所有权归
/// Rust，测试不再关闭（`from_raw_fd` 是唯一关闭点）。
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn receive_download_roundtrip_with_file_fds() {
    let _guard = SERVER_TEST_LOCK.lock().await;
    let dir = temp_dir("fd_recv_roundtrip");
    let source = dir.join("photo.jpg");
    let payload = "fd-direct payload ".repeat(500).into_bytes();
    std::fs::write(&source, &payload).unwrap();
    let source_modified_ms: u64 = 1_600_000_000_000;

    // 模拟 ArkTS 移交：打开源文件读取描述符，随 JSON 交给 Rust
    let fd_send = File::open(&source).unwrap().into_raw_fd();

    let config_json = serde_json::json!({
        "bindIp": "127.0.0.1",
        "port": 0,
        "taskId": "mta-fd-1",
        "senderId": "abcd",
        "senderName": "HandySendTest",
        "files": [{
            "fdSend": fd_send,
            "path": "",
            "entryName": "1/photo.jpg",
            "lastModifiedMs": source_modified_ms,
        }],
    })
    .to_string();

    // path 回退对照路径（既有 receive_download_roundtrip_over_https）之外的 fd 主路径
    let state = localsend_core::bridge::state::bridge();
    let port = mta::start_server(state, &config_json)
        .await
        .expect("带 fd 直读的服务器应成功启动");
    assert!(port > 0);

    let target = dir.join("out");
    let options = ZipParseOptions::new(16, 64 * 1024 * 1024, 0, Arc::new(|| false));
    let cancel = CancellationToken::new();
    let entries = receive::receive_download(
        state,
        "127.0.0.1",
        port,
        "mta-fd-1",
        target.to_string_lossy().as_ref(),
        payload.len() as u64,
        options,
        cancel,
        receive::ReceiveTimeouts::default(),
    )
    .await
    .expect("接收应成功");

    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].name, "photo.jpg");
    assert_eq!(entries[0].size, payload.len() as u64);
    assert_eq!(entries[0].modified_unix_ms, source_modified_ms as i64);
    assert_eq!(std::fs::read(target.join("photo.jpg")).unwrap(), payload);

    // fd 已由 Rust 消费/收尾关闭（此处不再关闭）；源路径仍可重新打开
    File::open(&source).expect("源文件在 fd 移交收尾后仍可重新打开");

    mta::stop_server();
    let _ = std::fs::remove_dir_all(&dir);
}

/// 判断 fd 是否仍指向给定文件（即：该号段是否仍持有本用例的源文件句柄）。
///
/// 不按「fd 号是否被占用」判断：fd 号是进程级全局资源，本用例断言前若有并发用例
/// 打开文件/套接字，刚被关闭的号段会被复用，`fcntl(F_GETFD)` 会误判为仍打开。
/// 改为比对 (st_dev, st_ino) 身份——fd 已关闭（fstat 返回 EBADF）或已被复用为其它
/// 文件时均返回 false，只有仍指向本用例源文件时才返回 true（真实泄漏）。
/// SAFETY：fstat 仅查询描述符状态，无副作用；测试运行目标为 host Linux。
fn fd_still_refers_to(fd: i32, path: &std::path::Path) -> bool {
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(fd, &mut stat) } != 0 {
        return false;
    }
    use std::os::unix::fs::MetadataExt;
    match std::fs::metadata(path) {
        Ok(meta) => stat.st_dev as u64 == meta.dev() && stat.st_ino as u64 == meta.ino(),
        Err(_) => false,
    }
}

/// 校验 fd 身份探针本身：打开的 fd 判为指向源文件（真实泄漏可被捕获）、停止引用后判为否
/// （号段复用的误报被排除）。两处断言均与并发用例无关，故自身不 flake。
#[test]
fn fd_identity_probe_distinguishes_open_and_closed() {
    let dir = temp_dir("fd_probe");
    let source = dir.join("probe.bin");
    std::fs::write(&source, b"probe-payload").unwrap();

    let fd = File::open(&source).unwrap().into_raw_fd();
    assert!(
        fd_still_refers_to(fd, &source),
        "仍打开的 fd 应被识别为指向源文件"
    );

    // 停止引用后（等价于生产失败路径关闭 fd）：不得再被判为指向源文件
    unsafe { libc::close(fd) };
    assert!(
        !fd_still_refers_to(fd, &source),
        "已关闭的 fd 不应被识别为指向源文件"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// 起服失败路径 fd 收尾：条目 A 携带真实 fdSend，配置 taskId 为空
/// → `start_server` 在 fd 所有权移交后即拒绝，必须返回错误且不 panic，
/// 未消费的 fd 全部由 Rust 关闭，测试侧不再触碰（fd 所有权已移交）。
#[test]
fn start_server_failure_closes_transferred_fds() {
    let _guard = SERVER_TEST_LOCK.blocking_lock();
    let dir = temp_dir("fd_failure");
    let source = dir.join("a.bin");
    std::fs::write(&source, b"cleanup-fd-payload").unwrap();

    let fd_a_send = File::open(&source).unwrap().into_raw_fd();

    let config_json = serde_json::json!({
        "bindIp": "127.0.0.1",
        "port": 0,
        "taskId": "",
        "senderId": "abcd",
        "senderName": "HandySendTest",
        "files": [
            { "fdSend": fd_a_send, "path": "", "entryName": "1/a.bin" },
        ],
    })
    .to_string();

    let state = localsend_core::bridge::state::bridge();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    // 失败路径不应 panic，且必须返回可读错误
    let result = runtime.block_on(mta::start_server(state, &config_json));
    assert!(result.is_err(), "taskId 为空时 start_server 应返回错误");

    // 失败收尾后 fd 已被 Rust 关闭（按文件身份判定，不受并发用例号段复用影响）
    assert!(
        !fd_still_refers_to(fd_a_send, &source),
        "条目 A 的 fdSend 应在失败路径关闭"
    );
    assert!(!mta::is_running(), "起服失败后服务器不应运行");

    let _ = std::fs::remove_dir_all(&dir);
}

/// 对端在下载中途取消（断开下载连接）：Rust 侧把下载阶段置为 `PeerAborted` 后，
/// 发送端 WS 状态机须在有限时间内终结并以可读原因发射发送失败事件，
/// 而不是空等到状态等待超时。
///
/// 用内存双向流模拟已升级的 WS 连接，避免依赖 TLS 与真实网络。
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn peer_download_abort_terminates_sender_ws() {
    use std::sync::atomic::AtomicBool;
    use std::time::Duration;

    use futures_util::{SinkExt, StreamExt};
    use localsend_core::bridge::mta::ws;
    use localsend_core::bridge::mta::{DownloadPhase, MtaContext};
    use tokio_tungstenite::tungstenite::protocol::Role;
    use tokio_tungstenite::tungstenite::Message;
    use tokio_tungstenite::WebSocketStream;

    let dir = temp_dir("peer_abort");
    let source = dir.join("payload.bin");
    std::fs::write(&source, b"payload").unwrap();

    let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(64);
    let (phase_tx, _phase_rx) = tokio::sync::watch::channel(DownloadPhase::Idle);
    let ctx = Arc::new(MtaContext {
        task_id: "mta-abort-1".into(),
        sender_id: "abcd".into(),
        sender_name: "HandySendTest".into(),
        files: vec![mta::MtaFileEntry {
            fd_send: -1,
            path: source.to_string_lossy().to_string(),
            entry_name: "1/payload.bin".into(),
            last_modified_ms: None,
            size_bytes: 7,
        }],
        file_name: "payload.bin".into(),
        mime_type: "application/zip".into(),
        thumbnail: None,
        file_count: 1,
        total_size: 7,
        text_content: None,
        sender_brand_id: None,
        sender_brand: None,
        event_tx: Some(event_tx),
        phase_tx: phase_tx.clone(),
        ws_connected: AtomicBool::new(false),
        cancel: CancellationToken::new(),
        fds_consumed: std::sync::Arc::new(std::sync::Mutex::new(vec![false])),
        download_served: AtomicBool::new(false),
        peer_frames: std::sync::atomic::AtomicUsize::new(0),
        reject_pending: AtomicBool::new(false),
        reject_notify: tokio::sync::Notify::new(),
    });

    let (server_io, client_io) = tokio::io::duplex(64 * 1024);
    let ws_task = tokio::spawn(async move {
        ws::run_ws(server_io, ctx).await;
    });
    let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;

    // 1) 接收 versionNegotiation → 回版本 ack 以通过协商
    let negotiation = client.next().await.unwrap().unwrap();
    let negotiation_text = negotiation.into_text().unwrap();
    assert!(
        negotiation_text.contains("versionNegotiation"),
        "应收到版本协商: {negotiation_text}"
    );
    client
        .send(Message::text(
            "ack:0:versionNegotiation?{\"version\":1,\"threadLimit\":5}",
        ))
        .await
        .unwrap();

    // 2) 接收 sendRequest → 回空 ack
    let request = client.next().await.unwrap().unwrap();
    let request_text = request.into_text().unwrap();
    assert!(
        request_text.contains("sendRequest"),
        "应收到 sendRequest: {request_text}"
    );
    client
        .send(Message::text("ack:1:sendRequest"))
        .await
        .unwrap();

    // 3) 下载开始后对端中途取消：等价于下载连接被断开（Rust 侧置 PeerAborted）
    phase_tx.send_replace(DownloadPhase::Started);
    phase_tx.send_replace(DownloadPhase::PeerAborted);

    // 发送端须在有限时间内终结 WS 状态机
    let finished = tokio::time::timeout(Duration::from_secs(5), ws_task).await;
    assert!(finished.is_ok(), "对端取消后发送端应在有限时间内终止");

    // 且须以可读原因发射发送失败事件（复用既有事件，不新增变体）
    let mut failure_reason: Option<String> = None;
    while let Ok(event) = event_rx.try_recv() {
        if let BridgeEvent::MtaSendFailed { reason } = event {
            failure_reason = Some(reason);
        }
    }
    let reason = failure_reason.expect("应发射 MtaSendFailed");
    assert!(reason.contains("取消"), "失败原因应可读: {reason}");

    let _ = std::fs::remove_dir_all(&dir);
}

/// 构造发送端 WS 收尾用例的共享上下文（空文件清单 + 相位通道）。
fn close_test_context(
    task_id: &str,
    event_tx: tokio::sync::mpsc::Sender<BridgeEvent>,
) -> (
    Arc<localsend_core::bridge::mta::MtaContext>,
    tokio::sync::watch::Sender<localsend_core::bridge::mta::DownloadPhase>,
) {
    use localsend_core::bridge::mta::{DownloadPhase, MtaContext};
    use std::sync::atomic::AtomicBool;

    let (phase_tx, _phase_rx) = tokio::sync::watch::channel(DownloadPhase::Idle);
    let ctx = Arc::new(MtaContext {
        task_id: task_id.into(),
        sender_id: "abcd".into(),
        sender_name: "HandySendTest".into(),
        files: vec![mta::MtaFileEntry {
            fd_send: -1,
            path: String::new(),
            entry_name: "1/payload.bin".into(),
            last_modified_ms: None,
            size_bytes: 0,
        }],
        file_name: "payload.bin".into(),
        mime_type: "application/zip".into(),
        thumbnail: None,
        file_count: 1,
        total_size: 0,
        text_content: None,
        sender_brand_id: None,
        sender_brand: None,
        event_tx: Some(event_tx),
        phase_tx: phase_tx.clone(),
        ws_connected: AtomicBool::new(false),
        cancel: CancellationToken::new(),
        fds_consumed: std::sync::Arc::new(std::sync::Mutex::new(vec![false])),
        download_served: AtomicBool::new(false),
        peer_frames: std::sync::atomic::AtomicUsize::new(0),
        reject_pending: AtomicBool::new(false),
        reject_notify: tokio::sync::Notify::new(),
    });
    (ctx, phase_tx)
}

/// 完成版本协商与 sendRequest 握手（回 ack），使状态机进入等待对端状态阶段。
async fn complete_sender_handshake<S>(client: &mut tokio_tungstenite::WebSocketStream<S>)
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message;

    let negotiation = client.next().await.unwrap().unwrap().into_text().unwrap();
    assert!(
        negotiation.contains("versionNegotiation"),
        "应收到版本协商: {negotiation}"
    );
    client
        .send(Message::text(
            "ack:0:versionNegotiation?{\"version\":1,\"threadLimit\":5}",
        ))
        .await
        .unwrap();
    let request = client.next().await.unwrap().unwrap().into_text().unwrap();
    assert!(
        request.contains("sendRequest"),
        "应收到 sendRequest: {request}"
    );
    client
        .send(Message::text("ack:1:sendRequest"))
        .await
        .unwrap();
}

/// 持续读取连接直到其以「终止」方式结束，途中若收到 WebSocket 关闭帧即判定失败
/// （会话终止不得发送关闭帧）。返回途中读到的全部文本帧（按到达顺序）。
async fn drain_until_terminated<S>(
    client: &mut tokio_tungstenite::WebSocketStream<S>,
) -> Vec<String>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    use futures_util::StreamExt;
    use tokio_tungstenite::tungstenite::Message;

    let mut texts: Vec<String> = Vec::new();
    loop {
        match client.next().await {
            Some(Ok(Message::Close(frame))) => {
                panic!("会话终止不得发送 WebSocket 关闭帧，实得: {frame:?}");
            }
            Some(Ok(Message::Text(text))) => texts.push(text.as_str().to_string()),
            Some(Ok(Message::Binary(bytes))) => {
                texts.push(String::from_utf8_lossy(&bytes).to_string());
            }
            Some(Ok(_)) => {}
            // 连接结束（EOF 或重置）即「连接终止」，正常收尾
            Some(Err(_)) | None => return texts,
        }
    }
}

/// 会话终止以连接终止结束：全程不发送 WebSocket 关闭帧；结束类指示（对状态的回执）
/// 在终止前已写出并被对端读到。
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn termination_sends_no_close_frame_and_delivers_directive_first() {
    use std::time::Duration;

    use futures_util::SinkExt;
    use localsend_core::bridge::mta::ws;
    use tokio_tungstenite::tungstenite::protocol::Role;
    use tokio_tungstenite::tungstenite::Message;
    use tokio_tungstenite::WebSocketStream;

    let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(64);
    let (ctx, _phase_tx) = close_test_context("mta-term-generic", event_tx);
    let (server_io, client_io) = tokio::io::duplex(64 * 1024);
    let task = tokio::spawn(async move { ws::run_ws(server_io, ctx).await });
    let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;
    complete_sender_handshake(&mut client).await;

    client
        .send(Message::text(
            "action:99:status?{\"taskId\":\"mta-term-generic\",\"type\":1,\"reason\":\"ok\"}",
        ))
        .await
        .unwrap();

    // 连接以终止方式结束：其间不得出现关闭帧，且对状态的回执应在终止之前读到
    let texts = tokio::time::timeout(Duration::from_secs(10), drain_until_terminated(&mut client))
        .await
        .expect("会话应在有界时间内以连接终止结束");
    assert!(
        texts.iter().any(|t| t.contains("ack:99:status")),
        "终止前应已写出对状态的回执（结束类指示）: {texts:?}"
    );

    let finished = tokio::time::timeout(Duration::from_secs(10), task).await;
    assert!(finished.is_ok(), "会话应在有界时间内结束");

    let mut completed = false;
    while let Ok(event) = event_rx.try_recv() {
        if matches!(event, BridgeEvent::MtaSendCompleted { .. }) {
            completed = true;
        }
    }
    assert!(completed, "成功收尾应发射 MtaSendCompleted");
}

/// 对端主动先行关闭：走「对端先行关闭」快路径直接结束，不等待终止前宽限。
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn peer_first_close_takes_fast_path() {
    use std::time::Duration;

    use futures_util::SinkExt;
    use localsend_core::bridge::mta::ws;
    use tokio_tungstenite::tungstenite::protocol::Role;
    use tokio_tungstenite::tungstenite::Message;
    use tokio_tungstenite::WebSocketStream;

    let (event_tx, _event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(64);
    let (ctx, _phase_tx) = close_test_context("mta-term-fast", event_tx);
    let (server_io, client_io) = tokio::io::duplex(64 * 1024);
    let task = tokio::spawn(async move { ws::run_ws(server_io, ctx).await });
    let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;
    complete_sender_handshake(&mut client).await;

    client
        .send(Message::text(
            "action:99:status?{\"taskId\":\"mta-term-fast\",\"type\":1,\"reason\":\"ok\"}",
        ))
        .await
        .unwrap();
    // 对端立即先行关闭（无状态码关闭帧）
    client.send(Message::Close(None)).await.unwrap();
    client.flush().await.unwrap();

    let start = tokio::time::Instant::now();
    let finished = tokio::time::timeout(Duration::from_secs(5), task).await;
    assert!(finished.is_ok(), "对端先行关闭后会话应结束");
    assert!(
        start.elapsed() < Duration::from_secs(1),
        "对端先行关闭应走快路径（不等待终止前宽限），实耗={:?}",
        start.elapsed()
    );
}

/// 收到对端成功终态后：发送端以**连接终止**结束会话（不发关闭帧），
/// 且仅在收到终态并回送确认之后终止；对端对本次传输仍记为成功。
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn terminal_status_terminates_without_close_frame_after_ack() {
    use std::time::Duration;

    use futures_util::SinkExt;
    use localsend_core::bridge::mta::ws;
    use tokio_tungstenite::tungstenite::protocol::Role;
    use tokio_tungstenite::tungstenite::Message;
    use tokio_tungstenite::WebSocketStream;

    let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(64);
    let (ctx, _phase_tx) = close_test_context("mta-term-ok", event_tx);
    let (server_io, client_io) = tokio::io::duplex(64 * 1024);
    let task = tokio::spawn(async move { ws::run_ws(server_io, ctx).await });
    let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;
    complete_sender_handshake(&mut client).await;

    // 对端回送成功终态
    client
        .send(Message::text(
            "action:99:status?{\"taskId\":\"mta-term-ok\",\"type\":1,\"reason\":\"ok\"}",
        ))
        .await
        .unwrap();

    // 连接以终止方式结束（不发关闭帧）；其间应先读到对状态的回执（结束类指示）
    let texts = tokio::time::timeout(Duration::from_secs(10), drain_until_terminated(&mut client))
        .await
        .expect("应在有界时间内以连接终止结束");
    assert!(
        texts.iter().any(|t| t.contains("ack:99:status")),
        "终止前应先回送对状态的回执: {texts:?}"
    );

    let finished = tokio::time::timeout(Duration::from_secs(10), task).await;
    assert!(finished.is_ok(), "会话应结束并释放连接");

    let mut completed = false;
    while let Ok(event) = event_rx.try_recv() {
        match event {
            BridgeEvent::MtaSendCompleted { .. } => completed = true,
            // 正常成功收尾仍判成功：不得出现失败/拒绝/部分完成事件
            BridgeEvent::MtaSendFailed { reason } => {
                panic!("成功收尾不得发射 MtaSendFailed: {reason}")
            }
            BridgeEvent::MtaSendRejected { reason } => {
                panic!("成功收尾不得发射 MtaSendRejected: {reason}")
            }
            BridgeEvent::MtaSendPartial { reason } => {
                panic!("成功收尾不得发射 MtaSendPartial: {reason}")
            }
            _ => {}
        }
    }
    assert!(completed, "应发射 MtaSendCompleted");
}

/// 对端不主动关闭：发送端仍须在有界收尾内以连接终止退出，不无限等待。
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn peer_silent_terminal_exits_within_bounded_wait() {
    use std::time::Duration;

    use futures_util::SinkExt;
    use localsend_core::bridge::mta::ws;
    use tokio_tungstenite::tungstenite::protocol::Role;
    use tokio_tungstenite::tungstenite::Message;
    use tokio_tungstenite::WebSocketStream;

    let (event_tx, _event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(64);
    let (ctx, _phase_tx) = close_test_context("mta-term-silent", event_tx);
    let (server_io, client_io) = tokio::io::duplex(64 * 1024);
    let task = tokio::spawn(async move { ws::run_ws(server_io, ctx).await });
    let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;
    complete_sender_handshake(&mut client).await;

    client
        .send(Message::text(
            "action:99:status?{\"taskId\":\"mta-term-silent\",\"type\":1,\"reason\":\"ok\"}",
        ))
        .await
        .unwrap();

    // 故意不主动关闭：发送端须在「对端先行关闭宽限 + 终止前送达宽限」的有界上限内以连接终止退出
    let start = tokio::time::Instant::now();
    let texts = tokio::time::timeout(Duration::from_secs(10), drain_until_terminated(&mut client))
        .await
        .expect("对端不主动关闭时应以连接终止有界结束");
    assert!(
        texts.iter().any(|t| t.contains("ack:99:status")),
        "终止前应先回送对状态的回执: {texts:?}"
    );
    let finished = tokio::time::timeout(Duration::from_secs(10), task).await;
    assert!(finished.is_ok(), "对端不主动关闭时状态机应在有界收尾内退出");
    assert!(
        start.elapsed() < Duration::from_secs(5),
        "收尾等待应受有界上限约束，实耗={:?}",
        start.elapsed()
    );
}

/// 本地取消：状态机须经会话终止有界退出，且不等待「终止前送达宽限」
/// （取消路径无结束类指示，不引入额外延时）。
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancel_path_terminates_within_bound_without_grace() {
    use std::time::Duration;

    use localsend_core::bridge::mta::ws;
    use tokio_tungstenite::tungstenite::protocol::Role;
    use tokio_tungstenite::WebSocketStream;

    let (event_tx, _event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(64);
    let (ctx, _phase_tx) = close_test_context("mta-term-cancel", event_tx);
    let cancel_ctx = Arc::clone(&ctx);
    let (server_io, client_io) = tokio::io::duplex(64 * 1024);
    let task = tokio::spawn(async move { ws::run_ws(server_io, ctx).await });
    let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;
    complete_sender_handshake(&mut client).await;

    // 触发本地取消（停服令牌）：状态机应立即经会话终止有界退出
    let start = tokio::time::Instant::now();
    cancel_ctx.cancel.cancel();
    let finished = tokio::time::timeout(Duration::from_secs(5), task).await;
    assert!(finished.is_ok(), "取消后状态机应经会话终止有界退出");
    assert!(
        start.elapsed() < Duration::from_secs(1),
        "取消路径不得等待终止前宽限，实耗={:?}",
        start.elapsed()
    );
}

/// 取消（拒绝）路径：先回送取消状态（结束类指示），随后以连接终止结束会话（不发关闭帧）。
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn reject_path_terminates_without_close_frame_after_cancel_status() {
    use std::time::Duration;

    use localsend_core::bridge::mta::ws;
    use tokio_tungstenite::tungstenite::protocol::Role;
    use tokio_tungstenite::WebSocketStream;

    let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(64);
    let (ctx, _phase_tx) = close_test_context("mta-term-reject", event_tx);
    let reject_ctx = Arc::clone(&ctx);
    let (server_io, client_io) = tokio::io::duplex(64 * 1024);
    let task = tokio::spawn(async move { ws::run_ws(server_io, ctx).await });
    let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;
    complete_sender_handshake(&mut client).await;

    reject_ctx.mark_reject_pending();
    // 先读到取消状态，随后连接以终止方式结束（不发关闭帧）
    let texts = tokio::time::timeout(Duration::from_secs(10), drain_until_terminated(&mut client))
        .await
        .expect("回送取消状态后应以连接终止结束");
    assert!(
        texts
            .iter()
            .any(|t| t.contains("status") && t.contains("user refuse")),
        "应回送取消状态: {texts:?}"
    );

    let finished = tokio::time::timeout(Duration::from_secs(10), task).await;
    assert!(finished.is_ok(), "回送取消状态后状态机应结束");

    let mut reject_sent = false;
    while let Ok(event) = event_rx.try_recv() {
        if matches!(event, BridgeEvent::MtaRejectSent { .. }) {
            reject_sent = true;
        }
    }
    assert!(reject_sent, "应发射 MtaRejectSent");
}

/// 失败收尾路径：版本不兼容即失败，失败事件发出后以连接终止结束（不发关闭帧）；
/// 失败路径无结束类指示，不等待，立即结束。
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn fail_path_terminates_without_close_frame_after_failure_event() {
    use std::time::Duration;

    use futures_util::{SinkExt, StreamExt};
    use localsend_core::bridge::mta::ws;
    use tokio_tungstenite::tungstenite::protocol::Role;
    use tokio_tungstenite::tungstenite::Message;
    use tokio_tungstenite::WebSocketStream;

    let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(64);
    let (ctx, _phase_tx) = close_test_context("mta-term-fail", event_tx);
    let (server_io, client_io) = tokio::io::duplex(64 * 1024);
    let task = tokio::spawn(async move { ws::run_ws(server_io, ctx).await });
    let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;

    let negotiation = client.next().await.unwrap().unwrap().into_text().unwrap();
    assert!(negotiation.contains("versionNegotiation"));
    // 回送不兼容版本：发送端以失败收尾
    client
        .send(Message::text(
            "ack:0:versionNegotiation?{\"version\":2,\"threadLimit\":5}",
        ))
        .await
        .unwrap();

    // 失败路径以连接终止结束，不发关闭帧
    let start = tokio::time::Instant::now();
    let _texts = tokio::time::timeout(Duration::from_secs(5), drain_until_terminated(&mut client))
        .await
        .expect("失败路径应以连接终止结束");
    assert!(
        start.elapsed() < Duration::from_secs(1),
        "失败路径无结束类指示，不得引入额外等待，实耗={:?}",
        start.elapsed()
    );

    let finished = tokio::time::timeout(Duration::from_secs(5), task).await;
    assert!(finished.is_ok(), "失败收尾后状态机应结束");

    let mut failed = false;
    while let Ok(event) = event_rx.try_recv() {
        if matches!(event, BridgeEvent::MtaSendFailed { .. }) {
            failed = true;
        }
    }
    assert!(failed, "应发射 MtaSendFailed");
}

/// 对端拒绝终态（`type=3` + `user refuse`）：仍以拒绝语义终结（发 MtaSendRejected，不发成功/失败），
/// 且以连接终止有界结束、不发关闭帧。保护既有取消/拒绝语义不因收尾方式变化而回退。
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn refused_status_terminates_with_rejection_without_close_frame() {
    use std::time::Duration;

    use futures_util::SinkExt;
    use localsend_core::bridge::mta::ws;
    use tokio_tungstenite::tungstenite::protocol::Role;
    use tokio_tungstenite::tungstenite::Message;
    use tokio_tungstenite::WebSocketStream;

    let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(64);
    let (ctx, _phase_tx) = close_test_context("mta-term-refuse", event_tx);
    let (server_io, client_io) = tokio::io::duplex(64 * 1024);
    let task = tokio::spawn(async move { ws::run_ws(server_io, ctx).await });
    let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;
    complete_sender_handshake(&mut client).await;

    // 对端拒绝（终止类型 + 用户拒绝原因）
    client
        .send(Message::text(
            "action:99:status?{\"taskId\":\"mta-term-refuse\",\"type\":3,\"reason\":\"user refuse\"}",
        ))
        .await
        .unwrap();

    let start = tokio::time::Instant::now();
    let texts = tokio::time::timeout(Duration::from_secs(10), drain_until_terminated(&mut client))
        .await
        .expect("拒绝终态应以连接终止有界结束");
    assert!(
        texts.iter().any(|t| t.contains("ack:99:status")),
        "终止前应先回送对状态的回执: {texts:?}"
    );
    assert!(
        start.elapsed() < Duration::from_secs(5),
        "拒绝终态收尾应受有界上限约束，实耗={:?}",
        start.elapsed()
    );

    let finished = tokio::time::timeout(Duration::from_secs(5), task).await;
    assert!(finished.is_ok(), "拒绝终态应结束会话");

    let mut rejected = false;
    let mut unexpected = false;
    while let Ok(event) = event_rx.try_recv() {
        match event {
            BridgeEvent::MtaSendRejected { .. } => rejected = true,
            BridgeEvent::MtaSendCompleted { .. } | BridgeEvent::MtaSendFailed { .. } => {
                unexpected = true;
            }
            _ => {}
        }
    }
    assert!(rejected, "拒绝终态应发射 MtaSendRejected");
    assert!(!unexpected, "拒绝终态不得发射成功/失败事件");
}
