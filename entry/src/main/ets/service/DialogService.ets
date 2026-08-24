/**
 * DialogService.ets — 统一对话框管理服务
 * 封装 UIContext.getPromptAction().openCustomDialog() + ComponentContent + wrapBuilder 模式
 *
 * 关键修复: closeCustomDialog 必须使用与 openCustomDialog 相同的 ComponentContent 实例,
 * 因此将 contentNode 引用存储在 params 对象中, 在 onClick 回调中复用同一实例关闭弹窗.
 */

import { ComponentContent, PromptAction } from '@kit.ArkUI';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { DiscoveredDevice } from '../model/Types';
import { DesignTokens } from '../common/DesignTokens';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:DialogService');

export class DialogService {
  private static ctx: UIContext | null = null;

  static init(uiContext: UIContext): void {
    DialogService.ctx = uiContext;
  }

  private static getPromptAction(): PromptAction | null {
    if (DialogService.ctx === null) {
      logger.error('UIContext not initialized. Call DialogService.init() first.');
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
    let contentNode =
      new ComponentContent(DialogService.ctx, wrapBuilder(buildTextSendDialog), params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
  }

  static showFavoriteDeleteDialog(device: DiscoveredDevice, onDelete: () => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    let params = new FavoriteDeleteParams(device, onDelete);
    let contentNode = new ComponentContent(DialogService.ctx, wrapBuilder(buildFavoriteDeleteDialog), params) as
      ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
  }

  static showFavoriteEditDialog(device: DiscoveredDevice, onSave: (newAlias: string) => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    let params = new FavoriteEditParams(device, onSave);
    let contentNode =
      new ComponentContent(DialogService.ctx, wrapBuilder(buildFavoriteEditDialog), params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
  }


  static showFileNameDialog(defaultName: string, callback: (name: string) => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    let params = new FileNameParams(defaultName, callback);
    let contentNode =
      new ComponentContent(DialogService.ctx, wrapBuilder(buildFileNameDialog), params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
  }

  static showInputDialog(title: ResourceStr, defaultValue: string, callback: (value: string) => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    // 必要时将 Resource 解析为字符串
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
    let contentNode =
      new ComponentContent(DialogService.ctx, wrapBuilder(buildInputDialog), params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
  }


  static showEncryptionNotice(callback: () => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    let params = new NoticeParams(callback);
    let contentNode =
      new ComponentContent(DialogService.ctx, wrapBuilder(buildEncryptionNotice), params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
  }

  static showQuickActionsDialog(callback: (action: string) => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    let params = new QuickActionsParams(callback);
    let contentNode =
      new ComponentContent(DialogService.ctx, wrapBuilder(buildQuickActionsDialog), params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Bottom });
  }

  static showAutoConfirmWarning(message: ResourceStr, callback: () => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    let params = new AutoConfirmWarningParams(message, callback);
    let contentNode = new ComponentContent(DialogService.ctx, wrapBuilder(buildAutoConfirmWarningDialog), params) as
      ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
  }

  // 发送方 PIN 输入弹窗：接收方开启 PIN 保护后，发送文件前要求输入 PIN 码
  static showPinDialog(deviceName: string, errorHint: string, callback: (pin: string) => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    let params = new PinParams(deviceName, errorHint, callback);
    let contentNode =
      new ComponentContent(DialogService.ctx, wrapBuilder(buildPinDialog), params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    promptAction.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
  }

  // 历史记录删除/清空确认弹窗：含"同时删除文件"复选框（默认不勾选）
  static showHistoryDeleteConfirmDialog(title: ResourceStr, message: string,
    onConfirm: (deleteFiles: boolean) => void): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null || DialogService.ctx === null) {
      return;
    }
    let params = new HistoryDeleteParams(title, message, onConfirm);
    let contentNode =
      new ComponentContent(DialogService.ctx, wrapBuilder(buildHistoryDeleteConfirmDialog), params) as
      ComponentContent<Object>;
    params.contentNode = contentNode;
    // 设置半透明黑色蒙层，避免深色模式下弹窗与页面背景融为一体
    promptAction.openCustomDialog(contentNode, {
      alignment: DialogAlignment.Center,
      maskColor: 'rgba(0, 0, 0, 0.45)'
    });
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

class AutoConfirmWarningParams extends DialogBaseParams {
  message: ResourceStr;
  callback: () => void;

  constructor(message: ResourceStr, callback: () => void) {
    super();
    this.message = message;
    this.callback = callback;
  }
}

class PinParams extends DialogBaseParams {
  deviceName: string;
  errorHint: string;
  callback: (pin: string) => void;
  currentValue: string = '';

  constructor(deviceName: string, errorHint: string, callback: (pin: string) => void) {
    super();
    this.deviceName = deviceName;
    this.errorHint = errorHint;
    this.callback = callback;
  }
}

// 历史记录删除/清空确认弹窗参数：
// deleteFiles 表示"同时删除文件"复选框状态（默认不勾选），
// 确认后经 onConfirm 回调把最终勾选状态交给调用方执行。
class HistoryDeleteParams extends DialogBaseParams {
  title: ResourceStr;
  message: string;
  deleteFiles: boolean = false;
  onConfirm: (deleteFiles: boolean) => void;

  constructor(title: ResourceStr, message: string, onConfirm: (deleteFiles: boolean) => void) {
    super();
    this.title = title;
    this.message = message;
    this.onConfirm = onConfirm;
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
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.text_primary'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .onClick(() => {
          DialogService.closeDialogByParams(params);
        })
      Button($r('app.string.dialog_confirm'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
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
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.text_primary'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .onClick(() => {
          DialogService.closeDialogByParams(params);
        })
      Button($r('app.string.dialog_confirm'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
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
      .borderRadius(DesignTokens.radius.max)
      .margin({ bottom: DesignTokens.space.md })
      .id('favoriteAliasInput')
      .onChange((value: string) => {
        params.currentAlias = value;
      })
    Row({ space: DesignTokens.space.sm }) {
      Button($r('app.string.dialog_cancel'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.text_primary'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .onClick(() => {
          DialogService.closeDialogByParams(params);
        })
      Button($r('app.string.dialog_confirm'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
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
      .borderRadius(DesignTokens.radius.max)
      .margin({ bottom: DesignTokens.space.md })
      .id('fileNameInput')
      .onChange((value: string) => {
        params.currentValue = value;
      })
    Row({ space: DesignTokens.space.sm }) {
      Button($r('app.string.dialog_cancel'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.text_primary'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .onClick(() => {
          DialogService.closeDialogByParams(params);
        })
      Button($r('app.string.dialog_confirm'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
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
      .borderRadius(DesignTokens.radius.max)
      .margin({ bottom: DesignTokens.space.md })
      .id('inputField')
      .onChange((value: string) => {
        params.currentValue = value;
      })
    Row({ space: DesignTokens.space.sm }) {
      Button($r('app.string.dialog_cancel'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.text_primary'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .onClick(() => {
          DialogService.closeDialogByParams(params);
        })
      Button($r('app.string.dialog_confirm'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
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
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.text_primary'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .onClick(() => {
          DialogService.closeDialogByParams(params);
        })
      Button($r('app.string.dialog_confirm'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
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
function buildAutoConfirmWarningDialog(params: AutoConfirmWarningParams) {
  Column() {
    Text($r('app.string.auto_confirm_title'))
      .fontSize(DesignTokens.font.subtitleL)
      .fontWeight(FontWeight.Bold)
      .margin({ bottom: DesignTokens.space.md })
    Text(params.message)
      .fontSize(DesignTokens.font.bodyM)
      .margin({ bottom: DesignTokens.space.md })
    Row({ space: DesignTokens.space.sm }) {
      Button($r('app.string.dialog_cancel'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.text_primary'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .onClick(() => {
          DialogService.closeDialogByParams(params);
        })
      Button($r('app.string.dialog_confirm'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
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

// ── 发送方 PIN 输入弹窗 ──
// 接收方（如 LocalSend）开启 PIN 保护时，发送前需输入对方 PIN 码。
// 输入框使用密码掩码，确认后经回调把 PIN 交给发送流程重试。

@Builder
function buildPinDialog(params: PinParams) {
  Column() {
    Text($r('app.string.pin_dialog_title'))
      .fontSize(DesignTokens.font.subtitleL)
      .fontWeight(FontWeight.Bold)
      .margin({ bottom: DesignTokens.space.sm })
    Text(params.deviceName)
      .fontSize(DesignTokens.font.subtitleM)
      .fontColor($r('app.color.text_secondary'))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .margin({ bottom: DesignTokens.space.md })
    if (params.errorHint.length > 0) {
      Text(params.errorHint)
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.danger_red'))
        .margin({ bottom: DesignTokens.space.sm })
    }
    TextInput({ placeholder: $r('app.string.pin_dialog_placeholder') })
      .type(InputType.Password)
      .borderRadius(DesignTokens.radius.max)
      .margin({ bottom: DesignTokens.space.md })
      .id('pinInput')
      .defaultFocus(true)
      .enableKeyboardOnFocus(true)
      .onChange((value: string) => {
        params.currentValue = value;
      })
    Row({ space: DesignTokens.space.sm }) {
      Button($r('app.string.dialog_cancel'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.text_primary'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .onClick(() => {
          // 取消时回调空串，通知等待方放弃 PIN 输入（发送流程按取消处理）
          params.callback('');
          DialogService.closeDialogByParams(params);
        })
      Button($r('app.string.dialog_confirm'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
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

// ── 历史记录删除/清空确认弹窗 ──
// 含"同时删除文件"复选框（默认不勾选）；确认后把最终勾选状态回传调用方。

@Builder
function buildHistoryDeleteConfirmDialog(params: HistoryDeleteParams) {
  Column() {
    Text(params.title)
      .fontSize(DesignTokens.font.subtitleL)
      .fontWeight(FontWeight.Bold)
      .margin({ bottom: DesignTokens.space.md })
    Text(params.message)
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_secondary'))
      .margin({ bottom: DesignTokens.space.md })
    // "同时删除文件"复选框（默认不勾选）
    Row({ space: DesignTokens.space.sm }) {
      Checkbox()
        .select(params.deleteFiles)
        .onChange((value: boolean) => {
          params.deleteFiles = value;
        })
      Text($r('app.string.history_delete_files_label'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
    }
    .width('100%')
    .padding({ left: DesignTokens.space.lg, right: DesignTokens.space.lg })
    .margin({ bottom: DesignTokens.space.md })
    Row({ space: DesignTokens.space.sm }) {
      Button($r('app.string.dialog_cancel'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.text_primary'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .onClick(() => {
          DialogService.closeDialogByParams(params);
        })
      Button($r('app.string.dialog_confirm'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
        .onClick(() => {
          params.onConfirm(params.deleteFiles);
          DialogService.closeDialogByParams(params);
        })
    }
  }
  .padding(DesignTokens.space.lg)
  .borderRadius(DesignTokens.radius.lg)
  .backgroundColor($r('app.color.card_background'))
  .backgroundBlurStyle(BlurStyle.Regular)
  .constraintSize({ maxWidth: '85%' })
}
