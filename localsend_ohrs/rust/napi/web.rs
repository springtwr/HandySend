//! 自研 Web 服务 NAPI 入口（薄封装，逻辑在 `bridge::web::runtime`）。
//!
//! ArkTS 侧经 `NativeBridge` 调用；事件经统一 `event_forwarder`
//! 推送（下载复用 `WebSend*`，上传用新增 `WebUpload*`）。

use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::*;

use crate::bridge::web::runtime;
use crate::napi::env::NapiEnv;

/// 启动自研 web 服务，返回实际绑定端口。
///
/// `config_json` 形如（camelCase）：
/// `{"alias","pin"?,"uploadEnabled","useHttps","uploadDir",
/// "files":[{"fileId","fileName","fileType","size","fd","filePath",
/// "preview"?,"sha256"?}]}`。
/// `fd >= 0` 时直读该 fd（ArkTS 持有原始句柄），否则回退 `filePath`。
#[napi]
pub async fn start_web_service(config_json: String) -> Result<u16> {
    NapiEnv::global().ensure_event_channel();
    runtime::start(&config_json)
        .await
        .map_err(|e| Error::from_reason(format!("Start web service failed: {e:#}")))
}

/// 停止自研 web 服务（幂等）。
#[napi]
pub fn stop_web_service() -> Result<()> {
    runtime::stop();
    Ok(())
}

/// 就地替换分享文件表（版本号 +1；返回生效文件数）。
#[napi]
pub fn update_web_service_files(files_json: String) -> Result<u32> {
    let count = runtime::update_files(&files_json)
        .map_err(|e| Error::from_reason(format!("Update web files failed: {e:#}")))?;
    Ok(count)
}

/// 设置浏览器上传入口开关。
#[napi]
pub fn set_web_service_upload_enabled(enabled: bool) -> Result<()> {
    runtime::set_upload_enabled(enabled)
        .map_err(|e| Error::from_reason(format!("Set web upload failed: {e:#}")))?;
    Ok(())
}

/// 接受待确认的浏览器会话（下载/上传两侧都试）。
#[napi]
pub fn accept_web_session(token: String) -> Result<()> {
    runtime::accept(&token)
        .map_err(|e| Error::from_reason(format!("Accept web session failed: {e:#}")))?;
    Ok(())
}

/// 拒绝待确认的浏览器会话（下载/上传两侧都试）。
#[napi]
pub fn decline_web_session(token: String) -> Result<()> {
    runtime::decline(&token)
        .map_err(|e| Error::from_reason(format!("Decline web session failed: {e:#}")))?;
    Ok(())
}

/// 令待确认的浏览器会话过期（浏览器收 408；下载/上传两侧都试）。
#[napi]
pub fn expire_web_session(token: String) -> Result<()> {
    runtime::expire(&token)
        .map_err(|e| Error::from_reason(format!("Expire web session failed: {e:#}")))?;
    Ok(())
}

/// 取消指定下载批次（应用任务取消）。
#[napi]
pub fn cancel_web_download(batch_id: String) -> Result<()> {
    runtime::cancel_download(&batch_id)
        .map_err(|e| Error::from_reason(format!("Cancel web download failed: {e:#}")))?;
    Ok(())
}

/// 设置浏览器上传的落盘目标（确认前调用；返回实际生效条目数）。
#[napi]
pub fn set_web_upload_targets(token: String, targets_json: String) -> Result<u32> {
    let applied = runtime::set_upload_targets(&token, &targets_json)
        .map_err(|e| Error::from_reason(format!("Set web upload targets failed: {e:#}")))?;
    Ok(applied)
}

/// 触发全量惰性打扫（供 ArkTS 侧超时驱动调用）。
#[napi]
pub async fn sweep_web_sessions() -> Result<()> {
    runtime::sweep()
        .await
        .map_err(|e| Error::from_reason(format!("Sweep web sessions failed: {e:#}")))?;
    Ok(())
}
