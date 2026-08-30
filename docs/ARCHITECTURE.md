# HandySend（便捷快传）架构文档

> 当项目结构、核心模块、API 接口等发生变更时，必须同步更新本文件及相关子文档。

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
│   │       ├── common/              # DesignTokens + Breakpoints + LanguageConstants + LogDomains
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

### 4.3 NativeBridge — NAPI 桥接

`entry/src/main/ets/service/NativeBridge.ets`

从 `localsend_ohrs` HAR 导入 Rust NAPI 函数，封装为 `native*` 函数并做类型转换。HAR 接口参数为 JSON 字符串，NativeBridge 负责 `JSON.stringify` + 类型映射。完整函数清单及 Rust NAPI 层结构详见 [architecture/native-bridge.md](architecture/native-bridge.md)。

### 4.4 DialogService — 弹窗服务

`entry/src/main/ets/service/DialogService.ets`

统一管理自定义弹窗，使用 `@Builder` + `openCustomDialog`（ComponentContent + wrapBuilder）模式。

- **A/B 类弹窗**（标准确认/提示/输入）使用 DialogV2 系统预置组件，在各调用点组件内打开
- **C 类弹窗**由 DialogService 承载：`showPinDialog`（autoCancel:false 禁止点击外部关闭，DialogV2 无等价能力）；操作列表、通用重命名等弹窗由各调用点组件自行实现

### 4.5 Logger — 统一日志模块

`entry/src/main/ets/utils/Logger.ets` + `entry/src/main/ets/common/LogDomains.ets`

封装 hilog，提供双层输出（hilog 系统日志 + addLog 应用内日志），按业务域细分 domain，支持结构化上下文（LogContext）。仅依赖 `@kit.PerformanceAnalysisKit`（hilog）和 `entry/BuildProfile`（编译时常量），addLog 回调通过运行时注入。

| 导出函数 | 说明 |
|----------|------|
| `getLogger(domain, tag)` | 创建 LoggerInstance（每个模块顶层调用一次，返回实例复用） |
| `registerAddLog(fn)` | 注入 addLog 回调（运行时注入，避免编译期循环依赖） |
| `initLogger()` | 根据编译模式初始化日志级别（Debug=DEBUG, Release=INFO） |
| `setDebugEnabled(on)` | 临时切换 Debug 开关（仅内存 + hilog 级别，不持久化，重启恢复） |

**初始化链路**：`AppService.initAppService()` → `registerAddLog(addLog)` → `initLogger()`

**业务域常量**（`LogDomains`）：

| 域 | 值 | 适用模块 |
|----|----|----------|
| GENERAL | 0x0000 | AppService, EntryAbility, EntryBackupAbility, DialogService, ReceiveHistoryService |
| DISCOVERY | 0x0001 | DiscoveryRepository, DeviceRepository, MainTabViewModel |
| TRANSFER | 0x0002 | SendRepository, ReceiveRepository, TransferViewModel, TransferPage, SendViewModel, SendContent, WebShareRepository, ChecksumRepository |
| NETWORK | 0x0003 | AppCore, NetworkSettingsSection, SettingsViewModel |
| SERVER | 0x0004 | ServerRepository |
| SETTINGS | 0x0005 | SettingsRepository, PreferencesUtil, FavoritesService |

**规范约束**：全项目仅 Logger.ets 可直接 import hilog，其他文件必须通过 `getLogger()` 使用日志功能。

**应用内日志缓冲与导出**：内存日志源位于 `AppCore.ets`（`logs: Array<LogEntry>`，上限 2000 条），变更通知经 `scheduleLogNotify()` 200ms 节流合并；导出通过 `DocumentViewPicker` 落盘，VM 层编排文本拼接，Page 层仅调命令 + 按结果弹 Toast（严格 MVVM：VM 不碰 UIContext/fs/picker）。

### 4.6 GallerySaveService — 相册保存服务

`entry/src/main/ets/service/GallerySaveService.ets`

使用 `photoAccessHelper.MediaAssetChangeRequest`（API 12+）将媒体文件保存到系统相册。通过 SaveButton 安全控件获取临时授权，无需申请 `ohos.permission.WRITE_IMAGEVIDEO` 受限权限。

**相册保存流程**：接收完成 → `ReceiveRepository.finishReceiveSession` 提取媒体文件 → `pendingRecvMediaFiles` 事件 → `TransferViewModel` 消费并弹出 `SaveToGalleryDialog` → 用户点击 SaveButton 授权 → `GallerySaveService.saveMediaToGallery` → 清理沙箱副本、更新历史记录。

## 5. Rust NAPI 层

`localsend_ohrs/rust/`

Rust NAPI 层结构、函数清单、事件系统、进度追踪、Web Share 架构详见 [architecture/native-bridge.md](architecture/native-bridge.md)。

## 6. 类型定义

应用层与 NAPI 层类型定义详见 [architecture/types.md](architecture/types.md)。

## 7. 测试体系

采用分层测试体系：

### 7.1 ArkTS 层

- **Local Test**：本地单元测试，运行于预览引擎，覆盖纯逻辑函数（不依赖系统 API / native / UIContext）
- **Instrument Test**：设备端测试，运行于真机/模拟器，覆盖 .so 调用、Repository 逻辑和事件解析

运行命令见 `docs/BUILD.md`，Instrument Test 编写规范见 `docs/testing/instrument-test-guide.md`。

### 7.2 Rust 核心层

Rust 核心层采用三层测试架构，由 `napi` feature flag 控制编译范围：

| 层级 | 位置 | 运行命令 | 说明 |
|------|------|----------|------|
| 上游核心测试 | `third_party/localsend/` | `cargo test --target x86_64-unknown-linux-gnu -p localsend --features crypto,discovery,http,multicast` | 验证协议实现正确性 |
| OHRS 集成测试 | `localsend_ohrs/tests/` | `cargo test --target x86_64-unknown-linux-gnu`（从 `tests/` 目录运行） | 验证桥接层与核心的集成（HTTP 服务器/客户端、HTTPS/mTLS、发现） |
| 桥接层单元测试 | `localsend_ohrs/rust/bridge/` | `cargo test --target x86_64-unknown-linux-gnu --no-default-features --lib` | 验证纯逻辑函数：类型转换（convert）、状态操作（bridge_core）、事件回调（callback） |

**Feature flag 机制**：

- `napi`（默认启用）：编译 NAPI 入口点和桥接层有状态逻辑，依赖 `napi-ohos`，仅能在 OHOS 交叉编译目标上编译
- 关闭 `napi`（`--no-default-features`）时编译 `convert`、`callback`、`state`、`bridge_core` 模块，可在 Linux native target 上运行 `cargo test`
- `napi_entry.rs` 通过 `include!()` 宏按条件引入 `lib.rs`，避免对 615 行 NAPI 代码逐行添加 `#[cfg]`

**关键点**：`--target x86_64-unknown-linux-gnu` 覆盖父目录 `.cargo/config.toml` 中的 OHOS 交叉编译目标；单元测试需额外加 `--no-default-features --lib` 避免链接 OHOS NDK。

可通过 hvigor 任务在 DevEco Studio 侧边工具面板执行，详见 `docs/BUILD.md`。

### 7.3 CI/CD

Rust 三层测试已接入 GitCode AtomGit Action 自动化流水线（`.gitcode/workflows/rust-test.yml`），push/PR 时自动执行格式检查、Clippy、单元测试、集成测试和上游测试。ArkTS 侧和设备测试暂未接入（需自托管 Runner）。详见 `docs/BUILD.md` §8。

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
| `DebugPage` / `HttpLogsPage` / `DiscoveryDebugPage` | 调试页面 |

### 8.2 主页面结构

```
MainTabFloating
├── SendContent (文件/图片/剪贴板/文本 + 附近设备列表 + 收藏清单)
├── ReceiveContent (本机信息 + 网络接口)
└── SettingsContent (组装 views/settings/ 各设置分组)
```

发送页设备展示按分流规则保证每台设备任意时刻恰好出现一次：`SendViewModel.getFavoriteDevicesForDisplay()` 以持久化收藏记录为基础数据源，仅输出「不在发现快照中」的离线收藏设备——判定只按 fingerprint 匹配、不比较 IP（容忍 DHCP 重新分配）；指纹命中发现快照的在线收藏由附近设备列表承载展示。离线收藏以收藏记录字段兜底合并为 `DiscoveredDevice` 形状的展示对象（自定义别名不可被广播别名覆盖；IP/端口/型号/类型/版本按「实时快照 > 收藏记录持久化字段 > 缺省」的回退链取值），不随附近列表的离线移除而消失。展示数组为空时，整个收藏区块连同标题一起不渲染。两处列表的 `Repeat` 键值由指纹与全部影响渲染的字段拼接而成，保证任一字段变化都会触发对应条目重建刷新。

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
| `ReceiveSettingsSection` | 接收相关设置 |
| `MoreSettingsSection` | 反馈/关于半屏弹窗 + 调试日志 + 恢复默认 |

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

注册的 skill：主屏启动 (`ohos.want.action.home`) + 系统分享接收 (`ohos.want.action.sendData/sendMultipleData`)

## 11. 功能特性

文件传输、图片传输、剪贴板共享、文本发送、网页分享（二维码 + Web Send 浏览器下载，网页鸿蒙高保真风格 + 手动文本内联预览与复制）、Web Upload（浏览器上传文件/发送文本）、UDP 组播 + HTTP 子网扫描设备发现、HTTPS 加密传输、收藏设备、自动确认请求（off/paired/on，Web Share 下载遵循独立的「自动确认下载请求」开关）、自动完成（传输完成后自动退出传输页）、相册保存（SaveButton 安全控件 + MediaAssetChangeRequest，无需 WRITE_IMAGEVIDEO 权限）、深色模式、外部分享、传输取消、PIN 保护（Web Share 复用 receivePin）、校验和（SHA-256）、接收历史（含 savedToGallery 标记）、指纹验证（Material Icons 图标体系 + SHA-256 哈希对齐 LocalSend v1.18）。

传输页只向对端设备展示（接收显示发送方/来自、发送显示接收方/发送到），列出文件清单与逐文件独立进度条及状态（等待/传输中/已完成）；多目标发送时每台设备展示独立发送百分比；接收端因 LocalSend v2 协议单活动上传会话限制，向并发发送方呈现"对方忙，请稍后重试"的可操作反馈。

## 12. 注意事项

1. **浮动 Tab 栏**：使用 HdsTabs + barFloatingStyle，要求 API >= 23
2. **文件导出依赖用户交互**：DocumentViewPicker 选择保存位置
3. **ohrs 路径限制**：Windows 不支持含空格路径，需符号链接
4. **MaterialIcons 字体**：Flutter SDK 的 MaterialIcons-Regular.otf 注册为自定义字体，用于指纹图标渲染
