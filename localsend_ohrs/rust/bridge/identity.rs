//! 本机身份 / 安全上下文 / 网络信息 / 通用工具。
//!
//! 聚合 init/init_with_persisted_identity（initialized 标志判断首次初始化）、
//! 安全上下文查询/重置、协议/设备类型解析、哈希工具、取消令牌、日志缓冲等
//! "本机身份与基础能力"函数。
//!
//! 不创建 tokio Runtime——runtime 由 NAPI 层 NapiEnv 管理。

use std::sync::Mutex;

use anyhow::Result;

use localsend::crypto;
use localsend::model::discovery::{DeviceType, ProtocolType};

use crate::bridge::event::BridgeError;
use crate::bridge::state::BridgeState;

// ── 解析工具 ────────────────────────────────────────────────────────────

/// 将协议字符串（"https" / "http"）解析为 ProtocolType，无法识别时默认 Https。
pub fn parse_protocol(s: &str) -> ProtocolType {
    match s.to_lowercase().as_str() {
        "http" => ProtocolType::Http,
        _ => ProtocolType::Https,
    }
}

/// 将设备类型字符串解析为 DeviceType，无法识别时默认 Mobile。
pub fn parse_device_type(s: &str) -> DeviceType {
    match s.to_lowercase().as_str() {
        "desktop" | "pc" => DeviceType::Desktop,
        "web" | "browser" => DeviceType::Web,
        "headless" => DeviceType::Headless,
        "server" => DeviceType::Server,
        _ => DeviceType::Mobile,
    }
}

/// DeviceType → 字符串（"mobile" / "desktop" / ...）。
pub fn device_type_to_string(dt: &DeviceType) -> &'static str {
    match dt {
        DeviceType::Mobile => "mobile",
        DeviceType::Desktop => "desktop",
        DeviceType::Web => "web",
        DeviceType::Headless => "headless",
        DeviceType::Server => "server",
    }
}

/// 当前协议类型（根据 use_https 状态）。
pub fn current_protocol(state: &BridgeState) -> ProtocolType {
    if state.use_https {
        ProtocolType::Https
    } else {
        ProtocolType::Http
    }
}

// ── 初始化 ────────────────────────────────────────────────────────────

/// 初始化桥接层（使用 state.save_dir 作为持久化目录）。
pub fn init(
    state: &Mutex<BridgeState>,
    alias: String,
    device_type: DeviceType,
) -> Result<(), BridgeError> {
    let save_dir = state.lock().unwrap().save_dir.clone();
    init_with_persisted_identity(state, alias, device_type, &save_dir)
}

/// 使用持久化身份初始化桥接层。
///
/// - 首次调用（`initialized == false`）时生成/加载 TLS 证书并计算指纹
/// - 后续调用复用已有证书，不重新生成（重复初始化安全）
/// - 不创建 runtime
pub fn init_with_persisted_identity(
    state: &Mutex<BridgeState>,
    alias: String,
    device_type: DeviceType,
    persist_dir: &str,
) -> Result<(), BridgeError> {
    log::debug!(
        "[DBG-INIT] init_with_persisted_identity: alias={} persist_dir={}",
        alias,
        persist_dir
    );
    let mut s = state.lock().unwrap();

    // 仅在首次初始化时生成/加载证书
    if !s.initialized {
        let persist_dir = if persist_dir.is_empty() {
            None
        } else {
            Some(persist_dir)
        };
        let loaded = persist_dir.and_then(|dir| load_persisted_identity(dir).ok().flatten());
        log::debug!("[DBG-INIT]   loaded_persisted={}", loaded.is_some());

        let cert = match loaded {
            Some((key_pem, cert_pem)) => {
                // 复用持久化的身份并从中派生指纹
                let fingerprint = fingerprint_from_cert_pem(&cert_pem);
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

        s.cert_pem = cert.certificate_pem;
        s.key_pem = cert.private_key_pem;
        s.fingerprint = cert.fingerprint;
        s.initialized = true;
    }

    // persist_dir 非空时同步到 save_dir（规范化尾斜杠）：reset_security_context
    // 依赖 save_dir 写盘持久化身份，若仅在 createServer 时才设置，服务器未
    // 启动状态下重置身份将不写盘，重启后会被磁盘上的旧身份覆盖。
    // createServer 随后会用配置中的 saveDir 再次赋值（真实应用中两者相同）。
    if !persist_dir.is_empty() {
        if persist_dir.ends_with('/') {
            s.save_dir = persist_dir.to_string();
        } else {
            s.save_dir = format!("{persist_dir}/");
        }
    }

    s.local_alias = alias;
    s.device_type = device_type;
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

// ── 安全上下文 ──────────────────────────────────────────────────────────

/// 安全上下文 DTO（私钥/公钥/证书/指纹）。
pub struct SecurityContextDto {
    pub private_key: String,
    pub public_key: String,
    pub certificate: String,
    pub certificate_hash: String,
}

/// 读取当前生效的安全上下文。证书尚未生成时返回空公钥（占位不崩溃）。
pub fn get_security_context(state: &BridgeState) -> Result<SecurityContextDto, BridgeError> {
    let cert_pem = state.cert_pem.clone();
    let key_pem = state.key_pem.clone();
    let fingerprint = state.fingerprint.clone();
    let public_key = public_key_from_cert_pem(&cert_pem);
    Ok(SecurityContextDto {
        private_key: key_pem,
        public_key,
        certificate: cert_pem,
        certificate_hash: fingerprint,
    })
}

/// 重置安全上下文：生成新的自签名证书与私钥，
/// 先覆盖持久化身份文件（save_dir 非空时），再更新 BridgeState 生效状态。
/// 写盘失败立即返回 Err，此时内存态与磁盘均保持旧值。
pub fn reset_security_context(
    state: &Mutex<BridgeState>,
) -> Result<SecurityContextDto, BridgeError> {
    let cert = crypto::cert::generate_self_signed()?;

    // 先持久化覆盖磁盘文件
    {
        let s = state.lock().unwrap();
        if !s.save_dir.is_empty() {
            save_persisted_identity(&s.save_dir, &cert.private_key_pem, &cert.certificate_pem)?;
        }
    }

    // 再更新状态
    {
        let mut s = state.lock().unwrap();
        s.cert_pem = cert.certificate_pem.clone();
        s.key_pem = cert.private_key_pem.clone();
        s.fingerprint = cert.fingerprint.clone();
        s.initialized = true;
    }

    Ok(SecurityContextDto {
        private_key: cert.private_key_pem,
        public_key: cert.public_key_pem,
        certificate: cert.certificate_pem,
        certificate_hash: cert.fingerprint,
    })
}

// ── 网络信息 ────────────────────────────────────────────────────────────

/// 网络接口信息（纯数据，NAPI 层转换为 #[napi(object)] 类型）。
#[derive(Debug, Clone)]
pub struct NetworkInterfaceInfo {
    pub name: String,
    pub ip: String,
    pub prefix_length: u32,
}

/// 获取本机服务器可访问的本地地址。
pub fn get_local_addresses(state: &BridgeState) -> Vec<String> {
    state
        .server_handle
        .as_ref()
        .map(|h| h.local_addresses().iter().map(|a| a.to_string()).collect())
        .unwrap_or_default()
}

/// 枚举所有非回环 IPv4 网络接口，返回结构化列表。
/// 使用 if_addrs crate 获取接口名、IP 地址和前缀长度，
/// 与 Rust 侧组播绑定的枚举逻辑一致。
pub fn get_network_interfaces() -> Vec<NetworkInterfaceInfo> {
    match if_addrs::get_if_addrs() {
        Ok(interfaces) => interfaces
            .into_iter()
            .filter(|iface| !iface.is_loopback())
            .filter_map(|iface| match &iface.addr {
                if_addrs::IfAddr::V4(v4) => Some(NetworkInterfaceInfo {
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

// ── 哈希工具 ────────────────────────────────────────────────────────────

/// 计算内存缓冲区的 SHA-256 哈希（十六进制）。
pub fn hash_buffer(data: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(data);
    hex::encode(hasher.finalize())
}

/// 计算组合指纹字符串的 SHA-256 哈希。
pub fn compute_fingerprint_hash(combined: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(combined.as_bytes());
    hex::encode(hasher.finalize())
}

/// 从 PEM 证书提取 DER 内容。
pub fn extract_der_from_pem(pem_str: &str) -> Vec<u8> {
    use std::io::Cursor;
    match x509_parser::pem::Pem::read(Cursor::new(pem_str.as_bytes())) {
        Ok((pem, _)) => pem.contents.to_vec(),
        Err(_) => Vec::new(),
    }
}

/// 从 PEM 证书提取公钥（SPKI PEM）。
pub fn public_key_from_cert_pem(cert_pem: &str) -> String {
    crypto::cert::public_key_from_cert_der(&extract_der_from_pem(cert_pem)).unwrap_or_default()
}

/// 从 PEM 证书计算指纹。
pub fn fingerprint_from_cert_pem(cert_pem: &str) -> String {
    crypto::cert::fingerprint_from_cert_der(&extract_der_from_pem(cert_pem))
}

/// 计算文件的 SHA-256 哈希，带流式进度和取消支持。
/// 取消时返回空字符串。
pub async fn hash_file_stream(
    state: &Mutex<BridgeState>,
    path: &str,
    cancel_id: Option<String>,
) -> Result<String, BridgeError> {
    let content = localsend::model::transfer::FileContent::Path(std::path::PathBuf::from(path));

    hash_content(state, content, cancel_id).await
}

/// 基于已打开的文件描述符计算 SHA-256（fd 直读场景，源文件不在沙箱路径）。
/// fd 所有权随 from_raw_fd 移交，计算完成或取消后由包装的 File 关闭。
#[cfg(any(target_os = "android", all(target_os = "linux", target_env = "ohos")))]
pub async fn hash_file_stream_fd(
    state: &Mutex<BridgeState>,
    fd: i32,
    cancel_id: Option<String>,
) -> Result<String, BridgeError> {
    let content = localsend::model::transfer::FileContent::Fd(fd);

    hash_content(state, content, cancel_id).await
}

/// 哈希公共实现：解析/创建取消令牌后流式计算 SHA-256。
async fn hash_content(
    state: &Mutex<BridgeState>,
    content: localsend::model::transfer::FileContent,
    cancel_id: Option<String>,
) -> Result<String, BridgeError> {
    // 获取或创建 CancellationToken
    let (cancel_id, cancel_token) = {
        let mut s = state.lock().unwrap();
        match cancel_id {
            Some(id) => {
                if let Some(token) = s.cancel_tokens.get(&id) {
                    (id, token.clone())
                } else {
                    let token = tokio_util::sync::CancellationToken::new();
                    s.cancel_tokens.insert(id.clone(), token.clone());
                    (id, token)
                }
            }
            None => {
                let id = uuid::Uuid::new_v4().to_string();
                let token = tokio_util::sync::CancellationToken::new();
                s.cancel_tokens.insert(id.clone(), token.clone());
                (id, token)
            }
        }
    };

    let result = crypto::hash::sha256_file_content(content, &cancel_token, |_bytes| {
        // 进度回调：当前实现不推送进度事件（保持简洁）
    })
    .await;

    // 操作完成后移除取消令牌
    {
        let mut s = state.lock().unwrap();
        s.cancel_tokens.remove(&cancel_id);
    }

    match result {
        Ok(hash) => Ok(hash),
        Err(localsend::crypto::hash::HashError::Cancelled) => Ok(String::new()),
        Err(e) => Err(BridgeError::Upstream(anyhow::anyhow!("{e}"))),
    }
}

/// 创建取消令牌，返回唯一 ID。
pub fn create_cancel_token(state: &Mutex<BridgeState>) -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let count = COUNTER.fetch_add(1, Ordering::Relaxed);
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let id = format!("{ts}-{count}");
    let token = tokio_util::sync::CancellationToken::new();
    let mut state = state.lock().unwrap();
    state.cancel_tokens.insert(id.clone(), token);
    id
}

/// 按 cancel_id 取消一次哈希操作。
pub fn cancel_hash(state: &BridgeState, cancel_id: &str) -> Result<(), BridgeError> {
    if let Some(token) = state.cancel_tokens.get(cancel_id) {
        token.cancel();
        Ok(())
    } else {
        Err(BridgeError::InvalidArgument(format!(
            "取消令牌不存在: {}",
            cancel_id
        )))
    }
}

// ── 日志 ──────────────────────────────────────────────────────────────

/// Rust 日志静态缓冲（logger 写入，poll 读取排空）。
/// 缓冲元素格式为 `level|message`（首个 `|` 为分隔符），供 ArkTS 侧还原原始级别。
static RUST_LOG_BUF: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// 日志级别 → 协议 token（与 ArkTS `common/LogLevels.ets` 取值一致）。
pub fn log_level_token(level: log::Level) -> &'static str {
    match level {
        log::Level::Error => "error",
        log::Level::Warn => "warn",
        log::Level::Info => "info",
        log::Level::Debug => "debug",
        log::Level::Trace => "trace",
    }
}

/// 构造缓冲区记录（`level|message`）。
fn format_log_entry(level: log::Level, msg: &str) -> String {
    format!("{}|{}", log_level_token(level), msg)
}

/// 剥离 `level|` 前缀，返回纯消息（无分隔符时原样返回）。
fn strip_level_prefix(entry: &str) -> String {
    match entry.find('|') {
        Some(idx) => entry[idx + 1..].to_string(),
        None => entry.to_string(),
    }
}

/// 排空并返回带级别的 Rust 日志缓冲，元素格式为 `level|message`。
pub fn drain_rust_log_buf_with_levels() -> Vec<String> {
    let mut buf = RUST_LOG_BUF.lock().unwrap();
    buf.drain(..).collect()
}

/// 排空并返回纯消息的 Rust 日志缓冲（兼容接口：剥离 `level|` 前缀）。
pub fn drain_rust_log_buf() -> Vec<String> {
    drain_rust_log_buf_with_levels()
        .into_iter()
        .map(|entry| strip_level_prefix(&entry))
        .collect()
}

#[cfg(feature = "napi")]
mod hilog_impl {
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
    pub struct HilogLogger;
    pub static HILOG_LOGGER: HilogLogger = HilogLogger;

    impl log::Log for HilogLogger {
        fn enabled(&self, _metadata: &log::Metadata) -> bool {
            true
        }

        fn log(&self, record: &log::Record) {
            let msg = format!("{}", record.args());
            if let Ok(mut buf) = super::RUST_LOG_BUF.lock() {
                // 写入 level 前缀，供 ArkTS 侧还原原始级别后分级展示
                buf.push(super::format_log_entry(record.level(), &msg));
            }
            let level: c_int = match record.level() {
                log::Level::Error => 3,
                log::Level::Warn => 2,
                log::Level::Info => 1,
                _ => 0,
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
}

/// 注册日志输出器（幂等）。NAPI 环境下输出到 hilog，否则仅写缓冲。
pub fn init_hilog_logger() {
    use std::sync::OnceLock;
    static LOGGER_INIT: OnceLock<()> = OnceLock::new();

    #[cfg(not(feature = "napi"))]
    static BUF_LOGGER: BufLogger = BufLogger;

    #[cfg(not(feature = "napi"))]
    struct BufLogger;

    #[cfg(not(feature = "napi"))]
    impl log::Log for BufLogger {
        fn enabled(&self, _metadata: &log::Metadata) -> bool {
            true
        }
        fn log(&self, record: &log::Record) {
            if let Ok(mut buf) = RUST_LOG_BUF.lock() {
                // 写入 level 前缀，供 ArkTS 侧还原原始级别后分级展示
                buf.push(format_log_entry(record.level(), &format!("{}", record.args())));
            }
        }
        fn flush(&self) {}
    }

    LOGGER_INIT.get_or_init(|| {
        #[cfg(feature = "napi")]
        {
            let _ = log::set_logger(&hilog_impl::HILOG_LOGGER);
            log::set_max_level(log::LevelFilter::Debug);
            let _ = tracing_log::LogTracer::init();
        }
        #[cfg(not(feature = "napi"))]
        {
            let _ = log::set_logger(&BUF_LOGGER);
            log::set_max_level(log::LevelFilter::Debug);
        }
    });
}

// ── 文件名工具 ──────────────────────────────────────────────────────

/// 将 `name` 重写为当前平台合法的文件名，将非法字符替换为 `_`。
pub fn sanitize_file_name(name: String) -> String {
    localsend::util::filename::sanitize(&name, localsend::util::filename::Rules::current())
}

/// 为 Web 分享页面构建带中文翻译的 WebI18n。
pub fn build_web_i18n() -> localsend::http::server::web::WebI18n {
    localsend::http::server::web::WebI18n {
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

// ── 单元测试 ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::sync::Arc;

    // ── 解析工具测试 ──

    #[test]
    fn parse_protocol_http() {
        assert!(matches!(parse_protocol("http"), ProtocolType::Http));
    }

    #[test]
    fn parse_protocol_https() {
        assert!(matches!(parse_protocol("https"), ProtocolType::Https));
    }

    #[test]
    fn parse_protocol_case_insensitive() {
        assert!(matches!(parse_protocol("HTTP"), ProtocolType::Http));
        assert!(matches!(parse_protocol("Https"), ProtocolType::Https));
    }

    #[test]
    fn parse_protocol_unknown_defaults_https() {
        assert!(matches!(parse_protocol("ftp"), ProtocolType::Https));
        assert!(matches!(parse_protocol(""), ProtocolType::Https));
    }

    #[test]
    fn parse_device_type_variants() {
        assert!(matches!(parse_device_type("mobile"), DeviceType::Mobile));
        assert!(matches!(parse_device_type("desktop"), DeviceType::Desktop));
        assert!(matches!(parse_device_type("pc"), DeviceType::Desktop));
        assert!(matches!(parse_device_type("web"), DeviceType::Web));
        assert!(matches!(parse_device_type("browser"), DeviceType::Web));
        assert!(matches!(
            parse_device_type("headless"),
            DeviceType::Headless
        ));
        assert!(matches!(parse_device_type("server"), DeviceType::Server));
    }

    #[test]
    fn parse_device_type_unknown_defaults_mobile() {
        assert!(matches!(parse_device_type("tablet"), DeviceType::Mobile));
        assert!(matches!(parse_device_type(""), DeviceType::Mobile));
    }

    // ── 哈希测试 ──

    #[test]
    fn hash_buffer_known_value() {
        let empty = hash_buffer(&[]);
        assert_eq!(empty.len(), 64);
        assert_eq!(
            empty,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        let hello = hash_buffer(b"hello");
        assert_eq!(
            hello,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn compute_fingerprint_hash_known_value() {
        let empty = compute_fingerprint_hash("");
        assert_eq!(
            empty,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        let hash = compute_fingerprint_hash("fp1|fp2");
        assert_eq!(
            hash,
            "455d623607d040d959540809aaa43092013fa4b9af6ad951996b44ce69b04e43"
        );
    }

    // ── DER / 指纹测试 ──

    #[test]
    fn extract_der_from_pem_invalid() {
        let result = extract_der_from_pem("not a pem");
        assert!(result.is_empty());
    }

    #[test]
    fn extract_der_from_pem_empty() {
        let result = extract_der_from_pem("");
        assert!(result.is_empty());
    }

    #[test]
    fn extract_der_from_pem_valid() {
        let cert = localsend::crypto::cert::generate_self_signed().unwrap();
        let der = extract_der_from_pem(&cert.certificate_pem);
        assert!(!der.is_empty(), "合法 PEM 应返回非空 DER");
        assert_eq!(der[0], 0x30, "DER 应以 SEQUENCE 标签开头");
    }

    // ── 初始化 / 证书测试 ──

    #[test]
    fn init_generates_cert_and_sets_initialized() {
        let state = Mutex::new(BridgeState::new());
        init_with_persisted_identity(&state, "MyPhone".to_string(), DeviceType::Mobile, "")
            .unwrap();

        let s = state.lock().unwrap();
        assert!(s.initialized);
        assert_eq!(s.local_alias, "MyPhone");
        assert!(!s.cert_pem.is_empty());
        assert!(!s.key_pem.is_empty());
        assert!(!s.fingerprint.is_empty());
    }

    #[test]
    fn init_twice_reuses_identity() {
        let state = Mutex::new(BridgeState::new());
        init_with_persisted_identity(&state, "A".to_string(), DeviceType::Mobile, "").unwrap();
        let cert1 = state.lock().unwrap().cert_pem.clone();
        let fp1 = state.lock().unwrap().fingerprint.clone();

        init_with_persisted_identity(&state, "B".to_string(), DeviceType::Desktop, "").unwrap();
        let s = state.lock().unwrap();
        assert_eq!(s.cert_pem, cert1, "重复初始化应复用证书");
        assert_eq!(s.fingerprint, fp1, "指纹不应变化");
        assert_eq!(s.local_alias, "B", "alias 应更新");
        assert_eq!(s.device_type, DeviceType::Desktop, "device_type 应更新");
    }

    #[test]
    fn init_with_persisted_identity_roundtrip() {
        let dir = format!(
            "{}/handysend-identity-test/",
            std::env::temp_dir().display()
        );
        let _ = std::fs::remove_dir_all(&dir);

        // 首次初始化：生成并持久化
        {
            let state = Mutex::new(BridgeState::new());
            init_with_persisted_identity(&state, "A".to_string(), DeviceType::Mobile, &dir)
                .unwrap();
            let fp = state.lock().unwrap().fingerprint.clone();
            assert!(!fp.is_empty());
        }

        // 重新初始化：从磁盘复用
        {
            let state = Mutex::new(BridgeState::new());
            init_with_persisted_identity(&state, "B".to_string(), DeviceType::Mobile, &dir)
                .unwrap();
            let fp = state.lock().unwrap().fingerprint.clone();
            assert!(!fp.is_empty());
            // 复用后的指纹与首次一致
        }

        // 清理
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn reset_security_context_generates_new_cert() {
        let dir = format!("{}/handysend-reset-test/", std::env::temp_dir().display());
        let mut bs = BridgeState::new();
        bs.save_dir = dir.clone();
        let state = Mutex::new(bs);

        let ctx1 = reset_security_context(&state).unwrap();
        assert!(!ctx1.certificate.is_empty());
        assert!(!ctx1.private_key.is_empty());
        assert!(!ctx1.certificate_hash.is_empty());

        // 验证磁盘持久化文件已写入
        assert!(std::path::Path::new(&format!("{}identity.key", dir)).exists());
        assert!(std::path::Path::new(&format!("{}identity.pem", dir)).exists());

        // 清理
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn reset_security_context_updates_fingerprint() {
        let dir = format!(
            "{}/handysend-reset-fp-test/",
            std::env::temp_dir().display()
        );
        let mut bs = BridgeState::new();
        bs.save_dir = dir.clone();
        let state = Mutex::new(bs);

        let ctx1 = reset_security_context(&state).unwrap();
        let ctx2 = reset_security_context(&state).unwrap();
        assert_ne!(ctx1.certificate_hash, ctx2.certificate_hash);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn reset_after_init_persists_to_persist_dir() {
        let dir = format!(
            "{}/handysend-reset-after-init-test/",
            std::env::temp_dir().display()
        );
        let _ = std::fs::remove_dir_all(&dir);

        // 未经 createServer 的初始化也应把 persist_dir 同步到 save_dir：
        // 服务器未启动状态下重置身份必须写盘，否则重启后会被旧身份覆盖
        let state = Mutex::new(BridgeState::new());
        init_with_persisted_identity(&state, "A".to_string(), DeviceType::Mobile, &dir).unwrap();
        let ctx1 = reset_security_context(&state).unwrap();
        assert!(std::path::Path::new(&format!("{}identity.key", dir)).exists());
        assert!(std::path::Path::new(&format!("{}identity.pem", dir)).exists());

        // 重新初始化应加载重置后的身份（指纹一致）
        let state2 = Mutex::new(BridgeState::new());
        init_with_persisted_identity(&state2, "B".to_string(), DeviceType::Mobile, &dir).unwrap();
        let fp = state2.lock().unwrap().fingerprint.clone();
        assert_eq!(fp, ctx1.certificate_hash);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_security_context_empty_cert() {
        let state = BridgeState::new();
        let ctx = get_security_context(&state).unwrap();
        assert!(ctx.certificate.is_empty());
        assert!(ctx.private_key.is_empty());
        assert!(ctx.certificate_hash.is_empty());
        assert!(ctx.public_key.is_empty());
    }

    #[test]
    fn get_security_context_after_init() {
        let state = Mutex::new(BridgeState::new());
        init_with_persisted_identity(&state, "A".to_string(), DeviceType::Mobile, "").unwrap();
        let s = state.lock().unwrap();
        let ctx = get_security_context(&s).unwrap();
        assert!(!ctx.certificate.is_empty());
        assert!(!ctx.public_key.is_empty());
        assert_eq!(ctx.certificate_hash, s.fingerprint);
    }

    // ── 取消令牌测试 ──

    #[test]
    fn create_cancel_token_returns_unique_ids() {
        let state = Mutex::new(BridgeState::new());
        let id1 = create_cancel_token(&state);
        let id2 = create_cancel_token(&state);
        assert_ne!(id1, id2);
        let s = state.lock().unwrap();
        assert!(s.cancel_tokens.contains_key(&id1));
        assert!(s.cancel_tokens.contains_key(&id2));
    }

    #[test]
    fn cancel_hash_existing_token() {
        let mut bs = BridgeState::new();
        let cancel = tokio_util::sync::CancellationToken::new();
        bs.cancel_tokens
            .insert("hash-1".to_string(), cancel.clone());
        let state = Mutex::new(bs);

        let result = cancel_hash(&state.lock().unwrap(), "hash-1");
        assert!(result.is_ok());
        assert!(cancel.is_cancelled());
    }

    #[test]
    fn cancel_hash_nonexistent_token() {
        let state = BridgeState::new();
        let result = cancel_hash(&state, "nonexistent");
        assert!(result.is_err());
    }

    // ── 网络信息测试 ──

    #[test]
    fn get_local_addresses_no_server_empty() {
        let state = BridgeState::new();
        assert!(get_local_addresses(&state).is_empty());
    }

    #[test]
    fn get_network_interfaces_returns_only_ipv4_non_loopback() {
        let interfaces = get_network_interfaces();
        for iface in &interfaces {
            assert!(!iface.ip.starts_with("127."), "不应包含回环地址");
            assert!(!iface.ip.contains(':'), "不应包含 IPv6 地址");
            assert!(!iface.name.is_empty());
        }
    }

    #[test]
    fn current_protocol_https_default() {
        let state = BridgeState::new();
        assert_eq!(current_protocol(&state), ProtocolType::Https);
    }

    #[test]
    fn current_protocol_http_when_disabled() {
        let mut state = BridgeState::new();
        state.use_https = false;
        assert_eq!(current_protocol(&state), ProtocolType::Http);
    }

    // ── 日志测试 ──

    #[test]
    fn drain_rust_log_buf_empty() {
        assert!(drain_rust_log_buf().is_empty());
    }

    #[test]
    fn log_entry_carries_level_prefix() {
        assert_eq!(format_log_entry(log::Level::Error, "boom"), "error|boom");
        assert_eq!(format_log_entry(log::Level::Warn, "careful"), "warn|careful");
        assert_eq!(format_log_entry(log::Level::Info, "ok"), "info|ok");
        assert_eq!(format_log_entry(log::Level::Debug, "detail"), "debug|detail");
        assert_eq!(format_log_entry(log::Level::Trace, "bye"), "trace|bye");
    }

    #[test]
    fn strip_level_prefix_removes_token() {
        assert_eq!(strip_level_prefix("info|hello"), "hello");
        assert_eq!(strip_level_prefix("error|shutting down connection"), "shutting down connection");
        // 无分隔符时原样返回（兼容旧格式）
        assert_eq!(strip_level_prefix("hello"), "hello");
    }

    // ── 文件名测试 ──

    #[test]
    fn sanitize_file_name_removes_invalid_chars() {
        // Linux 平台上 '/' 是唯一强制非法字符（其余按平台规则替换）
        let result = sanitize_file_name("a/b.txt".to_string());
        assert!(!result.contains('/'));
        assert!(!result.is_empty());
    }

    #[test]
    fn sanitize_file_name_keeps_valid_name() {
        let name = "report 2026.pdf".to_string();
        assert_eq!(sanitize_file_name(name), "report 2026.pdf");
    }

    // ── Web i18n 测试 ──

    #[test]
    fn build_web_i18n_has_all_fields() {
        let i18n = build_web_i18n();
        assert!(!i18n.waiting.is_empty());
        assert!(!i18n.enter_pin.is_empty());
        assert!(!i18n.invalid_pin.is_empty());
        assert!(!i18n.rejected.is_empty());
        assert!(!i18n.upload_rejected.is_empty());
        assert!(!i18n.files.is_empty());
        assert!(!i18n.file_name.is_empty());
        assert!(!i18n.size.is_empty());
        assert!(!i18n.download.is_empty());
        assert!(!i18n.upload.is_empty());
        assert!(!i18n.cancel.is_empty());
        assert!(!i18n.confirm.is_empty());
    }
}
