//! 独立 hyper 服务（路由装配点，仿 `mta::server::run_server` 模式）。
//!
//! C1-1 只占位：路由与会话逻辑在 C1-2（caps）/C1-3（单页空壳）
//! 起逐个装配；本文件先定服务配置形状，保证模块顺利编译。

/// 自研 web 服务配置（与上游 `WebConfig` 解耦，不再复用它）。
#[derive(Clone, Debug, Default)]
pub struct WebServiceConfig {
    /// 自有监听端口（与 LocalSend 服务端口独立，重启互不影响）。
    pub port: u16,
    /// 是否使用自签证书 HTTPS（跟随全局加密开关，不另起证书）。
    pub use_https: bool,
}
