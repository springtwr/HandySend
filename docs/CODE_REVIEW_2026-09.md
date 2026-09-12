# 代码审阅报告（2026-09）

> 2026-09-12 对全项目（ArkTS 约 2.8 万行 + Rust 约 9300 行）的整体审阅结论。
> 每项问题经人工核对后标注核对结论：✅ 已确认并修复 / ⚠️ 确认存在但本次不修（含原因）/ ❌ 核对后判定为误报。
> 修复提交 hash 在各条目中记录。

## P0 高优先级

### P0-1 MTA 发送取消竞态：CANCELLED 被覆盖为 FAILED、已释放定时器复活

- 位置：`entry/src/main/ets/service/mta/MtaSendService.ets`（sendToDevice 主体 / failSend / cancelSend）
- 描述：`sendToDevice` 全流程无协作取消检查点。用户在任意 await 点调用 `cancelSend` 后，仍在运行的 `sendToDevice` 继续推进：`failSend` 内 `setStage(FAILED)` 会把 CANCELLED 覆盖为 FAILED（UI 展示错误）；`startGroupClientPolling()` 在 `releaseSendResources` 之后执行会重新拉起已停止的轮询定时器；取消发生在 startServer await 期间时，服务器启动成功后继续向已断开的 GATT 写 P2pInfo 并二次走 failSend。
- 核对结论：✅ 已确认并修复。新增 `cancelledThisSession` 标志 + `checkSessionAborted` 检查点：sendToDevice 每个 await 后检查会话状态，已取消时幂等释放资源并终止旧链路；failSend 开头对已取消会话提前返回，CANCELLED 不再被覆盖；cancelSend/cleanupAll 置取消标志。

### P0-2 MTA 发送早期 return 导致接收服务永久停摆

- 位置：`MtaSendService.ets`（sendToDevice 早期 return）+ `viewmodel/MtaTransferViewModel.ets`（loadSend 先 suspend 后调用）
- 描述：「会话占用」「无可发送内容」两种早期 return 发生在 `sessionActive = true` 之前，而 ViewModel 在调用前已执行 `suspendMtaReceiveForSend()`。此时 `endSession` 永不触发 → `resumeMtaReceiveAfterSend` 永不运行 → `sendActive` 永久为 true、接收服务永久停摆、页面 `isSending` 永久为 true。
- 核对结论：✅ 已确认并修复。「会话占用」分支经核对不可达（loadSend 每次新建 MtaSendService 实例，sessionActive 恒为 false）；「无内容」分支在当前调用链也不可达（SendContent 导航前经 buildMtaSendParams 校验，空暂存/空文本均返回 undefined 不导航）。但防御链路依赖两个远距离隐式约定，属脆弱设计，已在 loadSend 暂停接收服务之前增加内容非空校验做纵深防御。

### P0-3 MTA GATT 读/写/服务发现无超时，Promise 可永久 pending

- 位置：`service/mta/MtaBleClient.ets`（readRemoteDeviceInfo / writeRemoteP2pInfo / findCharacteristic）
- 描述：`MtaConstants.ets` 定义的 `GATT_READ_TIMEOUT_MS` / `GATT_WRITE_TIMEOUT_MS` 全仓库无引用——超时在设计意图内但从未接线。对端 BLE 协议栈卡死时 `sendToDevice` 永久挂起，只能杀进程。
- 核对结论：✅ 已确认并修复。核对确认两个常量仅有定义无引用。新增 `withGattTimeout` 包装：读 DeviceInfo / 写 P2pInfo 分别接线 `GATT_READ_TIMEOUT_MS` / `GATT_WRITE_TIMEOUT_MS`；服务发现（getServices）视作读操作共用读超时。超时抛文本错误走 failSend 释放资源，底层迟到结果被忽略且无 unhandled rejection。

### P0-4 MTA WAITING_WS 阶段无超时，发送端可无限期等待

- 位置：`MtaSendService.ets`（P2P_INFO_WRITTEN → WAITING_WS 无定时兜底）；`MtaConstants.ets`（`SERVER_START_TIMEOUT_MS` 定义未使用）
- 描述：P2pInfo 写回后若接收端不回连（凭据解密失败、直连失败、对端杀进程），发送端永远停在 WAITING_WS。Rust 侧 `STATUS_WAIT_TIMEOUT` 只在 WS 连接建立后才开始计时，覆盖不到这一空窗。`nativeMtaStartServer` 也无 ArkTS 侧超时。
- 核对结论：✅ 已确认并修复。新增 `WAITING_WS_TIMEOUT_MS`（60 秒，覆盖对端解密凭据、直连建组与 WS 握手重试链路最大时长）与超时定时器：进入 WAITING_WS 启动，收到 mtaWsConnected 或释放资源时清除；超时仍未回连则 failSend。`nativeMtaStartServer` 接线 `SERVER_START_TIMEOUT_MS`（Promise.race 兜底，迟到启动的服务器由 failSend → releaseSendResources 回收）。

### P0-5 Rust 事件回调 Ability 重启后失效，事件全丢

- 位置：`localsend_ohrs/rust/napi/event_forwarder.rs` + `napi/env.rs`
- 描述：首次 `register_event_listener` 把 `event_rx` take 走；Ability 重启后（native static 不卸载、JS 侧 `nativeEventListenerRegistered` 复位会再次注册）：`ensure_event_channel` no-op、`start_event_forwarder` 因 `event_rx` 已 None 直接 return——新回调永不生效，旧 forwarder 持有指向已销毁 JS 环境的 tsfn，此后所有事件投递失败，应用"无事件"假死。
- 核对结论：✅ 已确认并修复。转发任务改为仅启动一次并持续消费事件流；tsfn 存入 NapiEnv，每次注册覆盖更新、投递时取最新——Ability 重启后 ArkTS 重新注册即恢复事件投递，旧 tsfn 被覆盖丢弃。

### P0-6 Rust prepare_send 的 RegisterDto.port 疑似填了对方端口（协议语义错误）

- 位置：`localsend_ohrs/rust/bridge/client.rs`（PrepareUploadRequestDto.info.port = target_port）
- 描述：LocalSend v2 协议中 prepare-upload 请求携带的 `info.port` 语义应为**发送方自己的服务器端口**（供接收方回调 /cancel）。当前实现填的是接收方端口。若语义确认：对端官方 LocalSend 取消会话时向我们声明的 target_port（它自己的端口）发 /cancel → 打到自己，取消通知丢失；两端都是 HandySend 时取消链路整体失效。需对照 `third_party/localsend` 上游源码确认。
- 核对结论：✅ 已确认并修复。对照上游源码确认语义：官方 App 构造 PrepareUploadRequestDto 时填 `originDevice.port`（发送方自身端口）；接收方取消会话时向 `session.sender` 的 ip + port（即请求中 info.port）回调 /cancel。原实现填 target_port 会使对端取消通知打到它自己的端口。已改为从 BridgeState.local_port 读取本机服务器端口填入。

### P0-7 Rust Mutex 锁中毒级联 panic

- 位置：`napi/*`、`bridge/*` 约 60 处 `Mutex::lock().unwrap()`
- 描述：任一线程持锁 panic 后 BridgeState 全局 Mutex 中毒，此后所有 NAPI 调用（含错误处理路径）都 panic → 应用崩溃。建议统一封装 `lock()` 辅助函数（`into_inner()` 中毒恢复）。
- 核对结论：✅ 已确认并修复。bridge/mod.rs 新增 `lock()` 辅助（`unwrap_or_else(PoisonError::into_inner)` 中毒恢复），生产代码 107 处 `lock().unwrap()` 全部替换（含 6 处多行链式形式）；测试代码保留 `unwrap()`（测试中锁中毒应 fail fast）。单元 139 + 集成 25 用例通过。

### P0-8 ReceiveContent 动画循环组件销毁后不可停

- 位置：`components/ReceiveContent.ets`
- 描述：logo 旋转动画 `onFinish` 无条件自续；`aboutToDisappear` 只清理「动画禁用」分支的 timer。组件销毁后动画持续空转（内存泄漏 + 僵尸动画）。
- 核对结论：✅ 已确认并修复。组件新增 `destroyed` 标志，`aboutToDisappear` 置位；`runLogoRotation` 入口与 `onFinish` 自续前均检查该标志，销毁后动画不再重启。

### P0-9 TransferFileList 列表 key 含 percent，进度期间行节点整行重建

- 位置：`views/TransferFileList.ets`（Repeat key 拼接 percent）
- 描述：进度经 updateProgress 高频直达 @Trace 数组，key 每变 1% 变化 → Repeat diff 判定为删除+新建，传输期间行节点整行重建，浪费性能。
- 核对结论：✅ 已确认并修复。Repeat key 固定为 `item.fileId`；配合 `TransferFileProgress` 改为 @ObservedV2 类（bytesSent/percent/status 标 @Trace），`computeTransferFileProgress` 增加按 fileId 复用实例的原地更新路径，@Trace 驱动行内细粒度刷新而非整行重建。补充实例复用单元测试。

### P0-10 MainTabViewModel autoAcceptedSessions 死代码，主页完成浮层永不执行

- 位置：`viewmodel/MainTabViewModel.ets`（autoAcceptedSessions 无非空写入路径）
- 描述：`checkTransferEvents` 永不触发回调 → `MainTabFloating` 的 CompletionOverlay completed/cancelled 分支永不执行。需决策：删除死代码（证据充分）还是补实现「自动接收完成浮层」（产品决策）。
- 核对结论：✅ 已确认，经决策删除死代码。核对证据：autoAcceptedSessions 全仓库仅有读取/清除，无任何写入方，`resolveAndClear` 恒为 false，浮层链路永不执行。删除 MainTabViewModel 的事件检查/回调桥接、MainTabFloating 的浮层状态与 CompletionOverlay 组件及 4 语言包字符串资源。自动接收场景的完成/取消提示如需支持，后续作为新需求单独设计。

### P0-11 PIN 弹窗在 UIContext 未就绪时静默失败，发送流程永久挂起

- 位置：`service/DialogService.ets`（openDialog 在 ctx null 时仅记日志 return）+ `SendRepository.ets`（askForPin 的 while(true) 循环）
- 描述：callback 永不调用 → Promise 永不 resolve → 发送流程永久挂起且无 UI 反馈。
- 核对结论：✅ 已确认，当前调用链不可达，做纵深防御修复。`DialogService.init` 在 `loadContent` 回调中执行，而发送只能从已就绪的 UI 发起，正常流程不会命中 ctx null；但挂起后果严重且修复成本极低。`openDialog` 改为返回打开结果，`showPinDialog` 打开失败时按取消语义回调空串，PIN 等待方按 401 错误结束而非挂起。

## P1 中优先级

### 结构与重复

| # | 问题 | 位置 | 核对结论 |
|---|------|------|----------|
| P1-1 | ReceiveRepository.ets（1260 行）职责过多；doPollRequests 与 handlePrepareUploadEventTyped 大段重复 | `service/repository/ReceiveRepository.ets` | （待核对） |
| P1-2 | ServerRepository：discoveryConfig 构建块重复 4 次、restart 两函数几乎相同且无互斥 | `service/repository/ServerRepository.ets` | （待核对） |
| P1-3 | finishReceiveSession 状态清理使 3 秒防御检查失效（碰巧结果正确） | `ReceiveRepository.ets` | ✅ 已确认并修复。核对属实：finishReceiveSession 全程无 await，同步将 receiveSessionStates 清 ''、sessionExported 置 false，延迟判定的成功条件永假，仅靠 '' 不匹配失败分支碰巧不误判；一旦引入 await 即会误判失败并误删文件。新增 sessionFinished 显式终结标记，延迟判定改查该标记（保留原 'finished' 条件双保险），标记参与 100 会话定期重置防泄漏 |
| P1-4 | createShareLink 先关旧 fd 后开新文件，失败时旧链接悬空 | `WebShareRepository.ets` | ✅ 已确认并修复。核对属实：先 closeShareFileHandles 再开新文件，任一环节失败时旧分享 URL 仍有效但源 fd 已失效。调整为「先开新文件 → nativeCreateShareLink 成功后才关旧句柄并移交」，失败路径旧分享句柄与链接保持一致可用，留待 stopShareLink 或下次成功创建时收口 |
| P1-5 | stopReceiveServiceInternal 异常路径不复位 receiveRunning | `MtaRepository.ets` | ✅ 已确认并修复。stopService 抛异常时 receiveRunning 卡 true，后续启动被幂等守卫拒绝永远无法再启动。改为 try-catch 包裹 stopService，失败记日志后仍复位标志 |
| P1-6 | stopLocalServer 中 nativeStopServer 失败被空 catch 吞掉 | `ServerRepository.ets` | ✅ 已确认并修复。停止失败后仍无条件置 serverRunning=false 并清指纹，若 Rust 侧服务器实际未停则端口仍占用且无从排查；reloadServerSettings（重启路径）同样吞错且紧接 nativeCreateServer，端口冲突风险更高。两处空 catch 均改为记 error 日志（不改变清理流程，两侧一致性由下次启动收口） |
| P1-7 | parseNativeEvent 对 payload 零校验：sessionId 缺失→事件静默丢失；progress 缺失→NaN 注入进度 | `model/NativeTypes.ets` | ✅ 已确认并修复。新增 REQUIRED_EVENT_FIELDS 必需字段表，parseNativeEvent 在 switch 前统一校验，缺失/null 字段记 warn 日志并丢弃事件（返回 undefined），防止 Rust/ArkTS 结构漂移时 undefined 静默注入下游（会话匹配失败、进度 NaN）且无从排查。补充 NativeTypes.test.ets 单元测试（8 用例） |
| P1-8 | MTA 接收服务启动 TOCTOU（无 starting 中间标志） | `MtaRepository.ets` | ✅ 核对不成立。MtaReceiveService.startService 已有 startingUp 并发闸门 + serviceRunning 幂等检查（616-631 行），Repository 层重复调用被安全忽略，无双启动风险；窗口内第二次调用被忽略仅影响极端时序下的启动重试，无状态损坏 |
| P1-9 | MTA 收发互斥标志并发发送时互相覆盖，恢复需求丢失 | `MtaRepository.ets` | ✅ 已确认并修复。sendToMtaDevice 守卫与 suspendMtaReceiveForSend 之间存在窗口（导航后 VM 加载前），并发可达；resumeReceiveAfterSend 单布尔被后一次 suspend 覆盖为 false，接收服务停摆。改为 sendActiveCount 计数（suspend +1/resume -1），任一次暂停见接收运行即记恢复需求，全部发送结束后才恢复；setMtaSendActive 兼容映射到计数 |
| P1-10 | 接收端 NEGOTIATED → REQUEST_RECEIVED 无超时可无限期卡死 | `MtaReceiveService.ets` | ✅ 已确认并修复。核对属实：WS 连接超时仅覆盖建立阶段，全程无心跳，对端协商后崩溃/网络静默断开收不到 close 事件，接收端无限期停在 NEGOTIATED。新增 REQUEST_WAIT_TIMEOUT_MS（30s）定时器：版本协商完成启动、收到接收请求取消、会话复位/destroy 清理；超时 failAndReset 复位到等待状态 |
| P1-11 | ensureBleRunning 失败后仍无条件进入 SERVICE_RUNNING | `MtaReceiveService.ets` | ✅ 已确认并修复。ensureBleRunning 吞异常仅 setError，resetToWaiting/completeAndRestart 仍 setStage(SERVICE_RUNNING)，广播/GATT 恢复失败时 UI 假就绪且无重连机制。ensureBleRunning/restartBleService 改为返回是否成功，失败路径 setStage(FAILED)，错误信息经 setError 呈现 |
| P1-12 | 下载中 WS 断开被静默忽略，收发双方终态分裂（一端完成一端失败） | `MtaReceiveService.ets` + `MtaTransferClient.ets` | ✅ 已确认并修复。核对属实：发送方 Rust ws.rs 收到对端关闭即 fail_ws 判失败，接收端 handleWsClosed 仅处理三个握手阶段，下载/保存中静默忽略；HTTP 下载若完成，status 回执无法送达，双方终态分裂。handleWsClosed 新增 DOWNLOADING/SAVING 分支：cancelDownload 取消后由下载/保存流程取消检查点走统一失败路径；COMPLETED 阶段的关闭属正常收尾时序（发送方收到回执后主动断开），保持忽略 |
| P1-13 | MtaTransferClient.send() 吞错，成功回执丢失 | `MtaTransferClient.ets` | ✅ 已确认并修复。send() catch 吞错后 sendStatus(OK) 失败仍记「已回送成功状态」，与发送方 fail_ws 终态分裂。send() 改为重抛：接受 ack 失败不进入下载并 failAndReset；成功回执失败时文件已落盘，保持 COMPLETED 记 ERROR 日志（发送方按超时收尾）；拒绝路径既有 catch 随重抛真正生效 |
| P1-14 | startGattServer / connectGattClient 异常路径句柄泄漏 | `MtaBleReceiver.ets` / `MtaBleClient.ets` | ✅ 已确认并修复。接收端 createGattServer 后 addService/on 抛异常仅 reject 未 close，server 句柄泄漏；客户端异常时 gattClient 字段残留非 null，句柄泄漏且后续重连被「已存在连接」永久拒绝。修复：接收端 catch 中 close 已创建的 server；客户端 catch 中复位全部连接状态并 close 已创建的 client。 |
| P1-15 | writeBuffer 客户端断开不清空（跨会话污染）+ 多客户端共享无隔离 | `MtaBleReceiver.ets` | ✅ 已确认并修复。断开仅清 connectedClientId，半截 prepared write 缓冲残留至下个会话；多客户端并发写入共用同一缓冲互相污染。修复：缓冲绑定写入方 deviceId，写入方变化时丢弃残留缓冲重新累积；断开/启停 GATT Server 时同步清空缓冲与归属。 |
| P1-16 | downloadZip fd 与临时文件异常路径泄漏；writeSync 失败被吞继续下载 | `MtaTransferClient.ets` | ✅ 已确认并修复（临时文件泄漏不成立）。fd 泄漏：openSync 与 try 之间 createHttp/on 抛异常时 fd 不关，已将资源创建全部纳入 try-finally；writeSync 失败原仅记日志、进度照常累加，最终把不完整 ZIP 交给解压报莫名错误，已改为置失败标志并在下载结束后抛出明确错误；临时文件失败路径由调用方 downloadAndSave 的 catch 统一 cleanupTemp 兜底，无泄漏。 |
| P1-17 | MTA 同步文件 IO（copyFileSync）阻塞 UI 线程 | `MtaSendService.ets` / `MtaTransferClient.ets` | ✅ 已确认并修复。发送暂存 copyUriToPath 与接收落盘 copyFileSync 均在 UI 线程同步复制，大文件期间卡顿。两处改为异步 fs.copyFile（官方 API，支持路径与 fd），stageFiles/copyUriToPath 链路相应 async 化；statSync/listFileSync 等元数据级同步调用保留。 |
| P1-18 | 接收端解压落盘磁盘峰值达数据量 3 倍 | `MtaTransferClient.ets` | ✅ 已确认并修复。原流程临时 ZIP、解压目录、目标副本三者全程并存，峰值 3 倍。修复：解压完成立即删 ZIP（峰值降至解压期间 2 倍，受 zlib 整包解压限制无法再降）；逐文件搬运成功后立即删解压源文件，搬运期间总占用恒约 1 倍。目标目录与 cacheDir 跨文件系统（FUSE），rename 方案不可行。 |
| P1-19 | 页面取消按钮立即 pop，destroy 与 cancelSend 并发执行 | `pages/MtaTransferPage.ets` | ✅ 已核对，良性并发不成立缺陷。立即 pop 是有意产品行为；并发共享路径全部幂等：endSession 有 sessionActive 闸门、nativeMtaStopServer 双调安全、disconnectGattClient 判空即返回、removeGroup 容忍 2801000、deleteStageDir 存在性检查；P0-1 引入的 cancelledThisSession + checkSessionAborted 检查点防止旧链路在 destroy 后继续推进。 |
| P1-20 | Rust start_server 入口守卫 TOCTOU，并发启动可产生双服务器 | `bridge/server.rs` | ✅ 已确认并修复。守卫检查 handle 后释放锁，而 handle 直到启动完成才写回，窗口内并发 start_server 均通过检查产生双服务器（前者被覆盖泄漏、无法停止）。新增 BridgeState.server_starting 标志：入口锁内检查并占用，注册成功与全部失败路径（端口重试失败/重试耗尽）清除。启动期间 stop_server 无法停止启动中的服务器属既有语义，未扩散范围。单元 139 + 集成 25 通过。 |
| P1-21 | Rust 持 state 锁做磁盘 IO + 证书生成，阻塞 JS 线程 | `bridge/identity.rs` | ✅ 已确认并修复。init_with_persisted_identity 全程持 state 锁做证书生成（首次可达数百毫秒）与磁盘读写，阻塞事件循环等所有 state 使用者；reset_security_context 持锁写盘，且原有写盘锁块与更新锁块之间存在并发分裂窗口。修复：新增 IDENTITY_LOCK 串行化身份操作，证书生成与磁盘 IO 全部移出 state 锁，state 锁仅覆盖短暂读写。单元 139 + 集成 25 通过。 |
| P1-22 | Rust ServerStopped / DeviceLost 事件从不发射（死事件） | `bridge/event.rs` / `bridge/server.rs` / `bridge/discovery.rs` | ✅ 已核对，确认为完整死链路，经决策保留。Rust 无发射点、ArkTS 无消费方；服务器停止的状态通知走 ArkTS 本地 serverRunning + notifyChange（调用方即停止方，无需事件回声）。两事件作为 LocalSend 协议事件模型的完整映射保留（含字段校验表条目），修复期间不做不必要的调整；未来实现意外停止/设备离线通知时再接入。 |
| P1-23 | Rust abort 窗口 fd 泄漏 + cancel 关键事件 try_send 可能丢弃 | `bridge/server.rs` | ✅ 已核对，部分成立。fd 泄漏不成立：发送方任何 abort 形态（取消/断连/决策超时释放 slot）下上游均发射 `PrepareUploadAborted`，桥接事件循环统一 `close_unconsumed_recv_fds`；decline 路径 fd 尚未注册；ArkTS respond 失败有 `discard_recv_file_fds` 回滚；stop_server 全量兜底。try_send 丢弃成立：`cancel_local_session` 的 `SessionEnd(Cancelled)` 为会话终态关键事件，channel 满时静默丢弃会导致 UI 收不到取消终态。已修复——事件发送移出状态锁，先 try_send、满时转后台线程阻塞投递（复用 /cancel 发送的 `std::thread::spawn + block_on` 模式）。 |
| P1-24 | Rust prepare_download 绕过桥接 DTO 直接序列化上游 resp.files | `bridge/client.rs` | ✅ 已核对，不成立。上游 `PrepareDownloadResponseDtoV2`/`InfoResponseDtoV2`/`FileDto` 均带 `serde(rename_all = "camelCase")`，透传序列化的字段名与 ArkTS 期望完全一致，仅为抽象泄漏（维护性），非运行缺陷。另发现整条 checksum 下载链在 ArkTS 侧无实际调用方（ChecksumRepository 四个对外函数在 AppService 仅死 import、无 re-export/调用），属既有死链路，按既有保留原则不动。 |
| P1-25 | Rust BridgeState 跨 Ability 残留（server_handle/discovery_handle/fd） | `bridge/state.rs` | ✅ 已核对，部分成立。单 Ability 应用不存在真正跨 Ability 并发；正常退出链路完整（onBackground 停 MTA → onWindowStageDestroy → 根页面 aboutToDisappear 停服务器，stop_server 全量清理句柄与 fd）；进程被杀时内核回收。唯一缺口：EntryAbility.onDestroy 无兜底——页面清理未执行且进程存活时，原生层句柄与预注册 fd 残留，重建后 start_server 返回 AlreadyRunning 造成两侧状态不一致。已修复：onDestroy 调用幂等的 stopMtaReceive + stopLocalServer（fire-and-forget）兜底。 |
| P1-26 | Rust 20ms 进度节流逻辑 4 份实现且行为漂移 | `bridge/server.rs` / `bridge/client.rs` | ✅ 已核对，成立。接收侧 `RecvProgressThrottle`（Option<Instant>）首条必达；发送/下载三处内联 `Instant::now()` 初始化导致首条被抑制（首帧进度最多延迟 20ms），行为漂移且 4 份实现无共享。已修复：提取共享 `bridge/throttle.rs::ProgressThrottle`（首条必达 + 20ms 间隔语义统一），server.rs 事件循环与 client.rs 三处（upload_file 闭包/download_file 流循环/upload_from_buffer 闭包）全部改用；纯节流测试迁至 throttle.rs（2 个），server.rs 保留跨层集成测试。 |
| P1-27 | Rust stop_share_server 清理集与 stop_server 不一致 | `bridge/server.rs` | ✅ 已核对，成立。stop_share_server 缺 active_transfers（取消令牌）、pending_requests、pending_decisions、session_peers 四项清理——分享服务器停止后残留累积直到下次 stop_server，期间 UI 轮询还会收到已死的过期请求。已修复：锁块内补齐四项清理与 stop_server 对齐。反向差异（stop_server 不 abort web_send_event_task）不成立：移除 web_send_event_tx 后发送端全部释放，任务 recv 返回 None 自然退出，无泄漏；相关失真注释已修正。show_token 不需补：重启 start_server 即覆盖。 |
| P1-28 | Rust pack_zip 同步 IO 阻塞 tokio worker | `bridge/mta/zip_stream.rs` | ✅ 已核对，成立。`native_mta_start_server`（napi async fn）最终跑在 4-worker tokio runtime 上，`pack_zip` 的 deflate 压缩与文件 IO 在 worker 线程同步执行，大文件打包会占死一个 worker，拖慢事件转发等其他任务。已修复：`mta::start_server` 中改用 `spawn_blocking` 执行打包。相邻 `build_tls_config` 的 rcgen 证书生成（ECDSA）耗时 <100ms，可接受，不动。 |
| P1-29 | Rust stop_server 不终止已接受连接（无 CancellationToken） | `bridge/mta/mod.rs` / `server.rs` | ✅ 已核对，成立。abort 仅作用于 accept 循环 task；每个已接受连接为独立 spawn 的 task，停止后继续服务——正在下载的对端可完整收完文件，"取消分享"语义不完整。已修复：MtaContext 增加取消令牌，stop_server 触发；accept 循环 select 感知退出、连接 task（TLS 握手 + hyper 服务）全程 select 感知（future drop 即关闭底层流、截断下载）、WS 升级完成后与状态机主循环均感知取消后主动关闭（不发失败事件，取消是本地主动行为）。 |
| P1-30 | Rust ws_connected 永不复位，WS 重连被静默拒绝且无事件 | `bridge/mta/mod.rs` / `ws.rs` | ✅ 已核对，成立。`mark_ws_connected` 置位后无任何复位点：对端断开后重连会被入口静默拒绝，发送流程无法恢复。已修复：run_ws 持有 Drop 守卫（`WsSlotGuard`），任何退出路径（正常收尾/出错/取消/panic）均复位 `ws_connected`，对端可重连。"拒绝无事件"不修：复位后拒绝只剩真正的并发重复连接（第一个 WS 仍在正常运行），此时发 `MtaSendFailed` 会污染正常流程状态，warn 日志足够。 |

## P2 低优先级 / 规范

| # | 问题 | 位置 | 核对结论 |
|---|------|------|----------|
| P2-1 | ~~规范禁止 `as` 断言但实际 100+ 处~~ 核对结论：一刀切禁止不合理（官方 FAQ 认可 `as` 为 ArkTS 动态边界标准姿势），已修订 AGENTS.md 规范为「禁止 any/unknown 与双重断言，允许动态边界 as」；存量 as 均属允许场景，个别判空后 `!` 非空断言另行修复 | 全项目 | ✅ 规范已修订 |
| P2-2 | `permission_bluetooth_reason` 缺 zh_CN 翻译 | `resources/zh_CN/element/string.json` | ✅ 已确认并修复。zh_CN 为近全量目录（324/325），独缺该权限文案；HarmonyOS 资源回退会兜底显示 base（中文）文案，无功能缺失，属目录维护完整性缺口。已补齐 zh_CN 条目（与 base 同文案）。zh_TW 目录本就无任何 permission_* 条目（整体依赖 base 回退的既有策略），不单独补。 |
| P2-3 | 文档 Target SDK 6.1.1(24) 与本地 build-profile targetSdkVersion 26.0.0 不一致 | `AGENTS.md` / `docs/ARCHITECTURE.md` | ✅ 已确认并修复。构建配置正确（targetSdkVersion 26.0.0 与本机 SDK API 26 / 26.0.0.105 一致，构建一直通过），文档过时。已将两处文档更正为 26.0.0(API 26)。 |
| P2-4 | MtaSendService.logs 只写不读；MtaReceiveService.destroy() 无调用方 | MTA service | ✅ 已确认并修复。logs 数组只写不读（UI 经 onLog 回调实时收取、hilog 另行输出），连同唯一关联的 clearLogs()（无外部调用方，HttpLogs 用的是 AppService 同名函数）与孤儿常量 MtaConstants.MAX_LOG_ENTRIES 一并删除。MtaReceiveService 为 MtaRepository 单例、永不销毁，停止走 stopService()；destroy() 无调用方且其独占清理项（crypto.reset/ble.destroy/p2p.destroy）在单例模型下不应执行（密钥对跨会话复用是既定行为），已删除。 |
| P2-5 | errorText 辅助函数 6 份重复 | `service/mta/*` | ✅ 已确认并修复。6 份实现逐字一致（md5 校验），已提取至 `utils/FormatUtil.ets` 统一导出，6 个文件（MtaCrypto/MtaBleReceiver/MtaP2pConnector/MtaBleClient/MtaP2pGroup/MtaTransferClient）删除本地副本改为 import。 |
| P2-6 | MtaReceiveModels.ets 名不副实（实为共享协议层） | `model/mta/MtaReceiveModels.ets` | ✅ 已确认并修复。该文件被发送侧（MtaSendModels/MtaSendService/MtaBleClient/MtaTransferClient）与主模型大量复用，文件头自述"供各 MTA 服务共用"，命名误导。已重命名为 `MtaProtocolModels.ets`（git mv 保留历史），测试文件同步改名，17 处引用更新，文件头注释更正为共享协议层定位。 |
| P2-7 | parseP2pInfo 不解析 freq 字段，发送端写入被静默丢弃 | `MtaReceiveModels.ets` | ✅ 已核对，不修。发送端写入 freq 是 P2pInfo 协议完整性要求（对端为第三方互传联盟设备，可能消费频点）；接收端凭据直连走 `WifiDeviceConfig` + `connectToCandidateConfig`，系统 API 不接受频点参数、系统自行扫描选网，解析 freq 后在本机无任何使用途径，补解析只会造出无人消费的死字段。"静默丢弃"描述准确但无功能影响。 |
| P2-8 | PROTOCOL_VERSION 双源硬编码且不做协商校验 | ArkTS + Rust | ✅ 已确认并修复。双源成立：ArkTS `MtaConstants.PROTOCOL_VERSION=1`（接收端 ack）与 Rust `mta/protocol.rs::PROTOCOL_VERSION=1`（发送端协商）。协商校验缺失成立：Rust 发送端 `wait_ack` 只看消息名不解析 ack 的 version；ArkTS 接收端无条件回 ack。已修复——Rust 发送端解析 ack 的 version，与本地版本不一致即发 MtaSendFailed；ArkTS 接收端新增 `isVersionNegotiationSupported` 纯函数（宽松策略：payload 缺失/解析失败/无版本字段视为兼容，老对端零影响），不兼容时报错断开不回 ack。双源常量保留（各自角色独立编译），协商校验使版本失配在握手期快速失败兜底。单元 141 + 集成 25 通过。 |
| P2-9 | sendRequest 的 ack 发送两次无注释 | `MtaTransferClient.ets` | ✅ 已核对，成立（注释缺失），行为正确已补注释。两次 ack 语义不同：首次为收到 sendRequest 的即时回执（让发送端 `wait_ack` 跳出 10s 确认等待），第二次（acceptRequest，id=1 对应发送端 SEND_REQUEST_ID）为用户接受后的协议确认——第三方发送端可能依赖该信号。第二次 ack 到达本机 Rust 发送端时其已进入 status 等待循环，按消息名不匹配被安全忽略。 |
| P2-10 | catShareText 无长度上限 | MTA 发送链路 | ✅ 已确认并修复。文本来源为剪贴板粘贴（handlePasteData），可携带数 MB 文本，catShareText 随 sendRequest 走 WS 单帧传输无上限，超大文本有撑爆 WS 帧与对端解析的风险。已修复：新增 `MtaConstants.MAX_SHARE_TEXT_BYTES`（256KB）与 `truncateUtf8Text` 纯函数（按 UTF-8 字节截断、不切断代理对），发送点截断 catShareText；完整文本仍经 sharedText.txt ZIP 条目送达，不丢内容。 |
| P2-11 | MAX_SEND_ENTRY_COUNT / MAX_SEND_TOTAL_BYTES 定义未强制校验 | `MtaConstants.ets` | ✅ 已确认并修复。两常量定义后全项目零使用（发送打包无校验），而接收端解压有 MAX_UNZIP_* 强制校验——超限内容需传完整个 ZIP 后才在接收端被拒，白耗一轮传输。已修复：sendToDevice 打包前校验条目数与总大小，超限 failSend 快速失败。 |
| P2-12 | BLEMtuChange 伪装成连接状态事件 | `MtaBleClient.ets` | ✅ 已确认并修复。BLEMtuChange 回调把 MTU 结果以 `MTU=517` 文本塞进 onGattConnectionChange，消费方日志显示"连接状态: MTU=517"语义失真（MTU 数据链路实际经 negotiatedMtu 字段轮询，事件仅用于日志）。已修复：回调集合新增 onMtuChange(mtu)，BLEMtuChange 改走独立回调，日志文案更正为"MTU 协商完成"。接收端（GATT Server）无此事件，不受影响。 |
| P2-13 | 本地化回退样板散布 10+ 处 | Repository 层 | ✅ 已确认并修复（主体收敛）。`if (appContext !== undefined) { getStringSync(...) } return '英文兜底'` 样板集中在 SendRepository 9 处，已提取模块内 `localizedText(res, fallback)` 辅助统一替换，并顺带补齐原样板缺失的 try/catch 异常隔离（原实现 getStringSync 抛异常会向上传播）。ServerRepository 剩 1 处为三元形态且复用外层已有 appContext 变量与 %d 替换，形态不同不强行统一。 |
| P2-14 | 一次性 UI 信号四种实现并存 | Repository 层 | ✅ 已核对，不修。四种形态为：ReceiveRepository 的 5 组 string + peek/consume 对（38 处外部调用）、SendRepository 的 boolean 完成标志、2 个 JSON 收件箱 set/consume 对、暂存清单 peek/consume/invalidate。对外契约已统一（peek/consume、set/consume 命名一致，各写入点均为覆盖写、consume 清空，无语义坑）；内部存储差异由负载类型决定（string/boolean/JSON/Array），非同一抽象的随意发散。引入泛型 OneShotSignal 要么改 38+ 处调用方签名（高风险扰动）要么保留函数包装（零收益），不值得。 |
| P2-15 | Rust 死状态字段（debug_log / share_link_info / recv_diag_drain_count）+ 双份相同导出 poll_debug_log | `bridge/state.rs` / `napi/identity.rs` | ✅ 已确认并修复。debug_log 无写入方（Rust 日志改走 identity 静态缓冲后遗留，drain 永远为空）；share_link_info 只写不读（ArkTS 分享链接来自 WebShareRepository）；recv_diag_drain_count 零读写。已删除三字段、ShareLinkState 结构体、server.rs 两处死写入、drain_debug_logs 中的空排空段；Rust 双导出收敛为 poll_debug_log 单导出（ArkTS 两个包装 nativePollDebugLog/nativePollDebugLogWithLevels 均有真实调用方，保留命名、内部统一调单一导出），index.d.ts 同步。单元 141 通过。 |
| P2-16 | Rust 双 tokio runtime 并存 + block_on 死代码 | `napi/env.rs` | ✅ 已确认并修复。NapiEnv::block_on 全仓无调用方（napi 层同步导出在 JS 线程执行、异步经 spawn 调度），已删除；cancel 路径临时 current_thread runtime 与全局 4-worker runtime 并存的问题随 P2-21 一并消除。 |
| P2-17 | Rust register_device 用 Debug 格式化 deviceType | `bridge/client.rs` | ✅ 已确认并修复。`format!("{:?}")` 依赖"变体名单词 + to_lowercase 恰好等于协议值"的巧合，上游若加多单词变体（Debug 与 serde SCREAMING_SNAKE_CASE 结果不一致）即产出错误值。已改用项目既有的 identity::device_type_to_string 显式映射（与 adapter 侧一致）。 |
| P2-18 | Rust 配置解析全部静默默认回退（拼写错误无感知） | `bridge/server.rs` / `discovery.rs` | ✅ 已确认并修复。新增 bridge/config.rs 类型化字段解析辅助：字段缺失 → 默认值（合法可选语义），字段存在但类型不符 → InvalidArgument 快速失败。已应用于 create_server（9 字段）、start_discovery_v2（8 字段，含白/黑名单数组元素校验，原先 filter_map 静默丢弃非字符串元素）、discovery_add_device、client.rs 两处目标设备解析（ip/port 改必填）。调用方为自家 ArkTS 类型化配置，正常路径行为不变。单元 147（含 6 个新辅助测试）+ 集成 25 通过。 |
| P2-19 | Rust 端口 as u16 静默截断 | 多处 | ✅ 已确认并修复。config u16 字段经 config::u16_field 校验范围（>65535 报错），client.rs 目标端口改 req_u16_field 必填校验；discovery.rs 分阶段发现通道列表中端口超界的通道跳过而非截断。 |
| P2-20 | Rust 无界日志缓冲（后台停止轮询后持续累积） | `bridge/identity.rs` | ✅ 已确认并修复。RUST_LOG_BUF 为无界 Vec，ArkTS 侧由 Discovery/Send/MtaSend 三个服务各自轮询排空，应用退后台或服务空闲期间无人排空时随日志持续增长。已改为 VecDeque + MAX_LOG_BUF_ENTRIES=2000 上限（满时挤出最旧条目），上限约 2000 条 × 单条百字节级 ≈ 数百 KB 封顶。新增有界追加单元测试（局部缓冲，规避并行测试对全局静态的竞态），单元 148 通过，napi feature 编译通过。 |
| P2-21 | cancel_local_session 每次取消裸起线程 + 新建 runtime | `bridge/server.rs` | ✅ 已确认并修复（与 P2-16 合并处理）。取消时两处（关键事件满时投递、/cancel 发送）各自 std::thread::spawn + 新建 current_thread runtime，纯异步任务无必要。已改为 cancel_local_session 接收全局 runtime 引用，两处直接 runtime.spawn；bridge 函数签名加 runtime 参数（napi 层传 NapiEnv 全局 runtime，测试内联建 runtime），消除双 runtime 与裸线程。单元 141 + 集成 25 通过。 |
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
