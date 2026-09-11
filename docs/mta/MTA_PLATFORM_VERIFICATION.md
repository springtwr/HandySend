# MTA 平台能力真机验证

> 汇总 MTA 相关平台能力的真机验证结论与关键实测数据：BLE 双向互通、P2P 建组/连接、凭据直连、GO IP 与本机 p2p0 MAC 获取、`p2pConnect` 数据面能力。
> 协议规格与工程实现落点见 [MTA_PROTOCOL_AND_IMPLEMENTATION.md](MTA_PROTOCOL_AND_IMPLEMENTATION.md)。

## 1. 验证设备信息

| 项 | 值 |
|---|---|
| HandySend 机型 / HarmonyOS 版本 | nova 15 Pro / API 24 |
| 对端安卓设备 | CatShare（设备名 `m20`）；MatePad 10.8（可运行 Termux）；EasyShare 发送端 |
| 验证日期 | 2026-09-09 ~ 2026-09-11 |

## 2. 结论摘要

| 能力 | 结论 | 状态 |
|---|---|---|
| BLE 广播 + 扫描响应 | 真实 CatShare 可发现 HandySend，广播字节与协议逐字节一致 | ✅ |
| GATT Server 凭据通道 | CatShare 连接读 DeviceInfo、据此加密回写 P2pInfo 完整还原 | ✅ |
| BLE 扫描 + GATT Client | 可发现并解析 CatShare 广播字段，可反读其 DeviceInfo | ✅ |
| P2P 建组（GO） | GO IP=`192.168.49.1`、SSID 保留 `DIRECT-` 前缀、自定义 passphrase 生效 | ✅ |
| GO IP 获取 | `getP2pLinkedInfo().groupOwnerAddr` 普通应用返回全零；`p2pConnectionChange` 事件回调返回真实值 | 🟢 有解 |
| 本机 p2p0 MAC | `getP2pLocalDevice()` 全零、`p2pDeviceChange` 不触发；`getCurrentGroup().ownerInfo.deviceAddress` 返回真实 MAC | 🟢 正解 |
| 凭据直连（接收端） | `addCandidateConfig` + `connectToCandidateConfig` 静默模式成功连上外部 WPA2 热点 | ✅ 正解成立 |
| P2P 主动发现 | 无定位权限时 0 台；引入 `APPROXIMATELY_LOCATION` 后可稳定发现（1~2 台） | ✅ 可用（需定位权限） |
| `p2pConnect` 数据面 | 可建组，安卓协商式 WLAN 直连下应用数据面完全可达（内核 main 表路由，GO/GC × 入站/出站四象限实测） | ✅ |
| `p2pConnect` 接收端可行性 | 无法加入 MTA 发送端创建的 autonomous GO，**不作为接收端路线** | ❌ 不可行 |

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

### 4.4 凭据直连（接收端关键路径）

```
凭据直连: ssid=M20 psk=13792468500 模式=静默
凭据直连: 添加候选配置成功 networkId=8，连接已发起（静默模式）
```

- `addCandidateConfig`（`securityType=WIFI_SEC_TYPE_PSK`）成功返回 networkId，`connectToCandidateConfig(networkId)` 静默模式连接外部 WPA2 热点成功。
- 对应 Android OPPO 的 `WifiNetworkSpecifier` 方案；`SET_WIFI_INFO`（normal/system_grant）实测可用。
- **凭据直连不需要定位权限**。

### 4.5 P2P 主动发现与定位权限

- 无定位权限时 `startDiscoverDevices()` 返回 0 台。
- 引入 `ohos.permission.APPROXIMATELY_LOCATION` 后，`startDiscoverDevices()` + `p2pPeerDeviceChange` 可稳定发现周围 P2P 设备（1~2 台）。
- MTA 设备发现走 BLE，不依赖 P2P 主动发现；定位权限仅在该主动发现路径需要。
- 无 `GET_WIFI_PEERS_MAC` 权限时对端地址返回随机 MAC（U/L 位=1）。

### 4.6 互通与多网络

- 本机建组后，MatePad 10.8 可发现并加入（`clientCount` 0→1，对端 `status=CONNECTED`），本机保持 GO。
- 「连接 P2P 组后原 WiFi 保持连接，IP 未切换」为**安卓 WLAN 直连（协商式）实验场景**的观测结果，不适用于 MTA 接收：MTA 接收端走凭据直连（把发送方 GO 当普通 WPA2 热点接入），会断开当前 WiFi。

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

> 该结论仅说明**协商式 WLAN 直连**的数据面可达，**不代表可加入 MTA 群组**——MTA 发送端创建的 autonomous GO 无法通过 `p2pConnect` 加入（见 §5.2）。

### 5.2 无法加入厂商 autonomous GO（接收端定论）

**结论**：`p2pConnect` 对 MTA 接收端不可行——它只能加入「listening/未成组」的对端，无法加入 MTA 发送端（CatShare/EasyShare，Android）创建的 autonomous GO。

| 目标设备状态 | `p2pConnect` 结果 |
|---|---|
| 安卓系统「WLAN 直连」页（listening，未成组） | ✅ 成功（本机以 GC 加入） |
| CatShare / EasyShare 建组后（autonomous GO，已成组） | ❌ `connectState=DISCONNECTED` |
| 凭据直连（把 GO 当 WPA2 热点） | ✅ 成功 |

机制：WiFi Direct 加入既有组有「GO Negotiation（设备地址驱动，面向未成组/listening 对端）」与「按 SSID + PSK 静默加入（`setNetworkName(ssid)`+`setPassphrase(psk)`，不走协商，面向 autonomous GO）」两条路径；MTA 发送端创建 autonomous GO，Android 接收端以 SSID + PSK 静默加入。鸿蒙当前无满足该条件的接口：`p2pConnect(WifiP2PConfig)` 只暴露 GO Negotiation，接口面不存在「按网络名加入」，注入 `groupName`/`passphrase` 仍走协商，故 `p2pConnect` 在接收 MTA 传输时会出错。ArkTS 与 Rust 均受此接口面约束（原生 WiFi C API `oh_wifi.h` 仅 STA 级，无 P2P）。

真机证据（MatePad + EasyShare 发送端）：收到 P2pInfo（ssid/psk/port）后以 `p2pConnect` 连接，事件 `connectState=DISCONNECTED`；`wpa_supplicant` 侧显示组接口曾 start 后被拆除（`wpas_p2p_group_started passphrase is null` → `wpa_vendor_ext_notify_group_delete`）。已覆盖变量（`netId` -1/-2、地址类型 0/1、`groupName`/`passphrase` 留空与注入、连接期间保持或停止发现、地址取自发现列表）均无法使其加入 autonomous GO。

### 5.3 接收端路径

MTA 接收端在鸿蒙上的可行路径为**凭据直连**：把发送方 WiFi Direct 组（autonomous GO）当普通 WPA2 热点接入（`addCandidateConfig` + `connectToCandidateConfig`），与 Android 侧 OPPO 的 `WifiNetworkSpecifier` 方案等价，接入时会断开当前 WiFi。因鸿蒙无满足「SSID + PSK 静默加入」的 P2P 接口，`p2pConnect` 不作为接收端备选路线。

## 6. 权限实测结论

| 权限 | 结论 |
|---|---|
| `GET_WIFI_INFO`（normal/system_grant） | createGroup / getCurrentGroup / getIpInfo / `p2pConnectionChange` 事件均可用 |
| `SET_WIFI_INFO`（normal/system_grant） | addCandidateConfig / connectToCandidateConfig 可用 |
| `ACCESS_BLUETOOTH` | BLE 广播 / 扫描 / GATT Server / GATT Client 均可用 |
| `APPROXIMATELY_LOCATION`（user_grant） | 仅 P2P 主动发现需要；凭据直连与 BLE 扫描不需要，接收端未声明 |
| `GET_WIFI_LOCAL_MAC`（系统应用） | 普通应用不可申请；对应 GO IP 全零问题已由事件回调替代 |
| `GET_WIFI_PEERS_MAC`（system_basic） | 未申请；对端地址返回随机 MAC，符合预期 |

## 7. 待验证项

| 项 | 说明 |
|---|---|
| GATT prepared write 分片 | 需构造 ≥512 字节分片写，验证 offset 累积与 `{}` 容错提取 |
| 带用户确认弹窗路径 | `connectToCandidateConfigWithUserAction` 未专项测试 |
| 与真实厂商设备互通（小米/OPPO/vivo） | 需厂商真机，P2 阶段开展 |
| 共享密钥派生兼容性 | 与真实厂商设备兼容性为 P2 验证重点 |
| 多网络并行深入 | MTA 接收端走凭据直连会断开当前 WiFi；原「原 WiFi 保持」观测仅适用于协商式 WLAN 直连实验，建议传输场景专项验证 |
| 边缘场景（蓝牙关闭 / 权限拒绝 / 设备名超长 / 资源清理） | 未专项测试，待补测 |

## 8. 参考资料

- OPPOShareReceiver、CatShare、EasyShare（本地源码）
- 协议规格与实现落点：[MTA_PROTOCOL_AND_IMPLEMENTATION.md](MTA_PROTOCOL_AND_IMPLEMENTATION.md)
