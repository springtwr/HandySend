//! 桥接核心逻辑——从 facade 函数中提取的可测试核心函数。
//!
//! 本模块始终编译（不受 `napi` feature 控制），提供直接操作
//! `BridgeState` 的核心逻辑函数，可在无 NAPI 环境下进行单元测试。
//!
//! NAPI facade 中的公开函数变为薄包装层，通过全局单例 `bridge()`
//! 调用本模块的核心函数。
//!
//! 注意：在 `--no-default-features` 模式下，本模块的公开函数会
//! 报 "never used" 警告——这是设计预期，因为调用方在
//! `#[cfg(feature = "napi")]` 门控的 facade 模块中。

#![allow(dead_code)]

use std::sync::Mutex;

use anyhow::Result;
use serde_json::json;

use localsend::crypto;
use localsend::http::server::v2::PrepareUploadDecisionV2;

use crate::bridge::convert;
use crate::bridge::state::BridgeState;

// ── 发现核心逻辑 ──────────────────────────────────────────────────────

/// 停止发现的核心逻辑——取消事件任务、发送停止信号、清除句柄。
pub fn do_stop_discovery(state: &Mutex<BridgeState>) {
    let mut state = state.lock().unwrap();
    if let Some(event_task) = state.discovery_event_task.take() {
        event_task.abort();
    }
    if let Some(stop_tx) = state.discovery_stop_tx.take() {
        let _ = stop_tx.send(());
    }
    state.discovery_handle.take();
}

/// 按指纹获取设备 JSON。
pub fn do_get_device(state: &BridgeState, fingerprint: &str) -> String {
    match state.discovery_handle.as_ref() {
        Some(h) => match h.device_by_fingerprint(fingerprint) {
            Some(d) => convert::device_to_json(&d).to_string(),
            None => "null".to_string(),
        },
        None => "null".to_string(),
    }
}

/// 获取组播错误字符串。
pub fn do_multicast_error(state: &BridgeState) -> String {
    match state.discovery_handle.as_ref() {
        Some(h) => match h.multicast_error() {
            Some(e) => format!("{e:#}"),
            None => String::new(),
        },
        None => String::new(),
    }
}

// ── 服务器核心逻辑 ────────────────────────────────────────────────────

/// 接受传输——从待处理决策中取出 oneshot 并发送 Accept 决策。
pub fn do_accept_transfer(
    state: &Mutex<BridgeState>,
    session_id: &str,
    file_ids: &[String],
) -> Result<()> {
    let mut state = state.lock().unwrap();
    if let Some(sender) = state.pending_decisions.remove(session_id) {
        let file_set: std::collections::HashSet<String> = file_ids.iter().cloned().collect();
        let decision = PrepareUploadDecisionV2::Accept(file_set);
        let _ = sender.send(decision);

        let mut reqs = state.pending_requests.lock().unwrap();
        reqs.retain(|r| r.session_id != session_id);

        Ok(())
    } else {
        Err(anyhow::anyhow!(
            "No pending decision for session: {}",
            session_id
        ))
    }
}

/// 拒绝传输——从待处理决策中取出 oneshot 并发送 Decline 决策。
pub fn do_decline_transfer(state: &Mutex<BridgeState>, session_id: &str) -> Result<()> {
    let mut state = state.lock().unwrap();
    if let Some(sender) = state.pending_decisions.remove(session_id) {
        let decision = PrepareUploadDecisionV2::Decline;
        let _ = sender.send(decision);

        let mut reqs = state.pending_requests.lock().unwrap();
        reqs.retain(|r| r.session_id != session_id);

        Ok(())
    } else {
        Err(anyhow::anyhow!(
            "No pending decision for session: {}",
            session_id
        ))
    }
}

/// 停止服务器——发送停止信号、清除句柄和所有状态。
pub fn do_stop_server(state: &Mutex<BridgeState>) {
    let mut state = state.lock().unwrap();
    if let Some(stop_tx) = state.server_stop_tx.take() {
        let _ = stop_tx.send(());
    }
    state.server_handle.take();
    state.event_tx.take();
    state.show_token.take();
    for (_key, cancel) in state.active_transfers.drain() {
        cancel.cancel();
    }
    state.pending_requests.lock().unwrap().clear();
    state.pending_decisions.clear();
    state.web_send_event_tx.take();
    state.web_send_files.lock().unwrap().clear();
    state.web_download_decisions.clear();
    state.pending_file_uploads.clear();
    state.pending_file_downloads.clear();
    state.session_peers.clear();
}

/// 获取服务器状态 JSON。
pub fn do_get_server_status(state: &BridgeState) -> String {
    let running = state.server_handle.is_some();
    let fingerprint = state.fingerprint.clone();
    let active_session = {
        let reqs = state.pending_requests.lock().unwrap();
        reqs.first().map(|r| r.session_id.clone())
    };

    json!({
        "running": running,
        "activeSession": active_session,
        "fingerprint": fingerprint,
    })
    .to_string()
}

/// 获取当前发送会话 ID。
pub fn do_get_current_send_session_id(state: &BridgeState) -> String {
    let sid = state.current_send_session_id.lock().unwrap();
    sid.clone()
}

/// 轮询待处理请求。
pub fn do_poll_pending_requests(state: &BridgeState) -> Vec<crate::bridge::state::PendingRequest> {
    let reqs = state.pending_requests.lock().unwrap();
    reqs.clone()
}

// ── 客户端核心逻辑 ────────────────────────────────────────────────────

/// 取消传输——触发指定会话的 CancellationToken。
pub fn do_cancel_transfer(state: &BridgeState, session_id: &str) {
    if let Some(cancel) = state.active_transfers.get(session_id) {
        cancel.cancel();
    }
}

// ── 公共门面核心逻辑 ──────────────────────────────────────────────────

/// 取消哈希操作。
pub fn do_cancel_hash(state: &BridgeState, cancel_id: &str) -> Result<()> {
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

/// 创建取消令牌，返回唯一 ID。
pub fn do_create_cancel_token(state: &Mutex<BridgeState>) -> String {
    // 使用时间戳 + 计数器生成唯一 ID，避免对 uuid crate 的编译期依赖
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

/// 获取安全上下文。
pub fn do_get_security_context(state: &BridgeState) -> Result<SecurityContextDto> {
    let cert_pem = state.cert_pem.clone();
    let key_pem = state.key_pem.clone();
    let fingerprint = state.fingerprint.clone();
    let public_key = convert::public_key_from_cert_pem(&cert_pem);
    Ok(SecurityContextDto {
        private_key: key_pem,
        public_key,
        certificate: cert_pem,
        certificate_hash: fingerprint,
    })
}

/// 重置安全上下文——生成新证书并更新状态。
pub fn do_reset_security_context(state: &Mutex<BridgeState>) -> Result<SecurityContextDto> {
    let cert = crypto::cert::generate_self_signed()?;

    // 先持久化覆盖磁盘文件；写盘失败立即返回 Err，此时内存态与磁盘均保持旧值
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
    }

    Ok(SecurityContextDto {
        private_key: cert.private_key_pem,
        public_key: cert.public_key_pem,
        certificate: cert.certificate_pem,
        certificate_hash: cert.fingerprint,
    })
}

// ── 内部辅助 ──────────────────────────────────────────────────────────

pub struct SecurityContextDto {
    pub private_key: String,
    pub public_key: String,
    pub certificate: String,
    pub certificate_hash: String,
}

const IDENTITY_KEY_FILE: &str = "identity.key";
const IDENTITY_CERT_FILE: &str = "identity.pem";

fn save_persisted_identity(dir: &str, key_pem: &str, cert_pem: &str) -> Result<()> {
    use std::path::Path;
    std::fs::create_dir_all(dir)?;
    let key_path = Path::new(dir).join(IDENTITY_KEY_FILE);
    let cert_path = Path::new(dir).join(IDENTITY_CERT_FILE);
    std::fs::write(&key_path, key_pem)?;
    std::fs::write(&cert_path, cert_pem)?;
    Ok(())
}

#[allow(dead_code)]
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

// ── 单元测试 ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bridge::callback::MockEventCallback;
    use serde_json::Value;
    use std::sync::Arc;

    // ── 发现核心逻辑测试 ──────────────────────────────────────────────

    #[test]
    fn test_stop_discovery_clears_state() {
        let state = Mutex::new(BridgeState::new());
        do_stop_discovery(&state);
        let s = state.lock().unwrap();
        assert!(s.discovery_handle.is_none());
        assert!(s.discovery_stop_tx.is_none());
        assert!(s.discovery_event_task.is_none());
    }

    #[test]
    fn test_get_device_no_handle_returns_null() {
        let state = BridgeState::new();
        assert_eq!(do_get_device(&state, "any-fp"), "null");
    }

    #[test]
    fn test_multicast_error_no_handle_returns_empty() {
        let state = BridgeState::new();
        assert!(do_multicast_error(&state).is_empty());
    }

    #[test]
    fn test_stop_discovery_preserves_callback() {
        let mut bridge_state = BridgeState::new();
        let mock = Arc::new(MockEventCallback::new());
        bridge_state.callback = Some(mock);
        let state = Mutex::new(bridge_state);

        do_stop_discovery(&state);

        let s = state.lock().unwrap();
        assert!(s.callback.is_some());
    }

    // ── 服务器核心逻辑测试 ──────────────────────────────────────────────

    #[test]
    fn test_accept_transfer_no_pending_decision() {
        let state = Mutex::new(BridgeState::new());
        let result = do_accept_transfer(&state, "nonexistent", &[]);
        assert!(result.is_err());
    }

    #[test]
    fn test_decline_transfer_no_pending_decision() {
        let state = Mutex::new(BridgeState::new());
        let result = do_decline_transfer(&state, "nonexistent");
        assert!(result.is_err());
    }

    #[test]
    fn test_accept_transfer_with_pending_decision() {
        let state = Mutex::new(BridgeState::new());
        let (tx, mut rx) = tokio::sync::oneshot::channel();

        {
            let mut s = state.lock().unwrap();
            s.pending_decisions.insert("session-1".to_string(), tx);
        }

        let result = do_accept_transfer(&state, "session-1", &["file-a".to_string()]);
        assert!(result.is_ok());

        // 验证 oneshot 被消费且发送了 Accept 决策
        let decision = rx.try_recv().unwrap();
        match decision {
            PrepareUploadDecisionV2::Accept(ids) => {
                assert!(ids.contains("file-a"));
            }
            PrepareUploadDecisionV2::Decline => panic!("期望 Accept"),
        }
    }

    #[test]
    fn test_decline_transfer_with_pending_decision() {
        let state = Mutex::new(BridgeState::new());
        let (tx, mut rx) = tokio::sync::oneshot::channel();

        {
            let mut s = state.lock().unwrap();
            s.pending_decisions.insert("session-2".to_string(), tx);
        }

        let result = do_decline_transfer(&state, "session-2");
        assert!(result.is_ok());

        let decision = rx.try_recv().unwrap();
        assert!(matches!(decision, PrepareUploadDecisionV2::Decline));
    }

    #[test]
    fn test_stop_server_clears_state() {
        let mut bridge_state = BridgeState::new();
        // 模拟活跃传输
        let cancel = tokio_util::sync::CancellationToken::new();
        bridge_state
            .active_transfers
            .insert("transfer-1".to_string(), cancel.clone());
        let state = Mutex::new(bridge_state);

        do_stop_server(&state);

        let s = state.lock().unwrap();
        assert!(s.server_handle.is_none());
        assert!(s.server_stop_tx.is_none());
        assert!(s.active_transfers.is_empty());
        assert!(s.pending_decisions.is_empty());
        assert!(cancel.is_cancelled(), "活跃传输的取消令牌应被触发");
    }

    #[test]
    fn test_get_server_status_not_running() {
        let state = BridgeState::new();
        let status = do_get_server_status(&state);
        let parsed: Value = serde_json::from_str(&status).unwrap();
        assert!(!parsed["running"].as_bool().unwrap());
    }

    #[test]
    fn test_get_current_send_session_id_default() {
        let state = BridgeState::new();
        let sid = do_get_current_send_session_id(&state);
        assert!(sid.is_empty());
    }

    // ── 客户端核心逻辑测试 ──────────────────────────────────────────────

    #[test]
    fn test_cancel_transfer_existing_session() {
        let mut state = BridgeState::new();
        let cancel = tokio_util::sync::CancellationToken::new();
        state
            .active_transfers
            .insert("session-1".to_string(), cancel.clone());
        do_cancel_transfer(&state, "session-1");
        assert!(cancel.is_cancelled());
    }

    #[test]
    fn test_cancel_transfer_nonexistent_session() {
        let state = BridgeState::new();
        // 不应 panic
        do_cancel_transfer(&state, "nonexistent");
    }

    // ── 公共门面核心逻辑测试 ──────────────────────────────────────────

    #[test]
    fn test_cancel_hash_existing_token() {
        let mut state = BridgeState::new();
        let cancel = tokio_util::sync::CancellationToken::new();
        state
            .cancel_tokens
            .insert("hash-1".to_string(), cancel.clone());
        let result = do_cancel_hash(&state, "hash-1");
        assert!(result.is_ok());
        assert!(cancel.is_cancelled());
    }

    #[test]
    fn test_cancel_hash_nonexistent_token() {
        let state = BridgeState::new();
        let result = do_cancel_hash(&state, "nonexistent");
        assert!(result.is_err());
    }

    #[test]
    fn test_create_cancel_token() {
        let state = Mutex::new(BridgeState::new());
        let id = do_create_cancel_token(&state);
        assert!(!id.is_empty());

        let s = state.lock().unwrap();
        assert!(s.cancel_tokens.contains_key(&id));
    }

    #[test]
    fn test_create_cancel_token_unique_ids() {
        let state = Mutex::new(BridgeState::new());
        let id1 = do_create_cancel_token(&state);
        let id2 = do_create_cancel_token(&state);
        assert_ne!(id1, id2);
    }

    #[test]
    fn test_get_security_context_empty_cert() {
        let state = BridgeState::new();
        let ctx = do_get_security_context(&state).unwrap();
        assert!(ctx.certificate.is_empty());
        assert!(ctx.private_key.is_empty());
        assert!(ctx.certificate_hash.is_empty());
        // 空证书时公钥也为空
        assert!(ctx.public_key.is_empty());
    }

    #[test]
    fn test_reset_security_context_generates_cert() {
        let mut bs = BridgeState::new();
        bs.save_dir = format!("{}/handysend-test/", std::env::temp_dir().display());
        let state = Mutex::new(bs);
        let ctx = do_reset_security_context(&state).unwrap();
        assert!(!ctx.certificate.is_empty());
        assert!(!ctx.private_key.is_empty());
        assert!(!ctx.certificate_hash.is_empty());
        assert!(!ctx.public_key.is_empty());

        // 验证 BridgeState 已更新
        let s = state.lock().unwrap();
        assert_eq!(s.cert_pem, ctx.certificate);
        assert_eq!(s.key_pem, ctx.private_key);
        assert_eq!(s.fingerprint, ctx.certificate_hash);

        // 验证磁盘持久化文件已写入
        let key_path = format!("{}identity.key", s.save_dir);
        let cert_path = format!("{}identity.pem", s.save_dir);
        assert!(
            std::path::Path::new(&key_path).exists(),
            "identity.key 应已持久化"
        );
        assert!(
            std::path::Path::new(&cert_path).exists(),
            "identity.pem 应已持久化"
        );

        // 清理测试文件
        let _ = std::fs::remove_dir_all(&s.save_dir);
    }

    #[test]
    fn test_reset_security_context_updates_fingerprint() {
        let mut bs = BridgeState::new();
        bs.save_dir = format!("{}/handysend-test-fp/", std::env::temp_dir().display());
        let state = Mutex::new(bs);

        let ctx1 = do_reset_security_context(&state).unwrap();
        let ctx2 = do_reset_security_context(&state).unwrap();

        // 两次生成的证书指纹应不同
        assert_ne!(ctx1.certificate_hash, ctx2.certificate_hash);

        // 清理测试文件
        let s = state.lock().unwrap();
        let _ = std::fs::remove_dir_all(&s.save_dir);
    }
}
