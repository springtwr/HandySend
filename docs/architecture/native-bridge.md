# NativeBridge 与 Rust NAPI 层详解

> NAPI 桥接函数清单、事件系统、进度追踪、Web Share 架构。

## NativeBridge — NAPI 桥接

`entry/src/main/ets/service/NativeBridge.ets`

从 `localsend_ohrs` HAR 导入 Rust NAPI 函数，封装为 `native*` 函数并做类型转换。关键设计：HAR 接口参数为 JSON 字符串，NativeBridge 负责 `JSON.stringify` + 类型映射。

### NAPI 函数清单

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
| `nativeDeclineWebDownload(sessionId)` | Web 分享：拒绝浏览器下载请求 |
| `nativeCreateServer(config)` | 创建服务器 |
| `nativeStopServer()` | 停止服务器 |
| `nativeGetServerStatus()` | 获取服务器状态 |
| `nativePollPendingRequests()` | 轮询待处理请求 |
| `nativeCreateShareLink(files)` | 创建分享链接 |
| `nativeStopShareServer()` | 停止分享服务器 |
| `nativeRespondTransfer(response)` | 响应传输请求 |
| `nativeSendFiles(target, files, pin)` | 发送文件 |
| `nativeCancelTransfer(sessionId)` | 取消传输 |
| `nativeCancelTransferLocal(sessionId)` | 取消本地传输 |
| `nativeCancelLocalSession(sessionId)` | 取消本地会话 |
| `nativeGetCurrentSendSessionId()` | 获取当前发送会话 ID |
| `nativePollDebugLog()` | 轮询调试日志 |
| `nativePrepareDownload(fileId, sessionId)` | 准备下载 |
| `nativeDownloadFile(fileId, sessionId, targetPath)` | 下载文件 |
| `nativeUploadFromBuffer(fileId, sessionId, buffer)` | 从缓冲区上传 |
| `nativeRegisterDevice(device)` | 注册设备 |
| `nativeHashFileStream(filePath, cancelToken)` | 文件流哈希 |
| `nativeCancelHash(cancelToken)` | 取消哈希 |
| `nativeHashBuffer(buffer)` | 缓冲区哈希 |
| `nativeFailFileDownload(fileId, sessionId)` | 标记文件下载失败 |
| `nativeFailFileUpload(fileId, sessionId)` | 标记文件上传失败 |
| `nativeGetNetworkInterfaces()` | 获取网络接口列表 |
| `nativeSanitizeFileName(name)` | 清理文件名 |
| `nativeCreateCancelToken()` | 创建取消令牌 |
| `nativeGetSecurityContext()` | 获取当前生效的 TLS 安全上下文（证书/公钥/私钥/指纹，用于安全信息展示） |
| `nativeResetSecurityContext()` | 重置 TLS 证书：重新生成自签名证书与密钥、覆盖持久化身份文件并更新 BridgeState |
| `registerEventListener(callback)` | 注册 Rust 事件回调（内部经 onBridgeEvent 类型化订阅分发） |
| `onBridgeEvent(type, handler)` / `offBridgeEvent(type, handler)` | 类型化事件订阅（按事件类型 on/off 分发） |
| `verifyNativeVersion()` | 验证原生库版本兼容性 |
| `getNativeLibraryVersion()` | 获取原生库版本号 |
| `getLocalSendProtocolVersion()` | 获取 LocalSend 协议版本 |

> 完整封装清单以 `entry/src/main/ets/service/NativeBridge.ets` 为准。

### Discovery 说明

announce 由 `nativeDiscoveryDiscoverStaged` 内含触发；ArkTS 刷新时向已知设备（收藏 + 已发现快照）逐个发送确认探测 + 组播广播，3 秒确认窗口结束后移除未回应的离线设备；扫描中再次点击刷新合并排队（最多补扫一次）。

## Rust NAPI 层

`localsend_ohrs/rust/`

```
lib.rs                   # crate 入口：pub mod bridge + #[cfg(napi)] pub mod napi
bridge/                  # 桥接层（纯逻辑，不依赖 runtime/NAPI，可脱离 napi feature 编译/测试）
  ├── mod.rs              # 模块声明 + pub use 重导出
  ├── event.rs            # BridgeEvent 强类型事件 + BridgeError + 事件分类常量
  ├── state.rs            # BridgeState 纯数据（无 runtime/callback）
  ├── engine.rs           # StateAction + apply_actions 纯函数状态变更
  ├── identity.rs         # init/安全上下文/网络信息/哈希/取消令牌/日志工具
  ├── server.rs           # 服务器生命周期 + 传输决策 + WebSend（含事件循环 task）
  ├── client.rs           # HTTP 客户端操作（发送、注册、取消、clientInfo、下载）
  ├── discovery.rs        # 发现生命周期 + 扫描 + 设备查询（含事件循环 task）
  └── adapter/            # 上游类型隔离
      ├── server.rs       # ServerEventV2/WebSendEvent/InternalEvent → (BridgeEvent, Vec<StateAction>)
      ├── multicast.rs    # MulticastEvent/DiscoveryEvent → BridgeEvent
      ├── client.rs       # ClientError → BridgeError
      └── types.rs        # DTO 定义 + 上游↔DTO 转换（纯函数）
napi/                    # NAPI 适配层（napi feature 门控，按入口域组织）
  ├── env.rs              # NapiEnv（OnceLock 持有 Runtime + BridgeState + event_rx）
  ├── event_forwarder.rs  # 事件转发（napi_threadsafe_function，按事件类型分发）
  ├── identity.rs         # init/安全上下文/哈希 NAPI 入口
  ├── server.rs           # 服务器/传输决策/WebSend NAPI 入口
  ├── client.rs           # 发送/接收/取消/注册 NAPI 入口
  ├── discovery.rs        # 发现 NAPI 入口
  └── mod.rs              # #[napi] 对象结构 + 模块声明
```

`napi` feature（默认启用）控制编译范围：启用时编译 NAPI 适配层（`napi/`）；关闭（`--no-default-features`）时仅编译 `bridge/` 模块，可在 Linux native target 上运行 `cargo test`。

### 架构关键点

- **runtime 归 NAPI 层**：`NapiEnv::global()`（OnceLock）持有 tokio Runtime（multi_thread, 4 workers）+ `&'static Arc<Mutex<BridgeState>>` + `event_rx`。桥接层函数通过参数接收 `Arc<Mutex<BridgeState>>` 或 `&Mutex<BridgeState>`，不感知 runtime
- **事件流**：`init` 时创建 `mpsc::channel::<BridgeEvent>`，sender 注入 `state.event_tx`，receiver 存入 `NapiEnv.event_rx`；`start_event_forwarder` spawn 消费任务，逐事件序列化（`{"type":"...","payload":{...}}`）经 `napi_threadsafe_function` 投递到 ArkTS 主线程
- **事件循环 task**：`start_server`/`start_discovery_v2`/`spawn_web_send_event_task` spawn 的事件循环 JoinHandle 存于 BridgeState，`stop_server`/`stop_discovery` 时 abort
- **桥接层函数命名**：无 `do_` 前缀、无 `_facade` 后缀，函数名即公共 API 名

### 进度追踪

发送端上传/接收端保存时以 20ms 节流推送 `BridgeEvent::UploadProgress { sessionId, fileId, direction, progress, speed }`（高频瞬态事件，channel 满时 `try_send` 丢弃，不阻塞关键事件送达）。进度值 `progress` 为 0.0~1.0，`direction` 为 `"send"`/`"recv"`。ArkTS 侧从会话文件映射补齐 bytesSent/totalBytes/filePath。

### 事件推送

所有事件（discovery/server/web share）通过 mpsc channel 以强类型 `BridgeEvent` 输出，NAPI 层经 `registerEventListener` 注册的 napi_threadsafe_function 推送。事件按关键/可丢弃分类：关键事件（PrepareUpload、SessionEnd、DeviceFound、DeviceLost、ServerStarted/Stopped、WebSend*、Error 等）`send().await` 保证送达；`UploadProgress` `try_send` 丢弃。ArkTS 侧通过 `NativeBridge.onBridgeEvent(type, handler)` 按类型订阅。

## Web Share 架构

Web Share 功能通过按需启停服务器实现，不依赖独立服务：

### Web Send（浏览器下载设备文件）

1. `create_share_link(files)` → 解析文件 → 停止当前服务器 → 构造 `WebConfig{send: Some(WebSendConfig), upload: false}` → 重启服务器 → 启动 `WebSendEvent` 处理 task → 返回分享 URL
2. 浏览器访问 URL → Rust HTTP server 返回下载页面 → 浏览器请求下载 → `WebSendEvent::PrepareDownload` 推送到 ArkTS
3. ArkTS 根据 `autoConfirmMode` 决定 auto-accept 或弹窗确认 → 调用 `nativeAcceptWebDownload`/`nativeDeclineWebDownload`
4. 浏览器下载文件时 `WebSendEvent::FileDownload` → Rust 通过 `FileContent::Path` 自动提供文件流
5. `stop_share_server()` → 停止服务器 → 清理 web 状态 → 用普通配置重启服务器

### Web Upload（浏览器上传文件到设备）

1. `start_web_upload()` → 停止当前服务器 → 构造 `WebConfig{send: None, upload: true}` → 重启服务器 → 返回 port
2. 浏览器访问 URL → 上传文件 → 触发 `prepareUpload`/`fileUpload` 事件（复用 v2 接收流程）
3. auto-accept 行为与普通 v2 接收一致（`shouldAutoAccept`）

### 关键设计

- `BridgeState.receive_pin`：服务器启动时保存 PIN，Web Share 重启服务器时自动复用
- `BridgeState.web_send_files`：fileId→filePath 映射，FileDownload 时提供 `FileContent::Path`
- `BridgeState.web_download_decisions`：sessionId→oneshot channel，accept/decline 发送决策
- `WebI18n`：中文文案（22 字段，含 downloadAll/selectFiles/uploadComplete/retry 等），由 Rust 构造传给 Web 页面

### 网页资产（鸿蒙高保真风格）

`third_party/localsend/packages/core/assets/web/` 下 `download.html`/`upload.html`/`error-403.html` 为鸿蒙化单文件页面（HarmonyOS Design Token 视觉、HMSymbol 字体子集 base64 内联、零外部资源），经 `include_str!` 编译进 `.so`，由 fork 定制分支 `harmony-web-ui` 维护：

- 协议契约与 JS 关键逻辑保留：`sessionStorage` 会话复用、PIN 循环、错误码映射（401/403/409/429/204）、顺序上传
- 增强：使用鸿蒙 PIN 对话框（而非浏览器 `prompt()`）、"全部下载"（Safari 不支持则禁用并提示）、手动输入文本内联预览 + 复制（下载页 `fileType='text'` 标记，由 ArkTS `shareByLink` 在链接分享路径设置）、上传页发送文本（虚拟 `message.txt` + `fileType='text/plain'` + `preview` 字段携带文本内容，接收端以 `preview` 有无区分文本消息与文本文件）
- Content-Disposition 同时输出 `filename=` 与 `filename*=UTF-8''`（RFC 5987），保证 Safari 中文文件名正常

## Discovery — 设备发现

设备发现由 Rust 核心的 `localsend::discovery` 模块实现，ArkTS 层通过 `DiscoveryRepository` 调用 NativeBridge 函数。

### Rust 核心发现功能

- **UDP 组播**：`224.0.0.167:<配置端口>`（默认 `53317`；组播端口跟随"端口"设置，与官方 LocalSend 一致），支持 hot-restart（新实例自动停止旧实例）
- **分阶段发现**（`discover_staged`）：announce → probe favorites → wait grace period → fallback subnet scan
- **设备 store**：去重、多 channel 合并、ranked channels、超时清理
- **事件推送**：设备变化经 mpsc channel 推送 `DeviceFound`（发现/更新）/`DeviceLost`（超时移除）事件

### 网络过滤

白/黑名单存储接口名（如 `wlan0,eth0`），按接口名粒度控制。ArkTS 侧 `computeDiscoveryWhitelist()` 将白名单中（且不在黑名单中）的接口映射为网段通配（按 prefixLength 生成 `a.b.c.*`），传入 Rust `InterfaceFilter.whitelist`；黑名单接口 IP 直接传入 `InterfaceFilter.blacklist`。白名单为空时不扫描任何接口（whitelist=undefined，组播降级），`getLocalDeviceInfo()` 同样按此语义过滤（白名单空 → 过滤后列表为空），保证组播绑定与子网扫描的接口一致性。首次启动时 `ensureDefaultNetworkLists()` 根据接口类型自动初始化默认值（wifi/ethernet 入白名单，其他入黑名单），避免空白名单导致无法发现设备。三个页面（发送/接收/设置）统一显示网络警告横幅：`noWifiWarning`（无 WiFi/以太网物理接口）优先于 `allInterfacesDisabled`（用户关闭了所有接口）。
