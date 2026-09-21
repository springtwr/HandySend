# 类型定义

> 应用层与 NAPI 层的类型定义参考。

## 应用层 (model/Types.ets)

| 类型 | 说明 |
|------|------|
| `DiscoveredDevice` | 发现的设备（alias, ip, port, fingerprint, channels, lastSeen 等） |
| `DeviceChannel` | 设备通道（host, port, protocol） |
| `PendingRequest` | 待处理请求（sessionId, senderAlias, senderFingerprint, senderProtocol, senderIp, senderDeviceType, senderDeviceModel, files[]；sender* 设备信息来自 prepareUpload 事件，轮询兜底路径为空，由 MainTabViewModel 回退到发现反查） |
| `TransferProgress` | 传输进度（sessionId, fileId, bytesSent, totalBytes） |
| `SendFileItem` | 待发送文件（fileId, filePath, fileName, size） |
| `FavoriteDevice` | 收藏设备（id, fingerprint, ip, port, alias, customAlias, lastProtocol；ip/port 与 deviceModel/deviceType/version 来自收藏时的发现快照，持久化保存并随设备在线被发现同步刷新——别名受自定义保护，其余字段在快照有效时才覆盖） |
| `ReceiveHistoryEntry` | 接收历史条目：**只承载路径与元数据**（fileName / fileType / path / savedToGallery / isMessage / fileSize / senderAlias / timestamp）；`textContent` 字段保留以兼容旧数据但不再写入，读取时忽略（正文只存在于 `path` 指向的文件中） |
| `MediaFileInfo` | 媒体文件信息（filePath, fileName, fileType, isImage），供相册保存弹窗使用 |
| `GallerySaveResult` | 相册保存结果（successCount, failCount, errors） |
| `AutoConfirmMode` | 枚举：off / paired / on |
| `SendMode` | 枚举：single / multiple / link |
| `SendSessionStatus` | 发送会话状态枚举 |
| `SendSessionState` | 发送会话状态（sessionId, unifiedSessionId, targetIp, targetAlias, status, files[], hashedFileCount, totalFiles），供多目标每设备进度/状态展示；`unifiedSessionId` 为注册表统一会话标识，该会话的进度与终态一律经它归属 |
| `FileProgressStatus` | 逐文件状态枚举：waiting / transferring / completed / failed |
| `TransferFileDescriptor` | 传输页文件元数据（fileId, fileName, size, fileType），经 TransferPageParams 传入，驱动文件清单 |
| `TransferFileProgress` | 单文件 UI 进度（fileId, fileName, size, fileType, bytesSent, percent, status），驱动逐文件进度条 |

## NAPI 层 (model/NativeTypes.ets)

与 Rust `#[napi(object)]` 结构体一一对应：`NativeServerConfig`, `NativeServerHandle`, `NativeServerStatus`, `NativeTargetDevice`, `NativeTransferRequest`, `NativeTransferFileInfo`, `NativeFileToSend`, `NativeSendResult`, `NativeShareLinkInfo`, `NativeSecurityContext`, `NativeCancellationToken` 等。

discovery 相关类型：`NativeDiscoveryConfig`, `NativeDiscoveredDevice`, `NativeDeviceChannel`。

Web Share 事件类型：`NativeWebSendPrepareDownloadEvent`（webSendPrepareDownload 事件）、`NativeWebSendFileDownloadEvent`（webSendFileDownload 事件）。

桥接层事件类型（camelCase）定义在 `NativeTypes.ets`：`serverStarted` / `serverStopped` / `register` / `prepareUpload` / `prepareUploadAborted` / `cancelReceived` / `uploadProgress` / `sessionEnd` / `fileUpload` / `deviceFound` / `deviceLost` / `webSendPrepareDownload` / `webSendFileDownload` / `webSendSessionEnd` / `error`。取消通知使用 `cancelReceived` 事件。

MTA 事件类型（camelCase，载荷契约见 `docs/mta/MTA_PROTOCOL_AND_IMPLEMENTATION.md`）：`mtaServerStarted` / `mtaWsConnected` / `mtaVersionNegotiated` / `mtaSendRequestSent` / `mtaRejectSent` / `mtaDownloadStarted` / `mtaSendProgress` / `mtaSendCompleted` / `mtaSendPartial` / `mtaSendRejected` / `mtaSendFailed` / `mtaReceiveProgress`。
