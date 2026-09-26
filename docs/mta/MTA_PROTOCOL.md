# MTA（互传联盟）协议权威文档

> 本文件是仓库内「MTA 协议」主题的**唯一权威入口**：以小米（`com.miui.mishare.connectivity`）与中兴
> （`com.zte.cn.zteshare`）的反编译源码为主来源、公开第三方参考实现（CatShare / EasyShare /
> OPPOShareReceiver）为旁证、运行期观测为可复现观测，完整描述 MTA 从 BLE 发现、GATT 凭据交换、加密、
> WiFi Direct 建组/入组、WebSocket 协商到文件传输与状态回执的**收发双向**全链路，以及每一处数据格式
> 的逐字段/逐字节细节、各厂商与实现的行为差异及兼容应对。
> 每项协议事实标注出处与证据强度；出处约定与证据强度标签见「章 0」，来源获取方式见「章 11」，
> 全部来源的短键与定位方式见文末「可复核来源索引」。
> 平台能力真机实测见 [MTA_PLATFORM_VERIFICATION.md](MTA_PLATFORM_VERIFICATION.md)；
> ArkTS 侧应用编排见 [../architecture/mta.md](../architecture/mta.md)。

## 目录

- [0. 文档说明](#0-文档说明)
- [1. 角色与全链路时序](#1-角色与全链路时序)
- [2. BLE 发现层](#2-ble-发现层)
- [3. GATT 凭据通道](#3-gatt-凭据通道)
- [4. 数据模型（DeviceInfo / P2pInfo / G·M·P）](#4-数据模型deviceinfo--p2pinfo--gmp)
- [5. 加密与密钥协商](#5-加密与密钥协商)
- [6. WiFi Direct 建组与入组](#6-wifi-direct-建组与入组)
- [7. WebSocket 应用层](#7-websocket-应用层)
- [8. 文件传输（HTTP / ZIP / 缩略图）](#8-文件传输http--zip--缩略图)
- [9. 品牌与设备身份](#9-品牌与设备身份)
- [10. 跨厂商差异与兼容应对](#10-跨厂商差异与兼容应对)
- [11. 取证与复现](#11-取证与复现)
- [12. 证据强度与未解项](#12-证据强度与未解项)
- [附录 A：本项目实现映射](#附录-a本项目实现映射)
- [附录 B：常量与字段速查](#附录-b常量与字段速查)
- [附录 C：第三方参考实现索引](#附录-c第三方参考实现索引)
- [可复核来源索引](#可复核来源索引)

---

## 0. 文档说明

### 0.1 定位与读者

本文件面向「从零实现一套可与厂商设备互通的 MTA 端点」或「定位跨厂商互通故障」的读者。它以协议为
主体，按「发现 → 凭据 → 加密 → 组网 → 应用层 → 传输 → 收尾」的链路顺序组织，尽量自包含：

- 每个环节**同时**给出发送方与接收方的行为（收发双向）。
- 每处数据格式给出字段含义、类型/取值、缺省与可选性（逐字段/逐字节）。
- 每项协议事实内联标注出处与证据强度，出处均可由他人独立复核。

工程侧编排（ArkTS/Rust 落点）不在主体内展开，收敛为「附录 A」的精简索引，细粒度实现指向
[../architecture/mta.md](../architecture/mta.md) 等架构文档。

### 0.2 术语表

| 术语 | 含义 |
|---|---|
| MTA | 互传联盟（Mobile Transfer Alliance）局域网互传协议族 |
| 发送方 / 接收方 | 发起传输的一端 / 接受传输的一端；发送方作 WiFi Direct GO，接收方作 GC |
| GO / GC | Group Owner（群主）/ Group Client（群客户端） |
| 主广播 | BLE 可连接广播包，承载发送者 ID 与品牌/能力字节 |
| 扫描响应 | 主动扫描时回送的 BLE 包，承载设备名（27 字节） |
| DeviceInfo | GATT 读特征返回的接收方信息 JSON |
| P2pInfo | GATT 写特征写入的组网凭据 JSON |
| G / M / P | ConnectionConfig 的引导网络 / 主网络 / 协议类型 |
| 帧 | WebSocket 文本报文，文法 `type:id:name?payload` |
| entry | ZIP 归档中的一个条目 |

### 0.3 来源分层

1. **主来源**：厂商反编译源码——小米 `com.miui.mishare.connectivity`（类名混淆为单字母）、
   中兴 `com.zte.cn.zteshare`（可读）。协议结论以厂商源码为准，锚点为「包名 + 类/成员/字符串常量」。
2. **旁证**：公开第三方参考实现——CatShare（`moe.reimu.catshare`）、EasyShare（`me.pipi.easyshare`）、
   OPPOShareReceiver（`com.mta.receiver`）。三者一律标注为「第三方参考实现（非厂商）」，锚点为
   「项目名 + 项目内相对路径」。
3. **运行期观测**：真机日志因机器而异，转述为**可复现观测**（进程名/日志标签 + 报文模式），不作为
   出处锚点，证据强度标 `[观测]`。
4. **交叉校验**：仓库既有 `docs/mta/*.md` 与 `docs/architecture/*.md`，用于发现遗漏与比对口径，
   不作最终出处。

小米侧类名被混淆为单字母，部分字符串常量在反编译产物中被替换为占位符；因此小米出处以「包内类路径 +
可读字符串常量（UUID、JSON 字段名）或方法名」定位；凡只能定位到占位符处，辅以日志标签或第三方源码
交叉佐证，并按证据强度降级标注。

### 0.4 证据强度标签

| 标签 | 含义 | 判定标准 |
|---|---|---|
| `[已取证]` | 公开源码可定位 | 能在厂商包名+类/常量，或第三方项目名+相对路径中定位 |
| `[观测]` | 可复现观测可证 | 给出进程名/日志标签 + 报文模式，读者可在同类设备复现 |
| `[推断]` | 无直接证据 | 仅由既有文档或间接线索推出，须同时说明依据 |

### 0.5 内联出处标注格式约定

出处只允许以下三类公开可复核锚点；正文段落用完整形式（含包名/项目名），表格内可用短键，短键在文末
「可复核来源索引」展开：

- 厂商（小米）：`（小米 `com.miui.mishare.connectivity` `a/c.java`#常量 `00003331…`）`；
  短键 `小米 a/c.java`。
- 厂商（中兴）：`（中兴 `com.zte.cn.zteshare` `ble/BleAdvertiserService.java`#成员 `PROTOCAL_UUID`）`；
  短键 `中兴 BleAdvertiserService.java`。
- 第三方：`（CatShare `moe.reimu.catshare`，`utils/BleUtils.kt`）`；EasyShare / OPPOShareReceiver 同理。
- 运行期观测：`（可复现观测：<进程名或日志标签> 出现 `<报文模式>`）`。

**禁止**以机器本地临时/绝对路径、本机日志文件名或日志行号、反编译产物的绝对路径作为出处。
厂商锚点以「类 + 成员名/字符串常量」定位，**不以行号**定位。一行为多来源时并列书写；多个事实共享同一
出处时，可在段末统一标注。

## 1. 角色与全链路时序

### 1.1 角色定义

MTA 是「一端广播待接入、另一端发现后主动建链」的 C/S 结构，且**发送方作 GO、接收方作 GC** 是两家
共同约定（中兴 `com.zte.cn.zteshare` `ble/BleAdvertiserService.java`（广播 + GATT 服务端）与
`wifi/WifiP2pCtrl.java`#成员 `createGroup`（发送方建组）[已取证]；小米
`com.miui.mishare.connectivity` `a/b/a.java`（GATT 服务端）与 `g/b.java`#方法 `b`（建组）[已取证]）。

| 角色 | 职责 |
|---|---|
| 接收方（GC） | BLE 广播（主广播 + 扫描响应）、提供 GATT 服务端、提供 DeviceInfo；收 P2pInfo 后入组、连发送方 WS/HTTPS、下载、回 status |
| 发送方（GO） | BLE 扫描、连接接收方 GATT 服务端、读 DeviceInfo、建组、写 P2pInfo、起 WS/HTTPS 服务、发 versionNegotiation/sendRequest、供 /download、收 status |

> 接收方**不主动扫描**、发送方**不广播**（中兴 `ble/BleScannerService.java` 仅发送侧启动扫描；
> 小米扫描侧按协议 service UUID 过滤 [推断]（依据：第三方参考实现同口径，且小米源码字符串被混淆无法
> 直读））。发送方在发送期间可另保持一个伴随 BLE 外设以支持部分对端反连（见「章 10」）。

### 1.2 端到端时序（收发双向）

```text
接收方（GC / 待接入）                              发送方（GO / 主动发起）
  │ ① BLE 启动：                                    │
  │   主广播：serviceUuid 00003331 + serviceData    │
  │     品牌/能力字节(6B)                            │
  │   扫描响应：serviceData(27B: 设备名 + 设备 ID)   │
  │ ② startAdvertising（可连接、可扫描）             │
  │                                                  │ ③ BLE 扫描（ScanFilter 00003331）
  │                                                  │    解析扫描响应 → 名称/5GHz/品牌
  │                                                  │ ④ 用户选中目标 → 起 HTTPS+WS 服务
  │ ⑤ GATT 连接 → 读 CHAR_STATUS ←──────────────────│    读 DeviceInfo{state,mac,key}
  │    （服务端返回 DeviceInfo，含 ECDH 公钥）        │
  │                                                  │ ⑥ ECDH 派生密钥 → AES-CTR 加密
  │                                                  │    仅 ssid/psk/mac
  │ ⑦ GATT 写 CHAR_P2P ←────────────────────────────│    写 P2pInfo{ssid,psk,mac,port,freq,key,G,M,P}
  │    （解密 ssid/psk/mac；触发入组）                │    并发起 createGroup（GO）
  │ ⑧ 入组（SSID+PSK 静默加入 / 发现驱动）           │    GO IP 192.168.49.1:port
  │ ⑨ 连 wss://192.168.49.1:port/websocket ─────────→│
  │    ← action:0:versionNegotiation?{"versions":[1],"version":1}
  │    → ack:0:versionNegotiation?{"version":1,"threadLimit":5}
  │    ← action:1:sendRequest?{file,taskId/id,...}
  │    → ack:1:sendRequest
  │ ⑩ 用户确认接收（超时 → status type=3）            │
  │ ⑪ GET https://192.168.49.1:port/download?taskId= →│  流式 ZIP（chunked）
  │    边下载边解压落盘                                │
  │ ⑫ → action:100:status?{"taskId":..,"id":..,"type":1,"reason":"ok"}
  │ ⑬ 断开、拆组、停服                               │
```

- 步骤 ③～⑦（GATT 凭据通道）[已取证]：中兴 `ble/BleGattService.java`（客户端）与
  `ble/BleAdvertiserService.java`（服务端）；小米 `a/a/g.java`（客户端）与 `a/b/a.java`（服务端）。
- 步骤 ⑨～⑫（WS/HTTP）[已取证]：中兴 `web/NanoWebsocket.java`#成员 `onOpen`、`web/WSclient.java`、
  `web/NanoServer.java`#成员 `serve`；小米 `e/f.java`、`e/c.java`。
- 步骤 ⑫ 状态帧形如 `action:100:status?{"taskId":…,"id":…,"type":1,"reason":"ok"}` [观测]
  （可复现观测：中兴进程 `com.zte.cn.zteshare` 日志出现该报文模式）。接收端帧号并非固定值，另见
  §7.3。

### 1.3 发/收双方逐步动作对照

| 步骤 | 发送方（GO） | 接收方（GC） |
|---|---|---|
| 发现 | 扫描（serviceUuid 过滤）+ 解析扫描响应 | 广播主广播 + 扫描响应，开 GATT 服务端 |
| 凭据 | 连 GATT → 读 DeviceInfo → 写 P2pInfo | 应读请求回 DeviceInfo；收 P2pInfo 后解密 |
| 加密 | 生成一次性 ECDH 密钥对，用对端公钥派生密钥 | 生成一次性 ECDH 密钥对，公钥随 DeviceInfo 下发 |
| 组网 | `createGroup` 作 GO | SSID+PSK 静默加入 / 主动发现后加入 |
| 应用层 | 起 WSS+HTTPS，发 versionNegotiation | 连 WSS，回 ack，收 sendRequest，回 ack |
| 传输 | 流式生成 ZIP 写响应体 | GET /download 流式解压落盘 |
| 收尾 | 收 status 后以连接终止结束会话（不发关闭帧）再延迟拆组停服 | 回 status（type/reason） |

各步骤的字段级细节与厂商差异分别见「章 2～10」；「章 10」汇总差异与应对。

> **收尾阶段的会话终止**（本项目发送方，交叉校验）[推断]：主动结束会话时**不发送 WebSocket 关闭帧**，
> 而是在确保结束类指示（结果回执 / 取消状态）已被对端读取后，以**连接终止**结束会话（释放传输连接）；
> 成功路径仅在收到对端 `status` 并回送确认之后才终止。目标对端（小米使用的 OkHttp WebSocket 客户端）
> 的「关闭完成」回调**仅在客户端自身发起关闭时**触发，且**收到服务端关闭帧后即停止读取**——故服务端
> 发关闭帧只会触发其空实现的「关闭中」回调，对端自身收尾（解除忙态）永不执行；直接终止连接使对端
> 进入其可处理的「连接失败终止」路径并完成自身收尾。

## 2. BLE 发现层

约定 UUID（两家一致）[已取证]：

| 名称 | UUID | 出处（短键） |
|---|---|---|
| 协议 service UUID（主广播） | `00003331-0000-1000-8000-008123456789` | 小米 a/c.java；中兴 BleAdvertiserService.java |
| GATT 服务 UUID | `00009955-0000-1000-8000-00805f9b34fb` | 小米 a/c.java；中兴 BleAdvertiserService.java |
| CHAR_STATUS（读） | `00009954-0000-1000-8000-00805f9b34fb` | 小米 a/c.java；中兴 BleAdvertiserService.java |
| CHAR_P2P（写） | `00009953-0000-1000-8000-00805f9b34fb` | 小米 a/c.java；中兴 BleAdvertiserService.java |

出处细目 [已取证]：小米 `com.miui.mishare.connectivity` `a/c.java`#常量
`00003331-0000-1000-8000-008123456789` 等（该类的静态 UUID 字段）；中兴
`com.zte.cn.zteshare` `ble/BleAdvertiserService.java`#成员 `PROTOCAL_UUID`、服务与特征 UUID。
第三方同口径：CatShare `moe.reimu.catshare` `utils/BleUtils.kt`（`ADV_SERVICE_UUID` / `SERVICE_UUID` /
`CHAR_STATUS_UUID` / `CHAR_P2P_UUID`）、OPPOShareReceiver `com.mta.receiver`
`constants/MtaConstants.kt`。

主广播 service UUID 使用**非标准蓝牙基址**（后缀 `008123456789`，非 `00805f9b34fb`），扫描端按该 UUID
过滤 [已取证]（小米 `a/c.java`；中兴 `ble/BleScannerService.java`#成员 `setServiceUuid`）。

### 2.1 主广播（可连接广播包）

主广播承载发送者 ID 与品牌/能力字节，不含设备名（避免超 31 字节）。两家的 serviceData UUID 均由「品牌/
能力字节 + 机型/能力字节」动态拼出，而非固定值：

| 实现 | serviceData UUID 构造 | 值（字节） |
|---|---|---|
| 小米 | `0000<设备类型><品牌码>-…-00805f9b34fb`（`a/c.java`#方法 `a(Context)`，格式参数顺序 `(deviceType, manufactureCode)`） | 设备 ID 前 6 字节 `Arrays.copyOfRange(t.a(),0,6)` |
| 中兴 | `R.string.service_data_uuid`，把第 5 位字符替换为「本机能力」十进制字符（bit0=支持 5GHz、bit1=BLE 需加密） | 设备 ID（hex 解码）前 6 字节 |

- 小米 [已取证]：`a/c.java`#常量（协议 UUID）、方法 `a(Context)` / `a(byte,byte)`；设备类型由 `c(context)`
  给出（手机 = `1`），品牌码由 `c.a()` 按 `Build.DEVICE` 映射（`c.java`）。
- 中兴 [已取证]：`ble/BleAdvertiserService.java`#方法 `startBleAdvertising`、`chooseWifiBand()`。
- 广播参数 [已取证]：中兴 `setAdvertiseMode(2)`（LOW_LATENCY）、`setTxPowerLevel(3)`（HIGH）、
  `setConnectable(true)`、`setTimeout(0)`（`ble/BleAdvertiserService.java`#方法 `startBleAdvertising`）；
  小米使用 `AdvertisingSet`（扩展广播路径，`a/b/a.java`）。
- 第三方旁证 [已取证]：CatShare `services/GattServerService.kt` 与 OPPOShareReceiver
  `ble/BleServerManager.kt` 主广播 serviceData UUID 均取固定 `000001ff-…`、值 6 字节（前 2 字节随机、
  其余补 0）。
- **本项目发送**（交叉校验）：设备 ID 为 16 字节，**首次生成后持久化（跨会话稳定），对齐厂商**
  （真机实测小米设备 ID 稳定、第三方 EasyShare 不稳定，稳定性属厂商实现选择）；主广播值 6 字节 =
  设备 ID 前 6 字节，扫描响应值 `[0..10)` = 设备 ID 尾段（对齐本节与 §2.2 的厂商拼接还原口径），
  细粒度实现见 [../architecture/mta.md](../architecture/mta.md)。

### 2.2 扫描响应（主动扫描回送的 27 字节包）

27 字节值布局：

| 偏移 | 小米 | 中兴 |
|---|---|---|
| `[0..8)` | 8×`00` | 设备 ID `[6..16)`（10 字节） |
| `[8..10)` | 设备 ID 前 2 字节 | （并入上段） |
| `[10..26)` | 设备名 16 字节 | 设备名 16 字节（`Utils.getOwnerInfo`） |
| `[26]` | `0x01` | `0x01` |

- 小米 [已取证]：`a/c.java`#方法 `b(Context)`；扫描响应的 serviceData UUID 由 `c.b()` 机型码按
  `a((byte)(iB>>>8),(byte)(iB&255))` 拼出（字符串内低字节在前）。
- 中兴 [已取证]：`ble/BleAdvertiserService.java`#方法 `startBleAdvertising`；serviceData UUID 固定
  `00000034-0000-1000-8000-00805f9b34fb`（`ZTE_UUID2`）。
- 第三方旁证 [已取证]：CatShare `services/GattServerService.kt` 与 OPPOShareReceiver
  `ble/BleServerManager.kt` 扫描响应 serviceData UUID 均取 `0000ffff-…`，值布局同上（8×`00` + 2 字节
  发送者 ID + 16 字节名称 + `0x01`）。

> 扫描响应的 serviceData UUID 并非固定：小米用机型码，荣耀用 `00000000`，中兴用 `00000034`，
> 第三方用 `0000ffff`。因此**扫描端按 serviceData 值的字节长度（27B = 扫描响应、6B = 主广播）分类，
> 而非按 UUID 匹配** [已取证]（小米 `a/a/i.java` 只读固定偏移；中兴 `ble/BleScannerService.java`#方法
> `addDevice` 只看 `bytes`）。

### 2.3 扫描端解析口径

小米 `a/a/i.java`#方法 `a(ScanResult)` 直接读取**合并扫描记录的固定字节偏移** [已取证]：

| 偏移 | 含义 |
|---|---|
| `23` | 品牌/厂商码（`bytes[23]`） |
| `24` bit0 | 是否支持 5GHz（`(bytes[24] & 1) != 0`） |
| `25..31)` + `35..45)` | 设备 ID（`25..31)` 与 `35..45)` 拼接为 16 字节，`ByteBuffer` 读两个 long） |
| `33,34` | 机型码（`(bytes[33] << 8) \| bytes[34]`） |
| `45..61)` | 设备名 16 字节 |
| `61` | 末字节标记（`bytes[61]`） |

中兴 `ble/BleScannerService.java`#方法 `addDevice` 使用同一组偏移 [已取证]：

| 字段 | 取值 |
|---|---|
| `flag` | `bytes[24]`（5GHz 能力位） |
| `deviceId` | `bytes[25..31)` + `bytes[35..45)`（`ScannedDevice.setDeviceId` 合并） |
| `manufacturerId` | `bytes[23]` |

- 设备 ID（发送者 ID）按**无符号**解析；发送者 ID 形如 `ecaab0036a324520832d3ff5130c7d4c`（16 字节 hex）
  [观测]（可复现观测：中兴进程 `com.zte.cn.zteshare` 日志出现该 32 位 hex 串）。
- 名称区规则 [已取证]：小米 `a/c.java`#方法 `b(Context)`、中兴 `Utils.java`#方法 `getOwnerInfo`；
  解码端小米 `a/a/i.java`、中兴 `Utils.java`#方法 `getDeviceName`。
  - ≤16 字节：原样放入并右侧补 `0x00`；
  - >16 字节：截到 15 字节并在末位写 `\t`（`0x09`）作截断标记；中兴按 UTF-8 码点回退避免截断多字节字符
    （`Utils.java`#方法 `findEmojiOfString`），小米按字节截断后再回退到合法前缀。
  - 解码：以首个 `0x00` 终止；末位为 `\t` 时置「已截断」标记。
  - 第三方旁证 [已取证]：CatShare `services/GattServerService.kt` 与 OPPOShareReceiver
    `ble/BleServerManager.kt` 用「UTF-8 字节 >15 则截到字符边界并追加 `\t`」的等价规则。

### 2.4 广告字节契约（C-1）小结

| 载体 | 关键内容 | 出处（短键） |
|---|---|---|
| 主广播 | serviceUuid `00003331…`；serviceData UUID 含品牌/能力字节；值 = 设备 ID 前 6 字节 | 小米 a/c.java；中兴 BleAdvertiserService.java |
| 扫描响应 | 27 字节；serviceData UUID 随实现；值 = 设备 ID 尾段 + 名称 16B + `0x01` | 小米 a/c.java；中兴 BleAdvertiserService.java |
| 解析 | 按值长度分类（27B/6B）；品牌 `bytes[23]`；5GHz `bytes[24]` bit0；名称 `[45..61)` | 小米 a/a/i.java；中兴 BleScannerService.java |

第三方对照：CatShare `utils/BleUtils.kt`、`services/GattServerService.kt`；OPPOShareReceiver
`constants/MtaConstants.kt`、`ble/BleServerManager.kt`。

---

## 3. GATT 凭据通道

### 3.1 服务与特征属性

| 实现 | 服务 | CHAR_STATUS（读） | CHAR_P2P（写） |
|---|---|---|---|
| 小米 | `00009955` | properties `10`=`READ\|WRITE`，permissions `17`=`READ\|WRITE` | properties `10`，permissions `17` |
| 中兴 | `00009955` | properties `14`=`READ\|WRITE\|WRITE_NO_RESPONSE`，permissions `17` | properties `14`，permissions `17` |
| 第三方（CatShare） | `00009955` | properties `10`，permissions `17` | properties `10`，permissions `17` |
| 第三方（OPPOShareReceiver） | `00009955` | properties `READ`，permissions `READ` | properties `WRITE`，permissions `WRITE` |

- 小米 [已取证]：`a/b/a.java`（`new BluetoothGattCharacteristic(c.<UUID 常量>, 10, 17)` 两处）。
- 中兴 [已取证]：`ble/BleAdvertiserService.java`#成员（`new BluetoothGattCharacteristic(…, 14, 17)`）。
- 第三方 [已取证]：CatShare `services/GattServerService.kt`#方法 `buildGattService`；OPPOShareReceiver
  `ble/BleServerManager.kt`#方法 `startGattServer`。
- 结论：**小米不声明无响应写，中兴声明无响应写**（`14` 含 `0x04`）。

### 3.2 服务端读写行为

**小米服务端**（`a/b/a.java`#方法 `onCharacteristicReadRequest` / `onCharacteristicWriteRequest`）
[已取证]：

- 读 `CHAR_STATUS`：以 `d.o.a()` 作为值回送 DeviceInfo JSON；若本地状态尚未就绪，`g.a().b()` 后最多
  等待 4000ms。
- 写 `CHAR_P2P`：按 `offset` **累积**分片（实例字段）；`isPrepared` 为假、或收到 `onExecuteWrite(true)`
  时调用私有方法 `a()` 完成落库——会用 `P2pInfo.key` 解密 `ssid`/`psk`/`mac` 并交协调器入组。
- 回响应：写请求 `responseNeeded` 为真时回 `sendResponse(…, 0, 0, bArr)`；对**未知特征**的写请求
  `responseNeeded` 为真时回错误码 `257`（`0x0101`，请求不支持）。

**中兴服务端**（`ble/BleAdvertiserService.java`#方法 `onCharacteristicReadRequest` /
`onCharacteristicWriteRequest`）[已取证]：

- 读 `00009954`：`sendResponse(bluetoothDevice, i, 0, i2,
  Utils.objToJsonString(bleRecevierInfo).getBytes(UTF-8))`——**对读请求明确回响应**。
- 写 `00009953`：解析 `BleSenderInfo`；`key` 非空则 `Utils.getSecretKey` 派生密钥并 `Utils.decrypt`
  `ssid`/`psk`/`mac`；随后 `connnectGroup()`。**不调用 `sendResponse`**——写请求无写响应。
- 前置拒绝：本地开热点（`isWifiApOpen`）或已开 P2P（`isWifiP2pOpen`）时直接失败。

**第三方服务端** [已取证]：CatShare `services/GattServerService.kt`#方法
`onCharacteristicWriteRequest`（prepared write 按 offset 累积、写未知特征回 `257`、`responseNeeded`
为真回成功）；OPPOShareReceiver `ble/BleServerManager.kt`#方法 `onCharacteristicWriteRequest`
（不处理 prepared write，直接解析）。

### 3.3 客户端读写行为

- 小米客户端（`a/a/g.java`）[已取证]：`connect` → `requestMtu(512)` → `discoverServices` →
  读 `CHAR_STATUS`（校验 `properties & 2`，`readCharacteristic`）→ 写 `CHAR_P2P`
  （校验 `properties & 8`，`writeCharacteristic` 默认**带响应写**，等待 `onCharacteristicWrite` 回调）。
- 中兴客户端（`ble/BleGattService.java`）[已取证]：连接后 `requestMtu(512)`，
  `onMtuChanged` 成功即 `discoverServices`；发现 `00009955` 服务后按 `00009954`（读）、
  `00009953`（写）分配特征；读到 DeviceInfo 后 `writeCharacteristic` 回写 P2pInfo。
- 两家写模式均为 **ATT Write Request（带响应写）** [已取证]；中兴服务端不回写响应 ⇒ 对中兴用带响应写会
  等到超时 [观测]（可复现观测：中兴进程 `com.zte.cn.zteshare` 日志在收到写请求后不出现写响应记录；
  应对见「章 10」）。

### 3.4 GATT 契约（C-2）小结

| 项 | 值 | 出处（短键） |
|---|---|---|
| 服务 / 读 / 写 UUID | `00009955` / `00009954` / `00009953` | 小米 a/c.java；中兴 BleAdvertiserService.java |
| 小米属性 | `READ\|WRITE`（`10`），权限 `READ\|WRITE`（`17`） | 小米 a/b/a.java |
| 中兴属性 | `READ\|WRITE\|WRITE_NO_RESPONSE`（`14`），权限 `17` | 中兴 BleAdvertiserService.java |
| 读方向 | 客户端读 CHAR_STATUS，服务端回 DeviceInfo | 小米 a/b/a.java；中兴 BleAdvertiserService.java |
| 写方向 | 客户端写 CHAR_P2P，服务端解析并解密 | 小米 a/b/a.java；中兴 BleAdvertiserService.java |
| prepared write | 按 `offset` 累积，`executeWrite(true)` 落库 | 小米 a/b/a.java |
| MTU | `requestMtu(512)` | 小米 a/a/g.java；中兴 BleGattService.java |

第三方对照：CatShare `services/GattServerService.kt`；OPPOShareReceiver `ble/BleServerManager.kt`。

---

## 4. 数据模型（DeviceInfo / P2pInfo / G·M·P）

### 4.1 DeviceInfo（CHAR_STATUS 读返回）

小米侧模型类 `d`（`DeviceStatus`，`d.java`）[已取证]：

| 字段 | 含义 | 类型 | 缺省 / 序列化条件 |
|---|---|---|---|
| `state` | 对端状态（0 = 就绪） | int | 总是写出；`0` = 就绪 |
| `mac` | 蓝牙/设备地址 | string | 仅 `state == 0` 且非空时写出；读入时 `toLowerCase()` |
| `reason` | 忙原因码 | int | 仅 `state == 1` 时写出 |
| `key` | 接收方 ECDH 公钥（Base64） | string | 非空时写出；缺省取 `a/c/b.c()`（GC 公钥） |

字段名锚点 [已取证]：小米 `mac` 字段在源码中经混淆常量
`com.xiaomi.onetrack.api.b.B` 引用，其字符串值为 `"mac"`；`state`/`reason`/`key` 为可读字面量
（同上 `d.java`）。

中兴侧模型类 `BleRecevierInfo`（`ble/BleRecevierInfo.java`，Gson 序列化）[已取证]：

| 字段 | 含义 | 缺省 / 条件 |
|---|---|---|
| `state` | 对端状态（固定 `0`，`getBleRecevierInfo`） | 总是写出 |
| `mac` | `Utils.getMacAddr()`（`/sys/class/net/p2p0/address`，失败兜底 `02:00:00:00:00:00`） | 总是写出 |
| `key` | 服务端 ECDH 公钥（Base64） | 仅 `needEncryptBle()` 且 `initKey` 成功时写出 |

- 中兴 `state=1` 的忙原因语义未在本实现中给出（接收端固定回 `0`）[推断]；`reason` 码表见既有文档
  交叉校验。
- `catShare` 字段**未在厂商（小米 `d.java`、中兴 `BleRecevierInfo.java`）DeviceInfo 模型中出现**，
  它属第三方参考实现的扩展 [已取证]：CatShare `models/DeviceInfo.kt`（`@SerialName("catShare")`，
  取 `BuildConfig.VERSION_CODE`）、EasyShare `models/DeviceInfo.kt`（另有 `catShareCrypto`）、
  OPPOShareReceiver `model/MtaModels.kt`#方法 `toJson`（字段 `catShare`，`ble/BleServerManager.kt`
  置 `catshare = 16`）。取值随实现，非厂商协议基线。

### 4.2 P2pInfo（CHAR_P2P 写）

小米侧模型类 `m`（`m.java`）`h()` 序列化 / `a(byte[])` 解析 [已取证]：

| 字段 | 含义 | 类型 | 序列化条件 | 解析缺省 |
|---|---|---|---|---|
| `id` | 发送者/任务 ID | string | 非空才写 | — |
| `mac` | 设备地址 | string | 非空才写；构造时 `toLowerCase()` | — |
| `port` | 服务端口 | int | 非 0 才写 | 0 |
| `freq` | 群组频点（MHz） | int | 非 0 才写 | 0 |
| `G` | 引导网络类型 | int | 非 0 才写 | 1 |
| `M` | 主网络类型 | int | 非 0 才写 | 1 |
| `P` | 协议类型 | int | 非 0 才写 | 2 |
| `ssid` | 群组名（可加密） | string | 非空才写 | — |
| `psk` | 群组口令（可加密） | string | 非空才写 | — |
| `key` | 公钥（触发加解密） | string | 非空才写 | 不解析则无 |

（`mac` 字段同样经混淆常量 `com.xiaomi.onetrack.api.b.B = "mac"` 引用 [已取证]。）

中兴侧模型类 `BleSenderInfo`（`ble/BleSenderInfo.java`）[已取证]：`id`、`mac`、`port`、`freq`、
`ssid`、`psk`、`key`，**无 `G`/`M`/`P`/`catShare`**。

第三方对照 [已取证]：

- CatShare `models/P2pInfo.kt`：`id`/`ssid`/`psk`/`mac`/`port`/`key`/`catShare`（**无** `freq`/`G`/`M`/`P`）。
- OPPOShareReceiver `model/MtaModels.kt`：`ssid`/`psk`/`mac`/`port`/`id`/`key`/`catShare`
  （**无** `freq`/`G`/`M`/`P`）。
- EasyShare `models/P2pInfo.kt`：CatShare 字段 + `catShareCrypto`/`catShareToken`/`catShareCert`。

- 加密对象：仅 `ssid`/`psk`/`mac`；`id`/`port`/`freq`/`key` 明文；`key` 存在即触发解密，缺失按明文
  [已取证]（中兴 `ble/BleAdvertiserService.java`#方法 `onCharacteristicWriteRequest`；小米
  `a/c.java`#方法 `a(m,String)` / `b(m,String)`）。
- **地址大小写**：小米 `m` 构造对 `mac` 调 `toLowerCase()`（`m.java`）[已取证]；中兴发送方
  `localBleSenderInfo.mac` 取自 `Utils.getMacAddr()`（`/sys/class/net/p2p0/address`，本身小写）
  [已取证]。
- 第三方同口径 [已取证]：CatShare `services/GattServerService.kt` 收 P2pInfo 后对
  `ssid`/`psk`/`mac` 解密、`catShare` 覆写为版本码；OPPOShareReceiver `ble/BleServerManager.kt`#
  方法 `handleP2pWrite` 同（并容忍 JSON 前导字节）。
- P2pInfo 样例 [观测]（可复现观测：中兴进程 `com.zte.cn.zteshare` 日志出现形如
  `BleSenderInfo{id='ecaab0…', mac='47fSTJhQnUVkiusoB12tTho=', port=52897, freq=5220,
  ssid='kJ+6b+M+…', psk='haKcG9QNvBg=', key='MFkwEwYHKoZIzj0C…'}` 的报文；
  `mac`/`ssid`/`psk` 为 Base64 密文）。

### 4.3 ConnectionConfig（G / M / P）

小米 `com.miui.mishare.ConnectionConfig` 常量 [已取证]：

| 字段 | 取值 | 语义 |
|---|---|---|
| `G` GuidingNetworkType | `1` = GATT；`2` = BLE 直连广播 | 引导网络类型（缺省 1） |
| `M` MainNetworkType | `1` = WiFi P2P；`2` = WiFi AP | 主网络类型（缺省 1） |
| `P` ProtocolType | `2` = MIOV HTTP；`3` = MI PC HTTP | 协议类型（缺省 2） |

来源：`ConnectionConfig.java`（常量 `GUIDING_NETWORK_TYPE_GATT=1` 等）；手机对手机缺省 `G=1/M=1/P=2`。

---

## 5. 加密与密钥协商

| 项 | 值 | 出处（短键） |
|---|---|---|
| 曲线 | ECDH P-256（`KeyPairGenerator "EC"` + `initialize(256)`） | 小米 a/c/b.java；中兴 Utils.java |
| 公钥编码 | X.509 SubjectPublicKeyInfo DER → Base64 | 小米 a/c/b.java；中兴 Utils.java |
| 共享密钥 | `KeyAgreement "ECDH"`，`generateSecret("TlsPremasterSecret")` | 小米 a/c/b.java；中兴 Utils.java |
| AES 模式 | `AES/CTR/NoPadding` | 小米 a/c/b.java；中兴 Utils.java |
| AES IV | `"0102030405060708"`（16 字节 ASCII，即十六进制 `3031…3038`） | 小米 a/c/b.java；中兴 Utils.java |
| 加密对象 | 仅 P2pInfo 的 `ssid`/`psk`/`mac` | 小米 a/c.java；中兴 BleGattService.java |
| 密钥对生命周期 | 每次会话重新生成（接收方 `key` 随 DeviceInfo 下发，发送方 `key` 随 P2pInfo 下发） | 中兴 BleAdvertiserService.java；小米 d.java |

- **共享密钥派生**：小米与中兴均调用 `generateSecret("TlsPremasterSecret")` 并取 `getEncoded()`（32 字节）
  [已取证]（小米 `a/c/b.java`；中兴 `Utils.java`#方法 `getSecretKey`）。第三方 OPPOShareReceiver 使用裸
  `generateSecret()`（`crypto/CryptoProvider.kt`#方法 `deriveSessionCipher`）[已取证]；对 P-256 ECDH
  两者均返回 32 字节原始共享密钥。
- 固定 IV + 无 KDF 是 MTA 既有设计，为兼容须照此实现；该加密仅保护经 BLE 通道传输的 WiFi 凭据，
  文件数据依赖 TLS（自签名证书、对端信任所有证书）[已取证]（中兴 `web/WebService.java`#方法
  `makeSecure` / `getClientSSlContext()`；第三方 OPPOShareReceiver `transfer/TransferManager.kt`#
  方法 `createNetworkBoundClient` 信任所有证书与主机名）。
- 密钥协商方向 [已取证]：接收方在 DeviceInfo 中下发**群客户端（GC）**公钥 `a/c/b.c()`；发送方用其派生
  密钥加密 P2pInfo；接收方用 `P2pInfo.key`（发送方公钥）解密（中兴
  `ble/BleAdvertiserService.java`#方法 `onCharacteristicWriteRequest`）。
- 第三方旁证 [已取证]：CatShare `BleSecurity.kt`（`deriveSessionKey`，曲线/公钥编码/AES/IV 与厂商一致）；
  EasyShare `SessionSecurity.kt`（可选证书 SHA-256 校验与令牌，属其扩展，非厂商基线）。

### 5.1 加密契约（C-5）小结

1. 双方各自生成一次性 P-256 密钥对；公钥以 SPKI DER + Base64 交换。
2. 共享密钥 = ECDH(P-256)，`generateSecret("TlsPremasterSecret").getEncoded()`（32 字节）。
3. `ssid`/`psk`/`mac` 各以 `AES/CTR/NoPadding` + 固定 16 字节 IV `0102030405060708` 加密后 Base64。
4. `key` 存在即解密；`key` 缺失按明文处理（兼容旧端与第三方）。

---

## 6. WiFi Direct 建组与入组

### 6.1 组形态

| 项 | 值 | 出处（短键） |
|---|---|---|
| GO IP | `192.168.49.1` | 可复现观测（小米进程日志）；[MTA_PLATFORM_VERIFICATION.md] |
| SSID | `DIRECT-<字符>`；小米校验 `^DIRECT-[a-zA-Z0-9]{2}.*` | 小米 g/b.java |
| PSK | 8 位随机字符（Android WiFi Direct 约定） | [MTA_PLATFORM_VERIFICATION.md] §4.1 |
| 持久化 | `enablePersistentMode(false)` | 小米 g/b.java；中兴 WifiP2pCtrl.java（未显式设置） |
| 角色 | 发送方 GO、接收方 GC | 小米 g/b.java；中兴 WifiP2pCtrl.java |

GO IP 出处 [观测]：可复现观测：小米进程 `com.miui.mishare.connectivity` 日志出现
`https://192.168.49.1:<port>/download…`；第三方 OPPOShareReceiver `constants/MtaConstants.kt`
（`DEFAULT_P2P_HOST = "192.168.49.1"`）同口径 [已取证]。

### 6.2 发送方建组

- **中兴**（`wifi/WifiP2pCtrl.java`）[已取证]：`createGroupWith5GBand()` 先 `setWifiP2pChannels(channel, 1, 0)`
  再 `createGroup`；`createGroupWithNot5GBand()` 用 `setWifiP2pChannels(channel, 0, 1)`。群组就绪后由
  `ConnectiveStateService.onGroupInfoAvailable` 回填本机发送凭据：`freq = group.getFrequency()`、
  `id = getDeviceId()`、`mac = isSPRDPlatform() ? owner.deviceAddress : getMacAddr()`、
  `psk = group.getPassphrase()`、`ssid = group.getNetworkName()`、`port = getLocalPort()`。
- **小米**（`g/b.java`）[已取证]：方法 `b(str, str2, z)` 用
  `setNetworkName` + `setPassphrase` + `setGroupOperatingFrequency(d.b(iA))` + `enablePersistentMode(false)`
  建组；另有 `setP2pConfig`/`setWifiP2pChannels` 回退路径 `c(...)`。
- 频段选择 [观测]：中兴按 `is5GHzBandSupported()` 与本机/对端能力选 5G 或非 5G 建组
  （可复现观测：中兴进程 `com.zte.cn.zteshare` 日志依次出现 `createGroupWith5GBand`、
  `createGroup success`、`frequency: 5220`）；小米按能力 `d.a(context, z)`/`d.b(iA)` 选频点。
- 第三方 [已取证]：CatShare `services/P2pSenderService.kt`（SSID `DIRECT-<8 随机字符>`，
  `utils/P2pUtils.kt`#方法 `createGroupSuspend` 建组）。

- **本机建组就绪判定**（本项目发送方，交叉校验）[推断]：建组流程为「有界清理旧组 → 建组 → 等待就绪」，
  就绪判定以**群组身份**为准——就绪组名须等于本次请求创建的组名；不匹配（含上一会话尚未拆除完成的残留组）
  即视为未就绪，在候选/超时预算内有界重试，绝不采用残留群组的无线凭据（否则下发给对端的是上一组的凭据，
  对端无法入组而挂起）。建组前对上一会话残留群组做有界处置，确认其消失；超时未消失不阻断建组，
  由身份校验兜底。

### 6.3 接收方入组

**中兴为「发现驱动 + SSID/PSK 静默加入」** [已取证]：

1. `BleAdvertiserService.onCharacteristicWriteRequest` 收 P2pInfo 后调用 `connnectGroup()`
   → `WifiP2pCtrl.connnectGroup()`：`stopPeerDiscovery` + `discoverPeers`。
2. `ConnectiveStateService.updatePeers()` 在发现结果里**大小写敏感**匹配
   `P2pInfo.mac.equals(discovered.deviceAddress)`：
   - 命中且类型未知、需要加入 → `stopPeerDiscovery` → 可复现观测：中兴进程日志出现
     `find Group is ok` → `connnectGroup(bleSenderInfo)`。
   - 未命中但有 peers → 回退 `connnectGroup(onValidatedMac)`。
3. `WifiP2pCtrl.connnectGroup(BleSenderInfo)` 用
   `setNetworkName(ssid)` + `setGroupOperatingFrequency(freq)` + `setPassphrase(psk)` 连接；
   `connnectGroup(String)` 先以 `bleSenderInfo.mac.equals(str)`（**大小写敏感**）比对，命中才
   `deviceAddress = mac` 并按设备地址驱动连接。

**小米为「SSID/PSK 静默加入 + 群主地址校验」** [已取证]：

1. 入组前判定：`ssid` 与 `psk` 均非空且 `ssid.matches("^DIRECT-[a-zA-Z0-9]{2}.*")` 时按 SSID+PSK 加入，
   否则回退 `deviceAddress`（取 `P2pInfo.mac`）驱动（`g/b.java`#方法 `a(String,String)`、`k()`）。
2. 入组后校验群主：`wifiP2pGroup.getOwner().deviceAddress.equalsIgnoreCase(P2pInfo.mac)`，不符记录
   `[CONNECT]unrecognized network owner` 并中止（`g/b.java`#方法 `a(WifiP2pInfo, WifiP2pGroup)`）。

**第三方** [已取证]：OPPOShareReceiver `wifi/WifiConnectionManager.kt` 用 `WifiNetworkSpecifier`
（SSID + WPA2 口令）静默加入；CatShare `services/P2pReceiverService.kt`#
方法 `connectSuspend` 按 `WifiP2pConfig` 入组。

### 6.4 地址大小写（关键兼容点）

- 小米接收端对群主地址用 **`equalsIgnoreCase`**（大小写不敏感）[已取证]（`g/b.java`）。
- 中兴接收端对 `P2pInfo.mac` 用 **`equals`**（大小写敏感）[已取证]
  （`ConnectiveStateService.java`；`wifi/WifiP2pCtrl.java`）。
- 小米自身构造 `P2pInfo.mac` 时 `toLowerCase()`（`m.java`）[已取证]；中兴本机 p2p0 地址本身小写
  [已取证]（`Utils.java`#方法 `getMacAddr`）。因此发送方的 `P2pInfo.mac` 对外统一小写即可同时满足两类
  接收端。

### 6.5 P2P 组网契约（C-6）小结

| 项 | 发送方（GO） | 接收方（GC） |
|---|---|---|
| 建组 | `createGroup`（含 SSID/PSK/频点，`enablePersistentMode(false)`） | — |
| 入组 | — | 中兴：先发现后静默加入；小米：静默加入 + 群主校验 |
| 地址比对 | 无 | 中兴大小写敏感 / 小米不敏感 |
| GO IP | `192.168.49.1` | 取事件 `groupOwnerAddr`，兜底 `192.168.49.1` |

第三方对照：CatShare `services/{P2pSenderService,P2pReceiverService}.kt`、`utils/P2pUtils.kt`；
OPPOShareReceiver `wifi/WifiConnectionManager.kt`。

---

## 7. WebSocket 应用层

### 7.1 端点与报文文法

- 端点 [已取证]：`wss://<ip>:<port>/websocket`（小米 `e/f.java`#方法 `a(String,int)`；中兴
  `web/WebService.java`#方法 `startClient`）。下载 `https://<ip>:<port>/download?taskId=<id>`（小米
  `e/f.java`；中兴 `web/WebService.java`）。
- 文法：`type:id:name?payload`，其中 `type ∈ {action, ack}`，`id` 为消息 ID（ack 复用原 id），
  `name` 为动作名，`?` 后为可选 JSON 负载 [已取证]。
  - 小米 `e/d.java`：以正则匹配 `action`/`ack` 与非空动作名 [已取证]。
  - 中兴 `web/WSclient.java`：正则 `action:[\d\D]+:versionNegotiation\?`、
    `action:[\d\D]+:sendRequest\?`、`action:[\d\D]+:status\?` [已取证]。
  - 第三方旁证 [已取证]：CatShare `models/WebSocketMessage.kt` 与 OPPOShareReceiver
    `model/MtaModels.kt`#方法 `parse` 均用正则 `^(\w+):(\d+):(\w+)(\?(.*))?$`。
- 对任意 `action` 消息须回 `ack:<原id>:<原name>` [已取证]（中兴 `web/WSclient.java`；小米 `e/d.java`
  识别 `ack`；第三方 OPPOShareReceiver `transfer/MtaProtocol.kt`#方法 `makeAck`）。

### 7.2 消息类型

**versionNegotiation**（发送方 → 接收方）[已取证]：

- 发送方在连接建立时发 `action:0:versionNegotiation?{"versions":[1],"version":1}`
  （中兴 `web/NanoWebsocket.java`#方法 `onOpen`；小米 `e/f.java` 写 `versions:[1]`）。
- 接收方回 `ack:0:versionNegotiation?{"version":1,"threadLimit":5}`
  （小米 `e/c.java` 处理 versionNegotiation；第三方 OPPOShareReceiver `transfer/MtaProtocol.kt`#
  方法 `handleVersionNegotiation` 取双方版本最小值回 `version` + `threadLimit=5`）[已取证]。
  可复现观测：中兴进程 `com.zte.cn.zteshare` 日志出现该 ack [观测]。
- `payload` 缺 `version` 时按 `1` 处理 [已取证]（第三方 OPPOShareReceiver
  `transfer/MtaProtocol.kt` 用 `optInt("version", 1)`）。

**sendRequest**（发送方 → 接收方）[已取证]：任务 JSON，回空 ack（中兴 `web/NanoWebsocket.java`、
`web/WSclient.java`）。

| 字段 | 含义 | 类型 | 可选 |
|---|---|---|---|
| `taskId` | 任务 ID | string | 视实现（见「章 10」） |
| `id` | 任务 ID（与 taskId 同值） | string | 否 |
| `senderId` | 发送者设备 ID | string | 否 |
| `senderName` | 发送者名称 | string | 否 |
| `fileName` | 主文件名 | string | 否 |
| `mimeType` | MIME | string | 否 |
| `fileCount` | 文件数 | int | 否 |
| `totalSize` | 总字节 | long | 否 |
| `file[]` | 条目列表（`name`/`mimeType`/`size`） | array | 可选 |
| `thumbnail` | 缩略图路径 `/thumbnail?taskId=<id>` | string | 可选 |
| `thumbnail_width` / `_height` | 缩略图尺寸 | int | 可选 |
| `catShareText` | 文本传输内容 | string | 可选（第三方扩展） |

来源 [已取证]：中兴 `web/SendRequest.java`（含 `file` 内部类、`thumbnail*`、`totalSize`）；第三方
OPPOShareReceiver `model/MtaModels.kt`#方法 `SendRequest.fromDict`（缺省 `senderName="Unknown"`、
`mimeType="*/*"`、`fileCount=1`、`totalSize=0`，文本取 `catShareText`，缩略图取 `thumbnail`）。样例
[观测]（可复现观测：中兴进程 `com.zte.cn.zteshare` 与小米进程 `com.miui.mishare.connectivity` 日志
出现形如 `action:<id>:sendRequest?{…,"taskId":…,"fileName":…,"totalSize":…}` 的报文）。

**status**（接收方 → 发送方）[已取证]：`action:<id>:status?{"taskId":..,"id":..,"type":..,"reason":..}`。

| 取值 | 语义 | 出处（短键） |
|---|---|---|
| `type=1`，无 reason | 成功 | 中兴 WSclient.java#方法 `sendSuccess`；第三方 OPPOShareReceiver `transfer/MtaProtocol.kt` |
| `type=2`，`reason=<文本>` | 失败（如 `no enough space`） | 中兴 WSclient.java；中兴 WebService.java |
| `type=3`，`reason="user refuse"` | 拒绝 | 中兴 WSclient.java；第三方 OPPOShareReceiver `transfer/MtaProtocol.kt` |
| `type=3`，`reason="user interrupt"` | 发送方取消（超时/中断） | 中兴 NanoWebsocket.java#方法 `cancelSend` |

状态码常量旁证 [已取证]：OPPOShareReceiver `constants/MtaConstants.kt`（`STATUS_OK=1`、
`STATUS_ERROR=2`、`STATUS_USER_REFUSE=3`）；CatShare `models/WebSocketMessage.kt`#
方法 `makeStatus`（payload 含 `taskId`/`type`/`reason`/`id`）。

### 7.3 帧 ID 与状态机

- 发送方消息 ID 从 `0` 递增（`versionNegotiation=0`、`sendRequest=1`；中兴 `web/NanoWebsocket.java`
  自增字段）[已取证]。
- 接收方 status 帧号**不固定**，按实现而异：第三方 OPPOShareReceiver 接收端 id 计数器自 `99` 起、
  首条为 `100`（`transfer/MtaProtocol.kt`）[已取证]；可复现观测：接收方 status 报文形如
  `action:100:status?{"taskId":…,"id":…,"type":1,"reason":"ok"}`（同 §1.2 步骤 ⑫）[观测]。
  **发送方按任意 `action:<数字>:status` 解析，不依赖固定帧号** [已取证]（中兴 `web/WSclient.java`
  正则）。
- 冲突检测：中兴发送方等待 sendRequest 的 ack 超时 `30000ms` 后经 `cancelSend` 回 `type=3`
  `reason="user interrupt"` [已取证]（`web/NanoWebsocket.java`#方法 `onOpen` 中 `postDelayed(…, 30000)`）。
- 接收方确认超时：中兴 `WebService` 用 `30000ms` 超时回拒绝（`runnableReceiverConfirmTimeout`）
  [已取证]（`web/WebService.java`）；第三方 OPPOShareReceiver `transfer/TransferManager.kt` 的
  WebSocket 连接超时亦为 `30000ms` [已取证]。
- 小米侧 `sendRequest` 等待 ack 超时亦为约 30s [推断]（依据：既有文档交叉校验）。

### 7.4 WS 报文契约（C-7 / C-8）小结

| 契约 | 内容 | 出处（短键） |
|---|---|---|
| C-7 WS 报文 | `type:id:name?payload`；action/ack；ack 复用原 id | 小米 e/d.java；中兴 WSclient.java |
| C-7 versionNegotiation | 发 `{"versions":[1],"version":1}`，回 ack `{"version":1,"threadLimit":5}` | 中兴 NanoWebsocket.java；小米 e/c.java |
| C-8 状态回执 | `{taskId,id,type,reason}`；type=1 成功 / 2 失败 / 3 拒绝 | 中兴 Status.java、WSclient.java；OPPO OPPOShareReceiver transfer/MtaProtocol.kt |

第三方对照：CatShare `models/WebSocketMessage.kt`、`utils/WsUtils.kt`；OPPOShareReceiver
`transfer/MtaProtocol.kt`、`constants/MtaConstants.kt`。

---

## 8. 文件传输（HTTP / ZIP / 缩略图）

### 8.1 HTTP 约定

| 端点 | 方法 | 响应 | 出处（短键） |
|---|---|---|---|
| `/download?taskId=<id>` | GET | chunked；`Content-Type = sendRequest.mimeType`（中兴） | 中兴 NanoServer.java |
| `/thumbnail?taskId=<id>` | GET | fixed-length；`Content-Type = image/*` | 中兴 NanoServer.java |

- 中兴服务端 [已取证]：下载用 `Response.newChunkedResponse(Status.OK, serverTask.sendRequest.mimeType,
  getZipStream(serverTask))`（`web/NanoServer.java`#方法 `serve`）；缩略图用
  `Response.newFixedLengthResponse(Status.OK, "image/*", …, thumbnail.length)`。
- 小米接收端下载请求带请求头 `content-type: application/x-tar` [观测]（可复现观测：小米进程
  `com.miui.mishare.connectivity` 日志出现该请求头）。`HandySend`（本项目）发送侧响应
  `Content-Type: application/zip`（交叉校验，见 [../architecture/mta.md](../architecture/mta.md)）。
- TLS：自签名证书；接收方信任所有证书、hostname 恒真 [已取证]（中兴 `web/WebService.java`#
  方法 `getClientSSlContext()` / `createOkHttpClient`；第三方 OPPOShareReceiver
  `transfer/TransferManager.kt`#方法 `createNetworkBoundClient`；小米 `e/h.java`#方法
  `a(int)`/`b()` 的信任所有证书与 hostname 恒真实现）。

### 8.2 ZIP 流式格式（C-9）

- **中兴发送** [已取证]：`getZipStream` 用 `java.util.zip.ZipOutputStream`（默认 Deflate）经 2MB
  `PipedInputStream` 管道写出（`web/NanoServer.java`）；逐条目 `putNextEntry(new ZipEntry(name))`
  后写入并 `closeEntry()`。条目名 `namePathUri.path`（文件：`Uri.getPath()`；媒体：选择器
  `_display_name`）[已取证]（`Utils.java`#方法 `getFilePath`）。
- **中兴接收** [已取证]：`ZipInputStream` 逐条目 `getNextEntry()`，条目名含 `sendRequest.file[].name`
  时按声明名落盘，否则回退 `fileName` 或取条目名末段（`web/WebService.java`#
  方法 `writeFileWithoutCreateZipFile`）；忽略目录条目 `nextEntry.isDirectory()`。
- **第三方接收** [已取证]：OPPOShareReceiver `transfer/TransferManager.kt`#方法 `downloadAndExtract`
  用 `ZipInputStream` 逐条目解压、忽略目录条目、按文件名扁平化落盘；CatShare
  `services/P2pReceiverService.kt` 同。
- **本项目发送**（交叉校验）[推断]：`zip` crate 无 Seek 流式写出，所有条目压缩方法恒为 `Deflated`
  并携带数据描述符；单条目超 32 位时启用 ZIP64；条目名 `{序号}/{文件名}`。细粒度实现见
  [../architecture/mta.md](../architecture/mta.md)。
- **条目时间**：MTA 载荷无时间字段，文件修改时间经 ZIP 条目时间（MS-DOS 时间）承载 [推断]
  （依据：现有文档与 ZIP 规范；接收端解压后还原，缺失回退落盘时刻）。中兴接收端使用
  `ZipInputStream` 未显式读取 `getLastModifiedTime` [已取证]，故时间保真取决于对端是否写入条目时间。

### 8.3 进度与大小口径

- 中兴接收进度 [已取证]：`(int)((clientTask.downloadSize * 100) / clientTask.totalSize)`
  （`web/WebService.java`#方法 `updateProgress`），分母为 `sendRequest.totalSize`。
- 中兴发送侧 `PipedInputStream(2097152)`（2MB 管道缓冲）[已取证]（`web/NanoServer.java`）。
- 第三方 [已取证]：OPPOShareReceiver `transfer/TransferManager.kt`#内部类 `CountingInputStream`
  以「已读字节 ÷ `response.contentLength()`」计算进度，仅在变化 ≥1% 时回调。
- **本项目发送尺寸来源**（交叉校验）[推断]：`sendRequest.totalSize` 与各条目尺寸、修改时间均取自
  源文件的**已打开句柄**属性（`statSync(fd)`），与实际发送字节同源（避免来源 URI 属性与句柄内容
  不一致导致声明尺寸失真）；`/download` 按实际读取字节产出载荷，声明尺寸不符时仅记诊断、不截断载荷。

### 8.4 缩略图探测（C-10）

- 触发 [已取证]：接收方在确认阶段若 `sendRequest.thumbnail != null` 则先拉取缩略图再弹确认
  （中兴 `web/WebService.java`#方法 `downloadTask` / `downloadThumbnail`；第三方 OPPOShareReceiver
  `transfer/MtaProtocol.kt`#方法 `handleSendRequest` 取 `thumbnail` 字段）。
- 识别 [已取证]：响应 `Content-Type: image/*`、无格式提示；中兴按 `BitmapFactory.decodeStream` 解码
  （`web/WebService.java`），即**按内容解码而非按扩展名**。
- 发送方是否提供 [已取证]：中兴发送方在图片/视频时生成 JPEG 缩略图并写 `thumbnail` 字段
  （`Utils.java`#方法 `parseMediaUri`）；小米 `e/f.java` 提供 `/thumbnail?taskId=` 端点。

### 8.5 传输契约（C-9 / C-10）小结

| 契约 | 内容 | 出处（短键） |
|---|---|---|
| C-9 传输 | `/download` chunked；ZIP（Deflate）；条目名 = 文件名/路径 | 中兴 NanoServer.java |
| C-9 请求头 | 小米接收端附加 `content-type: application/x-tar` | 可复现观测（小米进程日志） |
| C-9 进度 | 已收字节 ÷ `totalSize` | 中兴 WebService.java |
| C-10 探测 | 确认阶段 GET `/thumbnail`，`image/*`，按内容解码 | 中兴 WebService.java |

第三方对照：OPPOShareReceiver `transfer/TransferManager.kt`、`model/MtaModels.kt`；CatShare
`services/P2pReceiverService.kt`。

---

## 9. 品牌与设备身份

### 9.1 品牌码（manufacture code）

品牌码编码在主广播 serviceData UUID 的字节中，扫描端读 `bytes[23]`（小米 `a/a/i.java`；
中兴 `ble/BleScannerService.java`#方法 `addDevice`）[已取证]。

中兴按厂商码区间映射设备类型枚举 [已取证]（`ble/BleScannerService.java`；类型名见
`Utils.java`#方法 `getTypeString`）：

| 厂商码区间 | 类型枚举 | 名称 |
|---|---|---|
| 80–89 | 1 | ZTE |
| 20–29 | 2 | vivo |
| 10–19 | 3 | OPPO（11 = Realme→5） |
| 30–39 | 4 | MIUI（小米） |
| 60–65、67–69 | 6 | Nubia |
| 66 | 17 | RedMagic |
| 50–59 | 8 | Meizu |
| 41–45 | 9 | OnePlus |
| 90–95 | 10 | ByteDance |
| 32 | 11 | BlackShark |
| 70–75 | 12 | Samsung |
| 160 | 13 | ROG |
| 161–169 | 14 | ASUS |
| 110–119 | 15 | Motorola |
| 100–109 | 16 | Lenovo |
| 170–179 | 7 | Hisense |
| `0xFF` | 0 | 第三方（未知） |

- 该区间表 [已取证]（中兴 `ble/BleScannerService.java`），与既有 `docs/mta` 跨厂商文档一致
  （交叉校验；本文件以中兴源码为准）。
- 小米侧品牌线索：`c.java` 按 `Build.DEVICE` 映射到机型码字节，`c.b()` 给出机型码、`a/c.java`#
  方法 `a(Context)` 给出设备类型 [已取证]。具体机型→码值表见 `c.java`（如 `chiron=10`、`dipper=2`、
  `lavender=43`）[已取证]。

### 9.2 机型码与名称区

- 机型码：小米放在扫描响应 serviceData UUID（`c.b()`）；第三方实测常填 `0xFFFF`，小米自家填机型代号
  映射值 [推断]（依据：既有文档交叉校验）。
- 名称：扫描响应 `[10..26)` 16 字节区；补零/`\t` 截断规则见 §2.3。
- 账号判定：小米 `DiscoverDeviceInfo` 含 `mAccount`/`mManufactureCode` 等字段
  （`DiscoverDeviceInfo.java`），品牌码落在小米区间（30–39）时才挂小米账号 [推断]（依据：既有文档
  交叉校验；`DiscoverDeviceInfo` 字段 [已取证]）。

### 9.3 第三方参考实现（非厂商）

CatShare、EasyShare、OPPOShareReceiver 均为**第三方参考实现，不是真实厂商对端**：

- CatShare（`moe.reimu.catshare`，MIT，Copyright 2025 Midori Kochiya）：`models/{DeviceInfo,P2pInfo}.kt`、
  `services/{GattServerService,P2pSenderService,P2pReceiverService}.kt`、
  `utils/{BleUtils,P2pUtils,WsUtils}.kt`、`BleSecurity.kt`。
- EasyShare（`me.pipi.easyshare`，MIT，基于 CatShare 重构）：结构与 CatShare 相同，另有
  `SessionSecurity.kt`、`utils/{ArchiveEntryNames,ArchiveReceiveRecovery}.kt`；其 `models/DeviceInfo.kt`
  等扩展 `catShareCrypto`（`BleSecurity.kt`#常量 `MODERN_CRYPTO_VERSION = 2`）等字段。
- OPPOShareReceiver（`com.mta.receiver`，GPL-3.0）：`constants/MtaConstants.kt`、
  `crypto/CryptoProvider.kt`、`model/MtaModels.kt`、`transfer/{MtaProtocol,TransferManager,TransferService}.kt`、
  `ble/BleServerManager.kt`、`wifi/WifiConnectionManager.kt`。
- 平台能力验证中的第三方参考实现对端（CatShare、EasyShare 等）属此类 [观测]
  （[MTA_PLATFORM_VERIFICATION.md](MTA_PLATFORM_VERIFICATION.md) §3）。
- 真实厂商（OPPO / vivo / 荣耀 / Samsung 等）在本文中仅作**差异对照**（见「章 10」），未做深度取证；
  第三方的字段扩展（如 `catShare`、`catShareCrypto`）不属厂商协议基线。

## 10. 跨厂商差异与兼容应对

下列两表以「维度 × 实现」汇总差异；「基线」指两厂商共有的协议约定。每条给出应对与出处。第三方列
列出参考实现的取值，均标注「第三方参考实现（非厂商）」。

**行为对照**

| 维度 | 小米 | 中兴 | 第三方参考实现（非厂商） |
|---|---|---|---|
| GATT 写响应 | 回写响应 | **不回**写响应 | CatShare 回写响应 |
| GATT 写特征属性 | `READ\|WRITE` | `READ\|WRITE\|WRITE_NO_RESPONSE` | CatShare `10/17`；OPPO `READ`/`WRITE` |
| 入组方式 | SSID+PSK 静默加入 + 群主校验 | 先发现命中后静默加入；未命中退化地址驱动 | CatShare 发现驱动；OPPO SSID+PSK（`WifiNetworkSpecifier`） |
| 群主/地址比对 | `equalsIgnoreCase` | `equals`（敏感） | 由实现 |
| 5GHz 判定 | `bytes[24]` bit0 | `bytes[24]` flag + 本机能力 | 由实现 |
| 频段策略 | 选频点 `setGroupOperatingFrequency` | `setWifiP2pChannels`(5G 1,0 / 非5G 0,1) | CatShare `createGroup`；OPPO 2.4GHz |
| 任务 ID 字段 | 写 `id`（= `taskId`） | 写 `id`（无 `taskId`） | 用 `id` |
| 状态帧号 | 接收端回 `action:100`（观测） | 接收端从 `0` 递增 | OPPO 接收端自 `100` 起 |
| status 语义 | 成功/部分/拒绝/超时可区分 | 1 成功 / 2 失败 / 3 拒绝 | 同左 |
| reason 词表 | `ok`/`partial`/`user refuse`/`timeout` | `no enough space`/`user refuse`/`user interrupt` | OPPO `ok`/`user refuse` |
| 下载 Content-Type | 未取证 | `sendRequest.mimeType`（chunked） | 由实现 |
| 缩略图 | 提供 `/thumbnail` | 写 `thumbnail` 字段，返 `image/*` | OPPO 读 `thumbnail` 字段 |
| 品牌码区间 | 30–39 | 80–89 | `0xFF`（第三方未知） |

第三方列出处（短键）：CatShare `services/GattServerService.kt`、`services/P2pReceiverService.kt`、
`utils/P2pUtils.kt`；OPPOShareReceiver `ble/BleServerManager.kt`、`wifi/WifiConnectionManager.kt`、
`transfer/MtaProtocol.kt`、`constants/MtaConstants.kt`。

**兼容应对与出处**

| 维度 | 兼容应对 | 出处（短键） |
|---|---|---|
| GATT 写模式 | 按对端写特征能力选写模式：声明无响应写（`0x04`）用无响应写，否则带响应写 | 小米 a/b/a.java；中兴 BleAdvertiserService.java |
| 入组方式 | 发送方 GO 须可被发现（2.4GHz 社交信道），`P2pInfo.mac` = 对端发现地址 | 小米 g/b.java；中兴 WifiP2pCtrl.java、ConnectiveStateService.java |
| 地址大小写 | `P2pInfo.mac` 对外统一小写 | 小米 g/b.java；中兴 ConnectiveStateService.java |
| 5GHz 判定 | 按 bit0 判定，勿整字节相等；不可用回退 2.4GHz | 小米 a/a/i.java；中兴 BleScannerService.java、ZteShareStatus.java |
| 任务 ID | 同时写 `taskId`/`id`；解析缺 `taskId` 回退 `id` | 中兴 SendRequest.java；OPPO OPPOShareReceiver model/MtaModels.kt |
| status | 按「类型 + 原因」判定；帧号不固定；`type=2` 视为失败 | 中兴 WSclient.java、Status.java；OPPO OPPOShareReceiver transfer/MtaProtocol.kt |
| 下载/缩略图 | 不依赖 Content-Type 解 ZIP；缩略图按内容解码 | 中兴 NanoServer.java、WebService.java |
| 品牌码 | 按区间表识别，未在表内按第三方处理 | 中兴 BleScannerService.java |

### 10.1 针对具体厂商的互通要点

- **对中兴发送**：`P2pInfo.mac` 小写；GO 须可被发现（2.4GHz 社交信道）；用无响应写（见「章 3」的写模式
  应对）。
- **对中兴接收**：其入组依赖先发现再匹配 `mac`，故发送方 GO 的 SSID/频段须可被 2.4GHz 发现，
  且 `mac` 与发现地址严格相等 [已取证]（中兴 `ConnectiveStateService.java`）。
- **对小米**：地址 `equalsIgnoreCase`，频段可按能力选 5GHz；接收端回写响应，带响应写可用 [已取证]。
- **对第三方参考实现（非厂商）**：CatShare/EasyShare/OPPOShareReceiver 均可作为互通对端与交叉印证；
  但其 `catShare`/`catShareCrypto` 等扩展字段与证书校验不属厂商协议基线 [已取证]。
- **第三方伴随外设**：部分发送端在发送期间保持最小 BLE 外设供对端反连；是否必需取决于对端实现
  [推断]（依据：现有文档交叉校验与运行期观测；细节见 [../architecture/mta.md](../architecture/mta.md)）。

## 11. 取证与复现

本章给出本文档取证的产物来源与重建方式，供读者独立复现。

### 11.1 APK 获取

在真机上定位并拉取协议实现 APK（小米协议实现与运行进程同名，位于独立 APK
`com.miui.mishare.connectivity`）[推断]（步骤源自既有文档交叉校验）：

```bash
adb shell pm path com.miui.mishare.connectivity   # 小米
adb pull <上一步路径> mishare.apk
adb shell pm path com.zte.cn.zteshare              # 中兴
adb pull <上一步路径> zteshare.apk
```

产物为包名对应的 APK；用 `adb shell pm path` 只取回填路径、不将任何本地目录写入本文。

### 11.2 jadx 反编译

```bash
jadx --no-res --show-bad-code -d mishare_jadx mishare.apk
jadx -d zteshare_jadx zteshare.apk
```

- 小米侧类名被混淆为单字母，部分字符串常量被替换为占位符；协议定位以**包内类路径 + 可读字符串常量
  （UUID、JSON 字段名）与方法名**为主（如日志标签 `MiShare:BlePeripheralManager`、
  `MiShare:WebSocketClient`）。小米 DeviceInfo/P2pInfo 的 `mac` 字段经混淆常量
  `com.xiaomi.onetrack.api.b.B = "mac"` 引用，据此可定位。
- 中兴侧类名/字段名可读，出处以「包内相对路径 + 成员名/字符串常量」定位。

### 11.3 第三方参考实现获取

三份公开第三方参考实现可独立获取并按其项目内相对路径复核：

- CatShare（`moe.reimu.catshare`，MIT，Copyright 2025 Midori Kochiya）
- EasyShare（`me.pipi.easyshare`，MIT，基于 CatShare 重构）
- OPPOShareReceiver（`com.mta.receiver`，GPL-3.0）

关键文件清单见「附录 C」。

### 11.4 日志观测

按进程名抓取运行日志（进程名与包名同名）：

```bash
adb shell pidof com.miui.mishare.connectivity   # 取 pid
adb logcat -d --pid=<pid> > mishare_log.txt
adb shell pidof com.zte.cn.zteshare
adb logcat -d --pid=<pid> > zteshare_log.txt
```

定位方式：按**日志标签** grep（如小米 `MiShare:BlePeripheralManager`、`MiShare:WebSocketClient`；
中兴 `ZTEShare_Utils`、`ZTEShare_NanoWebsocket`），再按**报文模式**核对（如
`action:<id>:status?{…}`、`BleSenderInfo{…}`）。日志因机器与 ROM 版本而异，本文只以「进程名/日志标签 +
报文模式」的可复现观测表述，不以任何本机日志文件名或行号作为出处。

### 11.5 复现注意事项

- 协议行为随厂商 ROM 版本变化：本文结论对应当前拉取的 APK 版本。
- 单机型的运行期观测不泛化为全厂商结论；跨厂商结论以源码为准，观测为旁证。
- 若逆向产物在当前环境不可得，按「章 12」降级：回退既有 `docs/mta` 已整理内容，并将无法复核的出处
  降级标注为 `[推断]` 并注明「未复核」。

---

## 12. 证据强度与未解项

### 12.1 `[推断]` 项汇总

下表列出本文档中全部 `[推断]` 项及其依据，便于后续复核与降级。

| 项 | 依据 | 后续复核方向 |
|---|---|---|
| 中兴 `state=1` 忙原因码语义 | 中兴接收端固定回 `state=0`，源码未走 `state=1` 分支 | 抓取中兴作发送方读取忙对端的日志 |
| 小米 `sendRequest` 等待 ack 超时约 30s | 既有文档交叉校验；小米 `e/c.java` 有超时处理但数值需复核 | 反编译常量或真机造超时 |
| 小米账号判定（品牌 30–39 挂账号） | `DiscoverDeviceInfo` 有 `mAccount`/`mManufactureCode`；判定逻辑取自既有文档 | 追踪小米账号绑定调用链 |
| 机型码第三方填 `0xFFFF` | 既有文档交叉校验 | 实测第三方广播机型码 |
| ZIP 条目时间承载与 `Deflated`/数据描述符/ZIP64 | 依据 ZIP 规范与既有文档；中兴用 `ZipOutputStream` 默认 Deflate（未显式读条目时间） | 抓取 ZIP 二进制头部 |
| 发送期间第三方伴随 BLE 外设是否必需 | 既有文档与运行期观测；无「其它机型依赖」证据 | 多机型对照是否反连外设 |
| 小米主广播字符串格式参数顺序 | `a/c.java`#方法 `a(byte,byte)` 参数名在反编译中改写，实际字节序依源码推导 | 真机广播字节转储比对 |
| 小米扫描侧按协议 service UUID 过滤 | 第三方参考实现同口径；小米源码字符串被混淆无法直读 | 真机扫描过滤验证 |

### 12.2 证据强度分布

| 强度 | 覆盖内容 |
|---|---|
| `[已取证]` | UUID、GATT 属性/读写行为、DeviceInfo/P2pInfo 字段、加解密参数、建组/入组、WS 文法与端点、ZIP/HTTP 约定、品牌码区间、第三方扩展字段 |
| `[观测]` | 报文序列（versionNegotiation/sendRequest/status）、发送者 ID、加密 P2pInfo 样例、GO IP、下载请求头（均为进程名/标签 + 报文模式） |
| `[推断]` | 见 §12.1 |

### 12.3 待验证方向

1. 小米机型码/品牌码完整映射与广播字符串字节序（真机字节转储）。
2. 中兴 `state=1` 忙原因码表与发送方「对端忙」判定阈值。
3. 更多真实厂商（OPPO/vivo/荣耀/Samsung 等）的深度取证（当前仅作差异对照）。
4. 扩展广播（`isExtended`）下 AD 排列顺序与跨平台可发现性。

### 12.4 复核后修订记录

本轮依据公开来源（厂商源码 + 三份第三方参考实现 + 可复现观测）对全部协议结论做了一次复核，修订如下：

| 项 | 原表述 | 复核结论 |
|---|---|---|
| 小米 `mac` 字段定位 | 仅以混淆字段占位定位 | 以混淆常量 `com.xiaomi.onetrack.api.b.B = "mac"` 定位，字段名 `mac` 确认 |
| `catShare` 字段 | `[推断]`，属第三方扩展 | 升为 `[已取证]`：CatShare `models/DeviceInfo.kt`、OPPOShareReceiver `model/MtaModels.kt` 确认，厂商模型无此字段；取值随实现（非厂商基线） |
| 共享密钥派生（裸 `generateSecret()`） | `[推断]`，疑来自其它参考实现 | 落定：厂商用 `generateSecret("TlsPremasterSecret")`；第三方 OPPOShareReceiver 用裸调用（`crypto/CryptoProvider.kt`） |
| 接收方 status 帧号 | 记为小米接收端固定回 `action:100` | 改为可复现观测，并给出第三方佐证：OPPOShareReceiver 接收端 id 自 `99` 起、首条 `100` |
| 第三方参考实现范围 | 仅 CatShare / EasyShare | 扩为 CatShare / EasyShare / OPPOShareReceiver，统一标注「第三方参考实现（非厂商）」 |
| 广播 serviceData UUID | 仅厂商取值 | 补第三方旁证：CatShare/OPPOShareReceiver 主广播 `000001ff`、扫描响应 `0000ffff` |
| 出处标注 | 机器本地路径、本机日志文件名与行号、反编译绝对路径 | 改为「包名 + 类/成员/常量」「项目名 + 项目内相对路径」「可复现观测」 |

## 附录 A：本项目实现映射

本附录给出本项目（HandySend）对应协议的工程落点精简索引，供架构文档链接锚点使用；细粒度实现以架构
文档为准，此处不展开。

### A.1 模块划分

| 层 | 位置 | 内容 |
|---|---|---|
| Rust 原生 | `localsend_ohrs` 的 `mta` 模块 | WS/HTTPS 服务器、流式 ZIP 写出/解压、接收端下载落盘 |
| ArkTS 服务 | `entry/src/main/ets/service/mta` | BLE 广播/扫描/GATT、加密、WS 协商、建组/入组、收发编排 |
| 主流程接入 | `MtaRepository` / 会话注册表 | 发现扫描、接收服务前台启停、收发互斥、会话展示 |

### A.2 关键接口（NAPI 事件）

- 起停/取消：`nativeMtaStartServer` / `nativeMtaStopServer` / `nativeMtaRejectPeer`
- 接收驱动：`nativeMtaReceiveDownload`
- 事件：发送请求、取消状态已回送、发送/接收进度、完成/部分完成/拒绝/失败

### A.3 协议环节 → 落点映射

| 协议环节 | 落点 | 说明 |
|---|---|---|
| BLE 广播/扫描 | ArkTS `MtaBleReceiver` / `MtaBleClient` | 主广播 + 扫描响应；`ScanFilter` 按 serviceUuid 过滤 |
| GATT 服务端/客户端 | ArkTS `MtaBleReceiver` / GATT Client | 读 DeviceInfo、写 P2pInfo，含 prepared write 累积 |
| 加密 | ArkTS `MtaCrypto` | ECDH P-256、SPKI+Base64、AES-256-CTR 固定 16 字节 IV |
| WiFi Direct | ArkTS `MtaP2pGroup` / `MtaSendService` | 建组（按频段候选）、`p2pConnect` 入组、GO IP 获取 |
| WS/HTTP | Rust `mta` 模块 + ArkTS `MtaTransferClient` | `/websocket` 状态机、`/download`、`/thumbnail` |
| 传输 | Rust 流式 ZIP / 下载解压 | 边写边发、边收边解压落盘 |
| 编排 | ArkTS `MtaSendService` / `MtaReceiveService` / `MtaSendAdapter` / `MtaReceiveAdapter` | 阶段与进度、收发互斥、取消与清理 |

更细的实现（架构、NAPI 桥接、状态管理、测试体系）见：

- 应用侧 MTA 编排：[../architecture/mta.md](../architecture/mta.md)
- 原生桥接：[../architecture/native-bridge.md](../architecture/native-bridge.md)
- 数据模型：[../architecture/types.md](../architecture/types.md)
- 平台实测数据：[MTA_PLATFORM_VERIFICATION.md](MTA_PLATFORM_VERIFICATION.md)

## 附录 B：常量与字段速查

### B.1 协议常量

| 常量 | 值 | 出处（短键） |
|---|---|---|
| 协议 service UUID | `00003331-0000-1000-8000-008123456789` | 小米 a/c.java；中兴 BleAdvertiserService.java |
| GATT 服务 UUID | `00009955-0000-1000-8000-00805f9b34fb` | 小米 a/c.java；中兴 BleAdvertiserService.java |
| CHAR_STATUS UUID | `00009954-0000-1000-8000-00805f9b34fb` | 小米 a/c.java；中兴 BleAdvertiserService.java |
| CHAR_P2P UUID | `00009953-0000-1000-8000-00805f9b34fb` | 小米 a/c.java；中兴 BleAdvertiserService.java |
| 扫描响应 serviceData UUID | 小米：机型码；中兴：`00000034-…-00805f9b34fb` | 小米 a/c.java；中兴 BleAdvertiserService.java#`ZTE_UUID2` |
| WS 路径 | `/websocket` | 小米 e/f.java；中兴 WebService.java |
| 下载路径 | `/download?taskId=<id>` | 小米 e/f.java；中兴 NanoServer.java |
| 缩略图路径 | `/thumbnail?taskId=<id>` | 小米 e/f.java；中兴 NanoServer.java |
| 协议版本 | `1`（versionNegotiation 报 `versions:[1]`） | 中兴 NanoWebsocket.java；小米 e/f.java |
| 默认服务端口 | `52897`（可 +1 递增重试） | 中兴 ZteShareStatus.java |
| GO 默认网关 | `192.168.49.1` | 可复现观测（小米进程日志）；OPPO OPPOShareReceiver MtaConstants.kt |
| AES IV | `0102030405060708`（16 字节 ASCII） | 小米 a/c/b.java；中兴 Utils.java |
| ECDH 曲线 | P-256（`EC`/`256`） | 小米 a/c/b.java；中兴 Utils.java |
| 共享密钥算法 | `generateSecret("TlsPremasterSecret")` | 小米 a/c/b.java；中兴 Utils.java |
| GATT MTU | `512` | 小米 a/a/g.java；中兴 BleGattService.java |
| GATT 写请求响应超时 | 约 `8000ms`（对不回响应端） | [观测] + 既有文档交叉校验 |
| 确认阶段超时 | `30000ms` | 中兴 WebService.java、NanoWebsocket.java |

### B.2 关键 JSON 字段速查

| 对象 | 字段 | 说明 |
|---|---|---|
| DeviceInfo | `state` / `mac` / `reason` / `key` | 见 §4.1；`state=0` 就绪，`state=1` 忙（带 `reason`） |
| P2pInfo | `id`/`mac`/`port`/`freq`/`G`/`M`/`P`/`ssid`/`psk`/`key` | 见 §4.2；`ssid`/`psk`/`mac` 可加密 |
| versionNegotiation | `versions` / `version` | 发送 `versions:[1],version:1`；ack 回 `version` + `threadLimit` |
| sendRequest | `taskId`/`id`/`senderId`/`senderName`/`fileName`/`mimeType`/`fileCount`/`totalSize`/`file[]`/`thumbnail*` | 见 §7.2 |
| status | `taskId`/`id`/`type`/`reason` | `type` 1=成功、2=失败、3=拒绝 |

第三方扩展字段（非厂商基线）：`catShare`（CatShare/OPPOShareReceiver）、`catShareCrypto`/`catShareToken`/
`catShareCert`（EasyShare）、`catShareText`（文本传输）。

## 附录 C：第三方参考实现索引

三份公开第三方参考实现用于交叉印证，均标注为「第三方参考实现（非厂商）」；锚点为「项目名 + 项目内
相对路径」。

- **CatShare**（包名 `moe.reimu.catshare`，MIT，Copyright 2025 Midori Kochiya）
  - 关键文件：`models/{DeviceInfo,P2pInfo,WebSocketMessage,TaskInfo}.kt`、
    `services/{GattServerService,P2pSenderService,P2pReceiverService}.kt`、
    `utils/{BleUtils,P2pUtils,WsUtils}.kt`、`BleSecurity.kt`
- **EasyShare**（包名 `me.pipi.easyshare`，MIT，基于 CatShare 重构）
  - 关键文件：同 CatShare 结构，另有 `SessionSecurity.kt`、
    `utils/{ArchiveEntryNames,ArchiveReceiveRecovery}.kt`、`BleSecurity.kt`（`MODERN_CRYPTO_VERSION`）
- **OPPOShareReceiver**（包名 `com.mta.receiver`，GPL-3.0）
  - 关键文件：`constants/MtaConstants.kt`、`crypto/CryptoProvider.kt`、`model/MtaModels.kt`、
    `transfer/{MtaProtocol,TransferManager,TransferService}.kt`、`ble/BleServerManager.kt`、
    `wifi/WifiConnectionManager.kt`

三者的许可与项目结构以其各自仓库的 `LICENSE`/`README` 为准；本文仅引用其源码作为公开可复核旁证。

## 可复核来源索引

本索引给出正文出处短键的展开与定位方式。全部来源均可公开获取与独立复核，不依赖取证者本机产物。

### 厂商：小米（`com.miui.mishare.connectivity`）

- 短键：`小米`
- 包名：`com.miui.mishare.connectivity`
- 定位方式：包内相对路径 + 可读字符串常量（UUID、JSON 字段名）或方法名；类名混淆为单字母，部分字符串
  常量被替换为占位符，此时以日志标签或第三方源码交叉佐证。

关键类文件（相对包根）：

| 简称 | 文件 | 作用 |
|---|---|---|
| `a.c` | `a/c.java` | BLE 广播构造与 UUID/品牌字节、P2pInfo 加解密入口 |
| `a.a.i` | `a/a/i.java` | 扫描响应解析（固定字节偏移） |
| `a.b.a` | `a/b/a.java` | GATT 服务端（BlePeripheralManager） |
| `a.a.g` | `a/a/g.java` | GATT 客户端（GattConnection） |
| `m` | `m.java` | P2pInfo 模型（`h()` 序列化、`a(byte[])` 解析） |
| `d` | `d.java` | DeviceInfo 模型（`state`/`mac`/`reason`/`key`） |
| `a.c.b` | `a/c/b.java` | 加密实现（ECDH + AES-CTR + 固定 IV） |
| `g.b` | `g/b.java` | WiFi Direct 建组/入组、群主地址校验 |
| `e.f` | `e/f.java` | WS/HTTP 端点与 versionNegotiation 载荷 |
| `e.c` | `e/c.java` | WebSocket 客户端消息处理 |
| `c` | `c.java` | `Build.DEVICE` 机型码映射、`c.a()`/`c.b()` |

字段名锚点：`mac` 经混淆常量 `com.xiaomi.onetrack.api.b.B = "mac"` 引用。

### 厂商：中兴（`com.zte.cn.zteshare`）

- 短键：`中兴`
- 包名：`com.zte.cn.zteshare`
- 定位方式：包内相对路径 + 成员名/字符串常量（如 `ble/BleAdvertiserService.java#PROTOCAL_UUID`）。

### 第三方参考实现（非厂商）

- 短键：项目名（`CatShare` / `EasyShare` / `OPPOShareReceiver`）
- 包名：`moe.reimu.catshare` / `me.pipi.easyshare` / `com.mta.receiver`
- 定位方式：项目名 + 项目内相对路径；关键文件与许可见「附录 C」。

### 运行期观测

- 短键：`观测`
- 定位方式：进程名（小米 `com.miui.mishare.connectivity`、中兴 `com.zte.cn.zteshare`）或日志标签
  （小米 `MiShare:BlePeripheralManager`/`MiShare:WebSocketClient`；中兴 `ZTEShare_Utils`/
  `ZTEShare_NanoWebsocket`）+ 报文模式；采集方式见「章 11.4」。日志因机器而异，须在同类设备自行复现。
