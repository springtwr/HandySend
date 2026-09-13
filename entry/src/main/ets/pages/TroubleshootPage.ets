import { uiObserver } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { DesignTokens } from '../common/DesignTokens';
import { getMaxContentWidth, getPageMargin, isTabletPortrait } from '../common/Breakpoints';
import { getPort } from '../service/AppService';

// FAQ 条目数据结构
interface FaqItem {
  titleRes: ResourceStr;
  descRes: ResourceStr;
  hintRes?: ResourceStr;

  // 描述中含 {port} 占位符，需替换为当前配置端口
  needPortSubst?: boolean;
}

@ComponentV2
export struct TroubleshootPage {
  // 系统宽度断点（随窗口尺寸变化自动刷新，宽屏限宽用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  // NavDestination 返回栈（onReady 注入）
  private pathStack: NavPathStack = new NavPathStack()
  // 各 FAQ 条目的展开状态，默认全部折叠
  @Local expandedItems: boolean[] = [
    false, false, false, false,
    false, false, false, false, false, false, false
  ];
  // FAQ 条目数据数组
  private faqItems: FaqItem[] = [
    {
      titleRes: $r('app.string.troubleshoot_firewall_title'),
      descRes: $r('app.string.troubleshoot_firewall_desc'),
      needPortSubst: true
    } as FaqItem,
    {
      titleRes: $r('app.string.troubleshoot_discovery_title'),
      descRes: $r('app.string.troubleshoot_discovery_desc'),
      hintRes: $r('app.string.troubleshoot_discovery_service_hint')
    } as FaqItem,
    {
      titleRes: $r('app.string.troubleshoot_connection_title'),
      descRes: $r('app.string.troubleshoot_connection_desc')
    } as FaqItem,
    { titleRes: $r('app.string.troubleshoot_protocol_title'), descRes: $r('app.string.troubleshoot_protocol_desc') } as
      FaqItem,
    {
      titleRes: $r('app.string.troubleshoot_multi_interface_title'),
      descRes: $r('app.string.troubleshoot_multi_interface_desc')
    } as FaqItem,
    {
      titleRes: $r('app.string.troubleshoot_transfer_interrupt_title'),
      descRes: $r('app.string.troubleshoot_transfer_interrupt_desc')
    } as FaqItem,
    { titleRes: $r('app.string.troubleshoot_remote_title'), descRes: $r('app.string.troubleshoot_remote_desc') } as
      FaqItem,
    { titleRes: $r('app.string.troubleshoot_favorite_title'), descRes: $r('app.string.troubleshoot_favorite_desc') } as
      FaqItem,
    {
      titleRes: $r('app.string.troubleshoot_duplicate_title'),
      descRes: $r('app.string.troubleshoot_duplicate_desc')
    } as FaqItem,
    {
      titleRes: $r('app.string.troubleshoot_mta_transfer_title'),
      descRes: $r('app.string.troubleshoot_mta_transfer_desc'),
      hintRes: $r('app.string.troubleshoot_mta_transfer_hint')
    } as FaqItem,
    {
      titleRes: $r('app.string.troubleshoot_offline_title'),
      descRes: $r('app.string.troubleshoot_offline_desc')
    } as FaqItem,
  ];

  // 内容最大宽度：按断点取值；平板竖屏收紧至 800；窄屏返回 '100%' 全宽
  private getContentMaxWidth(): Length {
    let maxWidth: number = getMaxContentWidth(this.breakpointInfo.widthBreakpoint);
    if (isTabletPortrait(deviceInfo.deviceType, this.breakpointInfo.heightBreakpoint)) {
      maxWidth = 800;
    }
    if (maxWidth === 0) {
      return '100%';
    }
    return maxWidth;
  }

  build() {
    NavDestination() {
      // 垂直主轴容器：Scroll 经 layoutWeight 撑满高度（内容从顶部排列），alignItems 水平居中限宽内容
      Column() {
        Scroll() {
          Column({ space: DesignTokens.space.md }) {
            // FAQ 手风琴列表
            ForEach(this.faqItems, (item: FaqItem, index: number) => {
              Column() {
                // 标题行（可点击）
                Row() {
                  Text(item.titleRes)
                    .fontSize(DesignTokens.font.subtitleM)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)

                  SymbolGlyph(this.expandedItems[index] ?
                    $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
                    .fontSize(DesignTokens.font.subtitleM)
                    .fontColor([$r('app.color.text_secondary')])
                }
                .width('100%')
                .onClick(() => {
                  this.toggleItem(index);
                })

                // 展开内容
                if (this.expandedItems[index]) {
                  Column() {
                    Text(item.needPortSubst ? this.resolveDescWithPort(item.descRes) : item.descRes)
                      .fontSize(DesignTokens.font.bodyM)
                      .fontColor($r('app.color.text_secondary'))
                      .margin({ top: DesignTokens.space.tiny })
                      .width('100%')

                    // 可选的提示文字（如橙色警告）
                    if (item.hintRes !== undefined) {
                      Text(item.hintRes)
                        .fontSize(DesignTokens.font.bodyM)
                        .fontColor($r('app.color.warning_orange'))
                        .margin({ top: DesignTokens.space.tiny })
                        .width('100%')
                    }
                  }
                }
              }
              .width('100%')
              .padding({
                left: getPageMargin(this.breakpointInfo.widthBreakpoint),
                right: getPageMargin(this.breakpointInfo.widthBreakpoint),
                top: DesignTokens.space.md,
                bottom: DesignTokens.space.md
              })
              .backgroundColor($r('app.color.card_background'))
              .borderRadius(DesignTokens.radius.lg)
              .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
            }, (item: FaqItem, index: number) => `${index}`)

            // 调试工具导航
            Column() {
              // 安全信息——链接到含应用信息 + 证书重置的 DebugPage
              Row() {
                Text($r('app.string.service_info_title'))
                  .fontSize(DesignTokens.font.bodyM)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)

                SymbolGlyph($r('sys.symbol.chevron_forward'))
                  .fontSize(DesignTokens.font.subtitleM)
                  .fontColor([$r('app.color.text_secondary')])
              }
              .width('100%')
              .padding({
                left: DesignTokens.space.md,
                right: DesignTokens.space.md,
                top: DesignTokens.space.sm,
                bottom: DesignTokens.space.sm
              })
              .constraintSize({ minHeight: DesignTokens.size.thumbSm })
              .onClick(() => {
                this.pathStack.pushPathByName('DebugPage', undefined);
              })

              Divider().color($r('app.color.border_light'))

              // HTTP 日志
              Row() {
                Text($r('app.string.http_logs_title'))
                  .fontSize(DesignTokens.font.bodyM)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)

                SymbolGlyph($r('sys.symbol.chevron_forward'))
                  .fontSize(DesignTokens.font.subtitleM)
                  .fontColor([$r('app.color.text_secondary')])
              }
              .width('100%')
              .padding({
                left: DesignTokens.space.md,
                right: DesignTokens.space.md,
                top: DesignTokens.space.sm,
                bottom: DesignTokens.space.sm
              })
              .constraintSize({ minHeight: DesignTokens.size.thumbSm })
              .onClick(() => {
                this.pathStack.pushPathByName('HttpLogsPage', undefined);
              })
            }
            .width('100%')
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(DesignTokens.radius.lg)
            .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
          }
          .padding(DesignTokens.space.md)
        }
        .layoutWeight(1)
        .width('100%')
        .constraintSize({ maxWidth: this.getContentMaxWidth() })
        .edgeEffect(EdgeEffect.Spring)
        // Scroll 设置高度限制后内容较少时默认居中，显式顶部对齐（FAQ：Scroll layoutWeight 顶部对齐）
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      // 水平居中（Scroll 限宽后居中），垂直方向由 layoutWeight 撑满，内容始终从顶部排列
      .alignItems(HorizontalAlign.Center)
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .title($r('app.string.troubleshoot_title'), { backgroundColor: $r('app.color.page_background') })
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }

  // 切换 FAQ 条目的展开/折叠状态，使用 animateTo 包裹实现平滑动画
  private toggleItem(index: number): void {
    this.getUIContext().animateTo({
      duration: DesignTokens.animation.durationNormal,
      curve: Curve.FastOutSlowIn
    }, () => {
      this.expandedItems[index] = !this.expandedItems[index];
    });
  }

  // 读取资源字符串并将 {port} 占位符替换为当前配置端口
  private resolveDescWithPort(descRes: ResourceStr): string {
    let ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return '';
    }
    try {
      if (typeof descRes === 'string') {
        return descRes.replace('{port}', String(getPort()));
      }
      let raw = ctx.resourceManager.getStringSync(descRes.id);
      return raw.replace('{port}', String(getPort()));
    } catch (_e) {
      return '';
    }
  }
}

// 路由表引用：TroubleshootPageBuilder(name, param)
@Builder
export function TroubleshootPageBuilder(_name: string, _param: Object) {
  TroubleshootPage()
}
