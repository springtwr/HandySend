//! 事件回调抽象——将事件从 Rust Tokio 传递给 ArkTS 或测试收集器。
//!
//! 定义 `EventCallbackTrait` trait，提供两种实现：
//! - `NapiEventCallback`：生产实现，包装 napi-ohos 的 ThreadsafeFunction（仅 napi feature 下可用）
//! - `MockEventCallback`：测试实现，用 Arc<Mutex<Vec<String>>> 收集调用日志
//!
//! 注意：在 `--no-default-features` 模式下，`EventCallbackTrait` 和
//! `MockEventCallback` 会报 "never used" 警告——这是设计预期，
//! 因为调用方在 `#[cfg(feature = "napi")]` 门控的 facade 模块中。

#![allow(dead_code)]

use std::sync::{Arc, Mutex};

// ── 事件回调 trait ──────────────────────────────────────────────────────

/// 事件回调抽象，用于将 JSON 事件从 Rust 桥接层推送给消费者。
///
/// 生产环境下由 `NapiEventCallback` 实现（通过 ThreadsafeFunction
/// 投递到 ArkTS 主线程）；测试环境下由 `MockEventCallback` 实现
/// （收集调用日志供断言）。
pub trait EventCallbackTrait: Send + Sync {
    /// 使用 JSON 负载调用回调。
    fn call(&self, json_payload: String);
}

// ── NAPI 生产实现 ──────────────────────────────────────────────────────

/// 对 napi_ohos::ThreadsafeFunction 的封装，用于事件发射。
///
/// 回调由 ArkTS 调用 `registerEventListener` 注册一次，
/// 随后由 Rust 桥接层用于从 Tokio 线程推送事件。
#[cfg(feature = "napi")]
#[derive(Clone)]
pub struct NapiEventCallback {
    inner: Option<Arc<napi_ohos::threadsafe_function::ThreadsafeFunction<String>>>,
}

#[cfg(feature = "napi")]
impl NapiEventCallback {
    /// 创建一个包装 ThreadsafeFunction 的新回调。
    pub fn new(tsfn: napi_ohos::threadsafe_function::ThreadsafeFunction<String>) -> Self {
        Self {
            inner: Some(Arc::new(tsfn)),
        }
    }
}

#[cfg(feature = "napi")]
impl EventCallbackTrait for NapiEventCallback {
    /// 使用 JSON 负载调用回调。
    ///
    /// 可从任意线程安全调用（Tokio worker 等）。
    /// ThreadsafeFunction 会将调用投递到 ArkTS 主线程。
    fn call(&self, json_payload: String) {
        use napi_ohos::threadsafe_function::ThreadsafeFunctionCallMode;

        if let Some(ref tsfn) = self.inner {
            let tsfn = Arc::clone(tsfn);
            let status = tsfn.call(Ok(json_payload), ThreadsafeFunctionCallMode::NonBlocking);
            if status != napi_ohos::Status::Ok {
                log::warn!("NapiEventCallback: non-ok status={:?}", status);
            }
        }
    }
}

/// 生产环境回调类型别名——保持向后兼容。
#[cfg(feature = "napi")]
pub type EventCallback = NapiEventCallback;

// ── Mock 测试实现 ──────────────────────────────────────────────────────

/// 测试用 mock 回调，收集所有调用记录供断言。
///
/// 使用 `Arc<Mutex<Vec<String>>>` 线程安全地收集 JSON 负载，
/// `take_calls()` 方法取出并清空已收集的记录。
pub struct MockEventCallback {
    log: Arc<Mutex<Vec<String>>>,
}

impl MockEventCallback {
    /// 创建一个空的 mock 回调。
    pub fn new() -> Self {
        Self {
            log: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// 取出所有已收集的调用记录（drain），后续调用将返回空。
    pub fn take_calls(&self) -> Vec<String> {
        let mut log = self.log.lock().unwrap();
        log.drain(..).collect()
    }
}

impl EventCallbackTrait for MockEventCallback {
    fn call(&self, json_payload: String) {
        let mut log = self.log.lock().unwrap();
        log.push(json_payload);
    }
}

impl Default for MockEventCallback {
    fn default() -> Self {
        Self::new()
    }
}

// ── 单元测试 ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mock_event_callback_collects_calls() {
        let mock = MockEventCallback::new();
        mock.call(r#"{"type":"a"}"#.to_string());
        mock.call(r#"{"type":"b"}"#.to_string());
        mock.call(r#"{"type":"c"}"#.to_string());

        let calls = mock.take_calls();
        assert_eq!(calls.len(), 3);
        assert_eq!(calls[0], r#"{"type":"a"}"#);
        assert_eq!(calls[1], r#"{"type":"b"}"#);
        assert_eq!(calls[2], r#"{"type":"c"}"#);
    }

    #[test]
    fn test_mock_event_callback_take_drains() {
        let mock = MockEventCallback::new();
        mock.call(r#"{"type":"a"}"#.to_string());

        let first = mock.take_calls();
        assert_eq!(first.len(), 1);

        let second = mock.take_calls();
        assert!(second.is_empty(), "take_calls() 应清空已收集的记录");
    }

    #[test]
    fn test_napi_event_callback_implements_trait() {
        // 编译期检查：NapiEventCallback 实现了 EventCallbackTrait
        fn assert_impl<T: EventCallbackTrait>() {}
        #[cfg(feature = "napi")]
        assert_impl::<NapiEventCallback>();

        // MockEventCallback 也实现了 trait
        assert_impl::<MockEventCallback>();
    }
}
