//! 自研 Web 服务（与 LocalSend/MTA 同级）。
//!
//! 浏览器面：单页、无副作用能力查询、按浏览器 UUID 的 token 会话、
//! 文件表版本隔离。设备对设备 v2 协议不受影响。
//!
//! 子模块：
//! - `caps`：能力快照纯类型（`GET /caps` 的响应体，零副作用）
//! - `i18n`：浏览器单页文案（三语，`GET /i18n.json` 下发）
//! - `session`：下载 token 会话与共享文件表（建会话=出示清单）
//! - `upload`：上传 token 会话（每客户端独立槽，不吃 v2 全局单槽）
//! - `server`：独立 hyper 服务（路由装配，仿 `mta::server` 模式）
//! - `runtime`：服务运行时归属与 NAPI 薄封装的桥接（启停/事件转发）

pub mod caps;
pub mod i18n;
pub mod runtime;
pub mod server;
pub mod session;
pub mod upload;
pub mod zip_plan;
