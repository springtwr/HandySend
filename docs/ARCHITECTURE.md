# HandySend（便捷快传）架构文档

> 当项目结构、核心模块、API 接口等发生变更时，必须同步更新本文件及相关子文档。

## 1. 项目概述

HandySend 是基于 [LocalSend](https://github.com/localsend/localsend) v2 协议的 HarmonyOS NEXT 局域网文件共享客户端，通过 NAPI 桥接 Rust 协议核心库。

| 属性 | 值 |
|------|------|
| Bundle Name | `com.springtwr.handysend` |
| Target SDK | 26.0.0(API 26) |
| Compatible SDK | 6.1.0(23) |
| 许可证 | Apache License 2.0 |

## 2. 技术栈

| 层级 | 技术 |
|------|------|
| UI | ArkUI (ArkTS) |
| 协议 | LocalSend v2 (HTTP/HTTPS + UDP 组播/子网扫描发现) |
| 原生桥接 | HarmonyOS NAPI (napi-ohos 1.2) |
| 协议核心 | Rust → `liblocalsend_core.so` (HAR: `localsend_ohrs`) |
| 构建 | Hvigor / DevEco Studio / ohrs |
| 持久化 | Preferences (key-value) |
| 高端组件 | @kit.UIDesignKit (HdsTabs, SDK>=23) |

## 3. 目录结构

```
HandySend/
├── AppScope/                        # 应用级资源（图标、字符串）
├── entry/                           # 主模块
│   ├── src/main/
│   │   ├── module.json5             # 模块配置（权限、Ability、skill）
│   │   └── ets/
│   │       ├── entryability/        # EntryAbility 应用入口
│   │       ├── entrybackupability/  # EntryBackupAbility 备份扩展
│   │       ├── pages/               # 页面（Navigation 子页面，见 §8）
│   │       ├── components/          # 页面级内容组件 + 设置类型定义
│   │       ├── views/               # 可复用视图组件（传输/设备/弹窗）+ settings/ 设置分组
│   │       ├── service/             # 业务服务层
│   │       │   ├── AppService.ets   # 门面（初始化编排、事件分发、服务器生命周期）
│   │       │   ├── NativeBridge.ets # NAPI 桥接封装
│   │       │   ├── BackgroundTransferService.ets  # 后台传输服务（dataTransfer 长时任务 + 实况进度通知）
│   │       │   ├── PendingRequestNotifier.ets     # 后台待确认请求提示通知
│   │       │   ├── DialogService.ets
│   │       │   ├── GallerySaveService.ets
│   │       │   ├── transfer/        # ★ 统一会话引擎（注册表 + 会话历史 + 三类注册表 + 协议适配器）
│   │       │   └── repository/      # 按业务域拆分的 Repository（协议 I/O + 原生调用；详见 architecture/repositories.md）
│   │       ├── viewmodel/           # @ObservedV2 视图模型（含 TransferCenterViewModel / SessionDetailViewModel）
│   │       ├── model/               # 数据类型（详见 architecture/types.md）+ 设置默认值常量（SettingsDefaults，唯一事实来源）
│   │       │   └── transfer/        # 统一会话领域模型（TransferSession / SessionHistory / Registries）
│   │       ├── common/              # DesignTokens + Breakpoints + LanguageConstants + LogDomains + LogLevels + LogFormat
│   │       └── utils/               # 工具函数（Logger、格式化、校验、偏好读写等）
│   └── build-profile.json5          # 模块构建配置（不含签名，纳入版本控制）
├── localsend_ohrs/                   # Rust 原生 HAR 模块
│   ├── Cargo.toml                    # ★ 版本号唯一来源（crate-type=cdylib+lib，napi feature flag）
│   ├── rust/                         # Rust 源码（详见 architecture/native-bridge.md）
│   ├── tests/                        # OHRS 集成测试（独立 crate，详见 §7.2）
│   ├── package/                      # DevEco HAR 包结构
│   │   ├── hvigorfile.ts             # BuildRustNapi + RustTest 任务（版本同步 + 增量构建 + index.d.ts 一致性守卫 + Rust 测试）
│   │   ├── Index.ets                  # HAR 入口
│   │   └── libs/                     # .so 产物（arm64-v8a / x86_64，gitignore，增量判断依据）
│   └── third_party/localsend/        # Git submodule（fork 定制分支 harmony-web-ui，基于 v1.18.1 + 鸿蒙化定制；定制提交不推上游）
├── build-profile.json5               # 全局构建配置（含签名，gitignore）
└── oh-package.json5                  # 全局依赖
```

## 4. 核心模块

### 4.1 EntryAbility

`entry/src/main/ets/entryability/EntryAbility.ets`

- 处理系统分享 Intent（`ohos.want.action.sendData/sendMultipleData`）
- 始终加载 `MainTabFloating` 页面
- 窗口创建后注册 MaterialIcons 自定义字体（用于指纹图标渲染）
- 2in1 设备上约束窗口最小尺寸（480×640vp）
- 后台传输生命周期编排（详见 [architecture/background-transfer.md](architecture/background-transfer.md)）：
  - `onCreate` 初始化 `BackgroundTransferService`
  - `onBackground`：MTA 接收活跃（`isMtaReceivingActive()`）则跳过停止 MTA 接收，并启动后台传输任务（同步 `AppCore.setAppForeground(false)`）
  - `onForeground`：停止后台传输任务、撤回后台待确认请求提示通知并恢复前台状态（`setAppForeground(true)`）
  - `onDestroy` 兜底停止
- 2in1 设备注册 `windowStageClose` 拦截（API 14+）：标题栏点 X 时同步判断聚合传输快照——无活跃传输返回 false 正常退出；有活跃传输同步返回 true 阻止关闭，并异步弹出应用内二次确认（继续/退出），选"退出"主动终止应用（平台无主窗口隐藏能力，不再接入状态栏托盘、也不最小化窗口）

### 4.2 AppService ★ 核心业务门面

`entry/src/main/ets/service/AppService.ets`

AppService 是业务层的门面（facade）：初始化编排、Rust 事件分发、服务器生命周期组合。VM/View 统一从门面导入，门面通过 re-export 暴露 Repository 函数。业务逻辑按领域拆分到 `service/repository/`，各 Repository 职责、依赖关系、事件机制详见 [architecture/repositories.md](architecture/repositories.md)。

其中 `service/repository/MtaRepository.ets` 为应用级 MTA 运行时：持有仅用于发现的 `MtaBleClient` 实例与 MTA 接收服务单例，提供发现扫描、接收服务启停、收发互斥、接收命令门面与对外身份刷新；发现/收发编排、模拟品牌与文件保真等细节详见 [architecture/mta.md](architecture/mta.md)。

### 4.3 NativeBridge — NAPI 桥接

`entry/src/main/ets/service/NativeBridge.ets`

从 `localsend_ohrs` HAR 导入 Rust NAPI 函数，封装为 `native*` 函数并做类型转换。HAR 接口参数为 JSON 字符串，NativeBridge 负责 `JSON.stringify` + 类型映射。完整函数清单及 Rust NAPI 层结构详见 [architecture/native-bridge.md](architecture/native-bridge.md)。

**事件订阅模型**：NativeBridge 提供类型化事件订阅 `onBridgeEvent(eventType, handler)` / `offBridgeEvent(eventType, handler)`，内部维护事件表；NAPI 回调收到 Rust 事件 JSON（`{"type":"...","payload":{...}}`，camelCase type）后解析并按 type 分发给订阅者。Repository 按类型订阅事件。一次性操作统一为 Promise 接口。

### 4.4 DialogService — 弹窗服务

`entry/src/main/ets/service/DialogService.ets`

统一管理自定义弹窗，使用 `@Builder` + `openCustomDialog`（ComponentContent + wrapBuilder）模式。

- **A/B 类弹窗**（标准确认/提示/输入）使用 DialogV2 系统预置组件，在各调用点组件内打开
- **C 类弹窗**由 DialogService 承载：`showPinDialog`（autoCancel:false 禁止点击外部关闭，DialogV2 无等价能力）；操作列表、通用重命名等弹窗由各调用点组件自行实现

### 4.5 Logger — 统一日志模块

`entry/src/main/ets/utils/Logger.ets` + `entry/src/main/ets/common/LogDomains.ets` + `entry/src/main/ets/common/LogLevels.ets` + `entry/src/main/ets/common/LogFormat.ets`

封装 hilog，提供双层输出（hilog 系统日志 + addLog 应用内日志），按业务域细分 domain，支持模块标签（label）与结构化上下文（LogContext）。仅依赖 `@kit.PerformanceAnalysisKit`（hilog）和 `entry/BuildProfile`（编译时常量），addLog 回调通过运行时注入。

日志消息统一为 `[模块标签] [上下文] 内容`：模块标签由 `LoggerInstance` 集中前置，上下文由 `LogFormat` 的 `composeLogMessage` 拼接，调用点只保留正文；未传标签时退化为 `[上下文] 内容`。

| 导出函数 | 说明 |
|----------|------|
| `getLogger(domain, tag, label?)` | 创建 LoggerInstance（每个模块顶层调用一次，返回实例复用）；`label` 为模块级稳定短标签（如 `发送`），缺省时省略标签前缀 |
| `registerAddLog(fn)` | 注入 addLog 回调（运行时注入，避免编译期循环依赖） |
| `initLogger()` | 根据编译模式初始化日志级别（Debug=DEBUG, Release=INFO） |
| `setDebugEnabled(on)` | 临时切换 Debug 开关（仅内存 + hilog 级别，不持久化，重启恢复） |
| `logger.log(level, msg, ctx?)` | 通用分级出口：按 `LogLevels` token 分发到对应 hilog 级别，未知 token 兜底 info |

**初始化链路**：`AppService.initAppService()` → `registerAddLog(addLog)` → `initLogger()`

**业务域常量**（`LogDomains`）：

| 域 | 值 | 适用模块 |
|----|----|----------|
| GENERAL | 0x0000 | AppService, EntryAbility, EntryBackupAbility, DialogService, ReceiveHistoryService, NativeBridge, NativeTypes, EventBus, HttpLogsViewModel |
| DISCOVERY | 0x0001 | DiscoveryRepository, DeviceRepository, MainTabViewModel |
| TRANSFER | 0x0002 | SendRepository, ReceiveRepository, TransferViewModel, TransferPage, SendViewModel, SendContent, WebShareRepository, ChecksumRepository, GallerySaveService, VideoThumbnailUtil, ReceiveTargets, BackgroundTransferService, PendingRequestNotifier |
| NETWORK | 0x0003 | AppCore, NetworkSettingsSection |
| SERVER | 0x0004 | ServerRepository |
| SETTINGS | 0x0005 | SettingsRepository, PreferencesUtil, FavoritesService, SettingsViewModel |
| MTA | 0x0006 | service/mta/*、MtaRepository、Mta*ViewModel |

**消息格式**：`[模块] 内容`；带上下文为 `[模块] [sid=.. dir=..] 内容`；Rust 来源为 `[模块] Rust: 内容`。模块标签集中前置，保证 `grep '\[模块\]'` 无歧义过滤；正文数据方括号（如 `[wlan0]`）保留不影响过滤。日志消息不得含换行符。

**规范约束**：全项目仅 Logger.ets 可直接 import hilog，其他文件必须通过 `getLogger()` 使用日志功能；禁止 `console.*` 输出。模块标签、TAG、域与级别规则的完整清单见 `docs/DEBUG_LOG_INVENTORY.md`。

**应用内日志缓冲与导出**：内存日志源位于 `AppCore.ets`（`logs: Array<LogEntry>`，上限 2000 条，超限裁剪到最近 1800 条），仅内存存储不做变更通知；HTTP 日志页进入时加载一次快照，不做实时订阅刷新；导出通过 `DocumentViewPicker` 落盘，VM 层编排文本拼接，Page 层仅调命令 + 按结果弹 Toast（严格 MVVM：VM 不碰 UIContext/fs/picker）。

### 4.6 GallerySaveService — 相册保存服务

`entry/src/main/ets/service/GallerySaveService.ets`

使用 `photoAccessHelper.MediaAssetChangeRequest`（API 12+）将媒体文件保存到系统相册。通过 SaveButton 安全控件获取临时授权，无需申请 `ohos.permission.WRITE_IMAGEVIDEO` 受限权限。

**相册保存流程**：

1. 接收完成 → `ReceiveRepository.finishReceiveSession` 提取媒体文件写入 `pendingRecvMediaFiles`
2. 统一会话详情页 `SessionDetailPage` 经 `consumeRecvMediaFiles` 消费
3. 用户点击 SaveButton 授权后经 `GallerySaveService.saveMediaToGallery` 从 Download 最终位置读取媒体文件保存到相册
4. 保存结果经 `ReceiveHistoryService.updateGallerySavedStatus` 回写接收历史（fd-direct 下无沙箱副本，文件即交付物、保留于 Download）

MTA 接收的待保存媒体（`ReceiverState.pendingMediaFiles`）目前仅留存于接收目录，尚未接入详情页的相册保存入口。

### 4.7 BackgroundTransferService — 后台传输服务

`entry/src/main/ets/service/BackgroundTransferService.ets`

后台传输保护（手机/平板/PC 通用）：应用处于后台且存在活跃传输（LocalSend 发送/接收、MTA 发送/接收、Web 分享下载）时申请 `dataTransfer` 长时任务，并以实况通知展示聚合进度。核心机制：

- 数据源唯一为 `TransferSessionRegistry.getOverallSnapshot()` 协议无关聚合快照
- 订阅 AppCore changeBus 以 1s 节流发布
- 服务为模块级单例，由 EntryAbility 生命周期驱动

启停驱动、终态处理、前台引导、删除通知取消（USER_CANCEL 时经统一取消入口取消全部非终态会话）等实现细节详见 [architecture/background-transfer.md](architecture/background-transfer.md)。

### 4.8 PendingRequestNotifier — 后台待确认请求提示

`entry/src/main/ets/service/PendingRequestNotifier.ets`

应用处于后台时到达「需用户手动确认」的接收/下载请求时，发布一条可点击回到前台的系统通知（独立通知 id，与实况进度通知区分）；提示按统一注册表的待确认会话计数驱动发布/撤回，请求本身即注册表中的待确认会话，用户在传输中心确认/拒绝。详见 [architecture/background-transfer.md](architecture/background-transfer.md)。

### 4.9 统一会话引擎 — TransferSessionRegistry / 协议适配器 / 三类注册表

`entry/src/main/ets/service/transfer/`

把现有五条传输路径（LocalSend 发送/接收、MTA 发送/接收、Web 分享下载）的会话与待确认请求统一到**唯一的会话注册表（SSOT）**，协议差异下沉到**协议适配器**。统一会话建模「用户可见的一次有界传输活动」，与协议层会话/授权解耦。

- **唯一事实源**：`TransferSessionRegistry` 持有会话表，提供创建/追加文件/进度/状态/终结/取消/重试/查询/终态回收；UI（传输中心、通用详情页）、后台长时任务与通知聚合、批量操作一律从注册表读取。取消/确认/拒绝/重试动作按适配器能力声明分发（`canCancel` / `needsConfirm` / `canRetry`）：声明不适用的动作为空操作，不改状态、不调用适配器（如 Web 下载 `canCancel=false`，仅能由协议侧终结）
- **传输模型**：`dataFlow`（outbound/inbound）× `initiatedBy`（local/remote）两个正交维度；进度支持字节级与离散阶段两种口径，容忍文件集增量追加导致的**分母增长**（不回跳、不据此误判完成）
- **终态判定权归适配器**：协议可能无结束信号，适配器可用静默窗口、无活动超时等策略；注册表只负责终态之后的**可见窗口**（成功 3s / 失败与取消 5s）、归档与回收，同标识重建时取消挂起的回收定时器（不被旧定时器误删）
- **唯一通知入口**：复用 `AppCore` 变更总线（`subscribe`/`notifyChange`）发布 UI 变化；接收完成的交付信号（相册保存与文本展示）仍经 `peekRecv*`/`consumeRecv*` 一次性读取接口由 AppService 暴露给 ViewModel
- **会话历史**：`SessionHistoryStore` 以**抽象存储接口** + `PreferencesUtil` 实现（单键 JSON、有界 FIFO、`schemaVersion`、按会话标识幂等归档）；与文件级接收历史相互独立
  - 归档规则：被拒绝、以及因发送方撤回/取消而终结的**待确认**请求不归档（尚未建立传输关系），已进入进行中后的取消/失败仍按原规则归档
  - Preferences 实现以**内存权威列表**承载读取：首次访问时从偏好存储加载一次，`persist`/`clear` 先更新内存再触发落盘（沿用偏好存储的防抖刷写），读取直命中内存，避免传输中进度事件高频触发中心刷新时反复同步读 + 全量 JSON 解析；`resetSessionHistoryCache()` 供测试与重置场景失效缓存
- **协议适配器契约**：`adapters/SessionAdapter.ets` 定义 `SessionAdapter`（能力声明、展示描述符、确认/拒绝/取消/重试、事件翻译、会话资源释放）与适配器注册表；可选成员 `getGalleryMediaFiles(sessionId)` 由适配器提供该会话可保存到相册的媒体文件（未实现或未提供时页面回退到既有接收媒体信号）
  - 现有五个适配器：`LocalSendSendAdapter` / `LocalSendReceiveAdapter` / `MtaSendAdapter` / `MtaReceiveAdapter` / `WebDownloadAdapter`，另有最小桩 `StubAdapter` 验证扩展点
  - 展示描述符的 `directionLabel`、对端名称与副标题（`peerTitle` / `peerSubtitle`）及会话离散阶段文案（`TransferSession.stageText`，MTA 各阶段文案）以 `ResourceStr` 承载并配三语言资源，随系统语言切换
  - 描述符另携带对端 `deviceType`，详情页据此选择设备图标（缺失或未知时回退手机）；MTA 协议载荷（BLE 广播、GATT DeviceInfo、sendRequest）不携带对端设备类型或型号，MTA 收发会话的 `deviceType` 恒回退手机图标，适配器不伪造设备类型
- **三类注册表**：默认注册集中在 `DefaultRegistrations.ets`
  - `DeviceSourceRegistry`：设备来源（标签/图标/排序/发现数据源/空态与条件化引导/是否收藏）
  - `TransferMethodRegistry`：方式（网页发送/网页接收/指定 IP，按「网页」与「其它方式」分组）
  - `SettingsGroupRegistry`：设置分组（通用组与协议组按同一 `order` 序列混排，新增协议只需注册自己的分组）
  - 来源空态描述支持可选 `dynamicText()` 动态文案（设置后优先于静态 `text`），如 MTA 蓝牙关闭时切换为开启蓝牙提示
- **Web 下载 burst 模型**：一次浏览器下载突发 = 一个统一会话；静默窗口判定终态，接受后无活动由适配器超时终结；匿名对端以「本地化前缀资源 + IP」拼接的展示名（如「网页客户端 · IP」）兜底；同 IP 终态后再次下载创建新会话
- **文本消息与相册入口**：
  - 文本消息的文本内容由 `ReceiveRepository` 摄入请求时取自待处理请求的 `preview`（仅手动输入文本带该字段），写经 `ensureReceiveSession` 进入适配器侧映射，展示描述符据以携带文本内容（`supportsTextPreview` + `textPreview`）
  - 详情页渲染文本预览卡片（可滚动文本 + URL 时「打开链接」），底部正向动作由「确认」替换为「复制文本」——写入剪贴板后经适配器收尾（回接受 ack，不进入下载流程）
  - 文件接收会话以 `canSaveToGallery` 声明相册能力，完成态的标题栏菜单次级入口经 `getGalleryMediaFiles` 取媒体文件交由 `GallerySaveService` 保存

## 5. Rust NAPI 层

`localsend_ohrs/rust/`

### 5.1 模块结构

桥接层按业务域组织（`bridge/`），上游类型隔离在 `adapter/` 模块，runtime 归 NAPI 层管理：

```
rust/
├── lib.rs                       # crate 入口（pub mod bridge; #[cfg(napi)] pub mod napi）
├── bridge/                      # 桥接层（纯逻辑，不依赖 runtime/NAPI）
│   ├── event.rs                 # BridgeEvent 强类型事件 + BridgeError + 事件分类
│   ├── state.rs                 # BridgeState（纯数据，无 runtime/callback）
│   ├── engine.rs                # StateAction + apply_actions（纯函数状态变更）
│   ├── identity.rs              # init/安全上下文/网络信息/哈希/日志工具
│   ├── server.rs                # 服务器生命周期 + 传输决策
│   ├── web_share.rs             # Web 分享/网页上传（分享链接、下载决策、fd 内容源）
│   ├── client.rs                # 发送/接收/取消/注册
│   ├── discovery.rs             # 发现生命周期 + 扫描 + 设备查询
│   ├── mta/                     # MTA 发送端 TLS/WS/HTTP/ZIP 服务器 + 接收端 Rust 主导下载（工程自有代码）
│   │   ├── mod.rs               # 服务器生命周期（start/stop、配置解析、事件发射）
│   │   ├── protocol.rs          # 应用层消息纯函数（构造/解析/JSON、status 判定）
│   │   ├── zip_stream.rs        # 按文件清单库化流式写出 ZIP（详见下方「zip_stream 约束」）
│   │   ├── unzip_stream.rs      # 自有 ZIP 流式解析/解压核心（Stored/Deflated/带与不带签名数据描述符/ZIP64 扩展字段）+ 条目数/解压总量/单条目字节上限等安全约束
│   │   ├── receive.rs           # 接收端 Rust 主导下载（reqwest + 流式解压 + 直接写目标目录 + 进度/取消/回滚）
│   │   ├── ws.rs                # WS 连接上的 MTA 状态机（协商→请求→下载→状态）
│   │   └── server.rs            # hyper + tokio-rustls TLS 服务器（/websocket 升级、/download 流式 ZIP）
│   └── adapter/                 # 上游类型隔离（ServerEventV2/MulticastEvent/ClientError）
│       ├── server.rs            # ServerEventV2/WebSendEvent/InternalEvent → BridgeEvent
│       ├── multicast.rs         # MulticastEvent/DiscoveryEvent → BridgeEvent
│       ├── client.rs            # ClientError → BridgeError
│       └── types.rs             # DTO 定义 + 上游↔DTO 转换
└── napi/                        # NAPI 适配层（按入口域组织，napi feature 门控）
    ├── env.rs                   # NapiEnv（OnceLock 持有 Runtime + BridgeState + event_rx）
    ├── event_forwarder.rs       # 事件转发（napi_threadsafe_function）
    ├── identity.rs / server.rs / client.rs / discovery.rs / mta.rs   # NAPI 入口
    └── mod.rs                   # #[napi] 对象结构 + 模块声明
```

**zip_stream 约束**（`bridge/mta/zip_stream.rs`）：

- `ZipWriter::new_stream` 无 Seek；条目压缩方法恒为 Deflated——无 Seek 写出必然产生数据描述符，而对端解析器只接受压缩方法条目携带描述符
- 所有条目统一使用同一压缩档位，不按文件类型区分
- ZIP64 由库在条目超 32 位上限时自动启用；CRC 由库写出时计算
- 数据源为 ArkTS 直传 fd，文本条目回退沙箱路径；逐条目写源文件修改时间

### 5.2 架构关键决策

- **runtime 归 NAPI 层**：`NapiEnv` 通过 `OnceLock` 全局持有 tokio Runtime（multi_thread, 4 workers），`BridgeState` 不持有 runtime，避免 async 上下文 drop panic
- **事件走 mpsc channel**：`state.event_tx: Option<mpsc::Sender<BridgeEvent>>`，桥接层函数通过参数注入，消费者（NAPI/test）持有 receiver
- **adapter 隔离上游类型**：上游 `ServerEventV2` 变更时只需修改 `adapter/server.rs`（match 穷尽检查引导适配）
- **adapter + engine 纯函数**：`adapt_xxx(event) -> (Option<BridgeEvent>, Vec<StateAction>)` + `apply_actions(&mut BridgeState, actions)`，零网络零 runtime 可单测
- **事件 backpressure 分级**：关键事件 `send().await` 保证送达，`UploadProgress` 用 `try_send` 丢弃
- **事件循环 JoinHandle 管理**：`server_event_task`/`discovery_event_task`/`web_send_event_task` 存于 BridgeState，stop 时 abort
- **幂等性与错误语义**：重复 `start_server` 返回 `AlreadyRunning`；未启动 `stop_server` 幂等 Ok；重复/竞态 `accept_transfer` 返回 `SessionExpired`

Rust NAPI 层函数清单、事件系统、进度追踪、Web Share 架构详见 [architecture/native-bridge.md](architecture/native-bridge.md)。

## 6. 类型定义

应用层与 NAPI 层类型定义详见 [architecture/types.md](architecture/types.md)。

## 7. 测试体系

采用分层测试体系：

### 7.1 ArkTS 层

- **Instrument Test**：设备端测试，运行于真机/模拟器，统一承载 ArkTS 侧全部单元测试（纯逻辑函数、.so 调用、Repository 逻辑和事件解析），覆盖原 Local Test 迁移的全部用例

运行命令见 `docs/BUILD.md`，Instrument Test 编写规范见 `docs/testing/instrument-test-guide.md`。

### 7.2 Rust 核心层

Rust 核心层采用三层测试架构，由 `napi` feature flag 控制编译范围：

| 层级 | 位置 | 运行命令 | 说明 |
|------|------|----------|------|
| 上游核心测试 | `third_party/localsend/` | `cargo test --target x86_64-unknown-linux-gnu -p localsend --features crypto,discovery,http,multicast` | 验证协议实现正确性 |
| OHRS 集成测试 | `localsend_ohrs/tests/` | `cargo test --target x86_64-unknown-linux-gnu`（从 `tests/` 目录运行） | 验证桥接层事件管道（server_flow/client_flow/discovery_flow，event_tx/event_rx 直接消费）+ 配置矩阵（config_matrix：HTTPS/PIN/校验和开关、多接收者、Web Share、多文件、进度序列、协议安全边界），无 mock 无轮询 |
| 桥接层单元测试 | `localsend_ohrs/rust/bridge/` | `cargo test --target x86_64-unknown-linux-gnu --no-default-features --lib` | 验证纯函数：adapter 适配、engine 状态变更、identity 身份/安全/哈希、server/client/discovery 编排逻辑 |

**Feature flag 机制**：

- `napi`（默认启用）：编译 NAPI 适配层（`napi/` 目录），依赖 `napi-ohos`，仅能在 OHOS 交叉编译目标上编译
- 关闭 `napi`（`--no-default-features`）时仅编译 `bridge/` 模块（纯逻辑，无 NAPI 依赖），可在 Linux native target 上运行 `cargo test`

**关键点**：`--target x86_64-unknown-linux-gnu` 覆盖父目录 `.cargo/config.toml` 中的 OHOS 交叉编译目标；单元测试需额外加 `--no-default-features --lib` 避免链接 OHOS NDK。测试体系以纯函数单元测试为主力（214 个，零网络零 runtime），集成测试覆盖事件管道与配置矩阵（31 个），含 NAPI 封装完整性 guard 与跨层事件契约校验。

可通过 hvigor 任务在 DevEco Studio 侧边工具面板执行，详见 `docs/BUILD.md`。

### 7.3 CI/CD

Rust 三层测试已接入 GitCode AtomGit Action 自动化流水线（`.gitcode/workflows/ci.yml`），push/PR 时自动执行 NAPI 封装完整性校验、格式检查、Clippy、单元测试、集成测试和上游测试。ArkTS 侧和设备测试暂未接入（需自托管 Runner）。详见 `docs/BUILD.md` §8。

### 7.4 NAPI 封装完整性守卫 + 跨层事件契约

实现为 Rust 集成测试（`localsend_ohrs/tests/src/integration/napi_guard.rs`，跨平台，`cargo test` 直接执行），含两个校验：

1. **NAPI 封装完整性**：从 `index.d.ts`（NAPI 构建产物，由 Rust `#[napi]` 生成）提取所有导出函数名，与 `NativeBridge.ets` 的 `import { ... } from 'localsend_ohrs'` 块做差集。差集非空则报错。
2. **跨层事件契约**：解析 `NativeTypes.ets::parseNativeEvent` 各 case 分支读取的 payload 字段，与 Rust `BridgeEvent` 序列化契约表（见 `bridge/event.rs::test_all_event_variants_payload_contract`，同表双端校验）比对。任一端改动事件 tag/字段名（未同步对端）即报错。

**原则**：NAPI 层只导出 ArkTS 实际使用的函数，不存在"导出了但故意不封装"的情形。若某个 NAPI 函数 ArkTS 不需要，应删除该 `#[napi]` 导出（而非豁免）。

触发时机：CI `cargo test` + lefthook pre-commit 钩子（`localsend_ohrs/rust/napi/**` / `NativeBridge.ets` / `NativeTypes.ets` / guard 测试本身变更时）。

新增 NAPI 函数时：在 `NativeBridge.ets` 添加封装；若 ArkTS 不需要，则不添加 `#[napi]` 导出。改动 `BridgeEvent` 或 `parseNativeEvent` 事件字段时：两端同步修改（契约测试会拦截单向改动）。

## 8. UI 架构

### 8.1 页面路由

应用内导航采用组件导航（Navigation + NavPathStack + NavDestination，官方推荐）：

- `MainTabFloating` 为唯一 `@Entry` 页面，同时作为 Navigation 根容器承载 NavPathStack（现有 Tabs/侧边栏内容作为 NavBar 首页）
- 子页面为 `@ComponentV2` + `NavDestination` 内容页，注册于系统路由表 `entry/src/main/resources/base/profile/router_map.json`
- 跳转：`pathStack.pushPathByName(路由名, params)`；返回：子页经 `NavDestination().onReady` 获取 `pathStack` 后 `pop()`

| 页面 | 用途 |
|------|------|
| `MainTabFloating` | 主页（三个稳定一级区域：发送 / 传输中心 / 设置）+ Navigation 根容器 |
| `TransferCenterPage` | 传输中心（一级页签内容 + 路由页外壳）：跨协议聚合全部会话并合并为单一「会话」列表（详见下方说明） |
| `SessionDetailPage` | 唯一通用会话详情页：协议差异仅经适配器描述符、能力声明与可选插槽表达（详见下方说明） |
| `ShareLinkPage` | 分享链接 + 二维码 + 下载/上传请求确认 |
| `DeviceDetailsPage` | 设备详情 |
| `ReceiveHistoryPage` | 文件级接收历史（入口移入传输中心） |
| `VerifyPage` / `TroubleshootPage` | 验证/故障排除 |
| `DebugPage` / `HttpLogsPage` | 调试页面（服务信息/证书重置、诊断日志浏览与导出） |

**TransferCenterPage 行为细节**：

- 合并「会话」列表的构成：进行中 / 待确认 / 终态可见窗口 / 持久化历史，按会话时间倒序、按会话标识去重
- 「会话」标题行提供本机信息、文件历史与清除历史入口，页面顶部提供取消全部活跃
- 页面标题由主页页签承载，不重复展示

**SessionDetailPage 行为细节**：

- 内容结构：方向说明 / 设备卡 / 总进度与速度 / 逐文件进度卡（文本消息会话为文本预览卡片）/ 结果 / 时间线 + 底部固定动作区
- 同一时刻只呈现一组底部动作：待确认两键 / 进行中取消 / 终态返回或重试；指纹验证与保存到相册经标题栏菜单次级入口
- 返回不取消会话
- 会话在终态可见窗口结束后被回收时保留最后一次快照，继续呈现终态结果而不退化为空白占位页
- 按持久化历史条目标识进入时渲染只读摘要（对端/方向/来源协议/结果/时间/文件数与总大小，逐文件进度与时间线不保留并给出明确说明）
- 「自动完成」开启时，会话在浏览期间进入终态后约 2s 自动返回（相册保存弹窗可见与文本消息阅读时不返回，直接打开已终结会话不触发）

### 8.2 主页面结构

```
MainTabFloating
├── SendContent (装配发送页三区)
│   ├── SendContentZone  内容区（类型选择 + 暂存列表，可折叠/限高）
│   └── SendTargetZone   目标区（来源注册表驱动：来源标签/设备网格/收藏/刷新/空态）
│       └── SendMethodZone 方式区（方式注册表驱动：网页组 / 其它方式组）
├── TransferCenterContent (传输中心：单一「会话」标题行入口〔本机信息 / 文件历史 / 清除历史〕 + 合并会话列表〔进行中/待确认/终态可见窗口/历史，时间倒序，按会话标识去重〕 + 待确认交互 + 空态)
└── SettingsContent (按设置分组注册表装配 views/settings/ 各分区)
```

发送页设备展示按分流规则保证每台设备任意时刻恰好出现一次：

- `SendViewModel.getFavoriteDevicesForDisplay()` 以持久化收藏记录为基础数据源，仅输出「不在发现快照中」的离线收藏设备——判定只按 fingerprint 匹配、不比较 IP（容忍 DHCP 重新分配）；指纹命中发现快照的在线收藏由附近设备列表承载展示
- 离线收藏以收藏记录字段兜底合并为 `DiscoveredDevice` 形状的展示对象（自定义别名不可被广播别名覆盖；IP/端口/型号/类型/版本按「实时快照 > 收藏记录持久化字段 > 缺省」的回退链取值），不随附近列表的离线移除而消失
- 展示数组为空时，整个收藏区块连同标题一起不渲染；收藏区块仅在局域网标签下渲染
- 两处列表的 `Repeat` 键值由指纹与全部影响渲染的字段拼接而成，保证任一字段变化都会触发对应条目重建刷新

发送页整体作为跨应用拖放目标接收统一拖拽数据（统一数据管理框架 UDMF）：根容器声明 `allowDrop`，拖入记录经 `model/DragDropParser.ets` 纯函数按 UTD 分流后由 `SendViewModel.applyDroppedContent` 复用既有暂存链路，与系统分享链路行为一致。解析分流规则、暂存去重、容错反馈与授权可靠性提示详见 [architecture/drag-drop.md](architecture/drag-drop.md)。

MTA（互传联盟）主流程接入复用上述统一列表：发现的互传联盟设备经 `DiscoveredDevice` 统一形状（`protocol = 'mta'`）合并进统一设备集，发送经 `MtaSendAdapter`、接收经 `MtaReceiveAdapter` 登记到统一注册表，对外身份品牌取自设置项「模拟品牌」。发现扫描策略、来源标签与警告横幅、收发编排、模拟品牌与文件信息保真详见 [architecture/mta.md](architecture/mta.md)。

### 8.3 浮动 Tab 栏

使用 `HdsTabs` + `barOverlap(true)` + `barFloatingStyle` + `bindScroller` + `applyHideAnimation`/`applyShowAnimation` 实现浮动 Tab 栏（系统内置动画），要求 API >= 23。

滚动显示/隐藏逻辑：
- 子组件通过 `onScrollDelta(deltaY, absY)` 回调报告滚动增量和绝对偏移
- `absY ≤ 20` 时永远不隐藏（防止顶部回弹抖动）
- Tab 切换时自动恢复显示
- `-999` 哨兵值表示内容到达顶部，强制显示

### 8.4 设置页分组与半屏弹窗

设置页由 `SettingsContent` 依据设置分组注册表（`SettingsGroupRegistry`）装配 `views/settings/` 下的分区组件：分组标题由注册表描述符提供并统一渲染，分区组件只提供卡片内容（一个分组可含多个卡片）。

| 分区组件 | 内容 | 所属分组 |
|----------|------|----------|
| `DeviceIdentitySection` | 设备名称（随机/系统名称）+ 设备类型（半屏弹窗）+ 设备型号 | 设备信息 |
| `GeneralSettingsSection` | 自动完成/保存到相册/保存到历史/自动清空选中文件 | 通用（接收与发送） |
| `NetworkSettingsSection` | LocalSend 单卡片：服务器状态（启停/重启）+ 自动确认请求 + 接收 PIN（输入弹窗）+ 自动确认下载请求 + 高级设置折叠（加密传输/端口/创建校验和/组播组/发现超时/网络接口半屏弹窗）+ 服务器重启与网络警告横幅 | LocalSend |
| `ReceiveSettingsSection` | 自动确认请求（分段控件）+ 接收 PIN（输入弹窗）；作为 LocalSend 卡片的内容片段（无卡片容器） | LocalSend |
| `SendSettingsSection` | 自动确认下载请求；作为 LocalSend 卡片的内容片段（无卡片容器） | LocalSend |
| `MtaSettingsSection` | 互传联盟（MTA）接收开关 + 模拟品牌行（品牌图标 + 本地化显示名）与 `bindSheet` 品牌选择（点选即生效并关闭）+ 互传连接提醒开关 | 互传联盟（MTA） |
| `AppearanceSettingsSection` | 主题/滚动隐藏页签 + 语言半屏弹窗 | 外观 |
| `MoreSettingsSection` | 反馈/关于半屏弹窗 + 诊断日志 + 恢复默认 | 更多 |

分组按「设备信息 → 通用（接收与发送）→ LocalSend → 互传联盟（MTA）→ 外观 → 更多」的按使用频率顺序装配：通用分组与协议分组共用同一 `order` 序列混排（`listSettingsGroups()` 按其升序返回），新增协议仍只需注册自己的分组。LocalSend 分组收敛为单卡片，卡内顺序为服务器状态 → 自动确认请求 → 接收 PIN 码 → 自动确认下载请求 → 高级设置折叠。

本机信息（设备名称/设备指纹/各网卡 IP）经传输中心「会话」标题行入口的 `bindSheet` 呈现（`LocalDeviceSection`），不作为设置分组；服务状态归属 LocalSend 分组的服务器状态，二者不再重叠。

各半屏弹窗独立持有 `@Local isShowXxxSheet` 开关，通过 `bindSheet` 呈现。

### 8.5 响应式设计

断点体系基于系统窗口宽度断点（`@Env(SystemProperties.BREAK_POINT)`，类型 `uiObserver.WindowSizeLayoutBreakpointInfo`），覆盖手机/平板/折叠屏/PC（2in1）各形态。宽度断点区间：sm `[320,600)`、md `[600,840)`、lg `[840,1440)`、xl `[1440,+∞)`。

- **断点工具**（`common/Breakpoints.ets`）：
  - `WidthBreakpointType<T>`：四档取值工具（xs 归入 sm 档）
  - `getMaxContentWidth`：md→800、lg→960、xl→1120，sm/xs→0 全宽
  - `isNarrowWidth`（xs/sm）、`isWideWidth`（lg/xl）
  - `getSheetWidth`：sm/md→480、lg/xl→560
  - `getPageMargin`：sm→16、md→24、lg→24、xl→32
  - `isTabletPortrait`（tablet + HEIGHT_LG）
- **Tab 栏形态**：md 及以下 / 平板竖屏（tablet + HEIGHT_LG）/ 矮窗（height<600vp mediaquery 兜底）→ 底部水平栏；lg/xl 宽屏且非平板竖屏 → 侧边垂直栏 (barWidth=96)
- **内容最大宽度**：md 800 / lg 960 / xl 1120，sm 不限制
- **设备列表**：`SendContent` 使用 GridRow/GridCol 栅格按断点切换列数（sm/md 单列、lg 2 列、xl 3 列）
- **弹窗宽度**：统一 `constraintSize({ maxWidth: 480 })`
- **PC（2in1）窗口**：`module.json5` orientation 配置 `auto_rotation_restricted`；运行时按 `deviceInfo.deviceType === '2in1'` 调用 `window.setWindowLimits({ minWidth: 480, minHeight: 640 })`
- **深色模式**：完整 `dark/` 资源覆盖

### 8.6 文件类型图标

发送页暂存列表（`SendContent`）与接收历史列表（`ReceiveHistoryPage`）的文件类型图标统一由 `utils/FileTypeIconUtil.ets` 的纯函数 `getFileTypeIconResource(isMessage, fileName, fileType)` 映射，判定链依次为：

1. 纯文本消息（isMessage）
2. image/video/audio MIME 前缀
3. MIME 精确匹配表（PDF / Office 与 WPS 文档 / OFD / 流程图 / 思维导图 / 压缩包 / 文本 / 代码 / APK / 可执行文件等分类）
4. MIME 缺失或为 `application/octet-stream` 时经 `MimeUtils.getMimeForFileName` 按文件名扩展名回退重试
5. 未知类型兜底

两处列表共用同一函数，保证同一文件图标一致。

图标资源为 `entry/src/main/resources/base/media/` 下的彩色 PNG，命名 `ic_file_*`（message/image/video/audio/pdf/word/excel/ppt/ofd/flow/mindmap/archive/txt/code/apk/exe/unknown 共 17 个），仅放 `base` 限定符目录、无 dark 变体（彩色图标自带底色）：

- 发送页暂存列表中非媒体图标 40vp 直接显示（无灰底容器）
- 接收历史沿用 `DesignTokens.size.thumbSm` 尺寸居中
- 图片/视频条目优先显示缩略图，类型图标仅作缩略图缺失或未就绪时的回退

`MimeUtils.getMimeForExt` 的映射表覆盖常见文件格式及流程图/图表格式的识别（pom/vsd/vsdx/drawio/eddx/pos，六者统一显示流程图图标 `ic_file_flow`）。

## 9. 状态管理

采用 V2 状态管理（@ComponentV2 体系）：

- 页面级状态：`@Local`（持有 `@ObservedV2` ViewModel，`@Trace` 属性变化驱动精准 UI 刷新）
- 子组件参数：`@Param`（引用语义）
- 子组件回调：`@Event`
- 列表渲染：`Repeat` + `.each()/.key()`
- 弹窗：DialogV2（ConfirmDialogV2/AlertDialogV2/TipsDialogV2/CustomContentDialogV2）经 `openCustomDialog({ builder })` 打开；C 类自定义弹窗保留 DialogService（`@Builder` + `openCustomDialog`）
- 业务/共享状态：ViewModel 属性（@ObservedV2 + @Trace）+ Repository 模块变量（SSOT）
- 跨组件通知：Repository 事件总线（`subscribe`/`unsubscribe`/`notifyChange`）+ FavoritesService 回调
- 统一会话状态：`TransferSessionRegistry` 为唯一事实源；`TransferSession`/`SessionFile` 为 `@ObservedV2` 且进度/状态字段标 `@Trace`，列表条目按行内刷新（`Repeat` 键稳定，避免整行重建）
- 会话生命周期通知：注册表复用 `AppCore` 变更总线（`subscribeSessions`/`notifyChange`）发布 UI 变化；接收完成的交付信号（相册保存与文本展示）仍经 `peekRecv*`/`consumeRecv*` 一次性读取接口由 AppService 暴露给 ViewModel
- 传输中心：`TransferCenterViewModel` 从注册表读取全部会话与会话历史并合并为单一「会话」列表（进行中/待确认/终态可见窗口/历史按会话时间倒序、按统一会话标识去重），支持来源筛选与批量操作
  - 行序列在数据变更时一次性构建并缓存于 `@Trace` 字段（标题 + 可选来源筛选 + 条目/空态），渲染期不重算行模型、不逐行同步读取资源
  - 列表为扁平 `List`，该缓存序列同处一个带 `virtualScroll` 的顶层 `Repeat` 的直接子级 `ListItem` 序列（不使用 `ListItemGroup` 嵌套分组），配合 `cachedCount` 预加载，长会话历史下不因全量创建节点而卡顿
  - 卡片感由行内 padding/背景/圆角/描边表达，列表底部留出页签安全距离
- 新会话感知：`MainTabViewModel` 经 `start()`/`stop()` 订阅同一变更总线（与传输中心列表同源同时机刷新活跃/待确认角标），刷新时比对注册表中的待确认会话，出现新会话即经 `autoOpenSessionId` 信号通知 `MainTabFloating` 自动进入该会话详情页（首页可见时导航，已推入子页面时仅消费信号）
- 通用详情页：`SessionDetailViewModel` 读注册表会话 + 适配器展示描述符/能力声明 + 时间线，速度/ETA 由 `SpeedEstimator` 派生（不可用时以占位符呈现）
  - 会话被回收（`getSession` 返回 undefined）时保留最后一次快照，使详情页继续呈现终态结果而非空白页
  - 从未加载到会话（终态可见窗口已结束）时按持久化历史条目标识加载只读摘要
- 发送页：`SendViewModel` 移除单/多目标模式与内联进度；点击设备即创建会话并发送，暂存内容默认保留（可选「发送成功后自动清空暂存」）
- 跨页面共享 URIs：`setPendingSharedUris`/`consumePendingSharedUris` inbox
- 持久化偏好：`PreferencesUtil`（存储名 `handysend_settings`）；全部设置项默认值集中定义于 `model/SettingsDefaults.ets`（唯一事实来源，Repository 初始值/回退值、ViewModel 初始值与「恢复默认」、视图层非默认值判断均引用该常量）

## 10. 权限

| 权限 | 说明 |
|------|------|
| `ohos.permission.INTERNET` | 网络访问 |
| `ohos.permission.GET_NETWORK_INFO` | 获取网络信息 |
| `ohos.permission.GET_WIFI_INFO` | WiFi P2P 状态查询与连接（MTA 收发：建组/查组/p2pConnect 入组/本机 MAC/网络快照） |
| `ohos.permission.ACCESS_BLUETOOTH` | BLE 广播/扫描/GATT Server/GATT Client（MTA 主流程收发） |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | dataTransfer 长时任务（后台传输服务，见 §4.7） |

`module.json5` 声明 `dataTransfer` backgroundModes。

注册的 skill：主屏启动 (`ohos.want.action.home`) + 系统分享接收 (`ohos.want.action.sendData/sendMultipleData`)

## 11. 功能特性

- **传输**：文件传输、图片传输、剪贴板共享、文本发送、传输取消、HTTPS 加密传输、校验和（SHA-256）、传输保真（局域网与互传联盟两条链路均采集并在接收端还原源文件修改时间）、后台续传（后台存在活跃传输时申请或保持 dataTransfer 长时任务并以实况通知展示聚合进度，覆盖 LocalSend 收发、MTA 收发与 Web 下载，删通知即取消全部传输，见 §4.7）
- **发现**：UDP 组播 + HTTP 子网扫描设备发现、收藏设备
- **网页**：网页分享（二维码 + Web Send 浏览器下载，网页鸿蒙高保真风格 + 手动文本内联预览与复制）、Web Upload（浏览器上传文件/发送文本）、PIN 保护（Web Share 复用 receivePin）
- **接收**：自动确认请求（off/paired/on，Web Share 下载遵循独立的「自动确认下载请求」开关）、自动完成（传输完成后自动退出传输页）、相册保存（SaveButton 安全控件 + MediaAssetChangeRequest，无需 WRITE_IMAGEVIDEO 权限）、接收历史（含 savedToGallery 标记）、指纹验证（Material Icons 图标体系 + SHA-256 哈希对齐 LocalSend v1.18）
- **互传联盟（MTA）**：基础收发（发送页按设备来源标签发现并单目标发送互传联盟设备，含原生文本；应用前台按「互传联盟接收」开关自动接收互传联盟设备传输，落盘并按真实类型写入接收历史）
- **系统集成**：深色模式、外部分享、文件中转站拖入（跨应用统一拖拽 UDMF，文件/图片/文本/链接）、PC 关闭二次确认（2in1 有传输点 X 弹出继续/退出确认，无传输直接退出，见 §4.1）

统一会话详情页向对端会话展示（接收显示发送方/来自、发送显示接收方/发送到），列出文件清单与逐文件独立进度条及状态（等待/传输中/已完成）；发送页设备条目只承担发现与选择、不内联展示进度（进度与状态只在传输中心与详情页呈现）；接收端因 LocalSend v2 协议单活动上传会话限制，向并发发送方呈现"对方忙，请稍后重试"的可操作反馈。

## 12. 注意事项

1. **浮动 Tab 栏**：使用 HdsTabs + barFloatingStyle，要求 API >= 23
2. **文件导出依赖用户交互**：DocumentViewPicker 选择保存位置
3. **ohrs 路径限制**：Windows 不支持含空格路径，需符号链接
4. **MaterialIcons 字体**：Flutter SDK 的 MaterialIcons-Regular.otf 注册为自定义字体，用于指纹图标渲染
