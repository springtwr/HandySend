# EasyShare 实现研究报告

> 研究对象：`/home/springtwr/Develop/DevEcoStudioProjects/Sample/EasyShare`（本地源码，含完整 git 历史）。
> 研究方法：源码逐行阅读 + git 考古（上游 CatShare 历史、EasyShare 重构 PR、两个未合并修复分支）+ 与 [MTA_INTEGRATION_RESEARCH.md](MTA_INTEGRATION_RESEARCH.md)（基于 OPPOShareReceiver / CatShare 逆向）对比。
> 核心结论：**EasyShare 相对 CatShare 的更改以"跨品牌互通兼容"为主线**——广播层品牌伪装、协议层厂商行为差异适配、WiFi Direct 层 OEM 差异处理；另有一块独立的安全增强（v2/v3 加密）仅作用于 EasyShare↔EasyShare 对等场景，与厂商互通无关。

## 1. 项目定位与历史脉络

| 阶段 | 时间 | 内容 |
|---|---|---|
| CatShare 上游开发 | 2024-12 ~ 2025-02 | kmod-midori 原作者实现 MTA 双端；期间产出一批**品牌兼容修复**（vivo 系列最关键，见 §2.2） |
| 社区维护期 | 2025-05 ~ 2025-08 | LOCAL_MAC_ADDRESS 支持、快 tile 接收修复、自动接收、大文件修复 |
| EasyShare 重构 | 2026-08（PR #9/#11/#12，agent 生成） | 全面重构：**品牌伪装系统化**（品牌注册表 + 自动检测 + 手选 + 广播真实品牌）、Samsung 频段兼容、status 语义矩阵化、传输加固、v2 加密 |
| 未合并修复分支 | 2026-09（`claude/code-review-pr-issues-wedeb8`） | d5ff667：会话服务器暴露面收敛、超时对齐（含"厂商接收端确认弹窗 30s"的适配）；80c18ce：BLE 密钥轮换、crypto v3、GATT 长写与分帧缓冲分离 |

注意：vivo 修复等品牌兼容知识是**上游 CatShare 的积累**，EasyShare 继承后将其系统化（品牌注册表、单测钉死、矩阵化状态语义）。

## 2. 品牌兼容主线

### 2.1 广播发现层：品牌 ID 伪装

MTA 协议把品牌 ID 编码在主广播 serviceData UUID 的字节里（`000001xx`，`arr[2]`=5GHz 标志、`arr[3]`=品牌）。厂商发送端解析该字节决定设备列表里的品牌图标/分组，**部分厂商对未知品牌值可能不显示或降低优先级**。

| 项 | CatShare 原版 | EasyShare |
|---|---|---|
| 广播品牌字节 | 固定 `0xFF`（第三方） | **本机真实品牌**：自动检测 `Build.BRAND/MANUFACTURER/MODEL`，支持手动选择；检测失败为 0 |
| 品牌注册表 | 少量 | 扩充至 20+ 品牌（见下），每品牌配图标 |
| 字节→ID 转换 | 直接用有符号 Byte | `bleByteToBrandId` 无符号化 + 冲突处理 |

品牌注册表（比 MTA 报告 §3.3 的映射表大）：Pixel 130-139、Honor 140-149、Motorola 110-119、NIO 120-129、ASUS 161-169（160=ROG）、Hisense 170-179、Nubia 60-69（66=RedMagic）、ZTE 80-89、Smartisan 90-95、Black Shark 32；另注释了 800-802（ColorOS 系的 iPhone/iPad/Mac"果子互传"ID）与"OPPO 车机 200"。

**vivo 兼容修复（上游 5904241，关键）**：CatShare 早期广播 UUID 用 `0000011e`/`00000204`（从某厂商抓包而来），**vivo 扫描端不识别**，发送列表里看不到设备。修复为 `000001ff`/`0000ffff` 后 vivo 正常发现。即：**这两个 UUID 字节不是随便填的，vivo 等厂商扫描端对其有识别/白名单逻辑**。

其他广播层细节：

- **senderId 无符号解析（#7 号 issue 的根因之一）**：扫描响应 `[8-9]` 的 senderId 早期用有符号 `data[8].toInt().shl(8)`，首字节 ≥0x80 时符号扩展算错 ID → 不同设备被判成同一台、设备列表互相踩踏。修复为无符号 `(high and 0xff) shl 8 or (low and 0xff)`，并配套单测钉死（`80ff` 案例）。
- **设备名字段精确定义**：名字区 `[10-25]` 共 16 字节，≤16 字节原样放入右侧补零，**>16 字节截到 15 字节 + `\t` 作截断标记**；扫描端以首个 `0x00` 为终止符，末尾 `\t` 渲染为 `...`。UTF-8 截断按 codepoint 回退，不会产生非法字节序列（厂商解码失败会丢弃设备）。此为对 MTA 报告 §3.3"≤15 字节"的修正。
- **设备名取值（DeviceName.get()）**：依次读 `ro.product.marketname` / `ro.product.odm.marketname` / `ro.vendor.oplus.market.name` / `ro.vivo.market.name` / `ro.oppo.market.enname` 等**厂商私有系统属性**取"市场名"，兜底蓝牙默认名/代号/品牌+型号。目的：广播出去的设备名与该厂商系统互传里显示的习惯名称一致（如 OPPO 市场名而非 `Build.MODEL`）。默认名 `Android`。
- **5GHz 标志**：厂商设备在 `arr[2]` 广播真实 5GHz 能力；未合并分支 d5ff667 进一步要求接收端广播**本机真实** 5GHz 支持而非硬编码。
- `senderBrand`/`senderBrandId` 塞进 sendRequest 元数据（三方扩展，厂商接收端忽略），接收端兼容读取（缺 `senderBrand` 时从 `senderBrandId` 推导）。

### 2.2 WS/GATT 协议层：vivo 行为差异修复（上游积累）

CatShare 上游的 vivo 修复系列是整个品牌兼容知识库的核心，EasyShare 全部继承：

| 修复（提交） | 内容 | 原因 |
|---|---|---|
| 5904241 Fix vivo send | 广播 UUID 改 `000001ff`/`0000ffff`；**P2pInfo.`id` 必填** | vivo 发送端要求 P2pInfo 带 id 字段 |
| 7bd4404 Fix vivo send 2 | **status 消息 id 必须为 99**；reason 用 `""`（后定为 `"ok"`）；versionNegotiation payload 缺 `version` 字段时**默认按 1** | vivo 发送端按消息 id 识别/匹配 status |
| fdcb608 Send ACK for action messages | **发送端必须对接收端的 action 消息（如 status）回 ack**（`ack:<原id>:<name>`） | 部分厂商接收端等待 ack 才收尾 |
| 4f1f233 Do not close WS before everything is done | 发送端在传输全链路完成前不主动关 WS | 厂商接收端在 ack 后仍会继续使用连接 |
| d486ac1 Fix key missing | P2pInfo.`key` 默认 null（JSON 序列化可省略） | 对端明文模式（无 ECDH 公钥）解析失败 |

EasyShare 在此基础上把 status 语义**矩阵化**（`TransferStatusProtocol`）：

| type | reason | 语义 |
|---|---|---|
| 1 | `ok` | 全部成功 |
| 1 | `partial` | 部分成功（收到的文件数 < 声明数） |
| 3 | `user refuse` | 用户拒绝 |
| 3 | `timeout` | 接收端确认超时 |

status 消息 payload 同时带 `taskId` 与 `id`，消息 id 固定 99（CatShare 惯例；OPPO 接收端从 100 递增，两种均能被发送端容忍）。WS 消息格式、versionNegotiation（`{"version":1,"versions":[1]}` → ack `{"version":min(n,1),"threadLimit":5}`）、sendRequest 字段与 MTA 报告 §3.6 完全一致。

GATT 层品牌兼容点：发送端连接后先 `requestMtu(512)` 再发现服务（P2pInfo JSON 可能超默认 MTU 23）；接收端同时支持三条写入路径——prepared write（`isPrepared` 按 offset 累积 + executeWrite）、单次整写、EasyShare 自家 ESP 分帧（见 §4）——以兼容不同厂商 GATT 栈的写行为；JSON 解析容忍未知字段（`JsonWithUnknownKeys`，厂商/三方新增字段不致解析失败）；写缓冲上限 4096B、超限拒绝。

### 2.3 WiFi Direct 层：OEM 行为差异

**按目标品牌选频段（发送端建组）**：

- 目标广播 5GHz 支持 && **非 Samsung** → `GROUP_OWNER_BAND_AUTO`（可上 5GHz，速率高）；
- 目标不支持 5GHz **或目标是 Samsung** → 强制 `GROUP_OWNER_BAND_2GHZ`。

`requiresTwoGhzP2pCompatibility` 仅对 Samsung 生效，配套单测钉死（`samsungPeersUseTheCompatibilityP2pBand`：70/75 为真、76/null 为假）。即 **Samsung 的 Wi-Fi Direct 在 AUTO/5GHz 频段下与三方建组互通有已知问题**。

**按本机 OEM 处理建组/路由时序**（Android 系统层差异，同样是"不同品牌手机"）：

| OEM/版本 | 问题 | 处理 |
|---|---|---|
| Pixel | 首次 `createGroup` 可能初始化 p2p 接口但失败 | **最多重试 10 次**（每次等组信息 5s、间隔 1s）；每次失败后先查 `requestGroupInfo`，组已出现则直接采用 |
| Pixel | `removeGroup` 报成功但接口/tethering 未拆完 | 移组后固定等 **1s settle** 再建新组 |
| Samsung One UI / Android 16 | P2P 路由已装但不暴露 `ConnectivityManager` Network | 等 **500ms settle** 后走系统默认路由 |
| API 37+（Android 16+） | 需显式路由 | 按 p2p 接口名（`p2p-p2p0-x`）注册 NetworkCallback 拿 `Network.socketFactory` 绑定 socket |
| Android 17 | 前台通知原位替换保留 stale ongoing 标志 | 先 `stopForeground(REMOVE)` + cancel 再 notify |

接收端连接方式：标准 `WifiP2pConfig.setNetworkName(ssid).setPassphrase(psk)` + `connect()`（CatShare 方式），等 `CONNECTION_CHANGED` 且 `groupFormed && !isGroupOwner` 后取 `groupOwnerAddress`。SSID `DIRECT-`+8 位随机字母数字、PSK 8 位、`enablePersistentMode(false)`，与 MTA 报告 §3.8 一致。

**发送端超时与厂商接收端节奏对齐**（未合并 d5ff667 明确点出）：厂商接收端的用户确认弹窗约 **30s**（加服务层 31s 上限），因此发送端"等待下载开始"的超时必须大于该值（EasyShare 由 30s 调至 45s，未合并）；WS 连接等待由 10s 调至 20s（未合并）；接收端 OkHttp 读超时对齐发送端 120s stall 看门狗。

**发送端会话服务器暴露面**（未合并 d5ff667）：Ktor 服务器绑定所有接口，同一普通 WiFi 网络内的设备也能先到 `/websocket`、`/download` claim 传输——对**无 token 的联盟对端**这会直接抢走会话。修复方向：只服务来自 Wi-Fi Direct 组（GO 地址）的对端。这是"安全加固"与"互通正确性"的交叉点。

### 2.4 MAC 认证因子

互传联盟协议把设备 MAC 作为认证信息的一部分（CatShare README 明示无法完全绕过；实测 OPPO 发送端对接收失败敏感，小米/vivo 宽松）。EasyShare 的处理：

- **发送端 `P2pInfo.mac`（本机 p2p0 MAC）**：优先 Shizuku 特权服务读 `NetworkInterface("p2p0")`；系统应用可走 `LOCAL_MAC_ADDRESS` 权限（900d16e）；兜底 `02:00:00:00:00:00`。接口名必须固定 `p2p0`——早期用 `groupInfo.interface`（动态名 `p2p-p2p0-x`）读不到（acc0610）。
- **接收端 `DeviceInfo.mac`**：同样 Shizuku 读取，兜底 `02:00:00:00:00:00`。
- MAC 拿不到时的兜底值意味着**部分严格校验厂商（OPPO）会拒绝**，这是三方应用的结构性限制，不是实现 bug。

对应鸿蒙侧：HandySend 发送端已有正解 `getCurrentGroup().ownerInfo.deviceAddress`（见 MTA 报告 §7.1），不需要 Shizuku 等价物。

### 2.5 接收端确认流程与厂商节奏

接收端用户确认超时 **31s**（略长于厂商发送端等待窗口），确认前不开始下载；确认/拒绝/超时分别回 status `type=1 reason=ok` / `type=3 reason=user refuse` / `type=3 reason=timeout`。厂商发送端等待窗口（30s 左右）与之匹配。

## 3. 与 MTA 报告一致的部分（第三次印证）✅

以下结论与 MTA 报告完全一致，经第三个独立实现印证，可信度进一步上升：

- **协议常量**：`00003331` 广播 UUID、`00009955` GATT 服务、`00009954`/`00009953` 特征、`/websocket`、`/download?taskId=`、`threadLimit:5`。
- **广播格式**：主广播 `[2B senderId][4B 零]`；扫描响应 27 字节布局；legacy/可连接/可扫描/interval 160。
- **加密（legacy 路径）**：ECDH P-256、SPKI+Base64、AES-256-CTR/NoPadding、**固定 IV `"0102030405060708"` 16 字节 ASCII**（第三次印证 MTA 报告 §6.2 的 IV 修正）、仅加密 `ssid`/`psk`/`mac`、`key` 缺失按明文。
- **密钥派生（legacy）**：`generateSecret("TlsPremasterSecret")`（CatShare 同款；OPPO 用裸 `generateSecret()`，两运行结果一致）。
- **ZIP 流**：`{序号}/{文件名}`、文本 `0/sharedText.txt`（线上 key 保持 `catShareText` 以兼容厂商，接收端兼容读 `easyShareText`）。
- **TLS**：临时自签证书（domains 127.0.0.1/0.0.0.0/localhost）；联盟对端信任所有证书 + hostname 恒真。
- **`catShare` 线上 key**：承载版本号（EasyShare 填 `BuildConfig.VERSION_CODE`），`ProtocolCompatibilityTest` 单测钉死不许漂移。
- 发送端收到 status type=1 后 `delay(1s)` 清理；WS 消息正则；消息 id 发送方从 0 递增。

## 4. EasyShare 私有安全扩展（v2/v3，非品牌互通）🔒

通过 `catShareCrypto` 字段协商，**仅对端同为 EasyShare 时启用**，厂商设备不参与，对互通无影响（解析需容忍）：

| 新字段 | 用途 |
|---|---|
| `catShareCrypto` | 加密协议版本（≥2 现代；未合并分支引入 v3：token/cert 也加密传输） |
| `catShareToken` | 32 字节随机令牌，WS/下载 URL `?token=` 校验（恒时比较 + 一次性 claim） |
| `catShareCert` | 发送端自签证书 SHA-256，接收端 TrustManager + hostnameVerifier 双重锁定；联盟对端无此字段 → 回落信任所有证书 |

- v2 加密：ECDH 裸 secret 经 HKDF-SHA256（salt `"Easy Share BLE v2"`、info `"P2P metadata AES-GCM"`）派生密钥，`ssid`/`psk`/`mac` 改 AES-256-GCM（12B 随机 nonce、字段名作 AAD、`Base64(nonce‖ct‖tag)`）。
- GATT ESP 分帧（magic `ESP\x01` + totalSize + offset，帧 ≤480B、总 ≤4096B，多次普通写）：因 v2 的 P2pInfo JSON 含 token+cert 超过单帧上限而引入；对 legacy 对端不启用（单次整写）。未合并分支让长写缓冲与分帧缓冲分离，经分帧解析器路由。
- `secureReceiveOnly` / 未合并的"send only to secure devices" 设置：可限制仅与 v2+ 对端交互。
- 未合并 80c18ce：每会话轮换 EC 密钥（防广播 key 追踪设备）、证书改 RSA-2048 签名。

这些是 EasyShare↔EasyShare 的对等安全增强；其"检测对端能力 → 协商升级 → 失败回落 legacy"的双轨设计可作为 HandySend 后续安全增强的范本，但不影响与厂商互通的主线。

## 5. 传输健壮性（非品牌维度）

- **发送端超时/看门狗**：WS 连接 10s（未合并调 20s）、握手 5s、下载开始 30s（未合并调 45s，对齐厂商 30s 确认弹窗）、status 确认 30s、**120s stall 看门狗**（1s 轮询最后活动时间）。
- **接收端限额**：文件数 ≤10 000、任务总量 ≤20GiB、单 entry ≤10GiB、文本 ≤2MiB、实际字节上限 `声明值+max(1MiB,1%)`、存储预留 256MiB（传输中每 16MiB 复查）。
- **ZIP 防护**：拒绝绝对路径/盘符/`..`，只取最后一段文件名；Android 14+ 装 `ZipPathValidator`；网络 IO 中断但已有完整文件 → 保留并报 `partial`，否则全量回滚。
- **落盘**：MediaStore `Downloads/Easy Share` + `IS_PENDING` 两阶段发布，或 SAF 自定义目录。
- 单一 busy 互斥 + 任务级取消；发送端不预压缩媒体文件（已压缩格式 deflate 无收益，未合并）。

## 6. 对 HandySend 的映射与行动建议

现状核对结果（`entry/src/main/ets/service/mta/`、`localsend_ohrs/rust/bridge/mta/`）：

| 品牌兼容点 | EasyShare 做法 | HandySend 现状 | 建议 |
|---|---|---|---|
| 广播 serviceData UUID | `000001ff`/`0000ffff`（vivo 识别） | `MtaConstants.ADV_DATA_UUID = 000001ff` ✅ | 无需改 |
| 广播品牌字节 | 本机真实品牌（伪装） | 固定 `0xff` 第三方（`BRAND_ID_THIRD_PARTY`） | 华为非联盟成员，保持 `0xff` 合理；真机验证若某厂商列表不显示本机，可考虑增加手选品牌 |
| status 消息 id=99、reason `ok`/`user refuse` | vivo 修复 | `STATUS_MESSAGE_ID=99`、reason 常量一致 ✅ | 无需改 |
| P2pInfo.`id` 必填 | vivo 修复 | `info.id = senderIdHex` ✅ | 无需改 |
| versionNegotiation 缺 version 默认 1 | vivo 修复 | Rust 构造固定 `version:1` ✅ | 接收侧解析（`MtaTransferClient`）确认缺字段时按 1 |
| **发送端对对端 action 消息回 ack** | fdcb608：必须回 `ack:<id>:<name>` | Rust `ws.rs` 对任意 action 消息回送 `ack:<原id>:<原name>` ✅ | 无需改 |
| **Samsung 目标强制 2.4GHz** | `requiresTwoGhzP2pCompatibility` | `MtaSendService` 建组前按 `brandId ∈ [70,75]` 强制 `GROUP_OWNER_BAND_2GHZ` ✅ | 无需改 |
| 发送端不提前关 WS | 4f1f233 | `ws.rs` 注释"收到 status 后不抢先关闭"+ 2s 宽限 ✅ | 无需改 |
| 等下载开始超时 > 厂商确认弹窗 30s | 45s（未合并） | `STATUS_WAIT_TIMEOUT=180s` 笼统覆盖 | 现值可覆盖；若细化分阶段超时，注意该约束 |
| 会话服务器暴露面 | 只服务 P2P 组内对端（未合并） | Rust server bind `0.0.0.0` 随机端口 ❌ | **建议评估**：同一 WiFi 内任意设备可先 claim `/websocket`、`/download`；可校验对端地址或绑定 P2P 网络句柄 |
| senderId 无符号解析 | `and 0xff` | `bytesToHex(Uint8Array.slice(8,10))`，Uint8Array 天然无符号 ✅ | 无需改 |
| JSON 容忍未知字段 | `JsonWithUnknownKeys` | 需核对 ArkTS 侧 DeviceInfo/P2pInfo/sendRequest 解析 | **需确认**：厂商或三方新增字段（`catShareCrypto` 等）不应导致解析失败 |
| GATT 长写 prepared write | `isPrepared` 累积 + executeWrite | `MtaBleReceiver` 已按 `isPrepared` 累积 ✅（MTA 报告 §7.5） | 无需改；ESP 分帧为三方私有可不实现 |
| 设备名市场名 | 厂商私有 prop | 鸿蒙无对应机制 | 用系统设备名（现状）即可 |
| legacy 密钥派生 | `TlsPremasterSecret` | `agreement.generateSecret()`（OPPO 同款，两路径实测一致） | 维持；真机 P2 验证重点 |
| AES-CTR 固定 IV 16 字节 | 16 字节 ASCII | `AES_IV_TEXT` 16 字节 ✅ | 无需改 |
| 建组重试/settle（鸿蒙等价） | Pixel 10 次重试 + 1s settle | `MtaP2pGroup` 单次建组 | 可借鉴重试；鸿蒙 P2P 栈行为需实测后再定 |
| MAC（发送端 p2p0） | Shizuku/LOCAL_MAC_ADDRESS | `getCurrentGroup().ownerInfo.deviceAddress`（实测正解） | 维持 |

## 7. 结论

1. **品牌兼容是 EasyShare 更改的主线**，分布在四层：广播层（品牌 ID 伪装 + vivo UUID 修复 + 无符号化 + 市场名）、协议层（vivo 的 status id=99 / P2pInfo.id / version 默认值 / ACK / WS 关闭时序）、WiFi Direct 层（Samsung 2.4GHz + Pixel/One UI 时序兼容 + 厂商确认弹窗节奏对齐）、认证层（MAC 因子）。其知识源头是上游 CatShare 在真机踩坑后积累的修复，EasyShare 将其系统化（注册表、单测、状态矩阵）。
2. **v2/v3 安全扩展是独立的一块**，仅作用于 EasyShare 自家对等场景，靠"协商升级、失败回落 legacy"保证不伤互通。
3. **联盟兼容路径第三次印证**：legacy 实现与 OPPOShareReceiver / CatShare 逐项一致（IV 16 字节、status id=99、`catShare` key 等）。
4. **HandySend 剩余落差集中在会话服务器暴露面收敛**：Rust 服务器 bind `0.0.0.0` 随机端口，同一 WiFi 内任意设备可先 claim `/websocket`、`/download`；另有 JSON 容错解析需核对。发送端对 action 消息回 ack、Samsung 目标强制 2.4GHz 两处已与 EasyShare 对齐，其余品牌兼容点 HandySend 已对齐。

## 8. 参考资料

- EasyShare 本地源码（`Sample/EasyShare`，MIT，基于 CatShare 重构；含 git 全历史与未合并分支 `claude/code-review-pr-issues-wedeb8`）
- 上游 CatShare 提交：5904241 / 7bd4404（vivo 修复）、99f0f24（sender ID）、fdcb608（ACK）、4f1f233（WS 时序）、acc0610（p2p0 接口名）、900d16e（LOCAL_MAC_ADDRESS）
- [MTA_INTEGRATION_RESEARCH.md](MTA_INTEGRATION_RESEARCH.md)（OPPOShareReceiver / CatShare 逆向主报告）
- HandySend 现有实现：`entry/src/main/ets/service/mta/`、`localsend_ohrs/rust/bridge/mta/`
