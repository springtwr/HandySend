//! MTA 发送端流式 ZIP 写出。
//!
//! 按 ArkTS 传入的 `files[{fdCrc, fdSend, path, crc32, sizeBytes, entryName}]` 清单，
//! 边读源文件边把 ZIP 字节流写入目标 writer（下载响应体），不预打包、不落临时 ZIP。
//!
//! 条目一律使用 `Stored`（不压缩），本地文件头写**真实 CRC 与大小**（由起服时
//! `start_server` 同步预计算提供），**不使用数据描述符**——这是兼容面最广的标准
//! ZIP 形态，对端（`java.util.zip.ZipInputStream` 系）Stored 直通读、零 inflate。
//! 数据源为 ArkTS 直传的 content URI 文件描述符（`fd_send`，同进程 `File::from_raw_fd`
//! 接管读取，参照 LocalSend 路径既有机制）；`fd_send < 0` 时回退 `path`（文本条目等）。

use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::FromRawFd;

use serde::Deserialize;

/// fd 字段缺省值：`-1` 表示不使用 fd、回退沙箱路径。
/// 不能用 `#[serde(default)]` 的 0——0 是合法 fd 号，误接管会关闭无关资源（如 stdin）。
fn unused_fd() -> i32 {
    -1
}

/// 待发送文件条目（来自 ArkTS `MtaServerConfig.files`）。
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MtaFileEntry {
    /// content URI 文件描述符：起服 CRC 预计算读取源（<0 不用，回退 `path`）
    #[serde(default = "unused_fd")]
    pub fd_crc: i32,
    /// content URI 文件描述符：下载发送读取源（<0 回退 `path`）
    #[serde(default = "unused_fd")]
    pub fd_send: i32,
    /// 沙箱回退路径（文本条目、无 fd 场景）
    pub path: String,
    /// ZIP 条目名（"{序号}/{显示文件名}"）
    pub entry_name: String,
    /// 源文件修改时间（Unix 毫秒，可选）；缺省时条目时间退化为压缩基准时刻
    #[serde(default)]
    pub last_modified_ms: Option<u64>,
    /// 起服预计算的 CRC32（本地头/中央目录真实值）
    #[serde(default)]
    pub crc32: u32,
    /// 起服预计算的源文件大小（字节；本地头/中央目录真实值，Stored 下即压缩后大小）
    #[serde(default)]
    pub size_bytes: u64,
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

/// 构造 30 字节本地文件头（写真实 CRC 与大小，Stored 下压缩后大小 == 原始大小）。
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

/// 打开条目数据源：`fd_send >= 0` 时接管该 fd（读毕/错误时关闭），否则按路径打开。
fn open_source(entry: &MtaFileEntry) -> anyhow::Result<File> {
    if entry.fd_send >= 0 {
        // SAFETY：fd 由 ArkTS 打开并移交所有权；本函数返回的 File 读毕（EOF/错误）时关闭，
        // 后续不再由 ArkTS 或任何其他路径触碰（server 停止路径仅关闭未消费的 fd，见 mod.rs）。
        let file = unsafe { File::from_raw_fd(entry.fd_send) };
        return Ok(file);
    }
    File::open(&entry.path).map_err(|e| anyhow::anyhow!("打开待发送文件失败 {}: {e}", entry.path))
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
        let flags = if entry.entry_name.is_ascii() {
            0
        } else {
            FLAG_UTF8
        };
        let dos_bits = dos_datetime_bits(entry.last_modified_ms);
        let name_bytes = entry.entry_name.as_bytes();
        let name_len = name_bytes.len() as u16;
        let local_offset = offset;

        let header = local_header(
            flags,
            dos_bits,
            entry.crc32,
            entry.size_bytes as u32,
            name_len,
        );
        writer.write_all(&header)?;
        writer.write_all(name_bytes)?;
        offset += header.len() as u32 + name_len as u32;

        // 单遍读出：CRC 与大小来自起服预计算，下载阶段仅顺序读一次并校验一致性
        let mut source = open_source(entry)?;
        let mut entry_total: u64 = 0;
        loop {
            let read = source
                .read(&mut buffer)
                .map_err(|e| anyhow::anyhow!("读取待发送文件失败 {}: {e}", entry.entry_name))?;
            if read == 0 {
                break;
            }
            entry_total += read as u64;
            writer.write_all(&buffer[..read])?;
            offset += read as u32;
            total_source += read as u64;
            on_source_bytes(total_source);
        }
        if entry_total != entry.size_bytes {
            anyhow::bail!(
                "条目数据与声明大小不一致 {} 实际={} 声明={}",
                entry.entry_name,
                entry_total,
                entry.size_bytes
            );
        }
        let size32 = entry.size_bytes as u32;

        records.push(CentralRecord {
            name: entry.entry_name.clone(),
            flags,
            dos_bits,
            crc: entry.crc32,
            size: size32,
            local_offset,
        });
        log::debug!(
            "MTA 流式写出条目 entry={} 源字节={} 累计源字节={}",
            entry.entry_name,
            entry_total,
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
    use std::os::fd::IntoRawFd;

    /// 构造独立临时目录。
    fn temp_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("mta_zip_stream_{tag}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// 计算数据的 CRC32（与起服预计算同算法）。
    fn crc32_of(data: &[u8]) -> u32 {
        let mut hasher = crc32fast::Hasher::new();
        hasher.update(data);
        hasher.finalize()
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
        let crc_a = crc32_of(b"hello mta");
        let crc_b = crc32_of(b"second file");

        let files = vec![
            MtaFileEntry {
                fd_crc: -1,
                fd_send: -1,
                path: a_path.to_string_lossy().to_string(),
                entry_name: "1/a.txt".into(),
                last_modified_ms: None,
                crc32: crc_a,
                size_bytes: 9,
            },
            MtaFileEntry {
                fd_crc: -1,
                fd_send: -1,
                path: b_path.to_string_lossy().to_string(),
                entry_name: "2/b.txt".into(),
                last_modified_ms: Some(1_600_000_000_000),
                crc32: crc_b,
                size_bytes: 11,
            },
        ];
        let mut out: Vec<u8> = Vec::new();
        let result = write_zip_stream(&mut out, &files, |_| {}).unwrap();
        assert_eq!(result.entry_count, 2);
        assert_eq!(result.total_size, 9 + 11);
        assert_eq!(&out[0..4], b"PK\x03\x04");

        // 本地头：method=0（Stored）、无描述符标志、真实 CRC/大小（压缩后大小==原始大小）
        assert_eq!(u16::from_le_bytes([out[8], out[9]]), METHOD_STORED);
        assert_eq!(u16::from_le_bytes([out[6], out[7]]), 0);
        assert_eq!(
            u32::from_le_bytes([out[14], out[15], out[16], out[17]]),
            crc_a
        );
        assert_eq!(u32::from_le_bytes([out[18], out[19], out[20], out[21]]), 9);
        assert_eq!(u32::from_le_bytes([out[22], out[23], out[24], out[25]]), 9);

        // 条目 1 布局：本地头(30) + 文件名(7) + 数据(9)，无描述符字节；
        // 条目 2 本地头紧随其后，条目 2 数据在 46 + 30 + 7 处
        let entry2_data_at = 30 + 7 + 9 + 30 + 7;
        assert_eq!(&out[entry2_data_at..entry2_data_at + 4], b"seco");
        // 产物中不含数据描述符签名
        assert!(!out.windows(4).any(|w| w == b"PK\x07\x08"));

        // 中央目录写真实 CRC/大小、method=0，偏移链无描述符
        let cd_at = entry2_data_at + 11;
        assert_eq!(&out[cd_at..cd_at + 4], b"PK\x01\x02");
        assert_eq!(
            u16::from_le_bytes([out[cd_at + 10], out[cd_at + 11]]),
            METHOD_STORED
        );
        assert_eq!(
            u32::from_le_bytes([
                out[cd_at + 16],
                out[cd_at + 17],
                out[cd_at + 18],
                out[cd_at + 19]
            ]),
            crc_a
        );
        assert_eq!(
            u32::from_le_bytes([
                out[cd_at + 20],
                out[cd_at + 21],
                out[cd_at + 22],
                out[cd_at + 23]
            ]),
            9
        );
        assert_eq!(
            u32::from_le_bytes([
                out[cd_at + 24],
                out[cd_at + 25],
                out[cd_at + 26],
                out[cd_at + 27]
            ]),
            9
        );
        // 产物总长度：条目区（30+7+9 与 30+7+11）+ 中央目录(2×(46+7)) + EOCD(22)
        assert_eq!(out.len(), cd_at + (46 + 7) * 2 + 22);

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
    fn write_stream_reads_from_fd_and_closes_it() {
        let dir = temp_dir("fd");
        let a_path = dir.join("a.bin");
        let payload = vec![0x5au8; 1024 * 300];
        std::fs::write(&a_path, &payload).unwrap();
        let crc = crc32_of(&payload);

        // 模拟 ArkTS 直传 fd：打开后移交所有权（fd_send）
        let file = File::open(&a_path).unwrap();
        let fd_send = file.into_raw_fd();

        let files = vec![MtaFileEntry {
            fd_crc: -1,
            fd_send,
            path: String::new(),
            entry_name: "1/a.bin".into(),
            last_modified_ms: None,
            crc32: crc,
            size_bytes: payload.len() as u64,
        }];
        let mut out: Vec<u8> = Vec::new();
        let result = write_zip_stream(&mut out, &files, |_| {}).unwrap();
        assert_eq!(result.total_size, payload.len() as u64);

        // 产物可由标准读取器解出，内容一致
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(out)).unwrap();
        let mut entry = archive.by_index(0).unwrap();
        let mut content = Vec::new();
        use std::io::Read as _;
        entry.read_to_end(&mut content).unwrap();
        assert_eq!(content, payload);

        // fd 已被消费关闭：再次打开同路径仍可（避免断言操作系统行为，仅确认可重新打开）
        File::open(&a_path).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_stream_reports_source_progress() {
        let dir = temp_dir("progress");
        let a_path = dir.join("a.bin");
        let payload = vec![7u8; 1024 * 300];
        std::fs::write(&a_path, &payload).unwrap();
        let crc = crc32_of(&payload);
        let files = vec![MtaFileEntry {
            fd_crc: -1,
            fd_send: -1,
            path: a_path.to_string_lossy().to_string(),
            entry_name: "1/a.bin".into(),
            last_modified_ms: None,
            crc32: crc,
            size_bytes: payload.len() as u64,
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
    fn write_stream_zero_byte_entry() {
        let dir = temp_dir("empty");
        let empty_path = dir.join("empty.bin");
        std::fs::write(&empty_path, b"").unwrap();
        let files = vec![MtaFileEntry {
            fd_crc: -1,
            fd_send: -1,
            path: empty_path.to_string_lossy().to_string(),
            entry_name: "1/empty.bin".into(),
            last_modified_ms: None,
            crc32: 0,
            size_bytes: 0,
        }];
        let mut out: Vec<u8> = Vec::new();
        let result = write_zip_stream(&mut out, &files, |_| {}).unwrap();
        assert_eq!(result.total_size, 0);
        assert_eq!(result.entry_count, 1);

        // 本地头 method=0、CRC/大小全 0、无描述符
        assert_eq!(u16::from_le_bytes([out[8], out[9]]), METHOD_STORED);
        assert_eq!(u16::from_le_bytes([out[6], out[7]]), 0);
        assert_eq!(&out[14..26], &[0u8; 12]);
        assert!(!out.windows(4).any(|w| w == b"PK\x07\x08"));

        // 可被标准 seek 读取器读回，内容为空
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(out)).unwrap();
        assert_eq!(archive.len(), 1);
        let mut entry = archive.by_index(0).unwrap();
        assert_eq!(entry.name(), "1/empty.bin");
        let mut content = Vec::new();
        use std::io::Read as _;
        entry.read_to_end(&mut content).unwrap();
        assert!(content.is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_stream_size_mismatch_errors() {
        let dir = temp_dir("mismatch");
        let a_path = dir.join("a.bin");
        std::fs::write(&a_path, b"0123456789").unwrap();
        let files = vec![MtaFileEntry {
            fd_crc: -1,
            fd_send: -1,
            path: a_path.to_string_lossy().to_string(),
            entry_name: "1/a.bin".into(),
            last_modified_ms: None,
            crc32: crc32_of(b"0123456789"),
            size_bytes: 5, // 声明大小与实际不符
        }];
        let mut out: Vec<u8> = Vec::new();
        assert!(write_zip_stream(&mut out, &files, |_| {}).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_stream_missing_source_errors() {
        let files = vec![MtaFileEntry {
            fd_crc: -1,
            fd_send: -1,
            path: "/nonexistent/mta-file".into(),
            entry_name: "1/x".into(),
            last_modified_ms: None,
            crc32: 0,
            size_bytes: 1,
        }];
        let mut out: Vec<u8> = Vec::new();
        assert!(write_zip_stream(&mut out, &files, |_| {}).is_err());
    }
}
