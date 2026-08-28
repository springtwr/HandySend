# HandySend 构建指南

从零开始在一台新机器上克隆并构建 HandySend 的完整步骤。

## 1. 安装前置工具

### 1.1 DevEco Studio

**Windows**：下载安装 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)

**Linux**：华为官方未提供 Linux 版本，可使用社区版 [devecostudio-linux](https://github.com/alex3236/devecostudio-linux)（Arch Linux），默认安装路径 `/opt/devecostudio`

> Local Test 依赖预览器，预览器在 Linux 上不可用，因此 Linux 上无法运行 DevEco Studio 本地的单元测试功能

### 1.2 Rust 工具链

```bash
# Windows
winget install Rustlang.Rustup

# Linux / macOS
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# archlinux
sudo pacman -S rustup
```

安装 OHOS 目标：

```bash
rustup target add aarch64-unknown-linux-ohos
rustup target add x86_64-unknown-linux-ohos
```

### 1.3 ohrs（Rust NAPI 构建工具）

```bash
cargo install ohrs
```

### 1.4 DevEco Code + DevEco Cli（推荐）

[DevEco Code](https://gitcode.com/openharmony-sig/deveco-code) 是华为提供的 AI 编程助手

[DevEco Cli](https://gitcode.com/openharmony-sig/deveco-cli) 是鸿蒙开发配套的命令行工具，支持文档查询、构建、测试、设备管理等鸿蒙开发全流程所需功能。

两者独立安装，AGENTS.md 中多处依赖 deveco-cli ，建议都安装以获得最佳开发体验。

```bash
npm install -g @deveco/deveco-code
npm install -g @deveco/deveco-cli
```

## 2. 克隆项目

```bash
git clone <repo-url> HandySend
cd HandySend
git submodule update --init --recursive
```

将 localsend submodule 检出到 HandySend 定制分支（fork 仓库 `springtwr/localsend` 的 `harmony-web-ui` 分支，基于当前基线 + 鸿蒙化定制提交）：

```bash
cd localsend_ohrs/third_party/localsend
git checkout harmony-web-ui
cd ../../..
```

> - HandySend 的定制提交只推送到 `harmony-web-ui` 分支，不推送 localsend 上游
> - 构建前必须确保 submodule 检出到正确分支/提交，否则 Rust 编译可能因上游接口变更而失败

## 2.1 安装 Git Hooks（推荐）

项目使用 Lefthook 管理 Git Hooks，实现提交前自动检查和提交信息格式校验。

安装前置工具：

```bash
# 使用 npm 需安装 Node.js
# https://nodejs.org/zh-cn/download

# Lefthook（Hook 管理器）
npm install -g lefthook

# commitlint（提交信息校验）
npm install -g @commitlint/cli @commitlint/config-conventional

# gitleaks（敏感信息扫描，可选）
# Arch Linux：sudo pacman -S gitleaks
# 其他系统：https://github.com/gitleaks/gitleaks
```

在项目根目录激活 Hooks：

```bash
lefthook install
```

激活后，每次 `git commit` 会自动执行：

| Hook | 检查项 | 说明 |
|------|--------|------|
| pre-commit | 大文件检测 | 拒绝超过 512KB 的文件 |
| pre-commit | 敏感信息扫描 | 检测密钥/token 泄露（需安装 gitleaks） |
| pre-commit | ArkTS 静态检查 | 仅检查暂存的 .ets 文件（需 devecocli） |
| pre-commit | Rust 格式检查 | cargo fmt --check（仅暂存 .rs 文件） |
| pre-commit | Rust Clippy | cargo clippy（仅暂存 .rs 文件） |
| commit-msg | 约定式提交校验 | commitlint 校验提交信息格式 |

紧急情况下可绕过：`LEFTHOOK_EXCLUDE=0 git commit -m "..."`，或直接 `git commit --no-verify -m "..."`（跳过全部 hooks，包括 commit-msg 校验）。

## 3. 配置环境变量

### 3.1 Windows 路径空格问题

ohrs 不支持含空格的路径。DevEco SDK 默认安装在 `C:\Program Files\...`，需要创建无空格的符号链接：

```powershell
New-Item -ItemType Directory -Force -Path "C:\sdk_link"
New-Item -ItemType Junction -Path "C:\sdk_link\default" -Target "C:\Program Files\Huawei\DevEco Studio\sdk\default"
```

> Linux 不存在此问题，无需额外操作。

### 3.2 写入系统环境变量（推荐）

将环境变量写入系统配置，构建脚本会优先读取系统环境变量，无需每次依赖 `.env` 文件：

**Windows (PowerShell)**：

```powershell
[Environment]::SetEnvironmentVariable('DEVECO_HOME', 'C:\Program Files\Huawei\DevEco Studio', 'User')
[Environment]::SetEnvironmentVariable('DEVECO_SDK_HOME', 'C:\Program Files\Huawei\DevEco Studio\sdk', 'User')
[Environment]::SetEnvironmentVariable('OHOS_NDK_HOME', 'C:\sdk_link\default\openharmony', 'User')
[Environment]::SetEnvironmentVariable('JAVA_HOME', 'C:\Program Files\Huawei\DevEco Studio\jbr', 'User')
```

**Linux (bash/zsh)**：

```bash
# bash 用户：写入 ~/.bashrc
# zsh 用户：写入 ~/.zshenv（zsh 所有 shell 实例含非交互都读取；~/.zshrc 仅交互式加载）
# 路径适用于 Arch Linux 社区版 (github.com/alex3236/devecostudio-linux)
export DEVECO_HOME='/opt/devecostudio'
export DEVECO_SDK_HOME="$DEVECO_HOME/sdk"
export OHOS_NDK_HOME="$DEVECO_HOME/sdk/default/openharmony"
export JAVA_HOME="$DEVECO_HOME/jbr"
```

> **注意**：
> - 如果不想设置系统环境变量，可跳过此步，改用 3.3 节的 `.env` 文件。构建脚本会自动读取 `.env`，不依赖 shell 环境变量。
> - `JAVA_HOME` 也可以不使用 DevEco Studio 提供的版本，自己手动安装 OpenJDK 或 OracleJDK。
> - **Linux 生效方式**：`~/.bashrc` 中的 `export` 仅对新开的终端生效，当前终端需执行 `source ~/.bashrc`。DevEco Studio 作为图形应用不读取 bashrc，改完后需**注销重新登录桌面**才会生效；或者直接使用 `.env` 文件，无需注销。
> - **zsh 用户特别注意**：写 `~/.zshrc` 对命令行终端有效，但**对 CLI/AI 工具等 non-interactive shell 无效**（zsh 非交互不读 `.zshrc`）。要覆盖全部场景（交互终端 + 脚本 + 构建工具），应写入 `~/.zshenv`。实测：`~/.bashrc` 首行若有 `[[ $- != *i* ]] && return` 会直接拦截非交互调用，也不适合承载环境变量。

同时将常用工具目录加入 PATH：

**Windows (PowerShell)**：

```powershell
$deveco = 'C:\Program Files\Huawei\DevEco Studio'
$pathDirs = @(
  "$deveco\jbr\bin",
  "$deveco\bin",
  "$deveco\tools\ohpm\bin",
  "$deveco\tools\hvigor\bin",
  "$deveco\sdk\default\openharmony\toolchains"
)
$current = [Environment]::GetEnvironmentVariable('PATH', 'User')
foreach ($dir in $pathDirs) {
  if ($current -notlike "*$dir*") {
    $current += ";$dir"
  }
}
[Environment]::SetEnvironmentVariable('PATH', $current, 'User')
```

**Linux (bash)**：

```bash
# 在 ~/.bashrc 或 ~/.profile 或 ~/.zshrc 等shell配置文件中添加
deveco='/opt/devecostudio'
export PATH="$deveco/jbr/bin:$deveco/bin:$deveco/tools/ohpm/bin:$deveco/tools/hvigor/bin:$deveco/sdk/default/openharmony/toolchains:$HOME/.cargo/bin:$PATH"
```

设置后使环境变量生效：

- **Windows**：重启终端
- **Linux**：新开终端自动生效；当前终端执行 `source ~/.bashrc`；DevEco Studio 需注销重新登录桌面，或改用 `.env` 文件

环境变量一览：

| 变量                | Windows 值                                    | Linux 值                                  | 用途                              |
|-------------------|-----------------------------------------------|------------------------------------------|---------------------------------|
| `DEVECO_HOME`     | `C:\Program Files\Huawei\DevEco Studio`      | `/opt/devecostudio`                      | build_project 工具、DevEco CLI     |
| `DEVECO_SDK_HOME` | `C:\Program Files\Huawei\DevEco Studio\sdk`  | `$DEVECO_HOME/sdk`                       | hvigorw SDK 定位                  |
| `OHOS_NDK_HOME`   | `C:\sdk_link\default\openharmony`            | `$DEVECO_HOME/sdk/default/openharmony`   | ohrs Rust 编译（Windows 需无空格路径，用 junction） |
| `JAVA_HOME`       | `C:\Program Files\Huawei\DevEco Studio\jbr`  | `$DEVECO_HOME/jbr`                       | hvigorw PackageHap 阶段需要 `java`   |
| `OHRS_BUILD_ARCHS`| —                                             | —                                        | Rust 构建架构（见 3.4 节）            |

常用命令及默认路径：

| 命令             | Windows 路径                                                                | Linux 路径                                          |
|----------------|----------------------------------------------------------------------------|---------------------------------------------------|
| `devecostudio` | `$DEVECO_HOME\bin`                                                        | `$DEVECO_HOME/bin`                                |
| `ohpm`         | `$DEVECO_HOME\tools\ohpm\bin`                                             | `$DEVECO_HOME/tools/ohpm/bin`                     |
| `hdc`          | `$DEVECO_HOME\sdk\default\openharmony\toolchains`                         | `$DEVECO_HOME/sdk/default/openharmony/toolchains` |
| `hvigorw`      | `$DEVECO_HOME\tools\hvigor\bin`                                           | `$DEVECO_HOME/tools/hvigor/bin`                   |

### 3.3 使用 .env 文件（备选）

如果不写入系统环境变量，项目根目录的 `.env` 文件也会被构建脚本读取：

```bash
# Windows
Copy-Item .env.example .env

# Linux
cp .env.example .env
```

编辑 `.env`，填入实际路径。

`.env` 文件格式说明：

- 含空格的值用单引号包裹（如 `DEVECO_HOME='C:\Program Files\...'`），解析时自动剥离引号
- 支持 `$VAR` 和 `${VAR}` 变量引用语法，引用同文件中已定义的变量（如 `DEVECO_SDK_HOME='$DEVECO_HOME/sdk'`）
- 变量按行序解析，被引用的变量必须出现在引用者之前
- 未找到引用变量时保留原文不替换

> 如果运行命令时提示环境变量未定义，先检查系统环境变量，再到 `.env` 中查找。

### 3.4 Rust 构建架构（OHRS_BUILD_ARCHS）

默认只构建 `arm64`（真机部署）。如需使用模拟器，可加上 `x86_64`。

通过环境变量 `OHRS_BUILD_ARCHS` 控制，逗号分隔：

| 配置 | 场景 |
|------|------|
| `arm64`（默认） | 真机部署 |
| `arm64,x86_64` | 真机 + 模拟器 |

设置方式：

```bash
# Windows
[Environment]::SetEnvironmentVariable('OHRS_BUILD_ARCHS', 'arm64,x86_64', 'User')

# Linux — 写入 ~/.bashrc（bash）或 ~/.zshenv（zsh）或 .env
export OHRS_BUILD_ARCHS='arm64,x86_64'
```

## 4. 配置构建签名

`build-profile.json5` 包含签名信息，不纳入版本控制：

```bash
# Windows
Copy-Item build-profile.example.json5 build-profile.json5

# Linux
cp build-profile.example.json5 build-profile.json5
```

在 DevEco Studio 中配置签名：File → Project Structure → Signing Configs。

## 5. 验证环境

```bash
ohrs doctor
```

应输出全部 ✔：

```
✔  Environment variable OHOS_NDK_HOME should be set.
✔  Rust version should be >= 1.88.0.
✔  Rustup target: aarch64-unknown-linux-ohos should be installed.
✔  Rustup target: x86_64-unknown-linux-ohos should be installed.
```

## 6. 构建项目

### DevEco Studio（推荐）

Build → Make Project。Rust 只在首次或源码变更时编译，后续构建秒级完成。

### 命令行

```bash
# 构建 APP（包含 Rust 编译 + ArkTS 编译 + 打包）
hvigorw assembleApp

# 仅构建 HAR 模块（Rust 原生库）
hvigorw assembleHar
```

首次构建会编译 Rust（约 5-10 分钟），后续自动增量跳过。

## 7. 增量构建机制

BuildRustNapi 任务会检查以下条件，全部满足时跳过 Rust 编译：

1. `OHRS_BUILD_ARCHS` 指定的每个架构对应的 `libs/<arch>/liblocalsend_core.so` 均存在
2. 上述 `.so` 文件修改时间均晚于 Rust 源码
3. `package/src/main/cpp/types/liblocalsend_core/index.d.ts` 存在且排序后内容哈希与 `dist/.d.ts.hash` 一致

哈希计算方式：将 `index.d.ts` 按行拆分，过滤空行和 `//` 注释行，按字典序排序后计算 SHA-256。排序可消除 ohrs 生成时导出顺序不确定（HashMap 无序）的影响，避免误报。

跳过时输出：
```
[localsend_ohrs] Rust NAPI is up-to-date, skipping build.
```

`index.d.ts` 不一致时输出：
```
[DtsGuard] index.d.ts missing or hash mismatch, forcing rebuild
```

> **注意（网页资产不在增量检查范围）**：`isRustBuildUpToDate()` 只比对 `third_party/localsend/packages/core/src/`、`localsend_ohrs/rust/`、`Cargo.toml` 的修改时间，**不含 `third_party/localsend/packages/core/assets/web/` 下的网页资产**（`download.html`/`upload.html`/`error-403.html` 经 `include_str!` 编译进 `.so`）。修改网页文件后不会触发 Rust 重建（.so 仍是旧页面），必须删除 `libs/` 强制重编（见下）。

### 强制重编 Rust

```bash
# Windows
Remove-Item -Recurse -Force localsend_ohrs\package\libs

# Linux
rm -rf localsend_ohrs/package/libs
```

然后重新构建：`hvigorw assembleApp`

## 8. 版本管理

版本号唯一来源是 `localsend_ohrs/Cargo.toml` 中的 `version`，构建时自动同步到：

| 文件 | 说明 |
|------|------|
| `localsend_ohrs/Cargo.toml` | 唯一来源，手动修改 |
| `localsend_ohrs/package/oh-package.json5` | 构建时自动同步 |
| `localsend_ohrs/package/src/main/cpp/types/liblocalsend_core/oh-package.json5` | 构建时自动同步 |
| `entry/src/main/ets/service/NativeBridge.ets` | 构建时自动同步 |

## 9. 上游同步（fork 定制分支策略）

HandySend 基于 fork 的 `harmony-web-ui` 分支（v1.18.1 基线 + 鸿蒙化定制提交），**不直接跟随 localsend 上游**。同步上游更新按版本节奏进行（如 v1.18.2）。

标准流程（实验分支 + 全量验证后切换，可回退）：

```bash
cd localsend_ohrs/third_party/localsend
git remote add upstream https://github.com/localsend/localsend
git fetch upstream main           # 拉取上游更新
git checkout -b upgrade-<版本>     # 实验分支，不直接改动 harmony-web-ui
git rebase upstream/main             # 把定制提交移植到新基线，解决冲突

# 全量验证：core 测试 + HandySend 桥接编译 + 端到端
CARGO_BUILD_TARGET=x86_64-unknown-linux-gnu cargo test --features full

git push -u origin upgrade-<版本>  # 验证通过后推送
```

验证通过后，在主仓库把 submodule gitlink 切到新分支/提交：

```bash
cd <项目根>
git add localsend_ohrs/third_party/localsend
git commit -m "chore: 升级 localsend submodule 至 <版本>"
```

> **升级成本提示**：1.18.2 重构了 core 的 web 接口（`WebConfig` 拆分为 `WebMode`/`WebPages`、`WebSendEvent`→`WebDownloadEvent`），升级时除 submodule rebase 外，还需同步迁移 `localsend_ohrs/rust/bridge/`（`facade.rs`/`server_facade.rs`）桥接代码，这是主要工作量。

## 10. 故障排除

### ohrs 找不到 toolchain

确保 `OHOS_NDK_HOME` 指向 SDK 根目录：

```
OHOS_NDK_HOME=.../openharmony
```

### Windows 空格路径问题

错误：`OHOS CMake toolchain file not found`

创建无空格符号链接（见第 3.1 节），并在环境变量中使用符号链接路径。

### ohrs 命令找不到（DevEco Studio 构建）

DevEco Studio 启动 hvigor 时不继承 shell 的 PATH，导致 `~/.cargo/bin` 不在搜索路径中。构建脚本已自动处理：会将 `$CARGO_HOME/bin` 或 `$HOME/.cargo/bin`（Linux）/ `$USERPROFILE/.cargo/bin`（Windows）加入 PATH。

如果仍然找不到，确认 `ohrs` 已安装：

```bash
cargo install ohrs
which ohrs    # Linux
where ohrs    # Windows
```

### 类型声明不匹配

Rust 接口变更后类型声明可能不匹配，清理缓存重新构建：

```bash
hvigorw clean
hvigorw assembleApp
```

### hvigorw 命令找不到

确保 DevEco Studio 的 tools 目录在 PATH 中，或使用完整路径：

```bash
# Windows
$env:PATH = "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin;$env:PATH"

# Linux
export PATH="/opt/devecostudio/tools/hvigor/bin:$PATH"
```

### PackageHap 阶段报 `spawn java ENOENT`

hvigorw 的 PackageHap 步骤需要 `java` 命令。确保 `JAVA_HOME` 已设置且 `$JAVA_HOME/bin` 在 PATH 中：

```bash
# Windows
$env:JAVA_HOME = "C:\Program Files\Huawei\DevEco Studio\jbr"
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"

# Linux
export JAVA_HOME="/opt/devecostudio/jbr"
export PATH="$JAVA_HOME/bin:$PATH"
```

### Rust 编译被意外跳过

删除 libs/ 强制重编：

```bash
# Windows
Remove-Item -Recurse -Force localsend_ohrs\package\libs

# Linux
rm -rf localsend_ohrs/package/libs
```

或全量清理后重建：

```bash
hvigorw clean
hvigorw assembleApp
```