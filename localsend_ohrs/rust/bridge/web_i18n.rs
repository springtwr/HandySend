//! 网页分享文案本地化。
//!
//! 网页分享的下载页与上传页消费一组动态文案（34 项字段），由本模块按**应用生效语言**
//! 选择对应文案集后经 `/i18n.json` 下发。提供简体中文、繁体中文（台湾用语）、英文三套。
//!
//! 组织方式：
//! - 语言族判定为模块私有纯函数 `detect_lang`，返回私有三值枚举 [`WebLang`]；
//! - 每套文案各自一个私有构造函数；
//! - 对外只暴露分派入口 [`build_web_i18n`]，按语言族选择文案集。
//!
//! 文案字段集（34 项）与底层网页契约保持一致，不增不减。

use localsend::http::server::web::WebI18n;

/// 文案语言族（模块私有）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WebLang {
    /// 简体中文
    Simplified,
    /// 繁体中文（台湾用语）
    Traditional,
    /// 英文
    English,
}

/// 依据应用生效语言串判定文案语言族。
///
/// 规则：
/// - `zh-Hant`/`zh-TW`/`zh-HK`/`zh-MO` 归繁体；
/// - `zh-Hans`/`zh-CN`/`zh-SG` 及无地区后缀的 `zh` 归简体；
/// - 空值归简体；
/// - 其余（含 `en*` 与未覆盖语言如 `ja-JP`）归英文。
///
/// 生效语言串为 BCP47 形态，可能带脚本或地区后缀（如 `zh-Hant-TW`），故按语言族而非精确等值判定。
fn detect_lang(app_language: &str) -> WebLang {
    let lang = app_language.trim();
    if lang.is_empty() {
        return WebLang::Simplified;
    }

    let mut subtags = lang.split('-');
    let primary = subtags.next().unwrap_or("").to_ascii_lowercase();
    if primary != "zh" {
        return WebLang::English;
    }

    // 中文：默认简体，命中繁体脚本或繁体地区后缀时归繁体
    for subtag in subtags {
        match subtag.to_ascii_lowercase().as_str() {
            "hant" | "tw" | "hk" | "mo" => return WebLang::Traditional,
            _ => {}
        }
    }
    WebLang::Simplified
}

/// 依据应用生效语言构建网页文案集。
///
/// 供网页服务启动点调用：语言串为空、无法识别或读取失败时回退简体中文，绝不中断服务建立。
pub fn build_web_i18n(app_language: &str) -> WebI18n {
    match detect_lang(app_language) {
        WebLang::Simplified => simplified(),
        WebLang::Traditional => traditional(),
        WebLang::English => english(),
    }
}

/// 简体中文文案套（沿用既有文案，逐字保持）。
fn simplified() -> WebI18n {
    WebI18n {
        waiting: "等待响应…".to_string(),
        enter_pin: "输入PIN".to_string(),
        invalid_pin: "PIN错误".to_string(),
        too_many_attempts: "尝试次数过多".to_string(),
        rejected: "已拒绝".to_string(),
        upload_rejected: "接收方已拒绝请求。".to_string(),
        busy: "接收方正忙。".to_string(),
        files: "文件".to_string(),
        file_name: "文件名".to_string(),
        size: "大小".to_string(),
        download_all: "全部下载".to_string(),
        download: "下载".to_string(),
        select_files: "选择文件".to_string(),
        upload: "上传".to_string(),
        uploading: "正在上传".to_string(),
        upload_complete: "上传完成".to_string(),
        remove: "移除".to_string(),
        cancel: "取消".to_string(),
        confirm: "确定".to_string(),
        shared_by: "来自".to_string(),
        network_error: "网络错误".to_string(),
        retry: "重试".to_string(),
        share_title: "链接分享".to_string(),
        receive_title: "链接接收".to_string(),
        receive_subtitle: "文件将直接发送到接收方设备".to_string(),
        select_files_hint: "选择要发送的文件，可一次选择多个；也可直接发送文本".to_string(),
        send_text: "发送文本".to_string(),
        text_input_placeholder: "输入要发送的文本内容".to_string(),
        send: "发送".to_string(),
        download_all_unsupported: "当前浏览器不支持自动批量下载，请逐个点击文件下载".to_string(),
        text_preview_label: "该文件是手动输入的文本，以下是内容预览".to_string(),
        copy: "复制".to_string(),
        copied: "已复制".to_string(),
        js_required: "本地链接分享需要启用 JavaScript，当前已被禁用。请启用后重试。".to_string(),
    }
}

/// 英文文案套。
///
/// 英文即底层协议实现自带的默认文案，直接复用其 `Default` 实现，不再重写英文字面量，
/// 以保持文案来源单一。
fn english() -> WebI18n {
    WebI18n::default()
}

/// 繁体中文文案套（台湾用语）。
fn traditional() -> WebI18n {
    WebI18n {
        waiting: "等待回應…".to_string(),
        enter_pin: "輸入 PIN".to_string(),
        invalid_pin: "PIN 錯誤".to_string(),
        too_many_attempts: "嘗試次數過多".to_string(),
        rejected: "已拒絕".to_string(),
        upload_rejected: "接收方已拒絕請求。".to_string(),
        busy: "接收方正忙。".to_string(),
        files: "檔案".to_string(),
        file_name: "檔案名稱".to_string(),
        size: "大小".to_string(),
        download_all: "全部下載".to_string(),
        download: "下載".to_string(),
        select_files: "選擇檔案".to_string(),
        upload: "上傳".to_string(),
        uploading: "正在上傳".to_string(),
        upload_complete: "上傳完成".to_string(),
        remove: "移除".to_string(),
        cancel: "取消".to_string(),
        confirm: "確定".to_string(),
        shared_by: "來自".to_string(),
        network_error: "網路錯誤".to_string(),
        retry: "重試".to_string(),
        share_title: "連結分享".to_string(),
        receive_title: "連結接收".to_string(),
        receive_subtitle: "檔案將直接傳送到接收方裝置".to_string(),
        select_files_hint: "選擇要傳送的檔案，可一次選擇多個；也可直接傳送文字".to_string(),
        send_text: "傳送文字".to_string(),
        text_input_placeholder: "輸入要傳送的文字內容".to_string(),
        send: "傳送".to_string(),
        download_all_unsupported: "目前瀏覽器不支援自動批次下載，請逐個點擊檔案下載".to_string(),
        text_preview_label: "此檔案是手動輸入的文字，以下是內容預覽".to_string(),
        copy: "複製".to_string(),
        copied: "已複製".to_string(),
        js_required: "本機連結分享需要啟用 JavaScript，目前已停用。請啟用後重試。".to_string(),
    }
}

// ── 单元测试 ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// 逐项断言文案集 34 个字段均非空。
    fn assert_all_fields_non_empty(i18n: &WebI18n) {
        assert!(!i18n.waiting.is_empty());
        assert!(!i18n.enter_pin.is_empty());
        assert!(!i18n.invalid_pin.is_empty());
        assert!(!i18n.too_many_attempts.is_empty());
        assert!(!i18n.rejected.is_empty());
        assert!(!i18n.upload_rejected.is_empty());
        assert!(!i18n.busy.is_empty());
        assert!(!i18n.files.is_empty());
        assert!(!i18n.file_name.is_empty());
        assert!(!i18n.size.is_empty());
        assert!(!i18n.download_all.is_empty());
        assert!(!i18n.download.is_empty());
        assert!(!i18n.select_files.is_empty());
        assert!(!i18n.upload.is_empty());
        assert!(!i18n.uploading.is_empty());
        assert!(!i18n.upload_complete.is_empty());
        assert!(!i18n.remove.is_empty());
        assert!(!i18n.cancel.is_empty());
        assert!(!i18n.confirm.is_empty());
        assert!(!i18n.shared_by.is_empty());
        assert!(!i18n.network_error.is_empty());
        assert!(!i18n.retry.is_empty());
        assert!(!i18n.share_title.is_empty());
        assert!(!i18n.receive_title.is_empty());
        assert!(!i18n.receive_subtitle.is_empty());
        assert!(!i18n.select_files_hint.is_empty());
        assert!(!i18n.send_text.is_empty());
        assert!(!i18n.text_input_placeholder.is_empty());
        assert!(!i18n.send.is_empty());
        assert!(!i18n.download_all_unsupported.is_empty());
        assert!(!i18n.text_preview_label.is_empty());
        assert!(!i18n.copy.is_empty());
        assert!(!i18n.copied.is_empty());
        assert!(!i18n.js_required.is_empty());
    }

    #[test]
    fn detect_lang_traditional_variants() {
        assert_eq!(detect_lang("zh-Hant-TW"), WebLang::Traditional);
        assert_eq!(detect_lang("zh-Hant"), WebLang::Traditional);
        assert_eq!(detect_lang("zh-TW"), WebLang::Traditional);
        assert_eq!(detect_lang("zh-HK"), WebLang::Traditional);
        assert_eq!(detect_lang("zh-MO"), WebLang::Traditional);
    }

    #[test]
    fn detect_lang_simplified_variants() {
        assert_eq!(detect_lang("zh-Hans"), WebLang::Simplified);
        assert_eq!(detect_lang("zh-CN"), WebLang::Simplified);
        assert_eq!(detect_lang("zh-SG"), WebLang::Simplified);
        assert_eq!(detect_lang("zh"), WebLang::Simplified);
    }

    #[test]
    fn detect_lang_empty_falls_back_simplified() {
        assert_eq!(detect_lang(""), WebLang::Simplified);
        assert_eq!(detect_lang("   "), WebLang::Simplified);
    }

    #[test]
    fn detect_lang_other_languages_fall_back_english() {
        assert_eq!(detect_lang("en-US"), WebLang::English);
        assert_eq!(detect_lang("en"), WebLang::English);
        assert_eq!(detect_lang("ja-JP"), WebLang::English);
    }

    #[test]
    fn simplified_has_all_fields() {
        assert_all_fields_non_empty(&simplified());
    }

    #[test]
    fn english_has_all_fields() {
        assert_all_fields_non_empty(&english());
    }

    #[test]
    fn traditional_has_all_fields() {
        assert_all_fields_non_empty(&traditional());
    }

    #[test]
    fn build_dispatches_traditional_for_hant_variants() {
        // zh-Hant* / zh-TW 等应命中繁体文案套（以台湾用语字段值"檔案"区分）
        assert_eq!(build_web_i18n("zh-Hant-TW").files, "檔案");
        assert_eq!(build_web_i18n("zh-Hant").files, "檔案");
        assert_eq!(build_web_i18n("zh-TW").files, "檔案");
        assert_eq!(build_web_i18n("zh-HK").files, "檔案");
        assert_eq!(build_web_i18n("zh-MO").files, "檔案");
    }

    #[test]
    fn build_dispatches_simplified_and_english() {
        // 简体与空值命中简体文案套
        assert_eq!(build_web_i18n("zh-CN").files, "文件");
        assert_eq!(build_web_i18n("").files, "文件");
        // 未覆盖语言回退英文（复用底层默认文案）
        assert_eq!(build_web_i18n("ja-JP").files, "Files");
        assert_eq!(build_web_i18n("de-DE").files, "Files");
    }
}
