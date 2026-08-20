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
import { font, window } from '@kit.ArkUI';
import { systemShare } from '@kit.ShareKit';
import { triggerRefresh, setPendingSharedUris } from '../service/AppService';
import { initFavorites } from '../service/FavoritesService';
import { initHistory } from '../service/ReceiveHistoryService';
import { DialogService } from '../service/DialogService';
import { preferencesUtil, KEY_LOCALE } from '../utils/PreferencesUtil';
import { i18n } from '@kit.LocalizationKit';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:EntryAbility');

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    logger.debug('Ability onCreate');

    // 初始化 FavoritesService 和 ReceiveHistoryService
    initFavorites(this.context);
    initHistory(this.context);

    // 初始化语言设置
    let savedLocale: string = preferencesUtil.getString(KEY_LOCALE, '');
    if (savedLocale.length > 0) {
      try {
        // 设置应用首选语言
        i18n.System.setAppPreferredLanguage(savedLocale);
      } catch (_e) {
        logger.warn('Failed to set locale to ' + savedLocale);
      }
    }

    this.handleShareWant(want);
  }

  onNewWant(want: Want): void {
    logger.debug('Ability onNewWant');
    this.handleShareWant(want);
  }

  private handleShareWant(want: Want): void {
    systemShare.getSharedData(want).then((data: systemShare.SharedData) => {
      let uris: Array<string> = [];
      let records: Array<systemShare.SharedRecord> = data.getRecords();
      for (let i = 0; i < records.length; i++) {
        let uri: string = records[i].uri ?? '';
        if (uri.length > 0) {
          uris.push(uri);
        }
      }
      if (uris.length > 0) {
        setPendingSharedUris(JSON.stringify(uris));
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
      } catch (e) {
        logger.error('Failed to init DialogService/register font. Cause: ' + JSON.stringify(e));
      }
    });
  }

  onWindowStageDestroy(): void {
    // 主窗口销毁，释放 UI 相关资源
    logger.debug('Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // 应用回到前台
    logger.debug('Ability onForeground');
    triggerRefresh();
  }

  onBackground(): void {
    // 应用退到后台
    logger.debug('Ability onBackground');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    logger.debug('Ability onConfigurationUpdate: colorMode=' + JSON.stringify(newConfig.colorMode));
  }
}