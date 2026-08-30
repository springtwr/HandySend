#![cfg(test)]

//! HandySend 桥接集成测试——基于真实 HTTP 服务器验证 LocalSend 协议核心行为。
//!
//! 与上游 `packages/core/tests/` 的区别：
//! - 上游测试在 `third_party/localsend/` 下运行，测试 localsend crate 本身
//! - 本测试在 `localsend_ohrs/tests/` 下运行，验证 HandySend 桥接层使用的协议场景
//! - Phase C 后将扩展为同时覆盖桥接层纯逻辑函数

mod server_test;
mod client_test;
mod discovery_test;
