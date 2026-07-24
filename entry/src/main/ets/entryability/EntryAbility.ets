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

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { systemShare } from '@kit.ShareKit';
import { triggerRefresh } from '../service/AppService';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      PersistentStorage.persistProp('nekoshare_floating', true);
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    this.handleShareWant(want);
  }

  onNewWant(want: Want): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
    this.handleShareWant(want);
  }

  private handleShareWant(want: Want): void {
    let uris: Array<string> = [];

    // Path 1: synchronous from want.uri (single file, most common)
    if (want.uri !== undefined && want.uri !== null && want.uri.length > 0) {
      uris.push(want.uri);
    }

    if (uris.length > 0) {
      AppStorage.setOrCreate('sharedFileUris', JSON.stringify(uris));
      hilog.info(0x0000, 'NS_SHARE_DIAG', 'handleShareWant: from want.uri, count=%{public}d', uris.length);
      triggerRefresh();
      return;
    }

    // Path 2: async from systemShare (multi-file or complex shares)
    systemShare.getSharedData(want).then((data: systemShare.SharedData) => {
      let records: Array<systemShare.SharedRecord> = data.getRecords();
      for (let i = 0; i < records.length; i++) {
        let uri: string = records[i].uri ?? '';
        if (uri.length > 0) {
          uris.push(uri);
        }
      }
      if (uris.length > 0) {
        AppStorage.setOrCreate('sharedFileUris', JSON.stringify(uris));
        hilog.info(0x0000, 'NS_SHARE_DIAG', 'handleShareWant: from systemShare, count=%{public}d', uris.length);
        triggerRefresh();
      } else {
        hilog.info(0x0000, 'NS_SHARE_DIAG', 'handleShareWant: systemShare returned empty records');
      }
    }).catch(() => {
      hilog.info(0x0000, 'NS_SHARE_DIAG', 'handleShareWant: systemShare failed, trying parameters');
      // Path 3: fallback — internal forwarding from ShareExtAbility (legacy)
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

    let targetPage: string = 'pages/MainPage';
    if (deviceInfo.sdkApiVersion >= 23) {
      targetPage = 'pages/MainTabFloating';
    }

    windowStage.loadContent(targetPage, (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
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
}