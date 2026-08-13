//! ThreadsafeFunction callback for passing events from Rust Tokio to ArkTS.
//!
//! Replaces the old C function pointer approach with napi-rs ThreadsafeFunction,
//! which is the correct way to call JavaScript from Rust background threads
//! in the NAPI environment.

use std::sync::Arc;

use napi_ohos::threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode};

/// Wrapper around napi_ohos::ThreadsafeFunction for event emission.
///
/// The callback is registered once by ArkTS calling `registerEventListener`,
/// and then used by the Rust bridge to push events from Tokio threads.
#[derive(Clone)]
pub struct EventCallback {
    inner: Option<Arc<ThreadsafeFunction<String>>>,
}

impl EventCallback {
    /// Create a new callback wrapping a ThreadsafeFunction.
    pub fn new(tsfn: ThreadsafeFunction<String>) -> Self {
        Self {
            inner: Some(Arc::new(tsfn)),
        }
    }

    /// Create an empty callback (no-op).
    pub fn empty() -> Self {
        Self { inner: None }
    }

    /// Call the callback with a JSON payload.
    ///
    /// This is safe to call from any thread (Tokio worker, etc.).
    /// The ThreadsafeFunction will marshal the call to the ArkTS main thread.
    pub fn call(&self, json_payload: String) {
        if let Some(ref tsfn) = self.inner {
            let tsfn = Arc::clone(tsfn);
            // ThreadsafeFunction.call() is safe from any thread.
            // The callback in ArkTS receives a single string arg (JSON).
            let status = tsfn.call(Ok(json_payload), ThreadsafeFunctionCallMode::NonBlocking);
            // ThreadsafeFunction.call() returns napi_ohos::Status.
            // NonBlocking mode may return GenericFailure if the queue is full or the
            // ArkTS event loop is torn down. Log errors for diagnostics.
            if status != napi_ohos::Status::Ok {
                log::warn!("EventCallback: non-ok status={:?}", status);
            }
        }
    }
}
