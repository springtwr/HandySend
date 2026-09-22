/**
 * SessionHeader.ets — 详情页设备卡
 *
 * 由适配器展示描述符驱动（含匿名对端兜底），外壳不含协议分支；
 * 单层卡片容器（card_background + 圆角 lg + 边框）内直接排布
 * 设备图标 + 对端名称 + 来源/发送方式徽标 + 型号徽标 + 状态徽标；
 * 设备指纹默认单行缩略，点击后弹出完整指纹。
 */

import { AdvancedDialogV2Button, CustomContentDialogV2, promptAction } from '@kit.ArkUI';
import { DesignTokens } from '../../common/DesignTokens';
import { SessionDisplayDescriptor, SessionStage } from '../../model/transfer/TransferSession';
import { getPeerDeviceIconResource } from '../../utils/DeviceIconUtil';
import { hasDisplayText } from '../../service/transfer/adapters/SessionAdapter';
import { abbreviateMiddle } from '../../utils/FormatUtil';
import { SessionStatusBadge } from './SessionStatusBadge';

// 指纹缩略保留的首/尾字符数（中间以省略号连接，避免仅末尾截断丢失尾段信息）
const FINGERPRINT_HEAD_LEN: number = 11;
const FINGERPRINT_TAIL_LEN: number = 8;

@ComponentV2
export struct SessionHeader {
  @Require @Param display: SessionDisplayDescriptor
  @Require @Param stage: SessionStage
  @Param stageText: ResourceStr = ''
  // 来源/发送方式标签（LocalSend / 互传 / 网页等）
  @Param sourceLabel: ResourceStr = ''
  // 对端设备指纹（可为空）：默认缩略展示，点击弹出完整指纹
  @Param peerFingerprint: string = ''
  // 指纹弹窗内容区可用宽度（vp，由内容文本 onAreaChange 获取，用于判定单行/多行对齐）
  @Local fingerprintContentWidth: number = 0
  private fingerprintDialogId: number = -1

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

  /** 弹出完整设备指纹（自定义内容弹窗，文本可长按自由选择复制）。 */
  private showFullFingerprint(): void {
    let options: promptAction.CustomDialogOptions = {
      builder: () => {
        this.fingerprintDialog();
      },
      onDidDisappear: () => {
        this.fingerprintDialogId = -1;
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(options)
      .then((id: number) => {
        this.fingerprintDialogId = id;
      })
      .catch(() => {
      });
  }

  private closeFingerprintDialog(): void {
    if (this.fingerprintDialogId >= 0) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.fingerprintDialogId);
      this.fingerprintDialogId = -1;
    }
  }

  /**
   * 标识行标签：MTA 来源（mtaBrandId 存在）用中性文案（对端为 BLE 设备地址），
   * 其余来源沿用既有「指纹」文案。
   */
  private identifierLabel(): ResourceStr {
    return this.display.mtaBrandId !== undefined
      ? $r('app.string.device_identifier_label')
      : $r('app.string.device_fingerprint_label');
  }

  /** 完整设备指纹弹窗（自定义内容区，文本可长按自由选择复制）。 */
  @Builder
  fingerprintDialog() {
    CustomContentDialogV2({
      primaryTitle: this.identifierLabel(),
      contentBuilder: () => {
        this.fingerprintDialogContent();
      },
      buttons: [
        new AdvancedDialogV2Button({
          content: $r('app.string.dialog_confirm'),
          action: () => {
            this.closeFingerprintDialog();
          }
        })
      ]
    })
      .constraintSize({ maxWidth: 480 })
  }

  /** 完整设备指纹弹窗内容区：长按可选中的完整指纹文本（单行居中、多行左对齐）。 */
  @Builder
  fingerprintDialogContent() {
    Text(this.peerFingerprint)
      .width('100%')
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_primary'))
      .textAlign(this.fingerprintDialogTextAlign())
      .wordBreak(WordBreak.BREAK_ALL)
      .copyOption(CopyOptions.LocalDevice)
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        // 记录内容区可用宽度（vp），供单行/多行对齐判定
        if (typeof newValue.width === 'number') {
          this.fingerprintContentWidth = newValue.width;
        }
      })
  }

  /** 完整指纹弹窗文本对齐：单行居中、多行左对齐（按单行测量宽度与实际可用宽度比较判定）。 */
  private fingerprintDialogTextAlign(): TextAlign {
    if (this.fingerprintContentWidth <= 0) {
      return TextAlign.Start;
    }
    let singleLineWidthPx: number = this.getUIContext().getMeasureUtils().measureText({
      textContent: this.peerFingerprint,
      fontSize: DesignTokens.font.bodyM
    });
    let availableWidthPx: number = this.getUIContext().vp2px(this.fingerprintContentWidth);
    return singleLineWidthPx <= availableWidthPx ? TextAlign.Center : TextAlign.Start;
  }

  build() {
    Row({ space: DesignTokens.space.sm }) {
      Image(getPeerDeviceIconResource(this.display.deviceType, this.display.mtaBrandId))
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
            Text(this.identifierLabel())
              .fontSize(DesignTokens.font.captionM)
              .fontColor($r('app.color.text_tertiary'))
            Text(abbreviateMiddle(this.peerFingerprint, FINGERPRINT_HEAD_LEN, FINGERPRINT_TAIL_LEN))
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
