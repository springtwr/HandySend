# HandySend 开发流程

面向新成员的完整开发流程指南：从克隆仓库到日常开发、上游升级。构建细节见 `docs/BUILD.md`，架构见 `docs/ARCHITECTURE.md`。

## 0. 先建立认知：架构与关键机制

### 0.1 双仓库结构

```
HandySend（主仓库，gitcode: springtwr/HandySend）
 └── localsend_ohrs/third_party/localsend（submodule = LocalSend 协议核心）
      └── 定制仓库: GitCode springtwr/localsend-ohos
           └── main 分支 = HandySend 定制（基于特定tag + 鸿蒙化）
```

- **submodule 机制**：主仓库只记录一个 commit hash（gitlink），`git submodule update` 按它检出。
- **双 remote**（submodule 内）：
  - `origin` = 定制仓库（ `https://gitcode.com/springtwr/localsend-ohos.git` ）——检出与推送用
  - `upstream` = localsend 官方（`https://gh-proxy.org/https://github.com/localsend/localsend.git` ，经 gh-proxy 代理）——仅用于同步上游，需要自己添加

### 0.2 Submodule 独立性

主仓库只记录 submodule 的 commit hash（gitlink），submodule 目录本身是一个独立的 Git 仓库——有自己的对象库、分支和 remote。这意味着：

- 主仓库的提交**不会**自动包含 submodule 内部的改动，必须显式 `git add localsend_ohrs/third_party/localsend` 更新 gitlink
- ⚠️ **如果使用 git worktree**：每个 worktree 的 submodule 对象库完全独立，一个 worktree 里提交的 submodule 改动，其他 worktree 看不到，必须显式同步（见 §4）

### 0.3 协议分层

```
浏览器 ←HTTP→ Rust core（localsend submodule，网页经 include_str! 编入 .so）
              ↑ NAPI 桥接（localsend_ohrs/rust，主仓库自有代码）
              ↑ ArkTS 壳（entry/，纯 UI）
```

## 1. 克隆仓库

```bash
git clone <gitcode仓库URL> HandySend
cd HandySend
git submodule update --init
```

- submodule 自动从 `.gitmodules` 记录的 URL 拉取，检出到 gitlink 指定 commit（**detached HEAD 是正常状态**，即"绑定指定版本"）
- 使用 `--init`（不带 `--recursive`）：不递归初始化嵌套子模块 `support/submodules/flutter`（Flutter SDK，约 176MB），编译 `.so` 不需要它
- 验证：`git submodule status` 显示无 `+` 前缀、无 `-dirty`

## 2. 环境准备与构建

详见 `docs/BUILD.md`（§1-5 工具与环境、签名；§2.1 Git Hooks；§7 增量构建）。

```bash
ohrs doctor                              # 验证环境（armv7 一项 ✖ 可忽略，鸿蒙无 armv7 设备）
hvigorw assembleHap --mode module      # 全量构建（HAR + HAP）
hvigorw assembleHar                      # 仅 Rust 原生库
```

**⚠️ 增量构建两大坑**：

1. **网页资产随 Rust 重建**：单页 `localsend_ohrs/rust/bridge/web/assets/single.html` 在增量检查范围内（`localsend_ohrs/rust/`），改页面后正常增量构建即可
2. **cargo test 需指定 host target**：`cargo test --target x86_64-unknown-linux-gnu`（不指定会按 OHOS target 编译报 E0463）

## 3. 日常开发

### 场景 A：只改主仓库代码（ArkTS / 桥接 / 文档）

直接修改 → 提交 → 推送 → 按需合并。不涉及 submodule。

### 场景 B：改 submodule（localsend 定制，核心流程）

```bash
cd localsend_ohrs/third_party/localsend
git checkout main              # ① 切到定制分支
# ② 修改代码
git add <改动文件> && git commit -m "feat(web): ..."
# ③ push 到定制仓库（否则 gitlink 指向的提交别人/其他 worktree/CI 拉不到）
git push origin main

# ④ 回主仓库：更新 gitlink 并提交
cd <项目根目录>
git add localsend_ohrs/third_party/localsend
git commit -m "chore: 更新 submodule 至 <说明>"
```

### 场景 C：页面/网页改动后的验证

```bash
rm -rf localsend_ohrs/package/libs/      # 强制重编（见 §2 坑 1）
hvigorw assembleHap --mode module && devecocli run --skip-build
# 浏览器打开应用内分享链接，验证下载/上传/PIN/文本预览等
```

## 4. git worktree 专项

> 本节仅适用于使用 `git worktree` 多工作树开发的场景。单克隆 + 分支开发不需要关注。
>
> 新建 worktree 后记得补齐本地文件：见 §4.5（`tools/setup-worktree.sh`）。

### 4.1 Worktree 与 Submodule 的关系

```
HandySend/.git（主仓库 git 目录：对象 + 分支 refs，所有 worktree 共享）
 ├── 主 worktree: HandySend/    ← main 分支
 └── 本地 worktree: <path>/      ← 本地开发分支（git worktree add 创建）
```

- 主仓库对象与分支 refs **共享**，工作树**独立**
- **每个 worktree 的 submodule 是完全独立的仓库**（对象库、remote 配置各自独立）——在一个 worktree 里提交的 submodule 改动，其他 worktree 看不到，必须显式同步

### 4.2 worktree 间同步（已 push 到远程）

```bash
# 本地 worktree 侧：推送分支
git push origin <本地分支>

# 主 worktree 侧：
git merge origin/<本地分支>              # main 合入开发分支
git submodule sync                       # 修复 submodule remote（同步 .gitmodules 的 URL）
git submodule update --init  # ★submodule 按新 gitlink 从定制仓库拉取检出（不递归初始化嵌套子模块）
git push origin main
```

### 4.3 worktree 间同步（未 push，应急）

主仓库 refs 共享，submodule 对象库独立：

```bash
# 主 worktree 侧：
git merge <本地分支>                     # ① 合并主仓库（本地 refs 共享，无需 push）
git submodule sync                       # ② 修复 remote
# ③ 从本地 worktree 的 submodule 对象库拉取新提交（关键：对象库独立，需本地路径 fetch）
git -C localsend_ohrs/third_party/localsend fetch \
    <本地worktree绝对路径>/localsend_ohrs/third_party/localsend main
git submodule update                     # ④ 检出新 gitlink 对应 commit
```

⚠️ 本地路径 fetch 只是应急。**submodule 的 commit 最终必须 push 到定制仓库的 `main`**，否则新 clone / CI / 其他机器 `git submodule update` 会失败。

### 4.4 在新 worktree 初始化 submodule 定制分支

```bash
# 每个 worktree 的 submodule 需单独 fetch（对象库独立）
git -C localsend_ohrs/third_party/localsend fetch origin main
git -C localsend_ohrs/third_party/localsend checkout -b main origin/main
# 分支 HEAD 与 gitlink 一致时 submodule status 保持干净
```

### 4.5 补齐新 worktree 的本地文件

`git worktree add` 出来的工作树只有仓库内容。以下文件/目录不入库（含本机路径或签名，
或只有部分人使用），需要从主工作树补齐到新工作树：

| 文件/目录 | 处理方式 | 说明 |
|---|---|---|
| `build-profile.json5` | 复制 | IDE 构建必需，含本地签名路径 |
| `.env` | 软链接 | 本机工具链路径，软链接保证多工作树共用一份 |
| `.opencode/` | 复制 | OpenCode 的 MCP 配置，不用则不存在时自动跳过 |
| `codegraph.json` | 复制 | 索引排除规则，不存在时跳过 |
| `.codegraph/` | 重新建索引 | 每台机器/每个工作树独立，不能共享 |

```bash
tools/setup-worktree.sh ../HandySend-worktrees/dev       # 补齐 + 建 codegraph 索引
tools/setup-worktree.sh -s ../HandySend-worktrees/dev    # 不建索引（不用 codegraph）
tools/setup-worktree.sh -n ../HandySend-worktrees/dev    # 预演，只打印不写文件
```

- 内容一致则跳过；内容不同默认不覆盖，加 `--force` 才覆盖
- 不使用 OpenCode / codegraph 的人可以完全不执行本脚本，对仓库没有任何影响

## 5. 同步上游 localsend（按版本节奏，非自动）

上游改动以「逐条挑拣 `packages/core` 提交」的方式合入定制分支，不对定制分支 rebase，
也不使用 GitHub 网页的 Sync/Update：定制提交与上游提交各留各的历史，冲突只在挑拣时处理，
core 改动影响桥接层接口或行为时在同一批提交里完成适配。Flutter 应用、Dart isolates、CLI、
CI 与平台打包改动不进入 HandySend 构建，通常无需挑拣。

```bash
SUB=localsend_ohrs/third_party/localsend

git -C $SUB fetch upstream --tags                                      # ① 拉上游
git -C $SUB log --oneline --reverse localsend-synced..upstream/main -- packages/core   # ② 待评估提交
git -C $SUB cherry-pick -x <hash>                                      # ③ 需挑拣的逐条挑入
# ④ 验证：§7 的三组 cargo test + devecocli build + 设备端 Instrument Test
# ⑤ 更新 docs/UPSTREAM_SYNC.md 的已挑拣/跳过表、评估游标与同步日期
git -C $SUB branch -f localsend-synced upstream/main                   # ⑥ 移动游标
git -C $SUB push origin localsend-synced
# ⑦ 主仓库更新 gitlink；core 对齐的上游版本变化时改 localsend_ohrs/Cargo.toml 的 version
```

> 评估标准、已挑拣/跳过清单与复核命令见 [UPSTREAM_SYNC.md](UPSTREAM_SYNC.md)；
> 版本号口径见 [BUILD.md](BUILD.md) §10.1。

## 6. 常见坑速查

| 坑 | 现象 | 解法 |
|---|---|---|
| worktree submodule 独立 | 一个 worktree 提交了 submodule，另一个看不到/不更新 | 目标 worktree 跑 `git submodule sync` + `git submodule update`（未 push 时用 §4.3 本地路径 fetch） |
| submodule 未 push 定制仓库 | 新 clone/CI 的 `git submodule update` 失败 | 改完 submodule **必须** `git push origin main` |
| 页面改动不生效 | 改了 html，构建后浏览器仍旧页面 | `rm -rf localsend_ohrs/package/libs/` 强制重编 |
| pre-commit hook 拦截 | 检查全过但 commit 失败 | `git commit --no-verify` 兜底（正常应排查 hook） |
| cargo test E0463 | 按 OHOS target 编译 | 加 `--target x86_64-unknown-linux-gnu` 参数 |
| 凭据缺失 | push 报 "could not read Username" | gitcode 用个人凭据；GitHub 用 `gh auth token` 方式 |
| submodule status 无版本语义 | 显示裸 hash 而非 `(v1.18.1-2-...)` | `git fetch upstream --tags` 拉取 tag 后即显示 |

## 7. 命令速查

```bash
# submodule 状态 / 同步
git submodule status                     # 查 gitlink 一致性（无 +/-/-dirty 为正常）
git submodule sync                       # 修复 remote 与 .gitmodules 一致
git submodule update --init # 按 gitlink 检出（不递归初始化 flutter 嵌套子模块）

# 上游（在 submodule 内）
SUB=localsend_ohrs/third_party/localsend
git -C $SUB fetch upstream --tags        # 拉上游 tags（同步用）

# 构建 / 测试
hvigorw assembleHap --mode module      # 全量构建
rm -rf localsend_ohrs/package/libs       # 强制重编 Rust
cargo test --manifest-path localsend_ohrs/Cargo.toml --target x86_64-unknown-linux-gnu \
  --no-default-features --lib                                          # 桥接层单测
cargo test --manifest-path localsend_ohrs/tests/Cargo.toml \
  --target x86_64-unknown-linux-gnu                                    # 桥接层集成测试
cargo test --manifest-path localsend_ohrs/third_party/localsend/Cargo.toml \
  --target x86_64-unknown-linux-gnu -p localsend \
  --features crypto,discovery,http,multicast                           # 上游 core 测试
```
