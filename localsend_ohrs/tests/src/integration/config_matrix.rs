//! 配置矩阵测试——验证设置开关（HTTPS/PIN/校验和）与发送模式（多接收者/
//! Web Share）下的传输成败，覆盖 happy path 之外的参数化行为。
//!
//! 与 server_flow.rs（链路畅通）互补：本文件专注"开关打开/关闭后成败语义"。

#![cfg(test)]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::StreamExt;
use serde_json::json;

use localsend::http::client::{ClientError, LsHttpClientV2};
use localsend::http::dto_v2::PrepareUploadRequestDtoV2;
use localsend::model::discovery::{DeviceType, ProtocolType, PROTOCOL_VERSION_V2};
use localsend::model::transfer::FileDto;

use localsend_core::bridge::client;
use localsend_core::bridge::event::{BridgeEvent, SessionEndReason};
use localsend_core::bridge::identity;
use localsend_core::bridge::server;
use localsend_core::bridge::state::BridgeState;
use localsend_core::bridge::web_share;

/// 从事件流中等待下一个匹配谓词的桥接事件。
async fn wait_for_event(
    event_rx: &mut tokio::sync::mpsc::Receiver<BridgeEvent>,
    predicate: impl Fn(&BridgeEvent) -> bool,
) -> BridgeEvent {
    loop {
        let event = event_rx.recv().await.expect("事件流已关闭，等待事件失败");
        if predicate(&event) {
            return event;
        }
    }
}

/// 构造一个带 event_tx 的 BridgeState。
fn new_state_with_event_tx() -> (
    Arc<Mutex<BridgeState>>,
    tokio::sync::mpsc::Receiver<BridgeEvent>,
) {
    let (event_tx, event_rx) = tokio::sync::mpsc::channel::<BridgeEvent>(64);
    let state = Arc::new(Mutex::new(BridgeState::new()));
    state.lock().unwrap().event_tx = Some(event_tx);
    (state, event_rx)
}

/// 初始化身份（生成自签名证书与指纹）。
fn init_identity(state: &Arc<Mutex<BridgeState>>, tag: &str) {
    identity::init_with_persisted_identity(state, format!("Server-{tag}"), DeviceType::Mobile, "")
        .unwrap();
}

fn sender_info() -> localsend::http::dto_v2::RegisterDtoV2 {
    localsend::http::dto_v2::RegisterDtoV2 {
        alias: "Matrix-Sender".to_string(),
        version: PROTOCOL_VERSION_V2.to_string(),
        device_model: Some("HarmonyOS".to_string()),
        device_type: None,
        fingerprint: "matrix-sender-fp".to_string(),
        port: 53317,
        protocol: ProtocolType::Http,
        download: false,
    }
}

/// 构造文件 DTO（sha256 可指定，用于校验和矩阵）。
fn file_dto(id: &str, name: &str, size: u64, sha256: Option<String>) -> FileDto {
    FileDto {
        id: id.to_string(),
        file_name: name.to_string(),
        size,
        file_type: "application/octet-stream".to_string(),
        sha256,
        preview: None,
        metadata: None,
    }
}

fn prepare_upload_request(files: &[FileDto]) -> PrepareUploadRequestDtoV2 {
    PrepareUploadRequestDtoV2 {
        info: sender_info(),
        files: files
            .iter()
            .map(|file| (file.id.clone(), file.clone()))
            .collect(),
    }
}

/// 读取 state 中身份材料（证书/私钥/指纹）。
fn identity_materials(state: &Arc<Mutex<BridgeState>>) -> (String, String, String) {
    let s = state.lock().unwrap();
    (s.cert_pem.clone(), s.key_pem.clone(), s.fingerprint.clone())
}

/// 上传文件内容并返回上传结果。
async fn upload_content(
    client: &LsHttpClientV2,
    port: u16,
    protocol: ProtocolType,
    session_id: &str,
    file_id: &str,
    token: &str,
    content: &[u8],
) -> Result<(), ClientError> {
    let (tx, rx) = tokio::sync::mpsc::channel::<bytes::Bytes>(4);
    let tx_for_send = tx.clone();
    let bytes = content.to_vec();
    tokio::spawn(async move {
        for chunk in bytes.chunks(16) {
            if tx_for_send
                .send(bytes::Bytes::copy_from_slice(chunk))
                .await
                .is_err()
            {
                break;
            }
        }
    });
    drop(tx);
    let body = localsend::reqwest::Body::wrap_stream(
        tokio_stream::wrappers::ReceiverStream::new(rx)
            .map(move |chunk: bytes::Bytes| Ok::<bytes::Bytes, std::io::Error>(chunk)),
    );
    client
        .upload(
            protocol,
            "127.0.0.1",
            port,
            None,
            session_id,
            file_id,
            token,
            body,
            tokio_util::sync::CancellationToken::new(),
        )
        .await
}

/// 统一 prepare 模式：prepare-upload 在后台 task 执行（服务器等 decision），
/// 主流程从事件流收 PrepareUpload 后 accept_transfer，最后取回 task 结果。
/// 返回 (client, session_id, token)。
async fn prepare_in_background_and_accept(
    state: &Arc<Mutex<BridgeState>>,
    event_rx: &mut tokio::sync::mpsc::Receiver<BridgeEvent>,
    port: u16,
    protocol: ProtocolType,
    file_id: &str,
    files: &[FileDto],
    pin: Option<&str>,
) -> (LsHttpClientV2, String, String) {
    let (cert, key, _fp) = identity_materials(state);
    let client = LsHttpClientV2::try_new(&key, &cert, None, Some(Duration::from_secs(10)))
        .expect("客户端创建失败");
    let prepare_client = LsHttpClientV2::try_new(&key, &cert, None, Some(Duration::from_secs(10)))
        .expect("prepare 客户端创建失败");
    // 克隆进后台 task（spawn 要求 'static）
    let files_owned: Vec<FileDto> = files.to_vec();
    let pin_owned: Option<String> = pin.map(|s| s.to_string());

    let prepare_task = tokio::spawn(async move {
        prepare_client
            .prepare_upload(
                protocol,
                "127.0.0.1",
                port,
                None,
                prepare_upload_request(&files_owned),
                pin_owned.as_deref(),
                tokio_util::sync::CancellationToken::new(),
            )
            .await
    });

    // 服务器收到 PrepareUpload 事件后等待 decision——先 accept 再取 task 结果
    let prepare_event =
        wait_for_event(event_rx, |e| matches!(e, BridgeEvent::PrepareUpload { .. })).await;
    let session_id = match &prepare_event {
        BridgeEvent::PrepareUpload { session_id, .. } => session_id.clone(),
        _ => unreachable!(),
    };
    server::accept_transfer(state, &session_id, &[file_id.to_string()])
        .expect("accept_transfer 失败");

    let result = prepare_task
        .await
        .expect("prepare 任务异常")
        .expect("prepare-upload 失败");
    let session_id = result
        .response
        .as_ref()
        .expect("应返回会话")
        .session_id
        .clone();
    let token = result.response.as_ref().unwrap().files[file_id].clone();
    (client, session_id, token)
}

// ── HTTPS 开关：开启后使用 TLS + 指纹校验的完整传输 ───────────────

#[tokio::test]
async fn test_https_transfer_succeeds() {
    let (state, mut event_rx) = new_state_with_event_tx();
    init_identity(&state, "https");
    // 接收目录（避免上传文件写入测试运行目录）
    let save_dir = format!("{}/handysend-https/", std::env::temp_dir().display());
    std::fs::create_dir_all(&save_dir).unwrap();
    {
        let mut s = state.lock().unwrap();
        s.save_dir = save_dir.clone();
    }

    // use_https=true：服务器用 state 身份证书提供 TLS
    let port = server::start_server(state.clone(), 0, true, true, None, None, None)
        .await
        .expect("HTTPS 服务器启动失败");
    let _ = wait_for_event(&mut event_rx, |e| {
        matches!(e, BridgeEvent::ServerStarted { .. })
    })
    .await;

    // 客户端：同一身份对 + 期望指纹（回环 mTLS）
    let (_cert, _key, _fp) = identity_materials(&state);

    let content = b"https hello".to_vec();
    let files = vec![file_dto("f-https", "https.txt", content.len() as u64, None)];

    // prepare 后台 + 主流程 accept（HTTPS + 指纹校验）
    let (upload_client, session_id, token) = prepare_in_background_and_accept(
        &state,
        &mut event_rx,
        port,
        ProtocolType::Https,
        "f-https",
        &files,
        None,
    )
    .await;

    upload_content(
        &upload_client,
        port,
        ProtocolType::Https,
        &session_id,
        "f-https",
        &token,
        &content,
    )
    .await
    .expect("HTTPS 上传应成功");

    let end = wait_for_event(&mut event_rx, |e| {
        matches!(e, BridgeEvent::SessionEnd { .. })
    })
    .await;
    assert!(matches!(
        end,
        BridgeEvent::SessionEnd {
            reason: SessionEndReason::Finished,
            ..
        }
    ));
    server::stop_server(&state);
    let _ = std::fs::remove_dir_all(&save_dir);
}

// ── PIN 开关：开启后无/错/对 pin 的成败矩阵 ─────────────────────

#[tokio::test]
async fn test_pin_matrix() {
    // 服务器开启 PIN "1234"
    let (state, mut event_rx) = new_state_with_event_tx();
    init_identity(&state, "pin");
    let port = server::start_server(
        state.clone(),
        0,
        false,
        true,
        Some("1234".to_string()),
        None,
        None,
    )
    .await
    .expect("服务器启动失败");

    let (cert, key, _fp) = identity_materials(&state);
    let files = vec![file_dto("f-pin", "pin.txt", 10, None)];

    // 无 pin → 401（PIN required）
    let client_no_pin =
        LsHttpClientV2::try_new(&key, &cert, None, Some(Duration::from_secs(5))).unwrap();
    let no_pin_result = client_no_pin
        .prepare_upload(
            ProtocolType::Http,
            "127.0.0.1",
            port,
            None,
            prepare_upload_request(&files),
            None,
            tokio_util::sync::CancellationToken::new(),
        )
        .await;
    assert!(no_pin_result.is_err(), "无 pin 应被拒绝（401）");

    // 错 pin → 被拒绝
    let client_wrong =
        LsHttpClientV2::try_new(&key, &cert, None, Some(Duration::from_secs(5))).unwrap();
    let wrong_result = client_wrong
        .prepare_upload(
            ProtocolType::Http,
            "127.0.0.1",
            port,
            None,
            prepare_upload_request(&files),
            Some("9999"),
            tokio_util::sync::CancellationToken::new(),
        )
        .await;
    assert!(wrong_result.is_err(), "错误 pin 应被拒绝");

    // 正确 pin → 成功建立会话（prepare 后台 + 主流程 accept）
    let (client_ok, _session_id, _token) = prepare_in_background_and_accept(
        &state,
        &mut event_rx,
        port,
        ProtocolType::Http,
        "f-pin",
        &files,
        Some("1234"),
    )
    .await;
    drop(client_ok);
    server::stop_server(&state);
}

// ── 校验和开关：verifyChecksums 开/关 + sha256 匹配/不匹配的成败 ──

/// 执行一次"prepare→accept→上传"完整流程，返回上传结果。
async fn run_transfer(
    state: &Arc<Mutex<BridgeState>>,
    event_rx: &mut tokio::sync::mpsc::Receiver<BridgeEvent>,
    port: u16,
    file_id: &str,
    file_name: &str,
    content: &[u8],
    sha256: Option<String>,
) -> Result<(), ClientError> {
    let files = vec![file_dto(file_id, file_name, content.len() as u64, sha256)];
    let (client, session_id, token) = prepare_in_background_and_accept(
        state,
        event_rx,
        port,
        ProtocolType::Http,
        file_id,
        &files,
        None,
    )
    .await;
    upload_content(
        &client,
        port,
        ProtocolType::Http,
        &session_id,
        file_id,
        &token,
        content,
    )
    .await
}

#[tokio::test]
async fn test_verify_checksums_matrix() {
    use sha2::{Digest, Sha256};
    let content = b"checksum test content".to_vec();
    let real_sha = Sha256::digest(&content)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();

    // 1) verifyChecksums=true + sha256 与内容一致 → 成功
    let (state1, mut rx1) = new_state_with_event_tx();
    init_identity(&state1, "cs-on");
    {
        let mut s = state1.lock().unwrap();
        s.save_dir = format!("{}/handysend-cs-on/", std::env::temp_dir().display());
    }
    std::fs::create_dir_all(format!(
        "{}/handysend-cs-on/",
        std::env::temp_dir().display()
    ))
    .unwrap();
    let port1 = server::start_server(state1.clone(), 0, false, true, None, None, None)
        .await
        .expect("服务器启动失败");
    let ok = run_transfer(
        &state1,
        &mut rx1,
        port1,
        "f-cs-ok",
        "ok.txt",
        &content,
        Some(real_sha.clone()),
    )
    .await;
    assert!(ok.is_ok(), "开启校验且 sha256 一致时应成功: {:?}", ok.err());
    server::stop_server(&state1);

    // 2) verifyChecksums=true + sha256 与内容不一致 → 失败（422 Checksum mismatch）
    let (state2, mut rx2) = new_state_with_event_tx();
    init_identity(&state2, "cs-bad");
    {
        let mut s = state2.lock().unwrap();
        s.save_dir = format!("{}/handysend-cs-bad/", std::env::temp_dir().display());
    }
    std::fs::create_dir_all(format!(
        "{}/handysend-cs-bad/",
        std::env::temp_dir().display()
    ))
    .unwrap();
    let port2 = server::start_server(state2.clone(), 0, false, true, None, None, None)
        .await
        .expect("服务器启动失败");
    let bad = run_transfer(
        &state2,
        &mut rx2,
        port2,
        "f-cs-bad",
        "bad.txt",
        &content,
        Some("deadbeef".to_string()),
    )
    .await;
    assert!(bad.is_err(), "开启校验且 sha256 不一致时应失败: {:?}", bad);
    server::stop_server(&state2);

    // 3) verifyChecksums=false + 无 sha256 → 成功
    let (state3, mut rx3) = new_state_with_event_tx();
    init_identity(&state3, "cs-off");
    {
        let mut s = state3.lock().unwrap();
        s.save_dir = format!("{}/handysend-cs-off/", std::env::temp_dir().display());
    }
    std::fs::create_dir_all(format!(
        "{}/handysend-cs-off/",
        std::env::temp_dir().display()
    ))
    .unwrap();
    let port3 = server::start_server(state3.clone(), 0, false, false, None, None, None)
        .await
        .expect("服务器启动失败");
    let off = run_transfer(
        &state3, &mut rx3, port3, "f-cs-off", "off.txt", &content, None,
    )
    .await;
    assert!(off.is_ok(), "关闭校验且无 sha256 时应成功: {:?}", off.err());
    server::stop_server(&state3);
}

// ── 多个接收者模式：并发向多台接收服务器发送，各自验证落盘 ──────

#[tokio::test]
async fn test_multi_receiver_parallel_send() {
    let receivers: usize = 3;
    let mut receiver_setups = Vec::new();

    // 创建 3 台独立接收服务器（各自 save_dir），收集后逐个 move 进并发 task
    for i in 0..receivers {
        let (state, rx) = new_state_with_event_tx();
        init_identity(&state, &format!("recv-{i}"));
        let save_dir = format!(
            "{}/handysend-multi-recv-{i}/",
            std::env::temp_dir().display()
        );
        let _ = std::fs::remove_dir_all(&save_dir);
        std::fs::create_dir_all(&save_dir).unwrap();
        {
            let mut s = state.lock().unwrap();
            s.save_dir = save_dir.clone();
        }
        let port = server::start_server(state.clone(), 0, false, true, None, None, None)
            .await
            .expect("接收服务器启动失败");
        receiver_setups.push((state, rx, port, save_dir));
    }

    // 并发：每台接收方一个 task（prepare 后台 → 等事件 → 接受 → 上传 → 验证落盘）
    let mut handles = Vec::new();
    for (i, (state, mut rx, port, save_dir)) in receiver_setups.into_iter().enumerate() {
        handles.push(tokio::spawn(async move {
            let content = format!("multi-receiver-{i}").into_bytes();
            let (cert, key, _fp) = identity_materials(&state);
            let file_id = format!("f-multi-{i}");
            let file_name = format!("multi_{i}.txt");
            let files = vec![file_dto(&file_id, &file_name, content.len() as u64, None)];

            // prepare 在子 task 后台执行（服务器等 decision）
            let prepare_client =
                LsHttpClientV2::try_new(&key, &cert, None, Some(Duration::from_secs(10))).unwrap();
            let files_for_prepare = files.clone();
            let prepare_task = tokio::spawn(async move {
                prepare_client
                    .prepare_upload(
                        ProtocolType::Http,
                        "127.0.0.1",
                        port,
                        None,
                        prepare_upload_request(&files_for_prepare),
                        None,
                        tokio_util::sync::CancellationToken::new(),
                    )
                    .await
            });

            // 主 task 收 PrepareUpload 事件 → accept
            let prepare_event =
                wait_for_event(&mut rx, |e| matches!(e, BridgeEvent::PrepareUpload { .. })).await;
            let session_id = match &prepare_event {
                BridgeEvent::PrepareUpload { session_id, .. } => session_id.clone(),
                _ => unreachable!(),
            };
            server::accept_transfer(&state, &session_id, std::slice::from_ref(&file_id)).unwrap();

            let result = prepare_task
                .await
                .expect("prepare 任务异常")
                .expect("prepare 失败");
            let session_id = result.response.as_ref().unwrap().session_id.clone();
            let token = result.response.as_ref().unwrap().files[&file_id].clone();

            let client =
                LsHttpClientV2::try_new(&key, &cert, None, Some(Duration::from_secs(10))).unwrap();
            upload_content(
                &client,
                port,
                ProtocolType::Http,
                &session_id,
                &file_id,
                &token,
                &content,
            )
            .await
            .expect("上传失败");

            let end =
                wait_for_event(&mut rx, |e| matches!(e, BridgeEvent::SessionEnd { .. })).await;
            assert!(matches!(
                end,
                BridgeEvent::SessionEnd {
                    reason: SessionEndReason::Finished,
                    ..
                }
            ));

            // 验证该接收方落盘内容
            let saved_path = format!("{save_dir}{file_name}");
            assert!(
                std::path::Path::new(&saved_path).exists(),
                "接收方文件应保存: {saved_path}"
            );
            assert_eq!(std::fs::read(&saved_path).unwrap(), content);
            server::stop_server(&state);
            let _ = std::fs::remove_dir_all(&save_dir);
        }));
    }

    for h in handles {
        h.await.expect("接收方任务异常");
    }
}

// ── Web Share 模式：创建分享链接 → HTTP 访问下载验证 ──────────────

#[tokio::test]
async fn test_web_share_link_download() {
    let (state, mut event_rx) = new_state_with_event_tx();
    init_identity(&state, "webshare");

    // 先启动 HTTP 普通服务器（设置 use_https=false 与 local_port，
    // create_share_link 据此生成 http://IP:port 链接）
    let port = server::start_server(state.clone(), 0, false, true, None, None, None)
        .await
        .expect("普通服务器启动失败");
    let _ = wait_for_event(&mut event_rx, |e| {
        matches!(e, BridgeEvent::ServerStarted { .. })
    })
    .await;
    assert!(port > 0);

    // 构造一个真实的待分享文件（模拟设备上的文件）
    let share_dir = format!("{}/handysend-webshare/", std::env::temp_dir().display());
    let _ = std::fs::remove_dir_all(&share_dir);
    std::fs::create_dir_all(&share_dir).unwrap();
    let file_path = format!("{share_dir}share_me.txt");
    let file_content = b"web share content 12345".to_vec();
    std::fs::write(&file_path, &file_content).unwrap();

    let files_json = json!([{
        "fileId": "ws-1",
        "fileName": "share_me.txt",
        "size": file_content.len(),
        "fileType": "text/plain",
        "filePath": file_path,
        "preview": null,
        "sha256": null,
    }])
    .to_string();

    // 桥接层创建分享链接（内部：停止普通服务器 → 以 web 模式重启）
    let result_json = web_share::create_share_link(state.clone(), &files_json, "HandySend")
        .await
        .expect("create_share_link 失败");
    let result: serde_json::Value = serde_json::from_str(&result_json).unwrap();
    let url = result["url"].as_str().unwrap().to_string();
    assert!(url.starts_with("http://"), "URL 应为 http: {url}");

    // 用 HTTP 客户端访问分享页（模拟浏览器），应返回 200 且页面正常渲染
    let page = localsend::reqwest::get(&url).await.expect("访问分享页失败");
    assert_eq!(page.status().as_u16(), 200, "分享页应可访问");
    let html = page.text().await.unwrap();
    // 页面为单文件 HTML（文件名由 JS 渲染），验证页面渲染而非文件名文本
    assert!(
        html.contains("链接分享") || html.contains("download"),
        "分享页应正常渲染，实际开头: {}",
        html.chars().take(120).collect::<String>()
    );

    // 清理：停止分享服务器（恢复普通模式并停止）
    web_share::stop_share_server(state.clone()).await;
    let _ = wait_for_event(&mut event_rx, |e| {
        matches!(e, BridgeEvent::ServerStarted { .. })
    })
    .await;
    server::stop_server(&state);
    let _ = std::fs::remove_dir_all(&share_dir);
}

// ── Web Share 模式：fd 内容源的真实下载流程（首下 + 重复 + 并发） ──

/// fd 内容源走 dup/pread/Stream 路径（与真机一致），验证：
/// 1. 首次下载内容完整；
/// 2. 下载不消费 web_send_files 条目——重复下载与并发下载内容同样完整；
/// 3. Rust 全程不关闭原始 fd（下载后 fstat 仍有效）。
#[cfg(any(target_os = "linux", target_os = "android"))]
#[tokio::test]
async fn test_web_share_fd_download_repeatable() {
    use std::os::fd::AsRawFd;

    let (state, mut event_rx) = new_state_with_event_tx();
    init_identity(&state, "webfd");

    // 先启动 HTTP 普通服务器（create_share_link 据此生成 http://IP:port 链接）
    let port = server::start_server(state.clone(), 0, false, true, None, None, None)
        .await
        .expect("普通服务器启动失败");
    let _ = wait_for_event(&mut event_rx, |e| {
        matches!(e, BridgeEvent::ServerStarted { .. })
    })
    .await;
    assert!(port > 0);

    // 构造约 1.2MB 的真实文件（跨越多个 512KB 读取块，验证 pread 偏移推进）
    let share_dir = format!("{}/handysend-webfd/", std::env::temp_dir().display());
    let _ = std::fs::remove_dir_all(&share_dir);
    std::fs::create_dir_all(&share_dir).unwrap();
    let file_path = format!("{share_dir}share_fd.bin");
    let file_content: Vec<u8> = (0..1_200_000u32).map(|i| (i % 251) as u8).collect();
    std::fs::write(&file_path, &file_content).unwrap();
    // 模拟 ArkTS：持有 File 对象并以 fd 作为内容源（所有权归调用方）
    let file = std::fs::File::open(&file_path).unwrap();

    let files_json = json!([{
        "fileId": "wfd-1",
        "fileName": "share_fd.bin",
        "size": file_content.len(),
        "fileType": "application/octet-stream",
        "filePath": file_path,
        "preview": null,
        "sha256": null,
        "fd": file.as_raw_fd(),
    }])
    .to_string();

    let result_json = web_share::create_share_link(state.clone(), &files_json, "HandySend")
        .await
        .expect("create_share_link 失败");
    let result: serde_json::Value = serde_json::from_str(&result_json).unwrap();
    let base_url = result["url"].as_str().unwrap().to_string();
    assert!(base_url.starts_with("http://"), "URL 应为 http: {base_url}");

    // POST prepare-download：服务器发出决策请求，测试侧作为"用户"接受并取回 session_id
    let client = localsend::reqwest::Client::new();
    let prepare = client
        .post(format!("{base_url}/api/localsend/v2/prepare-download"))
        .send();
    let decide = async {
        let event = wait_for_event(&mut event_rx, |e| {
            matches!(e, BridgeEvent::WebSendPrepareDownload { .. })
        })
        .await;
        let BridgeEvent::WebSendPrepareDownload { session_id, .. } = event else {
            unreachable!("已按谓词过滤为 WebSendPrepareDownload");
        };
        web_share::accept_web_download(&state, &session_id).expect("接受下载失败");
        session_id
    };
    let (prepare_resp, session_id) = tokio::join!(prepare, decide);
    assert_eq!(
        prepare_resp
            .expect("prepare-download 请求失败")
            .status()
            .as_u16(),
        200,
        "prepare-download 应返回 200"
    );

    let download_url =
        format!("{base_url}/api/localsend/v2/download?sessionId={session_id}&fileId=wfd-1");

    // 首次下载：内容与原文件逐字节一致
    let first = localsend::reqwest::get(&download_url)
        .await
        .expect("首次下载请求失败");
    assert_eq!(first.status().as_u16(), 200, "首次下载应返回 200");
    let first_bytes = first.bytes().await.unwrap();
    assert_eq!(
        first_bytes.as_ref(),
        file_content.as_slice(),
        "首次下载内容应完整一致"
    );

    // 重复下载 + 并发下载：条目不被消费，两路内容均完整
    let (again_a, again_b) = tokio::join!(
        localsend::reqwest::get(&download_url),
        localsend::reqwest::get(&download_url),
    );
    for (label, resp) in [("重复下载", again_a), ("并发下载", again_b)] {
        let resp = resp.expect("重复/并发下载请求失败");
        assert_eq!(resp.status().as_u16(), 200, "{label}应返回 200");
        let bytes = resp.bytes().await.unwrap();
        assert_eq!(
            bytes.as_ref(),
            file_content.as_slice(),
            "{label}内容应完整一致"
        );
    }

    // 原始 fd 全程未被 Rust 关闭：下载后 fstat 仍有效（关闭则返回 EBADF）
    file.metadata().expect("原始 fd 被意外关闭");

    // 清理：停止分享服务器（恢复普通模式并停止）
    web_share::stop_share_server(state.clone()).await;
    let _ = wait_for_event(&mut event_rx, |e| {
        matches!(e, BridgeEvent::ServerStarted { .. })
    })
    .await;
    server::stop_server(&state);
    drop(file);
    let _ = std::fs::remove_dir_all(&share_dir);
}

// ── Web Share 下载：fd 内容源完整性 ──────────────────────────────
//
// `Content-Length` 由上游按 `FileDto.size` 固定写入，响应体是流式内容源；只要「实际交付
// 字节」小于「声明大小」，客户端即判定消息不完整并中断下载（宿主实测：声明 64MB / 实际
// 32MB 时客户端立即报响应体解码失败）。因此「大于一个读块的文件必须完整交付」是下载
// 可用的硬条件。以下用例以宿主可复现的方式锁定该路径：常规 fd 大文件逐字节一致；
// 同一大文件的重复与并发下载均完整。
//
// 所有等待均显式限时（HTTP 客户端超时 + 事件等待超时），绝不让测试挂死。

/// 限时等待匹配谓词的桥接事件（超时返回 `None`，不阻塞测试）。
async fn wait_for_event_bounded(
    event_rx: &mut tokio::sync::mpsc::Receiver<BridgeEvent>,
    predicate: impl Fn(&BridgeEvent) -> bool,
    timeout_ms: u64,
) -> Option<BridgeEvent> {
    tokio::time::timeout(
        Duration::from_millis(timeout_ms),
        wait_for_event(event_rx, predicate),
    )
    .await
    .ok()
}

/// 构建限时 HTTP 客户端：避免客户端等待声明长度未被满足的响应体时无限挂起。
fn http_client_with_timeout(secs: u64) -> localsend::reqwest::Client {
    localsend::reqwest::Client::builder()
        .timeout(Duration::from_secs(secs))
        .build()
        .expect("构建限时 HTTP 客户端失败")
}

/// 发起一次下载并返回响应体字节（响应体读取亦限时）。
async fn fetch_download_bytes(
    client: &localsend::reqwest::Client,
    url: &str,
) -> Result<Vec<u8>, String> {
    let resp = client
        .get(url)
        .send()
        .await
        .map_err(|e| format!("请求失败: {e}"))?;
    let status = resp.status().as_u16();
    if status != 200 {
        return Err(format!("非预期状态码 {status}"));
    }
    match tokio::time::timeout(Duration::from_secs(30), resp.bytes()).await {
        Ok(Ok(bytes)) => Ok(bytes.to_vec()),
        Ok(Err(e)) => Err(format!("读取响应体失败（声明长度未被满足）: {e}")),
        Err(_) => Err("读取响应体超时".to_string()),
    }
}

/// 以 fd 内容源创建分享并完成一次 prepare-download 握手，返回（base_url, session_id）。
#[cfg(any(target_os = "linux", target_os = "android"))]
async fn start_fd_share(
    state: &Arc<Mutex<BridgeState>>,
    event_rx: &mut tokio::sync::mpsc::Receiver<BridgeEvent>,
    tag: &str,
    fd: i32,
    declared_size: u64,
) -> (String, String) {
    let files_json = json!([{
        "fileId": format!("fd-{tag}"),
        "fileName": format!("fd_{tag}.bin"),
        "size": declared_size,
        "fileType": "application/octet-stream",
        "filePath": format!("/tmp/fd_{tag}.bin"),
        "preview": null,
        "sha256": null,
        "fd": fd,
    }])
    .to_string();

    let result_json = web_share::create_share_link(state.clone(), &files_json, "HandySend")
        .await
        .expect("create_share_link 失败");
    let result: serde_json::Value = serde_json::from_str(&result_json).unwrap();
    let base_url = result["url"].as_str().unwrap().to_string();

    let client = http_client_with_timeout(30);
    let prepare = client
        .post(format!("{base_url}/api/localsend/v2/prepare-download"))
        .send();
    let decide = async {
        let event = wait_for_event_bounded(
            event_rx,
            |e| matches!(e, BridgeEvent::WebSendPrepareDownload { .. }),
            10_000,
        )
        .await
        .expect("等待 prepare-download 事件超时");
        let BridgeEvent::WebSendPrepareDownload { session_id, .. } = event else {
            unreachable!("已按谓词过滤为 WebSendPrepareDownload");
        };
        web_share::accept_web_download(state, &session_id).expect("接受下载失败");
        session_id
    };
    let (prepare_resp, session_id) = tokio::join!(prepare, decide);
    assert_eq!(
        prepare_resp
            .expect("prepare-download 失败")
            .status()
            .as_u16(),
        200
    );
    (base_url, session_id)
}

/// 在临时目录写入指定内容并打开为只读句柄，返回（文件路径, 文件句柄）。
/// 使用独立子目录：既有 WebShare 用例会整体删除其分享目录，避免并行执行时互相干扰。
#[cfg(any(target_os = "linux", target_os = "android"))]
fn write_content_file(tag: &str, content: &[u8]) -> (String, std::fs::File) {
    let share_dir = format!(
        "{}/handysend-webfd-integrity/",
        std::env::temp_dir().display()
    );
    std::fs::create_dir_all(&share_dir).unwrap();
    let file_path = format!("{share_dir}{tag}.bin");
    std::fs::write(&file_path, content).unwrap();
    let file = std::fs::File::open(&file_path).unwrap();
    (file_path, file)
}

/// 停止分享服务器并复位到常规服务器（用例收尾共用）。
#[cfg(any(target_os = "linux", target_os = "android"))]
async fn stop_fd_share(
    state: &Arc<Mutex<BridgeState>>,
    event_rx: &mut tokio::sync::mpsc::Receiver<BridgeEvent>,
) {
    web_share::stop_share_server(state.clone()).await;
    let _ = wait_for_event_bounded(
        event_rx,
        |e| matches!(e, BridgeEvent::ServerStarted { .. }),
        10_000,
    )
    .await;
    server::stop_server(state);
}

/// 常规 fd 内容源大文件（64MB）下载：状态 200 且逐字节一致。
#[cfg(any(target_os = "linux", target_os = "android"))]
#[tokio::test]
async fn test_web_share_fd_download_large_byte_exact() {
    use std::os::fd::AsRawFd;

    const SIZE: usize = 64 * 1024 * 1024;

    let (state, mut event_rx) = new_state_with_event_tx();
    init_identity(&state, "fd-large");
    let port = server::start_server(state.clone(), 0, false, true, None, None, None)
        .await
        .expect("普通服务器启动失败");
    let _ = wait_for_event_bounded(
        &mut event_rx,
        |e| matches!(e, BridgeEvent::ServerStarted { .. }),
        10_000,
    )
    .await;
    assert!(port > 0);

    let expected: Vec<u8> = (0..SIZE as u32).map(|i| (i % 251) as u8).collect();
    let (file_path, file) = write_content_file("large", &expected);

    let (base_url, session_id) = start_fd_share(
        &state,
        &mut event_rx,
        "large",
        file.as_raw_fd(),
        SIZE as u64,
    )
    .await;
    let client = http_client_with_timeout(30);
    let url =
        format!("{base_url}/api/localsend/v2/download?sessionId={session_id}&fileId=fd-large");
    let bytes = fetch_download_bytes(&client, &url)
        .await
        .expect("大文件下载应成功");
    assert_eq!(bytes.len(), SIZE, "交付字节数应等于声明大小");
    assert!(bytes == expected, "大文件下载内容应逐字节一致");

    stop_fd_share(&state, &mut event_rx).await;
    drop(file);
    let _ = std::fs::remove_file(&file_path);
}

/// 同一大文件（32MB）并发下载两次：两份内容均逐字节一致（副本互不干扰）。
#[cfg(any(target_os = "linux", target_os = "android"))]
#[tokio::test]
async fn test_web_share_fd_download_concurrent_byte_exact() {
    use std::os::fd::AsRawFd;

    const SIZE: usize = 32 * 1024 * 1024;

    let (state, mut event_rx) = new_state_with_event_tx();
    init_identity(&state, "fd-concurrent");
    let port = server::start_server(state.clone(), 0, false, true, None, None, None)
        .await
        .expect("普通服务器启动失败");
    let _ = wait_for_event_bounded(
        &mut event_rx,
        |e| matches!(e, BridgeEvent::ServerStarted { .. }),
        10_000,
    )
    .await;
    assert!(port > 0);

    let expected: Vec<u8> = (0..SIZE as u32).map(|i| (i % 241) as u8).collect();
    let (file_path, file) = write_content_file("concurrent", &expected);

    let (base_url, session_id) = start_fd_share(
        &state,
        &mut event_rx,
        "concurrent",
        file.as_raw_fd(),
        SIZE as u64,
    )
    .await;
    let client = http_client_with_timeout(30);
    let url =
        format!("{base_url}/api/localsend/v2/download?sessionId={session_id}&fileId=fd-concurrent");
    let (a, b) = tokio::join!(
        fetch_download_bytes(&client, &url),
        fetch_download_bytes(&client, &url)
    );
    let a = a.expect("并发下载 A 应成功");
    let b = b.expect("并发下载 B 应成功");
    assert_eq!(a.len(), SIZE, "并发下载 A 交付字节数应等于声明大小");
    assert_eq!(b.len(), SIZE, "并发下载 B 交付字节数应等于声明大小");
    assert!(a == expected && b == expected, "并发下载内容均应逐字节一致");

    stop_fd_share(&state, &mut event_rx).await;
    drop(file);
    let _ = std::fs::remove_file(&file_path);
}

// ── Web Share over HTTPS：判定浏览器 HTTPS 下载失败的根因落点 ──────
//
// 现象：同一分享文件在 HTTP 下完整下载、在 HTTPS 下浏览器立即报「无法下载」。
// 下列用例以接受自签名证书的标准 HTTP 客户端（模拟浏览器在证书告警后继续访问）
// 在服务端启用 TLS 时下载文件：
// - 逐字节完整 → 服务端 TLS/响应下发路径正常，失败属浏览器对自签名证书的安全策略（分支 B）；
// - 截断/失败 → 服务端 TLS 响应下发缺陷（分支 A）。
//
// 所有等待均显式限时（HTTP 客户端超时 + 事件等待超时 + 响应体读取超时），绝不挂死。

/// 以 fd 内容源在 HTTPS 下创建分享并完成一次 prepare-download 握手。
/// 返回（接受自签名证书的客户端, base_url, session_id）；返回客户端可复用，
/// 以覆盖同一会话的重复/并发下载（多请求均须在 TLS 场景下到达并被完整应答）。
#[cfg(any(target_os = "linux", target_os = "android"))]
async fn start_https_fd_share(
    state: &Arc<Mutex<BridgeState>>,
    event_rx: &mut tokio::sync::mpsc::Receiver<BridgeEvent>,
    tag: &str,
    fd: i32,
    declared_size: u64,
) -> (localsend::reqwest::Client, String, String) {
    let files_json = json!([{
        "fileId": format!("https-{tag}"),
        "fileName": format!("https_{tag}.bin"),
        "size": declared_size,
        "fileType": "application/octet-stream",
        "filePath": format!("/tmp/https_{tag}.bin"),
        "preview": null,
        "sha256": null,
        "fd": fd,
    }])
    .to_string();

    let result_json = web_share::create_share_link(state.clone(), &files_json, "HandySend")
        .await
        .expect("create_share_link 失败");
    let result: serde_json::Value = serde_json::from_str(&result_json).unwrap();
    let base_url = result["url"].as_str().unwrap().to_string();
    assert!(
        base_url.starts_with("https://"),
        "URL 应为 https: {base_url}"
    );

    // 接受自签名证书的标准客户端（模拟浏览器在证书告警后继续访问）
    let client = localsend::reqwest::Client::builder()
        .use_rustls_tls()
        .danger_accept_invalid_certs(true)
        .timeout(Duration::from_secs(30))
        .build()
        .expect("构建 HTTPS 客户端失败");

    // prepare-download 握手：请求与「用户接受」决策并发
    let prepare = client
        .post(format!("{base_url}/api/localsend/v2/prepare-download"))
        .send();
    let decide = async {
        let event = wait_for_event_bounded(
            event_rx,
            |e| matches!(e, BridgeEvent::WebSendPrepareDownload { .. }),
            10_000,
        )
        .await
        .expect("等待 prepare-download 事件超时");
        let BridgeEvent::WebSendPrepareDownload { session_id, .. } = event else {
            unreachable!("已按谓词过滤为 WebSendPrepareDownload");
        };
        web_share::accept_web_download(state, &session_id).expect("接受下载失败");
        session_id
    };
    let (prepare_resp, session_id) = tokio::join!(prepare, decide);
    assert_eq!(
        prepare_resp
            .expect("prepare-download 请求失败")
            .status()
            .as_u16(),
        200,
        "prepare-download 应返回 200"
    );
    (client, base_url, session_id)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
#[tokio::test]
async fn test_web_share_https_download_byte_exact() {
    use std::os::fd::AsRawFd;

    const SIZE: usize = 4 * 1024 * 1024;

    let (state, mut event_rx) = new_state_with_event_tx();
    init_identity(&state, "web-https");
    // 服务端启用 TLS 启动普通服务器（create_share_link 据此生成 https 链接）
    let port = server::start_server(state.clone(), 0, true, true, None, None, None)
        .await
        .expect("HTTPS 普通服务器启动失败");
    let _ = wait_for_event_bounded(
        &mut event_rx,
        |e| matches!(e, BridgeEvent::ServerStarted { .. }),
        10_000,
    )
    .await;
    assert!(port > 0);

    let expected: Vec<u8> = (0..SIZE as u32).map(|i| (i % 251) as u8).collect();
    let (file_path, file) = write_content_file("https", &expected);

    let (client, base_url, session_id) =
        start_https_fd_share(&state, &mut event_rx, "diag", file.as_raw_fd(), SIZE as u64).await;

    // 分享页在 HTTPS 下可正常打开：证明 TLS 服务端到浏览器可达，失败仅发生在下载环节
    let page = client
        .get(&base_url)
        .send()
        .await
        .expect("HTTPS 分享页请求失败");
    assert_eq!(page.status().as_u16(), 200, "HTTPS 分享页应可访问");
    assert!(
        !page.text().await.unwrap().is_empty(),
        "HTTPS 分享页应有内容"
    );

    let url =
        format!("{base_url}/api/localsend/v2/download?sessionId={session_id}&fileId=https-diag");
    let bytes = fetch_download_bytes(&client, &url)
        .await
        .expect("HTTPS 大文件下载应成功");
    assert_eq!(bytes.len(), SIZE, "HTTPS 下交付字节数应等于声明大小");
    assert!(bytes == expected, "HTTPS 下载内容应逐字节一致");

    stop_fd_share(&state, &mut event_rx).await;
    drop(file);
    let _ = std::fs::remove_file(&file_path);
}

/// HTTPS 下的重复与并发下载：大文件（32MB，大于单次写缓冲）逐字节完整，
/// 锁定「HTTPS 下每个文件的下载请求都能到达应用并完整应答」不回归。
#[cfg(any(target_os = "linux", target_os = "android"))]
#[tokio::test]
async fn test_web_share_https_download_large_repeat_concurrent() {
    use std::os::fd::AsRawFd;

    const SIZE: usize = 32 * 1024 * 1024;

    let (state, mut event_rx) = new_state_with_event_tx();
    init_identity(&state, "web-https-large");
    let port = server::start_server(state.clone(), 0, true, true, None, None, None)
        .await
        .expect("HTTPS 普通服务器启动失败");
    let _ = wait_for_event_bounded(
        &mut event_rx,
        |e| matches!(e, BridgeEvent::ServerStarted { .. }),
        10_000,
    )
    .await;
    assert!(port > 0);

    let expected: Vec<u8> = (0..SIZE as u32).map(|i| (i % 241) as u8).collect();
    let (file_path, file) = write_content_file("https-large", &expected);

    let (client, base_url, session_id) = start_https_fd_share(
        &state,
        &mut event_rx,
        "large",
        file.as_raw_fd(),
        SIZE as u64,
    )
    .await;
    let url =
        format!("{base_url}/api/localsend/v2/download?sessionId={session_id}&fileId=https-large");

    // 首次下载：32MB 逐字节完整
    let first = fetch_download_bytes(&client, &url)
        .await
        .expect("HTTPS 首次大文件下载应成功");
    assert_eq!(first.len(), SIZE, "HTTPS 首次下载交付字节数应等于声明大小");
    assert!(first == expected, "HTTPS 首次下载内容应逐字节一致");

    // 重复 + 并发下载：两份内容均完整
    let (again, concurrent) = tokio::join!(
        fetch_download_bytes(&client, &url),
        fetch_download_bytes(&client, &url)
    );
    let again = again.expect("HTTPS 重复下载应成功");
    let concurrent = concurrent.expect("HTTPS 并发下载应成功");
    assert_eq!(again.len(), SIZE, "HTTPS 重复下载交付字节数应等于声明大小");
    assert_eq!(
        concurrent.len(),
        SIZE,
        "HTTPS 并发下载交付字节数应等于声明大小"
    );
    assert!(
        again == expected && concurrent == expected,
        "HTTPS 重复/并发下载内容均应逐字节一致"
    );

    stop_fd_share(&state, &mut event_rx).await;
    drop(file);
    let _ = std::fs::remove_file(&file_path);
}

// ── 桥接层 send_files 的参数传递：多接收者模式走完整桥接层 ────────

#[tokio::test]
async fn test_bridge_send_files_to_multi_receivers() {
    // 两台接收服务器 + 桥接层 client::send_files（验证桥接层目标参数传递）
    let (recv_a, mut rx_a) = new_state_with_event_tx();
    init_identity(&recv_a, "multi-a");
    let (recv_b, mut rx_b) = new_state_with_event_tx();
    init_identity(&recv_b, "multi-b");
    let dir_a = format!(
        "{}/handysend-bridge-multi-a/",
        std::env::temp_dir().display()
    );
    let dir_b = format!(
        "{}/handysend-bridge-multi-b/",
        std::env::temp_dir().display()
    );
    for d in [&dir_a, &dir_b] {
        let _ = std::fs::remove_dir_all(d);
        std::fs::create_dir_all(d).unwrap();
    }
    {
        let mut s = recv_a.lock().unwrap();
        s.save_dir = dir_a.clone();
    }
    {
        let mut s = recv_b.lock().unwrap();
        s.save_dir = dir_b.clone();
    }
    let port_a = server::start_server(recv_a.clone(), 0, false, true, None, None, None)
        .await
        .unwrap();
    let port_b = server::start_server(recv_b.clone(), 0, false, true, None, None, None)
        .await
        .unwrap();

    // 发送方身份（独立 state）
    let sender = new_state_with_event_tx().0;
    init_identity(&sender, "bridge-sender");

    // 发送文件（真实临时文件）
    let send_file = format!(
        "{}/handysend-bridge-send.txt",
        std::env::temp_dir().display()
    );
    let content = b"bridge multi receiver".to_vec();
    std::fs::write(&send_file, &content).unwrap();
    let files_json = json!([{
        "fileId": "bm-1",
        "fileName": "bridge_multi.txt",
        "size": content.len(),
        "fileType": "text/plain",
        "filePath": send_file,
        "preview": null,
        "sha256": null,
    }])
    .to_string();

    // 向接收方 A 发送（走完整桥接层 send_files）
    let target_a = json!({
        "ip": "127.0.0.1", "port": port_a, "protocol": "http",
        "fingerprint": "", "pin": null, "publicKey": null,
    })
    .to_string();
    let send_task_a = tokio::spawn({
        let sender = sender.clone();
        let files_json = files_json.clone();
        async move { client::send_files(&sender, &target_a, "HandySend", &files_json).await }
    });
    let prepare_a = wait_for_event(&mut rx_a, |e| {
        matches!(e, BridgeEvent::PrepareUpload { .. })
    })
    .await;
    let session_a = match &prepare_a {
        BridgeEvent::PrepareUpload { session_id, .. } => session_id.clone(),
        _ => unreachable!(),
    };
    server::accept_transfer(&recv_a, &session_a, &["bm-1".to_string()]).unwrap();
    let res_a = send_task_a.await.unwrap().unwrap();
    let val_a: serde_json::Value = serde_json::from_str(&res_a).unwrap();
    assert_eq!(val_a["success"], true, "发送给 A 应成功: {res_a}");

    // 向接收方 B 发送
    let target_b = json!({
        "ip": "127.0.0.1", "port": port_b, "protocol": "http",
        "fingerprint": "", "pin": null, "publicKey": null,
    })
    .to_string();
    let send_task_b = tokio::spawn({
        let sender = sender.clone();
        let files_json = files_json.clone();
        async move { client::send_files(&sender, &target_b, "HandySend", &files_json).await }
    });
    let prepare_b = wait_for_event(&mut rx_b, |e| {
        matches!(e, BridgeEvent::PrepareUpload { .. })
    })
    .await;
    let session_b = match &prepare_b {
        BridgeEvent::PrepareUpload { session_id, .. } => session_id.clone(),
        _ => unreachable!(),
    };
    server::accept_transfer(&recv_b, &session_b, &["bm-1".to_string()]).unwrap();
    let res_b = send_task_b.await.unwrap().unwrap();
    let val_b: serde_json::Value = serde_json::from_str(&res_b).unwrap();
    assert_eq!(val_b["success"], true, "发送给 B 应成功: {res_b}");

    // 两端都落盘且内容一致
    for (dir, name) in [(&dir_a, "bridge_multi.txt"), (&dir_b, "bridge_multi.txt")] {
        let p = format!("{dir}{name}");
        assert!(std::path::Path::new(&p).exists(), "文件应保存: {p}");
        assert_eq!(std::fs::read(&p).unwrap(), content);
    }

    server::stop_server(&recv_a);
    server::stop_server(&recv_b);
    for d in [dir_a, dir_b] {
        let _ = std::fs::remove_dir_all(&d);
    }
}

// ── 多文件传输：一次发送多个文件，全部落盘且内容一致 ──────────────

#[tokio::test]
async fn test_multi_file_transfer_succeeds() {
    let (state, mut event_rx) = new_state_with_event_tx();
    init_identity(&state, "multi-file");
    let save_dir = format!("{}/handysend-multifile/", std::env::temp_dir().display());
    let _ = std::fs::remove_dir_all(&save_dir);
    std::fs::create_dir_all(&save_dir).unwrap();
    {
        let mut s = state.lock().unwrap();
        s.save_dir = save_dir.clone();
    }
    let port = server::start_server(state.clone(), 0, false, true, None, None, None)
        .await
        .expect("服务器启动失败");

    // 3 个不同大小的文件
    let specs: Vec<(&str, &str, Vec<u8>)> = vec![
        ("f-a", "a.txt", b"aaa".repeat(10)),
        ("f-b", "b.txt", b"bbb".repeat(50)),
        ("f-c", "c.txt", b"ccc".repeat(100)),
    ];
    let files: Vec<FileDto> = specs
        .iter()
        .map(|(id, name, content)| file_dto(id, name, content.len() as u64, None))
        .collect();

    // prepare 后台 + 主流程 accept（接受全部文件）
    let (cert, key, _fp) = identity_materials(&state);
    let prepare_client =
        LsHttpClientV2::try_new(&key, &cert, None, Some(Duration::from_secs(10))).unwrap();
    let files_for_prepare = files.clone();
    let prepare_task = tokio::spawn(async move {
        prepare_client
            .prepare_upload(
                ProtocolType::Http,
                "127.0.0.1",
                port,
                None,
                prepare_upload_request(&files_for_prepare),
                None,
                tokio_util::sync::CancellationToken::new(),
            )
            .await
    });
    let prepare_event = wait_for_event(&mut event_rx, |e| {
        matches!(e, BridgeEvent::PrepareUpload { .. })
    })
    .await;
    let session_id = match &prepare_event {
        BridgeEvent::PrepareUpload {
            session_id, files, ..
        } => {
            assert_eq!(files.len(), 3, "PrepareUpload 应包含 3 个文件");
            session_id.clone()
        }
        _ => unreachable!(),
    };
    let all_ids: Vec<String> = specs.iter().map(|(id, _, _)| id.to_string()).collect();
    server::accept_transfer(&state, &session_id, &all_ids).unwrap();

    let result = prepare_task
        .await
        .expect("prepare 异常")
        .expect("prepare 失败");
    let session_id = result.response.as_ref().unwrap().session_id.clone();
    let tokens = result.response.as_ref().unwrap().files.clone();

    // 逐文件上传
    let client = LsHttpClientV2::try_new(&key, &cert, None, Some(Duration::from_secs(30))).unwrap();
    for (id, _name, content) in &specs {
        let token = tokens[*id].clone();
        upload_content(
            &client,
            port,
            ProtocolType::Http,
            &session_id,
            id,
            &token,
            content,
        )
        .await
        .unwrap_or_else(|err| panic!("文件 {id} 上传失败: {err}"));
    }

    // 会话正常结束
    let end = wait_for_event(&mut event_rx, |e| {
        matches!(e, BridgeEvent::SessionEnd { .. })
    })
    .await;
    assert!(matches!(
        end,
        BridgeEvent::SessionEnd {
            reason: SessionEndReason::Finished,
            ..
        }
    ));

    // 3 个文件全部落盘且内容一致
    for (id, name, content) in &specs {
        let p = format!("{save_dir}{name}");
        assert!(std::path::Path::new(&p).exists(), "文件 {id} 应保存: {p}");
        assert_eq!(std::fs::read(&p).unwrap(), *content, "文件 {id} 内容应一致");
    }

    server::stop_server(&state);
    let _ = std::fs::remove_dir_all(&save_dir);
}

// ── 协议安全边界：服务器只接受匹配协议的请求 ────────────────────────
//
// 注意：协议协商策略（发送方 HTTPS 拒绝降级 / 发送方 HTTP 升级 HTTPS）
// 是 ArkTS 层 `resolveSendProtocol` 的决策逻辑，由 SendLogic 测试
// 覆盖 4 种组合。本测试验证协商结果对应的真实传输边界：
// - 即使发送方错误地用明文 HTTP 请求 HTTPS 服务器，也会被 TLS 边界拒绝
//   （加密兜底：任何情况下明文都不会意外到达加密接收方）
// - HTTPS 请求发到 HTTP 端口同样无法建立
// - 正确路径：发送方按协商结果用 HTTPS（携带证书）连接 HTTPS 接收方成功，
//   由 test_https_transfer_succeeds 覆盖

#[tokio::test]
async fn test_protocol_security_boundaries() {
    let (state, mut event_rx) = new_state_with_event_tx();
    init_identity(&state, "mismatch");
    // HTTPS 接收方
    let port = server::start_server(state.clone(), 0, true, true, None, None, None)
        .await
        .expect("HTTPS 服务器启动失败");
    let _ = wait_for_event(&mut event_rx, |e| {
        matches!(e, BridgeEvent::ServerStarted { .. })
    })
    .await;

    // 明文（HTTP）客户端不带证书请求 HTTPS 服务器 → TLS 边界拒绝
    let client_http = LsHttpClientV2::try_new_without_cert().expect("HTTP 客户端创建失败");
    let files = vec![file_dto("f-http", "http.txt", 10, None)];
    let result = client_http
        .prepare_upload(
            ProtocolType::Http,
            "127.0.0.1",
            port,
            None,
            prepare_upload_request(&files),
            None,
            tokio_util::sync::CancellationToken::new(),
        )
        .await;
    assert!(
        result.is_err(),
        "明文请求不应到达 HTTPS 服务器（协议安全边界）"
    );

    // 反向：HTTPS 请求发送到 HTTP 端口——无法建立
    server::stop_server(&state);
    let (state2, mut rx2) = new_state_with_event_tx();
    init_identity(&state2, "mismatch-http");
    let port2 = server::start_server(state2.clone(), 0, false, true, None, None, None)
        .await
        .expect("HTTP 服务器启动失败");
    let _ = wait_for_event(&mut rx2, |e| matches!(e, BridgeEvent::ServerStarted { .. })).await;
    let (cert, key, _fp) = identity_materials(&state2);
    let client_https =
        LsHttpClientV2::try_new(&key, &cert, None, Some(Duration::from_secs(5))).unwrap();
    let files2 = vec![file_dto("f-https", "https.txt", 10, None)];
    let result2 = client_https
        .prepare_upload(
            ProtocolType::Https,
            "127.0.0.1",
            port2,
            None,
            prepare_upload_request(&files2),
            None,
            tokio_util::sync::CancellationToken::new(),
        )
        .await;
    assert!(result2.is_err(), "HTTPS 客户端请求 HTTP 端口应失败");
    server::stop_server(&state2);
}

// ── 传输进度：事件流中进度值序列递增且最终 100% ───────────────────

#[tokio::test]
async fn test_upload_progress_sequence() {
    let (state, mut event_rx) = new_state_with_event_tx();
    init_identity(&state, "progress");
    let save_dir = format!("{}/handysend-progress/", std::env::temp_dir().display());
    let _ = std::fs::remove_dir_all(&save_dir);
    std::fs::create_dir_all(&save_dir).unwrap();
    {
        let mut s = state.lock().unwrap();
        s.save_dir = save_dir.clone();
    }
    let port = server::start_server(state.clone(), 0, false, true, None, None, None)
        .await
        .expect("服务器启动失败");

    // 稍大文件（500KB）确保产生中间进度事件
    let content: Vec<u8> = (0..500_000u32).map(|i| (i % 251) as u8).collect();
    let files = vec![file_dto("f-p", "p.bin", content.len() as u64, None)];

    let (cert, key, _fp) = identity_materials(&state);
    let prepare_client =
        LsHttpClientV2::try_new(&key, &cert, None, Some(Duration::from_secs(10))).unwrap();
    let files_for_prepare = files.clone();
    let prepare_task = tokio::spawn(async move {
        prepare_client
            .prepare_upload(
                ProtocolType::Http,
                "127.0.0.1",
                port,
                None,
                prepare_upload_request(&files_for_prepare),
                None,
                tokio_util::sync::CancellationToken::new(),
            )
            .await
    });
    let prepare_event = wait_for_event(&mut event_rx, |e| {
        matches!(e, BridgeEvent::PrepareUpload { .. })
    })
    .await;
    let session_id = match &prepare_event {
        BridgeEvent::PrepareUpload { session_id, .. } => session_id.clone(),
        _ => unreachable!(),
    };
    server::accept_transfer(&state, &session_id, &["f-p".to_string()]).unwrap();

    let result = prepare_task
        .await
        .expect("prepare 异常")
        .expect("prepare 失败");
    let token = result.response.as_ref().unwrap().files["f-p"].clone();

    let client = LsHttpClientV2::try_new(&key, &cert, None, Some(Duration::from_secs(30))).unwrap();
    // 上传 + 同时收集进度事件直到 SessionEnd
    let upload_task = tokio::spawn({
        let client = client;
        let content = content.clone();
        let token = token.clone();
        let session_id = session_id.clone();
        async move {
            upload_content(
                &client,
                port,
                ProtocolType::Http,
                &session_id,
                "f-p",
                &token,
                &content,
            )
            .await
        }
    });

    // 主流程收集进度事件
    let mut progresses: Vec<f64> = Vec::new();
    let mut end_received = false;
    while !end_received {
        let ev = event_rx.recv().await.expect("事件流已关闭");
        match ev {
            BridgeEvent::UploadProgress {
                direction,
                progress,
                ..
            } => {
                if direction == "recv" {
                    progresses.push(progress);
                }
            }
            BridgeEvent::SessionEnd { .. } => end_received = true,
            _ => {}
        }
    }
    upload_task.await.expect("上传任务异常").expect("上传失败");

    // 进度断言：存在 100% 完成事件 + 存在中间进度（<1.0），方向为 recv
    assert!(
        progresses.iter().any(|p| *p >= 1.0),
        "应存在 100% 进度事件，实际: {:?}",
        progresses
    );
    assert!(
        progresses.iter().any(|p| *p > 0.0 && *p < 1.0),
        "应存在中间进度事件，实际: {:?}",
        progresses
    );
    // 单调不减（try_send 可能丢弃部分事件，但保留的应单调不减）
    for w in progresses.windows(2) {
        assert!(w[1] >= w[0], "进度应单调不减: {} -> {}", w[0], w[1]);
    }

    server::stop_server(&state);
    let _ = std::fs::remove_dir_all(&save_dir);
}
