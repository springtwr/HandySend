#![cfg(test)]

use bytes::Bytes;
use futures_util::StreamExt;
use localsend::crypto::hash::sha256_hex;
use localsend::http::client::{ClientError, LsHttpClientV2};
use localsend::http::dto_v2::{PrepareUploadRequestDtoV2, RegisterDtoV2};
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2, SessionEndReasonV2};
use localsend::http::server::{start_with_port, ServerConfigV2};
use localsend::http::state::ClientInfo;
use localsend::model::discovery::{DeviceType, ProtocolType, PROTOCOL_VERSION_V2};
use localsend::model::transfer::FileDto;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot, Mutex};
use tokio_stream::wrappers::ReceiverStream;
use tokio_util::sync::CancellationToken;

struct TestServer {
    port: u16,
    received: Arc<Mutex<HashMap<String, Vec<u8>>>>,
    session_ends: Arc<Mutex<Vec<(String, SessionEndReasonV2)>>>,
    _stop_tx: oneshot::Sender<()>,
}

async fn start_test_server(
    pin: Option<String>,
    accept: bool,
) -> TestServer {
    let _ = tracing_subscriber::fmt().with_test_writer().try_init();
    let received: Arc<Mutex<HashMap<String, Vec<u8>>>> = Arc::new(Mutex::new(HashMap::new()));
    let session_ends: Arc<Mutex<Vec<(String, SessionEndReasonV2)>>> =
        Arc::new(Mutex::new(Vec::new()));

    let (event_tx, mut event_rx) = mpsc::channel::<ServerEventV2>(16);

    tokio::spawn({
        let received = received.clone();
        let session_ends = session_ends.clone();
        async move {
            while let Some(event) = event_rx.recv().await {
                match event {
                    ServerEventV2::Register { .. } => {}
                    ServerEventV2::PrepareUpload {
                        files, decision_tx, ..
                    } => {
                        let decision = match accept {
                            true => {
                                PrepareUploadDecisionV2::Accept(files.keys().cloned().collect())
                            }
                            false => PrepareUploadDecisionV2::Decline,
                        };
                        let _ = decision_tx.send(decision);
                    }
                    ServerEventV2::FileUpload {
                        file_id, target_tx, ..
                    } => {
                        let received = received.clone();
                        let (binary_tx, mut binary_rx) = mpsc::channel(16);
                        let (result_tx, result_rx) = oneshot::channel();
                        let _ = target_tx.send(FileUploadTarget::Stream {
                            binary_tx,
                            result_rx,
                        });
                        tokio::spawn(async move {
                            let mut bytes = Vec::new();
                            while let Some(chunk) = binary_rx.recv().await {
                                bytes.extend_from_slice(&chunk);
                            }
                            received.lock().await.insert(file_id, bytes);
                            let _ = result_tx.send(Ok(()));
                        });
                    }
                    ServerEventV2::SessionEnd { session_id, reason } => {
                        session_ends.lock().await.push((session_id, reason));
                    }
                    ServerEventV2::PrepareUploadAborted { .. } => {}
                    ServerEventV2::CancelReceived { .. } => {}
                }
            }
        }
    });

    let (stop_tx, stop_rx) = oneshot::channel::<()>();

    let handle = start_with_port(
        0,
        None,
        ClientInfo {
            alias: "HandySend-Server".to_string(),
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: Some("HarmonyOS".to_string()),
            device_type: Some(DeviceType::Mobile),
            token: "handysend-fingerprint".to_string(),
        },
        None,
        Some(ServerConfigV2 {
            pin,
            verify_checksums: true,
            event_tx,
        }),
        None,
        stop_rx,
    )
    .await
    .expect("启动服务器失败");

    TestServer {
        port: handle.port(),
        received,
        session_ends,
        _stop_tx: stop_tx,
    }
}

fn sender_info() -> RegisterDtoV2 {
    RegisterDtoV2 {
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

async fn upload_bytes(
    client: &LsHttpClientV2,
    port: u16,
    session_id: &str,
    file_id: &str,
    token: &str,
    bytes: &[u8],
) -> Result<(), ClientError> {
    let (tx, rx) = mpsc::channel::<Bytes>(4);
    let chunks: Vec<Vec<u8>> = bytes.chunks(1024).map(|chunk| chunk.to_vec()).collect();
    let sent = Arc::new(AtomicU64::new(0));
    tokio::spawn(async move {
        for chunk in chunks {
            if tx.send(Bytes::from(chunk)).await.is_err() {
                break;
            }
        }
    });

    let progress = sent.clone();
    let body =
        localsend::reqwest::Body::wrap_stream(ReceiverStream::new(rx).map(move |chunk: Bytes| {
            progress.fetch_add(chunk.len() as u64, Ordering::Relaxed);
            Ok::<Bytes, std::io::Error>(chunk)
        }));
    let result = client
        .upload(
            ProtocolType::Http,
            "127.0.0.1",
            port,
            None,
            session_id,
            file_id,
            token,
            body,
            CancellationToken::new(),
        )
        .await;

    if result.is_ok() {
        assert_eq!(sent.load(Ordering::Relaxed), bytes.len() as u64);
    }

    result
}

fn assert_status(result: Result<impl Sized, ClientError>, expected_status: u16) {
    match result {
        Err(ClientError::StatusCode(err)) => assert_eq!(err.status, expected_status),
        Err(err) => panic!("期望状态码 {expected_status}，实际错误: {err:?}"),
        Ok(_) => panic!("期望状态码 {expected_status}，实际成功"),
    }
}

#[tokio::test]
async fn test_handysend_server_register_and_info() {
    let server = start_test_server(None, true).await;
    let client = LsHttpClientV2::try_new_without_cert().unwrap();

    let response = client
        .register(ProtocolType::Http, "127.0.0.1", server.port, sender_info())
        .await
        .unwrap();
    assert_eq!(response.body.alias, "HandySend-Server");
    assert_eq!(response.body.fingerprint, "handysend-fingerprint");

    let info = client
        .info(ProtocolType::Http, "127.0.0.1", server.port)
        .await
        .unwrap();
    assert_eq!(info.alias, "HandySend-Server");
    assert_eq!(info.fingerprint, "handysend-fingerprint");
}

#[tokio::test]
async fn test_handysend_full_upload_flow() {
    let server = start_test_server(None, true).await;
    let client = LsHttpClientV2::try_new_without_cert().unwrap();

    let file_a = file_dto("file-a", "照片.jpg", 100_000);
    let file_b = file_dto("file-b", "文档.pdf", 5);

    let result = client
        .prepare_upload(
            ProtocolType::Http,
            "127.0.0.1",
            server.port,
            None,
            prepare_upload_request(&[file_a.clone(), file_b.clone()]),
            None,
            CancellationToken::new(),
        )
        .await
        .unwrap();

    assert_eq!(result.status_code, 200);
    let response = result.response.unwrap();
    assert_eq!(response.files.len(), 2);

    let bytes_a: Vec<u8> = (0..100_000u32).map(|i| i as u8).collect();
    let bytes_b = b"hello".to_vec();

    upload_bytes(
        &client,
        server.port,
        &response.session_id,
        "file-a",
        &response.files["file-a"],
        &bytes_a,
    )
    .await
    .unwrap();

    upload_bytes(
        &client,
        server.port,
        &response.session_id,
        "file-b",
        &response.files["file-b"],
        &bytes_b,
    )
    .await
    .unwrap();

    let received = server.received.lock().await;
    assert_eq!(received["file-a"], bytes_a);
    assert_eq!(received["file-b"], bytes_b);
    drop(received);

    tokio::time::sleep(Duration::from_millis(100)).await;
    let session_ends = server.session_ends.lock().await;
    assert_eq!(
        *session_ends,
        vec![(response.session_id.clone(), SessionEndReasonV2::Finished)]
    );
}

#[tokio::test]
async fn test_handysend_upload_with_sha256_verification() {
    let server = start_test_server(None, true).await;
    let client = LsHttpClientV2::try_new_without_cert().unwrap();

    let bytes = b"hello".to_vec();
    let mut file = file_dto("file-a", "test.bin", bytes.len() as u64);
    file.sha256 = Some(sha256_hex(&bytes));

    let response = client
        .prepare_upload(
            ProtocolType::Http,
            "127.0.0.1",
            server.port,
            None,
            prepare_upload_request(&[file]),
            None,
            CancellationToken::new(),
        )
        .await
        .unwrap()
        .response
        .unwrap();

    upload_bytes(
        &client,
        server.port,
        &response.session_id,
        "file-a",
        &response.files["file-a"],
        &bytes,
    )
    .await
    .unwrap();

    assert_eq!(server.received.lock().await["file-a"], bytes);
}

#[tokio::test]
async fn test_handysend_pin_protection() {
    let server = start_test_server(Some("654321".to_string()), true).await;
    let client = LsHttpClientV2::try_new_without_cert().unwrap();

    let file = file_dto("file-a", "secret.bin", 5);

    let result = client
        .prepare_upload(
            ProtocolType::Http,
            "127.0.0.1",
            server.port,
            None,
            prepare_upload_request(&[file.clone()]),
            None,
            CancellationToken::new(),
        )
        .await;
    assert_status(result, 401);

    let result = client
        .prepare_upload(
            ProtocolType::Http,
            "127.0.0.1",
            server.port,
            None,
            prepare_upload_request(&[file.clone()]),
            Some("000000"),
            CancellationToken::new(),
        )
        .await;
    assert_status(result, 401);

    client
        .prepare_upload(
            ProtocolType::Http,
            "127.0.0.1",
            server.port,
            None,
            prepare_upload_request(&[file]),
            Some("654321"),
            CancellationToken::new(),
        )
        .await
        .unwrap();
}

#[tokio::test]
async fn test_handysend_declined_upload() {
    let server = start_test_server(None, false).await;
    let client = LsHttpClientV2::try_new_without_cert().unwrap();

    let file = file_dto("file-a", "rejected.bin", 5);
    let result = client
        .prepare_upload(
            ProtocolType::Http,
            "127.0.0.1",
            server.port,
            None,
            prepare_upload_request(&[file.clone()]),
            None,
            CancellationToken::new(),
        )
        .await;
    assert_status(result, 403);

    let result = client
        .prepare_upload(
            ProtocolType::Http,
            "127.0.0.1",
            server.port,
            None,
            prepare_upload_request(&[file]),
            None,
            CancellationToken::new(),
        )
        .await;
    assert_status(result, 403);
}

#[tokio::test]
async fn test_handysend_cancel_and_new_session() {
    let server = start_test_server(None, true).await;
    let client = LsHttpClientV2::try_new_without_cert().unwrap();

    let file = file_dto("file-a", "cancel.bin", 5);
    let response = client
        .prepare_upload(
            ProtocolType::Http,
            "127.0.0.1",
            server.port,
            None,
            prepare_upload_request(&[file.clone()]),
            None,
            CancellationToken::new(),
        )
        .await
        .unwrap()
        .response
        .unwrap();

    let result = client
        .prepare_upload(
            ProtocolType::Http,
            "127.0.0.1",
            server.port,
            None,
            prepare_upload_request(&[file.clone()]),
            None,
            CancellationToken::new(),
        )
        .await;
    assert_status(result, 409);

    client
        .cancel(
            ProtocolType::Http,
            "127.0.0.1",
            server.port,
            &response.session_id,
        )
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(100)).await;

    client
        .prepare_upload(
            ProtocolType::Http,
            "127.0.0.1",
            server.port,
            None,
            prepare_upload_request(&[file]),
            None,
            CancellationToken::new(),
        )
        .await
        .unwrap();
}
