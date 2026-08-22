# Git 提交规范

本项目采用 [约定式提交（Conventional Commits）](https://www.conventionalcommits.org/) 标准。

## 提交消息结构

```
<type>(<scope>): <description>

[正文]

[尾部]
```

## 1. 标题（必填）

格式：`<type>(<scope>): <description>`

示例：`feat(transfer): 新增传输进度百分比显示`

### 类型（type）

| 类型 | 用途 |
|------|------|
| `feat` | 新功能 |
| `fix` | 修复缺陷 |
| `docs` | 文档变更 |
| `style` | 代码样式调整（不影响功能，如格式化、空格） |
| `refactor` | 代码重构（既非新功能也非修复） |
| `perf` | 性能优化 |
| `test` | 测试相关（新增、修改、补充用例） |
| `build` | 构建系统或外部依赖变更（Rust 编译脚本、ohpm 依赖等） |
| `ci` | CI/CD 配置变更 |
| `chore` | 其他不涉及源码的杂项（.gitignore、IDE 配置等） |
| `revert` | 回退之前的提交 |

> **注意**：类型必须使用上述小写关键字，不使用自定义类型。

### 范围（scope）

可选，用括号包裹，表示变更涉及的模块或区域。推荐使用以下范围：

| 范围 | 说明 |
|------|------|
| `transfer` | 文件传输流程（发送/接收/进度/取消） |
| `discovery` | 设备发现与组播 |
| `settings` | 设置页面与偏好存储 |
| `native` | Rust HAR 层（localsend_ohrs） |
| `bridge` | NativeBridge 桥接层 |
| `ui` | UI 布局/组件/样式 |
| `log` | 日志模块 |
| `build` | 构建脚本与工具链 |

范围不是封闭列表——当变更集中在某个具体文件或小区域时，也可以用文件名或简短标识，如 `bridge`、`log`。如果变更跨多个模块，可省略范围。

### 描述（description）

- 以动词开头，简明扼要说明「做了什么」
- 不超过 50 个字符
- 使用中文
- 不加句号

| ✅ 正确 | ❌ 错误 |
|---------|---------|
| `feat(transfer): 新增传输进度百分比显示` | `feat(transfer): 新增了传输进度百分比显示的功能。` |
| `fix(discovery): 修复更改端口时无法发现设备` | `fix: bug fix` |
| `refactor(log): 调整日志级别，CRUD 细节降为 debug` | `refactor: 一些重构` |

## 2. 正文（可选）

- 详细说明变更的**背景、原因和结果**——为什么改、改了什么、有什么影响
- 每行不超过 72 个字符
- 使用中文
- 与标题空一行
- 多项内容用 `-` 列表，便于阅读

示例：

```
fix(transfer): 修复小文件传输时进度条提前到 100%

- 文件总大小在 SendContent 初始化时缓存，避免每次 UI 刷新同步调用 statSync
- 进度回调改为基于已传输字节数而非文件数计算
```

## 3. 尾部（可选）

- 关联 issue：`Closes #123`、`Fixes #456`
- 破坏性变更：以 `BREAKING CHANGE:` 开头，或标题类型后加 `!`
- 与正文空一行

示例：

```
refactor(native)!: 重构 Rust NAPI 层接口

将轮询机制迁移到事件回调模式，桥接层拆分为多模块。

BREAKING CHANGE: NativeBridge 的 onDiscovery 回调签名变更，调用方需适配新参数结构
```

`!` 是 `BREAKING CHANGE` 的简写——标题中加 `!` 等同于尾部写 `BREAKING CHANGE:`，两者选其一即可。

## 完整示例

### 简单提交（仅标题）

```
fix(settings): 修复恢复默认设置缺少确认对话框
```

### 带正文的提交

```
feat(log): 统一日志系统 — Logger 模块封装 hilog + Debug 开关

- 封装 Logger 模块，统一调用 hilog 的接口
- 通过 isDebug 开关控制日志级别
- 替换全项目散落的 hilog 直接调用
```

### 破坏性变更

```
refactor(bridge)!: 桥接层拆分为多模块

将单一 NativeBridge 拆分为 DiscoveryBridge、TransferBridge、ServerBridge。

BREAKING CHANGE: 原 NativeBridge 类已移除，需按功能引入对应 Bridge
Closes #12
```

## 自动校验

项目通过 Lefthook + commitlint 自动校验提交信息格式，不符合规范会被拦截。

- 配置文件：`commitlint.config.js`（规则与本文档一致）
- 校验工具：commitlint + @commitlint/config-conventional
- Hook 管理：lefthook（`lefthook.yml`）

被拦截时，按规范修改提交信息后重新提交即可。紧急情况可绕过：`LEFTHOOK=0 git commit`。

## 常见问题

**Q：一个提交包含多种类型怎么写？**
A：按主要目的选类型。重构中顺带修了个 typo → 用 `refactor`；修 bug 时发现需要新增辅助函数 → 仍用 `fix`。

**Q：scope 怎么选？**
A：优先用上面推荐的模块范围。如果改动集中在一个文件或小组件，用文件名也行。跨模块改动省略 scope。

**Q：描述用中文还是英文？**
A：中文。与项目代码注释规范保持一致。
