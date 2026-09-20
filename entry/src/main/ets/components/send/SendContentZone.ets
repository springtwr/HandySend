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
  @Event onTroubleshoot: () => void = () => {
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
    .responseRegion({ x: 0, y: 0, width: '100%', height: 48 })
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
            Image(getFileTypeIconResource(false, ri.item.fileName, ri.item.fileType))
              .width(DesignTokens.size.iconLg)
              .height(DesignTokens.size.iconLg)
          }

          // 文件名（flex 自适应宽度，单行截断）
          Text(ri.item.fileName)
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

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
          .responseRegion({ x: -16, y: -16, width: 48, height: 48 })
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
        .responseRegion({ x: -14, y: -14, width: 48, height: 48 })
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
      // 卡片外标题行（自定义标题 + 故障排查入口）
      Row() {
        Text($r('app.string.send_zone_content_title'))
          .fontSize(DesignTokens.font.titleS)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.questionmark_circle'))
          .fontSize(DesignTokens.font.titleM)
          .fontColor([$r('app.color.text_primary')])
          .responseRegion({ x: -12, y: -12, width: 48, height: 48 })
          .onClick(() => {
            this.onTroubleshoot();
          })
          .id('send_troubleshoot_entry')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: DesignTokens.space.md })

      // 内容卡片（标题在外）
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
      .margin({ top: DesignTokens.space.sm })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .id('send_content_zone')
  }
}
