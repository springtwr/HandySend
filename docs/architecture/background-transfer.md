# 后台传输与通知

> `BackgroundTransferService`（dataTransfer 长时任务 + 实况进度通知）与 `PendingRequestNotifier`（后台待确认请求提示）的实现细节。
>
> 主文档 `docs/ARCHITECTURE.md` §4.7 / §4.8 保留概述；生命周期编排见主文档 §4.1。

## 1. BackgroundTransferService — 后台传输服务

`entry/src/main/ets/service/BackgroundTransferService.ets`

后台传输保护（手机/平板/PC 通用）：应用处于后台且存在活跃传输（LocalSend 发送/接收、MTA 发送/接收、Web 分享下载）时申请 `dataTransfer` 长时任务（`backgroundTaskManager.startBackgroundRunning`，
`KEEP_BACKGROUND_RUNNING` 权限），并以实况通知（LIVE_VIEW SlotType + downloadTemplate，typeCode 8）展示聚合进度；全部会话终态后发布终态文案（成功/部分失败/失败三档）并延迟 10 秒停止任务实现通知停留。

服务为模块级单例，由 EntryAbility 生命周期驱动。

### 1.1 数据源

- 唯一来源为统一会话注册表——`TransferSessionRegistry.getOverallSnapshot()` 的协议无关聚合快照（活跃会话数/设备数/整体进度/成败汇总）
- 服务不再逐协议读取快照，也不再按方向硬编码取消分支
- 待确认会话（`awaitingConfirmation`）不计入活跃：活跃标志、会话数、设备数、进度与字节汇总均只覆盖「进行中」会话；`allFinished` 仍表示「全部会话均已终态」，仅有待确认时不视为全部完成

### 1.2 传输驱动启停

- 长时任务的申请/保持不再仅依赖 `onBackground` 时机：缓存 `UIAbilityContext`，changeBus 在后台检出进行中传输且任务空闲时主动申请（`ensureTransferTaskForBackground`，幂等）
- 终态停留期内新传输出现时取消终端停止定时器并复位终态标记，使任务继续有效

### 1.3 更新机制

- 订阅 AppCore changeBus，1s 节流发布（`throttleDelayMs` 纯函数决策 + 单 pending 定时器同帧合并）
- 代次计数器（startGeneration）防止停止后旧帧覆盖

### 1.4 终态正确性

- 终态发布前取消待发布节流帧；待发布帧在发布时刻重读最新聚合快照
- 终态发布后抑制一切进度帧（防过期帧回跳）
- 终态会话（含 MTA 发送）由注册表统一保留可见窗口（成功 3s / 失败与取消 5s），确保终态帧可算出 100% 而非 0%

### 1.5 前台引导与前台状态

- 前台收到变化且通知未授权时 `requestEnableNotification` 引导（进程级一次提示，2s 限频）
- 应用前台/后台由 `AppCore`（`setAppForeground`/`isAppForeground`，EntryAbility 生命周期驱动）统一提供

### 1.6 删除通知取消

- `continuousTaskCancel` 事件 USER_CANCEL(1) 时经统一取消入口下发：对注册表中全部非终态会话调用 `TransferSessionRegistry.cancel()`
- `cancel` 按适配器能力声明分发（`canCancel=false` 的协议为空操作，不改状态、不调用适配器），其余由各协议适配器执行具体取消动作

### 1.7 可测性

- 导出 `throttleDelayMs`/`resolveTerminalKind` 纯决策函数供 Instrument Test 单测（聚合断言迁移至 `BackgroundAggregateTest`，经注册表快照验证）

## 2. PendingRequestNotifier — 后台待确认请求提示

`entry/src/main/ets/service/PendingRequestNotifier.ets`

- 应用处于后台时到达「需用户手动确认」的接收/下载请求（LocalSend 接收、Web 分享下载、MTA 互传请求）时，发布一条可点击回到前台的系统通知（独立通知 id，与实况进度通知区分）
- 提示的发布/撤回按统一注册表的待确认会话计数驱动（`initPendingRequestNotifier` 订阅变更总线；无待确认会话或回到前台即撤回）
- 请求本身即注册表中的待确认会话，用户在任务确认/拒绝
