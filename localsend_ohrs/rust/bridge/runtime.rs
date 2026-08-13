//! Tokio runtime management for the LocalSend NAPI bridge.
//!
//! HarmonyOS NAPI calls are FFI; we need a runtime handle to dispatch async work.

use crate::bridge::state::bridge;

/// Ensure the tokio runtime exists. Called once by `napi_start`.
/// Runtime is initialized by `facade::init()`, not here.
pub fn ensure_runtime() -> anyhow::Result<()> {
    let state = bridge().lock().unwrap();
    if state.runtime.is_some() {
        return Ok(());
    }
    drop(state);
    Err(anyhow::anyhow!("Runtime not initialized; call facade::init() first"))
}

/// Run a future on the bridge's tokio runtime, blocking the calling thread.
///
/// Panics if the runtime has not been initialised.
pub fn block_on<F>(future: F) -> F::Output
where
    F: std::future::Future + Send + 'static,
    F::Output: Send + 'static,
{
    let state = bridge().lock().unwrap();
    let rt = state
        .runtime
        .as_ref()
        .expect("Runtime not initialised; call napi_start first")
        .handle()
        .clone();
    drop(state);
    rt.block_on(future)
}

/// Spawn a future onto the bridge's tokio runtime without blocking.
///
/// Panics if the runtime has not been initialised.
pub fn spawn<F>(future: F)
where
    F: std::future::Future + Send + 'static,
    F::Output: Send + 'static,
{
    let state = bridge().lock().unwrap();
    let rt = state
        .runtime
        .as_ref()
        .expect("Runtime not initialised; call napi_start first")
        .handle()
        .clone();
    drop(state);
    rt.spawn(future);
}
