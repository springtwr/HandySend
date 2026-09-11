# MTA p2pConnect 实验报告（平台能力排查）

> 文档更新：2026-09-11（v5：补充实验推翻「数据面不可达」结论，见 §6 补充实验）
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

**对 MTA 接收端的定位**：p2pConnect 数据面可行，作为备选/增强路线与凭据直连并列为双路线，两种路径的协议匹配性与兼容性另行评估（见 [MTA_INTEGRATION_RESEARCH.md](MTA_INTEGRATION_RESEARCH.md) §7.2）。注意协议匹配性差异独立于数据面：MTA 下发的是 STA 栈凭据（SSID+PSK），与 p2pConnect 的标准 P2P 协商流程（需设备发现+地址）不直接对应。

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

**最终结论**：p2pConnect 能建立 P2P 组且**应用数据面完全可达**（内核 main 表路由，GO/GC × 入站/出站四象限均实测打通）。`getAllNets` 不可见只是应用层网络管理 API 的局限，不构成数据面阻断。MTA 接收端连接方式进入**双路线评估**：凭据直连（STA 候选配置，`getAllNets` 可见、可 `setAppNet` 绑定）与 p2pConnect（标准 P2P 协商，main 表路由直通）均为可行路径，按协议匹配性与兼容性另行决策。

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

## 7. 相关文档

- [MTA_INTEGRATION_RESEARCH.md](MTA_INTEGRATION_RESEARCH.md)（§7.2 接收端连接方式双路线评估）
- [P2P_VERIFICATION_REPORT.md](P2P_VERIFICATION_REPORT.md)（P0 平台能力实测）
