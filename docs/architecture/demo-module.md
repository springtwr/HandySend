# 演示模块（虚拟设备模拟传输）

> 演示分支（`demo/virtual-devices`）专属的虚拟设备与模拟会话模块实现细节。
>
> 主文档 `docs/ARCHITECTURE.md` §4.11 保留概述；会话引擎与适配器命令分发机制见 `session-engine.md`。

> **分支限定声明**：本模块仅存在于 `demo/virtual-devices` 分支，用于演示与截图场景（三语言应用商店素材）。
> 不合入主干；主干上没有 `service/demo/`、`components/demo/` 目录与本文所述的各注入点改动。

## 1. 模块定位

演示模块在发送页注入四台虚拟设备（两台 LocalSend、两台 MTA），点击虚拟设备弹出场景菜单，
可触发四类模拟传输场景（收文件 / 收文本 / 发文件 / 发文本），会话经统一会话引擎登记，
任务页、会话详情页、接收历史、后台实况通知等既有 UI 与复用机制对模拟会话透明生效。

## 2. 文件结构

| 文件 | 职责 |
|------|------|
| `service/demo/DemoDevices.ets` | 虚拟设备定义（固定 fingerprint 集合）、`isDemoDevice()` 精确匹配、`getDemoDevices(protocol)` |
| `service/demo/DemoData.ets` | 演示数据常量：文件清单（收 5 条 / 发 4 条，各约 3.6 GB）、演示文本、进度计划（1s/60MB）、续期间隔（45s） |
| `service/demo/DemoFileWriter.ets` | 演示文件落盘（Download 目录回退 filesDir/demo_received）、1×1 PNG 占位图、接收历史条目写入 |
| `service/demo/DemoScenarioService.ets` | 场景编排核心：会话创建、进度推进器、适配器命令装饰、待确认续期、`initDemoModule()` 装配 |
| `service/demo/DemoTaskData.ets` | 任务中心模拟任务清单：固定 12 条终态记录定义（来源/方向/结果/文件清单来源/时间偏移与速度）、固定 web 对端常量、`DEMO_TASK_CATALOG` |
| `service/demo/DemoTaskHistory.ets` | 模拟任务历史注入：清单条目 → `SessionHistoryEntry` 映射（时间派生、逐文件清单、对端解析、时间线）与按固定 `sessionId` 的幂等 upsert |
| `components/demo/DemoScenarioSheet.ets` | 场景选择菜单弹窗（CustomContentDialogV2，四场景项 + 语言切换组 + 取消） |

## 3. 注入点（对既有文件的改动）

| 注入点 | 改动 |
|--------|------|
| `entryability/EntryAbility.ets` `onCreate` | `initBackgroundTransferService()` 之后调用 `initDemoModule(context)`（幂等） |
| `service/demo/DemoScenarioService.ets` `initDemoModule()` | `initDemoFileWriter(context)` 之后调用 `seedDemoTaskHistory()`（每次启动执行，幂等注入任务中心模拟任务） |
| `viewmodel/SendViewModel.ets` `refresh()` | 真实设备之后追加 `getDemoDevices()` 合并（排序置后；演示 MTA 设备不受蓝牙开关门控） |
| `components/SendContent.ets` `sendToSelectedDevice()` | 入口处拦截演示设备（先于暂存内容检查），打开场景菜单并跳过真实发送 |
| `service/transfer/adapters/LocalSendReceiveAdapter.ets` | 新增导出 `resetLocalReceivePendingTimeout()`（待确认超时重排，供续期使用） |
| `service/transfer/adapters/MtaReceiveAdapter.ets` | 新增导出 `resetMtaPendingTimeout()`（同上） |

## 4. 关键机制

### 4.1 适配器命令装饰

`initDemoModule()` 经 `getAdapter(key)` 取得四个会话适配器的命令引用（confirm/decline/cancel/retry
均为可变函数属性），对演示会话 id 改写为模拟逻辑、真实会话 id 透传原实现：

- **接收侧 confirm**：演示会话落盘演示文件、写入接收历史、启动进度推进器，最后以成功终态收尾
- **接收侧 decline/cancel**：注册表分发时已自行将会话置为拒绝/取消终态，装饰器对演示 id 直接 no-op，
  避免误触真实接收仓库或原生层调用
- **发送侧 cancel/retry**：`MtaSendAdapter` 的 `cancelActiveSend()`/`retryLastSend()` 无会话参数，
  会误杀并发中的真实发送，装饰器对演示 id 一律 no-op 并仅停止推进器

### 4.2 进度推进器

按统一会话 id 维护独立 interval（DEMO_PROGRESS_PLAN：每秒 60MB），逐文件推进字节并在
tick 内检测会话终态自停（用户手动取消时推进器随之清理）。

### 4.3 待确认续期

演示待确认会话每 45s 调用超时重置函数（LocalSend/MTA 各自的 reset 导出），
保证多语言截图期间待确认画面不因 60s 超时自动消失。

### 4.4 MTA 收文件场景形态

复刻真实 MTA 单条目会话：清单聚合为单条文件描述（fileId `mta-0`，文件数 5，大小取总量），
`ReceiverState`（REQUEST_RECEIVED → 接收中 → COMPLETED）序列直接喂 `handleMtaReceiveState`。

### 4.5 语言切换

语言切换组内嵌在演示场景菜单中（`DemoScenarioSheet`，点击任意虚拟设备即达）：列出
en / zh_Hans / zh_Hant 三个固定选项并高亮当前值，点击调用 `SettingsRepository.setLocale()`
（与设置页同一实现，持久化 + 应用 + 通知刷新）。
切换语言需冷启动后完全生效（`applyLocaleToApp` 的既有语义），截图流程为：场景菜单选语言 →
重启应用 → 按目标语言截取各页面。
应用页面本身不引入任何演示可见元素（标题栏、菜单与既有页面完全一致），保证截图与原版不可区分。

### 4.6 任务中心模拟任务种子

冷启动后任务中心自动呈现固定 12 条终态记录，无需手动触发任何场景；记录经既有任务历史机制持久化
与渲染，不新增任何页面/组件/UI，与真实任务同列表混排且不可区分。

- **注入方式**：以终态快照**直接写入**既有任务历史存储（`sessionHistoryStore.load()` → 逐条
  `upsertHistory` → `persist`），不经统一会话注册表、协议适配器与进度推进器，不创建真实会话、
  不启动定时器；启动时无订阅者，无需发布变更通知。
- **幂等与重建**：记录使用固定 `sessionId`（前缀 `demo-task-`），每次启动执行一次，同标识 upsert
  天然幂等（重启不重复）；清除任务历史后再启动即按固定清单重建（清除动作与本函数无耦合）。
- **固定清单**：LocalSend 5 / 互传 4 / web 3；成功 7 / 部分失败 1 / 失败 2 / 取消 2；文本 2 条。
- **相对时间**：以注入时刻为基准往前按固定偏移派生 `startedAt` / `finishedAt`（含固定时长与
  平均/峰值速度），列表排序确定、观感为近期，不随截图批次变化。
- **对端身份**：LocalSend/互传复用 `DemoDevices` 虚拟设备（互传按真实形状：无 IP/型号徽标、
  指纹取 BLE 地址、携带品牌标识）；web 用固定对端常量（`deviceType='web'`、`displayName=ip`）。
- **web 双形态**：浏览器上传到本机（`localsend-receive` + `inbound`）与网页下载（`web-download` +
  `outbound`），两者均经 `sourceLabelForSession` 归为 web 来源。
- **文本记录**：单条 `text/plain` 条目，`size` 取文本 UTF-8 字节数，经 `writeDemoTextFile(...)`
  落盘并把返回路径写入条目 `path`，供详情页内联预览正常渲染。
