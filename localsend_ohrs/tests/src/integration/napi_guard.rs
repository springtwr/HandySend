//! NAPI 封装完整性校验（跨平台 guard）。
//!
//! Rust 集成测试，`cargo test` 在 Windows/Mac/Linux 上统一执行。
//!
//! 校验逻辑：NAPI 导出面中每个函数都必须在 NativeBridge.ets 的
//! `import { ... } from 'localsend_ohrs'` 块中被封装。差集非空则失败。
//!
//! 导出面来源按优先级取其一：
//! 1. index.d.ts（napi 构建产物，pre-commit 本地场景必然存在）
//! 2. rust/napi/ 源码中的 `#[napi]` 函数名（CI 未执行 napi 构建时的
//!    回退；napi-rs 默认将 snake_case 转为 camelCase）
//!
//! 原则：NAPI 层只导出 ArkTS 实际使用的函数，不存在"导出了但故意不
//! 封装"的情形。若某个 NAPI 函数 ArkTS 不需要，应删除该 `#[napi]`
//! 导出（而非豁免）。

use localsend_core::bridge::event::EVENT_PAYLOAD_CONTRACT;
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

/// rust/napi/ 源码目录（index.d.ts 缺失时的回退数据源）。
fn napi_source_dir() -> PathBuf {
    tests_root().join("../rust/napi")
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

/// snake_case → camelCase（napi-rs 默认命名转换，如 send_files → sendFiles）。
fn snake_to_camel(name: &str) -> String {
    let mut result = String::with_capacity(name.len());
    let mut upper_next = false;
    for c in name.chars() {
        if c == '_' {
            upper_next = true;
        } else if upper_next {
            result.extend(c.to_uppercase());
            upper_next = false;
        } else {
            result.push(c);
        }
    }
    result
}

/// 从 rust/napi/ 源码提取 `#[napi]` 标注的函数名（转 camelCase）。
/// 仅识别裸 `#[napi]`（无 js_name 自定义名），`#[napi(object)]` 为类型
/// 导出、不含函数，跳过。
fn extract_napi_source_functions() -> Vec<String> {
    let dir = napi_source_dir();
    let mut files: Vec<PathBuf> = fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("读取 napi 源码目录失败 {}: {}", dir.display(), e))
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|ext| ext == "rs"))
        .collect();
    files.sort();

    let mut result = Vec::new();
    for path in files {
        let content = fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("读取 {} 失败: {}", path.display(), e));
        let lines: Vec<&str> = content.lines().collect();
        for (i, line) in lines.iter().enumerate() {
            if line.trim() == "#[napi]" {
                // 跳过紧随的其他属性行（如 #[allow(...)]）定位 fn 定义
                let fn_line = lines[i + 1..]
                    .iter()
                    .map(|l| l.trim())
                    .find(|l| !l.starts_with("#["));
                let next = fn_line.unwrap_or("");
                // 形如 `pub fn name(...)` 或 `pub async fn name(...)`
                let rest = next
                    .strip_prefix("pub async fn")
                    .or_else(|| next.strip_prefix("pub fn"))
                    .map(str::trim_start);
                if let Some(rest) = rest {
                    let name: String = rest
                        .chars()
                        .take_while(|c| c.is_alphanumeric() || *c == '_')
                        .collect();
                    if !name.is_empty() {
                        result.push(snake_to_camel(&name));
                    }
                }
            }
        }
    }
    result
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
    // 导出面来源：优先 index.d.ts（构建产物）；缺失时回退解析 rust/napi/
    // 源码的 #[napi] 函数名（CI 未执行 napi 构建的场景），保证校验恒执行
    let (napi_functions, source) = match fs::read_to_string(index_dts_path()) {
        Ok(content) => (extract_dts_functions(&content), "index.d.ts"),
        Err(_) => (
            extract_napi_source_functions(),
            "rust/napi/ 源码（index.d.ts 不存在，回退解析）",
        ),
    };
    assert!(
        !napi_functions.is_empty(),
        "NAPI 导出面为空——index.d.ts 与 rust/napi/ 源码均未提供函数"
    );

    let bridge_path = native_bridge_path();
    assert!(
        bridge_path.exists(),
        "NativeBridge.ets 不存在: {}",
        bridge_path.display()
    );
    let bridge_content = fs::read_to_string(&bridge_path).expect("读取 NativeBridge.ets 失败");

    let napi_functions: std::collections::BTreeSet<String> = napi_functions.into_iter().collect();
    let bridge_imports: std::collections::BTreeSet<String> =
        extract_bridge_imports(&bridge_content)
            .into_iter()
            .collect();

    // 差集：NAPI 导出但 NativeBridge 未封装
    let unwrapped: Vec<&String> = napi_functions.difference(&bridge_imports).collect();

    if unwrapped.is_empty() {
        eprintln!(
            "[napi-guard] ✅ 所有 {} 个 NAPI 函数均已封装（来源：{}）",
            napi_functions.len(),
            source
        );
        return;
    }

    // 详细列出未封装函数
    let missing: Vec<String> = unwrapped.iter().map(|s| s.to_string()).collect();
    panic!(
        "[napi-guard] ❌ 以下 NAPI 函数未在 NativeBridge.ets 中封装（来源：{}）: {:?}\n\
         请在 NativeBridge.ets 添加封装；若该函数 ArkTS 不需要，请在 Rust NAPI 层删除其 #[napi] 导出（不要用豁免）",
        source, missing
    );
}

// ── 跨层事件 JSON 契约（双端防漂移）───────────────────────────────────
//
// 契约表为 `bridge/event.rs::EVENT_PAYLOAD_CONTRACT`（单一事实源）：
// - Rust 侧契约测试：钉死 BridgeEvent 序列化的 tag 与 payload 字段集合
// - 本测试：钉死 NativeTypes.ets::parseNativeEvent 各 case 分支解析的字段
// 任一端改动字段名/tag（未同步对端）都会被拦截。
//
// serverStopped / mtaWsConnected 为 unit variant（serde internally-tagged
// 不产生 payload），ArkTS 分支同样不访问 payload，契约字段为空集合。

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
        // unit variant（None）无 payload，期望为空集合
        let expected: BTreeSet<String> = expected_fields
            .unwrap_or(&[])
            .iter()
            .map(|s| s.to_string())
            .collect();
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
    fn converts_snake_to_camel() {
        assert_eq!(snake_to_camel("send_files"), "sendFiles");
        assert_eq!(
            snake_to_camel("native_flush_rust_logs"),
            "nativeFlushRustLogs"
        );
        assert_eq!(snake_to_camel("init"), "init");
        // 前导/连续下划线：转大写（保守行为，当前代码库无此类函数名）
        assert_eq!(snake_to_camel("_a"), "A");
    }

    /// 回退解析器必须能从真实 rust/napi/ 源码解析出非空函数集合；
    /// 本地存在 index.d.ts 时，两个来源的函数集合必须一致。
    #[test]
    fn source_fallback_extracts_real_napi_functions() {
        let src: BTreeSet<String> = extract_napi_source_functions().into_iter().collect();
        assert!(
            !src.is_empty(),
            "rust/napi/ 源码未解析出任何 #[napi] 函数——回退解析器失效"
        );
        if let Ok(content) = fs::read_to_string(index_dts_path()) {
            let dts: BTreeSet<String> = extract_dts_functions(&content).into_iter().collect();
            assert_eq!(
                dts, src,
                "index.d.ts 与 rust/napi/ 源码的函数集合不一致——两个来源漂移"
            );
        }
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
