//! 浏览器单页文案（三语：简体/繁体/英文）。
//!
//! 服务端按启动配置的语言返回其一（`GET /i18n.json`），
//! 单页先拉文案再渲染；拉取失败时页面回退内置简体中文。

use serde::Serialize;

/// 单页文案（camelCase 键，与前端 `t(key)` 对照）。
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WebPageI18n {
    pub loading: String,
    pub stopped_note: String,
    pub download_title: String,
    pub upload_title: String,
    pub no_download_hint: String,
    pub upload_off_hint: String,
    pub start_receive: String,
    pub pick_first: String,
    pub waiting_confirm: String,
    pub rejected: String,
    pub confirm_timeout_retry: String,
    pub share_ended_retry: String,
    pub request_failed_retry: String,
    pub network_error_retry: String,
    pub upload_done: String,
    pub select_first: String,
    pub upload_failed_retry: String,
    pub upload_interrupted: String,
    pub pin_title: String,
    pub pin_confirm: String,
    pub pin_error: String,
    pub download: String,
    pub download_all: String,
    pub download_all_unsupported: String,
    pub upload: String,
    pub send_text: String,
    pub text_placeholder: String,
    pub text_send: String,
    pub preview_loading: String,
    pub preview_unavailable: String,
}

/// 按 BCP47 语言选择文案集（未知回退简体中文）。
pub fn web_page_i18n(locale: &str) -> WebPageI18n {
    let normalized: String = locale.to_lowercase().replace('_', "-");
    if normalized.starts_with("zh-tw") || normalized.starts_with("zh-hant") {
        traditional()
    } else if normalized.starts_with("en") {
        english()
    } else {
        simplified()
    }
}

fn simplified() -> WebPageI18n {
    WebPageI18n {
        loading: "加载中…".to_string(),
        stopped_note: "分享已结束，请让发送方重新开启后刷新本页。".to_string(),
        download_title: "下载".to_string(),
        upload_title: "发送到设备".to_string(),
        no_download_hint: "暂无可下载文件。".to_string(),
        upload_off_hint: "浏览器上传未开启。".to_string(),
        start_receive: "开启接收".to_string(),
        pick_first: "先去选文件".to_string(),
        waiting_confirm: "等待对方确认中…（请让对方打开应用确认）".to_string(),
        rejected: "对方已拒绝请求。".to_string(),
        confirm_timeout_retry: "对方未及时确认，请让对方打开应用后刷新本页重试。".to_string(),
        share_ended_retry: "分享已结束或暂无可下载文件，请刷新重试。".to_string(),
        request_failed_retry: "请求失败，请刷新重试。".to_string(),
        network_error_retry: "网络错误，请检查连接后重试。".to_string(),
        upload_done: "上传完成。".to_string(),
        select_first: "请先选择要发送的文件。".to_string(),
        upload_failed_retry: "上传失败，请重试。".to_string(),
        upload_interrupted: "网络错误，上传中断。".to_string(),
        pin_title: "请输入 PIN".to_string(),
        pin_confirm: "确定".to_string(),
        pin_error: "PIN 错误。".to_string(),
        download: "下载".to_string(),
        download_all: "全部下载".to_string(),
        download_all_unsupported: "当前浏览器不支持自动批量下载，请逐个点击下载。".to_string(),
        upload: "上传".to_string(),
        send_text: "发送文本".to_string(),
        text_placeholder: "输入要发送的文本".to_string(),
        text_send: "发送".to_string(),
        preview_loading: "预览加载中…".to_string(),
        preview_unavailable: "预览不可用。".to_string(),
    }
}

fn traditional() -> WebPageI18n {
    WebPageI18n {
        loading: "載入中…".to_string(),
        stopped_note: "分享已結束，請讓傳送方重新開啟後重新整理本頁。".to_string(),
        download_title: "下載".to_string(),
        upload_title: "傳送到裝置".to_string(),
        no_download_hint: "暫無可下載檔案。".to_string(),
        upload_off_hint: "瀏覽器上傳未開啟。".to_string(),
        start_receive: "開啟接收".to_string(),
        pick_first: "先去選擇檔案".to_string(),
        waiting_confirm: "等待對方確認中…（請讓對方開啟應用程式確認）".to_string(),
        rejected: "對方已拒絕請求。".to_string(),
        confirm_timeout_retry: "對方未及時確認，請讓對方開啟應用程式後重新整理本頁重試。".to_string(),
        share_ended_retry: "分享已結束或暫無可下載檔案，請重新整理重試。".to_string(),
        request_failed_retry: "請求失敗，請重新整理重試。".to_string(),
        network_error_retry: "網路錯誤，請檢查連線後重試。".to_string(),
        upload_done: "上傳完成。".to_string(),
        select_first: "請先選擇要傳送的檔案。".to_string(),
        upload_failed_retry: "上傳失敗，請重試。".to_string(),
        upload_interrupted: "網路錯誤，上傳中斷。".to_string(),
        pin_title: "請輸入 PIN".to_string(),
        pin_confirm: "確定".to_string(),
        pin_error: "PIN 錯誤。".to_string(),
        download: "下載".to_string(),
        download_all: "全部下載".to_string(),
        download_all_unsupported: "目前瀏覽器不支援自動批次下載，請逐一點擊下載。".to_string(),
        upload: "上傳".to_string(),
        send_text: "傳送文字".to_string(),
        text_placeholder: "輸入要傳送的文字".to_string(),
        text_send: "傳送".to_string(),
        preview_loading: "預覽載入中…".to_string(),
        preview_unavailable: "預覽不可用。".to_string(),
    }
}

fn english() -> WebPageI18n {
    WebPageI18n {
        loading: "Loading…".to_string(),
        stopped_note: "This share has ended. Ask the sender to start it again, then refresh.".to_string(),
        download_title: "Downloads".to_string(),
        upload_title: "Send to device".to_string(),
        no_download_hint: "No files shared yet.".to_string(),
        upload_off_hint: "Browser upload is off.".to_string(),
        start_receive: "Turn on receiving".to_string(),
        pick_first: "Pick files first".to_string(),
        waiting_confirm: "Waiting for confirmation… (ask them to open the app)".to_string(),
        rejected: "The request was rejected.".to_string(),
        confirm_timeout_retry: "No confirmation in time. Ask them to open the app, then refresh and retry.".to_string(),
        share_ended_retry: "The share has ended or has no files. Refresh and retry.".to_string(),
        request_failed_retry: "Request failed. Refresh and retry.".to_string(),
        network_error_retry: "Network error. Check the connection and retry.".to_string(),
        upload_done: "Upload complete.".to_string(),
        select_first: "Select files to send first.".to_string(),
        upload_failed_retry: "Upload failed. Please retry.".to_string(),
        upload_interrupted: "Network error. Upload interrupted.".to_string(),
        pin_title: "Enter PIN".to_string(),
        pin_confirm: "OK".to_string(),
        pin_error: "Invalid PIN.".to_string(),
        download: "Download".to_string(),
        download_all: "Download all".to_string(),
        download_all_unsupported:
            "Your browser does not support automatic batch download; download files one by one.".to_string(),
        upload: "Upload".to_string(),
        send_text: "Send text".to_string(),
        text_placeholder: "Type the message to send".to_string(),
        text_send: "Send".to_string(),
        preview_loading: "Loading preview…".to_string(),
        preview_unavailable: "Preview unavailable.".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_i18n_fallback_is_simplified_chinese() {
        assert_eq!(web_page_i18n("").loading, "加载中…");
        assert_eq!(web_page_i18n("fr").loading, "加载中…");
        assert_eq!(web_page_i18n("zh-TW").loading, "載入中…");
        assert_eq!(web_page_i18n("zh_Hant_TW").loading, "載入中…");
        assert_eq!(web_page_i18n("en-US").loading, "Loading…");
    }

    #[test]
    fn test_i18n_serializes_camel_case_keys() {
        let json = serde_json::to_value(web_page_i18n("en")).unwrap();
        assert_eq!(json["downloadAll"], serde_json::json!("Download all"));
        assert_eq!(json["confirmTimeoutRetry"].as_str().unwrap().len() > 0, true);
    }
}
