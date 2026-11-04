# 后台传输与通知

> `BackgroundTransferService`（dataTransfer 长时任务 + 实况进度通知）与 `BackgroundAttentionNotifier`（后台关注通知层）的实现细节。
>
> 主文档 `docs/ARCHITECTURE.md` §4.7 / §4.8 保留概述；生命周期编排见主文档 §4.1。

## 1. BackgroundTransferService — 后台传输服务

`entry/src/main/ets/service/BackgroundTransferService.ets`

后台传输保护（手机/平板/PC 通用）：应用处于后台、存在活跃传输（LocalSend 发送/接收、MTA 发送/接收、Web 分享下载/上传）
且通知权限已开启时申请 `dataTransfer` 长时任务（`backgroundTaskManager.startBackgroundRunning`，
`KEEP_BACKGROUND_RUNNING` 权限），并以实况通知（LIVE_VIEW SlotType + downloadTemplate，typeCode 8）展示聚合进度；
本轮无进行中会话后发布独立普通终态通知（成功/部分失败/失败三档），并立即停止传输长时任务。

服务为模块级单例，由 EntryAbility 生命周期驱动。

### 1.1 数据源

- 唯一来源为统一会话注册表——`TransferSessionRegistry.getOverallSnapshot()` 的协议无关聚合快照（活跃会话数/设备数/整体进度/成败汇总）；服务不逐协议读取快照，也不按方向硬编码取消分支
- 待确认会话（`awaitingConfirmation`）不计入活跃：活跃标志、会话数、设备数、进度与字节汇总均只覆盖「进行中」会话；`allFinished` 仍表示「全部会话均已终态」，仅有待确认时不视为全部完成

### 1.2 传输驱动启停

- 长时任务的申请/保持除 `onBackground` 时机外，也由 changeBus 驱动：缓存 `UIAbilityContext`，在后台检出进行中传输且任务空闲时主动申请（`ensureTransferTaskForBackground`，幂等）
- 传输任务与空闲保活任务分离，各自持有独立的 `dataTransfer` 长时任务、通知 Id 与任务 Id：
  - 传输任务：后台存在活跃会话时申请，通知显示「后台传输中 / 45%」；多任务时显示
    「后台传输中 / 共 3 个任务 · 45%」，随真实进度更新；
  - 保活任务：设置「允许后台接收」开启、通知权限已开启且网页服务或 LocalSend 服务器运行时，进入后台即申请，
    通知显示「后台运行中 / 临时保活5分钟，到期后自动关闭」，固定 5 分钟，每 30 秒推进进度，
    到期先发布 100% 结束帧再立即停止任务（通知随任务消失，与传输任务一致，不触发系统完成提醒）；
    不因传输开始/结束重置或延长。
- 通知权限未开启时不申请传输/保活长时任务（长时任务通知无法建立），
  「允许后台接收」设置项置灰
- 传输结束统一发布独立普通终态通知（成功/部分失败/失败三档，不自动撤销，回前台或点击后撤销）；
  普通通知发布完成后立即停止传输长时任务，避免「后台传输中」通知继续显示。
  普通终态通知与保活实况通知可并存。
- 系统可能因 `dataTransfer` 低速率提前取消保活任务（`detailedReason=4`）；保活任务被取消时只结束保活，
  不影响仍在进行的传输任务。
- 终态处理期间新传输出现时使在途停止失效并复位终态标记，使传输任务继续有效
- 回前台延迟 3 秒停止传输任务（3 秒内重新退后台则取消停止并复用原任务），同时立即停止保活任务；
  Ability 销毁时立即停止
- 停止按 `continuousTaskId` 精确执行；仅任务 Id 缺失、需要停全部的兜底路径才用启停代次保护
- 长时任务取消兼容 `USER_CANCEL` 与 `USER_CANCEL_REMOVE_NOTIFICATION`；
  API 26 起同时读取 `detailedReason`，低版本仅按 `reason` 判断
- 申请成功后重新读取整体快照：申请期间已结束的传输直接收尾，不发布申请前旧帧；
  期间新加入的会话纳入首帧

### 1.3 更新机制

- 订阅 AppCore changeBus，1s 节流发布（`throttleDelayMs` 纯函数决策 + 单 pending 定时器同帧合并）
- 代次计数器（startGeneration）防止停止后旧帧覆盖
- 聚合进度按本轮后台周期累计：进行中会话取实时字节，终态会话冻结最终字节；
  任务完成不把其字节从分母移除，新任务加入才增加分母，避免任务完成时进度跳变
- 实况窗文案只展示进度信息。按《Background Tasks Kit 接入规范》，`dataTransfer` 长时任务
  允许更新进度信息，但仅限进度展示，不用于提示、公告等其他用途

### 1.4 终态正确性

- 终态发布前取消待发布节流帧；待发布帧在发布时刻重读最新聚合快照
- 终态发布后抑制一切进度帧（防过期帧回跳）
- 终态会话（含 MTA 发送）由注册表统一保留可见窗口（成功 3s / 失败与取消 5s），确保终态帧可算出 100% 而非 0%

### 1.5 前台引导与前台状态

- 前台收到变化且通知未授权时 `requestEnableNotification` 引导（进程级一次提示，2s 限频）
- 应用前台/后台由 `AppCore`（`setAppForeground`/`isAppForeground`，EntryAbility 生命周期驱动）统一提供

### 1.6 删除通知取消

- `continuousTaskCancel` 用户取消事件（`USER_CANCEL` / `USER_CANCEL_REMOVE_NOTIFICATION`，
  含 API 26 `detailedReason`）经统一取消入口下发：对注册表中全部非终态会话调用 `TransferSessionRegistry.cancel()`
- `cancel` 按适配器能力声明分发（`canCancel=false` 的协议为空操作，不改状态、不调用适配器），其余由各协议适配器执行具体取消动作

### 1.7 可测性

- 导出 `throttleDelayMs`/`resolveTerminalKind`/`shouldExecuteStop`/`isUserCancel` 纯决策函数供 Instrument Test 单测；
  聚合断言由 `BackgroundAggregateTest` 经注册表快照验证

## 2. BackgroundAttentionNotifier — 后台关注通知层

`entry/src/main/ets/service/BackgroundAttentionNotifier.ets`

- 应用处于后台时，把需要用户关注的事件收敛为**一条**系统通知（独立通知 id，与实况进度通知区分）；
  单条待确认点击直达该请求详情，多条合并点击回任务中心（见 §3）
- **只展示待确认请求**：LocalSend / MTA 接收、Web 上传；
  数量取统一注册表的待确认会话标识数（`getPendingSessionIds`），`%d` 为等待确认的请求数
- 网页访问/网页下载不进入该通知：访问只写诊断日志，并通过 `noteWebAccess` 续期网页服务的有界保活；
  下载批次由后台传输实况通知承载（与上传/其它传输共用的聚合通知）
- **发布/撤回驱动**：注册表变更订阅 + 退后台补发（前台期间已存在的待确认请求在 `onBackground` 补齐）；
  回到前台（`onForeground`）撤回；无待确认即撤回
- **去重**：按「类别 + 数量 + 单条时的会话标识」签名判重，同一状态不重复 publish；
  数量不变但换成另一条请求时也会重发，避免点击目标仍指向已处理掉的旧请求
- **发布串行**：连续变化合并为一次排队，轮到本次时按最新注册表状态重算，
  避免较早的发布晚于较新状态完成而覆盖通知内容与点击目标；
  撤回与在途发布之间用代际号兜底回收，取消动作串行执行并在发布前等待完成，避免迟到的取消误删新通知
- 请求本身仍是注册表中的待确认会话，用户回到前台后可在任务页或直达的详情页处理

## 3. 通知点击深链

通知点击统一拉起主 Ability 并置于前台，按「单任务进详情、多任务进任务中心」选择落点，
口径与发送失败浮卡一致：

| 通知 | 落点 |
|------|------|
| 终态普通通知（§1） | 本轮仅 1 个传输任务 → 该任务详情；2 个及以上 → 任务中心 |
| 后台关注通知（§2） | 1 条待确认 → 该请求详情（进页即可接受/拒绝）；多条 → 任务中心 |
| 实况进度通知 / 空闲保活通知 | 任务中心 |

实况进度通知的点击目标在申请长时任务时经 `ContinuousTaskRequest.wantAgent` 一次性固定，进度帧无法改写；
后续新会话加入或原会话结束后目标会过期，故保持任务中心，不随单/多任务变化。

- **意图载体**：`utils/WantAgentUtil.buildBackToFrontWantAgent(context, navigationTarget?, sessionId?)`
  在 `Want.parameters` 写入 `handysend.navigate`（`transferCenter` / `sessionDetail`）；
  目标为 `sessionDetail` 且会话标识非空时另写 `handysend.sessionId`；缺省不传目标时保持既有无参调用兼容
- **解析**：`EntryAbility.onCreate`（冷启动）/ `onNewWant`（热启动）解析 `want.parameters`，
  `transferCenter` 置位任务中心信号；`sessionDetail` 携带会话标识时置位详情信号，标识缺失则退回任务中心；
  信号为 `AppService` 的一次性深链（置位时触发变更总线），与分享 want 解析链路互不干扰
- **消费**：`MainTabFloating` 在冷启动 `aboutToAppear` 与热启动订阅回调中消费该信号；
  两种落点都复用失败浮卡的跳转口径——先 `pathStack.clear(false)` 回到根、任务页签滚动位置归零并切到任务页签，
  详情落点再压入 `SessionDetailPage`，保证返回时落在任务列表而不是退出时所在页面；
  会话已被回收时详情页按统一标识回退历史只读摘要；两者都不存在（如进程重启后残留的待确认通知）则退回任务中心；
  从通知进入前台时（不论落到任务中心还是详情），点击通知那一刻已存在的待确认请求不再补弹，
  点击之后新到达的请求仍正常提示；
  信号为一次性，消费即清空，不产生重复跳转或页面叠加
