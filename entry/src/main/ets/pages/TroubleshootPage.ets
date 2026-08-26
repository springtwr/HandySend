import { DesignTokens } from '../common/DesignTokens';
import { getPort } from '../service/AppService';

// FAQ 条目数据结构
interface FaqItem {
  titleRes: ResourceStr;
  descRes: ResourceStr;
  hintRes?: ResourceStr;
  // 描述中含 {port} 占位符，需替换为当前配置端口
  needPortSubst?: boolean;
}

@Entry
@ComponentV2
struct TroubleshootPage {
  // 各 FAQ 条目的展开状态，默认全部折叠
  @Local expandedItems: boolean[] = [
    false, false, false, false,
    false, false, false, false, false
  ];

  // FAQ 条目数据数组
  private faqItems: FaqItem[] = [
    // 原有 4 条
    { titleRes: $r('app.string.troubleshoot_firewall_title'), descRes: $r('app.string.troubleshoot_firewall_desc'), needPortSubst: true } as FaqItem,
    { titleRes: $r('app.string.troubleshoot_discovery_title'), descRes: $r('app.string.troubleshoot_discovery_desc'), hintRes: $r('app.string.troubleshoot_discovery_service_hint') } as FaqItem,
    { titleRes: $r('app.string.troubleshoot_connection_title'), descRes: $r('app.string.troubleshoot_connection_desc') } as FaqItem,
    { titleRes: $r('app.string.troubleshoot_protocol_title'), descRes: $r('app.string.troubleshoot_protocol_desc') } as FaqItem,
    // 新增 5 条
    { titleRes: $r('app.string.troubleshoot_multi_interface_title'), descRes: $r('app.string.troubleshoot_multi_interface_desc') } as FaqItem,
    { titleRes: $r('app.string.troubleshoot_transfer_interrupt_title'), descRes: $r('app.string.troubleshoot_transfer_interrupt_desc') } as FaqItem,
    { titleRes: $r('app.string.troubleshoot_remote_title'), descRes: $r('app.string.troubleshoot_remote_desc') } as FaqItem,
    { titleRes: $r('app.string.troubleshoot_favorite_title'), descRes: $r('app.string.troubleshoot_favorite_desc') } as FaqItem,
    { titleRes: $r('app.string.troubleshoot_duplicate_title'), descRes: $r('app.string.troubleshoot_duplicate_desc') } as FaqItem,
  ];

  build() {
    Column() {
      // 标题栏
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_backward'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontColor([$r('app.color.text_primary')])
          .responseRegion({
            x: -12,
            y: -12,
            width: 48,
            height: 48
          })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })

        Text($r('app.string.troubleshoot_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
      }
      .width('100%')
      .height(DesignTokens.size.headerHeight)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

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
            .padding(DesignTokens.space.md)
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
              this.getUIContext().getRouter().pushUrl({ url: 'pages/DebugPage' });
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
              this.getUIContext().getRouter().pushUrl({ url: 'pages/HttpLogsPage' });
            })

            Divider().color($r('app.color.border_light'))

            // 发现调试
            Row() {
              Text($r('app.string.discovery_debug_title'))
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
              this.getUIContext().getRouter().pushUrl({ url: 'pages/DiscoveryDebugPage' });
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
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

  pageTransition() {
    PageTransitionEnter(
      { type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
    PageTransitionEnter(
      { type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit(
      { type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit(
      { type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
  }
}
