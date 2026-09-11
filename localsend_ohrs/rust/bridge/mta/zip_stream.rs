//! MTA 发送端 ZIP 预打包。
//!
//! 按 ArkTS 传入的 `files[{path, entryName}]` 清单，用 `zip` crate 逐个条目（deflate）
//! 打包到 `zipPath`，返回 ZIP 总大小、源文件总大小与条目数，供 WS sendRequest 与
//! HTTPS 下载的 `Content-Length` / 进度使用。预打包避免流式即压导致长度未知。

use std::fs::File;
use std::io::BufWriter;
use std::path::Path;

use serde::Deserialize;

/// 待打包文件条目（来自 ArkTS `MtaServerConfig.files`）。
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MtaFileEntry {
    /// 沙箱文件路径
    pub path: String,
    /// ZIP 条目名（"{序号}/{显示文件名}"）
    pub entry_name: String,
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
        let options: zip::write::SimpleFileOptions = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
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
            },
            MtaFileEntry {
                path: b_path.to_string_lossy().to_string(),
                entry_name: "2/b.txt".into(),
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
}
