# NekoShare 项目架构文档

> **用途**: 本文件是项目架构的记忆文件，供 AI 助手和开发者快速了解项目整体结构，避免重复扫描整个项目。
> **维护规则**: 当项目结构、核心模块、页面路由、API 接口等发生变更时，必须同步更新本文件。

---

## 1. 项目概述

NekoShare 是基于鸿蒙原生（HarmonyOS NEXT）实现的 [LocalSend](https://github.com/localsend/localsend) 兼容客户端。通过 NAPI 桥接调用 Rust 编写的 LocalSend v2 协议核心库，在 HarmonyOS NEXT 上实现局域网内跨设备文件/剪贴板/文本传输。

| 属性 | 值 |
|------|------|
| Bundle Name | `com.nekoev.nekoshare` |
| 版本 | 1.0.0 (versionCode: 1000000) |
| Target SDK | 6.1.1(24) |
| Compatible SDK | 6.0.0(20) |
| 运行系统 | HarmonyOS NEXT |
| 许可证 | Apache License 2.0 |
| 设备类型 | Phone / Tablet / 2in1 |

---

## 2. 技术栈

| 层级 | 技术 |
|------|------|
| UI 框架 | ArkUI (ArkTS) |
| 通信协议 | LocalSend v2 (HTTP/HTTPS + mDNS/UDP 组播) |
| 原生桥接 | HarmonyOS NAPI |
| 协议核心 | Rust → `liblocalsend_native.so` |
| 构建工具 | Hvigor / DevEco Studio |
| 数据持久化 | Preferences (key-value) |
| 高端UI组件 | @kit.UIDesignKit (HdsTabs, SDK>=23) |

---

## 3. 目录结构

```
NekoShare/
├── AppScope/                          # 应用级资源
│   ├── app.json5                      # 应用配置
│   └── resources/base/                # 应用图标(layered_image)、字符串
├── entry/                             # 主模块（唯一模块）
│   ├── build-profile.json5            # 模块构建配置
│   ├── oh-package.json5               # 模块依赖（无第三方依赖）
│   ├── obfuscation-rules.txt
│   ├── hvigorfile.ts
│   ├── src/main/
│   │   ├── module.json5               # 模块配置（权限、Ability、skill）
│   │   ├── ets/
│   │   │   ├── entryability/
│   │   │   │   └── EntryAbility.ets   # 应用入口 Ability
│   │   │   ├── entrybackupability/
│   │   │   │   └── EntryBackupAbility.ets
│   │   │   ├── model/
│   │   │   │   ├── Types.ets          # 应用层类型定义
│   │   │   │   └── NativeTypes.ets    # NAPI 桥接层类型定义
│   │   │   ├── service/
│   │   │   │   ├── AppService.ets     # ★ 核心业务逻辑
│   │   │   │   ├── NativeBridge.ets   # NAPI 桥接封装
│   │   │   │   └── DiscoveryService.ets # 设备发现
│   │   │   ├── pages/
│   │   │   │   ├── MainPage.ets       # 标准主页面
│   │   │   │   ├── MainTabFloating.ets # 浮动标签主页面
│   │   │   │   ├── Index.ets          # 调试/测试页面
│   │   │   │   ├── TransferPage.ets   # 传输进度页面
│   │   │   │   ├── ShareLinkPage.ets  # 分享链接页面
│   │   │   │   ├── CompletionNotifyPage.ets # 完成通知
│   │   │   │   └── AboutPage.ets      # 关于页面
│   │   │   ├── components/
│   │   │   │   ├── SendContent.ets    # 发送组件
│   │   │   │   ├── ReceiveContent.ets # 接收组件
│   │   │   │   ├── SettingsContent.ets # 设置组件
│   │   │   │   ├── TextSendDialog.ets # 文本发送对话框
│   │   │   │   └── settings/
│   │   │   │       ├── SettingsTypes.ets
│   │   │   │       ├── InputDialog.ets
│   │   │   │       └── DeviceTypePickerDialog.ets
│   │   │   └── utils/
│   │   │       └── PreferencesUtil.ets # 偏好存储工具
│   │   ├── cpp/types/liblocalsend_native/
│   │   │   ├── index.d.ts             # Rust NAPI 类型定义
│   │   │   └── oh-package.json5
│   │   └── resources/
│   │       ├── base/                  # 基础资源
│   │       ├── dark/                  # 深色模式资源
│   │       └── zh_CN/                 # 中文本地化
│   └── build/                         # 构建产物（gitignore）
├── build-profile.json5                # 全局构建配置
├── oh-package.json5                   # 全局依赖
├── hvigor/                            # Hvigor 构建配置
├── hvigorfile.ts                      # Hvigor 入口
├── code-linter.json5                  # 代码检查配置
├── LICENSE                            # Apache 2.0
└── README.md                          # 项目说明
```

---

## 4. 核心模块详解

### 4.1 EntryAbility — 应用入口

**文件**: `entry/src/main/ets/entryability/EntryAbility.ets`

- 处理系统分享 Intent（`systemShare.getSharedData`）
- 支持 `ohos.want.action.sendData` / `sendMultipleData` 接收外部文件
- 根据设备 SDK 版本选择主页面:
  - API >= 23 → `pages/MainTabFloating`（HdsTabs）
  - API < 23 → `pages/MainPage`（标准 Tabs）
- 前台恢复时调用 `triggerRefresh()`
- 初始化 `PersistentStorage.persistProp('nekoshare_floating', true)`

### 4.2 AppService — 核心业务逻辑 ★

**文件**: `entry/src/main/ets/service/AppService.ets` (~1036行)

#### 关键常量

| 常量 | 值 | 说明 |
|------|------|------|
| DEFAULT_PORT | 53317 | LocalSend 默认端口 |
| POLL_INTERVAL_MS | 500 | 轮询间隔 |
| DEVICE_EXPIRY_MS | 120000 | 设备过期时间 (2分钟) |
| KEEPALIVE_INTERVAL_MS | 60000 | 保活/重扫间隔 (1分钟) |

#### 模块级状态变量

```
serverRunning, serverFingerprint, httpsEnabled,
shareLinkInfo, sharePort,
discoveredDevices[], pendingRequests[], activeProgress[], logs[],
pollTimer, keepaliveTimer,
alias, deviceModel, deviceType,
changeCallbacks[], requestDoNotDisturb[],
sessionTotalFiles, sessionCompletedCount, sessionExported, sessionFileMap, completedFileIds
```

#### 主要导出函数

| 函数 | 说明 |
|------|------|
| `initAppService(context)` | 初始化，设置应用上下文 |
| `startLocalServer()` | 启动 Rust 服务器 + 设备发现 + 轮询 |
| `stopLocalServer()` | 停止服务器 + 发现 + 轮询 |
| `reloadServerSettings()` | 热重载服务器（先停后启，失败则回滚） |
| `sendToDevice(device, files)` | 发送文件（含 HTTPS/HTTP 协议协商） |
| `respondToRequest(sessionId, accept)` | 响应接收请求 |
| `prepareSendFiles(uris)` | URI → 沙箱路径复制，返回 SendFileItem[] |
| `createShareLink(files)` / `stopShareLink()` | 分享链接管理 |
| `rescanDevices()` | UDP 广播 + HTTP 子网扫描 |
| `getDiscoveredDevices()` | 返回未过期设备列表 |
| `getActiveProgress()` | 返回当前传输进度 |
| `subscribe(callback)` / `unsubscribe(callback)` | 状态变更订阅 |
| `triggerRefresh()` | 触发状态刷新通知 |
| `processSharedUris(urisJson)` | 处理外部分享的 URI |

#### 协议协商逻辑

```
发送端 HTTPS + 接收端 HTTPS → HTTPS 传输
发送端 HTTPS + 接收端 HTTP  → 报错，不传输
发送端 HTTP  → HTTP 传输（忽略接收端协议）
```

#### 文件导出流程

接收完成后：
1. 纯文本 (`text/plain`, 单文件) → 直接读取内容 → 显示文本 → 删除临时文件
2. 其他文件 → `DocumentViewPicker.save()` → 用户选择保存目录 → copyFile → 删除临时文件

### 4.3 NativeBridge — NAPI 桥接封装

**文件**: `entry/src/main/ets/service/NativeBridge.ets` (~67行)

封装 Rust 原生库 `liblocalsend_native.so` 的所有导出函数，类型来自 `NativeTypes.ets`：

| 函数 | 返回类型 | 说明 |
|------|----------|------|
| `nativeCreateServer(config)` | `Promise<NativeServerHandle>` | 创建服务器 |
| `nativeStopServer()` | `Promise<void>` | 停止服务器 |
| `nativeGetServerStatus()` | `NativeServerStatus` | 获取服务器状态 |
| `nativePollPendingRequests()` | `Array<NativeTransferRequest>` | 轮询接收请求 |
| `nativePollProgress()` | `Array<NativeProgressInfo>` | 轮询接收进度 |
| `nativePollSendProgress()` | `Array<NativeProgressInfo>` | 轮询发送进度 |
| `nativePollShareProgress()` | `Array<NativeProgressInfo>` | 轮询分享进度 |
| `nativeRespondTransfer(sessionId, accept, fileIds)` | `Promise<void>` | 响应传输请求 |
| `nativeSendFiles(target, alias, files)` | `Promise<NativeSendResult>` | 发送文件 |
| `nativeCreateShareLink(files, alias)` | `Promise<NativeShareLinkInfo>` | 创建分享链接 |
| `nativeStopShareServer()` | `Promise<void>` | 停止分享服务器 |
| `nativeCancelTransfer(target, sessionId)` | `Promise<void>` | 取消远端传输 |
| `nativeCancelLocalSession(sessionId)` | `Promise<void>` | 取消本地会话 |
| `nativeGetCurrentSendSessionId()` | `string` | 获取当前发送会话ID |
| `nativeGetRecvDiag()` | `NativeRecvDiag` | 获取接收诊断 |
| `nativePollDebugLog()` | `Array<string>` | 获取原生调试日志 |

### 4.4 DiscoveryService — 设备发现

**文件**: `entry/src/main/ets/service/DiscoveryService.ets` (~481行)

#### UDP 组播发现

- 组播组: `224.0.0.167:53317`
- 启动时发 3 次 announce (100ms / 500ms / 2000ms)
- 收到 announce 后先尝试 TCP `/api/localsend/v2/register`，失败则回退 UDP 广播
- 支持自发现过滤（通过 fingerprint）
- 协议版本: `2.1`

#### HTTP 子网扫描

- 触发条件: 1秒内 UDP 无设备发现
- 计算本机子网 IP 范围（最多 254 个目标）
- 50 并发 worker 扫描
- 对每个 IP 依次尝试 HTTPS / HTTP POST `/api/localsend/v2/register`
- 连接超时: HTTPS 2s, HTTP 800ms

#### 组播消息格式 (JSON)

```json
{
  "alias": "设备名",
  "version": "2.1",
  "deviceModel": "型号",
  "deviceType": "mobile|desktop|web|headless|server|tablet",
  "fingerprint": "证书指纹",
  "port": 53317,
  "protocol": "https|http",
  "download": false,
  "announce": true,
  "announcement": true
}
```

---

## 5. 类型定义

### 应用层类型 (Types.ets)

| 类型 | 字段 | 说明 |
|------|------|------|
| `DiscoveredDevice` | alias, ip, port, fingerprint, version, deviceModel, deviceType, protocol, lastSeen | 发现的设备 |
| `LocalDeviceInfo` | alias, fingerprint, ip | 本机信息 |
| `PendingRequestFile` | fileId, fileName, size, fileType, preview? | 待接收文件 |
| `PendingRequest` | sessionId, senderAlias, senderFingerprint, files[] | 待处理请求 |
| `TransferProgress` | sessionId, fileId, bytesSent, totalBytes, filePath | 传输进度 |
| `SendFileItem` | fileId, filePath, fileName, fileType, size, preview? | 待发送文件 |
| `LogEntry` | timestamp, level, message | 日志条目 |
| `StagedFile` | uri, fileName, fileType, isImage | 暂存文件(发送前) |

### NAPI 类型 (NativeTypes.ets)

| 类型 | 对应 Rust 类型 | 说明 |
|------|----------------|------|
| `NativeFileToSend` | FileToSend | 发送文件描述 |
| `NativeProgressInfo` | ProgressInfo | 进度信息 |
| `NativeSendResult` | SendResult | 发送结果 |
| `NativeServerConfig` | ServerConfig | 服务器配置 |
| `NativeServerHandle` | ServerHandle | 服务器句柄 |
| `NativeServerStatus` | ServerStatus | 服务器状态 |
| `NativeTargetDevice` | TargetDevice | 目标设备 |
| `NativeTransferFileInfo` | TransferFileInfo | 传输文件信息 |
| `NativeTransferRequest` | TransferRequest | 传输请求 |
| `NativeShareLinkInfo` | ShareLinkInfo | 分享链接信息 |
| `NativeRecvDiag` | RecvDiag | 接收诊断 |
| `NativeCancelTarget` | CancelTarget | 取消目标 |

### 特殊常量

- `CANCEL_EVENT_FILE_ID = '_cancel_'` — Rust 端通过 fileId 为此值的进度事件通知取消

---

## 6. UI 架构

### 6.1 页面路由 (main_pages.json)

| 页面 | 用途 | 入口条件 |
|------|------|----------|
| `pages/MainPage` | 标准 Tabs 主页 | SDK < 23 |
| `pages/MainTabFloating` | HdsTabs 浮动风格主页 | SDK >= 23 |
| `pages/Index` | 调试/测试页面 | 手动导航 |
| `pages/TransferPage` | 传输进度 | router.pushUrl |
| `pages/ShareLinkPage` | 分享链接+二维码 | router.pushUrl |
| `pages/CompletionNotifyPage` | 完成通知 | router.pushUrl |
| `pages/AboutPage` | 关于页面 | router.pushUrl |

### 6.2 主页面结构

两个主页面 (MainPage / MainTabFloating) 共享三个 Tab:

1. **Send** (`SendContent`) — 文件/图片/剪贴板/文本选择 + 设备列表
2. **Receive** (`ReceiveContent`) — 本机信息 + 自动保存设置 + 收藏设备
3. **Settings** (`SettingsContent`) — 通用设置 + 网络设置 + 关于入口

### 6.3 TransferPage 传输模式

通过 `router.getParams()` 获取参数，`mode` 字段区分:

- `send` — 发送模式: 预览 → 自动开始传输 → 进度条 → 完成/失败
- `receive` — 接收模式: 确认 → 接受/拒绝 → 进度条 → 完成/失败
- 剪贴板模式: `isClipboard=true` → 直接显示文本内容 → 复制/打开链接
- 文本发送模式: `isTextSend=true` → 简化发送界面

### 6.4 响应式设计

- 手机/窄屏 (`320vp <= width < 520vp`): 底部水平 Tab 栏
- 平板/宽屏: 侧边垂直 Tab 栏 (barWidth=96)
- 短屏 (`height < 600vp`): 底部 Tab 栏
- 内容最大宽度: 800vp
- 深色模式: 完整 `dark/element/color.json` 资源覆盖

### 6.5 组件层级

```
MainPage / MainTabFloating
├── SendContent
│   └── TextSendDialog (CustomDialog)
├── ReceiveContent
└── SettingsContent
    ├── InputDialog (CustomDialog) — 设备名称/型号输入
    └── DeviceTypePickerDialog (CustomDialog) — 设备类型选择
```

---

## 7. AppStorage 键值

| 键 | 类型 | 说明 |
|----|------|------|
| `nekoshare_floating` | boolean | 是否使用浮动标签 (PersistentStorage) |
| `serverReady` | boolean | 服务器是否就绪 |
| `sharedFileUris` | string (JSON) | 外部分享的文件 URI 列表 |
| `pendingSharedUris` | string (JSON) | 待处理的分享 URI |
| `recvTransferCompleted` | string | 已完成的接收会话ID |
| `recvTransferCancelled` | string | 被取消的接收会话ID |
| `recvTextMessage` | string (JSON) | 接收的文本消息 `{sessionId, content}` |
| `autoSaveMode` | string | 自动保存模式: 'off' / 'favorites' / 'on' |
| `favoriteDevices` | string (JSON) | 收藏设备指纹列表 |
| `encryptedTransfer` | boolean | 是否启用加密传输 |
| `hideShareByLink` | boolean | 是否隐藏链接分享 |
| `silentReceive` | boolean | 静默接收 |
| `enablePickerSpring` | boolean | 文件选择器弹动效果 |

---

## 8. Preferences 键值

存储名: `nekoshare_settings`

| 键 | 类型 | 默认值 | 说明 |
|----|------|--------|------|
| customAlias | string | '' | 自定义设备名称 |
| customDeviceType | string | 'mobile' | 自定义设备类型 |
| customDeviceModel | string | '' | 自定义设备型号 |
| autoSaveMode | string | 'off' | 自动保存模式 |
| favoriteDevices | string | '[]' | 收藏设备指纹 JSON |
| encryptedTransfer | boolean | true | 加密传输 |
| hideShareByLink | boolean | false | 隐藏链接分享 |
| silentReceive | boolean | false | 静默接收 |
| enablePickerSpring | boolean | true | 弹动效果 |

---

## 9. Rust 原生库 API (index.d.ts)

### 数据接口

`ServerConfig`, `ServerHandle`, `ServerStatus`, `TargetDevice`, `CancelTarget`,
`FileToSend`, `TransferFileInfo`, `TransferRequest`, `ProgressInfo`,
`SendResult`, `ShareLinkInfo`, `RecvDiag`

### 导出函数

| 函数 | 签名 |
|------|------|
| `createServer` | `(config: ServerConfig) => Promise<ServerHandle>` |
| `stopServer` | `() => Promise<void>` |
| `getServerStatus` | `() => ServerStatus` |
| `sendFiles` | `(target: TargetDevice, senderAlias: string, files: Array<FileToSend>) => Promise<SendResult>` |
| `respondTransfer` | `(sessionId: string, accept: boolean, acceptedFileIds: Array<string>) => Promise<void>` |
| `cancelTransfer` | `(target: CancelTarget, sessionId: string) => Promise<void>` |
| `cancelLocalSession` | `(sessionId: string) => Promise<void>` |
| `createShareLink` | `(files: Array<FileToSend>, alias: string) => Promise<ShareLinkInfo>` |
| `stopShareServer` | `() => Promise<void>` |
| `pollPendingRequests` | `() => Array<TransferRequest>` |
| `pollProgress` | `() => Array<ProgressInfo>` |
| `pollSendProgress` | `() => Array<ProgressInfo>` |
| `pollShareProgress` | `() => Array<ProgressInfo>` |
| `getCurrentSendSessionId` | `() => string` |
| `getRecvDiag` | `() => RecvDiag` |
| `pollDebugLog` | `() => Array<string>` |
| `computeFingerprint` | `(certPem: string) => string` |
| `verifyFingerprint` | `(certPem: string, expected: string) => boolean` |

---

## 10. 权限声明 (module.json5)

| 权限 | 说明 |
|------|------|
| `ohos.permission.INTERNET` | 网络访问 |
| `ohos.permission.GET_NETWORK_INFO` | 获取网络信息 |

### 注册的 skill

1. **主屏启动**: `entity.system.home` + `ohos.want.action.home`
2. **系统分享接收**: `entity.system.share` + `ohos.want.action.sendData/sendMultipleData`
   - 支持: `general.image`, `general.video`, `general.audio`, `general.composite-object`, `general.text`, `general.archive`, `general.file`
   - 单类型最大文件数: 50

---

## 11. 功能特性清单

| 功能 | 实现方式 |
|------|----------|
| 文件传输 | DocumentViewPicker → 沙箱复制 → Rust HTTP 上传 |
| 图片传输 | PhotoViewPicker → 同上 |
| 剪贴板共享 | PasteButton → pasteboard API → .txt → 发送 |
| 文本发送 | TextSendDialog → .txt → 发送 |
| 链接分享 | Rust 临时 HTTP 服务器 → 二维码 |
| 设备发现 | UDP 组播 (224.0.0.167:53317) + HTTP 子网扫描 |
| 加密传输 | HTTPS (Rust TLS)，可切换 HTTP |
| 收藏设备 | Preferences 存储 fingerprint JSON 数组 |
| 自动保存 | 三模式: off / favorites / on |
| 深色模式 | 完整 dark 资源覆盖 |
| 外部分享 | systemShare API + skill 注册 |
| 传输取消 | NAPI cancelTransfer / cancelLocalSession |
| 完成通知 | AppStorage 事件 → overlay 弹窗 |
| 响应式 UI | MediaQuery 断点适配 + HdsTabs |

---

## 12. 资源文件

### 颜色体系

亮色和暗色各定义了约 27 个颜色资源，主要分类:
- **背景**: page_background, card_background, input_bg
- **文本**: text_primary, text_secondary, text_tertiary, text_on_color
- **强调**: accent_blue, accent_blue_bg, ip_blue_text
- **状态**: success_green, warning_orange, danger_red, stop_red
- **特殊**: purple_text, purple_bg, clipboard_text, overlay_mask, shadow_color, gradient_mask

### SVG 图标

`ic_public_send_filled`, `ic_public_connection_filled`, `ic_public_settings_filled`,
`ic_public_file`, `ic_public_file_filled`, `ic_public_picture`, `ic_public_picture_filled`,
`ic_public_ok_filled`, `ic_public_cancel_filled`, `ic_public_refresh`,
`ic_public_devices_phone`, `ic_device_matebook`, `ic_device_pad`, `ic_browser`,
`ic_terminal`, `ic_server`, `ic_heart`, `ic_heart_fill`, `ic_x`, `ic_plus`,
`ic_justify`, `ic_clipboard`, `ic_gallery_sort_order`, `ic_public_email_send_filled`,
`ic_public_wlan_filled`

---

## 13. 已知技术细节与注意事项

1. **双主页面策略**: SDK>=23 用 `HdsTabs`（华为设计系统），<23 用标准 `Tabs`
2. **MIME 映射重复**: `AppService.getMimeForExt()` 和 `SendContent.getMimeFromExt()` 各有一份，略有差异
3. **日志使用**: 大量 `hilog.error` 用于调试输出（非真正错误），info/warn/error 级别混用
4. **进度轮询**: 500ms 间隔同时轮询接收/发送/分享三种进度，合并到统一数组
5. **文件命名冲突**: `resolveDestPath()` 处理同名文件，最多 `_1` 到 `_998`，之后用时间戳
6. **导出依赖用户交互**: 文件导出需要用户通过 DocumentViewPicker 选择保存位置
7. **AppStorage 跨组件通信**: 作为全局事件总线使用（recvTransferCompleted 等）
8. **NativeBridge 纯薄封装**: 仅做类型转换，所有业务逻辑在 AppService
9. **Index 页面为调试页**: 不作为正式入口，包含手动启停服务器、直接发送等调试功能

---

## 14. 关联文档

| 文件 | 用途 |
|------|------|
| `BUGS.md` | 已发现的功能性 Bug 清单（含严重程度、根因分析、修复建议） |
| `README.md` | 项目说明 |

---

## 变更记录

| 日期 | 变更内容 |
|------|----------|
| 2026-08-08 | 初始创建，完整记录项目架构；新增第14节关联文档，引用 BUGS.md |
