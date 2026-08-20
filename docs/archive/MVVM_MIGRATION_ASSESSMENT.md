# MVVM 迁移正向收益评估（已归档）

> **归档说明**：本文档为 MVVM 迁移实施前的评估记录（2026-08-18），迁移已于同日完成。
> 2026-08-19 完成 V2 状态管理迁移：@Component→@ComponentV2, @State→@Local, @Observed→@ObservedV2+@Trace, @Prop/@ObjectLink→@Param, ForEach→Repeat, @CustomDialog→@Builder+openCustomDialog, animateTo 适配。
> 文档中的现状描述、反模式命中、整改顺序、工作量预估均已过时，仅供追溯决策过程。
> 当前架构与状态管理机制请参阅 `../ARCHITECTURE.md`（第 4.2/8/9 节）；迁移完成快照见本文第 5.3 节。

> 评估时间：2026-08-18
> 评估范围：HandySend entry 模块全部 `.ets` 源码
> 评估依据：hmos-arkui-mvvm-pattern skill · 静态源码扫描
> 命中场景：MVVM-01（V1 版本下 MVVM 架构开发）
> 迁移状态：**已完成**（2026-08-18 MVVM 迁移，2026-08-19 V2 状态管理迁移）

## 1. 现状判断

### 1.1 状态管理版本

项目使用 V1 状态管理：`@Component` / `@State` / `@Prop` / `@Link` / `@StorageLink` / `@Watch`。
未启用 V2（`@ComponentV2` / `@ObservedV2` / `@Local` / `@Param` / `@Trace` 等均无匹配）。

整改时维持 V1，不升级到 V2，避免版本混用。

### 1.2 目录结构现状

`viewmodel/` 和 `views/` 目录已经创建但为空，说明已规划迁移方向但尚未启动。

### 1.3 体量与耦合证据

| 文件                               | 行数   | AppStorage 引用 | 说明                                                                                                                                                                    |
|----------------------------------|------|---------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `service/AppService.ets`         | 3041 | 79            | 75 个 export function、85 处 native 调用，集服务器/传输/发现/校验/收藏/历史/Web/PIN 于一身                                                                                                   |
| `service/DialogService.ets`      | 759  | -             | UI 调度器（11 个 static show 方法 + 11 个 Params 类 + 10 个 @Builder 渲染函数）。业务逻辑仅 13 行（showInputDialog 的 Resource→string 解析）。真正反模式不在 DialogService 自身，而在 4 个调用方 View 直接调 Service |
| `service/NativeBridge.ets`       | 674  | -             | Rust HAR 桥接，真正的数据边界（保持不变）                                                                                                                                             |
| `pages/TransferPage.ets`         | 1299 | 3             | 22 个 @State，private 字段持有业务数据（fileUris/sessionId/targetPort）                                                                                                           |
| `components/SettingsContent.ets` | 1275 | 25            | 直接 import 调用 11 个 AppService 函数                                                                                                                                       |
| `components/SendContent.ets`     | 1067 | 12            | 含传输业务逻辑                                                                                                                                                               |
| `pages/MainTabFloating.ets`      | 657  | 10            | 含跨页状态                                                                                                                                                                 |
| `components/ReceiveContent.ets`  | 570  | 11            | 同 SendContent 对偶                                                                                                                                                      |

View 层 AppStorage 引用合计约 60 处，Service 层 79 处，共约 140 处。

## 2. 反模式命中

| 反模式                      | 证据                                                                                                    | MVVM 期望                          |
|--------------------------|-------------------------------------------------------------------------------------------------------|----------------------------------|
| View 直接调 Service 函数      | TransferPage import `subscribe/sendToDevice/respondToRequest/markSendCompleted` 等 10+ 个 AppService 函数 | View 只依赖 ViewModel               |
| View 持有业务字段              | TransferPage private `fileUris` / `targetPort` / `sessionId` / `acceptedFileIds`                      | 业务数据属于 Model                     |
| AppStorage 当全局 ViewModel | 79 + ~60 处双向读写                                                                                        | ViewModel 直接持有状态，AppStorage 减为 0 |
| 上帝对象                     | AppService 3041 行跨 8 个业务域                                                                             | 按业务域拆分为 4-6 个 Repository         |
| Page/Component 巨大        | TransferPage 1299、SettingsContent 1275、SendContent 1067                                               | Page 只做组装，~200-300 行             |
| 状态分散                     | 同一份数据同时存在 @State + @StorageLink + private 三处                                                          | 单一数据源 (SSOT)                     |

## 3. 目标架构

```
Page (组装)        →  ViewModel (@ObservedV2 + @Trace)  →  Repository (无 UI 状态)
  ↓ @Param                ↑ 命令/事件                       ↓ 调用
  View                                            NativeBridge / PreferencesUtil
                                                            (保持不变)
```

- 单向数据流：数据向下 Model → ViewModel → View，事件向上 View → ViewModel → Model
- 单一数据源：ViewModel 是 UI 状态唯一来源
- View 禁止直接访问 Model：通过 ViewModel 间接访问

### 3.1 Repository 拆分预案

从 AppService 3041 行按业务域拆出：

| Repository            | 承接的 AppService 职责                   |
|-----------------------|-------------------------------------|
| `ServerRepository`    | 服务器生命周期、端口、启动/停止/重启                 |
| `TransferRepository`  | send/respond/cancel、进度轮询、session 管理 |
| `DiscoveryRepository` | 设备发现、扫描、注册、announce                 |
| `FavoritesRepository` | 收藏设备、别名同步                           |
| `HistoryRepository`   | 接收历史增删查                             |
| `WebShareRepository`  | 分享链接、Web 上传下载                       |
| `ChecksumRepository`  | 文件 hash、校验                          |

## 4. 正向收益

| 维度      | 当前                | 迁移后       | 收益说明                                       |
|---------|-------------------|-----------|--------------------------------------------|
| 可测试性    | 0 单测可写            | Repo 层可单测 | 业务逻辑脱离 UI，无 struct 依赖                      |
| 单文件瘦身   | AppService 3041 行 | ≤500 行    | 上帝对象按业务域拆为 4-6 个 Repo                      |
| 状态可追溯   | AppStorage ~140 处 | 0         | ViewModel 直接持有，单向数据流                       |
| Page 瘦身 | TransferPage 1299 | ~250      | Page 仅做组装，行数下降约 75%                        |
| 复用性     | 1 (绑定 struct)     | N         | TransferViewModel 可被 Page/卡片/Widget/后台任务复用 |
| 风险可控    | -                 | V1→V2 迁移完成 | 装饰器统一为 V2，NativeBridge 不变作稳定锚点                      |

## 5. 风险与成本

### 5.1 主要风险点

| 风险点              | 影响                                                                                                                                  | 缓解                                                                                                                                         |
|------------------|-------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------|
| AppService 拆解    | 79 处 AppStorage 涉及全局状态契约                                                                                                            | 逐项建立 ViewModel 同名属性承接，保留 AppStorage 作为 VM 内部持久化层过渡                                                                                         |
| DialogService 拆解 | 调度器职责单一（业务逻辑仅 13 行 Resource→string 解析），但 4 个调用方（EntryAbility/ReceiveOptionsPage/SendContent/SettingsContent）的回调式 API 需转为 VM 状态式 API | 真正难点在调用方迁移：VM 暴露 dialogState，Page 用 @Watch 监听后调 DialogService；DialogService 本身保留作 UI 工具层；ComponentContent 生命周期仍卡在 View 层（受 UIContext 依赖约束） |
| 跨页状态             | MainTabFloating 等通过 AppStorage 共享状态                                                                                                 | 提升到最近公共祖先或 VM 持有，按"状态提升"原则判定归属                                                                                                             |
| V1 嵌套观测          | 列表项 @Observed + @ObjectLink 易踩坑                                                                                                     | 参考 references/v1-nested-observation.md 处理                                                                                                  |

### 5.2 整改顺序（按风险由低到高，已全部完成）

```
1.  LanguagePage (122)     ✓ 试点（MVVM skill refactor-func-workflow 验证）
2.  HttpLogsPage (126)     ✓
3.  ShareLinkPage (167)    ✓
4.  VerifyPage (184)       ✓
5.  TroubleshootPage (196) — 跳过（纯静态页，无状态无逻辑）
6.  DeviceDetailsPage (198)  ✓
7.  ReceiveHistoryPage (201) ✓
8.  DebugPage (226)        ✓
9.  ReceiveOptionsPage (345) ✓
10. Index (436)            — 已删除（孤儿页，无任何引用）
11. MainTabFloating (657)  ✓
12. SettingsContent (1275) ✓
13. SendContent (1067)     ✓
14. ReceiveContent (570)   ✓
15. TransferPage (1299)    ✓
```

每改完一页立即验证：功能不变 + 数据流合规 + 装饰器配套 + 无冗余状态。

### 5.3 迁移完成快照（2026-08-18）

**AppStorage 彻底替换（~140 处 → 0）**：
- View 层 47 个 `@StorageLink` 全部迁移为 VM 属性（@ObservedV2 + @Trace 驱动精准属性级刷新）
- VM 层 ~30 处 AppStorage 读写改为 Repository getter + subscribe 回调
- AppService 83 处 AppStorage 移除：设置镜像改模块变量（SSOT 不变），运行时事件改 `peek/consume` 内存队列，死广播（webDownloadRequest/activeProgressCount/currentColorMode/session 前缀 key）删除
- 跨页面共享 URIs（sharedFileUris/pendingSharedUris）改 `setPendingSharedUris/consumePendingSharedUris` inbox
- FavoritesService/ReceiveHistoryService/EntryAbility/PreferencesUtil 同步清理
- 关键语义保持：MainTab 只消费 auto-accepted 会话事件、TransferPage 只消费自身 session 事件（peek + 条件 consume），等价于旧 @Watch 与轮询的竞争

**AppService 拆 Repo（3041 → ~230 行薄壳）**：
- `repository/AppCore.ets`：共享运行时（appContext/事件总线/日志/网卡/指纹）
- `repository/SettingsRepository.ets`：设置 + serverNeedsRestart
- `repository/DeviceRepository.ets`：设备身份
- `repository/ServerRepository.ets`：服务器生命周期
- `repository/DiscoveryRepository.ets`：设备发现/手动连接
- `repository/SendRepository.ets`：发送链路（sendToDevice/Multi、文件 staging、sendSessions）+ activeProgress + 共享 URIs inbox
- `repository/ReceiveRepository.ets`：接收链路（pending requests、自动确认、接收会话/进度事件、finishReceiveSession）+ 事件队列 + 请求轮询
- `repository/WebShareRepository.ets`：分享链接/Web 事件
- `repository/ChecksumRepository.ets`：校验和/下载/上传
- AppService 门面 re-export 保持全部对外签名不变（VM/View import 零改动）；依赖方向无循环（跨域共享状态集中在 AppCore/SettingsRepository getter；Receive→Send 单向依赖）

**验证**：全仓 0 处 AppStorage/@StorageLink/@StorageProp；整改文件 lint 0 errors、0 新增 warning；`hvigorw assembleApp` BUILD SUCCESSFUL。

## 6. 结论

迁移到 MVVM 的正向收益显著且可量化：可测试性从 0 到可测、单文件最大行数下降约 80%、状态契约从分散收敛到 SSOT。

风险通过"维持 V1 + NativeBridge 不变 + 逐页迁移"三重约束可控。

建议按整改顺序启动，先做 LanguagePage 作为试点，验证工作流后再批量推进。
