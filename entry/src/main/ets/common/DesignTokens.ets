/**
 * DesignTokens.ets — 设计Token常量体系
 * 基于 HarmonyOS HDS 设计规范，统一字号/间距/圆角/动画/热区
 */

export interface FontTokens {
  displayL: number
  displayM: number
  displayS: number
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
  xs: number
  sm: number
  md: number
  lg: number
  xl: number
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

export interface HotspotTokens {
  minSize: number
}

export interface LayoutTokens {
  headerHeight: number
  iconSize: number
  qrCodeSize: number
}

export interface DesignTokensType {
  font: FontTokens
  space: SpaceTokens
  radius: RadiusTokens
  animation: AnimationTokens
  hotspot: HotspotTokens
  layout: LayoutTokens
}

export const DesignTokens: DesignTokensType = {
  // ── 字号体系 (fp) ──
  font: {
    displayL: 56,
    displayM: 48,
    displayS: 38,
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
    xs: 8,
    sm: 12,
    md: 16,
    lg: 24,
    xl: 32
  } as SpaceTokens,

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

  // ── 热区 ──
  hotspot: {
    minSize: 48
  } as HotspotTokens,

  // ── 布局 ──
  layout: {
    headerHeight: 56,
    iconSize: 24,
    qrCodeSize: 200
  } as LayoutTokens
};
