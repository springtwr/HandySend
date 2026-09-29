# CI/CD 流水线

> 隶属构建体系，环境安装与环境变量配置见 [BUILD.md](BUILD.md)。

项目同时发布到 GitCode 与 GitHub，两平台各有一套对等的流水线配置：GitCode 使用 AtomGit Action（`.gitcode/workflows/`），
GitHub 使用 GitHub Actions（`.github/workflows/`）。ArkTS 相关 Job 通过 `container.image` 使用内置 Command Line
Tools 的 Docker 镜像（`springtwr/harmonyos-clt:26.0.0.821`），Rust 检查和构建安全网使用标准 Runner 环境（可利用 cargo 缓存）。

## 流水线配置

### ci.yml — PR/push 检查

配置文件：`.gitcode/workflows/ci.yml`（GitCode）/ `.github/workflows/ci.yml`（GitHub）

| Job | 运行环境 | Runner 规格 | 说明 |
|-----|----------|-------------|------|
| arkts-lint | 容器 | small（2核8G） | ArkTS codelinter 检查 |
| rust-lint | 标准Runner | small（2核8G） | cargo fmt --check + cargo clippy（--no-default-features，标准 Runner 无 OHOS NDK） |
| rust-unit-test | 标准Runner | small（2核8G） | 桥接层单元测试（--no-default-features --lib） |
| rust-integration-test | 标准Runner | small（2核8G） | 桥接层集成测试（localsend_ohrs/tests/） |
| rust-upstream-test | 标准Runner | medium（4核16G） | 上游 localsend crate 测试（编译量大） |

执行顺序：arkts-lint 和 rust-lint 并行执行，rust-lint 通过后 rust-unit-test / rust-integration-test / rust-upstream-test 并行执行。

GitHub 版 job 结构与上表一致，差异：

- 无 Runner 规格概念，统一使用 `ubuntu-latest`（4核16G）
- 额外包含 `pr-title-check` Job：PR 标题需符合约定式提交（复用 `commitlint.config.js`），覆盖外部 PR（不经本地 lefthook）与 squash merge 标题
- 并发控制：PR 内新 push 自动取消旧跑（`cancel-in-progress`），main 上的构建排队执行
- 另配置 Dependabot（`.github/dependabot.yml`）：每月检查 GitHub Actions 版本更新

### build.yml — Tag 触发构建

配置文件：`.gitcode/workflows/build.yml`（GitCode）/ `.github/workflows/build.yml`（GitHub）

| Job | 运行环境 | Runner 规格 | 说明 |
|-----|----------|-------------|------|
| build | 容器 | medium（4核16G） | 安装 Rust 交叉编译工具链 + ohpm 依赖 + assembleHap |

编译检查已在 CI 流水线（ci.yml）中完成，build 流水线仅负责构建产物打包。GitHub 版构建成功后自动创建 GitHub Release
（自动生成变更说明）并附上未签名 HAP；GitCode 版仅上传构建产物，Release 附件需手动归档。

## 触发条件

| 流水线 | 事件 | 触发范围 |
|--------|------|----------|
| ci.yml | push 到 main | 排除文档等非代码文件（paths-ignore） |
| ci.yml | pull_request | 排除文档等非代码文件（paths-ignore） |
| ci.yml | workflow_dispatch | 手动触发（不限路径） |
| build.yml | push tag v* | 版本标签推送 |

排除项：`docs/**`、`**/*.md`、`LICENSE`、`.gitignore`、`.gitleaks.toml`、`commitlint.config.js`、`lefthook.yml`、`.env.example`、
`.gitcode/ISSUE_TEMPLATE/**`、`.gitcode/PULL_REQUEST_TEMPLATE/**`（GitHub 版另加 `.github/ISSUE_TEMPLATE/**`、
`.github/PULL_REQUEST_TEMPLATE.md`、`.github/dependabot.yml`）。其余变更（含构建配置 json5、ets 源码、Rust 源码等）均触发 CI。

## Docker 镜像

镜像 `springtwr/harmonyos-clt:26.0.0.821` 基于 Ubuntu 26.04，内置 HarmonyOS Command Line Tools（hvigorw、ohpm、codelinter、Node.js、hdc、hap-sign-tool 等）
及 JDK 21。镜像已预配 PATH、ohpm 仓库和 npm 仓库，Job 的 step 可直接调用工具命令。需额外通过 `container.env` 注入 `OHOS_NDK_HOME`（Rust 交叉编译需要）。

镜像内关键路径：

| 路径 | 说明 |
|------|------|
| `/opt/command-line-tools/bin/` | hvigorw、ohpm 等命令 |
| `/opt/command-line-tools/tool/node/` | Node.js |
| `/opt/command-line-tools/sdk/` | HarmonyOS SDK |
| `/opt/command-line-tools/sdk/default/openharmony/` | OHOS NDK |
| `/usr/lib/jvm/java-21-openjdk-amd64/` | JDK 21 |

## 缓存策略

Rust Job（标准 Runner）独立缓存 cargo 注册表和编译产物（`target/`），以 `Cargo.lock` 哈希为缓存键，`restore-keys` 前缀匹配兜底。

容器 Job 不使用 cache 插件：容器内的家目录（`~/.cargo/`）与宿主 Runner 不共享文件系统，cache
插件无法正确缓存容器内的家目录路径。因此 build.yml 将 Rust 安全网拆到标准 Runner（有缓存），容器 Job 仅负责鸿蒙侧构建。

## 本地验证与后续扩展

提交前可通过 lefthook pre-commit 钩子提前捕获问题，各钩子的触发条件与检查项见 [BUILD.md](BUILD.md)「安装 Git Hooks」一节。
推送前可手动运行三层 Rust 测试，命令见 [testing/rust-test.md](testing/rust-test.md)。

后续扩展：

- Instrument Test：需 hdc + 真机/模拟器
- 构建产物发布：上传到应用市场或发布到 GitCode Release
