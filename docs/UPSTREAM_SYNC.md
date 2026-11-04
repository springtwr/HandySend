# 上游同步记录

> 记录 localsend submodule 的同步基线、上次评估的上游提交，以及挑拣/跳过原因。
> 发布标签与 submodule 的对应关系见 [BUILD.md](BUILD.md) §10；日常同步流程见
> [DEVELOPMENT_WORKFLOW.md](DEVELOPMENT_WORKFLOW.md) §5。

## 当前状态

- 基线标签：`v1.18.1`
- 上次评估上游提交：`92e133aa`（2026-10-30）
- 上次同步日期：2026-11-03
- 游标分支：`localsend-synced`（指向 `92e133aa`，需 push 到 origin 才能团队可见）
- 定制分支：`main`

评估范围是 `v1.18.1..92e133aa` 中触及 `packages/core` 的提交。其余提交属于 Flutter
应用、Dart isolates、CLI、CI、文档或各平台打包，不进入 HandySend 构建，未列入下表。

## 挑拣原则

- 只评估触及 `packages/core` 的提交；HandySend 的 Rust 依赖只指向该 crate
- 优先传输正确性、协议兼容性与可测量的性能收益
- 不引入需要桥接层或 ArkTS 侧额外适配才能闭环的行为变化
- 跳过平台专属（Android/iOS/macOS/Linux/Windows）、Flutter UI、CLI、CI 与文档改动

## 已挑拣

| 上游提交 | 本地提交 | 收益 | 影响面 |
|---|---|---|---|
| `d99988eb` | `1e12a231` | 局域网请求忽略系统代理与重定向 | core client：发送、发现注册、v2 info |
| `d291cf9b` | `27a810ac` | 移除 reqwest 的 system-proxy 特性 | 构建依赖 |
| `9aff08a3` | `0b971417` | 客户端仅 HTTP/1.1，服务端 TCP_NODELAY | core client/server：大文件吞吐 |
| `4b5236ce` | `f0f9dc44` | 恢复 v1/info 路由 | core server：兼容 1.17 及更早客户端 |
| `e10e6250` | `0a530836` | 文件流预读 16→4 块（约 2 MiB/流） | core `FileContent::Path` |
| `5db88c63` | `2373f56a` | 读取失败中止上传，不再发送空 body | core 上传 body（Path 路径） |
| `e768240d` | `de7b6e11` | 清理不可读文件上传测试 | core tests |
| `82abda32` | `9fad79b0` | PIN 特殊字符正确 URL 编码 | 所有 query 参数 |

> `e10e6250` 与 `5db88c63` 只覆盖 core 的 `FileContent::Path`。鸿蒙发送主路径由
> `localsend_ohrs/rust/bridge/client.rs` 的 `fd_pread_content` 自行实现，其预读量与
> 读取失败处理已由本地提交 `3e84a62` 补齐。

## 已评估并跳过

| 上游提交 | 原因 |
|---|---|
| `fca481e6` | 网页接收页拖拽；core web 页面不启用 |
| `deab2010` | 自定义网页分享；网页分享已由桥接层自研服务替代 |
| `224ef8b1` | web state 重构；同上 |
| `d84fcb2b` | 网页翻译加载错误提示；同上 |
| `89303dcf` | listener/组播失效上报；需桥接层与 ArkTS 联动，且鸿蒙挂起后 socket 失效场景未确认 |
| `612aeef2` | 单 IP 连接限制；依赖 `89303dcf` 的 accept 循环改造，当前无明确痛点 |

## 复核命令

```bash
SUB=localsend_ohrs/third_party/localsend

# 游标之后、仍触及 packages/core 的上游新提交
git -C $SUB fetch upstream main
git -C $SUB log --oneline --reverse localsend-synced..upstream/main -- packages/core

# 已挑拣的上游提交（来自 cherry-pick -x 的尾注）
git -C $SUB log --format=%B v1.18.1..HEAD \
  | grep -oE 'cherry picked from commit [0-9a-f]{7,40}' \
  | awk '{print $5}' | sort -u
```

`git cherry` 不适合本场景：它按 patch-id 判断，冲突解决或后续改动会让已挑提交显示为
未挑，且无法按路径过滤或表达“已评估但跳过”。

## 下次同步

1. `git -C $SUB fetch upstream main`
2. 按复核命令列出 `localsend-synced..upstream/main -- packages/core`
3. 逐个查看 `git -C $SUB show <hash> -- packages/core`
4. 需要挑拣的：`git -C $SUB cherry-pick -x <hash>`
5. 编译并运行测试
6. 更新本文件的「上次评估上游提交」「上次同步日期」与两张表
7. 移动游标：`git -C $SUB branch -f localsend-synced upstream/main`，再 push
8. 主仓库更新 gitlink 并提交，正文引用本文件

## 维护约定

- 每次评估后更新「上次评估上游提交」和「上次同步日期」，即使没有挑拣任何提交
- 挑拣或跳过的提交都要记入对应表格；跳过原因写清楚，避免下次重复评估
- 上游改写历史导致记录中的提交失效时，以新的 `upstream/main` 重新确认基线
