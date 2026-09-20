import { DesignTokens } from '../../common/DesignTokens';
import { SettingsViewModel } from '../../viewmodel/SettingsViewModel';
import {
  MtaSelectableBrand,
  mtaSelectableBrands,
  resolveMtaBrandDisplayName,
  resolveMtaBrandIcon
} from '../../model/mta/MtaBrandRegistry';
import { getSheetWidth, isWideWidth } from '../../common/Breakpoints';
import { uiObserver } from '@kit.ArkUI';

// 互传联盟（MTA）设置分组：MTA 接收开关 + 模拟品牌选择。
// 数据经 @Param 绑定父组件 VM，命令直调 VM（View → ViewModel）。
@ComponentV2
export struct MtaSettingsSection {
  // 系统宽度断点（随窗口尺寸变化自动刷新，半屏弹窗宽度断点化用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Require @Param viewModel: SettingsViewModel
  // 是否展示模拟品牌半屏弹窗
  @Local isShowBrandSheet: boolean = false
  // 可模拟品牌清单（构造时取一次，保证顺序稳定且避免重复计算）
  private brandOptions: Array<MtaSelectableBrand> = mtaSelectableBrands()

  // 模拟品牌半屏弹窗：列表项 = 品牌图标 + 本地化显示名，点选即写入并关闭
  @Builder
  brandSheetBuilder(): void {
    Column() {
      // 卡片容器：列表项 + Divider 分隔线
      Column() {
        List({ space: 0 }) {
          ForEach(this.brandOptions, (item: MtaSelectableBrand, index: number) => {
            ListItem() {
              Column() {
                Row({ space: DesignTokens.space.sm }) {
                  Image(item.iconRes)
                    .width(DesignTokens.size.iconSm)
                    .height(DesignTokens.size.iconSm)

                  Text(item.displayNameRes)
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor(this.viewModel.mtaSimulatedBrandId === item.canonical ? $r('app.color.accent_blue') :
                      $r('app.color.text_primary'))
                    .fontWeight(
                      this.viewModel.mtaSimulatedBrandId === item.canonical ? FontWeight.Bold : FontWeight.Normal)
                    .layoutWeight(1)
                }
                .width('100%')
                .padding({
                  left: DesignTokens.space.lg,
                  right: DesignTokens.space.lg,
                  top: 14,
                  bottom: 14
                })
                .constraintSize({ minHeight: DesignTokens.size.thumbSm })
                .alignItems(VerticalAlign.Center)
                .borderRadius(DesignTokens.radius.md)
                .onClick(() => {
                  this.viewModel.setMtaSimulatedBrandValue(item.canonical);
                  this.isShowBrandSheet = false;
                })
                .id('settings_mta_brand_option')

                if (index < this.brandOptions.length - 1) {
                  Divider().color($r('app.color.border_light'))
                }
              }
              .width('100%')
            }
          }, (item: MtaSelectableBrand) => `${item.canonical}`)
        }
        .width('100%')
      }
      .width('100%')
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(DesignTokens.radius.lg)
      .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
    }
    .width('100%')
    .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.lg })
  }

  build() {
    Column() {
      // 卡片（标题由设置分组统一渲染）
      Column() {
        // 互传联盟接收（默认开启）：应用在前台时以互传联盟身份接收附近设备传输
        Row() {
          Text($r('app.string.mta_receive_enabled_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.viewModel.mtaReceiveEnabled })
            .onChange((isOn: boolean) => {
              this.viewModel.setMtaReceiveEnabledValue(isOn);
            })
            .id('settings_mta_receive_toggle')
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)

        Text($r('app.string.mta_receive_enabled_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: DesignTokens.space.tiny })

        // 模拟品牌：显示当前品牌图标 + 本地化显示名，点击打开半屏选择弹窗
        Row() {
          Text($r('app.string.mta_simulated_brand_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Row({ space: DesignTokens.space.tiny }) {
            Image(resolveMtaBrandIcon(this.viewModel.mtaSimulatedBrandId))
              .width(DesignTokens.size.iconSm)
              .height(DesignTokens.size.iconSm)

            Text(resolveMtaBrandDisplayName(this.viewModel.mtaSimulatedBrandId))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            SymbolGlyph($r('sys.symbol.chevron_forward'))
              .fontSize(DesignTokens.font.titleS)
              .fontColor([$r('app.color.text_secondary')])
          }
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.isShowBrandSheet = true;
        })
        .id('settings_mta_simulated_brand_entry')
        .bindSheet($$this.isShowBrandSheet, this.brandSheetBuilder(), {
          height: SheetSize.MEDIUM,
          width: getSheetWidth(this.breakpointInfo.widthBreakpoint),
          // 宽屏（lg/xl）以居中弹窗呈现，窄屏保持底部弹窗（与手机行为一致）
          preferType: isWideWidth(this.breakpointInfo.widthBreakpoint) ? SheetType.CENTER : SheetType.BOTTOM,
          blurStyle: BlurStyle.Regular,
          title: {
            title: $r('app.string.mta_brand_picker_title'),
            subtitle: ''
          },
          showClose: true
        })

        Text($r('app.string.mta_simulated_brand_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: DesignTokens.space.tiny })

        // 互传连接提醒（默认开启）：关闭后主页面不再显示互传相关的蓝牙/WLAN 警告横幅
        Row() {
          Text($r('app.string.mta_connection_warnings_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.viewModel.mtaConnectionWarnings })
            .onChange((isOn: boolean) => {
              this.viewModel.setMtaConnectionWarningsValue(isOn);
            })
            .id('settings_mta_connection_warnings_toggle')
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })
        .alignItems(VerticalAlign.Center)

        Text($r('app.string.mta_connection_warnings_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: DesignTokens.space.tiny })
      }
      .padding({
        left: DesignTokens.space.lg,
        right: DesignTokens.space.lg,
        top: DesignTokens.space.md,
        bottom: DesignTokens.space.md
      })
      .borderRadius(DesignTokens.radius.lg)
      .backgroundColor($r('app.color.card_background'))
      .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
      .margin({ top: DesignTokens.space.sm })
    }
    .width('100%')
  }
}
