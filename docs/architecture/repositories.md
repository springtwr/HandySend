# Repository 层详解

> AppService 门面与各 Repository 的职责、依赖关系、编排函数、事件机制。

## AppService — 核心业务门面

`entry/src/main/ets/service/AppService.ets`

AppService 是业务层的门面（facade）：初始化编排、Rust 事件分发、服务器生命周期组合（服务器 + 请求轮询）。VM/View 统一从门面导入，门面通过 re-export 暴露 Repository 函数。业务逻辑按领域拆分到 `service/repository/`：

### 各 Repository 职责

| 文件 | 职责 |
|------|------|
| `AppCore.ets` | 共享运行时：appContext、事件总线（subscribe/unsubscribe/notifyChange）、日志、本地网卡枚举、服务器指纹 |
| `SettingsRepository.ets` | 全部设置（set/get + Preferences 持久化）、serverNeedsRestart 标志 |
| `DeviceRepository.ets` | 设备身份（alias/type/model）、refreshDeviceInfo、getLocalDeviceInfo |
| `ServerRepository.ets` | 服务器生命周期（start/stop/restart/reload）、serverRunning/serverError/noWifiWarning/allInterfacesDisabled、Rust save_dir getReceiveSaveDir（{filesDir}/HandySend/，TLS 身份持久化）、接收文本临时目录 getReceiveCacheDir（{cacheDir}/receive/）、启动孤儿文件清理与冷启动接收临时目录清扫 |
| `DiscoveryRepository.ets` | 设备发现（事件处理/rescan/staged scan/手动连接） |
| `SendRepository.ets` | 发送链路（sendToDevice/Multi、文件 staging、sendSessions）+ activeProgress + 共享 URIs inbox + 协议协商纯函数 `resolveSendProtocol`（加密不可降级策略，可独立测试）；发送零拷贝：prepareSendFiles 不落沙箱副本，sendToDevice 每次发送前 openSync 源文件并携带 fd（fd-direct） |
| `ReceiveRepository.ets` | 接收链路（pending requests、自动确认、接收会话/进度事件、finishReceiveSession）+ 事件队列（completed/cancelled/text/mediaFiles）+ 请求轮询 + 接收直写目标管理（确认接收时预创建 Download/`<包名>/` 文件并注册 fd；取消/失败时删除预创建的不完整文件；文本消息落 cache 临时目录阅后即删）+ 自动接收决策纯函数 `computeShouldAutoAccept`（off/paired/on 三模式 + 文本消息拦截，可独立测试） |
| `WebShareRepository.ets` | 分享链接、Web 上传/下载事件、下载请求确认队列（accept/decline） |
| `ChecksumRepository.ets` | 校验和、文件下载/上传、buffer hash |
| `FavoritesService.ets` | 收藏设备持久化与订阅（经 AppCore 事件总线同构的 EventBus 实例） |
| `ReceiveHistoryService.ets` | 接收历史持久化与查询 |
| `PreferencesRepo.ets` | 设置域偏好读写的唯一数据访问层（基础 get/set + 类型化方法，委托 PreferencesUtil）；接收历史、收藏等服务因隔离性直接使用 PreferencesUtil |

### 依赖方向

`ReceiveRepository → SendRepository`（activeProgress 归 Send，Receive 经导出的 upsert/remove 操作），Shell 层 import 全部 Repo。`ServerRepository` 与 `ReceiveRepository` 存在相互引用（Server 启动孤儿清理需读取待消费媒体路径，Receive 会话清理需读取接收文本临时目录），均为运行期函数调用，无模块初始化期访问，无环加载问题。

### 主要编排函数

| 函数 | 说明 |
|------|------|
| `initAppService(context)` | 初始化：加载设置到模块状态、初始化设备身份、订阅 Rust 桥接事件、注册网络监听 |
| `startLocalServer()` / `stopLocalServer()` | 组合服务器生命周期 + 请求轮询 |
| `reloadServerSettings()` | 热重载服务器（活跃传输时跳过，停→启→失败回滚） |
| `onBridgeEvent(type, handler)` | 类型化订阅 Rust 桥接事件（NativeBridge 按 type 分发到各 Repository） |

### 状态管理

设置与运行时状态由 Repository 模块变量持有（SSOT），VM 通过 getter 读取 + subscribe 回调刷新；一次性传输事件（接收完成/取消/文本消息）通过 `peek/consume` 内存队列消费；跨页面共享 URIs 通过 `setPendingSharedUris/consumePendingSharedUris` inbox 传递。

## 事件回调机制

Rust 桥接层通过 mpsc channel 以强类型 `BridgeEvent` 输出事件（camelCase type），NAPI 层经 `register_event_listener` 注册的 `ThreadsafeFunction` 推送到 ArkTS 主线程。NativeBridge 解析 JSON（`{"type":"...","payload":{...}}`）后按 type 分发给订阅者，AppService 通过 `onBridgeEvent(type, handler)` 订阅：

| 事件类型 | 说明 |
|----------|------|
| `deviceFound` | 设备发现/更新（事件推送，无轮询） |
| `register` | 设备注册反馈到 discovery store，同时合入 ArkTS 发现列表并通知界面刷新 |
| `prepareUpload` | 接收文件请求（事件推送，无轮询） |
| `sessionEnd` / `cancelReceived` | 会话结束/取消通知 |
| `uploadProgress` | 传输进度实时推送（direction: recv/send） |
| `prepareUploadAborted` | 发送方在确认前丢弃 prepare-upload 请求 |
| `webSendPrepareDownload` | Web 分享时浏览器请求下载文件（需 accept/decline） |
| `webSendFileDownload` | Web 分享时浏览器正在下载文件（Rust 侧自动处理文件流） |

## 进度推送机制

- Rust 侧在文件传输进度更新时（20ms 节流后），通过 `state.event_tx` 推送 `uploadProgress` 事件（高频瞬态事件，channel 满时 `try_send` 丢弃）
- ArkTS 侧在 `handleProgressUpdate()` 中处理单个进度事件（仅携带 `progress` 0.0~1.0，由会话文件映射补齐 bytesSent/totalBytes/filePath），更新 `activeProgress` 并通知 VM 刷新
- 接收进度完成时触发会话完成逻辑：文件导出、历史记录、auto-finish、清理
- 发送进度由事件驱动实时更新，会话完成由 `sendToDevice`/`sendToDeviceMulti` 的 Promise 流程处理
- 取消通知使用 `cancelReceived` 事件（本地取消另发 `/cancel` 请求到发送方）

## 接收失败语义

桥接 `bridge/server.rs` 结果跟踪任务 + `ReceiveRepository`：

- 传输中断（网络断开/写入失败）时，核心将文件置 `Failed` 并以 `SessionEnd(Finished)` 结束会话、释放槽位——传输即时终止，与官方 LocalSend 行为一致
- 由于 100% 进度事件与 `SessionEnd` 由不同 tokio 任务推送、顺序不保证，ArkTS 侧**延迟 3 秒判定**：若期间会话完成导出则视为成功（不清理），否则按失败处理（显示"传输失败"、清理进度与半成品文件）——避免误删刚写完、尚未导出的文件

## 发送 PIN 保护流程

`SendRepository.sendToDevice`：

- 接收方开启 PIN 时，`prepare-upload` 返回 401（PIN required）
- `sendToDevice` 收到 401 后调用 `DialogService.showPinDialog` 弹出 PIN 输入弹窗，用户输入后带 `pin` query 参数重试（最多 5 次，PIN 错误时弹窗显示错误提示）
- 用户取消弹窗则按 401 错误结束发送

## 协议协商（加密不可降级策略）

纯逻辑提取为 `SendRepository.resolveSendProtocol(localHttps, remoteHttps)`，可独立测试；`sendToDevice` 调用该函数获取协商结果：

1. 发送端启用 HTTPS + 接收端支持 HTTPS → 使用 HTTPS
2. 发送端启用 HTTPS + 接收端不支持 HTTPS → 错误，拒绝降级（返回 null）
3. 发送端禁用 HTTPS + 接收端支持 HTTPS → 升级使用 HTTPS（接收端服务器只监听 HTTPS，明文连接无法建立）
4. 发送端禁用 HTTPS + 接收端不支持 HTTPS → 使用 HTTP

`senderProtocol`：接收端通过 `cert_fingerprint` 是否存在判断发送端协议（有证书→HTTPS，无证书→HTTP），存入 `PendingRequest.senderProtocol`，用于接收对话框验证按钮状态。

## 证书固定

`sendFiles` → `prepare_send` / `upload_file` 传递目标指纹 `expectedFingerprint`，Rust 层在 HTTPS 连接时验证服务端证书。
