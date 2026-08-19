/**
 * DialogService.ets — 统一对话框管理服务
 * 封装 UIContext.getPromptAction().openCustomDialog() + ComponentContent + wrapBuilder 模式
 * 替代已废弃的 CustomDialogController
 * 
 * 关键修复: closeCustomDialog 必须使用与 openCustomDialog 相同的 ComponentContent 实例,
 * 因此将 contentNode 引用存储在 params 对象中, 在 onClick 回调中复用同一实例关闭弹窗.
 */

import { ComponentContent, PromptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DiscoveredDevice } from '../model/Types';
import { DesignTokens } from '../common/DesignTokens';

const TAG = 'DialogService';
const DOMAIN = 0x0001;

function dialogAccentColor(): ResourceColor {
  return $r('app.color.accent_blue');
}

export class DialogService {
  private static ctx: UIContext | null = null;

  static init(uiContext: UIContext): void {
    DialogService.ctx = uiContext;
  }

  private static getPromptAction(): PromptAction | null {
    if (DialogService.ctx === null) {
      hilog.error(DOMAIN, TAG, 'UIContext not initialized. Call DialogService.init() first.');
      return null;
    }
    return DialogService.ctx.getPromptAction();
  }




  // ── US3: 对话框方法 (将逐步从CustomDialogController迁移到@Builder模式) ──

  static showTextSendDialog(callback: (text: string) => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    let params = new TextSendParams(callback);
    let contentNode = new ComponentContent(DialogService.ctx, wrapBuilder(buildTextSendDialog), params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
  }

  static showFavoriteDeleteDialog(device: DiscoveredDevice, onDelete: () => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    let params = new FavoriteDeleteParams(device, onDelete);
    let contentNode = new ComponentContent(DialogService.ctx, wrapBuilder(buildFavoriteDeleteDialog), params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
  }

  static showFavoriteEditDialog(device: DiscoveredDevice, onSave: (newAlias: string) => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    let params = new FavoriteEditParams(device, onSave);
    let contentNode = new ComponentContent(DialogService.ctx, wrapBuilder(buildFavoriteEditDialog), params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
  }


  static showFileNameDialog(defaultName: string, callback: (name: string) => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    let params = new FileNameParams(defaultName, callback);
    let contentNode = new ComponentContent(DialogService.ctx, wrapBuilder(buildFileNameDialog), params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
  }

  static showInputDialog(title: ResourceStr, defaultValue: string, callback: (value: string) => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    // Resolve Resource to string if needed
    let titleStr: string = '';
    if (typeof title === 'string') {
      titleStr = title as string;
    } else {
      try {
        let ctx = DialogService.ctx.getHostContext();
        if (ctx !== undefined) {
          titleStr = ctx.resourceManager.getStringSync((title as Resource).id);
        }
      } catch (_e) {
        titleStr = '';
      }
    }
    let params = new InputParams(titleStr, defaultValue, callback);
    let contentNode = new ComponentContent(DialogService.ctx, wrapBuilder(buildInputDialog), params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
  }

  static showDeviceTypePicker(currentType: string, callback: (type: string) => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    let params = new DeviceTypePickerParams(currentType, callback);
    let contentNode = new ComponentContent(DialogService.ctx, wrapBuilder(buildDeviceTypePickerDialog), params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
  }


  static showEncryptionNotice(callback: () => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    let params = new NoticeParams(callback);
    let contentNode = new ComponentContent(DialogService.ctx, wrapBuilder(buildEncryptionNotice), params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
  }

  static showQuickActionsDialog(callback: (action: string) => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    let params = new QuickActionsParams(callback);
    let contentNode = new ComponentContent(DialogService.ctx, wrapBuilder(buildQuickActionsDialog), params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Bottom });
  }

  static showAutoSaveWarning(message: ResourceStr, callback: () => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    let params = new AutoSaveWarningParams(message, callback);
    let contentNode = new ComponentContent(DialogService.ctx, wrapBuilder(buildAutoSaveWarningDialog), params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
  }

  // ── 通用关闭方法: 使用存储在 params 中的 contentNode 关闭弹窗 ──
  static closeDialogByParams(params: DialogBaseParams): void {
    if (params.contentNode !== null) {
      let promptAction = DialogService.getPromptAction();
      if (promptAction !== null) {
        promptAction.closeCustomDialog(params.contentNode);
      }
    }
  }
}

// ── 基础参数类 (包含 contentNode 引用) ──
// contentNode 类型使用 Object 以兼容各子类的具体泛型参数

class DialogBaseParams {
  contentNode: ComponentContent<Object> | null = null;
}

class TextSendParams extends DialogBaseParams {
  callback: (text: string) => void;
  currentValue: string = '';
  constructor(callback: (text: string) => void) {
    super();
    this.callback = callback;
  }
}

class FavoriteDeleteParams extends DialogBaseParams {
  device: DiscoveredDevice;
  onDelete: () => void;
  constructor(device: DiscoveredDevice, onDelete: () => void) {
    super();
    this.device = device;
    this.onDelete = onDelete;
  }
}

class FavoriteEditParams extends DialogBaseParams {
  device: DiscoveredDevice;
  onSave: (newAlias: string) => void;
  currentAlias: string = '';
  constructor(device: DiscoveredDevice, onSave: (newAlias: string) => void) {
    super();
    this.device = device;
    this.onSave = onSave;
    this.currentAlias = device.alias || '';
  }
}


class FileNameParams extends DialogBaseParams {
  defaultName: string;
  callback: (name: string) => void;
  currentValue: string = '';
  constructor(defaultName: string, callback: (name: string) => void) {
    super();
    this.defaultName = defaultName;
    this.currentValue = defaultName;
    this.callback = callback;
  }
}

class InputParams extends DialogBaseParams {
  title: string;
  defaultValue: string;
  callback: (value: string) => void;
  currentValue: string = '';
  constructor(title: string, defaultValue: string, callback: (value: string) => void) {
    super();
    this.title = title;
    this.defaultValue = defaultValue;
    this.currentValue = defaultValue;
    this.callback = callback;
  }
}

class DeviceTypePickerParams extends DialogBaseParams {
  currentType: string;
  callback: (type: string) => void;
  constructor(currentType: string, callback: (type: string) => void) {
    super();
    this.currentType = currentType;
    this.callback = callback;
  }
}

class NoticeParams extends DialogBaseParams {
  callback: () => void;
  constructor(callback: () => void) {
    super();
    this.callback = callback;
  }
}

class QuickActionsParams extends DialogBaseParams {
  callback: (action: string) => void;
  constructor(callback: (action: string) => void) {
    super();
    this.callback = callback;
  }
}

class AutoSaveWarningParams extends DialogBaseParams {
  message: ResourceStr;
  callback: () => void;
  constructor(message: ResourceStr, callback: () => void) {
    super();
    this.message = message;
    this.callback = callback;
  }
}

// ── @Builder 对话框实现 ──
// 通过 openCustomDialog 展示
// 关闭弹窗使用存储在 params.contentNode 中的同一 ComponentContent 实例

@Builder
function buildTextSendDialog(params: TextSendParams) {
  Column() {
    Text($r('app.string.send_text_input_title'))
      .fontSize(DesignTokens.font.subtitleL)
      .fontWeight(FontWeight.Bold)
      .margin({ bottom: DesignTokens.space.md })
    TextArea()
      .height(120)
      .borderRadius(DesignTokens.radius.md)
      .margin({ bottom: DesignTokens.space.md })
      .id('textSendInput')
      .defaultFocus(true)
      .enableKeyboardOnFocus(true)
      .onChange((value: string) => {
        params.currentValue = value;
      })
    Row({ space: DesignTokens.space.sm }) {
      Button($r('app.string.dialog_cancel'))
        .layoutWeight(1)
        .height(DesignTokens.hotspot.minSize)
        .borderRadius(DesignTokens.radius.md)
        .backgroundColor($r('app.color.text_secondary'))
        .onClick(() => {
          DialogService.closeDialogByParams(params);
        })
      Button($r('app.string.dialog_confirm'))
        .layoutWeight(1)
        .height(DesignTokens.hotspot.minSize)
        .borderRadius(DesignTokens.radius.md)
        .onClick(() => {
          params.callback(params.currentValue);
          DialogService.closeDialogByParams(params);
        })
    }
  }
  .padding(DesignTokens.space.lg)
  .borderRadius(DesignTokens.radius.lg)
  .backgroundColor($r('app.color.card_background'))
  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
  .constraintSize({ maxWidth: '85%' })
}

@Builder
function buildFavoriteDeleteDialog(params: FavoriteDeleteParams) {
  Column() {
    Text($r('app.string.delete_favorite_title'))
      .fontSize(DesignTokens.font.subtitleL)
      .fontWeight(FontWeight.Bold)
      .margin({ bottom: DesignTokens.space.md })
    Text(params.device.alias || params.device.ip)
      .fontSize(DesignTokens.font.subtitleM)
      .margin({ bottom: DesignTokens.space.md })
    Row({ space: DesignTokens.space.sm }) {
      Button($r('app.string.dialog_cancel'))
        .layoutWeight(1)
        .height(DesignTokens.hotspot.minSize)
        .borderRadius(DesignTokens.radius.md)
        .backgroundColor($r('app.color.text_secondary'))
        .onClick(() => {
          DialogService.closeDialogByParams(params);
        })
      Button($r('app.string.dialog_confirm'))
        .layoutWeight(1)
        .height(DesignTokens.hotspot.minSize)
        .borderRadius(DesignTokens.radius.md)
        .onClick(() => {
          params.onDelete();
          DialogService.closeDialogByParams(params);
        })
    }
  }
  .padding(DesignTokens.space.lg)
  .borderRadius(DesignTokens.radius.lg)
  .backgroundColor($r('app.color.card_background'))
  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
  .constraintSize({ maxWidth: '85%' })
}

@Builder
function buildFavoriteEditDialog(params: FavoriteEditParams) {
  Column() {
    Text($r('app.string.edit_favorite_title'))
      .fontSize(DesignTokens.font.subtitleL)
      .fontWeight(FontWeight.Bold)
      .margin({ bottom: DesignTokens.space.md })
    Text(params.device.alias || params.device.ip)
      .fontSize(DesignTokens.font.subtitleM)
      .margin({ bottom: DesignTokens.space.sm })
    TextInput({ text: params.currentAlias })
      .borderRadius(DesignTokens.radius.md)
      .margin({ bottom: DesignTokens.space.md })
      .id('favoriteAliasInput')
      .onChange((value: string) => {
        params.currentAlias = value;
      })
    Row({ space: DesignTokens.space.sm }) {
      Button($r('app.string.dialog_cancel'))
        .layoutWeight(1)
        .height(DesignTokens.hotspot.minSize)
        .borderRadius(DesignTokens.radius.md)
        .backgroundColor($r('app.color.text_secondary'))
        .onClick(() => {
          DialogService.closeDialogByParams(params);
        })
      Button($r('app.string.dialog_confirm'))
        .layoutWeight(1)
        .height(DesignTokens.hotspot.minSize)
        .borderRadius(DesignTokens.radius.md)
        .onClick(() => {
          params.onSave(params.currentAlias);
          DialogService.closeDialogByParams(params);
        })
    }
  }
  .padding(DesignTokens.space.lg)
  .borderRadius(DesignTokens.radius.lg)
  .backgroundColor($r('app.color.card_background'))
  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
  .constraintSize({ maxWidth: '85%' })
}

@Builder
function buildFileNameDialog(params: FileNameParams) {
  Column() {
    Text($r('app.string.rename_file_title'))
      .fontSize(DesignTokens.font.subtitleL)
      .fontWeight(FontWeight.Bold)
      .margin({ bottom: DesignTokens.space.md })
    TextInput({ text: params.defaultName })
      .borderRadius(DesignTokens.radius.md)
      .margin({ bottom: DesignTokens.space.md })
      .id('fileNameInput')
      .onChange((value: string) => {
        params.currentValue = value;
      })
    Row({ space: DesignTokens.space.sm }) {
      Button($r('app.string.dialog_cancel'))
        .layoutWeight(1)
        .height(DesignTokens.hotspot.minSize)
        .borderRadius(DesignTokens.radius.md)
        .backgroundColor($r('app.color.text_secondary'))
        .onClick(() => {
          DialogService.closeDialogByParams(params);
        })
      Button($r('app.string.dialog_confirm'))
        .layoutWeight(1)
        .height(DesignTokens.hotspot.minSize)
        .borderRadius(DesignTokens.radius.md)
        .onClick(() => {
          params.callback(params.currentValue);
          DialogService.closeDialogByParams(params);
        })
    }
  }
  .padding(DesignTokens.space.lg)
  .borderRadius(DesignTokens.radius.lg)
  .backgroundColor($r('app.color.card_background'))
  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
}

@Builder
function buildInputDialog(params: InputParams) {
  Column() {
    Text(params.title)
      .fontSize(DesignTokens.font.subtitleL)
      .fontWeight(FontWeight.Bold)
      .margin({ bottom: DesignTokens.space.md })
    TextInput({ text: params.defaultValue })
      .borderRadius(DesignTokens.radius.md)
      .margin({ bottom: DesignTokens.space.md })
      .id('inputField')
      .onChange((value: string) => {
        params.currentValue = value;
      })
    Row({ space: DesignTokens.space.sm }) {
      Button($r('app.string.dialog_cancel'))
        .layoutWeight(1)
        .height(DesignTokens.hotspot.minSize)
        .borderRadius(DesignTokens.radius.md)
        .backgroundColor($r('app.color.text_secondary'))
        .onClick(() => {
          DialogService.closeDialogByParams(params);
        })
      Button($r('app.string.dialog_confirm'))
        .layoutWeight(1)
        .height(DesignTokens.hotspot.minSize)
        .borderRadius(DesignTokens.radius.md)
        .onClick(() => {
          params.callback(params.currentValue);
          DialogService.closeDialogByParams(params);
        })
    }
  }
  .padding(DesignTokens.space.lg)
  .borderRadius(DesignTokens.radius.lg)
  .backgroundColor($r('app.color.card_background'))
  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
  .constraintSize({ maxWidth: '85%' })
}

class DeviceTypeItem {
  value: string = ''
  labelId: string = ''
  iconId: string = ''

  constructor(value: string, labelId: string, iconId: string) {
    this.value = value;
    this.labelId = labelId;
    this.iconId = iconId;
  }
}

const DEVICE_TYPES: Array<DeviceTypeItem> = [
  new DeviceTypeItem('mobile', 'app.string.device_type_mobile', 'app.media.ic_public_devices_phone'),
  new DeviceTypeItem('desktop', 'app.string.device_type_desktop', 'app.media.ic_device_matebook'),
  new DeviceTypeItem('web', 'app.string.device_type_web', 'app.media.ic_browser'),
  new DeviceTypeItem('headless', 'app.string.device_type_headless', 'app.media.ic_terminal'),
  new DeviceTypeItem('server', 'app.string.device_type_server', 'app.media.ic_server'),
  new DeviceTypeItem('tablet', 'app.string.device_type_tablet', 'app.media.ic_device_pad'),
];

@Builder
function buildDeviceTypePickerDialog(params: DeviceTypePickerParams) {
  Column() {
    Text($r('app.string.select_device_type_title'))
      .fontSize(DesignTokens.font.subtitleL)
      .fontWeight(FontWeight.Bold)
      .margin({ bottom: DesignTokens.space.md })
    ForEach(DEVICE_TYPES, (item: DeviceTypeItem) => {
      Row({ space: DesignTokens.space.sm }) {
        Image($r(item.iconId))
          .width(22)
          .height(22)
          .fillColor($r('app.color.text_primary'))

        Text($r(item.labelId))
          .fontSize(DesignTokens.font.subtitleM)
          .layoutWeight(1)

        if (item.value === params.currentType) {
          Text('✓')
            .fontSize(DesignTokens.font.subtitleL)
            .fontColor(dialogAccentColor())
        }
      }
      .width('100%')
      .padding(DesignTokens.space.md)
      .borderRadius(DesignTokens.radius.md)
      .onClick(() => {
        params.callback(item.value);
        DialogService.closeDialogByParams(params);
      })
    }, (item: DeviceTypeItem) => item.value)
  }
  .padding(DesignTokens.space.lg)
  .borderRadius(DesignTokens.radius.lg)
  .backgroundColor($r('app.color.card_background'))
  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
  .constraintSize({ maxWidth: '85%' })
}

@Builder
function buildEncryptionNotice(params: NoticeParams) {
  Column() {
    Text($r('app.string.encryption_notice_title'))
      .fontSize(DesignTokens.font.subtitleL)
      .fontWeight(FontWeight.Bold)
      .margin({ bottom: DesignTokens.space.md })
    Text($r('app.string.encryption_notice_message'))
      .fontSize(DesignTokens.font.bodyM)
      .margin({ bottom: DesignTokens.space.md })
    Row({ space: DesignTokens.space.sm }) {
      Button($r('app.string.dialog_cancel'))
        .layoutWeight(1)
        .height(DesignTokens.hotspot.minSize)
        .borderRadius(DesignTokens.radius.md)
        .backgroundColor($r('app.color.text_secondary'))
        .onClick(() => {
          DialogService.closeDialogByParams(params);
        })
      Button($r('app.string.dialog_confirm'))
        .layoutWeight(1)
        .height(DesignTokens.hotspot.minSize)
        .borderRadius(DesignTokens.radius.md)
        .onClick(() => {
          params.callback();
          DialogService.closeDialogByParams(params);
        })
    }
  }
  .padding(DesignTokens.space.lg)
  .borderRadius(DesignTokens.radius.lg)
  .backgroundColor($r('app.color.card_background'))
  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
  .constraintSize({ maxWidth: '85%' })
}

@Builder
function buildQuickActionsDialog(params: QuickActionsParams) {
  Column() {
    Text($r('app.string.quick_actions_title'))
      .fontSize(DesignTokens.font.subtitleL)
      .fontWeight(FontWeight.Bold)
      .margin({ bottom: DesignTokens.space.md })
    List() {
      ListItem() {
        Row() {
          Text($r('app.string.save_to_gallery_label'))
            .fontSize(DesignTokens.font.bodyM)
        }
        .width('100%')
        .padding(DesignTokens.space.md)
        .onClick(() => {
          params.callback('save_to_gallery');
          DialogService.closeDialogByParams(params);
        })
      }
      ListItem() {
        Row() {
          Text($r('app.string.open_file'))
            .fontSize(DesignTokens.font.bodyM)
        }
        .width('100%')
        .padding(DesignTokens.space.md)
        .onClick(() => {
          params.callback('open_with');
          DialogService.closeDialogByParams(params);
        })
      }
    }
  }
  .padding(DesignTokens.space.lg)
  .borderRadius(DesignTokens.radius.lg)
  .backgroundColor($r('app.color.card_background'))
  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
  .constraintSize({ maxWidth: '85%' })
}

@Builder
function buildAutoSaveWarningDialog(params: AutoSaveWarningParams) {
  Column() {
    Text($r('app.string.auto_save_title'))
      .fontSize(DesignTokens.font.subtitleL)
      .fontWeight(FontWeight.Bold)
      .margin({ bottom: DesignTokens.space.md })
    Text(params.message)
      .fontSize(DesignTokens.font.bodyM)
      .margin({ bottom: DesignTokens.space.md })
    Row({ space: DesignTokens.space.sm }) {
      Button($r('app.string.dialog_cancel'))
        .layoutWeight(1)
        .height(DesignTokens.hotspot.minSize)
        .borderRadius(DesignTokens.radius.md)
        .backgroundColor($r('app.color.text_secondary'))
        .onClick(() => {
          DialogService.closeDialogByParams(params);
        })
      Button($r('app.string.dialog_confirm'))
        .layoutWeight(1)
        .height(DesignTokens.hotspot.minSize)
        .borderRadius(DesignTokens.radius.md)
        .onClick(() => {
          params.callback();
          DialogService.closeDialogByParams(params);
        })
    }
  }
  .padding(DesignTokens.space.lg)
  .borderRadius(DesignTokens.radius.lg)
  .backgroundColor($r('app.color.card_background'))
  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
  .constraintSize({ maxWidth: '85%' })
}
