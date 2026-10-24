//! Token 会话纯类型（一浏览器一 token 一会话）。
//!
//! 替代旧按 IP 单槽：多标签/多浏览器不再互踢；会话创建即登记
//! 建会话时的文件表版本（`file_revision`），换表只影响新会话。

use std::collections::HashMap;

/// 一次下载出示的文件条目快照（建会话时冻结，不跟随换表）。
#[derive(Clone, Debug)]
pub struct OfferedFile {
    /// 对外文件标识（换表时按路径复用，见 ArkTS 侧同名逻辑）。
    pub file_id: String,
    /// 建会话时冻结的文件表版本。
    pub file_revision: u64,
}

/// Token 会话（运行态由服务持有，此处只定形状）。
#[derive(Clone, Debug)]
pub struct TokenSession {
    /// 浏览器 UUID（首访服务端下发，`sessionStorage` 复用）。
    pub token: String,
    /// 归属分享标识（`shareId` 外键，一分享多任务）。
    pub share_id: String,
    /// 建会话时出示的文件快照。
    pub offered_files: HashMap<String, OfferedFile>,
}
