# AGENTS.md

## 项目概述

HandySend（便捷快传）— 基于 LocalSend 协议的 HarmonyOS 局域网文件共享应用。
- 前端：ArkTS/ArkUI（entry 模块）
- 原生层：Rust HAR（localsend_ohrs 模块），通过 NativeBridge 桥接
- 目标 SDK：6.1.1(24)，最低 6.0.0(20)

- 详细架构见 `docs/ARCHITECTURE.md`（项目结构、核心模块、API 接口变更时必须同步更新该文件）
- 环境变量设置见 `.env`；运行命令时若提示环境变量未定义，先检查系统环境变量再到 `.env` 查找
- 构建所需环境变量：`OHOS_NDK_HOME`、`DEVECO_SDK_HOME`、`DEVECO_HOME`、`JAVA_HOME`，详见 `docs/BUILD.md`

## 编码准则

### 1. 先思考再动手

- 不确定时先问，不要默默假设
- 多种方案时列出选项，由用户决定
- 存在更简单方案时主动提出

### 2. 简洁优先

- 只实现被要求的功能，不做推测性设计
- 不为单次使用抽象框架，不添加未要求的"灵活性"
- 200 行能缩成 50 行就重写

### 3. 精准改动

- 只改必须改的地方，不顺手"改进"相邻代码
- 匹配项目既有风格
- 删自己改动产生的孤儿代码（未使用的 import/变量），不删改动前已存在的死代码
- 每行 diff 应能追溯到用户请求

### 4. 目标驱动

- 任务转化为可验证目标：修 bug 先复现，重构先确认测试通过
- 多步骤任务先给出简短计划

### 禁止

- 不在未确认需求时扩大范围
- 不添加用户未要求的功能
- 不为"更优雅"重写无关代码
- 不删除未充分理解的代码

### 文件约定

- 所有新增的 md 文件放在 `docs/` 目录中
- 更新文档时忠实展示更新时项目的情况，除非类似更新记录这种特定文档或有明确要求，否则不要在文档中添加“新增了……”、“修改了……”、“已经……”之类的增量式内容

## ArkTS 规范

- 写或修改 `.ets` 文件前，先加载 `arkts-grammar-standards` skill
- 对 ArkTS/ArkUI 行为不确定、查询鸿蒙开发文档和 API 参考时，优先使用 `devecocli docs` 查官方文档
- `devecocli` 找不到时再用 `arkts_knowledge_search` 查询官方知识库
- 禁止 `any`、`unknown`、`as` 类型断言
- 使用显式继承，不用结构化类型
- 禁止动态属性访问 `obj[dynamicKey]`
- 对象字面量必须有显式类型上下文

## 项目约定

### UI 设计系统

- 使用 `DesignTokens` 常量体系（字号/间距/圆角/热区），不要硬编码数值
- 颜色使用 `$r('app.color.xxx')` 资源引用
- 字符串使用 `$r('app.string.xxx')` 资源引用
- 热区最小尺寸：`DesignTokens.hotspot.minSize`

### 原生层交互

- 通过 `NativeBridge.ets` 调用 Rust 函数，不要直接 import `localsend_ohrs`
- 原生类型定义在 `model/NativeTypes.ets`，与 Rust 侧一一对应
- 原生库版本号定义在 `localsend_ohrs/Cargo.toml`，修改后通过脚本自动同步到其它位置

### 导航

- 使用 `router` 进行页面跳转和返回
- 页面间传参通过 `router.getParams() as Record<string, string>`
- 页面转场动画统一使用 `pageTransition()` + DesignTokens.animation

### 状态管理

- 页面级状态用 `@State`
- 跨组件共享通过 `AppStorage` + `@StorageLink`/`@StorageProp`
- 持久化偏好通过 `PreferencesUtil`

### 服务层

- 服务函数以模块为单位组织（AppService, DiscoveryService, FavoritesService 等）
- DialogService 统一管理弹窗，不要在页面中直接创建 AlertDialog

## 构建与验证

快速命令：`hvigorw assembleApp`（HAP）、`hvigorw assembleHar`（HAR）、`hvigorw clean`（清理）
- 构建失败时加载 `arkts-error-fixes` skill 修复
- 运行时崩溃加载 `arkts-runtime-fix` skill 诊断
- 不主动调用 `verify_ui`，除非用户明确要求
- 详细构建指南见 `docs/BUILD.md`

常用工具路径（建议加入 PATH，均派生自 `DEVECO_HOME`）：

| 命令             | 路径                                                                         | 派生关系                                              |
|----------------|----------------------------------------------------------------------------|---------------------------------------------------|
| `devecostudio` | `C:\Program Files\Huawei\DevEco Studio\bin`                                | `$DEVECO_HOME/bin`                                |
| `ohpm`         | `C:\Program Files\Huawei\DevEco Studio\tools\ohpm\bin`                     | `$DEVECO_HOME/tools/ohpm/bin`                     |
| `hdc`          | `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains` | `$DEVECO_SDK_HOME/default/openharmony/toolchains` |
| `hvigorw`      | `C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin`                   | `$DEVECO_HOME/tools/hvigor/bin`                   |

## 输出要求

完成任务时简洁说明：做了什么、如何验证、是否有未完成项或风险。
