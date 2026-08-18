import { getLocalDeviceInfo, getDiscoveredDevices, isServerRunning, startServer, restartServer,
  getDeviceModel, startWebUpload, getShareLink, getEncryptedTransfer, isEnableAnimations,
  getPort, getServerError, getNoWifiWarning, doesServerNeedRestart, getAutoSaveMode } from '../service/AppService';
import { LocalDeviceInfo, DiscoveredDevice, FavoriteDevice } from '../model/Types';
import { removeFavorite as removeFavoriteService, getFavorites as getFavoritesService,
  subscribeFavorites, unsubscribeFavorites } from '../service/FavoritesService';

// Receive-tab business state + commands, extracted from ReceiveContent.
// Owns server-state mirrors (previously @StorageLink) + favorites snapshot for
// reactive rendering without AppStorage.
@Observed
export class ReceiveViewModel {
  public localDeviceInfo: LocalDeviceInfo = { alias: '', fingerprint: '', ip: '0.0.0.0', interfaces: [] }
  public serverOnline: boolean = false
  public refreshTick: number = 0
  // Server-state mirrors (previously @StorageLink in the view)
  public autoSaveMode: string = 'paired'
  public favoriteDevices: Array<FavoriteDevice> = []
  public encryptedTransfer: boolean = true
  public enableAnimations: boolean = true
  public serverPort: number = 53317
  public serverReady: boolean = false
  public serverError: string = ''
  public noWifiWarning: boolean = false
  public serverNeedsRestart: boolean = false
  private favoritesCallback: () => void = () => {}

  load(): void {
    this.localDeviceInfo = getLocalDeviceInfo();
    if (this.localDeviceInfo.alias === '') {
      this.localDeviceInfo.alias = '便捷快传';
    }
    this.serverOnline = isServerRunning();
    this.autoSaveMode = getAutoSaveMode() as string;
    this.refreshState();
  }

  refresh(): void {
    this.refreshTick = this.refreshTick + 1;
    this.serverOnline = isServerRunning();
    this.localDeviceInfo = getLocalDeviceInfo();
    this.refreshState();
  }

  // Refreshes all server-state mirrors from AppService (called on load/refresh).
  private refreshState(): void {
    this.serverReady = isServerRunning();
    this.serverNeedsRestart = doesServerNeedRestart();
    this.serverError = getServerError();
    this.noWifiWarning = getNoWifiWarning();
    this.encryptedTransfer = getEncryptedTransfer();
    this.enableAnimations = isEnableAnimations();
    this.serverPort = getPort();
    this.favoriteDevices = getFavoritesService().slice();
  }

  // Subscribes to favorite-device changes (called from the view's aboutToAppear).
  subscribeFavorites(): void {
    this.favoritesCallback = () => {
      this.favoriteDevices = getFavoritesService().slice();
    };
    subscribeFavorites(this.favoritesCallback);
  }

  // Unsubscribes favorite-device changes (called from the view's aboutToDisappear).
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

  // Returns true when a share link is ready (caller navigates to ShareLinkPage).
  async startWebUploadFlow(): Promise<boolean> {
    try {
      await startWebUpload();
      if (getShareLink().length > 0) {
        return true;
      }
    } catch (_e) {
      // Web upload start failed
    }
    return false;
  }
}
