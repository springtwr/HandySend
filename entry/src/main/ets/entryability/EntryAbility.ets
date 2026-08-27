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
import { triggerRefresh, setPendingSharedUris, setPendingSharedTexts } from '../service/AppService';
import { initFavorites } from '../service/repository/FavoritesService';
import { initHistory } from '../service/repository/ReceiveHistoryService';
import { DialogService } from '../service/DialogService';
import { preferencesUtil, KEY_LOCALE } from '../utils/PreferencesUtil';
import { i18n } from '@kit.LocalizationKit';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:EntryAbility');

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;

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
      } catch (e) {
        logger.error('Failed to init DialogService/register font. Cause: ' + JSON.stringify(e));
      }
    });
  }

  onWindowStageDestroy(): void {
    // 主窗口销毁，释放 UI 相关资源
    this.mainWindow = null;
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