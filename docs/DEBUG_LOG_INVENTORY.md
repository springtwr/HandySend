# Debug Log Inventory

HandySend 使用统一日志模块 `Logger.ets` 封装 hilog，按业务域（domain）细分，支持结构化上下文。

## 日志过滤方式

```bash
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
| GENERAL | 0x0000 | AppService, EntryAbility, DialogService, ReceiveHistoryService, EntryBackupAbility |
| DISCOVERY | 0x0001 | DiscoveryRepository, DeviceRepository, MainTabViewModel |
| TRANSFER | 0x0002 | SendRepository, ReceiveRepository, TransferViewModel, TransferPage, SendViewModel, SendContent, WebShareRepository, ChecksumRepository |
| NETWORK | 0x0003 | AppCore, NetworkSettingsSection, SettingsViewModel |
| SERVER | 0x0004 | ServerRepository |
| SETTINGS | 0x0005 | SettingsRepository, PreferencesUtil, FavoritesService |
| MTA | 0x0006 | service/mta/*、MtaRepository、Mta*ViewModel |

## ArkTS 侧（Logger 模块）

每个模块在文件顶层创建 logger 实例：`const logger = getLogger(LogDomains.XXX, 'HandySend:模块名')`

| TAG | 模块 | 关键日志点 |
|-----|------|-----------|
| `HandySend:AppService` | AppService.ets | 初始化、事件分发（按 type 分发到各 Repository）、native 版本校验 |
| `HandySend:EntryAbility` | EntryAbility.ets | Ability 生命周期（onCreate/onWindowStageCreate/onForeground/onBackground/onDestroy） |
| `HandySend:EntryBackup` | EntryBackupAbility.ets | 备份生命周期 |
| `HandySend:DialogService` | DialogService.ets | 弹窗操作 |
| `HandySend:ReceiveHistoryService` | ReceiveHistoryService.ets | 历史记录添加/清空 |
| `HandySend:MainTab` | MainTabViewModel.ets | Tab 切换、分享 URI 消费 |
| `HandySend:DiscoveryRepository` | DiscoveryRepository.ets | 设备发现事件、扫描/连接/注册 |
| `HandySend:DeviceRepository` | DeviceRepository.ets | 设备身份刷新 |
| `HandySend:SendRepository` | SendRepository.ets | 发送流程（sendToDevice/Multi、文件 staging、会话管理） |
| `HandySend:ReceiveRepository` | ReceiveRepository.ets | 接收流程（pending requests、auto-accept、会话完成/取消） |
| `HandySend:TransferViewModel` | TransferViewModel.ets | 传输进度 UI 状态管理 |
| `HandySend:TransferPage` | TransferPage.ets | 传输页面生命周期 |
| `HandySend:NetworkSettings` | NetworkSettingsSection.ets | 网络设置分组（接口刷新、警告横幅） |
| `HandySend:SettingsViewModel` | SettingsViewModel.ets | 设置状态管理 |
| `HandySend:GallerySaveService` | GallerySaveService.ets | 相册保存（SaveButton 授权、MediaAssetChangeRequest） |
| `HandySend:VideoThumbnail` | VideoThumbnailUtil.ets | 视频缩略图生成 |
| `HandySend:SendViewModel` | SendViewModel.ets | 发送状态管理 |
| `HandySend:SendContent` | SendContent.ets | 发送内容组件（文件选择、剪贴板） |
| `HandySend:WebShareRepository` | WebShareRepository.ets | Web 分享链接创建/停止、上传/下载事件 |
| `HandySend:ChecksumRepository` | ChecksumRepository.ets | 校验和计算/取消、文件下载/上传 |
| `HandySend:AppCore` | AppCore.ets | 网卡检测、事件总线 |
| `HandySend:ServerRepository` | ServerRepository.ets | 服务器生命周期（start/stop/restart/reload） |
| `HandySend:SettingsRepository` | SettingsRepository.ets | 设置读写、持久化 |
| `HandySend:PreferencesUtil` | PreferencesUtil.ets | 偏好存储操作 |
| `HandySend:FavoritesService` | FavoritesService.ets | 收藏设备 CRUD |
| `HandySend:MtaSend` | service/mta/MtaSendService.ets | MTA 发送编排（扫描/建组/服务器/传输状态机、Rust 日志归并） |
| `HandySend:MtaReceive` | service/mta/MtaReceiveService.ets | MTA 接收编排（广播/GATT/P2P/WS/下载状态机） |
| `HandySend:MtaTransfer` | service/mta/MtaTransferClient.ets | MTA WS 传输客户端（握手、消息、下载） |
| `HandySend:MtaP2pConnector` | service/mta/MtaP2pConnector.ets | P2P 连接、GO IP、网络绑定 |
| `HandySend:MtaP2pGroup` | service/mta/MtaP2pGroup.ets | WiFi Direct 建组/删组 |
| `HandySend:MtaBleClient` | service/mta/MtaBleClient.ets | BLE 扫描与 GATT Client |
| `HandySend:MtaBleReceiver` | service/mta/MtaBleReceiver.ets | BLE 广播与 GATT Server |
| `HandySend:MtaBleVerify` | service/mta/BleVerifyService.ets | BLE 验证服务（广播/GATT/扫描/权限） |
| `HandySend:MtaP2pVerify` | service/mta/P2pVerifyService.ets | P2P 验证服务（建组/直连/发现/HTTP） |
| `HandySend:MtaRepository` | repository/MtaRepository.ets | MTA 发现与接收服务启停门面 |
| `HandySend:MtaSendVM` | MtaSendViewModel.ets | MTA 发送页视图模型 |
| `HandySend:MtaReceiveVM` | MtaReceiveViewModel.ets | MTA 接收页视图模型 |
| `HandySend:MtaTransferVM` | MtaTransferViewModel.ets | MTA 传输页视图模型 |
| `HandySend:MtaBleVerifyVM` | MtaBleVerifyViewModel.ets | MTA BLE 验证页视图模型 |
| `HandySend:MtaP2pVerifyVM` | MtaP2pVerifyViewModel.ets | MTA P2P 验证页视图模型 |

## MTA 日志级别与格式约定

- **级别 token**：`common/LogLevels.ets` 为唯一事实源，取规范五级英文小写 `debug`/`info`/`warn`/`error`/`fatal`；页面与导出直接展示 token，不做二次翻译。
- **语义映射**：诊断/状态细节 → `debug`；关键流程节点 → `info`；可恢复告警（含注册/反注册失败、资源清理失败）→ `warn`；流程失败/异常 → `error`。
- **hilog 消息格式**：`<source>: <content>`，经 `logger.log(level, msg)` 出口按 token 分发到对应 hilog 级别。
- **条目/导出格式**：`<time> [<level>] <source>: <content>`（`<level>` 为规范 token）。
- **Rust 日志桥接**：缓冲元素格式为 `level|message`（`level ∈ error/warn/info/debug/trace`）；ArkTS 侧按首个 `|` 解析，`trace` 归一到 `debug`，无分隔符按 `info` 兜底。MTA 侧经带级别轮询接口读取，非 MTA 消费方剥离前缀后按 debug 输出。

## 结构化日志上下文（LogContext）

传输相关日志可附加结构化前缀，格式 `[sid=xxx dir=send alias=Phone]`：

| 字段 | 说明 | 截断规则 |
|------|------|----------|
| sessionId | 会话 ID | 取前 8 字符 |
| fileId | 文件 ID | 不截断 |
| direction | 传输方向（send/recv/share） | — |
| targetAlias | 目标设备别名 | — |
| protocol | 协议（http/https） | — |

## Debug 开关

- **Debug 版本**：默认 DEBUG 级别，全量输出
- **Release 版本**：默认 INFO 级别，Settings 页 Toggle 可临时开启 DEBUG，重启恢复
- 不持久化，不依赖 PreferencesUtil
- `setDebugEnabled()` 同时修改内存标志 + hilog 全局级别
