/**
 * ThemeStyles.ets — 预设主题风格定义
 * 替代颜色选择器，提供 LocalSend 原版风格的固定主题色选择
 */

export interface ThemeStyle {
  id: string
  label: string
  primaryColor: string
  accentColor: string
  lightBackground: string
  darkBackground: string
}

function createThemeStyle(id: string, label: string, primaryColor: string, accentColor: string,
  lightBackground: string, darkBackground: string): ThemeStyle {
  let style: ThemeStyle = {
    id: id,
    label: label,
    primaryColor: primaryColor,
    accentColor: accentColor,
    lightBackground: lightBackground,
    darkBackground: darkBackground
  };
  return style;
}

export const THEME_STYLES: Array<ThemeStyle> = [
  createThemeStyle('blue', 'Blue', '#3D8AF2', '#6BA3F5', '#E8F0FE', '#1A2A40'),
  createThemeStyle('green', 'Green', '#58DB6B', '#7DE68C', '#E8F5E9', '#1A3320'),
  createThemeStyle('purple', 'Purple', '#7232DD', '#915DE6', '#F3E8FF', '#1C1A30'),
  createThemeStyle('orange', 'Orange', '#F29C73', '#F5B896', '#FFF3E0', '#332210'),
  createThemeStyle('red', 'Red', '#DB3131', '#E55B5B', '#FFEBEE', '#3A1A1A'),
  createThemeStyle('teal', 'Teal', '#26A69A', '#4DB6AC', '#E0F2F1', '#1A3330'),
  createThemeStyle('pink', 'Pink', '#E91E63', '#F06292', '#FCE4EC', '#3A1A25'),
  createThemeStyle('brown', 'Brown', '#8D6E63', '#A1887F', '#EFEBE9', '#2C2018')
];

export function getThemeStyleById(id: string): ThemeStyle | null {
  for (let i = 0; i < THEME_STYLES.length; i++) {
    if (THEME_STYLES[i].id === id) {
      return THEME_STYLES[i];
    }
  }
  return null;
}

export function getDefaultThemeStyle(): ThemeStyle {
  return THEME_STYLES[0];
}
