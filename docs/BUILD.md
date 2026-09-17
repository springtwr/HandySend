# HandySend 构建指南

从零开始在一台新机器上克隆并构建 HandySend 的完整步骤。

## 1. 安装前置工具

### 1.1 DevEco Studio

**Windows**：下载安装 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)

**Linux**：华为官方未提供 Linux 版本，可使用社区版 [devecostudio-linux](https://github.com/alex3236/devecostudio-linux)（Arch Linux），默认安装路径 `/opt/devecostudio`

ArkTS 侧单元测试为统一设备端测试（`hvigorw onDeviceTest`），在 Linux 上需连接真机/模拟器运行；无可用设备时以 `arkts_check` 静态检查 + 构建作为替代验证，Rust 侧使用 `cargo test`（详见 §7.5）。

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
git submodule update --init
```

将 localsend submodule 检出到 HandySend 定制分支（fork 仓库 `springtwr/localsend` 的 `harmony-web-ui` 分支，基于当前基线 + 鸿蒙化定制提交）：

```bash
cd localsend_ohrs/third_party/localsend
git checkout harmony-web-ui
cd ../../..
```

> - HandySend 的定制提交只推送到 `harmony-web-ui` 分支，不推送 localsend 上游
> - 构建前必须确保 submodule 检出到正确分支/提交，否则 Rust 编译可能因上游接口变更而失败
> - 编译 `.so` 不需要 Flutter：`--init` 不递归初始化嵌套子模块（`support/submodules/flutter`，Flutter SDK 约 176MB，仅服务于上游 app），可避免拉取多余的 SDK

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
| pre-commit | ArkTS 静态检查 | 暂存 .ets 文件时触发，执行 codelinter 全仓扫描（需 codelinter，未安装则跳过） |
| pre-commit | Rust 格式检查 | 暂存 .rs 文件时触发，cargo fmt --check（主 crate 与 tests crate 分别检查） |
| pre-commit | Rust Clippy | 暂存 .rs 文件时触发，cargo clippy -D warnings（未安装 cargo 则跳过） |
| pre-commit | NAPI 封装完整性 | NAPI 导出面 / NativeBridge / NativeTypes 或校验脚本变更时触发（cargo test 集成测试） |
| pre-commit | 设备端测试编译 | ohosTest 或 NativeBridge/NativeTypes 变更时触发，hvigorw 编译 ohosTest（需 hvigorw，未安装则跳过） |
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

### 3.2 写入系统环境变量

将环境变量写入系统配置，构建脚本会同时读取系统环境变量和 `.env` 文件：

- `.env` 文件中的值**始终覆盖**系统环境变量（项目本地配置优先级最高）
- 如果 `.env` 文件中未定义某变量，则使用系统环境变量的值

> **桌面 vs 命令行**：DevEco Studio 和 Command Line Tools 是两套独立工具链，均可独立完成鸿蒙应用构建。
> - **唯一必需变量**：`OHOS_NDK_HOME`（ohrs Rust 交叉编译需要），其余均可选
> - `DEVECO_HOME` / `JAVA_HOME` 用于 DevEco Studio GUI 构建和 build_project 工具，命令行构建（hvigorw）不需要

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

| 变量                | Windows 值                                    | Linux 值                                  | 用途                              | 是否必需 |
|-------------------|-----------------------------------------------|------------------------------------------|---------------------------------|----------|
| `OHOS_NDK_HOME`   | `C:\sdk_link\default\openharmony`            | `$DEVECO_HOME/sdk/default/openharmony`   | ohrs Rust 编译（Windows 需无空格路径，用 junction） | ✅ 必需 |
| `DEVECO_HOME`     | `C:\Program Files\Huawei\DevEco Studio`      | `/opt/devecostudio`                      | build_project 工具、DevEco CLI；作为其他变量前缀 | ❌ 便捷变量 |
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

## 7.5 运行测试

### Instrument Test（设备端测试）

Instrument Test 运行于真机/模拟器，可调用系统 API 和原生 .so 函数，统一承载 ArkTS 侧全部单元测试（含自 Local Test 迁移的纯逻辑用例）。需先安装应用到设备。

全量 500 用例（本地单元测试迁移 + 既有设备端用例），模拟器（Mate 80 Pro）实测在 6s 内（不含构建与安装耗时）。

```bash
# 全量 Instrument Test
hvigorw onDeviceTest -p module=entry

# 指定测试套件
hvigorw onDeviceTest -p module=entry -p scope=ServerNativeTest

# 指定单个用例
hvigorw onDeviceTest -p module=entry -p scope=ServerNativeTest#createServer_returns_valid_handle
```

> 同时连接多台设备时 `onDeviceTest` 会在设备选择阶段失败（`ExecuteCommand need connect-key?`）：其覆盖率插件调用 hdc 时未指定设备序列号。此时断开多余设备，或改用下节的 hdc 直连方式。

#### hdc 直连

无需 DevEco Studio 设备管理，也可绕开多设备选择问题。设备序列号由 `hdc list targets` 查询。

```bash
# 1. 构建并签名测试包（onDeviceTest 的构建阶段即产出，其后的部署失败可忽略）
hvigorw onDeviceTest -p module=entry

# 2. 安装主包与测试包
hdc -t 127.0.0.1:5555 install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc -t 127.0.0.1:5555 install -r entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap

# 3. 运行（-s coverage false 关闭覆盖率采集，避免额外的采集与回传开销）
hdc -t 127.0.0.1:5555 shell aa test -b com.springtwr.handysend -m entry_test \
  -s unittest /ets/testrunner/OpenHarmonyTestRunner -s timeout 15000 -s coverage false
```

> 输出以 `OHOS_REPORT_STATUS: consuming=<ms>` 逐用例给出耗时，`taskconsuming=<ms>` 为总耗时，便于定位慢用例。

详细编写规范和用例说明见 `docs/testing/instrument-test-guide.md`。

### Rust 核心层测试

Rust 核心层测试在 Linux 开发机上直接运行 `cargo test`，无需真机、无需 NAPI 运行时。分三层：

#### DevEco Studio / hvigorw（推荐）

已注册为 hvigor 任务，位于侧边 hvigor 工具面板：**HandySend → localsend_ohrs → 任务 → 其它**。

命令行运行：

```bash
# 桥接层单元测试（214 用例，秒级）
hvigorw RustTestUnit -p module=localsend_ohrs

# 桥接层集成测试（31 用例，秒级）
hvigorw RustTestIntegration -p module=localsend_ohrs

# 上游 localsend crate 测试（~133 用例，~30s）
hvigorw RustTestUpstream -p module=localsend_ohrs
```

#### 手动运行 cargo test

#### 上游 localsend crate 测试

直接在 `third_party/localsend/` 下运行上游的单元测试和集成测试（76 单元 + 57 集成，覆盖协议、HTTP 服务器/客户端、发现、加密等）：

```bash
cd localsend_ohrs/third_party/localsend
cargo test --target x86_64-unknown-linux-gnu -p localsend --features crypto,discovery,http,multicast
```

> `--target x86_64-unknown-linux-gnu` 是必须的：`localsend_ohrs/.cargo/config.toml` 硬编码了 `x86_64-unknown-linux-ohos` 交叉编译目标，Cargo 会沿目录树向上查找配置，不显式指定 native target 则测试无法运行。`-p localsend` 限定只运行 core crate 的测试，不加则运行 workspace 全部成员。
>
> 部分组播/发现测试在无网络接口的环境中可能 skip，属正常现象。

#### 桥接层集成测试

验证桥接层事件管道（server_flow / client_flow / discovery_flow，通过 `event_tx`/`event_rx` 直接消费事件流，无 mock、无轮询）+ 配置矩阵（`config_matrix.rs`：HTTPS/PIN/校验和开关、多接收者并发、Web Share 链接、多文件传输、进度序列、协议安全边界、create_server 落盘），并包含 NAPI 封装完整性 guard（`napi_guard.rs`：校验 index.d.ts 导出与 NativeBridge.ets 封装差集 + `NativeTypes.ets::parseNativeEvent` 与 Rust `BridgeEvent` 序列化的跨层事件契约）：

```bash
cd localsend_ohrs/tests
cargo test --target x86_64-unknown-linux-gnu
```

> `localsend_ohrs_tests` 是独立 crate（不在 `localsend_ohrs` workspace 中），必须从 `localsend_ohrs/tests/` 目录运行。`--target x86_64-unknown-linux-gnu` 覆盖父级 `.cargo/config.toml` 中设置的 OHOS 交叉编译目标。
>
> 作为独立 crate，其 profile 不继承主 crate，`localsend_ohrs/tests/Cargo.toml` 同样对 `rsa` 与 `num-bigint-dig` 设置 `opt-level = 3`（原因见下方桥接层单元测试小节）：unoptimized 下 31 个用例约 91s，优化后约 6s。

#### 桥接层单元测试

覆盖桥接层中不依赖 NAPI 运行时的逻辑函数（类型转换、序列化、哈希、状态操作等），含 `BridgeEvent` 全变体序列化字段契约（防 ArkTS/Rust 契约漂移）：

```bash
cd localsend_ohrs
cargo test --target x86_64-unknown-linux-gnu --no-default-features --lib
```

> `--no-default-features` 关闭 napi feature，避免链接 OHOS NDK（`hilog_ndk.z` 等）。`--lib` 只测试库代码，排除集成测试二进制。
>
> 该套件含多组 TLS 身份/证书用例，会触发 RSA-2048 密钥生成。`localsend_ohrs/Cargo.toml` 的 `[profile.dev.package.rsa]` 与 `[profile.dev.package.num-bigint-dig]` 对这两个密码学 crate 单独设置 `opt-level = 3`：unoptimized 下单次生成约 13s，优化后约 0.06s，全量用例耗时由约 43s 降至约 2s。该设置只作用于这两个第三方 crate，项目自身代码仍为 unoptimized。

## 8. CI/CD（AtomGit Action）

项目使用 GitCode 平台的 AtomGit Action 实现自动化检查与构建。ArkTS 相关 Job 通过 `container.image` 使用内置 Command Line Tools 的 Docker 镜像（`springtwr/harmonyos-clt:26.0.0.821`），Rust 检查和构建安全网使用标准 Runner 环境（可利用 cargo 缓存）。

### 8.1 流水线配置

#### ci.yml — PR/push 检查

配置文件：`.gitcode/workflows/ci.yml`

| Job | 运行环境 | Runner 规格 | 说明 |
|-----|----------|-------------|------|
| arkts-lint | 容器 | small（2核8G） | ArkTS codelinter 检查 |
| rust-lint | 标准Runner | small（2核8G） | cargo fmt --check + cargo clippy（--no-default-features，标准 Runner 无 OHOS NDK） |
| rust-unit-test | 标准Runner | small（2核8G） | 桥接层单元测试（--no-default-features --lib） |
| rust-integration-test | 标准Runner | small（2核8G） | 桥接层集成测试（localsend_ohrs/tests/） |
| rust-upstream-test | 标准Runner | medium（4核16G） | 上游 localsend crate 测试（编译量大） |

执行顺序：arkts-lint 和 rust-lint 并行执行，rust-lint 通过后 rust-unit-test / rust-integration-test / rust-upstream-test 并行执行。

#### build.yml — Tag 触发构建

配置文件：`.gitcode/workflows/build.yml`

| Job | 运行环境 | Runner 规格 | 说明 |
|-----|----------|-------------|------|
| build | 容器 | medium（4核16G） | 安装 Rust 交叉编译工具链 + ohpm 依赖 + assembleApp |

编译检查已在 CI 流水线（ci.yml）中完成，build 流水线仅负责构建产物打包。

### 8.2 触发条件

| 流水线 | 事件 | 触发范围 |
|--------|------|----------|
| ci.yml | push 到 main | 排除文档等非代码文件（paths-ignore） |
| ci.yml | pull_request | 排除文档等非代码文件（paths-ignore） |
| ci.yml | workflow_dispatch | 手动触发（不限路径） |
| build.yml | push tag v* | 版本标签推送 |

排除项：`docs/**`、`**/*.md`、`LICENSE`、`.gitignore`、`.gitleaks.toml`、`commitlint.config.js`、`lefthook.yml`、`.env.example`、`.gitcode/ISSUE_TEMPLATE/**`、`.gitcode/PULL_REQUEST_TEMPLATE/**`。其余变更（含构建配置 json5、ets 源码、Rust 源码等）均触发 CI。

### 8.3 Docker 镜像

镜像 `springtwr/harmonyos-clt:26.0.0.821` 基于 Ubuntu 26.04，内置 HarmonyOS Command Line Tools（hvigorw、ohpm、codelinter、Node.js、hdc、hap-sign-tool 等）及 JDK 21。镜像已预配 PATH、ohpm 仓库和 npm 仓库，Job 的 step 可直接调用工具命令。需额外通过 `container.env` 注入 `OHOS_NDK_HOME`（Rust 交叉编译需要）。

镜像内关键路径：

| 路径 | 说明 |
|------|------|
| `/opt/command-line-tools/bin/` | hvigorw、ohpm 等命令 |
| `/opt/command-line-tools/tool/node/` | Node.js |
| `/opt/command-line-tools/sdk/` | HarmonyOS SDK |
| `/opt/command-line-tools/sdk/default/openharmony/` | OHOS NDK |
| `/usr/lib/jvm/java-21-openjdk-amd64/` | JDK 21 |

### 8.4 缓存策略

Rust Job（标准 Runner）独立缓存 cargo 注册表和编译产物（`target/`），以 `Cargo.lock` 哈希为缓存键，`restore-keys` 前缀匹配兜底。

容器 Job 不使用 cache 插件：容器内的家目录（`~/.cargo/`）与宿主 Runner 不共享文件系统，cache 插件无法正确缓存容器内的家目录路径。因此 build.yml 将 Rust 安全网拆到标准 Runner（有缓存），容器 Job 仅负责鸿蒙侧构建。

### 8.5 本地验证

提交前可通过 lefthook pre-commit 钩子提前捕获问题：

| 钩子 | 触发条件 | 说明 |
|------|----------|------|
| NAPI 封装完整性 | rust/napi / NativeBridge.ets / NativeTypes.ets / 校验脚本变更 | 从 index.d.ts 提取函数名，与 NativeBridge import 做差集 |
| Rust 格式检查 | .rs 文件变更 | cargo fmt --check（主 crate 与 tests crate 分别检查） |
| Rust Clippy | .rs 文件变更 | cargo clippy -D warnings |
| ArkTS 静态检查 | .ets 文件变更 | codelinter 全仓扫描，输出到 temp/code-linter-report.json |
| 设备端测试编译 | ohosTest / NativeBridge.ets / NativeTypes.ets 变更 | hvigorw 编译 ohosTest，校验测试侧导出引用一致性 |
| 敏感信息扫描 | 全部暂存文件 | gitleaks |
| 大文件检测 | 全部暂存文件 | >512KB 拒绝 |

推送前可手动运行三层测试：

```bash
cd localsend_ohrs && cargo test --target x86_64-unknown-linux-gnu --no-default-features --lib
cd tests && cargo test --target x86_64-unknown-linux-gnu
cd ../third_party/localsend && cargo test --target x86_64-unknown-linux-gnu -p localsend --features crypto,discovery,http,multicast
```

### 8.6 后续扩展

- Instrument Test：需 hdc + 真机/模拟器
- 构建产物发布：上传到应用市场或发布到 GitCode Release

## 9. 版本管理

项目内存在两套相互独立的版本号体系。

### 9.1 原生库版本（localsend_ohrs）

原生库版本号唯一来源是 `localsend_ohrs/Cargo.toml` 中的 `version`（镜像上游 localsend fork 基线，如 1.18.1），构建时自动同步到：

| 文件 | 说明 |
|------|------|
| `localsend_ohrs/Cargo.toml` | 唯一来源，手动修改 |
| `localsend_ohrs/package/oh-package.json5` | 构建时自动同步 |
| `localsend_ohrs/package/src/main/cpp/types/liblocalsend_core/oh-package.json5` | 构建时自动同步 |
| `entry/src/main/ets/service/NativeBridge.ets` | 构建时自动同步 |

### 9.2 应用版本（AppScope）

应用版本（上架版本）唯一来源是 `AppScope/app.json5` 的 `versionName` / `versionCode`。`versionCode` 采用「日期 + 序号」格式（如 202609081 = 2026-09-08 当日第 1 个版本）。构建产物中的版本（`module.json` / `pack.info`）只取此处，**升级应用版本仅需修改该文件**。

`entry/oh-package.json5` 的 `version` 仅是模块包元数据（供 ohpm 依赖解析/发布使用），不参与 HAP 产物，固定为 `1.0.0`，不随应用版本升级。

### 9.3 发布版本流程

版本升级/发布使用 **release 构建**与 **release 提交**：

1. 在 `AppScope/app.json5` 修改 `versionName` / `versionCode`
2. release 构建验证（与 build.yml 的 Tag 触发构建一致）：

   ```bash
   devecocli build --build-mode release
   # 等价命令行：hvigorw assembleApp --mode project -p product=default -p buildMode=release
   ```

   产物位于 `entry/build/default/outputs/default/`（signed/unsigned HAP、pack.info、mapping）
3. 归档产物到 `temp/handysend-release/<版本>/`（该目录不入版本控制）
4. 提交版本发布：`release: 发布 <版本>`（如 `release: 发布 1.1.0`）
5. 打 `v<版本>` 标签并推送，触发 build.yml 以 release 模式构建未签名 HAP 产物（作为 GitCode Release 附件）

## 10. 上游同步（fork 定制分支策略）

HandySend 基于 fork 的 `harmony-web-ui` 分支（v1.18.1 基线 + 鸿蒙化定制提交），**不直接跟随 localsend 上游**。同步上游更新按版本节奏进行（如 v1.18.2）。

标准流程（实验分支 + 全量验证后切换，可回退）：

```bash
cd localsend_ohrs/third_party/localsend
git remote add upstream https://github.com/localsend/localsend
git fetch upstream main           # 拉取上游更新
git checkout -b upgrade-<版本>     # 实验分支，不直接改动 harmony-web-ui
git rebase upstream/main             # 把定制提交移植到新基线，解决冲突

# 全量验证：core 测试 + HandySend 桥接编译 + 端到端
cargo test --target x86_64-unknown-linux-gnu --features full

git push -u origin upgrade-<版本>  # 验证通过后推送
```

验证通过后，在主仓库把 submodule gitlink 切到新分支/提交：

```bash
cd <项目根>
git add localsend_ohrs/third_party/localsend
git commit -m "chore: 升级 localsend submodule 至 <版本>"
```

> **升级成本提示**：1.18.2 重构了 core 的 web 接口（`WebConfig` 拆分为 `WebMode`/`WebPages`、`WebSendEvent`→`WebDownloadEvent`），升级时除 submodule rebase 外，还需同步迁移 `localsend_ohrs/rust/bridge/`（adapter 层 `WebSendEvent` 适配、server 模块 WebSend 逻辑）桥接代码，这是主要工作量。

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