/**
 * PermissionService.ets — 运行时权限查询、申请与设置页引导
 *
 * 集中通知权限（Notification Kit）与蓝牙权限（user_grant）的：
 * - 授权状态查询（供设置页展示，便于发现「因缺权限导致功能异常」）；
 * - 首次申请（系统弹窗仅首次出现，用户拒绝后再次调用不再弹窗）；
 * - 被拒后的设置页/半模态弹窗引导。
 *
 * 所有申请经模块内串行链排队：同一时刻只发起一个系统弹窗，
 * 避免启动阶段多个权限申请同时弹出互相冲突。
 *
 * 隐私声明守卫：应用接入应用市场隐私托管服务后，首次启动由系统弹出标准化
 * 隐私弹窗，其优先级高于权限申请弹窗，未签署时系统会直接丢弃权限申请
 * （不弹窗也不再补弹）。故权限申请前须经 isPrivacyAgreed 判断。
 */

import { notificationManager } from '@kit.NotificationKit';
import { privacyManager } from '@kit.AppGalleryKit';
import { abilityAccessCtrl, bundleManager, common, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { errorText } from '../utils/FormatUtil';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:PermissionService', '权限');

const BLUETOOTH_PERMISSION: Permissions = 'ohos.permission.ACCESS_BLUETOOTH';

// 权限申请串行链：后发申请排队等待前一个结束，避免系统弹窗互相冲突
let requestChain: Promise<void> = Promise.resolve();

function enqueue(task: () => Promise<void>): Promise<void> {
  let next: Promise<void> = requestChain.then(task);
  requestChain = next.catch((): void => {
  });
  return next;
}

/** 当前应用 accessTokenId（查询本应用权限状态用） */
function selfTokenId(): number {
  return bundleManager.getBundleInfoForSelfSync(
    bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION).appInfo.accessTokenId;
}

/** 通知权限是否已开启 */
export function isNotificationPermissionGranted(): boolean {
  try {
    return notificationManager.isNotificationEnabledSync();
  } catch (e) {
    logger.warn('查询通知授权状态失败: ' + errorText(e));
    return false;
  }
}

/** 蓝牙权限是否已授予 */
export function isBluetoothPermissionGranted(): boolean {
  try {
    let atManager = abilityAccessCtrl.createAtManager();
    let status: abilityAccessCtrl.GrantStatus = atManager.checkAccessTokenSync(selfTokenId(), BLUETOOTH_PERMISSION);
    return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  } catch (e) {
    logger.warn('查询蓝牙授权状态失败: ' + errorText(e));
    return false;
  }
}

/**
 * 隐私声明是否已签署（可否进行系统权限申请）。
 *
 * 接入应用市场隐私托管服务后，首次启动由系统弹出标准化隐私弹窗，该弹窗优先级
 * 高于权限申请弹窗：未签署时系统会直接丢弃权限申请（既不弹窗也不补弹），
 * 故权限申请前须经此判断。
 *
 * 未接入托管服务时 getAppPrivacyMgmtInfo 报 1006700003（The application does
 * not use privacy manager service）或 type 非 FULL_MODE，此时系统不会弹隐私
 * 弹窗、权限申请不受其影响，一律视为已签署，保证本地调试与未上架场景行为不变。
 */
export function isPrivacyAgreed(): boolean {
  try {
    let mgmtInfo: privacyManager.AppPrivacyMgmtInfo = privacyManager.getAppPrivacyMgmtInfo();
    if (mgmtInfo.type !== privacyManager.AppPrivacyMgmtType.FULL_MODE) {
      return true;
    }
    let results: privacyManager.AppPrivacyResult[] = privacyManager.getAppPrivacyResult();
    if (results.length === 0) {
      logger.info('已接入隐私管理服务但无签署记录，视为未签署');
      return false;
    }
    for (let i = 0; i < results.length; i++) {
      // DISAGREED（不同意）与 REQUIRE_RESIGNING_VERSION_UPDATE（协议变更需重签）均视为未签署
      if (results[i].result !== privacyManager.AppPrivacyResultType.FULL_MODE_AGREED) {
        return false;
      }
    }
    return true;
  } catch (e) {
    logger.warn('查询隐私签署状态失败，按已签署处理: ' + errorText(e));
    return true;
  }
}

/**
 * 申请通知权限（首次调用弹窗；已开启或用户已拒绝时不再弹窗），
 * 返回申请后是否已开启。
 */
export async function requestNotificationPermission(context: common.UIAbilityContext): Promise<boolean> {
  if (isNotificationPermissionGranted()) {
    return true;
  }
  let granted: boolean = false;
  await enqueue(async (): Promise<void> => {
    try {
      await notificationManager.requestEnableNotification(context);
      granted = isNotificationPermissionGranted();
    } catch (e) {
      logger.info('通知授权未通过: ' + errorText(e));
      granted = false;
    }
  });
  return granted;
}

/**
 * 申请蓝牙权限（首次调用弹窗；已授予或用户已拒绝时不再弹窗），
 * 返回申请后是否已授予。
 */
export async function requestBluetoothPermission(context: common.Context): Promise<boolean> {
  if (isBluetoothPermissionGranted()) {
    return true;
  }
  let granted: boolean = false;
  await enqueue(async (): Promise<void> => {
    try {
      let atManager = abilityAccessCtrl.createAtManager();
      let permissions: Array<Permissions> = [BLUETOOTH_PERMISSION];
      let result: PermissionRequestResult = await atManager.requestPermissionsFromUser(context, permissions);
      granted = result.authResults.length > 0 && result.authResults[0] === 0;
    } catch (e) {
      logger.error('申请蓝牙权限失败: ' + errorText(e));
      granted = false;
    }
  });
  return granted;
}

/**
 * 通知权限被拒后：拉起通知管理半模态弹窗，用户设置完成后 Promise 才返回
 * （调用方随后重新查询状态才能读到最新结果）。
 * 低版本无 openNotificationSettingsWithResult 时回退到仅打开的 openNotificationSettings。
 */
export async function guideToNotificationSettings(context: common.UIAbilityContext): Promise<void> {
  try {
    await notificationManager.openNotificationSettingsWithResult(context);
  } catch (e) {
    logger.warn('打开通知设置半模态弹窗失败，回退系统设置页: ' + errorText(e));
    try {
      await notificationManager.openNotificationSettings(context);
    } catch (e2) {
      logger.warn('打开通知设置失败: ' + errorText(e2));
    }
  }
}

/** 蓝牙权限被拒后：拉起权限设置弹窗，引导用户手动开启 */
export async function guideToBluetoothPermissionSetting(context: common.Context): Promise<void> {
  try {
    let atManager = abilityAccessCtrl.createAtManager();
    let permissions: Array<Permissions> = [BLUETOOTH_PERMISSION];
    await atManager.requestPermissionOnSetting(context, permissions);
  } catch (e) {
    logger.warn('打开蓝牙权限设置失败: ' + errorText(e));
  }
}
