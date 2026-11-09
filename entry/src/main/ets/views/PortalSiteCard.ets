/**
 * PortalSiteCard.ets — 在线服务站点卡片。
 *
 * 三行信息：站点名称、特性徽标、站点地址；左侧为名称首字色块。
 * 点击用系统浏览器打开站点，长按弹出编辑/删除菜单。
 */

import { DesignTokens } from '../common/DesignTokens';
import {
  PortalSite,
  PORTAL_BADGE_LARGE_FILE,
  PORTAL_BADGE_LOGIN,
  PORTAL_BADGE_NO_LOGIN,
  PORTAL_BADGE_P2P,
  PORTAL_BADGE_TEMPORARY
} from '../model/PortalSite';

/** 徽标文案。 */
function badgeText(key: string): ResourceStr {
  if (key === PORTAL_BADGE_NO_LOGIN) {
    return $r('app.string.portal_badge_no_login');
  }
  if (key === PORTAL_BADGE_LOGIN) {
    return $r('app.string.portal_badge_login');
  }
  if (key === PORTAL_BADGE_P2P) {
    return $r('app.string.portal_badge_p2p');
  }
  if (key === PORTAL_BADGE_LARGE_FILE) {
    return $r('app.string.portal_badge_large_file');
  }
  if (key === PORTAL_BADGE_TEMPORARY) {
    return $r('app.string.portal_badge_temporary');
  }
  return key;
}

/** 徽标颜色：登录要求用绿/橙，点对点用紫，大文件用蓝，临时有效用次要文字色。 */
function badgeColor(key: string): Resource {
  if (key === PORTAL_BADGE_NO_LOGIN) {
    return $r('app.color.success_green');
  }
  if (key === PORTAL_BADGE_LOGIN) {
    return $r('app.color.warning_orange');
  }
  if (key === PORTAL_BADGE_P2P) {
    return $r('app.color.purple_text');
  }
  if (key === PORTAL_BADGE_LARGE_FILE) {
    return $r('app.color.accent_blue');
  }
  return $r('app.color.text_tertiary');
}

/** 名称首字：取第一个字符作为色块文字。 */
function siteInitial(name: string): string {
  return name.length > 0 ? name.substring(0, 1).toUpperCase() : '?';
}

/** 地址展示：去掉协议前缀，缩短占用宽度。 */
function displayUrl(url: string): string {
  if (url.startsWith('https://')) {
    return url.substring(8);
  }
  if (url.startsWith('http://')) {
    return url.substring(7);
  }
  return url;
}

@ComponentV2
export struct PortalSiteCard {
  @Require @Param site: PortalSite;
  @Event onOpen: (site: PortalSite) => void = (_site: PortalSite): void => {
  };
  @Event onEdit: (site: PortalSite) => void = (_site: PortalSite): void => {
  };
  @Event onDelete: (site: PortalSite) => void = (_site: PortalSite): void => {
  };

  /** 长按菜单：编辑与删除。 */
  @Builder
  cardMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.portal_edit') })
        .onClick((): void => {
          this.onEdit(this.site);
        })
      MenuItem({ content: $r('app.string.portal_delete_confirm') })
        .onClick((): void => {
          this.onDelete(this.site);
        })
    }
  }

  /** 本地图标：预设站点随包携带，用户站点回退首字母。 */
  @Builder
  iconImage(icon: Resource) {
    Image(icon)
      .width(DesignTokens.size.iconLg)
      .height(DesignTokens.size.iconLg)
      .borderRadius(DesignTokens.radius.md)
      .objectFit(ImageFit.Contain)
      .backgroundColor($r('app.color.card_background'))
      .border({
        width: DesignTokens.component.borderSlim,
        color: $r('app.color.border_light')
      })
  }

  @Builder
  badges() {
    Row({ space: DesignTokens.space.tiny }) {
      ForEach(this.site.badges, (badge: string) => {
        Row({ space: DesignTokens.space.xxs }) {
          Circle({ width: 4, height: 4 })
            .fill(badgeColor(badge))
          Text(badgeText(badge))
            .fontSize(DesignTokens.font.captionM)
            .fontColor(badgeColor(badge))
        }
      }, (badge: string) => badge)
    }
    .width('100%')
  }

  build() {
    Row({ space: DesignTokens.space.sm }) {
      if (this.site.id === 'airportal') {
        this.iconImage($r('app.media.ic_portal_airportal'))
      } else if (this.site.id === 'upfile') {
        this.iconImage($r('app.media.ic_portal_upfile'))
      } else if (this.site.id === 'sendwang') {
        this.iconImage($r('app.media.ic_portal_sendwang'))
      } else if (this.site.id === 'pairdrop') {
        this.iconImage($r('app.media.ic_portal_pairdrop'))
      } else if (this.site.id === 'webnote') {
        this.iconImage($r('app.media.ic_portal_webnote'))
      } else {
        Stack() {
          Text(siteInitial(this.site.name))
            .fontSize(DesignTokens.font.subtitleL)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.accent_blue'))
        }
        .width(DesignTokens.size.iconLg)
        .height(DesignTokens.size.iconLg)
        .borderRadius(DesignTokens.radius.md)
        .backgroundColor($r('app.color.card_background'))
        .border({
          width: DesignTokens.component.borderSlim,
          color: $r('app.color.border_light')
        })
      }

      Column({ space: DesignTokens.space.xxs }) {
        Text(this.site.name)
          .fontSize(DesignTokens.font.bodyL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        this.badges()

        Text(displayUrl(this.site.url))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .borderRadius(DesignTokens.radius.lg)
    .backgroundColor($r('app.color.card_background'))
    .border({
      width: DesignTokens.component.borderSlim,
      color: $r('app.color.border_light')
    })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.onOpen(this.site);
    })
    .bindContextMenu(this.cardMenu, ResponseType.LongPress)
    .accessibilityGroup(true)
  }
}
