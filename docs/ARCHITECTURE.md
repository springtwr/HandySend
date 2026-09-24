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
| 高端组件 | @kit.UIDesignKit (HdsNavigation / HdsNavDestination / HdsTabs, SDK>=23) |

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
│   │       ├── pages/               # 页面（导航子页面，见 §8）
│   │       ├── components/          # 页面级内容组件 + 设置类型定义
│   │       ├── views/               # 可复用视图组件（传输/设备/弹窗）+ settings/ 设置分组
│   │       ├── service/             # 业务服务层
│   │       │   ├── AppService.ets   # 门面（初始化编排、事件分发、服务器生命周期）
│   │       │   ├── NativeBridge.ets # NAPI 桥接封装
│   │       │   ├── BackgroundTransferService.ets  # 后台传输服务（dataTransfer 长时任务 + 实况进度通知）
│   │       │   ├── PendingRequestNotifier.ets     # 后台待确认请求提示通知
│   │       │   ├── PermissionService.ets          # 运行时权限查询、申请与设置页引导（通知/蓝牙）
│   │       │   ├── DialogService.ets
│   │       │   ├── GallerySaveService.ets
│   │       │   ├── transfer/        # ★ 统一会话引擎（注册表 + 任务历史 + 三类注册表 + 协议适配器）
│   │       │   └── repository/      # 按业务域拆分的 Repository（协议 I/O + 原生调用；详见 architecture/repositories.md）
│   │       ├── viewmodel/           # @ObservedV2 视图模型（含 TransferCenterViewModel / SessionDetailViewModel）
│   │       ├── model/               # 数据类型（详见 architecture/types.md）+ 设置默认值常量（SettingsDefaults，唯一事实来源）
│   │       │   └── transfer/        # 统一会话领域模型（TransferSession / SessionHistory / Registries）
│   │       ├── common/              # DesignTokens + Breakpoints + ImmersiveTitleBar + LanguageConstants + LogDomains + LogLevels + LogFormat
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
- 窗口内容加载完成后申请通知与蓝牙权限（经 `PermissionService` 串行排队；两个接口仅首次弹窗，已授权或用户已拒绝后静默返回，见 §4.10）
- 窗口创建后注册 MaterialIcons 自定义字体（用于指纹图标渲染）
- 2in1 设备上约束窗口最小尺寸（480×640vp）
- 后台传输生命周期编排（详见 [architecture/background-transfer.md](architecture/background-transfer.md)）：
  - `onCreate` 初始化 `BackgroundTransferService`
  - `onBackground`：MTA 接收活跃（`isMtaReceivingActive()`）则跳过停止 MTA 接收，并启动后台传输任务（同步 `AppCore.setAppForeground(false)`）
  - `onForeground`：停止后台传输任务、撤回后台待确认请求提示通知并恢复前台状态（`setAppForeground(true)`）
  - `onDestroy` 兜底停止
- 2in1 设备注册 `windowStageClose` 拦截（API 14+）：标题栏点 X 时同步判断聚合传输快照——无活跃传输返回 false 正常退出；有活跃传输同步返回
  true 阻止关闭，并异步弹出应用内二次确认（继续/退出），选"退出"主动终止应用（平台无主窗口隐藏能力，不再接入状态栏托盘、也不最小化窗口）

### 4.2 AppService ★ 核心业务门面

`entry/src/main/ets/service/AppService.ets`

AppService 是业务层的门面（facade）：初始化编排、Rust 事件分发、服务器生命周期组合。VM/View 统一从门面导入，门面通过 re-export 暴露 Repository 函数。
业务逻辑按领域拆分到 `service/repository/`，各 Repository 职责、依赖关系、事件机制详见 [architecture/repositories.md](architecture/repositories.md)。

其中 `service/repository/MtaRepository.ets` 为应用级 MTA 运行时：持有仅用于发现的 `MtaBleClient` 实例与 MTA 接收服务单例，提供发现扫描、
接收服务启停、收发互斥、接收命令门面与对外身份刷新，接收/扫描各入口受 MTA 总开关守卫（关闭时空操作）；发现/收发编排、模拟品牌与文件保真等细节详见 [architecture/mta.md](architecture/mta.md)。

### 4.3 NativeBridge — NAPI 桥接

`entry/src/main/ets/service/NativeBridge.ets`

从 `localsend_ohrs` HAR 导入 Rust NAPI 函数，封装为 `native*` 函数并做类型转换。HAR 接口参数为 JSON 字符串，NativeBridge 负责
`JSON.stringify` + 类型映射。完整函数清单及 Rust NAPI 层结构详见 [architecture/native-bridge.md](architecture/native-bridge.md)。

**事件订阅模型**：NativeBridge 提供类型化事件订阅 `onBridgeEvent(eventType, handler)` / `offBridgeEvent(eventType, handler)`，内部维护事件表；NAPI 回调收到
Rust 事件 JSON（`{"type":"...","payload":{...}}`，camelCase type）后解析并按 type 分发给订阅者。Repository 按类型订阅事件。一次性操作统一为 Promise 接口。

### 4.4 DialogService — 弹窗服务

`entry/src/main/ets/service/DialogService.ets`

统一管理自定义弹窗，使用 `@Builder` + `openCustomDialog`（ComponentContent + wrapBuilder）模式。

- **A/B 类弹窗**（标准确认/提示/输入）使用 DialogV2 系统预置组件，在各调用点组件内打开
- **C 类弹窗**由 DialogService 承载：`showPinDialog`（autoCancel:false 禁止点击外部关闭，DialogV2 无等价能力）；操作列表、通用重命名等弹窗由各调用点组件自行实现

### 4.5 Logger — 统一日志模块

`entry/src/main/ets/utils/Logger.ets` + `entry/src/main/ets/common/LogDomains.ets` + `entry/src/main/ets/common/LogLevels.ets` + `entry/src/main/ets/common/LogFormat.ets`

封装 hilog，提供双层输出（hilog 系统日志 + addLog 应用内日志），按业务域细分 domain，支持模块标签（label）与结构化上下文（LogContext）
。仅依赖 `@kit.PerformanceAnalysisKit`（hilog）和 `entry/BuildProfile`（编译时常量），addLog 回调通过运行时注入。

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
| GENERAL | 0x0000 | AppService, EntryAbility, EntryBackupAbility, DialogService, ReceiveHistoryService, NativeBridge, NativeTypes, EventBus, HttpLogsViewModel, PermissionService |
| DISCOVERY | 0x0001 | DiscoveryRepository, DeviceRepository, MainTabViewModel |
| TRANSFER | 0x0002 | SendRepository, ReceiveRepository, ReceiveTargets, SendViewModel, SendContent, WebShareRepository 等（完整清单见注 1） |
| NETWORK | 0x0003 | AppCore, NetworkSettingsSection |
| SERVER | 0x0004 | ServerRepository |
| SETTINGS | 0x0005 | SettingsRepository, PreferencesUtil, FavoritesService, SettingsViewModel |
| MTA | 0x0006 | service/mta/*、MtaRepository、Mta*ViewModel |

> **注 1**：TRANSFER 域适用模块完整清单：SendRepository, ReceiveRepository,
> ReceiveTargets, SendViewModel, SendContent, WebShareRepository, ChecksumRepository,
> GallerySaveService, VideoThumbnailUtil, service/transfer/*（会话引擎与协议适配器）,
> TransferCenterViewModel, SessionDetailViewModel, BackgroundTransferService,
> PendingRequestNotifier。

**消息格式**：`[模块] 内容`；带上下文为 `[模块] [sid=.. dir=..] 内容`；Rust 来源为 `[模块] Rust: 内容`。
模块标签集中前置，保证 `grep '\[模块\]'` 无歧义过滤；正文数据方括号（如 `[wlan0]`）保留不影响过滤。日志消息不得含换行符。

**规范约束**：全项目仅 Logger.ets 可直接 import hilog，其他文件必须通过 `getLogger()` 使用日志功能；禁止 `console.*` 输出。模块标签、TAG、域与级别规则的完整清单见 `docs/DEBUG_LOG_INVENTORY.md`。

**应用内日志缓冲与导出**：内存日志源位于 `AppCore.ets`（`logs: Array<LogEntry>`，上限 2000 条，超限裁剪到最近 1800 条）；
日志写入仅经独立的日志通道（`logBus`）通知诊断日志页订阅者，不触发全局界面刷新。诊断日志页进入时加载一次快照，
其后按「合并窗口 + 积压阈值」策略增量刷新并滚动跟随（上滑暂停时浮出「回到底部」主色胶囊控件）；
「详细日志（DEBUG）」开关位于该页标题栏底部自定义区域、常驻可见且不随列表滚动离开视野，状态不持久化；
导出通过 `DocumentViewPicker` 落盘，VM 层编排文本拼接，Page 层仅调命令 + 按结果弹 Toast（严格 MVVM：VM 不碰 UIContext/fs/picker）。

### 4.6 GallerySaveService — 相册保存服务

`entry/src/main/ets/service/GallerySaveService.ets`

使用 `photoAccessHelper.MediaAssetChangeRequest`（API 12+）将媒体文件保存到系统相册。通过 SaveButton 安全控件获取临时授权，无需申请 `ohos.permission.WRITE_IMAGEVIDEO` 受限权限。

**相册保存流程**：

1. 接收完成 → `ReceiveRepository.finishReceiveSession` 提取媒体文件写入 `pendingRecvMediaFiles`
2. 统一会话详情页 `SessionDetailPage` 经 `consumeRecvMediaFiles` 消费
3. 用户点击 SaveButton 授权后经 `GallerySaveService.saveMediaToGallery` 从 Download 最终位置读取媒体文件保存到相册
4. 保存结果经 `ReceiveHistoryService.updateGallerySavedStatus` 回写接收历史（fd-direct 下无沙箱副本，文件即交付物、保留于 Download）

MTA 接收的待保存媒体（`ReceiverState.pendingMediaFiles`）经 `MtaReceiveAdapter.getGalleryMediaFiles` 接入统一详情页的相册保存入口。

### 4.7 BackgroundTransferService — 后台传输服务

`entry/src/main/ets/service/BackgroundTransferService.ets`

后台传输保护（手机/平板/PC 通用）：应用处于后台且存在活跃传输（LocalSend 发送/接收、MTA 发送/接收、Web 分享下载）时申请 `dataTransfer` 长时任务，并以实况通知展示聚合进度。核心机制：

- 数据源唯一为 `TransferSessionRegistry.getOverallSnapshot()` 协议无关聚合快照（活跃标志、会话数、设备数、进度与字节汇总只统计已进入传输的「进行中」会话，待确认不计入活跃）
- 订阅 AppCore changeBus 以 1s 节流发布
- 服务为模块级单例，由 EntryAbility 生命周期驱动
- 进度通知与待确认提示通知的点击均携带「任务中心」深链意图（Want 参数 `handysend.navigate=transferCenter`），冷/热启动回前台后统一落到任务中心列表

启停驱动、终态处理、前台引导、删除通知取消（USER_CANCEL 时经统一取消入口取消全部非终态会话）等实现细节详见 [architecture/background-transfer.md](architecture/background-transfer.md)。

### 4.8 PendingRequestNotifier — 后台待确认请求提示

`entry/src/main/ets/service/PendingRequestNotifier.ets`

应用处于后台时到达「需用户手动确认」的接收/下载请求时，发布一条可点击回到前台的系统通知（独立通知 id，与实况进度通知区分）；提示按统一注册表的待确认会话计数驱动发布/撤回，
请求本身即注册表中的待确认会话，用户在任务确认/拒绝。点击该通知携带「任务中心」深链意图（见 §4.7），冷/热启动回前台后落到任务中心列表。
详见 [architecture/background-transfer.md](architecture/background-transfer.md)。

### 4.9 统一会话引擎 — TransferSessionRegistry / 协议适配器 / 三类注册表

`entry/src/main/ets/service/transfer/`

把五条传输路径（LocalSend 发送/接收、MTA 发送/接收、Web 分享下载）的会话与待确认请求统一到**唯一的会话注册表（SSOT）
**，协议差异下沉到**协议适配器**；统一会话建模「用户可见的一次有界传输活动」，与协议层会话/授权解耦。要点：

- **唯一事实源**：UI（任务、通用详情页）、后台长时任务与通知聚合、批量操作一律从注册表读取；
  取消/确认/拒绝/重试动作按适配器能力声明分发（`canCancel` / `needsConfirm` / `canRetry`），声明不适用的动作为空操作
- **终态判定权归适配器**（静默窗口 / 无活动超时等策略）；注册表只负责终态之后的可见窗口（成功 3s /
  失败与取消 5s）、归档与回收，并承担同设备取代、发送侧无进展兜底终结、清除历史语义与可进入性校验等不变式
- **协议差异承接**：协议适配器（`service/transfer/adapters/`）负责事件翻译与动作回调，三类注册表（设备来源 / 传输方式 / 设置分组）提供来源、方式与设置分组的扩展点
- **文件清单回填与展示口径**：接收类协议的逐文件清单在下载落盘完成后由适配器以真实结果**整体替换**（`setSessionFiles`），
  任务详情的文件条目数与任务列表的文件数量文案据此等于真实接收结果；待确认/进行中阶段的内联文本预览需具备「可预览来源」
  （条目路径非空 / 会话携带文本消息内容 / 已终态或历史只读），避免无内容占位被误判而提示「内容不可用」
- **任务历史**：`SessionHistoryStore` 独立持久化（存储文件 `handysend_session_history`），与文件级接收历史相互独立

详见 [architecture/session-engine.md](architecture/session-engine.md)。

### 4.10 PermissionService — 运行时权限服务

`entry/src/main/ets/service/PermissionService.ets`

集中通知授权与蓝牙权限（`ohos.permission.ACCESS_BLUETOOTH`，user_grant）的查询、首次申请与被拒后的设置页引导，供启动流程与设置页共用：

- **查询**：`isNotificationPermissionGranted`（`isNotificationEnabledSync`）与
  `isBluetoothPermissionGranted`（`checkAccessTokenSync`）；设置页「通用」分组据此展示授权状态，便于定位「缺权限导致功能异常」
- **申请**：`requestNotificationPermission`（`requestEnableNotification`）与 `requestBluetoothPermission`（`requestPermissionsFromUser`）；两个接口仅首次调用弹窗，已授权或用户已拒绝后再次调用静默返回
- **引导**：`guideToNotificationSettings`（`openNotificationSettingsWithResult`，用户设置完成后才返回，便于调用方刷新状态；低版本回退
  `openNotificationSettings`）与 `guideToBluetoothPermissionSetting`（`requestPermissionOnSetting`），用于用户拒绝后引导到系统设置页手动开启
- **串行排队**：所有申请经模块内串行链排队，同一时刻只发起一个系统弹窗，避免启动阶段多个权限申请同时弹出互相冲突。
  MTA 启动时的蓝牙权限申请（`MtaBleCommon.ensureBluetoothPermission`）委托本服务，与启动流程共用同一串行链

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
│   ├── web_share.rs             # Web 分享/网页上传（分享链接、下载决策、fd 内容源：pread 显式偏移读）
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
- **事件 backpressure 分级**：关键事件 `send().await` 保证送达；高频进度事件用 `try_send` 丢弃，
  但进度终值（100%）按关键事件送达（每文件完成判定的依据，不得因 channel 满而丢失）
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
| OHRS 集成测试 | `localsend_ohrs/tests/` | `cargo test --target x86_64-unknown-linux-gnu`（从 `tests/` 目录运行） | 验证桥接层事件管道与配置矩阵（见注 2） |
| 桥接层单元测试 | `localsend_ohrs/rust/bridge/` | `cargo test --target x86_64-unknown-linux-gnu --no-default-features --lib` | 验证纯函数（清单见注 3） |

> **注 2**：事件管道（server_flow/client_flow/discovery_flow，event_tx/event_rx 直接消费）；
> 配置矩阵（config_matrix：HTTPS/PIN/校验和开关、多接收者、Web Share（链接页、fd 内容源
> 大文件、重复/并发下载、HTTPS 下载）、多文件、进度序列、协议安全边界）；无 mock 无轮询。
>
> **注 3**：纯函数覆盖：adapter 适配、engine 状态变更、identity 身份/安全/哈希、
> server/client/discovery 编排逻辑。

**Feature flag 机制**：

- `napi`（默认启用）：编译 NAPI 适配层（`napi/` 目录），依赖 `napi-ohos`，仅能在 OHOS 交叉编译目标上编译
- 关闭 `napi`（`--no-default-features`）时仅编译 `bridge/` 模块（纯逻辑，无 NAPI 依赖），可在 Linux native target 上运行 `cargo test`

**关键点**：`--target x86_64-unknown-linux-gnu` 覆盖父目录 `.cargo/config.toml` 中的 OHOS 交叉编译目标；单元测试需额外加 `--no-default-features --lib` 避免链接
OHOS NDK。测试体系以纯函数单元测试为主力（209 个，零网络零 runtime），集成测试覆盖事件管道与配置矩阵（37 个），含 NAPI 封装完整性 guard 与跨层事件契约校验。

可通过 hvigor 任务在 DevEco Studio 侧边工具面板执行，详见 `docs/BUILD.md`。

### 7.3 CI/CD

Rust 三层测试已接入 GitCode AtomGit Action 自动化流水线（`.gitcode/workflows/ci.yml`），push/PR 时自动执行 NAPI 封装完整性校验、
格式检查、Clippy、单元测试、集成测试和上游测试。ArkTS 侧和设备测试暂未接入（需自托管 Runner）。详见 `docs/BUILD.md` §8。

### 7.4 NAPI 封装完整性守卫 + 跨层事件契约

实现为 Rust 集成测试（`localsend_ohrs/tests/src/integration/napi_guard.rs`，跨平台，`cargo test` 直接执行），含两个校验：

1. **NAPI 封装完整性**：从 `index.d.ts`（NAPI 构建产物，由 Rust `#[napi]` 生成）提取所有导出函数名，与 `NativeBridge.ets` 的 `import { ... } from 'localsend_ohrs'` 块做差集。差集非空则报错。
2. **跨层事件契约**：解析 `NativeTypes.ets::parseNativeEvent` 各 case 分支读取的 payload 字段，与 Rust `BridgeEvent` 序列化契约表（见
   `bridge/event.rs::test_all_event_variants_payload_contract`，同表双端校验）比对。任一端改动事件 tag/字段名（未同步对端）即报错。

**原则**：NAPI 层只导出 ArkTS 实际使用的函数，不存在"导出了但故意不封装"的情形。若某个 NAPI 函数 ArkTS 不需要，应删除该 `#[napi]` 导出（而非豁免）。

触发时机：CI `cargo test` + lefthook pre-commit 钩子（`localsend_ohrs/rust/napi/**` / `NativeBridge.ets` / `NativeTypes.ets` / guard 测试本身变更时）。

新增 NAPI 函数时：在 `NativeBridge.ets` 添加封装；若 ArkTS 不需要，则不添加 `#[napi]` 导出。改动 `BridgeEvent` 或 `parseNativeEvent` 事件字段时：两端同步修改（契约测试会拦截单向改动）。

## 8. UI 架构

### 8.1 页面路由

应用内导航采用组件导航（官方 UI 设计套件组件 HdsNavigation + NavPathStack + HdsNavDestination，官方推荐）：

- `MainTabFloating` 为唯一 `@Entry` 页面，同时作为导航根容器（`HdsNavigation`）承载 NavPathStack（现有 Tabs/侧边栏内容作为首页栏），并装配主页面标题栏
- 子页面为 `@ComponentV2` + `HdsNavDestination` 内容页，注册于系统路由表 `entry/src/main/resources/base/profile/router_map.json`（`buildFunction` 注册方式不变）
- 跳转：`pathStack.pushPathByName(路由名, params)`；返回：子页经 `HdsNavDestination().onReady` 获取 `pathStack` 后 `pop()`

| 页面 | 用途 |
|------|------|
| `MainTabFloating` | 主页（三个稳定一级区域：发送 / 任务 / 设置）+ 导航根容器 + 主页面标题栏 |
| `TransferCenterPage` | 任务（一级页签内容 + 路由页外壳）：跨协议聚合全部会话并合并为单一列表（详见下方说明） |
| `SessionDetailPage` | 唯一通用会话详情页：协议差异仅经适配器描述符、能力声明与可选插槽表达（详见下方说明） |
| `ShareLinkPage` | 分享链接 + 二维码 + 下载/上传请求确认 |
| `DeviceDetailsPage` | 设备详情 |
| `ReceiveHistoryPage` | 文件级接收历史（入口移入任务标题栏「更多」菜单） |
| `VerifyPage` / `TroubleshootPage` | 验证/故障排除 |
| `HttpLogsPage` | 诊断日志页（实时浏览与导出） |

**沉浸式标题栏与安全区扩展**（全应用统一顶部表现）：

- 标题栏配置统一由 `common/ImmersiveTitleBar.ets` 的 `buildImmersiveTitleBar()` 产出（标题文案 + 可选结束端菜单 + 可选形态覆盖项），页面不得内联模糊/层叠/滚动参数；主页面与全部路由子页面共用同一份配置
- 标题栏采用小标题模式（`HdsNavigationTitleMode.MINI` / `HdsNavDestinationTitleMode.MINI`），层叠于内容之上，
  并把标题栏设为组件级安全区（`enableComponentSafeArea`），使内容区自动按实际标题栏高度避让而无需预置高度常量
- 宽屏主界面是唯一例外：其按形态覆盖安全区开关、起始端内边距与滚动终点模糊半径（见 [8.2](#82-主页面结构)），
  子页面与窄屏不下发覆盖项、沿用上述默认配置
- 背景为**沉浸式渐变模糊**：`scrollEffectOpts` 配置 `enableScrollEffect` + `ScrollEffectType.IMMERSIVE_GRADIENT_BLUR` + 起止偏移常量，终点样式的背景板配置模糊半径；
  未滚动时背板透明，滚动到结束偏移达到最终强度。模糊生效策略**强制使能**（随系统策略档位自适应的策略在非最高档位不生效，会使背板退化为纯色块）
- **标题栏一律不下发不透明背板色**：不透明底色会覆盖滚动模糊；终点蒙层亦显式设为透明——默认的主题化灰蒙层会把穿透上来的内容洗白、
  退化为"不透明面板"；两态标题色固定为页面主文字色，避免滚动时色系突变（默认会切换为反差色）
- **通透悬浮观感的主路径是系统沉浸光感材质**：标题栏样式配置 `systemMaterialEffect`（仅组件级开启，不改变应用内其他组件外观）
  ；材质档位先经设备材质能力探测决定，能力缺失或探测失败时降级为默认档位并记 warn。模糊与蒙层配置作为材质不可用时的回退
- **菜单图标以资源引用传入、使用组件默认档位**：图形修饰对象自带固定字号会掩盖档位设置（放到最大档位也毫无变化）；最大档位会使无背板约束的主页面按钮过大
- **内容穿透依赖逐层关闭裁剪**：滚动容器、页签容器与其内容容器（后两者 `clip` 默认为真）均须不裁剪，
  列表类还需配合预加载数量（第二参为真）使滚出视口的条目仍参与绘制；否则内容无法进入标题栏区域、背板下无内容可透出
- 滚动驱动来自 `bindToScrollable([当前滚动控制器])`：主页面逐页签绑定当前页签的真实控制器（嵌套底部页签时必须逐页签绑定，否则滚动模糊丢失），子页面绑定自身滚动容器
- 运行环境能力判定（`canIUse`）缺失时关闭滚动动态过渡，标题栏取起始样式；材质档位探测以同一能力判定为前提，探测失败时降级为默认档位

安全区扩展只作用于配置它的当前组件、不会向父/子组件传递，且仅当组件边界与避让区重合时生效，因此按「内容根节点 → 各直接中间节点 → 滚动容器
→ 内容」**逐层**配置 `expandSafeArea([SafeAreaType.SYSTEM], [TOP, BOTTOM])`（滚动容器内的延伸若不逐层补齐，滚动后会失效）。各载体链路：

| 载体 | 层级链 |
|------|--------|
| 主页 | `HdsNavigation` → `Stack` → `Column` → `HdsTabs` → `TabContent` → `Row` → 内容组件内部链 |
| 发送页 | 根 `Stack` → `Scroll` |
| 设置页 | 根 `Scroll` |
| 任务 | 内容根 `Column` → 列表容器 → `List` |
| 子页面 | `HdsNavDestination` → 各中间容器 → 滚动容器 |

顶部模糊载体与内容避让均由标题栏承担，底部避让沿用既有做法（内容区底部预留/偏移、`List.contentEndOffset`），全面屏手势导航下页面背景延伸至屏幕边缘、无白色条带。

**TransferCenterPage 行为细节**：

- 壳层（主入口页签与路由外壳）持有内容视图模型与滚动控制器并下传内容组件，同时承载标题栏与入口；内容组件为纯内容，自行启停视图模型的职责归壳层
- 合并列表的构成：进行中 / 待确认 / 终态可见窗口 / 持久化历史，按会话时间倒序、按会话标识去重；行序列为「条目 / 空态」，不含标题行
- 会话条目固定三行：方向文案（发送 / 来自 / Web 下载）、设备昵称 + 来源协议徽标（进行中与终态时行末展示状态徽标）、
  时间（精确到秒）+ 文件数量；进行中且具备字节进度时追加独立进度行，终态仅展示结果徽标不展示进度，无字节进度的会话不渲染误导性 0%
- 条目状态与进度直接绑定统一会话对象的 `@Trace` 字段（行模型只保留时间戳/方向/来源/昵称/文件数量等稳定展示值），与会话详情页同源同口径；历史条目行无实时对象，以终态快照展示
- 行序列构建后执行可解析性校验：不能解析为「实时会话或历史记录」的条目从序列中剔除并留痕，保证列表中每一条目都可进入详情
- 「任务」页签使用本地双向箭头图标（`ic_tab_transfer`），不再复用接收页签图标
- 标题与入口由标题栏承载：结束端直接图标为「本机信息」，其后的「文件历史」与「清除任务历史」由标题栏自动生成的「更多」菜单收纳（直接显示项数上限为「期望直接显示项数
  + 1」，为自动生成的「更多」入口预留槽位）；「清除任务历史」常显，无可清除内容（持久化历史 + 已终态可见会话）时置灰不可用
- 「清除任务历史」为不可逆操作，点击后先弹出共享二次确认弹窗（DialogV2 `AlertDialogV2`，取消 / 清除两键，取消不产生任何效果），确认后
  同时清空持久化历史、已终态可见会话条目与发送文本目录（`filesDir/text_send/`）
- 本机信息半模态与标题栏入口装配由 `views/transfer/TransferCenterTitleActions.ets` 统一提供，主入口与路由外壳共用，避免两处漂移；
  二次确认弹窗的说明文案由 `views/transfer/ClearHistoryConfirmDialog.ets` 统一提供，
  弹窗本体以两入口组件内的 `@Builder` 方法实现（DialogV2 需绑定组件实例），避免文案漂移
- 清空任务历史后由领域动作层发布变更总线通知，列表与入口置灰状态随通知自动重算

**SessionDetailPage 行为细节**：

- 内容结构：方向说明（与分区标题同风格）→ 独立设备卡（位于文件区块上方，单层卡片容器内直接排布对端信息，不套内层色块）→ 平铺总进度与速度（位于文件区块上方，
  历史条目无实时进度时不渲染、无卡片背景）→ 三区块结构——「文件」区块（分区标题 + 文件清单卡片〔条目直排于卡片内、相邻条目以分隔线区隔；校验和可得时一并展示；
  文本消息会话为文本预览卡片，不展示文件清单与字节进度〕）；「详情」区块（分区标题「传输详情」+ 完整信息卡片〔总大小/耗时/平均与峰值速度 + 结果与错误（同一卡片内，不单列分区） /
  本机与标识〕）；「时间线」区块（分区标题 + 时间线卡片），下接悬浮底部操作区；进度行（速度 / 剩余时间）与总体百分比同侧靠右对齐；时间点信息统一由时间线承载，详情区块不重复展示
- 设备卡展示对端设备信息（来源/发送方式徽标、型号徽标，缺失项降级省略）；设备图标按来源解析（MTA 来源用品牌图标、其余用设备类型图标，与发送页设备列表同源，进行中与结束后一致）
  ；对端标识（LocalSend 指纹，或 MTA 对端的 BLE 设备地址）默认中间缩略（保留首尾字符），标签随来源中性化，点击后弹出完整内容（弹窗文本可长按自由选择复制，单行居中、多行左对齐）
- 完整信息按「实时会话」与「历史条目」统一取数（`SessionDetailViewModel.meta`）：对端设备信息、逐文件清单、耗时、平均/峰值速度、错误信息与错误码、完整时间线、本机设备与标识；
  缺省字段以统一占位降级。**信息行统一为单行缩略**（宽度不足时按中间省略，不再多行完整展开），点击弹出完整值弹窗（弹窗文本可自由选择复制、单行居中多行左对齐），
  复制为长按整行（复制完整值并给出成功/失败提示，不附加来源标注）；本机与标识区块的两栏来源不同——「协议会话 ID」取自会话承载的协议层标识
  （协议无此概念或尚未回填时为空，展示统一占位），「会话标识」取自应用内统一会话标识（条目身份、详情取数依据）
- 详情信息以 `@ObservedV2` 类承载可变字段（`@Trace`）并在刷新时**原地更新同一实例**，展示子组件直接读取该实例字段；
  耗时与平均速度在**进行中按实时口径**（耗时 = 当前时刻 − 开始时刻；平均速度 = 已传字节 ÷ 已用时间）、**终态回落归档值**（耗时取会话耗时、平均速度取归档平均速度），
  待确认阶段或从未产生字节进度时保持统一占位符；刷新跟随既有的进度变更通知节奏，不引入独立定时器
- 文件区块按**统一预览规则**渲染，依赖「文件数量 + 文本类判定」（`isTextFile` 为唯一判定来源）与「可预览来源」：会话**仅一个文本类文件**时**内联预览**
  （文本卡片可滚动；发送方向标题为「发送给 X 的文本」、接收方向为「来自 X 的文本」；用户经文件选择器选中的 `.txt` 与手输文本消息表现一致，不做区分），
  但该条目已有路径、会话携带文本消息内容、或会话已终态/历史只读时才内联，否则按文件清单呈现（消除待确认/进行中阶段无内容占位被误判为内联而提示「内容不可用」）；会话**有多个文件**时展示文件清单；
  无文本类文件时仅清单。内容一律按**逐文件路径按需读取**（单文本文件的内联内容于数据变更时读取一次并缓存，渲染期不读盘；点击预览为按需读取），
  读取失败或文件不存在时明确提示「内容不可用」，不空白无响应。会话被回收后的历史态执行**同一套规则**（依据历史逐文件条目的路径），
  不再出现"预览退化成无意义的 `.txt` 条目"。文本预览（多文件点击预览弹窗与内联预览）支持长按自由选择复制；弹窗文本按单行居中、多行左对齐排版（与协议会话 ID 弹窗同口径）
- 文件清单条目左侧展示类型图标（与发送页暂存列表、接收历史同源）；条目在本机可读且为图片 / 视频时改为缩略预览（图片经异步存在性确认后以 URI 直渲、
  视频异步生成缩略图），不可读或生成失败时安静回退类型图标；缩略图在条目出现时按需加载一次，渲染期不读盘、同一条目不重复加载
- 点击任一条目弹出**统一操作菜单**（不再按文件类型隐式绑定点击行为）：「预览全文」（文本类、定位非空且未超预览阈值时可用）/
  「打开所在位置」（定位非空时可用，经系统文件管理器打开文件所在目录，打开前先判文件缺失）/「用其他应用打开」（定位非空时可用，
  以隐式 Want 携带文件 URI、MIME 类型与只读授权标志并强制展示系统应用选择框；无可用应用 / 调起失败 / 用户取消 / 定位不可转授均给出明确提示）
- 文本预览引入**单一阈值 128KB**（`utils/FilePreviewPolicy`，回退值 64KB，判定与读取上限同源）：超阈值的文本类条目不提供可用的预览项、
  不读取内容，并在菜单内说明「文件过大、不支持预览」；大小不可得（为 0 或未知）按可预览处理，不因缺信息而误禁
- 内联预览形态下若该文件超过预览阈值，不读取其内容，改为展示「文件过大、不支持预览」的明确提示，并保留「打开所在位置」与「用其他应用打开」两条出口
- 同一时刻只呈现一组底部动作：待确认文件会话为「拒绝 + 确认」，待确认文本消息会话为「关闭 + 复制」，进行中为单键「取消传输」；
  终态不渲染操作区（返回由系统手势与标题栏承担）；指纹验证经标题栏菜单次级入口。「保存到相册」不再有标题栏入口：由设置项统一控制，开启时接收完成且存在可
  保存媒体即自动弹出保存提示（候选媒体覆盖各协议路径：适配器可保存媒体能力优先，未实现该能力的协议回退到接收侧媒体信号，归属判定按协议层会话标识比对）
- 安全区按「子页面容器 → 各中间容器 → 滚动容器」逐层扩展（`expandSafeArea`，顶部 + 底部），`page_background` 延伸至屏幕最底；底部操作区以 `Stack`
  透明悬浮于内容之上（按钮直接浮在内容上方、无渐隐遮罩，内容自操作区背后滚过），滚动内容列底部预留下方间距，全面屏手势导航下无白色小条、末张卡片完整可见、按钮不被系统导航条遮挡
- 返回不取消会话
- 会话在终态可见窗口结束后被回收时，优先退化为该会话的历史只读摘要；历史也不可得（如用户清空历史）
  时保留最后一次快照用于展示，但置位「实时会话已释放」使全部动作可用性为否（不再出现可点但无响应的动作按钮）
- 按持久化历史条目标识进入时，逐文件清单、完整时间线与上述完整信息同样可读（不可得项按约定降级）
- 「自动完成」开启时，会话在浏览期间进入终态后约 2s 自动返回（相册保存弹窗可见与文本消息阅读时不返回，直接打开已终结会话不触发）

**ReceiveHistoryPage 行为细节**：

- 列表行展示要素（自上而下）：文件名（最多两行，超出按系统能力选择行中/行尾省略）→ **文本类条目内容缩略预览**（仅内容可读且未超预览阈值时渲染）
  → 发送者与大小 → 时间；左侧为类型图标区（图片/视频缩略图就绪时优先，缺失回退类型图标）
- 缩略预览覆盖**全部文本类条目**（文本消息与用户经文件选择器选中的 `.txt`/`.md` 等一视同仁），内容为按需读取该文件所得：列表行出现时（`onAppear`）触发懒加载，
  不阻塞列表滚动、渲染期不读盘；读取经共用工具 `utils/FileTextUtil.readTextOfLocation`（预览场景传入预览阈值作为读取上限），文本类判定经
  `utils/MimeUtils.isTextFile` 唯一来源；预览行最多两行、超出省略，路径为空、非文本类、文件缺失、读取失败或**超过预览阈值**时**不渲染该行**且不报错
- 预览与条目操作口径与会话详情页**完全一致**，共用同一套公共能力：左侧类型图标区与媒体缩略按需加载（`components/FileEntryThumb`）、
  单行缩略值行及其弹窗（`components/SingleLineValueRow`）、文本预览阈值判定（`utils/FilePreviewPolicy`，阈值 128KB、回退 64KB）、
  条目操作菜单项与可用性判定（`components/FileEntryActions`）与文件定位 / 打开能力（`utils/FileLocationUtil`）；调整这些公共实现即两页同步生效
- 条目操作菜单：公共项为「预览全文 / 打开所在位置 / 用其他应用打开」（可用性同详情页条目），其后追加本页专有项「复制」（读取文件本身全文）与
  「删除记录」（保留既有确认流程与文案）；「打开所在位置」的可用性**只依据路径非空**（文本消息条目已是磁盘上的真实文件，不再因其「消息」语义被禁用），
  点击时先确认文件未缺失，文件缺失则提示且不打开目录
- 条目级可得性口径（`viewmodel/ReceiveHistoryItemViewModel`）：`canViewFullText` = 文本类且路径非空且未超预览阈值；`canCopyText` = 文本类且路径非空；
  `isPreviewOverLimit` = 文本类且路径非空且超预览阈值；`canOpenContainingFolder` = 路径非空；`previewText` = 按路径读取到的内容（未读取/不可用/超阈值为空串）
- 文本消息完整内容弹窗（点击文本类条目或选择菜单「预览全文」打开）：内容超出可视高度时在弹窗内滚动阅读、支持长按自由选择复制，
  文本按单行居中、多行左对齐排版（与协议会话 ID 弹窗同口径）；保留弹窗内「复制」按钮与内容不可用提示；**超过预览阈值时不读取内容、不弹窗，
  改为明确提示「文件过大、不支持预览」**
- 本轮只对齐预览与条目操作口径，不改列表结构、虚拟滚动与 `cachedCount` 约定，也不改其专有流程语义（清空历史、删除记录及其确认弹窗）

### 8.2 主页面结构

三大主页面顶部统一显示标题栏（标题随页签切换，层叠于内容之上；窄屏下毛玻璃随内容滚动渐显，宽屏下该滚动模糊关闭，见下文），页内不再重复标题与页面级入口；
主入口持有三个页签的真实滚动控制器与任务视图模型，经参数下传给内容组件。

主页面按窗口形态选择首页栏内容，页面根容器与三个页签的内容组件树共用：

```
MainTabFloating（@Entry，页面根容器为 HdsNavigation，仅首页栏内容随窗口形态分支）
└── HdsNavigation（页面根容器，沉浸式标题栏 + NavPathStack）
    └── 首页栏内容区（按窗口形态二选一）
        ├── 宽屏形态（lg/xl 且非平板竖屏、非矮窗、侧边栏菜单能力可用）
        │   └── Row 两段式布局
        │       ├── 左：宽侧边栏列（固定 240vp，不折叠不拖拽调宽；底色延伸至顶部高度带与底部系统栏）
        │       │   └── WidescreenSideBar（品牌区自顶部高度带起排布）
        │       │       ├── 顶部区：应用图标 + 应用名（随系统语言，高 56vp）
        │       │       └── HdsSideMenu：发送 / 任务 / 设置三项一级导航（任务项带数字角标）
        │       └── 右：内容区列（自带等于标题栏高度的顶部避让）
        │           └── HdsTabs（隐藏页签栏：barHeight 0、不可滑动切换）承载三个 TabContent
        └── 其余形态（手机 / 平板竖屏 / 矮窗 / 侧边栏菜单能力缺失）
            └── HdsTabs（底部浮动页签栏）承载三个 TabContent
```

三个 TabContent（宽窄两形态共用）：

```
├── SendContent (装配发送页三区；根 Stack 承载收藏设备半模态面板 bindSheet)
│   ├── SendContentZone  内容区（类型选择 + 暂存列表，可折叠/限高）
│   └── SendTargetZone   目标区（来源注册表驱动：来源标签/设备网格/收藏/刷新/空态）
│       └── SendMethodZone 方式区（方式注册表驱动：网页组 / 其它方式组）
├── TransferCenterContent (任务：合并会话列表〔进行中/待确认/终态可见窗口/历史，时间倒序，按会话标识去重〕 + 待确认交互 + 空态)
└── SettingsContent (按设置分组注册表装配 views/settings/ 各分区)
```

导航容器（`HdsNavigation`）在两种形态下均为页面根容器，窗口形态只切换其首页栏内容：宽屏下首页栏为「左宽侧边栏 + 右页签内容」的两段式
`Row`。宽屏下标题栏不再对内容区做自动避让（`enableComponentSafeArea` 关闭），改由右侧内容区列自行预留等于标题栏高度的顶部避让；标题栏
左侧侧边栏列自顶部高度带起排布，其品牌区（应用图标 + 应用名）与内容区标题栏同处一个高度带且互不重叠。标题栏的标题与菜单均须恒定下发：
组件按字段合并配置、省略字段会沿用上一次的值，故宽屏形态以空标题显式表示「不显示页签名」（页签识别由侧边栏选中高亮项承担）；若改用省略字段表示，
平板由竖屏转为横屏时页签名会被带进宽屏形态并压在侧边栏区域上方。宽屏下标题栏滚动终点模糊半径取 0，滚动时不再出现模糊背板，避免遮挡侧边栏品牌区。由此宽屏
下推入的子页面（`HdsNavDestination`）可正常渲染并全屏覆盖首页栏（侧边栏随之被覆盖），不会出现空白；窄屏形态不受影响（子页面仍全屏推入）。

宽屏侧边栏选中项与内容区页签索引同源（`currentTabIndex`）：点击导航项经侧边栏视图组件上抛，由主页面保存旧页签滚动位置、
调用页签控制器切换索引（切换动画开始时恢复目标页签滚动位置）并同步互传发现扫描可见性，与底部页签栏切换行为一致；
侧边栏「任务」项角标由 `MainTabViewModel.activeTransferCount` 驱动，口径为**非终态会话数**（进行中 + 待确认，与窄屏底部页签同源），
为 0 时不显示。形态判定见 [8.5](#85-响应式设计)。

主页根容器还承载两处全局行为（详见 [9. 状态管理](#9-状态管理)）：**新传输提示弹窗**——应用前台时收到新的待确认接收请求，
在任意页面（含子页面）之上弹出统一提示（「查看」进入该会话详情、「稍后」/遮罩/返回键仅关闭；单槽位守卫、按会话标识去重；后台不弹、回前台补弹一次）；
**通知深链**——点击后台传输 / 待确认通知携带「任务中心」深链意图，消费时先清空路由栈回到根、再切到任务页签。

两处页签容器均显式指定 `index`（取自 `currentTabIndex`），使窗口跨断点导致页签容器重建后回到用户当前页签，
标题栏文案与内容区保持一致；滚动位置的保存与恢复对滚动控制器读数做容错（控制器未绑定或已销毁时视为本次无有效位置，
不向上抛出异常），断点切换过程中切换页签不会因读数失败而中断。

主页面标题栏的标题与结束端菜单随页签索引驱动：

| 页签 | 标题栏内容 | 动作实现 |
|------|-----------|---------|
| 发送 | 标题「发送」+ 结束端「更多」溢出入口（收纳「故障排查 / 诊断日志」两项） | 点击弹出原生溢出菜单，按选择经路由栈推入对应页面 |
| 任务 | 标题「任务」+ 结束端「本机信息」图标 + 「更多」菜单（文件历史 / 清除任务历史） | 本机信息 → 半模态；文件历史 → 路由栈；清除任务历史 → 任务视图模型动作 |
| 设置 | 标题「设置」，无入口 | — |

设置页仅新增标题栏，页内分组标题与分区顺序保持既有形态。

发送页设备展示与收藏口径：

- 附近设备列表由来源注册表驱动渲染，点击设备即发送；条目上的心形图标提供一键收藏 / 取消收藏（写入方）
- 收藏设备的查看与使用统一经方式区「其它方式」菜单的「收藏列表」入口打开的半模态面板承载
  （`views/FavoriteDevicesSheet.ets`，宿主为发送页根 Stack 的 `bindSheet`）：面板列出全部收藏设备并标注
  在线 / 离线，点击在线设备直接发送（与附近列表一致），点击离线设备先按已保存地址定向探测、成功后再发送、
  失败给出明确提示；条目「更多」菜单提供设备详情、重命名（自定义别名）、恢复默认别名（还原设备广播名）
  与单台删除，长按进入多选模式后经顶部操作条批量删除，删除（单台 / 批量）均二次确认。入口不以是否已暂存
  内容为门禁，未选择内容时仍可打开面板，仅在点击设备发起发送时提示先选择内容；无收藏时空态仅提示
  「暂无已收藏设备」
- 条目「更多」菜单的「设备详情」先关闭面板再经 `onNavigateTo('DeviceDetailsPage', ...)` 路由跳转到既有
  设备详情页：bindSheet 不支持路由跳转，且模态弹窗跳转新页面时不会自动消失、会遮挡新页面，故须先关闭；
  参数由 `FavoriteDevice` 构造（可选字段补空串），离线收藏同样可查看已保存信息
- 面板「在线 / 离线」以发送页发现快照（`SendViewModel.discoveredDevices`）为唯一事实源，经视图
  `@Monitor('viewModel.discoveredDevices')` 驱动重算，与附近列表口径一致并实时反映设备上下线
- 收藏变更（新增 / 重命名 / 删除）经 `FavoritesService` 变更总线实时同步到面板与附近列表的心形状态；
  收藏的自定义别名回填附近列表条目（`DeviceItemViewModel.aliasOverride`），使同一设备两处显示一致
- 收藏条目与附近列表共用同一套设备图标（`DeviceIconUtil`）与徽标样式；面板仅覆盖 LocalSend 来源设备，
  互传联盟（MTA）设备因缺少稳定身份标识不纳入收藏

发送页整体作为跨应用拖放目标接收统一拖拽数据（统一数据管理框架 UDMF）：根容器声明 `allowDrop`，拖入记录经 `model/DragDropParser.ets` 纯函数按 UTD 分流后由
`SendViewModel.applyDroppedContent` 复用既有暂存链路，与系统分享链路行为一致。解析分流规则、暂存去重、容错反馈与授权可靠性提示详见 [architecture/drag-drop.md](architecture/drag-drop.md)。

MTA（互传联盟）主流程接入复用上述统一列表：发现的互传联盟设备经 `DiscoveredDevice` 统一形状（`protocol = 'mta'`）合并进统一设备集，发送经 `MtaSendAdapter`、接收经 `MtaReceiveAdapter`
登记到统一注册表，对外身份品牌取自设置项「模拟品牌」。发现扫描策略、来源标签与警告横幅、收发编排、模拟品牌与文件信息保真详见 [architecture/mta.md](architecture/mta.md)。

协议禁用态按「是否还有可用路径」分级呈现：单一协议禁用时不显示任何常驻提示——受影响的来源标签、收藏设备与方式入口已按开关隐藏或置灰，足以表达；仅当两个协议均禁用、发送页
已无可用路径时，顶部渲染一条中性提示卡（与既有提示横幅同结构但取信息语义色，说明两条协议均已关闭并提供「去设置」入口），且支持就地关闭。关闭状态由主页宿主持有、本次会话内
有效且不持久化（双关解除后复位，再次进入双关仍可见），跨 `TabContent` 重建保持；「去设置」仅切换页签，不直接改动开关。设置页 LocalSend 分组的「无 Wi-Fi」「接口全关」网络
警告横幅显式与 LocalSend 总开关联动（关闭时不显示，与发送页同口径），全应用警告横幅均不提供用户关闭入口（保持「实时反映当前状态」语义）。网页分享页在 LocalSend 关闭时不展示
失效地址、二维码与请求区，改渲染中性禁用提示；分享入口（网页分享 / 网页接收 / 指定 IP 分享）在总开关关闭时直接返回，作为菜单置灰之外的防御纵深。

### 8.3 浮动 Tab 栏

底部浮动页签栏为非宽屏形态的页签栏（宽屏形态改用常驻宽侧边栏并隐藏页签栏，见 8.2 / 8.5）。使用 `HdsTabs` + `barOverlap(true)`
+ `barFloatingStyle` + `bindScroller` + `applyHideAnimation`/`applyShowAnimation` 实现浮动 Tab 栏（系统内置动画），要求 API >= 23。

`bindScroller(页签索引, 滚动控制器)` 绑定的是各 Tab 内容组件**真实使用**的滚动控制器（由主入口持有并下传，内容组件不再内部自建），该控制器同时经
`bindToScrollable` 绑定到导航组件以驱动标题栏滚动模糊；页签切换时按 `TabContent.onWillHide` 保存偏移、按 `HdsTabs.onAnimationStart` 恢复，避免切换后滚动位置错乱。

滚动显示/隐藏逻辑：
- 子组件通过 `onScrollDelta(deltaY, absY)` 回调报告滚动增量和绝对偏移
- `absY ≤ 20` 时永远不隐藏（防止顶部回弹抖动）
- Tab 切换时自动恢复显示
- `-999` 哨兵值表示内容到达顶部，强制显示

`onScrollDelta` 的上报口径（各滚动组件 `onDidScroll` 回调参数不同，不可混用）：
- `deltaY`：帧内纵向增量，内容向上滚动为正、向下为负，取组件回调的第 1 个参数
- `absY`：滚动控制器当前绝对纵向偏移（顶部为 0）
- `Scroll` 回调为 `(xOffset, yOffset, scrollState)`，第 2 参 `yOffset` 即帧内纵向增量
- `List` 回调为 `(scrollOffset, scrollState)`，第 2 参是 `ScrollState` 枚举（仅 0/1/2），不是增量

### 8.4 设置页分组与半屏弹窗

设置页由 `SettingsContent` 依据设置分组注册表（`SettingsGroupRegistry`）装配 `views/settings/` 下的分区组件：分组标题由注册表描述符提供并统一渲染，分区组件只提供卡片内容（一个分组可含多个卡片）。

| 分区组件 | 内容 | 所属分组 |
|----------|------|----------|
| `DeviceIdentitySection` | 设备名称（随机/系统名称）+ 设备类型（半屏弹窗）+ 设备型号 | 设备信息 |
| `GeneralSettingsSection` | 自动完成/保存到相册/保存到历史/自动清空选中文件 | 通用（接收与发送） |
| `NetworkSettingsSection` | LocalSend 单卡片：LocalSend 总开关（关闭即停服务器/设备发现/网页分享；有活跃传输时关闭经二次确认弹窗，确认后中断相关会话）+ 服务器状态（启停/重启，总开关关闭时显示「已禁用」且按钮置灰）+ 自动确认请求 + 接收 PIN + 自动确认下载请求 + 高级设置折叠（含安全信息（证书）半屏弹窗）+ 服务器重启与网络警告横幅（「无 Wi-Fi」「接口全关」显式联动总开关，关闭时不显示；细节见注 4） | LocalSend |
| `ReceiveSettingsSection` | 自动确认请求（分段控件）+ 接收 PIN（输入弹窗）；作为 LocalSend 卡片的内容片段（无卡片容器） | LocalSend |
| `SendSettingsSection` | 自动确认下载请求；作为 LocalSend 卡片的内容片段（无卡片容器） | LocalSend |
| `MtaSettingsSection` | MTA 总开关（关闭即停接收服务与发现扫描；有活跃传输时关闭经二次确认弹窗）+ 互传联盟（MTA）接收开关（总开关关闭时置灰不可用）+ 模拟品牌行（品牌图标 + 本地化显示名）与 `bindSheet` 品牌选择（点选即生效并关闭）+ 互传连接提醒开关 | 互传联盟（MTA） |
| `AppearanceSettingsSection` | 主题/滚动隐藏页签 + 语言半屏弹窗 | 外观 |
| `MoreSettingsSection` | 反馈/关于/赞助半屏弹窗 + 诊断日志入口 + 恢复默认 | 更多 |

> **注 4**：接收 PIN 为输入弹窗；「高级设置折叠」含加密传输/端口/创建校验和/组播组/
> 发现超时/网络接口与安全信息（证书）半屏弹窗。

分组按「设备信息 → 通用（接收与发送）→ LocalSend → 互传联盟（MTA）→ 外观 → 更多」的按使用频率顺序装配：通用分组与协议分组共用同一 `order` 序列混排（`listSettingsGroups()`
按其升序返回），新增协议仍只需注册自己的分组。LocalSend 分组收敛为单卡片，卡内顺序为服务器状态 → 自动确认请求 → 接收 PIN 码 → 自动确认下载请求 → 高级设置折叠。

本机信息（标签「昵称」/ 完整不截断的设备指纹 / 各网卡「接口名 + 网络类型文字徽标 + IP」单行）经任务标题栏「本机信息」入口的 `bindSheet` 呈现（`LocalDeviceSection`），不作为设置分组；
半模态参数（宽屏居中 / 窄屏底部、尺寸、模糊与标题栏关闭按钮）由 `views/transfer/TransferCenterTitleActions.ets` 统一提供。服务状态归属 LocalSend 分组的服务器状态，二者不再重叠。

各半屏弹窗独立持有 `@Local isShowXxxSheet` 开关，通过 `bindSheet` 呈现。

### 8.5 响应式设计

断点体系基于系统窗口宽度断点（`@Env(SystemProperties.BREAK_POINT)`，类型 `uiObserver.WindowSizeLayoutBreakpointInfo`），
覆盖手机/平板/折叠屏/PC（2in1）各形态。宽度断点区间：sm `[320,600)`、md `[600,840)`、lg `[840,1440)`、xl `[1440,+∞)`。

- **断点工具**（`common/Breakpoints.ets`）：
  - `WidthBreakpointType<T>`：四档取值工具（xs 归入 sm 档）
  - `getMaxContentWidth`：md→800、lg→960、xl→1120，sm/xs→0 全宽
  - `isNarrowWidth`（xs/sm）、`isWideWidth`（lg/xl）
  - `getSheetWidth`：sm/md→480、lg/xl→560
  - `getPageMargin`：sm→16、md→24、lg→24、xl→32
  - `isTabletPortrait`（tablet + HEIGHT_LG）
  - `isWidescreenSideBarLayout`：宽 lg/xl 且非平板竖屏、非矮窗 → 宽侧边栏形态
    （矮窗标记来自 `mediaquery` 的 `(height<600vp)` 监听）
- **导航形态**：宽屏（`isWidescreenSideBarLayout` 成立且 `canIUse('SystemCapability.UIDesign.HDSPattern.Standard')` 可用）→ 首页栏为
  「常驻宽侧边栏 + 隐藏页签栏的内容区」两段式布局：侧边栏宽度取 `DesignTokens.size.widescreenSideBarWidth` 的固定 240vp、
  顶部区高度取 `widescreenSideBarHeaderHeight`、底色取 `app.color.accent_blue_bg`，导航菜单为 `HdsSideMenu`，其导航图标以系统
  符号（`sys.symbol.*`）+ `SymbolGlyphModifier` 承载，随选中 / 未选中态着色；内容区页签栏隐藏（`barHeight` 0 且不可滑动切换）。
  宽屏顶部由侧边栏品牌区与内容区标题栏并列占据同一高度带：标题栏关闭对内容区的自动避让、起始端内边距取侧边栏宽度，
  内容区列自行预留等于侧边栏顶部区高度（`widescreenSideBarHeaderHeight`，56vp）的顶部避让；滚动终点模糊半径取 0，滚动时不出现模糊背板。
  其余情况（md 及以下 / 平板竖屏 / 矮窗 / 能力缺失）→ 底部浮动水平页签栏
- **安全区策略**：导航根容器与内容根节点均声明 `expandSafeArea(SYSTEM, TOP+BOTTOM)`，宽侧边栏列底色声明 `expandSafeArea(SYSTEM, TOP+BOTTOM)`，
  使页面背景与侧边栏底色延伸至顶部高度带与底部系统导航条区域，不出现空白带或异色带
- **发送页布局**：单栏纵向滚动（内容区与目标区上下排列），不随窗口宽度分栏
- **内容最大宽度**：md 800 / lg 960 / xl 1120，sm 不限制
- **设备列表**：`SendTargetZone` 使用 GridRow/GridCol 栅格按断点切换列数（sm/md 单列、lg 2 列、xl 3 列），
  断点参照为窗口尺寸（默认）；单栏内容区宽度随窗口变化，按容器尺寸判定会低估列数
- **弹窗宽度**：统一 `constraintSize({ maxWidth: 480 })`
- **PC（2in1）窗口**：`module.json5` orientation 配置 `auto_rotation_restricted`；运行时按 `deviceInfo.deviceType === '2in1'` 调用 `window.setWindowLimits({ minWidth: 480, minHeight: 640 })`
- **深色模式**：完整 `dark/` 资源覆盖

### 8.6 文件类型图标

发送页暂存列表（`SendContent`）与接收历史列表（`ReceiveHistoryPage`）的文件类型图标统一由
`utils/FileTypeIconUtil.ets` 的纯函数 `getFileTypeIconResource(isMessage, fileName, fileType)` 映射，判定链依次为：

1. 纯文本消息（isMessage）
2. image/video/audio MIME 前缀
3. MIME 精确匹配表（PDF / Office 与 WPS 文档 / OFD / 流程图 / 思维导图 / 压缩包 / 文本 / 代码 / APK / 可执行文件等分类）
4. MIME 缺失或为 `application/octet-stream` 时经 `MimeUtils.getMimeForFileName` 按文件名扩展名回退重试
5. 未知类型兜底

两处列表共用同一函数，保证同一文件图标一致。

图标资源为 `entry/src/main/resources/base/media/` 下的彩色 PNG，命名 `ic_file_*`（message/image/video/audio/pdf/word/excel/ppt/ofd/flow/mindmap/archive/txt/code/apk/exe/unknown
共 17 个），仅放 `base` 限定符目录、无 dark 变体（彩色图标自带底色）：

- 发送页暂存列表中非媒体图标 40vp 直接显示（无灰底容器）
- 接收历史沿用 `DesignTokens.size.thumbSm` 尺寸居中
- 图片/视频条目优先显示缩略图，类型图标仅作缩略图缺失或未就绪时的回退

`MimeUtils.getMimeForExt` 的映射表覆盖常见文件格式及流程图/图表格式的识别（pom/vsd/vsdx/drawio/eddx/pos，六者统一显示流程图图标 `ic_file_flow`）。

### 8.7 空态

空态（列表或内容为空时的提示）统一由 `components/EmptyState.ets` 的 `EmptyState` 组件承载。该组件为无状态
展示件，仅依赖 `common/DesignTokens.ets` 与颜色资源，不引用视图模型、服务或页面模块；调用点只传文案与开关，
不再各自内联字号、颜色、内边距与对齐。

- **视觉基准**：主标题 `DesignTokens.font.bodyM`(14) + `text_secondary`；副提示 `DesignTokens.font.bodyS`(12) +
  `text_tertiary`（条件引导类提示由 `hintColor` 传入语义色），两者间距 `DesignTokens.space.tiny`(8vp)；
  水平方向始终居中，副提示缺省时不渲染
- **占满高度**：`fillHeight` 开启时占满可用高度并垂直居中（仅诊断日志页使用）；空态需与列表首行同位时，
  由调用点在组件外挂该页的左右页边距与首元素顶部间距（文件接收历史页取 16vp，与主页、发送页、设置页同一口径）
- **面板高度统一**：空态面板的最小高度统一取 `DesignTokens.size.emptyStateMinHeight`(120vp)，使高度不随
  文案行数与窗口宽度（窄屏折行）变化。卡片型空态由组件直接取该值；非卡片型空态（发送页两处位于「设备卡片」内）
  由调用方以该值减去外层卡片内边距反推出内容区最小值（`minHeight`）
- **卡片按该页条目形态跟随**：`useCard` 开启时套用与同页条目同款卡片（`radius.lg` + 1vp `border_light`
  边框 + `card_background` 背景）；左右内边距与条目文字对齐取 16vp，上下取 32vp。
  条目是卡片的页面（任务页、网络接口半模态、文件接收历史页）开启；条目非卡片的页面（诊断日志页、
  会话详情时间线）与已被卡片包裹的空态（发送页两处、Web 分享页）保持关闭，避免第二层卡片与双重内边距

调用点：

| 位置 | 文件 | useCard | fillHeight | minHeight |
|------|------|---------|------------|-----------|
| 任务页列表行级空态 | `views/transfer/TransferCenterList.ets` | 是 | 否 | — |
| 网络接口半模态空态 | `views/settings/NetworkSettingsSection.ets` | 是 | 否 | — |
| 文件接收历史页空态（与列表首行同位） | `pages/ReceiveHistoryPage.ets` | 是 | 否 | — |
| 诊断日志页整页空态 | `pages/HttpLogsPage.ets` | 否 | 是 | — |
| 发送页设备区空态（带条件引导）与无来源空态 | `components/send/SendTargetZone.ets` | 否 | 否 | 120 − 2×20 = 80vp |
| Web 分享页段落内空态 | `pages/ShareLinkPage.ets` | 否 | 否 | — |
| 会话详情时间线空态 | `views/transfer/SessionTimeline.ets` | 否 | 否 | — |

## 9. 状态管理

采用 V2 状态管理（@ComponentV2 体系）：

- 页面级状态：`@Local`（持有 `@ObservedV2` ViewModel，`@Trace` 属性变化驱动精准 UI 刷新）
- 子组件参数：`@Param`（引用语义）
- 子组件回调：`@Event`
- 列表渲染：`Repeat` + `.each()/.key()`
- 弹窗：DialogV2（ConfirmDialogV2/AlertDialogV2/TipsDialogV2/CustomContentDialogV2）经 `openCustomDialog({ builder })` 打开；C 类自定义弹窗保留 DialogService（`@Builder` + `openCustomDialog`）
- 业务/共享状态：ViewModel 属性（@ObservedV2 + @Trace）+ Repository 模块变量（SSOT）
- 跨组件通知：Repository 事件总线（`subscribe`/`unsubscribe`/`notifyChange`）+ FavoritesService 回调（`FavoritesService` 另导出 `renameFavorite`/`restoreDefaultAlias`/`removeFavorites`/`canRestoreDefaultAlias` 等收藏管理接口，供收藏面板消费）
- 统一会话状态：`TransferSessionRegistry` 为唯一事实源；`TransferSession`/`SessionFile` 为 `@ObservedV2` 且进度/状态字段标 `@Trace`，列表条目按行内刷新（`Repeat` 键稳定，避免整行重建）
- 会话生命周期通知：注册表复用 `AppCore` 变更总线（`subscribeSessions`/`notifyChange`）发布 UI 变化；
  接收完成的交付信号（相册保存与文本展示）仍经 `peekRecv*`/`consumeRecv*` 一次性读取接口由 AppService 暴露给 ViewModel
- 任务：`TransferCenterViewModel` 从注册表读取全部会话与任务历史并合并为单一列表（进行中/待确认/终态可见窗口/历史按会话时间倒序、按统一会话标识去重），按会话状态展示与操作
  - 行序列在数据变更时一次性构建并缓存于 `@Trace` 字段（条目 / 空态），渲染期不重算行模型、不逐行同步读取资源
  - 条目身份（列表渲染键）即统一会话标识，与会话一一对应且在整个生命周期内不变——不因条目来源由「终态可见窗口内的实时条目」转为「归档后的历史条目」而改变，按身份增量渲染因此始终复用同一行
  - 行序列构建顺序固定为「合并去重（实时条目优先）→ 兜底去重（再按会话标识去重）→ 确定性排序 → 可进入性校验 →
    组装（空态最后）」；排序以会话时间倒序为主键、以会话标识字典序为次级键，使顺序完全确定，不因同秒创建或来源遍历顺序而抖动
  - 行模型只缓存稳定展示值（时间戳/方向/来源协议/昵称/文件数量）并持有统一会话对象引用；条目状态与进度直接读会话对象的 `@Trace` 字段，与会话详情页同源，避免快照与实时对象的口径分叉
  - 文件数量文案（`SessionRowModel.fileCountText`）在会话**恰好一个文件且该文件为文本类**时承载本地化「文本」标签（三语言资源 `transfer_center_text_label`），
    多文件或单非文本文件保持文件数量文案；判定为纯函数、经 `MimeUtils.isTextFile` 唯一文本类判定，实时行取会话文件清单、历史行取历史逐文件清单，两处同口径（同一会话由实时行转为历史行时标签不变）
  - 列表为扁平 `List`，该缓存序列同处一个带 `virtualScroll` 的顶层 `Repeat` 的直接子级 `ListItem` 序列（不使用 `ListItemGroup` 嵌套分组），配合 `cachedCount` 预加载，长任务历史下不因全量创建节点而卡顿
  - 行 UI 直接在列表行迭代器内内联、由本行数据在本行作用域内逐字段构建（不使用带对象参数的组件内构建方法）；迭代器内为单一构造路径，
    空态由无参构建方法产出、条目行在同一构造点内联产出，避免与虚拟滚动的节点复用叠加时把同一份构建结果串用到多行
  - 行序列内容变化时输出转储诊断，与本次构建的行序列同源：**常态仅一行摘要**（行数/被剔除条数/首尾条目标识，体积不随记录数增长）；
    命中异常信号（条目被剔除、存在重复标识、行数相比上次减少）时改输出完整序列（行数与每行的索引/会话标识/时间文案/阶段/来源），保留排障证据；
    **渲染正确性以「转储 + 真机复核」为验证边界**——行渲染效果无法由纯逻辑用例拦截，判定方法为：转储各行互不相同而界面仍出现多行内容相同 ⇒ 渲染侧错位；转储本身即相同 ⇒ 问题回到数据侧
  - 卡片感由行内 padding/背景/圆角/描边表达，列表底部留出页签安全距离
- 新会话感知与前台提示：`MainTabViewModel` 经 `start()`/`stop()` 订阅同一变更总线（与任务列表同源同时机刷新任务入口数量与待确认计数），刷新时比对注册表中的待确认会话，
  出现新会话即以 `autoOpenSessionId` 一次性信号通知 `MainTabFloating`；后者在应用前台任意页面（含子页面）之上弹出统一的新传输提示弹窗
  （`AlertDialogV2` 经 `openCustomDialog` 打开，「查看」推入该会话详情、「稍后」/遮罩/返回键仅关闭），单槽位守卫避免叠加、按会话标识去重不重复提示；
  应用后台时不弹、回前台（`onPageShow`）补弹一次
- 通知深链：通知点击意图经 Want 参数 `handysend.navigate=transferCenter` 传递，`EntryAbility`（冷启动 `onCreate` / 热启动 `onNewWant`）解析后置位
  `AppService` 一次性深链信号（置位时触发变更总线）；`MainTabFloating` 在冷启动 `aboutToAppear` 与热启动订阅回调中消费，消费时先 `pathStack.clear()` 回到根、
  再切到任务页签，保证从通知进入后展示任务中心列表
- 任务入口数量：`MainTabViewModel.activeTransferCount` 取 `TransferSessionRegistry.getUnfinishedCount()`（非终态 = 进行中 + 待确认），
  窄屏底部页签与宽屏侧边栏共用同一字段，口径一致
- 会话动作口径：`model/transfer/TransferSession.resolveSessionActions(stage, capabilities, isText)` 为唯一事实源，
  任务列表行（`TransferCenterViewModel.rowActions`）与会话详情页（`SessionDetailViewModel.canConfirm`/`canDecline`/`canCancel`）共用；
  待确认文件会话为「确认/拒绝」、待确认文本消息会话为「关闭/复制」、任意方向进行中（含发送「等待对端接收/确认」）为「取消」
- 通用详情页：`SessionDetailViewModel` 读注册表会话 + 适配器展示描述符/能力声明 + 时间线，速度/ETA 由 `SpeedEstimator`
  派生（不可用时以占位符呈现）；`meta` 汇总完整传输信息（对端设备/时间/传输详情〔性能与结果、错误〕/本机标识），实时会话与历史条目统一取数
  - 会话被回收（`getSession` 返回 undefined）时保留最后一次快照，使详情页继续呈现终态结果而非空白页
  - 从未加载到会话（终态可见窗口已结束）时按持久化历史条目标识加载历史条目的完整信息、逐文件清单与时间线
- 发送页：`SendViewModel` 移除单/多目标模式与内联进度；点击设备即创建会话并发送，暂存内容默认保留（可选「发送成功后自动清空暂存」）
- 跨页面共享 URIs：`setPendingSharedUris`/`consumePendingSharedUris` inbox
- 持久化偏好：`PreferencesUtil` 按用途分三个**相互独立的存储文件**——应用设置（含设备身份、网络名单、收藏）`handysend_settings`、任务历史
  `handysend_session_history`、文件接收历史 `handysend_receive_history`（历史为高频写且体积随条目增长，与设置的低频小写入隔离）；全部设置项默认值集中定义于
  `model/SettingsDefaults.ets`（唯一事实来源，Repository 初始值/回退值、ViewModel 初始值与「恢复默认」、视图层非默认值判断均引用该常量）

## 10. 权限

| 权限 | 说明 |
|------|------|
| `ohos.permission.INTERNET` | 网络访问 |
| `ohos.permission.GET_NETWORK_INFO` | 获取网络信息 |
| `ohos.permission.GET_WIFI_INFO` | WiFi P2P 状态查询与连接（MTA 收发：建组/查组/p2pConnect 入组/本机 MAC/网络快照） |
| `ohos.permission.ACCESS_BLUETOOTH` | BLE 广播/扫描/GATT Server/GATT Client（MTA 主流程收发） |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | dataTransfer 长时任务（后台传输服务，见 §4.7） |

`module.json5` 声明 `dataTransfer` backgroundModes。

除上表 `requestPermissions` 声明的权限外，应用还使用通知授权（Notification Kit）：首次启动弹窗申请，授权状态经 `PermissionService`（§4.10）查询。后台传输的实况进度通知（§4.7）
与后台待确认请求提示通知（§4.8）依赖该授权——拒绝后通知仍可发布失败但后台传输不受影响，仅在通知栏不可见。通知授权与蓝牙权限的状态展示与重新申请入口位于设置页「通用」分组。

注册的 skill：主屏启动 (`ohos.want.action.home`) + 系统分享接收 (`ohos.want.action.sendData/sendMultipleData`)

## 11. 功能特性

- **传输**：文件传输、图片传输、剪贴板共享、文本发送、传输取消、HTTPS 加密传输、校验和（SHA-256）、传输保真（局域网与互传联盟两条链路均采集并在接收端还原源文件修改时间）
  、后台续传（后台存在活跃传输时申请或保持 dataTransfer 长时任务并以实况通知展示聚合进度，覆盖 LocalSend 收发、MTA 收发与 Web 下载，删通知即取消全部传输，见 §4.7）
- **发现**：UDP 组播 + HTTP 子网扫描设备发现、收藏设备
- **网页**：网页分享（二维码 + Web Send 浏览器下载，网页鸿蒙高保真风格 + 手动文本内联预览与复制）、Web Upload（进入网页接收页自动启用浏览器上传，
  页内逐条接受/拒绝浏览器上传请求，退出前存在未终结入站会话时先确认，上传文件/发送文本）、PIN 保护（Web Share 复用 receivePin）
- **接收**：自动确认请求（off/paired/on，Web Share 下载遵循独立的「自动确认下载请求」开关）、自动完成（传输完成后自动退出传输页）、相册保存（SaveButton 安全控件 +
  MediaAssetChangeRequest，无需 WRITE_IMAGEVIDEO 权限）、接收历史（含 savedToGallery 标记）、指纹验证（Material Icons 图标体系 + SHA-256 哈希对齐 LocalSend v1.18）
- **互传联盟（MTA）**：基础收发（发送页按设备来源标签发现并单目标发送互传联盟设备，含原生文本；应用前台按「互传联盟接收」开关自动接收互传联盟设备传输，落盘并按真实类型写入接收历史）
- **系统集成**：深色模式、外部分享、文件中转站拖入（跨应用统一拖拽 UDMF，文件/图片/文本/链接）、PC 关闭二次确认（2in1 有传输点 X 弹出继续/退出确认，无传输直接退出，见 §4.1）

统一会话详情页向对端会话展示（接收显示发送方/来自、发送显示接收方/发送到），列出文件清单与逐文件独立进度条及状态（等待/传输中/已完成）；发送页设备条目只承担发现与选择、
不内联展示进度（进度与状态只在任务与详情页呈现）；接收端因 LocalSend v2 协议单活动上传会话限制，向并发发送方呈现"对方忙，请稍后重试"的可操作反馈。

## 12. 注意事项

1. **浮动 Tab 栏**：使用 HdsTabs + barFloatingStyle，要求 API >= 23
2. **文件导出依赖用户交互**：DocumentViewPicker 选择保存位置
3. **ohrs 路径限制**：Windows 不支持含空格路径，需符号链接
4. **MaterialIcons 字体**：Flutter SDK 的 MaterialIcons-Regular.otf 注册为自定义字体，用于指纹图标渲染
5. **沉浸式标题栏**：标题栏配置必须经 `common/ImmersiveTitleBar.ets` 工厂产出，页面不得内联模糊/层叠/滚动参数，也不得设置标题栏不透明背景色（会覆盖滚动模糊）；滚动模糊要求逐页签绑定当前真实滚动控制器
6. **安全区扩展逐层设置**：`expandSafeArea` 只作用于当前组件，滚动容器内的延伸须从内容根节点到滚动容器逐层配置，否则滚动后失效
