# NekoShare 功能性 Bug 清单

> **用途**: 记录项目中已发现的功能性 bug，供修复时参考。
> **维护规则**: bug 修复后标记为已修复，新发现的 bug 追加到末尾。

---

## BUG-01: 加密传输设置在应用重启后不生效（严重） ✅ 已修复

**严重程度**: 🔴 严重  
**文件**: `entry/src/main/ets/service/AppService.ets` 第 34 行 + 第 65-68 行  
**关联文件**: `MainPage.ets` / `MainTabFloating.ets`

**现象**: 用户在设置中关闭"加密传输"后，下次启动应用时服务器仍以 HTTPS 启动，忽略用户保存的偏好。

**根因**: `AppService.ets` 中模块级变量 `httpsEnabled` 初始值硬编码为 `true`（第 34 行），而 `initAppService()` 函数（第 65-68 行）仅存储 context 和调用 `refreshDeviceInfo()`，**从未从 Preferences 读取 `encryptedTransfer` 来同步 `httpsEnabled`**。

```typescript
// 第 34 行: 硬编码 true
let httpsEnabled = true;

// 第 65-68 行: 初始化时未读取偏好
export function initAppService(context: common.UIAbilityContext): void {
  appContext = context;
  refreshDeviceInfo();  // 没有读取 encryptedTransfer 偏好
}
```

而在 `MainPage.ets` / `MainTabFloating.ets` 的 `aboutToAppear()` 中，虽然读取了偏好写入 `AppStorage`（第 93-94 行），但 **从未调用 `setHttpsEnabled()` 同步到 AppService 的模块变量**：

```typescript
// MainPage.ets 第 93-107 行
let encryptedTransfer: boolean = preferencesUtil.getBoolean('encryptedTransfer', true);
AppStorage.setOrCreate('encryptedTransfer', encryptedTransfer);
// ❌ 缺少: setHttpsEnabled(encryptedTransfer);

AppStorage.setOrCreate('serverReady', false);
initAppService(context);
startLocalServer().then(() => { ... });  // 使用的是 httpsEnabled=true
```

**影响**: 关闭加密传输后重启应用，服务器仍以 HTTPS 启动，无法与 HTTP 设备通信。

**修复**: 在 `initAppService()` 中增加 `httpsEnabled = preferencesUtil.getBoolean('encryptedTransfer', true);`，确保启动服务器前从偏好读取加密设置。

---

## BUG-02: 分享链接始终使用 HTTP，忽略 HTTPS 设置（中等）

**严重程度**: 🟡 中等  
**文件**: `entry/src/main/ets/service/AppService.ets` 第 220 行

**现象**: 即使应用启用了加密传输（HTTPS），通过"分享链接"功能生成的 URL 仍然是 `http://`，而非 `https://`。

**根因**: `createShareLink()` 函数中，链接 URL 协议硬编码为 `http://`：

```typescript
// 第 220 行
shareLinkInfo = 'http://' + localIp + ':' + sharePort;
```

**影响**: 
- HTTPS 模式下，生成的链接在浏览器中打开会因协议不匹配而无法连接
- 安全性降级：用户以为使用加密传输，实际分享链接走的是明文 HTTP

**修复建议**: 改为 `shareLinkInfo = (httpsEnabled ? 'https' : 'http') + '://' + localIp + ':' + sharePort;`

---

## BUG-03: 文本发送成功后页面一闪而过，用户看不到完成状态（中等）

**严重程度**: 🟡 中等  
**文件**: `entry/src/main/ets/pages/TransferPage.ets` 第 378-392 行

**现象**: 发送文本（`isTextSend=true`）成功后，TransferPage 立即调用 `router.back()` 返回主页，用户完全看不到"发送成功"的界面。而普通文件发送成功后会通过 `scheduleDismiss()` 延迟 2 秒再返回。

**根因**: `isTextSend` 路径在成功和失败后都直接调用 `router.back()`，没有使用 `scheduleDismiss()` 给用户展示结果的时间：

```typescript
// 第 378-392 行 (isTextSend 成功路径)
if (result.success) {
  this.progressPercent = 100;
  this.transferState = TransferState.Completed;
  markSendCompleted();
} else {
  this.transferState = TransferState.Failed;
  this.errorMessage = result.error || '发送失败';
}
// ❌ 成功和失败都直接返回，不给用户看到结果
if (!this.dismissed) {
  this.dismissed = true;
  router.back();
}
return;
```

对比普通文件发送路径（第 403-408 行）：
```typescript
// 普通文件发送成功，有 2 秒延迟
if (result.success) {
  this.progressPercent = 100;
  this.transferState = TransferState.Completed;
  markSendCompleted();
  this.scheduleDismiss();  // ✅ 延迟 2 秒再返回
}
```

**影响**: 
- 成功：用户看不到发送完成的确认，体验突兀
- 失败：错误消息设置后页面瞬间消失，用户不知道发送失败的原因

**修复建议**: 成功时使用 `scheduleDismiss()`，失败时不自动返回（让用户手动点击"返回"按钮）。

---

## BUG-04: 接收进度更新未验证 sessionId，存在跨会话干扰风险（中等）

**严重程度**: 🟡 中等  
**文件**: `entry/src/main/ets/pages/TransferPage.ets` 第 196-221 行

**现象**: 当同时存在多个接收会话（例如一个通过 TransferPage 展示，另一个自动接收），其他会话的完成/取消事件会错误地标记当前页面为完成/取消。

**根因**: `updateProgress()` 方法中：

1. **`recvTransferCompleted` 非文本场景（第 210-213 行）**：不验证 sessionId，任何会话完成都会标记当前页面为完成：
```typescript
// 第 210-213 行: ❌ 没有 sessionId 校验
this.progressPercent = 100;
this.transferState = TransferState.Completed;
this.recvTransferCompleted = '';
this.scheduleDismiss();
```

2. **`recvTransferCancelled`（第 216-221 行）**：完全不做 sessionId 校验：
```typescript
// 第 216-221 行: ❌ 没有任何 sessionId 校验
if (!this.isSend && this.recvTransferCancelled.length > 0) {
  this.transferState = TransferState.Failed;
  this.recvTransferCancelled = '';
  this.scheduleDismiss();
  return;
}
```

**注意**: `recvTextMessage` 的处理（第 200-208 行）是正确的，它会验证 `msg['sessionId'] === this.sessionId`。

**影响**: 多个并发传输时，一个会话完成可能导致另一个正在进行的会话错误显示为完成或取消。

**修复建议**: 在非文本的 `recvTransferCompleted` 和 `recvTransferCancelled` 处理中增加 `this.sessionId` 校验：
```typescript
if (!this.isSend && this.recvTransferCompleted.length > 0) {
  if (this.recvTransferCompleted !== this.sessionId) {
    return; // 不是当前会话的事件，忽略
  }
  // ... 处理完成逻辑
}
```

---

## BUG-05: 接收端进度统计未按 sessionId 过滤，多会话时进度不准（中等）

**严重程度**: 🟡 中等  
**文件**: `entry/src/main/ets/pages/TransferPage.ets` 第 223-251 行

**现象**: TransferPage 接收模式下，进度条统计的是所有接收会话的总进度，而非当前会话的进度。

**根因**: `updateProgress()` 中，接收端（`!this.isSend`）统计进度时，累加了所有 `activeProgress` 中非 share 类型的条目，没有按 `this.sessionId` 过滤：

```typescript
// 第 235-237 行: ❌ 接收端累加了所有会话的进度
} else if (!this.isSend) {
  totalBytes = totalBytes + p.totalBytes;
  sentBytes = sentBytes + p.bytesSent;
}
```

**影响**: 如果同时有多个接收会话，进度条显示的是所有会话的综合进度，不是当前会话的真实进度。

**修复建议**: 增加 sessionId 过滤：
```typescript
} else if (!this.isSend && p.sessionId === this.sessionId) {
  totalBytes = totalBytes + p.totalBytes;
  sentBytes = sentBytes + p.bytesSent;
}
```

---

## BUG-06: 自动接收文件时 exportSessionFiles 阻塞 UI 线程（中等）

**严重程度**: 🟡 中等  
**文件**: `entry/src/main/ets/service/AppService.ets` 第 701-753 行

**现象**: 自动接收模式下，文件接收完成后调用 `exportSessionFiles()` 弹出系统保存对话框，此函数是 `async` 但在 `doPollProgress()` 同步轮询中被调用时未 `await`，可能导致时序问题。

**根因**: `doPollProgress()` 是同步函数（由 `setInterval` 调用），在其中调用了 `exportSessionFiles()`（异步函数）但未 await：

```typescript
// 第 684-686 行
} else {
  exportSessionFiles(sessionId);  // ❌ async 函数未 await
}
```

**影响**: 
- 文件保存对话框可能在非预期时机弹出
- 如果多个文件同时完成，可能同时弹出多个保存对话框
- 异常未被捕获

**修复建议**: 将 `doPollProgress` 改为 async，或使用 `setTimeout` 延迟调用 `exportSessionFiles``。

---

## BUG-07: prepareSendFiles 中文件句柄泄漏（中等）

**严重程度**: 🟡 中等  
**文件**: `entry/src/main/ets/service/AppService.ets` 第 940-943 行

**现象**: `prepareSendFiles()` 中，如果 `copyFileSync` 或 `statSync` 抛出异常，`srcFile` 不会被关闭。

**根因**: 文件打开后，`closeSync(srcFile)` 在 copy 和 stat 之后才调用，如果中间步骤抛出异常则不会执行：

```typescript
// 第 940-943 行
let srcFile = fs.openSync(uri, fs.OpenMode.READ_ONLY);
fs.copyFileSync(srcFile.fd, destPath);  // 如果这里抛异常...
let stat = fs.statSync(destPath);       // 或这里抛异常...
fs.closeSync(srcFile);                  // ❌ 不会被执行
```

**影响**: 文件描述符泄漏，长期运行可能导致资源耗尽。

**修复建议**: 使用 try-finally 确保关闭：
```typescript
let srcFile = fs.openSync(uri, fs.OpenMode.READ_ONLY);
try {
  fs.copyFileSync(srcFile.fd, destPath);
  let stat = fs.statSync(destPath);
  // ...
} finally {
  fs.closeSync(srcFile);
}
```

---

## BUG-08: `isTextSend` 判断逻辑有误，非纯文本文件会被错误标记（中等）

**严重程度**: 🟡 中等  
**文件**: `entry/src/main/ets/components/SendContent.ets` 第 251-256 行 + `TransferPage.ets` 第 367 行

**现象**: 当用户选择多个文件，其中包含一个文本文件和非文本文件时，如果文本文件恰好排在前面，`isTextSend` 可能被错误设为 `true`（取决于文件顺序），导致使用简化的发送界面。

**根因**: `SendContent.sendToSelectedDevice()` 中判断 `allText` 的逻辑仅检查 `fileType !== 'text/plain'`，但这是正确的。然而 `isTextSend` 的实际影响是被用来选择不同的 UI 路径和完成行为（BUG-03），这导致混合文件场景下的行为不一致。

更深层的 bug：**`isTextSend` 的设计意图应该是"仅发送文本内容（剪贴板/手动输入）"，但判断依据是"所有文件的 fileType 都是 text/plain"**。如果用户通过文件选择器选了一个 `.txt` 文件，也会走 `isTextSend` 路径，触发 BUG-03 的一闪而过问题。

**影响**: 选择 `.txt` 文件发送时会一闪而过，与选择其他类型文件的体验不一致。

**修复建议**: `isTextSend` 应仅在用户通过 TextSendDialog 或剪贴板发送时为 true，不应基于文件类型判断。可通过增加一个来源标记（如 `isManualTextInput`）来区分。

---

## BUG-09: 多处硬编码中文字符串，破坏国际化（低）

**严重程度**: 🟢 低（功能性正确，但破坏 i18n）  
**涉及文件**: 多个

**详情**:

| 文件 | 行号 | 硬编码内容 | 应使用的资源键 |
|------|------|-----------|--------------|
| `SettingsContent.ets` | 57 | `'设备名称'` | `$r('app.string.input_alias_title')` |
| `SettingsContent.ets` | 58 | `'请输入设备名称'` | `$r('app.string.input_alias_placeholder')` |
| `SettingsContent.ets` | 80 | `'设备型号'` | `$r('app.string.input_model_title')` |
| `SettingsContent.ets` | 81 | `'请输入设备型号'` | `$r('app.string.input_model_placeholder')` |
| `SettingsContent.ets` | 134 | `'通用'` | 需新增资源键 |
| `SettingsContent.ets` | 251 | `'网络'` | 需新增资源键 |
| `SettingsContent.ets` | 258 | `'加密传输'` | `$r('app.string.encrypted_transfer')` |
| `SettingsContent.ets` | 290 | `'设备名称'` | `$r('app.string.input_alias_title')` |
| `SettingsContent.ets` | 315 | `'设备类型'` | `$r('app.string.select_device_type_title')` |
| `SettingsContent.ets` | 347 | `'设备型号'` | `$r('app.string.input_model_title')` |
| `SettingsContent.ets` | 388 | `'关于'` | `$r('app.string.about_title')` |
| `MainPage.ets` | 52 | `'接收完成'` | 需新增资源键 |
| `MainPage.ets` | 53 | `'来自 ... 的文件已接收完成'` | 需新增资源键 |
| `MainPage.ets` | 74 | `'发送已取消'` | 需新增资源键 |
| `MainPage.ets` | 75 | `'来自 ... 的文件传输已被对方取消'` | 需新增资源键 |
| `MainPage.ets` | 359 | `Button('确定')` | `$r('app.string.dialog_confirm')` |
| `MainTabFloating.ets` | 55 | `'接收完成'` | 同上 |
| `MainTabFloating.ets` | 56 | `'来自 ... 的文件已接收完成'` | 同上 |
| `MainTabFloating.ets` | 77 | `'发送已取消'` | 同上 |
| `MainTabFloating.ets` | 78 | `'来自 ... 的文件传输已被对方取消'` | 同上 |
| `MainTabFloating.ets` | 453 | `Button('确定')` | `$r('app.string.dialog_confirm')` |
| `AppService.ets` | 787 | 中文错误消息 | 需新增资源键 |
| `AppService.ets` | 837 | `'发送失败: '` | 需新增资源键 |
| `AppService.ets` | 846 | `'发送异常: '` | 需新增资源键 |
| `TransferPage.ets` | 836 | `'Open Link'` | `$r('app.string.open_link')` |
| `CompletionNotifyPage.ets` | 35 | `'发送已取消'` / `'接收完成'` | 需新增资源键 |
| `CompletionNotifyPage.ets` | 41 | `'来自 ... 的文件...'` | 需新增资源键 |
| `CompletionNotifyPage.ets` | 48 | `Button('确定')` | `$r('app.string.dialog_confirm')` |
| `DeviceTypePickerDialog.ets` | 12 | `'选择设备类型'` | `$r('app.string.select_device_type_title')` |
| `InputDialog.ets` | 7 | `'确定'` | `$r('app.string.dialog_confirm')` |
| `InputDialog.ets` | 8 | `'取消'` | `$r('app.string.dialog_cancel')` |

**影响**: 英文环境下这些文字仍然显示为中文，无法正常使用。

---

## BUG-10: `CompletionNotifyPage` 实际未被使用，但存在硬编码中文（低）

**严重程度**: 🟢 低  
**文件**: `entry/src/main/ets/pages/CompletionNotifyPage.ets`

**现象**: `CompletionNotifyPage` 已注册在 `main_pages.json` 中，但项目中没有任何地方通过 `router.pushUrl` 导航到该页面。主页面使用内联 overlay 弹窗来显示完成通知，这个页面是遗留代码。

**影响**: 无直接影响，但增加维护负担和包体积。

**修复建议**: 确认后移除，或改为主页面完成通知的正式实现。

---

## BUG-11: 普通文件发送失败时页面不自动返回，但也没有"返回"按钮提示（低）

**严重程度**: 🟢 低  
**文件**: `entry/src/main/ets/pages/TransferPage.ets` 第 409-411 行 + 第 1009-1028 行

**现象**: 普通文件发送失败时（`transferState = Failed`），代码设置了 `errorMessage` 但没有调用 `scheduleDismiss()` 也没有 `router.back()`。此时 UI 上显示"返回"按钮（第 1010-1027 行），需要用户手动点击。

这本身是合理的——让用户看到错误信息。但与文本发送路径（BUG-03）的行为不一致：文本发送失败会立即 `router.back()`，不让用户看到错误。

**影响**: 行为不一致，可能造成用户困惑。

---

## BUG-12: `send/` 临时目录文件不清理（低）

**严重程度**: 🟢 低  
**文件**: `entry/src/main/ets/service/AppService.ets` 第 926 行 + `SendContent.ets` 第 133 行

**现象**: `prepareSendFiles()` 将源文件复制到 `filesDir/send/` 目录，`SendContent.stageTextFile()` 也在同一目录创建文本文件，但发送完成后从未清理这些临时文件。

**影响**: 随着使用时间增长，`send/` 目录会积累大量临时文件，占用存储空间。

**修复建议**: 发送完成（或失败）后清理 `send/` 目录中的临时文件。

---

## BUG-13: `doPollProgress` 中 `completedFileIds` 等会话状态永不清理（低）

**严重程度**: 🟢 低  
**文件**: `entry/src/main/ets/service/AppService.ets` 第 59-63 行

**现象**: 以下模块级 Record 对象在会话完成后永不清理：
- `sessionTotalFiles`
- `sessionCompletedCount`
- `sessionExported`
- `sessionFileMap`
- `completedFileIds`

**影响**: 长时间运行后这些对象会持续增长，占用内存。虽然单次传输的数据量很小，但在持续运行场景下可能成为问题。

**修复建议**: 在会话完成后（`exportSessionFiles` 之后）清理对应的 key。

---

## BUG-14: 接收端完成时 overlay 弹窗的"确定"按钮背景色在深色模式下是白色（低）

**严重程度**: 🟢 低  
**文件**: `entry/src/main/ets/pages/MainPage.ets` 第 375 行 / `MainTabFloating.ets` 第 469 行

**现象**: 接收完成 overlay 弹窗的 `backgroundColor` 硬编码为 `Color.White`，在深色模式下显得刺眼。

```typescript
.backgroundColor(Color.White)  // ❌ 深色模式下不协调
```

**修复建议**: 改为 `$r('app.color.card_background')`，适配深色模式。

---

## 变更记录

| 日期 | 变更 |
|------|------|
| 2026-08-08 | 初始创建，记录 BUG-01 到 BUG-14 |
