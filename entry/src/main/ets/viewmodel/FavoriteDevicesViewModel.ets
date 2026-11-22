/**
 * FavoriteDevicesViewModel.ets — 收藏设备面板状态与编排
 *
 * 承载面板的条目集合、在线判定、多选模式与重命名/删除命令；同文件内提供条目展示层 ViewModel。
 * 在线判定以发送页发现快照（SendViewModel.discoveredDevices）为唯一事实源，保证与附近列表口径一致。
 */

import { FavoriteDevice, DiscoveredDevice } from '../model/Types';
import { favoriteKeyOf, isMtaFavorite } from '../model/DeviceIdentity';
import { mtaBrandBadgeText } from '../model/mta/MtaMainModels';
import { resolveMtaPhoneBrandIcon } from '../model/mta/MtaBrandRegistry';
import {
  getFavorites,
  removeFavorites,
  renameFavorite as renameFavoriteService,
  restoreDefaultAlias as restoreDefaultAliasService,
  canRestoreDefaultAlias as canRestoreDefaultAliasService,
  subscribeFavorites as subscribeFavoritesBus,
  unsubscribeFavorites as unsubscribeFavoritesBus
} from '../service/repository/FavoritesService';
import { SendViewModel } from './SendViewModel';

/**
 * 在线收藏键集合（纯函数）：从发现快照按收藏键口径产出（MTA 为 `mta:<senderId>`，
 * LocalSend 为设备指纹），供面板在线判定与单测复用。
 */
export function collectOnlineFavoriteKeys(devices: Array<DiscoveredDevice>): Set<string> {
  let result: Set<string> = new Set<string>();
  for (let i = 0; i < devices.length; i++) {
    result.add(favoriteKeyOf(devices[i]));
  }
  return result;
}

/** 统计已勾选条目数（纯函数）。 */
export function countSelected(items: Array<FavoriteDeviceItemViewModel>): number {
  let count: number = 0;
  for (let i = 0; i < items.length; i++) {
    if (items[i].selected) {
      count++;
    }
  }
  return count;
}

/** 面板条目展示层 ViewModel（@ObservedV2 精准观测）。 */
@ObservedV2
export class FavoriteDeviceItemViewModel {
  // 底层收藏记录（发送与管理事件使用）
  item: FavoriteDevice
  @Trace public alias: string = ''
  @Trace public deviceType: string = ''
  @Trace public deviceModel: string = ''
  @Trace public isOnline: boolean = false
  @Trace public selected: boolean = false
  // MTA 收藏的展示字段（品牌徽标/图标）
  @Trace public isMta: boolean = false
  @Trace public mtaBrandName: string = ''
  @Trace public mtaBrandId: number = -1

  constructor(favorite: FavoriteDevice) {
    this.item = favorite;
    this.alias = favorite.alias;
    this.deviceType = favorite.deviceType ?? '';
    this.deviceModel = favorite.deviceModel ?? '';
    this.isMta = isMtaFavorite(favorite);
    this.mtaBrandName = favorite.mtaBrandName ?? '';
    this.mtaBrandId = favorite.mtaBrandId ?? -1;
  }

  get fingerprint(): string {
    return this.item.fingerprint;
  }

  /** MTA 品牌徽标文案（品牌未知时回退固定文案；非 MTA 收藏不使用） */
  get mtaBrandBadge(): string {
    return mtaBrandBadgeText(this.mtaBrandName);
  }

  /** MTA 对端品牌图标（非 MTA 收藏不使用） */
  get mtaBrandIcon(): Resource {
    return resolveMtaPhoneBrandIcon(this.mtaBrandId);
  }

  /** 用最新收藏记录刷新展示字段（重命名 / 在线同步后），保留勾选状态。 */
  syncFromFavorite(favorite: FavoriteDevice): void {
    this.item = favorite;
    this.alias = favorite.alias;
    this.deviceType = favorite.deviceType ?? '';
    this.deviceModel = favorite.deviceModel ?? '';
    this.isMta = isMtaFavorite(favorite);
    this.mtaBrandName = favorite.mtaBrandName ?? '';
    this.mtaBrandId = favorite.mtaBrandId ?? -1;
  }
}

/** 收藏设备面板状态与命令（@ObservedV2）。 */
@ObservedV2
export class FavoriteDevicesViewModel {
  @Trace public items: Array<FavoriteDeviceItemViewModel> = []
  @Trace public selectionMode: boolean = false
  // 正在定向探测的指纹（空串表示无；用于行级进行中反馈）
  @Trace public probingFingerprint: string = ''
  private sendViewModel: SendViewModel | undefined = undefined
  private favoritesCallback: () => void = () => {
  }

  /** 绑定发送页 ViewModel（在线快照来源）。 */
  attach(sendViewModel: SendViewModel): void {
    this.sendViewModel = sendViewModel;
  }

  /** 订阅收藏变更总线。 */
  subscribeFavorites(): void {
    this.favoritesCallback = () => {
      this.refresh();
    };
    subscribeFavoritesBus(this.favoritesCallback);
  }

  /** 取消订阅收藏变更总线。 */
  unsubscribeFavorites(): void {
    unsubscribeFavoritesBus(this.favoritesCallback);
  }

  /** 是否有收藏（空态判定）。 */
  get hasFavorites(): boolean {
    return this.items.length > 0;
  }

  /** 已勾选数量。 */
  get selectedCount(): number {
    return countSelected(this.items);
  }

  /** 是否全选（空列表不为全选）。 */
  get allSelected(): boolean {
    return this.items.length > 0 && this.selectedCount === this.items.length;
  }

  /** 全量刷新：按最新收藏记录重建条目，保留既有条目的勾选与在线状态。 */
  refresh(): void {
    let localOnline: Set<string> = this.currentLocalOnlineKeys();
    let mtaOnline: Set<string> = this.currentMtaOnlineKeys();
    let favorites: Array<FavoriteDevice> = getFavorites();
    let rebuilt: Array<FavoriteDeviceItemViewModel> = [];
    for (let i = 0; i < favorites.length; i++) {
      let favorite: FavoriteDevice = favorites[i];
      if (!this.isFavoriteVisible(favorite)) {
        continue;
      }
      let online: boolean = localOnline.has(favorite.fingerprint) || mtaOnline.has(favorite.fingerprint);
      let existing: FavoriteDeviceItemViewModel | undefined = this.findItem(favorite.fingerprint);
      if (existing !== undefined) {
        existing.syncFromFavorite(favorite);
        existing.isOnline = online;
        rebuilt.push(existing);
      } else {
        let item: FavoriteDeviceItemViewModel = new FavoriteDeviceItemViewModel(favorite);
        item.isOnline = online;
        rebuilt.push(item);
      }
    }
    this.items = rebuilt;
    // 收藏被清空后退出多选模式，避免遗留空白选择态
    if (this.items.length === 0) {
      this.selectionMode = false;
    }
  }

  /** 收藏是否应按当前协议总开关展示（MTA 收藏跟随 MTA 开关，其余跟随 LocalSend） */
  private isFavoriteVisible(favorite: FavoriteDevice): boolean {
    if (this.sendViewModel === undefined) {
      return true;
    }
    return isMtaFavorite(favorite) ? this.sendViewModel.mtaEnabled : this.sendViewModel.localSendEnabled;
  }

  /** 发现刷新时仅更新在线状态（不重建条目，保留勾选与滚动状态）。 */
  refreshOnlineStatus(): void {
    if (this.sendViewModel === undefined) {
      return;
    }
    let localOnline: Set<string> = collectOnlineFavoriteKeys(this.sendViewModel.discoveredDevices);
    let mtaOnline: Set<string> = collectOnlineFavoriteKeys(this.sendViewModel.mtaDiscoveredDevices);
    for (let i = 0; i < this.items.length; i++) {
      let key: string = this.items[i].fingerprint;
      this.items[i].isOnline = localOnline.has(key) || mtaOnline.has(key);
    }
  }

  private currentLocalOnlineKeys(): Set<string> {
    if (this.sendViewModel === undefined) {
      return new Set<string>();
    }
    return collectOnlineFavoriteKeys(this.sendViewModel.discoveredDevices);
  }

  private currentMtaOnlineKeys(): Set<string> {
    if (this.sendViewModel === undefined) {
      return new Set<string>();
    }
    return collectOnlineFavoriteKeys(this.sendViewModel.mtaDiscoveredDevices);
  }

  private findItem(fingerprint: string): FavoriteDeviceItemViewModel | undefined {
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].fingerprint === fingerprint) {
        return this.items[i];
      }
    }
    return undefined;
  }

  // ── 多选命令 ──

  /** 进入多选模式并选中触发长按的条目。 */
  enterSelection(fingerprint: string): void {
    this.selectionMode = true;
    this.setSelected(fingerprint, true);
  }

  /** 退出多选模式并清空全部勾选。 */
  exitSelection(): void {
    this.selectionMode = false;
    for (let i = 0; i < this.items.length; i++) {
      this.items[i].selected = false;
    }
  }

  /** 切换单条勾选状态。 */
  toggleSelect(fingerprint: string): void {
    let item: FavoriteDeviceItemViewModel | undefined = this.findItem(fingerprint);
    if (item !== undefined) {
      item.selected = !item.selected;
    }
  }

  /** 全选 / 取消全选切换。 */
  toggleSelectAll(): void {
    let target: boolean = !this.allSelected;
    for (let i = 0; i < this.items.length; i++) {
      this.items[i].selected = target;
    }
  }

  private setSelected(fingerprint: string, value: boolean): void {
    let item: FavoriteDeviceItemViewModel | undefined = this.findItem(fingerprint);
    if (item !== undefined) {
      item.selected = value;
    }
  }

  // ── 删除命令 ──

  /** 删除已勾选的收藏（批量），完成后退出多选模式。 */
  removeSelected(): void {
    let fingerprints: Array<string> = [];
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].selected) {
        fingerprints.push(this.items[i].fingerprint);
      }
    }
    if (fingerprints.length === 0) {
      return;
    }
    removeFavorites(fingerprints);
    this.exitSelection();
  }

  /** 删除单台收藏（经条目「更多」菜单触发）。 */
  removeOne(fingerprint: string): void {
    removeFavorites([fingerprint]);
  }

  // ── 设备详情 ──

  /**
   * 构建设备详情页路由参数：供详情页只读展示，可选字段缺省补空串，
   * 因此离线收藏同样可查看已保存信息。
   */
  buildDetailsParams(favorite: FavoriteDevice): Record<string, string | number> {
    let isMta: boolean = isMtaFavorite(favorite);
    return {
      'alias': favorite.alias,
      'ip': favorite.ip,
      'port': favorite.port,
      'fingerprint': favorite.fingerprint,
      'version': favorite.version ?? '',
      'deviceModel': favorite.deviceModel ?? '',
      'deviceType': favorite.deviceType ?? '',
      // LocalSend 传输协议（http/https）；MTA 收藏不使用
      'protocol': favorite.lastProtocol ?? '',
      // 设备来源：详情页按来源切换展示字段与可用操作
      'source': isMta ? 'mta' : 'localsend',
      'mtaSenderIdHex': favorite.mtaSenderIdHex ?? '',
      'mtaBleAddress': favorite.mtaBleAddress ?? '',
      'mtaBrandId': favorite.mtaBrandId ?? -1,
      'mtaBrandName': favorite.mtaBrandName ?? ''
    };
  }

  // ── 重命名命令 ──

  /** 重命名收藏设备别名（空白别名由服务层拒绝）。 */
  renameFavorite(fingerprint: string, alias: string): void {
    renameFavoriteService(fingerprint, alias);
  }

  /** 恢复默认别名（广播名不可得时服务层不处理）。 */
  restoreDefaultAlias(fingerprint: string): void {
    restoreDefaultAliasService(fingerprint);
  }

  /** 是否可恢复默认别名（供菜单项置灰）。 */
  canRestoreDefaultAlias(fingerprint: string): boolean {
    return canRestoreDefaultAliasService(fingerprint);
  }

  // ── 探测进行中反馈 ──

  setProbing(fingerprint: string): void {
    this.probingFingerprint = fingerprint;
  }

  clearProbing(): void {
    this.probingFingerprint = '';
  }
}
