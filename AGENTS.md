# AGENTS.md

## 项目概述

HandySend（便捷快传）— 基于 LocalSend 协议的 HarmonyOS 局域网文件共享应用。
- 前端：ArkTS/ArkUI（entry 模块）
- 原生层：Rust HAR（localsend_ohrs 模块），通过 NativeBridge 桥接
- 目标 SDK：26.0.0(API 26)，最低 6.1.0(23)

- 详细架构见 `docs/ARCHITECTURE.md`（项目结构、核心模块、API 接口变更时必须同步更新该文件）
- 环境变量设置见 `.env`；运行命令时若提示环境变量未定义，先检查系统环境变量再到 `.env` 查找

## 编码准则

### 先思考再动手

- 不确定时先问，不要默默假设
- 多种方案时列出选项，由用户决定
- 存在更简单方案时主动提出，但不能为了简单而丢失合理性

### 简洁优先

- 只实现被要求的功能，不做推测性设计
- 不为单次使用抽象框架，但同一段代码多次重复使用时需提醒用户（由用户决定是否抽象）
- 200 行能缩成 50 行就重写

### 精准改动

- 只改必须改的地方，不顺手"改进"相邻代码
- 匹配项目既有风格
- 删自己改动产生的孤儿代码（未使用的 import/变量），不删改动前已存在的死代码
- 每行 diff 应能追溯到用户请求
- 改动中发现可改进的地方需要告知用户，由用户决定是否修改（包括代码、注释和文档）

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
- 文档中一行文本的显示宽度禁止超过 100 个全角字符（等价于 200 个半角字符；全角按 2 计、半角按 1 计）
- 更新文档时忠实展示更新时项目的情况，除非类似更新记录这种特定文档或有明确要求，否则不要在文档中添加“新增了……”、“替代原有的……”之类的增量式内容

### 架构文档分层

- `docs/ARCHITECTURE.md` 只写项目全貌，实现细节写入 `docs/architecture/<主题>.md`，主文档对应章节只保留概述 + `详见` 链接
- 新增内容若使某节超长或属实现细节，改写/新建子文档而非堆进主文档；子文档头部用引用块回链主文档对应章节

### Git 提交

- 提交前阅读 `docs/COMMIT_CONVENTION.md`，遵循约定式提交规范
- 提交前检查文档是否需要同步更新（如架构变更更新 `docs/ARCHITECTURE.md`，构建变更更新 `docs/BUILD.md`）

## ArkTS 规范

- 组件内 `@Builder` 方法按值传递基本类型参数时，其内部 UI 不随参数变化刷新；随状态变化的展示值须经子组件
  `@Param` 绑定，或封装为按引用的单一对象参数
- 文件定位同时支持两种形式：应用沙箱/公共目录的绝对路径，与文件选择器返回的 `file://` URI。`file://` 可经
  `@ohos.file.fs` 直接 open/read，不要一律换算成本机路径后再访问
- 文件属性类接口（如 `fs.stat`）的参数是应用沙箱路径；选择器来源 URI 的换算路径本应用通常无直接访问权，
  此类校验须按输入形式优先路由、失败回退另一种方式，不要只按一种形式静默判定

## 项目约定

### UI 设计系统

- UI 相关技术约定（DesignTokens、资源引用、热区等）见 `docs/ARCHITECTURE.md`

## 构建与验证

- 非必要不直接调用 hvigorw/hdc/ohpm 等底层工具（仪器测试除外，见下条）
- ArkTS 侧单元测试统一为设备端测试（Instrument Test，命令见 `docs/testing/instrument-test-guide.md`）：
  Linux 上连接真机/模拟器后运行 `hvigorw onDeviceTest -p module=entry`；
  无可用设备时以 `devecocli check arkts` 静态检查 + 构建验证，Rust 侧用 `cargo test`
- 详细构建指南见 `docs/BUILD.md`

## 输出要求

完成任务时简洁说明：做了什么、如何验证、是否有未完成项或风险。
- 给出变更文件清单

<!-- HMOS-DEV-RULES:BEGIN -->
## HarmonyOS 开发规则（devecocli）

本机已安装 `devecocli`（`devecocli --help` 查看全部命令，`devecocli --version` 查版本）。以下能力与规则仅在开发 HarmonyOS/OpenHarmony 项目时使用。

### 核心命令

- **静态检查**：`devecocli check arkts [files...] [--fix]` —— ArkTS 严格模式检查，一轮编辑后、`devecocli build` 之前跑一次，`--fix` 可自动修复高置信度错误。另有 `check lint`（DevEco Code Linter）和 `check compat`（SDK 版本间 API 兼容扫描）
- **构建**：`devecocli build`（产物截断时全文落盘于 `Full output saved to:` 所示路径）；`devecocli build clean` 清理构建产物
- **部署运行**：`devecocli run`（构建+安装+启动；唯一设备自动选择，已构建过可用 `--skip-build`）
- **设备**：`devecocli device list` / `devecocli emulator list|start|stop`
- **调试取证**：`devecocli log`（hilog，默认 `--tail 2000`，加 `--follow` 实时跟随）
  过滤项：`--device <名称/序列号>`、`--bundle-name <包名>`、`--keyword <关键词>`、`--level D|I|W|E|F`、
  `--from/--to <相对时间，如 5m>`；崩溃日志：`devecocli log --crash --bundle-name <包名>`
- **UI 自动化**：`devecocli ui layout|screenshot|click|text|swipe|dircfling ...`（ArkUI 布局树、截图、点击、输入、滑动）
- **脚手架**：`devecocli create --app-name <name>`（已存在返回 PROJECT_EXISTS，exit 2，需用户确认后再用 `--merge`）
- **官方文档**：`devecocli docs search <关键词>` / `devecocli docs read <documentId>` / `devecocli docs catalog`
  （`search` 加 `--catalog <name>` 限定范围，可选值：`harmonyos-guides` 开发指南、`harmonyos-references` API参考、
  `best-practices` 最佳实践、`harmonyos-faqs` FAQ、`harmonyos-releases` 版本说明、`harmonyos-roadmap` 变更预告）

### Skill 路由

先判断场景，再按下表加载对应 skill，不要凭记忆写或猜：

| 场景 | 加载 |
|---|---|
| ArkTS/ArkUI 开发、组件选型、ArkTS 报错定位 | `hmos-arkui-develop-skill`（语法约束 + 组件规范；报错先查其 `references/common-mistakes/` 与 `quick-rules/`） |
| devecocli 命令用法（构建、部署、日志、设备、ui） | `deveco-cli` |
| 运行时崩溃/白屏/build 成功但运行失败（从症状出发，联动 devecocli 拉日志） | `hmos-runtime-fix-skill` |
| 已拿到 JS Crash 日志，按 Reason/Error/Stacktrace 定位根因 | `hmos-jscrash-analysis`（release 混淆堆栈用 SourceMap 反解） |
| 运行 ArkTS 侧设备端 Instrument Test | `hmos-instrument-test` |

### 工作规则

1. ArkTS/ArkUI/OpenHarmony 的问题（语法、API、装饰器、生命周期、构建报错）**先用 `devecocli docs search` 查证，再回答或写代码**，不要凭记忆。
2. 鸿蒙工程识别标志：`build-profile.json5` / `oh-package.json5` / `AppScope/app.json5`。
3. 写 `.ets` 文件前按「Skill 路由」加载对应 skill。
4. 构建闭环：编辑 → `devecocli check arkts`（pre-filter，不替代 build）→ `devecocli build` → `devecocli run --skip-build`。**`build` 成功才算完成**，未成功不得宣布完成，也不得先 `run` 再补 build。
5. `check arkts` 报错时先查「Skill 路由」里 ArkTS skill 的常见错误与速查表定位根因，不要凭猜测改；改完重新 check 再 build。
6. 设备选择：先 `devecocli device list`；优先级为真机 > 已连接的模拟器 > `devecocli emulator start` 新起的模拟器；多设备可用时用 `question` 工具让用户选，不自己挑。
7. 真机因未配置签名而安装失败时不要盲目重试，提示用户在 DevEco Studio 完成签名配置。
8. **取日志必须先收窄范围，禁止裸跑 `devecocli log` 拉全量**：设备日志刷新很快，系统日志会在几秒内把应用日志冲掉。
   默认带 `--bundle-name <包名>`（取自 `AppScope/app.json5` 的 `bundleName`），多设备时再加 `--device <名称/序列号>`；
   仍太杂时用 `--keyword <关键词>`、`--level` 或 `--from/--to` 继续收窄；确需放宽时说明原因与影响范围。
   崩溃日志同理用 `devecocli log --crash --bundle-name <包名>`，不要裸跑 `--crash`。
9. UI 验证（`devecocli ui`）**只在用户明确要求时执行**——"加个页面""改样式""修 bug"都不是触发词；单个验证目标最多尝试 3 次，不通过就停下汇报症状与根因假设，由用户决定；未做 UI 验证不算遗留问题。

### ArkTS 编码规则

1. 按 ArkTS 而非通用 TypeScript 写代码。
2. 状态管理统一使用 V2：`@ComponentV2` 组件 + `@Local` / `@Param` / `@Event` / `@Provider` / `@Consumer` 等 V2 装饰器，
   不写 V1 的 `@State` / `@Link` / `@Prop` / `@ObjectLink`；V1 与 V2 装饰器不可混用。
3. 禁止 `any`、`unknown`（用户明确允许除外）。
4. 禁止 `as` 类型断言（`as any`、`as unknown as T`、`{...} as T`）。
5. 禁止结构化类型，改用显式继承或接口实现。
6. 禁止动态属性访问（如 `obj[key]`，key 为变量）。
7. 对象字面量必须有显式类型上下文（赋给带类型的变量，或作为带类型的参数传入）。

### 构建失败诊断

1. 只盯 `ERROR` 行定位问题，`WARN` 除非相关否则忽略。
2. 按类别定位：
   - **类型错误**：ArkTS 严格类型检查失败 → 补显式类型或去掉不安全断言
   - **导入错误**：模块缺失或路径写错 → 查 `oh-package.json5` 依赖
   - **资源错误**：`resources/` 下资源缺失或命名错误
   - **权限错误**：`module.json5` 未声明权限
   - **SDK 版本错误**：API level 不匹配 → 查 `build-profile.json5` 的 `compileSdkVersion`
3. 修完重新 `devecocli build`（走增量）。
4. 增量构建意外失败时，`devecocli build clean` 或删除 `.hvigor`、`build` 目录后做一次干净构建。
5. 报 `DEVECO_HOME` 缺失时说明如何设置，然后继续其余安全的工作。
<!-- HMOS-DEV-RULES:END -->
