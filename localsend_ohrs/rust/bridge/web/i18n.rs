//! 浏览器单页文案（三语：简体/繁体/英文）。
//!
//! 服务端按 `GET /i18n.json?lang=` 返回对应语言，
//! 单页先拉文案再渲染；拉取失败时页面回退内置简体中文。

use serde::Serialize;

/// 单页文案（camelCase 键，与前端 `t(key)` 对照）。
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WebPageI18n {
    /// 应用显示名（与 AppScope 各语言的 app_name 保持一致）。
    pub app_name: String,
    pub theme: String,
    pub theme_system: String,
    pub theme_light: String,
    pub theme_dark: String,
    pub language: String,
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
    pub retry: String,
    pub upload_done: String,
    pub select_first: String,
    pub upload_failed_retry: String,
    pub upload_interrupted: String,
    pub pin_title: String,
    pub pin_confirm: String,
    pub pin_error: String,
    pub auth_subtitle: String,
    pub auth_placeholder: String,
    pub auth_enter: String,
    pub auth_too_many: String,
    pub access_ended_reload: String,
    pub refresh_page: String,
    pub access_link_required: String,
    pub access_link_invalid: String,
    pub download: String,
    pub download_all: String,
    pub download_all_unsupported: String,
    pub upload: String,
    pub choose_file: String,
    pub clear: String,
    pub remove: String,
    pub nothing_to_send: String,
    pub send_text: String,
    pub text_placeholder: String,
    pub text_send: String,
    pub preview_loading: String,
    pub preview_unavailable: String,
    pub share_updated_retry: String,
    pub https_hint: String,
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
        app_name: "便捷快传".to_string(),
        theme: "主题".to_string(),
        theme_system: "跟随系统".to_string(),
        theme_light: "浅色".to_string(),
        theme_dark: "深色".to_string(),
        language: "语言".to_string(),
        loading: "加载中…".to_string(),
        stopped_note: "分享已结束，请让发送方重新开启后刷新本页。".to_string(),
        download_title: "下载".to_string(),
        upload_title: "发送".to_string(),
        no_download_hint: "暂无可下载文件，请等待发送方添加。".to_string(),
        upload_off_hint: "浏览器上传未开启，请让发送方在应用内开启。".to_string(),
        start_receive: "开启接收".to_string(),
        pick_first: "先去选文件".to_string(),
        waiting_confirm: "等待对方确认中…（请让对方打开应用确认）".to_string(),
        rejected: "对方已拒绝请求。".to_string(),
        confirm_timeout_retry: "对方未及时确认，请让对方打开应用后刷新本页重试。".to_string(),
        share_ended_retry: "分享已结束或暂无可下载文件，请刷新重试。".to_string(),
        request_failed_retry: "请求失败，请刷新重试。".to_string(),
        network_error_retry: "网络错误，请检查连接后重试。".to_string(),
        retry: "重试".to_string(),
        upload_done: "上传完成。".to_string(),
        select_first: "请先选择要发送的文件。".to_string(),
        upload_failed_retry: "上传失败，请重试。".to_string(),
        upload_interrupted: "网络错误，上传中断。".to_string(),
        pin_title: "请输入访问密码".to_string(),
        pin_confirm: "确定".to_string(),
        pin_error: "密码错误。".to_string(),
        auth_subtitle: "此网页已设置访问密码，输入后即可继续。".to_string(),
        auth_placeholder: "访问密码".to_string(),
        auth_enter: "进入".to_string(),
        auth_too_many: "尝试次数过多，请稍后再试。".to_string(),
        access_ended_reload: "本次网页访问已结束，请刷新页面重新访问。".to_string(),
        refresh_page: "刷新页面".to_string(),
        access_link_required: "请扫描发送方出示的二维码后访问。".to_string(),
        access_link_invalid: "访问链接已失效，请让发送方重新出示二维码。".to_string(),
        download: "下载".to_string(),
        download_all: "全部下载".to_string(),
        download_all_unsupported: "当前浏览器不支持自动批量下载，请逐个点击下载。".to_string(),
        upload: "发送".to_string(),
        choose_file: "选择文件".to_string(),
        clear: "清空".to_string(),
        remove: "移除".to_string(),
        nothing_to_send: "请选择文件或输入文本。".to_string(),
        send_text: "发送文本".to_string(),
        text_placeholder: "输入要发送的文本".to_string(),
        text_send: "发送文本".to_string(),
        preview_loading: "预览加载中…".to_string(),
        preview_unavailable: "预览不可用。".to_string(),
        share_updated_retry: "分享内容已更新，请刷新重试。".to_string(),
        https_hint: "当前为加密连接（自签名证书），如下载失败，可让对方关闭加密传输后重试。"
            .to_string(),
    }
}

fn traditional() -> WebPageI18n {
    WebPageI18n {
        app_name: "便捷快傳".to_string(),
        theme: "主題".to_string(),
        theme_system: "跟隨系統".to_string(),
        theme_light: "淺色".to_string(),
        theme_dark: "深色".to_string(),
        language: "語言".to_string(),
        loading: "載入中…".to_string(),
        stopped_note: "分享已結束，請讓傳送方重新開啟後重新整理本頁。".to_string(),
        download_title: "下載".to_string(),
        upload_title: "傳送".to_string(),
        no_download_hint: "暫無可下載檔案，請等待傳送方新增。".to_string(),
        upload_off_hint: "瀏覽器上傳未開啟，請讓傳送方在應用程式內開啟。".to_string(),
        start_receive: "開啟接收".to_string(),
        pick_first: "先去選擇檔案".to_string(),
        waiting_confirm: "等待對方確認中…（請讓對方開啟應用程式確認）".to_string(),
        rejected: "對方已拒絕請求。".to_string(),
        confirm_timeout_retry: "對方未及時確認，請讓對方開啟應用程式後重新整理本頁重試。"
            .to_string(),
        share_ended_retry: "分享已結束或暫無可下載檔案，請重新整理重試。".to_string(),
        request_failed_retry: "請求失敗，請重新整理重試。".to_string(),
        network_error_retry: "網路錯誤，請檢查連線後重試。".to_string(),
        retry: "重試".to_string(),
        upload_done: "上傳完成。".to_string(),
        select_first: "請先選擇要傳送的檔案。".to_string(),
        upload_failed_retry: "上傳失敗，請重試。".to_string(),
        upload_interrupted: "網路錯誤，上傳中斷。".to_string(),
        pin_title: "請輸入存取密碼".to_string(),
        pin_confirm: "確定".to_string(),
        pin_error: "密碼錯誤。".to_string(),
        auth_subtitle: "此網頁已設定存取密碼，輸入後即可繼續。".to_string(),
        auth_placeholder: "存取密碼".to_string(),
        auth_enter: "進入".to_string(),
        auth_too_many: "嘗試次數過多，請稍後再試。".to_string(),
        access_ended_reload: "本次網頁存取已結束，請重新整理頁面再次存取。".to_string(),
        refresh_page: "重新整理頁面".to_string(),
        access_link_required: "請掃描傳送方出示的 QR Code 後存取。".to_string(),
        access_link_invalid: "存取連結已失效，請讓傳送方重新出示 QR Code。".to_string(),
        download: "下載".to_string(),
        download_all: "全部下載".to_string(),
        download_all_unsupported: "目前瀏覽器不支援自動批次下載，請逐一點擊下載。".to_string(),
        upload: "傳送".to_string(),
        choose_file: "選擇檔案".to_string(),
        clear: "清除".to_string(),
        remove: "移除".to_string(),
        nothing_to_send: "請選擇檔案或輸入文字。".to_string(),
        send_text: "傳送文字".to_string(),
        text_placeholder: "輸入要傳送的文字".to_string(),
        text_send: "傳送文字".to_string(),
        preview_loading: "預覽載入中…".to_string(),
        preview_unavailable: "預覽不可用。".to_string(),
        share_updated_retry: "分享內容已更新，請重新整理重試。".to_string(),
        https_hint: "目前為加密連線（自簽章憑證），如下載失敗，可請對方關閉加密傳輸後重試。"
            .to_string(),
    }
}

fn english() -> WebPageI18n {
    WebPageI18n {
        app_name: "HandySend".to_string(),
        theme: "Theme".to_string(),
        theme_system: "Follow system".to_string(),
        theme_light: "Light".to_string(),
        theme_dark: "Dark".to_string(),
        language: "Language".to_string(),
        loading: "Loading…".to_string(),
        stopped_note: "This share has ended. Ask the sender to start it again, then refresh.".to_string(),
        download_title: "Downloads".to_string(),
        upload_title: "Send".to_string(),
        no_download_hint: "No files have been shared yet. Wait for the sender to add some.".to_string(),
        upload_off_hint: "Browser upload is off. Ask the sender to turn it on in the app.".to_string(),
        start_receive: "Turn on receiving".to_string(),
        pick_first: "Pick files first".to_string(),
        waiting_confirm: "Waiting for confirmation… (ask them to open the app)".to_string(),
        rejected: "The request was rejected.".to_string(),
        confirm_timeout_retry: "No confirmation in time. Ask them to open the app, then refresh and retry.".to_string(),
        share_ended_retry: "The share has ended or has no files. Refresh and retry.".to_string(),
        request_failed_retry: "Request failed. Refresh and retry.".to_string(),
        network_error_retry: "Network error. Check the connection and retry.".to_string(),
        retry: "Retry".to_string(),
        upload_done: "Upload complete.".to_string(),
        select_first: "Select files to send first.".to_string(),
        upload_failed_retry: "Upload failed. Please retry.".to_string(),
        upload_interrupted: "Network error. Upload interrupted.".to_string(),
        pin_title: "Enter password".to_string(),
        pin_confirm: "OK".to_string(),
        pin_error: "Invalid password.".to_string(),
        auth_subtitle: "This page is password protected. Enter the password to continue.".to_string(),
        auth_placeholder: "Access password".to_string(),
        auth_enter: "Enter".to_string(),
        auth_too_many: "Too many attempts. Try again later.".to_string(),
        access_ended_reload: "This web session has ended. Refresh the page to access again.".to_string(),
        refresh_page: "Refresh".to_string(),
        access_link_required: "Scan the QR code shown by the sender to access this page.".to_string(),
        access_link_invalid: "This access link is invalid. Ask the sender to show the QR code again."
            .to_string(),
        download: "Download".to_string(),
        download_all: "Download all".to_string(),
        download_all_unsupported:
            "Your browser does not support automatic batch download; download files one by one.".to_string(),
        upload: "Send".to_string(),
        choose_file: "Choose files".to_string(),
        clear: "Clear".to_string(),
        remove: "Remove".to_string(),
        nothing_to_send: "Choose files or type a message.".to_string(),
        send_text: "Send text".to_string(),
        text_placeholder: "Type the message to send".to_string(),
        text_send: "Send text".to_string(),
        preview_loading: "Loading preview…".to_string(),
        preview_unavailable: "Preview unavailable.".to_string(),
        share_updated_retry: "Shared content has changed. Refresh and retry.".to_string(),
        https_hint: "This is an encrypted connection (self-signed certificate). If downloads fail, ask them to turn off encrypted transfer and retry.".to_string(),
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
    fn test_app_name_localized() {
        assert_eq!(web_page_i18n("zh-CN").app_name, "便捷快传");
        assert_eq!(web_page_i18n("zh-Hant").app_name, "便捷快傳");
        assert_eq!(web_page_i18n("en-US").app_name, "HandySend");
    }

    #[test]
    fn test_i18n_serializes_camel_case_keys() {
        let json = serde_json::to_value(web_page_i18n("en")).unwrap();
        assert_eq!(json["downloadAll"], serde_json::json!("Download all"));
        assert_eq!(json["themeSystem"], serde_json::json!("Follow system"));
        assert!(json["shareUpdatedRetry"].as_str().unwrap().len() > 0);
        assert!(json["httpsHint"].as_str().unwrap().len() > 0);
        assert!(json["accessLinkRequired"].as_str().unwrap().len() > 0);
        assert!(json["accessLinkInvalid"].as_str().unwrap().len() > 0);
        assert_eq!(
            json["confirmTimeoutRetry"].as_str().unwrap().len() > 0,
            true
        );
    }
}
