//! MTA 跨层流程集成测试（host 目标可直接运行）。
//!
//! 覆盖：
//! - 应用层消息构造/解析、sendRequest JSON、status 分类（纯函数）；
//! - 发送端流式写出 ZIP（Stored、fd 直读（path 回退））→ 接收端流式解析/落盘的往返与条目元数据；
//! - 接收端 Rust 主导下载（HTTPS + 跳过证书校验）端到端往返；
//! - 服务器生命周期（`start_server` 绑定端口、不预打包，`stop_server` 清理）；起服失败路径 fd 收尾。

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
        classify_status("{\"type\":3,\"reason\":\"no\"}"),
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
        fd_crc: -1,
        fd_send: -1,
        path: source.to_string_lossy().to_string(),
        entry_name: "1/hello.txt".into(),
        last_modified_ms: Some(1_600_000_000_000),
        crc32: 0,
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
    let options = ZipParseOptions::new(16, 1024 * 1024, Arc::new(|| false));
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
    let options = ZipParseOptions::new(16, 64 * 1024 * 1024, Arc::new(|| false));
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
    let options = ZipParseOptions::new(16, 64 * 1024 * 1024, Arc::new(|| false));
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

/// 端到端 fd 直读：模拟 ArkTS 每文件 `openSync` 打开两个独立读取入口
/// （fdCrc 供起服 CRC 预计算、fdSend 供下载发送），随配置 JSON 移交 Rust，
/// 经 `start_server` → `receive_download` 完成整链往返，断言落盘产物的
/// 名称/大小/内容/修改时间与源文件逐项一致。fd 移交后所有权归 Rust，
/// 测试不再关闭（`from_raw_fd` 是唯一关闭点）。
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn receive_download_roundtrip_with_file_fds() {
    let _guard = SERVER_TEST_LOCK.lock().await;
    let dir = temp_dir("fd_recv_roundtrip");
    let source = dir.join("photo.jpg");
    let payload = "fd-direct payload ".repeat(500).into_bytes();
    std::fs::write(&source, &payload).unwrap();
    let source_modified_ms: u64 = 1_600_000_000_000;

    // 模拟 ArkTS 移交：同一文件两次独立 open，fd 随 JSON 交给 Rust
    let fd_crc = File::open(&source).unwrap().into_raw_fd();
    let fd_send = File::open(&source).unwrap().into_raw_fd();

    let config_json = serde_json::json!({
        "bindIp": "127.0.0.1",
        "port": 0,
        "taskId": "mta-fd-1",
        "senderId": "abcd",
        "senderName": "HandySendTest",
        "files": [{
            "fdCrc": fd_crc,
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
    let options = ZipParseOptions::new(16, 64 * 1024 * 1024, Arc::new(|| false));
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

/// 查询 fd 是否仍被占用（host Linux：fcntl(F_GETFD) 在 fd 已关闭时返回 EBADF）。
/// SAFETY：F_GETFD 仅查询描述符标志，无副作用；测试运行目标为 host Linux。
fn fd_is_open(fd: i32) -> bool {
    let result = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    result >= 0
}

/// 起服失败路径 fd 收尾：条目 A 携带真实 fdCrc/fdSend，条目 B 无 fd 且
/// path 不存在 → 预计算在 B 处失败，`start_server` 必须返回错误且不 panic，
/// 失败前未消费的 fd（A 的 fdSend）与已消费路径（A 的 fdCrc）全部由 Rust 关闭，
/// 测试侧不再触碰（fd 所有权已移交）。
#[test]
fn start_server_failure_closes_transferred_fds() {
    let _guard = SERVER_TEST_LOCK.blocking_lock();
    let dir = temp_dir("fd_failure");
    let source = dir.join("a.bin");
    std::fs::write(&source, b"cleanup-fd-payload").unwrap();

    let fd_a_crc = File::open(&source).unwrap().into_raw_fd();
    let fd_a_send = File::open(&source).unwrap().into_raw_fd();

    let config_json = serde_json::json!({
        "bindIp": "127.0.0.1",
        "port": 0,
        "taskId": "mta-fd-fail-1",
        "senderId": "abcd",
        "senderName": "HandySendTest",
        "files": [
            {
                "fdCrc": fd_a_crc,
                "fdSend": fd_a_send,
                "path": "",
                "entryName": "1/a.bin",
            },
            { "path": "/nonexistent/mta-missing.bin", "entryName": "2/missing.bin" },
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
    assert!(result.is_err(), "预计算失败时 start_server 应返回错误");

    // 失败收尾后两个 fd 均已被 Rust 关闭（fdCrc 由预计算消费关闭、fdSend 由收尾关闭）
    assert!(!fd_is_open(fd_a_crc), "条目 A 的 fdCrc 应在失败路径关闭");
    assert!(!fd_is_open(fd_a_send), "条目 A 的 fdSend 应在失败路径关闭");
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
            fd_crc: -1,
            fd_send: -1,
            path: source.to_string_lossy().to_string(),
            entry_name: "1/payload.bin".into(),
            last_modified_ms: None,
            crc32: 0,
            size_bytes: 7,
        }],
        file_name: "payload.bin".into(),
        mime_type: "application/zip".into(),
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
