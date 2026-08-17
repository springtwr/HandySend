# NekoShare

基于鸿蒙原生实现的 [LocalSend](https://github.com/localsend/localsend) 兼容客户端。

NekoShare 通过 NAPI 桥接调用 Rust 编写的 LocalSend v2 协议核心库，在 HarmonyOS NEXT 上实现局域网内跨设备文件/剪贴板/文本传输。

## 功能

- **文件传输** — 发送和接收任意文件
- **图片传输** — 从系统相册选取图片发送
- **剪贴板共享** — 一键将剪贴板内容发送到其他设备，或接收其他设备的剪贴板
- **文本发送** — 手动输入文本发送到目标设备
- **链接分享** — 生成二维码链接，对方扫码即可下载文件
- **设备发现** — 自动扫描局域网内运行 LocalSend/NekoShare 的设备
- **加密传输** — 基于 HTTPS 的端到端加密传输
- **收藏设备** — 收藏常用设备，快速发送
- **自动保存** — 可配置自动保存接收到的文件
- **深色模式** — 自动适配系统深色模式
- **响应式 UI** — 适配手机、平板、2in1 设备

## 技术栈

| 层级 | 技术 |
|------|------|
| UI 框架 | ArkUI (ArkTS) |
| 通信协议 | LocalSend v2 (HTTP/HTTPS + mDNS) |
| 原生桥接 | HarmonyOS NAPI |
| 协议核心 | Rust → `liblocalsend_core.so` (HAR: `localsend-ohrs`) |
| 构建工具 | Hvigor / DevEco Studio |

## 开始使用

### 前置条件

- [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/) (5.0+)
- HarmonyOS NEXT SDK (API 13+)

### 构建

1. 克隆仓库（含 submodule）
   ```bash
   git clone https://gitcode.com/loar/NekoShare.git
   cd NekoShare
   git submodule update --init --recursive
   ```

2. 准备项目配置文件（**必须**，否则 DevEco Studio 无法识别为鸿蒙项目）
   ```bash
   cp build-profile.example.json5 build-profile.json5
   cp .env.example .env
   ```

3. 在 DevEco Studio 中配置签名：File → Project Structure → Signing Configs

4. 连接设备或启动模拟器，点击 **Run** 运行

> 完整的构建指南（环境变量、跨平台配置、故障排除等）见 [docs/BUILD.md](docs/BUILD.md)。

## 与其他 LocalSend 客户端协作

NekoShare 实现了 LocalSend v2 协议，可与以下客户端互相传输：

- [LocalSend](https://github.com/localsend/localsend) (Android / iOS / Windows / macOS / Linux)
- 其他兼容 LocalSend 协议的第三方客户端

确保所有设备连接到同一 Wi-Fi 网络即可自动发现。

## 协议

本项目基于 [Apache License 2.0](LICENSE) 开源。

## 致谢

- [LocalSend](https://github.com/localsend/localsend) — 优秀的跨平台局域网传输工具，NekoShare 的协议参考实现
