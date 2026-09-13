//! MTA 发送端流式 ZIP 写出。
//!
//! 按 ArkTS 传入的 `files[{path, entryName}]` 清单，边读沙箱源文件边把 ZIP 字节流写入
//! 目标 writer（下载响应体），不预打包、不落临时 ZIP：服务器暂存完成后立即就绪，
//! 传输开始前的等待不再随文件总大小线性增长。
//!
//! 条目一律使用 `Stored`（不压缩）。为保证产物是标准 ZIP（而非依赖数据描述符的流式
//! 变体），条目的 CRC32 与大小写在本地文件头中：写出前先顺序读取一次源文件计算 CRC，
//! 再顺序读取写出条目数据——两次顺序读，无 deflate CPU，服务器起服仍为 O(1)。

use std::fs::File;
use std::io::{Read, Write};

use serde::Deserialize;

/// 待发送文件条目（来自 ArkTS `MtaServerConfig.files`）。
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MtaFileEntry {
    /// 沙箱文件路径
    pub path: String,
    /// ZIP 条目名（"{序号}/{显示文件名}"）
    pub entry_name: String,
    /// 源文件修改时间（Unix 毫秒，可选）；缺省时条目时间退化为压缩基准时刻
    #[serde(default)]
    pub last_modified_ms: Option<u64>,
}

/// 流式写出结果：源文件总字节数与条目数。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ZipWriteResult {
    /// 源文件总字节数（进度分母）
    pub total_size: u64,
    /// 条目数
    pub entry_count: usize,
}

// ── ZIP 结构常量 ──

/// 本地文件头签名
const LOCAL_SIG: u32 = 0x0403_4b50;
/// 中央目录头签名
const CENTRAL_SIG: u32 = 0x0201_4b50;
/// 中央目录结束记录签名
const EOCD_SIG: u32 = 0x0605_4b50;
/// 解压所需版本（2.0）
const VERSION: u16 = 20;
/// 压缩方法：不压缩
const METHOD_STORED: u16 = 0;
/// 文件名 UTF-8 标志位
const FLAG_UTF8: u16 = 0x0800;
/// 缺省 DOS 时间：1980-01-01 00:00:00（date=0x0021, time=0）
const DEFAULT_DOS_BITS: u32 = 0x0021_0000;
/// 条目读写缓冲区大小（字节）
const IO_BUFFER_SIZE: usize = 256 * 1024;

/// 从条目名去掉 "{序号}/" 前缀取显示文件名。
pub fn display_name(entry_name: &str) -> String {
    match entry_name.split_once('/') {
        Some((_, rest)) => rest.to_string(),
        None => entry_name.to_string(),
    }
}

/// 由 Unix 毫秒编码 DOS 日期时间位（高 16 位日期、低 16 位时间）。
///
/// 时间按 UTC 解释；缺失、非法或超出 DOS 可表示区间（1980–2107）时用缺省值，
/// 保证本地头与中央目录使用同一时间来源。
fn dos_datetime_bits(last_modified_ms: Option<u64>) -> u32 {
    let ms = match last_modified_ms {
        Some(value) if value > 0 => value,
        _ => return DEFAULT_DOS_BITS,
    };
    let seconds = (ms / 1000) as i64;
    let datetime = match time::OffsetDateTime::from_unix_timestamp(seconds) {
        Ok(value) => value,
        Err(_) => return DEFAULT_DOS_BITS,
    };
    let year = datetime.year();
    if !(1980..=2107).contains(&year) {
        return DEFAULT_DOS_BITS;
    }
    let date =
        (((year - 1980) as u32) << 9) | ((datetime.month() as u32) << 5) | datetime.day() as u32;
    let time_bits = ((datetime.hour() as u32) << 11)
        | ((datetime.minute() as u32) << 5)
        | (datetime.second() as u32 / 2);
    (date << 16) | time_bits
}

/// 顺序读取源文件，返回 CRC32 与字节数。
fn compute_crc_and_size(path: &str) -> anyhow::Result<(u32, u64)> {
    let mut file =
        File::open(path).map_err(|e| anyhow::anyhow!("打开待发送文件失败 {path}: {e}"))?;
    let mut hasher = crc32fast::Hasher::new();
    let mut buffer = vec![0u8; IO_BUFFER_SIZE];
    let mut total: u64 = 0;
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|e| anyhow::anyhow!("读取待发送文件失败 {path}: {e}"))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        total += read as u64;
    }
    Ok((hasher.finalize(), total))
}

/// 构造 30 字节本地文件头。
fn local_header(flags: u16, dos_bits: u32, crc: u32, size: u32, name_len: u16) -> [u8; 30] {
    let mut header = [0u8; 30];
    header[0..4].copy_from_slice(&LOCAL_SIG.to_le_bytes());
    header[4..6].copy_from_slice(&VERSION.to_le_bytes());
    header[6..8].copy_from_slice(&flags.to_le_bytes());
    header[8..10].copy_from_slice(&METHOD_STORED.to_le_bytes());
    header[10..12].copy_from_slice(&(dos_bits as u16).to_le_bytes());
    header[12..14].copy_from_slice(&((dos_bits >> 16) as u16).to_le_bytes());
    header[14..18].copy_from_slice(&crc.to_le_bytes());
    header[18..22].copy_from_slice(&size.to_le_bytes());
    header[22..26].copy_from_slice(&size.to_le_bytes());
    header[26..28].copy_from_slice(&name_len.to_le_bytes());
    header[28..30].copy_from_slice(&0u16.to_le_bytes());
    header
}

/// 一条已写出条目的中央目录记录。
struct CentralRecord {
    /// 条目名（与本地头一致）
    name: String,
    /// 通用标志位
    flags: u16,
    /// DOS 日期时间位
    dos_bits: u32,
    /// CRC32
    crc: u32,
    /// 大小（Stored 下等于压缩后大小）
    size: u32,
    /// 本地文件头偏移
    local_offset: u32,
}

/// 构造 46 字节中央目录头（文件名单独追加）。
fn central_header(record: &CentralRecord, name_len: u16) -> [u8; 46] {
    let mut header = [0u8; 46];
    header[0..4].copy_from_slice(&CENTRAL_SIG.to_le_bytes());
    header[4..6].copy_from_slice(&VERSION.to_le_bytes());
    header[6..8].copy_from_slice(&VERSION.to_le_bytes());
    header[8..10].copy_from_slice(&record.flags.to_le_bytes());
    header[10..12].copy_from_slice(&METHOD_STORED.to_le_bytes());
    header[12..14].copy_from_slice(&(record.dos_bits as u16).to_le_bytes());
    header[14..16].copy_from_slice(&((record.dos_bits >> 16) as u16).to_le_bytes());
    header[16..20].copy_from_slice(&record.crc.to_le_bytes());
    header[20..24].copy_from_slice(&record.size.to_le_bytes());
    header[24..28].copy_from_slice(&record.size.to_le_bytes());
    header[28..30].copy_from_slice(&name_len.to_le_bytes());
    // 额外字段长度、注释长度、起始磁盘号、内部属性均为 0
    header[36..38].copy_from_slice(&0u16.to_le_bytes());
    // 外部属性：Unix 常规文件 0o100644（高 16 位为 Unix 模式）
    header[38..42].copy_from_slice(&(0o100_644u32 << 16).to_le_bytes());
    header[42..46].copy_from_slice(&record.local_offset.to_le_bytes());
    header
}

/// 构造 22 字节中央目录结束记录。
fn end_of_central_directory(entry_count: u16, cd_size: u32, cd_offset: u32) -> [u8; 22] {
    let mut eocd = [0u8; 22];
    eocd[0..4].copy_from_slice(&EOCD_SIG.to_le_bytes());
    eocd[4..6].copy_from_slice(&0u16.to_le_bytes());
    eocd[6..8].copy_from_slice(&0u16.to_le_bytes());
    eocd[8..10].copy_from_slice(&entry_count.to_le_bytes());
    eocd[10..12].copy_from_slice(&entry_count.to_le_bytes());
    eocd[12..16].copy_from_slice(&cd_size.to_le_bytes());
    eocd[16..20].copy_from_slice(&cd_offset.to_le_bytes());
    eocd[20..22].copy_from_slice(&0u16.to_le_bytes());
    eocd
}

/// 按文件清单把 ZIP 字节流写入 `writer`，返回源文件总大小与条目数。
///
/// `on_source_bytes` 在条目数据写出过程中被调用，参数为累计已读源字节数，
/// 供发送进度上报（口径为"已读源字节 ÷ 声明总大小"）。写出失败时向上返回错误，
/// 由响应体收尾，不挂起连接。
pub fn write_zip_stream<W, F>(
    writer: &mut W,
    files: &[MtaFileEntry],
    mut on_source_bytes: F,
) -> anyhow::Result<ZipWriteResult>
where
    W: Write,
    F: FnMut(u64),
{
    if files.len() > u16::MAX as usize {
        anyhow::bail!("ZIP 条目数超过 65535");
    }
    let mut records: Vec<CentralRecord> = Vec::with_capacity(files.len());
    let mut offset: u32 = 0;
    let mut total_source: u64 = 0;
    let mut buffer = vec![0u8; IO_BUFFER_SIZE];

    for entry in files {
        let (crc, size) = compute_crc_and_size(&entry.path)?;
        if size > u32::MAX as u64 {
            anyhow::bail!("单条目超过 ZIP32 上限 {}", entry.entry_name);
        }
        let size32 = size as u32;
        let flags = if entry.entry_name.is_ascii() {
            0
        } else {
            FLAG_UTF8
        };
        let dos_bits = dos_datetime_bits(entry.last_modified_ms);
        let name_bytes = entry.entry_name.as_bytes();
        let name_len = name_bytes.len() as u16;
        let local_offset = offset;

        let header = local_header(flags, dos_bits, crc, size32, name_len);
        writer.write_all(&header)?;
        writer.write_all(name_bytes)?;
        offset += header.len() as u32 + name_len as u32;

        let mut source = File::open(&entry.path)
            .map_err(|e| anyhow::anyhow!("打开待发送文件失败 {}: {e}", entry.path))?;
        loop {
            let read = source
                .read(&mut buffer)
                .map_err(|e| anyhow::anyhow!("读取待发送文件失败 {}: {e}", entry.path))?;
            if read == 0 {
                break;
            }
            writer.write_all(&buffer[..read])?;
            offset += read as u32;
            total_source += read as u64;
            on_source_bytes(total_source);
        }

        records.push(CentralRecord {
            name: entry.entry_name.clone(),
            flags,
            dos_bits,
            crc,
            size: size32,
            local_offset,
        });
        log::debug!(
            "MTA 流式写出条目 entry={} 源字节={} 累计源字节={}",
            entry.entry_name,
            size,
            total_source
        );
    }

    let cd_offset = offset;
    for record in &records {
        let name_bytes = record.name.as_bytes();
        let name_len = name_bytes.len() as u16;
        let header = central_header(record, name_len);
        writer.write_all(&header)?;
        writer.write_all(name_bytes)?;
        offset += header.len() as u32 + name_len as u32;
    }
    let cd_size = offset - cd_offset;

    let eocd = end_of_central_directory(records.len() as u16, cd_size, cd_offset);
    writer.write_all(&eocd)?;
    writer.flush()?;

    log::debug!(
        "MTA 流式写出发送产物完成 源总字节={} 条目数={}",
        total_source,
        records.len()
    );
    Ok(ZipWriteResult {
        total_size: total_source,
        entry_count: records.len(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 构造独立临时目录。
    fn temp_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("mta_zip_stream_{tag}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn display_name_strips_sequence() {
        assert_eq!(display_name("1/photo.jpg"), "photo.jpg");
        assert_eq!(display_name("plain.txt"), "plain.txt");
    }

    #[test]
    fn dos_datetime_bits_roundtrip_even_second() {
        // 2020-09-13T12:26:40Z（秒数为偶数，可被 DOS 时间精确表示）
        let bits = dos_datetime_bits(Some(1_600_000_000_000));
        let time_bits = (bits & 0xffff) as u16;
        let date_bits = (bits >> 16) as u16;
        assert_eq!(time_bits, ((12 << 11) | (26 << 5) | 20) as u16);
        assert_eq!(date_bits, (((2020 - 1980) << 9) | (9 << 5) | 13) as u16);
    }

    #[test]
    fn dos_datetime_bits_out_of_range_defaults() {
        assert_eq!(dos_datetime_bits(None), DEFAULT_DOS_BITS);
        assert_eq!(dos_datetime_bits(Some(0)), DEFAULT_DOS_BITS);
        // 1960-01-01（早于 DOS 下限）
        assert_eq!(
            dos_datetime_bits(Some(-315_619_200_000i64 as u64)),
            DEFAULT_DOS_BITS
        );
    }

    #[test]
    fn write_stream_produces_valid_zip() {
        let dir = temp_dir("valid");
        let a_path = dir.join("a.txt");
        let b_path = dir.join("b.txt");
        std::fs::write(&a_path, b"hello mta").unwrap();
        std::fs::write(&b_path, b"second file").unwrap();

        let files = vec![
            MtaFileEntry {
                path: a_path.to_string_lossy().to_string(),
                entry_name: "1/a.txt".into(),
                last_modified_ms: None,
            },
            MtaFileEntry {
                path: b_path.to_string_lossy().to_string(),
                entry_name: "2/b.txt".into(),
                last_modified_ms: Some(1_600_000_000_000),
            },
        ];
        let mut out: Vec<u8> = Vec::new();
        let result = write_zip_stream(&mut out, &files, |_| {}).unwrap();
        assert_eq!(result.entry_count, 2);
        assert_eq!(result.total_size, 9 + 11);
        assert_eq!(&out[0..4], b"PK\x03\x04");

        // 可被标准 seek 读取器读回，条目名/内容/时间一致
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(out)).unwrap();
        assert_eq!(archive.len(), 2);
        let mut first = archive.by_index(0).unwrap();
        assert_eq!(first.name(), "1/a.txt");
        let mut content = String::new();
        use std::io::Read as _;
        first.read_to_string(&mut content).unwrap();
        assert_eq!(content, "hello mta");
        drop(first);
        let second = archive.by_index(1).unwrap();
        assert_eq!(second.name(), "2/b.txt");
        // 2020-09-13T12:26:40Z 以 UTC 解释，读回应一致
        let modified = second.last_modified().unwrap();
        let dt = time::OffsetDateTime::try_from(modified).unwrap();
        assert_eq!(dt.unix_timestamp(), 1_600_000_000);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_stream_reports_source_progress() {
        let dir = temp_dir("progress");
        let a_path = dir.join("a.bin");
        let payload = vec![7u8; 1024 * 300];
        std::fs::write(&a_path, &payload).unwrap();
        let files = vec![MtaFileEntry {
            path: a_path.to_string_lossy().to_string(),
            entry_name: "1/a.bin".into(),
            last_modified_ms: None,
        }];
        let mut out: Vec<u8> = Vec::new();
        let mut samples: Vec<u64> = Vec::new();
        let result = write_zip_stream(&mut out, &files, |bytes| samples.push(bytes)).unwrap();
        assert_eq!(result.total_size, payload.len() as u64);
        assert!(!samples.is_empty());
        assert_eq!(*samples.last().unwrap(), payload.len() as u64);
        // 进度单调不减
        for pair in samples.windows(2) {
            assert!(pair[1] >= pair[0]);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_stream_missing_source_errors() {
        let files = vec![MtaFileEntry {
            path: "/nonexistent/mta-file".into(),
            entry_name: "1/x".into(),
            last_modified_ms: None,
        }];
        let mut out: Vec<u8> = Vec::new();
        assert!(write_zip_stream(&mut out, &files, |_| {}).is_err());
    }
}
