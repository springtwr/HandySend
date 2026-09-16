import { uiObserver } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { DesignTokens } from '../common/DesignTokens';
import { getPageContentMaxWidth, getPageMargin } from '../common/Breakpoints';
import { DeviceDetailsViewModel } from '../viewmodel/DeviceDetailsViewModel';
import { ipShortCode } from '../utils/NetworkPresentation';
import { VerifyPageParams } from '../model/Types';

@ComponentV2
export struct DeviceDetailsPage {
  // 系统宽度断点（随窗口尺寸变化自动刷新，宽屏限宽用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: DeviceDetailsViewModel = new DeviceDetailsViewModel();
  // 路由参数（经 DeviceDetailsPageBuilder 传入，结构与旧 pushUrl params 一致）
  @Param pageParam: Object = new Object()
  // NavDestination 返回栈（onReady 注入）
  private pathStack: NavPathStack = new NavPathStack()

  aboutToAppear(): void {
    let params: Record<string, string | number | boolean> = this.pageParam as Record<string, string | number | boolean>;
    if (params !== undefined) {
      const alias: string = params['alias'] as string;
      const ip: string = params['ip'] as string;
      const port: number = params['port'] as number;
      const fingerprint: string = params['fingerprint'] as string;
      const version: string = params['version'] as string;
      const deviceModel: string = params['deviceModel'] as string;
      const deviceType: string = params['deviceType'] as string;
      const protocol: string = params['protocol'] as string;
      this.viewModel.loadDevice(alias, ip, port, fingerprint, version, deviceModel, deviceType, protocol);
    }
  }

  // 内容最大宽度：按断点取值；平板竖屏收紧至 800；窄屏返回 '100%' 全宽
  private getContentMaxWidth(): Length {
    return getPageContentMaxWidth(this.breakpointInfo.widthBreakpoint,
      this.breakpointInfo.heightBreakpoint, deviceInfo.deviceType);
  }

  build() {
    NavDestination() {
      Row() {
        Scroll() {
          Column() {
            // 设备信息卡片
            Column() {
              Text(this.viewModel.deviceAlias)
                .fontSize(DesignTokens.font.titleM)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))

              Row({ space: DesignTokens.space.tiny }) {
                Text(ipShortCode(this.viewModel.deviceIp))
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

                Text(this.viewModel.deviceModel)
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
              .margin({ top: DesignTokens.space.tiny })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding(DesignTokens.space.xl)

            // 信息详情
            Column() {
              this.infoRow($r('app.string.device_alias_label'), this.viewModel.deviceAlias)
              this.infoRow($r('app.string.device_ip_label'), this.viewModel.deviceIp)
              this.infoRow($r('app.string.device_port_label'), this.viewModel.devicePort.toString())
              this.infoRow($r('app.string.device_version_label'), this.viewModel.deviceVersion)
              this.infoRow($r('app.string.device_protocol_label'), this.viewModel.deviceProtocol)
              this.infoRow($r('app.string.device_fingerprint_label'),
                this.viewModel.deviceFingerprint)
            }
            .width('100%')
            .padding(DesignTokens.space.md)
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(DesignTokens.radius.lg)
            .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
            .margin({ top: DesignTokens.space.md })

            // 操作按钮
            Column({ space: DesignTokens.space.sm }) {
              // 验证按钮
              Button($r('app.string.verify_device_button'))
                .width('100%')
                .height(DesignTokens.size.thumbSm)
                .backgroundColor($r('app.color.accent_blue'))
                .fontColor($r('app.color.text_on_color'))
                .borderRadius(DesignTokens.radius.md)
                .onClick(() => {
                  let verifyParams: VerifyPageParams = {
                    localFingerprint: this.viewModel.localFingerprint,
                    remoteFingerprint: this.viewModel.deviceFingerprint
                  };
                  this.pathStack.pushPathByName('VerifyPage', verifyParams);
                })

              // 收藏切换按钮
              Button(this.viewModel.isFavoriteDevice ? $r('app.string.remove_favorite_button') :
                $r('app.string.add_favorite_button'))
                .width('100%')
                .height(DesignTokens.size.thumbSm)
                .backgroundColor(
                  this.viewModel.isFavoriteDevice ? $r('app.color.danger_red') : $r('app.color.page_background'))
                .fontColor(
                  this.viewModel.isFavoriteDevice ? $r('app.color.text_on_color') : $r('app.color.text_primary'))
                .border({
                  width: DesignTokens.component.borderSlim,
                  color: this.viewModel.isFavoriteDevice ? $r('app.color.danger_red') : $r('app.color.border_light')
                })
                .borderRadius(DesignTokens.radius.md)
                .onClick(() => {
                  this.viewModel.toggleFavorite();
                })
            }
            .width('100%')
            .margin({ top: DesignTokens.space.lg })
          }
          .padding({
            left: getPageMargin(this.breakpointInfo.widthBreakpoint),
            right: getPageMargin(this.breakpointInfo.widthBreakpoint), bottom: DesignTokens.space.xl
          })
        }
        .layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: this.getContentMaxWidth() })
        .edgeEffect(EdgeEffect.Spring)
        // Scroll 设置高度限制后内容较少时默认居中，显式顶部对齐
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      // 内容从顶部排列，避免内容不满一屏时被交叉轴默认居中
      .alignItems(VerticalAlign.Top)
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .title($r('app.string.device_details_title'), { backgroundColor: $r('app.color.page_background') })
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }

  @Builder
  infoRow(label: ResourceStr, value: string): void {
    Row() {
      Text(label)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .width('40%')

      Text(value)
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

// 路由表引用：DeviceDetailsPageBuilder(name, param)
@Builder
export function DeviceDetailsPageBuilder(name: string, param: Object) {
  DeviceDetailsPage({ pageParam: param })
}
