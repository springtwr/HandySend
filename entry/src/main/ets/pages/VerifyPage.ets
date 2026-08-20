import { DesignTokens } from '../common/DesignTokens';
import { VerifyViewModel } from '../viewmodel/VerifyViewModel';

@Entry
@ComponentV2
struct VerifyPage {
  @Local viewModel: VerifyViewModel = new VerifyViewModel();

  aboutToAppear(): void {
    // MaterialIcons 字体已在 EntryAbility 中全局注册——此处无需再注册

    let params = this.getUIContext().getRouter().getParams() as Record<string, string>;
    if (params !== undefined) {
      const localFingerprint: string = params['localFingerprint'] !== undefined ? params['localFingerprint'] as string : '';
      const remoteFingerprint: string = params['remoteFingerprint'] !== undefined ? params['remoteFingerprint'] as string : '';
      this.viewModel.loadFingerprints(localFingerprint, remoteFingerprint);
    }
  }

  build() {
    Column() {
      // 标题栏
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
          // 说明文本
          Text($r('app.string.verify_instruction'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .margin({ top: DesignTokens.space.md, bottom: DesignTokens.space.lg })

          // 模式切换：图标 / 文本
          Row() {
            Text($r('app.string.verify_icon_mode'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor(!this.viewModel.showHex ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
              .fontWeight(!this.viewModel.showHex ? FontWeight.Bold : FontWeight.Normal)
              .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
              .backgroundColor(!this.viewModel.showHex ? $r('app.color.accent_blue_bg') : Color.Transparent)
              .borderRadius({ topLeft: DesignTokens.radius.md, bottomLeft: DesignTokens.radius.md })
              .onClick(() => {
                this.viewModel.setDisplayMode(false);
              })

            Text($r('app.string.verify_hex_mode'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor(this.viewModel.showHex ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
              .fontWeight(this.viewModel.showHex ? FontWeight.Bold : FontWeight.Normal)
              .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
              .backgroundColor(this.viewModel.showHex ? $r('app.color.accent_blue_bg') : Color.Transparent)
              .borderRadius({ topRight: DesignTokens.radius.md, bottomRight: DesignTokens.radius.md })
              .onClick(() => {
                this.viewModel.setDisplayMode(true);
              })
          }
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .borderRadius(DesignTokens.radius.md)
          .border({ width: 1, color: $r('app.color.border_light') })
          .margin({ bottom: DesignTokens.space.lg })

          // 显示区域
          if (!this.viewModel.showHex) {
            // 图标模式：Material 图标 4 列网格
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
              Repeat(this.viewModel.combinedIcons).each((ri: RepeatItem<string>) => {
                Text(ri.item)
                  .fontSize(DesignTokens.font.displayS)
                  .fontFamily('MaterialIcons')
                  .fontColor($r('app.color.text_primary'))
                  .width('25%')
                  .textAlign(TextAlign.Center)
                  .padding(DesignTokens.space.xs)
              }).key((item: string, index: number) => index.toString())
            }
            .width('100%')
            .padding(DesignTokens.space.md)
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(DesignTokens.radius.lg)
            .border({ width: 1, color: $r('app.color.border_light') })
          } else {
            // 文本模式：直接显示组合指纹字符串
            // 与 LocalSend 原版一致：SelectableText(fingerprint.combined)
            Column() {
              Text(this.viewModel.combinedFingerprint)
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

          // 指纹信息
          Column() {
            Text($r('app.string.local_fingerprint_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Text(this.viewModel.localFingerprint.substring(0, 40) + '...')
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
            Text(this.viewModel.remoteFingerprint.substring(0, 40) + '...')
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
