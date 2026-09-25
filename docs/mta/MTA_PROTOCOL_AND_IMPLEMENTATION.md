# MTA（互传联盟）协议与实现

> 覆盖 MTA 协议全链路（BLE 发现 → GATT 凭据交换 → ECDH/AES 加密 → WiFi Direct 连接 → WebSocket 协商 → HTTPS ZIP 下载）、HarmonyOS 平台能力映射、工程实现落点，以及与厂商设备互通所需的品牌兼容映射。
> 平台能力真机实测结论与关键数据见 [MTA_PLATFORM_VERIFICATION.md](MTA_PLATFORM_VERIFICATION.md)；ArkTS 侧应用编排（发现扫描、收发互斥、设置与历史）见 [../architecture/mta.md](../architecture/mta.md)。

## 1. 协议全链路

### 1.1 完整握手时序

```
接收端（本机）                          发送端（小米/OPPO/vivo 等厂商设备）
  │  ① BLE 广播启动：                     │
  │     主广播: serviceUuid 00003331     │
  │       + serviceData 000001ff(6B)     │
  │     扫描响应: serviceData 0000ffff   │
  │       (27B: 设备名+发送者ID)          │
  │                                      │  ② BLE 扫描(ScanFilter 00003331)
  │                                      │     解析扫描响应 → 设备名/5GHz/品牌
  │                                      │  ③ 用户选中设备 → 启动发送任务
  │                                      │  ④ 起 HTTPS+WS 服务器(随机端口,自签证书)
  │                                      │  ⑤ createGroup: DIRECT-xxxxxxxx/8位密码
  │  ⑥ GATT 连接 → 读 CHAR_STATUS ←─────│  ⑦ 读 DeviceInfo{state:0, mac, key:ECDH公钥}
  │                                      │  ⑧ ECDH 派生密钥 → AES-CTR 加密 ssid/psk/mac
  │  ⑨ GATT 写 CHAR_P2P ←───────────────│  ⑩ 写 P2pInfo{ssid,psk,mac,port,key}
  │     (解密 ssid/psk/mac)               │
  │  ⑪ 连接 WiFi Direct 组(ssid/psk)      │  (GO: 192.168.49.1)
  │  ⑫ wss://192.168.49.1:port/websocket ─│
  │      ← action:0:versionNegotiation    │
  │      → ack:0:versionNegotiation?{"version":1,"threadLimit":5}
  │      ← action:1:sendRequest?{taskId,...}
  │      → ack:1:sendRequest
  │  ⑬ 用户确认接收                        │
  │  ⑭ GET https://192.168.49.1:port/     │
  │       download?taskId=<id> ──────────→│  流式 ZIP(entry: 序号/文件名, Deflated, chunked)
  │     边下载边解压保存                    │
  │  ⑮ → action:99:status?{"type":1,"reason":"ok","taskId":..}
```

### 1.2 协议常量

| 用途 | 值 |
|---|---|
| BLE 广播 service UUID | `00003331-0000-1000-8000-008123456789` |
| GATT 服务 UUID | `00009955-0000-1000-8000-00805f9b34fb` |
| 状态特征 CHAR_STATUS | `00009954-0000-1000-8000-00805f9b34fb`（读 → DeviceInfo JSON） |
| P2P 特征 CHAR_P2P | `00009953-0000-1000-8000-00805f9b34fb`（写 → P2pInfo JSON） |
| 主广播 serviceData UUID | `000001ff-0000-1000-8000-00805f9b34fb`（6 字节） |
| 扫描响应 serviceData UUID | `0000ffff-0000-1000-8000-00805f9b34fb`（27 字节） |
| P2P 默认网关 | `192.168.49.1`（WiFi Direct GO 标准网关） |
| WS 路径 | `/websocket` |
| 下载路径 | `/download?taskId=<id>` |
| 协议版本 | `1`（协商 ack 带 `threadLimit:5`） |

主广播 serviceUuid 使用**非标准蓝牙基址**（后缀 `008123456789`，非 `00805f9b34fb`）；扫描端按该 UUID 过滤。

### 1.3 广播数据格式

- **主广播**（≤31 字节）：serviceUuid `00003331` + serviceData `000001ff` = 6 字节 `[2B 发送者 ID][4B 零]`，不含设备名（避免超 31 字节）。
- **扫描响应**（27 字节 @ `0000ffff`）：`[0-7] 零填充 [8-9] 发送者 ID [10-25] 设备名 [26]=0x01`。设备名区共 16 字节：≤16
  字节原样放入并右侧补零；>16 字节截到 15 字节并以 `\t` 作截断标记；扫描端以首个 `0x00` 为终止符，UTF-8 截断按 codepoint 回退。
- **扫描端分类规则**：按 serviceData 值的字节长度区分——27 字节为扫描响应、6 字节为主广播，其余忽略；
  **不依赖 UUID**（部分厂商如荣耀扫描响应的 serviceData UUID 并非 `0000ffff`，仅按 UUID 匹配会漏掉设备名）。
- 发送者 ID 按**无符号**解析（`(high & 0xff) << 8 | (low & 0xff)`），首字节 ≥0x80 时不得符号扩展。
- 5GHz/品牌信息编码在 serviceData UUID 字节中（`arr[2]`=5GHz 标志，`arr[3]`=品牌 ID，第三方用 `ff`）。
- 广播参数：legacy 模式、可连接、可扫描、interval 160（~100ms）、TX_POWER_HIGH。

### 1.4 数据模型（JSON key）

**DeviceInfo**（CHAR_STATUS 读返回）：

```json
{"state":0,"mac":"<蓝牙MAC>","key":"<ECDH公钥 base64>","catShare":7}
{"state":1,"reason":2,"key":"<ECDH公钥 base64>","catShare":7}
```

- `state` 为对端状态：本机作为接收方时返回固定 0（就绪）；作为发送方读取目标对端时，0 表示对端就绪可接收，非 0 表示对端忙
  （如小米互传在上一会话收尾期内返回 `state=1`，此时不返回 `mac` 并附带 `reason`）。
- `reason` 为对端忙原因码（可选，缺省 0）：已知语义 1=镜像占用、2=热点占用，其余为未知；仅用于诊断日志归因，不改变面向用户文案。
- `mac` 为接收方蓝牙 MAC（三方应用可填兜底值）；`key` 为可选 ECDH P-256 公钥（存在则凭据加密传输）
  ；`catShare` 为 CatShare 扩展版本标识（OPPO 硬编码 16，CatShare/EasyShare 填版本号，HandySend 填常量 7）。
- **对端忙的提前收束**：发送端在读取对端 DeviceInfo 之后、建组之前以 `state` 是否为就绪值判定对端忙；判忙即以「对端设备正忙，请稍后重试」结束本次发送，
  不建组、不起服、不写回凭据。对端忙时不会加入新的 P2P 组，此时写回的 `P2pInfo` 会被其静默丢弃；忙原因码只进诊断日志，不自动重试
  （实测对端在约 60s 内不会自行恢复）。对端就绪时发送流程与结果不变。

**P2pInfo**（CHAR_P2P 写）：

```json
{"id":"a1b2","ssid":"<加密>","psk":"<加密>","mac":"<加密>","port":43210,"key":"<发送端公钥>","catShare":7}
```

- `id` 必填（vivo 发送端要求）；当 `DeviceInfo.key` 与 `P2pInfo.key` 均存在时，`ssid`/`psk`/`mac` 为 AES-CTR 加密后的 Base64；`port`/`id`/`key`/`catShare` 明文；`key` 缺失按明文处理。

**sendRequest payload**：`taskId`/`id`、`senderId`、`senderName`、`fileName`、`mimeType`、`fileCount`、
`totalSize`，可选 `catShareText`（文本传输）、`thumbnail`；三方扩展 `senderBrand`/`senderBrandId` 厂商接收端忽略。

### 1.5 加密规格

| 项 | 值 |
|---|---|
| 密钥交换 | ECDH P-256（secp256r1），双方各生成一次性密钥对（每轮会话重新生成） |
| 公钥编码 | X.509 SubjectPublicKeyInfo DER → Base64（NO_WRAP） |
| 共享密钥 | 双方运行结果一致（32 字节，X 坐标）；两 Android 实现分别用裸 `generateSecret()` 与 `generateSecret("TlsPremasterSecret")` |
| AES 模式 | AES-256-CTR / NoPadding |
| AES IV | **`"0102030405060708"` ASCII 16 字节**（固定，非 8 字节） |
| 加密对象 | 仅 P2pInfo 的 `ssid`/`psk`/`mac`；`P2pInfo.key` 存在即触发解密，缺失按明文处理 |
| TLS | WSS + HTTPS 自签名证书，联盟对端信任所有证书 |

固定 IV + 无 KDF 是 MTA 协议既有设计，为兼容必须照此实现；该加密仅保护经 BLE 通道传输的 WiFi 凭据，文件数据依赖 TLS。

### 1.6 WebSocket 应用层协议

- 消息格式：`type:id:name?json_payload`（正则 `^(\w+):(\d+):(\w+)(\?(.*))?$`）。
- `type` ∈ {`action`, `ack`}；`id` 为消息 ID（ack 复用原 id）；发送端必须对接收端的 action 消息回 `ack:<原id>:<原name>`。
- 消息类型：
  - `versionNegotiation`（S→R）：`{"version":1,"versions":[1]}`；回 ack `{"version":min(n,1),"threadLimit":5}`；payload 缺 `version` 时按 1 处理。
  - `sendRequest`（S→R）：任务 JSON；回空 ack。
  - `status`（R→S）：接收端回执帧号取 `100`（对齐可用的第三方实现；vivo 口径为 99）；`type=1 reason=ok`（成功）/ `type=1 reason=partial`（部分接收）/
  `type=3 reason=user refuse`（拒绝）/ `type=3 reason=timeout`（接收端确认超时）。
  载荷同时携带 `taskId` 与 `id`（同值，字段顺序 `taskId,id,type,reason`）——按可用的第三方实现对齐，小米端据此判成功。
- **回送时机**：接收端在**下载体收完**（`networkDone`，此时仍在解压/落盘）即回送 status，而非等解压落盘结束——部分厂商（小米）发完文件后等待回执的窗口很短
  （实测约 0.2s），过晚回送的帧会在其断连前落不到地，使其以失败收尾（文件实际已送达）。提前回送**仅在写入成功时**置「已回送」标记；写入失败保持未置，收尾路径先等在途回执结算、
  再兜底回送一次，保证任何路径都恰有一次有效回执（既不漏送也不重复）。
- **状态分类**：结果按「类型 + 原因」组合判定（对齐对端实现，原因大小写不敏感）——`type=1 reason=partial` → **部分完成**（仅收了部分文件，
  不得呈现为成功）；`type=1`（其余/无原因）→ 成功；`type=3 reason=user refuse` → 拒绝；`type=3 reason=timeout` → 超时；其余类型或原因 → 失败。
- 状态机：`WAITING_VERSION → WAITING_SEND_REQUEST → WAITING_USER_ACCEPT → TRANSFERRING → COMPLETED/FAILED`。
- 消息 ID 规则：发送方从 0 递增（versionNegotiation=0, sendRequest=1）；接收方 status 固定 99。
- 发送端在传输全链路完成前不主动关闭 WS。
- **传输终止语义**：对端中途取消不发送专用协议消息，表现为断开下载连接（HTTP）和/或关闭 WS。发送端把「下载连接被对端断开」与「对端关闭 WS」都识别为传输终止信号，立即结束本次发送、
  以可读原因提示并按既有语义释放资源（未移交的发送直读 fd、文本会话暂存目录、TLS 服务器、P2P 群组、定时器）；传输阶段另设无进展看门狗，覆盖对端既不关连接也不发状态的静默情形。发出
  `sendRequest` 后、对端尚未开始下载期间为**「等待对方确认」阶段**（会话阶段文案 `mta_send_stage_waiting_peer_confirm`），以「等待对端开始接收」窗口（约 35s，见
  `MtaConstants.PEER_ACCEPT_TIMEOUT_MS`，覆盖对端用户确认窗口）为界：窗口内对端开始下载即进入传输阶段并撤销该中间态；对端回送状态即按其类型即时终结；对端关闭本次 WS 连接、或连续约
  1~2s（`MtaConstants.GROUP_CLIENT_ZERO_STREAK_LIMIT` 次群组轮询）观测到退出本次 P2P 组（客户端数归零 / 群组信息不可得）时，提前以「对方已放弃接收」终结，不等窗口到期；窗口内对端既未开始下载、
  也未回送状态、也未断开时，窗口到期判定对方未接收并以「对方拒绝接收」终结，不干等到 Rust 侧状态等待超时。该阶段收到的「对端关闭连接 / 读取失败 / 状态等待超时」类失败对用户统一呈现为「对方已放弃接收」
  （原始原因保留在日志中），更早链路阶段与传输阶段沿用各自原因文案。等待阶段的可归因诊断：Rust 侧 WS 状态机按会话统计从对端读到的报文数并在会话收尾输出一次（含会话内相对耗时）
  ，逐帧诊断日志亦附带会话内相对耗时；ArkTS 侧在终态输出一次「请求→结果耗时」、在窗口到期时输出窗口时长与「窗口期内未收到对端任何结果」判定——两者配对即可区分「对端未发送」
  与「本端漏收/漏读」，读取层异常（非文本帧 / 报文无法解析 / 读取错误）日志不被移除或降级为静默。终态稳定：已完成的发送结果不被迟到的取消/失败信号覆盖，取消与完成竞态不误报失败。
- **发送端本地取消**：用户在发送页取消时，发送端向对端回送取消状态 `action:99:status?{"taskId":..,"type":3,"reason":"user refuse"}` 并关闭该 WS 连接，对端据此立即呈现「对方已取消」
  ，不必等到自身超时（对端按任意 action 帧处理 status，故不要求先完成版本协商）。回送发生在对端已接入会话通道时的当前连接，或对端尚未接入时其接入后的首个连接——后者先于版本协商直接回送，
  不再推进 `sendRequest`。对端尚未接入时保留 TLS 服务器与 P2P 群组可接入，等待上限 10s（对端接入即提前结束），到期未接入按「未能通知对端」结束等待；等待期内用户可直接返回放弃通知，
  等待期内资源占用严格有界且不引入后台常驻链路。取消状态成功写入对端连接后才释放资源，释放语义与正常完成/失败一致；取消终态稳定，不被迟到的完成/失败信号覆盖。
- **接收端取消/失败回执**：接收端用户在下载中取消时回送 `type=3 reason=user refuse`（best-effort），使发送端得到明确结果而非仅凭连接关闭推断；其余失败（下载停滞、解压/落盘错误）
  保持断连语义——协议原因词表只有 `ok`/`partial`/`user refuse`/`timeout`，无「本地错误」项，硬套原因会让对端显示错误结论。
- **接收端确认超时**：接收端等待用户确认超过 `MtaConstants.PEER_DECISION_TIMEOUT_MS`（30s）即自动回送 `type=3 reason=user refuse` 并复位等待，先于发送端「等待对端开始接收」
  窗口（35s）到期，避免被发送端单方拆组停服后再由本端失败。

### 1.7 文件传输

- 发送方**边读源文件边生成 ZIP 流**（`Content-Type: application/zip`，分块传输、不设 `Content-Length`）：由 `zip` crate 的无 Seek 流式写出器生成标准 ZIP，**所有条目压缩方法恒为
  `Deflated`**（无 Seek 流式写出必然产生数据描述符，而对端解析器只接受压缩方法条目携带描述符；不压缩直存会被对端解析器直接报错并中止下载），所有条目统一使用同一压缩档位（压缩库允许的最快档，
  不按文件类型区分），单条目大小或总偏移超 32 位时 ZIP64 结构（扩展字段/64 位描述符/结束记录与定位器）由库自动启用；CRC 由库在条目写完时自动计算，不再起服预读。
  条目数据单遍读出（`fdSend` 文件描述符直读，缺省 -1 按 `path` 回退打开），读毕校验实际字节与声明大小一致；entry 名 `{序号}/{文件名}`（从 1 起，如 `1/photo.jpg`），
  文本场景仅一个 entry `1/sharedText.txt`。文件条目由 ArkTS 打开源 URI（picker URI `fs.openSync(READ_ONLY)`，每文件一个读取入口，随 `MtaServerConfig.files[]` 的
  `fdSend` 与 `sizeBytes` 透传）直读，不复制到沙箱；文本条目仍写沙箱临时文件按 `path` 读取。fd 所有权随起服移交：失败退出点由 Rust 关闭全部未消费 fd，成功后未消费
  `fdSend` 由 `stop_server` 收尾；ArkTS 只在移交前关闭已开 fd。起服只做配置解析与端口绑定，不再预读源文件，就绪时间与文件总量无关；下载一经开始即持续有字节流向对端。
- 接收方**由 Rust 主导边下载边解压**：Rust 直接发起 HTTPS 下载（`reqwest` + 跳过服务端证书校验）、流式解析 ZIP 并把条目**直接写入目标目录**（`Download/<bundleName>`）
  ，支持 `Stored`/`Deflated` 与带/不带签名的数据描述符及 ZIP64 扩展字段；只取文件名防路径穿越、忽略目录 entry、重名加 `(n)` 后缀、还原条目修改时间，防 zip
  bomb（条目数/解压总字节/单条目字节上限；解压总量上限由 ArkTS 按对端声明值与容差计算后作为绝对上限传入）；进入下载前校验落盘目录可用空间 ≥ 声明总大小 + 256MiB 预留，
  不足则拒绝且不产生任何落盘文件；失败/取消中止下载并删除本次已写文件。ArkTS 仅负责协议交互与业务接线（接收请求/接受/拒绝、`status` 回执、接收历史、相册、UI）。
- **进度口径（有效数据）**：两端统一为「实际字节 ÷ `sendRequest.totalSize`」，界面文案为「已处理 / 共」。发送端分子为已读源文件字节（Rust 流式写出过程中累计），接收端分子为 Rust
  上报的已解压字节（`mtaReceiveProgress.receivedBytes`）；分母均为接收请求声明的原始文件总大小。接收端不依赖响应头 `Content-Length`（发送端为 chunked）。两端完成态均置 100%。
- **速率口径（网络字节）**：压缩使网络字节与有效数据字节分离（实测同一笔传输网络 1.65GB / 数据 4.09GB），故速率改用网络字节口径——
  发送端为出网字节（`mtaSendProgress.networkBytes`，响应体数据帧实际交给连接写出的累计）、接收端为网络读入字节（`mtaReceiveProgress.networkBytes`，
  响应体读入累计）。展示层按时间窗口平滑并用窗口内区间速率中位数剔除瞬时尖峰（事件突发到达、压缩流尾部一次性产出等），避免出现远超链路能力的数值。
- **进度上报**：发送端在流式写出过程中按时间节流上报（`mtaSendProgress`，含有效数据与网络字节两路累计），结束时无条件上报终值；接收端由
  Rust 按时间节流上报（`mtaReceiveProgress` 可丢弃事件），传输完成的 100% 进度不受节流限制；网络数据全部读入而仍在解压/落盘时，
  接收端另上报一次带「网络已收完」标记的进度，展示层据此把阶段文案切换为「解压/保存中」（此后网络速率自然衰减为不可用，不再呈现高速率）。
- **单位口径**：应用层大小与速率统一按 10³ 进制换算（B/KB/MB/GB）；原生层诊断日志按 2 次幂进制并显式以 MiB/s 标注，两者口径各自自洽、不互相矛盾。
- **接收诊断可见性**：接收端由 Rust 输出「网络读入 / 解压产出 / 写盘」三速率、HTTP 块大小统计与接收结束汇总（均为 debug 级）。Rust 日志写入静态缓冲后由 ArkTS 侧轮询排空，接收会话期间
  `MtaReceiveService` 按 `RUST_LOG_POLL_MS` 轮询并把 MTA 相关行按原始级别展示在日志域 `Rust` 下，会话结束后即停止轮询（不常驻）；非 debug 级配置不产生额外输出，与发送端具备同等可见性。
- 文件修改时间经 **ZIP 条目时间**（DOS 日期时间位）承载（协议载荷无时间字段，条目时间是唯一标准位）：发送方按源文件修改时间编码条目时间，
  接收方在流式解压过程中读取条目时间并在写盘后还原文件修改时间；条目时间缺失/不可用时回退落盘时刻，不中断传输。
- TLS：发送方临时生成自签证书（域名含 127.0.0.1/0.0.0.0/localhost）；接收方信任所有证书 + hostname 恒真。
- **缩略图（可选增强）**：发送方可在 `sendRequest` 中携带 `thumbnail`/`thumbnail_width`/`thumbnail_height`；
  接收方在确认阶段以 `GET /thumbnail?taskId=<任务 ID>` 拉取（同一 TLS 端口，响应
  `application/octet-stream`、无格式提示，按魔数识别）。HandySend 已实现接收侧拉取，并在任务详情的
  文件条目上展示（协议只提供一张，用于首条图片条目）；发送侧提供缩略图尚未实现。
- 任务 ID：发送方随机数，同时写入 `taskId`/`id`；厂商发送方收到 status `type=1` 后延迟约 1s 删组停服（HandySend 自身发送完成清理延迟为 3s，见 `MtaConstants.SEND_COMPLETE_SETTLE_DELAY_MS`）。
- 厂商接收端的用户确认超时约 31s（HandySend 发送端「等待对端开始接收」窗口 35s 即为覆盖该窗口而设，见
  `MtaConstants.PEER_ACCEPT_TIMEOUT_MS`），确认前不开始下载；HandySend 自身作为接收端的确认超时取
  `MtaConstants.PEER_DECISION_TIMEOUT_MS`（30s，短于发送端窗口），到期自动回送拒绝状态，不无限期等待用户决策。

### 1.8 WiFi Direct 规格

| 项 | 值 |
|---|---|
| 默认 GO IP | `192.168.49.1` |
| SSID 格式 | `DIRECT-<8位随机字符>`（Android WiFi Direct 约定） |
| PSK | 8 位随机字符 |
| 加密 | WPA2-PSK |
| 频段 | 发送端按目标品牌与 5GHz 能力选频段（见注 1） |
| 持久化 | `enablePersistentMode(false)` |

> **注 1**：目标非 Samsung 且声明支持 5GHz → 显式优先请求 5GHz（`GO_BAND_5GHZ` 同时携带
> 限定非 DFS 频点 `goFreq`，如 5180MHz），施加约 3s 有界就绪探测，超时/请求抛错即快速
> 回退 `GROUP_OWNER_BAND_2GHZ`；目标为 Samsung 或不支持 5GHz → 仅 `GROUP_OWNER_BAND_2GHZ`。
> 接收端入组沿用自动频段（`GO_BAND_AUTO`，群组频段由对端 GO 决定，本机不可控）。

发送端建组按候选（频段 + 频点）串行尝试：对每个候选执行「清理旧组 → 建组 → 等待群组就绪」，5GHz 候选施加约 3s 有界就绪探测、2.4GHz 候选沿用既有较宽超时，单次失败/超时/请求抛错继续下一候选，
全部失败才判定建组失败，任一候选成功即视为建组成功；尝试之间检测会话取消。请求 5GHz 而就绪后实际群点为 2.4GHz 时按实际频段接受，不重复建组。建组完成后经 `getCurrentGroup().frequency`
读取实际频点（MHz），按区间映射频段标签（2400–2500 → 2.4GHz，4900–5900 → 5GHz，其余或 0 → 未知），实际频点写入会话并随 `P2pInfo.freq` 上报。接收端在加入对端群组、连接
确认后读取对端群组实际频点并写入接收状态。两端均将实际频点与是否受限写入日志并在传输页展示频段标签，2.4GHz 频段提示速度可能受限，频点未知时降级显示且不影响传输流程。

**建组频段取证（debug 级）**：建组前记录本机并发 STA 频段快照（`wifiManager.getLinkedInfoSync()` 的 `band`/`frequency`/`linkSpeed`/`ssid`，未关联
WiFi 或读取失败时降级为「未知」），候选循环内为每个候选记录请求频段与频点（`goBand`/`goFreq`）、`createGroup` 异常（若有）、`waitGroupReady`
就绪耗时与结果、以及作为实际群点的群组频点。取证为只读，不改变建组策略与流程（仍 5GHz 显式优先、失败/超时快速回退 2.4GHz），也不引入额外固定等待。

## 2. HarmonyOS 平台能力映射

| 协议环节 | HarmonyOS API | 权限 | 状态 |
|---|---|---|---|
| BLE 广播（主广播+扫描响应） | `ble.startAdvertising`（`advertisingData` + `advertisingResponse`） | `ACCESS_BLUETOOTH` | ✅ |
| BLE 扫描（serviceUuid 过滤） | `ble.startBLEScan` + `ScanFilter.serviceUuid` | `ACCESS_BLUETOOTH` | ✅ |
| GATT 服务端 | `ble.createGattServer` + `addService` + `on('characteristicRead/Write')` + `sendResponse` | `ACCESS_BLUETOOTH` | ✅ |
| GATT 长写 | `CharacteristicWriteRequest.isPrepared` 按 offset 累积 | — | ✅ |
| GATT 写模式 | `ble.GattWriteType.WRITE_NO_RESPONSE` / `WRITE` | 对端声明 `writeNoResponse` 即用无响应写（带响应写依赖对端回送 ATT 响应，第三方实现常不闭合）；写失败不在同一连接内重试 | — | ✅ |
| WiFi P2P 建组（GO） | `wifiManager.createGroup(WifiP2PConfig{groupName,passphrase,goBand,goFreq})`（5GHz 候选附带合法频点） | `GET_WIFI_INFO`（normal） | ✅ |
| p2pConnect 入组（接收端） | `wifiManager.p2pConnect(WifiP2PConfig{...})`（完整参数见注 2） | `GET_WIFI_INFO`（normal + system_grant，安装即授予） | ✅ |
| 获取 GO IP | `p2pConnectionChange` 事件 `groupOwnerAddr`（普通应用可用）；`192.168.49.1` 兜底 | `GET_WIFI_INFO` | ✅ |
| 本机 P2P 设备地址（发送端 `P2pInfo.mac`） | Native `getifaddrs` 读 `p2p0` 硬件地址（`nativeGetInterfaceMac`），见 §4.4 | — | ✅ |
| 对端真实 MAC（增强） | `getP2pPeerDevices`/`getScanInfoList` 等（`GET_WIFI_PEERS_MAC` 后返回真实地址） | `GET_WIFI_PEERS_MAC`（三方不可授予，声明后安装失败） | 🟠 可选，不使用 |
| HTTPS 服务器+自签 | Rust hyper + rustls + rcgen | — | ✅ |
| WebSocket 客户端/协议 | ArkTS `MtaTransferClient`/协议纯函数 | — | ✅ |
| ECDH P-256 / AES-256-CTR | ArkTS `@kit.CryptoArchitectureKit` → `MtaCrypto` | — | ✅ |
| ZIP 流式写出（发送端） | Rust `zip_stream::write_zip_stream`（`zip` crate 无 Seek 流式写出；细节见注 3） | — | ✅ |
| ZIP 流式解压 + 下载落盘（接收端） | Rust `receive`（reqwest 下载 + `unzip_stream` 解析 + 直接写目标目录） | — | ✅ |
| 三方应用开热点 | `@ohos.net.sharing` | — | ❌ 不开放（走 `createGroup`） |
| 定位权限 | `APPROXIMATELY_LOCATION`（仅 P2P 主动发现需要） | — | 接收端 p2pConnect 不需要，HandySend 未声明 |

> **注 2**：完整参数 `WifiP2PConfig{deviceAddress:'00:00:00:00:00:00',deviceAddressType:RANDOM,
> netId:-1,groupName:ssid,passphrase:psk,goBand:AUTO}`。
>
> **注 3**：条目压缩方法恒为 Deflated、全条目统一压缩档位；ZIP64 超限自动启用；
> 数据源 ArkTS fd 直读或 path 回退。

**权限结论**：接收端全链路仅需 `ACCESS_BLUETOOTH` + `GET_WIFI_INFO`（normal 级 system_grant，安装即授予）
；定位权限仅在 P2P 主动发现时需要，HandySend 接收端不使用 P2P 主动发现，故 `module.json5` 未声明该权限。

## 3. 实现落点

### 3.1 Rust 核心（`localsend_ohrs` 的 `mta` 模块）

1. 依赖：`zip`（发送端无 Seek 流式 ZIP 写出，deflate 复用 `flate2`，ZIP64 自动处理）、`crc32fast`（接收端 Stored 条目描述符 CRC 校验）、`flate2`（发送端 deflate 压缩、
   接收端 deflate 流式解压）、`time`（按源文件时间编码 ZIP 条目时间）、`tokio-tungstenite`（WS）、`hyper`/`hyper-util`（HTTP + upgrade）、`tokio-rustls`/`rustls`/`rustls-pemfile`（TLS
   服务端）、`reqwest`（接收端 HTTPS 下载，跳过服务端证书校验，需安装 rustls `ring` provider）；ECDH+AES-CTR 加解密在 ArkTS 侧（`MtaCrypto`）。
2. MTA WebSocket 服务器：`/websocket` 路径，实现 `type:id:name?json` 消息解析与状态机（versionNegotiation/sendRequest/status），对 action 消息回 ack。本地取消意图（`MtaContext`
   的 `reject_pending`/`reject_notify`，经 `reject_peer()` 登记）在状态机四处被响应：对端接入时、等待版本确认、等待 `sendRequest` 确认、等待对端状态；
   响应统一为「回送取消状态 → 关闭连接 → 发 `mtaRejectSent` → 结束状态机」，意图生效后不再推进握手、不抢先发送 `sendRequest`，accept 循环保持监听直至上层释放资源时停服。
3. MTA HTTPS 服务器：`/download?taskId=` 路由，按文件清单流式生成 ZIP 写入响应体（chunked、无 `Content-Length`；数据源为 ArkTS 直传 fd，文本条目回退沙箱路径），临时自签证书；不预打包、不落临时 ZIP。
4. 流式 ZIP 写出：`zip_stream::write_zip_stream` 用 `zip` crate 的无 Seek 流式写出器逐条目写出（**所有条目压缩方法恒为 `Deflated`**，所有条目统一使用同一压缩档位——压缩库允许的最快档，
   不按文件类型区分；单条目超 32 位上限时由库启用 ZIP64），数据单遍读出（`open_source`：`fdSend >= 0` 接管 fd 直读，否则按 `path` 打开），读毕校验实际字节与声明大小一致；
   条目时间取源文件修改时间，并在写出过程中累计已读源字节供进度上报；起服失败路径由 `close_unconsumed_fds` 关闭全部未消费 fd（`fdSend` 所有权自 config 解析成功起归 Rust）。
5. ZIP 流式解析/解压核心：`unzip_stream::parse_zip` 顺序解析 ZIP（`Stored`/`Deflated`/带与不带签名数据描述符/ZIP64 扩展字段），由 `ZipEntryHandler`
   逐条目消费解压字节流并汇报累计解压字节；强制仅取文件名防穿越、忽略目录条目、条目数/解压总字节/单条目字节上限；不持有会话/线程/通道。
6. 接收端 Rust 主导下载：`receive::receive_download` 用 `reqwest`（跳过服务端证书校验）请求 `/download?taskId=` 并流式读取响应体，边收边解压、
   把条目直接写入目标目录（重名 `(n)`、还原条目时间、失败/取消删除本次已写文件），经 `mtaReceiveProgress` 事件上报进度（有效数据分子 + 网络读入字节累计
   + 「网络已收完」标记）并返回落盘元数据 `[{name,size,modifiedUnixMs,savedPath}]`；重建连接超时、响应码校验、下载停滞看门狗与取消令牌语义。
7. NAPI 桥接：`nativeMtaStartServer` / `nativeMtaStopServer` / `nativeMtaRejectPeer` / `nativeMtaReceiveDownload` + 事件推送（发送请求、取消状态已回送、
   发送/接收进度、完成/部分完成/拒绝/失败）。`nativeMtaRejectPeer` 只登记「向对端回送取消」意图（服务器不存在时为空操作），不停止服务器、不触发取消令牌。

### 3.2 ArkTS 层（`entry/src/main/ets/service/mta`）

- **BLE**：接收端广播（主广播 + 扫描响应格式）、发送端扫描（`ScanFilter.serviceUuid=00003331` + serviceData 解析）、GATT
  Server（`CHAR_STATUS` 读返回 DeviceInfo、`CHAR_P2P` 写解析含 prepared write 累积与 `{...}` 容错提取）、GATT Client。
- **WiFi Direct**：发送端 `createGroup`（`DIRECT-` 前缀，5GHz 候选附带 `goFreq` 限定频点）按候选（频段 + 频点）串行尝试并在失败/超时时快速回退（Samsung 与不支持
  5GHz 的对端仅 2.4GHz），接收端 p2pConnect 入组（全 0 地址 + 随机地址类型 + 临时组注入 SSID/PSK）、GO IP 获取（`p2pConnectionChange` 事件 + `192.168.49.1`
  兜底）；发送端经 Native `getifaddrs` 读 `p2p0` 硬件地址（`nativeGetInterfaceMac`）取本机 P2P 设备地址填入 `P2pInfo.mac`（见 §4.4），建组后与接收端连接确认后均经 `getCurrentGroup().frequency`
  读取实际频点；建组频段取证的本机 STA 快照读取（`MtaP2pGroup.getStaBandText`）位于 `MtaP2pGroup`，候选循环的请求/异常/耗时/实际群点记录位于 `MtaSendService`。
- **加密**：`MtaCrypto`（ECDH P-256、SPKI+Base64、AES-256-CTR 固定 16 字节 IV）。
- **传输**：`MtaTransferClient`（WS 协商、按对端声明值计算解压总量上限后调用 `nativeMtaReceiveDownload` 驱动 Rust 下载/解压/落盘，订阅 `mtaReceiveProgress` 事件上报进度：
  分母为接收请求声明的原始总大小、分子为已解压字节，按时间节流、完成置 100%；以 Rust 返回元数据按扩展名解析真实 MIME 构造展示条目）、`MtaReceiveService`（进入下载编排前校验落盘目录可用空间
  ≥ 声明总大小 + 256MiB 预留，不足即拒绝且不进入下载）、`MtaSendService`（发送文件 fd 直读：逐文件 `fs.openSync(uri, READ_ONLY)` 打开读取入口（`fdSend`），
  `statSync(uri)` 取源文件大小与修改时间，随 `MtaServerConfig.files[]` 的 `fdSend`/`sizeBytes` 透传 Rust；打包前依序校验条目数 → 总大小 → 单文件三档上限，
  各档独立提示；fd 在 `nativeMtaStartServer` 调用移交，之后 ArkTS 不再触碰，移交前失败/取消关闭已开 fd；文本条目走沙箱临时文件、fd 缺省 -1；编排 + 事件处理 +
  资源释放；完成态保留传输中的源总字节；取消编排为「登记回送取消意图 → 有界等待（`mtaRejectSent` 事件 / 10s 上限 / 用户直接返回，先到者结算）→ 结束会话 → 释放资源」
  ，等待期不结束会话以保持接收服务暂停与收发互斥，资源释放设一次性守卫使「等待结算」与「页面销毁」两条路径不重复释放）、`MtaP2pGroup`（建组 + 群组信息）。

### 3.3 主流程接入

- **应用级仓储 `MtaRepository`**：持有一个仅用于发现的 `MtaBleClient`（发送页可见期间常驻扫描、均衡功耗模式）与一个
  MTA 接收服务单例；提供发现扫描、接收服务前台启停（按「互传联盟接收」设置，默认开启）、收发互斥与接收命令门面。
- **统一设备列表**：`DiscoveredDevice` 含可选 MTA 字段；发送页可见期间持续 BLE 扫描（切走 Tab、推入子页面或退后台即停止，`MainTabFloating` 按可见性联动启停），
  扫描期间每 15 秒剔除超时未再广播的设备（30 秒未见即离线）；本机蓝牙关闭时停止扫描并清空设备列表，蓝牙重新开启后自动恢复扫描与接收服务，
  把发现的互传联盟设备经统一形状（`protocol = 'mta'`，BLE 标识作 fingerprint）并入附近设备列表。MTA 发现标签仅在会话内曾发现互传设备时出现，空态文案引导开启蓝牙与 WLAN（无需连接网络）。
- **连接警告横幅**：发送页与接收页均按优先级只显示一条连接警告（同网络警告款式）——WLAN 关闭且局域网不可用时与「未连接局域网」提示合并；WLAN
  关闭但局域网可用时（如已接网线）只提示互传需要 WLAN（设备可被发现但无法传输）；蓝牙与 WLAN 均未开启时显示合并提示；仅蓝牙关闭时提示开启蓝牙。
  接收页的互传相关提示以「互传联盟接收」开关为前提。三方应用无法主动开启 WLAN（`wifiManager.enableWifi` 需系统应用权限），WLAN 开关状态经 `wifiManager.isWifiActive()` 查询。
- **MTA 会话接入统一注册表**：`MtaSendAdapter` 承接 MTA 发送编排——`MtaSendService` 完成建组/协商/传输，适配器把阶段变化翻译为注册表操作（阶段文案/进度/终态），并负责收发互斥（
  发送前停发现扫描并暂停接收服务、终态后按开关恢复）与取消/重试（取消沿用「登记回送取消意图 → 有界等待（`mtaRejectSent` 事件 / 上限 / 用户直接返回）→ 结束会话 → 释放资源」）
  ；`MtaReceiveAdapter` 把接收状态快照映射为待确认/进行中/终态会话。MTA 会话（发送与接收）统一经任务与通用详情页 `SessionDetailPage` 展示，已无 MTA 专用传输页。MTA 仅单目标。
- **接收历史与文件类型**：`MtaReceiveService` 按落盘文件名扩展名解析真实 MIME 写入接收历史（不再统一记通用二进制类型），该真实类型同时作为「保存到相册」的媒体筛选依据。
- **文本收发**：`SendRequestPayload` 含可选 `catShareText`；发送侧文本以 ZIP 单条目 `1/sharedText.txt` 随包发送，接收侧解析后按文本消息写入接收历史（落盘文本文件即交付物）。
- **生命周期与设置**：偏好键 `mtaReceiveEnabled`（默认 `true`）与设置页「互传联盟接收」开关；`EntryAbility.onForeground`/`onBackground`
  按开关启停接收服务，蓝牙临时关闭时接收服务复位、蓝牙恢复后按前台与开关状态自动重启（经蓝牙状态跃迁判定，忽略「开启中/关闭中」中间态）。

### 3.4 实施进展

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 协议验证 | 协议核心（ECDH/AES/WS/ZIP）研究与实现 | ✅ 已完成 |
| P0' 平台实测 | BLE 双向互通、P2P 建组、p2pConnect 入组、GO IP/SSID、本机 p2p0 MAC、数据面 | ✅ 已完成（见 [MTA_PLATFORM_VERIFICATION.md](MTA_PLATFORM_VERIFICATION.md)） |
| P1 接收端闭环 | BLE 广播 + GATT + p2pConnect 入组 + WS 协商 + 下载解压 | ✅ 与荣耀真机端到端互通（见 [MTA_PLATFORM_VERIFICATION.md](MTA_PLATFORM_VERIFICATION.md) §8） |
| P3 发送端 | createGroup + WS/HTTPS 服务器 + 流式 ZIP + BLE 扫描发现 | ✅ 与荣耀真机端到端互通（同上） |
| P4 体验完善 | 文本传输、进度、接收历史、设置开关 | 🟡 部分（自动确认待定） |
| P5 主流程接入 | 发送页统一列表发现与单目标发送、前台自动接收、文本收发 | ✅ 与荣耀真机双向互传（同上） |

## 4. 品牌兼容映射

品牌兼容围绕「广播层品牌伪装、协议层厂商行为差异适配、WiFi Direct 层 OEM 差异处理、认证层 MAC 因子」四条主线。

### 4.1 品牌 ID 注册表

MTA 把品牌 ID 编码在主广播 serviceData UUID 的 `arr[3]`。基础映射：10-19 OPPO（11=Realme）、20-29 vivo、30-39 Xiaomi、41-45 OnePlus、50-59 Meizu、70-75 Samsung、100-109 Lenovo、`FF` 第三方。
扩展注册表：Nubia 60-69（66=RedMagic）、ZTE 80-89、Smartisan 90-95、Motorola 110-119、NIO 120-129、Pixel 130-139、Honor 140-149、ASUS 161-169（160=ROG）、Hisense 170-179、Black Shark 32。

**vivo 识别约束（关键）**：广播 UUID 字节不是任意值，vivo 扫描端对其有识别/白名单逻辑——早期用 `0000011e`/`00000204` 时 vivo 列表不显示设备，改为 `000001ff`/`0000ffff` 后正常发现。

### 4.2 协议层厂商行为差异

| 差异点 | 厂商要求 | 处理 |
|---|---|---|
| `P2pInfo.id` | vivo 发送端要求必填 | 填写发送者 ID |
| status 消息 id | vivo 按消息 id 识别，必须为 99 | status 固定 id=99 |
| versionNegotiation | payload 缺 `version` 时按 1 | 解析缺省为 1；构造固定 `version:1` |
| action 回 ack | 部分厂商接收端等待 ack 才收尾 | 对任意 action 消息回 `ack:<原id>:<原name>` |
| WS 关闭时序 | 厂商接收端 ack 后仍继续使用连接 | 传输全链路完成前不主动关 WS |
| `P2pInfo.key` | 对端明文模式解析失败 | `key` 默认可省略（null），缺失按明文 |
| status 语义 | 部分/超时需可区分 | `ok`/`partial`/`user refuse`/`timeout` |
| 任务 ID 字段 | 部分厂商（如荣耀）仅按 `id` 读写任务 ID | `sendRequest` 同时写 `taskId`/`id`；解析 `taskId` 缺失回退 `id`；`status` 回执同时携带 `taskId`/`id`（缺 `id` 时小米端直接判本次接收失败） |
| 未知 status type | 荣耀故障时回 `type=2 reason="cannot access"` | 结果按「类型 + 原因」组合判定（见注 4） |

> **注 4**：`type=1 reason=partial` → 部分完成、`type=1` → 成功、
> `type=3 reason=user refuse/timeout` → 拒绝/超时、其余（含 `type=2`）→ 失败。

### 4.3 WiFi Direct 层 OEM 差异

- **频段选择**：目标广播 5GHz 支持且**非 Samsung** → 显式优先请求 5GHz（`GO_BAND_5GHZ` 同时携带限定非 DFS 频点 `goFreq`，如 5180MHz），施加约 3s
  有界就绪探测，超时/请求抛错即快速回退 `GROUP_OWNER_BAND_2GHZ`（本平台 `GO_BAND_AUTO` 实测恒落 2.4GHz，无法据此取得 5GHz）；目标不支持 5GHz **或目标为
  Samsung** → 强制 `GROUP_OWNER_BAND_2GHZ`（Samsung 的 WiFi Direct 在 5GHz 下与三方建组互通有已知问题）。接收端群组频段由对端 GO 决定，仅读取并展示实际频点。
- **建组/路由时序**（Android 侧差异，鸿蒙等价行为需实测后确定）：部分 OEM 首次建组可能失败需重试；移组后需 settle
  再建新组；部分版本 P2P 路由已装但不暴露 `ConnectivityManager` Network，需按 p2p 接口名注册 NetworkCallback。
- **确认弹窗节奏**：厂商接收端用户确认弹窗约 30s，发送端「等待下载开始」超时必须大于该值；HandySend 自身作为接收端亦设 30s 确认超时
  （`MtaConstants.PEER_DECISION_TIMEOUT_MS`），到期自动回送拒绝状态，使两端结果一致且可归因。

### 4.4 MAC 认证因子

互传联盟协议把设备 MAC 作为认证信息的一部分：

- **发送端 `P2pInfo.mac`（本机 P2P 设备地址）**：须等于对端识别到的群主设备地址——小米端会校验，不一致时报 `unrecognized network owner` 并中止（对端加入组后不连 WS）。
  鸿蒙对三方应用屏蔽了该地址的读取：`getCurrentGroup().ownerInfo.deviceAddress` 返回随机值、`getP2pLocalDevice()` 返回全 0、`/sys/class/net/<iface>/address` 拒绝访问，
  `GET_WIFI_PEERS_MAC` 亦不可授予（声明后安装失败）；故由 Native `getifaddrs` 直接读 `p2p0` 硬件地址（`nativeGetInterfaceMac`，见 native-bridge 文档）。
  读取失败时只能回退 `ownerInfo.deviceAddress`（无相应权限时为随机值），此时以 **warn** 记录回退值，避免该兼容缺口静默复现。
- **接收端 `DeviceInfo.mac`（蓝牙 MAC）**：三方应用拿不到可靠真实蓝牙 MAC，兜底 `02:00:00:00:00:00`；部分严格校验厂商（OPPO）可能因此拒绝，
  属三方应用结构性限制。鸿蒙「设置 → 关于本机 → 状态信息」展示真实 MAC，可文字引导用户查抄填入以改善通过率（无公开 URI 直达，需校验 `XX:XX:XX:XX:XX:XX` 格式）。

### 4.5 HandySend 对齐对照

| 品牌兼容点 | 厂商做法 | HandySend 现状 |
|---|---|---|
| 广播 serviceData UUID | `000001ff`/`0000ffff`（vivo 识别） | `MtaConstants.ADV_DATA_UUID`/`SCAN_RSP_UUID` 一致 |
| 广播 serviceData 分类 | 按值的字节长度区分扫描响应(27B)/主广播(6B) | `parseMtaAdvServiceData` 同样按长度分类，兼容荣耀非 `0000ffff` 的 UUID |
| 广播品牌字节 | 本机真实品牌（伪装） | 固定 `0xff` 第三方（`BRAND_ID_THIRD_PARTY`）；华为非联盟成员，保持第三方合理 |
| status 消息 id=99、reason `ok`/`user refuse` | vivo 修复 | `STATUS_MESSAGE_ID=99`、reason 常量一致 |
| `P2pInfo.id` 必填 | vivo 修复 | `info.id = senderIdHex` |
| versionNegotiation 缺 `version` 默认 1 | vivo 修复 | 构造固定 `version:1`；接收侧缺字段按 1 |
| 对端 action 消息回 ack | 必须回 | Rust `ws.rs` 对任意 action 回 `ack:<原id>:<原name>` |
| sendRequest 任务 ID | 同时写 `taskId`/`id`，读取优先 `taskId`、缺失回退 `id` | 发送端 `SendRequestPayload.id` 镜像 `taskId`；接收端 `parseSendRequestPayload` 按 `id` 回退 |
| Samsung 目标强制 2.4GHz | `requiresTwoGhzP2pCompatibility` | `MtaSendService` 按 `brandId ∈ [70,75]` 仅用 `GROUP_OWNER_BAND_2GHZ` |
| 非 Samsung 目标 5GHz 优先 | 依 5GHz 能力标识选频段 | `resolvePreferredGroupBands` 给出 `[5GHz(goFreq=5180), 2.4GHz]` 候选，`MtaSendService` 施加约 3s 探测并在失败/超时时快速回退 |
| 群组实际频点读取与展示 | 建组后读取频点 | 发送端建组后、接收端连接确认后经 `getCurrentGroup().frequency` 读取，写入状态/会话、日志与传输页频段文案 |
| 发送端不提前关 WS | 传输完成前不关 | `ws.rs` 收到 status 后不抢先关闭 + 宽限 |
| senderId 无符号解析 | `and 0xff` | `Uint8Array` 天然无符号 |
| GATT 长写 prepared write | `isPrepared` 累积 | `MtaBleReceiver` 已按 `isPrepared` 累积 |
| AES-CTR 固定 IV 16 字节 | 16 字节 ASCII | `AES_IV_TEXT` 16 字节 |
| legacy 密钥派生 | 裸 / `TlsPremasterSecret` | `agreement.generateSecret()`；真机兼容性为验证重点 |
| 发送端 P2P 设备地址 | Shizuku 读 `p2p0` MAC | Native `getifaddrs` 读 `p2p0` 硬件地址（`nativeGetInterfaceMac`） |

## 5. 风险与待验证

| 风险项 | 评级 | 说明 / 缓解 |
|---|---|---|
| 共享密钥派生兼容性 | 🟢 低 | 已在荣耀真机双向互通验证通过（ECDH P-256 + AES-CTR 固定 IV 被对端接受）；其余厂商待验证 |
| 接收端 `DeviceInfo.mac` 厂商校验 | 🟡 中 | 荣耀未因兜底值 `02:00:00:00:00:00` 拒绝；OPPO 等严格校验厂商待验证，可引导手动填入 |
| GATT 长写分片 | 🟠 中 | `isPrepared` 按 offset 累积（参照 1024B/4096B 缓冲） |
| 会话服务器暴露面 | 🟡 中 | Rust server bind `0.0.0.0` 随机端口，同一 WiFi 内设备可能先 claim 会话；可评估校验对端地址（P2P 网络不出现在 `getAllNets`，无法绑定 App 网络） |
| 多网络并行 | 🟢 低 | 接收端 p2pConnect 入组不影响已连 WiFi；P2P 网段路由装入内核 main 表，应用数据面可达 |
| 后台保活 | 🟡 中 | BLE 广播 + GATT 需长时任务；鸿蒙 `backgroundTaskManager` 与 Android 前台服务不同 |
| JSON 容错解析 | 🟢 低 | 厂商/三方新增字段不应导致解析失败；荣耀 status 曾回未定义的 `type=2`，按未知状态判失败，需核对各解析点 |

## 6. 参考资料

- [OPPOShareReceiver](https://github.com/testmybest/OPPOShareReceiver)（本地源码，GPL-3.0）
- [CatShare](https://github.com/kmod-midori/CatShare)（本地源码，MIT，Copyright 2025 Midori Kochiya）
- [EasyShare](https://github.com/HotKids/EasyShare)（本地源码，MIT，基于 CatShare 重构）
- 小米互传（MiShare）实现逆向：[MISHARE_REFERENCE.md](MISHARE_REFERENCE.md)（广播固定偏移解析、P2pInfo 字段、WS 字段与路径）
- HarmonyOS 官方文档：`ble.startAdvertising` / `ble.createGattServer` / `ScanFilter` / `wifiManager.createGroup` / `p2pConnect` / `getCurrentGroup` / `getP2pLinkedInfo` / `removeGroup`
- 平台能力实测结论与数据：[MTA_PLATFORM_VERIFICATION.md](MTA_PLATFORM_VERIFICATION.md)
