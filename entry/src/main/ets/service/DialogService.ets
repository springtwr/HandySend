/**
 * DialogService.ets — 统一对话框管理服务
 * 封装 UIContext.getPromptAction().openCustomDialog() + ComponentContent + wrapBuilder 模式
 *
 * 说明（US6 弹窗分类迁移后）：
 * - A/B 类弹窗已迁移至 DialogV2（ConfirmDialogV2/AlertDialogV2/TipsDialogV2/CustomContentDialogV2），
 *   在各调用点组件内实现，本服务仅保留 C 类弹窗（无法由 DialogV2 承载）。
 * - C 类：showPinDialog（autoCancel:false 禁止点击外部关闭）、showQuickActionsDialog（操作列表）、
 *   showFileNameDialog（通用重命名，保留备用）。
 *
 * 关键修复: closeCustomDialog 必须使用与 openCustomDialog 相同的 ComponentContent 实例,
 * 因此将 contentNode 引用存储在 params 对象中, 在 onClick 回调中复用同一实例关闭弹窗.
 */

import { ComponentContent, PromptAction, promptAction } from '@kit.ArkUI';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
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

  // ── 通用打开样板：null 检查 + ComponentContent + contentNode 回填 + openCustomDialog ──

  private static openDialog<T extends DialogBaseParams>(params: T, builder: WrappedBuilder<[T]>,
    options?: promptAction.BaseDialogOptions): void {
    let promptActionInstance = DialogService.getPromptAction();
    if (promptActionInstance === null || DialogService.ctx === null) {
      return;
    }
    let contentNode =
      new ComponentContent(DialogService.ctx, builder, params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    if (options === undefined) {
      promptActionInstance.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
    } else {
      promptActionInstance.openCustomDialog(contentNode, options);
    }
  }

  // ── 对话框方法（C 类） ──

  // 通用重命名弹窗（保留备用；当前无调用方）。
  static showFileNameDialog(defaultName: string, callback: (name: string) => void): void {
    let params = new FileNameParams(defaultName, callback);
    DialogService.openDialog(params, wrapBuilder(buildFileNameDialog));
  }

  // 快速操作列表弹窗（点击即触发，无 ActionSheet 语义；当前无调用方）。
  static showQuickActionsDialog(callback: (action: string) => void): void {
    let params = new QuickActionsParams(callback);
    DialogService.openDialog(params, wrapBuilder(buildQuickActionsDialog), { alignment: DialogAlignment.Bottom });
  }

  // 发送方 PIN 输入弹窗：接收方开启 PIN 保护后，发送文件前要求输入 PIN 码。
  // autoCancel:false（禁止点击外部关闭）在 DialogV2 中无等价能力，故保留本实现。
  static showPinDialog(deviceName: string, errorHint: string, callback: (pin: string) => void): void {
    let params = new PinParams(deviceName, errorHint, callback);
    DialogService.openDialog(params, wrapBuilder(buildPinDialog), {
      alignment: DialogAlignment.Center,
      autoCancel: false
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

class QuickActionsParams extends DialogBaseParams {
  callback: (action: string) => void;

  constructor(callback: (action: string) => void) {
    super();
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

// ── @Builder 对话框实现（C 类） ──
// 通过 openCustomDialog 展示
// 关闭弹窗使用存储在 params.contentNode 中的同一 ComponentContent 实例

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
