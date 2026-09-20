/**
 * FileRow.ets — 公共文件行组件
 *
 * 发送页暂存列表与会话详情页文件清单共用：图标 + 名称 + 大小/进度 + 可选移除。
 */

import { DesignTokens } from '../common/DesignTokens';
import { image } from '@kit.ImageKit';
import { getFileTypeIconResource } from '../utils/FileTypeIconUtil';
import { formatSizeDetailed } from '../utils/FormatUtil';

@ComponentV2
export struct FileRow {
  @Require @Param fileName: string
  @Param fileType: string = ''
  @Param fileSize: number = 0
  // 已传字节（showProgress 为 true 时参与百分比计算）
  @Param bytesSent: number = 0
  @Param showProgress: boolean = false
  // 是否提供移除入口（暂存列表使用）
  @Param removable: boolean = false
  // 图片缩略图源（暂存列表图片条目直显）
  @Param imageUri: string = ''
  // 视频缩略图（异步生成就绪后直显；未就绪时回退类型图标）
  @Param videoPreview: image.PixelMap | undefined = undefined
  @Event onRemove: () => void = () => {
  }

  private percent(): number {
    if (this.fileSize <= 0) {
      return 0;
    }
    let pct: number = (this.bytesSent * 100) / this.fileSize;
    return pct > 100 ? 100 : pct;
  }

  build() {
    Column() {
      Row({ space: DesignTokens.space.sm }) {
        if (this.imageUri.length > 0) {
          Image(this.imageUri)
            .width(DesignTokens.size.iconMd)
            .height(DesignTokens.size.iconMd)
            .borderRadius(DesignTokens.radius.sm)
            .objectFit(ImageFit.Cover)
            .autoResize(true)
        } else if (this.videoPreview !== undefined) {
          Image(this.videoPreview)
            .width(DesignTokens.size.iconMd)
            .height(DesignTokens.size.iconMd)
            .borderRadius(DesignTokens.radius.sm)
            .objectFit(ImageFit.Cover)
        } else {
          Image(getFileTypeIconResource(false, this.fileName, this.fileType))
            .width(DesignTokens.size.iconSm)
            .height(DesignTokens.size.iconSm)
            .fillColor($r('app.color.text_primary'))
        }

        Column() {
          Text(this.fileName)
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(formatSizeDetailed(this.fileSize))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: DesignTokens.space.mini })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.removable) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(DesignTokens.size.iconSm)
            .fontColor([$r('app.color.text_secondary')])
            .responseRegion({ x: -12, y: -12, width: 48, height: 48 })
            .onClick(() => {
              this.onRemove();
            })
            .accessibilityGroup(true)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.showProgress) {
        Row({ space: DesignTokens.space.sm }) {
          Progress({ value: this.percent(), total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(DesignTokens.size.progressBarHeight)
            .color($r('app.color.accent_blue'))
            .backgroundColor($r('app.color.border_light'))
            .layoutWeight(1)
          Text(Math.round(this.percent()) + '%')
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .width(DesignTokens.space.xl + 6)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .margin({ top: DesignTokens.space.tiny })
      }
    }
    .width('100%')
    .padding({ top: DesignTokens.space.tiny, bottom: DesignTokens.space.tiny })
    .id('file_row')
  }
}
