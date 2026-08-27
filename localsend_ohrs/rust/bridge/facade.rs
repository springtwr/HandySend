//! 门面层——所有门面模块共享的公共工具函数。
//!
//! 模块拆分后，本文件仅包含：
//! - 协议/设备类型解析辅助
//! - 初始化/销毁
//! - 设备/服务器 JSON 序列化辅助
//! - 加密/安全工具
//! - 文件名/元数据工具
//! - 调试/分享链接诊断
//!
//! 服务器逻辑 → server_facade.rs
//! 客户端逻辑 → client_facade.rs
//! 发现逻辑 → discovery_facade.rs

use anyhow::Result;
use serde_json::{json, Value};

use localsend::crypto;
use localsend::discovery::StatefulDevice;
use localsend::http::server::v2::ServerEventV2;
use localsend::http::server::web::{WebConfig, WebI18n, WebSendConfig, WebSendEvent};
use localsend::model::discovery::{DeviceType, ProtocolType};
use localsend::model::transfer::FileDto;

use crate::bridge::state::bridge;

// ── Rust → hilog 日志输出 ────────────────────────────────────────────────
// Rust 侧使用 log crate，但此前从未注册 logger（log::info! 等全部为空操作），
// 导致 announce / probe / 子网扫描等内部行为在 hilog 中完全不可见。
// 这里实现一个调用 HarmonyOS hilog NDK（OH_LOG_Print）的输出器。

use std::ffi::{c_char, c_int, CString};

#[link(name = "hilog_ndk.z")]
extern "C" {
    fn OH_LOG_Print(
        level: c_int,
        domain: u32,
        tag: *const c_char,
        fmt: *const c_char,
        ...
    ) -> c_int;
}

/// log crate → 日志缓冲输出器。
/// OH_LOG_Print 的 FFI 变参调用在 ohos target 上静默失败（无输出），
/// 因此日志写入静态缓冲，由 ArkTS 侧通过 poll_debug_log 轮询后输出到 hilog。
/// 仍保留 OH_LOG_Print 尝试（部分环境可用时可直接输出）。
pub struct HilogLogger;
static HILOG_LOGGER: HilogLogger = HilogLogger;

/// Rust 日志静态缓冲（logger 写入，poll 读取排空）。
static RUST_LOG_BUF: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// 排空并返回 Rust 日志缓冲（供 poll_debug_log 合并读取）。
pub fn drain_rust_log_buf() -> Vec<String> {
    let mut buf = RUST_LOG_BUF.lock().unwrap();
    let entries: Vec<String> = buf.drain(..).collect();
    entries
}

impl log::Log for HilogLogger {
    fn enabled(&self, _metadata: &log::Metadata) -> bool {
        true
    }

    fn log(&self, record: &log::Record) {
        let msg = format!("{}", record.args());
        // 写入静态缓冲（ArkTS 轮询输出）
        if let Ok(mut buf) = RUST_LOG_BUF.lock() {
            buf.push(msg.clone());
        }
        // 尝试直接输出到 hilog（OH_LOG_Print；ohos target 上可能静默失败，无副作用）
        let level: c_int = match record.level() {
            log::Level::Error => 3,
            log::Level::Warn => 2,
            log::Level::Info => 1,
            _ => 0, // Debug / Trace
        };
        if let Ok(cmsg) = CString::new(msg) {
            let tag = c"HandySendRust";
            let fmt = c"%s";
            unsafe {
                OH_LOG_Print(level, 0x0001, tag.as_ptr(), fmt.as_ptr(), cmsg.as_ptr());
            }
        }
    }

    fn flush(&self) {}
}

/// 注册 hilog 输出器并启用 Debug 级日志（幂等，可在任意 napi 入口调用）。
/// ArkTS 侧当前不调用 native init()，因此在此注册：
/// 各发现/服务器 napi 入口会调用本函数确保日志输出器已就位。
pub fn init_hilog_logger() {
    use std::sync::OnceLock;
    static LOGGER_INIT: OnceLock<()> = OnceLock::new();
    LOGGER_INIT.get_or_init(|| {
        let _ = log::set_logger(&HILOG_LOGGER);
        log::set_max_level(log::LevelFilter::Debug);
        // 将 localsend core 内部的 tracing 事件（socket 绑定、probe、扫描等）转发到 log crate，
        // 经 HilogLogger 输出到 hilog，便于追踪发现流程内部行为。
        let _ = tracing_log::LogTracer::init();
    });
}

// ── 公共门面 API ────────────────────────────────────────────────────────

/// 根据 `use_https` 状态获取当前协议类型。
pub fn current_protocol() -> ProtocolType {
    let state = bridge().lock().unwrap();
    if state.use_https {
        ProtocolType::Https
    } else {
        ProtocolType::Http
    }
}

/// 将协议字符串（"https" / "http"）解析为 ProtocolType。
/// 无法识别时默认使用 Https。
pub fn parse_protocol_helper(s: &str) -> ProtocolType {
    match s.to_lowercase().as_str() {
        "http" => ProtocolType::Http,
        _ => ProtocolType::Https,
    }
}

pub fn parse_device_type(s: &str) -> DeviceType {
    match s.to_lowercase().as_str() {
        "desktop" | "pc" => DeviceType::Desktop,
        "web" | "browser" => DeviceType::Web,
        "headless" => DeviceType::Headless,
        "server" => DeviceType::Server,
        _ => DeviceType::Mobile,
    }
}

pub fn init(alias: String, device_type: DeviceType) -> Result<()> {
    // 使用 BridgeState 中的 save_dir 作为持久化目录。
    // 这使证书指纹在应用重启间保持稳定。
    let save_dir = {
        let state = bridge().lock().unwrap();
        state.save_dir.clone()
    };
    init_with_persisted_identity(alias, device_type, &save_dir)
}

/// 与 [`init`] 类似，但会先尝试加载之前持久化的 TLS 身份
/// （私钥 + 证书）从 `persist_dir` 加载；若不存在则生成一个
/// 新的。这使证书指纹
/// 在应用重启间保持稳定。
///
/// 空的 `persist_dir` 会禁用持久化（每次启动都是新身份）。
pub fn init_with_persisted_identity(
    alias: String,
    device_type: DeviceType,
    persist_dir: &str,
) -> Result<()> {
    log::debug!(
        "[DBG-INIT] init_with_persisted_identity: alias={} persist_dir={}",
        alias,
        persist_dir
    );
    let mut state = bridge().lock().unwrap();

    // 仅在首次调用时生成证书和运行时
    if state.runtime.is_none() {
        let persist_dir = if persist_dir.is_empty() {
            None
        } else {
            Some(persist_dir)
        };
        let loaded = persist_dir.and_then(|dir| load_persisted_identity(dir).ok().flatten());
        log::debug!("[DBG-INIT]   loaded_persisted={}", loaded.is_some());

        let cert = match loaded {
            Some((key_pem, cert_pem)) => {
                // 复用持久化的身份并从中派生指纹。
                let fingerprint =
                    crypto::cert::fingerprint_from_cert_der(&extract_der_from_pem(&cert_pem));
                localsend::crypto::cert::SelfSignedCert {
                    private_key_pem: key_pem,
                    public_key_pem: String::new(),
                    certificate_pem: cert_pem,
                    fingerprint,
                }
            }
            None => {
                let cert = crypto::cert::generate_self_signed()?;
                if let Some(dir) = persist_dir {
                    let _ =
                        save_persisted_identity(dir, &cert.private_key_pem, &cert.certificate_pem);
                }
                cert
            }
        };

        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(2)
            .thread_name("localsend")
            .build()?;

        state.cert_pem = cert.certificate_pem;
        state.key_pem = cert.private_key_pem;
        state.fingerprint = cert.fingerprint;
        state.runtime = Some(rt);
    }

    state.local_alias = alias;
    state.device_type = device_type;
    Ok(())
}

/// 身份文件存储在服务器保存目录旁边。
const IDENTITY_KEY_FILE: &str = "identity.key";
const IDENTITY_CERT_FILE: &str = "identity.pem";

fn load_persisted_identity(dir: &str) -> Result<Option<(String, String)>> {
    use std::path::Path;
    let key_path = Path::new(dir).join(IDENTITY_KEY_FILE);
    let cert_path = Path::new(dir).join(IDENTITY_CERT_FILE);
    if !key_path.exists() || !cert_path.exists() {
        return Ok(None);
    }
    let key = std::fs::read_to_string(&key_path)?;
    let cert = std::fs::read_to_string(&cert_path)?;
    if key.trim().is_empty() || cert.trim().is_empty() {
        return Ok(None);
    }
    Ok(Some((key, cert)))
}

fn save_persisted_identity(dir: &str, key_pem: &str, cert_pem: &str) -> Result<()> {
    use std::path::Path;
    std::fs::create_dir_all(dir)?;
    let key_path = Path::new(dir).join(IDENTITY_KEY_FILE);
    let cert_path = Path::new(dir).join(IDENTITY_CERT_FILE);
    std::fs::write(&key_path, key_pem)?;
    std::fs::write(&cert_path, cert_pem)?;
    Ok(())
}

/// 按 cancel_id 取消一次哈希操作。不会从映射中移除该令牌
/// （操作完成后 hash_file_stream 会将其清理）。
pub fn cancel_hash(cancel_id: &str) -> Result<()> {
    let state = bridge().lock().unwrap();
    if let Some(token) = state.cancel_tokens.get(cancel_id) {
        token.cancel();
        Ok(())
    } else {
        Err(anyhow::anyhow!(
            "Cancel token not found for hash: {}",
            cancel_id
        ))
    }
}

// ── 取消令牌 ─────────────────────────────────────────────────────────────

/// 创建一个新的 CancellationToken 并返回其 UUID id。
pub fn create_cancel_token() -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let token = tokio_util::sync::CancellationToken::new();
    let mut state = bridge().lock().unwrap();
    state.cancel_tokens.insert(id.clone(), token);
    id
}

/// 按 id 取消令牌。取消后将其从映射中移除。
pub fn cancel_token_cancel(id: &str) -> Result<()> {
    let mut state = bridge().lock().unwrap();
    if let Some(token) = state.cancel_tokens.remove(id) {
        token.cancel();
        Ok(())
    } else {
        Err(anyhow::anyhow!("Cancel token not found: {}", id))
    }
}

// ── 查询工具 ──────────────────────────────────────────────────────────

pub fn get_local_device_json() -> String {
    let state = bridge().lock().unwrap();
    let json = json!({
        "alias": state.local_alias,
        "deviceType": format!("{:?}", state.device_type),
        "fingerprint": state.fingerprint,
        "port": state.local_port,
        "certPem": state.cert_pem,
    });
    json.to_string()
}

pub fn get_local_addresses() -> Vec<String> {
    let state = bridge().lock().unwrap();
    state
        .server_handle
        .as_ref()
        .map(|h| h.local_addresses().iter().map(|a| a.to_string()).collect())
        .unwrap_or_default()
}

/// 枚举所有非回环 IPv4 网络接口，返回结构化列表。
/// 使用 if_addrs crate 获取接口名、IP 地址和前缀长度。
/// 仅包含 IPv4 非回环接口，与 Rust 侧组播绑定的枚举逻辑一致。
pub fn get_network_interfaces() -> Vec<crate::NetworkInterfaceInfo> {
    match if_addrs::get_if_addrs() {
        Ok(interfaces) => interfaces
            .into_iter()
            .filter(|iface| !iface.is_loopback())
            .filter_map(|iface| match &iface.addr {
                if_addrs::IfAddr::V4(v4) => Some(crate::NetworkInterfaceInfo {
                    name: iface.name.clone(),
                    ip: v4.ip.to_string(),
                    prefix_length: v4.prefixlen as u32,
                }),
                if_addrs::IfAddr::V6(_) => None,
            })
            .collect(),
        Err(e) => {
            log::warn!("获取网络接口失败: {e}");
            Vec::new()
        }
    }
}

// ── 内部 DTO 转换 ─────────────────────────────────────────────────

pub fn device_type_to_string(dt: &DeviceType) -> &'static str {
    match dt {
        DeviceType::Mobile => "mobile",
        DeviceType::Desktop => "desktop",
        DeviceType::Web => "web",
        DeviceType::Headless => "headless",
        DeviceType::Server => "server",
    }
}

pub fn protocol_to_string(p: &ProtocolType) -> &'static str {
    match p {
        ProtocolType::Http => "http",
        ProtocolType::Https => "https",
    }
}

pub fn device_to_json(d: &StatefulDevice) -> Value {
    let http = d.device.http();
    // 根据设备的排序通道构建通道数组
    let channels: Vec<Value> = d
        .get_ranked_channels()
        .iter()
        .filter_map(|ch| ch.http())
        .map(|h| {
            json!({
                "host": h.host,
                "port": h.port,
                "protocol": protocol_to_string(&h.protocol),
            })
        })
        .collect();

    json!({
        "alias": d.device.alias,
        "fingerprint": d.device.fingerprint,
        "version": d.device.version,
        "deviceModel": d.device.device_model,
        "deviceType": d.device.device_type.as_ref().map(|dt| device_type_to_string(dt)),
        "download": d.device.download,
        "host": http.map(|h| &h.host),
        "port": http.map(|h| h.port),
        "protocol": http.map(|h| protocol_to_string(&h.protocol)),
        "channels": channels,
    })
}

pub fn server_event_to_json(event: &ServerEventV2) -> String {
    match event {
        ServerEventV2::Register { ip, info } => json!({
            "type": "register",
            "ip": ip.to_string(),
            "info": {
                "alias": info.alias,
                "version": info.version,
                "deviceModel": info.device_model,
                "deviceType": info.device_type.as_ref().map(|dt| device_type_to_string(dt)),
                "fingerprint": info.fingerprint,
                "download": info.download,
                "port": info.port,
                "protocol": protocol_to_string(&info.protocol),
            },
        })
        .to_string(),

        ServerEventV2::PrepareUpload {
            session_id,
            ip,
            info,
            cert_fingerprint,
            files,
            ..
        } => {
            let file_list: Vec<Value> = files
                .iter()
                .map(|(id, f)| {
                    let mut obj = json!({
                        "id": id,
                        "fileName": f.file_name,
                        "size": f.size,
                        "fileType": f.file_type,
                    });
                    if let Some(ref preview) = f.preview {
                        obj["preview"] = json!(preview);
                    }
                    if let Some(ref sha256) = f.sha256 {
                        obj["sha256"] = json!(sha256);
                    }
                    obj
                })
                .collect();
            json!({
                "type": "prepare_upload",
                "sessionId": session_id,
                "ip": ip.to_string(),
                "info": {
                    "alias": info.alias,
                    "version": info.version,
                    "deviceModel": info.device_model,
                    "deviceType": info.device_type.as_ref().map(|dt| device_type_to_string(dt)),
                    "fingerprint": info.fingerprint,
                    "download": info.download,
                    "port": info.port,
                },
                "certFingerprint": cert_fingerprint,
                "files": file_list,
            })
            .to_string()
        }

        ServerEventV2::FileUpload {
            session_id,
            file_id,
            file,
            ..
        } => json!({
            "type": "file_upload",
            "sessionId": session_id,
            "fileId": file_id,
            "file": {
                "fileName": file.file_name,
                "size": file.size,
                "fileType": file.file_type,
            },
        })
        .to_string(),

        ServerEventV2::SessionEnd { session_id, reason } => json!({
            "type": "session_end",
            "sessionId": session_id,
            "reason": format!("{reason:?}"),
        })
        .to_string(),

        ServerEventV2::PrepareUploadAborted { session_id } => json!({
            "type": "prepare_upload_aborted",
            "sessionId": session_id,
        })
        .to_string(),

        ServerEventV2::CancelReceived { ip, session_id } => json!({
            "type": "cancel_received",
            "ip": ip.to_string(),
            "sessionId": session_id,
        })
        .to_string(),
    }
}

// ── 加密 / 安全 ────────────────────────────────────────────────────────

pub struct KeyPairDto {
    pub private_key: String,
    pub public_key: String,
}

pub struct SecurityContextDto {
    pub private_key: String,
    pub public_key: String,
    pub certificate: String,
    pub certificate_hash: String,
}

pub struct FileMetadataDto {
    pub last_modified: Option<String>,
    pub last_accessed: Option<String>,
}

/// 校验 PEM 证书与期望的公钥匹配。
pub fn verify_cert(cert_pem: &str, public_key: &str) -> Result<()> {
    crypto::cert::verify_cert_from_pem(cert_pem.to_string(), Some(public_key))
}

/// 生成用于设备认证令牌的 Ed25519 密钥对。
pub fn generate_key_pair() -> Result<KeyPairDto> {
    let signing_key = crypto::token::generate_key();
    let private_key = crypto::token::export_private_key(&signing_key)?;
    let public_key = crypto::token::export_public_key(&signing_key)?;

    Ok(KeyPairDto {
        private_key: private_key.to_string(),
        public_key,
    })
}

/// 生成完整的安全上下文：RSA-2048 密钥对、自签名证书、
/// 以及 SHA-256 指纹。
pub fn generate_security_context() -> Result<SecurityContextDto> {
    let cert = crypto::cert::generate_self_signed()?;

    Ok(SecurityContextDto {
        private_key: cert.private_key_pem,
        public_key: cert.public_key_pem,
        certificate: cert.certificate_pem,
        certificate_hash: cert.fingerprint,
    })
}

/// 读取当前生效的安全上下文（BridgeState 中的私钥/证书/指纹）。
/// 公钥从当前生效证书的 DER 中提取 SPKI PEM；
/// 证书尚未生成时返回空公钥，供 UI 显示空值占位而不崩溃。
pub fn get_security_context() -> Result<SecurityContextDto> {
    let (cert_pem, key_pem, fingerprint) = {
        let state = bridge().lock().unwrap();
        (
            state.cert_pem.clone(),
            state.key_pem.clone(),
            state.fingerprint.clone(),
        )
    };
    let public_key = crypto::cert::public_key_from_cert_der(&extract_der_from_pem(&cert_pem))
        .unwrap_or_default();
    Ok(SecurityContextDto {
        private_key: key_pem,
        public_key,
        certificate: cert_pem,
        certificate_hash: fingerprint,
    })
}

/// 重置安全上下文：生成新的 RSA-2048 自签名证书与私钥，
/// 先覆盖持久化身份文件（save_dir 非空时），再更新 BridgeState 生效状态。
/// 写盘失败立即返回 Err，此时内存态与磁盘均保持旧值（FR-008 一致性保证）。
pub fn reset_security_context() -> Result<SecurityContextDto> {
    let cert = crypto::cert::generate_self_signed()?;

    // 先持久化覆盖磁盘文件；save_dir 为空（未配置）时跳过
    let save_dir = {
        let state = bridge().lock().unwrap();
        state.save_dir.clone()
    };
    if !save_dir.is_empty() {
        save_persisted_identity(&save_dir, &cert.private_key_pem, &cert.certificate_pem)?;
    }

    // 再更新全局生效状态（内存）
    {
        let mut state = bridge().lock().unwrap();
        state.cert_pem = cert.certificate_pem.clone();
        state.key_pem = cert.private_key_pem.clone();
        state.fingerprint = cert.fingerprint.clone();
    }

    Ok(SecurityContextDto {
        private_key: cert.private_key_pem,
        public_key: cert.public_key_pem,
        certificate: cert.certificate_pem,
        certificate_hash: cert.fingerprint,
    })
}

/// 计算指定路径文件的 SHA-256 哈希。
/// 返回十六进制编码的哈希字符串。
pub async fn hash_file(path: &str) -> Result<String> {
    let content = localsend::model::transfer::FileContent::Path(std::path::PathBuf::from(path));
    let cancel = tokio_util::sync::CancellationToken::new();

    let hash = crypto::hash::sha256_file_content(content, &cancel, |_progress| {})
        .await
        .map_err(|e| anyhow::anyhow!("{e}"))?;

    Ok(hash)
}

/// 计算文件的 SHA-256 哈希，带流式进度事件和取消支持。
/// 返回计算出的 SHA-256 哈希值（十六进制字符串）；取消时返回空字符串。
pub async fn hash_file_stream(path: &str, cancel_id: Option<String>) -> Result<String> {
    let content = localsend::model::transfer::FileContent::Path(std::path::PathBuf::from(path));

    // 获取或创建 CancellationToken
    let (cancel_id, cancel_token) = {
        let mut state = bridge().lock().unwrap();
        match cancel_id {
            Some(id) => {
                if let Some(token) = state.cancel_tokens.get(&id) {
                    (id, token.clone())
                } else {
                    let token = tokio_util::sync::CancellationToken::new();
                    state.cancel_tokens.insert(id.clone(), token.clone());
                    (id, token)
                }
            }
            None => {
                let id = uuid::Uuid::new_v4().to_string();
                let token = tokio_util::sync::CancellationToken::new();
                state.cancel_tokens.insert(id.clone(), token.clone());
                (id, token)
            }
        }
    };

    let callback = {
        let state = bridge().lock().unwrap();
        state.callback.clone()
    };

    let cid = cancel_id.clone();
    let cb = callback.clone();

    let result = crypto::hash::sha256_file_content(content, &cancel_token, move |bytes| {
        if let Some(ref cb) = cb {
            let payload = json!({
                "type": "hash_progress",
                "cancelId": cid,
                "bytes": bytes,
            });
            cb.call(payload.to_string());
        }
    })
    .await;

    // 操作完成后移除取消令牌
    {
        let mut state = bridge().lock().unwrap();
        state.cancel_tokens.remove(&cancel_id);
    }

    match result {
        Ok(hash) => {
            if let Some(ref cb) = callback {
                let payload = json!({
                    "type": "hash_done",
                    "cancelId": cancel_id,
                    "hash": hash,
                });
                cb.call(payload.to_string());
            }
            Ok(hash)
        }
        Err(localsend::crypto::hash::HashError::Cancelled) => {
            if let Some(ref cb) = callback {
                let payload = json!({
                    "type": "hash_cancelled",
                    "cancelId": cancel_id,
                });
                cb.call(payload.to_string());
            }
            Ok(String::new())
        }
        Err(e) => {
            if let Some(ref cb) = callback {
                let payload = json!({
                    "type": "hash_error",
                    "cancelId": cancel_id,
                    "error": format!("{e}"),
                });
                cb.call(payload.to_string());
            }
            Err(anyhow::anyhow!("{e}"))
        }
    }
}

/// 使用 CancellationToken 对象计算文件的 SHA-256 哈希。
/// 返回计算出的 SHA-256 哈希值（十六进制字符串）；取消时返回空字符串。
pub async fn hash_file_stream_with_token(
    path: &str,
    cancel_token: tokio_util::sync::CancellationToken,
) -> Result<String> {
    let content = localsend::model::transfer::FileContent::Path(std::path::PathBuf::from(path));

    let cancel_id = uuid::Uuid::new_v4().to_string();

    let callback = {
        let state = bridge().lock().unwrap();
        state.callback.clone()
    };

    let cid = cancel_id.clone();
    let cb = callback.clone();

    let result = crypto::hash::sha256_file_content(content, &cancel_token, move |bytes| {
        if let Some(ref cb) = cb {
            let payload = json!({
                "type": "hash_progress",
                "cancelId": cid,
                "bytes": bytes,
            });
            cb.call(payload.to_string());
        }
    })
    .await;

    match result {
        Ok(hash) => {
            if let Some(ref cb) = callback {
                let payload = json!({
                    "type": "hash_done",
                    "cancelId": cancel_id,
                    "hash": hash,
                });
                cb.call(payload.to_string());
            }
            Ok(hash)
        }
        Err(localsend::crypto::hash::HashError::Cancelled) => {
            if let Some(ref cb) = callback {
                let payload = json!({
                    "type": "hash_cancelled",
                    "cancelId": cancel_id,
                });
                cb.call(payload.to_string());
            }
            Ok(String::new())
        }
        Err(e) => {
            if let Some(ref cb) = callback {
                let payload = json!({
                    "type": "hash_error",
                    "cancelId": cancel_id,
                    "error": format!("{e}"),
                });
                cb.call(payload.to_string());
            }
            Err(anyhow::anyhow!("{e}"))
        }
    }
}

/// 计算内存缓冲区的 SHA-256 哈希。
pub fn hash_buffer(data: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(data);
    hex::encode(hasher.finalize())
}

pub fn compute_fingerprint(cert_pem: &str) -> String {
    let cert_der = extract_der_from_pem(cert_pem);
    crypto::cert::fingerprint_from_cert_der(&cert_der)
}

fn extract_der_from_pem(pem_str: &str) -> Vec<u8> {
    use std::io::Cursor;
    match x509_parser::pem::Pem::read(Cursor::new(pem_str.as_bytes())) {
        Ok((pem, _)) => pem.contents.to_vec(),
        Err(_) => Vec::new(),
    }
}

pub fn verify_fingerprint(cert_pem: &str, expected: &str) -> bool {
    let actual = compute_fingerprint(cert_pem);
    actual.eq_ignore_ascii_case(expected)
}

/// 计算组合指纹字符串的 SHA-256 哈希。
/// 返回十六进制编码的哈希字符串（小写，64 个字符）。
/// 用于验证页面的图标映射。
pub fn compute_fingerprint_hash(combined: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(combined.as_bytes());
    let result = hasher.finalize();
    hex::encode(result)
}

// ── 文件名工具 ──────────────────────────────────────────────────────

/// 将 `name` 重写为当前平台合法的文件名，
/// 将非法字符替换为 `_`。
pub fn sanitize_file_name(name: String) -> String {
    localsend::util::filename::sanitize(&name, localsend::util::filename::Rules::current())
}

/// 判断 `name` 是否为当前平台合法的文件名。
pub fn is_valid_file_name(name: String) -> bool {
    localsend::util::filename::is_valid(&name, localsend::util::filename::Rules::current())
}

// ── 文件元数据 ────────────────────────────────────────────────────────────

/// 以 RFC 3339 字符串读取文件时间戳。
pub fn read_file_metadata(path: &str) -> Option<FileMetadataDto> {
    use localsend::model::transfer::FileMetadata;

    let meta = FileMetadata::from_path(std::path::Path::new(path))?;

    Some(FileMetadataDto {
        last_modified: meta.modified,
        last_accessed: meta.accessed,
    })
}

// ── 调试 / 诊断 ──────────────────────────────────────────────────────

pub fn poll_debug_log() -> Vec<String> {
    let entries: Vec<String> = {
        let state = bridge().lock().unwrap();
        let mut log = state.debug_log.lock().unwrap();
        log.drain(..).collect()
    };
    let mut entries = entries;
    // 合并 Rust 日志缓冲（logger 输出）
    entries.append(&mut drain_rust_log_buf());
    entries
}

/// 为 Rust 层启用调试级日志。
pub fn enable_debug_logging() -> Result<()> {
    log::set_max_level(log::LevelFilter::Debug);
    log::debug!("Debug logging enabled");
    Ok(())
}

pub async fn create_share_link(files_json: &str, _alias: &str) -> Result<String> {
    // 解析文件 JSON 数组
    let files: Vec<Value> = serde_json::from_str(files_json)
        .map_err(|e| anyhow::anyhow!("Failed to parse files JSON: {e:#}"))?;

    if files.is_empty() {
        return Err(anyhow::anyhow!("No files provided for share link"));
    }

    // 构建 FileDto HashMap 和 fileId→filePath 映射
    let mut file_dtos: std::collections::HashMap<String, FileDto> =
        std::collections::HashMap::new();
    let mut file_paths: std::collections::HashMap<String, String> =
        std::collections::HashMap::new();

    for f in &files {
        let file_id = f["fileId"].as_str().unwrap_or("").to_string();
        let file_name = f["fileName"].as_str().unwrap_or("").to_string();
        let size = f["size"].as_u64().unwrap_or(0);
        let file_type = f["fileType"].as_str().unwrap_or("").to_string();
        let file_path = f["filePath"].as_str().unwrap_or("").to_string();
        let preview = f["preview"].as_str().map(|s| s.to_string());
        let sha256 = f["sha256"].as_str().map(|s| s.to_string());

        if file_id.is_empty() || file_path.is_empty() {
            continue;
        }

        file_dtos.insert(
            file_id.clone(),
            FileDto {
                id: file_id.clone(),
                file_name: file_name.clone(),
                size,
                file_type: file_type.clone(),
                sha256: sha256.clone(),
                preview: preview.clone(),
                metadata: None,
            },
        );
        file_paths.insert(file_id.clone(), file_path);
    }

    if file_dtos.is_empty() {
        return Err(anyhow::anyhow!("No valid files provided for share link"));
    }

    // 从状态读取接收 PIN
    let current_pin: Option<String> = {
        let state = bridge().lock().unwrap();
        state.receive_pin.clone()
    };

    // 创建 WebSend 事件通道
    let (web_send_event_tx, web_send_event_rx) = tokio::sync::mpsc::channel::<WebSendEvent>(64);

    // 停止当前服务器并等待端口释放
    let wait_stopped_fut = {
        let mut state = bridge().lock().unwrap();
        // 发送停止信号
        if let Some(stop_tx) = state.server_stop_tx.take() {
            let _ = stop_tx.send(());
        }
        // 取得句柄，以便等待优雅关闭
        state.server_handle.take()
    };

    // 获取重启所需的状态值
    let (port, use_https, verify_checksums, callback) = {
        let state = bridge().lock().unwrap();
        (
            state.local_port,
            state.use_https,
            state.verify_checksums,
            state.callback.clone(),
        )
    };

    // 等待服务器任务完成（端口释放），而非固定休眠
    if let Some(handle) = wait_stopped_fut {
        handle.wait_stopped().await;
    }

    // 使用 WebSendConfig 构建 WebConfig
    let i18n = build_web_i18n();
    let web_send_config = WebSendConfig {
        files: file_dtos,
        pin: current_pin.clone(),
        event_tx: web_send_event_tx.clone(),
    };
    let web_config = WebConfig {
        send: Some(web_send_config),
        upload: false,
        i18n,
    };

    // 将 Web 发送状态存入 BridgeState
    {
        let mut state = bridge().lock().unwrap();
        state.web_send_event_tx = Some(web_send_event_tx);
        *state.web_send_files.lock().unwrap() = file_paths;
    }

    // 以 WebConfig 重启服务器（直接 await——我们已在异步上下文中）
    crate::bridge::server_facade::start_server(
        port,
        use_https,
        verify_checksums,
        current_pin,
        Some(web_config),
    )
    .await?;

    // 派生 WebSendEvent 处理任务
    crate::bridge::server_facade::spawn_web_send_event_task(web_send_event_rx, callback.clone());

    // 从重启后的服务器获取实际端口和 IP
    let (actual_port, local_ip) = {
        let state = bridge().lock().unwrap();
        let port = state.local_port;
        // 从服务器句柄获取第一个非回环 IP
        let ip = state
            .server_handle
            .as_ref()
            .and_then(|h| {
                h.local_addresses()
                    .iter()
                    .find(|a| !a.ip().is_loopback())
                    .map(|a| a.ip().to_string())
            })
            .unwrap_or_else(|| "0.0.0.0".to_string());
        (port, ip)
    };

    // 构建分享 URL
    let protocol = if use_https { "https" } else { "http" };
    let url = if local_ip == "0.0.0.0" {
        // 回退：直接使用端口
        format!("{}://0.0.0.0:{}", protocol, actual_port)
    } else {
        format!("{}://{}:{}", protocol, local_ip, actual_port)
    };

    // 存储 ShareLinkState
    let session_id = format!(
        "web_send_{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
    );
    {
        let state = bridge().lock().unwrap();
        *state.share_link_info.lock().unwrap() = Some(crate::bridge::state::ShareLinkState {
            url: url.clone(),
            port: actual_port,
            session_id: session_id.clone(),
        });
    }

    Ok(json!({
        "url": url,
        "port": actual_port,
        "sessionId": session_id,
    })
    .to_string())
}

pub async fn stop_share_server() {
    // 停止当前服务器并取得句柄以便优雅关闭
    let wait_stopped_fut = {
        let mut state = bridge().lock().unwrap();
        // 发送停止信号
        if let Some(stop_tx) = state.server_stop_tx.take() {
            let _ = stop_tx.send(());
        }
        let handle = state.server_handle.take();
        // 清除 Web 发送状态
        state.web_send_event_tx.take();
        state.web_send_files.lock().unwrap().clear();
        state.web_download_decisions.clear();
        state.pending_file_uploads.clear();
        state.pending_file_downloads.clear();
        *state.share_link_info.lock().unwrap() = None;
        handle
    };

    // 获取重启所需的状态值
    let (port, use_https, verify_checksums, current_pin) = {
        let state = bridge().lock().unwrap();
        (
            state.local_port,
            state.use_https,
            state.verify_checksums,
            state.receive_pin.clone(),
        )
    };

    // 等待服务器任务完成（端口释放），而非固定休眠
    if let Some(handle) = wait_stopped_fut {
        handle.wait_stopped().await;
    }

    // 以正常模式重启服务器（无 WebConfig）
    let _ = crate::bridge::server_facade::start_server(
        port,
        use_https,
        verify_checksums,
        current_pin,
        None, // 无 Web 配置 → 正常模式
    )
    .await;
}

pub fn get_recv_diag() -> String {
    let state = bridge().lock().unwrap();
    let drain_count = *state.recv_diag_drain_count.lock().unwrap();
    let queued_events = {
        let log = state.debug_log.lock().unwrap();
        log.len() as u64
    };
    drop(state);

    json!({
        "drainCount": drain_count,
        "queuedEvents": queued_events,
    })
    .to_string()
}

/// 为 Web 分享页面构建带中文翻译的 WebI18n。
pub fn build_web_i18n() -> WebI18n {
    WebI18n {
        waiting: "等待响应…".to_string(),
        enter_pin: "输入PIN".to_string(),
        invalid_pin: "PIN错误".to_string(),
        too_many_attempts: "尝试次数过多".to_string(),
        rejected: "已拒绝".to_string(),
        upload_rejected: "接收方已拒绝请求。".to_string(),
        busy: "接收方正忙。".to_string(),
        files: "文件".to_string(),
        file_name: "文件名".to_string(),
        size: "大小".to_string(),
        download_all: "全部下载".to_string(),
        download: "下载".to_string(),
        select_files: "选择文件".to_string(),
        upload: "上传".to_string(),
        uploading: "正在上传".to_string(),
        upload_complete: "上传完成".to_string(),
        remove: "移除".to_string(),
        cancel: "取消".to_string(),
        confirm: "确定".to_string(),
        shared_by: "来自".to_string(),
        network_error: "网络错误".to_string(),
        retry: "重试".to_string(),
    }
}
