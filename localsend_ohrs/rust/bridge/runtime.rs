//! LocalSend NAPI 桥接层的 tokio 运行时管理。
//!
//! HarmonyOS NAPI 调用属于 FFI；我们需要运行时句柄来调度异步任务。

use crate::bridge::state::bridge;

/// 确保 tokio 运行时存在。由 `napi_start` 调用一次。
/// 运行时由 `facade::init()` 初始化，而非此处。
pub fn ensure_runtime() -> anyhow::Result<()> {
    let state = bridge().lock().unwrap();
    if state.runtime.is_some() {
        return Ok(());
    }
    drop(state);
    Err(anyhow::anyhow!("Runtime not initialized; call facade::init() first"))
}

/// 在桥接层的 tokio 运行时上执行 future，阻塞调用线程。
///
/// 若运行时尚未初始化则会 panic。
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

/// 在桥接层的 tokio 运行时上派生 future，不阻塞调用线程。
///
/// 若运行时尚未初始化则会 panic。
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
