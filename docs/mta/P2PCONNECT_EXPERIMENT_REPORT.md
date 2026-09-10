# MTA p2pConnect 实验报告（平台能力排查）

> 文档创建：2026-09-10（v4：真机实测完成，结论落定）
> 验证工具：HandySend「MTA P2P 验证」页「p2pConnect 实验」分区
>   （`entry/src/main/ets/pages/MtaP2pVerifyPage.ets`，Spec: `spec/p2pconnect-experiment/`）
> 目的：真机排查「p2pConnect 连接后网络未激活」是**配置问题**还是**平台限制**，
>   为 MTA 接收端连接方式（凭据直连 vs p2pConnect）的最终决策提供实验依据。
> 真机：nova 15 Pro（HarmonyOS，API 24）+ 对端 MatePad 10.8（非鸿蒙设备）

## 1. 结论摘要（已实测）

| 实验组 | 场景 | 结论 | 状态 |
|--------|------|------|------|
| A 平台基线 | P2P 发现取对端地址 → 本机 p2pConnect 连接标准 P2P 对端 | 组**能**建立；但**平台层 P2P 网络不进 `getAllNets`**，应用数据面不可达 | ✅ 已验（平台限制） |
| B 凭据注入探测 | netId(-1/-2) × 凭据(空/真实值) 对照 | **未单独执行**：两轮 netId 均为 -2，角色由对端状态/GO 协商决定；A 已定论数据面不可用，凭据注入无继续价值 | ⊘ 未执行 |
| C 厂商 GO 局限 | CatShare 发送端 GO 的 p2pConnect | 场景不适用（临时组 + 凭据经 BLE 加密下发，无凭据注入入口） | ⚠️ 不适用 |
| D 发现能力 | 引入定位权限后复验 P0「主动发现为空」 | **发现可用**（P0 结论需修正，见 §2 疑点④） | ✅ 已验（可用） |

**总体结论**：**p2pConnect 路线在应用可用网络层被平台阻断**——无论本机作 GO 还是 GC，P2P 网络（`p2p-p2p0-x`）都不注册进 `getAllNets`，应用无法取得 `NetHandle` 绑定，到 `192.168.49.1` 的连接失败（EINPROGRESS）。**MTA 接收端维持凭据直连（STA 候选配置）为唯一正解。**

## 2. 四个疑点分析

| 疑点 | 说明 | 判据 | 实测结论 |
|------|------|------|------|
| ① 角色结果 | p2pConnect 对已是自治 GO 的对端，可能走 GO 协商而非 join；失败回退可能**本机自建空 GO 组** | `p2pConnectionChange` 的 `isGroupOwner`、`getCurrentGroup()` 的 isP2pGo/客户端列表 | **角色由对端状态/GO 协商决定，`netId` 不控制**：对端已有组时本机以 GC 加入（`isGroupOwner=false`，加入对端组）；对端 idle 时本机可能成为 GO（`isGroupOwner=true`，自建组）。两种角色均出现 |
| ② WPS 凭据注入 | OH `p2pConnect` 不暴露 WPS 参数；`passphrase`/`groupName` 是否为 join 消费无文档依据 | 对比凭据传空 vs 传真实值 | 未单独执行（A 已定论数据面不可用）；但 GC 成功加入对端既有组，说明**系统自行完成了协商，未依赖本机注入凭据** |
| ③ 地址类型 | `deviceAddressType` 应传系统返回值（REAL/RANDOM） | 对比 0/1 的连接结果 | 实测用系统返回值（RANDOM=0，`d2:08:...`），连接成功，未见类型错配 |
| ④ 发现能力与定位权限 | P0「发现为空（0 台）」实测时无定位权限 | 引入 `APPROXIMATELY_LOCATION` 后复验 | **发现可用**：授予定位权限后稳定发现对端（1~2 台）。P0「发现不可用」结论应修正为「缺定位权限所致」 |

## 3. 实验输入采集指引

> P2P 验证专注「发现 → p2pConnect → 观测」标准路径，**不依赖 BLE、不引入 MVP 接收能力**。设备地址经 P2P 设备发现或群组快照获取；标准 P2P 协商本身不需要凭据字段。

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

> CatShare 等厂商发送端**仅在发送文件时创建 WiFi Direct 组、且组为临时组**，组凭据经 BLE GATT 加密下发，**没有供本机注入 `passphrase`/`groupName` 的入口**。因此「对厂商 GO 做 p2pConnect 凭据注入」在本验证框架内不成立：
> - 若为验证疑点 ② 的凭据注入行为，请在**标准 P2P 对端**（MatePad 建组，凭据可从其群组信息得知）上执行实验 B；
> - 厂商 GO 的互通仍由 MVP 凭据直连路径承担（见 MTA 接收验证报告），不在本 p2pConnect 实验范围内。

## 4. A/B/D 实验步骤与判定标准

### 实验 A（平台基线：本机 GC 是否有 IP / 是否注册网络）

**步骤**：
1. 按 §3 A 组采集对端地址并完成对端建组
2. 实验分区：地址类型=真实(1)、netId=-2、凭据空 → 发起连接
3. 观察 p2pConnectionChange 事件（connectState / **isGroupOwner** / groupOwnerAddr）
4. 刷新群组信息（角色）、刷新网络列表（P2P 网络是否注册）、TCP 探测 GO IP:端口

**判定**：
- GC 角色 + p2p 接口有 IP + 网络列表含 P2P + TCP 可达 → **平台 GC 数据面正常，疑点转向 ②/③**
- GC 角色但无 IP / 不进网络列表 → **平台 GC 数据面缺失，p2pConnect 路线终结，凭据直连维持唯一正解**
- 本机变 GO（isGroupOwner=true 且无客户端）→ **疑点 ① 成立：连接走了 GO 协商/自建组**，记录事件时序后清理重试

### 实验 B（凭据注入探测：OH 是否消费 passphrase/groupName）

**步骤**：对标准 P2P GO（MatePad 建组，已知其 SSID/密码），按 2×2 矩阵执行：

| netId | passphrase/groupName | 预期观察 |
|-------|---------------------|---------|
| -1 | 空 | 疑点 ① 对照：GO 协商路径行为 |
| -2 | 空 | 官方示例写法：persistent 协商路径 |
| -1 | 真实值 | 凭据是否被消费用于 join |
| -2 | 真实值 | 凭据是否被消费用于 join |

每格：发起 → 记录事件 → 刷新群组/网络列表 → hilog 抓取 supplicant 日志 → p2pCancelConnect/清理。

**判定**：`hdc shell hilog | grep -iE "p2p|wpa|dhcp"` 中查看 P2P_CONNECT 命令参数（是否含 psk/groupName）与 WPS/join 走向。

### 实验 D（发现能力与定位权限验证）

**步骤**：
1. 确保已授予定位权限（发现动作触发申请）
2. 对端（MatePad）进入 P2P 发现/连接状态
3. 实验分区「开始发现」→ 观察发现列表是否出现对端设备
4. 对比 hilog wifi P2P scan 相关日志

**判定**：
- 授予定位权限后能发现对端 → **P0「发现为空」结论源于缺权限，疑点 ④ 成立**，发现路径可用
- 授予后仍为空 → 与定位权限无关，疑点 ④ 否定，发现能力受限（不影响 A/B 主流程，地址经路径二/群组快照采集）

## 5. 判定结果

| 观测 | 实测结果 | 判定 |
|------|---------|------|
| 组是否建立 | 是（`connectState=CONNECTED`，两轮均建立组） | P2P 连接本身可用 |
| 本机角色 | GO（`isGroupOwner=true`）与 GC（`isGroupOwner=false`）均出现 | 角色由对端状态/GO 协商决定，`netId` 不可控 |
| P2P 网络是否注册 | **否**（`getAllNets` 仅 `wlan0`，`疑似 P2P 0 条`） | **平台限制：P2P 网络对应用不可见** |
| `getIpInfo` | 始终 STA IP（`192.168.2.2`），未切 P2P | 应用默认网络未变 |
| TCP 到 GO | `[2301115]`（EINPROGRESS）失败 | 无到 `192.168.49.0/24` 的可用路由 |
| 发现能力 | 授予定位权限后可发现 1~2 台 | 发现可用（修正 P0 结论） |

**最终结论**：p2pConnect 能建立 P2P 组，但**平台层不向应用暴露 P2P 网络**（`getAllNets` 不可见），应用无法绑定/路由 → **对 MTA 接收端不可用**。凭据直连（STA 候选配置）是唯一可行路径——它是真实注册的 STA 网络，`getAllNets` 可见、可 `setAppNet` 绑定、路由可用。

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

### 关键对比

| 角色 | `isGroupOwner` | 组归属 | `getAllNets` | TCP 到 GO |
|------|----------------|--------|--------------|-----------|
| 本机 GO | true | 本机组 `DIRECT-Ya-...` | 仅 `wlan0` | 失败 |
| 本机 GC | false | 对端组 `DIRECT-HN-...` | 仅 `wlan0` | 失败 |

→ **角色不同但平台层表现一致**：P2P 网络均不注册，数据面均不可达。

> 说明：对端为**非鸿蒙设备**，无法在其上启动监听服务，故 TCP 探测的「失败」不能单独区分「端口无服务」与「路由不通」；但 `getAllNets` 仅含 `wlan0` 已足以定论——应用侧没有可用的 P2P 网络句柄，任何目标都不可达。

## 7. 相关文档

- [MTA_INTEGRATION_RESEARCH.md](MTA_INTEGRATION_RESEARCH.md)（§7.2 凭据直连正解）
- [P2P_VERIFICATION_REPORT.md](P2P_VERIFICATION_REPORT.md)（P0 平台能力实测）
