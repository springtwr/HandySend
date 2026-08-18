import { LanguageViewModel } from '../viewmodel/LanguageViewModel';
import { LANGUAGE_LIST, LanguageOption } from '../common/LanguageConstants';
import { DesignTokens } from '../common/DesignTokens';

/**
 * LanguagePage
 * 语言选择页。整改为 MVVM 纯组装：
 * - 创建 ViewModel 实例（@State + @Observed 第一层观测）
 * - aboutToAppear 调 vm.loadLocale 加载当前语言
 * - onClick 调 vm.selectLocale 应用并返回
 * - build 只渲染，无业务逻辑、无 AppStorage 访问
 */
@Entry
@Component
struct LanguagePage {
  @State viewModel: LanguageViewModel = new LanguageViewModel();

  aboutToAppear(): void {
    let params = this.getUIContext().getRouter().getParams() as Record<string, string>;
    let current: string | undefined = undefined;
    if (params !== undefined && params['currentLocale'] !== undefined) {
      current = params['currentLocale'];
    }
    this.viewModel.loadLocale(current);
  }

  build() {
    Column() {
      // Header
      Row() {
        Image($r('sys.media.ohos_ic_public_arrow_left'))
          .width(24)
          .height(24)
          .fillColor($r('app.color.text_primary'))
          .responseRegion({ x: -12, y: -12, width: 48, height: 48 })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })

        Text($r('app.string.language_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
      }
      .width('100%')
      .height(56)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      Column() {
        ForEach(LANGUAGE_LIST, (lang: LanguageOption, index: number) => {
          Row() {
            Text(lang.label)
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            if (this.viewModel.selectedLocale === lang.value) {
              Text('\u2713')
                .fontSize(DesignTokens.font.subtitleM)
                .fontColor($r('app.color.accent_blue'))
            }
          }
          .width('100%')
          .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: 14, bottom: 14 })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.viewModel.selectLocale(lang.value);
            this.getUIContext().getRouter().back();
          })

          if (index < LANGUAGE_LIST.length - 1) {
            Divider().color($r('app.color.border_light'))
          }
        }, (lang: LanguageOption) => lang.value)
      }
      .width('100%')
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(DesignTokens.radius.lg)
      .border({ width: 1, color: $r('app.color.border_light') })
      .margin(DesignTokens.space.md)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
    PageTransitionEnter({ type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
  }
}
