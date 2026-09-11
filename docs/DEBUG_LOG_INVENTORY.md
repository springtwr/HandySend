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
| GENERAL | 0x0000 | AppService、EntryAbility、EntryBackupAbility、DialogService、ReceiveHistoryService、NativeBridge、HttpLogsViewModel |
| DISCOVERY | 0x0001 | DiscoveryRepository、DeviceRepository、MainTabViewModel |
| TRANSFER | 0x0002 | SendRepository、ReceiveRepository、TransferViewModel、TransferPage、SendViewModel、SendContent、WebShareRepository、ChecksumRepository、GallerySaveService、VideoThumbnailUtil |
| NETWORK | 0x0003 | AppCore、NetworkSettingsSection |
| SERVER | 0x0004 | ServerRepository |
| SETTINGS | 0x0005 | SettingsRepository、PreferencesUtil、FavoritesService、SettingsViewModel |
| MTA | 0x0006 | service/mta/*、MtaRepository、Mta*ViewModel |

## 日志级别规则（四级）

| 级别 | 适用 |
|------|------|
| debug | 诊断/状态细节/逐帧进度/no-op 跳过/重试细节 |
| info | 关键流程节点（启动、连接、请求接受、完成、取消、设置变更生效） |
| warn | 可恢复告警/无效操作/降级（能力未开启、资源清理失败、重复请求被忽略、注册/反注册失败） |
| error | 真正失败/异常（解析/连接/IO/保存失败、启动异常） |
| fatal | 致命不可恢复（保留） |

Release（debug 关）下 debug 级被抑制，仅 info 及以上输出。

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
| `HandySend:HttpLogsViewModel` | `[日志页]` | HttpLogsViewModel.ets | 日志导出保存失败 |
| `HandySend:MainTab` | `[主页]` | MainTabViewModel.ets | Tab 切换、分享 URI 消费 |
| `HandySend:DiscoveryRepository` | `[发现]` | DiscoveryRepository.ets | 设备发现事件、扫描/连接/注册、Rust 日志归并 |
| `HandySend:DeviceRepository` | `[设备]` | DeviceRepository.ets | 设备身份刷新 |
| `HandySend:SendRepository` | `[发送]` | SendRepository.ets | 发送流程（sendToDevice/Multi、文件 staging、会话管理）、Rust 日志归并 |
| `HandySend:ReceiveRepository` | `[接收]` | ReceiveRepository.ets | 接收流程（pending requests、auto-accept、会话完成/取消） |
| `HandySend:TransferViewModel` | `[传输]` | TransferViewModel.ets | 传输进度 UI 状态管理 |
| `HandySend:TransferPage` | `[传输页]` | TransferPage.ets | 传输页面生命周期 |
| `HandySend:SendViewModel` | `[发送页]` | SendViewModel.ets | 发送状态管理 |
| `HandySend:SendContent` | `[发送内容]` | SendContent.ets | 发送内容组件（文件选择、剪贴板） |
| `HandySend:WebShareRepository` | `[网页分享]` | WebShareRepository.ets | Web 分享链接创建/停止、上传/下载事件 |
| `HandySend:ChecksumRepository` | `[校验]` | ChecksumRepository.ets | 校验和计算/取消 |
| `HandySend:GallerySaveService` | `[相册]` | GallerySaveService.ets | 相册保存（SaveButton 授权、MediaAssetChangeRequest） |
| `HandySend:VideoThumbnail` | `[缩略图]` | VideoThumbnailUtil.ets | 视频缩略图生成 |
| `HandySend:NetworkSettings` | `[网络设置]` | NetworkSettingsSection.ets | 网络设置分组（接口刷新、警告横幅） |
| `HandySend:SettingsViewModel` | `[设置页]` | SettingsViewModel.ets | 设置状态管理 |
| `HandySend:AppCore` | `[网络]` | AppCore.ets | 网卡检测、事件总线 |
| `HandySend:ServerRepository` | `[服务端]` | ServerRepository.ets | 服务器生命周期（start/stop/restart/reload） |
| `HandySend:SettingsRepository` | `[设置]` | SettingsRepository.ets | 设置读写、持久化 |
| `HandySend:PreferencesUtil` | `[偏好]` | PreferencesUtil.ets | 偏好存储操作 |
| `HandySend:FavoritesService` | `[收藏]` | FavoritesService.ets | 收藏设备 CRUD |
| `HandySend:MtaRepository` | `[互传]` | repository/MtaRepository.ets | MTA 发现与接收服务启停门面 |
| `HandySend:MtaSend` | `[互传发送]` | service/mta/MtaSendService.ets | MTA 发送编排、Rust 日志归并 |
| `HandySend:MtaReceive` | `[互传接收]` | service/mta/MtaReceiveService.ets | MTA 接收编排（广播/GATT/P2P/WS/下载状态机） |
| `HandySend:MtaTransfer` | `[互传传输]` | service/mta/MtaTransferClient.ets | MTA WS 传输客户端（握手、消息、下载） |
| `HandySend:MtaBleClient` | `[互传蓝牙]` | service/mta/MtaBleClient.ets | BLE 扫描与 GATT Client |
| `HandySend:MtaBleReceiver` | `[互传蓝牙]` | service/mta/MtaBleReceiver.ets | BLE 广播与 GATT Server |
| `HandySend:MtaP2pConnector` | `[互传P2P]` | service/mta/MtaP2pConnector.ets | P2P 连接、GO IP、网络绑定 |
| `HandySend:MtaP2pGroup` | `[互传P2P]` | service/mta/MtaP2pGroup.ets | WiFi Direct 建组/删组 |
| `HandySend:MtaBleVerify` | `[互传蓝牙验证]` | service/mta/BleVerifyService.ets | BLE 验证服务（广播/GATT/扫描/权限） |
| `HandySend:MtaP2pVerify` | `[互传P2P验证]` | service/mta/P2pVerifyService.ets | P2P 验证服务（建组/直连/发现/HTTP） |
| `HandySend:MtaSendVM` | `[互传发送]` | MtaSendViewModel.ets | MTA 发送页视图模型 |
| `HandySend:MtaReceiveVM` | `[互传接收]` | MtaReceiveViewModel.ets | MTA 接收页视图模型 |
| `HandySend:MtaTransferVM` | `[互传传输]` | MtaTransferViewModel.ets | MTA 传输页视图模型 |
| `HandySend:MtaBleVerifyVM` | `[互传蓝牙验证]` | MtaBleVerifyViewModel.ets | MTA BLE 验证页视图模型 |
| `HandySend:MtaP2pVerifyVM` | `[互传P2P验证]` | MtaP2pVerifyViewModel.ets | MTA P2P 验证页视图模型 |

> 同一标签可对应多个协作模块（如 `[互传蓝牙]`、`[互传P2P]`）；标签标识业务子系统，不要求全局唯一。

## MTA 子系统正文区分

MTA 各子系统（如 GATT、P2P、WS、下载、暂存）以「子系统: 内容」形式保留在正文中，如 `[互传接收] GATT: sendResponse(写) 失败: ...`。

## Rust 侧日志

- Rust `log::*` 调用按四级语义校正；调试标签（`[DBG-*]` 等）已移除，由正文自述。
- 缓冲元素格式为 `level|message`（`level ∈ error/warn/info/debug/trace`）；ArkTS 侧按首个 `|` 解析，`trace` 归一到 `debug`，无分隔符按 `info` 兜底。
- ArkTS 消费方统一以 `Rust: ` 作为正文前缀（如 `[发现] Rust: ...`），经带级别轮询接口读取，保留原始级别。

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
- **Release 版本**：默认 INFO 级别，Settings 页 Toggle 可临时开启 DEBUG，重启恢复
- 不持久化，不依赖 PreferencesUtil
- `setDebugEnabled()` 同时修改内存标志 + hilog 全局级别
