#!/usr/bin/env bash
#
# setup-worktree.sh —— 为新创建的 git worktree 补齐本地（不入库）配置
#
# 背景：这几个文件/目录没有入库，原因分两类：
#       · 含本机路径、签名或密钥，每人各不相同：build-profile.json5、.env
#       · 只有部分人使用，不是项目必需：.opencode（OpenCode 的 MCP 配置）、
#         .codegraph（索引数据）、codegraph.json（索引排除规则）
#       `git worktree add` 出来的新工作树只有仓库内容，不会有它们，本脚本负责补齐。
#
# 做的事：
#   1. 复制主工作树根目录的 build-profile.json5 到目标 worktree 根目录
#      （该文件含本地签名/路径信息，已在 .gitignore 中忽略，IDE 构建需要它）
#   2. 将主工作树的 .env 软链接到目标 worktree 根目录
#   3. 复制主工作树的 .opencode 目录到目标 worktree 根目录（可选，见下）
#      （内容基本是固定的 MCP 配置，很少改动，复制比软链接省事：
#       .gitignore 里的 `.opencode/` 只匹配真实目录，软链接会被 git 当成未跟踪变化）
#   4. 若主工作树有 codegraph.json（索引排除配置），一并复制
#   5. 在目标 worktree 中执行 `codegraph init`，建好独立的索引（可用 -s 跳过）
#      （.codegraph/ 是每台机器/每个工作树各自的本地数据，不能共享）
#
# 谁需要执行：
#   - 只是 clone 或切分支开发：不需要，本脚本不执行就对仓库没有任何影响
#   - 用 git worktree 且需要 IDE 构建：执行（至少需要 build-profile.json5）
#   - 不用 OpenCode：主工作树里没有 .opencode 时会自动跳过，无需额外参数
#   - 不用 codegraph：加 -s 跳过索引；本机没装 codegraph 时脚本也只告警并继续
#   - 本脚本只补齐"本机已有"的东西，不会替任何人创建 OpenCode / codegraph 配置
#
# 用法：
#   tools/setup-worktree.sh <worktree 路径> [-f|--force] [-s|--skip-codegraph] [-n|--dry-run]
#
# 位置：
#   tools/setup-worktree.sh，随仓库同步；脚本本身不修改仓库内容，只写目标 worktree。
#
# 说明：
#   - 脚本可在主工作树或任意 worktree 中运行；主工作树根目录通过
#     `git rev-parse --git-common-dir` 解析，因此不依赖当前工作目录。
#   - 已存在且内容一致的 build-profile.json5 / .opencode / codegraph.json 会被跳过。
#   - 已存在但内容不同的文件或目录默认不覆盖，加 --force 才覆盖。
#   - 旧版本脚本留下的 .opencode 软链接会被自动替换为真实目录（仅此一处例外）。
#   - 对已存在的 .env“真实文件”（非软链接）不删除、不覆盖，
#     避免误删实际内容；请手动处理后重跑。
#   - codegraph init 较慢（本仓库索引约 150MB）；索引失败只告警不中断，可手动重跑。
#   - codegraph 正常在 PATH 上（~/.local/bin 或 mise shims），但脚本可能被 IDE /
#     非交互 shell 调起，因此仍按 CODEGRAPH_BIN → PATH → mise shims → ~/.local/bin →
#     系统目录 的顺序探测；也可用 CODEGRAPH_BIN=/path/to/codegraph 显式指定。
#   - --dry-run（-n）只打印将要执行的操作，不写入任何文件，可用于改脚本后自测。
#
set -euo pipefail

FORCE=0
SKIP_CODEGRAPH=0
DRY_RUN=0
TARGET=""

usage() {
  cat <<'EOF'
用法: tools/setup-worktree.sh <worktree 路径> [选项]

选项:
  -f, --force          覆盖已存在但内容不同的 build-profile.json5 / .opencode
  -s, --skip-codegraph 跳过 codegraph init（不用 codegraph 或想稍后建索引时用）
  -n, --dry-run        只打印将要执行的操作，不写入任何文件
  -h, --help           显示本帮助

示例:
  tools/setup-worktree.sh ../HandySend-worktrees/dev
  tools/setup-worktree.sh -s ../HandySend-worktrees/dev        # 不建 codegraph 索引
  tools/setup-worktree.sh -n ../HandySend-worktrees/dev        # 预演
EOF
}

die() {
  printf '错误: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf '警告: %s\n' "$*" >&2
}

info() {
  printf '%s\n' "$*"
}

# ---------- 参数解析 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--force)
      FORCE=1
      shift
      ;;
    -s|--skip-codegraph)
      SKIP_CODEGRAPH=1
      shift
      ;;
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "未知选项: $1（用 --help 查看用法）"
      ;;
    *)
      if [ -n "$TARGET" ]; then
        die "只接受一个路径参数，多余的参数: $1"
      fi
      TARGET=$1
      shift
      ;;
  esac
done

if [ -z "$TARGET" ]; then
  usage >&2
  exit 2
fi

# ---------- 定位源（主工作树）与目标 ----------
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

COMMON_GIT_DIR=$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
if [ -n "$COMMON_GIT_DIR" ] && [ -d "$COMMON_GIT_DIR" ]; then
  SRC_ROOT=$(dirname -- "$COMMON_GIT_DIR")
else
  # 回退：从脚本所在目录向上找含 .git 的目录（脚本可能位于仓库的深层目录）
  SRC_ROOT=""
  probe=$SCRIPT_DIR
  while [ "$probe" != "/" ]; do
    if [ -e "$probe/.git" ]; then
      SRC_ROOT=$probe
      break
    fi
    probe=$(dirname -- "$probe")
  done
  [ -n "$SRC_ROOT" ] || die "无法定位主工作树根目录（未找到 .git），请先进入仓库目录"
  warn "无法通过 git 定位主工作树，回退使用 $SRC_ROOT"
fi
SRC_ROOT=$(cd -- "$SRC_ROOT" && pwd)

[ -d "$TARGET" ] || die "目标路径不存在或不是目录: $TARGET"
TARGET=$(cd -- "$TARGET" && pwd)

if [ "$(realpath -- "$TARGET")" = "$(realpath -- "$SRC_ROOT")" ]; then
  die "目标路径就是主工作树本身: $TARGET"
fi

# 必需：build-profile.json5（IDE 构建）、.env（本机路径）
for f in build-profile.json5 .env; do
  [ -e "$SRC_ROOT/$f" ] || die "源路径缺失: $SRC_ROOT/$f"
done

# 目标应当是同一仓库的 worktree，不是则仅提示
TARGET_COMMON=$(git -C "$TARGET" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
if [ -z "$TARGET_COMMON" ]; then
  warn "$TARGET 不是 git 仓库（请确认已用 git worktree add 创建）"
elif [ "$(realpath -- "$TARGET_COMMON")" != "$(realpath -- "$SRC_ROOT/.git")" ]; then
  warn "$TARGET 与主工作树不是同一个 git 仓库，仍继续执行"
fi

info "源目录:   $SRC_ROOT"
info "目标目录: $TARGET"
info ""

# 预演模式：打印将要执行的动作，不落盘
skip_if_dry_run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[预演] 未执行: $*"
    return 0
  fi
  return 1
}

# ---------- 1. 复制 build-profile.json5 ----------
copy_file() {
  local src=$1 dst=$2 name
  name=$(basename -- "$dst")

  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    if cmp -s -- "$src" "$dst"; then
      info "[跳过] $name 已存在且内容一致"
      return 0
    fi
    if [ "$FORCE" -ne 1 ]; then
      warn "$name 已存在且内容不同，未覆盖（需要覆盖请加 --force）"
      return 0
    fi
    info "[覆盖] $name"
  else
    info "[复制] $name"
  fi

  skip_if_dry_run "cp $src → $dst" && return 0
  cp -f -- "$src" "$dst"
}

# ---------- 2. 软链接 .env ----------
link_path() {
  local src=$1 dst=$2 name
  name=$(basename -- "$dst")

  if [ -L "$dst" ]; then
    if [ "$(realpath -- "$dst")" = "$(realpath -- "$src")" ]; then
      info "[跳过] $name 已正确链接"
      return 0
    fi
    if [ "$FORCE" -ne 1 ]; then
      warn "$name 是指向别处的软链接（$(readlink -- "$dst")），未改动（需要重建请加 --force）"
      return 0
    fi
    skip_if_dry_run "rm -f $dst && ln -s $src $dst" && return 0
    rm -f -- "$dst"
    info "[重建] $name 软链接"
  elif [ -e "$dst" ]; then
    # 真实文件：可能是用户自己的内容，绝不擅自删除
    warn "$name 已存在且不是软链接，未改动；确认后可执行: rm -f '$dst' 再重跑"
    return 0
  else
    info "[链接] $name -> $src"
  fi

  skip_if_dry_run "ln -s $src $dst" && return 0
  ln -s -- "$src" "$dst"
}

# ---------- 3. 复制 .opencode 目录 ----------
copy_dir() {
  local src=$1 dst=$2 name
  name=$(basename -- "$dst")

  if [ -L "$dst" ]; then
    # 旧版脚本建的软链接：不是用户数据，直接换成真实目录
    skip_if_dry_run "rm -f $dst（旧软链接）&& cp -a $src $dst" && return 0
    rm -f -- "$dst"
    info "[替换] $name 原软链接改为真实目录"
  elif [ -e "$dst" ]; then
    if [ ! -d "$dst" ]; then
      warn "$name 已存在但不是目录，未改动；确认后可删除 '$dst' 再重跑"
      return 0
    fi
    if diff -r -q -- "$src" "$dst" >/dev/null 2>&1; then
      info "[跳过] $name 已存在且内容一致"
      return 0
    fi
    if [ "$FORCE" -ne 1 ]; then
      warn "$name 已存在且内容不同，未覆盖（需要覆盖请加 --force）"
      return 0
    fi
    skip_if_dry_run "rm -rf $dst && cp -a $src $dst" && return 0
    rm -rf -- "$dst"
    info "[覆盖] $name"
  else
    info "[复制] $name"
  fi

  skip_if_dry_run "cp -a $src $dst" && return 0
  cp -a -- "$src" "$dst"
}

copy_file "$SRC_ROOT/build-profile.json5" "$TARGET/build-profile.json5"
link_path "$SRC_ROOT/.env" "$TARGET/.env"

# ---------- 3. 复制 .opencode 目录（可选：不是所有人都用 OpenCode） ----------
if [ -d "$SRC_ROOT/.opencode" ]; then
  copy_dir "$SRC_ROOT/.opencode" "$TARGET/.opencode"
else
  info "[跳过] 主工作树没有 .opencode（不使用 OpenCode 时正常）"
fi

# ---------- 4. 复制 codegraph.json（索引排除配置） ----------
if [ -f "$SRC_ROOT/codegraph.json" ]; then
  copy_file "$SRC_ROOT/codegraph.json" "$TARGET/codegraph.json"
else
  warn "主工作树没有 codegraph.json，跳过（索引将不套用排除规则）"
fi

# ---------- 5. 在目标 worktree 中初始化 codegraph ----------
# codegraph 现在装在 ~/.local/bin（npm --prefix ~/.local），与 node 版本无关；
# mise 的 shim 也指向稳定路径。仍按"显式路径优先、PATH 兜底"的顺序探测，
# 因为脚本可能被 IDE / 非交互 shell 调起，拿不到完整 PATH：
#   1. 环境变量 CODEGRAPH_BIN 指定的路径
#   2. PATH 中的 codegraph
#   3. mise shims（~/.local/share/mise/shims）
#   4. ~/.local/bin 与系统目录
# 调用时把 codegraph 所在目录放到 PATH 最前面，保证用同目录的 node 解释器运行。
codegraph_works() {
  local bin=$1
  [ -x "$bin" ] || return 1
  PATH="$(dirname -- "$bin"):$PATH" "$bin" --version >/dev/null 2>&1
}

resolve_codegraph() {
  local cand found
  local -a candidates=()

  if [ -n "${CODEGRAPH_BIN:-}" ]; then
    if codegraph_works "$CODEGRAPH_BIN"; then
      printf '%s\n' "$CODEGRAPH_BIN"
      return 0
    fi
    warn "CODEGRAPH_BIN 指定的路径不可用: $CODEGRAPH_BIN，继续自动查找"
  fi

  if found=$(command -v codegraph 2>/dev/null); then
    candidates+=("$found")
  fi

  for cand in \
    "${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims/codegraph" \
    "$HOME/.local/bin/codegraph" \
    /usr/local/bin/codegraph \
    /usr/bin/codegraph; do
    [ -e "$cand" ] && candidates+=("$cand")
  done

  for cand in "${candidates[@]}"; do
    if codegraph_works "$cand"; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

init_codegraph() {
  if [ "$SKIP_CODEGRAPH" -eq 1 ]; then
    info "[跳过] 按 --skip-codegraph 要求不做 codegraph init"
    return 0
  fi

  local cg
  if ! cg=$(resolve_codegraph); then
    warn "未找到可用的 codegraph 命令，跳过索引。"
    warn "安装到与 node 版本无关的位置："
    warn "  npm i -g --prefix \"\$HOME/.local\" @colbymchenry/codegraph"
    warn "（亦可设 CODEGRAPH_BIN=/path/to/codegraph 后重跑本脚本）"
    return 0
  fi
  info "[使用] codegraph: $cg"

  run_cg() {
    PATH="$(dirname -- "$cg"):$PATH" "$cg" "$@"
  }

  if [ -f "$TARGET/.codegraph/codegraph.db" ]; then
    info "[跳过] 目标已有 codegraph 索引（需要重建请执行: cd '$TARGET' && codegraph index）"
    return 0
  elif [ -d "$TARGET/.codegraph" ]; then
    info "[重建] codegraph 索引（目标有 .codegraph 但无数据库，执行 codegraph index）"
    skip_if_dry_run "cd $TARGET && codegraph index" && return 0
    if ! ( cd -- "$TARGET" && run_cg index ); then
      warn "codegraph index 失败；可稍后在 $TARGET 手动重跑: codegraph index"
      return 0
    fi
  else
    info "[初始化] codegraph 索引（codegraph init，耗时较长）"
    skip_if_dry_run "cd $TARGET && codegraph init -y" && return 0
    if ! ( cd -- "$TARGET" && run_cg init -y ); then
      warn "codegraph init 失败；可稍后在 $TARGET 手动重跑: codegraph init"
      return 0
    fi
  fi
  info "[完成] codegraph 索引就绪"
}

init_codegraph

# ---------- 收尾：确认没有在 git 中留下“变化” ----------
if [ "$DRY_RUN" -eq 0 ] && [ -n "$TARGET_COMMON" ]; then
  leftover=$(git -C "$TARGET" status --porcelain -- .env .opencode build-profile.json5 codegraph.json .codegraph 2>/dev/null || true)
  if [ -n "$leftover" ]; then
    warn "以下内容仍被 git 视为变更，请检查 .gitignore / 目标目录状态："
    printf '%s\n' "$leftover" >&2
  fi
fi

info ""
if [ "$DRY_RUN" -eq 1 ]; then
  info "预演结束：以上是将会执行的操作，未写入任何文件。"
else
  info "完成。"
fi
