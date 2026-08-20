# 链接分享（Link Sharing）调研与方案评估

> 调研时间：2026-08-15
> 范围：LocalSend 链接分享实现机制、HandySend 接入现状、ArkTS 原生实现 vs 复用 LocalSend 方案对比

## 1. LocalSend 链接分享的实现机制

### 1.1 整体架构

LocalSend 的链接分享本质是**在同一个 HTTP 服务器端口上，额外提供面向浏览器的 Web 页面和 API**。核心实现全部在 Rust core 中（本项目 `localsend_ohrs/third_party/localsend/packages/core/` 已包含完整源码）。

```
浏览器 ──HTTP/TLS──▶ Rust hyper 服务器 (:53317)
                       ├── GET  /                                     → 内嵌 HTML 页面
                       ├── GET  /i18n.json                            → 页面多语言文案
                       ├── POST /api/localsend/v2/prepare-download    → 获取文件列表
                       ├── GET  /api/localsend/v2/download            → 下载文件
                       └── POST /api/localsend/v2/prepare-upload / upload → 浏览器上传
```

### 1.2 两种分享模式

`app/lib/pages/web_share_page.dart` 区分两个方向，由 `WebConfig` 配置（`packages/core/src/http/server/web.rs`）：

| 模式 | 含义 | Rust 配置 | 页面 |
|---|---|---|---|
| Web Send（发送） | 本机选好文件，生成链接+二维码，对方浏览器打开 → 下载本机文件 | `send: Some(WebSendConfig { files, pin })` | `download.html` |
| Web Upload（接收） | 对方浏览器打开链接 → 上传文件到本机 | `upload: true` | `upload.html` |

- 下载模式优先级更高：`WebConfig::send` 设置时 `/` 返回下载页；否则 `upload: true` 时返回上传页；两者都没有则返回 403（此时仅 v2 协议端点可用）。
- 页面文件是编译期嵌入的：`include_str!("../../../assets/web/download.html")`（`web.rs:70-72`）。

### 1.3 关键机制（Rust core）

- **事件驱动授权**：浏览器请求 `prepare-download` 时，服务器发 `WebSendEvent::PrepareDownload { decision_tx }` 给应用层，由用户（或自动接受设置）决定是否允许；同意后返回文件列表 JSON（`PrepareDownloadResponseDtoV2`，含设备信息 + `files`）。同一 IP 重载页面可直接复用已接受的 session。
- **文件内容由应用层提供**：下载时发 `WebSendEvent::FileDownload { content_tx }`，应用通过 `FileContent::{Stream, Path, Fd}` 提供内容，Rust 负责流式传输（`receiver_stream_body`）。
- **TLS 特殊处理**：web 页面激活时，TLS 客户端证书从"强制"变为"可选"（`mandatory_client_auth = app_state.web.is_none() && !app_state.web_upload`，`mod.rs:346`）——因为浏览器没有 LocalSend 客户端证书。
- **PIN 保护**：`WebSendConfig.pin` + IP 级失败次数限制（`LruCache`）。
- **mDNS 广播标记**：`MulticastMessageV2.download: bool` 告知局域网内其他 LocalSend 设备"此设备支持通过链接下载"。

### 1.4 Flutter 端接入方式

`server_provider.dart` 的 `startServer` 接受 `webSendState` / `webUpload` 参数，构造 `WebParams` 传给 Rust `start_server`（`localsend_isolates/rust/src/api/server.rs`），进而组装 `WebConfig`。事件经 `RsHttpServer::listen` 合并流回到 Dart 的 `_handleEvent`。

## 2. HandySend 接入现状

| 层 | 状态 |
|---|---|
| Rust core（third_party） | ✅ web share 已完整实现，含测试（`core/tests/v2_web_send.rs`） |
| Rust 桥接层 `localsend_ohrs/rust/bridge/facade.rs:339` | ❌ `create_share_link` 是 stub，返回空 `url/port/sessionId`；`stop_share_server` 是 no-op |
| Rust 桥接 `start_server`（`server_facade.rs:26`） | ⚠️ 调用 core `start_with_port` 时 web 参数传 `None`，未启用 web |
| ArkTS `AppService.ets` | ✅ `createShareLink`/`stopShareLink`/`getShareLink` 已实现（经 NativeBridge） |
| ArkTS `ShareLinkPage.ets` | ✅ 页面已存在：URL 展示、二维码、复制、停止按钮（含 stub 兜底逻辑） |
| ArkTS `SendModeSelector` / `SendContent` | ✅ 已有"链接分享"发送模式入口 |

结论：HandySend 的 ArkTS UI 与 LocalSend Rust core 之间只差一层 Rust 桥接未接通——`create_share_link` stub 导致当前链接分享实际不可用（页面显示兜底的 `http://<ip>:53317`，浏览器访问只会得到 403，因为 web 未启用）。

## 3. 方案对比

### 3.1 方案 A：ArkTS 原生实现网页分享

用 `@ohos.net.socket.TCPSocketServer` 手写 HTTP 服务器 + ArkWeb 内嵌页面。

| 优点 | 缺点 |
|---|---|
| 不依赖 Rust 桥接层改动 | HarmonyOS 无 HTTP 服务端 API，必须基于 TCP Socket 按 RFC 9112 手写 HTTP 解析（请求行/Header/body/chunked/multipart），工作量大、易错 |
| UI 可完全自定义 | 需自行实现 mDNS 广播、会话管理、PIN、并发连接、大文件流式读写、断点续传，全部从零实现 |
| 无 native 库改动、不重新编译 HAR | 性能远逊 Rust（hyper + tokio 异步流），大文件传输时 ArkTS/JS 层明显吃力 |
| | 与 LocalSend 协议兼容性风险高——其他 LocalSend 设备无法识别/发现此分享 |
| | 无法复用现有 Rust 的接收/校验/进度/发送逻辑，与项目"Rust 核心 + ArkTS 壳"架构相悖 |
| | 双向模式（下载页+上传页）都要重做，工作量约为方案 B 的 5-10 倍 |

### 3.2 方案 B：复用 LocalSend（推荐）

只做 Rust 桥接层"接通"：stub 换成真实实现 + 暴露 web 配置 + 桥接 `WebSendEvent` 回 ArkTS。

| 优点 | 缺点 |
|---|---|
| Rust core 已完整实现 web send/upload（页面、API、会话、PIN、TLS 可选证书全部现成），已有测试覆盖 | 需写 Rust 桥接代码并重新编译 HAR（`localsend_ohrs`） |
| 改动集中在 `localsend_ohrs` 桥接 + ArkTS 事件处理，ArkTS UI（ShareLinkPage/AppService）基本不用重写 | 浏览器页面是 Rust 内嵌的 LocalSend 官方页面（i18n 需配置中文文案，页面样式定制需改 third_party，维护成本增加） |
| 与 LocalSend 协议 v2.2 完全兼容，mDNS 广播自动带 `download: true` | 需设计 WebSendEvent → ArkTS 回调的事件桥（现有 `registerEventListener` 通道可复用） |
| 性能与官方一致，自动获得加密（TLS + 可选客户端证书）、PIN、流式传输 | 依赖 submodule 上游代码（本地 fork 已存在，风险可控） |
| 与项目现有架构完全一致 | |

**工作量估算（方案 B）**：
1. `facade.rs`：`create_share_link` 从 stub 改为真实实现（收集文件 → `WebSendConfig` → 重启服务器带 web 参数 → 返回 URL/port/sessionId）；`stop_share_server` 停止并恢复普通服务器。
2. `start_server`：支持传入 `WebConfig`（参考 `localsend_isolates/rust/src/api/server.rs` 的 `WebParams`）。
3. `WebSendEvent` 事件桥：`PrepareDownload`（决策）与 `FileDownload`（提供文件内容）经现有 callback 通道发给 ArkTS，ArkTS 侧 AppService 增加自动接受/拒绝决策和文件流读取。
4. ArkTS：`ShareLinkPage` 小改（真实 URL），AppService 增加 web 事件处理 + 可选自动接受设置（`shareViaLinkAutoAccept` 偏好已存在）。

## 4. 结论与建议

**推荐方案 B（复用 LocalSend）**：

1. 能力已存在：本项目 fork 的 Rust core 已完整实现链接分享（含下载页/上传页/API/会话/PIN/TLS），且 HandySend 桥接层、ArkTS UI 均已预留接口——缺的只是桥接层接通。
2. 成本最低：方案 A 相当于从零重写 LocalSend 官方已实现且经过测试的整套 web 服务，并放弃协议兼容性。
3. 架构一致：符合项目"一切网络协议走 Rust，ArkTS 只做 UI 和调度"的既有设计。

## 附：关键代码位置

- Rust core web 服务：`localsend_ohrs/third_party/localsend/packages/core/src/http/server/web.rs`
- Rust core 路由注册：`.../core/src/http/server/mod.rs`（`handle_request_inner`）
- Flutter 接入：`.../app/lib/provider/network/server/server_provider.dart`、`.../app/lib/pages/web_share_page.dart`
- HandySend Rust 桥接：`localsend_ohrs/rust/bridge/facade.rs`（stub）、`.../bridge/server_facade.rs`
- HandySend ArkTS：`entry/src/main/ets/service/AppService.ets`、`.../pages/ShareLinkPage.ets`

---

## 5. 链接分享网页替换为鸿蒙风格高保真 HTML

> 评估时间：2026-08-15
> 背景：在方案 B（复用 LocalSend）基础上，进一步评估将浏览器端的 `download.html` / `upload.html` 替换为鸿蒙应用风格高保真 HTML 的可行性。

### 5.1 设计能力来源

- **deveco-mcp（MCP 服务器）无设计能力**：仅提供 `check`（ArkTS/C++ 静态语法分析）与 `restart`（LSP 重启）两个工具。
- **deveco-cli** 的 `layout`/`ui` 子命令仅面向应用内 ArkTS UI 调试（dump ArkUI 布局树），不用于网页设计。
- **具备能力的是本地 skill `hmos-design-visual-mobile`**：
  - 设计 token：`harmony-tokens.css`（548 行语义 token：字体/颜色/间距/圆角）、`mobile-scale.css`（360 画布尺度）
  - 组件模板：statusbar、titlebar、toolbar、list、button、switch、divider、cardview、chipstab、search、bottomtab、aibottombar、size（13 个 `-tem.html`）
  - 图标/字体资源：`HMSymbolVF_1.ttf`（鸿蒙符号字体）、emoji 字体、statusbar PNG、ProgressBar SVG
  - 默认主题色：Harmony 品牌蓝 `--harmony-brand: rgba(10,89,247,1)`
  - 限制：面向移动端单屏（360×792 画布 + 系统壳层），组件契约（如 `.harmony-list` 固定 `width: 328px`）偏向手机画布。

### 5.2 现状约束

LocalSend 网页的两个特点：

1. **单文件纯 HTML/JS、零外部依赖**，经 `include_str!` 编译进 Rust 二进制（`web.rs:70-72`）。
2. **JS 与 Rust 的 API 契约**（替换时必须原样保留）：
   - `GET /i18n.json` → 多语言文案
   - `POST /api/localsend/v2/prepare-download` → 获取文件列表（含 PIN/403/429 处理）
   - `GET /api/localsend/v2/download?sessionId=&fileId=` → 下载
   - `POST /prepare-upload` / `POST /upload` → 上传流程（含 401/403/409/429/204 处理）

### 5.3 替换路线对比

| 路线 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| A. 内联单文件替换（推荐） | 用 hmos-design-visual-mobile 生成鸿蒙风格页面，CSS/JS/字体/图标全部内联为单 HTML，直接替换 `assets/web/download.html`、`upload.html` | 改动最小，`include_str!` 链路不变，全设备自动生效；skill 支持独立 HTML token 兜底 | 字体 base64 内联使文件变大；放弃 IE8 兼容 |
| B. 扩展 Rust 路由 serve 资源 | 改 `web.rs` serve 资源目录（字体/PNG/CSS 分开加载） | 页面可引用外部资源，设计自由度大 | 需改 third_party，改动大、维护成本高 |

### 5.4 关键约束与工作量

关键约束：

1. **JS 逻辑保留、UI 重写**：XHR、PIN 弹窗、错误码映射、sessionStorage 逻辑必须完整保留，只替换 DOM 结构与样式层。
2. **响应式适配**：链接分享页可能在手机或桌面浏览器打开；skill 默认 360 移动画布，需 `@media` 断点适配，为主要增量工作。
3. **i18n 文案接入**：页面文案来自 `/i18n.json`，需将 `i18n.waiting/enterPin/rejected/files/size` 等映射进新 UI（如 PIN 弹窗改鸿蒙对话框样式）。
4. **文件体积与兼容性**：内联字体后单文件可达数百 KB；仅支持现代浏览器（可接受，需知悉）。
5. **third_party 为 fork**：修改 `assets/web/*.html` 属改动 submodule，上游升级可能冲突（当前已为本地 fork，风险可控）。

工作量估算（路线 A）：

| 任务 | 工作量 |
|---|---|
| 鸿蒙风格 `download.html`（文件列表 + PIN 对话框 + 状态页） | 中 |
| 鸿蒙风格 `upload.html`（选择文件 + 上传进度 + 状态页） | 中 |
| 响应式适配（移动 + 桌面） | 中 |
| 资源内联化 + 编译验证（HAR 构建） | 小 |
| 协议 JS 逻辑移植与端到端联调 | 中 |

### 5.5 结论

1. deveco-mcp 无设计能力；鸿蒙高保真 HTML 设计能力在 `hmos-design-visual-mobile` skill。
2. 替换完全可行，推荐路线 A（内联单文件替换）：保留 API 契约与 JS 逻辑，重写视觉层为鸿蒙风格。
3. 桥接接通（第 3.2 节方案 B）解决"功能可用"，网页鸿蒙化解决"视觉美观"，两个方向相互独立、可叠加。
4. 主要风险：响应式适配、内联后文件体积、third_party fork 维护差异。
