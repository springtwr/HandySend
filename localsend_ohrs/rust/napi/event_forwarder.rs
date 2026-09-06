//! 事件转发——从事件流消费 BridgeEvent，通过 napi_threadsafe_function
//! 按事件类型分发到 ArkTS 主线程。
//!
//! 事件序列化为 `{"type":"...","payload":{...}}` JSON 字符串，
//! ArkTS 侧 NativeBridge 解析 type 后分发给对应订阅者。

use std::sync::Arc;

use napi_ohos::threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode};

use crate::bridge::event::BridgeEvent;

/// 启动事件转发任务：消费 NapiEnv 中的 event_rx，逐事件序列化并通过
/// tsfn 投递到 ArkTS 主线程。
///
/// 必须在 init（设置 event_rx 后）调用一次。
pub fn start_event_forwarder(tsfn: ThreadsafeFunction<String>) {
    let env = crate::napi::env::NapiEnv::global();
    let rx = env.event_rx.lock().unwrap().take();
    let Some(mut rx) = rx else {
        log::warn!("事件流接收端未设置——init 未调用或 forwarder 已启动");
        return;
    };

    // ThreadsafeFunction 不可 Clone，用 Arc 共享
    let tsfn = Arc::new(tsfn);

    env.runtime.spawn(async move {
        while let Some(event) = rx.recv().await {
            let json = serde_json::to_string(&event).unwrap_or_default();
            let tsfn = Arc::clone(&tsfn);
            let status = tsfn.call(Ok(json), ThreadsafeFunctionCallMode::NonBlocking);
            if status != napi_ohos::Status::Ok {
                log::warn!("事件转发失败: status={:?}", status);
            }
        }
        log::debug!("事件转发任务结束");
    });
}

/// 将 BridgeEvent 序列化为 JSON 字符串（供调试/测试）。
pub fn event_to_json(event: &BridgeEvent) -> String {
    serde_json::to_string(event).unwrap_or_else(|_| "{}".to_string())
}
