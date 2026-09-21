//! 桥接层——将 LocalSend 协议能力暴露为强类型 API。
//!
//! 按业务域组织：
//! - `event`：强类型事件与错误定义（BridgeEvent / BridgeError）
//! - `state`：BridgeState 纯数据状态
//! - `engine`：StateAction + apply_actions 纯函数状态变更
//! - `identity`：本机身份 / 安全上下文 / 通用工具
//! - `server`：服务器生命周期 + 传输决策
//! - `web_share`：Web 分享 / 网页上传（分享链接、下载决策、fd 内容源）
//! - `client`：发送 / 接收 / 取消 / 注册
//! - `discovery`：发现生命周期 + 扫描 + 设备查询
//! - `mta`：MTA 互传（BLE 发现、P2P 连接、ZIP 流式收发）
//! - `adapter`：上游类型隔离（ServerEventV2 / MulticastEvent / ClientError 等）
//!
//! 设计约束：
//! - 桥接层不持有 tokio Runtime，runtime 由 NAPI 层 NapiEnv 管理
//! - 事件通过 `state.event_tx`（mpsc::Sender<BridgeEvent>）输出
//! - 上游类型只出现在 adapter 模块中
//! - 事件处理拆为 adapter 适配 + engine 状态变更纯函数

pub mod adapter;
pub mod client;
pub mod config;
pub mod discovery;
pub mod engine;
pub mod event;
pub mod identity;
pub mod mta;
pub mod server;
pub mod state;
pub mod throttle;
pub mod web_share;

pub use event::{BridgeError, BridgeEvent, SessionEndReason};

use std::sync::{Mutex, MutexGuard};

/// 获取互斥锁（锁中毒时恢复内部数据）。
///
/// 任一线程持锁 panic 会让全局 Mutex 中毒，此后所有 `lock().unwrap()`
/// 都会级联 panic 并使 NAPI 调用崩溃；中毒时取出内部数据继续运行，
/// 避免单点 panic 扩散为应用崩溃。
pub fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}
