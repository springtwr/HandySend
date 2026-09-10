# MTA P2P 平台能力真机验证报告（P0）

> 验证日期：2026-09-09
> 验证设备：nova 15 Pro（HarmonyOS，API 24）+ MatePad 10.8 + 安卓设备
> 验证工具：HandySend「MTA P2P 验证」调试页（`entry/src/main/ets/pages/MtaP2pVerifyPage.ets`）
> 对应验证项：P0-3/4/5b（P2P 建组 / 连接 / 本机 p2p0 MAC）

## 1. 结论摘要

| 验证项 | 结论 | 状态 |
|--------|------|------|
| `createGroup()` 建组（GO） | GO IP=`192.168.49.1`、SSID 保留 `DIRECT-` 前缀、自定义 passphrase 生效、接口 `p2p-p2p0-N`、2.4G 频段 | ✅ |
| GO IP 获取 | `getP2pLinkedInfo().groupOwnerAddr` 普通应用返回全零；**`p2pConnectionChange` 事件回调返回真实 GO IP** | 🟢 有解 |
| 本机 p2p0 MAC | `getP2pLocalDevice().deviceAddress` 全零；`p2pDeviceChange` 事件不触发；**`getCurrentGroup().ownerInfo.deviceAddress` 返回真实 MAC** | 🟢 新正解 |
| 凭据直连（接收端） | `addCandidateConfig` + `connectToCandidateConfig` 成功连上外部 WPA2 热点（静默模式） | ✅ 正解成立 |
| P2P 主动发现 | `startDiscoverDevices()` 无法发现周围设备；仅当对端主动连接时才在 `getP2pPeerDevices` 出现 | ❌ 不可用（MTA 不依赖） |
| 与安卓设备互通 | 安卓/鸿蒙对端可发现并加入本机 `DIRECT-xx` 群组（`clientCount` 0→1） | ✅ |
| 多网络并行 | 连接 P2P 组后原 WiFi（192.168.2.x）保持连接，IP 未切换 | ✅ 待深入 |

## 2. 详细验证数据

### 2.1 建组与群组信息（P0-3）

```
创建群组: groupName=DIRECT-N82ZfypT passphrase=7qdloJkR goBand=0
查询群组: isP2pGo=true groupName=DIRECT-N82ZfypT passphrase=7qdloJkR
          goIpAddress=192.168.49.1 interface=p2p-p2p0-0 frequency=2412 clientCount=0
```

- GO IP `192.168.49.1` 多次建组一致，与协议文档 §3.2 一致 → **硬编码兜底可行**
- SSID 保留 `DIRECT-` 前缀，自定义 8 位 passphrase 生效
- `createGroup` 异步生效：调用后立即 `getCurrentGroup()` 返回 2801000（无群组），约 60ms 后 `p2pConnectionChange` 事件确认 → **事件驱动是建组成功的准确信号**
- 群组无客户端时 `clientDevices` 为 `undefined`（需容错），有客户端后返回数组

### 2.2 GO IP 获取（§7.3 风险验证）

| 数据源 | 结果 | 说明 |
|--------|------|------|
| `getP2pLinkedInfo().groupOwnerAddr` | `00.00.00.00` 全零 | 手机端需 `GET_WIFI_LOCAL_MAC`（仅系统应用），普通应用不可用 |
| `p2pConnectionChange` 事件 `groupOwnerAddr` | `192.168.49.1` 真实值 | **可靠来源**，无需特权权限 |

**结论**：接收端 GO IP 应取自 `p2pConnectionChange` 事件回调；`192.168.49.1` 硬编码可作兜底。

### 2.3 本机 p2p0 MAC（§7.1 风险验证，结论修订）

| 数据源 | 结果 | 说明 |
|--------|------|------|
| `getP2pLocalDevice().deviceAddress` | `00:00:00:00:00:00` 全零 | 文档"仅需 GET_WIFI_INFO"的假设在实测设备上不成立 |
| `p2pDeviceChange` 事件 | 整个建组/连接生命周期**未触发** | 与文档"无前提即可获取"假设不符 |
| `getCurrentGroup().ownerInfo.deviceAddress` | `b8:7a:eb:7a:69:1d` | **返回真实 MAC**（U/L 位=0 全局唯一，5 次建组一致） |

**结论（修订 §7.1）**：MTA 发送端 `P2pInfo.mac` 应使用 `getCurrentGroup().ownerInfo.deviceAddress`（建组后查询，仅需 `GET_WIFI_INFO`）。文档假设的 `getP2pLocalDevice()`/`p2pDeviceChange` 路径实测不可用。

### 2.4 凭据直连（P0-4，接收端关键路径）

```
凭据直连: ssid=M20 psk=13792468500 模式=静默
凭据直连: 添加候选配置成功 networkId=8，连接已发起（静默模式）
```

- `addCandidateConfig`（`securityType=WIFI_SEC_TYPE_PSK`）成功，返回 networkId
- `connectToCandidateConfig(networkId)` 静默模式连接外部 WPA2 热点**成功**
- 连接结果经 `wifiConnectionChange` 事件与网络快照观察确认

**结论**：接收端凭据直连（把 P2P 组当普通 WPA2 热点）路径可行，对应 Android `WifiNetworkSpecifier` 方案成立。`SET_WIFI_INFO` 权限（normal/system_grant）实测可用。

### 2.5 P2P 设备发现与协商（P0-4 对比项）

- `startDiscoverDevices()` 主动发现：本次测试**无法发现**周围 P2P 设备（0 台）
- 当对端（MatePad 10.8）在 WLAN 直连页主动连接本机后，`getP2pPeerDevices` 返回该设备（`status=CONNECTED`）
- 对端地址为随机 MAC（U/L 位=1，`42:b0:1c:...`）——符合 `GET_WIFI_PEERS_MAC` 权限模型（未申请则返回随机地址）

**结论**：本次（无定位权限）下 P2P 主动发现未返回设备；**MTA 协议设备发现走 BLE（P0-2 已验，见 [BLE_VERIFICATION_REPORT.md](BLE_VERIFICATION_REPORT.md)），不依赖 P2P 主动发现，故不影响 MTA 标准方案**。

> **后续修正（2026-09-10）**：引入 `ohos.permission.APPROXIMATELY_LOCATION` 后复验，`startDiscoverDevices()` + `p2pPeerDeviceChange` **可稳定发现周围 P2P 设备**（1~2 台）。因此本次「0 台」系**缺定位权限**所致，而非平台不支持主动发现。详见 [P2PCONNECT_EXPERIMENT_REPORT.md](P2PCONNECT_EXPERIMENT_REPORT.md)（疑点④）。

### 2.6 互通（P0 辅助验证）

- 本机建组 `DIRECT-xx` 后，MatePad 10.8 可发现并加入（`clientCount` 0→1，对端 `status=CONNECTED`）
- 安卓设备加入后本机保持 GO 状态

## 3. 权限实测结论

| 权限 | 结论 |
|------|------|
| `GET_WIFI_INFO`（normal/system_grant） | createGroup/getCurrentGroup/getIpInfo/p2pConnectionChange 事件均可用 |
| `SET_WIFI_INFO`（normal/system_grant） | addCandidateConfig/connectToCandidateConfig 可用 |
| `GET_WIFI_LOCAL_MAC`（系统应用） | 未测试（非普通应用可申请）；对应 `getP2pLinkedInfo().groupOwnerAddr` 全零问题已有事件回调替代 |
| `GET_WIFI_PEERS_MAC`（system_basic） | 未申请；对端地址返回随机 MAC，符合预期 |

## 4. P0-6 决策记录

**决策：采用标准方案（WiFi Direct），无需局域网降级。**

依据：
1. 发送端：`createGroup` 做 GO + `getCurrentGroup()`（真实 MAC + GO IP）✅
2. 接收端：凭据直连（`addCandidateConfig` + `connectToCandidateConfig`）正解成立 ✅
3. GO IP：`p2pConnectionChange` 事件获取真实值 + `192.168.49.1` 硬编码兜底 ✅
4. P2P 主动发现不可用 → 不影响（MTA 发现走 BLE）✅

## 5. 遗留验证项

| 项 | 说明 |
|----|------|
| `connectToCandidateConfigWithUserAction` 双路 | 本次仅测静默模式，带用户确认弹窗路径待补测 |
| P2P 组内 HTTP 服务可达性 | 验证页已具备能力，未在本次完成端到端（对端浏览器访问） |
| p2pConnect 数据面（本机 GO / GC） | ✅ 已验（2026-09-10）：可建组、角色由协商决定，但 P2P 网络不进 `getAllNets`、应用数据面不可达，详见 [P2PCONNECT_EXPERIMENT_REPORT.md](P2PCONNECT_EXPERIMENT_REPORT.md) |
| 多网络并行深入 | 已观察到原 WiFi 保持，建议传输场景专项验证 |
| 与真实小米/OPPO/vivo 设备互通 | 需厂商真机（P2 阶段） |
| BLE 广播/扫描/GATT（P0-2） | ✅ 已完成（2026-09-10，对端 CatShare 双向互通），详见 [BLE_VERIFICATION_REPORT.md](BLE_VERIFICATION_REPORT.md) |
