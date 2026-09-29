# HandySend 构建指南

从零开始在一台新机器上克隆并构建 HandySend 的完整步骤。

## 1. 安装前置工具

### 1.1 DevEco Studio

**Windows**：下载安装 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)

**Linux**：华为官方未提供 Linux 版本，可使用社区版 [devecostudio-linux](https://github.com/alex3236/devecostudio-linux)（Arch Linux），默认安装路径 `/opt/devecostudio`

ArkTS 侧单元测试为统一设备端测试（`hvigorw onDeviceTest`），在 Linux 上需连接真机/模拟器运行；无可用设备时以
`arkts_check` 静态检查 + 构建作为替代验证，Rust 侧使用 `cargo test`（运行方式见「§8 运行测试」）。

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

> `aarch64` 用于真机，`x86_64` 用于模拟器，按需安装。鸿蒙无 armv7 设备，本项目构建不使用该 target。

### 1.3 ohrs（Rust NAPI 构建工具）

```bash
cargo install ohrs
```

### 1.4 DevEco Code（推荐）

[DevEco Code](https://gitcode.com/openharmony-sig/deveco-code) 是华为提供的 AI 编程助手，已内置配套命令行工具
`devecocli`（文档查询、构建、测试、设备管理等）。在 DevEco Code 中开发无需额外安装；如需在 DevEco Code
之外使用 `devecocli`，可单独安装 [DevEco Cli](https://gitcode.com/openharmony-sig/deveco-cli)：

```bash
npm install -g @deveco/deveco-cli
```

## 2. 克隆项目

```bash
git clone <repo-url> HandySend
cd HandySend
git submodule update --init
```

submodule 指向 fork 仓库 `springtwr/localsend_harmony-web-ui`，其默认分支即 HandySend 定制分支 `harmony-web-ui`（基于当前基线 + 鸿蒙化定制提交），主仓库 gitlink 与该分支保持同步，克隆后无需手动检出。

> - HandySend 的定制提交只推送到 `harmony-web-ui` 分支，不推送 localsend 上游
> - 编译 `.so` 不需要 Flutter：`--init` 不递归初始化嵌套子模块（`support/submodules/flutter`，Flutter SDK 约 176MB，仅服务于上游 app），可避免拉取多余的 SDK

> submodule 工作流（定制提交、worktree、上游升级）见 [DEVELOPMENT_WORKFLOW.md](DEVELOPMENT_WORKFLOW.md)。

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

# gitleaks（敏感信息扫描，必需：未安装时 pre-commit 拒绝提交）
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
| pre-commit | 敏感信息扫描 | 检测密钥/token 泄露（gitleaks 未安装时拒绝提交，安全检查不可跳过） |
| pre-commit | ArkTS 静态检查 | 暂存 .ets 文件时触发，对变更的 .ets 执行 codelinter 增量检查，检出 error 拒绝提交（需 codelinter、node，缺任一则跳过） |
| pre-commit | Rust 格式检查 | 暂存 .rs 文件时触发，cargo fmt --check（主 crate 与 tests crate 分别检查） |
| pre-commit | Rust Clippy | 暂存 .rs 文件时触发，cargo clippy -D warnings（未安装 cargo 则跳过） |
| pre-commit | NAPI 封装完整性 | NAPI 导出面 / NativeBridge / NativeTypes 或校验脚本变更时触发（cargo test 集成测试） |
| pre-commit | 设备端测试编译 | ohosTest 或 NativeBridge/NativeTypes 变更时触发，hvigorw 编译 ohosTest（需 hvigorw，未安装则跳过） |
| commit-msg | 约定式提交校验 | commitlint 校验提交信息格式 |

紧急情况下可跳过指定任务：`LEFTHOOK_EXCLUDE=任务名 git commit -m "..."`（任务名如 `大文件检测`，可用逗号分隔多个）；全局关闭
hooks 用 `LEFTHOOK=0 git commit -m "..."`，或直接 `git commit --no-verify -m "..."`（跳过全部 hooks，包括 commit-msg 校验）。

## 3. 配置环境变量

### 3.1 Windows 路径空格问题

ohrs 不支持含空格的路径。DevEco SDK 默认安装在 `C:\Program Files\...`，需要创建无空格的符号链接：

```powershell
New-Item -ItemType Directory -Force -Path "C:\sdk_link"
New-Item -ItemType Junction -Path "C:\sdk_link\default" -Target "C:\Program Files\Huawei\DevEco Studio\sdk\default"
```

> Linux 不存在此问题，无需额外操作。

### 3.2 写入系统环境变量

将环境变量写入系统配置，构建脚本会同时读取系统环境变量和 `.env` 文件：

- `.env` 文件中的值**始终覆盖**系统环境变量（项目本地配置优先级最高）
- 如果 `.env` 文件中未定义某变量，则使用系统环境变量的值

> **桌面 vs 命令行**：DevEco Studio 和 Command Line Tools 是两套独立工具链，均可独立完成鸿蒙应用构建。
> - **唯一必需变量**：`OHOS_NDK_HOME`（ohrs Rust 交叉编译需要），其余均可选
> - `DEVECO_HOME` / `JAVA_HOME` 用于 DevEco Studio GUI 构建和 devecocli 工具，命令行构建（hvigorw）不需要

**Windows (PowerShell)**：

```powershell
[Environment]::SetEnvironmentVariable('DEVECO_HOME', 'C:\Program Files\Huawei\DevEco Studio', 'User')
[Environment]::SetEnvironmentVariable('OHOS_NDK_HOME', 'C:\sdk_link\default\openharmony', 'User')
[Environment]::SetEnvironmentVariable('JAVA_HOME', 'C:\Program Files\Huawei\DevEco Studio\jbr', 'User')
```

**Linux (bash/zsh)**：

```bash
# bash 用户：写入 ~/.bashrc
# zsh 用户：写入 ~/.zshenv（zsh 所有 shell 实例含非交互都读取；~/.zshrc 仅交互式加载）
# 路径适用于 Arch Linux 社区版 (github.com/alex3236/devecostudio-linux)
export DEVECO_HOME='/opt/devecostudio'
export OHOS_NDK_HOME="$DEVECO_HOME/sdk/default/openharmony"
export JAVA_HOME="$DEVECO_HOME/jbr"
```

> **注意**：
> 如果不想设置系统环境变量，可跳过此步，改用 3.3 节的 `.env` 文件。构建脚本会自动读取 `.env`，不依赖 shell 环境变量。
> - `JAVA_HOME` 也可以不使用 DevEco Studio 提供的版本，自己手动安装 OpenJDK 或 OracleJDK。
> - **Linux 生效方式**：`~/.bashrc` 中的 `export` 仅对新开的终端生效，当前终端需执行 `source ~/.bashrc`。DevEco
>   Studio 作为图形应用不读取 bashrc，改完后需**注销重新登录桌面**才会生效；或者直接使用 `.env` 文件，无需注销。
> - **zsh 用户特别注意**：写 `~/.zshrc` 对命令行终端有效，但**对 CLI/AI 工具等 non-interactive shell 无效**（zsh 非交互不读 `.zshrc`）。要覆盖全部场景（交互终端
>   + 脚本 + 构建工具），应写入 `~/.zshenv`。实测：`~/.bashrc` 首行若有 `[[ $- != *i* ]] && return` 会直接拦截非交互调用，也不适合承载环境变量。

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

| 变量                | Windows 值                                    | Linux 值                                  | 用途                              | 是否必需 |
|-------------------|-----------------------------------------------|------------------------------------------|---------------------------------|----------|
| `OHOS_NDK_HOME`   | `C:\sdk_link\default\openharmony`            | `$DEVECO_HOME/sdk/default/openharmony`   | ohrs Rust 编译（Windows 需无空格路径，用 junction） | ✅ 必需 |
| `DEVECO_HOME`     | `C:\Program Files\Huawei\DevEco Studio`      | `/opt/devecostudio`                      | devecocli 工具、DevEco CLI；作为其他变量前缀 | ❌ 便捷变量 |
| `JAVA_HOME`       | `C:\Program Files\Huawei\DevEco Studio\jbr`  | `$DEVECO_HOME/jbr`                       | hvigorw PackageHap 阶段需要 `java`（也可用系统 JDK） | ❌ 可选 |
| `OHRS_BUILD_ARCHS`| —                                             | —                                        | Rust 构建架构（见 3.4 节）            | ❌ 可选 |

常用命令及默认路径：

| 命令             | Windows 路径                                                                | Linux 路径                                          |
|----------------|----------------------------------------------------------------------------|---------------------------------------------------|
| `devecostudio` | `$DEVECO_HOME\bin`                                                        | `$DEVECO_HOME/bin`                                |
| `ohpm`         | `$DEVECO_HOME\tools\ohpm\bin`                                             | `$DEVECO_HOME/tools/ohpm/bin`                     |
| `hdc`          | `$DEVECO_HOME\sdk\default\openharmony\toolchains`                         | `$DEVECO_HOME/sdk/default/openharmony/toolchains` |
| `hvigorw`      | `$DEVECO_HOME\tools\hvigor\bin`                                           | `$DEVECO_HOME/tools/hvigor/bin`                   |

### 3.3 使用 .env 文件

项目根目录的 `.env` 文件会被构建脚本读取，**优先级高于系统环境变量**——同名变量以 `.env` 中的值为准。

```bash
# Windows
Copy-Item .env.example .env

# Linux
cp .env.example .env
```

编辑 `.env`，填入实际路径。

`.env` 文件格式说明：

- 含空格的值用单引号包裹（如 `DEVECO_HOME='C:\Program Files\...'`），解析时自动剥离引号
- 支持 `$VAR` 和 `${VAR}` 变量引用语法，引用同文件中已定义的变量或系统环境变量（如 `JAVA_HOME='$DEVECO_HOME/jbr'`）
- 变量按行序解析，同文件内被引用的变量必须出现在引用者之前；系统环境变量不受行序限制

> 如果运行命令时提示环境变量未定义，检查 `.env` 和系统环境变量是否已正确配置。注意 `.env` 值会覆盖同名系统环境变量。

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

## 4. 配置签名（仅部署到设备时需要）

构建未签名 HAP（如 CI 产物）无需配置签名；仅在安装到真机/模拟器前需要。

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

`armv7-unknown-linux-ohos` 一项会显示 ✖，可忽略：这是 ohrs 工具自身硬编码检查全部 OHOS target，鸿蒙无 armv7 设备，本项目构建不使用该 target。其余各项应为 ✔：

```
✔  Environment variable OHOS_NDK_HOME should be set.
✔  Rust version should be >= 1.88.0.
✔  Rustup target: aarch64-unknown-linux-ohos should be installed.
✖  Rustup target: armv7-unknown-linux-ohos should be installed.
✔  Rustup target: x86_64-unknown-linux-ohos should be installed.
```

## 6. 构建项目

### DevEco Studio（推荐）

Build → Make Project。Rust 只在首次或源码变更时编译，后续构建秒级完成。

### 命令行

```bash
# 构建 HAP 应用（包含 Rust 编译 + ArkTS 编译 + 打包）
# hvigor 26 起 project 模式不再暴露 HAP 模块任务，assembleHap 需模块模式调用
hvigorw assembleHap --mode module

# 仅构建 HAR 模块（Rust 原生库）
hvigorw assembleHar --mode module
```

首次构建会编译 Rust。依赖与 cargo 缓存就绪时，重编各目标架构（`libs/<arch>/liblocalsend_core.so`）实测为秒级，
后续自动增量跳过；只有在 cargo 缓存缺失（首次拉取依赖或清理 `target/`）时才需完整编译全部依赖。

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

> **注意（网页资产不在增量检查范围）**：`isRustBuildUpToDate()` 只比对 `third_party/localsend/packages/core/src/`、`localsend_ohrs/rust/`、
> `Cargo.toml` 的修改时间，**不含 `third_party/localsend/packages/core/assets/web/` 下的网页资产**（`download.html`/`upload.html`/`error-403.html`
> 经 `include_str!` 编译进 `.so`）。修改网页文件后不会触发 Rust 重建（.so 仍是旧页面），必须删除 `libs/` 强制重编（见下）。

### 强制重编 Rust

```bash
# Windows
Remove-Item -Recurse -Force localsend_ohrs\package\libs

# Linux
rm -rf localsend_ohrs/package/libs
```

然后重新构建：`hvigorw assembleHap --mode module`

## 8. 运行测试

| 测试层 | 运行环境 | 运行方式 |
|--------|----------|----------|
| Instrument Test（ArkTS 全部单元测试） | 真机/模拟器 | `hvigorw onDeviceTest -p module=entry` |
| Rust 桥接层单元测试 | Linux 开发机 | `hvigorw RustTestUnit -p module=localsend_ohrs` 或 cargo test |
| Rust 桥接层集成测试 | Linux 开发机 | `hvigorw RustTestIntegration -p module=localsend_ohrs` 或 cargo test |
| Rust 上游 localsend crate 测试 | Linux 开发机 | `hvigorw RustTestUpstream -p module=localsend_ohrs` 或 cargo test |

- Instrument Test 运行命令、hdc 直连方式与编写规范见 [testing/instrument-test-guide.md](testing/instrument-test-guide.md)
- Rust 三层测试的命令、参数说明与耗时优化见 [testing/rust-test.md](testing/rust-test.md)
- CI 流水线中的测试矩阵见 [CI_CD.md](CI_CD.md)

## 9. CI/CD（AtomGit Action / GitHub Actions）

项目同时发布到 GitCode 与 GitHub，两平台各有一套对等的流水线：

- **ci.yml**（PR/push 检查）：ArkTS codelinter 检查、Rust fmt/clippy、三层 Rust 测试
- **build.yml**（push tag `v*` 触发）：构建未签名 HAP，GitHub 版自动创建 Release 附带产物

流水线配置、触发条件、Docker 镜像与缓存策略见 [CI_CD.md](CI_CD.md)。

## 10. 版本管理

项目内存在两套相互独立的版本号体系。

### 10.1 原生库版本（localsend_ohrs）

原生库版本号唯一来源是 `localsend_ohrs/Cargo.toml` 中的 `version`（镜像上游 localsend fork 基线，如 1.18.1），构建时自动同步到：

| 文件 | 说明 |
|------|------|
| `localsend_ohrs/Cargo.toml` | 唯一来源，手动修改 |
| `localsend_ohrs/package/oh-package.json5` | 构建时自动同步 |
| `localsend_ohrs/package/src/main/cpp/types/liblocalsend_core/oh-package.json5` | 构建时自动同步 |
| `entry/src/main/ets/service/NativeBridge.ets` | 构建时自动同步 |

### 10.2 应用版本（AppScope）

应用版本（上架版本）唯一来源是 `AppScope/app.json5` 的 `versionName` / `versionCode`。`versionCode` 采用「日期 + 序号」格式（如
202609081 = 2026-09-08 当日第 1 个版本）。构建产物中的版本（`module.json` / `pack.info`）只取此处，**升级应用版本仅需修改该文件**。

`entry/oh-package.json5` 的 `version` 仅是模块包元数据（供 ohpm 依赖解析/发布使用），不参与 HAP 产物，固定为 `1.0.0`，不随应用版本升级。

### 10.3 发布版本流程

版本升级/发布使用 **release 构建**与 **release 提交**：

1. 在 `AppScope/app.json5` 修改 `versionName` / `versionCode`
2. release 构建验证（与 build.yml 的 Tag 触发构建一致）：

   ```bash
   devecocli build --build-mode release
   # 等价命令行：hvigorw assembleHap --mode module -p product=default -p buildMode=release
   ```

   产物位于 `entry/build/default/outputs/default/`（signed/unsigned HAP、pack.info、mapping）
3. 归档产物到 `temp/handysend-release/<版本>/`（该目录不入版本控制）
4. 提交版本发布：`release: 发布 <版本>`（如 `release: 发布 1.1.0`）
5. 打 `v<版本>` 标签并推送到两平台，触发 build.yml 以 release 模式构建未签名 HAP 产物（GitHub 自动创建 Release 并附上产物；GitCode Release 附件手动归档）

## 11. 故障排除

### ohrs 找不到 toolchain

确保 `OHOS_NDK_HOME` 指向 SDK 根目录：

```
OHOS_NDK_HOME=.../openharmony
```

### Windows 空格路径问题

错误：`OHOS CMake toolchain file not found`

创建无空格符号链接（见第 3.1 节），并在环境变量中使用符号链接路径。

### ohrs 命令找不到（DevEco Studio 构建）

DevEco Studio 启动 hvigor 时不继承 shell 的 PATH，导致 `~/.cargo/bin` 不在搜索路径中。构建脚本已自动处理：
会将 `$CARGO_HOME/bin` 或 `$HOME/.cargo/bin`（Linux）/ `$USERPROFILE/.cargo/bin`（Windows）加入 PATH。

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
hvigorw assembleHap --mode module
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
hvigorw assembleHap --mode module
```
