import { DesignTokens } from '../common/DesignTokens';
import { SendSessionState, SendSessionStatus } from '../model/Types';
import { TransferViewModel } from '../viewmodel/TransferViewModel';

// 多设备发送会话列表（从 TransferPage.multiDeviceSessionView @Builder 拆出）。
// 经 @ObjectLink 绑定父组件 VM，状态标签/颜色逻辑内聚。
@Component
export struct TransferSessionList {
  @ObjectLink viewModel: TransferViewModel

  private getSessionStatusLabel(status: SendSessionStatus): ResourceStr {
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
    } else if (status === SendSessionStatus.recipientBusy) {
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
    } else if (status === SendSessionStatus.recipientBusy) {
      return $r('app.color.danger_bg');
    } else if (status === SendSessionStatus.declined || status === SendSessionStatus.canceled ||
      status === SendSessionStatus.canceledByReceiver || status === SendSessionStatus.tooManyAttempts) {
      return $r('app.color.danger_bg');
    }
    return $r('app.color.page_background');
  }

  build() {
    Column() {
      ForEach(this.viewModel.sendSessions, (session: SendSessionState) => {
        Row({ space: DesignTokens.space.sm }) {
          Image($r('app.media.ic_public_devices_phone'))
            .width(32)
            .height(32)
            .fillColor($r('app.color.text_primary'))

          Column() {
            Text(session.targetAlias)
              .fontSize(DesignTokens.font.bodyM)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))

            Text(session.targetIp)
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: DesignTokens.space.mini })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          // Status indicator
          Text(this.getSessionStatusLabel(session.status))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor(this.getSessionStatusColor(session.status))
            .backgroundColor(this.getSessionStatusBgColor(session.status))
            .padding({ left: DesignTokens.space.xs, right: DesignTokens.space.xs, top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
            .borderRadius(DesignTokens.radius.sm)
        }
        .width('100%')
        .padding(DesignTokens.space.sm)
        .backgroundColor($r('app.color.page_background'))
        .borderRadius(DesignTokens.radius.md)
        .alignItems(VerticalAlign.Center)
        .margin({ top: DesignTokens.space.xs })
        .transition(
          TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 20 }))
            .animation({ duration: 300, curve: Curve.FastOutSlowIn })
        )
      }, (session: SendSessionState) => session.sessionId)
    }
    .width('100%')
  }
}
