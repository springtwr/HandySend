# Debug Log Inventory

运行时通过 `[DBG-` 前缀过滤日志（`hdc shell hilog | grep "\[DBG-"`）即可定位对应模块。

## ArkTS 侧（AppService.ets）

| 前缀 | 触发点 | 用途 |
|------|--------|------|
| `[DBG-EVENT]` | 事件分发循环 | 事件类型、原始 JSON |
| `[DBG-DISC]` | `handleDeviceFound` / `handleDiscoveryUpdate` | 设备发现/更新（单设备 / 全量列表） |
| `[DBG-REG]` | register 回调 | 注册请求/响应 |
| `[DBG-RECV]` | `handlePrepareUploadEventTyped` / `handlePrepareDownloadTyped` | 接收传输事件详情 |
| `[DBG-WEB-DL]` | `downloadFileFromDevice`（web 下载） | Web 下载流程 |
| `[DBG-WEB-UP]` | `startWebUpload` | Web 上传启动 |
| `[DBG-DEVS]` | `getDiscoveredDevices` | 设备列表查询、过期筛选 |
| `[DBG-HTTPS]` | `setHttpsEnabled` | 加密开关切换、持久化 |
| `[DBG-SCAN]` | `rescanDevices` / `triggerStagedDiscover` | 扫描/发现触发 |
| `[DBG-SERVER]` | `startLocalServer` | 服务器启动参数 |
| `[DBG-SEND]` | `sendToDevice` | 发送目标、协议协商 |
| `[DBG-SHARE]` | `stopShareLink` | 分享链接停止 |

## Rust 侧

| 文件 | 函数 | 前缀 | 用途 |
|------|------|------|------|
| `client_facade.rs` | `prepare_send` | `[DBG-SEND]` | 协议协商、TLS 证书、文件数 |
| `client_facade.rs` | `prepare_send` 结果 | `[DBG-SEND]` | 成功/失败+状态码 |
| `client_facade.rs` | `upload_file` | `[DBG-UPLOAD]` | 上传参数 |
| `client_facade.rs` | `send_files` | `[DBG-SEND-FILES]` | 发送入口 |
| `server_facade.rs` | `start_server_with_show_token` | `[DBG-SRV]` | 服务器启动参数 |
| `server_facade.rs` | `stop_server` | `[DBG-SRV]` | 服务器停止 |
| `server_facade.rs` | `accept_transfer` | `[DBG-SRV]` | 接受传输 |
| `server_facade.rs` | `decline_transfer` | `[DBG-SRV]` | 拒绝传输 |
| `server_facade.rs` | `start_web_upload` | `[DBG-WEB-UP]` | Web 上传启动+端口 |
| `server_facade.rs` | 事件循环 `PrepareUpload` | `[DBG-SRV-EVT]` | 接收上传请求详情 |
| `server_facade.rs` | 事件循环 `FileUpload` | `[DBG-SRV-EVT]` | 文件上传事件+save_path |
| `discovery_facade.rs` | `start_discovery_v2` | `[DBG-DISC]` | 发现服务启动 |
| `discovery_facade.rs` | `discovery_announce` | `[DBG-DISC]` | 广播宣告 |
| `discovery_facade.rs` | `discovery_discover_staged` | `[DBG-DISC]` | 分阶段发现 |
| `discovery_facade.rs` | `discovery_scan_subnet` | `[DBG-DISC]` | 子网扫描 |
| `discovery_facade.rs` | 事件监听 `Discovered/Updated` | `[DBG-DISC-EVT]` | 设备发现/更新事件 |
| `discovery_facade.rs` | `discovery_get_devices` | `[DBG-DISC-GET]` | Rust DeviceStore 设备数 |
| `facade.rs` | `init_with_persisted_identity` | `[DBG-INIT]` | 初始化+证书持久化 |

## 待诊断 Bug 与对应日志

| Bug | 现象 | 关键日志前缀 |
|-----|------|-------------|
| Bug3 | 浏览器选文件确认后崩溃 | `[DBG-EVENT]` → `[DBG-RECV]` → `[DBG-SRV-EVT]`（files 数组是否为空） |
| Bug5 | 离线设备刷新后仍出现 | `[DBG-DISC]`（device_found 事件） + `[DBG-DEVS]`（过期筛选） — **已修复**：改用单设备事件 + 刷新清空列表 |
| Bug6 | 刷新按钮触发多次 DISCOVER | `[DBG-SCAN]` + `[DBG-DISC]` + `[DBG-DISC-EVT]` — **已修复**：改用 discover_staged（内含 announce） |
| Bug7 | HTTP→HTTPS 跨协议传输崩溃 | `[DBG-SEND]` + `[DBG-UPLOAD]`（协议选择、TLS 失败） |
| Bug8 | 加密开关重启后未持久化 | `[DBG-HTTPS]` + `[DBG-INIT]`（写入值 vs 读取值） — **已修复**：flushNow 持久化 + 日志确认 |
