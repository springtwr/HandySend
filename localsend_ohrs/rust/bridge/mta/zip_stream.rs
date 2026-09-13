//! MTA 发送端 ZIP 预打包。
//!
//! 按 ArkTS 传入的 `files[{path, entryName}]` 清单，用 `zip` crate 逐个条目（deflate）
//! 打包到 `zipPath`，返回 ZIP 总大小、源文件总大小与条目数，供 WS sendRequest 与
//! HTTPS 下载的 `Content-Length` / 进度使用。预打包避免流式即压导致长度未知。

use std::fs::File;
use std::io::BufWriter;
use std::path::Path;

use serde::{Deserialize, Serialize};

/// 待打包文件条目（来自 ArkTS `MtaServerConfig.files`）。
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MtaFileEntry {
    /// 沙箱文件路径
    pub path: String,
    /// ZIP 条目名（"{序号}/{显示文件名}"）
    pub entry_name: String,
    /// 源文件修改时间（Unix 毫秒，可选）；缺省时 ZIP 条目时间退化为打包时刻
    #[serde(default)]
    pub last_modified_ms: Option<u64>,
}

/// ZIP 条目时间读取结果（条目名 + 修改时间毫秒）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ZipEntryTime {
    /// ZIP 条目名（含 "{序号}/" 前缀）
    pub entry_name: String,
    /// 条目修改时间（Unix 毫秒；不可用时为 0）
    pub modified_unix_ms: i64,
}

/// 由 Unix 毫秒构造 ZIP 条目时间；缺失或不可表示时返回 None。
fn entry_datetime(last_modified_ms: Option<u64>) -> Option<zip::DateTime> {
    let ms = last_modified_ms?;
    let nanos = (ms as i128).checked_mul(1_000_000)?;
    let datetime = time::OffsetDateTime::from_unix_timestamp_nanos(nanos).ok()?;
    zip::DateTime::try_from(datetime).ok()
}

/// ZIP 条目时间 → Unix 毫秒；不可转换时返回 0（由接收端回退落盘时刻）。
fn datetime_to_unix_ms(datetime: zip::DateTime) -> i64 {
    match time::OffsetDateTime::try_from(datetime) {
        Ok(value) => (value.unix_timestamp_nanos() / 1_000_000) as i64,
        Err(_) => 0,
    }
}

/// 从条目名去掉 "{序号}/" 前缀取显示文件名。
pub fn display_name(entry_name: &str) -> String {
    match entry_name.split_once('/') {
        Some((_, rest)) => rest.to_string(),
        None => entry_name.to_string(),
    }
}

/// 打包结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PackResult {
    /// 生成的 ZIP 文件字节数
    pub zip_size: u64,
    /// 源文件总字节数
    pub total_size: u64,
    /// 条目数
    pub entry_count: usize,
}

/// 按文件清单预打包 ZIP（deflate），返回打包结果。
pub fn pack_zip(zip_path: &str, files: &[MtaFileEntry]) -> anyhow::Result<PackResult> {
    log::debug!("MTA ZIP 预打包开始 zip={} 条目数={}", zip_path, files.len());
    let file = File::create(zip_path)?;
    let mut writer = zip::ZipWriter::new(BufWriter::new(file));
    let mut total_size: u64 = 0;
    for entry in files {
        let mut source = File::open(&entry.path)
            .map_err(|e| anyhow::anyhow!("打开待打包文件失败 {}: {e}", entry.path))?;
        let source_len = source.metadata().map(|m| m.len()).unwrap_or(0);
        let mut options: zip::write::SimpleFileOptions = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        // 源文件时间可用时写入条目时间（MTA 协议载荷无时间字段，
        // 条目时间是唯一可承载文件时间的标准位）；不可用时保留默认值
        if let Some(datetime) = entry_datetime(entry.last_modified_ms) {
            options = options.last_modified_time(datetime);
        }
        writer.start_file(entry.entry_name.clone(), options)?;
        std::io::copy(&mut source, &mut writer)?;
        total_size += source_len;
        log::debug!(
            "MTA ZIP 打包条目 entry={} 源字节={} 累计源字节={}",
            entry.entry_name,
            source_len,
            total_size
        );
    }
    let mut buffered = writer.finish()?;
    // 确保缓冲区落盘后再读取元数据
    use std::io::Write;
    buffered.flush()?;
    let zip_size = Path::new(zip_path).metadata()?.len();
    log::debug!(
        "MTA ZIP 预打包完成 zip字节={} 源总字节={} 条目数={}",
        zip_size,
        total_size,
        files.len()
    );
    Ok(PackResult {
        zip_size,
        total_size,
        entry_count: files.len(),
    })
}

/// 读取 ZIP 中央目录中各条目的修改时间。
///
/// ArkTS 侧流式解压不保留条目时间，需以此接口作为权威时间来源；
/// 解析失败的 ZIP 由调用方（NAPI 层）转为空数组并记日志，不抛出到主流程。
pub fn read_entry_times(zip_path: &str) -> anyhow::Result<Vec<ZipEntryTime>> {
    let file = File::open(zip_path)?;
    let mut archive = zip::ZipArchive::new(file)?;
    let mut result: Vec<ZipEntryTime> = Vec::with_capacity(archive.len());
    for index in 0..archive.len() {
        let entry = archive.by_index(index)?;
        let modified_unix_ms = entry.last_modified().map(datetime_to_unix_ms).unwrap_or(0);
        result.push(ZipEntryTime {
            entry_name: entry.name().to_string(),
            modified_unix_ms,
        });
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    #[test]
    fn pack_creates_valid_zip() {
        let dir = std::env::temp_dir().join(format!("mta_zip_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let a_path = dir.join("a.txt");
        let b_path = dir.join("b.txt");
        std::fs::write(&a_path, b"hello mta").unwrap();
        std::fs::write(&b_path, b"second file").unwrap();
        let zip_path = dir.join("out.zip");

        let files = vec![
            MtaFileEntry {
                path: a_path.to_string_lossy().to_string(),
                entry_name: "1/a.txt".into(),
                last_modified_ms: None,
            },
            MtaFileEntry {
                path: b_path.to_string_lossy().to_string(),
                entry_name: "2/b.txt".into(),
                last_modified_ms: None,
            },
        ];
        let result = pack_zip(zip_path.to_string_lossy().as_ref(), &files).unwrap();
        assert_eq!(result.entry_count, 2);
        assert_eq!(result.total_size, 9 + 11);
        assert!(result.zip_size > 0);

        // ZIP 头部魔数 PK\x03\x04
        let mut head = [0u8; 4];
        File::open(&zip_path)
            .unwrap()
            .read_exact(&mut head)
            .unwrap();
        assert_eq!(&head, b"PK\x03\x04");

        // 可被 zip 读回且条目名一致
        let reader = File::open(&zip_path).unwrap();
        let mut archive = zip::ZipArchive::new(reader).unwrap();
        assert_eq!(archive.len(), 2);
        let mut first = archive.by_index(0).unwrap();
        assert_eq!(first.name(), "1/a.txt");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn display_name_strips_sequence() {
        assert_eq!(display_name("1/photo.jpg"), "photo.jpg");
        assert_eq!(display_name("plain.txt"), "plain.txt");
    }

    #[test]
    fn pack_writes_source_modified_time_and_read_back() {
        let dir = std::env::temp_dir().join(format!("mta_zip_time_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let a_path = dir.join("a.txt");
        std::fs::write(&a_path, b"timed").unwrap();
        let zip_path = dir.join("out.zip");

        // 2020-09-13T12:26:40Z（秒数为偶数，可被 DOS 时间精确表示）
        let epoch_ms: u64 = 1_600_000_000_000;
        let files = vec![MtaFileEntry {
            path: a_path.to_string_lossy().to_string(),
            entry_name: "1/a.txt".into(),
            last_modified_ms: Some(epoch_ms),
        }];
        pack_zip(zip_path.to_string_lossy().as_ref(), &files).unwrap();

        let times = read_entry_times(zip_path.to_string_lossy().as_ref()).unwrap();
        assert_eq!(times.len(), 1);
        assert_eq!(times[0].entry_name, "1/a.txt");
        assert_eq!(times[0].modified_unix_ms as u64, epoch_ms);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn pack_without_source_time_still_reads_valid_time() {
        let dir = std::env::temp_dir().join(format!("mta_zip_notime_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let a_path = dir.join("a.txt");
        std::fs::write(&a_path, b"plain").unwrap();
        let zip_path = dir.join("out.zip");

        // 缺省源时间：打包不应失败，条目时间退化为可读的默认值（非负）
        let files = vec![MtaFileEntry {
            path: a_path.to_string_lossy().to_string(),
            entry_name: "1/a.txt".into(),
            last_modified_ms: None,
        }];
        pack_zip(zip_path.to_string_lossy().as_ref(), &files).unwrap();

        let times = read_entry_times(zip_path.to_string_lossy().as_ref()).unwrap();
        assert_eq!(times.len(), 1);
        assert!(times[0].modified_unix_ms >= 0);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn read_entry_times_invalid_zip_errors() {
        let result = read_entry_times("/nonexistent/not-a-zip.zip");
        assert!(result.is_err());
    }
}
