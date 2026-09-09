# MTA 接收端真机验证报告（MVP）

> 验证日期：待真机验证后补充
> 验证设备：HandySend 侧 HarmonyOS 设备（API 24）+ 对端安卓设备（安装 CatShare）
> 验证工具：HandySend「MTA 接收」调试页（`entry/src/main/ets/pages/MtaReceivePage.ets`）、CatShare
> 对应验证项：MTA_IMPLEMENTATION_PLAN.md Phase 2（接收端核心）
> 说明：本报告为框架 + 操作指引，**实测数据列留空待真机对打后补充**。

## 0. 验证设备信息

| 项 | 值 |
|----|----|
| HandySend 机型 / HarmonyOS 版本 | 待补充 |
| CatShare 机型 / 安卓版本 / CatShare 版本 | 待补充 |
| 验证日期 | 待补充 |
| 网络环境（原 WiFi / P2P 组网） | 待补充 |

## 1. 结论摘要

| 验证项 | 对应 SC | 结论 | 状态 |
|--------|---------|------|------|
| 一键启动接收服务（广播 + GATT Server 并存），CatShare 可发现 HandySend | SC-001 | 待真机验证 | ⏳ |
| CatShare 连接 GATT 并读取合法 DeviceInfo（含真实 ECDH 公钥） | SC-001 | 待真机验证 | ⏳ |
| 接收 P2pInfo（单包 + prepared write 分片）并完整还原 | SC-002 | 待真机验证 | ⏳ |
| ECDH + AES-256-CTR 解密 ssid/psk/mac 与 CatShare 明文一致 | SC-002 | 待真机验证 | ⏳ |
| 凭据直连成功加入 CatShare 的 WiFi Direct 组并取得 GO IP | SC-003 | 待真机验证 | ⏳ |
| WS 版本协商成功，sendRequest 内容正确展示 | SC-004 | 待真机验证 | ⏳ |
| 用户确认后文件内容与发送方 100% 一致、多文件全部落盘 | SC-005 | 待真机验证 | ⏳ |
| 路径穿越/目录/重名条目 ZIP 解压安全（不越界、不覆盖） | SC-006 | 待真机验证 | ⏳ |
| 一次接收完成后回执成功、P2P 断开、广播自动恢复可再次接收 | SC-007 | 待真机验证 | ⏳ |
| 页面退出/一键清理后无 BLE/P2P/WS 资源残留 | SC-008 | 待真机验证 | ⏳ |
| 现有 LocalSend 收发功能回归不受影响 | SC-009 | 待真机验证 | ⏳ |
| `docs/mta` 文档同步（本报告 + 实施计划状态） | SC-010 | 已完成（实测数据待补） | 🟡 |

**总体结论：待真机对打后补充。**

## 2. 操作指引

1. 打开 HandySend →「设置/更多 → 故障排查 → MTA 接收」进入调试页。
2. 确认蓝牙、WiFi/P2P 开关已开启，按提示授予 `ACCESS_BLUETOOTH` 等权限。
3. 点击「启动接收服务」：页面应显示服务运行、广播中、GATT Server 运行中，并展示本会话 ECDH 公钥。
4. 在安卓 CatShare 中进入「发送」流程，选择 HandySend 设备并选择文件发送。
5. 观察页面：
   - 「P2P 凭据」卡片出现解密后的 ssid/psk/mac 与直连后的 GO 网关、端口；
   - 收到接收请求后弹出「接收请求」卡片（发送方/文件名/文件数/总大小）；
   - 点击「接受」后「下载进度」卡片实时刷新；
   - 完成后「已保存文件」卡片列出落盘路径（`Download/<包名>/`）。
6. 打开系统文件管理器进入「下载/包名」目录，核对接收文件内容与大小。
7. 观察日志区（可按来源/级别筛选阅读），验证完成后点击「复制日志」归档到本报告「实测数据」处。
8. 观察接收完成后广播是否自动恢复，用 CatShare 发起第二次发送验证连续接收。
9. 退出页面后再次进入，确认资源无残留、可正常启动。

## 3. 验证项与操作步骤

### 3.1 SC-001：启动接收服务并被发现

**操作**：见 §2 步骤 1–4。

**预期**：广播与 GATT Server 同时运行；CatShare 设备列表出现 HandySend；读取 DeviceInfo 含 `state`/`mac`/`key`/`catShare`，`key` 为可解码的 ECDH 公钥。

**实测数据**

```
（待补充：页面状态截图/文本、DeviceInfo JSON、CatShare 侧读取结果）
```

### 3.2 SC-002：P2pInfo 接收与凭据解密

**操作**：CatShare 读到 DeviceInfo 后写入 P2pInfo；观察日志区 P2pInfo 原文与解密结果。

**预期**：单包与分片写入均能完整还原；解密出的 ssid/psk/mac 与 CatShare 发送明文一致；`key` 缺失时按明文处理不崩溃。

**实测数据**

```
（待补充：P2pInfo 原文、解密后 ssid/psk/mac、与 CatShare 明文比对结论）
```

### 3.3 SC-003：凭据直连与 GO IP

**操作**：观察「P2P 凭据」卡片与日志区 `p2pConnectionChange` 事件。

**预期**：成功加入 CatShare 的 WiFi Direct 组，取得可用 GO 网关（事件回调优先，缺失时 `192.168.49.1` 兜底）。

**实测数据**

```
（待补充：connectState、groupOwnerAddr、实际使用 GO IP、原 WiFi 是否保持）
```

### 3.4 SC-004：WS 协商与接收请求

**操作**：直连成功后观察日志区 WS 消息。

**预期**：收到 `action:0:versionNegotiation` 并回 `ack:0:versionNegotiation?{"version":1,"threadLimit":5}`；收到 `action:1:sendRequest` 并回空 ack；页面展示发送方名称/文件名/文件数/总大小。

**实测数据**

```
（待补充：versionNegotiation / sendRequest 原文、页面展示内容）
```

### 3.5 SC-005 / SC-006：下载、解压与落盘

**操作**：点击「接受」；观察进度；完成后核对 `Download/<包名>/`。

**预期**：进度实时更新；文件内容与发送方一致；多文件全部落盘；重名文件自动加 `(1)` 后缀；含 `../`/目录 entry 的 ZIP 不越界写出。

**实测数据**

```
（待补充：下载耗时/速率、落盘文件清单与校验结论、重名/穿越用例结果）
```

### 3.6 SC-007：回执与自动恢复

**操作**：完成一次接收后，观察日志与页面状态；用 CatShare 发起第二次发送。

**预期**：回送 `action:99:status?{"type":1,"reason":"ok"}`；P2P 断开、WS 关闭、广播与 GATT Server 自动重启；CatShare 可再次发现并发起第二次接收。

**实测数据**

```
（待补充：status 回执日志、第二次接收结论）
```

### 3.7 SC-008：资源释放

**操作**：传输中/完成后退出页面或点击「一键清理」；重新进入页面。

**预期**：无 BLE/P2P/WS 资源残留，可正常再次启动；取消下载后无半成品文件污染目标目录。

**实测数据**

```
（待补充：退出后 CatShare 是否仍能发现、重新进入后状态、取消下载后目录检查）
```

## 4. 风险与关注点（真机验证重点）

| 关注点 | 说明 | 处理 |
|--------|------|------|
| 共享密钥派生差异 | ArkTS `generateSecret` 输出长度/取值需与 CatShare 一致（预期 32B） | 若解密失败，记录双方公钥与共享密钥长度，评估左补零到 32B 兜底 |
| P2P 子网路由 | 直连后向 GO IP 发起 WS/HTTPS 是否走 P2P 接口 | 若请求未命中，评估引入 `@ohos.net.connection` 网络绑定（降级预案） |
| GATT 长写分片 | CatShare 实测多为 256B 单包；大凭据/低 MTU 才触发 prepared write | 用 nRF Connect 或大凭据场景补验分片路径 |
| 原 WiFi 是否断开 | P0 观察到原 WiFi 保持，接收场景需专项确认对下载可达性的影响 | 记录 `getIpInfo` 快照 |
| 蓝牙权限/开关边缘场景 | 关闭蓝牙或拒绝权限时的失败提示与不崩溃 | 专项用例验证 |
| 自签名证书跳过 | WS `skipServerCertVerification` / HTTPS `remoteValidation:'skip'` 生效 | 确认握手成功 |

## 5. 日志归档

将调试页「复制日志」内容粘贴于此（待真机验证后补充）：

```
（待补充）
```
