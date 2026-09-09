# MTA（互传联盟）协议整合研究报告

> 本文档整合基于 OPPOShareReceiver / CatShare 源码的逐行逆向分析（本报告主体），以及之前预研阶段的研究结论。两份研究在协议常量、广播格式、数据模型、WS 协议、加密规格、HarmonyOS 能力映射六大块结论一致，互相印证。本文档同时记录差异点、修正结论与真机验证重点，作为实施规划 [MTA_IMPLEMENTATION_PLAN.md](MTA_IMPLEMENTATION_PLAN.md) 的技术依据。

## 1. 结论摘要

- **协议可行性：可行。** MTA 协议链路（BLE 发现 → GATT 凭据交换 → ECDH/AES 加密 → WiFi Direct → WebSocket 协商 → HTTPS ZIP 下载）可在 HarmonyOS 上完整实现，平台 API 能力已逐项核实。
- **核心工作量**：Rust 核心新增 MTA 模块（WebSocket 服务器、HTTPS 下载、ECDH/AES 加密、ZIP 打包）+ ArkTS 层新增 BLE 广播/扫描、GATT 服务端、WiFi Direct 管理、接收/发送服务编排与 UI。
- **中高风险**：~~真实 MAC 获取（🔴，已降 🟡 见 §7.1）~~、WiFi P2P 凭据直连（🔴，之前预研补充）、GO IP 获取（🟠）、共享密钥派生兼容性（🟠）、GATT 长写分片（🟠）、BLE 广播 27 字节扫描响应（🟠）。
- **华为分享**：华为分享是私有协议，华为非互传联盟成员，与 MTA 不互通；鸿蒙底层短距能力（BLE/WiFi Direct）成熟开放，MTA 协议本身可完整实现，但不能复用华为分享通道。

## 2. 研究来源

| 项目 | 定位 | 角色 | 逆向依据 |
|------|------|------|---------|
| OPPOShareReceiver（本地源码） | MTA 接收端 | 仅接收 | `constants/MtaConstants.kt`、`model/MtaModels.kt`、`crypto/CryptoProvider.kt`、`ble/BleServerManager.kt`、`wifi/WifiConnectionManager.kt`、`transfer/MtaProtocol.kt`、`transfer/TransferManager.kt` |
| CatShare（本地源码） | MTA 双端 | 收发一体 | `services/GattServerService.kt`、`services/P2pReceiverService.kt`、`services/P2pSenderService.kt`、`services/BaseP2pService.kt`、`services/MacAddressService.kt`、`BleSecurity.kt`、`utils/BleUtils.kt`、`utils/WsUtils.kt`、`utils/P2pUtils.kt`、`utils/ShizukuUtils.kt`、`models/*.kt`、`ShareActivity.kt` |

两项目均实现 MTA 协议，可与小米、OPPO、vivo、一加、Realme、荣耀、魅族等互传联盟成员设备的系统互传功能互通。协议实现基于逆向工程，README 明示兼容性不保证。

## 3. MTA 协议全链路

### 3.1 完整握手时序

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

### 3.2 协议常量（两个项目完全一致）

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

### 3.3 广播数据格式

- **主广播**（≤31 字节）：serviceUuid `00003331` + serviceData `000001ff` = 6 字节 `[2B随机发送者ID][4B零]`。**不含设备名**（避免超 31 字节）。
- **扫描响应**（27 字节 @ `0000ffff`）：`[0-7]零填充 [8-9]发送者ID [10-25]设备名(UTF-8,≤15字节,超长补\t) [26]=0x01`。
- 5GHz/品牌信息编码在 serviceData UUID 字节中（`arr[2]`=5GHz 标志，`arr[3]`=品牌 ID，第三方用 `01ff`）。
- 广播参数：legacy 模式、可连接、可扫描、interval 160（~100ms）、TX_POWER_HIGH。

**品牌 ID 映射**：10-19 OPPO（11=Realme）、20-29 vivo、30-39 Xiaomi、41-45 OnePlus、50-59 Meizu、70-75 Samsung、100-109 Lenovo、FF 第三方。

### 3.4 数据模型（JSON key）

**DeviceInfo**（CHAR_STATUS 读返回）：
```json
{"state":0,"mac":"<蓝牙MAC>","key":"<ECDH公钥 base64>","catShare":16}
```
- `state`：固定 0；`mac`：三方应用可填 `02:00:00:00:00:00` 兜底；`key`：可选（存在则凭据加密传输）；`catShare`：CatShare 扩展标识（OPPO 硬编码 16，CatShare 填版本号）。

**P2pInfo**（CHAR_P2P 写）：
```json
{"id":"a1b2","ssid":"<加密>","psk":"<加密>","mac":"<加密>","port":43210,"key":"<发送端公钥>","catShare":7}
```
- 当 `DeviceInfo.key` 与 `P2pInfo.key` 均存在时，`ssid`/`psk`/`mac` 为 AES-CTR 加密后的 Base64；`port`/`id`/`key`/`catShare` 明文。

**sendRequest payload**：`taskId`/`id`、`senderId`、`senderName`、`fileName`、`mimeType`、`fileCount`、`totalSize`，可选 `catShareText`（文本传输）、`thumbnail`。

### 3.5 加密规格

| 项 | 值 |
|---|---|
| 密钥交换 | ECDH P-256（secp256r1），双方各生成一次性密钥对（每轮会话重新生成） |
| 公钥编码 | X.509 SubjectPublicKeyInfo DER → Base64（NO_WRAP） |
| 共享密钥 | `KeyAgreement.generateSecret()` → 32 字节原始 X 坐标（无 KDF） |
| AES 模式 | AES-256-CTR / NoPadding |
| AES IV | **`"0102030405060708"` ASCII 16 字节**（固定；⚠️ 非 8 字节，见 §6） |
| 加密对象 | 仅 P2pInfo 的 `ssid`/`psk`/`mac`；`P2pInfo.key` 存在即触发解密，缺失按明文处理 |
| TLS | WSS + HTTPS 自签名证书，双方信任所有证书 |

**安全注意**：固定 IV + 无 KDF 是已知弱点，但 MTA 协议如此设计，为兼容必须照此实现。此加密仅保护 BLE 通道传输的 WiFi 凭据，文件数据依赖 TLS（自签名 + 全信任，实际依赖 WiFi Direct 组隔离）。

### 3.6 WebSocket 应用层协议

- 消息格式：`type:id:name?json_payload`（正则 `^(\w+):(\d+):(\w+)(\?(.*))?$`）。
- `type` ∈ {`action`, `ack`}；`id` 为消息 ID（ack 复用原 id）。
- 消息类型：
  - `versionNegotiation`（S→R）：`{"version":1,"versions":[1]}`；回 ack `{"version":min(n,1),"threadLimit":5}`
  - `sendRequest`（S→R）：任务 JSON；回空 ack
  - `status`（R→S）：`{"type":1,"reason":"ok"}`（成功）/ `{"type":3,"reason":"user refuse"}`（拒绝）
- 状态机：`WAITING_VERSION → WAITING_SEND_REQUEST → WAITING_USER_ACCEPT → TRANSFERRING → COMPLETED/FAILED`
- 消息 ID 规则：发送方从 0 递增（versionNegotiation=0, sendRequest=1）；接收方主动消息 OPPO 从 100 递增、CatShare status 固定 99。

### 3.7 文件传输

- 发送方把多文件打包成 **ZIP 流**（`Content-Type: application/zip`），entry 名 `{序号}/{文件名}`（如 `0/photo.jpg`）；文本场景仅一个 entry `0/sharedText.txt`。
- 接收方 `ZipInputStream` 流式解压，只取 `File(entry.name).name` 防路径穿越，重名加 `(1)` 后缀，忽略目录 entry。
- TLS：发送方临时生成自签证书（Ktor `buildKeyStore`，域名含 127.0.0.1/0.0.0.0/localhost）；接收方信任所有证书 + hostname 恒真。
- 任务 ID：发送方随机数，同时写入 `taskId`/`id`；发送方收到 status type=1 → delay(1s) → 删组停服。

### 3.8 WiFi Direct 规格

| 项 | 值 |
|---|---|
| 默认 GO IP | `192.168.49.1` |
| SSID 格式 | `DIRECT-<8位随机字符>`（Android WiFi Direct 约定） |
| PSK | 8 位随机字符 |
| 加密 | WPA2-PSK |
| 频段 | 根据目标设备是否支持 5GHz：支持 → `GROUP_OWNER_BAND_AUTO`，否则 `GROUP_OWNER_BAND_2GHZ` |
| 持久化 | `enablePersistentMode(false)` |

## 4. HarmonyOS 平台能力映射

### 4.1 能力映射（已用 devecocli 官方文档逐项核实）

| 协议环节 | HarmonyOS API | 权限 | 状态 |
|---|---|---|---|
| BLE 广播（主广播+扫描响应） | `ble.startAdvertising`（`AdvertisingParams.advertisingData` + `advertisingResponse`） | `ACCESS_BLUETOOTH` | ✅ |
| BLE 扫描（serviceUuid 过滤） | `ble.startBLEScan` + `ScanFilter.serviceUuid` | `ACCESS_BLUETOOTH` | ✅ |
| GATT 服务端 | `ble.createGattServer` + `addService` + `on('characteristicRead/Write')` + `sendResponse` | `ACCESS_BLUETOOTH` | ✅ |
| GATT 长写 | `CharacteristicWriteRequest.isPrepared` 字段 | — | ✅ 需按 offset 累积 |
| WiFi P2P 建组（GO） | `wifiManager.createGroup(WifiP2PConfig{groupName,passphrase,goBand})` | `GET_WIFI_INFO`（普通） | ✅ |
| WiFi P2P 连接 | `wifiManager.p2pConnect` / `removeGroup` | `GET_WIFI_INFO`（普通） | ⚠️ 凭据直连需实测 |
| **凭据直连候选组（关键补充）** | `wifiManager.addCandidateConfig(WifiDeviceConfig{ssid,preSharedKey,securityType})` + `connectToCandidateConfig(networkId,{withUserAction})` | **`SET_WIFI_INFO`（normal + system_grant，开放权限，安装即授予）** | ✅ 官方确认开放 |
| 获取 GO IP | `getP2pLinkedInfo().groupOwnerAddr` / `getCurrentGroup().goIpAddress` | ⚠️ `GET_WIFI_LOCAL_MAC`（手机仅系统应用） | 🟠 |
| 三方应用开热点 | `@ohos.net.sharing` | — | ❌ 不可用（d.ts 无方法） |
| HTTPS 服务器+自签 | Rust 核心 hyper + rustls + rcgen（已具备） | — | ✅ |
| WebSocket 服务器 | Rust 核心 tokio-tungstenite（需新增 server 端） | — | 🟠 |
| ECDH P-256 | Rust 核心新增 `p256` crate | — | 🟠 |
| AES-256-CTR | Rust 核心新增 `aes` crate | — | 🟠 |
| ZIP 打包/解压 | Rust 核心新增 `zip` crate | — | 🟠 |
| 真实 MAC（发送端 p2p0） | **`getCurrentGroup().ownerInfo.deviceAddress`（P0 实测正解）** / ~~`getP2pLocalDevice()`（全零）~~ / ~~`p2pDeviceChange`（不触发）~~ | `GET_WIFI_INFO`（普通） | ✅ 实测成立（见 §7.1） |
| 对端真实 MAC（增强） | `GET_WIFI_PEERS_MAC` 权限后 `getP2pPeerDevices`/`getCurrentGroup`/`getScanInfoList`/`p2pPeerDeviceChange` 返回真实地址 | `GET_WIFI_PEERS_MAC`（system_basic + system_grant，**API 14 起普通应用开放**） | 🟠 需 ACL/AGC 申请，发送端 P2pInfo.mac 不依赖 |

### 4.2 需要做的工作清单（未来实现时）

**A. Rust 核心（localsend_ohrs 新增 `mta` 模块）**
1. 新增依赖：`p256`（ECDH）、`aes`（AES-CTR）、`zip`（打包）、`tokio-tungstenite` server feature。
2. MTA 加密：ECDH P-256 密钥对生成/派生、公钥 SPKI+Base64 编解码、AES-256-CTR 加解密（固定 IV 16 字节）。
3. MTA WebSocket 服务器：`/websocket` 路径，实现 `type:id:name?json` 消息解析与状态机（versionNegotiation/sendRequest/status）。
4. MTA HTTPS 服务器：`/download?taskId=` 路由，ZIP 流式输出，临时自签证书。
5. NAPI 桥接：`nativeMta*` 函数 + 事件推送（发送请求、进度、完成）。

**B. ArkTS 层（entry 模块）**
6. BLE 服务：接收端广播（`startAdvertising` 主广播+扫描响应格式）、发送端扫描（`ScanFilter.serviceUuid=00003331` + serviceData 解析）。
7. GATT 服务端：`createGattServer` + `00009955` 服务 + 两特征值，CHAR_STATUS 读返回 DeviceInfo、CHAR_P2P 写解析（含 prepared write 累积、`{...}` 提取容错）。
8. WiFi Direct 管理：发送端 `createGroup`（DIRECT-xxx）、接收端 P2P 连接，GO IP 获取（硬编码 192.168.49.1 兜底）；**发送端通过 `getP2pLocalDevice()`（建组后）或 `p2pDeviceChange` 事件获取本机 p2p0 MAC 填入 `P2pInfo.mac`**。
9. MTA 服务编排：接收/发送流程状态机 + 长时任务 + 权限申请（ACCESS_BLUETOOTH、GET_WIFI_INFO、定位）。
10. UI：MTA 设备列表/接收确认弹窗/传输进度，复用现有传输页组件。

**C. 配置**
11. `module.json5` 新增权限：`ohos.permission.ACCESS_BLUETOOTH`、`ohos.permission.GET_WIFI_INFO`、定位（BLE 扫描兜底）；可选 `ohos.permission.GET_WIFI_PEERS_MAC`（对端真实地址，system_basic，API 14+ 普通应用开放，需 AGC 申请）。
12. 设置页新增 MTA 开关。

## 5. 风险矩阵（合并两报告评级）

| 风险项 | 评级 | 缓解措施 |
|--------|------|---------|
| BLE GATT Server / 广播 / 扫描过滤 | 🟢 低 | API 完整，官方有示例 |
| BLE 广播 27 字节扫描响应 | 🟠 中 | `advertisingResponse` 支持自定义 serviceData（≤31 字节限制内）；需真机验证主广播+扫描响应同时发送 |
| WiFi P2P 做 GO（发送端） | 🟡 中 | `createGroup()` 可用（GET_WIFI_INFO 权限）；GO IP 与 SSID 格式需实测；备选局域网降级 |
| **WiFi P2P 凭据直连（接收端）** | 🟡 中→🟢 有解 | `p2pConnect()` 是标准协商流程，与"已知 SSID+PSK 直连"不匹配；**替代路径：`addCandidateConfig`+`connectToCandidateConfig`（SET_WIFI_INFO 开放权限）把 P2P 组当普通 WPA2 热点直连**；备选局域网降级 |
| 三方应用开热点 | 🔴 不可用 | `@ohos.net.sharing` 不开放；只能 `createGroup` 走 P2P，或跳转设置页（不可控） |
| 多网络并行 | 🟡 中 | 连接 P2P 后原 WiFi 是否断开需实测 `@ohos.net.connection` 绑定行为 |
| 真实 MAC（发送端 p2p0） | 🟡 有解 | **`getP2pLocalDevice().deviceAddress`（建组后）或 `p2pDeviceChange` 事件直接获取本机 p2p0 MAC，仅需 `GET_WIFI_INFO`**；需实测与厂商设备校验兼容性；接收端蓝牙 MAC 走手动输入增强或 `02:00:00:00:00:00` 兜底；对端真实 MAC 增强依赖 `GET_WIFI_PEERS_MAC`（API 14+ 普通应用开放） |
| 共享密钥派生差异 | 🟠 中高 | 两实现本地实测一致（32B）；与真实厂商设备兼容性需真机验证 |
| GATT 长写分片 | 🟠 中 | `isPrepared` 字段支持；需按 offset 累积到缓冲（参照 CatShare 1024B） |
| HTTPS 自签名 / ECDH+AES / ZIP | 🟢 低 | Rust 生态成熟 |

## 6. 双份研究对比印证结论

### 6.1 完全一致、互相印证的部分 ✅

协议常量、广播格式、数据模型、WS 协议、加密规格、文件传输、WiFi Direct 规格、品牌 ID 映射、HarmonyOS BLE 能力、Rust 层方案、华为分享结论、权限结论——十二项全部一致，MTA 协议逆向结论可信度高。

### 6.2 之前预研需修正的点 ⚠️

**🔴 实质错误：AES IV 字节数**
- 之前预研 §3.8 写 "8 字节"；实际 `"0102030405060708"` 是 **16 个 ASCII 字符 = 16 字节**（已用脚本验证字符数=字节数=16；已核实两项目源码均为 `"0102030405060708".toByteArray()`）。
- AES-CTR 的 IV 必须是 16 字节（128-bit 计数器），**实现时务必按 16 字节**，否则无法与厂商设备互通。

**🟠 遗漏：共享密钥派生差异**
- 之前预研只写"原始 32 字节（无 KDF）"（OPPO 方式）；CatShare 实际用 `generateSecret("TlsPremasterSecret")`。经 JDK 17 实测两实现运行结果一致（均 32 字节），但与真实厂商设备兼容性未验证——真机验证重点。

**🟠 遗漏：GATT 长写分片（prepared write）**
- 之前预研未提及。P2pInfo JSON 可能超 MTU，HarmonyOS `CharacteristicWriteRequest.isPrepared` 支持长写，需按 offset 累积。

### 6.3 之前预研更深入、应采纳的点 💡

**WiFi P2P 连接方式的关键限制（之前预研 §4.2 限制 2）——最重要补充**
- MTA 接收方需用已知 SSID+PSK 直连发送方的 WiFi Direct 热点；HarmonyOS `p2pConnect()` 是标准 P2P 流程（先发现→协商→连接），两者不匹配。
- Android CatShare 用 `WifiP2pConfig.setNetworkName(ssid).setPassphrase(psk)` 直连（API 27+）；OPPO 用 `WifiNetworkSpecifier` 把 P2P 热点当普通 WPA2 网络直连（不切走当前 WiFi）。
- 鸿蒙是否支持"凭据直连"未在文档中明确，**是接收端最大平台不确定性，必须真机实测**。

**多网络并行（之前预研 §4.2 限制 3）**：OPPO 用 `WifiNetworkSpecifier` 的核心价值是不切走当前 WiFi；若鸿蒙直连会切断现有网络，UX 明显劣化（传输期间无法上网）。

**局域网降级方案（之前预研 §6）**：WiFi Direct 不可行时的兜底路径——保留 BLE 发现，传输走局域网 IP。需额外机制告知发送方接收方 IP。

### 6.4 风险评级分歧（我方坚持保守）

| 事项 | 之前预研 | 本报告 | 依据 |
|---|---|---|---|
| 真实 MAC | 🟢 低（"MAC 并非关键认证因子"） | 🔴 高 | CatShare README 明确"互传联盟协议将设备的 MAC 地址作为其认证信息的一部分……目前暂时无法绕过"；实测 OPPO 发送端提示接收失败。兜底方案一致，但风险认知不同。 |

> **后续修正（2026-09）**：经核实 HarmonyOS 文档，发送端本机 p2p0 MAC 可通过 `getP2pLocalDevice()`（建组后）或 `p2pDeviceChange` 事件获取（仅需 `GET_WIFI_INFO`），风险已降至 🟡（详见 §7.1）；接收端 `DeviceInfo.mac`（蓝牙 MAC）另有"状态信息页手动输入"增强方案。

## 7. 中高风险事项深度分析

### 🟢 7.1 真实 MAC 获取（发送端 p2p0 — 实测正解）

> **P0 真机实测结论（2026-09，nova 15 Pro）**：本报告最初文档假设的两条路径均**实测不可用**，正解为 `getCurrentGroup().ownerInfo.deviceAddress`。详见 [P2P_VERIFICATION_REPORT.md](P2P_VERIFICATION_REPORT.md) §2.3。

- **问题**：MTA 把 MAC 作为设备认证信息。CatShare 在 Android 需 Shizuku 特权才能读 `p2p0` 真实 MAC；HarmonyOS 普通应用拿不到 `GET_WIFI_LOCAL_MAC`（仅系统应用）。
- **发送端 p2p0 MAC — 🟢 有解（实测确认）**：HarmonyOS 本机 P2P 设备地址获取路径实测结果：
  | 方式 | 接口 | 前提条件 | 实测结果 |
  |------|------|---------|---------|
  | ~~主动获取~~ | ~~`getP2pLocalDevice()`（API 9+）~~ | P2P 已建组或连接成功 | ❌ **返回全零 `00:00:00:00:00:00`** |
  | ~~事件监听~~ | ~~`on('p2pDeviceChange')`（API 10+）~~ | 无限制 | ❌ **建组/连接全程不触发** |
  | **群组 ownerInfo** | `getCurrentGroup().ownerInfo.deviceAddress` | 已建组/连接（发送端天然满足） | ✅ **返回真实 MAC**（U/L=0，多次建组一致） |
  - `getCurrentGroup().ownerInfo.deviceAddress` 仅需开放权限 `GET_WIFI_INFO`，返回本机真实 p2p0 MAC（实测 `b8:7a:eb:7a:69:1d` 为全局唯一地址，非随机）。
  - **发送端流程天然满足前提**：`createGroup()` 建组后直接 `getCurrentGroup()` 取 `ownerInfo.deviceAddress` 填 `P2pInfo.mac`。
  - ⚠️ 待 P2 真机验证：该真实 MAC 与安卓厂商设备识别/校验的兼容性。
- **对端设备真实 MAC（增强）**：`GET_WIFI_PEERS_MAC` 权限（system_basic，system_grant，**API 14 起向普通应用开放**）——申请后 `getP2pPeerDevices`/`getCurrentGroup`/`getScanInfoList`/`p2pPeerDeviceChange` 返回真实 deviceAddress/bssid；无此权限返回随机地址（实测对端 `42:b0:1c:...` 为随机 MAC）。发送端 `P2pInfo.mac` 不需要它（那是本机地址），但可用于扫描对端时获取真实标识。
- **缓解**（接收端 `DeviceInfo.mac`，蓝牙 MAC）：
  1. 兜底：用蓝牙 MAC（HarmonyOS BLE 可获取本机地址）或 `02:00:00:00:00:00`。
  2. **手动输入增强（仅接收端有效）**：鸿蒙手机/平板"设置 → 关于本机 → 状态信息"页展示真实 MAC（含"Wi-Fi MAC 地址"与"蓝牙 MAC 地址"条目）。`DeviceInfo.mac` 定义的正是接收方蓝牙 MAC，引导用户一次性查抄填入可改善 OPPO 等严格校验厂商的识别通过率；MAC 固定不变，属一次性设置。限制：无公开 URI 直达该页，仅能文字引导导航；需校验输入格式 `XX:XX:XX:XX:XX:XX`。
  3. 实测：CatShare 实测小米/vivo 发送正常、OPPO 发送端提示接收失败——部分厂商校验 MAC、部分不校验，需逐一真机验证。
  4. 进阶：系统能力申请（`GET_WIFI_LOCAL_MAC`），属后续增强。
- **影响**：作为接收端影响"厂商设备列表中是否显示本机/是否接受传输"；作为发送端影响"对方是否校验 GO MAC"（已由 `getP2pLocalDevice()` 解决）。

### 🟢 7.2 WiFi P2P 凭据直连（接收端 — 实测成立）

> **P0 真机实测结论（2026-09）**：`addCandidateConfig` + `connectToCandidateConfig` 静默模式成功连上外部 WPA2 热点，正解成立。详见 [P2P_VERIFICATION_REPORT.md](P2P_VERIFICATION_REPORT.md) §2.4。

- **问题**：MTA 接收方拿到 ssid/psk 后需直接连接发送方创建的 WiFi Direct 组；鸿蒙 `p2pConnect()` 文档示例面向"发现设备后协商连接"，未明确支持凭据直连。
- **正解（已实测）**：`wifiManager.addCandidateConfig(WifiDeviceConfig{ssid, preSharedKey, securityType})` + `connectToCandidateConfig(networkId)`——把发送方的 WiFi Direct 组当普通 WPA2 热点凭据直连，与 Android OPPOShareReceiver 的 `WifiNetworkSpecifier` 方案对应。**权限 `SET_WIFI_INFO` 已确认开放**（normal 级别 + system_grant，安装即授予）。
- **已验证**：① `addCandidateConfig` 返回 networkId，`connectToCandidateConfig` 静默模式连接成功；② `p2pConnect` 协商路径依赖 P2P 主动发现（鸿蒙实测不可用），不作为依赖。
- **待验证**：带用户确认弹窗路径（`connectToCandidateConfigWithUserAction`）、连接 WiFi Direct P2P 组（而非普通 AP）、连接后原 WiFi 是否断开。
- **兜底**：局域网降级方案（BLE 发现 + 局域网 IP 传输）。

### 🟠 7.3 GO IP 获取（实测补充）

> **P0 真机实测结论（2026-09）**：`getP2pLinkedInfo().groupOwnerAddr` 普通应用返回全零（需 `GET_WIFI_LOCAL_MAC`）；**`p2pConnectionChange` 事件回调返回真实 GO IP**（实测 `192.168.49.1`）。详见 [P2P_VERIFICATION_REPORT.md](P2P_VERIFICATION_REPORT.md) §2.2。

- `getP2pLinkedInfo().groupOwnerAddr`/`getCurrentGroup().goIpAddress` 在手机上需 `GET_WIFI_LOCAL_MAC`（普通应用返回全零）。
- **缓解（已实测）**：监听 `p2pConnectionChange` 事件取 `groupOwnerAddr`（真实值，仅需 `GET_WIFI_INFO`）+ 硬编码 `192.168.49.1`（实测一致，OPPOShareReceiver 亦验证可行）兜底。
- **影响**：接收端连不上 GO 则整个传输无法进行——接收端最关键连通点。

### 🟠 7.4 共享密钥派生兼容性

- CatShare 用 `TlsPremasterSecret`，OPPO 用 `generateSecret()`；两实现本地实测一致（32 字节），与真实厂商设备兼容性未验证。OPPO 接收 CatShare 发送"提示失败"可能与此相关。
- **缓解**：Rust 实现两种派生路径（32B 原始 / TLS premaster 兼容），真机验证后锁定；或先按 `generateSecret()`（32B 原始）实现——两 Android 项目共同交集。

### 🟠 7.5 GATT 长写分片

- P2pInfo JSON（含 base64 公钥）可能超 BLE MTU（默认 23 字节，协商后 512）。
- HarmonyOS `CharacteristicWriteRequest.isPrepared` 支持长写，需按 `offset` 累积到缓冲（参照 CatShare 1024B 缓冲），`isPrepared=false` 时触发解析。
- 另注意 OPPO 的容错：从原始字节找第一个 `{` 到最后一个 `}` 截取 JSON（数据前可能有 preamble 字节）。

### 🟠 7.6 其他

- **P2P 组网行为**：鸿蒙 `createGroup` 的 `goBand`/`groupName`/`passphrase` 是否与 Android WiFi Direct 完全兼容（SSID `DIRECT-` 前缀是 Android 约定，鸿蒙是否强制）需验证。
- **后台保活**：BLE 广播 + GATT 服务需要长时任务，鸿蒙 `backgroundTaskManager`（`BLUETOOTH_INTERACTION` 类型）与 Android `FOREGROUND_SERVICE` 不同，需适配。
- **ZIP 安全**：解压需防 zip bomb（大小/条目数上限），参照 CatShare 对路径穿越的处理。

## 8. 关于"华为分享"

- **结论**：华为分享（Huawei Share / `@kit.ShareKit` 的 `harmonyShare`）是**华为私有协议**（NFC 触碰 + BLE + WiFi Direct），华为**不是互传联盟成员**，华为分享与 MTA **不互通**。两者是**互补而非替代**关系。
- **鸿蒙可借鉴的**：系统内置分享框架的 UI/UX、`ohos.want.action.sendData` 分享入口（HandySend 已支持）可作为 MTA 发送的入口整合点。
- **平台可行性确认**：鸿蒙底层短距能力（BLE 广播/GATT、WiFi Direct）成熟且 `createGroup`/`p2pConnect` 对普通应用开放（仅需 `GET_WIFI_INFO`），因此 MTA 协议在鸿蒙上完整实现可行。

## 9. 建议的实施路径

| 阶段 | 内容 | 依赖 |
|---|---|---|
| P0 协议验证 | Rust MTA 核心 + 单元测试（加密/WS 状态机/ZIP） | 无真机 |
| P0' 平台实测 | 最小验证 App：BLE 广播/扫描、P2P createGroup、**`addCandidateConfig`+`connectToCandidateConfig` 凭据直连（与 `p2pConnect` 对比）**、GO IP/SSID 实测、多网络并行、**`getP2pLocalDevice()`/`p2pDeviceChange` 获取本机 p2p0 MAC 及厂商兼容性实测** | 鸿蒙真机 |
| P1 接收端闭环 | BLE 广播 + GATT + WiFi 连接（硬编码 192.168.49.1 兜底）+ WS + 下载 | P0'/P0 |
| P2 真机互通验证 | 与小米/OPPO/vivo 实测，校准密钥派生/MAC/GO IP/凭据直连 | 双机 |
| P3 发送端 | createGroup + WS/HTTPS 服务器 + ZIP 打包 + BLE 扫描发现 | P1/P2 |
| P4 体验完善 | 文本传输、自动确认、进度、历史记录、设置开关 | P3 |

**最小可行（MVP）**：P0 + P0' + P1，实现"接收厂商设备文件"闭环，与 OPPOShareReceiver 对应。

## 10. 与实施规划的衔接

本报告为技术研究结论，实施细节见 [MTA_IMPLEMENTATION_PLAN.md](MTA_IMPLEMENTATION_PLAN.md)（分阶段任务、NAPI 函数清单、权限清单、里程碑估算）。本报告对实施规划的评审结论（2026-08-29）：

1. **接收端凭据直连正解**（🔴 P0）：新增验证 `addCandidateConfig`+`connectToCandidateConfig`（`SET_WIFI_INFO` 开放权限，normal + system_grant）把 P2P 组当普通 WPA2 热点直连，与 `p2pConnect()` 对比。**已同步修订实施计划 §4.0/§4.1/§7**。
2. **权限清单补 `SET_WIFI_INFO`**（🔴 P0）：已加入实施计划 §7。
3. **蓝牙 MAC 风险升级**（🟠 P0）：从 🟢 升 🔴，P0 需真实安卓设备验证厂商识别。已同步修订实施计划 §2。
4. **发送端 p2p0 MAC 有解**（🟡 P0）：`getP2pLocalDevice()`（建组后）与 `p2pDeviceChange` 事件（无前提）可获本机 p2p0 MAC，仅需 `GET_WIFI_INFO`；对端真实 MAC 增强依赖 `GET_WIFI_PEERS_MAC`（system_basic，API 14+ 普通应用开放）。风险从 🔴 降 🟡，P0 实测厂商兼容性。**已同步修订实施计划 §2/§4.1**。
5. **AES IV 按 16 字节**（🟠 实现期）：已写入实施计划 §1 修订记录与任务 1-1。
6. **共享密钥派生双路径兼容**（🟠 实现期）：已写入实施计划 §1 修订记录与任务 1-1。
7. **GATT 长写分片**（🟠 实现期）：已补充到实施计划任务 2-7。

> 实施计划其余部分（接收端优先、Rust/ArkTS 分层、P0 实测先行、局域网降级、里程碑估算 22-32 天）经评审确认合理，无需修改。

## 11. 参考资料

- [MTA_IMPLEMENTATION_PLAN.md](MTA_IMPLEMENTATION_PLAN.md)（实施规划）
- OPPOShareReceiver（本地源码，GPL-3.0）
- CatShare（本地源码，GPL-3.0）
- HarmonyOS 官方文档：`ble.startAdvertising` / `ble.createGattServer` / `ScanFilter` / `wifiManager.createGroup` / `p2pConnect` / `getCurrentGroup` / `getP2pLinkedInfo`（经 `devecocli docs` 核实）
