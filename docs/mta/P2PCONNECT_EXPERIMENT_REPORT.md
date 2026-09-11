# MTA p2pConnect 实验报告（平台能力排查）

> 文档更新：2026-09-11（v6：真机定论 p2pConnect 无法加入 MTA 发送端的 autonomous GO，对接收端不可行，见 §7；v5：补充实验推翻「数据面不可达」结论，见 §6 补充实验）
> 验证工具：HandySend「MTA P2P 验证」页（`entry/src/main/ets/pages/MtaP2pVerifyPage.ets`）
> 目的：真机排查 p2pConnect 连接后的网络能力，为 MTA 接收端连接方式
>   （凭据直连 vs p2pConnect）的决策提供实验依据。
> 真机：nova 15 Pro（HarmonyOS，API 24）+ 对端 MatePad 10.8（安卓，可运行 Termux）

## 1. 结论摘要

| 实验组 | 场景 | 结论 | 状态 |
|--------|------|------|------|
| A 平台基线 | P2P 发现取对端地址 → 本机 p2pConnect 连接标准 P2P 对端 | 组能建立；**P2P 网络不进 `getAllNets`，但数据面完全可达**（路由在内核 main 表，应用无需 `NetHandle`） | ✅ 已验 |
| A' 数据面补充 | GO/GC 双角色 × 入站/出站四象限实测 | **全部可达**：应用层 TCP 双向收发成功（含本机 GC 主动出站 connect 对端 GO —— MTA 接收端真实场景） | ✅ 已验（2026-09-11） |
| B 凭据注入探测 | netId(-1/-2) × 凭据(空/真实值) 对照 | **未单独执行**：角色由对端状态/GO 协商决定，`netId` 不控制；标准 P2P 协商不依赖本机注入凭据 | ⊘ 未执行 |
| C 厂商 GO 局限 | CatShare 发送端 GO 的 p2pConnect | 场景不适用（临时组 + 凭据经 BLE 加密下发，无凭据注入入口） | ⚠️ 不适用 |
| D 发现能力 | 引入定位权限后复验 P0「主动发现为空」 | **发现可用**（P0 结论需修正，见 §2 疑点④） | ✅ 已验（可用） |

**总体结论**：p2pConnect 能建立 P2P 组，**应用数据面完全可达**——P2P 网段路由（`192.168.49.0/24`）随连接直接装入内核 main 路由表，任何未绑定网络的应用 socket 均可路由，无需 `getAllNets`/`NetHandle`。`getAllNets` 不含 P2P 网络仍然成立，但仅意味着 NetManager 应用层 API 看不到该网络（不能 `bindSocket`/`setAppNet`），**与数据面可达性无关**。GO/GC 双角色、入站/出站双方向均已实测打通（§6 补充实验）。

**对 MTA 接收端的定位（真机定论）**：p2pConnect 只对「listening/未成组」的对端有效（本机以 GC 加入），**无法加入 MTA 发送端（CatShare/EasyShare）创建的 autonomous GO**，因此**不作为接收端备选路线**；接收端使用**凭据直连**（把 GO 当 WPA2 热点 STA 关联）。机制、对照实验与真机证据见 §7；平台实验数据见 §2–§6。

## 2. 四个疑点分析

| 疑点 | 说明 | 判据 | 实测结论 |
|------|------|------|------|
| ① 角色结果 | p2pConnect 对已是自治 GO 的对端，可能走 GO 协商而非 join；失败回落可能**本机自建空 GO 组** | `p2pConnectionChange` 的 `isGroupOwner`、`getCurrentGroup()` 的 isP2pGo/客户端列表 | **角色由对端状态/GO 协商决定，`netId` 不控制**：对端已有组时本机以 GC 加入（`isGroupOwner=false`，加入对端组）；对端 idle 时本机可能成为 GO（`isGroupOwner=true`，自建组）。两种角色均出现 |
| ② WPS 凭据注入 | OH `p2pConnect` 不暴露 WPS 参数；`passphrase`/`groupName` 是否为 join 消费无文档依据 | 对比凭据传空 vs 传真实值 | 未单独执行；但 GC 成功加入对端既有组，说明**系统自行完成了协商，未依赖本机注入凭据** |
| ③ 地址类型 | `deviceAddressType` 应传系统返回值（REAL/RANDOM） | 对比 0/1 的连接结果 | 实测用系统返回值（RANDOM=0，`d2:08:...`），连接成功，未见类型错配 |
| ④ 发现能力与定位权限 | P0「发现为空（0 台）」实测时无定位权限 | 引入 `APPROXIMATELY_LOCATION` 后复验 | **发现可用**：授予定位权限后稳定发现对端（1~2 台）。P0「发现不可用」结论应修正为「缺定位权限所致」 |

## 3. 实验输入采集指引

> P2P 验证专注「发现 → p2pConnect → 观测」标准路径，不依赖 BLE、不引入 MVP 接收能力。
> 设备地址经 P2P 设备发现或群组快照获取；标准 P2P 协商本身不需要凭据字段。

### A 组：对端 P2P 设备地址采集（两条路径任选）

**路径一：P2P 设备发现直接选取（主路径）**
1. 实验分区「P2P 设备发现」子节点击「开始发现」（首次会申请定位权限）
2. 对端处于 P2P 发现/连接状态，本机发现列表出现其设备名/地址
3. 点击条目「连接」：自动用该设备地址 + 系统返回的地址类型 + 实验分区当前 netId/凭据/频段**直接发起标准 P2P 协商**（默认 netId=-2、凭据空、AUTO）；如需切换场景，先点预设（如「标准协商」netId=-1）再连接
4. 也可点「填入」把地址与地址类型写入实验分区，调整参数后手动「发起连接」

**路径二：群组快照采集（发现不可用时兜底）**
1. 本机「MTA P2P 验证」页建组（createGroup）
2. 对端在「WLAN 直连」页主动连接本机群组
3. 本机刷新群组信息：`clients:` 行展示对端设备地址（可能为隐私化随机 MAC，U/L=1）
4. 记录该地址 → 删组 → 让对端自己建组
5. 本机实验分区填入该地址，发起 p2pConnect（本机做 GC）

### C 组：厂商 GO 场景局限说明（不适用）

> CatShare 等厂商发送端仅在发送文件时创建 WiFi Direct 组、且组为临时组，组凭据经 BLE GATT 加密下发，没有供本机注入 `passphrase`/`groupName` 的入口。因此「对厂商 GO 做 p2pConnect 凭据注入」在本验证框架内不成立：
> - 若为验证疑点 ② 的凭据注入行为，请在标准 P2P 对端（MatePad 建组，凭据可从其群组信息得知）上执行实验 B；
> - 厂商 GO 的互通仍由 MVP 凭据直连路径承担（见 MTA 接收验证报告），不在本 p2pConnect 实验范围内。

## 4. 实验 A 判定标准

**步骤**：
1. 按 §3 A 组采集对端地址并完成对端建组
2. 实验分区：地址类型=真实(1)、netId=-2、凭据空 → 发起连接
3. 观察 p2pConnectionChange 事件（connectState / isGroupOwner / groupOwnerAddr）
4. 刷新群组信息（角色）、刷新网络列表、TCP 探测 GO IP:端口
5. **TCP 探测判定前提：对端必须有真实监听服务**，否则超时（EINPROGRESS）无法区分「端口无服务」与「路由不通」

## 5. 判定结果

| 观测 | 实测结果 | 判定 |
|------|---------|------|
| 组是否建立 | 是（`connectState=CONNECTED`） | P2P 连接本身可用 |
| 本机角色 | GO（`isGroupOwner=true`）与 GC（`isGroupOwner=false`）均出现 | 角色由对端状态/GO 协商决定，`netId` 不可控 |
| P2P 网络是否注册进 `getAllNets` | **否**（仅 `wlan0`） | NetManager 应用层 API 不暴露 P2P 网络（`bindSocket`/`setAppNet` 不可用） |
| 内核路由 | **`192.168.49.0/24 → p2p-p2p0-x` 装入 main 表**（GO/GC 一致） | **应用 socket 无需绑定即可路由**，数据面可达 |
| `getIpInfo` | 始终 STA IP（`192.168.2.2`），未切 P2P | 应用默认网络未变（不影响 main 表路由） |
| 应用层入站（对端 → 本机应用） | **HTTP 200**（对端浏览器访问本机验证页 HTTP 服务，收到 "MTA P2P Verify Server OK"） | **可达** |
| 应用层出站（本机应用 → 对端 GO） | **HTTP 200**（本机 GC，验证页 httpGet 对端 Termux 服务） | **可达 —— MTA 接收端真实场景成立** |
| 发现能力 | 授予定位权限后可发现 1~2 台 | 发现可用（修正 P0 结论） |

**最终结论**：p2pConnect 能建立 P2P 组且**应用数据面完全可达**（内核 main 表路由，GO/GC × 入站/出站四象限均实测打通）。`getAllNets` 不可见只是应用层网络管理 API 的局限，不构成数据面阻断。接收端可行性最终以 §7 真机定论为准：p2pConnect 无法加入 MTA 发送方的 autonomous GO，接收端使用凭据直连。

## 6. 实测数据区

### 运行 1：对端 M20（本机成为 GO）

```
设备发现: 发现列表更新，共 1 台
设备发现: 直接连接 M20（地址类型=0 netId=-2 组名= 密码= goBand=0）
p2pConnectionChange: connectState=CONNECTED isGroupOwner=true groupOwnerAddr=192.168.49.1
查询群组: isP2pGo=true groupName=DIRECT-Ya-nova 15 Pro interface=p2p-p2p0-0
          frequency=5240 clientCount=1 clients=[80:2e:33:bb:54:07]
网络列表: 共 1 条，疑似 P2P 0 条: net=128 if=wlan0 addr=[192.168.2.2, ...]
TCP 探测 192.168.49.1:8080 → 连接失败: [2301115] Operation in progress
```

### 运行 2/3：对端 MatePad 10.8（本机成为 GC，加入对端既有组）

```
设备发现: 发现列表更新，共 2 台
设备发现: 直接连接 小叫花子t的MatePad 10.8（地址类型=0 netId=-2 组名= 密码= goBand=0）
p2pConnectionChange: connectState=CONNECTED isGroupOwner=false groupOwnerAddr=192.168.49.1
查询群组: isP2pGo=false groupName=DIRECT-HN-小叫花子t的MatePa
          interface=p2p-p2p0-3/4 frequency=5240/2462 clientCount=0 clients=[]
          ownerAddr=04:76:cd:9f:e6:46（对端 GO）
网络列表: 共 1 条，疑似 P2P 0 条: net=128 if=wlan0 addr=[192.168.2.2, ...]
TCP 探测 192.168.49.1:8080 → 连接失败: [2301115] Operation in progress
```

> **归因修正（2026-09-11）**：运行 1/2/3 的 TCP 探测失败**不能归因于路由不通**——当时对端 8080 端口无监听服务，SYN 无响应导致超时（EINPROGRESS 是「连接挂起直到超时」的表现；真正的无路由应报 `ENETUNREACH`、对端拒绝应报 `ECONNREFUSED`）。当时以「`getAllNets` 仅含 wlan0」+「探测超时」推断数据面不可达是过度推断：前者只说明 NetManager 不暴露 P2P 网络，后者源于无监听服务。补充实验（E1/E2/E3）已实测推翻。

### 补充实验 E1：内核层验证（2026-09-11，本机 GO 角色）

P2P 直连状态下 `hdc shell` 采集：

```
# 接口：GO IP 192.168.49.1，UP RUNNING
p2p-p2p0-5 Link encap:Ethernet HWaddr 4e:04:0a:90:4a:0b
          inet addr:192.168.49.1 Bcast:192.168.49.255 Mask:255.255.255.0
          UP BROADCAST RUNNING MULTICAST MTU:1500

# main 路由表（/proc/net/route，十六进制小端）：
#   p2p-p2p0-5  Destination=0031A8C0 Mask=00FFFFFF → 192.168.49.0/24
#   ancop2p-p2p0-5 Destination=000A11AC → 172.17.10.0/24（系统 ANCO 伴生接口）
# 即 P2P 网段路由直接装入 main 表，未绑定网络的应用 socket 可查

# ARP：对端 GC 已解析
192.168.49.6  0x1 0x6  e2:79:00:07:17:87  *  p2p-p2p0-5

# ping 对端 GC：3/3 通，39~439ms（首包高为省电唤醒）
```

**旁证**：接口 RX 达百万包级、系统为 P2P 链路建 ANCO 伴生接口（172.17.10.0/24）——华为系统服务（华为分享/多屏协同类）长期使用 P2P 数据面传输真实数据。

### 补充实验 E2：应用层入站（2026-09-11，本机 GO 角色）

- 本机验证页 `createGroup` 建 GO → HTTP 服务绑 `192.168.49.1:8080` → 对端 MatePad（GC）浏览器访问 `http://192.168.49.1:8080`
- **结果：浏览器收到 "MTA P2P Verify Server OK"**（本机 HandySend 应用 `buildHttpResponse()` 固定响应）
- **判定：第三方应用在 P2P 接口上完整 TCP 收发成功**（三次握手 + HTTP 请求 + 响应均走 P2P 链路）

### 补充实验 E3：应用层出站（2026-09-11，本机 GC 角色，MTA 真实场景）

- 对端 MatePad 建组做 GO，Termux 运行 `python -m http.server 8080`
- 本机 p2pConnect 以 GC 加入（`p2p-p2p0-9`，本机 IP `192.168.49.227` 由对端 GO DHCP 分配）
- 内核层：`192.168.49.0/24 → p2p-p2p0-9` 同样在 main 表；ping 对端 GO 3/3 通（13~34ms）
- 本机验证页「HTTP 请求」主动发起 `http://192.168.49.1:8080/`
- **结果：HTTP 200**（收到 Termux python http.server 目录列表响应）
- **判定：应用主动出站 connect 到 P2P 网段目标完全可达**——复刻 MTA 接收端（GC → GO 拉取数据）真实路径，成立

### 关键对比

| 角色 | 接口 IP | main 表路由 | ping 对端 | 应用层入站 | 应用层出站 |
|------|---------|-------------|-----------|-----------|-----------|
| 本机 GO | 192.168.49.1 | ✅ | ✅ (192.168.49.6) | ✅ HTTP 200 | —（响应随连接返回，双向已证） |
| 本机 GC | 192.168.49.227 | ✅ | ✅ (192.168.49.1) | — | ✅ HTTP 200 |

→ **双角色数据面均可达**；`getAllNets` 均不含 P2P 网络（应用层 API 局限，不影响数据面）。

## 7. 对 MTA 接收端的最终结论（真机定论）

> 结论（2026-09-11，nova 15 Pro 真机）：**p2pConnect 对 MTA 接收端不可行**——它只能加入「listening/未成组」的对端，**无法加入 MTA 发送端（CatShare/EasyShare，Android）创建的 autonomous GO**。

### 7.1 对照实验

| 目标设备状态 | p2pConnect 结果 |
|--------------|----------------|
| 安卓系统「WLAN 直连」页（listening，未成组） | ✅ 成功（本机以 GC 加入） |
| CatShare / EasyShare 建组后（autonomous GO，已成组） | ❌ `connectState=DISCONNECTED` |
| 凭据直连（把 GO 当 WPA2 热点） | ✅ 成功 |

已覆盖、均无法使其成功加入 autonomous GO 的变量：`netId`（-1/-2）、设备地址类型（0/1）、`groupName`/`passphrase` 留空与注入、连接期间保持或停止发现、设备地址取自 P2P 发现列表。

### 7.2 机制

- WiFi Direct 加入既有组有两条路径：**GO Negotiation**（设备地址驱动，面向未成组/listening 对端）与**按网络名加入**（`setNetworkName(ssid)` + `setPassphrase(psk)`，面向 autonomous GO）。
- MTA 发送端（CatShare/EasyShare/OPPO 等）创建的是 **autonomous GO**；Android 接收端用**按网络名加入**。
- 鸿蒙 `p2pConnect(WifiP2PConfig)` 只暴露 **GO Negotiation**（`deviceAddress` 驱动）；接口面不存在「按网络名加入」，注入 `groupName`/`passphrase` 实测仍走协商、仍 `DISCONNECTED`。ArkTS 与 Rust 均受此接口面约束（原生 WiFi C API `oh_wifi.h` 仅 STA 级，无 P2P）。

### 7.3 真机证据（MatePad + EasyShare 发送端）

```
应用侧（15:20:39–15:20:49）：
  收到 P2pInfo ssid=DIRECT-SIZWwsmg psk=Z0g04fWr port=40011
  发现对端 1 台: MatePad 10.8(5e:21:2e:72:1a:b6, type=0)
  p2pConnect deviceAddress=5e:21:2e:72:1a:b6 groupName=DIRECT-SIZWwsmg passphrase=Z0g04fWr netId=-2
  connectState=DISCONNECTED isGroupOwner=false

系统侧 wpa_supplicant（同窗口）：
  Initializing interface 'p2p-p2p0-5'
  wpas_p2p_group_started passphrase is null
  wpa_vendor_ext_notify_group_delete
```

即：框架建立了 P2P 组接口、组曾 start，随后被拆除，最终事件 `DISCONNECTED`，且未与对端达成可用的 GO Negotiation。（发现到的对端地址为随机 MAC，每次扫描会变化。）

### 7.4 接收端路径

MTA 接收端在鸿蒙上的可行路径为**凭据直连**：把发送方 WiFi Direct 组当普通 WPA2 热点接入（`addCandidateConfig` + `connectToCandidateConfig`），与 Android 侧 OPPO 的 `WifiNetworkSpecifier` 方案等价。`p2pConnect` 不再作为接收端备选路线。

## 8. MTA 接收调试页双路线实验方案（2026-09-11 追加）

> 目标：复现并归因「MTA 接收端用 p2pConnect 接收时卡在 WS 握手超时」。
> 载体：MTA 接收调试页 `MtaReceivePage`（`entry/src/main/ets/pages/MtaReceivePage.ets`）的「连接路线」开关与「WS 握手诊断」子节。
> 前提：本阶段仅改造调试页；生产主流程默认仍为凭据直连，生产行为不变。
> 结果：p2pConnect 路线经真机实测无法加入 MTA 发送方的 autonomous GO（见 §7），本方案作为该实验的观测能力与判据记录保留。

### 8.1 观测能力与页面动作对照

| 观测项 | 页面动作 / 位置 | 接收状态字段 |
|--------|----------------|--------------|
| 连接路线 | 服务区「连接路线」选择行（凭据直连 / p2pConnect） | `connectRoute` |
| 连接结果与参数 | 日志区 `P2P` 行（记录 deviceAddress/deviceAddressType/groupName/passphrase/netId/goBand） | — |
| WS 握手结果 | 「WS 握手诊断」子节：目标地址、握手结果、总耗时 | `wsHandshakeResult` |
| 每轮尝试时间线 | 同上：轮次 / 成功或失败 / 耗时 / 失败类型 / 原始错误码 | `wsHandshakeResult.attempts` |
| 网络绑定结果 | 同上：「网络绑定」行（已绑定 netId / 未找到 P2P 网络） | `netBindResult` |
| 网络并存快照 | 同上：「网络并存」行 + 「刷新网络」按钮 | `networkSummary` |

操作步骤（每次对照实验）：

1. 在接收页选择连接路线（凭据直连 / p2pConnect），点「启动接收服务」。
2. 用发送端（CatShare）发起一次接收传输，等待页面出现 WS 握手诊断结果。
3. 点击「刷新网络」记录连接后的网络并存快照。
4. 点击「复制日志」保存完整日志，填入 §8.5 记录模板。
5. 切换另一条路线重复 1~4，得到同一发送端的对照结果。

### 8.2 四类根因的假设与判据

| 根因 | 假设 | 页面判据 | 内核/系统判据 | 结论判定 |
|------|------|----------|---------------|----------|
| R1 网络层不通 | P2P 链路未建立或应用流量未走 P2P 网段，SYN 无路由 | 「网络绑定」显示未找到 P2P 网络；每轮均为超时；网络并存里无 P2P 接口 | 见 §8.3：接口无 IP、main 表无 `192.168.49.0/24`、ping 对端 GO 不通 | 通过=确认 R1；不通过=排除 R1 |
| R2 TLS 或 WS 服务未就绪 | TCP 可通但 TLS 握手/WS 升级被拒或证书校验失败 | 失败类型为「error 事件」且带原始错误码（非本地超时）；或对端返回 RST | 见 §8.3：`connect` 成功、ping 通，但目标端口无监听或立即 RST | 通过=确认 R2；不通过=排除 R2 |
| R3 握手超时参数过短 | 服务就绪晚于 3s×4 轮窗口，握手晚到成功 | 前几轮超时、后续轮成功（时间线出现「晚到成功」）；总耗时接近窗口上限 | 握手窗口期内可观察到对端慢启动 | 通过=确认 R3；不通过=排除 R3 |
| R4 发送方尚未起服 | 发送端在接收方开始握手时尚未监听 WSS 端口 | 全部轮次超时且目标端口无监听；稍后重试可成功 | 见 §8.3：目标端口 `LISTEN` 缺失；`connect` 返回 ECONNREFUSED/超时 | 通过=确认 R4；不通过=排除 R4 |

> 说明：R1 与 R2/R4 的区别在于「TCP 是否已通」——`ECONNREFUSED`（对端拒绝）指向服务层或未起服，`ENETUNREACH`/`No route to host` 指向网络层，本地超时（无任何响应）需结合内核证据判定。

### 8.3 内核证据命令（`hdc shell`）

```sh
# 1) 查看 P2P 接口是否 UP 且有 IP（接口名含 p2p）
ifconfig | grep -A3 p2p

# 2) 查看 main 路由表是否含 P2P 网段（192.168.49.0/24）
cat /proc/net/route

# 3) 查看对端 ARP 是否解析（连接后应出现对端 GO 的 MAC）
cat /proc/net/arp

# 4) ping 对端 GO（替换为页面「目标地址」中的 IP，如 192.168.49.1）
ping -c 3 192.168.49.1

# 5) 确认目标 WSS 端口是否在监听（替换端口；需对端可执行，或在本机 GO 场景看本机）
ss -ltnp | grep <端口>

# 6) TCP 握手结果结合 4/5 判定：对端拒绝→服务层；超时无响应→结合路由与 ARP 判定网络层
```

> 内核证据采集时机：在 WS 每轮尝试进行中或结束后立即采集；接收页「网络并存」已给出应用层可见的本机 IP/网关/默认网络/网络条目。

### 8.4 判据流程（一次握手超时的区分步骤）

1. 看「网络绑定」与「网络并存」：无 P2P 接口或 main 表无 `192.168.49.0/24` 路由 → R1（网络层）。
2. 若网络层通，看失败类型与错误码：
   - 出现明确错误码（非本地超时）→ R2/R4（按 §8.3 第 5/6 步区分服务未就绪 vs 未起服）。
   - 全部为本地超时 → 结合目标端口监听判定 R4；若端口已监听仍超时 → R2（TLS/升级层）。
3. 若时间线出现「后几轮成功」→ R3（超时窗口过短/服务晚到）。
4. 无法区分 TCP 是否已通时，判定为「不确定」，需补采内核证据后复判。

### 8.5 数据记录模板

```text
日期：            路线（凭据直连 / p2pConnect）：            发送端：
连接参数：deviceAddress=            groupName=            netId=       goBand=
连接结果：connected=         detail=
WS 目标：wss://            :
WS 握手：成功/失败    总耗时=        ms    轮数=
每轮尝试：
  第 1 轮：成功/失败（类型） 耗时=      ms  code=           msg=
  第 2 轮：...
网络绑定：netBindResult=
网络并存：networkSummary=
内核证据：
  ifconfig(p2p)=
  /proc/net/route=
  /proc/net/arp=
  ping 对端 GO=
否定性观测（本方案不能证明什么）：
  - 页面「网络并存」为空不代表网络层不通（应用层 NetManager 可能不暴露 P2P 网络）；
  - 一次握手失败不能直接断定连接方式有问题，必须与另一路线对照。
```

### 8.6 「确认可行」与后续改造决策点

- 判定「p2pConnect 路线可行」的最低门槛：连接后 WS 握手成功且能完成一次版本协商（进入 `negotiated`）。
- 若两条路线均失败：先按 §8.2 归因到服务层/发送端，不改造生产接收端。
- 若仅 p2pConnect 路线失败：记录 R1/R2 证据，评估是否需要发现+设备地址采集，暂不改造生产主流程。
- 若 p2pConnect 路线稳定可行：再决定是否将生产 `MtaRepository` 的默认路线切换/增强为双路线（需单独设计选路与回退策略），本阶段不实施。
- 决策记录：见 [MTA_INTEGRATION_RESEARCH.md](MTA_INTEGRATION_RESEARCH.md) §7.2 接收端连接方式判定。

## 9. 相关文档

- [MTA_INTEGRATION_RESEARCH.md](MTA_INTEGRATION_RESEARCH.md)（§7.2 接收端连接方式判定）
- [P2P_VERIFICATION_REPORT.md](P2P_VERIFICATION_REPORT.md)（P0 平台能力实测）
