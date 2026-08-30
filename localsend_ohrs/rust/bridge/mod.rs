//! 桥接层——将 LocalSend 协议能力暴露为强类型 API。
//!
//! 按业务域组织：
//! - `event`：强类型事件与错误定义（BridgeEvent / BridgeError）
//! - `state`：BridgeState 纯数据状态
//! - `engine`：StateAction + apply_actions 纯函数状态变更
//! - `identity`：本机身份 / 安全上下文 / 通用工具
//! - `server`：服务器生命周期 + 传输决策 + WebSend
//! - `client`：发送 / 接收 / 取消 / 注册
//! - `discovery`：发现生命周期 + 扫描 + 设备查询
//! - `adapter`：上游类型隔离（ServerEventV2 / MulticastEvent / ClientError 等）
//!
//! 设计约束：
//! - 桥接层不持有 tokio Runtime，runtime 由 NAPI 层 NapiEnv 管理（FR-004）
//! - 事件通过 `state.event_tx`（mpsc::Sender<BridgeEvent>）输出（FR-001/FR-006）
//! - 上游类型只出现在 adapter 模块中（FR-002）
//! - 事件处理拆为 adapter 适配 + engine 状态变更纯函数（FR-003）

pub mod adapter;
pub mod client;
pub mod discovery;
pub mod engine;
pub mod event;
pub mod identity;
pub mod server;
pub mod state;

pub use event::{BridgeError, BridgeEvent, SessionEndReason};
pub use state::{BridgeState, PendingFile, PendingRequest};
