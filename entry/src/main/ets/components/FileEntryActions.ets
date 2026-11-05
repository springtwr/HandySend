/**
 * FileEntryActions.ets — 条目操作菜单（跨页公用的选项结构与菜单项集合）
 *
 * 统一「预览全文 / 打开所在位置 / 用其他应用打开」三项的展示与可用性判定：
 * 非文本类不展示预览项；超阈值时仍可截断预览（说明仅在预览弹窗/卡片内展示）；定位为空时后两项不可用；
 * 应用私有文本（收发文本落盘目录内的沙箱文件）仅「打开所在位置」不可用（私有目录无可导航位置），
 * 「用其他应用打开」走应用文件分享机制，不受影响。
 * 接收方向的图片/视频另有可选「保存到相册」项：已保存过时保留该项但置灰为「已保存到相册」，
 * 未被置灰时点击进入保存弹窗（SaveButton 授权后写入相册）。
 * 会话详情文件清单另有可选「校验和」项：仅在文件确有校验和时展示，点击弹出完整值弹窗。
 *
 * 使用约定：调用方在组件内以 `Menu() { FileEntryMenuItems(options) ... }` 包一层后绑定到行上
 * （`bindMenu`），既可在末尾追加本页专有项（接收历史页的复制文本 / 删除记录），
 * 也保证两页共用同一套菜单项实现（改一处即两页同步生效）。
 */

/** 条目操作菜单选项：可用性标志 + 回调；复制项可选（会话详情文件清单使用）。 */
export interface FileEntryMenuOptions {
  /** 是否展示「预览全文」项（非文本类不展示，与「是否可用」区分） */
  showPreviewItem: boolean
  /** 「预览全文」是否可用（文本类 + 定位非空；超阈值时为截断预览，说明仅在预览弹窗/卡片内展示） */
  canPreviewText: boolean
  /** 「打开所在位置」是否可用（定位非空） */
  canOpenLocation: boolean
  /** 「用其他应用打开」是否可用（定位非空） */
  canOpenWithApp: boolean
  onPreviewText: () => void
  onOpenLocation: () => void
  onOpenWithApp: () => void
  /** 是否展示「复制」项（可选；会话详情文件清单使用，接收历史页沿用专有复制项） */
  showCopyItem?: boolean
  /** 「复制」是否可用（文本类 + 定位非空，不受预览阈值限制） */
  canCopyText?: boolean
  onCopyText?: () => void
  /** 是否展示「保存到相册」项（可选；接收方向的图片/视频且不在图库中时展示） */
  showSaveToGallery?: boolean
  /** 「保存到相册」是否可用；为 false 时展示为「已保存到相册」并置灰 */
  canSaveToGallery?: boolean
  onSaveToGallery?: () => void
  /** 是否展示「校验和」项（可选；会话详情文件清单仅在文件有校验和时展示） */
  showChecksum?: boolean
  onShowChecksum?: () => void
}

/** 公共菜单项集合（须由调用方包在 `Menu()` 内使用）。 */
@Builder
export function FileEntryMenuItems(options: FileEntryMenuOptions) {
  if (options.showPreviewItem) {
    MenuItem({
      content: $r('app.string.session_file_preview_full'),
      startIcon: $r('sys.symbol.doc_plaintext_fill')
    })
      .enabled(options.canPreviewText)
      .onClick(() => {
        options.onPreviewText();
      })
  }
  MenuItem({
    content: $r('app.string.history_open_directory'),
    startIcon: $r('sys.symbol.folder')
  })
    .enabled(options.canOpenLocation)
    .onClick(() => {
      options.onOpenLocation();
    })
  MenuItem({
    content: $r('app.string.session_file_open_with_app'),
    startIcon: $r('sys.symbol.link')
  })
    .enabled(options.canOpenWithApp)
    .onClick(() => {
      options.onOpenWithApp();
    })
  if (options.showSaveToGallery === true) {
    MenuItem({
      // 已保存过的条目保留该项但置灰，明确标记状态而不隐藏，避免用户误以为无法保存
      content: options.canSaveToGallery === true ?
        $r('app.string.gallery_save_dialog_title') : $r('app.string.gallery_save_success')
    })
      .enabled(options.canSaveToGallery === true)
      .onClick(() => {
        if (options.onSaveToGallery !== undefined) {
          options.onSaveToGallery();
        }
      })
  }
  if (options.showCopyItem === true) {
    MenuItem({
      content: $r('app.string.copy'),
      startIcon: $r('sys.symbol.doc_plaintext_fill')
    })
      .enabled(options.canCopyText === true)
      .onClick(() => {
        if (options.onCopyText !== undefined) {
          options.onCopyText();
        }
      })
  }
  if (options.showChecksum === true) {
    MenuItem({
      content: $r('app.string.session_detail_checksum_label'),
      startIcon: $r('sys.symbol.checkmark_shield_fill')
    })
      .onClick(() => {
        if (options.onShowChecksum !== undefined) {
          options.onShowChecksum();
        }
      })
  }
}
