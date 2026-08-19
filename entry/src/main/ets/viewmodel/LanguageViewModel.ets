import { preferencesRepo } from '../repository/PreferencesRepo';
import { setLocale } from '../service/AppService';

/**
 * LanguageViewModel
 * 语言选择页的视图模型。持有 UI 状态 selectedLocale，暴露加载/选择命令。
 *
 * 反模式合规：
 * - 不依赖 UI 组件（反模式 2 ✓）
 * - 不持有 UIContext / PromptAction（反模式 2 ✓）
 *
 * 说明：selectLocale 调 AppService.setLocale（持久化 + i18n 切换 + notifyChange）。
 * 待 AppService 拆 Repo 后可改调 PreferencesRepo + i18n 工具。
 */
@ObservedV2
export class LanguageViewModel {
  @Trace public selectedLocale: string = '';

  /**
   * 加载当前语言。优先用路由传入的值，否则从持久化读取。
   * 必须在 Page 的 aboutToAppear 中调用（@ObservedV2 构造函数内修改不触发更新）。
   */
  loadLocale(currentFromParams?: string): void {
    if (currentFromParams !== undefined && currentFromParams.length > 0) {
      this.selectedLocale = currentFromParams;
    } else {
      this.selectedLocale = preferencesRepo.getLocale();
    }
  }

  /**
   * 选择语言并应用。先更新 UI 状态，再调 AppService.setLocale 触发持久化 + 系统语言切换。
   */
  selectLocale(value: string): void {
    this.selectedLocale = value;
    setLocale(value);
  }
}
