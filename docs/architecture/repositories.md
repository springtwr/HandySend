# Repository 层详解

> AppService 门面与各 Repository 的职责、依赖关系、编排函数、事件机制。
>
> **会话状态边界（本特性后）**：Repository 退化为「协议 I/O + 原生调用 + 适配器事件来源」，
> 不再持有会话状态与聚合。全部会话的唯一事实源是 `service/transfer/TransferSessionRegistry`，
> 由 `service/transfer/adapters/*` 把各协议事件翻译为注册表操作（见「统一会话引擎」一节）。

## AppService — 核心业务门面

`entry/src/main/ets/service/AppService.ets`

AppService 是业务层的门面（facade）：初始化编排、Rust 事件分发、服务器生命周期组合（服务器 + 请求轮询）。VM/View 统一从门面导入，门面通过 re-export 暴露 Repository 函数。业务逻辑按领域拆分到 `service/repository/`：

### 各 Repository 职责

| 文件 | 职责 |
|------|------|
| `AppCore.ets` | 共享运行时：appContext、事件总线（subscribe/unsubscribe/notifyChange）、日志、本地网卡枚举、服务器指纹 |
| `SettingsRepository.ets` | 全部设置（set/get + Preferences 持久化）、serverNeedsRestart 标志 |
| `DeviceRepository.ets` | 设备身份（alias/type/model）、refreshDeviceInfo、getLocalDeviceInfo |
| `ServerRepository.ets` | 服务器生命周期（start/stop/restart）、serverRunning/serverError/noWifiWarning/allInterfacesDisabled、Rust save_dir getReceiveSaveDir（{filesDir}/HandySend/，TLS 身份持久化）、接收文本临时目录 getReceiveCacheDir（{cacheDir}/receive/）、启动孤儿文件清理与冷启动接收临时目录清扫 |
| `DiscoveryRepository.ets` | 设备发现（事件处理/rescan/staged scan/手动连接） |
| `SendRepository.ets` | 发送链路的**协议 I/O**：sendToDevice/Multi、文件 staging、`resolveSendProtocol`（加密不可降级策略，可独立测试）、send/recv 共享的 `activeProgress`（进度事件补齐字节用）+ 共享 URIs inbox；会话创建/进度/终态经 `LocalSendSendAdapter` 登记到统一注册表（仓库自身的会话表仅作发送内部簿记，UI/后台/聚合不再读取）；每次发送的逻辑会话标识唯一（时间戳 + 单调计数），并为其派生会话内唯一的文件标识，`beginLocalSendSession` 返回的统一标识记入会话状态，进度与终态一律按该统一标识归属（不做按逻辑标识的首匹配查找）；成功/失败/异常/取消各路径均保证终态落地。发送零拷贝：prepareSendFiles 不落沙箱副本，sendToDevice 每次发送前 openSync 源文件并携带 fd（fd-direct）；文本消息准备：prepareSendFiles 对命中「手动文本来源」入参的条目读取文本内容填入 preview（见「文本消息准备」） |
| `ReceiveRepository.ets` | 接收链路的**协议 I/O 与事件来源**：pending requests、自动确认、接收会话/进度事件、finishReceiveSession、请求轮询、接收直写目标管理（确认接收时预创建 Download/`<包名>/` 文件并注册 fd；取消/失败时删除预创建的不完整文件；文本消息落 cache 临时目录阅后即删）、自动接收决策纯函数 `computeShouldAutoAccept`（off/paired/on 三模式 + 文本消息拦截，可独立测试）；会话/待确认请求经 `LocalSendReceiveAdapter` 登记到注册表，确认/拒绝入口由中心经适配器回调本仓库 |
| `ReceiveTargets.ets` | 接收直写目标（fd-direct）登记：Download/<包名>/ 目录授权 URI 缓存、会话目标路径登记表（sessionId → fileId → 最终路径），供取消/失败清理与相册保存读取 |
| `MtaRepository.ets` | 应用级 MTA 运行时：发现扫描、接收服务启停、收发互斥、接收命令门面与对外身份刷新（详见 `docs/mta/MTA_PROTOCOL_AND_IMPLEMENTATION.md` §3.3）；接收阶段经 `MtaReceiveAdapter` 翻译为统一会话操作，确认/拒绝/取消入口由中心经适配器回调本仓库 |
| `WebShareRepository.ets` | 分享链接、Web 上传/下载事件、下载请求确认队列（accept/decline）；浏览器下载突发经 `WebDownloadAdapter` 建模为一个统一会话（静默窗口/无活动超时判定终态），确认/拒绝经适配器回调本仓库 |
| `ChecksumRepository.ets` | 发送文件校验和计算（sha256，fd-direct 流式哈希） |
| `FavoritesService.ets` | 收藏设备持久化与订阅（经 AppCore 事件总线同构的 EventBus 实例） |
| `ReceiveHistoryService.ets` | 接收历史持久化与查询 |
| `PreferencesRepo.ets` | 设置域偏好读写的唯一数据访问层（基础 get/set + 类型化方法，委托 PreferencesUtil）；接收历史、收藏等服务因隔离性直接使用 PreferencesUtil |

### 依赖方向

`ReceiveRepository → SendRepository`（activeProgress 归 Send，Receive 经导出的 upsert/remove 操作），Shell 层 import 全部 Repo。`ServerRepository` 与 `ReceiveRepository` 存在相互引用（Server 启动孤儿清理需读取待消费媒体路径，Receive 会话清理需读取接收文本临时目录），均为运行期函数调用，无模块初始化期访问，无环加载问题。

### 主要编排函数

| 函数 | 说明 |
|------|------|
| `initAppService(context)` | 初始化：加载设置到模块状态、初始化设备身份、加载持久化 TLS 身份（save_dir，跨启动指纹稳定）、订阅 Rust 桥接事件、注册网络监听 |
| `startLocalServer()` / `stopLocalServer()` | 组合服务器生命周期 + 请求轮询 |
| `onBridgeEvent(type, handler)` | 类型化订阅 Rust 桥接事件（NativeBridge 按 type 分发到各 Repository） |

### 状态管理

设置与运行时状态由 Repository 模块变量持有；**会话状态与聚合的唯一事实源为 `service/transfer/TransferSessionRegistry`**，VM 通过注册表查询 + `subscribeSessions`/`notifyChange` 刷新。跨页面共享 URIs 通过 `setPendingSharedUris/consumePendingSharedUris` inbox 传递；接收文本消息/媒体文件信息仍以 `peek/consume` 队列供相册保存与文本展示消费（会话生命周期信号已不再走一次性队列）。

## 统一会话引擎（service/transfer/）

| 文件 | 职责 |
|------|------|
| `TransferSessionRegistry.ets` | 会话注册表（SSOT）：创建/追加文件/进度/状态/终结/取消/重试/查询、终态可见窗口与有界回收（同标识重建取消挂起定时器）、协议无关聚合快照、历史读写入口 |
| `SessionHistoryStore.ets` | 会话历史存储：抽象接口 + `PreferencesUtil` 实现（单键 JSON、FIFO 有界、`schemaVersion`、按会话标识幂等归档；被拒绝或撤回取消的待确认请求不归档），与文件级接收历史相互独立；Preferences 实现以**内存权威列表**承载读取（首次访问加载一次，写入先改内存再触发落盘），读取不再每次解析全量 JSON；`resetSessionHistoryCache()` 供测试与重置场景失效缓存 |
| `DeviceSourceRegistry.ets` | 设备来源注册表（标签/图标/排序/发现数据源/空态与条件化引导/是否收藏）；空态支持可选 `dynamicText()` 动态文案（优先于静态 `text`，如 MTA 蓝牙关闭时切换提示） |
| `TransferMethodRegistry.ets` | 传输方式注册表（网页发送/网页接收/指定 IP，按「网页」与「其它方式」分组） |
| `SettingsGroupRegistry.ets` | 设置分组注册表（通用组固定 + 协议组动态） |
| `DefaultRegistrations.ets` | 协议默认注册集中点（来源/方式/设置分组；网页分享来源仅为会话条目提供来源协议标签，空发现数据源使其不成为发送页来源标签） |
| `adapters/SessionAdapter.ets` | 适配器契约（能力声明、展示描述符、确认/拒绝/取消/重试、事件翻译、资源释放）与适配器注册表；可选成员 `getGalleryMediaFiles(sessionId)` 提供该会话可保存到相册的媒体文件（未提供时页面回退既有接收媒体信号） |
| `adapters/LocalSendSendAdapter.ets` | LocalSend 发送：会话创建/进度/终态/取消/重试 |
| `adapters/LocalSendReceiveAdapter.ets` | LocalSend 接收：prepareUpload → 待确认/进行中；sessionEnd/cancelReceived/prepareUploadAborted → 终态；待确认超时终结与资源清理 |
| `adapters/MtaSendAdapter.ets` | MTA 发送：承接 `MtaSendService` 生命周期、收发互斥与取消/重试，并把阶段文案/进度/终态翻译为注册表操作 |
| `adapters/MtaReceiveAdapter.ets` | MTA 接收：REQUEST_RECEIVED → 待确认；建链/下载/落盘 → 进行中；COMPLETED/FAILED → 终态；文本消息会话经描述符携带文本，正向动作为「复制文本」（写剪贴板后回接受 ack，不进入下载），文件会话经 `getGalleryMediaFiles` 提供相册媒体 |
| `adapters/WebDownloadAdapter.ets` | Web 下载 burst 模型：静默窗口 + 接受后无活动超时；匿名对端描述符兜底 |
| `adapters/StubAdapter.ets` | 最小桩协议：验证「仅注册适配器与描述符即可被中心/详情页渲染并可取消」的扩展点；仅测试期由用例显式调用 `registerStubProtocol()`，不进入生产注册流程 |

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

## 文本消息准备（preview 补设）

LocalSend 协议以条目中的 `preview` 字段承载文本消息内容：接收端据此把该条目识别为「文本消息」而非普通 `.txt` 文件。

- `SendRepository.prepareSendFiles(uris, manualTextUris?)` 是全部 LocalSend 发送入口（单目标点击设备、指定 IP 分享、多目标内联发送、网页分享）唯一的条目构造点，preview 补设归位于此，不再有第二处实现。
- 「哪些条目属于手动文本」的筛选由 `entry/src/main/ets/model/SendTextPreparation.ets` 的纯函数 `collectManualTextUris(stagedFiles)` 唯一提供：仅收集 `isManualText === true` 的条目源定位，保持输入相对顺序，不依赖系统 API / 原生桥接 / UI 上下文（由 `entry/src/ohosTest/ets/test/model/SendTextPreparationTest.test.ets` 的纯函数用例覆盖）。
- 同模块的纯函数 `isAllManualText(stagedFiles)` 唯一提供「全部暂存条目是否均为手动文本」判定：集合非空且每个条目均为手动文本时为真，空集合为假（沿用既有约定并由本地纯函数用例锁定），存在任一未标记来源的条目（`undefined` 或显式 `false`）即为假。发送参数构建（`SendViewModel.buildSendParams` 与 `SendViewModel.buildMtaSendParams`）均调用该函数，不再各自构建布尔数组或内联累算。
- 调用方（`SendViewModel` 的预准备缓存路径 `prepareAndCacheItems`、网页分享路径 `shareByLink`）均调用该纯函数取得源定位列表并作为 `manualTextUris` 传入 `prepareSendFiles`；未传入该入参时不补设任何 preview（向后兼容）。
- 补设按条目独立进行：手动文本条目携带 preview，用户主动选择的 `.txt` 文件不带 preview（`StagedFile.isManualText` 是区分二者的唯一依据），混合内容互不影响。
- 文本临时文件缺失/不可读时 preview 留空，条目仍按普通文件发送，不影响发送流程完成。
- 传输页 `TransferViewModel.startSendTransfer` 消费发送页的预准备结果（已含 preview）；其无预准备缓存的回退路径不传入 `manualTextUris`，故不补设。
- 发送结局映射的唯一实现是 `SendRepository.finishSendFailure`：仅当本次发送为「单条文本消息」时，接收端的 403（拒绝）、204（仅预览送达）与 `partialFailure` 才按已送达处理（`success: true`）。「单条文本消息」的判据由 `entry/src/main/ets/model/SendTextPreparation.ets` 的纯函数 `isSingleTextMessageSend(files)` 唯一提供：整批恰好一个条目、内容类型为文本、且承载非空 preview 三者同时成立才为真，空集合与其余情形为假。用户主动选择的 `.txt` 文件虽同为文本类型但不承载 preview，故被拒绝时按普通文件结局报告（会话状态 `declined`），不会误报完成。该纯函数不依赖系统 API / 原生桥接 / UI 上下文，由 `entry/src/ohosTest/ets/test/model/SendTextPreparationTest.test.ets` 的纯函数用例覆盖主要分支，发送仓库是其唯一调用方；下游会话状态映射（`sendToDeviceWithSession`）不重复该判定。

## 预准备结果缓存与失效

发送页在首次发送前调用 `prepareSendFiles` 构造条目并计算校验和，结果缓存于 `SendRepository`（`setPrePreparedItems`），供多目标模式连续向多台设备发送时复用。

- 单目标模式导航到传输页时以 `consumePrePreparedItems` 一次性消费并清空缓存；多目标内联发送以 `peekPrePreparedItems` 查看但不消费，且发送成功后不清空暂存列表，缓存因此长期留存。
- 暂存列表的任何内容变更都必须使缓存失效（`invalidatePrePreparedItems`）：移除条目（`removeStagedFile`）、清空列表（`clearStagedFiles`）、分享入口合并新的文件条目（`refresh`），以及两个新增入口——文件选择器结果（`stageUris`）与手动文本暂存（`stageTextFile`；分享文本与粘贴入口同样经此失效）。
- 失效时机限定为「确有新增条目」：`stageUris` 跳过已暂存条目后按实际新增数判定，`stageTextFile` 在写入暂存列表之后失效；未发生新增时不失效，以保持连续多设备发送的准备结果复用（避免重复计算校验和）。
- 仅替换条目缩略图（视频首帧，`loadVideoPreview`）不改变发送内容，不失效缓存。

## 协议协商（加密不可降级策略）

纯逻辑提取为 `SendRepository.resolveSendProtocol(localHttps, remoteHttps)`，可独立测试；`sendToDevice` 调用该函数获取协商结果：

1. 发送端启用 HTTPS + 接收端支持 HTTPS → 使用 HTTPS
2. 发送端启用 HTTPS + 接收端不支持 HTTPS → 错误，拒绝降级（返回 null）
3. 发送端禁用 HTTPS + 接收端支持 HTTPS → 升级使用 HTTPS（接收端服务器只监听 HTTPS，明文连接无法建立）
4. 发送端禁用 HTTPS + 接收端不支持 HTTPS → 使用 HTTP

`senderProtocol`：接收端通过 `cert_fingerprint` 是否存在判断发送端协议（有证书→HTTPS，无证书→HTTP），存入 `PendingRequest.senderProtocol`，用于接收对话框验证按钮状态。

## 证书固定

`sendFiles` → `prepare_send` / `upload_file` 传递目标指纹 `expectedFingerprint`，Rust 层在 HTTPS 连接时验证服务端证书。
