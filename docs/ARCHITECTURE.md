# HandySend（便捷快传）架构文档

> 当项目结构、核心模块、API 接口等发生变更时，必须同步更新本文件。

## 1. 项目概述

HandySend 是基于 [LocalSend](https://github.com/localsend/localsend) v2 协议的 HarmonyOS NEXT 局域网文件共享客户端，通过 NAPI 桥接 Rust 协议核心库。

| 属性 | 值 |
|------|------|
| Bundle Name | `com.springtwr.handysend` |
| Target SDK | 6.1.1(24) |
| Compatible SDK | 6.0.0(20) |
| 许可证 | Apache License 2.0 |

## 2. 技术栈

| 层级 | 技术 |
|------|------|
| UI | ArkUI (ArkTS) |
| 协议 | LocalSend v2 (HTTP/HTTPS + mDNS/UDP) |
| 原生桥接 | HarmonyOS NAPI (napi-ohos 1.2) |
| 协议核心 | Rust → `liblocalsend_core.so` (HAR: `localsend_ohrs`) |
| 构建 | Hvigor / DevEco Studio / ohrs |
| 持久化 | Preferences (key-value) |
| 高端组件 | @kit.UIDesignKit (HdsTabs, SDK>=23) |

## 3. 目录结构

```
HandySend/
├── AppScope/                    # 应用级资源（图标、字符串）
├── entry/                       # 主模块
│   ├── src/main/
│   │   ├── module.json5         # 模块配置（权限、Ability、skill）
│   │   └── ets/
│   │       ├── entryability/    # EntryAbility 应用入口
│   │       ├── pages/           # 页面
│   │       ├── components/      # UI 组件
│   │       ├── service/         # 业务服务
│   │       ├── model/           # 数据类型（Types, NativeTypes）
│   │       ├── common/          # DesignTokens 设计常量
│   │       └── utils/           # 工具函数
│   └── build-profile.json5     # 模块构建配置（含签名，gitignore）
├── localsend_ohrs/              # Rust 原生 HAR 模块
│   ├── Cargo.toml               # ★ 版本号唯一来源
│   ├── rust/                    # Rust 源码
│   ├── package/                 # DevEco HAR 包结构
│   │   ├── hvigorfile.ts        # BuildRustNapi 任务（版本同步 + 增量构建）
│   │   ├── Index.ets            # HAR 入口
│   │   └── libs/                # .so 产物（gitignore，增量判断依据）
│   └── third_party/localsend/   # Git submodule (上游仓库)
├── build-profile.json5          # 全局构建配置（gitignore）
└── oh-package.json5             # 全局依赖
```

## 4. 核心模块

### 4.1 EntryAbility

`entry/src/main/ets/entryability/EntryAbility.ets`

- 处理系统分享 Intent（`ohos.want.action.sendData/sendMultipleData`）
- 始终加载 `MainTabFloating` 页面
- 窗口创建后注册 MaterialIcons 自定义字体（用于指纹图标渲染）

### 4.2 AppService ★ 核心业务

`entry/src/main/ets/service/AppService.ets`

管理服务器生命周期、设备发现、文件传输、状态订阅。主要导出函数：

| 函数 | 说明 |
|------|------|
| `initAppService(context)` | 初始化，加载设置到 AppStorage，注册 Rust 事件回调 |
| `startLocalServer()` / `stopLocalServer()` | 启停服务器 + Rust discovery + 请求轮询 |
| `reloadServerSettings()` | 热重载服务器（停→启→失败回滚） |
| `sendToDevice(device, files)` | 发送文件（含 HTTPS/HTTP 协议协商） |
| `respondToRequest(sessionId, accept)` | 响应接收请求 |
| `createShareLink(files)` / `stopShareLink()` | 分享链接管理 |
| `startWebUpload()` | 启动 Web Upload 模式（浏览器上传） |
| `rescanDevices()` | Rust announce + staged discover |
| `handleNativeEvent(eventJson)` | 统一处理 Rust 回调事件（discovery/server/web share） |

事件回调机制（`register_event_listener`）：
- Rust 侧通过 `ThreadsafeFunction` 从 tokio 线程推送事件到 ArkTS 主线程
- 所有事件通过 `handleNativeEvent()` 按 `type` 字段分发
- `discovery_update`：设备列表更新（替代旧的 1 秒轮询）
- `prepare_upload`：接收文件请求（替代 `pollPendingRequests` 主流程）
- `register`：设备注册反馈到 discovery store
- `session_end` / `cancel_received`：会话结束/取消通知
- `progress_update`：传输进度实时推送（direction: recv/send/share，替代旧 poll 机制）
- `prepare_download`：Web 分享时浏览器请求下载文件（需 accept/decline）
- `file_download`：Web 分享时浏览器正在下载文件（Rust 侧自动处理文件流）

进度推送机制：
- Rust 侧在文件传输进度更新时（20ms 节流后），通过 `EventCallback.call()` 推送 `progress_update` 事件
- ArkTS 侧在 `handleProgressUpdate()` 中处理单个进度事件，更新 `activeProgress` 和 `AppStorage`
- 接收进度完成时触发会话完成逻辑：文件导出、历史记录、auto-finish、清理
- 发送进度由 callback 驱动实时更新，会话完成由 `sendToDevice`/`sendToDeviceMulti` 的 Promise 流程处理
- 旧的 `setInterval` poll 定时器和 `doPollProgress` 函数已删除
- `CANCEL_EVENT_FILE_ID` hack 已删除，改为使用 `cancel_received` 事件

协议协商（加密不可降级策略）：
1. 发送端启用HTTPS + 接收端支持HTTPS → 使用HTTPS
2. 发送端启用HTTPS + 接收端不支持HTTPS → 错误，拒绝降级
3. 发送端禁用HTTPS + 接收端支持HTTPS → 使用HTTP（对方服务器同时接受HTTP）
4. 发送端禁用HTTPS + 接收端不支持HTTPS → 使用HTTP

`senderProtocol`：接收端通过 `cert_fingerprint` 是否存在判断发送端协议（有证书→HTTPS，无证书→HTTP），存入 `PendingRequest.senderProtocol`，用于接收对话框验证按钮状态。

### 4.3 NativeBridge — NAPI 桥接

`entry/src/main/ets/service/NativeBridge.ets`

从 `localsend_ohrs` HAR 导入 Rust NAPI 函数，封装为 `native*` 函数并做类型转换。关键设计：HAR 接口参数为 JSON 字符串，NativeBridge 负责 `JSON.stringify` + 类型映射。

新增 NAPI 函数（v1.18.1 协议对齐）：

| 函数 | 说明 |
|------|------|
| `nativeStartDiscoveryV2(config)` | 完整配置启动 Rust discovery（替代旧 DiscoveryService） |
| `nativeDiscoveryAnnounce()` | 发送 announce burst |
| `nativeDiscoveryDiscoverStaged(channels, ips, port, protocol, graceMs)` | 分阶段发现（announce → probe favorites → subnet scan） |
| `nativeDiscoveryScanSubnet(ip, port, protocol)` | 扫描子网 |
| `nativeDiscoveryAddDevice(device)` | 将 server register 事件反馈给 discovery store |
| `nativeDiscoverySetAnswerAnnouncements(answer)` | 控制 discovery 是否回应 announce |
| `nativeDiscoveryStop()` | 停止 discovery |
| `nativeDiscoveryGetDevices()` | 获取当前设备列表 |
| `nativeDiscoveryGetDevice(fingerprint)` | 按 fingerprint 查询设备 |
| `nativeDiscoveryMulticastError()` | 获取 multicast 错误 |
| `nativeClientInfo(protocol, ip, port)` | GET /api/localsend/v2/info |
| `nativeComputeFingerprintHash(combined)` | SHA-256 哈希，用于指纹图标计算 |
| `nativeAcceptWebDownload(sessionId)` | Web 分享：接受浏览器下载请求 |
| `nativeDeclineWebDownload(sessionId)` | Web 分享：拒绝浏览器下载请求 |
| `nativeStartWebUpload()` | Web 分享：启动浏览器上传模式，返回 port |
| `registerEventListener(callback)` | 注册 Rust 事件回调 |

证书固定（`expectedFingerprint`）：`sendFiles` → `prepare_send` / `upload_file` 传递目标指纹，Rust 层在 HTTPS 连接时验证服务端证书。

### 4.4 Discovery — 设备发现（已迁移到 Rust 核心）

设备发现已完全迁移到 Rust 核心的 `localsend::discovery` 模块，ArkTS 层不再有自实现。

Rust 核心发现功能：
- **UDP 组播**：`224.0.0.167:53317`，支持 hot-restart（新实例自动停止旧实例）
- **分阶段发现**（`discover_staged`）：announce → probe favorites → wait grace period → fallback subnet scan
- **设备 store**：去重、多 channel 合并、ranked channels、超时清理
- **事件推送**：通过 `discovery_update` callback 实时推送设备列表变化
- **网络过滤**：支持 InterfaceFilter（whitelist/blacklist）

旧的 `DiscoveryService.ets`（580 行 UDP 自实现）已删除。

### 4.5 DialogService — 弹窗服务

`entry/src/main/ets/service/DialogService.ets`

统一管理弹窗，不要在页面中直接创建 AlertDialog。

## 5. Rust NAPI 层

`localsend_ohrs/rust/`

```
lib.rs (NAPI 入口)
  ├── #[napi(object)] 结构体：ProgressInfo, ServerHandle, SendResult 等
  ├── 高层 API：createServer, sendFiles, pollSendProgress 等
  ├── Discovery API：startDiscoveryV2, discoveryAnnounce, discoveryDiscoverStaged 等
  ├── Client API：clientInfo, registerDevice, prepareSend, uploadFile 等
  └── bridge/
       ├── facade.rs          # 公共工具函数（init, parse helpers, crypto, query, debug）
       ├── server_facade.rs   # 服务器生命周期、事件处理、接收进度
       ├── client_facade.rs   # HTTP 客户端操作（发送、注册、取消、clientInfo）
       ├── discovery_facade.rs # 完整 discovery 接口（start_discovery_v2, announce, discover_staged, scan_subnet, add_device, 事件监听 task）
       ├── state.rs           # BridgeState 单例 + 进度共享状态
       ├── callback.rs        # EventCallback (ThreadsafeFunction)
       └── runtime.rs         # Tokio runtime 管理
```

进度追踪：发送端 `upload_file()` 每 512KB chunk 更新进度（20ms 节流），写入 HashMap 后立即通过 `EventCallback.call()` 推送 `progress_update` 事件；接收端通过 `progress_tx` 通道更新，同样在写入 HashMap 后推送 callback。状态存储 `Arc<Mutex<HashMap<String, ProgressEntry>>>`。

事件推送：所有事件（discovery/server/web share）通过统一 `register_event_listener` 回调推送，ArkTS 侧按 `type` 字段分发。

### Web Share 架构

Web Share 功能通过按需启停服务器实现，不依赖独立服务：

**Web Send（浏览器下载设备文件）**：
1. `create_share_link(files)` → 解析文件 → 停止当前服务器 → 构造 `WebConfig{send: Some(WebSendConfig), upload: false}` → 重启服务器 → 启动 `WebSendEvent` 处理 task → 返回分享 URL
2. 浏览器访问 URL → Rust HTTP server 返回下载页面 → 浏览器请求下载 → `WebSendEvent::PrepareDownload` 推送到 ArkTS
3. ArkTS 根据 `quickSaveMode` 决定 auto-accept 或弹窗确认 → 调用 `nativeAcceptWebDownload`/`nativeDeclineWebDownload`
4. 浏览器下载文件时 `WebSendEvent::FileDownload` → Rust 通过 `FileContent::Path` 自动提供文件流
5. `stop_share_server()` → 停止服务器 → 清理 web 状态 → 用普通配置重启服务器

**Web Upload（浏览器上传文件到设备）**：
1. `start_web_upload()` → 停止当前服务器 → 构造 `WebConfig{send: None, upload: true}` → 重启服务器 → 返回 port
2. 浏览器访问 URL → 上传文件 → 触发 `prepare_upload`/`file_upload` 事件（复用 v2 接收流程）
3. auto-accept 行为与普通 v2 接收一致（`shouldAutoAccept`）

**关键设计**：
- `BridgeState.receive_pin`：服务器启动时保存 PIN，Web Share 重启服务器时自动复用
- `BridgeState.web_send_files`：fileId→filePath 映射，FileDownload 时提供 `FileContent::Path`
- `BridgeState.web_download_decisions`：sessionId→oneshot channel，accept/decline 发送决策
- `WebI18n`：中文文案（waiting/enterPin/invalidPin 等），由 Rust 构造传给 Web 页面

## 6. 类型定义

### 应用层 (model/Types.ets)

| 类型 | 说明 |
|------|------|
| `DiscoveredDevice` | 发现的设备（alias, ip, port, fingerprint, channels, lastSeen 等） |
| `DeviceChannel` | 设备通道（host, port, protocol） |
| `PendingRequest` | 待处理请求（sessionId, senderAlias, senderFingerprint, senderProtocol, files[]） |
| `TransferProgress` | 传输进度（sessionId, fileId, bytesSent, totalBytes） |
| `SendFileItem` | 待发送文件（fileId, filePath, fileName, size） |
| `FavoriteDevice` | 收藏设备 |
| `ReceiveHistoryEntry` | 接收历史条目 |
| `QuickSaveMode` | 枚举：off / paired / on |
| `SendMode` | 枚举：single / multiple / link |
| `SendSessionStatus` | 发送会话状态枚举 |

### NAPI 层 (model/NativeTypes.ets)

与 Rust `#[napi(object)]` 结构体一一对应：`NativeServerConfig`, `NativeServerHandle`, `NativeServerStatus`, `NativeTargetDevice`, `NativeTransferRequest`, `NativeProgressInfo`, `NativeFileToSend`, `NativeSendResult`, `NativeShareLinkInfo`, `NativeRecvDiag` 等。

新增 discovery 相关类型：`NativeDiscoveryConfig`, `NativeDiscoveredDevice`, `NativeDeviceChannel`, `NativeInterfaceFilter`。

新增 Web Share 事件类型：`NativeWebSendPrepare`（prepare_download 事件）、`NativeWebSendFileDownload`（file_download 事件）。

特殊常量：~~`CANCEL_EVENT_FILE_ID`~~ 已删除，取消通知改用 `cancel_received` 事件。

## 7. 测试体系

### 7.1 测试类型与目录结构

采用 **Local Test（本地单元测试）**：运行于预览引擎，无需真机/模拟器，仅支持 Stage 模型，不支持测试 C/C++ 方法及系统 API。

```text
entry/src/test/                      # entry 模块 Local Test
├── List.test.ets                    # 测试入口（挂载全部测试套件）
├── MimeUtils.test.ets               # MIME 工具函数（纯函数，边界情况多）
├── ThemeStyles.test.ets             # 主题样式查找与唯一性验证
├── PreferencesUtil.test.ets         # 偏好设置（未初始化分支降级行为）
├── FavoritesService.test.ets        # 收藏服务 CRUD + 去重/溢出/别名同步
└── ReceiveHistoryService.test.ets   # 接收历史服务 FIFO + MAX_HISTORY 边界
```

**未测试模块**（Local Test 限制）：依赖系统 API（`@kit.ArkData` preferences、`@kit.AbilityKit` context）的 `init*` 函数；依赖 native `.so` 的 NativeBridge；依赖 UIContext 的 DialogService；页面/组件（UI 层需 Instrumented Test）。

### 7.2 运行命令

```bash
# entry 模块全部 Local Test
hvigorw test -p module=entry

# 指定测试套件（scope 格式：{suiteName}#{methodName} 或 {suiteName}）
hvigorw test -p module=entry -p scope=MimeUtilsTest#*
```

## 8. UI 架构
### 页面路由

| 页面 | 用途 |
|------|------|
| `MainTabFloating` | 主页（三个 Tab：Send/Receive/Settings） |
| `TransferPage` | 传输进度（send/receive/clipboard/text 模式） |
| `ShareLinkPage` | 分享链接 + 二维码 |
| `DeviceDetailsPage` | 设备详情 |
| `ReceiveOptionsPage` | 接收选项 |
| `ReceiveHistoryPage` | 接收历史 |
| `VerifyPage` / `TroubleshootPage` | 验证/故障排除 |
| `LanguagePage` | 语言设置 |
| `DebugPage` / `HttpLogsPage` / `DiscoveryDebugPage` | 调试页面 |

### 主页面结构

```
MainTabFloating
├── SendContent (文件/图片/剪贴板/文本 + 设备列表)
├── ReceiveContent (本机信息 + 收藏设备)
└── SettingsContent (通用/网络设置 + 反馈/关于半屏弹窗)
```

### 浮动 Tab 栏

双架构实现，运行时根据 `deviceInfo.sdkApiVersion` 选择：

- **API >23**：`HdsTabs` + `barOverlap(true)` + `barFloatingStyle` + `bindScroller` + `applyHideAnimation`/`applyShowAnimation`（系统内置动画）
- **API ≤23**：`Tabs` + `barHeight(0)` + `Stack` 覆层自定义浮动 Tab 栏，`animateTo` 手动偏移+透明度动画

滚动显示/隐藏逻辑：
- 子组件通过 `onScrollDelta(deltaY, absY)` 回调报告滚动增量和绝对偏移
- `absY ≤ 20` 时永远不隐藏（防止顶部回弹抖动）
- Tab 切换时自动恢复显示
- `-999` 哨兵值表示内容到达顶部，强制显示

### 半屏弹窗

设置页的反馈和关于功能使用 `bindSheet` 半屏弹窗，共享单一 `isShowSheet` + `sheetMode` 状态：

| sheetMode | 内容 |
|-----------|------|
| `feedback` | 反馈描述 + 应用市场按钮 + 代码仓库按钮 |
| `about` | 版本信息卡片（HandySend/LocalSend/协议版本）+ 仓库地址卡片 |

### 响应式设计

- 手机 (320-520vp)：底部水平 Tab 栏
- 平板/宽屏：侧边垂直 Tab 栏 (barWidth=96)
- 内容最大宽度：800vp
- 深色模式：完整 `dark/` 资源覆盖

## 9. 状态管理

- 页面级状态：`@State`
- 跨组件共享：`AppStorage` + `@StorageLink`/`@StorageProp`
- 持久化偏好：`PreferencesUtil`（存储名 `handysend_settings`）

主要 AppStorage 键：`serverReady`, `serverNeedsRestart`, `sharedFileUris`, `recvTransferCompleted`, `recvTransferCancelled`, `recvTextMessage`, `autoSaveMode`, `favoriteDevices`, `encryptedTransfer` 等。

## 10. 权限

| 权限 | 说明 |
|------|------|
| `ohos.permission.INTERNET` | 网络访问 |
| `ohos.permission.GET_NETWORK_INFO` | 获取网络信息 |

注册的 skill：主屏启动 (`ohos.want.action.home`) + 系统分享接收 (`ohos.want.action.sendData/sendMultipleData`)

## 11. 功能特性

文件传输、图片传输、剪贴板共享、文本发送、链接分享（二维码 + Web Send 浏览器下载）、Web Upload（浏览器上传）、UDP 组播 + HTTP 子网扫描设备发现、HTTPS 加密传输、收藏设备、自动保存（off/paired/on，Web Share 复用相同逻辑）、深色模式、外部分享、传输取消、PIN 保护（Web Share 复用 receivePin）、校验和（SHA-256）、接收历史、指纹验证（Material Icons 图标体系 + SHA-256 哈希对齐 LocalSend v1.18）。

## 12. 注意事项

1. **浮动 Tab 栏双架构**：API>23 用 HdsTabs 内建 API，API≤23 手动 Tabs+Stack 实现
2. **NativeBridge 类型转换层**：HAR 接口返回 `#[napi(object)]` 结构体，映射到 NativeTypes
3. **进度推送**：Rust 侧通过 `progress_update` callback 事件实时推送，20ms 节流，无传输时 CPU=0
4. **文件导出依赖用户交互**：DocumentViewPicker 选择保存位置
5. **AppStorage 作为事件总线**：recvTransferCompleted 等跨组件通知
6. **ohrs 路径限制**：Windows 不支持含空格路径，需符号链接
7. **版本同步**：Cargo.toml 为唯一来源，构建时自动同步到 oh-package.json5 和 NativeBridge.ets
8. **MaterialIcons 字体**：Flutter SDK 的 MaterialIcons-Regular.otf 注册为自定义字体，用于指纹图标渲染
