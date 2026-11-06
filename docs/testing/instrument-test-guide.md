# Instrument Test 指南

> 隶属测试体系，测试策略概述见 ARCHITECTURE.md §7；Rust 侧测试见 [rust-test.md](rust-test.md)。

## 前置条件

- 鸿蒙真机/模拟器已连接并开启 USB 调试
- @ohos/hypium 依赖已配置（见根目录 `oh-package.json5` devDependencies）

## 运行命令

Instrument Test 运行于真机/模拟器，可调用系统 API 和原生 .so 函数，统一承载 ArkTS 侧全部单元测试。全量运行耗时见下文「耗时」一节。

### 方式一：onDeviceTest

一条命令完成构建、安装与运行，适合日常回归。

```bash
# 全量
hvigorw onDeviceTest -p module=entry -p coverage=false

# 指定测试套件
hvigorw onDeviceTest -p module=entry -p coverage=false -p scope=ServerNativeTest

# 指定单个用例（套件名#用例名）
hvigorw onDeviceTest -p module=entry -p coverage=false \
  -p scope=ServerNativeTest_Running#createServer_server_running_with_valid_fingerprint
```

`-p coverage=false` 关闭覆盖率采集与报告生成。开启覆盖率时，插件在 `spawnSync` 的输出上限内会被
`OHOS_REPORT_COVERAGE_DATA` 截断，进而报 `getjsCoverageData failed`。

该命令不把测试输出打印到控制台，而是追加写入：

- `entry/.test/default/intermediates/ohosTest/coverage_data/coverage.log`：逐用例状态与汇总
- `entry/.test/default/intermediates/ohosTest/coverage_data/test_result.txt`：用例结果与汇总

```bash
# 查看最近一次汇总
grep "OHOS_REPORT_RESULT" \
  entry/.test/default/intermediates/ohosTest/coverage_data/coverage.log | tail -1
```

注意：

- 日志为追加写入，多次运行后需取最后一条汇总，或先清空日志
- 运行前会先卸载应用再安装，应用数据会被清空
- 多台设备同时连接时该命令会失败（内部 hdc 调用未指定设备），此时断开多余设备或改用方式二

### 方式二：hdc 直连

构建、安装、运行分开执行，可实时查看用例输出，也可用 `-t` 指定设备。

#### 1. 构建测试包

```bash
hvigorw --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap
```

产物：

- 主包：`entry/build/default/outputs/default/entry-default-signed.hap`
- 测试包：`entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap`

主包未改动时可复用已有产物，只需重新构建测试包。

#### 2. 安装到设备

设备序列号由 `hdc list targets` 查询；只连接一台设备时可省略 `-t`。

```bash
hdc -t <序列号> install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc -t <序列号> install -r entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap
```

#### 3. 运行测试

```bash
# 全量
hdc -t <序列号> shell aa test -b com.springtwr.handysend -m entry_test \
  -s unittest /ets/testrunner/OpenHarmonyTestRunner -s timeout 15000 -s coverage false

# 指定测试套件
hdc -t <序列号> shell aa test -b com.springtwr.handysend -m entry_test \
  -s unittest /ets/testrunner/OpenHarmonyTestRunner -s class ServerNativeTest \
  -s timeout 15000 -s coverage false

# 指定单个用例（套件名#用例名）
hdc -t <序列号> shell aa test -b com.springtwr.handysend -m entry_test \
  -s unittest /ets/testrunner/OpenHarmonyTestRunner \
  -s class ServerNativeTest_Running#createServer_server_running_with_valid_fingerprint \
  -s timeout 15000 -s coverage false
```

说明：

- `-s coverage false` 关闭覆盖率采集，避免额外的采集与回传开销
- `-s class` 对应 `describe` 的套件名，`#` 后为 `it` 的用例名；精确匹配，同一文件内的其他 `describe` 不会一并执行
- `aa test` 不支持 release 签名应用（错误码 10106002），本项目默认使用 debug 签名
- 同时连接多台设备时 `-t` 必须指定，否则 hdc 报 `ExecuteCommand need connect-key?`

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

- 方式一：结果写入 `coverage_data/coverage.log` 与 `test_result.txt`（路径见上文），控制台只显示任务状态
- 方式二：结果直接输出到 `aa test` 的标准输出，逐用例打印 `OHOS_REPORT_STATUS`，结束时汇总
  `Tests run`、`Failure` 等统计
- DevEco Studio：测试运行窗口的结果树（通过/失败/跳过统计）

失败用例附带错误信息与堆栈。

## 耗时

全量用例在模拟器（Mate 80 Pro）上实测为秒级（不含构建与安装耗时），差异主要来自等待与网络往返而非 CPU 算力。

运行输出以 `OHOS_REPORT_STATUS: consuming=<ms>` 逐用例给出耗时（`taskconsuming` 为总耗时），按数值倒序即可定位慢用例。经验上耗时集中在两类位置：

- 上游库的固有等待：如 `nativeDiscoveryDiscoverStaged` 内部会扫描网卡子网段，测试侧可通过 `graceMs`（确认收集期）与 `forceSubnetScan`（跳过收集、强制执行）参数控制其中一段
- 需要决策或外部响应的链路：未被响应的决策会等满超时，按第 7~9 条编写可消除这部分开销

`SecurityNativeTest` 的重置身份用例会触发 RSA 密钥生成（真机 release 下为亚秒级开销），属设备端必要开销。

## 运行环境要求

Instrument Test 运行于真机/模拟器，支持系统 API、`.so` 调用与文件操作；Linux 上需连接真机或模拟器运行。
