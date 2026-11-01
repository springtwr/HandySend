# Debug Log Inventory

HandySend 使用统一日志模块 `Logger.ets` 封装 hilog，按业务域（domain）细分，消息统一为 `[模块] 内容`，支持结构化上下文（LogContext）。

## 日志消息格式

| 形态 | 格式 | 说明 |
|------|------|------|
| 无上下文 | `[模块] 内容` | 默认形态，模块标签位于消息最前 |
| 带上下文 | `[模块] [字段=值 …] 内容` | 传输/接收/分享链路，标签在前、上下文在后 |
| 原生来源 | `[模块] Rust: 内容` | Rust 日志经桥接后的正文前缀 |

- 模块标签为模块/子系统级稳定短标签，由 `getLogger(domain, tag, label)` 集中前置，调用点不再手写 `[模块]`。
- 正文中的数据方括号（如 `[wlan0]`、文件列表）保留，不影响按 `[模块]` 无歧义过滤。
- 日志消息不得包含换行符，保证一事件一行。

## 日志过滤方式

```bash
# 按模块标签过滤
hdc shell hilog | grep '\[发送\]'

# 按模块 TAG 过滤
hdc shell hilog -t HandySend:SendRepository

# 按业务域过滤（domain 十六进制）
hdc shell hilog -D 0x0002    # TRANSFER 域
hdc shell hilog -D 0x0006    # MTA 域（仅 MTA 全链路日志）

# 按 TAG 前缀过滤所有 HandySend 日志
hdc shell hilog | grep "HandySend:"
```

## 业务域（LogDomains）

| 域 | 值 | 适用模块 |
|----|----|----------|
| GENERAL | 0x0000 | AppService、EntryAbility、EntryBackupAbility、DialogService、ReceiveHistoryService、NativeBridge、NativeTypes、EventBus、HttpLogsViewModel |
| DISCOVERY | 0x0001 | DiscoveryRepository、DeviceRepository、MainTabViewModel |
| TRANSFER | 0x0002 | SendRepository、ReceiveRepository、ReceiveTargets、SendViewModel、SendContent、WebShareRepository 等（完整清单见注 1） |
| NETWORK | 0x0003 | AppCore、NetworkSettingsSection |
| SERVER | 0x0004 | ServerRepository |
| SETTINGS | 0x0005 | SettingsRepository、PreferencesUtil、FavoritesService、SettingsViewModel |
| MTA | 0x0006 | service/mta/*、MtaRepository、Mta*ViewModel |

> **注 1**：TRANSFER 域适用模块完整清单：SendRepository、ReceiveRepository、
> ReceiveTargets、SendViewModel、SendContent、WebShareRepository、RustWeb（NativeBridge
> 内的网页传输 Rust 日志归并）、ChecksumRepository、GallerySaveService、VideoThumbnailUtil、
> service/transfer/*（会话引擎与协议适配器）、TransferCenterViewModel、SessionDetailViewModel、
> BackgroundTransferService、BackgroundAttentionNotifier。

## 日志级别规则（五级）

| 级别 | 目的 | 适用 |
|------|------|------|
| debug | 内部诊断细节（Release 默认抑制） | 状态细节/逐帧进度/no-op 跳过/重试细节/通知收发/鉴权结果/自动重启/历史裁剪/网卡转储/路由分支/适配器内部步骤/取消中间步骤/内部标识与协议字段 |
| info | 对外可见的关键流程节点 | 用户操作结果、会话终结、服务启停、请求接受/完成/取消/被拒、设置变更生效 |
| warn | 可恢复告警/无效操作/降级（能力未开启、资源清理失败、重复请求被忽略、注册/反注册失败、环境或权限受限） | 流程继续但需关注的分支 |
| error | 非预期失败/异常（解析/连接/IO/保存失败、启动异常、不变量被破坏） | 没有回退的真正故障 |
| fatal | 致命不可恢复（保留） | 几乎不用 |

### 级别判定要点

- 对端拒绝、用户取消、无可用应用、权限被拒、存储不足、对端版本不兼容等**可解释的业务结果不得记为 error**：
  对外可见的结果用 info，因环境/能力受限而无法继续的分支用 warn。
- 清理、反注册、停止服务失败通常记 warn：主流程已继续，失败仅影响资源回收。
- 防御性守卫命中、能力开关关闭后的空操作、重复请求忽略记 debug，不作为告警。
- info 正文只描述“发生了什么”，不得携带会话/文件/令牌等内部标识、原始协议字段、逐阶段细节与耗时；
  这些内容放 debug，或用 LogContext 统一承载。
- 同一事件只在一个最合适的位置记录；已在底层记录原因的失败，上层只记录结果，不重复记 error。

## 日志语言规则

- 日志正文使用简体中文；技术标识保留英文原文（字段名如 `port=`/`taskId=`、协议名如 HTTP/TLS/WS/GATT、错误码、HTTP 状态码、会话标识等）。
- Rust MTA 日志正文必须保留 `MTA` 前缀，供 ArkTS 侧按正文包含 `MTA` 归并（`drainRustLog` 的 `includes('MTA')` 过滤依赖此约定，翻译时不得去掉）。

### 标点与格式

- 中文正文使用全角标点（`，`、`：`、`；`、`。`），中文句子后的说明、原因、错误统一用 `：`。
- 英文技术片段、`key=value` 字段与纯英文标签保留半角（如 `port=`、`GATT Server`、`HTTP 403`）。
- 日志末尾不加句号；一条日志只表达一个事件，不换行。
- 诊断字段统一为 `键=值`，键与值之间不加空格；字段之间用单个空格分隔。

### 用词口径

- Web 相关统一称“网页”，用户可见的任务统一称“任务”，协议/注册表内部称“会话”，MTA 品牌名保留 `MTA`。
- 传输角色：LocalSend 语境用“发送方/接收方”，协议层对端用“对端”，面向人的提示用“对方”。
- 服务、任务、进程用“启动/停止”，开关、能力、功能用“开启/关闭”。
- 文件与用户数据用“删除”，列表/集合中的条目用“移除”，临时产物用“清理”。
- 操作未达成用“失败”；捕获回调、异步流程或系统 API 抛出的异常用“异常”；结果状态用“成功”，过程结束用“完成”。
- 不以函数名、类名或变量名作正文主语；改用功能描述，例如 `nativeStopServer` 写作“停止原生服务器”，
  `stateChange` 写作“蓝牙状态变化监听”。

Release（debug 关）下 debug 级被抑制，仅 info 及以上输出。

## 文件日志（双通道）

- 位置：应用沙箱 `filesDir/diagnostics/`
- 文件：
  - `events-current.log` / `events-previous.log`：info/warn/error/fatal，始终写入，绝不写 debug，单文件上限 512KB
  - `detail-current.log` / `detail-previous.log`：始终写 info+；详细日志开启时额外写 debug，单文件上限 2MB
- 时间：本地时区 ISO 8601，带偏移（如 `2026-11-01T03:48:47.184+08:00`），不是 UTC `Z`
- 写入：内存队列 + 每 500ms 批量 append；warn/error/fatal 立即 flush；退后台、窗口销毁、正常退出主动 flush
- 轮转：current 超过上限时删除旧 previous，current 改名为 previous，新建 current 并写新会话头
- 会话标记：`# session-start ...`、`# session-end ...`；previous 文件保留上一次会话内容，供 ZIP 导出携带
- 页面：固定只读 detail 当前文件尾部（最近约 256KB），按偏移增量刷新；时间按本地 24 小时制显示；详细开关只决定后续是否追加 debug
- debug 预算：全局每秒最多 100 条、突发 300 条；超限丢弃并写入 `# debug-suppressed` 汇总，events 不受影响
- 导出：events/detail 的 current/previous 四份文件 + `metadata.json`/`README.txt` 打包为 ZIP
- 内存回退：`AppCore` 仅保留最近 500 条，文件日志不可用时供诊断页临时显示

## 传输进度与任务列表转储的节流策略

- 传输进度日志：发送/接收两侧统一口径，进行中按「会话」维度每 5 秒最多 1 条
  （`传输进度` / `接收进度`），逐文件不再单独刷日志；文件完成与终态（完成/失败/取消）必发、不受节流限制；
  无字节进度的会话（如纯文本消息）不输出进度日志；节流状态随会话终结清理。
- 任务列表行序列转储（`TransferCenterViewModel`）：常态仅一行摘要（行数/剔除数/首尾条目标识），
  体积不随记录数增长；命中异常信号（条目被剔除、存在重复标识、行数相比上次减少）时输出完整序列。

## ArkTS 侧（Logger 模块）

每个模块在文件顶层创建 logger 实例：`const logger = getLogger(LogDomains.XXX, 'HandySend:模块名', '模块标签')`

| TAG | 标签 | 模块 | 关键日志点 |
|-----|------|------|-----------|
| `HandySend:AppService` | `[应用]` | AppService.ets | 初始化、事件分发、native 版本校验 |
| `HandySend:EntryAbility` | `[启动]` | EntryAbility.ets | Ability 生命周期 |
| `HandySend:EntryBackup` | `[备份]` | EntryBackupAbility.ets | 备份生命周期 |
| `HandySend:DialogService` | `[弹窗]` | DialogService.ets | 弹窗操作 |
| `HandySend:ReceiveHistoryService` | `[历史]` | ReceiveHistoryService.ets | 历史记录添加/清空 |
| `HandySend:NativeBridge` | `[桥接]` | NativeBridge.ets | NAPI 事件回调/处理器异常、Rust 日志归并 |
| `HandySend:RustWeb` | `[网页传输]` | NativeBridge.ets | Rust 网页传输子系统日志归并（按 Rust target 归入 `bridge::web`） |
| `HandySend:NativeTypes` | `[Native 类型]` | model/NativeTypes.ets | 事件必填字段缺失丢弃告警 |
| `HandySend:EventBus` | `[事件总线]` | utils/EventBus.ets | 事件回调异常 |
| `HandySend:HttpLogsViewModel` | `[日志页]` | HttpLogsViewModel.ets | 文件尾部读取、全量日志导出保存失败 |
| `HandySend:MainTab` | `[主页]` | MainTabViewModel.ets | Tab 切换、分享 URI 消费 |
| `HandySend:MainTabFloating` | `[主页]` | MainTabFloating.ets | 首页悬浮壳层、启动门禁与页面收尾 |
| `HandySend:DiscoveryRepository` | `[发现]` | DiscoveryRepository.ets | 设备发现事件、扫描/连接/注册、Rust 日志归并 |
| `HandySend:DeviceRepository` | `[设备]` | DeviceRepository.ets | 设备身份刷新 |
| `HandySend:SendRepository` | `[发送]` | SendRepository.ets | 发送流程（sendToDevice/Multi、文件 staging、会话管理）、Rust 日志归并 |
| `HandySend:ReceiveRepository` | `[接收]` | ReceiveRepository.ets | 接收流程（pending requests、auto-accept、会话完成/取消） |
| `HandySend:ReceiveTargets` | `[接收目标]` | service/repository/ReceiveTargets.ets | 接收目录获取失败、直写目标准备失败 |
| `HandySend:SendViewModel` | `[发送页]` | SendViewModel.ets | 发送状态管理 |
| `HandySend:SendContent` | `[发送内容]` | SendContent.ets | 发送内容组件（文件选择、剪贴板、拖放接收） |
| `HandySend:WebShareRepository` | `[网页传输]` | WebShareRepository.ets | 网页传输链接创建/停止、上传/下载事件、Rust 日志轮询（服务运行期每 2 秒排空） |
| `HandySend:ShareLinkViewModel` | `[网页传输]` | ShareLinkViewModel.ets | 网页传输面板状态与开关联动 |
| `HandySend:TransferRegistry` | `[会话注册表]` | service/transfer/TransferSessionRegistry.ets | 会话创建/状态迁移/终结/回收与聚合（统一会话事实源） |
| `HandySend:SessionHistory` | `[任务历史]` | service/transfer/SessionHistoryStore.ets | 任务历史归档、FIFO 裁剪与 schema 迁移 |
| `HandySend:SessionAdapter` | `[协议适配]` | service/transfer/adapters/*.ets | 各协议事件翻译与能力/展示描述符 |
| `HandySend:ProtocolDisableGuard` | `[协议开关]` | service/transfer/ProtocolDisableGuard.ets | 协议关闭确认文案解析 |
| `HandySend:TransferCenter` | `[任务]` | viewmodel/TransferCenterViewModel.ets | 中心分组/筛选/批量操作 |
| `HandySend:SessionDetail` | `[会话详情]` | viewmodel/SessionDetailViewModel.ets | 通用详情页状态与动作 |
| `HandySend:ChecksumRepository` | `[校验]` | ChecksumRepository.ets | 校验和计算 |
| `HandySend:GallerySaveService` | `[相册]` | GallerySaveService.ets | 相册保存（SaveButton 授权、MediaAssetChangeRequest） |
| `HandySend:VideoThumbnail` | `[缩略图]` | VideoThumbnailUtil.ets | 视频缩略图生成 |
| `HandySend:ImageThumbnail` | `[缩略图]` | ImageThumbnailUtil.ets | 发送侧预览缩略图生成（等比缩放 + JPEG 编码落盘，失败降级告警） |
| `HandySend:NetworkSettings` | `[网络设置]` | NetworkSettingsSection.ets | 网络设置分组（接口刷新、警告横幅） |
| `HandySend:SettingsViewModel` | `[设置页]` | SettingsViewModel.ets | 设置状态管理 |
| `HandySend:AppCore` | `[网络]` | AppCore.ets | 网卡检测、事件总线 |
| `HandySend:ServerRepository` | `[服务端]` | ServerRepository.ets | 服务器生命周期（start/stop/restart） |
| `HandySend:SettingsRepository` | `[设置]` | SettingsRepository.ets | 设置读写、持久化 |
| `HandySend:PreferencesUtil` | `[偏好]` | PreferencesUtil.ets | 偏好存储操作 |
| `HandySend:FavoritesService` | `[收藏]` | FavoritesService.ets | 收藏设备 CRUD |
| `HandySend:MtaRepository` | `[互传]` | service/repository/MtaRepository.ets | MTA 发现与接收服务启停门面 |
| `HandySend:MtaSend` | `[互传发送]` | service/mta/MtaSendService.ets | MTA 发送编排、Rust 日志归并、对端入组观测汇总、<br>写回 P2pInfo 写方式（按对端能力选择）与结果/耗时/失败原因、<br>写回后对端蓝牙链路变化与复读对端公开信息（成败/内容与 state 变化/判定结论）、<br>收束汇总写方式与成功判据、发送伴随外设启停与对端行为记录、<br>建链阶段耗时（点击→写回凭据/对端接入）与各阶段相对耗时 |
| `HandySend:MtaReceive` | `[互传接收]` | service/mta/MtaReceiveService.ets | MTA 接收编排（广播/GATT/P2P/WS/下载状态机）、建链阶段耗时（收凭据→本机弹窗）与各阶段相对耗时、会话收尾复用/重建判定 |
| `HandySend:MtaTransfer` | `[互传传输]` | service/mta/MtaTransferClient.ets | MTA WS 传输客户端（握手、消息、下载、status 回执） |
| `HandySend:MtaBleClient` | `[互传蓝牙]` | service/mta/MtaBleClient.ets | BLE 扫描解析诊断（原始 serviceData/解析结果/异常、5GHz 标记原值与判定依据）、<br>GATT Client（地址重扫/建链重试、按对端能力选择写模式（无响应写/带响应写）<br>与写诊断：写方式/目标特征/MTU/长度/耗时/写结果/失败原因） |
| `HandySend:MtaBleCommon` | `[互传蓝牙]` | service/mta/MtaBleCommon.ets | BLE 状态查询、Rust 日志轮询与权限辅助 |
| `HandySend:MtaBleReceiver` | `[互传蓝牙]` | service/mta/MtaBleReceiver.ets | BLE 广播字节诊断（主广播/扫描响应 hex）、GATT Server |
| `HandySend:MtaCrypto` | `[互传加密]` | service/mta/MtaCrypto.ets | 共享密钥派生、字段加解密（IV/长度/失败阶段） |
| `HandySend:MtaP2pConnector` | `[互传P2P]` | service/mta/MtaP2pConnector.ets | P2P 连接、GO IP、网络并存诊断 |
| `HandySend:MtaP2pGroup` | `[互传P2P]` | service/mta/MtaP2pGroup.ets | WiFi Direct 建组/删组、群组就绪以身份（就绪组名==请求组名）校验、<br>建组前残留群组有界消失等待、本机 P2P 设备地址读取（Native，对外统一归一为小写） |

> 同一标签可对应多个协作模块（如 `[互传蓝牙]`、`[互传P2P]`）；标签标识业务子系统，不要求全局唯一。

## MTA 子系统正文区分

MTA 各子系统（如 GATT、P2P、WS、下载、暂存）以「子系统: 内容」形式保留在正文中，如 `[互传接收] GATT: sendResponse(写) 失败: ...`。

MTA 收发服务经 `appendLog` 写入的日志与 `logger.*` 共用同一套级别规则：协议阶段推进、密钥/频点/地址、
逐阶段耗时与写回诊断等内部细节用 debug；用户可见的请求、接受、拒绝、完成、取消用 info；
清理/恢复/重试失败用 warn；只有无法继续的失败用 error。

## MTA 品牌兼容诊断点

MTA 收发链路的诊断级（debug）观测点，用于跨品牌兼容排障；需在诊断日志页开启「详细日志（DEBUG）」开关后经页内保存导出。

| 环节 | 模块 | 观测内容 |
|------|------|----------|
| 发送端广播解析 | MtaBleClient | 每条广播的 serviceData（UUID+hex）、厂商数据（公司 id+hex）、服务 UUID 列表、<br>原始报文 hex 与解析结果（设备名/品牌/5GHz/senderId/RSSI）、<br>5GHz 标记原始字节与判定依据（bit0）；异常与去重规则见注 2 |
| 接收端广播构造 | MtaBleReceiver | 广播启动/重启时主广播与扫描响应完整字节 hex、品牌字节、serviceUuid 与广播参数（interval/txPower/connectable） |
| 凭据加解密 | MtaCrypto | 共享密钥派生方式与密钥长度、字段加解密 IV hex 与密文长度；失败阶段（Base64 解码/密钥协商/AES 加解密）与长度线索 |
| Rust WS 协议 | bridge/mta/ws.rs | 每个 WS 报文的 `type:id:name` 与关键载荷（版本、taskId、文件数/总大小、对端 status 类型与原因）；<br>收尾「会话终止」（终止路径/终止方式=连接终止(未发送关闭帧)/结束类指示是否已送出/<br>对端是否先行关闭/宽限内对端是否结束/终止前等待与相对耗时） |
| Rust ZIP 流式写出 | bridge/mta/zip_stream.rs | 逐条目流式写出（条目名/源字节/累计源字节）与产物汇总（源总字节/条目数）；告警项：条目声明大小与实际读取不一致（按实际字节继续产出完整载荷） |
| Rust 接收下载 | bridge/mta/receive.rs、unzip_stream.rs | 接收开始（taskId/目标目录/声明总量）与完成（条目数/解压字节）、三速率与 HTTP 块大小统计、接收汇总（成功/失败）；告警项见注 3 |
| Rust 服务器/下载 | bridge/mta/server.rs、mod.rs | WS 升级、`/download` 开始/25% 里程碑/完成（禁止逐块）、taskId 不匹配告警、对端中止下载告警、服务器起停 |
| 发送端 GATT 建链 | MtaBleClient、MtaSendService | 连接前按 senderId 重扫与第 N 次重连、对端 CHAR_P2P 属性、<br>写回 P2pInfo 写方式（按对端能力选择：无响应写/带响应写，无响应写以端到端信号判成功）<br>与写诊断（目标特征/MTU/长度/耗时/写结果/失败原因）、对端 DeviceInfo 原文 |
| 发送端入组与链路 | MtaSendService | 会话收束（失败/取消）时汇总对端入组观测（是否曾入组/最大客户端数/群组信息不可得次数）；<br>写回 P2pInfo 后对端蓝牙链路变化（保持/断开/断开后重连，含相对写回耗时）；<br>写回后复读对端公开信息（成败、内容与 state 是否变化、判定结论）；<br>写回 P2pInfo 写方式与成功判据（带响应写以写回调判定、无响应写以端到端信号判定） |
| 发送端建组身份 | MtaSendService、MtaP2pGroup | 建组就绪以群组身份（就绪组名==本次请求创建的组名）判定：<br>本次请求组名、观测到的就绪组名、是否匹配、候选/尝试次数；<br>建组前残留群组的有界处置结果（已消失 / 超时未消失）；身份不匹配时不采用其凭据 |
| 发送端 P2P 地址 | MtaP2pGroup、MtaSendService | 逐接口 Native 读本机硬件地址（`p2p0` 等），即 `P2pInfo.mac` 的取值来源；<br>对外发送前统一归一为小写（中兴用大小写敏感比对、小米不敏感，小写同时满足）；<br>读取失败回退 `ownerInfo.deviceAddress` 时以 warn 记录回退值 |
| 发送伴随外设 | MtaSendService、MtaBleReceiver | 发送期间保持的最小 BLE 外设（广播 + GATT Server，隔离于发送会话）：<br>启动/停止与广播预览；对端连接/断开、读请求（客户端/offset）、写请求摘要（目标特征/offset/累计长度/prepared）、<br>写入 P2pInfo（仅记录不接入接收会话）；停止时汇总对端行为（连接/断开/读/写/是否收到 P2pInfo） |
| 接收端 WS 回执 | MtaTransferClient、MtaReceiveService | 回送 status 完整报文（帧号/字段）、提前回送与失败兜底重送、确认超时自动拒绝、取消回送 user refuse；未处理报文原文 |
| 接收端缩略图 | MtaReceiveService、bridge/mta/receive.rs | 拉取开始 / 未取到 / 已就绪（含落盘路径）；Rust 侧保存结果（识别格式、字节数、路径） |
| 发送端缩略图 | MtaSendService、bridge/mta、server.rs | 生成结论（已生成尺寸与耗时 / 非媒体不提供 / 失败不提供）；Rust 侧提供结论与 `/thumbnail` 命中、未提供、taskId 不匹配 |
| 建链阶段耗时（发送侧） | MtaSendService、MtaSendAdapter | 以用户点击为起点，逐阶段记录相对耗时<br>（伴随外设就绪/GATT 连接/对端信息读取/组网就绪/本地服务就绪/写回凭据/对端接入/版本协商/对端开始下载）<br>与「点击→写回凭据」「点击→对端接入」总耗时 |
| 建链阶段耗时（接收侧） | MtaReceiveService | 以收到对端凭据为起点，逐阶段记录相对耗时（凭据解密/入组完成/WS 建连/版本协商/本机弹窗）与「收凭据→本机弹窗」总耗时 |
| 接收对外服务复用 | MtaReceiveService、MtaRepository | 会话收尾复用判定（可复用即复用既有广播/GATT 与密钥，失败回退完整重建）；应用退后台/开关关闭时抑制复用 |

> **注 2**：serviceDataMap 缺失、扫描响应字节长度不足、UUID 不匹配、品牌或设备名字段
> 解析失败等异常；同一设备仅在解析签名变化时记录（签名含原始 serviceData 与厂商数据）。
>
> **注 3**：三速率指网络读入/解压产出/写盘；还原文件时间失败时告警。
>
> **注 4**：MTA 接收会话的群组凭据行（`凭据解密成功 …`）按「口令打码 + debug 级」输出，明文口令不进入常规日志。

## Rust 侧日志

- Rust `log::*` 调用按同一套五级语义校正；调试标签（`[DBG-*]` 等）已移除，由正文自述。
- Rust info 只保留服务启停、接收完成等关键节点；页面访问、下载会话建立、批次/令牌明细与协议阶段参数用 debug。
- 缓冲元素格式为 `level|target|message`（`level ∈ error/warn/info/debug/trace`，`target` 为 Rust 模块路径）；ArkTS 侧按前两个 `|` 解析，`trace` 归一到 `debug`，无分隔符按 `info` 兜底。
- ArkTS 消费方统一以 `Rust: ` 作为正文前缀（如 `[发现] Rust: ...`、`[桥接] Rust: ...`），经带级别轮询接口读取，保留原始级别；轮询时机为设备发现、发送结束与网页服务运行期（每 2 秒）。
- target 位于 `bridge::web` 下的 Rust 日志由 ArkTS 侧归入 `[网页传输]`，其余行仍按 `[桥接]` 输出。
- MTA 相关 Rust 日志正文以 `MTA` 标识开头，供 ArkTS 侧按正文包含 `MTA` 归并到 MTA 发送/应用日志。
- 第三方依赖（`rustls`/`tokio_rustls`/`reqwest`）的 debug/trace 日志按 target 前缀屏蔽（bridge/identity.rs `log_enabled`）
  ，仅保留其 warn/error；`log!` 宏只检查 max_level、不调用 `enabled()`，故过滤须在输出器的 `log()` 入口收口。

## 结构化日志上下文（LogContext）

传输相关日志可附加结构化前缀，格式 `[模块] [sid=xxx dir=send alias=Phone] 内容`：

| 字段 | 输出键 | 说明 | 截断规则 |
|------|--------|------|----------|
| sessionId | `sid` | 会话 ID | 取前 8 字符 |
| fileId | `fid` | 文件 ID | 不截断 |
| direction | `dir` | 传输方向（send/recv/share） | — |
| targetAlias | `alias` | 目标设备别名 | — |
| protocol | `proto` | 协议（http/https） | — |

## Debug 开关

- 默认关闭不再基于内存压力：内存回退 500 条、写入队列 500 行、页面尾读 256KB 均有界
- 仍保留显式开关的原因：限制持续 debug 写入、hilog 与 Rust 日志的 I/O/性能开销，
  减少原始协议/设备标识等诊断内容长期落盘，并避免普通用户看到诊断噪音
- **Debug 构建**：未保存用户选择时默认 DEBUG
- **Release 构建**：未保存用户选择时默认 INFO
- 诊断日志页标题栏溢出菜单 →「日志设置」弹层，内含唯一的「记录详细日志」Toggle 与说明
- 用户选择持久化，重启后继续生效；可在启动阶段捕获详细日志
- `setDebugEnabled()` 修改内存标志、hilog 全局级别、detail 的 debug 写入和 Rust 日志级别
- 文件日志写入与页面读取解耦：页面关闭后仍持续写 events/detail；detail 始终记录 info+，debug 按开关追加
