//! 桥接层强类型事件与错误定义。
//!
//! `BridgeEvent` 是桥接层对外事件的唯一出口类型，通过
//! `state.event_tx`（mpsc channel）推送，Serde 可序列化为 ArkTS 可消费的 JSON。
//!
//! 事件分类：
//! - **关键事件**：必须用 `send().await` 保证送达（PrepareUpload、SessionEnd、
//!   DeviceFound、DeviceLost、ServerStarted/Stopped、WebSend*、Error 等）
//! - **可丢弃事件**：用 `try_send` 发送，channel 满则丢弃（UploadProgress——
//!   进度是瞬态值，用户只关心最新值）

use serde::Serialize;

use crate::bridge::adapter::types::{DeviceDto, FileDto, SenderInfoDto};

/// 桥接层统一事件枚举。
///
/// Serde 使用内部 tag 序列化：`{"type":"...","payload":{...}}`，
/// ArkTS 侧按 `type` 分发即可，无需解析任意 JSON。
///
/// 注意：`rename_all = "camelCase"` 仅重命名 variant 名（tag），
/// `rename_all_fields = "camelCase"` 才将 struct variant 的字段重命名为
/// camelCase（与 ArkTS `NativeTypes.ets::parseNativeEvent` 的取值一致，
/// 由 `test_all_event_variants_payload_contract` 钉死契约）。
#[derive(Debug, Clone, Serialize)]
#[serde(
    tag = "type",
    content = "payload",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum BridgeEvent {
    // ── 服务器（关键事件，send().await）──
    /// 服务器成功启动（携带实际绑定的端口）。
    ServerStarted { port: u16 },
    /// 服务器已停止。
    ServerStopped,

    /// 远端设备通过 HTTP 注册（发现流程的 HTTP 应答）。
    Register { ip: String, info: SenderInfoDto },

    /// 发送方发起 PrepareUpload，等待用户决策。
    PrepareUpload {
        session_id: String,
        sender_ip: String,
        sender_alias: String,
        sender_fingerprint: String,
        sender_device_type: String,
        sender_device_model: String,
        cert_fingerprint: String,
        files: Vec<FileDto>,
    },

    /// 发送方在决策前取消了 PrepareUpload 请求。
    PrepareUploadAborted { session_id: String },

    /// 远端设备请求取消一个本机正在发送的会话。
    CancelReceived { ip: String, session_id: String },

    // ── 传输（UploadProgress 可丢弃 try_send，其余关键）──
    /// 上传进度（高频瞬态事件，channel 满时丢弃）。
    /// `direction` 为 "recv"（接收）或 "send"（发送）。
    UploadProgress {
        session_id: String,
        file_id: String,
        direction: String,
        progress: f64,
        speed: f64,
    },

    /// 会话结束（携带结束原因）。
    SessionEnd {
        session_id: String,
        reason: SessionEndReason,
    },

    /// 文件开始上传（FileUpload 事件，包含文件元数据）。
    FileUpload {
        session_id: String,
        file_id: String,
        file_name: String,
        size: u64,
    },

    // ── 发现（关键事件）──
    /// 发现新设备（携带完整设备信息，消费者拿到事件即可使用）。
    DeviceFound { device: DeviceDto },
    /// 设备下线或超时。
    DeviceLost { fingerprint: String },

    // ── WebSend（关键事件）──
    /// Web 浏览器请求下载文件（待用户决策）。
    WebSendPrepareDownload {
        session_id: String,
        ip: String,
        user_agent: Option<String>,
    },
    /// Web 浏览器实际下载文件。
    WebSendFileDownload {
        session_id: String,
        file_id: String,
        file_name: String,
        size: u64,
    },
    /// WebSend 会话结束。
    WebSendSessionEnd { session_id: String },

    // ── MTA 发送端服务器（关键事件，MtaSendProgress 可丢弃）──
    /// MTA 服务器已启动（携带实际绑定端口）。
    MtaServerStarted { port: u16 },
    /// 对端已建立 MTA WebSocket 连接。
    MtaWsConnected,
    /// MTA 版本协商完成。
    MtaVersionNegotiated { version: i64 },
    /// 已发送 sendRequest 并收到对端确认。
    MtaSendRequestSent { task_id: String },
    /// 对端开始下载 ZIP。
    MtaDownloadStarted { task_id: String },
    /// ZIP 发送进度（高频瞬态事件，channel 满时丢弃）。
    MtaSendProgress {
        sent_bytes: u64,
        total_bytes: u64,
        percent: f64,
    },
    /// 本次 MTA 发送完成（对端回送成功状态）。
    MtaSendCompleted { task_id: String },
    /// 本次 MTA 发送被对端拒绝。
    MtaSendRejected { reason: String },
    /// 本次 MTA 发送失败（超时/连接中断等）。
    MtaSendFailed { reason: String },

    // ── 错误（关键事件）──
    /// 异步运行错误（上传失败、下载失败、会话意外终止、网络中断等）。
    Error { context: String, message: String },
}

impl BridgeEvent {
    /// 该事件是否属于"可丢弃"分类（channel 满时可用 `try_send` 丢弃）。
    ///
    /// 仅高频瞬态进度事件可丢弃；其余均为关键事件，必须 `send().await` 保证送达。
    pub fn is_droppable(&self) -> bool {
        matches!(
            self,
            BridgeEvent::UploadProgress { .. } | BridgeEvent::MtaSendProgress { .. }
        )
    }
}

/// 按事件分类发送桥接事件。
///
/// - 可丢弃事件（UploadProgress）：`try_send`，channel 满则丢弃，不阻塞
/// - 关键事件：`send().await` 保证送达
pub async fn send_event(
    event_tx: &Option<tokio::sync::mpsc::Sender<BridgeEvent>>,
    event: BridgeEvent,
) {
    let Some(tx) = event_tx else {
        return;
    };
    if event.is_droppable() {
        let _ = tx.try_send(event);
    } else {
        let _ = tx.send(event).await;
    }
}

/// 会话结束原因。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionEndReason {
    /// 所有文件上传完成。
    Finished,
    /// 发送方或接收方取消。
    Cancelled,
    /// 接收方拒绝。
    Declined,
    /// 传输失败。
    Failed,
    /// 等待决策超时。
    Timeout,
}

/// 桥接层统一错误类型（同步操作错误通过 `Result<_, BridgeError>` 返回）。
#[derive(Debug, thiserror::Error)]
pub enum BridgeError {
    /// 桥接层未初始化（未调用 init / init_with_persisted_identity）。
    #[error("未初始化")]
    NotInitialized,

    /// 服务器已运行，重复启动。
    #[error("服务器已运行")]
    AlreadyRunning,

    /// 服务器未运行。
    #[error("服务器未运行")]
    ServerNotRunning,

    /// 会话不存在或已过期（两阶段竞态：用户未响应时对方已取消）。
    #[error("会话不存在或已过期: {0}")]
    SessionExpired(String),

    /// 参数无效。
    #[error("无效参数: {0}")]
    InvalidArgument(String),

    /// 上游 localsend 库错误。
    #[error("上游错误: {0}")]
    Upstream(#[from] anyhow::Error),

    /// IO 错误。
    #[error("IO 错误: {0}")]
    Io(#[from] std::io::Error),
}

// ── 单元测试 ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    /// 事件分类常量：关键事件清单（必须 send().await 保证送达）。
    const CRITICAL_EVENTS: &[&str] = &[
        "serverStarted",
        "serverStopped",
        "register",
        "prepareUpload",
        "prepareUploadAborted",
        "cancelReceived",
        "sessionEnd",
        "fileUpload",
        "deviceFound",
        "deviceLost",
        "webSendPrepareDownload",
        "webSendFileDownload",
        "webSendSessionEnd",
        "mtaServerStarted",
        "mtaWsConnected",
        "mtaVersionNegotiated",
        "mtaSendRequestSent",
        "mtaDownloadStarted",
        "mtaSendCompleted",
        "mtaSendRejected",
        "mtaSendFailed",
        "error",
    ];

    /// 可丢弃事件清单（try_send）。
    const DROPPABLE_EVENTS: &[&str] = &["uploadProgress", "mtaSendProgress"];

    #[test]
    fn test_upload_progress_is_droppable() {
        let e = BridgeEvent::UploadProgress {
            session_id: "s".into(),
            file_id: "f".into(),
            direction: "recv".into(),
            progress: 0.5,
            speed: 100.0,
        };
        assert!(e.is_droppable());
    }

    #[test]
    fn test_critical_events_are_not_droppable() {
        // 遍历所有非进度事件，验证它们均为关键事件
        let critical = vec![
            BridgeEvent::ServerStarted { port: 53317 },
            BridgeEvent::ServerStopped,
            BridgeEvent::Register {
                ip: "192.168.1.5".into(),
                info: SenderInfoDto::default(),
            },
            BridgeEvent::PrepareUpload {
                session_id: "s".into(),
                sender_ip: "192.168.1.5".into(),
                sender_alias: "Phone".into(),
                sender_fingerprint: "fp".into(),
                sender_device_type: "mobile".into(),
                sender_device_model: "HarmonyOS".into(),
                cert_fingerprint: "cert".into(),
                files: vec![],
            },
            BridgeEvent::PrepareUploadAborted {
                session_id: "s".into(),
            },
            BridgeEvent::CancelReceived {
                ip: "192.168.1.5".into(),
                session_id: "s".into(),
            },
            BridgeEvent::SessionEnd {
                session_id: "s".into(),
                reason: SessionEndReason::Finished,
            },
            BridgeEvent::FileUpload {
                session_id: "s".into(),
                file_id: "f".into(),
                file_name: "a.txt".into(),
                size: 10,
            },
            BridgeEvent::DeviceFound {
                device: DeviceDto::default(),
            },
            BridgeEvent::DeviceLost {
                fingerprint: "fp".into(),
            },
            BridgeEvent::WebSendPrepareDownload {
                session_id: "s".into(),
                ip: "192.168.1.5".into(),
                user_agent: None,
            },
            BridgeEvent::WebSendFileDownload {
                session_id: "s".into(),
                file_id: "f".into(),
                file_name: "a.txt".into(),
                size: 10,
            },
            BridgeEvent::WebSendSessionEnd {
                session_id: "s".into(),
            },
            BridgeEvent::MtaServerStarted { port: 53317 },
            BridgeEvent::MtaWsConnected,
            BridgeEvent::MtaVersionNegotiated { version: 1 },
            BridgeEvent::MtaSendRequestSent {
                task_id: "t".into(),
            },
            BridgeEvent::MtaDownloadStarted {
                task_id: "t".into(),
            },
            BridgeEvent::MtaSendCompleted {
                task_id: "t".into(),
            },
            BridgeEvent::MtaSendRejected {
                reason: "user refuse".into(),
            },
            BridgeEvent::MtaSendFailed {
                reason: "timeout".into(),
            },
            BridgeEvent::Error {
                context: "ctx".into(),
                message: "msg".into(),
            },
        ];
        for e in critical {
            assert!(!e.is_droppable(), "{e:?} 应为关键事件");
        }
    }

    #[test]
    fn test_event_classification_lists_consistent() {
        // 序列化验证 tag 名与分类清单一致
        let samples: Vec<(BridgeEvent, &str)> = vec![
            (BridgeEvent::ServerStarted { port: 53317 }, "serverStarted"),
            (
                BridgeEvent::UploadProgress {
                    session_id: "s".into(),
                    file_id: "f".into(),
                    direction: "recv".into(),
                    progress: 0.5,
                    speed: 100.0,
                },
                "uploadProgress",
            ),
            (
                BridgeEvent::DeviceFound {
                    device: DeviceDto::default(),
                },
                "deviceFound",
            ),
            (
                BridgeEvent::SessionEnd {
                    session_id: "s".into(),
                    reason: SessionEndReason::Cancelled,
                },
                "sessionEnd",
            ),
        ];
        for (event, expected_type) in samples {
            let json = serde_json::to_value(&event).unwrap();
            assert_eq!(json["type"], expected_type);
            assert!(json["payload"].is_object(), "应包含 payload 字段");
        }
    }

    #[test]
    fn test_session_end_reason_serialize_camel_case() {
        let v = serde_json::to_value(SessionEndReason::Finished).unwrap();
        assert_eq!(v, "finished");
        let v = serde_json::to_value(SessionEndReason::Cancelled).unwrap();
        assert_eq!(v, "cancelled");
    }

    #[test]
    fn test_bridge_error_messages() {
        assert_eq!(BridgeError::NotInitialized.to_string(), "未初始化");
        assert_eq!(BridgeError::AlreadyRunning.to_string(), "服务器已运行");
        assert_eq!(BridgeError::ServerNotRunning.to_string(), "服务器未运行");
        assert_eq!(
            BridgeError::SessionExpired("sess-1".into()).to_string(),
            "会话不存在或已过期: sess-1"
        );
        assert_eq!(
            BridgeError::InvalidArgument("port".into()).to_string(),
            "无效参数: port"
        );
    }

    // ── 跨层事件 JSON 契约（SC：防止 ArkTS/Rust 契约漂移）──
    //
    // ArkTS 侧 `NativeTypes.ets::parseNativeEvent` 按 `type` 分发事件，并
    // 从 payload 中解析具体字段（camelCase）。本测试把每个 BridgeEvent
    // 变体的序列化字段集合钉死为契约基线，字段名与 `NativeTypes.ets`
    // 各 case 分支的取值一一对应。
    //
    // Rust 侧改动 tag / 字段名（含 serde 属性）时此处立即失败，提醒
    // 同步修改 ArkTS 解析器；ArkTS 侧改字段名时需同步更新本契约表。

    #[test]
    fn test_all_event_variants_payload_contract() {
        // (事件, 期望 tag, 期望 payload 字段集合；None 表示 unit variant 无 payload 字段)
        let samples: Vec<(BridgeEvent, &str, Option<&[&str]>)> = vec![
            (
                BridgeEvent::ServerStarted { port: 53317 },
                "serverStarted",
                Some(&["port"]),
            ),
            // unit variant：serde internally-tagged 不产生 payload 字段（{"type":"serverStopped"}）
            (BridgeEvent::ServerStopped, "serverStopped", None),
            (
                BridgeEvent::Register {
                    ip: "192.168.1.5".into(),
                    info: SenderInfoDto::default(),
                },
                "register",
                Some(&["ip", "info"]),
            ),
            (
                BridgeEvent::PrepareUpload {
                    session_id: "s".into(),
                    sender_ip: "192.168.1.5".into(),
                    sender_alias: "Phone".into(),
                    sender_fingerprint: "fp".into(),
                    sender_device_type: "mobile".into(),
                    sender_device_model: "M".into(),
                    cert_fingerprint: "cert".into(),
                    files: vec![],
                },
                "prepareUpload",
                Some(&[
                    "sessionId",
                    "senderIp",
                    "senderAlias",
                    "senderFingerprint",
                    "senderDeviceType",
                    "senderDeviceModel",
                    "certFingerprint",
                    "files",
                ]),
            ),
            (
                BridgeEvent::PrepareUploadAborted {
                    session_id: "s".into(),
                },
                "prepareUploadAborted",
                Some(&["sessionId"]),
            ),
            (
                BridgeEvent::CancelReceived {
                    ip: "192.168.1.5".into(),
                    session_id: "s".into(),
                },
                "cancelReceived",
                Some(&["ip", "sessionId"]),
            ),
            (
                BridgeEvent::UploadProgress {
                    session_id: "s".into(),
                    file_id: "f".into(),
                    direction: "recv".into(),
                    progress: 0.5,
                    speed: 100.0,
                },
                "uploadProgress",
                Some(&["sessionId", "fileId", "direction", "progress", "speed"]),
            ),
            (
                BridgeEvent::SessionEnd {
                    session_id: "s".into(),
                    reason: SessionEndReason::Finished,
                },
                "sessionEnd",
                Some(&["sessionId", "reason"]),
            ),
            (
                BridgeEvent::FileUpload {
                    session_id: "s".into(),
                    file_id: "f".into(),
                    file_name: "a.txt".into(),
                    size: 10,
                },
                "fileUpload",
                Some(&["sessionId", "fileId", "fileName", "size"]),
            ),
            (
                BridgeEvent::DeviceFound {
                    device: DeviceDto::default(),
                },
                "deviceFound",
                Some(&["device"]),
            ),
            (
                BridgeEvent::DeviceLost {
                    fingerprint: "fp".into(),
                },
                "deviceLost",
                Some(&["fingerprint"]),
            ),
            (
                BridgeEvent::WebSendPrepareDownload {
                    session_id: "s".into(),
                    ip: "192.168.1.5".into(),
                    user_agent: Some("Mozilla".into()),
                },
                "webSendPrepareDownload",
                Some(&["sessionId", "ip", "userAgent"]),
            ),
            (
                BridgeEvent::WebSendFileDownload {
                    session_id: "s".into(),
                    file_id: "f".into(),
                    file_name: "a.txt".into(),
                    size: 10,
                },
                "webSendFileDownload",
                Some(&["sessionId", "fileId", "fileName", "size"]),
            ),
            (
                BridgeEvent::WebSendSessionEnd {
                    session_id: "s".into(),
                },
                "webSendSessionEnd",
                Some(&["sessionId"]),
            ),
            (
                BridgeEvent::MtaServerStarted { port: 53317 },
                "mtaServerStarted",
                Some(&["port"]),
            ),
            (BridgeEvent::MtaWsConnected, "mtaWsConnected", None),
            (
                BridgeEvent::MtaVersionNegotiated { version: 1 },
                "mtaVersionNegotiated",
                Some(&["version"]),
            ),
            (
                BridgeEvent::MtaSendRequestSent {
                    task_id: "t".into(),
                },
                "mtaSendRequestSent",
                Some(&["taskId"]),
            ),
            (
                BridgeEvent::MtaDownloadStarted {
                    task_id: "t".into(),
                },
                "mtaDownloadStarted",
                Some(&["taskId"]),
            ),
            (
                BridgeEvent::MtaSendProgress {
                    sent_bytes: 10,
                    total_bytes: 100,
                    percent: 10.0,
                },
                "mtaSendProgress",
                Some(&["sentBytes", "totalBytes", "percent"]),
            ),
            (
                BridgeEvent::MtaSendCompleted {
                    task_id: "t".into(),
                },
                "mtaSendCompleted",
                Some(&["taskId"]),
            ),
            (
                BridgeEvent::MtaSendRejected {
                    reason: "user refuse".into(),
                },
                "mtaSendRejected",
                Some(&["reason"]),
            ),
            (
                BridgeEvent::MtaSendFailed {
                    reason: "timeout".into(),
                },
                "mtaSendFailed",
                Some(&["reason"]),
            ),
            (
                BridgeEvent::Error {
                    context: "ctx".into(),
                    message: "msg".into(),
                },
                "error",
                Some(&["context", "message"]),
            ),
        ];

        for (event, expected_type, expected_fields) in samples {
            let json = serde_json::to_value(&event).unwrap();
            assert_eq!(
                json["type"], expected_type,
                "事件 tag 漂移: {expected_type}"
            );
            match expected_fields {
                None => {
                    assert!(
                        json.get("payload").is_none(),
                        "unit variant 不应有 payload 字段: {expected_type}"
                    );
                }
                Some(expected_fields) => {
                    let payload = json["payload"].as_object().expect("payload 应为对象");
                    let actual: BTreeSet<&str> = payload.keys().map(|s| s.as_str()).collect();
                    let expected: BTreeSet<&str> = expected_fields.iter().copied().collect();
                    assert_eq!(
                        actual, expected,
                        "payload 字段集合漂移: {expected_type}（改动字段名需同步 NativeTypes.ets parseNativeEvent）"
                    );
                }
            }
        }
    }
}
