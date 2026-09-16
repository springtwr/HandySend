import { DesignTokens } from '../common/DesignTokens';
import { getPageContentMaxWidth, getPageMargin } from '../common/Breakpoints';
import { deviceInfo } from '@kit.BasicServicesKit';
import { VerifyViewModel } from '../viewmodel/VerifyViewModel';
import { TabSegmentButtonV2, SegmentButtonV2Items, uiObserver } from '@kit.ArkUI';

@ComponentV2
export struct VerifyPage {
  // 系统宽度断点（随窗口尺寸变化自动刷新，宽屏限宽用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: VerifyViewModel = new VerifyViewModel();
  @Local selectedIndex: number = 0;
  // 路由参数（经 VerifyPageBuilder 传入，结构与旧 pushUrl params 一致）
  @Param pageParam: Object = new Object()
  private swiperController: SwiperController = new SwiperController();
  // 验证区最小高度：与图标模式自然高度对齐（4 行图标网格 + 卡片内边距），
  // 文本模式内容不足时撑到该高度、内容超过时才自适应，避免两页高度悬殊
  private readonly verifyAreaMinHeight: number =
    DesignTokens.font.displayS * 4 + DesignTokens.space.tiny * 8 + DesignTokens.space.md * 2;
  // 官方分段按钮（TabSegmentButtonV2）选项集合：图标 / 文本 两种验证视图
  // 官方示例写法：SegmentButtonV2Items 直接以选项字面量数组构造
  private segmentItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: $r('app.string.verify_icon_mode') },
    { text: $r('app.string.verify_hex_mode') }
  ]);
  // NavDestination 返回栈（onReady 注入）
  private pathStack: NavPathStack = new NavPathStack()

  aboutToAppear(): void {
    // MaterialIcons 字体已在 EntryAbility 中全局注册——此处无需再注册

    let params: Record<string, string> = this.pageParam as Record<string, string>;
    if (params !== undefined) {
      const localFingerprint: string =
        params['localFingerprint'] !== undefined ? params['localFingerprint'] as string : '';
      const remoteFingerprint: string =
        params['remoteFingerprint'] !== undefined ? params['remoteFingerprint'] as string : '';
      this.viewModel.loadFingerprints(localFingerprint, remoteFingerprint);
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
        // 内容区：胶囊分段选择器 + 描述文本 + 验证区域（Swiper 支持滑动切换与转场）
        Column() {
          // 胶囊分段选择器（图标 / 文本），紧凑不占满宽
          // 采用官方 SegmentButtonV2（TabSegmentButtonV2）：华为标准"内容区切换"分段控件
          TabSegmentButtonV2({
            items: this.segmentItems,
            selectedIndex: this.selectedIndex,
            $selectedIndex: (index: number) => {
              // 立即同步高亮（不等 Swiper 动画播完），并驱动 Swiper 滑动切换
              this.selectedIndex = index;
              this.swiperController.changeIndex(index, true);
            },
            enableStateAnimation: true
          })
            .width(164)
            .alignSelf(ItemAlign.Center)

          // 描述性文本（居中）
          Text($r('app.string.verify_instruction'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: DesignTokens.space.sm, bottom: DesignTokens.space.lg })

          // 验证区域：图标 / 文本，Swiper 提供滑动切换与转场动画。
          // 不设 layoutWeight/height('100%')：高度自适应内容，避免卡片被拉满整页导致下方大片空白
          Swiper(this.swiperController) {
            // 图标模式
            Column() {
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
                Repeat(this.viewModel.combinedIcons).each((ri: RepeatItem<string>) => {
                  Text(ri.item)
                    .fontSize(DesignTokens.font.displayS)
                    .fontFamily('MaterialIcons')
                    .fontColor($r('app.color.text_primary'))
                    .width('25%')
                    .textAlign(TextAlign.Center)
                    .padding(DesignTokens.space.tiny)
                }).key((item: string, index: number) => index.toString())
              }
              .width('100%')
            }
            .width('100%')
            .constraintSize({ minHeight: this.verifyAreaMinHeight })
            .justifyContent(FlexAlign.Center)
            .padding(DesignTokens.space.md)
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(DesignTokens.radius.lg)
            .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })

            // 文本模式
            Column() {
              Text(this.viewModel.combinedFingerprint)
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .fontFamily('monospace')
                .wordBreak(WordBreak.BREAK_ALL)
                .textAlign(TextAlign.Center)
                .copyOption(CopyOptions.LocalDevice)
                .width('100%')
            }
            .width('100%')
            .constraintSize({ minHeight: this.verifyAreaMinHeight })
            .justifyContent(FlexAlign.Center)
            .padding(DesignTokens.space.md)
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(DesignTokens.radius.lg)
            .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
          }
          // 关闭循环滑动（loop 默认开启，会导致标签可无限循环切换）
          .loop(false)
          // 滑动动画开始时即同步标签高亮（onChange 要等动画播完才回调，造成延时）
          .onAnimationStart((_index: number, targetIndex: number) => {
            this.selectedIndex = targetIndex;
          })
          .onChange((index: number) => {
            this.selectedIndex = index;
          })
          .indicator(false)
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .padding({
          left: getPageMargin(this.breakpointInfo.widthBreakpoint),
          right: getPageMargin(this.breakpointInfo.widthBreakpoint)
        })
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: this.getContentMaxWidth() })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      // 内容从顶部排列，避免内容不满一屏时被交叉轴默认居中
      .alignItems(VerticalAlign.Top)
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .title($r('app.string.verify_title'), { backgroundColor: $r('app.color.page_background') })
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}

// 路由表引用：VerifyPageBuilder(name, param)
@Builder
export function VerifyPageBuilder(name: string, param: Object) {
  VerifyPage({ pageParam: param })
}
