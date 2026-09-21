/**
 * SessionHeader.ets — 详情页设备卡
 *
 * 由适配器展示描述符驱动（含匿名对端兜底），外壳不含协议分支；
 * 单层卡片容器（card_background + 圆角 lg + 边框）内直接排布
 * 设备图标 + 对端名称 + 来源/发送方式徽标 + 型号徽标 + 状态徽标；
 * 设备指纹默认单行缩略，点击后弹出完整指纹。
 */

import { DesignTokens } from '../../common/DesignTokens';
import { SessionDisplayDescriptor, SessionStage } from '../../model/transfer/TransferSession';
import { getDeviceIconResource } from '../../utils/DeviceIconUtil';
import { hasDisplayText } from '../../service/transfer/adapters/SessionAdapter';
import { SessionStatusBadge } from './SessionStatusBadge';

// 指纹缩略保留的首/尾字符数（中间以省略号连接，避免仅末尾截断丢失尾段信息）
const FINGERPRINT_HEAD_LEN: number = 11;
const FINGERPRINT_TAIL_LEN: number = 8;

/** 指纹中间缩略：长度不足时原样返回，否则保留首尾字符并以省略号连接。 */
function abbreviateFingerprint(value: string): string {
  if (value.length <= FINGERPRINT_HEAD_LEN + FINGERPRINT_TAIL_LEN + 1) {
    return value;
  }
  return value.substring(0, FINGERPRINT_HEAD_LEN) + '…' + value.substring(value.length - FINGERPRINT_TAIL_LEN);
}

@ComponentV2
export struct SessionHeader {
  @Require @Param display: SessionDisplayDescriptor
  @Require @Param stage: SessionStage
  @Param stageText: ResourceStr = ''
  // 来源/发送方式标签（LocalSend / 互传 / 网页等）
  @Param sourceLabel: ResourceStr = ''
  // 对端设备指纹（可为空）：默认缩略展示，点击弹出完整指纹
  @Param peerFingerprint: string = ''

  /** 徽标统一样式（来源/发送方式 / 型号共用）。 */
  @Builder
  badge(text: ResourceStr) {
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

  /** 弹出完整设备指纹（缩略展示的补充入口）。 */
  private showFullFingerprint(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.device_fingerprint_label'),
      message: this.peerFingerprint,
      confirm: {
        value: $r('app.string.dialog_confirm'),
        action: () => {
        }
      }
    });
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
        if (hasDisplayText(this.sourceLabel) || this.display.badges.length > 0) {
          Row({ space: DesignTokens.space.tiny }) {
            if (hasDisplayText(this.sourceLabel)) {
              this.badge(this.sourceLabel)
            }
            Repeat(this.display.badges)
              .each((ri: RepeatItem<string>) => {
                this.badge(ri.item)
              })
              .key((item: string) => item)
          }
          .margin({ top: DesignTokens.space.tiny })
        }
        // 对端设备指纹：默认单行缩略，点击弹出完整指纹；缺失时不渲染该行
        if (this.peerFingerprint.length > 0) {
          Row({ space: DesignTokens.space.tiny }) {
            Text($r('app.string.device_fingerprint_label'))
              .fontSize(DesignTokens.font.captionM)
              .fontColor($r('app.color.text_tertiary'))
            Text(abbreviateFingerprint(this.peerFingerprint))
              .fontSize(DesignTokens.font.captionM)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .margin({ top: DesignTokens.space.tiny })
          .alignItems(VerticalAlign.Center)
          .accessibilityGroup(true)
          .onClick(() => {
            this.showFullFingerprint();
          })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SessionStatusBadge({ stage: this.stage, stageText: this.stageText })
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
    .alignItems(VerticalAlign.Center)
    .id('session_detail_header')
  }
}
