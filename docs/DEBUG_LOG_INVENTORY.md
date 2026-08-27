# Debug Log Inventory

HandySend 使用统一日志模块 `Logger.ets` 封装 hilog，按业务域（domain）细分，支持结构化上下文。

## 日志过滤方式

```bash
# 按模块 TAG 过滤
hdc shell hilog -t HandySend:SendRepository

# 按业务域过滤（domain 十六进制）
hdc shell hilog -D 0x0002    # TRANSFER 域

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
