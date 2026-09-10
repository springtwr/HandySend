//! MTA 发送端应用层协议纯函数。
//!
//! WS 消息采用 `type:id:name?json_payload` 文本格式（`?` 及 payload 可省略）。
//! 本模块只做字符串构造/解析与 JSON 序列化，不依赖任何系统能力或网络，
//! 因此可直接在 host 目标上 `cargo test --no-default-features --lib` 单测。

use serde::{Deserialize, Serialize};

/// MTA 协议版本。
pub const PROTOCOL_VERSION: i64 = 1;

/// 已解析的 WS 消息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WsMessage {
    /// 消息类型：action / ack 等
    pub msg_type: String,
    /// 消息 ID
    pub id: u32,
    /// 消息名：versionNegotiation / sendRequest / status 等
    pub name: String,
    /// 可选 JSON payload（无 payload 时为空串）
    pub payload: String,
}

/// 构造 `type:id:name?json_payload` 文本（payload 为空时省略 `?`）。
pub fn build_message(msg_type: &str, id: u32, name: &str, payload: Option<&str>) -> String {
    match payload {
        Some(p) if !p.is_empty() => format!("{msg_type}:{id}:{name}?{p}"),
        _ => format!("{msg_type}:{id}:{name}"),
    }
}

/// 为动作类消息构造确认文本：`action` 消息回送 `ack:<原id>:<原name>`（无 payload），
/// 其它类型返回 `None`。部分厂商接收端会等待确认后才收尾，故所有动作类消息均需确认。
pub fn build_ack(message: &WsMessage) -> Option<String> {
    if message.msg_type == "action" {
        Some(build_message("ack", message.id, &message.name, None))
    } else {
        None
    }
}

/// 校验协议标识符：仅允许 ASCII 字母数字与下划线（对齐 ArkTS `\w+`）。
fn is_identifier(text: &str) -> bool {
    !text.is_empty() && text.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// 解析 `type:id:name?json_payload`，格式非法返回 `None`。
pub fn parse_message(raw: &str) -> Option<WsMessage> {
    let (head, payload) = match raw.split_once('?') {
        Some((h, p)) => (h, p),
        None => (raw, ""),
    };
    let mut parts = head.splitn(3, ':');
    let msg_type = parts.next()?;
    let id_text = parts.next()?;
    let name = parts.next()?;
    if !is_identifier(msg_type) || !is_identifier(name) {
        return None;
    }
    let id: u32 = id_text.parse().ok()?;
    Some(WsMessage {
        msg_type: msg_type.to_string(),
        id,
        name: name.to_string(),
        payload: payload.to_string(),
    })
}

/// versionNegotiation 消息 payload（声明协议版本与支持的版本集合）。
pub fn version_negotiation_payload() -> String {
    format!("{{\"version\":{PROTOCOL_VERSION},\"versions\":[{PROTOCOL_VERSION}]}}")
}

/// sendRequest 消息 payload。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SendRequestPayload {
    /// 任务 ID
    pub task_id: String,
    /// 发送方 ID
    pub sender_id: String,
    /// 发送方名称
    pub sender_name: String,
    /// 主文件名（展示用）
    pub file_name: String,
    /// 文件 MIME 类型
    pub mime_type: String,
    /// 文件数
    pub file_count: usize,
    /// 总字节数
    pub total_size: u64,
    /// MTA 原生文本内容（可选）；缺省时不序列化，行为与既有完全一致
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cat_share_text: Option<String>,
}

/// 序列化 sendRequest payload 为 JSON 文本。
pub fn send_request_json(payload: &SendRequestPayload) -> String {
    serde_json::to_string(payload).unwrap_or_default()
}

/// 对端 status 类型分类。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StatusKind {
    /// type=1 成功
    Ok,
    /// type=3 拒绝
    Refused,
    /// 其它/无法判定
    Other,
}

/// 解析 status payload 的 `type` 字段并分类。
pub fn classify_status(payload: &str) -> StatusKind {
    let value: serde_json::Value = match serde_json::from_str(payload) {
        Ok(v) => v,
        Err(_) => return StatusKind::Other,
    };
    match value.get("type").and_then(|v| v.as_i64()) {
        Some(1) => StatusKind::Ok,
        Some(3) => StatusKind::Refused,
        _ => StatusKind::Other,
    }
}

/// 提取 status payload 的 `reason` 字段（缺失返回空串）。
pub fn status_reason(payload: &str) -> String {
    let value: serde_json::Value = match serde_json::from_str(payload) {
        Ok(v) => v,
        Err(_) => return String::new(),
    };
    value
        .get("reason")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string()
}

// ── 单元测试 ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_with_and_without_payload() {
        assert_eq!(
            build_message("action", 0, "versionNegotiation", Some("{\"version\":1}")),
            "action:0:versionNegotiation?{\"version\":1}"
        );
        assert_eq!(
            build_message("ack", 1, "sendRequest", None),
            "ack:1:sendRequest"
        );
        assert_eq!(
            build_message("ack", 1, "sendRequest", Some("")),
            "ack:1:sendRequest"
        );
    }

    #[test]
    fn build_ack_for_action_only() {
        let action = WsMessage {
            msg_type: "action".into(),
            id: 99,
            name: "status".into(),
            payload: "{\"type\":1,\"reason\":\"ok\"}".into(),
        };
        assert_eq!(build_ack(&action), Some("ack:99:status".to_string()));

        // 动作消息无 payload 时同样回送确认
        let action_bare = WsMessage {
            msg_type: "action".into(),
            id: 7,
            name: "cancel".into(),
            payload: String::new(),
        };
        assert_eq!(build_ack(&action_bare), Some("ack:7:cancel".to_string()));

        // 非动作消息（如 ack 自身）不回送
        let ack = WsMessage {
            msg_type: "ack".into(),
            id: 1,
            name: "sendRequest".into(),
            payload: String::new(),
        };
        assert_eq!(build_ack(&ack), None);
    }

    #[test]
    fn parse_roundtrip() {
        let raw = build_message(
            "action",
            0,
            "versionNegotiation",
            Some(&version_negotiation_payload()),
        );
        let msg = parse_message(&raw).expect("应可解析");
        assert_eq!(msg.msg_type, "action");
        assert_eq!(msg.id, 0);
        assert_eq!(msg.name, "versionNegotiation");
        assert_eq!(msg.payload, "{\"version\":1,\"versions\":[1]}");
    }

    #[test]
    fn parse_without_payload() {
        let msg = parse_message("ack:1:sendRequest").expect("应可解析");
        assert_eq!(msg.msg_type, "ack");
        assert_eq!(msg.id, 1);
        assert_eq!(msg.name, "sendRequest");
        assert_eq!(msg.payload, "");
    }

    #[test]
    fn parse_invalid_returns_none() {
        assert!(parse_message("garbage").is_none());
        assert!(parse_message("action:abc:name").is_none());
        assert!(parse_message("action:1:").is_none());
        assert!(parse_message("").is_none());
    }

    #[test]
    fn send_request_json_camel_case() {
        let payload = SendRequestPayload {
            task_id: "t1".into(),
            sender_id: "s1".into(),
            sender_name: "HandySend".into(),
            file_name: "a.zip".into(),
            mime_type: "application/zip".into(),
            file_count: 2,
            total_size: 1024,
            cat_share_text: None,
        };
        let json = send_request_json(&payload);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["taskId"], "t1");
        assert_eq!(parsed["senderId"], "s1");
        assert_eq!(parsed["senderName"], "HandySend");
        assert_eq!(parsed["fileName"], "a.zip");
        assert_eq!(parsed["mimeType"], "application/zip");
        assert_eq!(parsed["fileCount"], 2);
        assert_eq!(parsed["totalSize"], 1024);
        // 文本缺省时不序列化
        assert!(parsed.get("catShareText").is_none());
    }

    #[test]
    fn send_request_json_with_cat_share_text() {
        let payload = SendRequestPayload {
            task_id: "t2".into(),
            sender_id: "s2".into(),
            sender_name: "HandySend".into(),
            file_name: "sharedText.txt".into(),
            mime_type: "application/zip".into(),
            file_count: 1,
            total_size: 5,
            cat_share_text: Some("hello".into()),
        };
        let json = send_request_json(&payload);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        // 文本以 camelCase 字段 catShareText 序列化
        assert_eq!(parsed["catShareText"], "hello");
        // 反序列化兼容（缺失字段为 None）
        let decoded: SendRequestPayload = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.cat_share_text.as_deref(), Some("hello"));
    }

    #[test]
    fn classify_status_variants() {
        assert_eq!(
            classify_status("{\"type\":1,\"reason\":\"ok\"}"),
            StatusKind::Ok
        );
        assert_eq!(
            classify_status("{\"type\":3,\"reason\":\"user refuse\"}"),
            StatusKind::Refused
        );
        assert_eq!(classify_status("{\"type\":2}"), StatusKind::Other);
        assert_eq!(classify_status("not json"), StatusKind::Other);
        assert_eq!(classify_status("{}"), StatusKind::Other);
    }

    #[test]
    fn status_reason_extraction() {
        assert_eq!(
            status_reason("{\"type\":3,\"reason\":\"user refuse\"}"),
            "user refuse"
        );
        assert_eq!(status_reason("{}"), "");
        assert_eq!(status_reason("bad"), "");
    }
}
