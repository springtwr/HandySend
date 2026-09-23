/**
 * WidescreenSideBar.ets — 宽屏侧边栏面板
 *
 * 宽屏（平板横屏 / 折叠屏展开 / PC）主界面常驻侧边栏的内容：顶部为应用图标与应用名，
 * 下方为「发送 / 任务 / 设置」三项一级导航菜单，其中「任务」项在有活跃会话时显示数字角标。
 * 组件自身不设宽度，宽度由父容器（宽屏两段式布局的侧边栏列）决定；不承载业务逻辑。
 */

import {
  HdsSideMenu,
  HdsSideMenuBadgeParam,
  HdsSideMenuMainItem,
  HdsSideMenuMainItemParam
} from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { DesignTokens } from '../common/DesignTokens';

@ComponentV2
export struct WidescreenSideBar {
  // 当前选中导航项索引：由主页面按当前页签下传，选中态始终以主页面为准
  @Require @Param selectedIndex: number
  // 活跃会话数：驱动「任务」项角标，为 0 时不显示角标
  @Param activeTransferCount: number = 0
  // 导航项点击回调：由主页面执行页签切换
  @Event onSelect: (index: number) => void = (_index: number) => {
  }
  // 参与渲染的菜单项集合（角标变化时就地刷新，见 syncTransferBadge）
  @Local private menuItems: Array<HdsSideMenuMainItem> = []
  // 「任务」菜单项引用：角标刷新时定点更新，不重建整个菜单项集合
  private transferItem: HdsSideMenuMainItem | undefined = undefined

  aboutToAppear(): void {
    this.menuItems = this.createMenuItems();
  }

  /** 活跃会话数变化时刷新「任务」项角标（无需切换页面）。 */
  @Monitor('activeTransferCount')
  onActiveTransferCountChanged(): void {
    this.syncTransferBadge();
  }

  /**
   * 构建三项导航菜单项，顺序与内容区页签索引一致（0 发送 / 1 任务 / 2 设置）。
   * 文案复用既有页签资源；图标采用系统符号（可着色修饰符）承载，
   * 菜单组件据此随选中 / 未选中态为图标着色，与文案选中态一致。
   */
  private createMenuItems(): Array<HdsSideMenuMainItem> {
    let transferParam: HdsSideMenuMainItemParam = {
      itemId: 'widescreen_nav_transfer',
      label: $r('app.string.tab_transfer_center'),
      symbol: new SymbolGlyphModifier($r('sys.symbol.arrow_left_arrow_right'))
    };
    // 角标随初始活跃会话数下发；数量为 0 时该组件不显示角标
    let transferBadge: HdsSideMenuBadgeParam = { count: this.activeTransferCount };
    transferParam.badge = transferBadge;
    let transferItem: HdsSideMenuMainItem = new HdsSideMenuMainItem(transferParam);
    this.transferItem = transferItem;
    return [
      new HdsSideMenuMainItem({
        itemId: 'widescreen_nav_send',
        label: $r('app.string.tab_send'),
        symbol: new SymbolGlyphModifier($r('sys.symbol.paperplane_fill'))
      }),
      transferItem,
      new HdsSideMenuMainItem({
        itemId: 'widescreen_nav_settings',
        label: $r('app.string.tab_settings'),
        symbol: new SymbolGlyphModifier($r('sys.symbol.gearshape_fill'))
      })
    ];
  }

  /**
   * 刷新「任务」项角标：沿用菜单项自带的角标更新能力就地更新（不重建集合，避免选中态抖动）。
   * 角标数量口径由菜单组件自带：0 不显示、1 显示圆点、大于 99 显示「99+」。
   */
  private syncTransferBadge(): void {
    if (this.transferItem === undefined) {
      return;
    }
    let badge: HdsSideMenuBadgeParam = { count: this.activeTransferCount };
    this.transferItem.updateBadge(badge);
  }

  /** 顶部区：应用图标 + 应用名（应用名取应用名资源，随系统语言变化）。 */
  @Builder
  headerArea() {
    Row({ space: DesignTokens.space.tiny }) {
      Image($r('app.media.startIcon'))
        .width(DesignTokens.size.iconSm)
        .height(DesignTokens.size.iconSm)
        .borderRadius(DesignTokens.radius.md)
        .objectFit(ImageFit.Contain)

      Text($r('app.string.app_name'))
        .fontSize(DesignTokens.font.titleM)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        // 应用名较长（不同语言）时单行截断，不换行破坏顶部区高度
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(DesignTokens.size.widescreenSideBarHeaderHeight)
    .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      this.headerArea()

      HdsSideMenu({
        items: this.menuItems,
        selectedIndex: this.selectedIndex,
        $selectedIndex: (index: number): void => {
          this.onSelect(index);
        }
      })
        .width('100%')
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
