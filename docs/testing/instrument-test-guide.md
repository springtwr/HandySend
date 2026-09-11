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

## 与 Local Test 的区别

| 维度 | Local Test (entry/src/test/) | Instrument Test (entry/src/ohosTest/) |
|------|------|------|
| 运行环境 | 预览引擎 | 真机/模拟器 |
| 系统API | 不支持 | 支持 |
| .so 调用 | 不支持 | 支持 |
| 文件操作 | 不支持 | 支持 |
| Linux可用 | 否（需预览器） | 是（需真机） |

> 在 Linux 上运行 Local Test（`entry/src/test/`，如 `hvigorw test`）会卡死/长时间无响应，不要尝试；Linux 上 ArkTS 侧改用 `arkts_check` 静态检查 + 构建验证。
