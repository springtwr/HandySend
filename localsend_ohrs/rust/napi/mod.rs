//! NAPI 适配层——将桥接层 API 暴露为 ArkTS 可调用的 #[napi] 函数。
//!
//! 按入口域组织（T049-T056）：
//! - `env`：NapiEnv（runtime + state + event_rx）
//! - `event_forwarder`：事件转发（napi_threadsafe_function）
//! - `identity`：初始化 / 安全上下文 / 基础能力
//! - `server`：服务器 / 传输决策 / WebSend
//! - `client`：发送 / 接收 / 取消 / 注册
//! - `discovery`：发现

use napi_derive_ohos::napi;

pub mod client;
pub mod discovery;
pub mod env;
pub mod event_forwarder;
pub mod identity;
pub mod server;

use napi_ohos::bindgen_prelude::*;
use napi_ohos::threadsafe_function::ThreadsafeFunction;

// ── NAPI 对象结构 ─────────────────────────────────────────────────────

/// 传输文件信息。
#[napi(object)]
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferFileInfo {
    pub file_id: String,
    pub file_name: String,
    pub size: i64,
    pub file_type: String,
    pub preview: Option<String>,
    pub sha256: Option<String>,
}

/// 传输请求（PrepareUpload 等待决策）。
#[napi(object)]
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferRequest {
    pub session_id: String,
    pub sender_alias: String,
    pub sender_fingerprint: String,
    pub sender_protocol: String,
    pub files: Vec<TransferFileInfo>,
}

/// 服务器状态。
#[napi(object)]
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerStatus {
    pub running: bool,
    pub active_session: Option<String>,
    pub fingerprint: Option<String>,
}

/// 服务器句柄。
#[napi(object)]
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerHandle {
    pub fingerprint: String,
    pub port: u16,
}

/// HTTP 错误。
#[napi(object)]
#[derive(serde::Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct HttpError {
    pub kind: String,
    pub status: Option<u16>,
    pub message: Option<String>,
}

/// 发送结果。
#[napi(object)]
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SendResult {
    pub session_id: String,
    pub success: bool,
    pub failed_files: Vec<String>,
    pub error: Option<HttpError>,
}

/// 分享链接信息。
#[napi(object)]
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShareLinkInfo {
    pub url: String,
    pub port: u16,
    pub session_id: String,
}

/// 安全上下文（TLS 证书身份）。
#[napi(object)]
pub struct SecurityContext {
    pub private_key: String,
    pub public_key: String,
    pub certificate: String,
    pub certificate_hash: String,
}

/// 网络接口信息。
#[napi(object)]
pub struct NetworkInterfaceInfo {
    pub name: String,
    pub ip: String,
    pub prefix_length: u32,
}

// ── 事件回调注册 ─────────────────────────────────────────────────────

/// 注册事件监听回调并启动事件转发。
///
/// 事件以 `{"type":"...","payload":{...}}` JSON 字符串传递到 ArkTS 主线程，
/// ArkTS 侧按 type 分发（FR-010）。
#[napi]
pub fn register_event_listener(callback: ThreadsafeFunction<String>) -> Result<()> {
    // 确保事件通道存在（幂等）——若 ArkTS 未先调用 init，此处自动补建
    let env = crate::napi::env::NapiEnv::global();
    env.ensure_event_channel();
    event_forwarder::start_event_forwarder(callback);
    log::debug!("Event listener registered");
    Ok(())
}
