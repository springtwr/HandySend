/**
 * PortalViewModel.ets — 在线服务入口页视图模型。
 *
 * 只承载站点列表、添加/编辑/删除命令与恢复默认状态；
 * 站点数据全部本地化，由 PortalSiteRepository 负责。
 */

import {
  PortalSite,
  PORTAL_BADGE_LARGE_FILE,
  PORTAL_BADGE_LOGIN,
  PORTAL_BADGE_NO_LOGIN,
  PORTAL_BADGE_P2P,
  PORTAL_BADGE_TEMPORARY
} from '../model/PortalSite';
import {
  addPortalSite,
  getPortalSites,
  removePortalSite,
  restoreDefaultPortalSites,
  subscribePortalSites,
  unsubscribePortalSites,
  updatePortalSite
} from '../service/repository/PortalSiteRepository';

@ObservedV2
export class PortalViewModel {
  @Trace public sites: Array<PortalSite> = [];

  private refreshHandler: () => void = (): void => {
    this.reload();
  };

  load(): void {
    this.reload();
    subscribePortalSites(this.refreshHandler);
  }

  unload(): void {
    unsubscribePortalSites(this.refreshHandler);
  }

  private reload(): void {
    this.sites = getPortalSites();
  }

  /** 由表单开关生成徽标序列。 */
  private badgesOf(needLogin: boolean, largeFile: boolean, p2p: boolean,
    temporary: boolean): Array<string> {
    let badges: Array<string> = [needLogin ? PORTAL_BADGE_LOGIN : PORTAL_BADGE_NO_LOGIN];
    if (p2p) {
      badges.push(PORTAL_BADGE_P2P);
    }
    if (largeFile) {
      badges.push(PORTAL_BADGE_LARGE_FILE);
    }
    if (temporary) {
      badges.push(PORTAL_BADGE_TEMPORARY);
    }
    return badges;
  }

  /** 添加站点；返回空串表示成功，否则为错误标识。 */
  add(name: string, url: string, needLogin: boolean, largeFile: boolean,
    p2p: boolean, temporary: boolean): string {
    return addPortalSite(name, url, this.badgesOf(needLogin, largeFile, p2p, temporary));
  }

  /** 编辑站点；返回空串表示成功，否则为错误标识。 */
  update(id: string, name: string, url: string, needLogin: boolean, largeFile: boolean,
    p2p: boolean, temporary: boolean): string {
    return updatePortalSite(id, name, url, this.badgesOf(needLogin, largeFile, p2p, temporary));
  }

  remove(id: string): void {
    removePortalSite(id);
  }

  /** 恢复内置默认；返回 false 表示内置配置不可用。 */
  restoreDefaults(): boolean {
    let ok: boolean = restoreDefaultPortalSites();
    this.reload();
    return ok;
  }
}
