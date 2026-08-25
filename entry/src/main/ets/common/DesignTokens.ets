/**
 * DesignTokens.ets — 设计Token常量体系
 * 基于 HarmonyOS HDS 设计规范，统一字号/间距/圆角/动画/尺寸/组件
 */

export interface FontTokens {
  displayXl: number
  displayL: number
  displayM: number
  displayS: number
  iconInline: number
  iconXs: number
  titleL: number
  titleM: number
  titleS: number
  subtitleL: number
  subtitleM: number
  subtitleS: number
  bodyL: number
  bodyM: number
  bodyS: number
  captionL: number
  captionM: number
}

export interface SpaceTokens {
  mini: number
  xxs: number
  tiny: number
  sm: number
  inner: number
  md: number
  lg: number
  card: number
  xl: number
  xxl: number
}

export interface SizeTokens {
  iconXs: number
  iconSm: number
  iconMd: number
  iconLg: number
  thumbSm: number
  thumbMd: number
  thumbLg: number
  inlineButton: number
  headerHeight: number
  qrCodeSize: number
  sheetWidth: number
  tabBarClearance: number
}

export interface RadiusTokens {
  sm: number
  md: number
  lg: number
  max: number
}

export interface AnimationTokens {
  durationFast: number
  durationNormal: number
  durationSlow: number
  listAppearDelay: number
  springStiffness: number
  springDamping: number
}

export interface ComponentTokens {
  borderSlim: number
}

export interface DesignTokensType {
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
    displayXl: 64,
    displayL: 56,
    displayM: 48,
    displayS: 36,
    iconInline: 20,
    iconXs: 12,
    titleL: 30,
    titleM: 24,
    titleS: 20,
    subtitleL: 18,
    subtitleM: 16,
    subtitleS: 14,
    bodyL: 16,
    bodyM: 14,
    bodyS: 12,
    captionL: 12,
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
    xl: 32,
    xxl: 48
  } as SpaceTokens,

  // ── 尺寸体系 (vp) ──
  size: {
    iconXs: 16,
    iconSm: 24,
    iconMd: 32,
    iconLg: 40,
    thumbSm: 48,
    thumbMd: 64,
    thumbLg: 80,
    inlineButton: 28,
    headerHeight: 56,
    qrCodeSize: 200,
    sheetWidth: 480,
    tabBarClearance: 80
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
    durationFast: 200,
    durationNormal: 350,
    durationSlow: 500,
    listAppearDelay: 30,
    springStiffness: 0.6,
    springDamping: 0.8
  } as AnimationTokens,

  // ── 组件级常量 ──
  component: {
    borderSlim: 1
  } as ComponentTokens
};
