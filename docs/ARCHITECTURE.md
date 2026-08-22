# HandySend（便捷快传）架构文档

> 当项目结构、核心模块、API 接口等发生变更时，必须同步更新本文件。

## 1. 项目概述

HandySend 是基于 [LocalSend](https://github.com/localsend/localsend) v2 协议的 HarmonyOS NEXT 局域网文件共享客户端，通过 NAPI 桥接 Rust 协议核心库。

| 属性 | 值 |
|------|------|
| Bundle Name | `com.springtwr.handysend` |
| Target SDK | 6.1.1(24) |
| Compatible SDK | 6.1.0(23) |
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
│   │       ├── pages/           # 页面（纯组装）
│   │       ├── components/      # 页面级内容组件（SendContent/ReceiveContent/SettingsContent）
│   │       ├── views/           # 可复用视图组件（含 views/settings/ 设置分组）
│   │       ├── service/         # 业务服务（AppService 门面 + NativeBridge + DialogService）
│   │       ├── service/repository/  # 按业务域拆分的 Repository + AppCore 共享层
│   │       ├── viewmodel/       # 视图模型（@ObservedV2）
│   │       ├── model/           # 数据类型（Types, NativeTypes）
│   │       ├── common/          # DesignTokens 设计常量 + LogDomains 日志域
│   │       └── utils/           # 工具函数（Logger 统一日志模块）
│   └── build-profile.json5     # 模块构建配置（含签名，gitignore）
├── localsend_ohrs/              # Rust 原生 HAR 模块
│   ├── Cargo.toml               # ★ 版本号唯一来源
│   ├── rust/                    # Rust 源码
│   ├── package/                 # DevEco HAR 包结构
│   │   ├── hvigorfile.ts        # BuildRustNapi 任务（版本同步 + 增量构建 + index.d.ts 一致性守卫）
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

### 4.2 AppService ★ 核心业务门面

`entry/src/main/ets/service/AppService.ets`

AppService 是业务层的门面（facade）：初始化编排、Rust 事件分发、服务器生命周期组合（服务器 + 请求轮询）。VM/View 统一从门面导入，门面通过 re-export 暴露 Repository 函数。业务逻辑按领域拆分到 `service/repository/`：

| 文件 | 职责 |
|------|------|
| `AppCore.ets` | 共享运行时：appContext、事件总线（subscribe/unsubscribe/notifyChange）、日志、本地网卡枚举、服务器指纹 |
| `SettingsRepository.ets` | 全部设置（set/get + Preferences 持久化）、serverNeedsRestart 标志 |
| `DeviceRepository.ets` | 设备身份（alias/type/model）、refreshDeviceInfo、getLocalDeviceInfo |
| `ServerRepository.ets` | 服务器生命周期（start/stop/restart/reload）、serverRunning/serverError/noWifiWarning/allInterfacesDisabled |
| `DiscoveryRepository.ets` | 设备发现（事件处理/rescan/staged scan/手动连接） |
| `SendRepository.ets` | 发送链路（sendToDevice/Multi、文件 staging、sendSessions）+ activeProgress + 共享 URIs inbox |
| `ReceiveRepository.ets` | 接收链路（pending requests、自动确认、接收会话/进度事件、finishReceiveSession）+ 事件队列 + 请求轮询 |
| `WebShareRepository.ets` | 分享链接、Web 上传/下载事件 |
| `ChecksumRepository.ets` | 校验和、文件下载/上传、buffer hash |

依赖方向：`ReceiveRepository → SendRepository`（activeProgress 归 Send，Receive 经导出的 upsert/remove 操作），Shell 层 import 全部 Repo 无环。

主要编排函数：

| 函数 | 说明 |
|------|------|
| `initAppService(context)` | 初始化：加载设置到模块状态、初始化设备身份、注册 Rust 事件回调、注册网络监听 |
| `startLocalServer()` / `stopLocalServer()` | 组合服务器生命周期 + 请求轮询 |
| `reloadServerSettings()` | 热重载服务器（活跃传输时跳过，停→启→失败回滚） |
| `handleNativeEvent(eventJson)` | 统一分发 Rust 回调事件到各 Repository |

状态管理说明：设置与运行时状态由 Repository 模块变量持有（SSOT），VM 通过 getter 读取 + subscribe 回调刷新；一次性传输事件（接收完成/取消/文本消息）通过 `peek/consume` 内存队列消费；跨页面共享 URIs 通过 `setPendingSharedUris/consumePendingSharedUris` inbox 传递。

事件回调机制（`register_event_listener`）：
- Rust 侧通过 `ThreadsafeFunction` 从 tokio 线程推送事件到 ArkTS 主线程
- 所有事件通过 `handleNativeEvent()` 按 `type` 字段分发
- `discovery_update`：设备列表更新（事件推送，无轮询）
- `prepare_upload`：接收文件请求（事件推送，无轮询）
- `register`：设备注册反馈到 discovery store
- `session_end` / `cancel_received`：会话结束/取消通知
- `progress_update`：传输进度实时推送（direction: recv/send/share）
- `prepare_download`：Web 分享时浏览器请求下载文件（需 accept/decline）
- `file_download`：Web 分享时浏览器正在下载文件（Rust 侧自动处理文件流）

进度推送机制：
- Rust 侧在文件传输进度更新时（20ms 节流后），通过 `EventCallback.call()` 推送 `progress_update` 事件
- ArkTS 侧在 `handleProgressUpdate()` 中处理单个进度事件，更新 `activeProgress` 并通知 VM 刷新
- 接收进度完成时触发会话完成逻辑：文件导出、历史记录、auto-finish、清理
- 发送进度由 callback 驱动实时更新，会话完成由 `sendToDevice`/`sendToDeviceMulti` 的 Promise 流程处理
- 取消通知使用 `cancel_received` 事件

发送 PIN 保护流程（`SendRepository.sendToDevice`）：
- 接收方开启 PIN 时，`prepare-upload` 返回 401（PIN required）
- `sendToDevice` 收到 401 后调用 `DialogService.showPinDialog` 弹出 PIN 输入弹窗，用户输入后带 `pin` query 参数重试（最多 5 次，PIN 错误时弹窗显示错误提示）
- 用户取消弹窗则按 401 错误结束发送

协议协商（加密不可降级策略，实际生效于 `SendRepository.sendToDevice`）：
1. 发送端启用HTTPS + 接收端支持HTTPS → 使用HTTPS
2. 发送端启用HTTPS + 接收端不支持HTTPS → 错误，拒绝降级
3. 发送端禁用HTTPS + 接收端支持HTTPS → 升级使用HTTPS（接收端服务器只监听 HTTPS，明文连接无法建立）
4. 发送端禁用HTTPS + 接收端不支持HTTPS → 使用HTTP

`senderProtocol`：接收端通过 `cert_fingerprint` 是否存在判断发送端协议（有证书→HTTPS，无证书→HTTP），存入 `PendingRequest.senderProtocol`，用于接收对话框验证按钮状态。

### 4.3 NativeBridge — NAPI 桥接

`entry/src/main/ets/service/NativeBridge.ets`

从 `localsend_ohrs` HAR 导入 Rust NAPI 函数，封装为 `native*` 函数并做类型转换。关键设计：HAR 接口参数为 JSON 字符串，NativeBridge 负责 `JSON.stringify` + 类型映射。

NAPI 函数：

| 函数 | 说明 |
|------|------|
| `nativeStartDiscoveryV2(config)` | 完整配置启动 Rust discovery（discovery 统一入口） |
| `nativeDiscoveryDiscoverStaged(channels, ips, port, protocol, graceMs)` | 分阶段发现（announce → probe known channels → grace 确认窗口 → 无确认时回退子网扫描；ArkTS 刷新传默认接口 ips 启用子网扫描兜底） |
| `nativeDiscoveryScanSubnet(ip, port, protocol)` | 扫描子网 |
| `nativeDiscoveryAddDevice(device)` | 将 server register 事件反馈给 discovery store |
| `nativeDiscoverySetAnswerAnnouncements(answer)` | 控制 discovery 是否回应 announce |
| `nativeDiscoveryStop()` | 停止 discovery |
| `nativeDiscoveryGetDevice(fingerprint)` | 按 fingerprint 查询设备 |
| `nativeDiscoveryMulticastError()` | 获取 multicast 错误 |
| `nativeClientInfo(protocol, ip, port)` | GET /api/localsend/v2/info |
| `nativeComputeFingerprintHash(combined)` | SHA-256 哈希，用于指纹图标计算 |
| `nativeAcceptWebDownload(sessionId)` | Web 分享：接受浏览器下载请求 |
| `nativeStartWebUpload()` | Web 分享：启动浏览器上传模式，返回 port |
| `registerEventListener(callback)` | 注册 Rust 事件回调 |

announce 由 `nativeDiscoveryDiscoverStaged` 内含触发；ArkTS 刷新时向已知设备（收藏 + 已发现快照）逐个发送确认探测 + 组播广播，3 秒确认窗口结束后移除未回应的离线设备；扫描中再次点击刷新合并排队（最多补扫一次）。

证书固定（`expectedFingerprint`）：`sendFiles` → `prepare_send` / `upload_file` 传递目标指纹，Rust 层在 HTTPS 连接时验证服务端证书。

### 4.4 Discovery — 设备发现

设备发现由 Rust 核心的 `localsend::discovery` 模块实现，ArkTS 层通过 `DiscoveryRepository` 调用 NativeBridge 函数。

Rust 核心发现功能：
- **UDP 组播**：`224.0.0.167:<配置端口>`（默认 `53317`；组播端口跟随"端口"设置，与官方 LocalSend 一致），支持 hot-restart（新实例自动停止旧实例）
- **分阶段发现**（`discover_staged`）：announce → probe favorites → wait grace period → fallback subnet scan
- **设备 store**：去重、多 channel 合并、ranked channels、超时清理
- **事件推送**：通过 `discovery_update` callback 实时推送设备列表变化
- **网络过滤**：白/黑名单存储接口名（如 `wlan0,eth0`），按接口名粒度控制。ArkTS 侧 `computeDiscoveryWhitelist()` 将白名单中（且不在黑名单中）的接口映射为网段通配（按 prefixLength 生成 `a.b.c.*`），传入 Rust `InterfaceFilter.whitelist`；黑名单接口 IP 直接传入 `InterfaceFilter.blacklist`。白名单为空时不扫描任何接口（whitelist=undefined，组播降级）。`getLocalDeviceInfo()` 同样按接口名过滤，UI 展示和子网扫描均使用过滤后的接口列表。三个页面（发送/接收/设置）统一显示网络警告横幅：`noWifiWarning`（无 WiFi/以太网物理接口）优先于 `allInterfacesDisabled`（用户关闭了所有接口）。


### 4.5 DialogService — 弹窗服务

`entry/src/main/ets/service/DialogService.ets`

统一管理弹窗，使用 `@Builder` + `openCustomDialog` 模式，页面通过 DialogService 静态方法调用。

提供 `showPinDialog(deviceName, errorHint, callback)` 供发送方输入接收方要求的 PIN 码：密码掩码输入，确认回调输入值，取消回调空串（发送流程据此放弃发送）。

### 4.6 Logger — 统一日志模块

`entry/src/main/ets/utils/Logger.ets` + `entry/src/main/ets/common/LogDomains.ets`

封装 hilog，提供双层输出（hilog 系统日志 + addLog 应用内日志），按业务域细分 domain，支持结构化上下文（LogContext）。仅依赖 `@kit.PerformanceAnalysisKit`（hilog）和 `entry/BuildProfile`（编译时常量），addLog 回调通过运行时注入。

| 导出函数 | 说明 |
|----------|------|
| `getLogger(domain, tag)` | 创建 LoggerInstance（每个模块顶层调用一次，返回实例复用） |
| `registerAddLog(fn)` | 注入 addLog 回调（运行时注入，避免编译期循环依赖） |
| `initLogger()` | 根据编译模式初始化日志级别（Debug=DEBUG, Release=INFO） |
| `setDebugEnabled(on)` | 临时切换 Debug 开关（仅内存 + hilog 级别，不持久化，重启恢复） |
| `isDebugEnabled()` | 查询当前 Debug 开关状态 |

**初始化链路**：`AppService.initAppService()` → `registerAddLog(addLog)` → `initLogger()`

**Debug 开关策略**：
- Debug 版本（`BuildProfile.DEBUG = true`）：默认 DEBUG 级别，全量输出
- Release 版本（`BuildProfile.DEBUG = false`）：默认 INFO 级别，Settings 页 Toggle 可临时开启，重启恢复
- 不持久化，不依赖 PreferencesUtil

**业务域常量**（`LogDomains`）：

| 域 | 值 | 适用模块 |
|----|----|----------|
| GENERAL | 0x0000 | AppService, EntryAbility, DialogService, ReceiveHistoryService |
| DISCOVERY | 0x0001 | DiscoveryRepository, DeviceRepository, MainTabViewModel |
| TRANSFER | 0x0002 | SendRepository, ReceiveRepository, TransferViewModel, TransferPage, SendViewModel, SendContent, WebShareRepository, ChecksumRepository |
| NETWORK | 0x0003 | AppCore, NetworkSettingsSection, SettingsViewModel |
| SERVER | 0x0004 | ServerRepository |
| SETTINGS | 0x0005 | SettingsRepository, PreferencesUtil, FavoritesService |

**TAG 命名**：`HandySend:模块名`（≤31 字节），通过 `hdc hilog -t HandySend:xxx` 按模块过滤。

**结构化上下文**（`LogContext`）：可选字段 sessionId/fileId/direction/targetAlias/protocol，拼接前缀如 `[sid=abc1234 dir=send alias=Phone]`。

**隐私标识**：Logger 内部统一使用 `%{public}s`，敏感数据由调用方截断（如 sessionId 仅取前 8 字符）。

**规范约束**：全项目仅 Logger.ets 可直接 import hilog，其他文件必须通过 `getLogger()` 使用日志功能。

**应用内日志缓冲与导出**（内存日志源 + HttpLogsPage）：
- 内存日志源位于 `AppCore.ets`：`logs: Array<LogEntry>`（LogEntry = `{ timestamp, level, message }`），由 `addLog(level, message)` 追加。
- 容量上限 2000 条，`addLog` 时若超出则 `logs.slice(-1800)` 保留最近 1800 条（约 0.6–1 MB，消息均长 < 1KB），避免组播高频写入撑爆内存并截断早期日志。
- 变更通知节流：`addLog` / `clearLogs` 不直接 `notifyChange`，而是经 `scheduleLogNotify()` 用 200ms `setTimeout` 合并，保证高频写入期间订阅者（日志页）最多每 200ms 重绘一次。
- 导出：`AppCore.saveLogsToFile(context, text)` 用 `DocumentViewPicker`（`DocumentPickerMode.DOWNLOAD`）落盘到用户可见的 Downloads/应用目录，无需存储权限；VM 层 `HttpLogsViewModel.saveLogs(context)` 拼文本并编排，返回 `SaveLogsResult`；Page 层仅调命令 + 按结果弹 Toast（严格 MVVM：VM 不碰 UIContext/fs/picker）。
- 实时刷新：HttpLogsPage 在 `aboutToAppear` 订阅、`aboutToDisappear` 退订；VM 回调用箭头函数字段持有 `this` 并 `getLogs().slice()` 拷贝新引用触发 `@Trace` 刷新（原地 push 同一引用不触发 V2）。

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
3. ArkTS 根据 `autoConfirmMode` 决定 auto-accept 或弹窗确认 → 调用 `nativeAcceptWebDownload`/`nativeDeclineWebDownload`
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
| `PendingRequest` | 待处理请求（sessionId, senderAlias, senderFingerprint, senderProtocol, senderIp, senderDeviceType, senderDeviceModel, files[]；sender* 设备信息来自 prepare_upload 事件，轮询兜底路径为空，由 MainTabViewModel 回退到发现反查） |
| `TransferProgress` | 传输进度（sessionId, fileId, bytesSent, totalBytes） |
| `SendFileItem` | 待发送文件（fileId, filePath, fileName, size） |
| `FavoriteDevice` | 收藏设备 |
| `ReceiveHistoryEntry` | 接收历史条目 |
| `AutoConfirmMode` | 枚举：off / paired / on |
| `SendMode` | 枚举：single / multiple / link |
| `SendSessionStatus` | 发送会话状态枚举 |

### NAPI 层 (model/NativeTypes.ets)

与 Rust `#[napi(object)]` 结构体一一对应：`NativeServerConfig`, `NativeServerHandle`, `NativeServerStatus`, `NativeTargetDevice`, `NativeTransferRequest`, `NativeProgressInfo`, `NativeFileToSend`, `NativeSendResult`, `NativeShareLinkInfo`, `NativeRecvDiag` 等。

discovery 相关类型：`NativeDiscoveryConfig`, `NativeDiscoveredDevice`, `NativeDeviceChannel`, `NativeInterfaceFilter`。

Web Share 事件类型：`NativeWebSendPrepare`（prepare_download 事件）、`NativeWebSendFileDownload`（file_download 事件）。

取消通知使用 `cancel_received` 事件。

## 7. 测试体系

### 7.1 测试类型与目录结构

采用 **Local Test（本地单元测试）**：运行于预览引擎，无需真机/模拟器，仅支持 Stage 模型，不支持测试 C/C++ 方法及系统 API。

```text
entry/src/test/                      # entry 模块 Local Test
├── List.test.ets                    # 测试入口（挂载全部测试套件）
├── MimeUtils.test.ets               # MIME 工具函数（纯函数，边界情况多）
├── PreferencesUtil.test.ets         # 偏好设置（未初始化分支降级行为）
├── FavoritesService.test.ets        # 收藏服务 CRUD + 去重/溢出/别名同步
└── ReceiveHistoryService.test.ets   # 接收历史服务 FIFO + MAX_HISTORY 边界
```

### 7.2 可测范围

Repository 和 ViewModel 层的纯逻辑函数（不依赖系统 API / native / UIContext）可在 Local Test 中测试，如 peek/consume 事件队列、shouldAutoAccept 判断、设备过期淘汰、进度更新、ViewModel 选择/过滤操作等。纯工具函数（MimeUtils、FormatUtil、LogFormatter、FingerprintIcons）同样可测。

依赖系统 API（`@kit.*`）、native `.so`、UIContext、文件操作（picker/fs）的函数不可测，需 Instrumented Test。

### 7.3 运行命令

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
| `DebugPage` / `HttpLogsPage` / `DiscoveryDebugPage` | 调试页面 |

### 主页面结构

```
MainTabFloating
├── SendContent (文件/图片/剪贴板/文本 + 设备列表)
├── ReceiveContent (本机信息 + 收藏设备)
└── SettingsContent (组装 views/settings/ 各设置分组)
```

### 浮动 Tab 栏

使用 `HdsTabs` + `barOverlap(true)` + `barFloatingStyle` + `bindScroller` + `applyHideAnimation`/`applyShowAnimation` 实现浮动 Tab 栏（系统内置动画），要求 API >= 23。

滚动显示/隐藏逻辑：
- 子组件通过 `onScrollDelta(deltaY, absY)` 回调报告滚动增量和绝对偏移
- `absY ≤ 20` 时永远不隐藏（防止顶部回弹抖动）
- Tab 切换时自动恢复显示
- `-999` 哨兵值表示内容到达顶部，强制显示

### 设置页分组与半屏弹窗

设置页由 `views/settings/` 下的分组组件组装（每个分组一个卡片）：

| 分组组件 | 内容 |
|----------|------|
| `NetworkSettingsSection` | 服务器状态/昵称/设备类型/设备型号/高级设置（端口/组播/发现超时/网络接口）+ 网络警告横幅（noWifiWarning/allInterfacesDisabled）+ 设备类型与网络接口半屏弹窗（含刷新按钮） |
| `AppearanceSettingsSection` | 主题/动画/滚动隐藏页签 + 语言半屏弹窗 |
| `SendSettingsSection` | 自动确认下载请求/创建校验和 |
| `ReceiveSettingsSection` | 接收相关设置 |
| `MoreSettingsSection` | 反馈/关于半屏弹窗 + 调试日志 + 恢复默认 |

各半屏弹窗独立持有 `@Local isShowXxxSheet` 开关，通过 `bindSheet` 呈现；列表卡片内文字左右内边距统一为 `DesignTokens.space.lg`（24vp），与设置页卡片一致。

### 响应式设计

- 手机 (320-520vp)：底部水平 Tab 栏
- 平板/宽屏：侧边垂直 Tab 栏 (barWidth=96)
- 内容最大宽度：800vp
- 深色模式：完整 `dark/` 资源覆盖

## 9. 状态管理

采用 V2 状态管理（@ComponentV2 体系）：

- 页面级状态：`@Local`（持有 `@ObservedV2` ViewModel，`@Trace` 属性变化驱动精准 UI 刷新）
- 子组件参数：`@Param`（引用语义）
- 子组件回调：`@Event`
- 列表渲染：`Repeat` + `.each()/.key()`
- 弹窗：`@Builder` + `openCustomDialog`
- 业务/共享状态：ViewModel 属性（@ObservedV2 + @Trace）+ Repository 模块变量（SSOT）
- 跨组件通知：Repository 事件总线（`subscribe`/`unsubscribe`/`notifyChange`）+ FavoritesService 回调
- 一次性传输事件：`peek/consume` 内存队列（接收完成/取消/文本消息）
- 跨页面共享 URIs：`setPendingSharedUris`/`consumePendingSharedUris` inbox
- 持久化偏好：`PreferencesUtil`（存储名 `handysend_settings`）

## 10. 权限

| 权限 | 说明 |
|------|------|
| `ohos.permission.INTERNET` | 网络访问 |
| `ohos.permission.GET_NETWORK_INFO` | 获取网络信息 |

注册的 skill：主屏启动 (`ohos.want.action.home`) + 系统分享接收 (`ohos.want.action.sendData/sendMultipleData`)

## 11. 功能特性

文件传输、图片传输、剪贴板共享、文本发送、链接分享（二维码 + Web Send 浏览器下载）、Web Upload（浏览器上传）、UDP 组播 + HTTP 子网扫描设备发现、HTTPS 加密传输、收藏设备、自动确认请求（off/paired/on，Web Share 下载遵循独立的「自动确认下载请求」开关）、自动完成（传输完成后自动退出传输页）、深色模式、外部分享、传输取消、PIN 保护（Web Share 复用 receivePin）、校验和（SHA-256）、接收历史、指纹验证（Material Icons 图标体系 + SHA-256 哈希对齐 LocalSend v1.18）。

## 12. 注意事项

1. **浮动 Tab 栏**：使用 HdsTabs + barFloatingStyle，要求 API >= 23
2. **文件导出依赖用户交互**：DocumentViewPicker 选择保存位置
3. **ohrs 路径限制**：Windows 不支持含空格路径，需符号链接
4. **MaterialIcons 字体**：Flutter SDK 的 MaterialIcons-Regular.otf 注册为自定义字体，用于指纹图标渲染
