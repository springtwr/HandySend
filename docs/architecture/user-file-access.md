# 用户文件访问（选择、授权与句柄）

> 隶属架构文档；项目全貌见 [ARCHITECTURE.md](../ARCHITECTURE.md)。本主题覆盖发送侧的
> 文件选择上限、Picker URI 授权持久化、暂存句柄复用，以及任务详情页的文件清单与缩略图策略。

## 1. 选择入口与数量上限

| 入口 | 选择器 | 单次上限 | 备注 |
|---|---|---|---|
| 文件 | `DocumentViewPicker` | 100 | 文档选择器自身上限 500，应用收敛到 100 |
| 图库（图片和视频） | `PhotoViewPicker` | 100 | 不设 `MIMEType`，默认混选图片与视频 |
| 粘贴 | 系统安全控件 `PasteButton` | — | 不经过 Picker，读剪贴板纯文本 |
| 文本 | 应用内输入弹窗 | — | 不经过 Picker，正文写入沙箱文本文件 |

发送页仅提供上述四个入口，音频、文档、压缩包等统一从「文件」入口选择。
`DocumentSelectOptions.defaultFilePathUri` 为空时选择器落在文件管理器的「最近访问」页，
该页只列最近 30 天内访问过的文件（系统 UI 策略，应用侧无法改为默认展示全部），
更早的文件需用户切到「浏览」页按目录查找。鸿蒙 7 的文件选择器在「浏览」页提供分类聚合，
更早版本没有。

图库入口合并图片与视频后，暂存项按扩展名区分两者（`isImageExtension`）：图片直接显示缩略图，
视频由 `loadVideoPreview` 懒生成缩略图（多个视频按请求顺序串行解码），其余类型回退类型图标。

上限常量为 `SendViewModel.ets` 顶部的 `MAX_PICK_SELECT_NUMBER`，两个 Picker 入口共用。

`StagedFile` 记录文件名、MIME、图片标记、源修改时间与真实大小；大小与修改时间在选择返回后
由 `prefetchStagedMeta` 异步补全（受限并发、不阻塞 UI），补全完成前列表显示占位 `—`。
手输文本条目另记正文预览 `textPreview`（换行折叠为空格），列表以正文代替沙箱文件名展示。

## 2. Picker URI 的授权

Picker 返回的 URI（`file://media/...`、`file://docs/...`）只带临时授权，**超过有效期后失效**
（与进程是否重启无关；文件数量少时测试时间短，容易误判为授权一直有效）。

处理方式（`utils/UriPermission.ets`）：

- **选择后立即持久化**：`persistPickedUris` 调 `fileShare.persistPermission`（只读），
  把临时授权写入系统数据库（不占应用存储、不复制文件）；
- **访问前激活**：`ensureUriAccess` 调 `fileShare.activatePermission`，按下述时机调用：
  缩略图解码前（`FileEntryThumb`）、打开类动作探测前（`FileLocationUtil`）；
  进程内用集合缓存成功/失败结果，避免重复 IPC；
- **删除时撤销**：清空或删除任务历史时 `revokeUriAccess` 撤销这些 URI 的持久化授权。

所需权限 `ohos.permission.FILE_ACCESS_PERSIST`（`system_grant`、normal 级）在 `module.json5`
声明；能力是否存在用 `canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization')`
判定，不支持时静默降级。

未持久化过的历史条目（旧版本产生）无法激活，读取时按不可用降级并提示「文件暂不可用」。

### 2.1 接收目录的选择与授权

接收侧普通文件的保存目录由 `service/repository/ReceiveDirectory.ets` 唯一提供，LocalSend、网页上传与
MTA 三条接收链路共用，禁止各自解析路径。

- **默认目录**：`DocumentViewPicker.save` 的 DOWNLOAD 模式取 `Download/<包名>/`，
  返回的 URI 自带持久化授权；Picker 不可用时回退直接构造同一路径的文档类 URI。
- **自定义目录**：设置页「文件保存目录」经 `DocumentViewPicker.select` 的 `FOLDER`
  模式选择，随后调用 `persistWritableUri` 持久化 `READ_MODE | WRITE_MODE` 授权；
  接收前经 `ensureWritableUriAccess` 激活。URI 存入设置项 `receiveDirectoryUri`，
  空串表示默认目录。
- **设备限制**：`FOLDER` 选择在手机/平板需 API 26+（2in1 13+），设置项按产品要求
  统一以 API 26 为界置灰；低版本设备只能使用默认目录。
- **重启后激活**：应用启动时 `activateConfiguredReceiveDirectory` 激活当前自定义目录的持久授权；
  接收历史/详情页按路径读取文件时，`FileLocationUtil` 在无权限时会尝试激活文件所在目录 URI。
- **路径展示**：相对路径中的特殊目录段按当前语言映射为文件管理器显示名
  （`Huawei Share` → 华为分享，`HO_DATA_EXT_MISC` → 兼容应用数据）；
  官方未提供内部名到显示名的查询接口，映射表由应用维护。
- **失效回退**：自定义目录被删除、移动或授权被撤销时，`ensureReceiveDirectory`
  回退默认目录、清除该设置并记录日志，设置页经变更通知同步刷新为默认目录；
  目录缓存按设置值比较，且命中时仍校验目录可访问，失效后下一次接收自动重新解析。
  LocalSend 接收（含纯文本放行后）、网页上传普通文件、MTA 文件接收或设置页
  会消费一次性回退提示，用 Toast 告知用户保存位置已改为默认目录。

## 3. 暂存句柄与复用

`SendViewModel` 为暂存项保留只读句柄（`stagedHandles`，上限 400，对应「4 次 × 100 个」的常见组合），
用于避免同一批文件被反复 open：

| 使用方 | 复用方式 |
|---|---|
| 发送（`sendToDevice`） | `fs.dup(sourceFd)` 后交 Rust，Rust 取得副本所有权；Rust 以 pread 从文件头读取 |
| 校验和（`calculateChecksumsForFiles`） | `fs.dup(sourceFd)` 后读取前 `fs.lseek` 归位共享偏移 |
| 网页分享（`createShareLink` / `updateShareFiles`） | **借用**同一 fd 登记进文件表，不额外占用 |

`dup` 副本与暂存句柄共享文件偏移。发送链路在 Rust 侧用 `pread` 按显式偏移读取，
既不推进也不依赖共享偏移，因此重发以及多目标并发复用同一句柄都不会读错位置；
读取出错时上传立即中止并向发送侧报错，避免把截断内容当作完整文件发送。
校验和链路仍走顺序读，读取前统一 `fs.lseek(fd, 0, SEEK_SET)` 归位。

网页服务的下载链路对每个文件自行 `dup` 副本、不取得所有权，因此可以借用暂存句柄。借用的
句柄由暂存区负责关闭；`closeStagedHandle` 发现该文件仍在分享表（`isSharingPath`）时转入
延迟关闭，待分享表更新成功（`flushDeferredHandles`）后再关闭，避免原生层读到已关闭的 fd。

句柄在 `dup` / 借用前会校验大小：若句柄已被关闭且编号被其他文件复用，大小不一致则回退
按路径打开，防止发出错误内容。

句柄上限用尽后（暂存超过 400 个）其余条目在发送时按路径打开，功能不受影响、仅耗时增加。

## 4. 详情页缩略图

`FileEntryThumb` 自行打开句柄并用 `ImageSource` 按展示尺寸（约 80×80）解码成 PixelMap：

- 不把 `file://media/...` 直接交给 `Image`，否则失败时拿不到错误原因；
- 仅在该行滚入可视区时加载；首屏后 12 行按 90 ms 错峰预加载，滚动时缩略图已就绪；
- 不落盘任何缩略图缓存（大批量传图会显著增加应用占用空间）；
- 解码失败显示类型图标，重新滚入可视区时重试；图片/视频加载中显示占位块，避免图标闪烁。

## 5. 详情页文件清单

文件清单首屏渲染 40 行，底部「还有 N 个文件，点击加载更多」每次追加 60 行
（`SessionDetailViewModel.visibleFileCount`）。数百行的会话不会一次性建树，
建行与解码开销分摊到用户操作中。

## 6. 任务历史存储

任务历史按段写入 Preferences（段大小 250 条、目标 750 条、硬上限 1000 条，见 `model/HistoryCapacity.ets`），
单条会话包含全部文件明细（文件名、类型、大小、路径、校验和、阶段），体积随文件数线性增长；
100 文件批次单条约 35-43KB，满段约 10.5MB。写入时只序列化一次并直接写字符串，
并输出 `历史段写入 <键> 条目=N 字符=M` 便于观测体积（字符数不等于 UTF-8 字节数）。
