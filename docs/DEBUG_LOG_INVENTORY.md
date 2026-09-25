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
> ReceiveTargets、SendViewModel、SendContent、WebShareRepository、ChecksumRepository、
> GallerySaveService、VideoThumbnailUtil、service/transfer/*（会话引擎与协议适配器）、
> TransferCenterViewModel、SessionDetailViewModel、BackgroundTransferService、
> PendingRequestNotifier。

## 日志级别规则（四级）

| 级别 | 适用 |
|------|------|
| debug | 诊断/状态细节/逐帧进度/no-op 跳过/重试细节 |
| info | 关键流程节点（启动、连接、请求接受、完成、取消、设置变更生效） |
| warn | 可恢复告警/无效操作/降级（能力未开启、资源清理失败、重复请求被忽略、注册/反注册失败） |
| error | 真正失败/异常（解析/连接/IO/保存失败、启动异常） |
| fatal | 致命不可恢复（保留） |

Release（debug 关）下 debug 级被抑制，仅 info 及以上输出。

## 传输进度与任务列表转储的节流策略

- 传输进度日志：发送/接收两侧统一口径，进行中按「会话标识 + 文件标识」维度每秒最多 1 条
  （`File progress` / `Receive file progress`），终态（完成/失败/取消）必发、不受节流限制；
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
| `HandySend:NativeBridge` | `[桥接]` | NativeBridge.ets | NAPI 事件回调/处理器异常 |
| `HandySend:NativeTypes` | `[Native 类型]` | model/NativeTypes.ets | 事件必填字段缺失丢弃告警 |
| `HandySend:EventBus` | `[事件总线]` | utils/EventBus.ets | 事件回调异常 |
| `HandySend:HttpLogsViewModel` | `[日志页]` | HttpLogsViewModel.ets | 日志导出保存失败 |
| `HandySend:MainTab` | `[主页]` | MainTabViewModel.ets | Tab 切换、分享 URI 消费 |
| `HandySend:DiscoveryRepository` | `[发现]` | DiscoveryRepository.ets | 设备发现事件、扫描/连接/注册、Rust 日志归并 |
| `HandySend:DeviceRepository` | `[设备]` | DeviceRepository.ets | 设备身份刷新 |
| `HandySend:SendRepository` | `[发送]` | SendRepository.ets | 发送流程（sendToDevice/Multi、文件 staging、会话管理）、Rust 日志归并 |
| `HandySend:ReceiveRepository` | `[接收]` | ReceiveRepository.ets | 接收流程（pending requests、auto-accept、会话完成/取消） |
| `HandySend:ReceiveTargets` | `[接收目标]` | service/repository/ReceiveTargets.ets | 接收目录获取失败、直写目标准备失败 |
| `HandySend:SendViewModel` | `[发送页]` | SendViewModel.ets | 发送状态管理 |
| `HandySend:SendContent` | `[发送内容]` | SendContent.ets | 发送内容组件（文件选择、剪贴板、拖放接收） |
| `HandySend:WebShareRepository` | `[网页分享]` | WebShareRepository.ets | Web 分享链接创建/停止、上传/下载事件 |
| `HandySend:TransferRegistry` | `[会话注册表]` | service/transfer/TransferSessionRegistry.ets | 会话创建/状态迁移/终结/回收与聚合（统一会话事实源） |
| `HandySend:SessionHistory` | `[任务历史]` | service/transfer/SessionHistoryStore.ets | 任务历史归档、FIFO 裁剪与 schema 迁移 |
| `HandySend:SessionAdapter` | `[协议适配]` | service/transfer/adapters/*.ets | 各协议事件翻译与能力/展示描述符 |
| `HandySend:TransferCenter` | `[任务]` | viewmodel/TransferCenterViewModel.ets | 中心分组/筛选/批量操作 |
| `HandySend:SessionDetail` | `[会话详情]` | viewmodel/SessionDetailViewModel.ets | 通用详情页状态与动作 |
| `HandySend:ChecksumRepository` | `[校验]` | ChecksumRepository.ets | 校验和计算 |
| `HandySend:GallerySaveService` | `[相册]` | GallerySaveService.ets | 相册保存（SaveButton 授权、MediaAssetChangeRequest） |
| `HandySend:VideoThumbnail` | `[缩略图]` | VideoThumbnailUtil.ets | 视频缩略图生成 |
| `HandySend:NetworkSettings` | `[网络设置]` | NetworkSettingsSection.ets | 网络设置分组（接口刷新、警告横幅） |
| `HandySend:SettingsViewModel` | `[设置页]` | SettingsViewModel.ets | 设置状态管理 |
| `HandySend:AppCore` | `[网络]` | AppCore.ets | 网卡检测、事件总线 |
| `HandySend:ServerRepository` | `[服务端]` | ServerRepository.ets | 服务器生命周期（start/stop/restart） |
| `HandySend:SettingsRepository` | `[设置]` | SettingsRepository.ets | 设置读写、持久化 |
| `HandySend:PreferencesUtil` | `[偏好]` | PreferencesUtil.ets | 偏好存储操作 |
| `HandySend:FavoritesService` | `[收藏]` | FavoritesService.ets | 收藏设备 CRUD |
| `HandySend:MtaRepository` | `[互传]` | service/repository/MtaRepository.ets | MTA 发现与接收服务启停门面 |
| `HandySend:MtaSend` | `[互传发送]` | service/mta/MtaSendService.ets | MTA 发送编排、Rust 日志归并 |
| `HandySend:MtaReceive` | `[互传接收]` | service/mta/MtaReceiveService.ets | MTA 接收编排（广播/GATT/P2P/WS/下载状态机） |
| `HandySend:MtaTransfer` | `[互传传输]` | service/mta/MtaTransferClient.ets | MTA WS 传输客户端（握手、消息、下载、status 回执） |
| `HandySend:MtaBleClient` | `[互传蓝牙]` | service/mta/MtaBleClient.ets | BLE 扫描解析诊断（原始 serviceData/解析结果/异常）、GATT Client（地址重扫/建链重试、写模式选择） |
| `HandySend:MtaBleReceiver` | `[互传蓝牙]` | service/mta/MtaBleReceiver.ets | BLE 广播字节诊断（主广播/扫描响应 hex）、GATT Server |
| `HandySend:MtaCrypto` | `[互传加密]` | service/mta/MtaCrypto.ets | 共享密钥派生、字段加解密（IV/长度/失败阶段） |
| `HandySend:MtaP2pConnector` | `[互传P2P]` | service/mta/MtaP2pConnector.ets | P2P 连接、GO IP、网络并存诊断 |
| `HandySend:MtaP2pGroup` | `[互传P2P]` | service/mta/MtaP2pGroup.ets | WiFi Direct 建组/删组、本机 P2P 设备地址读取（Native） |

> 同一标签可对应多个协作模块（如 `[互传蓝牙]`、`[互传P2P]`）；标签标识业务子系统，不要求全局唯一。

## MTA 子系统正文区分

MTA 各子系统（如 GATT、P2P、WS、下载、暂存）以「子系统: 内容」形式保留在正文中，如 `[互传接收] GATT: sendResponse(写) 失败: ...`。

## MTA 品牌兼容诊断点

MTA 收发链路的诊断级（debug）观测点，用于跨品牌兼容排障；需在诊断日志页开启「详细日志（DEBUG）」开关后经页内保存导出。

| 环节 | 模块 | 观测内容 |
|------|------|----------|
| 发送端广播解析 | MtaBleClient | 每条广播原始 serviceData（UUID + 字节 hex）与解析结果（设备名/品牌 id 与名/是否 5GHz/senderId/RSSI）；异常与去重规则见注 2 |
| 接收端广播构造 | MtaBleReceiver | 广播启动/重启时主广播与扫描响应完整字节 hex、品牌字节、serviceUuid 与广播参数（interval/txPower/connectable） |
| 凭据加解密 | MtaCrypto | 共享密钥派生方式与密钥长度、字段加解密 IV hex 与密文长度；失败阶段（Base64 解码/密钥协商/AES 加解密）与长度线索 |
| Rust WS 协议 | bridge/mta/ws.rs | 每个 WS 报文的 `type:id:name` 与关键载荷（版本、taskId、文件数/总大小、对端 status 类型与原因） |
| Rust ZIP 流式写出 | bridge/mta/zip_stream.rs | 逐条目流式写出（条目名/源字节/累计源字节）与产物汇总（源总字节/条目数） |
| Rust 接收下载 | bridge/mta/receive.rs、unzip_stream.rs | 接收开始（taskId/目标目录/声明总量）与完成（条目数/解压字节）、三速率与 HTTP 块大小统计、接收汇总（成功/失败）；告警项见注 3 |
| Rust 服务器/下载 | bridge/mta/server.rs、mod.rs | WS 升级、`/download` 开始/25% 里程碑/完成（禁止逐块）、taskId 不匹配告警、对端中止下载告警、服务器起停 |
| 发送端 GATT 建链 | MtaBleClient、MtaSendService | 连接前按 senderId 重扫与第 N 次重连、对端 CHAR_P2P 写模式（属性/选用写模式/回退重试）、对端 DeviceInfo 原文 |
| 发送端 P2P 地址 | MtaP2pGroup | 逐接口 Native 读本机硬件地址（`p2p0` 等），即 `P2pInfo.mac` 的取值来源 |
| 接收端 WS 回执 | MtaTransferClient、MtaReceiveService | 回送 status 完整报文（帧号/字段）与提前回送时机；收到未处理报文的完整原文（对端判定依据） |

> **注 2**：serviceDataMap 缺失、扫描响应字节长度不足、UUID 不匹配、品牌或设备名字段
> 解析失败等异常；同一设备仅解析签名变化时记录。
>
> **注 3**：三速率指网络读入/解压产出/写盘；还原文件时间失败时告警。

## Rust 侧日志

- Rust `log::*` 调用按四级语义校正；调试标签（`[DBG-*]` 等）已移除，由正文自述。
- 缓冲元素格式为 `level|message`（`level ∈ error/warn/info/debug/trace`）；ArkTS 侧按首个 `|` 解析，`trace` 归一到 `debug`，无分隔符按 `info` 兜底。
- ArkTS 消费方统一以 `Rust: ` 作为正文前缀（如 `[发现] Rust: ...`），经带级别轮询接口读取，保留原始级别。
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

- **Debug 版本**：默认 DEBUG 级别，全量输出
- **Release 版本**：默认 INFO 级别，诊断日志页「详细日志（DEBUG）」Toggle 可临时开启 DEBUG，重启恢复
- 不持久化，不依赖 PreferencesUtil
- `setDebugEnabled()` 同时修改内存标志 + hilog 全局级别
