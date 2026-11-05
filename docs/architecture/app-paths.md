# 应用沙箱目录与路径约定

> 隶属架构文档；项目全貌见 [ARCHITECTURE.md](../ARCHITECTURE.md)。本主题记录应用私有目录的
> 唯一来源、尾斜杠约定、冷启动清理入口，以及 Rust 侧路径拼接的输入约定。

## 1. 目录来源

| 用途 | 唯一来源 | 尾斜杠 |
|---|---|---|
| 发送文本 | `SendRepository.sendTextDir()` | 有 |
| 发送缩略图 | `SendRepository.sendThumbnailDir()` | 有 |
| 接收文本 | `ReceiveTargets.recvTextDir()` / `ensureRecvTextDir()` | 前者有，后者无 |
| 接收临时目录 | `ServerRepository.getReceiveCacheDir()` | 有 |
| Rust save_dir | `ServerRepository.getReceiveSaveDir()` | 有 |
| 网页上传暂存 | `WebShareRepository.webUploadStageDir()` | 有 |
| MTA 接收预览缩略图 | `MtaReceiveService` 文件内 `mtaThumbnailDirOf()` | 无 |
| 诊断日志 | `DiagnosticLogService` 文件内 `logDir()` | 无 |

业务代码不得自行拼接 `filesDir` / `cacheDir`；新增目录必须复用上表函数。只读的容量查询
可直接使用 `filesDir` / `cacheDir` 本身，不涉及子目录拼接。运行期读取与冷启动清理
共用带 `context` 的纯路径变体，避免两套口径：

- `ServerRepository` 文件内的 `receiveSaveDirOf(context)` / `receiveCacheDirOf(context)`；
- `SendRepository` 文件内的 `sendThumbnailDirOf(context)` / `legacySendDirOf(context)`。

## 2. 拼接约定

- ArkTS 目录函数默认返回带尾斜杠，调用方直接 `dir + fileName`；`ensureRecvTextDir()`、
  `mtaThumbnailDirOf()`、`logDir()` 等不带尾斜杠，调用方使用 `dir + '/' + name`，
  函数注释中注明。
- Rust 侧 `save_dir` 依赖尾斜杠（`format!("{}{}", save_dir, name)`）；
  MTA `target_dir` 使用 `format!("{target_dir}/文件名")`，对应 ArkTS 不带尾斜杠的目录。
- 一次性导出（诊断日志 ZIP、临时解包目录）使用带时间戳的独立路径，不纳入固定目录。

## 3. 冷启动清理

`EntryAbility.onCreate` 冷启动时统一清理以下临时目录，再次拉起走 `onNewWant` 不重复执行：

| 清理函数 | 目录 | 说明 |
|---|---|---|
| `cleanupSendDirWithContext` | `cacheDir/send/` | 发送缩略图缓存 |
| 同上 | `filesDir/send/` | 旧版本手动文本暂存，全量删除 |
| `cleanupReceiveCacheDirWithContext` | `cacheDir/receive/` | 接收临时/回退文件 |
| 同上 | `filesDir/HandySend/` | 当前 TLS 身份目录；清理旧版本接收残留，保留身份文件 |
| `cleanupMtaThumbnailDirWithContext` | `cacheDir/mta_thumb/` | MTA 接收预览缩略图 |

MTA 接收预览缩略图仅供确认阶段展示，冷启动清理不影响接收主流程；会话历史中的预览路径
可能因缓存清理而失效，属于临时预览的正常降级。
