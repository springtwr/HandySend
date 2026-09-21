/**
 * DesignTokens.ets — 设计Token常量体系
 * 基于 HarmonyOS HDS 设计规范，统一字号/间距/圆角/动画/尺寸/组件
 */

interface FontTokens {
  displayS: number
  iconInline: number
  iconXs: number
  titleM: number
  titleS: number
  subtitleL: number
  subtitleM: number
  subtitleS: number
  bodyL: number
  bodyM: number
  bodyS: number
  captionM: number
}

interface SpaceTokens {
  mini: number
  xxs: number
  tiny: number
  sm: number
  inner: number
  md: number
  lg: number
  card: number
  xl: number
}

interface SizeTokens {
  iconXs: number
  iconSm: number
  iconLg: number
  thumbSm: number
  inlineButton: number
  qrCodeSize: number
  tabBarClearance: number
  // 主页首张卡片统一最小高度（发送/接收页对齐）
  cardMinHeight: number
  // 传输进度条统一高度（各传输页对齐）
  progressBarHeight: number
}

interface RadiusTokens {
  sm: number
  md: number
  lg: number
  max: number
}

interface AnimationTokens {
  durationNormal: number
  listAppearDelay: number
  springStiffness: number
  springDamping: number
}

interface ComponentTokens {
  borderSlim: number
}

interface DesignTokensType {
  font: FontTokens
  space: SpaceTokens
  size: SizeTokens
  radius: RadiusTokens
  animation: AnimationTokens
  component: ComponentTokens
}

export const DesignTokens: DesignTokensType = {
  // ── 字号体系 (fp) ──
  font: {
    displayS: 36,
    iconInline: 20,
    iconXs: 12,
    titleM: 24,
    titleS: 20,
    subtitleL: 18,
    subtitleM: 16,
    subtitleS: 14,
    bodyL: 16,
    bodyM: 14,
    bodyS: 12,
    captionM: 10
  } as FontTokens,

  // ── 间距体系 (vp) ──
  space: {
    mini: 2,
    xxs: 4,
    tiny: 8,
    sm: 12,
    inner: 10,
    md: 16,
    lg: 24,
    card: 20,
    xl: 32
  } as SpaceTokens,

  // ── 尺寸体系 (vp) ──
  size: {
    iconXs: 16,
    iconSm: 24,
    iconLg: 40,
    thumbSm: 48,
    inlineButton: 28,
    qrCodeSize: 200,
    tabBarClearance: 80,
    cardMinHeight: 220,
    progressBarHeight: 4
  } as SizeTokens,

  // ── 圆角体系 (vp) ──
  radius: {
    sm: 4,
    md: 8,
    lg: 16,
    max: 9999
  } as RadiusTokens,

  // ── 动画参数 ──
  animation: {
    durationNormal: 350,
    listAppearDelay: 30,
    springStiffness: 0.6,
    springDamping: 0.8
  } as AnimationTokens,

  // ── 组件级常量 ──
  component: {
    borderSlim: 1
  } as ComponentTokens
};
