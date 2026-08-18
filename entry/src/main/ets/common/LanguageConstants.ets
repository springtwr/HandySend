/**
 * LanguageConstants
 * 语言选项配置常量。无业务实体身份，归类为纯配置，放 common/。
 */

export class LanguageOption {
  value: string = '';
  label: string = '';
  bcp47: string = '';

  constructor(value: string, label: string, bcp47: string) {
    this.value = value;
    this.label = label;
    this.bcp47 = bcp47;
  }
}

export const LANGUAGE_LIST: Array<LanguageOption> = [
  new LanguageOption('', '跟随系统', 'default'),
  new LanguageOption('zh', '中文（简体）', 'zh-Hans'),
  new LanguageOption('zh-TW', '中文（繁體）', 'zh-Hant'),
  new LanguageOption('en', 'English', 'en-US'),
];
