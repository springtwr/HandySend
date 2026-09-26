# MTA（互传联盟）集成

> MTA 发现、发送/接收编排、对外身份与模拟品牌、接收历史与文件保真的实现细节。
>
> 主文档 `docs/ARCHITECTURE.md` §4.2 / §8.2 保留概述；统一会话建模见 `session-engine.md` 与 `repositories.md`；
> 协议层细节（BLE 握手、ECDH、WiFi Direct 时序）见 `docs/mta/MTA_PROTOCOL.md`。

## 1. 架构定位

`entry/src/main/ets/service/repository/MtaRepository.ets` 为应用级 MTA 运行时：

- 持有仅用于发现的 `MtaBleClient` 实例与 MTA 接收服务单例
- 提供发现扫描、接收服务启停、收发互斥、接收命令门面与对外身份刷新（昵称或「模拟品牌」变更时重广播）
- 变化经 `AppCore.notifyChange` 通知 UI
- AppService 门面再导出其全部对外函数，供发送页、设置页与应用生命周期调用

## 2. 发现与设备展示

### 2.1 BLE 发现扫描

- `MtaRepository` 在发送页可见期间保持 BLE 发现扫描（均衡功耗扫描模式）；切走 Tab、推入子页面或应用退后台即停止
- 扫描期间周期性剔除超时未再广播的设备（30 秒未见即离线）
- 本机蓝牙关闭时立即停止扫描、清空设备列表并复位接收服务；蓝牙重新开启后按需自动恢复扫描与接收服务（跳过失败冷却；经蓝牙状态跃迁判定，忽略中间态）

### 2.2 统一设备集与条目渲染

- 发现的互传联盟设备经 `DiscoveredDevice` 统一形状（`protocol = 'mta'`、BLE 标识作 fingerprint）合并进统一设备集，且不参与 LocalSend 收藏；`discoveredDevices` 仍仅含 LocalSend，未污染既有发现/收藏逻辑
- 条目以对端手机品牌图标与品牌徽标替代设备类型图标与 IP 短码（图标按广播品牌标识经 `MtaBrandRegistry` 解析，无专属图标的品牌与未知品牌回退默认兜底）

### 2.3 附近设备区域与来源标签

发送页「附近设备」区域由设备来源注册表通用渲染（`SendTargetZone`）：

- `SendViewModel` 经 `model/SendDeviceGrouping.ets` 纯函数把统一设备集拆为局域网/互传两组展示数据源
- 来源标签仅在本次发送页会话曾发现该来源设备时出现（互传侧经 `hasSeenMtaDevice` 会话内保持；来源数小于 2 时不展示标签）
- 互传设备数归零时展示互传专属空态，空态文案由来源描述符提供：引导开启本机蓝牙与 WLAN（无需连接网络）并确认对端在附近且已开启分享
- 收藏区块仅在局域网来源下渲染

### 2.4 连接警告横幅

发送页连接警告横幅（与网络警告同款式）按优先级只显示一条：

- WLAN 关闭且局域网不可用：与既有「未连接局域网」提示合并（互传发现依赖蓝牙、传输依赖 WLAN，有线局域网不可替代，此时两者是同一件事）
- WLAN 关闭但局域网可用（如已接网线）：只提示互传需要 WLAN（设备可被发现但无法传输）
- 蓝牙与 WLAN 均未开启：显示合并提示（互传口径）
- 仅蓝牙关闭：提示开启蓝牙
- 互传相关提示以「互传联盟接收」开关为前提（关闭时接收端不广播）
- 互传相关提示受设置「互传连接提醒」（`mtaConnectionWarnings`，默认开启）控制，关闭后不再显示互传相关警告、仅保留 LocalSend 自身的局域网警告
- 三方应用无法主动开启 WLAN（`wifiManager.enableWifi` 仅系统应用可用），故仅作提示引导

## 3. 发送编排

- 点击 MTA 设备经 `SendContent` 按 `protocol` 分流到 MTA 发送编排
- 发送前读取对端 `DeviceInfo` 后判定对端是否忙（`state` 非就绪值，判定依据见协议文档 §1.4）：判忙即以「对端设备正忙，请稍后重试」结束本次发送，
  不建组、不起服、不写回凭据，忙原因码仅入诊断日志；不自动重试，对端就绪时流程与结果不变
- `MtaSendAdapter` 承接 `MtaSendService` 生命周期、收发互斥（发送前停发现扫描并暂停接收服务，会话终态后按开关恢复）
  与取消/重试，并把会话登记到统一注册表（进度与结果经任务与通用详情页呈现，不再有 MTA 专用传输页）
- 已有 MTA 发送进行中时提示设备忙并忽略
- 与来源无关的发送方式入口（网页分享 / 网页接收 / 指定 IP 分享）经方式注册表在目标区标题行的图标菜单中按「网页」与「其它方式」分组渲染

## 4. 接收流程

- 应用进入前台时按「互传联盟接收」设置（默认开启）自动启动 MTA 接收服务（BLE 广播 + GATT Server），进入后台停止
- 收到互传联盟设备传输请求时经 `MtaReceiveAdapter` 登记为统一注册表的待确认会话，在任务确认/拒绝（应用在后台时另发提示通知）
- 请求接受后下载解压落盘到既有接收目录并写入接收历史
- MTA 发送与接收经 `MtaRepository` 互斥：发起发送前暂停接收服务，发送结束（完成/失败/取消）后按开关恢复

## 5. 接收历史与 MIME

- MTA 接收历史按文件扩展名解析真实 MIME 写入（不再统一记通用二进制类型）
- 该真实类型同时作为「保存到相册」的媒体筛选依据（待保存媒体经 `MtaReceiveAdapter.getGalleryMediaFiles` 接入通用详情页的相册保存入口，见主文档 §4.6）
- **文本接收**：用户接受文本时先把文本写入接收目录（`Download/<包名>/`，重名自动加序号、与普通文件同规则），成功后再回执与回送成功状态；
  写入失败按既有失败语义处理，不谎报成功。接收历史以单一文本条目记**真实路径**与元数据（不写入正文），详情页与文件历史据此读取文件内容
- **文本发送**：互传发送的文本文件写入应用**私有持久目录**下的发送文本目录 `filesDir/text_send/`（路径统一由 `SendRepository.sendTextDir` 提供，
  只在用户主动「清除任务历史」时被清空），对端可见条目名仍为 `sharedText.txt`（协议行为不变）；发送会话携带该文本文件的本地路径，供详情页按路径预览内容

## 6. 对外身份与模拟品牌

MTA 对外身份中的品牌取自设置项「模拟品牌」（`model/mta/MtaBrandRegistry.ets` 为品牌标识 ↔ 名称的单一事实源，默认第三方）。

### 6.1 品牌清单

- 可模拟清单收敛为小米 / OPPO / vivo / 荣耀 / 一加 / 真我 / 三星 / 魅族 8 个主流品牌 + 默认「第三方」
- 用于扫描识别对方设备的品牌标识映射保持完整、不随该清单缩减

### 6.2 协议字段

- 接收端 BLE 主广播 serviceData UUID 的品牌字节按所选品牌生成（默认第三方时等于既有常量）
- 发送端 Rust 服务器配置与 `sendRequest` 载荷携带可选的 `senderBrandId`/`senderBrand`（默认第三方时不序列化、对老对端零影响；`senderBrand` 始终为不随语言变化的规范英文名）
- 品牌变更经 `MtaRepository.refreshMtaReceiveIdentity()` 触发重广播，接收服务未运行时为空操作

### 6.3 本地化显示

- 设置页显示名随应用语言本地化（`brand_name_<key>` 字符串资源：`base` 英文、`zh_Hans` 简体、`zh_Hant` 繁体，中文下有通用中文名的品牌显示中文名），不影响协议字段与收发界面徽标

### 6.4 图标资源

- 设置页模拟品牌图标：`entry/src/main/resources/base/media/ic_brand_<key>.png`（`xiaomi/oppo/vivo/honor/oneplus/realme/samsung/meizu/default`）
  ，复制自 EasyShare 项目（MIT 许可，Copyright 2025 Midori Kochiya）
- 对端手机品牌图标：`entry/src/main/resources/base/media/ic_phone_brand_<key>.png`（
  `realme/oppo/vivo/blackshark/xiaomi/oneplus/meizu/redmagic/nubia/samsung/zte/lenovo/motorola/pixel/honor/rog/asus/hisense` 18
  个品牌），在识别映射各区间以可选 `iconRes` 标注，经 `resolveMtaPhoneBrandIcon` 供发送页 MTA 设备列表条目渲染（按发现的品牌标识解析）
- 无专属图标的品牌（Smartisan / Easy Share / NIO / 第三方）与未知品牌回退默认兜底图标（`ic_brand_default`）

## 7. 文件信息保真

文件信息保真覆盖两条链路（源文件修改时间的采集与还原）：

- 局域网发送：暂存前采集源文件修改时间随发送文件 JSON 传入（Rust 桥接填充上传 DTO 的 `metadata.modified`，接收端由核心落盘后应用）
- MTA 发送：发送端直读源文件 fd（每文件一个读取入口，文本条目写入 `filesDir/text_send/` 的文件按路径读取）并把源修改时间写入
  ZIP 条目时间；接收端解压落盘后按条目时间还原、无效时保持落盘时刻（MTA 协议载荷无时间字段，ZIP 条目时间是唯一可承载位）
