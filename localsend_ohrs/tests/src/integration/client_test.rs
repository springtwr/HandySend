#![cfg(test)]

use bytes::Bytes;
use futures_util::StreamExt;
use localsend::http::client::{ClientError, LsHttpClientV2};
use localsend::http::dto_v2::{PrepareUploadRequestDtoV2, RegisterDtoV2};
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2};
use localsend::http::server::{start_with_port, ServerConfigV2};
use localsend::http::state::ClientInfo;
use localsend::model::discovery::{DeviceType, ProtocolType, PROTOCOL_VERSION_V2};
use localsend::model::transfer::FileDto;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::{mpsc, oneshot};
use tokio_stream::wrappers::ReceiverStream;
use tokio_util::sync::CancellationToken;

async fn start_server_with_upload() -> (u16, oneshot::Sender<()>) {
    let _ = tracing_subscriber::fmt().with_test_writer().try_init();

    let (event_tx, mut event_rx) = mpsc::channel::<ServerEventV2>(16);

    tokio::spawn(async move {
        while let Some(event) = event_rx.recv().await {
            match event {
                ServerEventV2::PrepareUpload {
                    files, decision_tx, ..
                } => {
                    let decision =
                        PrepareUploadDecisionV2::Accept(files.keys().cloned().collect());
                    let _ = decision_tx.send(decision);
                }
                ServerEventV2::FileUpload {
                    target_tx, ..
                } => {
                    let (binary_tx, mut binary_rx) = mpsc::channel(16);
                    let (result_tx, result_rx) = oneshot::channel();
                    let _ = target_tx.send(
                        localsend::http::server::common::save::FileUploadTarget::Stream {
                            binary_tx,
                            result_rx,
                        },
                    );
                    tokio::spawn(async move {
                        let mut bytes = Vec::new();
                        while let Some(chunk) = binary_rx.recv().await {
                            bytes.extend_from_slice(&chunk);
                        }
                        let _ = result_tx.send(Ok(()));
                    });
                }
                _ => {}
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
            pin: None,
            verify_checksums: true,
            event_tx,
        }),
        None,
        stop_rx,
    )
    .await
    .expect("启动服务器失败");

    (handle.port(), stop_tx)
}

fn sender_info() -> RegisterDtoV2 {
    RegisterDtoV2 {
        alias: "HandySend-Client".to_string(),
        version: PROTOCOL_VERSION_V2.to_string(),
        device_model: Some("HarmonyOS".to_string()),
        device_type: None,
        fingerprint: "client-fingerprint".to_string(),
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

#[tokio::test]
async fn test_handysend_client_register() {
    let (port, _stop_tx) = start_server_with_upload().await;
    let client = LsHttpClientV2::try_new_without_cert().unwrap();

    let response = client
        .register(ProtocolType::Http, "127.0.0.1", port, sender_info())
        .await
        .unwrap();
    assert_eq!(response.body.alias, "HandySend-Server");
    assert_eq!(response.body.fingerprint, "handysend-fingerprint");
    assert!(!response.body.download);
}

#[tokio::test]
async fn test_handysend_client_prepare_and_upload() {
    let (port, _stop_tx) = start_server_with_upload().await;
    let client = LsHttpClientV2::try_new_without_cert().unwrap();

    let file = file_dto("file-1", "test.txt", 13);

    let result = client
        .prepare_upload(
            ProtocolType::Http,
            "127.0.0.1",
            port,
            None,
            PrepareUploadRequestDtoV2 {
                info: sender_info(),
                files: [(file.id.clone(), file)].into_iter().collect(),
            },
            None,
            CancellationToken::new(),
        )
        .await
        .unwrap();

    assert_eq!(result.status_code, 200);
    let response = result.response.unwrap();

    let content = b"Hello, Handy!";
    upload_bytes(
        &client,
        port,
        &response.session_id,
        "file-1",
        &response.files["file-1"],
        content,
    )
    .await
    .unwrap();
}

#[tokio::test]
async fn test_handysend_client_cancel_upload() {
    let (port, _stop_tx) = start_server_with_upload().await;
    let client = LsHttpClientV2::try_new_without_cert().unwrap();

    let file = file_dto("file-1", "cancel.txt", 5);

    let result = client
        .prepare_upload(
            ProtocolType::Http,
            "127.0.0.1",
            port,
            None,
            PrepareUploadRequestDtoV2 {
                info: sender_info(),
                files: [(file.id.clone(), file)].into_iter().collect(),
            },
            None,
            CancellationToken::new(),
        )
        .await
        .unwrap();

    let response = result.response.unwrap();

    client
        .cancel(
            ProtocolType::Http,
            "127.0.0.1",
            port,
            &response.session_id,
        )
        .await
        .unwrap();
}

#[tokio::test]
async fn test_handysend_client_cancellation_token() {
    let (port, _stop_tx) = start_server_with_upload().await;
    let client = LsHttpClientV2::try_new_without_cert().unwrap();

    let file = file_dto("file-1", "token-cancel.txt", 5);
    let cancel = CancellationToken::new();

    let result = client
        .prepare_upload(
            ProtocolType::Http,
            "127.0.0.1",
            port,
            None,
            PrepareUploadRequestDtoV2 {
                info: sender_info(),
                files: [(file.id.clone(), file)].into_iter().collect(),
            },
            None,
            cancel.clone(),
        )
        .await;

    cancel.cancel();

    match result {
        Ok(_) | Err(ClientError::Cancelled) => {}
        Err(e) => panic!("期望成功或取消，实际: {e:?}"),
    }
}
