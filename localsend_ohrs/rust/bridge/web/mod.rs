//! 自研 Web 服务（与 LocalSend/MTA 同级）。
//!
//! 取代上游 `localsend::http::server::web` 的浏览器面：单页、
//! 无副作用能力查询、按浏览器 UUID 的 token 会话、文件表版本隔离。
//! 设备对设备 v2 协议不受影响；引用上游 `web` 处一律起别名
//! （`as upstream_web`），C5-6 删老链路时归零验证。
//!
//! 子模块：
//! - `caps`：能力快照纯类型（`GET /caps` 的响应体，零副作用）
//! - `session`：token 会话纯类型（建会话=出示清单，不画进度）
//! - `server`：独立 hyper 服务（路由装配，仿 `mta::server` 模式）

pub mod caps;
pub mod server;
pub mod session;
