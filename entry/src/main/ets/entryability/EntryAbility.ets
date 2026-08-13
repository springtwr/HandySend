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
import { hilog } from '@kit.PerformanceAnalysisKit';
import { font, window } from '@kit.ArkUI';
import { systemShare } from '@kit.ShareKit';
import { triggerRefresh } from '../service/AppService';
import { initFavorites } from '../service/FavoritesService';
import { initHistory } from '../service/ReceiveHistoryService';
import { DialogService } from '../service/DialogService';
import { preferencesUtil, KEY_LOCALE } from '../utils/PreferencesUtil';
import { i18n } from '@kit.LocalizationKit';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');

    // Initialize FavoritesService and ReceiveHistoryService
    initFavorites(this.context);
    initHistory(this.context);

    // Initialize locale setting
    let savedLocale: string = preferencesUtil.getString(KEY_LOCALE, '');
    if (savedLocale.length > 0) {
      try {
        // Set app preferred language
        i18n.System.setAppPreferredLanguage(savedLocale);
      } catch (_e) {
        hilog.warn(DOMAIN, 'testTag', 'Failed to set locale to %{public}s', savedLocale);
      }
    }

    this.handleShareWant(want);
  }

  onNewWant(want: Want): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
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
        AppStorage.setOrCreate('sharedFileUris', JSON.stringify(uris));
        triggerRefresh();
      }
    }).catch(() => {
      if (want.parameters !== undefined) {
        let sharedParam: Object | undefined = want.parameters['nekoshare.sharedUris'];
        if (sharedParam !== undefined && typeof sharedParam === 'string') {
          let json: string = sharedParam as string;
          if (json.length > 0) {
            AppStorage.setOrCreate('sharedFileUris', json);
            triggerRefresh();
          }
        }
      }
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    let targetPage: string = 'pages/MainTabFloating';

    windowStage.loadContent(targetPage, (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      // Initialize DialogService and register custom fonts with UIContext after window content is loaded
      try {
        let uiContext = windowStage.getMainWindowSync().getUIContext();
        DialogService.init(uiContext);
        // Register MaterialIcons font globally for fingerprint icon rendering
        // Uses Flutter SDK's MaterialIcons-Regular.otf which includes 0xF0xxx PUA code points
        uiContext.getFont().registerFont({
          familyName: 'MaterialIcons',
          familySrc: $rawfile('materialicons-regular.otf')
        });
        hilog.info(DOMAIN, 'testTag', 'MaterialIcons font registered');
      } catch (e) {
        hilog.error(DOMAIN, 'testTag', 'Failed to init DialogService/register font. Cause: %{public}s', JSON.stringify(e));
      }
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    triggerRefresh();
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    hilog.info(DOMAIN, 'testTag', 'Ability onConfigurationUpdate: colorMode=%{public}s', JSON.stringify(newConfig.colorMode));
    if (newConfig.colorMode !== undefined) {
      AppStorage.setOrCreate('currentColorMode', newConfig.colorMode);
    }
  }
}