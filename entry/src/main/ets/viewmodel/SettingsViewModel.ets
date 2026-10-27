import {
  setHttpsEnabled,
  refreshDeviceInfo,
  setReceivePin,
  setAutoFinish,
  setSaveToGallery,
  setDestination,
  setCustomAlias,
  getCustomAlias,
  setTheme,
  setLocale,
  setHideTabBarOnScroll,
  isHideTabBarOnScroll,
  setAdvancedSettings,
  setPort,
  setMulticastGroup,
  setDiscoveryTimeout,
  setNetworkWhitelist,
  getNetworkWhitelist,
  setNetworkBlacklist,
  getNetworkBlacklist,
  setCreateChecksums,
  setVerifyChecksums,
  setAutoClearStagedAfterSend,
  setAutoConfirmMode,
  restartServer,
  startServer,
  stopServer,
  getAutoConfirmMode,
  getReceivePin,
  isAutoFinish,
  isSaveToGallery,
  getDestination,
  getTheme,
  getLocale,
  isCreateChecksums,
  isVerifyChecksums,
  isAutoClearStagedAfterSend,
  isAdvancedSettings,
  getPort,
  getMulticastGroup,
  getDiscoveryTimeout,
  getEncryptedTransfer,
  isServerRunning,
  doesServerNeedRestart,
  getNoWifiWarning,
  getAllInterfacesDisabled,
  subscribe,
  unsubscribe,
  getAppContext,
  restartDiscovery,
  getLocalSendEnabled,
  setLocalSendEnabled,
  getMtaEnabled,
  setMtaEnabled,
  getWebSendAllowed,
  setWebSendAllowed,
  applyWebSendAllowed,
  getWebReceiveAllowed,
  setWebReceiveAllowed,
  applyWebReceiveAllowed,
  getWebHttpsEnabled,
  setWebHttpsEnabled,
  getWebPort,
  setWebPort,
  getWebInterfaceNames,
  getWebInterfaceBlacklistNames,
  setWebInterfaces,
  setWebDisplayAddress,
  getWebActualPort,
  isWebPortFallback,
  refreshWebAddress,
  restartWebService,
  getMtaReceiveEnabled,
  setMtaReceiveEnabled,
  applyMtaEnabled,
  applyMtaReceiveEnabled,
  stopMtaReceive,
  getMtaSimulatedBrand,
  setMtaSimulatedBrand,
  applyMtaSimulatedBrand,
  isMtaConnectionWarnings,
  setMtaConnectionWarnings
} from '../service/AppService';
import {
  isNotificationPermissionGranted,
  isBluetoothPermissionGranted,
  requestNotificationPermission,
  requestBluetoothPermission,
  guideToNotificationSettings,
  guideToBluetoothPermissionSetting,
  guideToAppPermissionSettings
} from '../service/PermissionService';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AutoConfirmMode } from '../model/Types';
import { generateAlias, getSystemDeviceName } from '../utils/AliasGenerator';
import { errorText } from '../utils/FormatUtil';
import { getNativeLibraryVersion, getLocalSendProtocolVersion } from '../service/NativeBridge';
import { setDebugEnabled, getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { getLocalInterfaces, updateLocalInterfaces } from '../service/AppService';
import { NetworkInterface } from '../model/Types';
import { WebPortError, validateWebPort } from '../model/WebAddress';
import {
  DEFAULT_ENCRYPTED_TRANSFER,
  DEFAULT_AUTO_CONFIRM_MODE,
  DEFAULT_RECEIVE_PIN,
  DEFAULT_AUTO_FINISH,
  DEFAULT_SAVE_TO_GALLERY,
  DEFAULT_DESTINATION,
  DEFAULT_THEME,
  DEFAULT_LOCALE,
  DEFAULT_HIDE_TAB_BAR_ON_SCROLL,
  DEFAULT_CREATE_CHECKSUMS,
  DEFAULT_VERIFY_CHECKSUMS,
  DEFAULT_ADVANCED_SETTINGS,
  DEFAULT_PORT,
  DEFAULT_MULTICAST_GROUP,
  DEFAULT_DISCOVERY_TIMEOUT,
  DEFAULT_NETWORK_WHITELIST,
  DEFAULT_NETWORK_BLACKLIST,
  DEFAULT_AUTO_CLEAR_STAGED,
  DEFAULT_LOCALSEND_ENABLED,
  DEFAULT_MTA_ENABLED,
  DEFAULT_WEB_SEND_ENABLED,
  DEFAULT_WEB_RECEIVE_ENABLED,
  DEFAULT_WEB_HTTPS_ENABLED,
  DEFAULT_WEB_PORT,
  DEFAULT_MTA_RECEIVE_ENABLED,
  DEFAULT_MTA_SIMULATED_BRAND,
  DEFAULT_MTA_CONNECTION_WARNINGS,
  DEFAULT_CUSTOM_ALIAS
} from '../model/SettingsDefaults';
import {
  buildSessionDetailLines,
  cancelSessions as cancelActiveSessions,
  confirmDisableDirection
} from '../service/transfer/ProtocolDisableGuard';
import { listActiveSessionsByProtocolKeys } from '../service/transfer/TransferSessionRegistry';
import { DialogService } from '../service/DialogService';
import { TransferSession } from '../model/transfer/TransferSession';
import { LOCAL_SEND_KEY } from '../service/transfer/adapters/LocalSendSendAdapter';
import { LOCAL_RECEIVE_KEY } from '../service/transfer/adapters/LocalSendReceiveAdapter';
import { MTA_SEND_KEY } from '../service/transfer/adapters/MtaSendAdapter';
import { MTA_RECEIVE_KEY } from '../service/transfer/adapters/MtaReceiveAdapter';
import { WEB_DOWNLOAD_KEY } from '../service/transfer/adapters/WebDownloadAdapter';
import { WEB_UPLOAD_KEY } from '../service/transfer/adapters/WebUploadAdapter';

// 网络设置相关类型经 ViewModel 出口（View 层不直接 import model/Types）。
export { NetworkInterface, NetworkType } from '../model/Types';

const logger = getLogger(LogDomains.SETTINGS, 'HandySend:SettingsViewModel', '设置页');

// LocalSend 总开关关闭时中断的会话协议键范围：LocalSend 发送/接收
//（网页会话已独立，自带总开关，不再随 LocalSend 开关中断）
const LOCALSEND_SESSION_KEYS: Array<string> = [LOCAL_SEND_KEY, LOCAL_RECEIVE_KEY];

// MTA 总开关关闭时中断的会话协议键范围：MTA 发送/接收
const MTA_SESSION_KEYS: Array<string> = [MTA_SEND_KEY, MTA_RECEIVE_KEY];

// 网页传输总开关关闭时中断的会话协议键范围：网页下载 + 上传
const WEB_SEND_SESSION_KEYS: Array<string> = [WEB_DOWNLOAD_KEY, WEB_UPLOAD_KEY];
// 允许对方上传开关关闭时中断的会话协议键范围：网页上传
const WEB_RECEIVE_SESSION_KEYS: Array<string> = [WEB_UPLOAD_KEY];

// 设置业务命令 + 身份状态，从 SettingsContent 抽出。
// 持有全部设置值 + 服务/持久化副作用。
@ObservedV2
export class SettingsViewModel {
  @Trace public customAlias: string = DEFAULT_CUSTOM_ALIAS
  @Trace public handySendVersion: string = ''
  @Trace public localsendVersion: string = ''
  @Trace public protocolVersion: string = ''
  // 设置状态
  @Trace public encryptedTransfer: boolean = DEFAULT_ENCRYPTED_TRANSFER
  @Trace public autoConfirmMode: string = DEFAULT_AUTO_CONFIRM_MODE as string
  @Trace public receivePin: string = DEFAULT_RECEIVE_PIN
  @Trace public autoFinish: boolean = DEFAULT_AUTO_FINISH
  @Trace public saveToGallery: boolean = DEFAULT_SAVE_TO_GALLERY
  @Trace public localSendEnabled: boolean = DEFAULT_LOCALSEND_ENABLED
  @Trace public mtaEnabled: boolean = DEFAULT_MTA_ENABLED
  @Trace public webSendAllowed: boolean = DEFAULT_WEB_SEND_ENABLED
  @Trace public webReceiveAllowed: boolean = DEFAULT_WEB_RECEIVE_ENABLED
  @Trace public webHttpsEnabled: boolean = DEFAULT_WEB_HTTPS_ENABLED
  @Trace public webPort: number = DEFAULT_WEB_PORT
  @Trace public webInterfaceNames: Array<string> = []
  @Trace public webInterfaceBlacklistNames: Array<string> = []
  @Trace public webActualPort: number = 0
  @Trace public webPortFallback: boolean = false
  @Trace public mtaReceiveEnabled: boolean = DEFAULT_MTA_RECEIVE_ENABLED
  @Trace public mtaSimulatedBrandId: number = DEFAULT_MTA_SIMULATED_BRAND
  @Trace public mtaConnectionWarnings: boolean = DEFAULT_MTA_CONNECTION_WARNINGS
  @Trace public destination: string = DEFAULT_DESTINATION
  @Trace public advancedSettings: boolean = DEFAULT_ADVANCED_SETTINGS
  @Trace public port: number = DEFAULT_PORT
  @Trace public multicastGroup: string = DEFAULT_MULTICAST_GROUP
  @Trace public discoveryTimeout: number = DEFAULT_DISCOVERY_TIMEOUT
  @Trace public networkWhitelist: string = DEFAULT_NETWORK_WHITELIST
  @Trace public networkBlacklist: string = DEFAULT_NETWORK_BLACKLIST
  @Trace public createChecksums: boolean = DEFAULT_CREATE_CHECKSUMS
  @Trace public verifyChecksums: boolean = DEFAULT_VERIFY_CHECKSUMS
  @Trace public autoClearStaged: boolean = DEFAULT_AUTO_CLEAR_STAGED
  @Trace public serverNeedsRestart: boolean = false
  @Trace public hideTabBarOnScroll: boolean = DEFAULT_HIDE_TAB_BAR_ON_SCROLL
  @Trace public theme: string = DEFAULT_THEME
  @Trace public locale: string = DEFAULT_LOCALE
  @Trace public serverReady: boolean = false
  @Trace public noWifiWarning: boolean = false
  @Trace public allInterfacesDisabled: boolean = false
  @Trace public notificationGranted: boolean = false
  @Trace public bluetoothGranted: boolean = false
  @Trace public interfaceListVersion: number = 0 // 接口列表版本号，每次刷新递增，供 UI 监听
  private refreshCallback: () => void = () => {
  }

  loadInitialData(): void {
    this.customAlias = getCustomAlias();

    this.loadSettings();

    // 获取版本信息
    this.localsendVersion = getNativeLibraryVersion();
    this.protocolVersion = 'v' + getLocalSendProtocolVersion();
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
      .then((bundleInfo: bundleManager.BundleInfo) => {
        this.handySendVersion = bundleInfo.versionName;
      })
      .catch((_e: BusinessError) => {
        this.handySendVersion = '';
      });
  }

  // 从 AppService 加载全部设置并订阅服务器状态变化。
  loadSettings(): void {
    this.encryptedTransfer = getEncryptedTransfer();
    this.autoConfirmMode = getAutoConfirmMode() as string;
    this.receivePin = getReceivePin();
    this.autoFinish = isAutoFinish();
    this.saveToGallery = isSaveToGallery();
    this.localSendEnabled = getLocalSendEnabled();
    this.mtaEnabled = getMtaEnabled();
    this.webSendAllowed = getWebSendAllowed();
    this.webReceiveAllowed = getWebReceiveAllowed();
    this.webHttpsEnabled = getWebHttpsEnabled();
    this.webPort = getWebPort();
    this.webInterfaceNames = getWebInterfaceNames();
    this.webInterfaceBlacklistNames = getWebInterfaceBlacklistNames();
    this.webActualPort = getWebActualPort();
    this.webPortFallback = isWebPortFallback();
    this.mtaReceiveEnabled = getMtaReceiveEnabled();
    this.mtaSimulatedBrandId = getMtaSimulatedBrand();
    this.mtaConnectionWarnings = isMtaConnectionWarnings();
    this.destination = getDestination();
    this.theme = getTheme();
    this.locale = getLocale();
    this.hideTabBarOnScroll = isHideTabBarOnScroll();
    this.createChecksums = isCreateChecksums();
    this.verifyChecksums = isVerifyChecksums();
    this.autoClearStaged = isAutoClearStagedAfterSend();
    this.advancedSettings = isAdvancedSettings();
    this.port = getPort();
    this.multicastGroup = getMulticastGroup();
    this.discoveryTimeout = getDiscoveryTimeout();
    this.networkWhitelist = getNetworkWhitelist();
    this.networkBlacklist = getNetworkBlacklist();
    this.serverReady = isServerRunning();
    this.serverNeedsRestart = doesServerNeedRestart();
    this.noWifiWarning = getNoWifiWarning();
    // 权限为系统状态（非持久化设置），随设置加载一并查询刷新
    this.notificationGranted = isNotificationPermissionGranted();
    this.bluetoothGranted = isBluetoothPermissionGranted();
  }

  subscribe(): void {
    this.refreshCallback = () => {
      this.serverReady = isServerRunning();
      this.serverNeedsRestart = doesServerNeedRestart();
      this.noWifiWarning = getNoWifiWarning();
      this.allInterfacesDisabled = getAllInterfacesDisabled();
      // 网页方向开关可由面板内按钮改写（双向同步），此处一并重读，
      // 否则从面板返回设置页时开关状态残留旧值
      this.webSendAllowed = getWebSendAllowed();
      this.webReceiveAllowed = getWebReceiveAllowed();
      this.webHttpsEnabled = getWebHttpsEnabled();
        this.webPort = getWebPort();
      this.webInterfaceNames = getWebInterfaceNames();
      this.webInterfaceBlacklistNames = getWebInterfaceBlacklistNames();
      this.webActualPort = getWebActualPort();
      this.webPortFallback = isWebPortFallback();
      // 权限可能已在系统侧变更（如从设置页返回），一并重新查询
      this.notificationGranted = isNotificationPermissionGranted();
      this.bluetoothGranted = isBluetoothPermissionGranted();
      // 接口列表可能已刷新（网络变化时），通知 UI 重新读取
      this.interfaceListVersion++;
    };
    subscribe(this.refreshCallback);
  }

  unsubscribe(): void {
    unsubscribe(this.refreshCallback);
  }

  setAlias(value: string): void {
    this.customAlias = value;
    setCustomAlias(value);
    refreshDeviceInfo();
  }

  randomizeAlias(): void {
    let newAlias = generateAlias();
    this.setAlias(newAlias);
  }

  useSystemAlias(): void {
    let sysName = getSystemDeviceName();
    this.setAlias(sysName);
  }

  setAutoConfirmMode(mode: string): void {
    this.autoConfirmMode = mode;
    if (mode === 'off') {
      setAutoConfirmMode(AutoConfirmMode.off);
    } else if (mode === 'paired') {
      setAutoConfirmMode(AutoConfirmMode.paired);
    } else {
      setAutoConfirmMode(AutoConfirmMode.on);
    }
  }

  setReceivePinValue(pin: string): void {
    this.receivePin = pin;
    setReceivePin(pin);
  }

  setAutoFinishEnabled(on: boolean): void {
    this.autoFinish = on;
    setAutoFinish(on);
  }

  setGallerySaveEnabled(on: boolean): void {
    this.saveToGallery = on;
    setSaveToGallery(on);
  }

  /** 发送成功后自动清空暂存（默认关闭：暂存保留以支持连续发送） */
  setAutoClearStagedAfterSendEnabled(on: boolean): void {
    this.autoClearStaged = on;
    setAutoClearStagedAfterSend(on);
  }

  // LocalSend 总开关：开启或无活跃传输时立即持久化并启停服务器（含设备发现与网页分享）；
  // 关闭且有活跃传输（含待确认）时先二次确认，确认后写入、生效并逐会话中断
  setLocalSendEnabledValue(on: boolean): void {
    this.setProtocolToggleValue(on, LOCALSEND_SESSION_KEYS, $r('app.string.localsend_enabled_label'),
      (enabled: boolean) => {
        this.localSendEnabled = enabled;
        setLocalSendEnabled(enabled);
      },
      (enabled: boolean) => {
        this.applyLocalSendEnabled(enabled);
      });
  }

  // 按开关状态启停 LocalSend 服务器（开启=重启恢复，关闭=停止）
  private applyLocalSendEnabled(on: boolean): void {
    if (on) {
      startServer().catch((e: Error) => {
        logger.error('LocalSend 开启后启动服务器失败: ' + errorText(e));
      });
    } else {
      stopServer().catch((e: Error) => {
        logger.error('LocalSend 关闭后停止服务器失败: ' + errorText(e));
      });
    }
  }

  // 网页传输总开关：开启即启动服务；关闭时停止服务并撤下分享文件。
  // 关闭且有活跃网页会话时先二次确认，确认后写入、生效并逐会话中断
  setWebSendAllowedValue(on: boolean): void {
    this.setProtocolToggleValue(on, WEB_SEND_SESSION_KEYS, $r('app.string.web_send_label'),
      (enabled: boolean) => {
        this.webSendAllowed = enabled;
        setWebSendAllowed(enabled);
      },
      (enabled: boolean) => {
        applyWebSendAllowed(enabled);
      });
  }

  // 允许对方上传：仅在网页传输总开关开启时生效；关闭时关闭上传入口。
  // 关闭且有活跃上传（含待确认）时先二次确认，确认后写入、生效并逐会话中断
  setWebReceiveAllowedValue(on: boolean): void {
    if (on && !this.webSendAllowed) {
      logger.warn('网页传输总开关未开启，忽略允许上传');
      return;
    }
    this.setProtocolToggleValue(on, WEB_RECEIVE_SESSION_KEYS, $r('app.string.web_receive_label'),
      (enabled: boolean) => {
        this.webReceiveAllowed = enabled;
        setWebReceiveAllowed(enabled);
      },
      (enabled: boolean) => {
        applyWebReceiveAllowed(enabled);
      });
  }

  // ── 网页独立安全项：变更需要重启网页服务；有活跃网页会话时先确认 ──

  /** 网页加密传输开关：持久化后重启网页服务使证书/协议生效。 */
  setWebHttpsEnabledValue(on: boolean): void {
    let old: boolean = this.webHttpsEnabled;
    this.applyWebServiceSetting($r('app.string.web_https_label'), () => {
      this.webHttpsEnabled = on;
      setWebHttpsEnabled(on);
    }, () => {
      this.webHttpsEnabled = old;
    });
  }

  /** 校验网页端口输入（供 UI 区分“越界”和“与 LocalSend 冲突”）。 */
  validateWebPortValue(raw: string): WebPortError {
    return validateWebPort(Number(raw), this.port);
  }

  /** 网页端口：校验通过后持久化并重启网页服务；返回是否已受理。 */
  setWebPortValue(raw: string): boolean {
    let port: number = Number(raw);
    if (validateWebPort(port, this.port) !== WebPortError.none) {
      return false;
    }
    this.applyWebServiceSetting($r('app.string.web_port_label'), () => {
      this.webPort = port;
      setWebPort(port);
    }, () => {
    });
    return true;
  }

  /** 网络接口白/黑名单：只影响地址展示，不重启服务。 */
  setWebInterfacesValue(whitelist: Array<string>, blacklist: Array<string>): void {
    this.webInterfaceNames = whitelist;
    this.webInterfaceBlacklistNames = blacklist;
    setWebInterfaces(whitelist, blacklist);
    refreshWebAddress();
  }

  /**
   * 应用需要重启网页服务的设置变更：
   * 无活跃会话直接应用；有活跃会话先确认，确认后应用并中断会话，取消则回退 UI 值。
   */
  private applyWebServiceSetting(labelRes: Resource, apply: () => void, revert: () => void): void {
    let label: string = this.resolveResourceText(labelRes);
    let vm = this;
    let active: Array<TransferSession> =
      listActiveSessionsByProtocolKeys([WEB_DOWNLOAD_KEY, WEB_UPLOAD_KEY]);
    if (active.length === 0) {
      apply();
      restartWebService().catch((e: Error) => {
        logger.error('网页设置变更后重启服务失败: ' + errorText(e));
      });
      logger.info('网页服务设置已应用: ' + label);
      return;
    }
    DialogService.showWebServiceRestartConfirmDialog(buildSessionDetailLines(active),
      (confirmed: boolean) => {
        if (confirmed) {
          apply();
          vm.cancelSessions(active);
          restartWebService().catch((e: Error) => {
            logger.error('网页设置变更后重启服务失败: ' + errorText(e));
          });
          logger.info('网页服务设置已应用: ' + label + '，中断会话数=' + active.length);
        } else {
          revert();
          logger.info('网页服务设置变更已取消: ' + label);
        }
      });
  }

  // MTA 总开关：开启或无活跃传输时立即持久化并生效（关闭=停接收与发现扫描，开启=按接收子开关恢复接收）；
  // 关闭且有活跃传输（含待确认）时先二次确认，确认后写入、生效并逐会话中断
  setMtaEnabledValue(on: boolean): void {
    this.setProtocolToggleValue(on, MTA_SESSION_KEYS, $r('app.string.mta_enabled_label'),
      (enabled: boolean) => {
        this.mtaEnabled = enabled;
        setMtaEnabled(enabled);
      },
      () => {
        applyMtaEnabled();
      });
  }

  /**
   * 协议总开关统一写入流程：
   * - 开启方向或无活跃传输：立即写入并生效；
   * - 关闭且有活跃传输（含待确认）：弹窗确认——确认后写入、生效并逐会话中断（落取消终态）；
   *   取消则不写入，显式写回原值驱动 Toggle 回弹。
   */
  private setProtocolToggleValue(on: boolean, sessionKeys: Array<string>, labelRes: Resource,
    write: (enabled: boolean) => void, apply: (enabled: boolean) => void): void {
    let label: string = this.resolveResourceText(labelRes);
    if (on) {
      write(true);
      apply(true);
      logger.info('协议开关已开启: ' + label);
      return;
    }
    let vm = this;
    confirmDisableDirection(label, sessionKeys,
      (active: Array<TransferSession>) => {
        write(false);
        apply(false);
        vm.cancelSessions(active);
        if (active.length === 0) {
          logger.info('协议开关已关闭（无活跃传输）: ' + label);
        } else {
          logger.info('协议开关已关闭（用户确认）: ' + label + '，中断会话数=' + active.length);
        }
      },
      () => {
        // 取消：开关保持原值（true），写回以驱动绑定 Toggle 回弹
        write(true);
        logger.info('协议开关关闭已取消: ' + label);
      });
  }

  // 解析资源为当前语言文本（解析失败回退空串）
  private resolveResourceText(res: Resource): string {
    let ctx = getAppContext();
    if (ctx === undefined) {
      return '';
    }
    try {
      return ctx.resourceManager.getStringSync(res.id);
    } catch (e) {
      logger.warn('解析资源文本失败: ' + errorText(e));
      return '';
    }
  }

  // 逐会话中断（落取消终态；声明不可取消的会话由 cancel 内部跳过，交由协议侧事件终结）
  private cancelSessions(sessions: Array<TransferSession>): void {
    cancelActiveSessions(sessions);
  }

  // 允许接收开关：持久化后立即按开关启停 MTA 接收服务
  setMtaReceiveEnabledValue(on: boolean): void {
    this.mtaReceiveEnabled = on;
    setMtaReceiveEnabled(on);
    if (on) {
      applyMtaReceiveEnabled();
    } else {
      stopMtaReceive();
    }
  }

  // 模拟品牌：持久化后刷新接收广播身份（接收未运行时为空操作）
  setMtaSimulatedBrandValue(id: number): void {
    this.mtaSimulatedBrandId = id;
    setMtaSimulatedBrand(id);
    applyMtaSimulatedBrand();
  }

  // 显示互传提醒开关：持久化后经 notifyChange 通知发送页重算警告横幅
  setMtaConnectionWarningsValue(on: boolean): void {
    this.mtaConnectionWarnings = on;
    setMtaConnectionWarnings(on);
  }

  setThemeMode(theme: string): void {
    this.theme = theme;
    setTheme(theme);
  }

  setHideTabBarOnScrollEnabled(on: boolean): void {
    this.hideTabBarOnScroll = on;
    setHideTabBarOnScroll(on);
  }

  // 设置语言（语言弹窗使用）：更新 UI 状态并调用 AppService.setLocale 完成持久化与切换
  setLocaleValue(value: string): void {
    this.locale = value;
    setLocale(value);
  }

  setEncryptionEnabled(on: boolean): void {
    this.encryptedTransfer = on;
    setHttpsEnabled(on);
  }

  /**
   * 点击「通知权限」项：未开启时先申请（首次弹窗），仍被拒则引导到系统通知设置；
   * 已开启时同样拉起系统通知设置，便于用户撤销授权。
   * 权限为系统状态，操作后重新查询并刷新展示。
   */
  async applyNotificationPermission(): Promise<void> {
    try {
      let ctx = getAppContext();
      if (ctx === undefined) {
        return;
      }
      if (this.notificationGranted) {
        await guideToNotificationSettings(ctx);
        this.notificationGranted = isNotificationPermissionGranted();
        return;
      }
      let granted: boolean = await requestNotificationPermission(ctx);
      if (!granted) {
        // 半模态设置弹窗在用户操作完成后才返回，返回后重新查询即为最新状态
        await guideToNotificationSettings(ctx);
        granted = isNotificationPermissionGranted();
      }
      this.notificationGranted = granted;
    } catch (e) {
      logger.warn('通知权限申请流程异常: ' + errorText(e));
    }
  }

  /**
   * 点击「设备发现和连接」项（蓝牙权限）：未授予时先申请（首次弹窗），仍被拒则引导到系统权限设置；
   * 已授予时打开本应用在系统设置中的详情页，供用户关闭权限（返回后由前台刷新回查状态）。
   */
  async applyBluetoothPermission(): Promise<void> {
    try {
      let ctx = getAppContext();
      if (ctx === undefined) {
        return;
      }
      if (this.bluetoothGranted) {
        await guideToAppPermissionSettings(ctx);
        return;
      }
      let granted: boolean = await requestBluetoothPermission(ctx);
      if (!granted) {
        await guideToBluetoothPermissionSetting(ctx);
        granted = isBluetoothPermissionGranted();
      }
      this.bluetoothGranted = granted;
    } catch (e) {
      logger.warn('蓝牙权限申请流程异常: ' + errorText(e));
    }
  }

  // 解析并校验对话框原始输入；应用成功时返回 true。
  setPortValue(value: string): boolean {
    let p = parseInt(value);
    if (isNaN(p) || p <= 0 || p > 65535) {
      return false;
    }
    this.port = p;
    setPort(p);
    return true;
  }

  setMulticastGroupValue(v: string): void {
    this.multicastGroup = v;
    setMulticastGroup(v);
  }

  // 解析并校验对话框原始输入；应用成功时返回 true。
  setDiscoveryTimeoutValue(value: string): boolean {
    let t = parseInt(value);
    if (isNaN(t) || t <= 0) {
      return false;
    }
    this.discoveryTimeout = t;
    setDiscoveryTimeout(t);
    return true;
  }

  // 保存网络白/黑名单并立即重启 discovery（不需要重启服务器）
  saveNetworkListsAndApply(whitelist: string, blacklist: string): void {
    logger.debug('白名单: \'' + whitelist + '\' 黑名单: \'' + blacklist + '\'');
    this.networkWhitelist = whitelist;
    this.networkBlacklist = blacklist;
    setNetworkWhitelist(whitelist);
    setNetworkBlacklist(blacklist);
    restartDiscovery();
  }

  // 获取本机网络接口列表，委托调用 AppCore
  getLocalInterfacesList(): Array<NetworkInterface> {
    return getLocalInterfaces();
  }

  // 刷新本机网络接口列表（重新枚举所有接口）
  refreshLocalInterfaces(): void {
    updateLocalInterfaces();
  }

  setChecksumsEnabled(on: boolean): void {
    this.createChecksums = on;
    this.verifyChecksums = on;
    setCreateChecksums(on);
    setVerifyChecksums(on);
  }

  restartServer(): Promise<string | void> {
    return restartServer();
  }

  startServer(): Promise<string | void> {
    return startServer();
  }

  stopServer(): Promise<string | void> {
    return stopServer();
  }

  restoreDefaults(): void {
    // 将所有设置重置为默认值（全部引用 SettingsDefaults 常量）
    // 设备身份——空字符串时根据系统信息自动检测
    this.customAlias = DEFAULT_CUSTOM_ALIAS;
    setCustomAlias(DEFAULT_CUSTOM_ALIAS);

    // 接收设置
    this.autoConfirmMode = DEFAULT_AUTO_CONFIRM_MODE as string;
    setAutoConfirmMode(DEFAULT_AUTO_CONFIRM_MODE);
    this.receivePin = DEFAULT_RECEIVE_PIN;
    setReceivePin(DEFAULT_RECEIVE_PIN);
    this.autoFinish = DEFAULT_AUTO_FINISH;
    setAutoFinish(DEFAULT_AUTO_FINISH);
    this.saveToGallery = DEFAULT_SAVE_TO_GALLERY;
    setSaveToGallery(DEFAULT_SAVE_TO_GALLERY);
    this.destination = DEFAULT_DESTINATION;
    setDestination(DEFAULT_DESTINATION);

    // 主题与外观
    this.theme = DEFAULT_THEME;
    setTheme(DEFAULT_THEME);
    this.hideTabBarOnScroll = DEFAULT_HIDE_TAB_BAR_ON_SCROLL;
    setHideTabBarOnScroll(DEFAULT_HIDE_TAB_BAR_ON_SCROLL);
    // LocalSend 总开关复位：值变化时才启停服务器，避免无谓重启
    let localSendWasEnabled: boolean = this.localSendEnabled;
    this.localSendEnabled = DEFAULT_LOCALSEND_ENABLED;
    setLocalSendEnabled(DEFAULT_LOCALSEND_ENABLED);
    if (localSendWasEnabled !== DEFAULT_LOCALSEND_ENABLED) {
      this.applyLocalSendEnabled(DEFAULT_LOCALSEND_ENABLED);
    }
    // MTA 总开关复位：值变化时才启停接收与扫描，避免无谓重启
    let mtaWasEnabled: boolean = this.mtaEnabled;
    this.mtaEnabled = DEFAULT_MTA_ENABLED;
    setMtaEnabled(DEFAULT_MTA_ENABLED);
    if (mtaWasEnabled !== DEFAULT_MTA_ENABLED) {
      applyMtaEnabled();
    }
    this.mtaReceiveEnabled = DEFAULT_MTA_RECEIVE_ENABLED;
    setMtaReceiveEnabled(DEFAULT_MTA_RECEIVE_ENABLED);
    applyMtaReceiveEnabled();
    this.mtaSimulatedBrandId = DEFAULT_MTA_SIMULATED_BRAND;
    setMtaSimulatedBrand(DEFAULT_MTA_SIMULATED_BRAND);
    applyMtaSimulatedBrand();
    this.mtaConnectionWarnings = DEFAULT_MTA_CONNECTION_WARNINGS;
    setMtaConnectionWarnings(DEFAULT_MTA_CONNECTION_WARNINGS);
    // 网页方向允许开关复位：值变化时才启停服务，避免无谓操作
    let webSendWasAllowed: boolean = this.webSendAllowed;
    this.webSendAllowed = DEFAULT_WEB_SEND_ENABLED;
    setWebSendAllowed(DEFAULT_WEB_SEND_ENABLED);
    if (webSendWasAllowed !== DEFAULT_WEB_SEND_ENABLED) {
      applyWebSendAllowed(DEFAULT_WEB_SEND_ENABLED);
    }
    let webReceiveWasAllowed: boolean = this.webReceiveAllowed;
    this.webReceiveAllowed = DEFAULT_WEB_RECEIVE_ENABLED;
    setWebReceiveAllowed(DEFAULT_WEB_RECEIVE_ENABLED);
    if (webReceiveWasAllowed !== DEFAULT_WEB_RECEIVE_ENABLED) {
      applyWebReceiveAllowed(DEFAULT_WEB_RECEIVE_ENABLED);
    }
    // 网页独立安全项复位（服务已在上方按开关关闭，无需再重启）
    this.webHttpsEnabled = DEFAULT_WEB_HTTPS_ENABLED;
    setWebHttpsEnabled(DEFAULT_WEB_HTTPS_ENABLED);
    this.webPort = DEFAULT_WEB_PORT;
    setWebPort(DEFAULT_WEB_PORT);
    this.webInterfaceNames = [];
    this.webInterfaceBlacklistNames = [];
    setWebInterfaces([], []);
    setWebDisplayAddress('');
    this.webActualPort = 0;
    this.webPortFallback = false;

    // 语言——重置为跟随系统（使用 setLocale 走完整流程）
    this.locale = DEFAULT_LOCALE;
    setLocale(DEFAULT_LOCALE);

    // 发送设置
    this.autoClearStaged = DEFAULT_AUTO_CLEAR_STAGED;
    setAutoClearStagedAfterSend(DEFAULT_AUTO_CLEAR_STAGED);

    // 安全
    this.encryptedTransfer = DEFAULT_ENCRYPTED_TRANSFER;
    setHttpsEnabled(DEFAULT_ENCRYPTED_TRANSFER);

    // 高级设置
    this.advancedSettings = DEFAULT_ADVANCED_SETTINGS;
    setAdvancedSettings(DEFAULT_ADVANCED_SETTINGS);
    this.port = DEFAULT_PORT;
    setPort(DEFAULT_PORT);
    this.multicastGroup = DEFAULT_MULTICAST_GROUP;
    setMulticastGroup(DEFAULT_MULTICAST_GROUP);
    this.discoveryTimeout = DEFAULT_DISCOVERY_TIMEOUT;
    setDiscoveryTimeout(DEFAULT_DISCOVERY_TIMEOUT);
    this.networkWhitelist = DEFAULT_NETWORK_WHITELIST;
    setNetworkWhitelist(DEFAULT_NETWORK_WHITELIST);
    this.networkBlacklist = DEFAULT_NETWORK_BLACKLIST;
    setNetworkBlacklist(DEFAULT_NETWORK_BLACKLIST);
    this.createChecksums = DEFAULT_CREATE_CHECKSUMS;
    this.verifyChecksums = DEFAULT_VERIFY_CHECKSUMS;
    setCreateChecksums(DEFAULT_CREATE_CHECKSUMS);
    setVerifyChecksums(DEFAULT_VERIFY_CHECKSUMS);

    // 调试日志（非常驻设置项，不经 SettingsDefaults）：恢复默认时一并复位该内存态
    setDebugEnabled(false);

    // 刷新设备信息（服务器重启横幅会自动显示）
    refreshDeviceInfo();

    // 仅当服务器确实以默认设置运行时才清除重启横幅。
    // 不要盲目清除——setHttpsEnabled(true) 等操作可能已设置重启标志
    // 如果服务器曾以非默认值运行（例如 HTTPS=false）。
    // 服务器以新设置重启后，重启横幅会自动消失。
  }
}
