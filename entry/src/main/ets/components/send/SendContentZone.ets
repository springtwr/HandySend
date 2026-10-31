/**
 * SendContentZone.ets — 发送页内容区
 *
 * 内容类型选择 + 暂存列表：无暂存内容时展示类型选择网格，有暂存内容时展示
 * 统计/添加/清空操作行与暂存条目列表（40vp 缩略图、48vp 行高、红色圆形移除按钮）；
 * 已选内容后再次添加时以半模态复用同一类型选择网格。
 * 两种状态共用同一内容高度；暂存列表使用 List + Repeat 懒加载（只建可视区与预加载区的行），
 * 数百个文件不会一次性建树。
 */

import { uiObserver } from '@kit.ArkUI';
import { DesignTokens } from '../../common/DesignTokens';
import { getSheetWidth, isWideWidth } from '../../common/Breakpoints';
import { StagedFile } from '../../model/Types';
import { SendViewModel } from '../../viewmodel/SendViewModel';
import { getFileTypeIconResource } from '../../utils/FileTypeIconUtil';

// 内容区两种状态（类型选择网格 / 暂存列表）共用的内容高度：
// 两者高度一致，切换状态时卡片高度不跳变
const CONTENT_ZONE_HEIGHT: number = 170;

// 入场动画错峰条数上限：超过该下标的条目不再累加延迟，
// 避免一次性选中大量文件时末条要等很久才出现
const MAX_STAGGERED_ITEM_COUNT: number = 6;

// 暂存列表预加载行数：配合 Repeat 懒加载，只保留可视区上下各若干行
const STAGED_LIST_CACHED_COUNT: number = 6;

@ComponentV2
export struct SendContentZone {
  @Require @Param viewModel: SendViewModel
  // 系统宽度断点（随窗口尺寸变化自动刷新，添加文件面板宽度断点化用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  // 「添加文件」半模态显隐：已选文件后再以与空态一致的 8 宫格选择内容类型
  @Local isShowPickerSheet: boolean = false
  // 面板收起后待执行的动作（系统选择器/文本对话框要在面板完全消失后再打开）
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
  typePicker() {
    Grid() {
      GridItem() {
        this.pickButton($r('sys.symbol.doc_text_fill'), $r('app.string.send_file'), 'send_pick_file', () => {
          this.dispatchPick(() => {
            this.viewModel.pickFiles();
          });
        })
      }

      GridItem() {
        this.pickButton($r('sys.symbol.doc_plaintext_fill'), $r('app.string.send_document'), 'send_pick_document',
          () => {
            this.dispatchPick(() => {
              this.viewModel.pickDocuments();
            });
          })
      }

      GridItem() {
        // 粘贴：使用系统安全控件（PasteButton）读取剪贴板，无需额外权限
        Column() {
          PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Normal })
            .width('100%')
            .height(66)
            .iconSize(DesignTokens.font.iconInline)
            .fontSize(DesignTokens.font.bodyS)
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
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 7, bottom: 7 })
        .borderRadius(DesignTokens.radius.md)
        .backgroundColor($r('app.color.page_background'))
        .id('send_paste')
      }

      GridItem() {
        this.pickButton($r('sys.symbol.text_aligncenter'), $r('app.string.send_justify'), 'send_pick_justify', () => {
          this.dispatchPick(() => {
            this.onTextInput();
          });
        })
      }

      GridItem() {
        this.pickButton($r('sys.symbol.picture_fill'), $r('app.string.send_image'), 'send_pick_image', () => {
          this.dispatchPick(() => {
            this.viewModel.pickImages();
          });
        })
      }

      GridItem() {
        this.pickButton($r('sys.symbol.video_fill'), $r('app.string.send_video'), 'send_pick_video', () => {
          this.dispatchPick(() => {
            this.viewModel.pickVideos();
          });
        })
      }

      GridItem() {
        this.pickButton($r('sys.symbol.music_fill'), $r('app.string.send_audio'), 'send_pick_audio', () => {
          this.dispatchPick(() => {
            this.viewModel.pickAudio();
          });
        })
      }

      GridItem() {
        this.pickButton($r('sys.symbol.doc_zipper_fill'), $r('app.string.send_archive'), 'send_pick_archive', () => {
          this.dispatchPick(() => {
            this.viewModel.pickArchives();
          });
        })
      }
    }
    // 固定两行高度：Grid 组件默认撑满可用高度，不显式限高会在卡片内留下大片空白
    .columnsTemplate('1fr 1fr 1fr 1fr')
    .rowsTemplate('1fr 1fr')
    .columnsGap(DesignTokens.space.inner)
    .rowsGap(DesignTokens.space.inner)
    .width('100%')
    .height(CONTENT_ZONE_HEIGHT)
    .id('send_type_picker')
  }

  @Builder
  pickButton(icon: Resource, label: ResourceStr, itemId: string, action: () => void) {
    Column() {
      SymbolGlyph(icon)
        .fontSize(DesignTokens.font.iconInline)
        .fontColor([$r('app.color.text_primary')])
      Text(label)
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: DesignTokens.space.tiny })
    }
    .width('100%')
    // 与「粘贴」安全控件同高：卡片内边距取 card（上下各 20vp），使各按钮在 1fr 行内一致铺满
    .padding({ top: DesignTokens.space.card, bottom: DesignTokens.space.card })
    .borderRadius(DesignTokens.radius.md)
    .backgroundColor($r('app.color.page_background'))
    .alignItems(HorizontalAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
    .onClick(() => {
      action();
    })
    .id(itemId)
  }

  // 宫格动作统一入口：面板未打开时直接执行；面板打开时先收起，
  // 待面板完全消失（onDisappear）后再执行后续动作，避免系统选择器/对话框与面板叠层
  private dispatchPick(action: () => void): void {
    if (!this.isShowPickerSheet) {
      action();
      return;
    }
    this.pendingPickAction = action;
    this.isShowPickerSheet = false;
  }

  // 面板回退动画结束后执行待办动作；用户直接关闭面板时无待办动作，不产生副作用
  private runPendingPick(): void {
    let action: (() => void) | undefined = this.pendingPickAction;
    this.pendingPickAction = undefined;
    if (action !== undefined) {
      action();
    }
  }

  // 「添加文件」半模态内容：复用空态的类型选择网格，已选文件后仍以相同的 8 宫格选择类型
  @Builder
  pickerSheet() {
    Column() {
      this.typePicker()
    }
    .width('100%')
    .padding({
      left: DesignTokens.space.card,
      right: DesignTokens.space.card,
      top: DesignTokens.space.sm,
      bottom: DesignTokens.space.card
    })
    .id('send_add_files_sheet')
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

      // 文件名（flex 自适应宽度，单行截断）。
      // 文本消息条目不展示沙箱文件名（内部实现细节）：改用带序号的“文本”标签，多条时可分辨；
      // 文本消息条目可点击进入编辑；普通文件点击无操作（编辑能力仅面向 isManualText 标记的条目）
      Text(ri.item.isManualText === true ? $r('app.string.staged_text_title', ri.index + 1) : ri.item.fileName)
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
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
    .height(48)
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
          this.isShowPickerSheet = true;
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

    // 暂存列表自身与空态类型网格同高：仅一个文件时也不出现高度跳变。
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
    .constraintSize({ minHeight: CONTENT_ZONE_HEIGHT, maxHeight: CONTENT_ZONE_HEIGHT })
    .width('100%')
    .margin({ top: DesignTokens.space.tiny })
  }

  build() {
    Column() {
      // 内容卡片（页内标题行与故障排查入口已迁入外层标题栏）
      Column() {
        if (this.viewModel.stagedFiles.length === 0) {
          this.typePicker()
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
      // 空态类型 grid 与暂存文件列表共用同一最小高度，避免只选一个文件时卡片高度跳变
      .constraintSize({ minHeight: DesignTokens.size.cardMinHeight })
      // 卡片成为内容区首元素：沿用原标题行的顶部间距，避免内容贴顶
      .margin({ top: DesignTokens.space.md })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .id('send_content_zone')
    // 「添加文件」半模态：与项目其他面板一致的宽度/居中策略，高度按 8 宫格内容自适应
    .bindSheet($$this.isShowPickerSheet, this.pickerSheet(), {
      height: SheetSize.FIT_CONTENT,
      width: getSheetWidth(this.breakpointInfo.widthBreakpoint),
      preferType: isWideWidth(this.breakpointInfo.widthBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
      blurStyle: BlurStyle.Regular,
      title: {
        title: $r('app.string.send_add_files')
      },
      showClose: true,
      // 面板完全收起后再执行所选动作：系统选择器会覆盖整页，文本输入会再开对话框
      onDisappear: () => {
        this.runPendingPick();
      }
    })
  }
}
