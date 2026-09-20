/**
 * SessionHeader.ets — 详情页设备卡
 *
 * 由适配器展示描述符驱动（含匿名对端兜底），外壳不含协议分支；
 * 卡片形态对齐旧传输页设备卡：设备图标 + 对端名称 + IP 短码/型号徽标 + 状态徽标。
 */

import { DesignTokens } from '../../common/DesignTokens';
import { SessionDisplayDescriptor, SessionStage } from '../../model/transfer/TransferSession';
import { getDeviceIconResource } from '../../utils/DeviceIconUtil';
import { hasDisplayText } from '../../service/transfer/adapters/SessionAdapter';
import { SessionStatusBadge } from './SessionStatusBadge';

@ComponentV2
export struct SessionHeader {
  @Require @Param display: SessionDisplayDescriptor
  @Require @Param stage: SessionStage
  @Param stageText: ResourceStr = ''
  // 对端 IP（可为空）：非空时以 IP 短码徽标呈现
  @Param peerIp: string = ''

  /** 徽标统一样式（IP 短码 / 型号共用）。 */
  @Builder
  badge(text: string) {
    Text(text)
      .fontSize(DesignTokens.font.bodyS)
      .fontColor($r('app.color.ip_blue_text'))
      .backgroundColor($r('app.color.accent_blue_bg'))
      .padding({
        left: DesignTokens.space.tiny,
        right: DesignTokens.space.tiny,
        top: DesignTokens.space.mini,
        bottom: DesignTokens.space.mini
      })
      .borderRadius(DesignTokens.radius.sm)
  }

  /** IP 末段短码（无 IP 时返回空串）。 */
  private ipShortCode(): string {
    if (this.peerIp.length === 0) {
      return '';
    }
    let idx: number = this.peerIp.lastIndexOf('.');
    return idx >= 0 ? this.peerIp.substring(idx + 1) : this.peerIp;
  }

  build() {
    Row({ space: DesignTokens.space.sm }) {
      Image(getDeviceIconResource(this.display.deviceType))
        .width(DesignTokens.size.iconLg)
        .height(DesignTokens.size.iconLg)
        .fillColor($r('app.color.text_primary'))

      Column() {
        Text(hasDisplayText(this.display.peerTitle) ? this.display.peerTitle : '--')
          .fontSize(DesignTokens.font.subtitleM)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.peerIp.length > 0 || this.display.badges.length > 0) {
          Row({ space: DesignTokens.space.tiny }) {
            if (this.peerIp.length > 0) {
              this.badge('#' + this.ipShortCode())
            }
            Repeat(this.display.badges)
              .each((ri: RepeatItem<string>) => {
                this.badge(ri.item)
              })
              .key((item: string) => item)
          }
          .margin({ top: DesignTokens.space.tiny })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SessionStatusBadge({ stage: this.stage, stageText: this.stageText })
    }
    .width('100%')
    .padding(DesignTokens.space.sm)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
    .alignItems(VerticalAlign.Center)
    .id('session_detail_header')
  }
}
