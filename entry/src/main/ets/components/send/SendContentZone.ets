/**
 * SendContentZone.ets — 发送页内容区
 *
 * 内容类型选择 + 暂存列表：无暂存内容时展示类型选择网格，有暂存内容时展示
 * 统计/添加/清空操作行与暂存条目列表（40vp 缩略图、48vp 行高、红色圆形移除按钮）。
 * 宽屏双栏下占满整高由列表内部滚动。
 */

import { DesignTokens } from '../../common/DesignTokens';
import { StagedFile } from '../../model/Types';
import { SendViewModel } from '../../viewmodel/SendViewModel';
import { formatSizeDetailed } from '../../utils/FormatUtil';
import { getFileTypeIconResource } from '../../utils/FileTypeIconUtil';

// 内容区两种状态（类型选择网格 / 暂存列表）共用的内容高度：
// 两者高度一致，切换状态时卡片高度不跳变
const CONTENT_ZONE_HEIGHT: number = 170;

@ComponentV2
export struct SendContentZone {
  @Require @Param viewModel: SendViewModel
  // 宽屏双栏：内容区占满整高（暂存列表内部滚动）
  @Param fillHeight: boolean = false
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
          this.viewModel.pickFiles();
        })
      }

      GridItem() {
        this.pickButton($r('sys.symbol.doc_plaintext_fill'), $r('app.string.send_document'), 'send_pick_document',
          () => {
            this.viewModel.pickDocuments();
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
                this.onPaste();
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
          this.onTextInput();
        })
      }

      GridItem() {
        this.pickButton($r('sys.symbol.picture_fill'), $r('app.string.send_image'), 'send_pick_image', () => {
          this.viewModel.pickImages();
        })
      }

      GridItem() {
        this.pickButton($r('sys.symbol.video_fill'), $r('app.string.send_video'), 'send_pick_video', () => {
          this.viewModel.pickVideos();
        })
      }

      GridItem() {
        this.pickButton($r('sys.symbol.music_fill'), $r('app.string.send_audio'), 'send_pick_audio', () => {
          this.viewModel.pickAudio();
        })
      }

      GridItem() {
        this.pickButton($r('sys.symbol.doc_zipper_fill'), $r('app.string.send_archive'), 'send_pick_archive', () => {
          this.viewModel.pickArchives();
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

  @Builder
  stagedList() {
    Column({ space: DesignTokens.space.mini }) {
      Repeat(this.viewModel.stagedFiles).each((ri: RepeatItem<StagedFile>) => {
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

          // 文件名（flex 自适应宽度，单行截断）
          // 文本消息条目可点击进入编辑；普通文件点击无操作（编辑能力仅面向 isManualText 标记的条目）
          Text(ri.item.fileName)
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

          // 暂存文件真实大小（statSync 结果，随暂存项缓存）
          Text(formatSizeDetailed(this.viewModel.getStagedFileSize(ri.index)))
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
              delay: ri.index * DesignTokens.animation.listAppearDelay
            })
        )
        .id('send_staged_file_item')
      }).key((item: StagedFile) => item.uri + (item.previewPixelMap !== undefined ? '#p' : ''))
    }
    .width('100%')
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
          this.viewModel.pickFiles();
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

    if (this.fillHeight) {
      Scroll() {
        this.stagedList()
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
      .layoutWeight(1)
      .width('100%')
      .margin({ top: DesignTokens.space.tiny })
    } else {
      Scroll() {
        this.stagedList()
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
      // 暂存列表自身与空态类型网格同高：仅一个文件时也不出现高度跳变
      .constraintSize({ minHeight: CONTENT_ZONE_HEIGHT, maxHeight: CONTENT_ZONE_HEIGHT })
      .width('100%')
      .margin({ top: DesignTokens.space.tiny })
    }
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
  }
}
