# Rust 核心层测试

> 隶属测试体系，测试策略概述见 [../ARCHITECTURE.md](../ARCHITECTURE.md)；ArkTS 侧设备端测试见
> [instrument-test-guide.md](instrument-test-guide.md)。

Rust 核心层测试在 Linux 开发机上直接运行 `cargo test`，无需真机、无需 NAPI 运行时。分三层：

| 层级 | 覆盖范围 | 命令入口 |
|------|----------|----------|
| 桥接层单元测试 | 不依赖 NAPI 运行时的逻辑函数（类型转换、序列化、哈希、状态操作等） | `cargo test --no-default-features --lib` |
| 桥接层集成测试 | 事件管道、配置矩阵、NAPI 封装完整性 guard | `localsend_ohrs/tests/` 独立 crate |
| 上游 localsend crate 测试 | 协议、HTTP 服务器/客户端、发现、加密等 | 上游仓库自带的单元 + 集成测试 |

三层测试均已注册为 hvigor 任务，位于 DevEco Studio 侧边 hvigor 工具面板：**HandySend → localsend_ohrs → 任务 → 其它**。

## hvigor 任务方式（推荐）

```bash
# 桥接层单元测试（秒级）
hvigorw RustTestUnit -p module=localsend_ohrs

# 桥接层集成测试（秒级）
hvigorw RustTestIntegration -p module=localsend_ohrs

# 上游 localsend crate 测试（约半分钟）
hvigorw RustTestUpstream -p module=localsend_ohrs
```

## 手动运行 cargo test

### 桥接层单元测试

覆盖桥接层中不依赖 NAPI 运行时的逻辑函数（类型转换、序列化、哈希、状态操作等），含 `BridgeEvent` 全变体序列化字段契约（防 ArkTS/Rust 契约漂移）：

```bash
cd localsend_ohrs
cargo test --target x86_64-unknown-linux-gnu --no-default-features --lib
```

> `--no-default-features` 关闭 napi feature，避免链接 OHOS NDK（`hilog_ndk.z` 等）。`--lib` 只测试库代码，排除集成测试二进制。
>
> 该套件含多组 TLS 身份/证书用例，会触发 RSA-2048 密钥生成。`localsend_ohrs/Cargo.toml` 的 `[profile.dev.package.rsa]` 与 `[profile.dev.package.num-bigint-dig]` 对这两个密码学
> crate 单独设置 `opt-level = 3`：unoptimized 下单次生成需十余秒，优化后降至毫秒级，全量用例耗时由数十秒降至秒级。该设置只作用于这两个第三方 crate，项目自身代码仍为 unoptimized。

### 桥接层集成测试

验证桥接层事件管道（server_flow / client_flow / discovery_flow / mta_flow，通过 `event_tx`/`event_rx` 直接消费事件流，无 mock、无轮询）+ 配置矩阵（`config_matrix.rs`：
HTTPS/PIN/校验和开关、多接收者并发、Web Share 链接、多文件传输、进度序列、协议安全边界、create_server 落盘），并包含 NAPI 封装完整性 guard（`napi_guard.rs`：
校验 index.d.ts 导出与 NativeBridge.ets 封装差集 + `NativeTypes.ets::parseNativeEvent` 与 Rust `BridgeEvent` 序列化的跨层事件契约）：

```bash
cd localsend_ohrs/tests
cargo test --target x86_64-unknown-linux-gnu
```

> `localsend_ohrs_tests` 是独立 crate（不在 `localsend_ohrs` workspace 中），必须从 `localsend_ohrs/tests/`
> 目录运行。`--target x86_64-unknown-linux-gnu` 覆盖父级 `.cargo/config.toml` 中设置的 OHOS 交叉编译目标。
>
> 作为独立 crate，其 profile 不继承主 crate，`localsend_ohrs/tests/Cargo.toml` 同样对 `rsa` 与 `num-bigint-dig`
> 设置 `opt-level = 3`（原因见上方桥接层单元测试小节）：unoptimized 下全量运行需分钟级，优化后降至秒级。

### 上游 localsend crate 测试

直接在 `third_party/localsend/` 下运行上游的单元测试和集成测试（覆盖协议、HTTP 服务器/客户端、发现、加密等）：

```bash
cd localsend_ohrs/third_party/localsend
cargo test --target x86_64-unknown-linux-gnu -p localsend --features crypto,discovery,http,multicast
```

> `--target x86_64-unknown-linux-gnu` 是必须的：`localsend_ohrs/.cargo/config.toml` 硬编码了 `x86_64-unknown-linux-ohos` 交叉编译目标，Cargo
> 会沿目录树向上查找配置，不显式指定 native target 则测试无法运行。`-p localsend` 限定只运行 core crate 的测试，不加则运行 workspace 全部成员。
>
> 部分组播/发现测试在无网络接口的环境中可能 skip，属正常现象。
