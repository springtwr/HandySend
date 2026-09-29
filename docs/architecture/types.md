# 类型定义

> 应用层与 NAPI 层的类型定义参考。
>
> 主文档 `docs/ARCHITECTURE.md` §6 保留概述。

## 应用层 (model/Types.ets)

| 类型 | 说明 |
|------|------|
| `DiscoveredDevice` | 发现的设备（alias, ip, port, fingerprint, channels, lastSeen 等） |
| `DeviceChannel` | 设备通道（host, port, protocol） |
| `PendingRequest` | 待处理请求（sessionId, senderAlias, senderFingerprint, senderProtocol, senderIp, senderDeviceType, senderDeviceModel, files[]；来源见注 1） |
| `TransferProgress` | 传输进度（sessionId, fileId, bytesSent, totalBytes） |
| `SendFileItem` | 待发送文件（fileId, filePath, fileName, size） |
| `FavoriteDevice` | 收藏设备（id, fingerprint, ip, port, alias, customAlias, lastProtocol；快照与覆盖规则见注 2） |
| `ReceiveHistoryEntry` | 接收历史条目：**只承载路径与元数据**（fileName / fileType / path / savedToGallery / isMessage / fileSize / senderAlias / timestamp；其余语义见注 3） |
| `MediaFileInfo` | 媒体文件信息（filePath, fileName, fileType, isImage），供相册保存弹窗使用 |
| `GallerySaveResult` | 相册保存结果（successCount, failCount, errors） |
| `AutoConfirmMode` | 枚举：off / paired / on |
| `SendSessionStatus` | 发送会话状态枚举 |
| `SendSessionState` | 发送会话状态（sessionId, unifiedSessionId, targetIp, targetAlias, status, files[], hashedFileCount, totalFiles；用途与归属见注 4） |
| `TransferFileDescriptor` | 传输文件元数据（fileId, fileName, size, fileType），构建 MTA 发送请求（`MtaSendRequest.fileDescriptors`）时使用 |

> **注 1**：`PendingRequest` 的 `sender*` 设备信息来自 `prepareUpload` 事件，轮询兜底
> 路径为空，由 `MainTabViewModel` 回退到发现反查。
>
> **注 2**：`FavoriteDevice` 的 ip/port 与 deviceModel/deviceType/version 来自收藏时的
> 发现快照，持久化保存并随设备在线被发现同步刷新——别名受自定义保护，其余字段在
> 快照有效时才覆盖。
>
> **注 3**：`ReceiveHistoryEntry` 的 `textContent` 字段保留以兼容旧数据但不再写入，
> 读取时忽略（正文只存在于 `path` 指向的文件中）。`path` 是该条目可用性的唯一依据
> ——非空即对应磁盘上的真实文件（文本消息与用户经文件选择器选中的 `.txt`/`.md` 等
> 在此一视同仁，均不再有「消息无文件」语义），为空（旧数据/无磁盘文件）时展示层按
> 「不可用」降级。
>
> **注 4**：`SendSessionState` 供多目标每设备进度/状态展示；`unifiedSessionId` 为注册表
> 统一会话标识，该会话的进度与终态一律经它归属。

### 接收历史条目展示要素 (viewmodel/ReceiveHistoryItemViewModel.ets)

条目级 ViewModel 在原始条目之外补充运行期展示状态，供 `ReceiveHistoryPage` 的列表行与操作菜单使用：

| 成员 | 类型 | 语义 |
|------|------|------|
| `isTextEntry` | boolean（派生） | 文本类判定（经 `utils/MimeUtils.isTextFile` 唯一来源） |
| `canViewFullText` | boolean（派生） | 文本类且 `path` 非空且未超预览阈值：可查看全文 |
| `isPreviewOverLimit` | boolean（派生） | 文本类且 `path` 非空且超预览阈值：不产缩略预览，查看全文时明确提示文件过大 |
| `canCopyText` | boolean（派生） | 文本类且 `path` 非空：可复制文本（显式动作，不受预览阈值限制） |
| `canOpenContainingFolder` | boolean（派生） | `path` 非空：可打开所在目录（不再依据「消息」语义禁用） |
| `previewText` | string（`@Trace`） | 文本类条目的内容缩略预览（列表行出现时按需懒加载）；未读取 / 路径为空 / 文件缺失 / 非文本类 / 超阈值时为空串 |

- 文本类判定经 `utils/MimeUtils.isTextFile` 唯一来源；文本内容读取经 `utils/FileTextUtil.readTextOfLocation` 唯一入口（预览场景传入预览阈值作为读取上限），
  路径为空、超阈值或读取失败一律按「不可用 / 空内容」降级，不抛异常、不空白无响应。
- 类型图标区与媒体缩略（图片 URI / 视频缩略图）由公共组件 `components/FileEntryThumb` 承载，条目级 ViewModel 不再持有缩略状态。

## NAPI 层 (model/NativeTypes.ets)

与 Rust `#[napi(object)]` 结构体一一对应：`NativeServerConfig`, `NativeServerHandle`, `NativeServerStatus`, `NativeTargetDevice`, `NativeTransferRequest`,
`NativeTransferFileInfo`, `NativeFileToSend`, `NativeSendResult`, `NativeShareLinkInfo`, `NativeSecurityContext`, `NativeCancellationToken` 等。

discovery 相关类型：`NativeDiscoveryConfig`, `NativeDiscoveredDevice`, `NativeDeviceChannel`。

Web Share 事件类型：`NativeWebSendPrepareDownloadEvent`（webSendPrepareDownload 事件）、`NativeWebSendFileDownloadEvent`（webSendFileDownload 事件）。

桥接层事件类型（camelCase）定义在 `NativeTypes.ets`：`serverStarted` / `serverStopped` / `register` / `prepareUpload` / `prepareUploadAborted` / `cancelReceived` / `uploadProgress`
/ `sessionEnd` / `fileUpload` / `deviceFound` / `deviceLost` / `webSendPrepareDownload` / `webSendFileDownload` / `webSendSessionEnd` / `error`。取消通知使用 `cancelReceived` 事件。

MTA 事件类型（camelCase，载荷契约见 `docs/mta/MTA_PROTOCOL.md` 附录 A）：`mtaServerStarted` / `mtaWsConnected` / `mtaVersionNegotiated` / `mtaSendRequestSent`
/ `mtaRejectSent` / `mtaDownloadStarted` / `mtaSendProgress` / `mtaSendCompleted` / `mtaSendPartial` / `mtaSendRejected` / `mtaSendFailed` / `mtaReceiveProgress`。
