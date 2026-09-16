# 系统剪贴板内容生命周期与易失原因

> 调查"系统剪贴板过一段时间没有内容、而输入法剪贴板仍有内容"现象的原因，说明系统剪贴板的覆盖/清空机制、与输入法剪贴板的差异，以及 HandySend 自身对剪贴板的影响。结论均以华为官方文档为出处，用于用户答疑，不指导任何剪贴板写入策略的修改。

## 1. 结论摘要

| 结论 | 说明 | 官方出处 |
|---|---|---|
| 系统剪贴板是"最后写入者覆盖"的单一内容槽 | 任意应用一次复制都会整体替换剪贴板既有内容，只保留最近一条 | [§2](#2-系统剪贴板为最后写入者覆盖的单一内容槽) |
| 输入法剪贴板是独立的持久化多槽历史 | 由输入法应用自行维护多条历史，与系统剪贴板是两个数据源 | [§3](#3-输入法剪贴板是独立的持久化多槽历史) |
| 系统剪贴板内容非持久化，系统重启即清空 | 内容存于剪贴板系统服务，重启后不复存在 | [§4](#4-系统剪贴板内容非持久化系统重启即清空) |
| API 12+ 剪贴板读取受限但写入不受限 | 读取需权限或安全控件、后台更受限；复制写入无需权限 | [§5](#5-api-12-剪贴板读取受限写入不受限) |
| HandySend 仅经 `ClipboardUtil.copyText` 写入，无主动清空 | 全库无 `clearData`/`clearDataSync` 调用，不覆盖用户剪贴板 | [§6](#6-handysend-对系统剪贴板的影响) |

## 2. 系统剪贴板为"最后写入者覆盖"的单一内容槽

系统剪贴板由剪贴板系统服务维护，内容槽是**单一**的：任意应用通过 `setData` 写入一次，即为一次整体替换。

官方依据（`@ohos.pasteboard (剪贴板)` API 参考，`setData` 说明）：

> 写入的数据会替换剪贴板中已有的内容。

- 一次复制产生的 `PasteData` 可携带多条记录（Record）与同份数据的不同格式（Entry），但**对整个系统剪贴板而言始终只有一份 PasteData**，不存在多份历史。
- 因此场景中的"系统剪贴板过一段时间没有内容"一是被其他应用的复制操作整体替换（包括后台应用），二是内容过期或系统重启（见 §4）。用户在输入法剪贴板还能看到旧条目，是因为那是另一份独立的历史（见 §3）。

**出处**：开发指南《使用剪贴板进行复制粘贴》（use-pasteboard-to-copy-and-paste）、API 参考《@ohos.pasteboard (剪贴板)》（js-apis-pasteboard）。

## 3. 输入法剪贴板是独立的持久化多槽历史

输入法剪贴板（如系统中输入法应用自带的剪贴板历史）由**输入法应用自身**基于其剪贴板访问权限读取并持久化维护，保存多条历史记录，与系统剪贴板是**两个独立数据源**。

官方依据（FAQ《剪贴板权限管控疑问》）：

> 输入法已申请读取剪贴板权限，用户通过输入法选中某条复制的内容进行粘贴……

- 输入法应用保存的是它读取过的剪贴板内容快照历史，可保留多槽；而系统剪贴板只保留最近一次写入（§2）。
- 这就是"系统剪贴板里没了、输入法剪贴板里还有"的直接原因——用户看到的是输入法自身的持久化历史，而非系统剪贴板当前内容。
- 输入法维护的剪贴板历史属输入法应用的本地数据（一般会随输入法清理/卸载清空或按策略限制条数），不在本应用或系统剪贴板服务的生命周期内。

**出处**：FAQ《剪贴板权限管控疑问》（faq-basics-service-kit-49）。

## 4. 系统剪贴板内容非持久化，系统重启即清空

系统剪贴板内容存储在**剪贴板系统服务**中（与 `PasteDataProperty` 时间戳等元数据一起在系统侧维护），并非持久化到磁盘，设备重启后不复存在。

官方依据（`@ohos.pasteboard (剪贴板)` API 参考，剪贴板内容变化次数说明）：

> 当剪贴板内容过期或调用 `clearDataSync` 等接口导致剪贴板内容为空时，内容变化次数不会因此改变。系统重启或剪贴板服务异常重启时，剪贴板内容变化次数重新从 0 开始计数。

- 上述引文直接证实"系统重启/剪贴板服务异常重启"会重置剪贴板状态（内容随之清空），且存在"内容过期"机制，说明剪贴板内容本身不具备持久化保证。
- 相同出处（API 参考）的 `clearData`/`clearDataSync` 说明也明确：清空成功后 `hasData` 返回 false，剪贴板空槽。

**出处**：API 参考《@ohos.pasteboard (剪贴板)》（js-apis-pasteboard，`getChangeCount`/`clearData` 说明）。

## 5. API 12+ 剪贴板读取受限，写入不受限

API version 12 起，为提升隐私安全保护，系统对剪贴板**读取**接口增加权限管控；**写入（复制）不受管控**。

官方依据（《申请访问剪贴板权限》）：

> API version 12及之后，系统为提升用户隐私安全保护能力，剪贴板读取接口增加权限管控。

涉及读取管控的接口包括 `getData`/`getDataSync`/`getUnifiedData`/`getUnifiedDataSync`（以及 NDK 对应接口）。两种合法读取途径：

1. **安全控件（粘贴控件 PasteButton）**：使用粘贴控件访问剪贴板的应用**无需申请权限**，属"用户点击即许可"的临时授权，且不弹窗。
2. **`ohos.permission.READ_PASTEBOARD` 权限**：受限的 user_grant（用户授权）权限，申请后按用户授权场景读取。

写入侧不受限，官方依据（FAQ《剪贴板权限管控疑问》）：

> 复制内容是系统默认支持的能力，不需要额外申请权限。

**出处**：开发指南《申请访问剪贴板权限》（get-pastedata-permission-guidelines）、API 参考《@ohos.pasteboard (剪贴板)》（getData 的权限说明）、FAQ《剪贴板权限管控疑问》（faq-basics-service-kit-49）。

## 6. HandySend 对系统剪贴板的影响

HandySend 全库中，系统剪贴板写入仅此一处：

- `entry/src/main/ets/utils/ClipboardUtil.ets` 的 `copyText(text)`：`pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)` 后调用 `pasteboard.getSystemPasteboard().setData(pasteData)`。

全库检索确认：**不存在任何 `clearData`/`clearDataSync` 调用**，即 HandySend 从不主动清空系统剪贴板；也仅此一处 `setData` 写入。因此：

- HandySend 只可能在用户主动点击"复制"类操作时**覆盖**系统剪贴板为最新一次复制的内容（符合 §2 的最后写入者覆盖机制）。
- "系统剪贴板内容消失"不会是 HandySend 主动清空造成；应用层的原因只能是"被其他应用的复制覆盖"或平台侧的过期/重启清空（§2/§4）。

## 7. 本应用读取剪贴板使用的接口与授权机制

HandySend 经发送页粘贴控件（`PasteButton`）读取剪贴板，链路位于 `entry/src/main/ets/components/SendContent.ets`：

1. `PasteButton` 为系统安全控件，点击后系统执行授权校验，回调返回 `PasteButtonOnClickResult`：
   - `SUCCESS`（0）：本次点击获得当前剪贴板内容的临时读取权限，可继续读取；
   - `TEMPORARY_AUTHORIZATION_FAILED`（1）：授权未成功（如控件样式不合法、被遮挡、字体/图标颜色相近等），此时不应继续读取剪贴板内容。
2. 授权成功后按官方推荐的"预检优先"做法读取（该方法来自《申请访问剪贴板权限》的剪贴板弹窗适配优化建议，本应用据此避免无效读取与提示歧义）：
   - `pasteboard.getSystemPasteboard().hasData(): Promise<boolean>`：先判断剪贴板是否有内容，无内容则提示"剪贴板为空"且不发起 `getData`；
   - `pasteboard.getSystemPasteboard().hasDataType(pasteboard.MIMETYPE_TEXT_PLAIN): boolean`：再判断是否含纯文本，仅有图片/文件/HTML 等非文本内容时同样按"剪贴板为空"处理；
   - `getData(): Promise<pasteboard.PasteData>`：两道预检均通过后才读取数据本体；
   - `PasteData.getPrimaryText(): string`：取第一条纯文本，无纯文本时返回 `undefined`，本应用将其规范化为 `''` 再进入暂存链路（空串由视图模型层按"剪贴板为空"兜底）。
3. 读取过程中 `getData` 抛异常（剪贴板服务异常、数据损坏等）时提示"读取剪贴板失败"。

**出处**：开发指南《使用粘贴控件》（pastebutton）、API 参考《PasteButton》（ts-security-components-pastebutton，《@ohos.pasteboard (剪贴板)》js-apis-pasteboard、《申请访问剪贴板权限》（get-pastedata-permission-guidelines）。