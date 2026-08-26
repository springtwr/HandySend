import { DesignTokens } from '../common/DesignTokens';
import { SendSessionState, SendSessionStatus } from '../model/Types';
import { TransferViewModel } from '../viewmodel/TransferViewModel';

// 多设备发送会话列表（从 TransferPage.multiDeviceSessionView @Builder 拆出）。
// 经 @Param 绑定父组件 VM，状态标签/颜色逻辑内聚。
@ComponentV2
export struct TransferSessionList {
  @Require @Param viewModel: TransferViewModel

  private getSessionStatusLabel(session: SendSessionState): ResourceStr {
    let status = session.status;
    // finishedWithErrors/pinRequired 优先显示具体错误消息
    if (status === SendSessionStatus.finishedWithErrors || status === SendSessionStatus.pinRequired) {
      if (session.errorMessage !== undefined && session.errorMessage.length > 0) {
        return session.errorMessage;
      }
    }
    if (status === SendSessionStatus.waiting) {
      return $r('app.string.session_status_waiting');
    } else if (status === SendSessionStatus.calculatingHash) {
      return $r('app.string.session_status_checksum');
    } else if (status === SendSessionStatus.sending) {
      return $r('app.string.session_status_sending');
    } else if (status === SendSessionStatus.finished) {
      return $r('app.string.session_status_done');
    } else if (status === SendSessionStatus.finishedWithErrors) {
      return $r('app.string.session_status_error');
    } else if (status === SendSessionStatus.declined) {
      return $r('app.string.session_status_declined');
    } else if (status === SendSessionStatus.canceled || status === SendSessionStatus.canceledByReceiver) {
      return $r('app.string.session_status_canceled');
    } else if (status === SendSessionStatus.tooManyAttempts) {
      return $r('app.string.session_status_locked');
    } else if (status === SendSessionStatus.viewed) {
      return $r('app.string.session_status_viewed');
    } else if (status === SendSessionStatus.recipientBusy) {
      return $r('app.string.session_status_busy');
    } else if (status === SendSessionStatus.timeout) {
      return $r('app.string.session_status_timeout');
    } else if (status === SendSessionStatus.pinRequired) {
      return $r('app.string.session_status_pin_required');
    }
    return '';
  }

  private getSessionStatusColor(status: SendSessionStatus): ResourceColor {
    if (status === SendSessionStatus.sending || status === SendSessionStatus.calculatingHash) {
      return $r('app.color.accent_blue');
    } else if (status === SendSessionStatus.finished) {
      return $r('app.color.success_green');
    } else if (status === SendSessionStatus.finishedWithErrors) {
      return $r('app.color.warning_orange');
    } else if (status === SendSessionStatus.viewed) {
      return $r('app.color.success_green');
    } else if (status === SendSessionStatus.recipientBusy || status === SendSessionStatus.timeout ||
      status === SendSessionStatus.pinRequired) {
      return $r('app.color.danger_red');
    } else if (status === SendSessionStatus.declined || status === SendSessionStatus.canceled ||
      status === SendSessionStatus.canceledByReceiver || status === SendSessionStatus.tooManyAttempts) {
      return $r('app.color.danger_red');
    }
    return $r('app.color.text_secondary');
  }

  private getSessionStatusBgColor(status: SendSessionStatus): ResourceColor {
    if (status === SendSessionStatus.sending || status === SendSessionStatus.calculatingHash) {
      return $r('app.color.accent_blue_bg');
    } else if (status === SendSessionStatus.finished) {
      return $r('app.color.success_bg');
    } else if (status === SendSessionStatus.finishedWithErrors) {
      return $r('app.color.warning_bg');
    } else if (status === SendSessionStatus.viewed) {
      return $r('app.color.success_bg');
    } else if (status === SendSessionStatus.recipientBusy || status === SendSessionStatus.timeout ||
      status === SendSessionStatus.pinRequired) {
      return $r('app.color.danger_bg');
    } else if (status === SendSessionStatus.declined || status === SendSessionStatus.canceled ||
      status === SendSessionStatus.canceledByReceiver || status === SendSessionStatus.tooManyAttempts) {
      return $r('app.color.danger_bg');
    }
    return $r('app.color.page_background');
  }

  // 读取某会话的发送百分比；不存在时返回 0（UI 据此决定是否展示）。
  private getSessionProgressPercent(sessionId: string): number {
    let p: number | undefined = this.viewModel.sessionProgress[sessionId];
    if (p === undefined) {
      return 0;
    }
    return p;
  }

  build() {
    Column() {
      Repeat(this.viewModel.sendSessions).each((ri: RepeatItem<SendSessionState>) => {
        Row({ space: DesignTokens.space.sm }) {
          Image($r('app.media.ic_device_mobile'))
            .width(DesignTokens.size.iconMd)
            .height(DesignTokens.size.iconMd)
            .fillColor($r('app.color.text_primary'))

          Column() {
            Text(ri.item.targetAlias)
              .fontSize(DesignTokens.font.bodyM)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')

            Text(ri.item.targetIp)
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: DesignTokens.space.mini })

            // 每设备发送进度：全宽进度条 + 百分比 + 状态，放在名称/IP 下方不挤占名称行
            Row({ space: DesignTokens.space.sm }) {
              Progress({ value: this.getSessionProgressPercent(ri.item.sessionId), total: 100, type: ProgressType.Linear })
                .width('100%')
                .height(4)
                .color($r('app.color.accent_blue'))
                .backgroundColor($r('app.color.border_light'))
                .layoutWeight(1)
              Text(Math.round(this.getSessionProgressPercent(ri.item.sessionId)) + '%')
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_secondary'))
                .width(DesignTokens.space.xl + 6)
                .textAlign(TextAlign.End)
              Text(this.getSessionStatusLabel(ri.item))
                .fontSize(DesignTokens.font.bodyS)
                .fontColor(this.getSessionStatusColor(ri.item.status))
                .backgroundColor(this.getSessionStatusBgColor(ri.item.status))
                .padding({
                  left: DesignTokens.space.tiny,
                  right: DesignTokens.space.tiny,
                  top: DesignTokens.space.mini,
                  bottom: DesignTokens.space.mini
                })
                .borderRadius(DesignTokens.radius.sm)
            }
            .width('100%')
            .margin({ top: DesignTokens.space.tiny })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding(DesignTokens.space.sm)
        .backgroundColor($r('app.color.page_background'))
        .borderRadius(DesignTokens.radius.md)
        .alignItems(VerticalAlign.Center)
        .margin({ top: DesignTokens.space.tiny })
        .transition(
          TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 20 }))
            .animation({ duration: 300, curve: Curve.FastOutSlowIn })
        )
      }).key((item: SendSessionState) => item.sessionId)
    }
    .width('100%')
  }
}
