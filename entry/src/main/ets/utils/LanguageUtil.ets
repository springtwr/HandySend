import { LANGUAGE_LIST } from '../common/LanguageConstants';

/**
 * LanguageUtil
 * 纯逻辑工具：根据语言代码查询显示名。无 UI 状态、无副作用。
 */
export function getLanguageDisplayName(code: string): ResourceStr {
  for (let i = 0; i < LANGUAGE_LIST.length; i++) {
    if (LANGUAGE_LIST[i].value === code) {
      return LANGUAGE_LIST[i].label;
    }
  }
  return code;
}
