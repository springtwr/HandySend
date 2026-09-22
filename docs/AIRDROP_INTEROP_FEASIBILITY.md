# AirDrop 互通可行性研究

> 本文档记录「HandySend 能否与 Apple AirDrop 互通」的调研结论、证据与判定依据。属调研记录，不描述本项目已具备的任何能力。

## 1. 结论

**作为 HarmonyOS 三方应用，与 Apple AirDrop 完整互通不可行。**

断点不在业务层，而在射频层：AirDrop 只运行在 AWDL（Apple Wireless Direct Link）之上，而 AWDL 要求独占 Wi-Fi 射频、
把网卡置于 monitor mode 并直接收发 802.11 帧。HarmonyOS 未向三方应用开放任何对应能力，系统自身也不实现 AWDL。

判定依据不止于「接口缺失」，还包括正面证据：截至调研时，所有已知的互通实现（含 Google 官方方案）
无一例外都需要 monitor mode／驱动级支持，且其中最强的方案（Google Mosey）下沉到了内核模块与 Wi-Fi 芯片固件。

## 2. AirDrop 的协议分层

AirDrop 由两层构成，二者缺一不可。

| 层 | 职责 | 关键内容 |
|----|------|----------|
| 链路层 AWDL | 建立点对点 802.11 链路 | monitor mode + 帧注入；信道序列（social channel 6/44/149）；可用窗口 AW=16 TU、周期 AWC=64 AW；主从选举；MIF/PSF 动作帧；TLV 集合见注 1 |
| 业务层 AirDrop | 发现与传输 | mDNS/DNS-SD 广播；HTTPS 端点 `/Discover`、`/Ask`、`/Upload`；Apple binary plist 报文体；cpio/DvZip 归档载荷；自签证书 TLS |

> **注 1**：链路层 AWDL 的 TLV 集合包括 sync params、election v1/v2、channel sequence、service response、data path、version。

链路层的关键特征：**它不是 IP 层能力**。AWDL 节点按可用窗口在社交信道间跳频，需要 100% 占空比侦听当前信道才能不错过帧；上层拿到的只是一个虚拟网卡（`awdl0`）。

**发现层同时依赖两层。** AirDrop 候选列表不仅来自 mDNS，还来自 AWDL 动作帧内的 service TLV（type `0x02`）——
iOS 会从动作帧构建候选。因此即使把 mDNS 与 HTTPS 全部实现，缺少 AWDL 链路时 Apple 设备也不会出现在候选列表中。

## 3. 上游实现如何达成互通

### 3.1 OWL + OpenDrop（Linux，seemoo-lab）

两层拆分的经典实现，必须组合使用。

- **OWL**（C，用户态守护进程，需 root）：把网卡切为 active monitor mode（nl80211 `SET_INTERFACE` + `NL80211_MNTR_FLAG_ACTIVE`），用 libpcap 收发 802.11 帧；经 `/dev/net/tun` 建 TAP `awdl0`（IPv6
  link-local，邻居表自动增删），供上层当作普通网卡使用。固定标识：AWDL OUI `00:17:f2`、BSSID `00:25:00:ff:94:73`、action category 127 / type 8；VERSION TLV 自报 `AWDL v3.4` + `devclass = macOS`。
- **OpenDrop**（Python）：跑在 `awdl0` 上，只做业务层——mDNS 注册/浏览 `_airdrop._tcp.local.`（IPv6-only）、HTTPS 服务（默认端口
  8771，自签证书，`verify_mode = CERT_NONE`）、`/Discover` `/Ask` `/Upload` 端点、Apple binary plist 报文体、gzip + cpio 载荷。

硬性条件：网卡须支持 **active monitor mode 与帧注入**（官方推荐 Atheros AR9280）；需 root；虚拟机与 WSL 不支持；开启后网卡被独占，无法同时连接 AP。

已知缺口：缺少 BLE 触发环节，而 Apple 设备只有在收到特定 BLE 广播后才拉起 AWDL／AirDrop 服务，故常常发现不到对端。

### 3.2 ESP32Drop（自研硬件，独立重写）

在 ESP32-S3 上从零重写 AWDL 与 AirDrop，约 12,400 行 C，规格完整、带主机端单测。它证明了「只要拿到裸射频，AWDL 可以被紧凑地实现」，同时暴露了若干关键约束：

- **独占射频**：AWDL 把接口锁在信道 6 并保持 promiscuous，按可用窗口调度发送。代码注释明确指出这与
  `WiFi.begin()` 无法共存，且这是**固有性质而非实现缺陷**——维持 100% 占空比锁频要求听到信道 6 上的每一帧。
- **BLE 与 AWDL 不能同时驻留**：两者合计占用内部 DRAM（约 26 KB + 110 KB），发送方必须分时切换。
- **占空比是物理常数**：一个 AW 为 16 TU，一个 AWC 为 64 AW，信道序列把 AWC 切成 16 个 4 AW 的槽，通常只获批其中一个 → 原始占空比 6.25%，扣除前后保护后 5.01%。
- **受驱动限制**：ESP32 Wi-Fi 驱动拒绝真实 AWDL 数据帧所用的 QoS Data 形状（`(fc1 & 3) == 0`），也拒绝组地址 DATA 帧，因此实现只能工作在驱动允许的范围内。

### 3.3 Google Mosey（Android 原生，Quick Share 扩展）

Google 在 Android 上原生实现了与 Apple AirDrop 的互通，以 Quick Share 扩展形式分发（包名 `com.google.android.mosey`）。其分层如下（结论来自随模块分发的二进制逆向，非文档声称）：

| 层 | 内容 |
|----|------|
| 应用 | `com.google.android.mosey`（特权系统应用，位于 `/system_ext/priv-app/`） |
| 服务 | `MoseyApp` + `libbinder_ndk`；实际 Binder 描述符为 `com.google.pixel.moseyservice.IMoseyService`，并在 VINTF manifest 中声明为 AIDL HAL |
| 用户态 daemon | `/vendor/bin/mosey_server`（Rust，薄壳）`dlopen` `libmosey_daemon_ffi.so`，调用 `mosey_start_4`／`mosey_stop`／`mosey_reset` |
| init | `mosey.rc`，capabilities `NET_ADMIN` `NET_RAW` |
| 接口 | `wonder0`（网络设备）与 `radiotap0`（抓包/注入）；另建 `mosey0`/`mosey_tun` TUN 承载 mDNS/IPv6 数据面 |
| 帧收发 | libpcap + TPACKET_V3；`radiotap-tx` / `radiotap-rx` |
| 信道 | `6 / 2g / 20`、`44 / 5g / 80`、`149 / 5g / 80` |
| 驱动通道 | 厂商命令 OUI `0x001A11`（Google `00:1A:11`）；另有一条私有 ioctl 通道 "ART"：`ART_GET_IF_ADDR`、`ART_SET_CHAN`、`ART_TX_RATE`、`ART_BSSID` |
| 内核 | 厂商 Wi-Fi 驱动的 `wondertap` 机制（Broadcom `bcmdhd4390.ko` 等），或由第三方模块提供虚拟 mac80211 phy |
| 协议性质 | daemon 内嵌的 `mosey_frame` crate 字段名与 AWDL 一致（字段清单见注 2） |

> **注 2**：`mosey_frame` crate 字段：`AW period`、`AF period`、`Master address`、
> `Presence mode`、`Channel seq`、`Sync params`、`Guard time`；选举含 `MasterScore`、
> `counter`、`metric`、`distance_to_top_master`、`election_params_v2`。

**特权面**（全部为系统/root 专属，三方应用不可获得）：

- 内核 capability `NET_ADMIN` + `NET_RAW`；
- 七项 `signature|privileged` 权限：`MANAGE_WIFI_INTERFACES`、`LOCAL_MAC_ADDRESS`、`BLUETOOTH_PRIVILEGED`、
  `NETWORK_FACTORY`、`CREATE_APP_SPECIFIC_NETWORK`、`CONNECTIVITY_USE_RESTRICTED_NETWORKS`、`LOCATION_HARDWARE`；
- SELinux 类型 `mosey_server` / `mosey_service` / `mosey_app` 与 `vendor_service_contexts` 映射；`sepolicy.rule` 显式放行 packet socket、routing/generic netlink、TUN；
- 隐藏 API 白名单、phenotype 特性开关覆盖、默认权限授予。

**机型门控与厂商封杀**：仅部分带相应 Wi-Fi 芯片的机型可用；厂商会主动禁用（某机型系统配置中存在 `<disable pkg="com.google.android.mosey" priority="10"/>`）。社区只能借助 root + 自编内核模块绕过。

### 3.4 其他实现

| 项目 | 说明 |
|------|------|
| `Frostie314159/grace` | Rust 实现的 AWDL（GPL-3.0） |
| `chronosirius-android/external_owl` | 把 OWL 打补丁进 Android 系统源码树 |
| `bodaay/GoOpenDrop` | OpenDrop 的 Go 实现（已归档） |
| `rylena/libredrop` | 面向 Linux 的 AirDrop 互通维护版 |
| `jedbillyb/airdrop-mt7921` | 用内置 MediaTek MT7921 芯片实现 Linux ↔ iPhone 双向互通；做法是「先建普通 monitor vif 并调谐，再并列添加 active vif」，本质仍是 monitor mode |
| `spiral009/aviumui-wlan-tools` | 面向 Qualcomm qcacld-3.0 的驱动补丁与工具（细节见注 3） |
| `seregonwar/AirWin` | 声称在 Windows 上实现 AirDrop，实测为半成品：源码仅 mDNS + 普通 TCP/TLS 且使用自定义 JSON 报文（非 Apple 协议），`OWDL` 依赖目录缺失导致无法构建，AWDL 侧函数为空壳 |
| `spieglt/FlyingCarpet`、`schlagmichdoch/PairDrop`、`AwareShare` 等 | 自有协议的「类 AirDrop」方案，**不与 Apple 互通**，无参考价值 |

> **注 3**：开启 monitor 注入、active-monitor 标志、监管解锁、monitor 信道上报；以
> `con_mode=4` 进入全局 monitor mode，并用 AF_PACKET 注入 802.11 帧。

## 4. 射频层要求对照

把所有**真正与 Apple 互通**的实现按其射频层获取方式排列：

| 实现 | 平台 | 射频层获取方式 | 额外前置 |
|------|------|----------------|----------|
| OWL + OpenDrop | Linux | nl80211 monitor mode + libpcap 注入 | root |
| ESP32Drop | ESP32-S3 | 芯片原生 promiscuous + raw TX | **独占射频** |
| airdrop-mt7921 | Linux | monitor vif 组合配置 | 特定芯片 + root |
| aviumui-wlan-tools | Android (Qualcomm) | **打补丁的内核驱动** + AF_PACKET 注入 | root + 重编驱动 + 固件重载 |
| chronosirius external_owl | Android | OWL 补丁进系统源码 | 系统级构建 |
| **Google Mosey** | Android | monitor 接口 + 私有驱动 ioctl + 厂商固件 `wondertap` | 特权系统应用 + 内核模块 + 七项签名级权限 + SELinux |

**规律：不存在任何"纯应用层"的 AirDrop 互通先例。** 连平台方 Google 都必须下沉到内核模块与 Wi-Fi 芯片固件，且被机型门控、被 OEM 主动禁用。

## 5. HarmonyOS 平台能力边界

| AirDrop 必需能力 | HarmonyOS 三方应用可得性 |
|------------------|--------------------------|
| 802.11 monitor mode + 帧注入 | 无。`wifiManager` 仅提供 STA、扫描、Wi-Fi Direct（P2P） |
| 原始包套接字 / 裸 802.11 帧 | 无。仅 UDP/TCP/WebSocket 等 IP 层能力 |
| AWDL 协议栈 | 无。开发指南与 API 参考中不存在 AWDL 相关接口 |
| Wi-Fi Aware / NAN | 文档中未见开放接口（仅有 Wi-Fi Direct） |
| TUN/TAP 虚拟网卡 | 无 |
| BLE 广播与扫描 | 有。`@kit.ConnectivityKit` 的 `ble` 能力，项目已用于 MTA |
| mDNS / DNS-SD | 无系统 API；当前实现使用自定义 UDP 组播，Rust 侧亦无 mDNS 依赖 |
| TLS HTTPS 服务端/客户端 | 有（Rust `hyper` + `rustls` + `tokio-rustls` + `reqwest`，项目已用于 MTA） |

关于 `ohos.permission.kernel.NET_RAW`：该权限**仅支持在 PC/2in1 设备上申请**，且需以二进制签名工具签名、运行时 `sudo` 提权生效，
用途是**网络抓包**（官方示例为 tcpdump）。它不提供 802.11 帧注入，也不是应用可用的常规权限，不能作为 AWDL 实现的依托。

## 6. HandySend 现有能力的可复用性

本项目当前技术栈与 AirDrop 业务层的重合度较高，但射频层为零。

| 层 | HandySend 现状 | 对 AirDrop 的可复用性 |
|----|----------------|----------------------|
| 业务层协议栈 | Rust `hyper` + `rustls` + `tokio-rustls` + `rcgen`（TLS 服务器、自签证书）、`reqwest`（HTTPS 客户端）、`tokio`、`socket2` | 高。HTTP 服务/客户端与 TLS 框架可直接复用 |
| 归档 | `flate2`、`zip` | 部分。cpio 与 DvZip 需新实现 |
| binary plist | 无依赖 | 需新建 |
| mDNS | 无（现用 UDP 组播 `224.0.0.167`） | 需新建 |
| BLE | `ble` 广播/扫描/GATT Server（MTA 在用） | 高。可用于 Apple 设备唤醒环节 |
| Wi-Fi Direct | `wifiManager` P2P 建组/入组（MTA 在用） | **不可用**。Apple 设备不参与 Wi-Fi Direct |
| 射频层 | 无 | **不可用**，且无接口可达 |

ESP32Drop 的实现天然分层，可作为业务层的规格参照：其 `airdrop/core/` 约 2,500 行是**无平台依赖、可主机端测试的整数 C**（DNS-SD、HTTP、binary
plist、cpio、DvZip、UTI 判定、zlib），覆盖发现报文构造、HTTP 事务编排与载荷编解码；而 TLS 终止、socket I/O 与整个 AWDL 层需按平台重写。

需要特别指出：**发现层是最不可移植的部分**。它同时依赖 AWDL 动作帧内的 service TLV 与裸 mDNS 组播，两者在移动 OS 上都不开放；即使业务层全部重写，缺少 AWDL 链路时 Apple 设备不会出现在候选列表中。

## 7. 可行路径与前置条件

三方应用层面无解。若要推进，只有以下路径，均超出应用权限范围：

1. **系统/厂商级定制**：由设备厂商在 Wi-Fi 驱动中暴露 monitor／raw 帧接口（对标 `wondertap` 与 `wonder0`），并预置一个持有
   `NET_ADMIN`/`NET_RAW` 的特权原生服务承载 AWDL 与 AirDrop 业务层。这需要芯片厂商配合，且需处理与系统 Wi-Fi 共存的冲突。
2. **等待平台开放**：HarmonyOS 开放 AWDL 或 Wi-Fi Aware/NAN 能力。无时间表；若走 NAN 路线，还需 Apple 侧同样以 NAN 承载。
3. **不做互通**：仅在自有协议范围内提供「类 AirDrop」体验，与 Apple 设备无互操作性。

## 8. 调研方法与来源

- **协议层**：精读 `seemoo-lab/owl`（C，AWDL 实现）与 `seemoo-lab/opendrop`（Python，业务层）全量源码。
- **最小实现规格**：精读 `s-iwaki-d/ESP32Drop` 源码与其 20 余个主机端测试。
- **官方方案**：逆向 `thelok1s/mosey-extended` 随包分发的 `mosey_server` 与 `libmosey_daemon_ffi.so`（ELF 字符串与符号）
  ；交叉参考 `leofungwai/oneplus13-mosey-research`（Qualcomm 机型实测笔记）、`DanielNappa/ring-around-the-mosey`。
- **反例排查**：核查 `seregonwar/AirWin` 的依赖声明与源码实现是否一致、能否构建、有无互通证据。
- **平台能力**：以 `devecocli docs` 检索 HarmonyOS 开发指南与 API 参考（WLAN／P2P／权限／Connectivity Kit）。
- **检索范围**：GitHub 仓库搜索（约 60 组关键词，含中英文鸿蒙相关词）与项目元数据核查。

## 9. 未决问题

1. **Mosey 究竟走 AWDL 还是 Wi-Fi Aware(NAN)**。其 daemon 内的 TLV 字段名强烈指向 AWDL，但二进制中无 `awdl` 字面量，亦无空口抓包证据。
   实测笔记对此明确标注为 inconclusive，并声明「NAN 不等于 AWDL」。若最终证实走 NAN，需重新评估第 7 节路径 2 的前提。
2. **Mosey 的内核模块本身缺失**（社区模块未附带源码），故「驱动最低暴露面」只能由用户态二进制反推，第 3.3 节的驱动通道描述属推断而非源码验证。
3. **社区文档可信度有限**。以 `mosey-extended` 为例，其 README 存在 Binder 服务名写错、厂商子命令表与二进制不符、机型支持矩阵自相矛盾等问题。本章结论均以随包二进制与源码为准，不采信其文档声称。
4. **GitHub 检索存在固有局限**：结果受搜索索引与关键词覆盖影响，且加密货币领域的同名 "airdrop" 噪声极多；本轮已过滤，但不排除存在未被索引的实现。
