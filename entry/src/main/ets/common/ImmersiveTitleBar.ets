/**
 * ImmersiveTitleBar.ets — 沉浸式标题栏配置工厂
 *
 * 全应用统一的顶部表现：标题栏层叠于内容之上、设为组件级安全区（内容区自动避让标题栏，
 * 同时允许内容从标题栏下方穿过）。
 *
 * 安全区与起始端内边距按形态参数化：宽屏主界面关闭自动避让并右移标题栏内容，
 * 使侧边栏品牌区与内容区标题栏同处一个高度带且互不重叠；子页面与窄屏沿用默认配置。
 *
 * 通透悬浮的观感来自**系统沉浸光感材质**（组件级开启，见 systemMaterialEffect）：材质生效时
 * 其优先级高于组件自身设置的背景色/模糊/阴影/边框，标题栏交互区域由材质呈现。
 * 由此，模糊与蒙层相关配置保留为**材质不可用时的回退路径**（此时标题栏表现为"毛玻璃随滚动渐显"）。
 * 主页面与全部路由子页面共用同一份配置，避免逐页内联造成的观感漂移。
 */

import { LengthMetrics } from '@kit.ArkUI';
import {
  BlurStrategy,
  HdsNavigationMenuContentOptions,
  HdsNavigationTitleBarOptions,
  HdsTitleBarContentStyle,
  hdsMaterial,
  ScrollEffectType,
  TitleBarContentOptions,
  TitleBarStyleOptions
} from '@kit.UIDesignKit';
import { getLogger } from '../utils/Logger';
import { LogDomains } from './LogDomains';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:ImmersiveTitleBar', '沉浸式标题栏');

// 标题栏滚动渐显的起止偏移（vp）：内容未滚动时不显背板，滚动到结束偏移时背板达到最终强度。
// 起止偏移决定渐显手感，全应用统一取值以保证主/子页面顶部观感一致。
const BLUR_START_OFFSET_VP: number = 0;
const BLUR_END_OFFSET_VP: number = 56;

// 标题栏渐变模糊的模糊半径：仅渐变模糊与沉浸式渐变模糊生效（取值 0.0~128.0，起始 6.1.0(23)，
// 与本工程兼容下限一致）；通用模糊取不到该半径，故模糊类型必须采用渐变模糊。
const BLUR_RADIUS: number = 16.0;

/**
 * 标题栏配置入参：标题文案 + 可选的结束端菜单内容 + 按形态参数化的可选覆盖项。
 *
 * 标题恒为必填：标题栏配置按字段合并、省略字段会让组件沿用上一次的值，故「不显示页签名」的形态
 * 须显式下发空标题，而不是省略该字段。宽屏主界面另需关闭内容区对标题栏的自动避让（改由内容区自行预留顶部避让）。
 */
export interface ImmersiveTitleBarParams {
  /** 标题文案；宽屏主界面下发空字符串，表示该形态不显示页签名（页签识别由侧边栏选中高亮项承担）。 */
  title: ResourceStr
  menu?: HdsNavigationMenuContentOptions
  /** 标题栏是否作为组件级安全区（内容区据此自动避让标题栏）；不传时为 true。 */
  enableComponentSafeArea?: boolean
  /** 滚动终点态的背景板模糊半径；不传时取 BLUR_RADIUS（保持既有滚动模糊强度）。 */
  scrollBlurRadius?: number
  /** 标题栏底部自定义区域内容；不传时该区域不设置（保持组件默认表现）。 */
  bottomBuilder?: CustomBuilder
}

/**
 * 标题栏滚动渐显能力检测。
 *
 * 套件导航组件所属系统能力在兼容下限即可用，正常不触发降级；能力缺失时关闭滚动动态过渡，
 * 使标题栏样式常驻（保留毛玻璃背板），避免背板缺失或异常。
 */
function supportsTitleBarScrollEffect(): boolean {
  return canIUse('SystemCapability.UIDesign.HDSComponent.Core');
}

// 设备材质档位探测结果缓存：能力探测只在首次构造标题栏样式时执行一次
let cachedMaterialLevel: hdsMaterial.MaterialLevel | undefined = undefined;

/**
 * 标题栏沉浸光感材质的档位：按设备能力探测决定。
 *
 * 该探测位于全页面共用的标题栏工厂中，一旦抛异常会波及所有页面的标题栏构造，
 * 故须先做运行时能力判定、并对探测本身容错：能力缺失或探测失败一律降级为默认档位（自适应）。
 * 结果同样写入缓存（含降级结果），避免每次重建标题栏都重试。
 * 设备不支持沉浸式材质类型时降级到较轻档位（官方做法），避免低算力设备卡顿与发热。
 */
function resolveMaterialLevel(): hdsMaterial.MaterialLevel {
  if (cachedMaterialLevel !== undefined) {
    return cachedMaterialLevel;
  }
  let level: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
  // 与同文件 supportsTitleBarScrollEffect() 使用同一项系统能力判定
  if (canIUse('SystemCapability.UIDesign.HDSComponent.Core')) {
    try {
      let materialTypes: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      if (materialTypes.indexOf(hdsMaterial.MaterialType.IMMERSIVE) < 0) {
        level = hdsMaterial.MaterialLevel.SMOOTH;
      }
    } catch (e) {
      logger.warn('query system material types failed, fallback to adaptive level: ' + String(e));
    }
  }
  cachedMaterialLevel = level;
  return level;
}

/**
 * 标题栏样式：组件级沉浸光感材质 + （材质不可用时的）强制使能滚动动态沉浸式渐变模糊。
 *
 * 通透观感的主路径是 systemMaterialEffect 开启的系统沉浸光感材质（仅组件级开启，不影响应用内其他组件）：
 * 材质生效时其优先级高于组件自身设置的背景色/模糊/阴影/边框，故下方的模糊与蒙层配置此时不参与决定观感，
 * 仅作为**材质不可用时的回退路径**保留（回退时表现为"毛玻璃随内容滚动渐显"）。
 *
 * 回退路径的模糊类型必须使用沉浸式渐变模糊（而非普通渐变模糊）：模糊半径只对渐变模糊类生效
 * （取值范围 0.0~128.0），通用模糊取不到半径，只能得到一个均匀背板——官方通用模糊示例中
 * 该背板配的是不透明底色（系统一级背景色），实测即表现为纯色不透明块。而在两者都能取到半径的
 * 渐变模糊类中，动态过渡开启时普通渐变模糊的终点蒙层默认取**深色半透明**、主标题默认切为
 * **反差色**（浅色主题下即白字），与系统基线不符；沉浸式渐变模糊的默认蒙层为浅色雾面、
 * 主标题不切反差色，故选用后者。回退路径的模糊生效策略刻意使用强制使能：自适应策略的语义是
 * "模糊能否生效由系统策略档位决定，仅最高（精美）档位生效"，非最高档位下模糊不生效；
 * 强制使能保证各档位下均为半透明模糊，代价是低算力设备的渲染开销上升，故模糊只作用于标题栏单层。
 *
 * 背景与文字色处理：
 * - 回退路径两态均不使用组件默认蒙层底色：起始态本就默认透明，滚动终点态显式设为透明
 *   （该类型默认取主题化灰蒙层，不透明度偏高，会把穿透上来的内容洗成近白、退化为"不透明面板"）；
 *   终点态的视觉因此完全来自模糊半径生效后的模糊本身。
 * - 两态的内容区样式取同一份：菜单 / 返回按钮的背板取页面卡片背景色（作为材质与模糊均不可用时的兜底），
 *   图标色显式取页面主文字色，避免图标与材质背板或自设背板同色而不可辨；
 *   标题色显式固定为页面主/次文字色，避免滚动前后标题在"文字色 ↔ 反差色"之间发生色系突变。
 */
function immersiveTitleBarStyle(scrollBlurRadius: number): TitleBarStyleOptions {
  let contentStyle: HdsTitleBarContentStyle = {
    // 标题色两态同值：滚动前后保持同一色系，不随动态样式切换为反差色
    titleStyle: {
      mainTitleColor: $r('app.color.text_primary'),
      subTitleColor: $r('app.color.text_secondary')
    },
    // 按钮背板与图标色两态同值：保证浅色 / 深色主题下图标与背板、材质的对比度足够
    menuStyle: {
      backgroundColor: $r('app.color.card_background'),
      iconColor: $r('app.color.text_primary')
    },
    backIconStyle: {
      backgroundColor: $r('app.color.card_background'),
      iconColor: $r('app.color.text_primary')
    }
  };
  return {
    // 系统沉浸光感材质（组件级开启）：材质类型取自适应，档位按设备材质能力探测结果决定
    systemMaterialEffect: {
      materialType: hdsMaterial.MaterialType.ADAPTIVE,
      materialLevel: resolveMaterialLevel()
    },
    scrollEffectOpts: {
      enableScrollEffect: supportsTitleBarScrollEffect(),
      scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
      blurEffectiveStartOffset: LengthMetrics.vp(BLUR_START_OFFSET_VP),
      blurEffectiveEndOffset: LengthMetrics.vp(BLUR_END_OFFSET_VP)
    },
    blurStrategy: BlurStrategy.ENABLE,
    // 未滚动（过渡起始）态：仅内容区样式，蒙层保持组件默认透明
    originalStyle: { contentStyle: contentStyle },
    // 滚动终点态：内容区样式同值 + 仅由模糊半径产生的模糊，蒙层背景显式透明
    scrollEffectStyle: {
      contentStyle: contentStyle,
      backgroundStyle: {
        blurRadius: scrollBlurRadius,
        backgroundColor: Color.Transparent
      }
    }
  };
}

/**
 * 构造沉浸式标题栏配置：标题文案 + 结束端菜单 + 统一样式 + 组件级安全区。
 *
 * 组件级安全区让内容区自动按实际标题栏高度避让（首条内容不被标题栏遮挡），
 * 同时不影响内容延伸绘制到标题栏下方，是内容穿透与安全区扩展同时成立的前提。
 * 宽屏主界面关闭该避让（内容区因此上延到标题栏所在高度带），改由内容区自行预留顶部避让。
 * 标题与菜单均须恒定下发（见下方注释）：组件按字段合并配置，省略字段会沿用上一次的值。
 */
export function buildImmersiveTitleBar(params: ImmersiveTitleBarParams): HdsNavigationTitleBarOptions {
  let content: TitleBarContentOptions = {};
  // 标题字段须恒定下发：省略该字段会让组件保留上一次设置的标题——平板由竖屏（有页签名）转为横屏
  // （宽屏侧边栏形态）时，页签名会被带过去压在侧边栏区域上方；故不显示页签名的形态显式下发空标题。
  content.title = { mainTitle: params.title };
  // 菜单字段须恒定下发：省略该字段会让组件保留上一次设置的菜单，切换到无入口页签时
  // 表现为「更多」入口残留；无入口时显式下发空菜单，使标题栏结束端可靠清空。
  let menuContent: HdsNavigationMenuContentOptions = { value: [] };
  if (params.menu !== undefined) {
    menuContent = params.menu;
  }
  content.menu = menuContent;
  // 标题栏底部自定义区域按需下发：仅在调用方提供内容时设置，未提供时保持组件默认（不设置该字段）
  if (params.bottomBuilder !== undefined) {
    content.bottomBuilder = { builder: params.bottomBuilder };
  }
  return {
    enableComponentSafeArea: params.enableComponentSafeArea ?? true,
    style: immersiveTitleBarStyle(params.scrollBlurRadius ?? BLUR_RADIUS),
    content: content
  };
}
