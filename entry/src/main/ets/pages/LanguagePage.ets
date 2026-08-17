import { setLocale } from '../service/AppService';
import { DesignTokens } from '../common/DesignTokens';

// Language option class for ArkTS compatibility
class LanguageOption {
  value: string = ''
  label: string = ''
  bcp47: string = ''

  constructor(value: string, label: string, bcp47: string) {
    this.value = value;
    this.label = label;
    this.bcp47 = bcp47;
  }
}

const LANGUAGE_LIST: Array<LanguageOption> = [
  new LanguageOption('', '跟随系统', 'default'),
  new LanguageOption('zh', '中文（简体）', 'zh-Hans'),
  new LanguageOption('zh-TW', '中文（繁體）', 'zh-Hant'),
  new LanguageOption('en', 'English', 'en-US'),
];

export function getLanguageDisplayName(code: string): string {
  for (let i = 0; i < LANGUAGE_LIST.length; i++) {
    if (LANGUAGE_LIST[i].value === code) {
      return LANGUAGE_LIST[i].label;
    }
  }
  return code;
}

@Entry
@Component
struct LanguagePage {
  @State selectedLocale: string = ''

  aboutToAppear(): void {
    let params = this.getUIContext().getRouter().getParams() as Record<string, string>;
    if (params !== undefined && params['currentLocale'] !== undefined) {
      this.selectedLocale = params['currentLocale'] as string;
    } else {
      this.selectedLocale = AppStorage.get<string>('locale') || '';
    }
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

            if (this.selectedLocale === lang.value) {
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
            this.selectedLocale = lang.value;
            // setLocale() calls setAppPreferredLanguage — takes effect immediately
            setLocale(lang.value);
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
