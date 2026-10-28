//! Web 流式 ZIP 的尺寸计算与条目时间编码。
//!
//! 网页全部下载使用 `Stored` 压缩、无额外字段、无注释；在条目名与大小已知时，
//! 本地头/数据描述符/中央目录/EOCD 的字节数是确定的，因此可以在发响应头前
//! 算出精确 `Content-Length`，让浏览器下载管理器显示百分比。
//!
//! 本模块只做纯计算，不读写文件；写入侧必须使用同一份 `layout()` 结果里的
//! `large` 标记，避免长度预测与实际输出漂移。

use std::time::{SystemTime, UNIX_EPOCH};

/// ZIP32 字段上限；达到该值的单个条目使用 Zip64 字段。
pub const ZIP64_THRESHOLD: u64 = 0xFFFF_FFFF;

/// Zip64 EOCD（56）+ locator（20）。
const ZIP64_FOOTER_LEN: u64 = 76;

/// 单个条目的尺寸输入（名称长度按 UTF-8 字节数）。
#[derive(Clone, Copy, Debug)]
pub struct SizeEntry {
    pub name_len: usize,
    pub size: u64,
}

/// 单个条目的布局结果。
#[derive(Clone, Copy, Debug)]
pub struct EntryLayout {
    /// 是否使用 Zip64 条目字段。
    pub large: bool,
    /// 本地头起始偏移（用于中央目录 Zip64 offset 额外字段判断）。
    pub header_start: u64,
}

/// 整个 ZIP 的布局结果。
#[derive(Clone, Debug)]
pub struct ZipLayout {
    pub entries: Vec<EntryLayout>,
    /// 精确的响应体字节数。
    pub total_len: u64,
    /// 是否需要主动设置空的 Zip64 extensible data sector。
    ///
    /// zip crate 自身用 `>` 判断归档级 Zip64；恰好 4GB 时会写出 0xFFFFFFFF
    /// 但没有 Zip64 EOCD。这里在 `>=` 时主动强制，保证归档有效。
    pub force_zip64: bool,
}

/// 计算 Stored 流式 ZIP 的精确长度。
pub fn layout(entries: &[SizeEntry]) -> Result<ZipLayout, &'static str> {
    let mut layouts = Vec::with_capacity(entries.len());
    let mut local_len: u64 = 0;
    let mut central_len: u64 = 0;
    for entry in entries {
        if entry.name_len > u16::MAX as usize {
            return Err("zip entry name is too long");
        }
        let name_len = entry.name_len as u64;
        let large = entry.size >= ZIP64_THRESHOLD;
        // 30 = local header magic + fixed block；20 = 本地 Zip64 extra。
        let local_entry = 30u64
            .checked_add(name_len)
            .and_then(|v| v.checked_add(if large { 20 } else { 0 }))
            .and_then(|v| v.checked_add(entry.size))
            .and_then(|v| v.checked_add(if large { 24 } else { 16 }))
            .ok_or("zip entry size overflow")?;
        // 中央目录：46 固定头 + 名称；large 条目带 16 字节大小字段，
        // offset 达到 4GB 时再带 8 字节 offset 字段。
        let central_extra = if large {
            20 + if local_len >= ZIP64_THRESHOLD { 8 } else { 0 }
        } else if local_len >= ZIP64_THRESHOLD {
            12
        } else {
            0
        };
        let central_entry = 46u64
            .checked_add(name_len)
            .and_then(|v| v.checked_add(central_extra))
            .ok_or("zip central directory size overflow")?;
        layouts.push(EntryLayout {
            large,
            header_start: local_len,
        });
        local_len = local_len
            .checked_add(local_entry)
            .ok_or("zip local data size overflow")?;
        central_len = central_len
            .checked_add(central_entry)
            .ok_or("zip central directory size overflow")?;
    }
    let needs_zip64 = entries.len() > u16::MAX as usize
        || local_len >= ZIP64_THRESHOLD
        || central_len >= ZIP64_THRESHOLD;
    let total_len = local_len
        .checked_add(central_len)
        .and_then(|v| v.checked_add(if needs_zip64 { ZIP64_FOOTER_LEN } else { 0 }))
        .and_then(|v| v.checked_add(22))
        .ok_or("zip total size overflow")?;
    Ok(ZipLayout {
        entries: layouts,
        total_len,
        force_zip64: needs_zip64,
    })
}

/// 用设备本地时间编码 ZIP 条目时间；缺失/非法时退回当前时间。
///
/// ZIP 的 DOS 时间没有时区，只有 2 秒精度；这里使用本地年月日时分秒，
/// 使解压端显示的墙钟时间与手机一致。
pub fn entry_date_time(last_modified_ms: Option<u64>) -> zip::DateTime {
    let ms = last_modified_ms
        .or_else(|| {
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .ok()
                .map(|d| d.as_millis() as u64)
        })
        .unwrap_or(0);
    match local_parts(ms) {
        Some((year, month, day, hour, minute, second)) => zip::DateTime::from_date_and_time(
            year as u16,
            month as u8,
            day as u8,
            hour as u8,
            minute as u8,
            second as u8,
        )
        .unwrap_or_else(|_| zip::DateTime::default()),
        None => zip::DateTime::default(),
    }
}

/// 生成 `handysend-YYYYMMDD-HHmmss.zip`（设备本地时间）。
pub fn zip_file_name() -> String {
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    match local_parts(ms) {
        Some((year, month, day, hour, minute, second)) => {
            format!("handysend-{year:04}{month:02}{day:02}-{hour:02}{minute:02}{second:02}.zip")
        }
        None => "handysend-files.zip".to_string(),
    }
}

#[allow(deprecated)]
fn local_parts(ms: u64) -> Option<(i32, u32, u32, u32, u32, u32)> {
    let seconds = (ms / 1000) as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: localtime_r 只写调用方提供的 tm；seconds 是合法值。
    let result = unsafe { libc::localtime_r(&seconds, &mut tm) };
    if result.is_null() {
        return None;
    }
    let year = tm.tm_year + 1900;
    if !(1980..=2107).contains(&year) {
        return None;
    }
    Some((
        year,
        (tm.tm_mon + 1) as u32,
        tm.tm_mday as u32,
        tm.tm_hour as u32,
        tm.tm_min as u32,
        tm.tm_sec as u32,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_layout_single_small_entry() {
        let layout = layout(&[SizeEntry {
            name_len: 5,
            size: 10,
        }])
        .unwrap();
        // 30+5+10+16 + 46+5 + 22
        assert_eq!(layout.total_len, 134);
        assert!(!layout.force_zip64);
        assert!(!layout.entries[0].large);
    }

    #[test]
    fn test_layout_zero_byte_and_utf8_name() {
        assert_eq!(
            layout(&[SizeEntry {
                name_len: 5,
                size: 0
            }])
            .unwrap()
            .total_len,
            124
        );
        // “目录/文件.txt” UTF-8 为 17 字节
        assert_eq!(
            layout(&[SizeEntry {
                name_len: 17,
                size: 5
            }])
            .unwrap()
            .total_len,
            153
        );
    }

    #[test]
    fn test_layout_multiple_entries() {
        let layout = layout(&[
            SizeEntry {
                name_len: 5,
                size: 10,
            },
            SizeEntry {
                name_len: 5,
                size: 1000,
            },
        ])
        .unwrap();
        assert_eq!(layout.total_len, 1236);
    }

    #[test]
    fn test_layout_large_entry_uses_zip64_fields() {
        let layout = layout(&[SizeEntry {
            name_len: 5,
            size: ZIP64_THRESHOLD,
        }])
        .unwrap();
        assert!(layout.entries[0].large);
        assert!(layout.force_zip64);
        // 30+5+20+size+24 + 46+5+20 + 76 + 22
        assert_eq!(
            layout.total_len,
            30 + 5 + 20 + ZIP64_THRESHOLD + 24 + 46 + 5 + 20 + 76 + 22
        );
    }

    #[test]
    fn test_layout_rejects_too_long_name() {
        assert!(layout(&[SizeEntry {
            name_len: u16::MAX as usize + 1,
            size: 0
        }])
        .is_err());
    }

    #[test]
    fn test_zip_file_name_shape() {
        let name = zip_file_name();
        assert!(name.starts_with("handysend-"));
        assert!(name.ends_with(".zip"));
        assert_eq!(name.len(), "handysend-20260101-120000.zip".len());
    }
}
