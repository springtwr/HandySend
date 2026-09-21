//! 适配器模块——隔离所有上游 localsend 类型。
//!
//! 按事件源组织文件：
//! - `server.rs`：ServerEventV2 / WebSendEvent / InternalEvent → 桥接层事件
//! - `multicast.rs`：DiscoveryEvent → 桥接层事件
//! - `client.rs`：ClientError → BridgeError + 客户端请求构造
//! - `types.rs`：DTO 定义 + 上游↔DTO 转换
//!
//! 上游类型变更时只需修改对应文件，编译器通过 match 穷尽检查引导适配。

pub mod client;
pub mod multicast;
pub mod server;
pub mod types;
