# MTA 平台能力与端到端互传真机验证

> 汇总 MTA 相关平台能力的真机验证结论与关键实测数据：BLE 双向互通、P2P 建组/连接、`p2pConnect` 加入匿名 GO、GO IP 与本机 p2p0 MAC 获取、多网络并行；并汇总端到端双向互传真机验证结论（目前仅荣耀）。
> 协议规格与工程实现落点见 [MTA_PROTOCOL_AND_IMPLEMENTATION.md](MTA_PROTOCOL_AND_IMPLEMENTATION.md)。

## 1. 验证设备信息

| 项 | 值 |
|---|---|
| HandySend 机型 / HarmonyOS 版本 | nova 15 Pro / API 24 |
| 端到端互传对端（真机双向） | 荣耀 HONOR 100 Pro（系统「荣耀分享」）；2026-09-13 完成发送、接收双向互传 |
| 能力验证对端 | CatShare（设备名 `m20`）；MatePad 10.8（可运行 Termux）；EasyShare 发送端 |
| 能力验证日期 | 2026-09-09 ~ 2026-09-13 |

> 本文档区分两类结论：**平台能力验证**（BLE / GATT / P2P 等单项能力，对端为开源 MTA 实现与测试设备，见 §3~§6）与**端到端互传验证**（完整链路收发，见 §8）。目前端到端双向互传仅在荣耀真机上完成。

## 2. 结论摘要

下表除首行（端到端互传）外均为**平台能力验证**结论；端到端互传结论见首行与 §8。

| 能力 | 结论 | 状态 |
|---|---|---|
| MTA 端到端双向互传（真机） | 与荣耀（HONOR 100 Pro，系统「荣耀分享」）双向发送/接收全部成功：BLE 发现 → GATT 凭据交换 → P2P 建组/入组 → WS 协商 → HTTPS ZIP 下载 → status 回执 | ✅ 目前唯一已验证的端到端互传对端（见 §8） |
| BLE 广播 + 扫描响应 | 真实 CatShare 可发现 HandySend，广播字节与协议逐字节一致 | ✅ |
| GATT Server 凭据通道 | CatShare 连接读 DeviceInfo、据此加密回写 P2pInfo 完整还原 | ✅ |
| BLE 扫描 + GATT Client | 可发现并解析 CatShare 广播字段，可反读其 DeviceInfo | ✅ |
| P2P 建组（GO） | GO IP=`192.168.49.1`、SSID 保留 `DIRECT-` 前缀、自定义 passphrase 生效 | ✅ |
| GO IP 获取 | `getP2pLinkedInfo().groupOwnerAddr` 普通应用返回全零；`p2pConnectionChange` 事件回调返回真实值 | 🟢 有解 |
| 本机 p2p0 MAC | `getP2pLocalDevice()` 全零、`p2pDeviceChange` 不触发；`getCurrentGroup().ownerInfo.deviceAddress` 返回真实 MAC | 🟢 正解 |
| P2P 主动发现 | 无定位权限时 0 台；引入 `APPROXIMATELY_LOCATION` 后可稳定发现（1~2 台） | ✅ 可用（需定位权限） |
| `p2pConnect` 数据面 | 可建组，安卓协商式 WLAN 直连下应用数据面完全可达（内核 main 表路由，GO/GC × 入站/出站四象限实测） | ✅ |
| `p2pConnect` 加入匿名 GO（接收端） | 全 0 设备地址 + 随机地址类型 + 临时组（netId=-1）注入 groupName/passphrase，可静默加入发送方 autonomous GO，不影响已连 WiFi，文件接收数据面可达 | ✅ 接收端正解 |

## 3. BLE 平台能力

### 3.1 广播与发现

HandySend 以 MTA 格式广播，真实 CatShare 的发送流程可发现该设备：

```
主广播(6B): 18 61 00 00 00 00
扫描响应(27B): 00 00 00 00 00 00 00 00 18 61 48 61 6e 64 79 53 65 6e 64 09 09 09 09 09 09 09 01
```

- 主广播 = serviceUuid `00003331-0000-1000-8000-008123456789` + serviceData `000001ff`（2B 发送者 ID `18 61` + 4B 零）；含 128 位 service UUID 后总长 31 字节，正好在上限内。
- 扫描响应 = 27 字节 serviceData `0000ffff`（[0-7] 零填充、[8-9] 发送者 ID `18 61`、[10-25] 设备名 `HandySend` + `\t` 填充、[26]=0x01）。
- **关键点**：主广播 service UUID 必须使用非标准基址 `00003331-0000-1000-8000-008123456789`（CatShare `ScanFilter.setServiceUuid` 按该值过滤）；使用标准蓝牙基址会导致扫描端匹配不上。

### 3.2 GATT Server 凭据交换

CatShare 连接 GATT Server 后读取 CHAR_STATUS 并回写 CHAR_P2P：

```
GATT Server: DeviceInfo={"state":0,"mac":"02:00:00:00:00:00","key":"MFkwEwYHKoZIzj0C...","catShare":7}
GATT Server: 客户端 4E:67:01:6C:18:55 已连接 / 读请求 offset=0
GATT Server: 写入分片 4E:67:01:6C:18:55 offset=0 total=256 prepared=false
GATT Server: 完整接收 (256 字符): {"id":"0943","ssid":"...","psk":"...","mac":"...","port":38303,"key":"...","catShare":7}
GATT Server: 客户端已断开
```

- DeviceInfo 四字段齐全，`key` 为合法 X.509 SPKI DER Base64（P-256）。
- CatShare 读走 DeviceInfo 后用其公钥 ECDH 加密 `ssid`/`psk`/`mac` 回写 P2pInfo，证明 HandySend 公钥格式被真实 MTA 实现接受。
- 写入 256 字节，MTU 协商后单包发完（`prepared=false`），完整还原一致。
- 编写侧需支持 `prepared write` 分片路径（按 `offset` 累积）以覆盖超 MTU 场景。

### 3.3 扫描与 GATT Client

```
扫描: 发现 m20 id=E8:31:38:5B:14:30 rssi=-33 senderId=0943 brand=第三方 5GHz=true
GATT Client: 读取成功: {"state":0,"key":"...","mac":"22:d0:98:12:82:08","catShare":7}
```

- serviceUuid 过滤生效，列表中仅出现 MTA 设备；`senderId=0943` 与 P2pInfo `id` 交叉一致。
- HandySend 作 GATT Client 可连接 CatShare 的 GATT Server 并读回其 DeviceInfo，读到的公钥与 §3.2 加密凭据所用公钥一致。

### 3.4 权限与边界

| 权限 | 结论 |
|---|---|
| `ohos.permission.ACCESS_BLUETOOTH` | 运行时授权后广播 / 扫描 / GATT Server / GATT Client 均可用 |
| 定位权限 | BLE 扫描（`startBLEScan`）在无定位权限下正常上报设备；定位仅 P2P 主动发现需要 |

已验证广播与 GATT Server 可同时在线。设备名超长截断、蓝牙关闭/权限拒绝提示、资源清理等边缘场景未专项测试。

## 4. P2P 平台能力

### 4.1 建组（发送端 GO）

```
创建群组: groupName=DIRECT-N82ZfypT passphrase=7qdloJkR goBand=0
查询群组: isP2pGo=true goIpAddress=192.168.49.1 interface=p2p-p2p0-0 frequency=2412 clientCount=0
```

- GO IP `192.168.49.1` 多次建组一致，硬编码兜底可行。
- SSID 保留 `DIRECT-` 前缀，自定义 8 位 passphrase 生效。
- `createGroup` 异步生效：调用后立即 `getCurrentGroup()` 可能返回 2801000（无群组），约 60ms 后 `p2pConnectionChange` 事件确认——**事件驱动是建组成功的准确信号**。
- 群组无客户端时 `clientDevices` 为 `undefined`，需容错。

### 4.2 GO IP 获取

| 数据源 | 结果 | 说明 |
|---|---|---|
| `getP2pLinkedInfo().groupOwnerAddr` | `00.00.00.00` 全零 | 手机端需 `GET_WIFI_LOCAL_MAC`（仅系统应用） |
| `p2pConnectionChange` 事件 `groupOwnerAddr` | `192.168.49.1` 真实值 | **可靠来源**，无需特权权限 |

结论：接收端 GO IP 取自 `p2pConnectionChange` 事件回调，`192.168.49.1` 作兜底。

### 4.3 本机 p2p0 真实 MAC（发送端）

| 数据源 | 结果 |
|---|---|
| `getP2pLocalDevice().deviceAddress` | `00:00:00:00:00:00` 全零（不可用） |
| `p2pDeviceChange` 事件 | 整个建组/连接生命周期未触发（不可用） |
| `getCurrentGroup().ownerInfo.deviceAddress` | `b8:7a:eb:7a:69:1d`（U/L 位=0 全局唯一，多次建组一致） |

结论：发送端 `P2pInfo.mac` 使用 `getCurrentGroup().ownerInfo.deviceAddress`（建组后查询，仅需 `GET_WIFI_INFO`）。

### 4.4 p2pConnect 加入匿名 GO（接收端关键路径）

`p2pConnect` 以如下 `WifiP2PConfig` 参数组合可静默加入发送方（Android）创建的匿名 autonomous GO：

| 字段 | 值 | 说明 |
|---|---|---|
| `deviceAddress` | `00:00:00:00:00:00` | 全 0 地址 |
| `deviceAddressType` | `RANDOM_DEVICE_ADDRESS`（0） | 随机地址类型 |
| `netId` | -1 | 临时组 |
| `groupName` | 解密出的 SSID | 凭据注入 |
| `passphrase` | 解密出的 PSK | 凭据注入 |
| `goBand` | `GO_BAND_AUTO`（0） | 自动频段 |

- 连接成功由 `p2pConnectionChange` 事件 `connectState=1` 确认；GO IP 取事件 `groupOwnerAddr`，`192.168.49.1` 作兜底。
- 加入群组不影响已连 WiFi（多网络并行，见 §4.6）。
- 能力实测：BLE 凭据通道 → p2pConnect 入组 → WS 协商 → 文件接收数据面打通；完整端到端双向互传以 §8 荣耀真机为准。
- 仅需 `GET_WIFI_INFO`（normal/system_grant），不需要定位权限。

### 4.5 P2P 主动发现与定位权限

- 无定位权限时 `startDiscoverDevices()` 返回 0 台。
- 引入 `ohos.permission.APPROXIMATELY_LOCATION` 后，`startDiscoverDevices()` + `p2pPeerDeviceChange` 可稳定发现周围 P2P 设备（1~2 台）。
- MTA 设备发现走 BLE，不依赖 P2P 主动发现；定位权限仅在该主动发现路径需要。
- 无 `GET_WIFI_PEERS_MAC` 权限时对端地址返回随机 MAC（U/L 位=1）。

### 4.6 互通与多网络

- 本机建组后，MatePad 10.8 可发现并加入（`clientCount` 0→1，对端 `status=CONNECTED`），本机保持 GO。
- p2pConnect 加入群组后原 WiFi 保持连接，IP 未切换（多网络并行）；接收端连接期间可同时保持蜂窝/宽带网络在线。
- P2P 网络不出现在 `getAllNets`，但 P2P 网段路由随连接装入内核 main 路由表（见 §5.1）。

## 5. p2pConnect 能力与接收端定论

### 5.1 数据面可达（安卓协商式 WLAN 直连实测）

在**安卓 WLAN 直连（走协商）**场景下，`p2pConnect` 能建立 P2P 组，**应用数据面完全可达**（GO/GC 双向可达）：

- P2P 网络不出现在 `getAllNets`（NetManager 应用层 API 看不到，无法 `bindSocket`/`setAppNet`），但 P2P 网段路由（`192.168.49.0/24 → p2p-p2p0-x`）随连接直接装入内核 main 路由表，未绑定网络的应用 socket 即可路由。
- 角色由对端状态/GO 协商决定（`netId` 不可控），GO 与 GC 两种角色均出现。
- 四象限实测：

| 角色 | 接口 IP | main 表路由 | ping 对端 | 应用层入站 | 应用层出站 |
|---|---|---|---|---|---|
| 本机 GO | 192.168.49.1 | ✅ | ✅ | ✅ HTTP 200 | —（响应双向已证） |
| 本机 GC | 192.168.49.227 | ✅ | ✅ | — | ✅ HTTP 200（本机 GC 主动出站访问对端 GO 服务） |

> 该数据面结论对 p2pConnect 建立的任意 P2P 组成立；接收端以 p2pConnect 加入发送方匿名 GO 的可行性见 §5.2。

### 5.2 p2pConnect 可加入厂商 autonomous GO（接收端定论）

**结论**：`p2pConnect` 对 MTA 接收端可行——以全 0 设备地址 + 随机地址类型 + 临时组（netId=-1）注入解密出的 `groupName`（SSID）/`passphrase`（PSK），可静默加入 MTA 发送端（CatShare/EasyShare，Android）创建的匿名 autonomous GO，不影响已连 WiFi，文件接收数据面可达。

| 目标设备状态 | `p2pConnect` 结果 |
|---|---|
| 安卓系统「WLAN 直连」页（listening，未成组） | ✅ 成功（本机以 GC 加入） |
| CatShare / EasyShare 建组后（autonomous GO，已成组） | ✅ 成功（全 0 地址 + RANDOM 类型 + 凭据注入 + 临时组） |

机制：WiFi Direct 加入既有组有「GO Negotiation（设备地址驱动，面向未成组/listening 对端）」与「按 SSID + PSK 静默加入（不走协商，面向 autonomous GO）」两条路径；`p2pConnect(WifiP2PConfig)` 在设备地址为全 0 时不再驱动 GO Negotiation，转而消费注入的 `groupName`/`passphrase` 按 SSID + PSK 静默加入，与 Android 接收端行为等价。

早期实验曾以非全 0 地址（发现列表采集的对端地址、P2pInfo.mac）配合 `netId` -1/-2、地址类型 0/1、凭据注入等组合连接 autonomous GO，事件均为 `connectState=DISCONNECTED`，`wpa_supplicant` 侧显示组接口 start 后被拆除——失败根因是地址驱动协商而非凭据注入无效。

### 5.3 接收端路径

MTA 接收端在鸿蒙上的路径为 **p2pConnect**：以全 0 设备地址 + 随机地址类型 + 临时组注入解密出的 SSID/PSK，静默加入发送方 WiFi Direct 组（autonomous GO），不影响已连 WiFi（多网络并行）。连接成功以 `p2pConnectionChange` 事件确认，GO IP 取事件 `groupOwnerAddr`；断开时 `p2pCancelConnect` + `removeGroup` 收尾。

## 6. 权限实测结论

| 权限 | 结论 |
|---|---|
| `GET_WIFI_INFO`（normal/system_grant） | createGroup / getCurrentGroup / getIpInfo / p2pConnect / removeGroup / `p2pConnectionChange` 事件均可用 |
| `ACCESS_BLUETOOTH` | BLE 广播 / 扫描 / GATT Server / GATT Client 均可用 |
| `APPROXIMATELY_LOCATION`（user_grant） | 仅 P2P 主动发现需要；接收端 p2pConnect 与 BLE 扫描不需要，接收端未声明 |
| `GET_WIFI_LOCAL_MAC`（系统应用） | 普通应用不可申请；对应 GO IP 全零问题已由事件回调替代 |
| `GET_WIFI_PEERS_MAC`（system_basic） | 未申请；对端地址返回随机 MAC，符合预期 |

## 7. 待验证项

| 项 | 说明 |
|---|---|
| GATT prepared write 分片 | 需构造 ≥512 字节分片写，验证 offset 累积与 `{}` 容错提取 |
| 与更多厂商设备互通（小米 / OPPO / vivo 等） | 荣耀已双向互通（见 §8）；其余联盟品牌需厂商真机验证 |
| 共享密钥派生兼容性 | 已在荣耀真机双向互通中验证（ECDH P-256 + AES-CTR 固定 IV 被对端接受） |
| p2pConnect 参数稳健性 | 全 0 地址 + RANDOM 类型 + netId=-1 组合已实测可行；其余字段取值边界（netId=-2、goBand 定频段等）未系统覆盖 |
| 边缘场景（蓝牙关闭 / 权限拒绝 / 设备名超长 / 资源清理） | 未专项测试，待补测 |

## 8. 端到端互传真机验证（荣耀）

2026-09-13 与荣耀 HONOR 100 Pro（系统「荣耀分享」）完成双向端到端互传，是目前唯一已验证的端到端互传对端。

| 方向 | 结果 |
|---|---|
| HandySend 发送 → 荣耀接收 | ✅ 成功（BLE 发现 → GATT 凭据 → HandySend 建组为 GO → 荣耀 WS 协商 → 拉取 `/download` ZIP → status 回执） |
| 荣耀发送 → HandySend 接收 | ✅ 成功（BLE 广播 / GATT Server → 荣耀建组为 GO → HandySend `p2pConnect` 入组 → WS 协商 → HTTPS ZIP 下载解压落盘 → status 回执） |

兼容性结论：

- **任务 ID 字段约定**：荣耀按 `id` 字段读写任务 ID，而非 `taskId`。HandySend 现已按 MTA 约定在 `sendRequest` 同时写入 `taskId`/`id`，解析时 `taskId` 缺失回退 `id`，`status` 回执携带 `taskId`。
- **ECDH / AES-CTR**：荣耀接受 HandySend 的 P-256 公钥与 AES-256-CTR（固定 16 字节 IV）加密凭据。
- **P2P 角色**：发送端由 HandySend 建组为 GO，接收端由 HandySend 以 `p2pConnect` 加入荣耀建立的匿名 GO，两种角色数据面均可达。

## 9. 参考资料

- [OPPOShareReceiver](https://github.com/testmybest/OPPOShareReceiver)、[CatShare](https://github.com/kmod-midori/CatShare)、[EasyShare](https://github.com/HotKids/EasyShare)（本地源码）
- 协议规格与实现落点：[MTA_PROTOCOL_AND_IMPLEMENTATION.md](MTA_PROTOCOL_AND_IMPLEMENTATION.md)
