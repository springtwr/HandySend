# HandySend（便捷快传）

基于鸿蒙原生实现的跨设备文件传输应用，兼容 LocalSend 协议与互传联盟（MTA）。

HandySend 通过 NAPI 桥接调用 Rust 编写的协议核心库，在 HarmonyOS NEXT 上实现局域网内跨设备文件/剪贴板/文本传输，并可与互传联盟设备经蓝牙发现 + Wi-Fi Direct 直连互传文件与文本，无需同一 Wi-Fi。

## 获取应用

从 [华为应用市场（AppGallery）](https://appgallery.huawei.com/app/detail?id=com.springtwr.handysend) 下载 HandySend（搜索"便捷快传"）。

应用详情与截图请在应用市场查看，本仓库面向开发与贡献。

## 功能

- **文件传输** — 发送和接收任意文件
- **图片传输** — 从系统相册选取图片发送
- **剪贴板共享** — 一键将剪贴板内容发送到其他设备，或接收其他设备的剪贴板
- **文本发送** — 手动输入文本发送到目标设备
- **链接分享** — 生成二维码链接，对方扫码即可下载文件
- **设备发现** — 自动扫描局域网内运行 LocalSend/HandySend 的设备
- **互传联盟（MTA）互传** — 与荣耀/小米/OPPO/vivo 等互传联盟设备直连互传文件与文本（蓝牙发现 + Wi-Fi Direct，无需同一 Wi-Fi）
- **加密传输** — 基于 HTTPS 的端到端加密传输
- **收藏设备** — 收藏常用设备，快速发送
- **自动确认请求** — 可配置自动接受传入文件请求，免确认开始传输
- **自动完成** — 传输完成后自动退出传输页
- **传输取消** — 发送/接收任意阶段均可取消
- **接收历史** — 记录接收的文件与文本消息
- **相册保存** — 通过安全控件将接收的媒体保存到系统相册
- **校验和** — 传输前后 SHA-256 校验，可验证文件完整性
- **指纹验证** — 基于 SHA-256 指纹的图标化身份验证
- **深色模式** — 自动适配系统深色模式
- **响应式 UI** — 适配手机、平板、2in1 设备

## 与其他 LocalSend 客户端协作

HandySend 实现了 LocalSend v2 协议，可与以下客户端互相传输：

- [LocalSend](https://github.com/localsend/localsend) (Android / iOS / Windows / macOS / Linux)
- 其他兼容 LocalSend 协议的第三方客户端

确保所有设备连接到同一 Wi-Fi 网络即可自动发现。

## 与互传联盟设备协作

HandySend 实现了互传联盟（MTA）协议，可与联盟成员的「分享」功能互通，例如荣耀分享、小米互传、OPPO/一加/真我互传、vivo 互传等。

互传不要求双方在同一 Wi-Fi：设备先通过蓝牙低功耗（BLE）互相发现并交换连接凭据，再经 Wi-Fi Direct 直连完成 WebSocket 协商与 HTTPS/ZIP 文件传输。

> 目前已在荣耀真机上完成双向互传验证，其余品牌待验证。

## 技术栈

| 层级 | 技术 |
|------|------|
| UI 框架 | ArkUI (ArkTS) |
| 通信协议 | LocalSend v2 (HTTP/HTTPS + UDP 组播发现) |
| 互传联盟协议 | MTA（BLE 发现 + Wi-Fi Direct + WebSocket 协商 + HTTPS/ZIP 传输） |
| 原生桥接 | HarmonyOS NAPI |
| 协议核心 | Rust → `liblocalsend_core.so` (HAR: `localsend_ohrs`) |
| 构建工具 | Hvigor / DevEco Studio |

## 快速开始

本部分面向开发者，目标是**以最少的步骤验证代码可构建**。暂时跳过 Lefthook 等仅在提交代码时才需要的前置工具，不影响构建。

### 前置条件（必需）

- [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/) (26.0.0+)
- Rust 工具链（含 `aarch64-unknown-linux-ohos` target）
- [ohrs](https://crates.io/crates/ohrs)（Rust NAPI 构建工具，`cargo install ohrs`）

### 最小构建步骤

1. 克隆仓库（含 submodule）
   ```bash
   git clone https://gitcode.com/springtwr/HandySend.git
   cd HandySend
   git submodule update --init
   ```

2. 检出 submodule 定制分支（**必须**，否则 Rust 编译可能因上游接口变更而失败）
   ```bash
   cd localsend_ohrs/third_party/localsend
   git checkout harmony-web-ui
   cd ../../..
   ```

3. 复制项目配置文件（**必须**，否则 DevEco Studio 无法识别为鸿蒙项目）
   ```bash
   cp build-profile.example.json5 build-profile.json5
   cp .env.example .env
   ```

4. 配置环境变量 — 编辑上一步复制的 `.env` 文件，写入正确的变量路径，或直接将它们设置为系统变量。Windows 需额外处理 OHOS NDK 路径空格问题。

5. 在 DevEco Studio 中配置签名：File → Project Structure → Signing Configs

6. 验证环境
   ```bash
   ohrs doctor
   ```

7. 构建
   ```bash
   hvigorw assembleApp
   ```

   首次构建包含 Rust 编译（约 5-10 分钟），后续增量跳过。

### 可跳过项（提交代码时才需要）

| 工具 | 说明 |
|------|------|
| Lefthook / commitlint / gitleaks | Git Hooks，仅在 `git commit` 时触发，构建验证无需安装 |
| DevEco Code / DevEco Cli | 推荐但非必需 |
| 模拟器架构 (`x86_64`) | 仅在使用模拟器时配置 `OHRS_BUILD_ARCHS=arm64,x86_64` |

> 完整构建指南（环境变量详解、跨平台配置、故障排除等）见 [docs/BUILD.md](docs/BUILD.md)；开发流程（分支、submodule 工作流、上游升级）见 [docs/DEVELOPMENT_WORKFLOW.md](docs/DEVELOPMENT_WORKFLOW.md)。

## 参与贡献

欢迎提交 Issue 与 Pull Request！详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 赞助

觉得好用的话可以给开发者赞助一点 token，助力项目更好发展：[爱发电](https://ifdian.net/a/springtwr)

## 协议

本项目基于 [Apache License 2.0](LICENSE) 开源。

## 致谢

- [LocalSend](https://github.com/localsend/localsend) — 优秀的跨平台局域网传输工具，HandySend 的协议参考与核心实现
- [NekoShare](https://gitcode.com/loar/NekoShare) — HandySend 最初的起点，项目最早基于 NekoShare 修改与扩展；其快速构建鸿蒙应用的流程为 HandySend 提供了重要参考
- [CatShare](https://github.com/kmod-midori/CatShare) — 互传联盟（MTA）协议的开源实现，HandySend 的 MTA 收发流程、消息格式与 taskId/id 字段约定均以其为对照参考（MIT，Copyright 2025 Midori Kochiya）
- [EasyShare](https://github.com/HotKids/EasyShare) — 基于 CatShare 重构的互传联盟实现，HandySend 的 MTA 品牌图标资源取自该项目（MIT，Copyright 2025 Midori Kochiya）
- [OPPOShareReceiver](https://github.com/testmybest/OPPOShareReceiver) — 互传联盟协议解析与设备信息字段约定的参考实现（GPL-3.0）
