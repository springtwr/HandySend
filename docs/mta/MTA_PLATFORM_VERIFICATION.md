# MTA 平台能力与端到端互传验证

> 记录 HarmonyOS 平台上 MTA 相关能力（BLE、WiFi Direct、权限）的验证方法与结论，以及端到端互传的验证
> 状态。每条结论只记「验证方法 + 结论 + 适用范围」，不含设备标识与机器专有数据（MAC / 私网 IP / 设备名 /
> 机型名 / 原始日志 / 日期）。
> 协议规格与工程实现落点见 [MTA_PROTOCOL.md](MTA_PROTOCOL.md)。

## 1. 文档说明

### 1.1 定位与读者

本文件面向「需要排查本应用在 HarmonyOS 上 MTA 能力是否可用、以何种方式落地、边界在哪」的读者。它与协议
文档分工：协议文档（[MTA_PROTOCOL.md](MTA_PROTOCOL.md)）描述 MTA 协议规格与可复核出处；本文件记录本应用
在目标平台上的能力落地实证与端到端互传验证状态。

### 1.2 表述口径

- 只记「验证方法 + 结论」：给出验证所用方法（能力路径、事件、确认信号）与得到的结论，不粘贴原始日志或
  设备标识。
- 去标识：不含 MAC 地址、私网 IP、设备名/机型名、原始日志片段、具体日期。**例外**：`192.168.49.1` 为
  WiFi Direct 群主的默认网关，属协议常量，予以保留。
- 不含本机路径、日志文件名/行号与 URL。

### 1.3 适用范围

- **平台能力结论**（§3～§5）适用于本应用目标的 HarmonyOS 版本（目标 SDK 26.0.0 / API 26，最低兼容
  6.1.0(23)），随系统版本与设备能力可能变化。
- **端到端互传结论**（§6）针对已验证的厂商对端集合（荣耀、小米/Redmi、中兴），不构成对全部品牌通用的
  保证。
- 对曾多次反转的结论（写模式、接收端入组），只保留当前成立口径；结论随系统/对端版本演进。

## 2. 结论摘要

| 能力 | 结论 | 状态 |
|---|---|---|
| BLE 广播 + 扫描响应 | 以 MTA 格式广播，真实第三方实现可发现；扫描端按 serviceData 值长度分类 | 可用 |
| GATT Server 凭据交换 | 对端可读 DeviceInfo、回写 P2pInfo；支持 prepared write 累积 | 可用 |
| BLE 扫描 + GATT Client | 按 serviceUuid 过滤扫描，可连接并读回 DeviceInfo | 可用 |
| P2P 建组（发送端 GO） | 5GHz 优先，失败快速回退 2.4GHz；SSID/口令自定义生效 | 可用 |
| GO IP 获取 | 取 `p2pConnectionChange` 事件 `groupOwnerAddr`，兜底 `192.168.49.1` | 可用 |
| 本机 P2P 设备地址 | 由 Native 读取 P2P 接口硬件地址；对外统一小写 | 可用 |
| 接收端入组（`p2pConnect`） | 全 0 地址 + 随机地址类型 + 临时组注入 SSID/PSK，静默加入匿名 GO | 可用 |
| 多网络并行 | 入组不改 STA 关联，已连 WiFi 保持；P2P 数据面可达 | 可用 |
| 权限 | 运行时授予 ACCESS_BLUETOOTH 后 BLE 全能力可用；无需定位权限 | 可用（见 §5） |
| 端到端互传 | 与荣耀、小米/Redmi、中兴完成互传联调（方向见 §6） | 已验证 |

平台能力结论见 §3～§5；端到端互传结论见 §6。

## 3. BLE 平台能力

### 3.1 广播与发现

- 验证方法：以 MTA 格式广播——主广播 serviceUuid `00003331-…` + serviceData `000001ff`（6 字节：
  设备 ID 前 6 字节），扫描响应 serviceData `0000ffff`（27 字节：设备 ID 尾段 10 字节 + 16 字节
  名称 + 末字节 `0x01`，与厂商扫描端按合并记录固定偏移 `25..31` + `35..45` 的拼接还原口径一致）；
  用真实第三方参考实现（CatShare 等）扫描发现本应用。
- 结论：可被发现，广播字节布局与协议逐字节一致（实测于 2 字节发送者 ID 布局；现为对齐厂商的
  16 字节设备 ID 布局，广播结构与 serviceData 值长度不变、仅值内容变化，待真机复验）。主广播
  service UUID 必须使用非标准基址 `00003331-…-008123456789`（扫描端按该 serviceUuid 过滤），
  改用标准基址会匹配不上。
- 名称区：名称 ≤16 字节时原样放入、其余补 `0x00`；超长时截到 15 字节并在末位写 `\t` 截断标记。
- 扫描端匹配：按 serviceData 的字节长度分类（27 字节 = 扫描响应、6 字节 = 主广播），不依赖 serviceData
  UUID 为固定值（不同厂商取值不同）。

### 3.2 GATT Server 凭据交换

- 验证方法：对端连接本机 GATT 服务，读 CHAR_STATUS（DeviceInfo），写 CHAR_P2P（P2pInfo），观察读写
  是否完整还原。
- 结论：对端可读走 DeviceInfo（含合法的 P-256 X.509 SPKI Base64 公钥），并用该公钥派生密钥加密回写
  P2pInfo，证明本机公钥格式被真实实现接受。
- prepared write：按写入 offset 累积分片，提交时提取 JSON；同时容忍写入前可能存在的非 JSON 前导字节。
- 写模式：本机发送端写回 P2pInfo 时按对端特征能力选择——对端声明支持无响应写则用无响应写，否则用带
  响应写；写回执不作为成功判据，端到端信号才是。

### 3.3 扫描与 GATT Client

- 验证方法：发送端以 MTA 主广播 serviceUuid 过滤扫描，解析扫描响应中的发送者 ID、设备名与品牌字节；
  作为 GATT Client 连接对端 GATT Server 并读 DeviceInfo。
- 结论：serviceUuid 过滤生效，列表中仅出现 MTA 设备；解析出的发送者 ID 与后续 P2pInfo 的 `id` 交叉一致；
  可读回对端 DeviceInfo，其公钥与凭据交换所用一致。

### 3.4 权限与边界

- 验证方法：运行时申请 `ohos.permission.ACCESS_BLUETOOTH` 后，逐项验证广播、扫描、GATT Server、
  GATT Client。
- 结论：授权后四项均可用；广播与 GATT Server 可同时在线；BLE 扫描不依赖定位权限。
- 边界：设备名超长截断、蓝牙关闭/权限拒绝的用户提示、资源清理等属容错路径。发送期间本应用还会保持
  一个最小 BLE 外设（广播 + GATT Server）供部分对端反连，该外设仅记录对端行为、不接入接收会话。

## 4. WiFi Direct 平台能力

### 4.1 建组（发送端 GO）

- 验证方法：以 `createGroup` 建组，指定自定义 SSID（保留 `DIRECT-` 前缀）与口令；按候选频段逐个尝试
  「有界清理旧组 → 建组 → 等待群组就绪」，以「就绪组名等于本次请求创建的组名」为成功信号（群组身份校验）。
- 结论：可建组，SSID 前缀与自定义口令生效。频段策略：非 Samsung 且对端声明支持 5GHz 时，显式优先请求
  5GHz（频段 + 限定非 DFS 频点）并施加有界就绪探测；超时或请求报错即快速回退 2.4GHz；Samsung 或对端不
  支持 5GHz 时仅有 2.4GHz 候选；全部失败才判定建组失败。请求 5GHz 而平台实际落在 2.4GHz 时按实际接受、
  不重复建组。
- 建组异步生效：`createGroup` 返回后立即查询可能尚无群组；应以群组信息就绪或 `p2pConnectionChange`
  事件作为就绪的触发，并就绪组名做**身份校验**——上一会话残留群组（组名不同）不得当作本次就绪采用。

### 4.2 GO IP 获取

- 验证方法：对比 `getP2pLinkedInfo().groupOwnerAddr` 与 `p2pConnectionChange` 事件回调的
  `groupOwnerAddr`。
- 结论：`getP2pLinkedInfo()` 在普通应用下返回全零（对应能力需系统级权限）；`p2pConnectionChange` 事件
  回调返回真实 GO 地址，为可靠来源。接收端 GO IP 取事件值，缺失时以协议默认网关 `192.168.49.1` 兜底。

### 4.3 本机 P2P 设备地址（发送端）

- 验证方法：对比 `getP2pLocalDevice()`、`p2pDeviceChange` 事件与 Native 读取网卡硬件地址三条路径。
- 结论：`getP2pLocalDevice()` 返回全零、`p2pDeviceChange` 在整个建组/连接周期未触发；
  `getCurrentGroup().ownerInfo.deviceAddress` 对三方应用屏蔽（无相应权限时为随机地址，仅作回退）。
  **本机 P2P 设备地址改由 Native 读取 P2P 接口硬件地址**（`nativeGetInterfaceMac`，经 `getifaddrs` 取
  `AF_PACKET` 地址；依次尝试基接口 `p2p0` 与当前群组接口，均不可得返回空串）。详见
  [../architecture/native-bridge.md](../architecture/native-bridge.md)。
- 该值即对端可见的群主设备地址，`P2pInfo.mac` 必须与之一致（部分对端会校验，否则判为未识别的网络群主）。
  对外发送的 P2P 地址统一小写（读取值归一覆盖回退值），可同时满足大小写敏感与不敏感的接收端。

### 4.4 接收端入组（`p2pConnect`）

- 验证方法：以 `p2pConnect` 提交配置——全 0 设备地址 + 随机地址类型 + 临时组（netId=-1）+ 注入解密出的
  SSID/口令，频段自动；以 `p2pConnectionChange` 的 `connectState=1` 确认连接。
- 结论：可静默加入发送方（Android）创建的匿名 autonomous GO。连接成功以事件确认；GO IP 取事件
  `groupOwnerAddr`、兜底 `192.168.49.1`；断开以取消连接 + 删组收尾。
- 机制：设备地址为全 0 时不再驱动 GO Negotiation，转而消费注入的 SSID/口令按「按 SSID + PSK 静默加入」
  路径接入。早期以非全 0 地址（发现列表采集的对端地址、对端 mac）配合不同 netId/地址类型/凭据注入组合
  连接 autonomous GO 均失败，失败根因是地址驱动协商而非凭据注入无效。

### 4.5 主动发现与定位权限

- 验证方法：检索本应用 MTA 发现路径所依赖的能力。
- 结论：MTA 设备发现走 BLE 扫描，不使用 P2P 主动发现；本应用未申请定位权限，接收端 `p2pConnect` 与
  BLE 扫描均不依赖定位。

### 4.6 多网络并行

- 验证方法：入组期间检查已连 WiFi（STA）是否保持、P2P 网段数据面是否可达。
- 结论：`p2pConnect` 不改变 STA 关联，已连 WiFi 保持连接，可同时保持蜂窝/宽带网络在线；P2P 网段随连接
  建立并承载接收数据面。应用层网络列表可能不列出 P2P 网络，不影响数据面可达。

## 5. 权限结论

| 权限 | 级别 | 对应能力 | 结论 |
|---|---|---|---|
| `ohos.permission.INTERNET` | normal | WS 协商与 HTTPS 下载 | 必需 |
| `ohos.permission.GET_NETWORK_INFO` | normal | 默认网络与网络列表查询 | 必需 |
| `ohos.permission.GET_WIFI_INFO` | normal / system_grant | 建组 / 查组 / 本机 IP / `p2pConnect` / 删组 / P2P 事件 | 必需 |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | normal | 长时任务（dataTransfer）后台续传 | 必需 |
| `ohos.permission.ACCESS_BLUETOOTH` | user_grant | BLE 广播 / 扫描 / GATT Server / GATT Client | 运行时授权后可用 |

未申请与不需要的权限：

- 定位（`APPROXIMATELY_LOCATION`）：仅 P2P 主动发现需要；本应用 MTA 路径走 BLE，不申请。
- `GET_WIFI_LOCAL_MAC`（系统应用）：普通应用不可申请；对应 GO IP 与本地地址需求已由事件回调与 Native
  读取替代。
- `GET_WIFI_PEERS_MAC`（system_basic）：未申请；本应用不依赖对端 MAC 清单。

## 6. 端到端互传验证

在下列厂商对端完成端到端互传联调；方向以实际覆盖为准。

| 对端 | 本应用发送 → 对端接收 | 对端发送 → 本应用接收 |
|---|---|---|
| 荣耀（系统「荣耀分享」） | 已验证 | 已验证 |
| 小米 / Redmi（小米互传） | 已验证 | 已验证 |
| 中兴（中兴互传） | 已验证 | 已验证 |

验证方法（双向共用的完整链路）：BLE 发现 → GATT 凭据交换 → P2P 建组/入组 → WS 协商 → HTTPS ZIP 下载 →
status 回执。发送方向由本应用建组为 GO；接收方向由本应用以 `p2pConnect` 加入对端建立的 GO，两种角色
数据面均可达。

兼容性要点：

- **任务 ID 字段**：部分对端按 `id` 字段读写任务 ID。本应用在 `sendRequest` 同时写入 `taskId`/`id`，
  解析时 `taskId` 缺失回退 `id`，`status` 回执携带 `taskId`。
- **凭据加密**：对端接受本应用的 P-256 公钥与 AES-256-CTR（固定 16 字节 IV）加密凭据。
- **写模式**：按对端写特征能力选择写模式（对端声明支持无响应写则无响应写，否则带响应写）。
- **对端忙**：读到的 DeviceInfo 状态非就绪时提前收束发送，避免无效等待。
- **地址大小写**：对外发送的 P2P 地址统一小写，兼容大小写敏感的接收端。
- **广播 serviceData 分类**：按 serviceData 值长度（27 字节/6 字节）分类，兼容把设备名放在非约定 UUID
  的对端。
- **文件时间保真**：文件时间经 ZIP 条目时间（MS-DOS，2 秒粒度）承载，条目时间缺失/不可用时回退落盘
  时刻；秒级取整与范围外时间会退化。

## 7. 待验证项

| 项 | 说明 |
|---|---|
| 更多厂商对端互通（OPPO / vivo / 三星 / 魅族 / 一加 / 真我 / 努比亚等） | 荣耀、小米/Redmi、中兴已联调；其余联盟品牌需厂商对端验证 |
| 超 MTU 的 prepared write 分片覆盖 | 分片累积已实现，需构造大分片写入以验证边界 |
| `p2pConnect` 参数稳健性 | 全 0 地址 + 随机地址类型 + netId=-1 组合已可行；其余取值边界（netId 其他值、定频段等）未系统覆盖 |
| 边缘场景（蓝牙关闭 / 权限拒绝 / 设备名超长 / 资源清理） | 属容错路径，未专项测试 |
