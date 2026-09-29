# Instrument Test 指南

> 隶属测试体系，测试策略概述见 ARCHITECTURE.md §7；Rust 侧测试见 [rust-test.md](rust-test.md)。

## 前置条件

- 鸿蒙真机已连接并开启 USB 调试
- 应用已安装到设备
- @ohos/hypium 依赖已配置（见根目录 `oh-package.json5` devDependencies）

## 运行命令

Instrument Test 运行于真机/模拟器，可调用系统 API 和原生 .so 函数，统一承载 ArkTS 侧全部单元测试。需先安装应用到设备。全量运行耗时见下文「耗时」一节。

```bash
# 全量 Instrument Test
hvigorw onDeviceTest -p module=entry

# 指定测试套件
hvigorw onDeviceTest -p module=entry -p scope=ServerNativeTest

# 指定单个用例
hvigorw onDeviceTest -p module=entry -p scope=ServerNativeTest#createServer_returns_valid_handle
```

> 同时连接多台设备时 `onDeviceTest` 会在设备选择阶段失败（`ExecuteCommand need connect-key?`）：其覆盖率插件调用 hdc 时未指定设备序列号。此时断开多余设备，或改用下节的 hdc 直连方式。

### hdc 直连

无需 DevEco Studio 设备管理，也可绕开多设备选择问题。设备序列号由 `hdc list targets` 查询。

```bash
# 1. 构建并签名测试包（onDeviceTest 的构建阶段即产出，其后的部署失败可忽略）
hvigorw onDeviceTest -p module=entry

# 2. 安装主包与测试包
hdc -t 127.0.0.1:5555 install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc -t 127.0.0.1:5555 install -r entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap

# 3. 运行（-s coverage false 关闭覆盖率采集，避免额外的采集与回传开销）
hdc -t 127.0.0.1:5555 shell aa test -b com.springtwr.handysend -m entry_test \
  -s unittest /ets/testrunner/OpenHarmonyTestRunner -s timeout 15000 -s coverage false
```

## 编写规范

1. 文件名必须以 `.test.ets` 结尾
2. 导入 `@ohos/hypium` 的 `describe`/`it`/`expect`
3. 导出 `export default function XxxTest()` 套件函数
4. 在 `List.test.ets` 中注册新套件
5. 所有代码注释使用中文
6. 遵循 ArkTS 严格模式语法
7. 等待异步结果用 `TestHelper` 的 `waitUntil` 条件轮询或事件订阅，不用固定 `sleep` 占位
8. 需要调用方决策的链路（`prepareUpload` 等）必须在用例内响应，否则发送侧会等满决策超时
9. 依赖外部环境（PC 端 CLI、对端设备）的用例先做可达性探测，不可达直接跳过；需要"必定失败"的目标用本机保留端口等可立即被拒的端点，避免等待不可达地址的 TCP 连接超时

### 示例

```typescript
import { describe, it, expect } from '@ohos/hypium'
import { getNativeLibraryVersion } from '../../../main/ets/service/NativeBridge'

export default function VersionNativeTest() {
  describe('VersionNativeTest', () => {
    it('getNativeLibraryVersion_returns_nonempty', 0, () => {
      let version = getNativeLibraryVersion()
      expect(version.length > 0).assertTrue()
    })
  })
}
```

## 测试报告

测试结果通过 DevEco Studio 的测试运行窗口查看，包含通过/失败/跳过统计。

## 耗时

全量用例在模拟器（Mate 80 Pro）上实测为秒级（不含构建与安装耗时），差异主要来自等待与网络往返而非 CPU 算力。

运行输出以 `OHOS_REPORT_STATUS: consuming=<ms>` 逐用例给出耗时（`taskconsuming` 为总耗时），按数值倒序即可定位慢用例。经验上耗时集中在两类位置：

- 上游库的固有等待：如 `nativeDiscoveryDiscoverStaged` 内部会扫描网卡子网段，测试侧只能通过 `graceMs` 参数影响其中一小段
- 需要决策或外部响应的链路：未被响应的决策会等满超时，按第 7~9 条编写可消除这部分开销

`SecurityNativeTest` 的重置身份用例会触发 RSA 密钥生成（真机 release 下为亚秒级开销），属设备端必要开销。

## 与 Local Test 的区别

> Local Test（`entry/src/test/`）已废弃：2026-09 其全部用例迁移至本目录并合并去重，目录已删除，不再存在单独的本地位。
> ArkTS 侧测试统一为设备端测试，无第二入口。下表保留历史差异说明。

| 维度 | Local Test (entry/src/test/，已废弃/删除) | Instrument Test (entry/src/ohosTest/) |
|------|------|------|
| 运行环境 | ~~预览引擎~~ | 真机/模拟器 |
| 系统API | ~~不支持~~ | 支持 |
| .so 调用 | ~~不支持~~ | 支持 |
| 文件操作 | ~~不支持~~ | 支持 |
| Linux可用 | ~~否（需预览器）~~ | 是（需真机/模拟器） |

> 已在 Linux 上运行过 Local Test（`entry/src/test/`，如 `hvigorw test`）会卡死/长时间无响应；该目录及命令已随迁移移除，请勿再使用。
