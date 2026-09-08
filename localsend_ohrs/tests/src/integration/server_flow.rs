//! 服务器接收文件流程管道测试。
//!
//! 通过 `event_tx`/`event_rx` 直接消费事件流，验证
//! PrepareUpload → accept → SessionEnd 完整事件链。无 mock、无轮询、
//! 不使用 std::thread::sleep——事件到达即断言（阻塞 recv）。

#![cfg(test)]

use std::sync::Arc;
use std::sync::Mutex;

use futures_util::StreamExt;
use localsend::http::client::LsHttpClientV2;
use localsend::http::dto_v2::PrepareUploadRequestDtoV2;
use localsend::model::discovery::{DeviceType, ProtocolType, PROTOCOL_VERSION_V2};
use localsend::model::transfer::FileDto;
use tokio::sync::mpsc;

use localsend_core::bridge::event::{BridgeError, BridgeEvent, SessionEndReason};
use localsend_core::bridge::identity;
use localsend_core::bridge::server;
use localsend_core::bridge::state::BridgeState;

/// 从事件流中等待下一个匹配谓词的桥接事件。
async fn wait_for_event(
    event_rx: &mut mpsc::Receiver<BridgeEvent>,
    predicate: impl Fn(&BridgeEvent) -> bool,
) -> BridgeEvent {
    loop {
        let event = event_rx.recv().await.expect("事件流已关闭，等待事件失败");
        if predicate(&event) {
            return event;
        }
    }
}

/// 构造一个带 event_tx 的 BridgeState（模拟 NAPI 环境注入）。
fn new_state_with_event_tx() -> (Arc<Mutex<BridgeState>>, mpsc::Receiver<BridgeEvent>) {
    let (event_tx, event_rx) = mpsc::channel::<BridgeEvent>(64);
    let state = Arc::new(Mutex::new(BridgeState::new()));
    state.lock().unwrap().event_tx = Some(event_tx);
    (state, event_rx)
}

fn sender_info() -> localsend::http::dto_v2::RegisterDtoV2 {
    localsend::http::dto_v2::RegisterDtoV2 {
        alias: "HandySend-Sender".to_string(),
        version: PROTOCOL_VERSION_V2.to_string(),
        device_model: Some("HarmonyOS".to_string()),
        device_type: None,
        fingerprint: "sender-fingerprint".to_string(),
        port: 53317,
        protocol: ProtocolType::Http,
        download: false,
    }
}

fn file_dto(id: &str, name: &str, size: u64) -> FileDto {
    FileDto {
        id: id.to_string(),
        file_name: name.to_string(),
        size,
        file_type: "application/octet-stream".to_string(),
        sha256: None,
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

/// 管道验证：PrepareUpload → accept_transfer → 上传 → SessionEnd(Finished)。
#[tokio::test]
async fn test_server_prepare_upload_flow() {
    let (state, mut event_rx) = new_state_with_event_tx();

    // 初始化身份
    let persist_dir = format!("{}/handysend-flow-server/", std::env::temp_dir().display());
    identity::init_with_persisted_identity(
        &state,
        "HandySend-Server".to_string(),
        DeviceType::Mobile,
        &persist_dir,
    )
    .unwrap();
    let _ = std::fs::remove_dir_all(&persist_dir);

    // 接收文件保存到项目根 temp/（已 gitignore），避免残留进 tests/ 目录
    let recv_dir = format!(
        "{}/../../temp/handysend-flow-recv/",
        env!("CARGO_MANIFEST_DIR")
    );
    std::fs::create_dir_all(&recv_dir).unwrap();
    {
        let mut s = state.lock().unwrap();
        s.save_dir = recv_dir.clone();
    }

    // 启动服务器（port 0 → OS 分配实际端口）
    let port = server::start_server(state.clone(), 0, false, true, None, None, None)
        .await
        .expect("启动服务器失败");

    // 验证 ServerStarted 事件
    let started = wait_for_event(&mut event_rx, |e| {
        matches!(e, BridgeEvent::ServerStarted { .. })
    })
    .await;
    match started {
        BridgeEvent::ServerStarted { port: p } => assert_eq!(p, port),
        _ => unreachable!(),
    }

    // 发送方发起 prepare-upload（后台任务——服务器在 accept 后才响应）
    let file_a = file_dto("file-a", "照片.jpg", 100_000);
    let client_for_prepare = LsHttpClientV2::try_new_without_cert().unwrap();
    let request_task = tokio::spawn(async move {
        client_for_prepare
            .prepare_upload(
                ProtocolType::Http,
                "127.0.0.1",
                port,
                None,
                prepare_upload_request(&[file_a.clone()]),
                None,
                tokio_util::sync::CancellationToken::new(),
            )
            .await
            .expect("prepare_upload 请求失败")
    });

    // 事件流收到 PrepareUpload 事件
    let prepare = wait_for_event(&mut event_rx, |e| {
        matches!(e, BridgeEvent::PrepareUpload { .. })
    })
    .await;
    let session_id = match &prepare {
        BridgeEvent::PrepareUpload {
            session_id,
            sender_ip,
            sender_alias,
            files,
            ..
        } => {
            assert_eq!(sender_ip, "127.0.0.1");
            assert_eq!(sender_alias, "HandySend-Sender");
            assert_eq!(files.len(), 1);
            assert_eq!(files[0].file_name, "照片.jpg");
            assert_eq!(files[0].size, 100_000);
            session_id.clone()
        }
        _ => unreachable!(),
    };

    // 用户接受传输
    server::accept_transfer(&state, &session_id, &["file-a".to_string()])
        .expect("accept_transfer 失败");

    // 等待发送方收到 200 + token
    let result = request_task.await.expect("发送任务异常");
    let response = result.response.expect("未收到上传令牌");
    assert_eq!(response.files.len(), 1);

    // 上传文件内容
    let client = LsHttpClientV2::try_new_without_cert().unwrap();
    let bytes: Vec<u8> = (0..100_000u32).map(|i| i as u8).collect();
    let (tx, rx) = mpsc::channel::<bytes::Bytes>(4);
    let tx_for_send = tx.clone();
    let bytes_clone = bytes.clone();
    tokio::spawn(async move {
        for chunk in bytes_clone.chunks(1024) {
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
            ProtocolType::Http,
            "127.0.0.1",
            port,
            None,
            &response.session_id,
            "file-a",
            &response.files["file-a"],
            body,
            tokio_util::sync::CancellationToken::new(),
        )
        .await
        .expect("上传失败");

    // 事件流收到 SessionEnd(Finished)
    let end = wait_for_event(&mut event_rx, |e| {
        matches!(e, BridgeEvent::SessionEnd { .. })
    })
    .await;
    match end {
        BridgeEvent::SessionEnd {
            session_id: sid,
            reason,
        } => {
            assert_eq!(sid, session_id);
            assert_eq!(reason, SessionEndReason::Finished);
        }
        _ => unreachable!(),
    }

    // 清理
    server::stop_server(&state);
    let _ = std::fs::remove_dir_all(&recv_dir);
}

/// 幂等性验证：重复 start_server 返回 AlreadyRunning。
#[tokio::test]
async fn test_server_start_idempotent() {
    let (state, mut event_rx) = new_state_with_event_tx();

    identity::init_with_persisted_identity(
        &state,
        "HandySend-Server".to_string(),
        DeviceType::Mobile,
        "",
    )
    .unwrap();

    let port = server::start_server(state.clone(), 0, false, true, None, None, None)
        .await
        .expect("首次启动失败");
    let _ = wait_for_event(&mut event_rx, |e| {
        matches!(e, BridgeEvent::ServerStarted { .. })
    })
    .await;

    // 重复启动 → AlreadyRunning
    let err = server::start_server(state.clone(), 0, false, true, None, None, None)
        .await
        .expect_err("重复启动应返回 AlreadyRunning");
    assert!(matches!(err, BridgeError::AlreadyRunning));

    // stop 后再次启动成功（快速 stop→start 无残留）
    server::stop_server(&state);
    let port2 = server::start_server(state.clone(), 0, false, true, None, None, None)
        .await
        .expect("stop 后重新启动失败");
    assert!(port2 > 0);

    server::stop_server(&state);
    // 未启动时 stop 幂等 Ok
    server::stop_server(&state);
}

/// create_server 全链路验证：JSON 配置启动（含 saveDir）→ 接收真实文件
/// → 断言文件保存到 save_dir 且内容一致。
///
/// 回归防护：create_server 的 save_dir 若在 start_server 之后才写入
/// state，服务器事件循环会捕获空值导致保存路径错误（只有文件名）——
/// 本测试通过断言落盘位置拦截该类时序缺陷。
#[tokio::test]
async fn test_create_server_saves_file_to_save_dir() {
    use futures_util::StreamExt;

    let (state, mut event_rx) = new_state_with_event_tx();
    identity::init_with_persisted_identity(
        &state,
        "HandySend-Server".to_string(),
        DeviceType::Mobile,
        "",
    )
    .unwrap();

    // 独立临时接收目录
    let save_dir = format!(
        "{}/handysend-create-server-test/",
        std::env::temp_dir().display()
    );
    let _ = std::fs::remove_dir_all(&save_dir);
    std::fs::create_dir_all(&save_dir).unwrap();

    // 通过 create_server（真实 App 路径：JSON 配置 → 状态 → 启动）启动
    let config = serde_json::json!({
        "alias": "HandySend-Server",
        "deviceType": "mobile",
        "deviceModel": "HarmonyOS",
        "port": 0,
        "useHttps": false,
        "saveDir": save_dir,
        "verifyChecksums": false,
    })
    .to_string();
    let result_json = server::create_server(state.clone(), &config)
        .await
        .expect("create_server 失败");
    let result: serde_json::Value = serde_json::from_str(&result_json).unwrap();
    let port = result["port"].as_u64().unwrap() as u16;
    assert!(port > 0);

    // 发送方 prepare-upload（后台任务）
    let file_name = "create_server_saved.txt";
    let file_content = b"hello create_server save_dir".to_vec();
    let file_a = file_dto("file-a", file_name, file_content.len() as u64);
    let client_for_prepare = LsHttpClientV2::try_new_without_cert().unwrap();
    let request_task = tokio::spawn(async move {
        client_for_prepare
            .prepare_upload(
                ProtocolType::Http,
                "127.0.0.1",
                port,
                None,
                prepare_upload_request(&[file_a.clone()]),
                None,
                tokio_util::sync::CancellationToken::new(),
            )
            .await
            .expect("prepare_upload 请求失败")
    });

    // 等 PrepareUpload 事件并接受
    let prepare = wait_for_event(&mut event_rx, |e| {
        matches!(e, BridgeEvent::PrepareUpload { .. })
    })
    .await;
    let session_id = match &prepare {
        BridgeEvent::PrepareUpload {
            session_id, files, ..
        } => {
            assert_eq!(files.len(), 1);
            assert_eq!(files[0].file_name, file_name);
            session_id.clone()
        }
        _ => unreachable!(),
    };
    server::accept_transfer(&state, &session_id, &["file-a".to_string()])
        .expect("accept_transfer 失败");

    // 拿到 token 后上传真实文件内容
    let response = request_task
        .await
        .expect("发送任务异常")
        .response
        .expect("未收到上传令牌");
    let client = LsHttpClientV2::try_new_without_cert().unwrap();
    let (tx, rx) = mpsc::channel::<bytes::Bytes>(4);
    let tx_for_send = tx.clone();
    let content_clone = file_content.clone();
    tokio::spawn(async move {
        for chunk in content_clone.chunks(16) {
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
            ProtocolType::Http,
            "127.0.0.1",
            port,
            None,
            &response.session_id,
            "file-a",
            &response.files["file-a"],
            body,
            tokio_util::sync::CancellationToken::new(),
        )
        .await
        .expect("上传失败");

    // 等会话结束
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

    // 核心断言：文件保存到 save_dir 且内容一致
    let saved_path = format!("{save_dir}{file_name}");
    assert!(
        std::path::Path::new(&saved_path).exists(),
        "接收文件应保存到 save_dir: {saved_path}"
    );
    let saved = std::fs::read(&saved_path).expect("读取保存文件失败");
    assert_eq!(saved, file_content, "保存文件内容应与发送一致");

    server::stop_server(&state);
    let _ = std::fs::remove_dir_all(&save_dir);
}
