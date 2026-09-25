/**
 * FavoriteDevicesSheet.ets — 收藏设备面板内容组件
 *
 * 由发送页以 bindSheet 半模态承载，集中展示全部收藏设备（在线 / 离线）：
 * 点击条目请求发送（在线直发、离线由发送页先定向探测）、长按进入多选批量删除、
 * 条目右侧「更多」菜单提供重命名 / 恢复默认别名 / 删除。
 * 设备图标与徽标口径复用附近列表同一套实现，保证两处展示一致。
 */

import {
  AlertDialogV2,
  AdvancedDialogV2Button,
  CustomContentDialogV2,
  promptAction
} from '@kit.ArkUI';
import { DesignTokens } from '../common/DesignTokens';
import { EmptyState } from '../components/EmptyState';
import { getDeviceIconResource } from '../utils/DeviceIconUtil';
import { getStringSync } from '../utils/ResourceUtil';
import { FavoriteDevice } from '../model/Types';
import { SendViewModel } from '../viewmodel/SendViewModel';
import { FavoriteDeviceItemViewModel, FavoriteDevicesViewModel } from '../viewmodel/FavoriteDevicesViewModel';

@ComponentV2
export struct FavoriteDevicesSheet {
  @Require @Param sendViewModel: SendViewModel
  @Require @Param panelViewModel: FavoriteDevicesViewModel
  // 点击条目请求发送（在线直发 / 离线探测由发送页编排）
  @Event onRequestSend: (favorite: FavoriteDevice) => void = (_favorite: FavoriteDevice) => {
  }
  // 点击「更多」菜单「设备详情」请求打开详情页（由发送页先关闭面板再路由跳转）
  @Event onOpenDetails: (favorite: FavoriteDevice) => void = (_favorite: FavoriteDevice) => {
  }
  // 重命名弹窗状态
  @Local renameTargetFingerprint: string = ''
  @Local renameValue: string = ''
  @Local renameValid: boolean = false
  // 待确认删除的指纹集合（单台为一项）
  private pendingDeleteFingerprints: Array<string> = []
  private pendingDeleteSingleAlias: string = ''
  // 是否由条目「更多」菜单触发的单台删除（否则为多选批量删除）
  private pendingDeleteIsSingleMenu: boolean = false
  // 当前打开的弹窗 id（关闭时使用）
  private activeDialogId: number = -1

  private closeActiveDialog(): void {
    if (this.activeDialogId >= 0) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.activeDialogId);
      this.activeDialogId = -1;
    }
  }

  // 解析带占位符（%s/%d）的字符串资源，用于确认弹窗消息文本
  private formatMessage(resource: Resource, placeholder: string, value: string): string {
    let raw: string = getStringSync(this.getUIContext(), resource);
    if (raw.length === 0) {
      return '';
    }
    return raw.replace(placeholder, value);
  }

  // ── 重命名弹窗（B 类 CustomContentDialogV2，非空白校验、确认禁用） ──

  private openRenameDialog(item: FavoriteDeviceItemViewModel): void {
    this.renameTargetFingerprint = item.fingerprint;
    this.renameValue = item.alias;
    this.renameValid = item.alias.trim().length > 0;
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.renameDialog();
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(dialogOptions)
      .then((id: number) => {
        this.activeDialogId = id;
      })
      .catch(() => {
      });
  }

  @Builder
  renameDialog() {
    CustomContentDialogV2({
      primaryTitle: $r('app.string.favorites_rename_title'),
      contentBuilder: () => {
        this.renameContent();
      },
      buttons: [
        new AdvancedDialogV2Button({
          content: $r('app.string.dialog_cancel'),
          action: () => {
            this.closeActiveDialog();
          }
        }),
        new AdvancedDialogV2Button({
          content: $r('app.string.dialog_confirm'),
          enabled: this.renameValid,
          action: () => {
            if (this.renameValid) {
              this.panelViewModel.renameFavorite(this.renameTargetFingerprint, this.renameValue);
            }
            this.closeActiveDialog();
          }
        })
      ]
    })
      .constraintSize({ maxWidth: 480 })
  }

  @Builder
  renameContent() {
    Column({ space: DesignTokens.space.sm }) {
      TextInput({ placeholder: $r('app.string.favorites_rename_placeholder'), text: this.renameValue })
        .borderRadius(DesignTokens.radius.max)
        .defaultFocus(true)
        .onChange((value: string) => {
          this.renameValue = value;
          // 联动确认按钮可用性：空白（或仅空白字符）时禁用确认
          this.renameValid = value.trim().length > 0;
        })
    }
    .width('100%')
  }

  // ── 删除二次确认（A 类 AlertDialogV2） ──

  private openDeleteConfirm(fingerprints: Array<string>, singleAlias: string, isSingleMenu: boolean): void {
    this.pendingDeleteFingerprints = fingerprints;
    this.pendingDeleteSingleAlias = singleAlias;
    this.pendingDeleteIsSingleMenu = isSingleMenu;
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.deleteConfirmDialog();
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(dialogOptions)
      .then((id: number) => {
        this.activeDialogId = id;
      })
      .catch(() => {
      });
  }

  private deleteConfirmMessage(): string {
    if (this.pendingDeleteIsSingleMenu && this.pendingDeleteSingleAlias.length > 0) {
      return this.formatMessage($r('app.string.favorites_delete_confirm_single'), '%s',
        this.pendingDeleteSingleAlias);
    }
    return this.formatMessage($r('app.string.favorites_delete_confirm_batch'), '%d',
      String(this.pendingDeleteFingerprints.length));
  }

  private confirmDelete(): void {
    if (this.pendingDeleteIsSingleMenu) {
      if (this.pendingDeleteFingerprints.length > 0) {
        this.panelViewModel.removeOne(this.pendingDeleteFingerprints[0]);
      }
    } else {
      this.panelViewModel.removeSelected();
    }
    this.pendingDeleteFingerprints = [];
    this.pendingDeleteSingleAlias = '';
    this.pendingDeleteIsSingleMenu = false;
  }

  @Builder
  deleteConfirmDialog() {
    AlertDialogV2({
      primaryTitle: $r('app.string.favorites_delete_confirm_title'),
      content: this.deleteConfirmMessage(),
      primaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_cancel'),
        action: () => {
          this.closeActiveDialog();
        }
      }),
      secondaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_confirm'),
        action: () => {
          this.confirmDelete();
          this.closeActiveDialog();
        }
      })
    })
  }

  // 由顶部操作条触发的批量删除（勾选项集合）
  private openBatchDeleteConfirm(): void {
    let fingerprints: Array<string> = [];
    for (let i = 0; i < this.panelViewModel.items.length; i++) {
      if (this.panelViewModel.items[i].selected) {
        fingerprints.push(this.panelViewModel.items[i].fingerprint);
      }
    }
    if (fingerprints.length === 0) {
      return;
    }
    this.openDeleteConfirm(fingerprints, '', false);
  }

  // ── 条目「更多」菜单 ──

  @Builder
  itemMenu(item: FavoriteDeviceItemViewModel) {
    Menu() {
      MenuItem({ content: $r('app.string.favorites_details') })
        .onClick(() => {
          this.onOpenDetails(item.item);
        })
      MenuItem({ content: $r('app.string.favorites_rename') })
        .onClick(() => {
          this.openRenameDialog(item);
        })
      MenuItem({ content: $r('app.string.favorites_restore_default') })
        .enabled(this.panelViewModel.canRestoreDefaultAlias(item.fingerprint))
        .onClick(() => {
          this.panelViewModel.restoreDefaultAlias(item.fingerprint);
        })
      // 广播名不可得时紧随其后说明原因（该项不可点）
      if (!this.panelViewModel.canRestoreDefaultAlias(item.fingerprint)) {
        MenuItem({ content: $r('app.string.favorites_restore_default_unavailable') })
          .enabled(false)
      }
      MenuItem({ content: $r('app.string.favorites_delete') })
        .onClick(() => {
          this.openDeleteConfirm([item.fingerprint], item.alias, true);
        })
    }
  }

  // ── 顶部操作条（多选模式） ──

  @Builder
  selectionBar() {
    Row({ space: DesignTokens.space.md }) {
      Text($r('app.string.favorites_select_cancel'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .onClick(() => {
          this.panelViewModel.exitSelection();
        })
        .id('favorites_selection_cancel')

      Blank()

      Text($r('app.string.favorites_select_all'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.accent_blue'))
        .onClick(() => {
          this.panelViewModel.toggleSelectAll();
        })
        .id('favorites_selection_all')

      Text($r('app.string.favorites_delete_count', this.panelViewModel.selectedCount))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor(this.panelViewModel.selectedCount > 0 ? $r('app.color.danger_red') :
          $r('app.color.text_tertiary'))
        .enabled(this.panelViewModel.selectedCount > 0)
        .onClick(() => {
          this.openBatchDeleteConfirm();
        })
        .id('favorites_selection_delete')
    }
    .width('100%')
    .padding({
      left: DesignTokens.space.md,
      right: DesignTokens.space.md,
      top: DesignTokens.space.sm,
      bottom: DesignTokens.space.sm
    })
    .alignItems(VerticalAlign.Center)
  }

  // ── 条目渲染 ──

  // 状态徽标统一样式（在线 / 离线 / 型号共用，保证样式与 DesignToken 一致）
  @Builder
  badge(text: ResourceStr, textColor: ResourceColor, bgColor: ResourceColor) {
    Text(text)
      .fontSize(DesignTokens.font.bodyS)
      .fontColor(textColor)
      .backgroundColor(bgColor)
      .padding({
        left: DesignTokens.space.tiny,
        right: DesignTokens.space.tiny,
        top: DesignTokens.space.mini,
        bottom: DesignTokens.space.mini
      })
      .borderRadius(DesignTokens.radius.sm)
  }

  @Builder
  favoriteItem(item: FavoriteDeviceItemViewModel) {
    Row({ space: DesignTokens.space.sm }) {
      // 多选模式下展示复选框；点击交由整行处理（指示器不拦截触摸，避免双次切换）
      if (this.panelViewModel.selectionMode) {
        Checkbox()
          .select(item.selected)
          .shape(CheckBoxShape.ROUNDED_SQUARE)
          .selectedColor($r('app.color.accent_blue'))
          .margin(0)
          .hitTestBehavior(HitTestMode.None)
      }

      Image(getDeviceIconResource(item.deviceType))
        .width(DesignTokens.size.iconLg)
        .height(DesignTokens.size.iconLg)
        .fillColor($r('app.color.text_primary'))

      Column() {
        Text(item.alias)
          .fontSize(DesignTokens.font.subtitleM)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row({ space: DesignTokens.space.tiny }) {
          this.badge(item.isOnline ? $r('app.string.favorites_online') : $r('app.string.favorites_offline'),
            item.isOnline ? $r('app.color.success_green') : $r('app.color.text_secondary'),
            item.isOnline ? $r('app.color.success_bg') : $r('app.color.disabled_bg'))
          if (item.deviceModel.length > 0) {
            this.badge(item.deviceModel, $r('app.color.ip_blue_text'), $r('app.color.accent_blue_bg'))
          }
        }
        .margin({ top: DesignTokens.space.tiny })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.panelViewModel.probingFingerprint === item.fingerprint) {
        // 离线定向探测进行中：行级反馈替代右侧操作图标
        Row({ space: DesignTokens.space.xxs }) {
          LoadingProgress()
            .width(DesignTokens.size.iconSm)
            .height(DesignTokens.size.iconSm)
            .color($r('app.color.accent_blue'))
          Text($r('app.string.favorites_probing'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
        }
      } else if (!this.panelViewModel.selectionMode) {
        SymbolGlyph($r('sys.symbol.ellipsis_circle'))
          .fontSize(DesignTokens.size.iconSm)
          .fontColor([$r('app.color.text_secondary')])
          .accessibilityText($r('app.string.favorites_more'))
          .margin({ left: DesignTokens.space.xxs })
          .responseRegion({
            x: -8,
            y: -8,
            width: 48,
            height: 48
          })
          .bindMenu(this.itemMenu(item))
          .id('favorite_device_more')
      }
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.page_background'))
    .borderRadius(DesignTokens.radius.md)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (this.panelViewModel.selectionMode) {
        this.panelViewModel.toggleSelect(item.fingerprint);
      } else if (this.panelViewModel.probingFingerprint.length === 0) {
        this.onRequestSend(item.item);
      }
    })
    .gesture(LongPressGesture().onAction(() => {
      if (!this.panelViewModel.selectionMode) {
        this.panelViewModel.enterSelection(item.fingerprint);
      }
    }))
    .id('favorite_device_item')
  }

  build() {
    Column() {
      if (this.panelViewModel.selectionMode) {
        this.selectionBar()
      }

      if (this.panelViewModel.hasFavorites) {
        List() {
          Repeat(this.panelViewModel.items)
            .each((ri: RepeatItem<FavoriteDeviceItemViewModel>) => {
              ListItem() {
                this.favoriteItem(ri.item)
              }
              // 卡片纵向间距与附近列表 gutter（space.inner）口径一致
              .margin({ bottom: DesignTokens.space.inner })
            })
            .key((item: FavoriteDeviceItemViewModel) => item.fingerprint)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.md })
      } else {
        EmptyState({
          mainText: $r('app.string.favorites_empty_title'),
          fillHeight: true
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: DesignTokens.space.sm })
  }
}
