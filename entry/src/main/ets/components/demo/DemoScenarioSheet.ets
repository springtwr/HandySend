/**
 * DemoScenarioSheet.ets — 演示场景选择菜单（仅演示分支存在）
 *
 * 点击演示设备时弹出的操作列表弹窗：标题展示设备昵称，
 * 四个场景项（收文件请求 / 收文本消息 / 发出文件传输 / 发出文本消息）+ 语言切换组 + 取消。
 * 语言切换组是演示截图流程的语言入口（复用既有 setLocale，冷启动生效）；
 * 应用页面本身不引入任何演示可见元素，保证截图与原版一致。
 * 风格对齐项目既有 B 类弹窗（CustomContentDialogV2 + DesignTokens 间距与卡片样式）。
 */

import { CustomContentDialogV2, AdvancedDialogV2Button } from '@kit.ArkUI';
import { DiscoveredDevice } from '../../model/Types';
import { DesignTokens } from '../../common/DesignTokens';
import { DemoScenarioType } from '../../service/demo/DemoData';
import { LANGUAGE_LIST, LanguageOption } from '../../common/LanguageConstants';
import { setLocale, getLocale } from '../../service/repository/SettingsRepository';

/** 场景菜单项展示定义 */
interface DemoScenarioOption {
  type: DemoScenarioType
  label: Resource
  icon: Resource
}

/** 四个场景项（顺序固定：收方向在前、发方向在后） */
const SCENARIO_OPTIONS: Array<DemoScenarioOption> = [
  {
    type: DemoScenarioType.receiveFiles,
    label: $r('app.string.demo_scenario_receive_files'),
    icon: $r('sys.symbol.download')
  },
  {
    type: DemoScenarioType.receiveText,
    label: $r('app.string.demo_scenario_receive_text'),
    icon: $r('sys.symbol.message')
  },
  {
    type: DemoScenarioType.sendFiles,
    label: $r('app.string.demo_scenario_send_files'),
    icon: $r('sys.symbol.upload')
  },
  {
    type: DemoScenarioType.sendText,
    label: $r('app.string.demo_scenario_send_text'),
    icon: $r('sys.symbol.paperplane')
  }
];

/** 语言切换组的可选项：沿用设置页语言清单，剔除「跟随系统」（演示截图需确定性语言） */
const DEMO_LANGUAGE_OPTIONS: Array<LanguageOption> =
  LANGUAGE_LIST.filter((item: LanguageOption) => item.value !== '');

@ComponentV2
export struct DemoScenarioSheet {
  /** 触发场景菜单的演示设备（菜单标题展示设备昵称） */
  @Require @Param device: DiscoveredDevice
  /** 选中场景回调（由宿主关闭弹窗并触发对应模拟场景） */
  @Event onScenario: (type: DemoScenarioType) => void = (_type: DemoScenarioType) => {
  }
  /** 选中语言回调（由宿主关闭弹窗；语言经既有 setLocale 持久化，重启后生效） */
  @Event onLanguage: () => void = () => {
  }
  /** 取消回调 */
  @Event onCancel: () => void = () => {
  }

  build() {
    CustomContentDialogV2({
      primaryTitle: this.device.alias,
      contentBuilder: () => {
        this.scenarioContent();
      },
      buttons: [
        new AdvancedDialogV2Button({
          content: $r('app.string.dialog_cancel'),
          action: () => {
            this.onCancel();
          }
        })
      ]
    })
    // 宽屏下限制弹窗最大宽度，避免铺满过宽（与项目既有弹窗一致）
      .constraintSize({ maxWidth: 480 })
  }

  @Builder
  scenarioContent() {
    Column({ space: DesignTokens.space.xxs }) {
      Text($r('app.string.demo_scenario_menu_title'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: DesignTokens.space.tiny })
        .id('demo_scenario_menu_hint')
      ForEach(SCENARIO_OPTIONS, (option: DemoScenarioOption) => {
        Row({ space: DesignTokens.space.sm }) {
          SymbolGlyph(option.icon)
            .fontSize(DesignTokens.size.iconSm)
            .fontColor([$r('app.color.text_primary')])
            .id(`demo_scenario_icon_${option.type}`)
          Text(option.label)
            .fontSize(DesignTokens.font.bodyL)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .id(`demo_scenario_label_${option.type}`)
        }
        .width('100%')
        .padding({
          left: DesignTokens.space.md,
          right: DesignTokens.space.md,
          top: DesignTokens.space.md,
          bottom: DesignTokens.space.md
        })
        .borderRadius(DesignTokens.radius.md)
        .backgroundColor($r('app.color.card_background'))
        .onClick(() => {
          this.onScenario(option.type);
        })
        .id(`demo_scenario_row_${option.type}`)
      }, (option: DemoScenarioOption) => option.type)
      // 语言切换组：演示截图流程的语言入口，选中项高亮样式对齐设置页语言弹窗
      Divider()
        .color($r('app.color.border_light'))
        .margin({
          top: DesignTokens.space.sm,
          bottom: DesignTokens.space.sm
        })
        .id('demo_scenario_language_divider')
      Text($r('app.string.demo_menu_language'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: DesignTokens.space.tiny })
        .id('demo_scenario_language_hint')
      ForEach(DEMO_LANGUAGE_OPTIONS, (option: LanguageOption) => {
        Row() {
          Text(option.label)
            .fontSize(DesignTokens.font.bodyL)
            .fontColor(
              getLocale() === option.value ? $r('app.color.accent_blue') : $r('app.color.text_primary'))
            .fontWeight(getLocale() === option.value ? FontWeight.Bold : FontWeight.Normal)
            .layoutWeight(1)
            .id(`demo_scenario_language_${option.value}`)
        }
        .width('100%')
        .padding({
          left: DesignTokens.space.md,
          right: DesignTokens.space.md,
          top: DesignTokens.space.md,
          bottom: DesignTokens.space.md
        })
        .borderRadius(DesignTokens.radius.md)
        .backgroundColor($r('app.color.card_background'))
        .onClick(() => {
          setLocale(option.value);
          this.onLanguage();
        })
        .id(`demo_scenario_language_row_${option.value}`)
      }, (option: LanguageOption) => option.value)
    }
    .width('100%')
  }
}
