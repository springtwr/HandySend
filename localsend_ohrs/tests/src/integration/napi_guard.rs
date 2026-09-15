//! NAPI 封装完整性校验（跨平台 guard）。
//!
//! Rust 集成测试，`cargo test` 在 Windows/Mac/Linux 上统一执行。
//!
//! 校验逻辑：index.d.ts（NAPI 导出面）中每个 `export declare function`
//! 都必须在 NativeBridge.ets 的 `import { ... } from 'localsend_ohrs'`
//! 块中被封装。差集非空则失败。
//!
//! 原则：NAPI 层只导出 ArkTS 实际使用的函数，不存在"导出了但故意不
//! 封装"的情形。若某个 NAPI 函数 ArkTS 不需要，应删除该 `#[napi]`
//! 导出（而非豁免）。
//!
//! 注意：index.d.ts 是构建产物（napi 生成），未执行过构建时不存在，
//! 此时测试跳过（pre-commit 场景文件必然存在）。

use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::PathBuf;

/// tests crate 根目录（localsend_ohrs/tests/）。
fn tests_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// index.d.ts 路径（相对 tests/ 为 ../package/...）。
fn index_dts_path() -> PathBuf {
    tests_root().join("../package/src/main/cpp/types/liblocalsend_core/index.d.ts")
}

/// NativeBridge.ets 路径（相对 tests/ 为 ../../entry/...）。
fn native_bridge_path() -> PathBuf {
    tests_root().join("../../entry/src/main/ets/service/NativeBridge.ets")
}

/// NativeTypes.ets 路径（相对 tests/ 为 ../../entry/...）。
fn native_types_path() -> PathBuf {
    tests_root().join("../../entry/src/main/ets/model/NativeTypes.ets")
}

/// 从 index.d.ts 提取所有 `export declare function <name>`。
fn extract_dts_functions(content: &str) -> Vec<String> {
    content
        .lines()
        .filter_map(|line| {
            let line = line.trim_start();
            line.strip_prefix("export declare function").map(|rest| {
                rest.trim_start()
                    .split(|c: char| !c.is_alphanumeric() && c != '_')
                    .next()
                    .unwrap_or("")
                    .to_string()
            })
        })
        .filter(|s| !s.is_empty())
        .collect()
}

/// 从 NativeBridge.ets 提取 `import { ... } from 'localsend_ohrs'` 块中的标识符。
/// 处理 as 别名（取左侧原始名）、类型导入（保留，供差集比较时被过滤）。
fn extract_bridge_imports(content: &str) -> Vec<String> {
    let mut in_block = false;
    let mut result: Vec<String> = Vec::new();
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("import {") {
            in_block = true;
            continue;
        }
        if !in_block {
            continue;
        }
        // 遇到 `} from 'localsend_ohrs'` 结束块
        if trimmed.starts_with("} from") {
            if trimmed.contains("localsend_ohrs") {
                break;
            }
            continue;
        }
        // 跳过空行/注释
        if trimmed.is_empty() || trimmed.starts_with("//") || trimmed.starts_with("/*") {
            continue;
        }
        // 提取标识符（as 左侧）
        let ident = trimmed
            .split(',')
            .next()
            .unwrap_or("")
            .trim()
            .split(" as ")
            .next()
            .unwrap_or("")
            .trim();
        if !ident.is_empty() {
            result.push(ident.to_string());
        }
    }
    result
}

#[test]
fn test_all_napi_functions_are_wrapped_in_native_bridge() {
    // index.d.ts 是构建产物——未构建时跳过（pre-commit 场景必然存在）
    let dts_path = index_dts_path();
    if !dts_path.exists() {
        eprintln!(
            "[napi-guard] 跳过：index.d.ts 不存在（未执行构建）: {}",
            dts_path.display()
        );
        return;
    }

    let bridge_path = native_bridge_path();
    assert!(
        bridge_path.exists(),
        "NativeBridge.ets 不存在: {}",
        bridge_path.display()
    );

    let dts_content = fs::read_to_string(&dts_path).expect("读取 index.d.ts 失败");
    let bridge_content = fs::read_to_string(&bridge_path).expect("读取 NativeBridge.ets 失败");

    let dts_functions: std::collections::BTreeSet<String> =
        extract_dts_functions(&dts_content).into_iter().collect();
    let bridge_imports: std::collections::BTreeSet<String> =
        extract_bridge_imports(&bridge_content)
            .into_iter()
            .collect();

    // 差集：dts 导出但 NativeBridge 未封装
    let unwrapped: Vec<&String> = dts_functions.difference(&bridge_imports).collect();

    if unwrapped.is_empty() {
        eprintln!(
            "[napi-guard] ✅ 所有 {} 个 NAPI 函数均已封装",
            dts_functions.len()
        );
        return;
    }

    // 详细列出未封装函数
    let missing: Vec<String> = unwrapped.iter().map(|s| s.to_string()).collect();
    panic!(
        "[napi-guard] ❌ 以下 NAPI 函数未在 NativeBridge.ets 中封装: {:?}\n\
         请在 NativeBridge.ets 添加封装；若该函数 ArkTS 不需要，请在 Rust NAPI 层删除其 #[napi] 导出（不要用豁免）",
        missing
    );
}

// ── 跨层事件 JSON 契约（双端防漂移）───────────────────────────────────
//
// 与 `bridge/event.rs::test_all_event_variants_payload_contract` 的契约表
// 保持同步（同一份期望，两个校验点）：
// - Rust 侧契约测试：钉死 BridgeEvent 序列化的 tag 与 payload 字段集合
// - 本测试：钉死 NativeTypes.ets::parseNativeEvent 各 case 分支解析的字段
// 任一端改动字段名/tag（未同步对端）都会被拦截。
//
// serverStopped 为 unit variant（serde internally-tagged 不产生 payload），
// ArkTS 分支同样不访问 payload，契约字段为空集合。

/// 事件类型 → payload 字段集合（camelCase，与 Rust BridgeEvent 序列化一致）。
const EVENT_PAYLOAD_CONTRACT: &[(&str, &[&str])] = &[
    ("serverStarted", &["port"]),
    ("serverStopped", &[]),
    ("register", &["ip", "info"]),
    (
        "prepareUpload",
        &[
            "sessionId",
            "senderIp",
            "senderAlias",
            "senderFingerprint",
            "senderDeviceType",
            "senderDeviceModel",
            "certFingerprint",
            "files",
        ],
    ),
    ("prepareUploadAborted", &["sessionId"]),
    ("cancelReceived", &["ip", "sessionId"]),
    (
        "uploadProgress",
        &["sessionId", "fileId", "direction", "progress", "speed"],
    ),
    ("sessionEnd", &["sessionId", "reason"]),
    ("fileUpload", &["sessionId", "fileId", "fileName", "size"]),
    ("deviceFound", &["device"]),
    ("deviceLost", &["fingerprint"]),
    ("webSendPrepareDownload", &["sessionId", "ip", "userAgent"]),
    (
        "webSendFileDownload",
        &["sessionId", "fileId", "fileName", "size"],
    ),
    ("webSendSessionEnd", &["sessionId"]),
    ("mtaServerStarted", &["port"]),
    ("mtaWsConnected", &[]),
    ("mtaVersionNegotiated", &["version"]),
    ("mtaSendRequestSent", &["taskId"]),
    ("mtaDownloadStarted", &["taskId"]),
    (
        "mtaSendProgress",
        &["sentBytes", "totalBytes", "percent", "networkBytes"],
    ),
    (
        "mtaReceiveProgress",
        &[
            "receivedBytes",
            "totalBytes",
            "percent",
            "networkBytes",
            "networkDone",
        ],
    ),
    ("mtaSendCompleted", &["taskId"]),
    ("mtaSendPartial", &["reason"]),
    ("mtaSendRejected", &["reason"]),
    ("mtaSendFailed", &["reason"]),
    ("error", &["context", "message"]),
];

/// 从文本中提取所有 `payload['<key>']` 形式的字段名。
fn extract_payload_keys(text: &str) -> BTreeSet<String> {
    let mut keys = BTreeSet::new();
    let mut rest = text;
    while let Some(pos) = rest.find("payload['") {
        let after = &rest[pos + "payload['".len()..];
        match after.find("']") {
            Some(end) => {
                keys.insert(after[..end].to_string());
                rest = &after[end + 2..];
            }
            None => break,
        }
    }
    keys
}

/// 解析 NativeTypes.ets：提取 parseNativeEvent 各 case 分支读取的 payload 字段。
///
/// 分支文本为 `case '<type>':` 到下一个 `case`/`default:` 之间；
/// prepareUpload 分支委托给 parsePrepareUploadEvent，需合并其函数体内的
/// payload 字段。
fn extract_native_types_case_fields(content: &str) -> HashMap<String, BTreeSet<String>> {
    let mut result: HashMap<String, BTreeSet<String>> = HashMap::new();

    let fn_start = content
        .find("function parseNativeEvent")
        .expect("NativeTypes.ets 未找到 parseNativeEvent");
    let body = &content[fn_start..];
    let switch_start = body
        .find("switch (t) {")
        .map(|p| p + "switch (t) {".len())
        .expect("parseNativeEvent 未找到 switch");
    // switch 结束：parseNativeEvent 函数体末尾（下一个顶层函数定义或文件尾）
    let body_end = body.find("\nfunction ").unwrap_or(body.len());
    let switch_body = &body[switch_start..body_end];

    let mut current: Option<String> = None;
    let mut current_text = String::new();
    for line in switch_body.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("case '") {
            if let Some(prev) = current.take() {
                result.insert(prev, extract_payload_keys(&current_text));
            }
            let type_name = rest.split("':").next().unwrap_or("").to_string();
            current = Some(type_name);
            current_text = String::new();
        } else if trimmed.starts_with("default:") {
            break;
        }
        if current.is_some() {
            current_text.push_str(trimmed);
            current_text.push('\n');
        }
    }
    if let Some(prev) = current.take() {
        result.insert(prev, extract_payload_keys(&current_text));
    }

    // prepareUpload 分支委托 parsePrepareUploadEvent——合并其 payload 字段
    if let Some(fields) = result.get_mut("prepareUpload") {
        if let Some(pp_start) = content.find("function parsePrepareUploadEvent") {
            let pp = &content[pp_start..];
            let pp_end = pp.find("\nfunction ").unwrap_or(pp.len());
            fields.extend(extract_payload_keys(&pp[..pp_end]));
        }
    }

    result
}

/// 校验 NativeTypes.ets::parseNativeEvent 各分支的 payload 字段与 Rust
/// BridgeEvent 序列化契约一致（双向：缺少分支或多出分支均报错）。
#[test]
fn test_native_types_parse_fields_match_event_contract() {
    let types_path = native_types_path();
    assert!(
        types_path.exists(),
        "NativeTypes.ets 不存在: {}",
        types_path.display()
    );
    let content = fs::read_to_string(&types_path).expect("读取 NativeTypes.ets 失败");
    let actual = extract_native_types_case_fields(&content);

    for (type_name, expected_fields) in EVENT_PAYLOAD_CONTRACT {
        let expected: BTreeSet<String> = expected_fields.iter().map(|s| s.to_string()).collect();
        match actual.get(*type_name) {
            Some(fields) => assert_eq!(
                fields, &expected,
                "parseNativeEvent 分支 '{type_name}' 的 payload 字段与 Rust BridgeEvent 契约不一致\n\
                 改字段名需同步 event.rs（rename_all_fields）与 NativeTypes.ets"
            ),
            None => panic!("parseNativeEvent 缺少 case 分支: {type_name}"),
        }
    }
    // 反向校验：ArkTS 解析了 Rust 没有的事件分支
    for type_name in actual.keys() {
        assert!(
            EVENT_PAYLOAD_CONTRACT.iter().any(|(t, _)| t == type_name),
            "parseNativeEvent 存在 Rust BridgeEvent 没有的事件分支: {type_name}"
        );
    }
}

/// 解析器单元测试——防止对文件格式的假设回归。
#[cfg(test)]
mod parser_tests {
    use super::*;

    #[test]
    fn parses_dts_function_names() {
        let content = "/* header */\nexport declare function init(a: string): void\nexport declare function sendFiles(x: number): string\n";
        let funcs = extract_dts_functions(content);
        assert_eq!(funcs, vec!["init".to_string(), "sendFiles".to_string()]);
    }

    #[test]
    fn parses_first_import_block_only() {
        let content = "\
import {
  init,
  sendFiles as nativeSendFiles,
  ServerStatus
} from 'localsend_ohrs';

import { NativeServerConfig } from '../model/NativeTypes';
";
        let imports = extract_bridge_imports(content);
        assert_eq!(
            imports,
            vec![
                "init".to_string(),
                "sendFiles".to_string(),
                "ServerStatus".to_string()
            ]
        );
    }

    #[test]
    fn handles_missing_as_alias() {
        let content = "import {\n  plainName,\n  withAlias as wa\n} from 'localsend_ohrs';";
        let imports = extract_bridge_imports(content);
        assert_eq!(
            imports,
            vec!["plainName".to_string(), "withAlias".to_string()]
        );
    }
}
