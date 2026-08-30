//! HarmonyOS 的 LocalSend NAPI 桥接——napi-rs 入口点。
//!
//! 所有函数均通过 `#[napi]` 宏注册，自动
//! 生成 `napi_register_module_v1` 和 `napi_define_properties` 条目。
//!
//! 桥接层通过以下方式包装上游 [`localsend`] 协议实现：
//! 门面层，确保 NAPI 层绝不直接导入上游
//! 内部类型。
//!
//! ## Feature flags
//!
//! - `napi`（默认启用）：编译 NAPI 入口点和桥接层有状态逻辑，
//!   依赖 `napi-ohos`，仅能在 OHOS 交叉编译目标上编译。
//!   关闭此 feature（`--no-default-features`）时仅编译 `convert` 纯逻辑模块，
//!   可在 Linux native target 上运行 `cargo test`。

mod bridge;

pub use bridge::convert;

#[cfg(feature = "napi")]
use bridge::facade;

#[cfg(feature = "napi")]
use bridge::state::bridge as bridge_state;

#[cfg(feature = "napi")]
use localsend::model::discovery::PROTOCOL_VERSION_V2;

#[cfg(feature = "napi")]
use napi_derive_ohos::napi;

#[cfg(feature = "napi")]
use napi_ohos::bindgen_prelude::*;

#[cfg(feature = "napi")]
use napi_ohos::threadsafe_function::ThreadsafeFunction;

#[cfg(feature = "napi")]
include!("napi_entry.rs");
