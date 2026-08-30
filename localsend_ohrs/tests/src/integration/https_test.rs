#![cfg(test)]

//! HTTPS + mTLS 集成测试——覆盖生产传输路径的完整客户端-服务器交互。
//!
//! 与 `client_test.rs` / `server_test.rs` 中的 HTTP 测试互补，
//! 本模块验证 HTTPS（自签名证书 + mTLS）路径的协议行为，
//! 确保生产传输路径有测试保护。

use bytes::Bytes;
use futures_util::StreamExt;
use localsend::crypto::cert::generate_self_signed;
use localsend::http::client::{ClientError, LsHttpClientV2};
use localsend::http::dto_v2::{PrepareUploadRequestDtoV2, RegisterDtoV2};
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2};
use localsend::http::server::{start_with_port, ServerConfigV2, TlsConfig};
use localsend::http::state::ClientInfo;
use localsend::model::discovery::{DeviceType, ProtocolType, PROTOCOL_VERSION_V2};
use localsend::model::transfer::FileDto;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::{mpsc, oneshot, Mutex};
use tokio_stream::wrappers::ReceiverStream;
use tokio_util::sync::CancellationToken;

// ── 测试辅助 ─────────────────────────────────────────────────────────────

/// 测试用自签名证书身份，模拟 LocalSend 对等端。
struct TestIdentity {
    cert: String,
    private_key: String,
    /// 证书 DER 格式的 SHA-256 指纹（大写十六进制）。
    fingerprint: String,
}

/// 生成测试用自签名证书身份。
fn generate_test_identity() -> TestIdentity {
    let cert = generate_self_signed().expect("生成测试证书失败");
    TestIdentity {
        cert: cert.certificate_pem,
        private_key: cert.private_key_pem,
        fingerprint: cert.fingerprint,
    }
}

/// HTTPS 测试服务器句柄。
struct TestServer {
    port: u16,
    /// 接收到的文件内容，按 file_id 索引。
    received: Arc<Mutex<HashMap<String, Vec<u8>>>>,
    _stop_tx: oneshot::Sender<()>,
}

/// 启动 HTTPS 测试服务器。
///
/// 使用给定身份的证书配置 TLS，事件循环自动接受所有上传请求
/// 并将接收到的文件内容存入 `received` 映射。
async fn start_https_server(identity: &TestIdentity) -> TestServer {
    let _ = tracing_subscriber::fmt().with_test_writer().try_init();
    let received: Arc<Mutex<HashMap<String, Vec<u8>>>> = Arc::new(Mutex::new(HashMap::new()));

    let (event_tx, mut event_rx) = mpsc::channel::<ServerEventV2>(16);

    tokio::spawn({
        let received = received.clone();
        async move {
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
                    _ => {}
                }
            }
        }
    });

    let (stop_tx, stop_rx) = oneshot::channel::<()>();

    let handle = start_with_port(
        0,
        Some(TlsConfig {
            cert: identity.cert.clone(),
            private_key: identity.private_key.clone(),
        }),
        ClientInfo {
            alias: "HandySend-HTTPS-Server".to_string(),
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: Some("HarmonyOS".to_string()),
            device_type: Some(DeviceType::Mobile),
            token: identity.fingerprint.clone(),
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
    .expect("启动 HTTPS 服务器失败");

    TestServer {
        port: handle.port(),
        received,
        _stop_tx: stop_tx,
    }
}

/// 构造 mTLS 客户端，使用发送方身份的证书并固定服务器指纹。
fn https_client(sender: &TestIdentity, server_fingerprint: &str) -> LsHttpClientV2 {
    LsHttpClientV2::try_new(
        &sender.private_key,
        &sender.cert,
        Some(server_fingerprint.to_string()),
        None,
    )
    .expect("构造 HTTPS 客户端失败")
}

/// 构造不带指纹固定的 mTLS 客户端（用于发现/注册场景）。
fn https_client_unpinned(sender: &TestIdentity) -> LsHttpClientV2 {
    LsHttpClientV2::try_new(&sender.private_key, &sender.cert, None, None)
        .expect("构造 HTTPS 客户端失败")
}

fn sender_info(fingerprint: &str) -> RegisterDtoV2 {
    RegisterDtoV2 {
        alias: "HandySend-HTTPS-Client".to_string(),
        version: PROTOCOL_VERSION_V2.to_string(),
        device_model: Some("HarmonyOS".to_string()),
        device_type: None,
        fingerprint: fingerprint.to_string(),
        port: 53317,
        protocol: ProtocolType::Https,
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

/// 通过 HTTPS 上传字节数据。
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
            ProtocolType::Https,
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

// ── HTTPS 集成测试 ─────────────────────────────────────────────────────

/// 客户端通过 HTTPS + mTLS 完成准备上传和文件上传全流程，验证接收内容一致。
#[tokio::test]
async fn test_https_prepare_upload_and_upload() {
    let server_identity = generate_test_identity();
    let sender = generate_test_identity();
    let server = start_https_server(&server_identity).await;
    let client = https_client(&sender, &server_identity.fingerprint);

    let file = file_dto("file-1", "test.txt", 13);
    let result = client
        .prepare_upload(
            ProtocolType::Https,
            "127.0.0.1",
            server.port,
            None,
            PrepareUploadRequestDtoV2 {
                info: sender_info(&sender.fingerprint),
                files: [(file.id.clone(), file)].into_iter().collect(),
            },
            None,
            CancellationToken::new(),
        )
        .await
        .unwrap();

    assert_eq!(result.status_code, 200);
    let response = result.response.unwrap();

    let content = b"Hello, HTTPS!";
    upload_bytes(
        &client,
        server.port,
        &response.session_id,
        "file-1",
        &response.files["file-1"],
        content,
    )
    .await
    .unwrap();

    let received = server.received.lock().await;
    assert_eq!(received["file-1"], content);
}

/// 客户端通过 HTTPS 注册设备，验证响应包含正确的设备信息和 public_key。
#[tokio::test]
async fn test_https_register_device() {
    let server_identity = generate_test_identity();
    let sender = generate_test_identity();
    let server = start_https_server(&server_identity).await;
    let client = https_client_unpinned(&sender);

    let response = client
        .register(
            ProtocolType::Https,
            "127.0.0.1",
            server.port,
            sender_info(&sender.fingerprint),
        )
        .await
        .unwrap();

    assert_eq!(response.body.alias, "HandySend-HTTPS-Server");
    assert_eq!(response.body.fingerprint, server_identity.fingerprint);
    // HTTPS 注册应返回 public_key 和 cert_fingerprint
    assert!(response.public_key.is_some());
    assert!(response.cert_fingerprint.is_some());
}

/// 客户端通过 HTTPS 请求 /info 端点，验证返回设备信息。
#[tokio::test]
async fn test_https_client_info() {
    let server_identity = generate_test_identity();
    let sender = generate_test_identity();
    let server = start_https_server(&server_identity).await;
    let client = https_client(&sender, &server_identity.fingerprint);

    let info = client
        .info(ProtocolType::Https, "127.0.0.1", server.port)
        .await
        .unwrap();

    assert_eq!(info.alias, "HandySend-HTTPS-Server");
    assert_eq!(info.fingerprint, server_identity.fingerprint);
}

/// 服务器和客户端证书指纹不匹配时，TLS 握手失败。
#[tokio::test]
async fn test_https_fingerprint_mismatch() {
    let server_identity = generate_test_identity();
    let sender = generate_test_identity();
    let server = start_https_server(&server_identity).await;

    // 客户端固定了错误的指纹（另一个身份的指纹）
    let wrong_identity = generate_test_identity();
    let client = https_client(&sender, &wrong_identity.fingerprint);

    let file = file_dto("file-1", "secret.txt", 10);
    let result = client
        .prepare_upload(
            ProtocolType::Https,
            "127.0.0.1",
            server.port,
            None,
            PrepareUploadRequestDtoV2 {
                info: sender_info(&sender.fingerprint),
                files: [(file.id.clone(), file)].into_iter().collect(),
            },
            None,
            CancellationToken::new(),
        )
        .await;

    // TLS 握手应失败（传输层错误，非 HTTP 状态码）
    assert!(
        matches!(result, Err(ClientError::Reqwest(_))),
        "指纹不匹配时应导致 TLS 握手失败，实际: {:?}",
        result.err()
    );
}
