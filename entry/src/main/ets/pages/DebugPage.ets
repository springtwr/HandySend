import { DesignTokens } from '../common/DesignTokens';
import { getPageContentMaxWidth, getPageMargin } from '../common/Breakpoints';
import { deviceInfo } from '@kit.BasicServicesKit';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { buildImmersiveTitleBar } from '../common/ImmersiveTitleBar';
import { DebugViewModel } from '../viewmodel/DebugViewModel';
import { NetworkInterface } from '../model/Types';
import { networkTypeLabel } from '../utils/NetworkPresentation';
import { AlertDialogV2, AdvancedDialogV2Button, promptAction, uiObserver } from '@kit.ArkUI';

// @Builder 按引用传递所需的参数类（对象字面量需显式类型，禁止匿名对象）
// 按值传递时状态变量变化不会触发 @Builder 内部 UI 刷新，因此封装为对象传参。
class SecurityPemBlockParam {
  label: ResourceStr = ''
  pem: string = ''
}

class DebugInfoRowParam {
  label: ResourceStr = ''
  value: ResourceStr = ''
}

@ComponentV2
export struct DebugPage {
  // 系统宽度断点（随窗口尺寸变化自动刷新，宽屏限宽用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: DebugViewModel = new DebugViewModel();
  // NavDestination 返回栈（onReady 注入）
  private pathStack: NavPathStack = new NavPathStack()
  // 内容滚动控制器：绑定到子页面容器以驱动标题栏滚动模糊
  private scroller: Scroller = new Scroller()
  // 当前打开的弹窗 id（关闭时使用）
  private activeDialogId: number = -1

  aboutToAppear(): void {
    this.viewModel.loadInfo();
  }

  // 内容最大宽度：按断点取值；平板竖屏收紧至 800；窄屏返回 '100%' 全宽
  private getContentMaxWidth(): Length {
    return getPageContentMaxWidth(this.breakpointInfo.widthBreakpoint,
      this.breakpointInfo.heightBreakpoint, deviceInfo.deviceType);
  }

  build() {
    HdsNavDestination() {
      Row() {
        Scroll(this.scroller) {
          Column({ space: DesignTokens.space.sm }) {
            // 设备信息
            Column() {
              Text($r('app.string.debug_device_info'))
                .fontSize(DesignTokens.font.subtitleM)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .padding({ bottom: DesignTokens.space.tiny })

              this.debugInfoRow({ label: $r('app.string.debug_app_version'), value: this.viewModel.appVersion })
              this.debugInfoRow({ label: $r('app.string.debug_device_info'), value: this.viewModel.deviceModelInfo })
              this.debugInfoRow({ label: $r('app.string.device_alias_label'), value: this.viewModel.localAlias })
            }
            .width('100%')
            .padding(DesignTokens.space.md)
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(DesignTokens.radius.lg)
            .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })

            // 网络接口（多网卡支持）
            Column() {
              Text($r('app.string.network_interfaces_title'))
                .fontSize(DesignTokens.font.subtitleM)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .padding({ bottom: DesignTokens.space.tiny })

              Repeat(this.viewModel.localInterfaces).each((ri: RepeatItem<NetworkInterface>) => {
                Column() {
                  Row() {
                    Text(networkTypeLabel(ri.item.type))
                      .fontSize(DesignTokens.font.bodyS)
                      .backgroundColor(ri.item.isDefault ? $r('app.color.accent_blue') : $r('app.color.border_light'))
                      .fontColor(ri.item.isDefault ? $r('app.color.text_on_color') : $r('app.color.text_secondary'))
                      .borderRadius(DesignTokens.radius.sm)
                      .padding({
                        left: 8,
                        right: 8,
                        top: 2,
                        bottom: 2
                      })

                    if (ri.item.isDefault) {
                      Text($r('app.string.default_network_badge'))
                        .fontSize(DesignTokens.font.bodyS)
                        .fontColor($r('app.color.success_green'))
                        .margin({ left: DesignTokens.space.tiny })
                    }
                  }
                  .width('100%')
                  .margin({ bottom: DesignTokens.space.tiny })

                  this.debugInfoRow(
                    { label: $r('app.string.ip_address_label'), value: `${ri.item.ip}/${ri.item.prefixLength}` })
                }
                .width('100%')
                .padding(DesignTokens.space.sm)
                .backgroundColor($r('app.color.page_background'))
                .borderRadius(DesignTokens.radius.md)
                .margin({ top: ri.index > 0 ? DesignTokens.space.tiny : 0 })
              }).key((item: NetworkInterface) => item.ip)
            }
            .width('100%')
            .padding(DesignTokens.space.md)
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(DesignTokens.radius.lg)
            .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })

            // 服务器信息
            Column() {
              Text($r('app.string.settings_network'))
                .fontSize(DesignTokens.font.subtitleM)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .padding({ bottom: DesignTokens.space.tiny })

              this.debugInfoRow({
                label: $r('app.string.server_status_label'),
                value: this.viewModel.serverRunning ? $r('app.string.server_status_running') :
                  $r('app.string.server_status_offline')
              })
              this.debugInfoRow({ label: $r('app.string.port_label'), value: String(this.viewModel.serverPort) })
              this.debugInfoRow({
                label: $r('app.string.encrypted_transfer'),
                value: this.viewModel.httpsEnabled ? 'HTTPS' : 'HTTP'
              })
              this.debugInfoRow({
                label: $r('app.string.protocol_version_label'),
                value: this.viewModel.protocolVersion
              })
              this.debugInfoRow({
                label: $r('app.string.device_fingerprint_label'),
                value: this.viewModel.serverFingerprint
              })
            }
            .width('100%')
            .padding(DesignTokens.space.md)
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(DesignTokens.radius.lg)
            .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })

            // 安全信息
            Column() {
              Text($r('app.string.security_info_title'))
                .fontSize(DesignTokens.font.subtitleM)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })

              Button($r('app.string.reset_certificate_button'))
                .width('100%')
                .height(DesignTokens.size.thumbSm)
                .backgroundColor($r('app.color.danger_red'))
                .fontColor($r('app.color.text_on_color'))
                .borderRadius(DesignTokens.radius.md)
                .margin({ bottom: DesignTokens.space.sm })
                .onClick(() => {
                  // 弹确认框，确认后才执行证书重置
                  this.openResetCertConfirmDialog();
                })

              // 证书 / 公钥 / 私钥 PEM 完整展示（长文本随页面滚动查看）
              this.securityPemBlock({ label: $r('app.string.certificate_label'), pem: this.viewModel.certPem })
              this.securityPemBlock({ label: $r('app.string.public_key_label'), pem: this.viewModel.publicKeyPem })
              this.securityPemBlock({ label: $r('app.string.private_key_label'), pem: this.viewModel.privateKeyPem })
            }
            .width('100%')
            .padding(DesignTokens.space.md)
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(DesignTokens.radius.lg)
            .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
          }
          .padding({
            left: getPageMargin(this.breakpointInfo.widthBreakpoint),
            right: getPageMargin(this.breakpointInfo.widthBreakpoint),
            top: DesignTokens.space.md,
            bottom: DesignTokens.space.md
          })
          .width('100%')
          .backgroundColor($r('app.color.page_background'))
        }
        .layoutWeight(1)
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
        .constraintSize({ maxWidth: this.getContentMaxWidth() })
        .edgeEffect(EdgeEffect.Spring)
        // 滚动容器不裁剪：滚动中的内容可绘制到标题栏区域内，使毛玻璃背板有内容可透出
        .clip(false)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      // 内容从顶部排列，避免内容不满一屏时被交叉轴默认居中
      .alignItems(VerticalAlign.Top)
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    // 子页面容器背景覆盖至标题栏区域：无内容经过时标题栏底色与页面背景一致，不露出系统默认底色
    .backgroundColor($r('app.color.page_background'))
    .titleBar(buildImmersiveTitleBar({ title: $r('app.string.service_info_title') }))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }

  // ── DialogV2 弹窗：重置证书确认（A 类 ConfirmDialogV2） ──

  private openResetCertConfirmDialog(): void {
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.resetCertConfirmDialog();
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(dialogOptions)
      .then((id: number) => {
        this.activeDialogId = id;
      })
      .catch(() => {
      });
  }

  private closeActiveDialog(): void {
    if (this.activeDialogId >= 0) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.activeDialogId);
      this.activeDialogId = -1;
    }
  }

  // 确认后执行重置：成功 toast，失败区分「传输进行中」与一般失败
  private async performResetCertificate(): Promise<void> {
    let success: boolean = await this.viewModel.resetCertificate();
    if (success) {
      this.showToast($r('app.string.reset_cert_success'));
    } else {
      let message: ResourceStr = this.viewModel.resetBlockedByBusy ?
        $r('app.string.reset_cert_busy') : $r('app.string.reset_cert_failed');
      this.showToast(message);
    }
  }

  private showToast(message: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_e) {
      // 忽略
    }
  }

  @Builder
  resetCertConfirmDialog() {
    AlertDialogV2({
      primaryTitle: $r('app.string.reset_certificate_button'),
      content: $r('app.string.reset_cert_confirm_content'),
      primaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_cancel'),
        action: () => {
          this.closeActiveDialog();
        }
      }),
      secondaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_confirm'),
        action: () => {
          this.closeActiveDialog();
          this.performResetCertificate();
        }
      })
    })
    // 宽屏下限制弹窗最大宽度，避免铺满过宽
      .constraintSize({ maxWidth: 480 })
  }

  @Builder
  securityPemBlock(param: SecurityPemBlockParam) {
    Column() {
      Text(param.label)
        .fontSize(DesignTokens.font.bodyM)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      if (param.pem.length > 0) {
        // PEM 为多行短文本（每行 ≤64 字符）
        Column() {
          Text(param.pem)
            .fontSize(DesignTokens.font.captionM)
            .fontFamily('monospace')
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .wordBreak(WordBreak.BREAK_ALL)
            .copyOption(CopyOptions.LocalDevice)
        }
        .width('100%')
        .backgroundColor($r('app.color.page_background'))
        .borderRadius(DesignTokens.radius.md)
        .padding(DesignTokens.space.sm)
        .margin({ top: DesignTokens.space.xxs })
      } else {
        Text('-')
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: DesignTokens.space.xxs })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: DesignTokens.space.tiny, bottom: DesignTokens.space.sm })
  }

  @Builder
  debugInfoRow(param: DebugInfoRowParam) {
    Row() {
      Text(param.label)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .width('40%')

      Text(param.value)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        // 指纹等 hex 长串强制断行，避免溢出
        .wordBreak(WordBreak.BREAK_ALL)
    }
    .width('100%')
    .padding({ top: DesignTokens.space.tiny, bottom: DesignTokens.space.tiny })
    .constraintSize({ minHeight: DesignTokens.size.thumbSm })
  }
}

// 路由表引用：DebugPageBuilder(name, param)
@Builder
export function DebugPageBuilder(_name: string, _param: Object) {
  DebugPage()
}
