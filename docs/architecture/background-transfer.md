# 后台传输与通知

> `BackgroundTransferService`（dataTransfer 长时任务 + 实况进度通知）与 `BackgroundAttentionNotifier`（后台关注通知层）的实现细节。
>
> 主文档 `docs/ARCHITECTURE.md` §4.7 / §4.8 保留概述；生命周期编排见主文档 §4.1。

## 1. BackgroundTransferService — 后台传输服务

`entry/src/main/ets/service/BackgroundTransferService.ets`

后台传输保护（手机/平板/PC 通用）：应用处于后台且存在活跃传输（LocalSend 发送/接收、MTA 发送/接收、Web 分享下载/上传）时申请 `dataTransfer` 长时任务（`backgroundTaskManager.startBackgroundRunning`，
`KEEP_BACKGROUND_RUNNING` 权限），并以实况通知（LIVE_VIEW SlotType + downloadTemplate，typeCode 8）展示聚合进度；全部会话终态后发布终态文案（成功/部分失败/失败三档）并延迟 10 秒停止任务实现通知停留。

服务为模块级单例，由 EntryAbility 生命周期驱动。

### 1.1 数据源

- 唯一来源为统一会话注册表——`TransferSessionRegistry.getOverallSnapshot()` 的协议无关聚合快照（活跃会话数/设备数/整体进度/成败汇总）
- 服务不再逐协议读取快照，也不再按方向硬编码取消分支
- 待确认会话（`awaitingConfirmation`）不计入活跃：活跃标志、会话数、设备数、进度与字节汇总均只覆盖「进行中」会话；`allFinished` 仍表示「全部会话均已终态」，仅有待确认时不视为全部完成

### 1.2 传输驱动启停

- 长时任务的申请/保持不再仅依赖 `onBackground` 时机：缓存 `UIAbilityContext`，changeBus 在后台检出进行中传输且任务空闲时主动申请（`ensureTransferTaskForBackground`，幂等）
- 传输任务与空闲保活任务分离，各自持有独立的 `dataTransfer` 长时任务、通知 Id 与任务 Id：
  - 传输任务：后台存在活跃会话时申请，通知显示「后台传输中 / 关闭通知会中断传输」，随真实进度更新；
  - 保活任务：设置「允许后台接收」开启且网页服务或 LocalSend 服务器运行时，进入后台即申请，
    通知显示「后台运行中 / 临时保活5分钟，到期后自动关闭」，固定 5 分钟，每 30 秒推进进度，
    到期先发布 100% 结束帧再立即停止任务（通知随任务消失，与传输任务一致，不触发系统完成提醒）；
    不因传输开始/结束重置或延长。
- 传输结束统一发布独立普通终态通知（成功/部分失败/失败三档，不自动撤销，回前台或点击后撤销）；
  普通通知发布完成后立即停止传输长时任务，避免「后台传输中」通知继续显示。
  普通终态通知与保活实况通知可并存。
- 系统可能因 `dataTransfer` 低速率提前取消保活任务（`detailedReason=4`）；保活任务被取消时只结束保活，
  不影响仍在进行的传输任务。
- 终态处理期间新传输出现时使在途停止失效并复位终态标记，使传输任务继续有效

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

## 2. BackgroundAttentionNotifier — 后台关注通知层

`entry/src/main/ets/service/BackgroundAttentionNotifier.ets`

- 应用处于后台时，把需要用户关注的事件收敛为**一条**系统通知（独立通知 id，与实况进度通知区分）；
  点击携带「任务中心」深链意图（见 §3）
- **只展示待确认请求**：LocalSend / MTA 接收、Web 上传；
  数量取统一注册表的待确认会话计数（`getPendingCount`），`%d` 为等待确认的请求数
- 网页访问/网页下载不进入该通知：访问只写诊断日志，并通过 `noteWebAccess` 续期网页服务的有界保活；
  下载批次由后台传输实况通知承载（与上传/其它传输共用的聚合通知）
- **发布/撤回驱动**：注册表变更订阅 + 退后台补发（前台期间已存在的待确认请求在 `onBackground` 补齐）；
  回到前台（`onForeground`）撤回；无待确认即撤回
- **去重**：按「类别 + 数量」签名判重，同一状态不重复 publish；
  撤回与在途发布之间用代际号兜底回收，避免通知滞留
- 请求本身仍是注册表中的待确认会话，用户回到前台后在任务页处理

## 3. 通知点击深链（回任务中心）

进度通知（§1）与后台关注通知（§2）的点击行为一致：拉起主 Ability 并置于前台，且携带「任务中心」深链意图。

- **意图载体**：`utils/WantAgentUtil.buildBackToFrontWantAgent(context, navigationTarget?)` 在 `Want.parameters` 写入
  `handysend.navigate`（值 `transferCenter`）；缺省不传目标时保持既有无参调用兼容
- **解析**：`EntryAbility.onCreate`（冷启动）/ `onNewWant`（热启动）解析 `want.parameters['handysend.navigate']`，命中即
  `AppService.setPendingNavigation('transferCenter')`（一次性信号，置位时触发变更总线）；与分享 want 解析链路互不干扰
- **消费**：`MainTabFloating` 在冷启动 `aboutToAppear` 与热启动订阅回调中消费该信号，消费时先 `pathStack.clear()`
  （回到根、清掉已推入的子页面）再 `switchToTab(1)` 切到任务页签，保证从通知进入后展示任务中心列表而非退出时所在页面；
  信号为一次性，消费即清空，不产生重复跳转或页面叠加
- **落点边界**：通知一律进任务中心列表，不自动进入具体会话详情
