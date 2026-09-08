# AGENTS.md

## 项目概述

HandySend（便捷快传）— 基于 LocalSend 协议的 HarmonyOS 局域网文件共享应用。
- 前端：ArkTS/ArkUI（entry 模块）
- 原生层：Rust HAR（localsend_ohrs 模块），通过 NativeBridge 桥接
- 目标 SDK：6.1.1(24)，最低 6.1.0(23)

- 详细架构见 `docs/ARCHITECTURE.md`（项目结构、核心模块、API 接口变更时必须同步更新该文件）
- 环境变量设置见 `.env`；运行命令时若提示环境变量未定义，先检查系统环境变量再到 `.env` 查找

## 编码准则

### 先思考再动手

- 不确定时先问，不要默默假设
- 多种方案时列出选项，由用户决定
- 存在更简单方案时主动提出

### 简洁优先

- 只实现被要求的功能，不做推测性设计
- 不为单次使用抽象框架，不添加未要求的"灵活性"
- 200 行能缩成 50 行就重写

### 精准改动

- 只改必须改的地方，不顺手"改进"相邻代码
- 匹配项目既有风格
- 删自己改动产生的孤儿代码（未使用的 import/变量），不删改动前已存在的死代码
- 每行 diff 应能追溯到用户请求
- 有明显可改进的地方需要告知用户，由用户决定是否修改（包括代码和注释）

### 目标驱动

- 任务转化为可验证目标：修 bug 先复现，重构先确认测试通过
- 多步骤任务先给出简短计划

### 注释规范

- 所有代码注释必须使用中文（适用于 ArkTS、Rust、构建脚本等全部项目自有代码）
- 注释中的英文专有名词（API 名、协议名、类型名、文件名等）可保留原文
- 不修改第三方/vendored 代码（如 `localsend_ohrs/third_party/`）中的注释
- 注释中不得带有 `FR-xxx`、`SC-xxx` 或 `USxx` 之类的任务编号

### 禁止

- 不删除未充分理解的代码

### 测试同步

- 每次修改代码后要检查是否需要同步更新 arkts 侧或 rust 侧的测试代码，详情见 `docs/ARCHITECTURE.md` 的 `测试体系` 章节

### 文件约定

- 所有新增的 md 文件放在 `docs/` 目录中
- 更新文档时忠实展示更新时项目的情况，除非类似更新记录这种特定文档或有明确要求，否则不要在文档中添加“新增了……”、“替代原有的……”之类的增量式内容

### Git 提交

- 提交前阅读 `docs/COMMIT_CONVENTION.md`，遵循约定式提交规范
- 提交前检查文档是否需要同步更新（如架构变更更新 `docs/ARCHITECTURE.md`，构建变更更新 `docs/BUILD.md`）

## ArkTS 规范

- 写或修改 `.ets` 文件前，先加载 `arkts-grammar-standards` skill
- 生成或修改 ArkUI 页面/组件时，加载 `hmos-arkui-develop-skill` skill
- 对 ArkTS/ArkUI 行为不确定、查询鸿蒙开发文档和 API 参考时，优先使用 `devecocli docs` 查官方文档，`search` 加 `--catalog <name>` 可限定范围，具体 catalog 如下：
  - `harmonyos-guides` 开发指南
  - `harmonyos-references` API参考
  - `best-practices` 最佳实践
  - `harmonyos-faqs` FAQ
  - `harmonyos-releases` 版本说明
  - `harmonyos-roadmap` 变更预告
- 状态管理统一使用 V2（`@ComponentV2`/`@Local` 等）
- 禁止 `any`、`unknown`、`as` 类型断言

## 项目约定

### UI 设计系统

- UI 相关技术约定（DesignTokens、资源引用、热区等）见 `docs/ARCHITECTURE.md`

## 构建与验证

- 优先使用 `devecocli` 执行构建、部署、日志等操作，非必要不直接调用 hvigorw/hdc/ohpm 等底层工具
- 构建失败时加载 `arkts-error-fixes` skill 修复
- 运行时崩溃加载 `arkts-runtime-fix` skill 诊断
- JS Crash 日志分析加载 `hmos-jscrash-analysis` skill
- 不主动调用 `verify_ui`，除非用户明确要求
- 详细构建指南见 `docs/BUILD.md`

## 输出要求

完成任务时简洁说明：做了什么、如何验证、是否有未完成项或风险。
- 修改 `.ets` 文件后执行 `arkts_check` 语法检查
- 给出变更文件清单
