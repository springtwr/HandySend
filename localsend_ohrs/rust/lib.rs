//! HarmonyOS 的 LocalSend NAPI 桥接——crate 入口。
//!
//! 桥接层通过 `bridge` 模块对外提供强类型 API：
//! - `--no-default-features`：仅编译桥接层纯逻辑（可在 Linux native target 上
//!   运行 `cargo test`）
//! - `napi`（默认）：额外编译 NAPI 适配层（`napi` 模块），依赖 `napi-ohos`，
//!   仅在 OHOS 交叉编译目标上可用
//!
//! 架构（桥接层架构重构，见 spec/bridge-redesign/）：
//! - runtime 归 NAPI 层 NapiEnv 管理，桥接层不持有 runtime
//! - 事件通过 mpsc channel 以强类型 BridgeEvent 输出
//! - 上游类型隔离在 `bridge::adapter` 模块

pub mod bridge;

#[cfg(feature = "napi")]
pub mod napi;
