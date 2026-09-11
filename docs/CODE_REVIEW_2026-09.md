# 代码审阅报告（2026-09）

> 2026-09-12 对全项目（ArkTS 约 2.8 万行 + Rust 约 9300 行）的整体审阅结论。
> 每项问题经人工核对后标注核对结论：✅ 已确认并修复 / ⚠️ 确认存在但本次不修（含原因）/ ❌ 核对后判定为误报。
> 修复提交 hash 在各条目中记录。

## P0 高优先级

### P0-1 MTA 发送取消竞态：CANCELLED 被覆盖为 FAILED、已释放定时器复活

- 位置：`entry/src/main/ets/service/mta/MtaSendService.ets`（sendToDevice 主体 / failSend / cancelSend）
- 描述：`sendToDevice` 全流程无协作取消检查点。用户在任意 await 点调用 `cancelSend` 后，仍在运行的 `sendToDevice` 继续推进：`failSend` 内 `setStage(FAILED)` 会把 CANCELLED 覆盖为 FAILED（UI 展示错误）；`startGroupClientPolling()` 在 `releaseSendResources` 之后执行会重新拉起已停止的轮询定时器；取消发生在 startServer await 期间时，服务器启动成功后继续向已断开的 GATT 写 P2pInfo 并二次走 failSend。
- 核对结论：✅ 已确认并修复（ad604e0）。新增 `cancelledThisSession` 标志 + `checkSessionAborted` 检查点：sendToDevice 每个 await 后检查会话状态，已取消时幂等释放资源并终止旧链路；failSend 开头对已取消会话提前返回，CANCELLED 不再被覆盖；cancelSend/cleanupAll 置取消标志。

### P0-2 MTA 发送早期 return 导致接收服务永久停摆

- 位置：`MtaSendService.ets`（sendToDevice 早期 return）+ `viewmodel/MtaTransferViewModel.ets`（loadSend 先 suspend 后调用）
- 描述：「会话占用」「无可发送内容」两种早期 return 发生在 `sessionActive = true` 之前，而 ViewModel 在调用前已执行 `suspendMtaReceiveForSend()`。此时 `endSession` 永不触发 → `resumeMtaReceiveAfterSend` 永不运行 → `sendActive` 永久为 true、接收服务永久停摆、页面 `isSending` 永久为 true。
- 核对结论：✅ 已确认并修复（ad604e0）。「会话占用」分支经核对不可达（loadSend 每次新建 MtaSendService 实例，sessionActive 恒为 false）；「无内容」分支在当前调用链也不可达（SendContent 导航前经 buildMtaSendParams 校验，空暂存/空文本均返回 undefined 不导航）。但防御链路依赖两个远距离隐式约定，属脆弱设计，已在 loadSend 暂停接收服务之前增加内容非空校验做纵深防御。

### P0-3 MTA GATT 读/写/服务发现无超时，Promise 可永久 pending

- 位置：`service/mta/MtaBleClient.ets`（readRemoteDeviceInfo / writeRemoteP2pInfo / findCharacteristic）
- 描述：`MtaConstants.ets` 定义的 `GATT_READ_TIMEOUT_MS` / `GATT_WRITE_TIMEOUT_MS` 全仓库无引用——超时在设计意图内但从未接线。对端 BLE 协议栈卡死时 `sendToDevice` 永久挂起，只能杀进程。
- 核对结论：✅ 已确认并修复（ad604e0）。核对确认两个常量仅有定义无引用。新增 `withGattTimeout` 包装：读 DeviceInfo / 写 P2pInfo 分别接线 `GATT_READ_TIMEOUT_MS` / `GATT_WRITE_TIMEOUT_MS`；服务发现（getServices）视作读操作共用读超时。超时抛文本错误走 failSend 释放资源，底层迟到结果被忽略且无 unhandled rejection。

### P0-4 MTA WAITING_WS 阶段无超时，发送端可无限期等待

- 位置：`MtaSendService.ets`（P2P_INFO_WRITTEN → WAITING_WS 无定时兜底）；`MtaConstants.ets`（`SERVER_START_TIMEOUT_MS` 定义未使用）
- 描述：P2pInfo 写回后若接收端不回连（凭据解密失败、直连失败、对端杀进程），发送端永远停在 WAITING_WS。Rust 侧 `STATUS_WAIT_TIMEOUT` 只在 WS 连接建立后才开始计时，覆盖不到这一空窗。`nativeMtaStartServer` 也无 ArkTS 侧超时。
- 核对结论：✅ 已确认并修复（ad604e0）。新增 `WAITING_WS_TIMEOUT_MS`（60 秒，覆盖对端解密凭据、直连建组与 WS 握手重试链路最大时长）与超时定时器：进入 WAITING_WS 启动，收到 mtaWsConnected 或释放资源时清除；超时仍未回连则 failSend。`nativeMtaStartServer` 接线 `SERVER_START_TIMEOUT_MS`（Promise.race 兜底，迟到启动的服务器由 failSend → releaseSendResources 回收）。

### P0-5 Rust 事件回调 Ability 重启后失效，事件全丢

- 位置：`localsend_ohrs/rust/napi/event_forwarder.rs` + `napi/env.rs`
- 描述：首次 `register_event_listener` 把 `event_rx` take 走；Ability 重启后（native static 不卸载、JS 侧 `nativeEventListenerRegistered` 复位会再次注册）：`ensure_event_channel` no-op、`start_event_forwarder` 因 `event_rx` 已 None 直接 return——新回调永不生效，旧 forwarder 持有指向已销毁 JS 环境的 tsfn，此后所有事件投递失败，应用"无事件"假死。
- 核对结论：✅ 已确认并修复（77d4f22）。转发任务改为仅启动一次并持续消费事件流；tsfn 存入 NapiEnv，每次注册覆盖更新、投递时取最新——Ability 重启后 ArkTS 重新注册即恢复事件投递，旧 tsfn 被覆盖丢弃。

### P0-6 Rust prepare_send 的 RegisterDto.port 疑似填了对方端口（协议语义错误）

- 位置：`localsend_ohrs/rust/bridge/client.rs`（PrepareUploadRequestDto.info.port = target_port）
- 描述：LocalSend v2 协议中 prepare-upload 请求携带的 `info.port` 语义应为**发送方自己的服务器端口**（供接收方回调 /cancel）。当前实现填的是接收方端口。若语义确认：对端官方 LocalSend 取消会话时向我们声明的 target_port（它自己的端口）发 /cancel → 打到自己，取消通知丢失；两端都是 HandySend 时取消链路整体失效。需对照 `third_party/localsend` 上游源码确认。
- 核对结论：✅ 已确认并修复（77d4f22）。对照上游源码确认语义：官方 App 构造 PrepareUploadRequestDto 时填 `originDevice.port`（发送方自身端口）；接收方取消会话时向 `session.sender` 的 ip + port（即请求中 info.port）回调 /cancel。原实现填 target_port 会使对端取消通知打到它自己的端口。已改为从 BridgeState.local_port 读取本机服务器端口填入。

### P0-7 Rust Mutex 锁中毒级联 panic

- 位置：`napi/*`、`bridge/*` 约 60 处 `Mutex::lock().unwrap()`
- 描述：任一线程持锁 panic 后 BridgeState 全局 Mutex 中毒，此后所有 NAPI 调用（含错误处理路径）都 panic → 应用崩溃。建议统一封装 `lock()` 辅助函数（`into_inner()` 中毒恢复）。
- 核对结论：✅ 已确认并修复（77d4f22）。bridge/mod.rs 新增 `lock()` 辅助（`unwrap_or_else(PoisonError::into_inner)` 中毒恢复），生产代码 107 处 `lock().unwrap()` 全部替换（含 6 处多行链式形式）；测试代码保留 `unwrap()`（测试中锁中毒应 fail fast）。单元 139 + 集成 25 用例通过。

### P0-8 ReceiveContent 动画循环组件销毁后不可停

- 位置：`components/ReceiveContent.ets`
- 描述：logo 旋转动画 `onFinish` 无条件自续；`aboutToDisappear` 只清理「动画禁用」分支的 timer。组件销毁后动画持续空转（内存泄漏 + 僵尸动画）。
- 核对结论：（待核对）

### P0-9 TransferFileList 列表 key 含 percent，进度期间行节点整行重建

- 位置：`views/TransferFileList.ets`（Repeat key 拼接 percent）
- 描述：进度经 updateProgress 高频直达 @Trace 数组，key 每变 1% 变化 → Repeat diff 判定为删除+新建，传输期间行节点整行重建，浪费性能。
- 核对结论：（待核对）

### P0-10 MainTabViewModel autoAcceptedSessions 死代码，主页完成浮层永不执行

- 位置：`viewmodel/MainTabViewModel.ets`（autoAcceptedSessions 无非空写入路径）
- 描述：`checkTransferEvents` 永不触发回调 → `MainTabFloating` 的 CompletionOverlay completed/cancelled 分支永不执行。需决策：删除死代码（证据充分）还是补实现「自动接收完成浮层」（产品决策）。
- 核对结论：（待核对）

### P0-11 PIN 弹窗在 UIContext 未就绪时静默失败，发送流程永久挂起

- 位置：`service/DialogService.ets`（openDialog 在 ctx null 时仅记日志 return）+ `SendRepository.ets`（askForPin 的 while(true) 循环）
- 描述：callback 永不调用 → Promise 永不 resolve → 发送流程永久挂起且无 UI 反馈。
- 核对结论：（待核对）

## P1 中优先级

### 结构与重复

| # | 问题 | 位置 | 核对结论 |
|---|------|------|----------|
| P1-1 | ReceiveRepository.ets（1260 行）职责过多；doPollRequests 与 handlePrepareUploadEventTyped 大段重复 | `service/repository/ReceiveRepository.ets` | （待核对） |
| P1-2 | ServerRepository：discoveryConfig 构建块重复 4 次、restart 两函数几乎相同且无互斥 | `service/repository/ServerRepository.ets` | （待核对） |
| P1-3 | finishReceiveSession 状态清理使 3 秒防御检查失效（碰巧结果正确） | `ReceiveRepository.ets` | （待核对） |
| P1-4 | createShareLink 先关旧 fd 后开新文件，失败时旧链接悬空 | `WebShareRepository.ets` | （待核对） |
| P1-5 | stopReceiveServiceInternal 异常路径不复位 receiveRunning | `MtaRepository.ets` | （待核对） |
| P1-6 | stopLocalServer 中 nativeStopServer 失败被空 catch 吞掉 | `ServerRepository.ets` | （待核对） |
| P1-7 | parseNativeEvent 对 payload 零校验：sessionId 缺失→事件静默丢失；progress 缺失→NaN 注入进度 | `model/NativeTypes.ets` | （待核对） |
| P1-8 | MtaRepository 接收服务启动 TOCTOU（无 starting 中间标志） | `MtaRepository.ets` | （待核对） |
| P1-9 | MTA 收发互斥标志并发发送时互相覆盖，恢复需求丢失 | `MtaRepository.ets` | （待核对） |
| P1-10 | 接收端 NEGOTIATED → REQUEST_RECEIVED 无超时可无限期卡死 | `MtaReceiveService.ets` | （待核对） |
| P1-11 | ensureBleRunning 失败后仍无条件进入 SERVICE_RUNNING | `MtaReceiveService.ets` | （待核对） |
| P1-12 | 下载中 WS 断开被静默忽略，收发双方终态分裂（一端完成一端失败） | `MtaReceiveService.ets` + `MtaTransferClient.ets` | （待核对） |
| P1-13 | MtaTransferClient.send() 吞错，成功回执丢失 | `MtaTransferClient.ets` | （待核对） |
| P1-14 | startGattServer / connectGattClient 异常路径句柄泄漏 | `MtaBleReceiver.ets` / `MtaBleClient.ets` | （待核对） |
| P1-15 | writeBuffer 客户端断开不清空（跨会话污染）+ 多客户端共享无隔离 | `MtaBleReceiver.ets` | （待核对） |
| P1-16 | downloadZip fd 与临时文件异常路径泄漏；writeSync 失败被吞继续下载 | `MtaTransferClient.ets` | （待核对） |
| P1-17 | MTA 同步文件 IO（copyFileSync）阻塞 UI 线程 | `MtaSendService.ets` / `MtaTransferClient.ets` | （待核对） |
| P1-18 | 接收端解压落盘磁盘峰值达数据量 3 倍 | `MtaTransferClient.ets` | （待核对） |
| P1-19 | 页面取消按钮立即 pop，destroy 与 cancelSend 并发执行 | `pages/MtaTransferPage.ets` | （待核对） |
| P1-20 | Rust start_server 入口守卫 TOCTOU，并发启动可产生双服务器 | `bridge/server.rs` | （待核对） |
| P1-21 | Rust 持 state 锁做磁盘 IO + 证书生成，阻塞 JS 线程 | `bridge/identity.rs` | （待核对） |
| P1-22 | Rust ServerStopped / DeviceLost 事件从不发射（死事件） | `bridge/event.rs` / `bridge/server.rs` / `bridge/discovery.rs` | （待核对） |
| P1-23 | Rust abort 窗口 fd 泄漏 + cancel 关键事件 try_send 可能丢弃 | `bridge/server.rs` | （待核对） |
| P1-24 | Rust prepare_download 绕过桥接 DTO 直接序列化上游 resp.files | `bridge/client.rs` | （待核对） |
| P1-25 | Rust BridgeState 跨 Ability 残留（server_handle/discovery_handle/fd） | `bridge/state.rs` | （待核对） |
| P1-26 | Rust 20ms 进度节流逻辑 4 份实现且行为漂移 | `bridge/server.rs` / `bridge/client.rs` | （待核对） |
| P1-27 | Rust stop_share_server 清理集与 stop_server 不一致 | `bridge/server.rs` | （待核对） |
| P1-28 | Rust pack_zip 同步 IO 阻塞 tokio worker | `bridge/mta/zip_stream.rs` | （待核对） |
| P1-29 | Rust stop_server 不终止已接受连接（无 CancellationToken） | `bridge/mta/mod.rs` / `server.rs` | （待核对） |
| P1-30 | Rust ws_connected 永不复位，WS 重连被静默拒绝且无事件 | `bridge/mta/mod.rs` / `ws.rs` | （待核对） |

## P2 低优先级 / 规范

| # | 问题 | 位置 | 核对结论 |
|---|------|------|----------|
| P2-1 | ~~规范禁止 `as` 断言但实际 100+ 处~~ 核对结论：一刀切禁止不合理（官方 FAQ 认可 `as` 为 ArkTS 动态边界标准姿势），已修订 AGENTS.md 规范为「禁止 any/unknown 与双重断言，允许动态边界 as」；存量 as 均属允许场景，个别判空后 `!` 非空断言另行修复 | 全项目 | ✅ 规范已修订 |
| P2-2 | `permission_bluetooth_reason` 缺 zh_CN 翻译 | `resources/zh_CN/element/string.json` | （待核对） |
| P2-3 | 文档 Target SDK 6.1.1(24) 与本地 build-profile targetSdkVersion 26.0.0 不一致 | `AGENTS.md` / `docs/ARCHITECTURE.md` | （待核对） |
| P2-4 | MtaSendService.logs 只写不读；MtaReceiveService.destroy() 无调用方 | MTA service | （待核对） |
| P2-5 | errorText 辅助函数 6 份重复 | `service/mta/*` | （待核对） |
| P2-6 | MtaReceiveModels.ets 名不副实（实为共享协议层） | `model/mta/MtaReceiveModels.ets` | （待核对） |
| P2-7 | parseP2pInfo 不解析 freq 字段，发送端写入被静默丢弃 | `MtaReceiveModels.ets` | （待核对） |
| P2-8 | PROTOCOL_VERSION 双源硬编码且不做协商校验 | ArkTS + Rust | （待核对） |
| P2-9 | sendRequest 的 ack 发送两次无注释 | `MtaTransferClient.ets` | （待核对） |
| P2-10 | catShareText 无长度上限 | MTA 发送链路 | （待核对） |
| P2-11 | MAX_SEND_ENTRY_COUNT / MAX_SEND_TOTAL_BYTES 定义未强制校验 | `MtaConstants.ets` | （待核对） |
| P2-12 | BLEMtuChange 伪装成连接状态事件 | `MtaBleClient.ets` | （待核对） |
| P2-13 | 本地化回退样板散布 10+ 处 | Repository 层 | （待核对） |
| P2-14 | 一次性 UI 信号四种实现并存 | Repository 层 | （待核对） |
| P2-15 | Rust 死状态字段（debug_log / share_link_info / recv_diag_drain_count）+ 双份相同导出 poll_debug_log | `bridge/state.rs` / `napi/identity.rs` | （待核对） |
| P2-16 | Rust 双 tokio runtime 并存 + block_on 死代码 | `napi/env.rs` | （待核对） |
| P2-17 | Rust register_device 用 Debug 格式化 deviceType | `bridge/client.rs` | （待核对） |
| P2-18 | Rust 配置解析全部静默默认回退（拼写错误无感知） | `bridge/server.rs` / `discovery.rs` | （待核对） |
| P2-19 | Rust 端口 as u16 静默截断 | 多处 | （待核对） |
| P2-20 | Rust 无界日志缓冲（后台停止轮询后持续累积） | `bridge/identity.rs` | （待核对） |
| P2-21 | cancel_local_session 每次取消裸起线程 + 新建 runtime | `bridge/server.rs` | （待核对） |
| P2-22 | download readTimeout 为 0 无停滞检测 | `MtaTransferClient.ets` | （待核对） |
| P2-23 | DiscoveryRepository addDevice rejection 处理三处不一致 | `DiscoveryRepository.ets` | （待核对） |
| P2-24 | AppService initAppService 无幂等守卫；NetConnection 无法注销 | `AppService.ets` | （待核对） |
| P2-25 | updateSendSessionStatus 5 秒延迟清理定时器不可取消 | `SendRepository.ets` | （待核对） |
| P2-26 | EventBus.notifyChange 无异常隔离（与其它分发点防御不一致） | `utils/EventBus.ets` | （待核对） |
| P2-27 | finishReceiveSession 定期重置波及进行中会话 | `ReceiveRepository.ets` | （待核对） |
| P2-28 | 本地准备失败被记为 canceledBySender 语义错误 | `ReceiveRepository.ets` | （待核对） |
| P2-29 | createSendSession 按 targetIp 匹配删除旧会话（同 IP 多设备冲突） | `SendRepository.ets` | （待核对） |
| P2-30 | 超时/连接错误关键词双份维护 | `SendRepository.ets` | （待核对） |
| P2-31 | Rust drainNativeDebugLog 两份逐行相同且丢弃级别 | `SendRepository.ets` / `DiscoveryRepository.ets` | （待核对） |
| P2-32 | Rust fail_file_upload 语义矛盾（做了 cancel 动作却报 SessionExpired） | `bridge/server.rs` | （待核对） |
| P2-33 | Rust active_transfers 令牌双重插入 + prepare 阶段脏值不复位 | `bridge/client.rs` | （待核对） |
| P2-34 | Rust create_cancel_token 令牌可永久驻留 | `bridge/identity.rs` | （待核对） |
| P2-35 | Rust RUNNING 锁 poisoned 后服务器永久失控且无日志 | `bridge/mta/mod.rs` | （待核对） |
| P2-36 | Rust 序列化失败发送空字符串 | `napi/event_forwarder.rs` | （待核对） |
| P2-37 | sendToDevice 静默拉起从未启动的服务器 | `SendRepository.ets` | （待核对） |
