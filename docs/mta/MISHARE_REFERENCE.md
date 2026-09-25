# 小米互传（MiShare）实现逆向参考

> 从 Redmi 上的小米互传连接服务 APK（包名 `com.miui.mishare.connectivity`，协议实现与
> 运行进程同名）逆向整理出的 MTA 协议实现细节，用于校正 HandySend 的兼容性判断。
> 获取方式见 §0；协议全貌见
> [MTA_PROTOCOL_AND_IMPLEMENTATION.md](MTA_PROTOCOL_AND_IMPLEMENTATION.md)。

## 0. 获取与复现

协议实现（BLE / WS / P2P）位于独立 APK **`com.miui.mishare.connectivity`**（协议组件与
运行进程同名；主包 `com.miui.mishare` 在本机没有对应的 `pm path` 输出）：

```bash
adb shell pm path com.miui.mishare.connectivity  # 本文所用 APK
adb pull <路径> /tmp/deveco/mishare.apk
jadx --no-res --show-bad-code -d <输出目录> /tmp/deveco/mishare.apk
```

清单中可见 `com.miui.mishare.connectivity.ConnectivityService`、`.MiShareService`、
`.GeneralReceiver`、`.tile.MiShareTileService` 等组件，与运行日志中的进程名一致。
代码有混淆（类名被替换为单字母），但字符串常量与控制流保留，按常量检索即可定位协议代码。
本文的类名沿用反编译结果（`com.miui.mishare.connectivity.*`）。

## 1. 广播层

### 1.1 小米侧发送的广播

主广播（`connectivity.a.c.a()`）：`serviceUuid 00003331-…-008123456789` +
一条 16 位 serviceData，值为 `发送者 ID(2B) + 4×00`；其 serviceData UUID 形如
`0000%02x%02x-…`，高字节取 `connectivity.c.a()`（按 `Build.DEVICE` 机型代号映射的设备码字节），
低字节取设备类型（手机 = 1）。

扫描响应（`connectivity.a.c.b()`）：一条 16 位 serviceData，27 字节值：
`[0-7] 8×00`、`[8-9] 发送者 ID`、`[10-25] 名称区`、`[26] = 01`；其 serviceData UUID 形如
`0000%02x%02x-…`，取值来自 `connectivity.c.b()`（机型码，Redmi Note 9 实测 `0x1B10`）。
名称区规则与参考实现一致：**≥16 字节即原样放入并右侧补零；超过 16 字节截到 15 字节并追加 `\t`**
（解码端以首个 `0x00` 终止、`\t` 作为被截断标记）。

### 1.2 对端记录的解析方式（关键）

`connectivity.a.a.i.a(ScanResult)` 直接读取**合并扫描记录的固定字节偏移**：

| 偏移 | 含义 | 本实现对应 |
|---|---|---|
| 0-2 | `02 01 02`（flags） | 系统生成 |
| 3-20 | 18 字节 AD（Android 侧是 128 位 service UUID 列表） | 见 §1.3 的对齐改动 |
| 23 | 品牌码 | 品牌字节（`0000%02x%02x` 的首字节） |
| 24 | bit0 = 是否支持 5GHz | 同上 UUID 的次字节 |
| 25-30 | 6 字节值（发送者 ID + 4×00） | 主广播 6 字节值 |
| 33-34 | 机型码（来自扫描响应 UUID） | 扫描响应 UUID |
| 35-44 | 扫描响应值前 10 字节 | `8×00 + 发送者 ID(2B)` |
| 45-60 | 名称区 16 字节 | 名称 |
| 61 | 扫描响应末字节（`01`） | 尾标 |

解析结果填入 `DiscoverDeviceInfo`（含 `ManufactureCode`/`DeviceCode`/`NickName`
+ `NickNameHasMore`/`Support5gBand`/`VendorId`/`Account` 等）；品牌码在 30-39（小米区间）时才挂小米账号。

> **该实现不校验偏移 3-20 那段 AD 的类型与内容**，只按固定偏移取字节。

### 1.3 HandySend 的偏差与结论

HarmonyOS 把 `serviceData` 排在 `serviceUuids` 之前，因此本机主广播是
`flags → 16 位 serviceData → 128 位 UUID 列表`，与小米期望的顺序相反，品牌码整体错位
（实测偏移 23 被读成 `0x00` → 列表显示「未识别的设备」）；名称来自独立的扫描响应 PDU，
偏移不变（45-60），因此一直显示正确。

**尝试过的对齐方案（已回退）**：把 MTA UUID 改以「零长度 serviceData」承载（非蓝牙基址的
128 位 UUID + 空值 = 18 字节）置于 6 字节条目之前、`serviceUuids` 置空。实测**系统会丢弃值
为空的 serviceData 条目**（新广播里只剩 6 字节与 27 字节两条），于是既未对齐偏移、又丢掉了
128 位 service UUID 列表 → 对端扫描过滤器匹配不到本机（Redmi 直接扫不到 HandySend）。

由此得到的结构性约束：要满足对端偏移，偏移 3-20 必须是一段**恰好 18 字节且携带 MTA UUID**
的 AD；而 128 位 service UUID 列表（0x07，恒为 18 字节且必发）会被 HarmonyOS 排在 serviceData
之后，128 位 serviceData 带零长度值又会被系统丢弃。**在保留 MTA UUID 的前提下，本机无法产出
对端期望的字节布局**；唯一未验证的方向是扩展广播（`AdvertiseSetting.isExtended`）。

## 2. GATT 凭据通道

- 服务 `00009955-…-00805f9b34fb`；`CHAR_STATUS 00009954`（读 → DeviceInfo）、
  `CHAR_P2P 00009953`（写 → P2pInfo）。参考实现把两个特征都声明为 READ|WRITE。
- P2pInfo JSON（`connectivity.m.h()` 序列化，字段与顺序）：

  | 字段 | 含义 | 缺省行为 |
  |---|---|---|
  | `id` | 发送者 ID | 空则不写 |
  | `mac` | 设备地址 | 空则不写 |
  | `port` | 服务端口 | 0 则不写 |
  | `freq` | 群组频点 | 0 则不写 |
  | `G` | 引导网络类型（GuidingNetworkType） | 缺省 1 |
  | `M` | 主网络类型（MainNetworkType） | 缺省 1 |
  | `P` | 协议类型（ProtocolType） | 缺省 2 |
  | `ssid` / `psk` | 群组凭据（可加密） | 空则不写 |
  | `key` | 公钥（触发加解密） | 空则不写 |

- 解析侧对缺失的 `G`/`M`/`P` 取缺省 1/1/2，因此 HandySend 当前不写这三个字段仍可互通。
- `G`/`M`/`P` 的枚举取值含义尚未取证。

## 3. WebSocket 应用层

- 路径：`/websocket`（信令）、`/download`（下载）、**`/thumbnail`（缩略图，本实现未做）**。
- 消息：`versionNegotiation`、`sendRequest`、状态回执原因 `timeout`/`user refuse` 等。
- `sendRequest` 载荷字段：`taskId`、`id`（同值）、`senderId`、`senderName`、`fileName`、
  `mimeType`、`fileCount`、`totalSize`、`fileUrl`（分享源 URI 以 `##` 连接），
  可选 `thumbnail`/`thumbnail_width`/`thumbnail_height`。
  HandySend 未发送 `fileUrl` 与缩略图字段，实测不影响互通（缩略图属功能缺口）。
- `sendRequest` 发出后等待 ack 的超时为 **30s**。
- 扫描侧：`ScanFilter.setServiceUuid(00003331-…)` + `ScanSettings.SCAN_MODE_LOW_LATENCY`（主动扫描，
  会接收扫描响应）。

## 4. 品牌与机型

- 品牌图标表：`icon_logo_{mi,oppo,vivo,honor,oneplus,realme,samsung,meizu,zte,nubia,blackshark,…}`，
  与 HandySend 的 `MtaBrandRegistry` 覆盖范围一致。
- 品牌码 = 主广播 16 位 serviceData UUID 的首字节（对端按偏移 23 读取）；机型码 = 扫描响应
  serviceData UUID 的 16 位值（第三方应用实测填 `0xFFFF`，小米自家填机型代号映射值）。
- 品牌码区间语义（30-39 = 小米）与 `MtaBrandRegistry` 一致。

## 5. 对 HandySend 的结论

1. **已尝试并回退**：主广播重排无法在 HarmonyOS 上实现（原因与实测见 §1.3）；已回退为
   `serviceUuids` 承载 MTA UUID + 6 字节 serviceData 的原方案，保证对端仍能发现本机。
   品牌标签问题的唯一未验证方向是扩展广播（`isExtended`）。
2. **保持**：P2pInfo 不写 `G`/`M`/`P`（对端取缺省），`freq`/`port`/`mac`/`key` 与小米一致。
3. **功能缺口**：缩略图（`/thumbnail` 与 `thumbnail*` 字段）未实现。
4. **待验证**：扩展广播（`isExtended: true`）下 HarmonyOS 的 AD 排列顺序是否变为 UUID 列表在前、
   以及小米侧能否扫描到扩展广播。

## 6. 未解项

- `G`/`M`/`P` 的枚举取值与对传输路径的实际影响。
- 品牌码区间的完整映射（本文只确认了小米 30-39 的账号判定用法）。
- 名称区的非 ASCII 处理（小米侧解码为严格 UTF-8，非法序列视为无名称）。
