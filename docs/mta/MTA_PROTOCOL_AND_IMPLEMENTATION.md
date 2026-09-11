# MTA（互传联盟）协议与实现

> 覆盖 MTA 协议全链路（BLE 发现 → GATT 凭据交换 → ECDH/AES 加密 → WiFi Direct 连接 → WebSocket 协商 → HTTPS ZIP 下载）、HarmonyOS 平台能力映射、工程实现落点，以及与厂商设备互通所需的品牌兼容映射。
> 平台能力真机实测结论与关键数据见 [MTA_PLATFORM_VERIFICATION.md](MTA_PLATFORM_VERIFICATION.md)。

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
  │       download?taskId=<id> ──────────→│  ZIP 流(entry: 序号/文件名)
  │     ZipInputStream 解压保存            │
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
- **扫描响应**（27 字节 @ `0000ffff`）：`[0-7] 零填充 [8-9] 发送者 ID [10-25] 设备名 [26]=0x01`。设备名区共 16 字节：≤16 字节原样放入并右侧补零；>16 字节截到 15 字节并以 `\t` 作截断标记；扫描端以首个 `0x00` 为终止符，UTF-8 截断按 codepoint 回退。
- 发送者 ID 按**无符号**解析（`(high & 0xff) << 8 | (low & 0xff)`），首字节 ≥0x80 时不得符号扩展。
- 5GHz/品牌信息编码在 serviceData UUID 字节中（`arr[2]`=5GHz 标志，`arr[3]`=品牌 ID，第三方用 `ff`）。
- 广播参数：legacy 模式、可连接、可扫描、interval 160（~100ms）、TX_POWER_HIGH。

### 1.4 数据模型（JSON key）

**DeviceInfo**（CHAR_STATUS 读返回）：

```json
{"state":0,"mac":"<蓝牙MAC>","key":"<ECDH公钥 base64>","catShare":7}
```

- `state` 固定 0；`mac` 为接收方蓝牙 MAC（三方应用可填兜底值）；`key` 为可选 ECDH P-256 公钥（存在则凭据加密传输）；`catShare` 为 CatShare 扩展版本标识（OPPO 硬编码 16，CatShare/EasyShare 填版本号，HandySend 填常量 7）。

**P2pInfo**（CHAR_P2P 写）：

```json
{"id":"a1b2","ssid":"<加密>","psk":"<加密>","mac":"<加密>","port":43210,"key":"<发送端公钥>","catShare":7}
```

- `id` 必填（vivo 发送端要求）；当 `DeviceInfo.key` 与 `P2pInfo.key` 均存在时，`ssid`/`psk`/`mac` 为 AES-CTR 加密后的 Base64；`port`/`id`/`key`/`catShare` 明文；`key` 缺失按明文处理。

**sendRequest payload**：`taskId`/`id`、`senderId`、`senderName`、`fileName`、`mimeType`、`fileCount`、`totalSize`，可选 `catShareText`（文本传输）、`thumbnail`；三方扩展 `senderBrand`/`senderBrandId` 厂商接收端忽略。

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
  - `status`（R→S）：消息 id 固定 99；`type=1 reason=ok`（成功）/ `type=1 reason=partial`（部分成功）/ `type=3 reason=user refuse`（拒绝）/ `type=3 reason=timeout`（接收端确认超时）。
- 状态机：`WAITING_VERSION → WAITING_SEND_REQUEST → WAITING_USER_ACCEPT → TRANSFERRING → COMPLETED/FAILED`。
- 消息 ID 规则：发送方从 0 递增（versionNegotiation=0, sendRequest=1）；接收方 status 固定 99。
- 发送端在传输全链路完成前不主动关闭 WS。

### 1.7 文件传输

- 发送方把多文件打包成 **ZIP 流**（`Content-Type: application/zip`），entry 名 `{序号}/{文件名}`（如 `0/photo.jpg`）；文本场景仅一个 entry `0/sharedText.txt`。
- 接收方流式解压，只取 `File(entry.name).name` 防路径穿越，重名加 `(1)` 后缀，忽略目录 entry；解压需防 zip bomb（大小/条目数上限）。
- TLS：发送方临时生成自签证书（域名含 127.0.0.1/0.0.0.0/localhost）；接收方信任所有证书 + hostname 恒真。
- 任务 ID：发送方随机数，同时写入 `taskId`/`id`；发送方收到 status `type=1` 后延迟约 1s 删组停服。
- 接收端用户确认超时约 31s（略长于厂商发送端等待窗口），确认前不开始下载。

### 1.8 WiFi Direct 规格

| 项 | 值 |
|---|---|
| 默认 GO IP | `192.168.49.1` |
| SSID 格式 | `DIRECT-<8位随机字符>`（Android WiFi Direct 约定） |
| PSK | 8 位随机字符 |
| 加密 | WPA2-PSK |
| 频段 | 目标支持 5GHz 且非 Samsung → `GROUP_OWNER_BAND_AUTO`；否则 `GROUP_OWNER_BAND_2GHZ` |
| 持久化 | `enablePersistentMode(false)` |

## 2. HarmonyOS 平台能力映射

| 协议环节 | HarmonyOS API | 权限 | 状态 |
|---|---|---|---|
| BLE 广播（主广播+扫描响应） | `ble.startAdvertising`（`advertisingData` + `advertisingResponse`） | `ACCESS_BLUETOOTH` | ✅ |
| BLE 扫描（serviceUuid 过滤） | `ble.startBLEScan` + `ScanFilter.serviceUuid` | `ACCESS_BLUETOOTH` | ✅ |
| GATT 服务端 | `ble.createGattServer` + `addService` + `on('characteristicRead/Write')` + `sendResponse` | `ACCESS_BLUETOOTH` | ✅ |
| GATT 长写 | `CharacteristicWriteRequest.isPrepared` 按 offset 累积 | — | ✅ |
| WiFi P2P 建组（GO） | `wifiManager.createGroup(WifiP2PConfig{groupName,passphrase,goBand})` | `GET_WIFI_INFO`（normal） | ✅ |
| 凭据直连（接收端） | `wifiManager.addCandidateConfig(WifiDeviceConfig{ssid,preSharedKey,securityType})` + `connectToCandidateConfig(networkId,{withUserAction})` | `SET_WIFI_INFO`（normal + system_grant，安装即授予） | ✅ |
| 获取 GO IP | `p2pConnectionChange` 事件 `groupOwnerAddr`（普通应用可用）；`192.168.49.1` 兜底 | `GET_WIFI_INFO` | ✅ |
| 本机 p2p0 真实 MAC（发送端） | `getCurrentGroup().ownerInfo.deviceAddress`（建组后查询） | `GET_WIFI_INFO`（normal） | ✅ |
| 对端真实 MAC（增强） | `getP2pPeerDevices`/`getScanInfoList` 等（`GET_WIFI_PEERS_MAC` 后返回真实地址） | `GET_WIFI_PEERS_MAC`（system_basic，需申请） | 🟠 可选，发送端 `P2pInfo.mac` 不依赖 |
| HTTPS 服务器+自签 | Rust hyper + rustls + rcgen | — | ✅ |
| WebSocket 客户端/协议 | ArkTS `MtaTransferClient`/协议纯函数 | — | ✅ |
| ECDH P-256 / AES-256-CTR | ArkTS `@kit.CryptoArchitectureKit` → `MtaCrypto` | — | ✅ |
| ZIP 解压 | ArkTS 流式解压 | — | ✅ |
| 三方应用开热点 | `@ohos.net.sharing` | — | ❌ 不开放（走 `createGroup`） |
| 定位权限 | `APPROXIMATELY_LOCATION`（仅 P2P 主动发现需要） | — | 接收端凭据直连不需要，HandySend 未声明 |

**权限结论**：接收端全链路仅需 `ACCESS_BLUETOOTH` + `GET_WIFI_INFO` + `SET_WIFI_INFO`（后二者为 normal 级 system_grant，安装即授予）；定位权限仅在 P2P 主动发现时需要，HandySend 接收端不使用 P2P 主动发现，故 `module.json5` 未声明该权限。

## 3. 实现落点

### 3.1 Rust 核心（`localsend_ohrs` 的 `mta` 模块）

1. 依赖：`zip`（deflate 打包）、`tokio-tungstenite`（WS）、`hyper`/`hyper-util`（HTTP + upgrade）、`tokio-rustls`/`rustls`/`rustls-pemfile`（TLS 服务端）；ECDH+AES-CTR 加解密在 ArkTS 侧（`MtaCrypto`）。
2. MTA WebSocket 服务器：`/websocket` 路径，实现 `type:id:name?json` 消息解析与状态机（versionNegotiation/sendRequest/status），对 action 消息回 ack。
3. MTA HTTPS 服务器：`/download?taskId=` 路由，ZIP 流式输出，临时自签证书。
4. NAPI 桥接：`nativeMta*` 函数 + 事件推送（发送请求、进度、完成、失败）。

### 3.2 ArkTS 层（`entry/src/main/ets/service/mta`）

- **BLE**：接收端广播（主广播 + 扫描响应格式）、发送端扫描（`ScanFilter.serviceUuid=00003331` + serviceData 解析）、GATT Server（`CHAR_STATUS` 读返回 DeviceInfo、`CHAR_P2P` 写解析含 prepared write 累积与 `{...}` 容错提取）、GATT Client。
- **WiFi Direct**：发送端 `createGroup`（`DIRECT-` 前缀）、接收端凭据直连、GO IP 获取（`p2pConnectionChange` 事件 + `192.168.49.1` 兜底）；发送端经 `getCurrentGroup().ownerInfo.deviceAddress` 获取本机 p2p0 MAC 填入 `P2pInfo.mac`。
- **加密**：`MtaCrypto`（ECDH P-256、SPKI+Base64、AES-256-CTR 固定 16 字节 IV）。
- **传输**：`MtaTransferClient`（WS 协商、HTTPS 流式下载、流式解压落盘）、`MtaSendService`（文件暂存 + 编排 + 事件处理 + 资源释放）、`MtaP2pGroup`（建组 + 群组信息）。

### 3.3 主流程接入

- **应用级仓储 `MtaRepository`**：持有一个仅用于发现的 `MtaBleClient`（每轮一次性扫描、结束后自动停止）与一个 MTA 接收服务单例；提供发现扫描、接收服务前台启停（按「互传联盟接收」设置，默认开启）、收发互斥与接收命令门面。
- **统一设备列表**：`DiscoveredDevice` 含可选 MTA 字段；发送页刷新时联动一轮 BLE 扫描，把发现的互传联盟设备经统一形状（`protocol = 'mta'`，BLE 标识作 fingerprint）并入附近设备列表。
- **MTA 传输页 `MtaTransferPage`/`MtaTransferViewModel`**：send 模式完成建组/协商/传输并展示会话级进度与结果；receive 模式订阅仓储接收快照，提供接受/拒绝/取消与进度。MTA 仅单目标。
- **文本收发**：`SendRequestPayload` 含可选 `catShareText`；发送侧文本以 ZIP 单条目 `1/sharedText.txt` 随包发送，接收侧解析后以可复制文本呈现并按文本消息写入接收历史。
- **生命周期与设置**：偏好键 `mtaReceiveEnabled`（默认 `true`）与设置页「互传联盟接收」开关；`EntryAbility.onForeground`/`onBackground` 按开关启停接收服务。

### 3.4 实施进展

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 协议验证 | 协议核心（ECDH/AES/WS/ZIP）研究与实现 | ✅ 已完成 |
| P0' 平台实测 | BLE 双向互通、P2P 建组、凭据直连、GO IP/SSID、本机 p2p0 MAC、p2pConnect 数据面 | ✅ 已完成（见 [MTA_PLATFORM_VERIFICATION.md](MTA_PLATFORM_VERIFICATION.md)） |
| P1 接收端闭环 | BLE 广播 + GATT + 凭据直连 + WS 协商 + 下载解压 | ✅ 代码完成，真机端到端互通待做 |
| P3 发送端 | createGroup + WS/HTTPS 服务器 + ZIP 打包 + BLE 扫描发现 | ✅ 代码完成，真机端到端互通待做 |
| P4 体验完善 | 文本传输、进度、接收历史、设置开关 | 🟡 部分（自动确认待定） |
| P5 主流程接入 | 发送页统一列表发现与单目标发送、前台自动接收、文本收发 | ✅ 代码完成，真机端到端待做 |

## 4. 品牌兼容映射

品牌兼容围绕「广播层品牌伪装、协议层厂商行为差异适配、WiFi Direct 层 OEM 差异处理、认证层 MAC 因子」四条主线。

### 4.1 品牌 ID 注册表

MTA 把品牌 ID 编码在主广播 serviceData UUID 的 `arr[3]`。基础映射：10-19 OPPO（11=Realme）、20-29 vivo、30-39 Xiaomi、41-45 OnePlus、50-59 Meizu、70-75 Samsung、100-109 Lenovo、`FF` 第三方。扩展注册表：Nubia 60-69（66=RedMagic）、ZTE 80-89、Smartisan 90-95、Motorola 110-119、NIO 120-129、Pixel 130-139、Honor 140-149、ASUS 161-169（160=ROG）、Hisense 170-179、Black Shark 32。

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

### 4.3 WiFi Direct 层 OEM 差异

- **频段选择**：目标广播 5GHz 支持且**非 Samsung** → `GROUP_OWNER_BAND_AUTO`；目标不支持 5GHz **或目标为 Samsung** → 强制 `GROUP_OWNER_BAND_2GHZ`（Samsung 的 WiFi Direct 在 AUTO/5GHz 下与三方建组互通有已知问题）。
- **建组/路由时序**（Android 侧差异，鸿蒙等价行为需实测后确定）：部分 OEM 首次建组可能失败需重试；移组后需 settle 再建新组；部分版本 P2P 路由已装但不暴露 `ConnectivityManager` Network，需按 p2p 接口名注册 NetworkCallback。
- **确认弹窗节奏**：厂商接收端用户确认弹窗约 30s，发送端「等待下载开始」超时必须大于该值。

### 4.4 MAC 认证因子

互传联盟协议把设备 MAC 作为认证信息的一部分：

- **发送端 `P2pInfo.mac`（本机 p2p0 MAC）**：鸿蒙正解为 `getCurrentGroup().ownerInfo.deviceAddress`（建组后查询，仅需 `GET_WIFI_INFO`），见 §2 与平台验证文档。
- **接收端 `DeviceInfo.mac`（蓝牙 MAC）**：三方应用拿不到可靠真实蓝牙 MAC，兜底 `02:00:00:00:00:00`；部分严格校验厂商（OPPO）可能因此拒绝，属三方应用结构性限制。鸿蒙「设置 → 关于本机 → 状态信息」展示真实 MAC，可文字引导用户查抄填入以改善通过率（无公开 URI 直达，需校验 `XX:XX:XX:XX:XX:XX` 格式）。

### 4.5 HandySend 对齐对照

| 品牌兼容点 | 厂商做法 | HandySend 现状 |
|---|---|---|
| 广播 serviceData UUID | `000001ff`/`0000ffff`（vivo 识别） | `MtaConstants.ADV_DATA_UUID`/`SCAN_RSP_UUID` 一致 |
| 广播品牌字节 | 本机真实品牌（伪装） | 固定 `0xff` 第三方（`BRAND_ID_THIRD_PARTY`）；华为非联盟成员，保持第三方合理 |
| status 消息 id=99、reason `ok`/`user refuse` | vivo 修复 | `STATUS_MESSAGE_ID=99`、reason 常量一致 |
| `P2pInfo.id` 必填 | vivo 修复 | `info.id = senderIdHex` |
| versionNegotiation 缺 `version` 默认 1 | vivo 修复 | 构造固定 `version:1`；接收侧缺字段按 1 |
| 对端 action 消息回 ack | 必须回 | Rust `ws.rs` 对任意 action 回 `ack:<原id>:<原name>` |
| Samsung 目标强制 2.4GHz | `requiresTwoGhzP2pCompatibility` | `MtaSendService` 按 `brandId ∈ [70,75]` 强制 `GROUP_OWNER_BAND_2GHZ` |
| 发送端不提前关 WS | 传输完成前不关 | `ws.rs` 收到 status 后不抢先关闭 + 宽限 |
| senderId 无符号解析 | `and 0xff` | `Uint8Array` 天然无符号 |
| GATT 长写 prepared write | `isPrepared` 累积 | `MtaBleReceiver` 已按 `isPrepared` 累积 |
| AES-CTR 固定 IV 16 字节 | 16 字节 ASCII | `AES_IV_TEXT` 16 字节 |
| legacy 密钥派生 | 裸 / `TlsPremasterSecret` | `agreement.generateSecret()`；真机兼容性为验证重点 |
| 发送端 p2p0 MAC | Shizuku / 特权读取 | `getCurrentGroup().ownerInfo.deviceAddress` |

## 5. 风险与待验证

| 风险项 | 评级 | 说明 / 缓解 |
|---|---|---|
| 共享密钥派生兼容性 | 🟠 中高 | 两实现本地一致（32B），与真实厂商设备兼容性待 P2 真机验证 |
| 接收端 `DeviceInfo.mac` 厂商校验 | 🟡 中 | 部分厂商校验 MAC；兜底值可能导致 OPPO 等拒绝，可引导手动填入 |
| GATT 长写分片 | 🟠 中 | `isPrepared` 按 offset 累积（参照 1024B/4096B 缓冲） |
| 会话服务器暴露面 | 🟡 中 | Rust server bind `0.0.0.0` 随机端口，同一 WiFi 内设备可能先 claim 会话；可评估校验对端地址或绑定 P2P 网络 |
| 多网络并行 | 🟡 中 | MTA 群组需以 SSID + PSK 静默加入（不走协商），鸿蒙无匹配接口，接收只能凭据直连、会断开当前 WiFi；`p2pConnect` 无法加入发送方匿名 autonomous GO |
| 后台保活 | 🟡 中 | BLE 广播 + GATT 需长时任务；鸿蒙 `backgroundTaskManager` 与 Android 前台服务不同 |
| JSON 容错解析 | 🟢 低 | 厂商/三方新增字段不应导致解析失败，需核对各解析点 |

## 6. 参考资料

- OPPOShareReceiver（本地源码，GPL-3.0）
- CatShare（本地源码，GPL-3.0）
- EasyShare（本地源码，MIT，基于 CatShare 重构）
- HarmonyOS 官方文档：`ble.startAdvertising` / `ble.createGattServer` / `ScanFilter` / `wifiManager.createGroup` / `p2pConnect` / `getCurrentGroup` / `getP2pLinkedInfo` / `addCandidateConfig`
- 平台能力实测结论与数据：[MTA_PLATFORM_VERIFICATION.md](MTA_PLATFORM_VERIFICATION.md)
