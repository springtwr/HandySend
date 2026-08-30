//! ClientError → BridgeError 适配 + 客户端请求构造。
//!
//! 纯函数：`adapt_client_error(&ClientError) -> BridgeError`，无 IO、无 runtime。

use localsend::http::client::ClientError;

use crate::bridge::event::BridgeError;

/// 将上游 ClientError（6 个变体）适配为桥接层 BridgeError。
pub fn adapt_client_error(err: &ClientError) -> BridgeError {
    match err {
        ClientError::StatusCode(se) => BridgeError::Upstream(anyhow::anyhow!(
            "HTTP 状态码错误: {} {}",
            se.status,
            se.message.as_deref().unwrap_or("")
        )),
        ClientError::Reqwest(re) => BridgeError::Upstream(anyhow::anyhow!("网络请求错误: {re}")),
        ClientError::Json(je) => BridgeError::Upstream(anyhow::anyhow!("JSON 解析错误: {je}")),
        ClientError::Io(ie) => BridgeError::Io(std::io::Error::other(ie.to_string())),
        ClientError::Other(ae) => BridgeError::Upstream(anyhow::anyhow!("{ae:#}")),
        ClientError::Cancelled => BridgeError::Upstream(anyhow::anyhow!("操作已取消")),
    }
}

/// 将上游 ClientError 转换为结构化 JSON（供 ArkTS SendResult.error 使用）。
pub fn client_error_to_json(err: &ClientError) -> serde_json::Value {
    use serde_json::json;
    match err {
        ClientError::StatusCode(se) => json!({
            "kind": "statusCode",
            "status": se.status,
            "message": se.message,
        }),
        ClientError::Reqwest(re) => json!({
            "kind": "reqwest",
            "message": format!("{re:#}"),
        }),
        ClientError::Json(je) => json!({
            "kind": "json",
            "message": je.to_string(),
        }),
        ClientError::Io(ie) => json!({
            "kind": "io",
            "message": ie.to_string(),
        }),
        ClientError::Other(ae) => json!({
            "kind": "other",
            "message": format!("{ae:#}"),
        }),
        ClientError::Cancelled => json!({
            "kind": "cancelled",
            "message": "Operation cancelled",
        }),
    }
}

// ── 单元测试 ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adapt_status_code_error() {
        let err = ClientError::StatusCode(localsend::http::StatusCodeError {
            status: 403,
            message: Some("Forbidden".to_string()),
        });
        let bridge_err = adapt_client_error(&err);
        assert!(matches!(bridge_err, BridgeError::Upstream(_)));
        let msg = bridge_err.to_string();
        assert!(msg.contains("403"), "应包含状态码: {msg}");
    }

    // Reqwest 变体无法在测试中构造（reqwest::Error::new 私有），
    // 其余 5 个变体已覆盖转换路径。

    #[test]
    fn adapt_json_error() {
        let err =
            ClientError::Json(serde_json::from_str::<serde_json::Value>("{invalid").unwrap_err());
        let bridge_err = adapt_client_error(&err);
        assert!(matches!(bridge_err, BridgeError::Upstream(_)));
    }

    #[test]
    fn adapt_io_error() {
        let err = ClientError::Io(std::io::Error::new(std::io::ErrorKind::NotFound, "no file"));
        let bridge_err = adapt_client_error(&err);
        assert!(matches!(bridge_err, BridgeError::Io(_)));
    }

    #[test]
    fn adapt_other_error() {
        let err = ClientError::Other(anyhow::anyhow!("custom failure"));
        let bridge_err = adapt_client_error(&err);
        assert!(matches!(bridge_err, BridgeError::Upstream(_)));
        assert!(bridge_err.to_string().contains("custom failure"));
    }

    #[test]
    fn adapt_cancelled() {
        let err = ClientError::Cancelled;
        let bridge_err = adapt_client_error(&err);
        assert!(matches!(bridge_err, BridgeError::Upstream(_)));
    }

    #[test]
    fn client_error_status_code_to_json() {
        let err = ClientError::StatusCode(localsend::http::StatusCodeError {
            status: 403,
            message: Some("Forbidden".to_string()),
        });
        let json = client_error_to_json(&err);
        assert_eq!(json["kind"], "statusCode");
        assert_eq!(json["status"], 403);
    }

    #[test]
    fn client_error_cancelled_to_json() {
        let err = ClientError::Cancelled;
        let json = client_error_to_json(&err);
        assert_eq!(json["kind"], "cancelled");
    }
}
