# NekoShare 构建指南

从零开始在一台新机器上克隆并构建 NekoShare 的完整步骤。

## 1. 安装前置工具

### 1.1 DevEco Studio

下载安装 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)，安装时勾选 OpenHarmony SDK。

### 1.2 Rust 工具链

```powershell
winget install Rustlang.Rustup
rustup target add aarch64-unknown-linux-ohos
rustup target add x86_64-unknown-linux-ohos
```

### 1.3 ohrs（Rust NAPI 构建工具）

```powershell
cargo install ohrs
```

### 1.4 DevEco Code + DevEco Cli（推荐）

[DevEco Code](https://gitcode.com/openharmony-sig/deveco-code) 是华为提供的 AI 编程助手，[DevEco Cli](https://gitcode.com/openharmony-sig/deveco-cli) 是配套的命令行工具，支持鸿蒙开发文档查询、知识搜索、设备管理等功能。两者独立安装，项目规范中多处依赖 deveco-cli skill，建议都安装以获得最佳开发体验。

```powershell
npm install -g @deveco/deveco-code
npm install -g @deveco/deveco-cli
```

## 2. 克隆项目

```powershell
git clone <repo-url> NekoShare
cd NekoShare
git submodule update --init --recursive
```

将 localsend 上游 submodule 切换到指定 tag（当前为 `v1.18.1`）：

```powershell
cd localsend_ohrs/third_party/localsend
git checkout v1.18.1
cd ../../..
```

> 构建前必须确保 submodule 已检出到正确 tag，否则 Rust 编译可能因上游接口变更而失败。

## 3. 配置环境变量

### 3.1 Windows 路径空格问题

ohrs 不支持含空格的路径。DevEco SDK 默认安装在 `C:\Program Files\...`，需要创建无空格的符号链接：

```powershell
New-Item -ItemType Directory -Force -Path "C:\sdk_link"
New-Item -ItemType Junction -Path "C:\sdk_link\default" -Target "C:\Program Files\Huawei\DevEco Studio\sdk\default"
```

### 3.2 写入系统环境变量（推荐）

将环境变量写入系统配置，构建脚本会优先读取系统环境变量，无需每次依赖 `.env` 文件：

```powershell
[Environment]::SetEnvironmentVariable('DEVECO_HOME', 'C:\Program Files\Huawei\DevEco Studio', 'User')
[Environment]::SetEnvironmentVariable('DEVECO_SDK_HOME', 'C:\Program Files\Huawei\DevEco Studio\sdk', 'User')
[Environment]::SetEnvironmentVariable('OHOS_NDK_HOME', 'C:\sdk_link\default\openharmony', 'User')
[Environment]::SetEnvironmentVariable('JAVA_HOME', 'C:\Program Files\Huawei\DevEco Studio\jbr', 'User')
```

> **注意**：如果不想设置用户环境变量，可跳过此步，改用 3.3 节的 `.env` 文件。构建时需在终端中手动设置这些变量。
> `JAVA_HOME` 也可以不使用 DevEco Studio 提供的版本，自己手动安装 OpenJDK 或 OracleJDK 

同时将常用工具目录加入 PATH（包括 JBR 的 bin 目录，hvigorw 的 PackageHap 阶段需要 `java` 命令）：

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

设置后**重启终端**使环境变量生效。

环境变量一览：

| 变量                | 值                                           | 用途                              |
|-------------------|---------------------------------------------|---------------------------------|
| `DEVECO_HOME`     | `C:\Program Files\Huawei\DevEco Studio`     | build_project 工具、DevEco CLI     |
| `DEVECO_SDK_HOME` | `C:\Program Files\Huawei\DevEco Studio\sdk` | hvigorw SDK 定位（.env 中可用 `$DEVECO_HOME/sdk`） |
| `OHOS_NDK_HOME`   | `C:\sdk_link\default\openharmony`           | ohrs Rust 编译（需无空格路径，用 junction） |
| `JAVA_HOME`       | `C:\Program Files\Huawei\DevEco Studio\jbr` | hvigorw PackageHap 阶段需要 `java`（.env 中可用 `$DEVECO_HOME/jbr`） |

常用命令及默认路径：

| 命令             | 默认路径                                                                       |
|----------------|----------------------------------------------------------------------------|
| `devecostudio` | `C:\Program Files\Huawei\DevEco Studio\bin`                                |
| `ohpm`         | `C:\Program Files\Huawei\DevEco Studio\tools\ohpm\bin`                     |
| `hdc`          | `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains` |
| `hvigorw`      | `C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin`                   |

### 3.3 使用 .env 文件（备选）

如果不写入系统环境变量，项目根目录的 `.env` 文件也会被构建脚本读取：

```powershell
Copy-Item .env.example .env
# 编辑 .env，填入实际路径
```

`.env` 文件格式说明：

- 含空格的值用单引号包裹（如 `DEVECO_HOME='C:\Program Files\...'`），解析时自动剥离引号
- 支持 `$VAR` 和 `${VAR}` 变量引用语法，引用同文件中已定义的变量（如 `DEVECO_SDK_HOME='$DEVECO_HOME/sdk'`）
- 变量按行序解析，被引用的变量必须出现在引用者之前
- 未找到引用变量时保留原文不替换

> 如果运行命令时提示环境变量未定义，先检查系统环境变量，再到 `.env` 中查找。

## 4. 配置构建签名

`build-profile.json5` 包含签名信息，不纳入版本控制：

```powershell
Copy-Item build-profile.example.json5 build-profile.json5
```

在 DevEco Studio 中配置签名：File → Project Structure → Signing Configs。

## 5. 验证环境

```powershell
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

```powershell
# 构建 APP（包含 Rust 编译 + ArkTS 编译 + 打包）
hvigorw assembleApp

# 仅构建 HAR 模块（Rust 原生库）
hvigorw assembleHar
```

首次构建会编译 Rust（约 5-10 分钟），后续自动增量跳过。

## 7. 增量构建机制

BuildRustNapi 任务会检查以下条件，全部满足时跳过 Rust 编译：

1. `package/libs/x86_64/liblocalsend_core.so` 存在
2. `package/libs/arm64-v8a/liblocalsend_core.so` 存在
3. `package/src/main/cpp/types/liblocalsend_core/index.d.ts` 存在
4. 上述文件修改时间均晚于 Rust 源码

跳过时输出：
```
[localsend_ohrs] Rust NAPI is up-to-date, skipping build.
```

### 强制重编 Rust

```powershell
Remove-Item -Recurse -Force localsend_ohrs\package\libs
hvigorw assembleApp
```

## 8. 版本管理

版本号唯一来源是 `localsend_ohrs/Cargo.toml` 中的 `version`，构建时自动同步到：

| 文件 | 说明 |
|------|------|
| `localsend_ohrs/Cargo.toml` | 唯一来源，手动修改 |
| `localsend_ohrs/package/oh-package.json5` | 构建时自动同步 |
| `localsend_ohrs/package/src/main/cpp/types/liblocalsend_core/oh-package.json5` | 构建时自动同步 |
| `entry/src/main/ets/service/NativeBridge.ets` | 构建时自动同步 |

## 9. 上游同步

```powershell
# 更新 LocalSend 上游 submodule
git submodule update --remote localsend_ohrs/third_party/localsend

# 切换到指定 tag
cd localsend_ohrs/third_party/localsend
git checkout v1.18.1
cd ../../..
```

## 10. 故障排除

### ohrs 找不到 toolchain

确保 `OHOS_NDK_HOME` 指向 SDK 根目录：

```
OHOS_NDK_HOME=.../openharmony
```

### Windows 空格路径问题

错误：`OHOS CMake toolchain file not found`

创建无空格符号链接（见第 3.1 节），并在环境变量中使用符号链接路径。

### 类型声明不匹配

Rust 接口变更后类型声明可能不匹配，清理缓存重新构建：

```powershell
hvigorw clean
hvigorw assembleApp
```

### hvigorw 命令找不到

确保 DevEco Studio 的 tools 目录在 PATH 中，或使用完整路径：

```powershell
$env:PATH = "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin;$env:PATH"
```

### PackageHap 阶段报 `spawn java ENOENT`

hvigorw 的 PackageHap 步骤需要 `java` 命令。确保 `JAVA_HOME` 已设置且 `%JAVA_HOME%\bin` 在 PATH 中：

```powershell
$env:JAVA_HOME = "C:\Program Files\Huawei\DevEco Studio\jbr"
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
```

### Rust 编译被意外跳过

删除 libs/ 强制重编：

```powershell
Remove-Item -Recurse -Force localsend_ohrs\package\libs
hvigorw assembleApp
```

或全量清理后重建：

```powershell
hvigorw clean
hvigorw assembleApp
```
