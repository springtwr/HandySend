# 贡献指南

欢迎为 HandySend 贡献代码、文档或反馈问题！

## 从哪里开始

提交 Issue 或 PR 前，建议先阅读以下文档：

- [AGENTS.md](AGENTS.md) — 项目规范与编码准则
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 架构与模块职责
- [docs/BUILD.md](docs/BUILD.md) — 完整构建指南（含环境变量、跨平台配置、故障排除）
- [docs/DEVELOPMENT_WORKFLOW.md](docs/DEVELOPMENT_WORKFLOW.md) — 开发流程（分支策略、submodule 工作流、上游升级）
- [docs/COMMIT_CONVENTION.md](docs/COMMIT_CONVENTION.md) — Git 提交规范（约定式提交）

## 报告问题

1. 先搜索是否已有相同 Issue，避免重复
2. 使用项目配置的 Issue 模板（在 GitCode 新建 Issue 时自动出现）：
   - **Bug 报告** — 提供设备型号、HarmonyOS 版本、HandySend 版本、复现步骤、预期与实际行为、日志
   - **功能请求** — 描述背景与动机、期望行为、建议方案、验收标准
3. 如无合适模板，使用空白 Issue

## 贡献代码

### 环境搭建

见 [docs/BUILD.md](docs/BUILD.md)。如果只想快速验证构建，可按 README「开发者：快速开始」的最小路径操作，暂时跳过 Git Hooks 安装。

### 分支与工作流

- 默认分支：`main`
- 开发流程：从 `main` 切功能分支 → 开发 → 推送 → 提交 PR 到 `main`
- **涉及 localsend submodule 定制的改动**：需先在 fork 定制仓库的 `harmony-web-ui` 分支提交并 push，
  主仓库 PR 仅更新 submodule gitlink。详见
  [docs/DEVELOPMENT_WORKFLOW.md](docs/DEVELOPMENT_WORKFLOW.md) §3 场景 B

### 代码规范

**ArkTS**：
- 禁止 `any`、`unknown`、`as` 类型断言
- 使用显式继承，不用结构化类型
- 禁止动态属性访问 `obj[dynamicKey]`
- 对象字面量必须有显式类型上下文
- 所有注释使用中文
- UI 使用 `DesignTokens` 常量与 `$r()` 资源引用，不硬编码数值

**Rust**（`localsend_ohrs/` 下非 third_party 的代码）：
- 通过 `cargo fmt --check` 格式检查
- 通过 `cargo clippy -- -D warnings` 静态检查

**提交信息**：
- 遵循约定式提交（Conventional Commits）：`type(scope): 描述`
- 描述使用中文，不超过 50 字符
- 详见 [docs/COMMIT_CONVENTION.md](docs/COMMIT_CONVENTION.md)

### PR 规则

1. **目标分支**：`main`
2. **标题格式**：遵循约定式提交 — `type(scope): 描述`（中文描述），如 `feat(transfer): 新增传输进度百分比显示`
3. **范围**：一个 PR 聚焦一个主题，避免混合多种无关改动
4. **自查清单**（提交 PR 前确认）：
   - [ ] 已阅读本贡献指南
   - [ ] 本地构建通过（`hvigorw assembleHap`）
   - [ ] 通过 Lefthook 检查（大文件检测、gitleaks、ArkTS 静态检查、Rust fmt/clippy、commitlint）
   - [ ] 代码遵循上述 ArkTS/Rust 规范，注释为中文
   - [ ] 已更新相关文档（如涉及架构变更，同步更新 `docs/ARCHITECTURE.md`）
   - [ ] PR 标题遵循约定式提交格式
5. **关联 Issue**：在 PR 描述或提交尾部使用 `Closes #xx` 或 `Fixes #xx`

### 模板

Issue 与 PR 模板位于 `.gitcode/` 目录，GitCode 新建时自动填充。

## 感谢

每一位贡献者都是 HandySend 社区的重要成员，感谢你的参与！
