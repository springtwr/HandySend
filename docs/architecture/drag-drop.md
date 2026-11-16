# 跨应用拖放（UDMF）

> 应用主页作为跨应用拖放目标的集成细节：数据解析分流、暂存与去重、反馈与容错、授权与可靠性提示。
>
> 主文档 `docs/ARCHITECTURE.md` §8.2 保留概述。

## 1. 总览

应用主页根容器整体作为跨应用拖放目标接收统一拖拽数据（统一数据管理框架 UDMF）：根容器声明
`allowDrop`（`general.file`/`general.folder`/`general.directory`/`general.image`/`general.video`/`general.audio`/`general.plain-text`/`general.hyperlink`）。
拖放在全应用生效：任意页签与经 Navigation 推入的子页面均可拖入；放下后自动回到主页根并切到发送页签，
新加入的暂存内容位于页首，便于立即查看与发送。

拖入记录经 `model/DragDropParser.ets` 纯函数按 UTD 分流后，由 `SendViewModel.applyDroppedContent` 复用既有暂存链路加入发送暂存列表，与系统分享链路行为一致。

## 2. 数据解析分流（DragDropParser）

- 文件夹类（`general.folder`/`general.directory`）读目录 URI 入 `folders`：`Folder` 子类读独立属性 `folderUri`，为空或读取异常时回退基类 `File.uri`
- 文件类读 `uri`（`Image`/`Video`/`Audio` 子类读各自独立 uri 属性 `imageUri`/`videoUri`/`audioUri`，为空时回退基类 `File.uri`）
- `PlainText` 读 `textContent`
- `Hyperlink` 以「描述 + 换行 + URL」组合
- 其余类型（`openharmony.app-item` 等）跳过
- 每次拖入输出记录数与各记录的 UTD 类型清单，便于确认来源实际数据类型

## 3. 暂存与去重

- 解析结果由 `SendViewModel.applyDroppedContent` 复用既有暂存链路：文件走 `stageUris`、文本以 `drop_` 前缀走 `stageTextFile`
- 文件夹走 `stageFolderUris`：逐个异步扫描（拖入时在放下后异步执行，与文件夹选择、系统分享同一链路），
  成功时以单个聚合条目暂存，目录内子项逐文件登记并计算相对路径；扫描为空 / 文件数超限 / 失败经既有批量提示通道反馈
- 拖入去重按类型分流：
  - 文件夹按根目录 URI 精确匹配（同一目录不重复暂存，拖入与系统分享共用）
  - 文件类按 URI 精确匹配（`isAlreadyStaged`）
  - 文本类按内容精确匹配（`isTextContentStaged`，因文本条目由带时间戳的新建沙箱文件承载、URI 每次拖入均不同，无法按 URI 去重）
- 命中重复则静默跳过

## 4. 反馈与容错

- 拖拽悬停时整页叠加高亮遮罩提示
- 数据获取失败延迟 1500ms 重试一次；重试仍失败或整批类型均不支持时提示「暂不支持此类内容」且暂存列表保持不变（不跳转）
- 存在可处理内容时，放下即回到发送页：收起主页自持弹层并广播子组件收起、清空路由栈退出子页面，
  切到发送页签并把滚动位置归零，使新加入的暂存条目可见
- 拖拽结果反馈按内容可处理性区分——存在可处理内容时反馈成功（含内容因重复去重而未新增的拖入，语义为「操作已接受、仅未新增条目」），仅数据获取失败或整批类型均不支持时反馈失败

## 5. 授权与可靠性提示

- 拖入文件/文件夹 URI 的访问依赖 UDMF 拖拽默认代理授权（`READ+WRITE+PERSIST`），无需申请额外权限
- 该 URI 由来源应用/中转站托管，来源关闭后可能不可读（文本因已写入沙箱不受影响），
  故移动端会话首次拖入含文件或文件夹类内容时弹出须手动关闭的可靠性提示弹窗（`AlertDialogV2` + `autoCancel:false`，文案「文件传输期间请勿关闭中转站，否则将导致传输失败」）
- 应用侧无法区分拖入来源（`UnifiedDataProperties` 与 `DragEvent` 均不携带来源应用信息），提示按平台策略触发：2in1 上从文件管理器/桌面直接拖拽是常态且公共文件 URI 长期有效，故不弹出
