//! 能力快照纯类型（`GET /caps` 响应体）。
//!
//! 查询本身零副作用：只读当前分享状态，绝不创建待确认会话
//! （旧下载页进页即 `POST prepare-download` 建挂起会话是被替代的根因）。

use serde::{Deserialize, Serialize};

/// 网页服务状态（给浏览器展示，不暴露内部实现）。
#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ShareState {
    /// 服务未运行（地址不可用，浏览器提示找发送方重开）。
    #[default]
    Stopped,
    /// 运行中（按 `has_download`/`upload_enabled` 条件渲染两段）。
    Active,
}

/// `GET /caps` 响应体（字段名即与单页/ArkTS 的对齐契约）。
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CapsSnapshot {
    /// 是否挂了可下载文件（决定下载段显隐）。
    pub has_download: bool,
    /// 当前文件表版本（换表单调增；旧 token 读旧快照）。
    pub file_revision: u64,
    /// 浏览器上传入口是否开放（决定上传段显隐）。
    pub upload_enabled: bool,
    /// 服务状态（`stopped` 时单页只给“分享已结束”）。
    pub share_state: ShareState,
    /// 是否提示自签证书风险（服务端按 HTTPS 与否填写）。
    pub https_hint: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_caps_snapshot_serde_roundtrip() {
        let caps = CapsSnapshot {
            has_download: true,
            file_revision: 7,
            upload_enabled: true,
            share_state: ShareState::Active,
            https_hint: false,
        };
        let json = serde_json::to_string(&caps).unwrap();
        assert!(json.contains("\"hasDownload\":true"));
        assert!(json.contains("\"fileRevision\":7"));
        assert_eq!(serde_json::from_str::<CapsSnapshot>(&json).unwrap(), caps);
    }

    #[test]
    fn test_stopped_state_serializes_lowercase() {
        let caps = CapsSnapshot {
            share_state: ShareState::Stopped,
            ..Default::default()
        };
        let json = serde_json::to_string(&caps).unwrap();
        assert!(json.contains("\"shareState\":\"stopped\""));
    }
}
