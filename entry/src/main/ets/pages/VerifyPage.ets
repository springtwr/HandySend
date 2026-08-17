import { toIcons, getCombinedFingerprint } from '../utils/FingerprintIcons';
import { DesignTokens } from '../common/DesignTokens';

@Entry
@Component
struct VerifyPage {
  @State localFingerprint: string = ''
  @State remoteFingerprint: string = ''
  @State combinedIcons: Array<string> = []
  @State combinedFingerprint: string = ''
  @State showHex: boolean = false

  aboutToAppear(): void {
    // MaterialIcons font is registered globally in EntryAbility — no need to register here

    let params = this.getUIContext().getRouter().getParams() as Record<string, string>;
    if (params !== undefined) {
      this.localFingerprint = params['localFingerprint'] !== undefined ? params['localFingerprint'] as string : '';
      this.remoteFingerprint = params['remoteFingerprint'] !== undefined ? params['remoteFingerprint'] as string : '';
    }

    // Calculate combined fingerprint string (sorted + joined, matching LocalSend protocol)
    this.combinedFingerprint = getCombinedFingerprint(this.localFingerprint, this.remoteFingerprint);

    // Generate icons from combined fingerprint (SHA-256 hash + base-260 conversion)
    this.combinedIcons = toIcons(this.combinedFingerprint);
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

        Text($r('app.string.verify_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
      }
      .width('100%')
      .height(56)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          // Instruction text
          Text($r('app.string.verify_instruction'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .margin({ top: DesignTokens.space.md, bottom: DesignTokens.space.lg })

          // Mode toggle: Icon / Text
          Row() {
            Text($r('app.string.verify_icon_mode'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor(!this.showHex ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
              .fontWeight(!this.showHex ? FontWeight.Bold : FontWeight.Normal)
              .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
              .backgroundColor(!this.showHex ? $r('app.color.accent_blue_bg') : Color.Transparent)
              .borderRadius({ topLeft: DesignTokens.radius.md, bottomLeft: DesignTokens.radius.md })
              .onClick(() => {
                this.showHex = false;
              })

            Text($r('app.string.verify_hex_mode'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor(this.showHex ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
              .fontWeight(this.showHex ? FontWeight.Bold : FontWeight.Normal)
              .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
              .backgroundColor(this.showHex ? $r('app.color.accent_blue_bg') : Color.Transparent)
              .borderRadius({ topRight: DesignTokens.radius.md, bottomRight: DesignTokens.radius.md })
              .onClick(() => {
                this.showHex = true;
              })
          }
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .borderRadius(DesignTokens.radius.md)
          .border({ width: 1, color: $r('app.color.border_light') })
          .margin({ bottom: DesignTokens.space.lg })

          // Display area
          if (!this.showHex) {
            // Icon mode: 4-column grid of Material Icons
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
              ForEach(this.combinedIcons, (icon: string, index: number) => {
                Text(icon)
                  .fontSize(DesignTokens.font.displayS)
                  .fontFamily('MaterialIcons')
                  .fontColor($r('app.color.text_primary'))
                  .width('25%')
                  .textAlign(TextAlign.Center)
                  .padding(DesignTokens.space.xs)
              }, (icon: string, index: number) => index.toString())
            }
            .width('100%')
            .padding(DesignTokens.space.md)
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(DesignTokens.radius.lg)
            .border({ width: 1, color: $r('app.color.border_light') })
          } else {
            // Text mode: show the combined fingerprint string directly
            // Matching LocalSend original: SelectableText(fingerprint.combined)
            Column() {
              Text(this.combinedFingerprint)
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .fontFamily('monospace')
                .wordBreak(WordBreak.BREAK_ALL)
                .textAlign(TextAlign.Center)
                .copyOption(CopyOptions.LocalDevice)
            }
            .width('100%')
            .padding(DesignTokens.space.md)
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(DesignTokens.radius.lg)
            .border({ width: 1, color: $r('app.color.border_light') })
          }

          // Fingerprint info
          Column() {
            Text($r('app.string.local_fingerprint_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Text(this.localFingerprint.substring(0, 40) + '...')
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_primary'))
              .fontFamily('monospace')
              .wordBreak(WordBreak.BREAK_ALL)
              .width('100%')
              .margin({ top: DesignTokens.space.mini })

            Text($r('app.string.remote_fingerprint_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .margin({ top: DesignTokens.space.sm })
            Text(this.remoteFingerprint.substring(0, 40) + '...')
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_primary'))
              .fontFamily('monospace')
              .wordBreak(WordBreak.BREAK_ALL)
              .width('100%')
              .margin({ top: DesignTokens.space.mini })
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.border_light') })
          .margin({ top: DesignTokens.space.md })
        }
        .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.xl })
      }
      .layoutWeight(1)
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
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
