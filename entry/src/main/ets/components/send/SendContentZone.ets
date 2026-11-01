/**
 * SendContentZone.ets — 发送页内容区
 *
 * 内容类型选择 + 暂存列表：无暂存内容时展示一行四个类型入口磁贴，有暂存内容时展示
 * 统计/添加/清空操作行与暂存条目列表（40vp 缩略图、48vp 行高、红色圆形移除按钮）；
 * 已选内容后再次添加时以锚在按钮下方的气泡复用同一组入口磁贴。
 * 磁贴高度、图标与字号随宽度断点放大；暂存列表按条目数取整行（最多 4 行，超出内部滚动）。
 * 列表使用 List + Repeat 懒加载（只建可视区与预加载区的行），数百个文件不会一次性建树。
 */

import { uiObserver } from '@kit.ArkUI';
import { DesignTokens } from '../../common/DesignTokens';
import { WidthBreakpointType } from '../../common/Breakpoints';
import { StagedFile } from '../../model/Types';
import { SendViewModel } from '../../viewmodel/SendViewModel';
import { getFileTypeIconResource } from '../../utils/FileTypeIconUtil';

// 类型入口磁贴：高度、图标与字号随宽度断点放大，避免宽屏下四格被压成扁条
const ACTION_TILE_HEIGHT: WidthBreakpointType<number> = new WidthBreakpointType<number>(72, 96, 112, 128);
const ACTION_ICON_SIZE: WidthBreakpointType<number> = new WidthBreakpointType<number>(24, 28, 32, 32);
const ACTION_LABEL_FONT: WidthBreakpointType<number> = new WidthBreakpointType<number>(12, 12, 14, 14);

// 「添加文件」气泡内的紧凑尺寸：气泡宽度固定，不随窗口断点放大
const ACTION_TILE_HEIGHT_COMPACT: number = 72;
const ACTION_ICON_SIZE_COMPACT: number = 24;
const ACTION_LABEL_FONT_COMPACT: number = 12;

// 暂存行高（含 40vp 缩略图、最多两行文件名、大小、移除按钮）
const STAGED_ROW_HEIGHT: number = 48;

// 暂存列表最多完整显示的行数：超出后列表内部滚动（总数已由统计行给出，无需露半行提示）
const STAGED_LIST_MAX_ROWS: number = 4;

// 入场动画错峰条数上限：超过该下标的条目不再累加延迟，
// 避免一次性选中大量文件时末条要等很久才出现
const MAX_STAGGERED_ITEM_COUNT: number = 6;

// 暂存列表预加载行数：配合 Repeat 懒加载，只保留可视区上下各若干行
const STAGED_LIST_CACHED_COUNT: number = 6;

@ComponentV2
export struct SendContentZone {
  @Require @Param viewModel: SendViewModel
  // 系统宽度断点（随窗口尺寸变化自动刷新，入口磁贴尺寸取值用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  // 「添加文件」气泡显隐：锚在按钮下方，避免底部半模态离触发点一整屏
  @Local isShowPickerPopup: boolean = false
  // 气泡收起后待执行的动作（系统选择器/文本对话框要在气泡完全消失后再打开）
  private pendingPickAction: (() => void) | undefined = undefined
  @Event onTextInput: () => void = () => {
  }
  @Event onPaste: () => void = () => {
  }
  // 点击暂存列表中文本消息条目的文件名区域时上抛（携带条目在 viewModel.stagedFiles 中的下标）；
  // 普通文件条目不触发，由宿主 SendContent 打开编辑弹窗
  @Event onEditText: (index: number) => void = (_index: number) => {
  }

  @Builder
  typePicker(compact: boolean) {
    Grid() {
      GridItem() {
        this.pickAction($r('sys.symbol.doc_text_fill'), $r('app.string.send_file'), 'send_pick_file',
          compact, () => {
            this.dispatchPick(() => {
              this.viewModel.pickFiles();
            });
          })
      }

      // 图库：图库选择器不设 MIMEType 即同时展示图片与视频并可混选
      GridItem() {
        this.pickAction($r('sys.symbol.picture_fill'), $r('app.string.send_media'), 'send_pick_media',
          compact, () => {
            this.dispatchPick(() => {
              this.viewModel.pickMedia();
            });
          })
      }

      // 粘贴：系统安全控件（PasteButton）读取剪贴板，无需额外权限；
      // 与其他磁贴同一底色与圆角（安全控件不支持透明底色，取磁贴底色保持一致）
      GridItem() {
        Column() {
          PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Normal })
            .width('100%')
            .height('100%')
            .iconSize(compact ? ACTION_ICON_SIZE_COMPACT :
              ACTION_ICON_SIZE.getValue(this.breakpointInfo.widthBreakpoint))
            .fontSize(compact ? ACTION_LABEL_FONT_COMPACT :
              ACTION_LABEL_FONT.getValue(this.breakpointInfo.widthBreakpoint))
            .borderRadius(DesignTokens.radius.md)
            .backgroundColor($r('app.color.page_background'))
            .iconColor($r('app.color.clipboard_button_icon'))
            .fontColor($r('app.color.clipboard_button_icon'))
            .layoutDirection(SecurityComponentLayoutDirection.VERTICAL)
            .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
              if (result === PasteButtonOnClickResult.SUCCESS) {
                this.dispatchPick(() => {
                  this.onPaste();
                });
              }
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .borderRadius(DesignTokens.radius.md)
        .backgroundColor($r('app.color.page_background'))
        .id('send_paste')
      }

      GridItem() {
        this.pickAction($r('sys.symbol.text_aligncenter'), $r('app.string.send_justify'), 'send_pick_justify',
          compact, () => {
            this.dispatchPick(() => {
              this.onTextInput();
            });
          })
      }
    }
    // 空态整行 1×4 铺满卡片；气泡内 2×2 紧凑排布，避免气泡横跨大半个屏幕
    .columnsTemplate(compact ? '1fr 1fr' : '1fr 1fr 1fr 1fr')
    .rowsTemplate(compact ? '1fr 1fr' : '1fr')
    .columnsGap(DesignTokens.space.inner)
    .rowsGap(DesignTokens.space.inner)
    .width('100%')
    .height(compact ? ACTION_TILE_HEIGHT_COMPACT * 2 + DesignTokens.space.inner :
      ACTION_TILE_HEIGHT.getValue(this.breakpointInfo.widthBreakpoint))
    .id(compact ? 'send_type_picker_compact' : 'send_type_picker')
  }

  // 磁贴入口：图标 + 文字，尺寸随宽度断点放大，底色与圆角与其它卡片内控件一致
  @Builder
  pickAction(icon: Resource, label: ResourceStr, itemId: string, compact: boolean, action: () => void) {
    Column() {
      SymbolGlyph(icon)
        .fontSize(compact ? ACTION_ICON_SIZE_COMPACT :
          ACTION_ICON_SIZE.getValue(this.breakpointInfo.widthBreakpoint))
        .fontColor([$r('app.color.text_primary')])
      Text(label)
        .fontSize(compact ? ACTION_LABEL_FONT_COMPACT :
          ACTION_LABEL_FONT.getValue(this.breakpointInfo.widthBreakpoint))
        .fontColor($r('app.color.text_primary'))
        .margin({ top: DesignTokens.space.tiny })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .borderRadius(DesignTokens.radius.md)
    .backgroundColor($r('app.color.page_background'))
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
    .onClick(() => {
      action();
    })
    .id(itemId)
  }

  // 磁贴动作统一分发：气泡未打开时直接执行；气泡打开时先收起，
  // 待气泡收起（onStateChange）后再执行后续动作，避免系统选择器/对话框与气泡叠层
  private dispatchPick(action: () => void): void {
    if (!this.isShowPickerPopup) {
      action();
      return;
    }
    this.pendingPickAction = action;
    this.isShowPickerPopup = false;
  }

  // 气泡收起后执行待办动作；用户直接关闭气泡时无待办动作，不产生副作用
  private runPendingPick(): void {
    let action: (() => void) | undefined = this.pendingPickAction;
    this.pendingPickAction = undefined;
    if (action !== undefined) {
      action();
    }
  }

  // 「添加文件」气泡内容：复用空态的类型入口磁贴，紧凑尺寸（气泡宽度固定，不随窗口断点放大）
  @Builder
  pickerPopup() {
    Column() {
      this.typePicker(true)
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .id('send_add_files_popup')
  }

  // 暂存列表条目：行内容（缩略图 / 文件名 / 大小 / 移除按钮）。
  // 列表本身由 stagedSection 中的 List 承载（配合 Repeat 懒加载，只建可视区的行）
  @Builder
  stagedRow(ri: RepeatItem<StagedFile>) {
    Row({ space: DesignTokens.space.sm }) {
      // 缩略图 40vp（行高 48）：图片源直显，视频用异步生成的缩略图，其余回退类型图标
      if (ri.item.isImage) {
        Image(ri.item.uri)
          .width(DesignTokens.size.iconLg)
          .height(DesignTokens.size.iconLg)
          .borderRadius(DesignTokens.radius.sm)
          .objectFit(ImageFit.Cover)
          .autoResize(true)
      } else if (ri.item.previewPixelMap !== undefined) {
        Image(ri.item.previewPixelMap)
          .width(DesignTokens.size.iconLg)
          .height(DesignTokens.size.iconLg)
          .borderRadius(DesignTokens.radius.sm)
          .objectFit(ImageFit.Cover)
      } else {
        // 文本消息（isManualText 标记）显示消息图标，与接收历史列表一致；
        // 普通 .txt 文件不带该标记，仍按 MIME 显示文本文件图标
        Image(getFileTypeIconResource(ri.item.isManualText === true, ri.item.fileName, ri.item.fileType))
          .width(DesignTokens.size.iconLg)
          .height(DesignTokens.size.iconLg)
      }

      // 文件名（flex 自适应宽度，最多两行，超出尾部截断）。
      // 文本消息条目不展示沙箱文件名（内部实现细节），直接展示正文预览，便于分辨内容；
      // 文本消息条目可点击进入编辑；普通文件点击无操作（编辑能力仅面向 isManualText 标记的条目）
      Text(ri.item.isManualText === true && ri.item.textPreview !== undefined ?
        ri.item.textPreview : ri.item.fileName)
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_primary'))
        // 文件名最多两行，超长尾部截断（48vp 行高内垂直居中）
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .onClick(() => {
          // 仅文本消息条目上抛编辑事件；普通文件（含 .txt）点击保持原行为（无操作）
          if (ri.item.isManualText === true) {
            this.onEditText(ri.index);
          }
        })
        .id('send_staged_file_edit')

      // 暂存文件真实大小（异步补全；未就绪时显示占位）
      Text(this.viewModel.getStagedFileSizeText(ri.index))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .margin({ left: DesignTokens.space.xxs })

      // 红底圆形移除按钮（热区 48vp）
      Row() {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(DesignTokens.font.iconXs)
          .fontColor([$r('app.color.text_on_color')])
      }
      .width(DesignTokens.size.iconXs)
      .height(DesignTokens.size.iconXs)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.danger_red'))
      .borderRadius(DesignTokens.radius.max)
      .responseRegion({
        x: -16,
        y: -16,
        width: 48,
        height: 48
      })
      .onClick(() => {
        this.viewModel.removeStagedFile(ri.index);
      })
      .id('send_staged_file_remove')
    }
    .width('100%')
    .height(STAGED_ROW_HEIGHT)
    .alignItems(VerticalAlign.Center)
    .onAppear(() => {
      // 视频缩略图懒生成（方法内部有类型与去重防护，非视频直接返回）
      this.viewModel.loadVideoPreview(ri.index);
    })
    .transition(
      TransitionEffect.OPACITY
        .combine(TransitionEffect.scale({ x: 0.8, y: 0.8 }))
        .animation({
          duration: 300,
          curve: Curve.FastOutSlowIn,
          // 仅首屏若干条错峰入场：延迟按实际下标线性递增时，批量选入的文件越多末条越晚出现
          // （缩略图到达导致条目按 key 重建时也会重复这段等待）
          delay: Math.min(ri.index, MAX_STAGGERED_ITEM_COUNT) * DesignTokens.animation.listAppearDelay
        })
    )
    .id('send_staged_file_item')
  }

  // 暂存列表高度：按条目数取整行，最多 STAGED_LIST_MAX_ROWS 行；放得下时贴合内容，不留空白
  private stagedListHeight(): number {
    let count: number = this.viewModel.stagedFiles.length;
    if (count <= 0) {
      return 0;
    }
    let rows: number = Math.min(count, STAGED_LIST_MAX_ROWS);
    return rows * STAGED_ROW_HEIGHT + (rows - 1) * DesignTokens.space.mini;
  }

  @Builder
  stagedSection() {
    // 操作行：统计 + 添加 + 清空
    Row({ space: DesignTokens.space.sm }) {
      Text($r('app.string.send_file_count_total', this.viewModel.stagedFiles.length,
        this.viewModel.getTotalSizeText()))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
      Text($r('app.string.send_add_files'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.accent_blue'))
        .onClick(() => {
          this.isShowPickerPopup = !this.isShowPickerPopup;
        })
        // 「添加文件」气泡：锚在按钮正下方，再次点击按钮或点外部均收起
        .bindPopup(this.isShowPickerPopup, {
          builder: () => {
            this.pickerPopup();
          },
          placement: Placement.Bottom,
          // 2 列紧凑磁贴 + 左右各 16vp 内边距
          width: 220,
          radius: DesignTokens.radius.lg,
          popupColor: $r('app.color.card_background'),
          enableArrow: false,
          autoCancel: true,
          offset: { x: 0, y: 6 },
          // 显隐状态由气泡回调回写：点空白收起时也能复位，否则再次点击无法重新弹出；
          // 收起后再执行所选动作，避免系统选择器/对话框与气泡叠层
          onStateChange: (event: PopupStateChangeParam) => {
            this.isShowPickerPopup = event.isVisible;
            if (!event.isVisible) {
              this.runPendingPick();
            }
          }
        })
        // 暂存清空后该按钮随列表一起销毁：显式复位，避免下次暂存时气泡自动弹出
        .onDisAppear(() => {
          this.isShowPickerPopup = false;
        })
        .id('send_add_files')
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(DesignTokens.font.iconInline)
        .fontColor([$r('app.color.text_tertiary')])
        .responseRegion({
          x: -14,
          y: -14,
          width: 48,
          height: 48
        })
        .onClick(() => {
          this.viewModel.clearStagedFiles();
        })
        .id('send_clear_files')
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)

    // 列表高度随条目数取整行，最多 4 行；少量文件时贴合内容，超出后列表内部滚动。
    // List 自身即滚动容器（配合 Repeat 的 virtualScroll 懒加载），不再外套 Scroll
    List({ space: DesignTokens.space.mini }) {
      Repeat(this.viewModel.stagedFiles).each((ri: RepeatItem<StagedFile>) => {
        ListItem() {
          this.stagedRow(ri)
        }
      })
        .key((item: StagedFile) => item.uri + (item.previewPixelMap !== undefined ? '#p' : '') +
          (item.size !== undefined ? '#s' : ''))
        .virtualScroll({ totalCount: this.viewModel.stagedFiles.length })
    }
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .cachedCount(STAGED_LIST_CACHED_COUNT)
    .height(this.stagedListHeight())
    .width('100%')
    .margin({ top: DesignTokens.space.tiny })
  }

  build() {
    Column() {
      // 内容卡片（页内标题行与常见问题入口已迁入外层标题栏）
      Column() {
        if (this.viewModel.stagedFiles.length === 0) {
          this.typePicker(false)
        } else {
          this.stagedSection()
        }
      }
      .width('100%')
      .padding({
        left: DesignTokens.space.card,
        right: DesignTokens.space.card,
        top: this.viewModel.stagedFiles.length === 0 ? DesignTokens.space.card : DesignTokens.space.sm,
        bottom: this.viewModel.stagedFiles.length === 0 ? DesignTokens.space.card : DesignTokens.space.sm
      })
      .borderRadius(DesignTokens.radius.lg)
      .backgroundColor($r('app.color.card_background'))
      .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
      // 卡片高度随内容：空态只有一行入口磁贴（72~128，随宽度断点），加入首个文件后长到列表高度
      // 卡片成为内容区首元素：沿用原标题行的顶部间距，避免内容贴顶
      .margin({ top: DesignTokens.space.md })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .id('send_content_zone')
  }
}
