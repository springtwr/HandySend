import { DesignTokens } from '../common/DesignTokens';
import { SendSessionState, SendSessionStatus } from '../model/Types';
import { TransferViewModel } from '../viewmodel/TransferViewModel';
import { sessionStatusLabel, sessionStatusColor, sessionStatusBgColor, sessionErrorMessage } from '../utils/SessionStatusPresentation';

// 多设备发送会话列表（从 TransferPage.multiDeviceSessionView @Builder 拆出）。
// 经 @Param 绑定父组件 VM，状态标签/颜色逻辑内聚。
@ComponentV2
export struct TransferSessionList {
  @Require @Param viewModel: TransferViewModel

  private getSessionStatusLabel(session: SendSessionState): ResourceStr {
    let status = session.status;
    // finishedWithErrors/pinRequired 优先显示具体错误消息
    let err: ResourceStr | null = sessionErrorMessage(status, session.errorMessage ?? '');
    if (err !== null) {
      return err;
    }
    return sessionStatusLabel(status);
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
                .fontColor(sessionStatusColor(ri.item.status))
                .backgroundColor(sessionStatusBgColor(ri.item.status))
                .padding({
                  left: DesignTokens.space.tiny,
                  right: DesignTokens.space.tiny,
                  top: DesignTokens.space.mini,
                  bottom: DesignTokens.space.mini
                })
                .borderRadius(DesignTokens.radius.sm)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 180 })
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
