//! 初始化 / 安全上下文 / 基础能力 NAPI 入口。
//!
//! 保持与旧 napi_entry.rs 相同的函数签名（ArkTS 侧调用不变）。

use napi_derive_ohos::napi;

use napi_ohos::bindgen_prelude::*;

use crate::bridge::identity;
use crate::napi::env::NapiEnv;
use crate::napi::{NetworkInterfaceInfo, SecurityContext};

/// 初始化桥接层（使用 save_dir 持久化身份）。
#[napi]
pub fn init(alias: String, device_type: String, _log_level: Option<String>) -> Result<()> {
    identity::init_hilog_logger();
    let dt = identity::parse_device_type(&device_type);

    let env = NapiEnv::global();
    identity::init(env.state, alias, dt)
        .map_err(|e| Error::from_reason(format!("Init failed: {e:#}")))?;

    // 确保事件通道存在（幂等）
    env.ensure_event_channel();

    log::debug!("Bridge initialized");
    Ok(())
}

/// 使用持久化身份初始化桥接层。
#[napi]
pub fn init_with_persisted_identity(
    alias: String,
    device_type: String,
    persist_dir: String,
) -> Result<()> {
    identity::init_hilog_logger();
    let dt = identity::parse_device_type(&device_type);

    let env = NapiEnv::global();
    identity::init_with_persisted_identity(env.state, alias, dt, &persist_dir)
        .map_err(|e| Error::from_reason(format!("Init failed: {e:#}")))?;

    // 确保事件通道存在（幂等）
    env.ensure_event_channel();

    log::debug!("Bridge initialized with persisted identity");
    Ok(())
}

/// 获取当前生效的安全上下文（私钥/公钥/证书/指纹）。
#[napi]
pub fn get_security_context() -> Result<SecurityContext> {
    let state = NapiEnv::global().state;
    let s = state.lock().unwrap();
    let ctx = identity::get_security_context(&s)
        .map_err(|e| Error::from_reason(format!("Get security context failed: {e:#}")))?;
    Ok(SecurityContext {
        private_key: ctx.private_key,
        public_key: ctx.public_key,
        certificate: ctx.certificate,
        certificate_hash: ctx.certificate_hash,
    })
}

/// 重置安全上下文：生成新的自签名证书与私钥。
#[napi]
pub fn reset_security_context() -> Result<SecurityContext> {
    let state = NapiEnv::global().state;
    let ctx = identity::reset_security_context(state)
        .map_err(|e| Error::from_reason(format!("Reset security context failed: {e:#}")))?;
    Ok(SecurityContext {
        private_key: ctx.private_key,
        public_key: ctx.public_key,
        certificate: ctx.certificate,
        certificate_hash: ctx.certificate_hash,
    })
}

/// 枚举所有非回环 IPv4 网络接口。
#[napi]
pub fn get_network_interfaces() -> Vec<NetworkInterfaceInfo> {
    identity::get_network_interfaces()
        .into_iter()
        .map(|iface| NetworkInterfaceInfo {
            name: iface.name,
            ip: iface.ip,
            prefix_length: iface.prefix_length,
        })
        .collect()
}

/// 计算内存缓冲区的 SHA-256 哈希（同步）。
#[napi]
pub fn hash_buffer(buffer: Buffer) -> String {
    identity::hash_buffer(&buffer)
}

/// 计算组合指纹字符串的 SHA-256 哈希。
#[napi]
pub fn compute_fingerprint_hash(combined: String) -> String {
    identity::compute_fingerprint_hash(&combined)
}

/// 计算文件的 SHA-256 哈希（异步，取消时返回空字符串）。
#[napi]
pub async fn hash_file_stream(path: String, cancel_id: Option<String>) -> Result<String> {
    let state = NapiEnv::global().state;
    identity::hash_file_stream(state, &path, cancel_id)
        .await
        .map_err(|e| Error::from_reason(format!("Hash file stream failed: {e:#}")))
}

/// 基于已打开的文件描述符计算 SHA-256（异步，取消时返回空字符串）。
#[cfg(any(target_os = "android", all(target_os = "linux", target_env = "ohos")))]
#[napi]
pub async fn hash_file_stream_fd(fd: i32, cancel_id: Option<String>) -> Result<String> {
    let state = NapiEnv::global().state;
    identity::hash_file_stream_fd(state, fd, cancel_id)
        .await
        .map_err(|e| Error::from_reason(format!("Hash file stream fd failed: {e:#}")))
}

/// 按 cancel_id 取消一次哈希操作。
#[napi]
pub fn cancel_hash(cancel_id: String) -> Result<()> {
    let state = NapiEnv::global().state;
    let s = state.lock().unwrap();
    identity::cancel_hash(&s, &cancel_id)
        .map_err(|e| Error::from_reason(format!("Cancel hash failed: {e:#}")))
}

/// 创建一个 CancellationToken 并返回其 UUID id。
#[napi]
pub fn create_cancel_token() -> String {
    let state = NapiEnv::global().state;
    identity::create_cancel_token(state)
}

/// 将 `name` 重写为当前平台合法的文件名。
#[napi]
pub fn sanitize_file_name(name: String) -> String {
    identity::sanitize_file_name(name)
}

/// 返回原生库版本（来自 Cargo.toml）。
#[napi]
pub fn get_native_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// 返回本库实现的 LocalSend 协议版本。
#[napi]
pub fn get_protocol_version() -> String {
    localsend::model::discovery::PROTOCOL_VERSION_V2.to_string()
}

/// 排空调试日志缓冲与 Rust 日志缓冲。元素格式为 `level|message`（旧格式无前缀时由调用方按 info 兜底）。
fn drain_debug_logs() -> Vec<String> {
    let state = NapiEnv::global().state;
    let mut entries: Vec<String> = {
        let s = state.lock().unwrap();
        let mut log = s.debug_log.lock().unwrap();
        log.drain(..).collect()
    };
    entries.append(&mut identity::drain_rust_log_buf_with_levels());
    entries
}

/// 排空并返回调试日志缓冲（带 `level|message` 前缀，签名保持 `Vec<String>` 不变）。
#[napi]
pub fn poll_debug_log() -> Vec<String> {
    drain_debug_logs()
}

/// 带级别的日志轮询入口：返回形如 `level|message` 的日志行，供 MTA 链路按级别还原展示。
#[napi]
pub fn poll_debug_log_with_levels() -> Vec<String> {
    drain_debug_logs()
}
