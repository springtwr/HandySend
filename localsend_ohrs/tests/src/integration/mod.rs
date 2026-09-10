#![cfg(test)]

//! HandySend 桥接集成测试——通过 event_tx/event_rx 直接消费事件流，
//! 验证桥接层事件管道通畅。无 mock、无轮询。

mod client_flow;
mod config_matrix;
mod discovery_flow;
mod mta_flow;
mod server_flow;

// NAPI 封装完整性校验（跨平台 guard，替代已删除的 scripts/napi-bridge-guard.sh）
mod napi_guard;
