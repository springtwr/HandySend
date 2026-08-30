#!/usr/bin/env bash
# napi-bridge-guard.sh — 校验 NAPI 函数封装完整性
#
# 从 index.d.ts 提取所有导出函数名，减去"有意不封装"白名单，
# 再与 NativeBridge.ets 的 import 列表做差集。差集非空则报错。
#
# 使用方式：
#   ./scripts/napi-bridge-guard.sh           # 默认从项目根目录推断路径
#   ./scripts/napi-bridge-guard.sh /path/to/project
#
# 退出码：0=通过 1=有未封装函数 2=脚本错误

set -euo pipefail

PROJECT_ROOT="${1:-.}"

# 关键文件路径（相对于项目根）
INDEX_DTS="localsend_ohrs/package/src/main/cpp/types/liblocalsend_core/index.d.ts"
NATIVE_BRIDGE="entry/src/main/ets/service/NativeBridge.ets"

# ── 有意不封装的白名单 ──────────────────────────────────────────────────
# 这些 NAPI 函数在 index.d.ts 中导出，但 NativeBridge.ets 有意不封装：
#   - init:          应用初始化由 AppService 内部编排，不走 NativeBridge 封装层
#   - startServer:   低级 API，已被 createServer（高级 API）替代
#   - prepareSend:   低级 API，已被 sendFiles（高级 API）替代
#   - getLocalAddresses: 已被 getNetworkInterfaces（结构化信息）替代
# 新增 NAPI 函数时：要么在 NativeBridge.ets 添加封装，要么在此白名单中添加理由
INTENTIONAL_SKIP=(
  init
  startServer
  prepareSend
  getLocalAddresses
)

# ── 辅助函数 ──────────────────────────────────────────────────────────────

# 从 index.d.ts 提取 export declare function 名称
extract_dts_functions() {
  local dts="$1"
  if [[ ! -f "$dts" ]]; then
    echo "[napi-guard] 错误: $dts 不存在" >&2
    return 1
  fi
  # 匹配 "export declare function functionName"
  grep -oP '^export declare function \K\w+' "$dts" | sort -u
}

# 从 NativeBridge.ets 提取 from 'localsend_ohrs' 导入的标识符
# 包括 as 别名形式（如 registerEventListener as nativeRegisterEventListener）
# 提取原始名称（as 左侧），用于与 index.d.ts 函数名比对
extract_bridge_imports() {
  local bridge="$1"
  if [[ ! -f "$bridge" ]]; then
    echo "[napi-guard] 错误: $bridge 不存在" >&2
    return 1
  fi
  # 策略：从 import { 到 } from 'localsend_ohrs' 之间提取标识符
  # 每行格式：  identifier, 或   identifier as alias, 或   Identifier（类型）
  # 提取 as 左侧的原始名称（去掉逗号、空白、as 部分）
  awk "
    /from 'localsend_ohrs'/ { in_block=0 }
    in_block && /^[[:space:]]*[a-zA-Z]/ {
      gsub(/^[[:space:]]+/, \"\")
      gsub(/,.*$/, \"\")
      # 取 as 左侧（原始名称）
      if (\$0 ~ / as /) {
        split(\$0, parts, / as /)
        print parts[1]
      } else {
        print \$0
      }
    }
    /import \{/ { in_block=1 }
  " "$bridge" | sort -u
}

# ── 主逻辑 ────────────────────────────────────────────────────────────────

dts_path="$PROJECT_ROOT/$INDEX_DTS"
bridge_path="$PROJECT_ROOT/$NATIVE_BRIDGE"

# 提取函数列表
dts_functions=$(extract_dts_functions "$dts_path") || exit 2
bridge_imports=$(extract_bridge_imports "$bridge_path") || exit 2

# 构建白名单文件用于 comm
whitelist_file=$(mktemp)
printf '%s\n' "${INTENTIONAL_SKIP[@]}" | sort -u > "$whitelist_file"

# 差集：dts_functions - bridge_imports - whitelist = 未封装函数
unwrapped=$(comm -23 <(echo "$dts_functions") <(echo "$bridge_imports") | \
            comm -23 - "$whitelist_file")

rm -f "$whitelist_file"

if [[ -z "$unwrapped" ]]; then
  echo "[napi-guard] ✅ 所有 NAPI 函数均已封装（或已加入白名单）"
  exit 0
fi

echo "[napi-guard] ❌ 以下 NAPI 函数未在 NativeBridge.ets 中封装：" >&2
echo "$unwrapped" | while read -r fn; do
  echo "  - $fn" >&2
done
echo "" >&2
echo "请在 NativeBridge.ets 添加封装，或在 scripts/napi-bridge-guard.sh 的 INTENTIONAL_SKIP 白名单中添加并注明理由" >&2
exit 1
