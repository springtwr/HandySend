/**
 * DialogService.ets — 统一对话框管理服务
 * 封装 UIContext.getPromptAction().openCustomDialog() + ComponentContent + wrapBuilder 模式
 *
 * 仅承载 C 类弹窗（标准确认/提示/输入类弹窗由调用点组件经 DialogV2 + openCustomDialog 实现）：
 * - showPinDialog（输入控件 + 错误提示；经 onWillDismiss 在交互式关闭时执行取消逻辑，
 *   防止用户点击弹窗外空白/返回键后 PIN 等待方挂起）。
 *
 * 关键修复: closeCustomDialog 必须使用与 openCustomDialog 相同的 ComponentContent 实例,
 * 因此将 contentNode 引用存储在 params 对象中, 在 onClick 回调中复用同一实例关闭弹窗.
 */

import { ComponentContent, PromptAction, promptAction } from '@kit.ArkUI';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { DesignTokens } from '../common/DesignTokens';

const logger = getLogger(LogDomains.GENERAL, 'HandySend:DialogService', '弹窗');

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
    options?: promptAction.BaseDialogOptions): boolean {
    let promptActionInstance = DialogService.getPromptAction();
    if (promptActionInstance === null || DialogService.ctx === null) {
      return false;
    }
    let contentNode =
      new ComponentContent(DialogService.ctx, builder, params) as ComponentContent<Object>;
    params.contentNode = contentNode;
    if (options === undefined) {
      promptActionInstance.openCustomDialog(contentNode, { alignment: DialogAlignment.Center });
    } else {
      promptActionInstance.openCustomDialog(contentNode, options);
    }
    return true;
  }

  // ── 对话框方法（C 类） ──

  // 发送方 PIN 输入弹窗：接收方开启 PIN 保护后，发送文件前要求输入 PIN 码。
  // 取消语义：取消按钮回调空串；同时注册 onWillDismiss——用户点击弹窗外空白/系统返回键等
  // 交互式关闭时也回调空串再关闭，保证发送流程的 PIN 等待方始终能收到结果，不会挂起。
  static showPinDialog(deviceName: string, errorHint: string, callback: (pin: string) => void): void {
    let params = new PinParams(deviceName, errorHint, callback);
    let opened = DialogService.openDialog(params, wrapBuilder(buildPinDialog), {
      alignment: DialogAlignment.Center,
      onWillDismiss: (action: DismissDialogAction) => {
        // 交互式关闭（点击遮罩/返回键/侧滑）等价于点击取消按钮
        params.callback('');
        params.contentNode = null;
        action.dismiss();
      }
    });
    // 打开失败（UIContext 未就绪）时按取消语义回调，保证 PIN 等待方不挂起
    if (!opened) {
      callback('');
    }
  }

  // 关闭二次确认弹窗（PC/2in1 有进行中传输时点击窗口关闭按钮触发）。
  // 回调参数 keepRunning：true = 继续（取消关闭、保留窗口与传输），false = 退出应用。
  // 交互式关闭（点击遮罩/返回键）等价于"继续"，避免误退出中断传输。
  static showCloseConfirmDialog(callback: (keepRunning: boolean) => void): void {
    let params = new CloseConfirmParams(callback);
    let opened = DialogService.openDialog(params, wrapBuilder(buildCloseConfirmDialog), {
      alignment: DialogAlignment.Center,
      onWillDismiss: (action: DismissDialogAction) => {
        params.callback(true);
        params.contentNode = null;
        action.dismiss();
      }
    });
    // 打开失败（UIContext 未就绪）时按"继续"处理，保证窗口不因弹窗失败而关闭
    if (!opened) {
      callback(true);
    }
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

class CloseConfirmParams extends DialogBaseParams {
  callback: (keepRunning: boolean) => void;

  constructor(callback: (keepRunning: boolean) => void) {
    super();
    this.callback = callback;
  }
}

// ── @Builder 对话框实现（C 类） ──
// 通过 openCustomDialog 展示
// 关闭弹窗使用存储在 params.contentNode 中的同一 ComponentContent 实例

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
      .id('pin_dialog_title')
    Text(params.deviceName)
      .fontSize(DesignTokens.font.subtitleM)
      .fontColor($r('app.color.text_secondary'))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .margin({ bottom: DesignTokens.space.md })
      .id('pin_dialog_device')
    if (params.errorHint.length > 0) {
      Text(params.errorHint)
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.danger_red'))
        .margin({ bottom: DesignTokens.space.sm })
        .id('pin_dialog_error_hint')
    }
    TextInput({ placeholder: $r('app.string.pin_dialog_placeholder') })
      .type(InputType.Password)
      .borderRadius(DesignTokens.radius.max)
      .margin({ bottom: DesignTokens.space.md })
      .id('pin_input')
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
        .id('pin_dialog_cancel_btn')
      Button($r('app.string.dialog_confirm'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
        .onClick(() => {
          params.callback(params.currentValue);
          DialogService.closeDialogByParams(params);
        })
        .id('pin_dialog_confirm_btn')
    }
  }
  .padding(DesignTokens.space.lg)
  .borderRadius(DesignTokens.radius.lg)
  .backgroundColor($r('app.color.card_background'))
  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
  .width('85%')
  // 宽屏下限制弹窗最大宽度，避免铺满过宽（手机 85% 屏宽 < 480vp 不受影响）
  .constraintSize({ maxWidth: 480 })
}

// ── 关闭二次确认弹窗（PC/2in1 有进行中传输时） ──
// "继续"保留窗口与传输；"退出"退出应用。

@Builder
function buildCloseConfirmDialog(params: CloseConfirmParams) {
  Column() {
    Text($r('app.string.close_confirm_title'))
      .fontSize(DesignTokens.font.subtitleL)
      .fontWeight(FontWeight.Bold)
      .margin({ bottom: DesignTokens.space.lg })
      .id('close_confirm_title')
    Row({ space: DesignTokens.space.sm }) {
      Button($r('app.string.close_confirm_exit'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.text_primary'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .onClick(() => {
          params.callback(false);
          DialogService.closeDialogByParams(params);
        })
        .id('close_confirm_exit_btn')
      Button($r('app.string.close_confirm_continue'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
        .onClick(() => {
          params.callback(true);
          DialogService.closeDialogByParams(params);
        })
        .id('close_confirm_continue_btn')
    }
  }
  .padding(DesignTokens.space.lg)
  .borderRadius(DesignTokens.radius.lg)
  .backgroundColor($r('app.color.card_background'))
  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
  .width('85%')
  .constraintSize({ maxWidth: 480 })
}
