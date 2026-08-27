//! ThreadsafeFunction 回调，用于将事件从 Rust Tokio 传递给 ArkTS。
//!
//! 使用 napi-rs 的 ThreadsafeFunction 从 Rust 后台线程调用 JavaScript，
//! 这是 NAPI 环境下的推荐方式。

use std::sync::Arc;

use napi_ohos::threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode};

/// 对 napi_ohos::ThreadsafeFunction 的封装，用于事件发射。
///
/// 回调由 ArkTS 调用 `registerEventListener` 注册一次，
/// 随后由 Rust 桥接层用于从 Tokio 线程推送事件。
#[derive(Clone)]
pub struct EventCallback {
    inner: Option<Arc<ThreadsafeFunction<String>>>,
}

impl EventCallback {
    /// 创建一个包装 ThreadsafeFunction 的新回调。
    pub fn new(tsfn: ThreadsafeFunction<String>) -> Self {
        Self {
            inner: Some(Arc::new(tsfn)),
        }
    }

    /// 使用 JSON 负载调用回调。
    ///
    /// 可从任意线程安全调用（Tokio worker 等）。
    /// ThreadsafeFunction 会将调用投递到 ArkTS 主线程。
    pub fn call(&self, json_payload: String) {
        if let Some(ref tsfn) = self.inner {
            let tsfn = Arc::clone(tsfn);
            // ThreadsafeFunction.call() 可从任意线程安全调用。
            // ArkTS 中的回调接收单个字符串参数（JSON）。
            let status = tsfn.call(Ok(json_payload), ThreadsafeFunctionCallMode::NonBlocking);
            // ThreadsafeFunction.call() 返回 napi_ohos::Status。
            // 队列已满或…时，NonBlocking 模式可能返回 GenericFailure
            // ArkTS 事件循环已关闭。记录错误用于诊断。
            if status != napi_ohos::Status::Ok {
                log::warn!("EventCallback: non-ok status={:?}", status);
            }
        }
    }
}
