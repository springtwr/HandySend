# MTA 支持实施规划

> 本文档规划 HandySend 支持 MTA（互传联盟）协议的详细实施路径，基于 [MTA_INTEGRATION_RESEARCH.md](MTA_INTEGRATION_RESEARCH.md) 的技术研究结论。

## 1. 实施原则

1. **接收端优先**：接收端 API 风险最低、价值最高（用户最常遇到的场景是被安卓设备发送文件）
2. **协议层与 UI 层分离**：协议核心在 Rust 层实现，BLE/P2P 管理在 ArkTS 层实现，UI 仅做展示
3. **不破坏现有 LocalSend 功能**：MTA 模块与 LocalSend 模块并行运行，互不干扰
4. **降级优先**：WiFi P2P 不可用时回退到局域网模式，BLE 发现始终可用

> **修订记录（基于整合研究报告 MTA_INTEGRATION_RESEARCH.md 评审）**：
> 1. **AES IV 为 16 字节**（`"0102030405060708"` 16 个 ASCII 字符），预研报告 §3.8"8 字节"为误，实现时按 16 字节。
> 2. **共享密钥派生需双路径兼容**：CatShare 用 `generateSecret("TlsPremasterSecret")`、OPPO 用 `generateSecret()`，本地实测一致（32B），与厂商设备兼容性待 P0 校准。
> 3. **GATT 长写（prepared write）**：P2pInfo JSON 可能超 MTU，需按 `isPrepared` + `offset` 累积（参照 CatShare 1024B 缓冲）。
> 4. **接收端凭据直连正解**：优先验证 `addCandidateConfig`+`connectToCandidateConfig`（见 §4.1）。
> 5. **发送端 p2p0 MAC 有解**：`getP2pLocalDevice().deviceAddress`（建组后，API 9+）或 `p2pDeviceChange` 事件（无前提，API 10+）可获取本机 p2p0 MAC，仅需 `GET_WIFI_INFO`；对端真实 MAC 增强依赖 `GET_WIFI_PEERS_MAC`（system_basic，API 14+ 普通应用开放）。风险从 🔴 降 🟡，P0 实测厂商兼容性（见 §2/§4.1）。
> 6. 完整对比结论见 [MTA_INTEGRATION_RESEARCH.md](MTA_INTEGRATION_RESEARCH.md)。
## 2. 风险矩阵

| 风险项 | 评级 | 缓解措施 |
|--------|------|---------|
| BLE GATT Server | 🟢 低 | API 完整，官方有示例 |
| BLE 广播数据构造 | 🟢 低 | serviceData/serviceUuids 均支持 |
| WiFi P2P 做 GO（发送端） | 🟡 中 | `createGroup()` 可用（GET_WIFI_INFO 权限），`WifiP2PGroupInfo` 含 `goIpAddress`+`passphrase`；但 GO IP 和 SSID 格式需实测；备选局域网降级 |
| WiFi P2P 连接对端（接收端） | 🟡 中→🟢 有解 | `p2pConnect()` 可用；标准协商 vs 凭据直连差异。**替代路径（已确认）：`addCandidateConfig`+`connectToCandidateConfig` 把 P2P 组当普通 WPA2 热点直连（`SET_WIFI_INFO` 开放权限）**；备选局域网降级 |
| WiFi 热点方案（发送端备选） | 🔴 不可用 | `@ohos.net.sharing` 对三方应用不开放（d.ts 无方法暴露）；FAQ 确认三方无法编程开热点；只能跳转设置页 |
| 多网络并行 | 🟡 中 | 需实测 `@ohos.net.connection` 绑定行为 |
| 蓝牙 MAC 地址 | 🟡 有解（修订） | 接收端：`02:00:00:00:00:00` 兜底 + 引导用户从"设置 → 关于本机 → 状态信息"一次性抄录真实蓝牙 MAC（改善 OPPO 等厂商识别）；发送端：**`getP2pLocalDevice()`/`p2pDeviceChange` 获取本机 p2p0 MAC（仅需 `GET_WIFI_INFO`）**。P0 需真机验证厂商识别/校验兼容性 |
| HTTPS 自签名服务器 | 🟢 低 | Rust 生态成熟 |
| ECDH + AES-CTR | 🟢 低 | Rust 生态成熟 |
| ZIP 打包/解压 | 🟢 低 | 成熟方案 |

## 3. 模块架构

### 3.1 新增模块概览

```
HandySend/
├── entry/src/main/ets/
│   ├── service/
│   │   ├── mta/                          # MTA 业务层（新增）
│   │   │   ├── MtaManager.ets            # MTA 门面（生命周期编排）
│   │   │   ├── BleGattServer.ets         # BLE GATT Server 管理（广播 + 服务）
│   │   │   ├── BleScanner.ets            # BLE 扫描器（发现 MTA 设备）
│   │   │   ├── P2pManager.ets            # WiFi P2P 连接管理
│   │   │   ├── MtaProtocol.ets           # WS 消息解析/构造
│   │   │   └── MtaConstants.ets          # 协议常量
│   │   └── NativeBridge.ets              # 扩展 MTA 相关 NAPI 调用
│   ├── model/
│   │   └── mta/                          # MTA 数据类型（新增）
│   │       ├── MtaDevice.ets             # MTA 设备信息
│   │       ├── MtaTransferRequest.ets    # 传输请求
│   │       └── MtaP2pInfo.ets            # P2P 连接信息
│   └── viewmodel/
│       └── MtaViewModel.ets              # MTA 视图模型（新增）
│
├── localsend_ohrs/rust/
│   ├── lib.rs                            # 新增 MTA NAPI 函数
│   └── bridge/
│       ├── mta_facade.rs                 # MTA 协议核心（新增）
│       ├── mta_crypto.rs                 # ECDH + AES-CTR（新增）
│       ├── mta_ws.rs                     # WebSocket 协议处理（新增）
│       └── mta_server.rs                 # HTTPS + WS 服务器（新增，发送端用）
```

### 3.2 模块职责

| 模块 | 层 | 职责 |
|------|-----|------|
| `BleGattServer.ets` | ArkTS | BLE 广播启停、GATT 服务注册、特征值读写回调、DeviceInfo 构造 |
| `BleScanner.ets` | ArkTS | BLE 扫描启停、过滤 MTA UUID、解析广播数据、品牌识别 |
| `P2pManager.ets` | ArkTS | P2P 群组创建/删除、P2P 连接/断开、**凭据直连（`addCandidateConfig`+`connectToCandidateConfig`）**、连接状态监听、GO IP 获取 |
| `MtaManager.ets` | ArkTS | 编排 MTA 完整流程、协调 BLE/P2P/WS/文件下载、状态管理 |
| `MtaProtocol.ets` | ArkTS | WS 消息格式化（`type:id:name?json`）、消息解析 |
| `mta_facade.rs` | Rust | ECDH 密钥交换、P2pInfo 解密、ZIP 解压、ZIP 打包、HTTPS 下载 |
| `mta_crypto.rs` | Rust | ECDH P-256 密钥生成、AES-CTR 加解密、Base64 编解码 |
| `mta_ws.rs` | Rust | WS 协议状态机、消息路由、发送端 WS 服务器 |
| `mta_server.rs` | Rust | HTTPS 服务器（/download 路由）、自签名证书生成 |

### 3.3 数据流

#### 接收端数据流

```
BLE GATT Server
  ├── onCharacteristicRead(CHAR_STATUS) → 返回 DeviceInfo JSON（含 ECDH 公钥）
  └── onCharacteristicWrite(CHAR_P2P) → 接收 P2pInfo JSON
        │
        ├── [Rust] mta_decrypt_p2p_info() → 解密 ssid/psk/mac
        │
        └── [ArkTS] P2pManager.connect(ssid, psk)
              │
              ├── [ArkTS] WebSocket 连接 wss://GO_IP:port/websocket
              │     │
              │     ├── 接收 versionNegotiation → 回复 ack
              │     ├── 接收 sendRequest → 回复 ack → 通知 UI
              │     └── 用户确认 → 
              │           │
              │           └── [Rust] mta_download_zip() → HTTPS 下载 ZIP
              │                 │
              │                 └── [Rust] mta_unpack_zip() → 解压保存
              │                       │
              │                       └── 发送 status(type=1, reason="ok")
              │
              └── 传输完成 → 断开 P2P → 重启 BLE 广播
```

#### 发送端数据流

> **发送端网络方案确认**：`@ohos.net.sharing` 对三方应用不开放，无法编程开 WiFi 热点。发送端必须使用 `wifiManager.createGroup()` 创建 P2P 群组做 GO（Group Owner），通过 `getCurrentGroup()` 获取 `goIpAddress` 和 `passphrase`。

```
BleScanner.startScan()
  │
  ├── 发现 MTA 设备 → 解析品牌/设备名
  │
  └── 用户选择目标设备
        │
        ├── [ArkTS] BleGattClient 连接 → 读取 DeviceInfo（含公钥）
        │
        ├── [ArkTS] P2pManager.createGroup() → 创建 P2P 群组（做 GO）
        │     │
        │     ├── getCurrentGroup() → 获取 goIpAddress、passphrase、groupName
        │     │
        │     └── [Rust] mta_encrypt_p2p_info() → 用 groupName(SSID)、passphrase(PSK)、MAC 加密
        │
        ├── [ArkTS] 写入 CHAR_P2P（P2pInfo JSON，含加密 WiFi 凭据）
        │
        ├── [Rust] mta_start_sender_server() → 启动 HTTPS + WS 服务器（绑定 GO IP）
        │     │
        │     ├── WS: 发送 versionNegotiation → 等待 ack
        │     ├── WS: 发送 sendRequest → 等待 ack
        │     ├── 等待接收方下载 /download?taskId=xxx
        │     │     └── [Rust] mta_pack_files_zip() → ZIP 流式传输
        │     └── 接收 status(type=1) → 传输完成
        │
        └── 清理：删除 P2P 群组、停止服务器
```

## 4. 需实测验证的项目

在正式开发前，须先完成以下验证（预计 1-2 天）。

### 4.0 已确认结论（文档调研）

| 项 | 结论 | 依据 |
|----|------|------|
| `@ohos.net.sharing` 三方可用性 | ❌ 不可用 | SDK 6.1.1 d.ts 仅含 `NetHandle` 类型，无 `startSharing` 等方法；FAQ 确认"除系统应用外不支持代码开热点" |
| 跳转设置页开热点 | ⚠️ 可行但不可控 | 可跳转 `hotspot_data_settings` 页面，但无法读取 SSID/PSK，用户体验差，不作为主方案 |
| `wifiManager.createGroup()` 三方可用 | ✅ 可用 | 仅需 `ohos.permission.GET_WIFI_INFO`（开放权限，system_grant） |
| `SET_WIFI_INFO` 三方可用（新增） | ✅ 可用 | **normal 级别 + system_grant（开放权限，安装即授予）**，支持 Phone/Tablet/2in1；`addCandidateConfig`/`connectToCandidateConfig` 的前置 |
| `addCandidateConfig`+`connectToCandidateConfig` 凭据直连（新增） | ✅ API 存在 | 把 P2P 组当普通 WPA2 热点直连（对应 Android `WifiNetworkSpecifier` 路径）；能否连 WiFi Direct 组需实测 |
| `WifiP2PGroupInfo.goIpAddress` | ✅ 存在 | 字段定义：群组 IP 地址（string），createGroup 后通过 `getCurrentGroup()` 获取 |
| `WifiP2PGroupInfo.passphrase` | ✅ 存在 | 字段定义：群组密钥（string），createGroup 时通过 `WifiP2PConfig.passphrase` 指定 |
| `WifiP2PConfig` 可自定义 | ✅ 可用 | `groupName`、`passphrase`、`goBand`、`netId` 均可自定义设置 |
| `getP2pLocalDevice()` 获取本机 p2p0 MAC（新增） | ⚠️ 已实测不可用 | API 9+，返回 `WifiP2pDevice.deviceAddress`；**P0 实测（nova 15 Pro）返回全零 `00:00:00:00:00:00`**，不采用。正解见下行 |
| `getCurrentGroup().ownerInfo.deviceAddress` 获取本机 p2p0 MAC（新增·实测正解） | ✅ 实测成立 | 建组后查询 `getCurrentGroup()` 取 `ownerInfo.deviceAddress`，返回真实 MAC（多次一致）；仅需 `GET_WIFI_INFO` |
| `p2pDeviceChange` 事件监听（新增） | ⚠️ 已实测不触发 | API 10+，回调单个 `WifiP2pDevice`；**P0 实测建组/连接全程不触发**，不采用 |
| `GET_WIFI_PEERS_MAC` 权限（新增） | ⚠️ 有解 | system_basic + system_grant；API 8-13 为 system_core，**API 14 起向普通应用开放**；用于对端设备真实地址（`getP2pPeerDevices`/`getCurrentGroup`/`getScanInfoList`/`p2pPeerDeviceChange`），发送端 `P2pInfo.mac` 不依赖 |

### 4.1 WiFi P2P 实测

| 验证项 | 方法 | 预期结果 | 降级方案 |
|--------|------|---------|---------|
| `createGroup()` 后 GO IP | 调用后检查 `getCurrentGroup().goIpAddress` | `192.168.49.1`（或其他） | 使用实际返回的 IP |
| `groupName` 生成的 SSID | 调用后检查 P2P 群组信息 | `DIRECT-` 前缀 | 使用实际 SSID |
| 自定义 `passphrase` 是否生效 | `createGroup({passphrase:"12345678"})` 后读取群组信息 | passphrase 一致 | 使用实际返回值 |
| `p2pConnect()` 连接外部 GO | 用另一设备的 P2P 设备地址连接 | 连接成功 | ❌ 依赖 P2P 主动发现（实测不可用），改用凭据直连 |
| `addCandidateConfig`+`connectToCandidateConfig` 凭据直连（新增） | 已知 SSID+PSK，构造 `WifiDeviceConfig{ssid, preSharedKey, securityType:PSK}` → `addCandidateConfig` → `connectToCandidateConfig` | 连接成功（无需 P2P 发现） | ✅ 实测成功（连上外部 WPA2 热点，静默模式） |
| 凭据直连后是否能访问 GO 服务器 | 连接成功后 HTTP 请求 GO IP:port | 可达 | 局域网降级 |
| 连接后是否断开原 WiFi | 连接 P2P 后检查 `getIpInfo()` | 不断开 | 局域网降级 |
| `@ohos.net.connection` 网络绑定 | 创建 NetHandle 绑定 P2P 网络 | HTTP 走 P2P | 使用 `getIpInfo()` 的 P2P 接口 IP |
| 安卓设备能否发现 P2P 群组 | 创建群组后用安卓手机 WiFi 列表查看 | 安卓能看到 DIRECT-xx 热点 | 使用实际 SSID |
| `getP2pLocalDevice()` 获取本机 p2p0 MAC（新增） | `createGroup()` 后调用 `getP2pLocalDevice().deviceAddress` | ~~返回本机 p2p0 接口 MAC，非全零~~ | ❌ 实测全零，改用 ownerInfo |
| `getCurrentGroup().ownerInfo.deviceAddress` 获取本机 p2p0 MAC（新增·实测正解） | `createGroup()` 后调用 `getCurrentGroup()` 取 `ownerInfo.deviceAddress` | 返回本机真实 p2p0 MAC | ✅ 实测返回真实 MAC（多次一致） |
| `p2pDeviceChange` 事件在建组前获取 MAC（新增） | 注册事件后读取回调 `WifiP2pDevice.deviceAddress` | ~~建组/连接前即可拿到本机 p2p0 MAC~~ | ❌ 实测全程不触发 |
| 本机 p2p0 MAC 与安卓厂商设备兼容性（新增） | 用获取的 MAC 作为 `P2pInfo.mac`，安卓 MTA 接收方识别/校验 | 小米/vivo 可识别，OPPO 视校验策略 | 待 P2 厂商真机验证 |

### 4.2 BLE 广播实测

| 验证项 | 方法 | 预期结果 |
|--------|------|---------|
| 31 字节广播数据限制 | 构造含 serviceUuids + serviceData(6字节) 的广播 | 不超限 |
| 扫描响应 27 字节数据 | 构造含 serviceData(27字节) 的扫描响应 | 不超限 |
| 安卓设备能否扫描到 | 用安卓手机 nRF Connect 扫描 | 能发现 |
| GATT 特征值读写 | 安卓设备连接后读写特征值 | 数据正确 |

### 4.3 建议的验证方案

创建一个最小验证 App，包含：
1. BLE 广播按钮 → 启动含 MTA UUID 的广播
2. BLE 扫描按钮 → 扫描周围 MTA 设备
3. P2P 创建群组按钮 → 创建群组并显示 GO IP/SSID
4. P2P 连接按钮 → 连接已知 P2P 设备
5. 简单 HTTPS 服务器 → 在 P2P 网络上启动并接受下载
6. P2P 本机信息按钮（新增） → 显示 `getP2pLocalDevice()`/`p2pDeviceChange` 获取的本机 p2p0 MAC

## 5. 分阶段实施计划

### Phase 0：实测验证（1-2 天）

**目标**：确认 HarmonyOS WiFi P2P API 的实际行为。**P2P 部分已完成（2026-09-09），详见 [P2P_VERIFICATION_REPORT.md](P2P_VERIFICATION_REPORT.md)；BLE 部分（P0-2）已完成双向实测（2026-09-10，对端 CatShare），详见 [BLE_VERIFICATION_REPORT.md](BLE_VERIFICATION_REPORT.md)。**

| 任务 | 说明 | 产出 | 状态 |
|------|------|------|------|
| P0-1 创建 P2P 验证页 | HandySend 内验证页（建组/MAC/凭据直连/网络/HTTP 服务） | 验证页代码 | ✅ |
| P0-2 验证 BLE 广播 + GATT Server | 确认安卓设备能扫描并读写（含发送端扫描 + GATT Client 双向） | 验证报告 | ✅ 与 CatShare 双向互通实测通过（广播发现/GATT 读写/扫描/GATT Client），详见 [BLE_VERIFICATION_REPORT.md](BLE_VERIFICATION_REPORT.md) |
| P0-3 验证 P2P 创建群组 | 确认 GO IP、SSID 格式 | 验证报告 | ✅ GO IP=`192.168.49.1`，`DIRECT-` 前缀生效 |
| P0-4 验证 P2P 连接外部 GO | 确认能否用凭据连接外部热点 | 验证报告 | ✅ 凭据直连成功；`p2pConnect` 协商路径依赖的主动发现实测不可用 |
| P0-5 验证多网络并行 | 确认连接 P2P 后原 WiFi 是否断开 | 验证报告 | 🟡 观察到原 WiFi 保持，待专项深入 |
| P0-5b 验证本机 p2p0 MAC 获取（新增） | 获取本机 p2p0 MAC 各路径实测 | 验证报告 | ✅ 正解 = `getCurrentGroup().ownerInfo.deviceAddress` |
| P0-6 决策：标准方案 or 降级方案 | 根据验证结果选择实施路径 | 决策记录 | ✅ **标准方案（WiFi Direct）** |

**决策条件（P0-6 结论）**：
- ✅ P0-3/4 通过 → **采用标准方案（WiFi Direct）**（P0-5 观察无碍）
- P0-3 通过但 P0-4 不通过 → 接收端降级（局域网），发送端标准（未发生）
- P0-3 不通过 → 全面降级（局域网方案）（未发生）

### Phase 1：基础设施（3-5 天）

**目标**：建立 Rust 层 MTA 加解密基础 + ArkTS 层 BLE 基础。

| 任务 | 说明 | 依赖 | 产出 |
|------|------|------|------|
| 1-1 新增 `mta_crypto.rs` | ECDH P-256 密钥生成、AES-CTR 加解密（**IV 固定 16 字节 `"0102030405060708"`；共享密钥派生双路径兼容：`generateSecret()` 32B 原始 / `TlsPremasterSecret` 兼容**） | 无 | Rust 模块 |
| 1-2 新增 `mta_facade.rs` 骨架 | 密钥交换、P2pInfo 解密/加密、Base64 | 1-1 | Rust 模块 |
| 1-3 新增 NAPI 函数：`mta_generate_key_pair` | 返回 ECDH 公钥（Base64） | 1-1 | NAPI 接口 |
| 1-4 新增 NAPI 函数：`mta_decrypt_p2p_info` | 解密 P2pInfo 中的 ssid/psk/mac | 1-2 | NAPI 接口 |
| 1-5 新增 NAPI 函数：`mta_encrypt_p2p_info` | 加密 ssid/psk/mac | 1-2 | NAPI 接口 |
| 1-6 新增 `MtaConstants.ets` | 协议常量（UUID、端口、加密参数等） | 无 | ArkTS 模块 |
| 1-7 新增 `BleGattServer.ets` | BLE 广播启停、GATT 服务注册 | 1-6 | ArkTS 模块 |
| 1-8 新增 `BleScanner.ets` | BLE 扫描启停、MTA 设备解析 | 1-6 | ArkTS 模块 |
| 1-9 新增 MTA 数据类型 | `MtaDevice.ets`、`MtaP2pInfo.ets` 等 | 无 | ArkTS 类型 |
| 1-10 NativeBridge 扩展 | 新增 MTA NAPI 调用封装 | 1-3, 1-4, 1-5 | NativeBridge 更新 |
| 1-11 集成测试：ECDH 密钥交换 | 与 CatShare/OPPOShareReceiver 的公钥格式互操作 | 1-3 | 测试验证 |

> **实现说明（2026-09-10）**：接收端 MVP 的协议核心（ECDH/AES-CTR、WS 客户端、HTTPS 流式下载、ZIP 解压）经架构权衡改为 **ArkTS 层实现**，不新增 Rust/NAPI 代码；对应模块为 `entry/src/main/ets/service/mta/`（`MtaCrypto`/`MtaBleReceiver`/`MtaP2pConnector`/`MtaTransferClient`/`MtaReceiveService`）与 `entry/src/main/ets/model/mta/`。Rust 层 `mta_crypto.rs`/`mta_facade.rs` 及 1-3~1-5 NAPI 函数本期未实施，保留为后续演进方向。

### Phase 2：接收端核心（5-7 天）

**目标**：实现完整的 MTA 接收流程（BLE → P2P → WS → 下载 → 解压）。

| 任务 | 说明 | 依赖 | 产出 |
|------|------|------|------|
| 2-1 新增 `P2pManager.ets` | P2P 连接管理（创建群组、连接、断开） | P0 结果 | ArkTS 模块 |
| 2-2 新增 `MtaProtocol.ets` | WS 消息格式化与解析 | 无 | ArkTS 模块 |
| 2-3 新增 `mta_ws.rs` | Rust 层 WS 协议状态机 | 无 | Rust 模块 |
| 2-4 新增 NAPI 函数：`mta_start_receiver` | 启动接收端（WS 客户端连接 + HTTPS 下载） | 2-3 | NAPI 接口 |
| 2-5 新增 NAPI 函数：`mta_unpack_zip` | ZIP 流解压到指定目录 | 无 | NAPI 接口 |
| 2-6 新增 NAPI 函数：`mta_download_zip` | HTTPS 下载 ZIP（信任自签名证书） | 2-4 | NAPI 接口 |
| 2-7 BLE GATT Server 完整流程 | 接收 P2pInfo（含 prepared write 长写累积）→ 解密 → 连接 P2P（凭据直连优先）→ 启动 WS 客户端 | 1-7, 2-1, 2-4 | 集成 |
| 2-8 接收端状态机 | 版本协商 → 接收请求 → 用户确认 → 下载 → 完成 | 2-3, 2-6 | 集成 |
| 2-9 MtaManager.ets 接收端编排 | 编排完整接收流程 + 错误处理 + 自动重启广播 | 2-7, 2-8 | ArkTS 模块 |
| 2-10 MTA 事件集成 | 通过现有 EventCallback 推送 MTA 事件 | 2-9 | 事件系统 |
| 2-11 传输后自动重启 BLE 广播 | 传输完成/断开后重新启动 BLE 广播等待新连接 | 2-9 | 集成 |
| 2-12 端到端测试：接收文件 | 从安卓 MTA 发送方发送文件到 HandySend | 全部 | 测试验证 |

> **接收端状态（2026-09-10）**：接收端 MVP 代码已完成（ArkTS 实现，独立调试页 `MtaReceivePage`，入口「排查页 → MTA 接收」），覆盖 US1~US6 的接收闭环与自动恢复；协议核心落点见 Phase 1 实现说明。真机端到端验收项、操作指引与实测数据见 [MTA_RECEIVE_VERIFICATION_REPORT.md](MTA_RECEIVE_VERIFICATION_REPORT.md)。2-3/2-4/2-5/2-6 的 Rust 层实现由 ArkTS 层对应模块替代。

### Phase 3：接收端 UI（3-4 天）

**目标**：在 HandySend UI 中集成 MTA 接收模式。

| 任务 | 说明 | 依赖 | 产出 |
|------|------|------|------|
| 3-1 MtaViewModel.ets | MTA 状态管理（扫描中/已连接/传输中/完成） | 2-9 | 视图模型 |
| 3-2 接收确认对话框 | 显示发送方名称、文件数、总大小，接受/拒绝按钮 | 3-1 | UI 组件 |
| 3-3 传输进度展示 | 复用现有进度组件，适配 MTA 进度事件 | 3-1 | UI 组件 |
| 3-4 MTA 接收模式开关 | 设置页/主页面开关，控制 BLE 广播启停 | 3-1 | UI 组件 |
| 3-5 后台长时任务 | 申请 `BLUETOOTH_INTERACTION` 长时任务保活 BLE | 3-4 | 权限处理 |
| 3-6 通知栏集成 | 接收请求通知、传输进度通知 | 3-1 | 通知 |

### Phase 4：发送端核心（5-7 天）

**目标**：实现完整的 MTA 发送流程（扫描 → BLE 连接 → P2P GO → 服务器 → 传输）。

**网络方案**：发送端必须使用 `wifiManager.createGroup()` 做 P2P GO（`@ohos.net.sharing` 对三方应用不开放）。

| 任务 | 说明 | 依赖 | 产出 |
|------|------|------|------|
| 4-1 新增 `mta_server.rs` | HTTPS + WS 服务器（自签名证书、/websocket、/download） | 无 | Rust 模块 |
| 4-2 新增 NAPI 函数：`mta_start_sender_server` | 启动发送端服务器（绑定指定 IP），返回端口 | 4-1 | NAPI 接口 |
| 4-3 新增 NAPI 函数：`mta_stop_sender_server` | 停止发送端服务器 | 4-1 | NAPI 接口 |
| 4-4 新增 NAPI 函数：`mta_pack_files_zip` | 将文件列表打包为 ZIP 流 | 无 | NAPI 接口 |
| 4-5 发送端 BLE GATT Client | 连接接收方 → 读取 DeviceInfo → 写入 P2pInfo | 1-8 | ArkTS 集成 |
| 4-6 发送端 P2P GO 创建 | `createGroup()` → `getCurrentGroup()` 获取 goIpAddress/passphrase/groupName → 加密后通过 BLE 发送给接收方 | 2-1, P0 验证 | ArkTS 集成 |
| 4-7 发送端 WS 协商 | 版本协商 → 发送请求 → 等待确认 → 传输 → 等待状态 | 4-2 | Rust 集成 |
| 4-8 发送端 HTTPS 下载服务 | /download 路由 → ZIP 流式响应（绑定 P2P GO IP） | 4-1, 4-4, 4-6 | Rust 集成 |
| 4-9 MtaManager.ets 发送端编排 | 编排完整发送流程：BLE 扫描 → GATT 连接 → P2P 创建群组 → 加密凭据 → BLE 写入 → 启动服务器 → 等待连接 → 传输 → 清理 | 4-5~4-8 | ArkTS 集成 |
| 4-10 端到端测试：发送文件 | 从 HandySend 发送文件到安卓 MTA 接收方 | 全部 | 测试验证 |

### Phase 5：发送端 UI（3-4 天）

**目标**：在 HandySend UI 中集成 MTA 发送模式。

| 任务 | 说明 | 依赖 | 产出 |
|------|------|------|------|
| 5-1 MTA 设备列表 | 在设备发现页显示 MTA 设备（与 LocalSend 设备区分） | 4-9 | UI 组件 |
| 5-2 设备选择 → 发送流程 | 选择 MTA 设备 → 选择文件 → 发送 | 4-9 | UI 流程 |
| 5-3 发送进度展示 | 复用现有发送进度组件 | 5-2 | UI 组件 |
| 5-4 MTA 设备图标/品牌显示 | 根据品牌 ID 显示设备品牌图标 | 5-1 | UI 组件 |

### Phase 6：CatShare 扩展 + 优化（2-3 天）

**目标**：实现 CatShare 扩展功能，优化稳定性。

| 任务 | 说明 | 依赖 | 产出 |
|------|------|------|------|
| 6-1 文本传输支持 | sendRequest 中的 `catShareText` 字段处理 | Phase 2/4 | 功能扩展 |
| 6-2 缩略图支持 | sendRequest 中的 `thumbnail` 字段处理 | Phase 4 | 功能扩展 |
| 6-3 自动接收模式 | 设置项：自动接收（跳过用户确认） | Phase 2 | 设置 |
| 6-4 传输稳定性优化 | 超时重试、断线重连、错误恢复 | Phase 2/4 | 稳定性 |
| 6-5 多文件大文件压力测试 | 发送 100+ 文件、1GB+ 单文件 | 全部 | 测试 |

## 6. 新增 NAPI 函数清单

### 加密/密钥

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `mta_generate_key_pair()` | 无 | `String`（Base64 公钥） | 生成 ECDH P-256 密钥对，返回 X.509 SPKI DER Base64 公钥 |
| `mta_decrypt_p2p_info(encryptedSsid, encryptedPsk, encryptedMac, peerPublicKey)` | 4 个 String | `String`（JSON：`{ssid, psk, mac}`） | 用对端公钥 + 本端私钥协商共享密钥，AES-CTR 解密 |
| `mta_encrypt_p2p_info(ssid, psk, mac, peerPublicKey)` | 4 个 String | `String`（JSON：`{ssid, psk, mac}`，值已 Base64） | AES-CTR 加密凭据 |

### 接收端

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `mta_start_receiver(host, port, taskId, saveDir)` | 4 个 String | `void` | 启动 HTTPS 下载 + ZIP 解压，进度通过 EventCallback 推送 |
| `mta_unpack_zip(zipPath, saveDir)` | 2 个 String | `void` | 解压 ZIP 到目录 |

### 发送端

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `mta_start_sender_server(bindIp)` | String（GO IP 地址） | `u16`（端口） | 启动 HTTPS + WS 服务器，绑定指定 P2P GO IP，返回监听端口 |
| `mta_stop_sender_server()` | 无 | `void` | 停止服务器 |
| `mta_pack_files_zip(filesJson)` | String | `void` | 注册文件列表到发送端服务器的下载路由 |

### 状态/查询

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `mta_get_status()` | 无 | `String`（JSON） | 获取当前 MTA 状态 |
| `mta_cancel_transfer()` | 无 | `void` | 取消当前 MTA 传输 |

## 7. 新增权限

| 权限 | 用途 | 三方可用 |
|------|------|---------|
| `ohos.permission.ACCESS_BLUETOOTH` | BLE 广播、扫描、GATT 连接 | ✅ |
| `ohos.permission.GET_WIFI_INFO` | WiFi P2P 状态查询、`getP2pLocalDevice()`/`p2pDeviceChange` 获取本机 p2p0 MAC | ✅ |
| `ohos.permission.SET_WIFI_INFO`（新增） | `addCandidateConfig`/`connectToCandidateConfig` 凭据直连 P2P 组 | ✅（normal + system_grant 开放权限） |
| `ohos.permission.GET_WIFI_PEERS_MAC`（新增，可选） | 对端设备真实地址（`getP2pPeerDevices`/`getCurrentGroup`/`getScanInfoList`/`p2pPeerDeviceChange`） | ⚠️ system_basic + system_grant，API 14 起向普通应用开放（受限 ACL，需 AGC 申请）；发送端 `P2pInfo.mac` 不依赖 |
| `ohos.permission.LOCATION` | BLE 扫描和 WiFi P2P 设备发现（接收端 MVP 未使用：GATT Server 广播无需定位，且不依赖 P2P 主动发现） | ✅ |
| `ohos.permission.INTERNET` | HTTPS/WSS 网络通信 | ✅ |

长时任务（BLE 广播保活）：
- 后台任务类型：`BLUETOOTH_INTERACTION`
- 通知栏需显示持续性通知

## 8. 与现有 LocalSend 功能的共存

| 项 | LocalSend | MTA | 共存方式 |
|----|-----------|-----|---------|
| 设备发现 | UDP 组播 + HTTP | BLE GATT | 独立运行，设备列表可合并展示 |
| 传输协议 | HTTP REST | WebSocket + HTTPS | 独立通道 |
| 网络接口 | WLAN | P2P（createGroup GO / 凭据直连客户端） | 可并行 |
| HTTP 服务器 | hyper（Rust） | hyper（Rust） | 不同端口，不同网络接口 |
| 文件操作 | 单文件流 | ZIP 打包/解压 | 独立处理 |
| UI | 现有页面 | 扩展现有页面 | Tab/开关切换 |

## 9. 里程碑与时间估算

| 里程碑 | 内容 | 预估时间 | 依赖 |
|--------|------|---------|------|
| **M0：验证** | WiFi P2P + BLE 实测 | 1-2 天 | 无 |
| **M1：基础设施** | 加解密 + BLE + NAPI 骨架 | 3-5 天 | M0 决策 |
| **M2：接收端可用** | 完整接收流程 + UI | 8-11 天 | M1 |
| **M3：发送端可用** | 完整发送流程 + UI | 8-11 天 | M2 |
| **M4：CatShare 扩展** | 文本/缩略图/自动接收 | 2-3 天 | M3 |
| **总计** | | **22-32 天** | |

关键路径：M0 → M1 → M2 → M3 → M4

M2（接收端可用）是最重要的里程碑，完成后用户即可接收来自安卓互传联盟设备的文件。
