# MTA BLE 平台能力真机验证报告（P0-2）

> 验证日期：2026-09-10
> 验证设备：HandySend 侧 nova 15 Pro（HarmonyOS，API 24）+ 对端安卓设备（安装 CatShare，设备名 `m20`）
> 验证工具：HandySend「MTA BLE 验证」调试页（`entry/src/main/ets/pages/MtaBleVerifyPage.ets`）、CatShare（MTA 双端对打）
> 对应验证项：MTA_IMPLEMENTATION_PLAN.md §4.2 / Phase 0（P0-2）

## 0. 验证设备信息

| 项 | 值 |
|----|----|
| HandySend 机型 / HarmonyOS 版本 | nova 15 Pro / API 24 |
| CatShare 机型 / 安卓版本 / CatShare 版本 | 安卓设备（CatShare 设备名 `m20`；机型/版本待补充） |
| nRF Connect 版本（如使用） | 未使用（本次以 CatShare 直接对打验证，nRF Connect 留作后续核对字节） |
| 验证日期 | 2026-09-10 |

## 1. 结论摘要

| 验证项 | 对应 SC | 结论 | 状态 |
|--------|---------|------|------|
| CatShare 发送流程可发现 HandySend（主广播 + 扫描响应） | SC-001 | 修复广播 service UUID 基址后，CatShare 设备列表可发现 HandySend | ✅ |
| nRF Connect 核对广播字节与 MTA 协议格式一致 | SC-001 | 本次未用 nRF Connect；广播构造字节与协议逐字节一致（见 §2.1） | 🟡 字节预览核对 |
| CatShare 连接 GATT Server 读 CHAR_STATUS 返回合法 DeviceInfo | SC-002 | CatShare 连接后读走 DeviceInfo（真实 ECDH 公钥），并据此加密回写 P2pInfo | ✅ |
| CatShare 向 CHAR_P2P 长写（prepared write）被完整还原 | SC-003 | P2pInfo 256 字节单包写入被完整还原；**prepared write 分片路径本次未触发** | 🟡 部分 |
| HandySend 扫描发现 CatShare（接收模式）并正确解析字段 | SC-004 | 发现 `m20`，senderId=`0943`（与 P2pInfo id 交叉一致）、品牌=第三方、5GHz=true | ✅ |
| HandySend 作为 GATT Client 读取 CatShare 的 DeviceInfo | SC-005 | 连接成功并读回 CatShare DeviceInfo（公钥与 §2.2 一致） | ✅ |
| 蓝牙关闭 / 权限拒绝时操作失败提示且不崩溃 | 边缘场景 | 待补充（本次未专项测试） | ⏳ |
| 设备名超长时按协议截断/填充仍能广播 | 边缘场景 | 待补充（本次设备名 `HandySend` 未超长） | ⏳ |
| 广播与 GATT Server 同时运行（接收端要求并存） | 边缘场景 | 本次广播与 GATT Server 同时在线，CatShare 可发现并连接 | ✅ |
| 页面退出后无 BLE 资源残留，再次进入可正常使用 | SC-006 | 待补充（本次未专项测试） | ⏳ |

**总体结论：MTA BLE 层与真实 CatShare 双向互通成立。** 接收端（广播 + GATT Server）与发送端（扫描 + GATT Client）四条链路均实测通过，P0-2 核心风险项（广播格式、GATT 凭据交换、设备发现、GATT Client 读取）全部解除。

## 2. 验证项与操作步骤

### 2.1 SC-001：CatShare 发现 HandySend 广播

**HandySend 侧**

1. 进入「排查页 → MTA BLE 验证」
2. 确认蓝牙已开启、`ACCESS_BLUETOOTH` 已授予
3. 输入设备名（`HandySend`，≤15 字节 UTF-8），点击「启动广播」

**CatShare 侧**

1. 安卓设备安装并打开 CatShare，进入「发送」流程
2. 在设备列表中查找 HandySend 设备名 → 可发现

**实测数据**

```
广播: 启动成功 设备名=HandySend
主广播(6B): 18 61 00 00 00 00
扫描响应(27B): 00 00 00 00 00 00 00 00 18 61 48 61 6e 64 79 53 65 6e 64 09 09 09 09 09 09 09 01
```

- 主广播：serviceUuid `00003331-0000-1000-8000-008123456789` + 6 字节 serviceData `000001ff-...`（2B 发送者 ID `18 61` + 4B 零）
- 扫描响应：27 字节 serviceData `0000ffff-...`（[0-7] 零填充、[8-9] 发送者 ID `18 61`、[10-25] 设备名 `HandySend` + `\t` 填充、[26]=0x01）
- 广播字节与 MTA 协议逐字节一致；主广播含 128 位 service UUID（非标准基址不可压缩）后总长 31 字节，正好在上限内

**⚠️ 根因修复记录**：首次实测 CatShare 无法发现 HandySend。定位为广播主 service UUID 基址错误——实现误用标准蓝牙基址 `00003331-0000-1000-8000-00805f9b34fb`，而 MTA 协议（CatShare `BleUtils.ADV_SERVICE_UUID`、OPPOShareReceiver `MtaConstants.ADV_SERVICE_UUID`）为**非标准基址 `00003331-0000-1000-8000-008123456789`**。CatShare 的 `ScanFilter.setServiceUuid(ParcelUuid(ADV_SERVICE_UUID))` 因此匹配不上。修正后 CatShare 立即可发现。该值同时是 HandySend 扫描 CatShare 的过滤条件（US3）。

### 2.2 SC-002 / SC-003：CatShare 连接 GATT Server 读写

**HandySend 侧**

1. 点击「启动 GATT Server」，记录页面展示的 ECDH 公钥（Base64）与 DeviceInfo JSON
2. 保持广播运行（验证并存）

**CatShare 侧**

1. 选中 HandySend → 发起 GATT 连接
2. 读取 CHAR_STATUS（`00009954-...`）
3. 用读到的公钥 ECDH 加密凭据，向 CHAR_P2P（`00009953-...`）写入 P2pInfo

**实测数据**

```
GATT Server: 启动成功，DeviceInfo={"state":0,"mac":"02:00:00:00:00:00","key":"MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE+gkh0wSrLjMa271Q6uEG47aO4UN+oY6jtnPhiB6M0ehB/bxq24G3sJQvw0u2SNyC3Sn5c0vJQ8vp1UPxyWRjjQ==","catShare":7}
GATT Server: 客户端 4E:67:01:6C:18:55 已连接
GATT Server: 读请求来自 4E:67:01:6C:18:55 offset=0
[bluetooth_service] GATTS_SendRsp: conn_id=0x0008, trans_id=0x00000001, status=0000
GATT Server: 写入分片 4E:67:01:6C:18:55 offset=0 total=256 prepared=false
GATT Server: 完整接收来自 4E:67:01:6C:18:55 (256 字符):
{"id":"0943","ssid":"wjpsBqUHRw0hjX6/n4qs","psk":"/EpXNadiAR4=","mac":"tEEEJ9ZpU2F48QTQzPvXsoM=","port":38303,"key":"MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAETDlnoI6AZk6uvOERtv+74whLaewZ3woH1f7s2RbITBqeBSnnq7uE4Aods893gjYhPbsFJMhd+7Jns09Uj+Alsw==","catShare":7}
GATT Server: 客户端 4E:67:01:6C:18:55 已断开
```

- CHAR_STATUS 读返回的 DeviceInfo 四个字段齐全，`key` 为合法 X.509 SPKI DER Base64（P-256，91 字节）
- CatShare 读走 DeviceInfo 后，用其公钥 ECDH 加密 `ssid`/`psk`/`mac` 并回写 P2pInfo（`port`/`id`/`key`/`catShare` 明文）→ 证明我方公钥格式被真实 MTA 实现接受
- 写入 256 字节，MTU 协商后单包发完（`prepared=false`），完整还原 100% 一致
- 写入后 CatShare 主动断开（`GATT_CONN_TERMINATE_PEER_USER`），转去连接 WiFi P2P 组（HandySend 未提供 P2P，符合预期）

**⚠️ 遗留**：本次未触发 `prepared write`（`isPrepared=true`）分片路径，因 CatShare 的 P2pInfo 在 MTU 协商后单包可发。SC-003 的「≥512 字节分片写入」需用 nRF Connect 手工构造分片写验证。

### 2.3 SC-004：HandySend 扫描发现 CatShare

1. 安卓 CatShare 进入「接收」模式（发出 MTA 格式广播）
2. HandySend 点击「启动扫描」

**实测数据**

```
扫描: 已启动扫描
扫描: 发现 m20 id=E8:31:38:5B:14:30 rssi=-33 senderId=0943 brand=第三方 5GHz=true
（同一设备持续上报，RSSI -18 ~ -35）
```

- 设备名 `m20`、品牌 `第三方`（FF）、5GHz=true、RSSI 稳定
- **交叉验证**：senderId `0943` 与 §2.2 中 CatShare 写入的 P2pInfo `"id":"0943"` 完全吻合
- serviceUuid 过滤生效：列表中仅出现 MTA 设备

**⚠️ 观察项（非阻塞）**：扫描回调每次 RSSI 抖动都触发一次日志（30 秒内约 161 条），日志区会刷屏。建议后续按设备去重/限流（如仅首次发现或 RSSI 变化超过阈值时记录）。

### 2.4 SC-005：HandySend 作为 GATT Client 读取 DeviceInfo

1. 在扫描列表点击 CatShare 设备项，自动填入 GATT Client 目标设备
2. 点击「连接」，等待状态「已连接」
3. 点击「读取 DeviceInfo」

**实测数据**

```
GATT Client: 目标设备已设为 E8:31:38:5B:14:30
GATT Client: 已发起连接 E8:31:38:5B:14:30
GATT Client: 连接状态: 连接中
GATT Client: 连接状态: 已连接
GATT Client: 读取成功: {"state":0,"key":"MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAETDlnoI6AZk6uvOERtv+74whLaewZ3woH1f7s2RbITBqeBSnnq7uE4Aods893gjYhPbsFJMhd+7Jns09Uj+Alsw==","mac":"22:d0:98:12:82:08","catShare":7}
```

- HandySend 作 GATT Client 成功连接 CatShare 的 GATT Server 并读回其 DeviceInfo
- **交叉验证**：读到的 `key` 与 §2.2 中 CatShare 加密凭据所用公钥完全一致

### 2.5 边缘场景

| 场景 | 操作 | 预期 | 实测 |
|------|------|------|------|
| 蓝牙关闭 | 关闭蓝牙后点击「启动广播」/「启动扫描」 | 日志显示明确失败原因，无崩溃 | 待补充 |
| 权限拒绝 | 拒绝 `ACCESS_BLUETOOTH` 后执行 BLE 操作 | 日志显示权限相关失败原因，无崩溃 | 待补充 |
| 设备名超长 | 输入 >15 字节设备名后启动广播 | 按协议截断/填充，广播仍成功 | 待补充 |
| 广播 + GATT 并存 | 同时启动广播与 GATT Server | 二者均可运行，CatShare 可发现并连接 | ✅ 实测通过 |
| 扫描 + 广播并存 | 同时启动扫描与广播 | 无冲突或记录冲突现象 | 待补充 |
| 资源清理 | 点击「一键清理」/退出页面后再次进入 | 无资源残留，可重复使用 | 待补充 |

## 3. 权限实测结论

| 权限 | 结论 |
|------|------|
| `ohos.permission.ACCESS_BLUETOOTH` | 运行时申请弹窗授权后，广播 / 扫描 / GATT Server / GATT Client 均可用 |
| 定位权限 | 本次未申请，BLE 扫描（`startBLEScan`）在无定位权限下正常上报设备 |

## 4. 待观察记录（Open Questions）

| 项 | 说明 | 实测 |
|----|------|------|
| DeviceInfo.key 校验 | CatShare 是否要求 `key` 有效才会继续写入 P2pInfo | 是——CatShare 读到我方 `key` 后立即用它加密凭据并回写 P2pInfo |
| GATT Client 配对 | 连接 CatShare 是否需要配对/绑定 | 不需要，直接连接成功 |
| CatShare 广播可连接标志 | 其接收模式广播是否可连接（GATT Client 连接前置） | 是，HandySend 作为 GATT Client 成功连接 |
| prepared write 行为 | offset 乱序/重复写入时的实际行为 | 本次未触发（单包 256 字节），待 nRF Connect 构造分片验证 |
| P2pInfo 加密内容 | 收到加密的 ssid/psk 仅原样记录，不解密（超出本次范围） | 已记录加密 Base64 原文，未解密 |

## 5. 遗留验证项

| 项 | 说明 |
|----|------|
| prepared write 分片（SC-003） | 用 nRF Connect 手工向 CHAR_P2P 分片写入 ≥512 字节，验证 offset 累积与 `{}` 容错提取 |
| 边缘场景（蓝牙关闭/权限拒绝/设备名超长/扫描+广播并存/资源清理） | 本次未专项测试，待补测 |
| 扫描日志限流 | 按设备去重/阈值记录，避免 RSSI 抖动刷屏 |
| P2P / WS / HTTPS 传输编排 | 超出 P0-2 BLE 层范围，另行开展 |
| 凭据加解密（ECDH + AES-CTR） | 正式实现由 Rust 层承担，验证页不实现 |
| 真实厂商设备（小米/OPPO/vivo）互通 | 需厂商真机，P2 阶段开展 |
