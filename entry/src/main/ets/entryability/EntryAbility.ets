/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { deviceInfo, BusinessError } from '@kit.BasicServicesKit';
import { systemShare } from '@kit.ShareKit';
import {
  triggerRefresh,
  setPendingSharedUris,
  setPendingSharedTexts,
  setPendingNavigation,
  cleanupSendDirWithContext,
  cleanupReceiveCacheDirWithContext,
  startMtaReceiveIfEnabled,
  stopMtaReceive,
  stopLocalServer
} from '../service/AppService';
import { NAVIGATION_PARAM_KEY, NAV_TARGET_TRANSFER_CENTER } from '../utils/WantAgentUtil';
import { initFavorites } from '../service/repository/FavoritesService';
import { initHistory } from '../service/repository/ReceiveHistoryService';
import { initDeviceIdentity } from '../service/repository/DeviceRepository';
import { loadFromPreferences } from '../service/repository/SettingsRepository';
import { isMtaReceivingActive } from '../service/repository/MtaRepository';
import {
  initBackgroundTransferService,
  startTransferTaskIfActive,
  stopTransferTask,
  hasActiveSessions
} from '../service/BackgroundTransferService';
import { withdrawPendingRequestNotification } from '../service/PendingRequestNotifier';
import { requestNotificationPermission, requestBluetoothPermission } from '../service/PermissionService';
import { DialogService } from '../service/DialogService';
import { initDemoModule } from '../service/demo/DemoScenarioService';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { initAllPreferences, flushAllPreferences } from '../utils/PreferencesUtil';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:EntryAbility', '启动');

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    logger.debug('Ability onCreate');

    // 冷启动清扫临时文件：暂存列表/接收会话均为内存态，进程被杀/崩溃等
    // 意外退出后 cache 目录中的文件成为孤儿；onCreate 时必无进行中的
    // 暂存/接收，全量删除安全（含旧版本 files 目录残留，TLS 身份保留）。
    // onCreate 仅冷启动执行一次（再次拉起走 onNewWant），不会误删活文件。
    cleanupSendDirWithContext(this.context);
    cleanupReceiveCacheDirWithContext(this.context);

    // 初始化全部偏好存储（设置/任务历史/接收历史）：三个存储相互独立，
    // 各服务 init 内部亦会初始化自身存储，此处统一前置保证任何服务取数前已就绪
    initAllPreferences(this.context);

    // 初始化 FavoritesService 和 ReceiveHistoryService
    initFavorites(this.context);
    initHistory(this.context);

    // 前置初始化设备身份：此时偏好存储已就绪，确保 onForeground 拉起 MTA 接收服务
    // 时昵称已可用，不会以空设备名启动。
    initDeviceIdentity();

    // 前置加载全部设置项：onForeground 早于首页 aboutToAppear（initAppService）
    // 执行，若不在此加载，冷启动时 startMtaReceiveIfEnabled 读到的仍是
    // SettingsRepository 的模块默认值（如 MTA 接收开关默认开），导致用户
    // 已关闭的开关在启动瞬间失效。loadFromPreferences 为幂等读取，后续
    // initAppService 中再次调用无副作用。
    loadFromPreferences();

    // 初始化后台传输服务：订阅 changeBus + 注册长时任务取消监听（进程级幂等）
    initBackgroundTransferService();

    // 初始化演示模块（仅演示分支存在）：解析落盘目录、安装适配器命令装饰、启动待确认续期
    initDemoModule(this.context);

    this.handleShareWant(want);
    this.handleNavigationWant(want);
  }

  onNewWant(want: Want): void {
    logger.debug('Ability onNewWant');
    this.handleShareWant(want);
    this.handleNavigationWant(want);
  }

  /**
   * 解析通知点击带来的深链意图：want 参数命中「任务中心」时置位一次性导航信号
   * （冷启动经 onCreate、热启动经 onNewWant 两条路径统一收口）。
   * 与分享 want（handleShareWant）解析链路相互独立，互不干扰。
   */
  private handleNavigationWant(want: Want): void {
    if (want.parameters === undefined) {
      return;
    }
    let target: Object | undefined = want.parameters[NAVIGATION_PARAM_KEY];
    if (target === undefined || typeof target !== 'string') {
      return;
    }
    if ((target as string) === NAV_TARGET_TRANSFER_CENTER) {
      setPendingNavigation(NAV_TARGET_TRANSFER_CENTER);
    }
  }

  private handleShareWant(want: Want): void {
    systemShare.getSharedData(want).then((data: systemShare.SharedData) => {
      let uris: Array<string> = [];
      let texts: Array<Record<string, string>> = [];
      let records: Array<systemShare.SharedRecord> = data.getRecords();
      for (let i = 0; i < records.length; i++) {
        let record: systemShare.SharedRecord = records[i];
        let uri: string = record.uri ?? '';
        let content: string = record.content ?? '';
        let title: string = record.title ?? '';
        let utd: string = record.utd ?? '';
        logger.debug('handleShareWant record[' + i + ']: utd=' + utd +
          ' uri_empty=' + (uri.length === 0) + ' content_empty=' + (content.length === 0));
        if (uri.length > 0) {
          // URI 非空 → 文件 URI 通道
          uris.push(uri);
        } else if (content.length > 0 || title.length > 0) {
          // URI 为空但有内容 → 文本/链接通道
          let textRecord: Record<string, string> = {
            'content': content,
            'title': title,
            'utd': utd
          };
          texts.push(textRecord);
        }
        // 两者均空则静默跳过
      }
      if (uris.length > 0) {
        setPendingSharedUris(JSON.stringify(uris));
      }
      if (texts.length > 0) {
        setPendingSharedTexts(JSON.stringify(texts));
      }
      if (uris.length > 0 || texts.length > 0) {
        triggerRefresh();
      }
    }).catch(() => {
      if (want.parameters !== undefined) {
        let sharedParam: Object | undefined = want.parameters['handysend.sharedUris'];
        if (sharedParam !== undefined && typeof sharedParam === 'string') {
          let json: string = sharedParam as string;
          if (json.length > 0) {
            setPendingSharedUris(json);
            triggerRefresh();
          }
        }
      }
    });
  }

  onDestroy(): void {
    logger.debug('Ability onDestroy');
    // 偏好写入为防抖刷盘，进程终止前全部强制落盘，防止 pending 写入丢失
    flushAllPreferences();
    // 兜底释放长时任务：进程终止时系统亦会清理，此处按官方最佳实践显式释放
    stopTransferTask();
    // 兜底清理：正常退出链路（onBackground 停 MTA → 页面 aboutToDisappear
    // 停服务器）已覆盖，此处兜住页面清理未执行的边缘场景，防止进程存活
    // 而 Ability 重建时原生层 server_handle/discovery_handle/直写 fd 残留。
    // 两者均幂等，重复调用无副作用
    stopMtaReceive();
    stopLocalServer().catch((_e: Error) => {
    });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    logger.debug('Ability onWindowStageCreate');

    let targetPage: string = 'pages/MainTabFloating';

    windowStage.loadContent(targetPage, (err) => {
      if (err.code) {
        logger.error('Failed to load the content. Cause: ' + JSON.stringify(err));
        return;
      }
      logger.debug('Succeeded in loading the content.');
      // 窗口内容加载后，初始化 DialogService 并向 UIContext 注册自定义字体
      try {
        let uiContext = windowStage.getMainWindowSync().getUIContext();
        DialogService.init(uiContext);
        // 全局注册 MaterialIcons 字体，用于指纹图标渲染
        // 使用 Flutter SDK 的 MaterialIcons-Regular.otf，其中包含 0xF0xxx PUA 码点
        uiContext.getFont().registerFont({
          familyName: 'MaterialIcons',
          familySrc: $rawfile('materialicons-regular.otf')
        });
        logger.debug('MaterialIcons font registered');
        // 将窗口背景色与页面背景对齐：页面转场/动画期间状态栏和导航条避让区
        // 会短暂露出窗口背景色，若不设置则为默认白色，造成"白块"闪烁
        this.mainWindow = windowStage.getMainWindowSync();
        this.applyWindowBackgroundColor();
        // 2in1（PC/桌面）自由窗口：设置窗口最小尺寸约束，避免窗口被缩得过小破坏布局
        this.applyDesktopWindowLimits();
        // 仅 PC/2in1：有活跃传输时拦截标题栏关闭按钮，弹出二次确认（继续/退出）
        if (deviceInfo.deviceType === '2in1') {
          this.registerCloseIntercept(windowStage);
        }
      } catch (e) {
        logger.error('Failed to init DialogService/register font. Cause: ' + JSON.stringify(e));
      }
      // 首次启动申请通知与蓝牙权限：两个接口仅首次弹窗，已授权或用户已拒绝后静默返回；
      // 经 PermissionService 串行排队，避免启动阶段多个系统弹窗互相冲突
      this.requestStartupPermissions();
    });
  }

  // 首次启动按需申请通知与蓝牙权限（串行；已授权或用户已拒绝时不弹窗）
  private requestStartupPermissions(): void {
    let ctx = this.context;
    requestNotificationPermission(ctx).then((): Promise<boolean> => {
      return requestBluetoothPermission(ctx);
    }).catch((e: BusinessError): void => {
      logger.warn('启动权限申请异常: ' + JSON.stringify(e));
    });
  }

  /**
   * 注册 windowStageClose 拦截（仅 PC/2in1；API 14+）：
   * - 无活跃传输 → 返回 false 正常退出；
   * - 有活跃传输 → 同步返回 true 阻止关闭，并异步弹出应用内二次确认：
   *   选"继续"保留窗口与传输，选"退出"主动终止应用。
   * 平台无主窗口隐藏能力，故不再接入状态栏托盘、也不最小化窗口。
   */
  private registerCloseIntercept(windowStage: window.WindowStage): void {
    try {
      windowStage.on('windowStageClose', () => {
        if (!hasActiveSessions()) {
          logger.info('windowStageClose: no active transfer, exit normally');
          return false;
        }
        logger.info('windowStageClose: active transfer, show confirm dialog');
        DialogService.showCloseConfirmDialog((keepRunning: boolean) => {
          if (!keepRunning) {
            logger.info('windowStageClose: user chose exit, terminating');
            this.context.terminateSelf().catch((_e: BusinessError) => {
            });
          }
        });
        return true;
      });
      logger.debug('windowStageClose intercept registered (PC/2in1)');
    } catch (e) {
      logger.warn('register windowStageClose failed: ' + JSON.stringify(e));
    }
  }

  // 2in1 设备上约束窗口最小尺寸（480x640vp）。手机/平板不受影响（设备类型不符直接跳过）。
  private applyDesktopWindowLimits(): void {
    if (deviceInfo.deviceType !== '2in1') {
      return;
    }
    if (this.mainWindow === null) {
      return;
    }
    try {
      this.mainWindow.setWindowLimits({
        minWidth: 480,
        minHeight: 640,
        pixelUnit: window.PixelUnit.VP
      }).then((_limits: window.WindowLimits) => {
        logger.debug('Desktop window limits applied (min 480x640vp)');
      }).catch((_e: BusinessError) => {
        logger.warn('Failed to set desktop window limits: ' + JSON.stringify(_e));
      });
    } catch (e) {
      logger.warn('Failed to set desktop window limits: ' + JSON.stringify(e));
    }
  }

  onWindowStageDestroy(): void {
    // 主窗口销毁，释放 UI 相关资源
    this.mainWindow = null;
    logger.debug('Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // 应用回到前台
    logger.debug('Ability onForeground');
    // 回前台停止长时任务（通知随之消失），进度展示交还前台传输页
    stopTransferTask();
    // 回到前台：撤回后台待确认请求提示通知（用户可在应用内处理请求）
    withdrawPendingRequestNotification();
    triggerRefresh();
    // 进入前台按「互传联盟接收」开关启动 MTA 接收服务（BLE 广播 + GATT Server）
    startMtaReceiveIfEnabled(this.context);
  }

  onBackground(): void {
    // 应用退到后台
    logger.debug('Ability onBackground');
    // 偏好写入为防抖刷盘，退后台时全部立即落盘，防止进程在后台被杀导致 pending 写入丢失
    flushAllPreferences();
    // MTA 接收进行中（建链/下载/落盘）时跳过停止，由长时任务保活继续接收；
    // 其余情况（含等待本端确认）维持现状停止服务——后台无法完成确认操作
    if (!isMtaReceivingActive()) {
      stopMtaReceive();
    }
    // 有活跃传输则申请 dataTransfer 长时任务并发布进度通知，无传输不影响既有行为
    startTransferTaskIfActive(this.context);
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    logger.debug('Ability onConfigurationUpdate: colorMode=' + JSON.stringify(newConfig.colorMode));
    // 深浅色模式切换时同步更新窗口背景色，避免避让区露出与页面不匹配的底色
    this.applyWindowBackgroundColor();
  }

  // 将窗口背景色与页面背景色（page_background 资源）对齐。
  // 非沉浸式布局下，状态栏/导航条避让区以及页面转场时露出的区域都使用窗口背景色，
  // 默认白色会与页面背景（浅色 #F2F3F5 / 深色 #121212）不一致，形成"白块"。
  private applyWindowBackgroundColor(): void {
    if (this.mainWindow === null) {
      return;
    }
    try {
      const colorValue: number = this.context.resourceManager.getColorSync($r('app.color.page_background').id);
      // getColorSync 返回 ARGB 格式，转为 #RRGGBB 字符串
      const hexColor: string = '#' + (colorValue & 0xFFFFFF).toString(16).padStart(6, '0');
      this.mainWindow.setWindowBackgroundColor(hexColor);
      logger.debug('Window background color set to ' + hexColor);
    } catch (e) {
      logger.warn('Failed to set window background color: ' + JSON.stringify(e));
    }
  }
}