import { getLocalDeviceInfo, getDiscoveredDevices, isServerRunning, startServer, restartServer,
  getDeviceModel, startWebUpload, getShareLink, getEncryptedTransfer, isEnableAnimations,
  getPort, getServerError, getNoWifiWarning, getAllInterfacesDisabled, doesServerNeedRestart, getAutoConfirmMode } from '../service/AppService';
import { LocalDeviceInfo, DiscoveredDevice, FavoriteDevice } from '../model/Types';
import { removeFavorite as removeFavoriteService, getFavorites as getFavoritesService,
  subscribeFavorites, unsubscribeFavorites } from '../service/FavoritesService';

// 接收页签业务状态 + 命令，从 ReceiveContent 抽出。
// 持有服务器状态镜像 + 收藏快照，无需 AppStorage 即可响应式渲染。
@ObservedV2
export class ReceiveViewModel {
  @Trace public localDeviceInfo: LocalDeviceInfo = { alias: '', fingerprint: '', ip: '0.0.0.0', interfaces: [] }
  @Trace public serverOnline: boolean = false
  @Trace public refreshTick: number = 0
  // 服务器状态镜像
  @Trace public autoConfirmMode: string = 'off'
  @Trace public favoriteDevices: Array<FavoriteDevice> = []
  @Trace public encryptedTransfer: boolean = true
  @Trace public enableAnimations: boolean = true
  @Trace public serverPort: number = 53317
  @Trace public serverReady: boolean = false
  @Trace public serverError: string = ''
  @Trace public noWifiWarning: boolean = false
  @Trace public allInterfacesDisabled: boolean = false
  @Trace public serverNeedsRestart: boolean = false
  private favoritesCallback: () => void = () => {}

  load(): void {
    this.localDeviceInfo = getLocalDeviceInfo();
    if (this.localDeviceInfo.alias === '') {
      this.localDeviceInfo.alias = '便捷快传';
    }
    this.serverOnline = isServerRunning();
    this.autoConfirmMode = getAutoConfirmMode() as string;
    this.refreshState();
  }

  refresh(): void {
    this.refreshTick = this.refreshTick + 1;
    this.serverOnline = isServerRunning();
    this.localDeviceInfo = getLocalDeviceInfo();
    this.refreshState();
  }

  // 从 AppService 刷新所有服务器状态镜像（加载/刷新时调用）。
  private refreshState(): void {
    this.serverReady = isServerRunning();
    this.serverNeedsRestart = doesServerNeedRestart();
    this.serverError = getServerError();
    this.noWifiWarning = getNoWifiWarning();
    this.allInterfacesDisabled = getAllInterfacesDisabled();
    this.encryptedTransfer = getEncryptedTransfer();
    this.enableAnimations = isEnableAnimations();
    this.serverPort = getPort();
    this.favoriteDevices = getFavoritesService().slice();
  }

  // 订阅收藏设备变化（从视图的 aboutToAppear 调用）。
  subscribeFavorites(): void {
    this.favoritesCallback = () => {
      this.favoriteDevices = getFavoritesService().slice();
    };
    subscribeFavorites(this.favoritesCallback);
  }

  // 取消订阅收藏设备变化（从视图的 aboutToDisappear 调用）。
  unsubscribeFavorites(): void {
    unsubscribeFavorites(this.favoritesCallback);
  }

  getDeviceModelValue(): string {
    return getDeviceModel();
  }

  getDiscoveredDevicesValue(): Array<DiscoveredDevice> {
    return getDiscoveredDevices();
  }

  filterFavorites(devices: Array<DiscoveredDevice>, favs: Array<FavoriteDevice>): Array<DiscoveredDevice> {
    let result: Array<DiscoveredDevice> = [];
    for (let i = 0; i < devices.length; i++) {
      let device = devices[i];
      for (let j = 0; j < favs.length; j++) {
        if (device.fingerprint === favs[j].fingerprint) {
          result.push(device);
          break;
        }
      }
    }
    return result;
  }

  getFavorites(): Array<FavoriteDevice> {
    return getFavoritesService();
  }

  removeFavorite(fingerprint: string): void {
    removeFavoriteService(fingerprint);
  }

  startServer(): Promise<string | void> {
    return startServer();
  }

  restartServer(): Promise<string | void> {
    return restartServer();
  }

  // 分享链接就绪时返回 true（调用方导航到 ShareLinkPage）。
  async startWebUploadFlow(): Promise<boolean> {
    try {
      await startWebUpload();
      if (getShareLink().length > 0) {
        return true;
      }
    } catch (_e) {
      // Web 上传启动失败
    }
    return false;
  }
}
