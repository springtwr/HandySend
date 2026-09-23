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
| `components/demo/DemoScenarioSheet.ets` | 场景选择菜单弹窗（CustomContentDialogV2，四场景项 + 语言切换组 + 取消） |

## 3. 注入点（对既有文件的改动）

| 注入点 | 改动 |
|--------|------|
| `entryability/EntryAbility.ets` `onCreate` | `initBackgroundTransferService()` 之后调用 `initDemoModule(context)`（幂等） |
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
