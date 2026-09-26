# MTA 协议跨厂商对照（小米 / 中兴 / CatShare / EasyShare / HandySend）

> 汇总各实现对 MTA（互传联盟）协议的关键行为，用于跨厂商兼容性判断与问题定位。
> 小米来自 `com.miui.mishare.connectivity` 反编译（见 [MISHARE_REFERENCE.md](MISHARE_REFERENCE.md)）；
> 中兴来自 `com.zte.cn.zteshare` 反编译；CatShare / EasyShare 为本地源码；
> HandySend 为本项目实现与真机日志。工程落点见
> [MTA_PROTOCOL_AND_IMPLEMENTATION.md](MTA_PROTOCOL_AND_IMPLEMENTATION.md)。

## 1. 角色与总体流程

- **接收方**广播（BLE）并提供 GATT Server；**发送方**扫描 → 连接接收方 GATT Server → 读 DeviceInfo →
  建 WiFi Direct 组（**作 GO**）→ 写 P2pInfo → **接收方入组** → 接收方连发送方 WS/TLS → 传输 → 状态回执。
- "发送方作 GO、接收方作 GC"是共同约定（各家一致）。

## 2. BLE 广播 / 扫描

- 协议服务 UUID `00003331-0000-1000-8000-008123456789`；主广播承载发送者 ID 与品牌/能力字节，
  扫描响应承载设备名（27 字节）。
- 发送方**不广播**（只扫描）；接收方广播且可连接。

## 3. GATT 凭据通道

服务 `00009955`：读特征 `00009954`（DeviceInfo）、写特征 `00009953`（P2pInfo）。

| 实现 | 特征属性 | 客户端写模式 | 服务端是否回应写请求 |
|---|---|---|---|
| 小米互传 | `READ\|WRITE` | `writeCharacteristic`（带响应） | 回应（`sendResponse` 状态 0，约 50ms） |
| 中兴互传 | `READ\|WRITE\|WRITE_NO_RESPONSE`（`0x0E`） | `writeCharacteristic`（带响应） | **不回应**（读请求回、写请求无 `sendResponse`） |
| CatShare / EasyShare | 读 `READ`、写 `WRITE` | 经 Nordic BLE 库 `write`（带响应） | 由接收端实现决定 |
| HandySend | `READ\|WRITE\|WRITE_NO_RESPONSE` | 见 §8（按对端能力选择写模式） | 读、写均回应 |

> **兼容性要点 1**：中兴的 GATT Server 对 `CHAR_P2P` 写请求**不调用 `sendResponse`**，因此
> **对中兴必须使用"无响应写"**；使用"带响应写"会一直等到超时（HandySend 实测 8s 超时）。
> 无响应写无法从本机确认送达，其"是否被处理"需由对端后续动作（反连 / 入组 / 回连 WS）判定。

## 4. DeviceInfo / P2pInfo 模型

| 实现 | DeviceInfo | P2pInfo |
|---|---|---|
| 小米互传 | `{mac, key, state, catShare?}` | `{id, mac, port, freq, G, M, P, ssid, psk, key}` |
| 中兴互传 | `{key, mac, state}` | `{freq, id, key, mac, port, psk, ssid}`（无 `catShare`/`G`/`M`/`P`） |
| CatShare | `{mac, key, state?, catShare?}` | `{id, ssid, psk, mac, port, key, catShare}`（无 `freq`/`G`/`M`/`P`） |
| EasyShare | 同 CatShare + 扩展 | 同 CatShare + `catShareCrypto`/`catShareToken`/`catShareCert` |
| HandySend | `{state, mac, key, catShare}` | `{id, ssid, psk, mac, port, freq, key, catShare, G, M, P}` |

- `id`：小米为设备标识（实测 4 字节级），中兴实测 16 字节，CatShare 为 2 字节发送者 ID。
- `freq`：群组频点（MHz）。**中兴解析后会用于 `setGroupOperatingFrequency`**（见 §6）。
- `G`/`M`/`P`：引导网络 / 主网络 / 协议类型；小米缺省 `1/1/2`。

## 5. 加密

- 统一：`ECDH P-256` 派生共享密钥，`AES` 加密 `ssid` / `psk` / `mac`，
  IV 取文本 `"0102030405060708"`（16 字节 ASCII，即十六进制 `3031…3038`）。
- 发送方在 P2pInfo 中携带自身公钥（`key`）；接收方用其公钥 + 自身私钥派生密钥解密。
- EasyShare 另有 `cryptoVersion` 变体（带字段名 AAD），与本机当前实现不同源。

## 6. 建组 / 入组（关键差异）

| 实现 | 发送方建组 | 接收方入组方式 |
|---|---|---|
| 小米互传 | `createGroup`（网络名 `DIRECT-x` + 口令，频段 AUTO / 2GHz） | **SSID + PSK 静默加入**（Android 9+）；入组后**校验群主地址 == `P2pInfo.mac`**，不符报 `unrecognized network owner` 并中止 |
| 中兴互传 | 需先 `setWifiP2pChannels` 选定信道，再 `createGroup` | **先 `discoverPeers`** → 在发现结果中匹配 `deviceAddress == P2pInfo.mac` → 命中后**SSID + PSK 静默加入**（并携带 `freq`）；**未命中**才退化为"设备地址驱动"`connect` |
| CatShare | `createGroup`（网络名 + 口令；2GHz / AUTO） | `connect`（网络名 + 口令，全 0 地址）静默加入 |
| EasyShare | 同上（另含 `requiresTwoGhzP2pCompatibility` 的 2.4GHz 名单） | 同上 |
| HandySend | `createGroup`（GO；5GHz 优先，失败回退 2.4GHz） | `p2pConnect`（全 0 地址 + SSID/PSK）静默加入 |

> **兼容性要点 2**：中兴接收端**依赖 P2P 主动发现**先"看见"发送方，且要求发现到的
> `deviceAddress` 等于 `P2pInfo.mac`，命中后才走 SSID+PSK 静默加入；未命中的退化路径（地址驱动协商）
> 更容易失败。因此对中兴：发送方 GO 必须**能被发现**（Android 默认发现的社交信道在 2.4GHz），
> 且 `P2pInfo.mac` 必须与对端**发现的设备地址**一致。
>
> 两端比对地址的**大小写策略不同**：小米用 `equalsIgnoreCase`（不敏感）；中兴用大小写敏感的 `equals`
> 与其发现阶段看到的（小写）地址严格比对，而本机 Native 以大写的 `{:02X}` 生成，导致中兴匹配不到
> `P2pInfo.mac` 而退化为地址驱动连接并失败。故本机`P2pInfo.mac` 对外统一归一为**小写**，同时满足两类接收端。

## 7. WS / HTTPS 应用层

- 端点：`/websocket`（信令）、`/download`（下载）、`/thumbnail`（预览图，接收方在下载前先取）。
- `sendRequest` 等待 ack 超时约 30s；状态回执 `action:100:status?{taskId,id,type,reason}`。

## 8. 对本机（HandySend）的结论

1. **写模式**：按对端写特征能力选择——对端声明支持无响应写即用无响应写，否则用带响应写。对中兴（不回写响应）
   必须"无响应写"，否则会超时；对小米/荣耀（回写响应）用带响应写。写回执不作为成功判据，无响应写场景以端到端
   信号（对端反连 / 入组 / 回连传输通道）判定。
2. **入组前置**：中兴要求**先被发现**（P2P discovery）再静默加入，且 `mac` 需与对端发现的地址一致；
   本机作 GO 时是否可被发现、以及 `mac` 取值，是中兴能否入组的关键。地址比对大小写策略不同（中兴严格
   相等 / 小米不敏感），本机 `P2pInfo.mac` 对外统一归一为小写以同时满足两者。**真机已确认**：改为小写后中兴在
   发现阶段匹配成功（中兴日志 `updatePeers mType=… mNeedConnnectGroup=…` → `find Group is ok` →
   `connnectGroup continue by ConnectiveState`）、入组并完成接收；中兴加入后其群主 `deviceAddress: 9a:b5:9b:eb:a7:15`、
   `frequency: 5180`，即本机 **小写** 的 p2p0 硬件地址（此前为大写，匹配失败、退化为地址驱动连接并失败）。
3. **频率**：本机 `P2pInfo.freq` 会被中兴用于 `setGroupOperatingFrequency`；建组频段与 `freq` 需自洽。
4. **预览图**：本机发送端未提供 `/thumbnail`，对端看不到本机发送的预览图。
5. **发送伴随 BLE 外设**：发送期间保持一个最小外设（广播 + GATT Server）供对端反连。真机证据显示中兴虽**反连**该
   外设但**未读未写**，其入组成败只与 `mac` 大小写相关，故**当前证据不支持「中兴依赖该外设」**；保留原因与隔离方式见实现文档 §1.9。
