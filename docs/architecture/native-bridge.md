# NativeBridge 与 Rust NAPI 层详解

> NAPI 桥接函数清单、事件系统、进度追踪、Web Share 架构。
>
> 主文档 `docs/ARCHITECTURE.md` §4.3 / §5 保留概述。

## NativeBridge — NAPI 桥接

`entry/src/main/ets/service/NativeBridge.ets`

从 `localsend_ohrs` HAR 导入 Rust NAPI 函数，封装为 `native*` 函数并做类型转换。关键设计：HAR 接口参数为 JSON 字符串，NativeBridge 负责 `JSON.stringify` + 类型映射。

### NAPI 函数清单

| 函数 | 说明 |
|------|------|
| `nativeInit(alias, deviceType)` / `nativeInitWithPersistedIdentity(alias, deviceType, persistDir)` | 初始化桥接层；后者从持久化目录加载 TLS 身份 |
| `nativeStartDiscoveryV2(config)` | 完整配置启动 Rust discovery（discovery 统一入口） |
| `nativeDiscoveryDiscoverStaged(channels, ips, port, protocol, altProtocol, graceMs, forceSubnetScan)` | 分阶段发现：announce → probe → grace → 双协议并行子网扫描（force 时必扫），返回确认数（注 1）|
| `nativeDiscoveryScanSubnet(ip, port, protocol)` | 扫描子网 |
| `nativeDiscoveryAddDevice(device)` | 将 server register 事件反馈给 discovery store |
| `nativeDiscoverySetAnswerAnnouncements(answer)` | 控制 discovery 是否回应 announce |
| `nativeDiscoveryStop()` | 停止 discovery |
| `nativeDiscoveryGetDevice(fingerprint)` | 按 fingerprint 查询设备 |
| `nativeDiscoveryMulticastError()` | 获取 multicast 错误 |
| `nativeClientInfo(protocol, ip, port)` | GET /api/localsend/v2/info |
| `nativeComputeFingerprintHash(combined)` | SHA-256 哈希，用于指纹图标计算 |
| `nativeCreateServer(config)` | 创建服务器 |
| `nativeStopServer()` | 停止服务器 |
| `nativeGetServerStatus()` | 获取服务器状态 |
| `nativePollPendingRequests()` | 轮询待处理请求 |
| `nativeStartWebService(configJson)` | 启动自研网页服务，返回实际绑定端口 |
| `nativeStopWebService()` | 停止自研网页服务（幂等） |
| `nativeMarkWebServiceStopped()` | 标记分享已停止但保留服务，供页面显示结束态 |
| `nativeUpdateWebServiceFiles(filesJson)` | 就地替换网页分享文件表，返回生效文件数 |
| `nativeSetWebServiceUploadEnabled(enabled)` | 控制浏览器上传入口 |
| `nativeSetWebUploadTargets(token, targetsJson)` | 预置浏览器上传的落盘目标，返回生效条目数 |
| `nativeCancelWebDownload(batchId)` | 取消指定网页下载批次 |
| `nativeAcceptWebSession(token)` / `nativeDeclineWebSession(token)` / `nativeExpireWebSession(token)` | 接受 / 拒绝 / 令待确认浏览器会话过期 |
| `nativeRespondTransfer(sessionId, accept, acceptedFileIds)` | 响应传输请求（同步 void；accept 前需先经 `nativeRegisterRecvFileFd` 逐文件预注册直写目标） |
| `nativeSendFiles(target, senderAlias, files)` | 发送文件（files 携带 `fd` 内容源描述符；fd≥0 由 Rust 直读源文件，否则回退 filePath） |
| `nativeRegisterRecvFileFd(sessionId, fileId, fd, path)` | 预注册接收文件的直写目标 fd（fd-direct：respondTransfer 前逐文件调用，写入完成/会话终态由 Rust 关闭） |
| `nativeDiscardRecvFileFds(sessionId)` | 丢弃某会话已注册但未开始上传的直写 fd（respond 失败/回滚时调用） |
| `nativeCancelTransfer(target, sessionId)` | 向对端设备发送取消传输请求 |
| `nativeCancelTransferLocal(sessionId)` | 取消本地传输 |
| `nativeCancelLocalSession(sessionId)` | 取消本地会话 |
| `nativeGetCurrentSendSessionId()` | 获取当前发送会话 ID |
| `nativeFlushRustLogs()` | 轮询 Rust 日志缓冲并按原始级别输出到 hilog（`level\|target\|message` 前缀分割） |
| `nativePollDebugLogWithLevels()` | 带级别的 Rust 日志轮询（返回原始 `level\|target\|message` 元素，供 MTA 链路按级别还原展示） |
| `nativeSetRustLogLevel(level)` | 同步 Rust 日志级别，供诊断日志开关联动 |
| `nativeHashFileStream(filePath, cancelId)` | 文件流哈希（沙箱路径版） |
| `nativeHashFileStreamFd(fd, cancelId)` | 基于文件描述符的流式哈希（fd-direct 源文件哈希；fd 由 Rust 关闭） |
| `nativeCancelHash(cancelId)` | 取消哈希 |
| `nativeHashBuffer(buffer)` | 缓冲区哈希 |
| `nativeFailFileUpload(sessionId, fileId)` | 标记文件上传失败 |
| `nativeGetNetworkInterfaces()` | 获取网络接口列表 |
| `nativeSanitizeFileName(name)` | 清理文件名 |
| `nativeCreateCancelToken()` | 创建取消令牌 |
| `nativeGetSecurityContext()` | 获取当前生效的 TLS 安全上下文（证书/公钥/私钥/指纹，用于安全信息展示） |
| `nativeResetSecurityContext()` | 重置 TLS 证书：重新生成自签名证书与密钥、覆盖持久化身份文件并更新 BridgeState |
| `nativeMtaStartServer(config)` | 启动 MTA 发送端 TLS 服务器（同一端口承载 `wss /websocket` 与 `https /download`，下载以流式 ZIP 响应、不预打包），返回实际绑定端口；配置细节见注 2 |
| `nativeMtaStopServer()` | 停止 MTA 发送端服务器（幂等） |
| `nativeMtaRejectPeer()` | 登记「向对端回送取消」意图（不停止服务器、不触发取消令牌；服务器不存在时为空操作）；回送时机见注 3 |
| `nativeGetInterfaceMac(interfaceName)` | 读取指定网络接口的硬件地址（MAC，形如 `AA:BB:CC:DD:EE:FF`；接口不存在或读取失败返回空串），经 `getifaddrs` 取 `AF_PACKET` 地址。<br>MTA 发送端用于取本机 P2P 设备地址填入 `P2pInfo.mac`（小米端会校验该值，详见 MTA 文档 §4.2） |
| `nativeMtaFetchThumbnail(goIp, port, taskId, targetDir, maxBytes)` | 接收确认阶段拉取 MTA 发送端缩略图；失败返回空串且不阻断接收 |
| `nativeMtaReceiveDownload(goIp, port, taskId, targetDir, ...)` | 参数与行为见注 4 |
| `onBridgeEvent(type, handler)` / `offBridgeEvent(type, handler)` | 类型化事件订阅（按事件类型 on/off 分发） |
| `verifyNativeVersion()` | 验证原生库版本兼容性 |
| `getNativeLibraryVersion()` | 获取原生库版本号 |
| `getLocalSendProtocolVersion()` | 获取 LocalSend 协议版本 |

> **注 1**：已知通道由收藏与当前已发现设备组成，ArkTS 同时传入默认接口 ips 以启用子网扫描兜底。
> 探测已知通道只证明 HTTP 可达，不证明组播可用，因此只有组播 announce 应答或 server register
> 回写带来的确认才会跳过子网扫描。兜底扫描同时覆盖 `protocol` 与 `altProtocol` 并各接口并行：
> 局域网内可能只有一种协议的设备（官方 LocalSend 默认 https、HandySend 默认 http）。
> `forceSubnetScan=true` 用于用户刷新与启动首扫：局域网内可能有不响应组播、只能通过 HTTP
> 探测发现的设备（如 PC 防火墙拦截入站组播），此时任何组播/register 确认都不足以证明没有漏设备。
>
> **注 2**：`nativeMtaStartServer` 的配置可选 `textContent`（文本发送时随 `sendRequest` 携带
> `catShareText`，缺省行为不变）；`files[]` 条目必带 `sizeBytes`（源文件大小，取自 ArkTS
> `statSync`，供进度分母、大小一致性校验与 ZIP64 判定），可携带可选 `fdSend`（ArkTS
> `openSync` 打开的源文件描述符，缺省 -1 按 `path` 回退读取），fd 自本次调用起所有权归
> Rust（失败路径亦由 Rust 关闭）。
>
> **注 3**：取消状态由原生 WS 状态机在对端接入或等待阶段回送，成功后经 `mtaRejectSent`
> 事件通知；用于发送页取消时通知对端，等待对端被通知或由上层结束会话。
>
> **注 4**：完整签名 `(goIp, port, taskId, targetDir, totalBytes, maxEntries, maxTotalBytes,
> maxEntryBytes, cancelTokenId?, connectTimeoutMs?, stallTimeoutMs?, headerTimeoutMs?)`。
> 接收端 Rust 主导下载：直接请求 `https://<goIp>:<port>/download?taskId=`（跳过服务端证书
> 校验）、流式解压并直接写入 `targetDir`（防穿越/忽略目录/重名 `(n)`/还原条目时间/上限），
> 返回落盘元数据 JSON `[{name, size, modifiedUnixMs, savedPath}]`；失败/取消删除本次已写
> 文件。`maxTotalBytes` 为解压总量上限（由 ArkTS 按对端声明值与容差计算）、`maxEntryBytes`
> 为单条目解压上限（0 表示不限制）；`connectTimeoutMs`/`stallTimeoutMs`/`headerTimeoutMs`
> 分别覆盖连接、下载停滞与等待响应头超时（缺省用 Rust 侧默认值）。

> 完整封装清单以 `entry/src/main/ets/service/NativeBridge.ets` 为准。

### Discovery 说明

announce 由 `nativeDiscoveryDiscoverStaged` 内含触发；ArkTS 刷新时向已知设备（收藏 + 已发现快照）
逐个发送确认探测 + 组播广播，并在用户刷新、启动首扫与网络变化后按 http/https 双协议强制扫描子网；
扫描结束后移除本轮未回应的离线设备；扫描中再次点击刷新合并排队（最多补扫一次）。

## Rust NAPI 层

`localsend_ohrs/rust/`

```
lib.rs                   # crate 入口：pub mod bridge + #[cfg(napi)] pub mod napi
bridge/                  # 桥接层（纯逻辑，不依赖 runtime/NAPI，可脱离 napi feature 编译/测试）
  ├── mod.rs              # 模块声明 + pub use 重导出
  ├── event.rs            # BridgeEvent 强类型事件 + BridgeError + 事件分类常量
  ├── state.rs            # BridgeState 纯数据（无 runtime/callback）
  ├── engine.rs           # StateAction + apply_actions 纯函数状态变更
  ├── identity.rs         # init/安全上下文/网络信息/哈希/取消令牌/日志工具
  ├── server.rs           # 服务器生命周期 + 传输决策 + WebSend（含事件循环 task）
  ├── client.rs           # HTTP 客户端操作（发送、注册、取消、clientInfo、下载）
  ├── discovery.rs        # 发现生命周期 + 扫描 + 设备查询（含事件循环 task）
  ├── mta/                # MTA 发送端 TLS/WS/HTTP/ZIP 服务器 + 接收端 Rust 主导下载（工程自有代码）
  │   ├── mod.rs          # 服务器生命周期（start/stop、配置解析、事件发射）
  │   ├── protocol.rs     # 应用层消息纯函数（构造/解析/JSON、status 判定）
  │   ├── zip_stream.rs   # 按文件清单库化流式写出 ZIP（无 Seek 流式；Deflated 统一档、ZIP64 自动启用；数据源 ArkTS fd 或路径回退）
  │   ├── unzip_stream.rs # 自有 ZIP 流式解析/解压核心（Stored/Deflated/带与不带签名数据描述符/ZIP64 扩展字段）+ 条目数/解压总量/单条目字节上限等安全约束
  │   ├── receive.rs      # 接收端 Rust 主导下载（reqwest + 流式解压 + 直接写目标目录 + 进度/取消/回滚）
  │   ├── ws.rs           # WS 连接上的 MTA 状态机
  │   └── server.rs       # hyper + tokio-rustls TLS 服务器（/websocket 升级、/download 流式 ZIP）
  └── adapter/            # 上游类型隔离
      ├── server.rs       # ServerEventV2/InternalEvent → (BridgeEvent, Vec<StateAction>)
      ├── multicast.rs    # MulticastEvent/DiscoveryEvent → BridgeEvent
      ├── client.rs       # ClientError → BridgeError
      └── types.rs        # DTO 定义 + 上游↔DTO 转换（纯函数）
napi/                    # NAPI 适配层（napi feature 门控，按入口域组织）
  ├── env.rs              # NapiEnv（OnceLock 持有 Runtime + BridgeState + event_rx）
  ├── event_forwarder.rs  # 事件转发（napi_threadsafe_function，按事件类型分发）
  ├── identity.rs         # init/安全上下文/哈希 NAPI 入口
  ├── server.rs           # 服务器/传输决策/WebSend NAPI 入口
  ├── client.rs           # 发送/接收/取消/注册 NAPI 入口
  ├── discovery.rs        # 发现 NAPI 入口
  ├── mta.rs              # MTA 发送端服务器启停 + 接收端 Rust 主导下载 NAPI 入口（nativeMtaStartServer/StopServer/ReceiveDownload）
  └── mod.rs              # #[napi] 对象结构 + 模块声明
```

`napi` feature（默认启用）控制编译范围：启用时编译 NAPI 适配层（`napi/`）；关闭（`--no-default-features`）时仅编译 `bridge/` 模块，可在 Linux native target 上运行 `cargo test`。

### zip_stream 约束（`bridge/mta/zip_stream.rs`）

- `ZipWriter::new_stream` 无 Seek；条目压缩方法恒为 Deflated——无 Seek 写出必然产生数据描述符，而对端解析器只接受压缩方法条目携带描述符
- 所有条目统一使用同一压缩档位，不按文件类型区分
- ZIP64 由库在条目超 32 位上限时自动启用；CRC 由库写出时计算
- 数据源为 ArkTS 直传 fd，文本条目回退沙箱路径；逐条目写源文件修改时间

### 架构关键点

- **runtime 归 NAPI 层**：`NapiEnv::global()`（OnceLock）持有 tokio Runtime（multi_thread, 4 workers）+ `&'static Arc<Mutex<BridgeState>>`
  + `event_rx`。桥接层函数通过参数接收 `Arc<Mutex<BridgeState>>` 或 `&Mutex<BridgeState>`，不感知 runtime
- **事件流**：`init` 时创建 `mpsc::channel::<BridgeEvent>`，sender 注入 `state.event_tx`，receiver 存入 `NapiEnv.event_rx`；
  `register_event_callback` spawn 消费任务，逐事件序列化（`{"type":"...","payload":{...}}`）经 `napi_threadsafe_function` 投递到 ArkTS 主线程
- **事件循环 task**：`start_server`/`start_discovery_v2`/`spawn_web_send_event_task` spawn 的事件循环 JoinHandle 存于 BridgeState，`stop_server`/`stop_discovery` 时 abort
- **adapter 隔离上游类型**：上游 `ServerEventV2` 变更时只需修改 `adapter/server.rs`（match 穷尽检查引导适配）；`adapt_xxx(event) -> (Option<BridgeEvent>, Vec<StateAction>)`
  + `apply_actions(&mut BridgeState, actions)` 为纯函数，零网络零 runtime 可单测
- **桥接层函数命名**：无 `do_` 前缀、无 `_facade` 后缀，函数名即公共 API 名
- **幂等性与错误语义**：重复 `start_server` 返回 `AlreadyRunning`；未启动 `stop_server` 幂等 Ok；重复/竞态 `accept_transfer` 返回 `SessionExpired`。
  `BridgeError::code()` 给出机器可判定编码（展示文本不变，跨语言分支用；NAPI 透出消费尚未闭环）

### 进度追踪

发送端上传/接收端保存时以 20ms 节流推送 `BridgeEvent::UploadProgress { sessionId, fileId, direction, progress, speed }`（高频瞬态事件，channel 满时 `try_send`
丢弃，不阻塞关键事件送达）。进度值 `progress` 为 0.0~1.0，`direction` 为 `"send"`/`"recv"`。ArkTS 侧从会话文件映射补齐 bytesSent/totalBytes/filePath。

校验和计算时按块推送 `BridgeEvent::ChecksumProgress { cancelId, hashedBytes }`（高频瞬态事件，`try_send` 丢弃）：
`cancelId` 为本次哈希的取消令牌 id，`hashedBytes` 为该文件累计已哈希字节（分母由 ArkTS 侧按文件大小提供，事件不携带总字节）。
`hash_content` 从 `BridgeState` 克隆事件发送端，把 `sha256_file_content` 的进度回调接为事件上报；ArkTS 按 `cancelId` 汇聚为准备进度写回发送会话。

### 事件推送

所有事件（discovery/server/web share/mta）通过 mpsc channel 以强类型 `BridgeEvent` 输出，NAPI 层经 `registerEventListener` 注册的 napi_threadsafe_function 推送。
事件按关键/可丢弃分类：关键事件（PrepareUpload、SessionEnd、DeviceFound、DeviceLost、ServerStarted/Stopped、WebAccess/WebDownload*、Mta*（进度除外）、Error 等）`send().await`
发送并带 1 秒超时防护（无消费者或通道满时丢弃并告警，不永久阻塞事件循环）；`UploadProgress`、`ChecksumProgress`、`MtaSendProgress` 与 `MtaReceiveProgress` `try_send` 丢弃，但可判定终值（进度 100%）者按关键事件送达
（每文件完成判定的依据，不得因 channel 满而丢失；`ChecksumProgress` 无终值判定，每文件完成由 ArkTS 侧 `await` 返回时确定）。ArkTS 侧通过 `NativeBridge.onBridgeEvent(type, handler)` 按类型订阅。

MTA 发送端事件：`mtaServerStarted{port}`、`mtaWsConnected`、`mtaVersionNegotiated{version}`、`mtaSendRequestSent{taskId}`、`mtaRejectSent{taskId}`（取消状态已成功写入对端连接，视为「已通知对端」
）、`mtaDownloadStarted{taskId}`、`mtaSendProgress{sentBytes,totalBytes,percent,networkBytes}`、`mtaSendCompleted{taskId}`、`mtaSendPartial{reason}`、
`mtaSendRejected{reason}`、`mtaSendFailed{reason}`。MTA 接收端进度事件：`mtaReceiveProgress{receivedBytes,totalBytes,percent,networkBytes,networkDone}`（接收由
Rust 主导，进度分子为已解压字节、分母为声明总大小；`networkBytes` 为网络字节口径的速率分子，`networkDone` 表示网络数据已全部读入、
仍在解压/落盘）。跨层字段契约由 `bridge/event.rs::test_all_event_variants_payload_contract` 与 `tests/src/integration/napi_guard.rs` 双端钉死。

MTA 原生文本：`MtaServerConfig`/`MtaContext` 携带可选 `text_content`（JSON `textContent`）；`sendRequest` payload 的 `SendRequestPayload` 携带可选 `cat_share_text`（序列化为
`catShareText`，缺省不序列化）。文本内容以 ZIP 单条目 `1/sharedText.txt` 随包发送，接收端解析 `catShareText` 后按文本消息处理，字段缺省时行为与不含文本的发送完全一致。

文件时间契约：局域网发送文件 JSON 可携带可选 `lastModified`（Unix 毫秒），`bridge/client.rs` 将其转为 RFC 3339 填入上传 `FileDto.metadata.modified`（缺省不填，接收端核心落盘后应用）；
MTA 待发送条目可携带可选 `lastModifiedMs`，`zip_stream.rs` 据其写入 ZIP 条目时间，接收端 `receive.rs` 流式解压时读回条目时间并在写盘后还原。两处字段均为可选，缺省时行为与既有完全一致。

## Web Share 架构

浏览器分享由自研独立服务实现（`bridge/web/`，与 LocalSend/MTA 同级、端口独立），设备对设备 v2 协议不受影响：

### 服务与会话

1. ArkTS `WebShareRepository` 组装配置（别名、本次访问码、能力令牌、上传开关、上传目录、文件表、首选端口）→ `start_web_service`
   启动 hyper 服务 → 返回实际端口 → 出示地址、二维码（URL 携带 `?t=<能力令牌>`）与本次访问码
2. 浏览器经二维码能力令牌或本次访问码门禁，二者并列、任一通过即可：
   `GET /?t=`（或 `/upload?t=`）校验令牌后下发 HttpOnly Cookie
   （`handysend_web_cap`，HTTPS 下为 `handysend_web_cap_https` 且带 `Secure`；绑定对端 IP 与 User-Agent 摘要）并 302 到去掉令牌的干净地址；
   无令牌打开裸地址时渲染整页访问码页；
   令牌错误或服务重启后旧链接失效时返回「链接已失效」提示页。
   `POST /web/auth` 校验访问码并下发 `handysend_web_auth`（HTTPS 下为 `handysend_web_auth_https` 且带 `Secure`；同样绑定 IP/UA），
   裸地址可直接提交，不要求先持能力 Cookie；
   `/caps`、建会话、下载、上传与完成回执要求能力 Cookie 或访问码 Cookie 之一。
   两种 Cookie 均按协议区分名称：浏览器禁止 HTTP 源用同名非 Secure Cookie 覆盖 HTTPS 下发的 Secure Cookie，
   否则关闭加密传输后，访问码登录成功也不会被浏览器保存。
3. 浏览器建会话即出示文件清单（下载）/声明清单（上传），会话键为浏览器 UUID token（IP 绑定，多标签/多浏览器互不踢）；
   `GET /caps` 只读快照，不建会话。下载会话只做授权与快照缓存：绝对 TTL 2 小时、最多 32 个，
   页面每次下载前 prepare 刷新；访问只记日志并续期网页保活，不建任务。
4. 上传仍走待确认流程（`PrepareUploadRequested`，接受/拒绝/过期）；下载不等待应用确认，
   页面门禁通过即直接回文件表。下载批次开始/结束经 `WebDownloadStarted` / `WebDownloadEnded` 收口；
   上传完成回执（`POST /web/finish`）与惰性打扫收口上传终态。

二维码与本次访问码是并列的页面入口：扫描二维码免密进入，裸地址展示访问码页。
访问码由客户端每次启动服务时生成（6 位数字，仅本次分享有效），分享停止或服务重启即失效，不进入设置持久化；
服务端仍兼容空值与旧调用（测试），空值表示免访问码。
能力令牌只解决「谁可以打开页面」：令牌可能被转发/截图，IP+UA 绑定也不构成强身份；
设置访问码时，通过任一入口即构成外发授权。生产环境始终有访问码/能力令牌；无门禁仅测试/旧调用放行并告警。

服务监听 `0.0.0.0`（全部网卡）；`WebServiceConfig.port` 为 0 时由系统随机分配，非 0 时优先绑定该端口，
被占用则回退随机端口并返回实际端口。ArkTS 侧在本次进程内复用上次实际端口，应用重启后重新优先尝试配置端口；实际端口与设置端口不一致时面板提示回退。
`WebServiceConfig.capability` 为本次服务实例的二维码/URL 能力令牌，缺省或空串时不启用能力门禁（兼容旧调用与测试）。
`WebServiceConfig.pin` 为本次访问码：ArkTS 每次启动生成 6 位数字，服务端校验非空值为 6 位数字；
空值兼容旧调用与测试，表示免访问码。

服务生命周期由 ArkTS 侧网页传输总开关驱动（`applyWebSendAllowed` / `restoreWebService`），允许上传子开关经 `applyWebReceiveAllowed` 控制上传入口，
与 LocalSend 服务器启停互不联动；启动前自行刷新网卡以取本机地址，不依赖 LocalSend 服务器的启动流程。
网页服务运行中进入后台时申请 5 分钟有界 `dataTransfer` 长时任务（通知「网页分享保持中」），
期间有访问/传输则续期；回到前台、删除通知或超时无活动时停止。

### 下载（本机 → 浏览器）

- 单文件 `GET /web/download`：按 token 查快照归属后下发；fd 内容源在换表时由保留区 `dup` 私有副本、
  请求定位时再复制一份消费（`pread` 显式偏移直读，同一文件可重复/并发下载），路径内容源走文件流式读；支持 Range 分片。
- 多文件 `POST /web/download-batch` 登记选中文件（或 `all=true`）→ `GET /web/download-batch?batch=` 流式 ZIP；
  一个批次一个任务，ZIP 条目以文件名去重、不预打包、不落临时文件；批次在首次 `GET` 时消费，
  重复请求返回 410，页面每次点击需重新登记。
- ZIP 使用 `Stored`，发响应头前按条目名/大小精确计算 `Content-Length`（含 Zip64），
  浏览器下载管理器因此能显示百分比；条目时间取源文件本地时间，单个文件 ≥4GB 使用 `large_file`。
- 批次事件 `WebDownloadStarted` / `WebDownloadProgress` / `WebDownloadFileDone` / `WebDownloadEnded`
  （`batchId` 为任务主键）；任务取消调用 `cancel_web_download`，响应在下个读块停止。
- 文件表热换仍版本号单调增，被删文件保留宽限；页面通过 `/web/events` SSE 感知变化并
  静默重拉完整文件表，短暂提示「文件列表已更新」；15 秒低频 `/caps` 轮询兜底。
- 网页访问只在新建 token 时发 `WebAccess`（IP/UA/文件数），应用只记日志并续期有界保活；
  下载没有页面心跳、leave、下载 session-end。停止分享先 `mark_web_service_stopped`
  标记 stopped 并广播，保留服务约 30 秒供页面收尾/刷新，再由 `stop_web_service` 关闭监听。
- 服务硬停止/重启会关闭已有 TCP/SSE 连接，避免浏览器复用旧 keep-alive 连接读到停止态。

### 上传（浏览器 → 本机）

- 每客户端独立上传槽（不占用 v2 全局单槽）；默认需确认，接受即全量；面板可开启“上传免确认”，
  与暂存文件列表解耦，应用重启或手动停止网页服务后重置
- 建会话立即回 202 并下发 token，页面轮询 `/web/upload-status` 等待应用确认；页面按标签页 client
  且同一批文件复用响应丢失的会话，换批或新标签页（含复制标签页）各自建会话；状态查询兼作页面心跳，取消离开宽限
- ArkTS 确认前经 `set_web_upload_targets` 预置最终落盘路径（普通文件进用户设置的接收目录，默认
  `Download/<包名>/`，重名自动加后缀；
  文本条目进接收文本目录（首次使用时创建）；仅单条文本消息记为文本消息）；
  服务端按声明大小流式落盘（超量 413），完成改名并经 `WebUploadProgress`/`WebUploadDone` 上报
- 未完成字节写在目标目录下的应用保留子目录 `.handysend-temp/web/`（与最终文件同父目录，完成后原子改名；
  临时区按协议分子目录，其他协议的同名临时文件不会被本协议清理）；会话终结（完成/拒绝/取消/超时/停止服务）时删除未完成文件并移除已空的临时目录；
  进程被强制终止时留下的半成品由下次接受上传时清理，旧名 `.handysend-upload-part` 作为 legacy 目录清理，
  不会触碰用户文件或已交付文件。
  页面关闭/刷新时标记离开，服务端 15s 宽限后结束会话；刷新后的页面按 caps 的 shareId 核对分享归属，
  同一分享才按 token 恢复上传状态：待确认期间保持发送入口禁用，应用已接受但刷新后无法续传时
  结束会话并提示重新发送；分享已更换则丢弃旧 token。
- 终结/过期只清理未完成的临时文件，不删除已改名为最终交付物的文件
- 上传建会话的文件 DTO 携带 `preview`（仅手动文本），接收端据此识别单条文本消息；
  文件与文本混合时文本按普通文本文件处理
- ArkTS 侧按 token 归属统一会话（`WebUploadAdapter`），终态后写接收历史；开启免确认时建会话后直接预置落盘目标并放行；任务声明 `canCancel`，
  结束任务时移除服务端上传会话，正在写入的请求体在下个读块停止并清理临时区
- 上传终态以建会话时的声明清单为准：清单内文件全部落盘即按成功终结，无需等待静默窗口；
  静默窗口只作兜底，覆盖完成事件缺失等异常情形。落盘完成事件同时回填最终路径，供接收历史与「保存到相册」读取

### 关键设计

- 原始读 fd 所有权归 ArkTS（`WebShareRepository` 持有 `fs.File` 阻止 GC 关闭，在停止/替换分享、创建失败时关闭），Rust 每次下载仅 `dup` 副本消费、从不关闭原始 fd
- 单页（`bridge/web/assets/single.html`，与服务同仓）按 `/caps` 条件渲染下载/发送页签；文案经 `/i18n.json`
  按浏览器语言或页头选择下发（简体/繁体/英文，失败回退内置简体中文）；主题与语言偏好保存在浏览器本地
- NAPI 层（`napi/web.rs`）只做薄封装，逻辑归属 `bridge/web/runtime.rs`（全局单例：服务状态 + 服务任务 + 转发任务）

## fd-direct 收发（直读/直写，无沙箱中转拷贝）

发送与接收均以文件描述符直读/直写，避免全量拷贝进沙箱再上传/导出的两段式 IO：

- **发送**：`prepareSendFiles` 不拷贝文件，`SendFileItem.filePath` 承载源定位（picker URI 或沙箱路径）；`sendToDevice` 每次 `nativeSendFiles` 前优先 `dup` 暂存句柄，句柄失效时按路径打开，并携带 `fd`。
  fd 所有权契约：调用返回后 Rust 对所有传入 fd 负全责（被上传消费的经 `from_raw_fd` 关闭，prepare 失败/取消/未轮到上传的由 `close_remaining_fds` 统一关闭），ArkTS 侧重试前重新打开
- **接收**：确认接收时（`respondToRequest`/auto-accept 内部 `acceptWithTargets`）先经
  `ReceiveDirectory.ensureReceiveDirectory` 获取接收目录（默认经 `DocumentViewPicker.save`
  DOWNLOAD 模式取 Download/`<包名>/`；自定义目录经 FOLDER Picker 选择并持久化读写授权）→
  `uniquePath` 消歧计算最终路径 → 在 `.handysend-temp/local-send/` 下创建临时文件并 `openSync` 写 fd →
  `registerRecvFileFd` 预注册（携带最终路径）→ 再发送 accept。Rust `handle_file_upload` 只消费预注册 fd
  构造 `FileUploadTarget::Fd`（无注册按失败处理，不落沙箱），写入完成后由结果任务 `rename` 到最终路径；
  会话终态（SessionEnd/Aborted/Cancel/本地取消）由 `close_unconsumed_recv_fds` 关闭未消费 fd。
  `finishReceiveSession` 直接用登记路径写历史；取消/失败时 ArkTS 只删除临时区未完成文件，
  已提交文件保留并补记接收历史
- **文本消息**：与普通文件走同一目标准备入口、按条目分流目录（普通文件落接收目录、
  文本消息 `filesDir/text_recv/`，同重名规则，文本即文件、长期保留）；进度兜底显示与取消清理仍尝试
  `{cacheDir}/receive/` 旧路径，冷启动清扫该目录残留。哈希（创建校验和）对源文件 openSync 后经 `hashFileStreamFd` 计算

### 网页资产（自研单页）

`bridge/web/assets/single.html` 为单文件页面（零外部资源），经 `include_str!` 编译进 `.so`，与服务同仓维护：

- 按 `/caps` 条件渲染下载/发送页签；下载走浏览器下载管理器（大文件无内存压力），
  文本类文件无预览字段时用 Range 取前 128KB 内联预览
  - 预览允许读取建会话后新增的当前文件表条目；真实下载仍按会话快照隔离
- 下载 token 存于 `sessionStorage`，刷新时直接 prepare 复用或重建会话，不发送心跳；
  上传 token 与所属 shareId 存于 `sessionStorage`，刷新后先核对 caps 的 shareId；
  建会话立即回 202（token/shareId），页面轮询 `/web/upload-status` 等待确认；
  同标签页按持久化 client 且同一批文件复用响应丢失的会话，换批或新标签页（含复制标签页）各自建会话；
  同一分享才按 token 恢复：待确认期间保持发送入口禁用，
  已接受但刷新后无法续传时结束会话并提示重新发送；
  上传顺序直传（XHR 看进度），
  文件与文本合并为一次上传：仅文本时 `message.txt` 携带 `preview`（文本消息），
  混合内容时文本作为 `message.txt` 随文件发送（文本文件）
- 建会话立即返回 202，页面轮询 `/web/upload-status` 等待确认：待确认时提示「等待对方确认」，
  接受后开始逐文件上传，拒绝/超时（状态查询 404）提示失败；每次发送开始先清掉上一次遗留的提示
- 页头可切换主题（跟随系统/浅色/深色）与语言（简体/繁体/英文），偏好存于浏览器 `localStorage`
- 下载页支持多选 + zip 批次：单文件直接下载，多文件由服务端统一 zip；浏览器用精确 `Content-Length` 显示进度；
  点击整行或复选框均可勾选，Shift 连选按展示顺序处理整段，Ctrl/Cmd+A 全选、Esc 取消全选
  （输入控件与预览正文内保留原生快捷键）；文件名可拖选或长按复制，触屏仅从复选框起手才能滑选多行；
  窄屏与触屏下文件名换行完整展示；
  文件列表经 SSE `/web/events` 感知变化后静默重拉完整文件表，实时更新并短暂提示「文件列表已更新」
- 访问码页（服务端按 Cookie 注入 `data-auth`，裸地址进入时展示）、错误码映射（401/403/404/410/413；上传另有 202/409）、
  上传全部完成后 `sendBeacon` 上报完成回执

## Discovery — 设备发现

设备发现由 Rust 核心的 `localsend::discovery` 模块实现，ArkTS 层通过 `DiscoveryRepository` 调用 NativeBridge 函数。

### Rust 核心发现功能

- **UDP 组播**：`224.0.0.167:<配置端口>`（默认 `53317`；组播端口跟随"端口"设置，与官方 LocalSend 一致），支持 hot-restart（新实例自动停止旧实例）
- **分阶段发现**：桥接层编排 announce → probe 已知通道 → 等待宽限期 → 子网扫描兜底
  （主/备用协议并行）。只有组播 announce 应答或 server register 回写带来的确认才跳过
  子网扫描：已知通道探测成功只能说明 HTTP 可达，组播仍可能被网络阻断。用户刷新、
  启动首扫与网络变化后强制扫描子网（并跳过宽限期），覆盖完全不响应组播、只能 HTTP
  探测的设备
- **设备 store**：去重、多 channel 合并、ranked channels、超时清理
- **事件推送**：设备变化经 mpsc channel 推送 `DeviceFound`（发现/更新）/`DeviceLost`（超时移除）事件

### 网络过滤

白/黑名单存储接口名（如 `wlan0,eth0`），按接口名粒度控制。启用判定统一由 `utils/NetworkInterfaceRules` 的
`isInterfaceEnabled()` 给出：黑名单优先排除，白名单放行，两者都未列出的接口按类型取默认。
`computeDiscoveryWhitelistFrom()` 将启用的接口映射为网段通配（按 prefixLength 生成 `a.b.c.*`），
传入 Rust `InterfaceFilter.whitelist`；黑名单接口 IP 直接传入 `InterfaceFilter.blacklist`。
`getLocalDeviceInfo()` 用同一判定过滤，保证组播绑定与子网扫描的接口一致性。首次启动时
`ensureDefaultNetworkLists()` 按接口类型初始化名单，此后新出现的接口不写入名单、直接按类型取默认。

接口类型分六类，判定依据、默认启用状态与展示排序如下：

| 类型 | 判定依据 | 默认启用 | 排序 |
| --- | --- | --- | --- |
| `wifi` | `wlan*`/`wifi*`/`ap*`/`p2p*`，含 SoftAP 与 Wi-Fi Direct | 是 | 0 |
| `ethernet` | `eth*`/`usb*`/`en*`/`br*`（普通桥接） | 是 | 1 |
| `vpn` | `tun*`/`tap*`/`wg*`/`zt*`/`tailscale*` 等 VPN 与隧道接口 | 是 | 2 |
| `bridge` | `anco*`/`docker*`/`veth*`/`virbr*` 等容器网桥（Docker 为 `br-<12 位十六进制>`） | 否 | 3 |
| `unknown` | 其余（含蓝牙网络、`ppp*`） | 否 | 4 |
| `cellular` | `rmnet*`/`ccmni*`/`wwan*` | 否 | 5 |

类型优先取 `connection.getAllNetsSync()` 的 `ConnectionProperties.interfaceName` 匹配结果，由 `bearerTypes`
映射（`BEARER_WIFI`/`BEARER_CELLULAR`/`BEARER_ETHERNET`/`BEARER_VPN`）；匹配失败时按接口名前缀补判。
SoftAP（热点）与次要 STA 没有 netId、不注册 NetworkAgent，不在该列表中，只能走前缀补判；容器网桥同样
匹配不到。VPN 接口若由 VPN 应用经 VPNExtensionAbility 创建，可直接由 `BEARER_VPN` 识别。

隧道接口保留且默认启用：它是跨公网传输的主要通道，剔除会让 VPN 与跨网场景完全不可用。容器网桥不在枚举
阶段剔除、只是默认关闭，用户可在网络接口弹窗中手动开启。系统网络事件覆盖不到热点开关（SoftAP 不产生
连接网络事件），由热点状态监听（`wifiManager.on('hotspotStateChange')`）补触发刷新，设置页与网页面板
可见时也会主动重枚举。网页分享链接按实时网卡派生，不做本地缓存，网卡列表刷新后立即生效。

普通桥接（`br0`、OpenWrt 的 `br-lan` 等）承载以太网流量，归 `ethernet`；只有 Docker 动态网桥
`br-<12 位十六进制网络 ID>` 归 `bridge`。`ppp*` 既可能是拨号数据链路，也可能是 PPTP/L2TP 隧道，
无法从接口名区分，按 `unknown` 处理、默认关闭，需要时由用户在弹窗中手动开启。

`anco*` 是鸿蒙系统自身的容器网桥（真机实测 `ancowlan0` 持有 `172.17.1.1/24`），局域网设备无法
主动访问，因此默认关闭。`docker*`/`veth*`/`br-<12 位十六进制>`/`virbr*`/`cni*`/`flannel*`/`kube*`
在鸿蒙手机、平板与 PC 模拟器上均无命中：鸿蒙 PC 的 Docker 运行在融合开发引擎的 StratoVirt Linux
虚拟机内，容器网桥位于虚拟机内部，宿主侧不可见；这些前缀保留用于覆盖容器网络将来直接暴露到宿主侧
的情况。

`tap*` 存在歧义：既可能是 OpenVPN 等隧道接口，也可能是 StratoVirt 虚拟机在宿主侧的二层网卡。
当前一律归 `vpn` 并默认启用；宿主侧 tap 若无 IPv4 地址不会被枚举，Host-Only 等模式给宿主侧
分配了 IPv4 时才会出现。真实鸿蒙 PC 的接口命名尚未实测。

三个页面（发送/接收/设置）统一显示网络警告横幅：`noWifiWarning`（无 WiFi/以太网物理接口）优先于
`allInterfacesDisabled`（用户关闭了所有接口）。

### IPv6 现状

网络接口当前按 IPv4 处理：Rust `get_network_interfaces()` 只返回非回环 IPv4，`IfAddr::V6`
直接丢弃；发现服务的 IPv6 组播关闭（`DiscoveryConfig.group_v6 = None`），接口 IP 与子网扫描
只接受 `Ipv4Addr`；ArkTS 侧接口模型只有 `ip` 与 `prefixLength`，网段通配、IP 校验、网页地址
筛选与 IP 短码均按点分十进制 IPv4 实现。

协议层已具备 IPv6 能力：HTTP 服务同时绑定 `0.0.0.0:<port>` 与 `[::]:<port>`，上游 core 提供
`ff12::fd3a:e420` 组播、按接口索引加入与 `fe80::1%3` 作用域地址处理。启用 IPv6 需扩展接口
枚举（含 scope id）、打开组播 v6 并改造 ArkTS 侧地址处理，暂未排期。
