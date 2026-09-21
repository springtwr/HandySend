// Breakpoints.ets — 断点体系工具模块
// 基于系统宽度断点（sm/md/lg/xl）的布局参数取值工具，纯函数无系统依赖，可纳入设备端测试。
// 断点来源：@Env(SystemProperties.BREAK_POINT) 的 uiObserver.WindowSizeLayoutBreakpointInfo.widthBreakpoint，
// 类型为全局 WidthBreakpoint 枚举（WIDTH_XS/SM/MD/LG/XL，与官方断点区间 [320,600)/[600,840)/[840,1440)/[1440,+∞) 对齐）。

/**
 * 四档宽度断点取值工具。
 * 构造时传入 sm/md/lg/xl 四档值，getValue 按当前宽度断点返回对应值；
 * xs 断点（<320vp）复用 sm 值，与官方「两个宽度相近的窗口布局相同」原则一致。
 */
export class WidthBreakpointType<T> {
  private smValue: T
  private mdValue: T
  private lgValue: T
  private xlValue: T

  constructor(sm: T, md: T, lg: T, xl: T) {
    this.smValue = sm
    this.mdValue = md
    this.lgValue = lg
    this.xlValue = xl
  }

  getValue(widthBp: WidthBreakpoint): T {
    if (widthBp === WidthBreakpoint.WIDTH_XS || widthBp === WidthBreakpoint.WIDTH_SM) {
      return this.smValue
    }
    if (widthBp === WidthBreakpoint.WIDTH_MD) {
      return this.mdValue
    }
    if (widthBp === WidthBreakpoint.WIDTH_LG) {
      return this.lgValue
    }
    // WIDTH_XL 及未知取值统一返回 xl 档
    return this.xlValue
  }
}

// 内容最大宽度（vp）映射：md→800、lg→960、xl→1120；sm/xs→0 表示不限制（调用方按全宽处理）
const CONTENT_WIDTH_BY_BREAKPOINT: WidthBreakpointType<number> =
  new WidthBreakpointType<number>(0, 800, 960, 1120)

export function getMaxContentWidth(widthBp: WidthBreakpoint): number {
  return CONTENT_WIDTH_BY_BREAKPOINT.getValue(widthBp)
}

// 是否为窄屏宽度（xs/sm，即窗口宽度 <600vp）
export function isNarrowWidth(widthBp: WidthBreakpoint): boolean {
  return widthBp === WidthBreakpoint.WIDTH_XS || widthBp === WidthBreakpoint.WIDTH_SM
}

// 是否为宽屏宽度（lg/xl，即窗口宽度 ≥840vp）：
// 仅宽屏使用侧边 Tab 栏；md（600~840vp，平板竖屏/折叠屏展开态）与窄屏一致使用底部 Tab 栏，
// 避免 96vp 侧边栏挤压内容（剩余 <744vp）
export function isWideWidth(widthBp: WidthBreakpoint): boolean {
  return widthBp === WidthBreakpoint.WIDTH_LG || widthBp === WidthBreakpoint.WIDTH_XL
}

// 半屏弹窗宽度（vp）映射：sm/md→480，lg/xl→560
// 宽屏下半屏弹窗适度加宽，与内容限宽更协调
const SHEET_WIDTH_BY_BREAKPOINT: WidthBreakpointType<number> =
  new WidthBreakpointType<number>(480, 480, 560, 560)

export function getSheetWidth(widthBp: WidthBreakpoint): number {
  return SHEET_WIDTH_BY_BREAKPOINT.getValue(widthBp)
}

// 页面水平边距（vp）映射：sm→16（手机现状 space.md）、md→24、lg→24、xl→32
// 平板/宽屏加大页边距，避免内容贴边、提升大屏呼吸感
const PAGE_MARGIN_BY_BREAKPOINT: WidthBreakpointType<number> =
  new WidthBreakpointType<number>(16, 24, 24, 32)

export function getPageMargin(widthBp: WidthBreakpoint): number {
  return PAGE_MARGIN_BY_BREAKPOINT.getValue(widthBp)
}

// 平板竖屏判断：设备类型为 tablet 且纵向窗口（高宽比 ≥1.2）。
// 大平板竖屏宽度可达 lg/xl 断点，但竖屏可用视觉宽度有限，需要收紧内容限宽增大留白
function isTabletPortrait(deviceType: string, heightBp: HeightBreakpoint): boolean {
  return deviceType === 'tablet' && heightBp === HeightBreakpoint.HEIGHT_LG
}

// 页面内容最大宽度：按宽度断点限宽（sm/xs 不限制）、平板竖屏收紧至 800，
// 不限制时返回 '100%' 全宽（供 constraintSize({ maxWidth }) 直接使用）
export function getPageContentMaxWidth(widthBp: WidthBreakpoint, heightBp: HeightBreakpoint,
  deviceType: string): Length {
  let maxWidth: number = getMaxContentWidth(widthBp);
  if (isTabletPortrait(deviceType, heightBp)) {
    maxWidth = 800;
  }
  if (maxWidth === 0) {
    return '100%';
  }
  return maxWidth;
}
