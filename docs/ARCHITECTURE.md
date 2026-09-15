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
| 协议 | LocalSend v2 (HTTP/HTTPS + mDNS/UDP) |
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
│   │       │   ├── DialogService.ets
│   │       │   ├── GallerySaveService.ets
│   │       │   └── repository/      # 按业务域拆分的 Repository（详见 architecture/repositories.md）
│   │       ├── viewmodel/           # @ObservedV2 视图模型
│   │       ├── model/               # 数据类型（详见 architecture/types.md）
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

### 4.2 AppService ★ 核心业务门面

`entry/src/main/ets/service/AppService.ets`

AppService 是业务层的门面（facade）：初始化编排、Rust 事件分发、服务器生命周期组合。VM/View 统一从门面导入，门面通过 re-export 暴露 Repository 函数。业务逻辑按领域拆分到 `service/repository/`，各 Repository 职责、依赖关系、事件机制详见 [architecture/repositories.md](architecture/repositories.md)。

其中 `service/repository/MtaRepository.ets` 为应用级 MTA 运行时：持有仅用于发现的 `MtaBleClient` 实例与 MTA 接收服务单例，提供发现扫描、接收服务启停、收发互斥、接收命令门面与对外身份刷新（昵称或「模拟品牌」变更时重广播），变化经 `AppCore.notifyChange` 通知 UI。门面再导出其全部对外函数供发送页、设置页与应用生命周期调用。

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

封装 hilog，提供双层输出（hilog 系统日志 + addLog 应用内日志），按业务域细分 domain，支持模块标签（label）与结构化上下文（LogContext）。仅依赖 `@kit.PerformanceAnalysisKit`（hilog）和 `entry/BuildProfile`（编译时常量），addLog 回调通过运行时注入。日志消息统一为 `[模块标签] [上下文] 内容`：模块标签由 `LoggerInstance` 集中前置，上下文由 `LogFormat` 的 `composeLogMessage` 拼接，调用点只保留正文；未传标签时退化为 `[上下文] 内容`。

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
| GENERAL | 0x0000 | AppService, EntryAbility, EntryBackupAbility, DialogService, ReceiveHistoryService, NativeBridge, HttpLogsViewModel |
| DISCOVERY | 0x0001 | DiscoveryRepository, DeviceRepository, MainTabViewModel |
| TRANSFER | 0x0002 | SendRepository, ReceiveRepository, TransferViewModel, TransferPage, SendViewModel, SendContent, WebShareRepository, ChecksumRepository, GallerySaveService, VideoThumbnailUtil |
| NETWORK | 0x0003 | AppCore, NetworkSettingsSection |
| SERVER | 0x0004 | ServerRepository |
| SETTINGS | 0x0005 | SettingsRepository, PreferencesUtil, FavoritesService, SettingsViewModel |
| MTA | 0x0006 | service/mta/*、MtaRepository、Mta*ViewModel |

**消息格式**：`[模块] 内容`；带上下文为 `[模块] [sid=.. dir=..] 内容`；Rust 来源为 `[模块] Rust: 内容`。模块标签集中前置，保证 `grep '\[模块\]'` 无歧义过滤；正文数据方括号（如 `[wlan0]`）保留不影响过滤。日志消息不得含换行符。

**规范约束**：全项目仅 Logger.ets 可直接 import hilog，其他文件必须通过 `getLogger()` 使用日志功能；禁止 `console.*` 输出。模块标签、TAG、域与级别规则的完整清单见 `docs/DEBUG_LOG_INVENTORY.md`。

**应用内日志缓冲与导出**：内存日志源位于 `AppCore.ets`（`logs: Array<LogEntry>`，上限 2000 条），变更通知经 `scheduleLogNotify()` 200ms 节流合并；导出通过 `DocumentViewPicker` 落盘，VM 层编排文本拼接，Page 层仅调命令 + 按结果弹 Toast（严格 MVVM：VM 不碰 UIContext/fs/picker）。

### 4.6 GallerySaveService — 相册保存服务

`entry/src/main/ets/service/GallerySaveService.ets`

使用 `photoAccessHelper.MediaAssetChangeRequest`（API 12+）将媒体文件保存到系统相册。通过 SaveButton 安全控件获取临时授权，无需申请 `ohos.permission.WRITE_IMAGEVIDEO` 受限权限。

**相册保存流程**：局域网接收完成 → `ReceiveRepository.finishReceiveSession` 提取媒体文件 → `pendingRecvMediaFiles` 事件 → `TransferViewModel` 消费并弹出 `SaveToGalleryDialog`；MTA 接收完成 → `MtaReceiveService` 按真实文件类型收集图片/视频 → `ReceiverState.pendingMediaFiles` → `MtaTransferViewModel` 消费并弹出同一 `SaveToGalleryDialog`。两条路径均在用户点击 SaveButton 授权后经 `GallerySaveService.saveMediaToGallery` 从 Download 最终位置读取媒体文件保存到相册，保存结果经 `ReceiveHistoryService.updateGallerySavedStatus` 回写接收历史（fd-direct 下无沙箱副本，文件即交付物、保留于 Download）。

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
│   │   ├── zip_stream.rs        # 按文件清单库化流式写出 ZIP（ZipWriter::new_stream 无 Seek；条目压缩方法恒为 Deflated——无 Seek 写出必然产生数据描述符，而对端解析器只接受压缩方法条目携带描述符；所有条目统一使用同一压缩档位，不按文件类型区分；ZIP64 由库在条目超 32 位上限时自动启用；CRC 由库写出时计算；数据源为 ArkTS 直传 fd，文本条目回退沙箱路径；逐条目写源文件修改时间）
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

- **Local Test**：本地单元测试，运行于预览引擎，覆盖纯逻辑函数（不依赖系统 API / native / UIContext）。仅限 Windows / macOS（需预览器）；Linux 上预览器不可用，运行会卡死/长时间无响应，禁止在 Linux 尝试，ArkTS 侧改用 `arkts_check` + 构建验证
- **Instrument Test**：设备端测试，运行于真机/模拟器，覆盖 .so 调用、Repository 逻辑和事件解析

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

Rust 三层测试已接入 GitCode AtomGit Action 自动化流水线（`.gitcode/workflows/rust-test.yml`），push/PR 时自动执行 NAPI 封装完整性校验、格式检查、Clippy、单元测试、集成测试和上游测试。ArkTS 侧和设备测试暂未接入（需自托管 Runner）。详见 `docs/BUILD.md` §8。

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
| `MainTabFloating` | 主页（三个 Tab：Send/Receive/Settings）+ Navigation 根容器 |
| `TransferPage` | 传输进度（send/receive/clipboard/text 模式） |
| `ShareLinkPage` | 分享链接 + 二维码 + 下载/上传请求确认 |
| `DeviceDetailsPage` | 设备详情 |
| `ReceiveHistoryPage` | 接收历史 |
| `VerifyPage` / `TroubleshootPage` | 验证/故障排除 |
| `DebugPage` / `HttpLogsPage` | 调试页面（服务信息/证书重置、诊断日志浏览与导出） |
| `MtaTransferPage` | MTA 传输（主流程，send/receive 两种模式：复用发送页暂存内容单向发送，或确认接收互传联盟设备传输，展示会话级进度与结果） |

### 8.2 主页面结构

```
MainTabFloating
├── SendContent (文件/图片/剪贴板/文本 + 附近设备列表 + 收藏清单)
├── ReceiveContent (本机信息 + 网络接口)
└── SettingsContent (组装 views/settings/ 各设置分组)
```

发送页设备展示按分流规则保证每台设备任意时刻恰好出现一次：`SendViewModel.getFavoriteDevicesForDisplay()` 以持久化收藏记录为基础数据源，仅输出「不在发现快照中」的离线收藏设备——判定只按 fingerprint 匹配、不比较 IP（容忍 DHCP 重新分配）；指纹命中发现快照的在线收藏由附近设备列表承载展示。离线收藏以收藏记录字段兜底合并为 `DiscoveredDevice` 形状的展示对象（自定义别名不可被广播别名覆盖；IP/端口/型号/类型/版本按「实时快照 > 收藏记录持久化字段 > 缺省」的回退链取值），不随附近列表的离线移除而消失。展示数组为空时，整个收藏区块连同标题一起不渲染；收藏区块仅在局域网标签下渲染。两处列表的 `Repeat` 键值由指纹与全部影响渲染的字段拼接而成，保证任一字段变化都会触发对应条目重建刷新。

MTA（互传联盟）主流程接入复用上述统一列表：`MtaRepository` 在发送页可见期间保持 BLE 发现扫描（切走 Tab、推入子页面或应用退后台即停止；均衡功耗扫描模式），扫描期间周期性剔除超时未再广播的设备（30 秒未见即离线），本机蓝牙关闭时立即停止扫描、清空设备列表并复位接收服务，蓝牙重新开启后按需自动恢复扫描与接收服务（跳过失败冷却；经蓝牙状态跃迁判定，忽略中间态），把发现的互传联盟设备经 `DiscoveredDevice` 统一形状（`protocol = 'mta'`、BLE 标识作 fingerprint）合并进统一设备集，条目以品牌徽标替代 IP 短码且不参与 LocalSend 收藏；`discoveredDevices` 仍仅含 LocalSend，未污染既有发现/收藏逻辑。发送页「附近设备」区域按设备类型（LocalSend / 互传联盟）用 `TabSegmentButtonV2` 切换列表与数量徽标：`SendViewModel` 经 `model/SendDeviceGrouping.ets` 纯函数把统一设备集拆为局域网/互传两组展示数据源与计数，局域网标签渲染收藏区块、副标题沿用局域网网络指引，互传联盟标签不渲染收藏区块、副标题提示确保对端在附近并已开启分享；标签仅在本次发送页会话曾发现互传设备时出现（`hasSeenMtaDevice`，一旦置真会话内保持），互传设备数归零时展示互传专属空态，空态文案引导开启本机蓝牙与 WLAN（无需连接网络）并确认对端在附近且已开启分享；发送页连接警告横幅（与网络警告同款式）按优先级只显示一条：WLAN 关闭且局域网不可用时与既有「未连接局域网」提示合并（互传发现依赖蓝牙、传输依赖 WLAN，有线局域网不可替代，此时两者是同一件事）；WLAN 关闭但局域网可用时（如已接网线）只提示互传需要 WLAN（设备可被发现但无法传输）；蓝牙与 WLAN 均未开启时显示合并提示（互传口径）；仅蓝牙关闭时提示开启蓝牙；接收页按同一优先级提示，但互传相关提示以「互传联盟接收」开关为前提（关闭时接收端不广播）；三方应用无法主动开启 WLAN（`wifiManager.enableWifi` 仅系统应用可用），故仅作提示引导。标题行右侧入口按标签分流：接收者模式入口（一个接收者 / 多个接收者）仅局域网标签渲染，与设备类型无关的发送方式入口（`sys.symbol.share`，用网页分享 / 指定IP分享）在两个标签下均渲染。点击 MTA 设备经 `SendContent` 按 `protocol` 分流到 `MtaTransferPage`（send 模式），复用发送页暂存文件完成单目标发送；已有 MTA 发送进行中时提示设备忙并忽略。应用进入前台时按「互传联盟接收」设置（默认开启）自动启动 MTA 接收服务（BLE 广播 + GATT Server），进入后台停止；收到互传联盟设备传输请求时经事件总线导航到 `MtaTransferPage`（receive 模式）确认，接受后下载解压落盘到既有接收目录并写入接收历史。MTA 发送与接收经 `MtaRepository` 互斥：发起发送前暂停接收服务，发送结束（完成/失败/取消）后按开关恢复。MTA 接收历史按文件扩展名解析真实 MIME 写入（不再统一记通用二进制类型），该真实类型同时作为「保存到相册」媒体筛选依据；接收完成后「保存到相册」开启且存在图片/视频时收集媒体并进入与局域网一致的保存流程。文件信息保真覆盖两条链路：局域网发送在暂存前采集源文件修改时间随发送文件 JSON 传入（Rust 桥接填充上传 DTO 的 `metadata.modified`，接收端由核心落盘后应用）；MTA 发送端直读源文件 fd（每文件一个读取入口，文本条目仍写沙箱临时文件按路径读取）并把源修改时间写入 ZIP 条目时间，接收端解压落盘后按条目时间还原、无效时保持落盘时刻（MTA 协议载荷无时间字段，ZIP 条目时间是唯一可承载位）。

MTA 对外身份中的品牌取自设置项「模拟品牌」（`model/mta/MtaBrandRegistry.ets` 为品牌标识 ↔ 名称的单一事实源，默认第三方）：可模拟清单收敛为小米 / OPPO / vivo / 荣耀 / 一加 / 真我 / 三星 / 魅族 8 个主流品牌 + 默认「第三方」，而用于扫描识别对方设备的品牌标识映射保持完整、不随该清单缩减。接收端 BLE 主广播 serviceData UUID 的品牌字节按所选品牌生成（默认第三方时等于既有常量），发送端 Rust 服务器配置与 `sendRequest` 载荷携带可选的 `senderBrandId`/`senderBrand`（默认第三方时不序列化、对老对端零影响；`senderBrand` 始终为不随语言变化的规范英文名）。设置页显示名随应用语言本地化（`brand_name_<key>` 字符串资源，`base` 英文、`zh_CN` 简体、`zh_TW` 繁体，中文下有通用中文名的品牌显示中文名），不影响协议字段与收发界面徽标。品牌变更经 `MtaRepository.refreshMtaReceiveIdentity()` 触发重广播，接收服务未运行时为空操作。品牌图标为 `entry/src/main/resources/base/media/ic_brand_<key>.png`（`xiaomi/oppo/vivo/honor/oneplus/realme/samsung/meizu/default`），复制自 EasyShare 项目（MIT 许可，Copyright 2025 Midori Kochiya）。

### 8.3 浮动 Tab 栏

使用 `HdsTabs` + `barOverlap(true)` + `barFloatingStyle` + `bindScroller` + `applyHideAnimation`/`applyShowAnimation` 实现浮动 Tab 栏（系统内置动画），要求 API >= 23。

滚动显示/隐藏逻辑：
- 子组件通过 `onScrollDelta(deltaY, absY)` 回调报告滚动增量和绝对偏移
- `absY ≤ 20` 时永远不隐藏（防止顶部回弹抖动）
- Tab 切换时自动恢复显示
- `-999` 哨兵值表示内容到达顶部，强制显示

### 8.4 设置页分组与半屏弹窗

设置页由 `views/settings/` 下的分组组件组装（每个分组一个卡片）：

| 分组组件 | 内容 |
|----------|------|
| `NetworkSettingsSection` | 服务器状态/昵称/设备类型/设备型号/高级设置 + 网络警告横幅 + 半屏弹窗 |
| `AppearanceSettingsSection` | 主题/动画/滚动隐藏页签 + 语言半屏弹窗 |
| `SendSettingsSection` | 自动确认下载请求/创建校验和 |
| `ReceiveSettingsSection` | 接收相关设置（自动确认请求/PIN/自动完成/保存到相册/保存到历史） |
| `MtaSettingsSection` | 互传联盟（MTA）接收开关 + 模拟品牌行（品牌图标 + 本地化显示名）与 `bindSheet` 品牌选择（点选即生效并关闭） |
| `MoreSettingsSection` | 反馈/关于半屏弹窗 + 诊断日志 + 恢复默认 |

分组在设置页按「接收设置 → 发送设置 → 互传联盟（MTA）→ 外观设置 → 网络与设备身份 → 更多」的顺序装配。

各半屏弹窗独立持有 `@Local isShowXxxSheet` 开关，通过 `bindSheet` 呈现。

### 8.5 响应式设计

断点体系基于系统窗口宽度断点（`@Env(SystemProperties.BREAK_POINT)`，类型 `uiObserver.WindowSizeLayoutBreakpointInfo`），覆盖手机/平板/折叠屏/PC（2in1）各形态。宽度断点区间：sm `[320,600)`、md `[600,840)`、lg `[840,1440)`、xl `[1440,+∞)`。

- **断点工具**（`common/Breakpoints.ets`）：`WidthBreakpointType<T>` 四档取值工具（xs 归入 sm 档）、`getMaxContentWidth`（md→800、lg→960、xl→1120，sm/xs→0 全宽）、`isNarrowWidth`（xs/sm）、`isWideWidth`（lg/xl）、`getSheetWidth`（sm/md→480、lg/xl→560）、`getPageMargin`（sm→16、md→24、lg→24、xl→32）、`isTabletPortrait`（tablet + HEIGHT_LG）
- **Tab 栏形态**：md 及以下 / 平板竖屏（tablet + HEIGHT_LG）/ 矮窗（height<600vp mediaquery 兜底）→ 底部水平栏；lg/xl 宽屏且非平板竖屏 → 侧边垂直栏 (barWidth=96)
- **内容最大宽度**：md 800 / lg 960 / xl 1120，sm 不限制
- **设备列表**：`SendContent` 使用 GridRow/GridCol 栅格按断点切换列数（sm/md 单列、lg 2 列、xl 3 列）
- **弹窗宽度**：统一 `constraintSize({ maxWidth: 480 })`
- **PC（2in1）窗口**：`module.json5` orientation 配置 `auto_rotation_restricted`；运行时按 `deviceInfo.deviceType === '2in1'` 调用 `window.setWindowLimits({ minWidth: 480, minHeight: 640 })`
- **深色模式**：完整 `dark/` 资源覆盖

## 9. 状态管理

采用 V2 状态管理（@ComponentV2 体系）：

- 页面级状态：`@Local`（持有 `@ObservedV2` ViewModel，`@Trace` 属性变化驱动精准 UI 刷新）
- 子组件参数：`@Param`（引用语义）
- 子组件回调：`@Event`
- 列表渲染：`Repeat` + `.each()/.key()`
- 弹窗：DialogV2（ConfirmDialogV2/AlertDialogV2/TipsDialogV2/CustomContentDialogV2）经 `openCustomDialog({ builder })` 打开；C 类自定义弹窗保留 DialogService（`@Builder` + `openCustomDialog`）
- 业务/共享状态：ViewModel 属性（@ObservedV2 + @Trace）+ Repository 模块变量（SSOT）
- 跨组件通知：Repository 事件总线（`subscribe`/`unsubscribe`/`notifyChange`）+ FavoritesService 回调
- 一次性传输事件：`peek/consume` 内存队列（接收完成/取消/文本消息/媒体文件信息）
- 传输页进度：`TransferViewModel` 持有 `fileInfos`/`fileProgressList`/`sessionProgress`，由 `rebuildFileProgress()`/`rebuildSessionProgress()` 聚合；`SendViewModel.sendSessionProgress` 以 IP 为键聚合每设备发送百分比
- 跨页面共享 URIs：`setPendingSharedUris`/`consumePendingSharedUris` inbox
- 持久化偏好：`PreferencesUtil`（存储名 `handysend_settings`）

## 10. 权限

| 权限 | 说明 |
|------|------|
| `ohos.permission.INTERNET` | 网络访问 |
| `ohos.permission.GET_NETWORK_INFO` | 获取网络信息 |
| `ohos.permission.GET_WIFI_INFO` | WiFi P2P 状态查询与连接（MTA 收发：建组/查组/p2pConnect 入组/本机 MAC/网络快照） |
| `ohos.permission.ACCESS_BLUETOOTH` | BLE 广播/扫描/GATT Server/GATT Client（MTA 主流程收发） |

注册的 skill：主屏启动 (`ohos.want.action.home`) + 系统分享接收 (`ohos.want.action.sendData/sendMultipleData`)

## 11. 功能特性

文件传输、图片传输、剪贴板共享、文本发送、网页分享（二维码 + Web Send 浏览器下载，网页鸿蒙高保真风格 + 手动文本内联预览与复制）、Web Upload（浏览器上传文件/发送文本）、UDP 组播 + HTTP 子网扫描设备发现、HTTPS 加密传输、收藏设备、自动确认请求（off/paired/on，Web Share 下载遵循独立的「自动确认下载请求」开关）、自动完成（传输完成后自动退出传输页）、相册保存（SaveButton 安全控件 + MediaAssetChangeRequest，无需 WRITE_IMAGEVIDEO 权限）、深色模式、外部分享、传输取消、PIN 保护（Web Share 复用 receivePin）、校验和（SHA-256）、接收历史（含 savedToGallery 标记）、指纹验证（Material Icons 图标体系 + SHA-256 哈希对齐 LocalSend v1.18）、互传联盟（MTA）基础收发（发送页按设备类型切换列表发现并单目标发送互传联盟设备，含原生文本；应用前台按「互传联盟接收」开关自动接收互传联盟设备传输，落盘并按真实类型写入接收历史、按设置保存媒体到相册）、传输保真（局域网与互传联盟两条链路均采集并在接收端还原源文件修改时间）。

传输页只向对端设备展示（接收显示发送方/来自、发送显示接收方/发送到），列出文件清单与逐文件独立进度条及状态（等待/传输中/已完成）；多目标发送时每台设备展示独立发送百分比；接收端因 LocalSend v2 协议单活动上传会话限制，向并发发送方呈现"对方忙，请稍后重试"的可操作反馈。

## 12. 注意事项

1. **浮动 Tab 栏**：使用 HdsTabs + barFloatingStyle，要求 API >= 23
2. **文件导出依赖用户交互**：DocumentViewPicker 选择保存位置
3. **ohrs 路径限制**：Windows 不支持含空格路径，需符号链接
4. **MaterialIcons 字体**：Flutter SDK 的 MaterialIcons-Regular.otf 注册为自定义字体，用于指纹图标渲染
