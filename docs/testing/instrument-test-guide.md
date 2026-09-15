# Instrument Test 指南

> 运行命令见 BUILD.md §7.5，测试策略概述见 ARCHITECTURE.md §7。

## 前置条件

- 鸿蒙真机已连接并开启 USB 调试
- 应用已安装到设备
- @ohos/hypium 依赖已配置（见 `entry/oh-package.json5` devDependencies）

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
import { nativeGetNativeVersion } from '../../../main/ets/service/NativeBridge'

export default function VersionNativeTest() {
  describe('VersionNativeTest', () => {
    it('getNativeVersion_returns_nonempty', 0, () => {
      let version = nativeGetNativeVersion()
      expect(version.length > 0).assertTrue()
    })
  })
}
```

## 测试报告

测试结果通过 DevEco Studio 的测试运行窗口查看，包含通过/失败/跳过统计。

## 耗时

全量 122 用例在真机（nova 15 Pro）与模拟器（Mate 80 Pro）上均为 6s 内，差异主要来自等待与网络往返而非 CPU 算力。

运行输出以 `OHOS_REPORT_STATUS: consuming=<ms>` 逐用例给出耗时（`taskconsuming` 为总耗时），按数值倒序即可定位慢用例。经验上耗时集中在两类位置：

- 上游库的固有等待：如 `nativeDiscoveryDiscoverStaged` 内部会扫描网卡子网段，测试侧只能通过 `graceMs` 参数影响其中一小段
- 需要决策或外部响应的链路：未被响应的决策会等满超时，按第 7~9 条编写可消除这部分开销

`SecurityNativeTest` 的重置身份用例会触发 RSA 密钥生成（真机 release 下每次约 0.1~0.3s），属设备端必要开销。

## 与 Local Test 的区别

| 维度 | Local Test (entry/src/test/) | Instrument Test (entry/src/ohosTest/) |
|------|------|------|
| 运行环境 | 预览引擎 | 真机/模拟器 |
| 系统API | 不支持 | 支持 |
| .so 调用 | 不支持 | 支持 |
| 文件操作 | 不支持 | 支持 |
| Linux可用 | 否（需预览器） | 是（需真机/模拟器） |

> 在 Linux 上运行 Local Test（`entry/src/test/`，如 `hvigorw test`）会卡死/长时间无响应，不要尝试；Linux 上 ArkTS 侧改用 `arkts_check` 静态检查 + 构建验证。
