//! MTA 发送端跨层流程集成测试（host 目标可直接运行）。
//!
//! 覆盖：
//! - 应用层消息构造/解析、sendRequest JSON、status 分类（纯函数）；
//! - ZIP 预打包（含条目名与大小）；
//! - 服务器生命周期（`start_server` 预打包 + 绑定 + 返回端口，`stop_server` 清理）。

use std::io::Read;

use localsend_core::bridge::mta::protocol::{
    self, classify_status, send_request_json, SendRequestPayload, StatusKind,
};
use localsend_core::bridge::mta::{self, zip_stream};

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
fn zip_pack_flow_creates_expected_entries() {
    let dir = temp_dir("zip");
    let source = dir.join("hello.txt");
    std::fs::write(&source, b"hello mta").unwrap();
    let zip_path = dir.join("out.zip");

    let files = vec![zip_stream::MtaFileEntry {
        path: source.to_string_lossy().to_string(),
        entry_name: "1/hello.txt".into(),
    }];
    let result = zip_stream::pack_zip(zip_path.to_string_lossy().as_ref(), &files).unwrap();
    assert_eq!(result.entry_count, 1);
    assert_eq!(result.total_size, 9);
    assert!(result.zip_size > 0);

    let mut head = [0u8; 4];
    std::fs::File::open(&zip_path)
        .unwrap()
        .read_exact(&mut head)
        .unwrap();
    assert_eq!(&head, b"PK\x03\x04");

    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn server_lifecycle_start_and_stop() {
    let dir = temp_dir("server");
    let source = dir.join("payload.bin");
    std::fs::write(&source, b"payload-data").unwrap();
    let zip_path = dir.join("out.zip");

    let config_json = serde_json::json!({
        "bindIp": "127.0.0.1",
        "port": 0,
        "taskId": "mta-test-1",
        "senderId": "abcd",
        "senderName": "HandySendTest",
        "files": [{ "path": source.to_string_lossy(), "entryName": "1/payload.bin" }],
        "zipPath": zip_path.to_string_lossy(),
    })
    .to_string();

    assert!(!mta::is_running());
    let state = localsend_core::bridge::state::bridge();
    let port = mta::start_server(state, &config_json)
        .await
        .expect("服务器应成功启动");
    assert!(port > 0, "应返回实际绑定端口");
    assert!(mta::is_running());
    assert!(zip_path.exists(), "启动时应完成 ZIP 预打包");

    mta::stop_server();
    assert!(!mta::is_running());
    // 幂等
    mta::stop_server();
    assert!(!mta::is_running());

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn server_config_rejects_empty_task() {
    let config_json = serde_json::json!({
        "bindIp": "127.0.0.1",
        "port": 0,
        "taskId": "",
        "senderId": "a",
        "senderName": "b",
        "files": [{ "path": "/tmp/x", "entryName": "1/x" }],
        "zipPath": "/tmp/out.zip",
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
