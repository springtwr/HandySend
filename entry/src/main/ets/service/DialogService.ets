/**
 * DialogService.ets — 统一对话框管理服务
 * 封装 UIContext.getPromptAction().openCustomDialog() + ComponentContent + wrapBuilder 模式
 *
 * 仅承载 C 类弹窗（标准确认/提示/输入类弹窗由调用点组件经 DialogV2 + openCustomDialog 实现）：
 * - showPinDialog（输入控件 + 错误提示；经 onWillDismiss 在交互式关闭时执行取消逻辑，
 *   防止用户点击弹窗外空白/返回键后 PIN 等待方挂起）。
 * - showProtocolDisableConfirmDialog（协议总开关关闭前的活跃传输二次确认；
 *   经 onWillDismiss 在交互式关闭时按取消处理，避免误关中断传输）。
 *
 * 另提供 showCenterToast：非 UI 层（Repository/Service）发起的屏幕中央短提示，
 * 复用同一份 UIContext。
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
      logger.error('UIContext 未初始化，请先调用 DialogService.init()');
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
    let settled: boolean = false;
    let settleOnce = (pin: string): void => {
      if (settled) {
        return;
      }
      settled = true;
      callback(pin);
    };
    let params = new PinParams(deviceName, errorHint, settleOnce);
    let opened = DialogService.openDialog(params, wrapBuilder(buildPinDialog), {
      alignment: DialogAlignment.Center,
      onWillDismiss: (action: DismissDialogAction) => {
        // 交互式关闭（点击遮罩/返回键/侧滑）等价于点击取消按钮；settled 防按钮与关闭双调
        params.callback('');
        params.contentNode = null;
        action.dismiss();
      }
    });
    // 打开失败（UIContext 未就绪）时按取消语义回调，保证 PIN 等待方不挂起
    if (!opened) {
      settleOnce('');
    }
  }

  // 关闭二次确认弹窗（PC/2in1 有进行中传输时点击窗口关闭按钮触发）。
  // 回调参数 keepRunning：true = 继续（取消关闭、保留窗口与传输），false = 退出应用。
  // 交互式关闭（点击遮罩/返回键）等价于"继续"，避免误退出中断传输。
  static showCloseConfirmDialog(callback: (keepRunning: boolean) => void): void {
    // 按钮与交互式关闭双调防护（同 PIN 弹窗 settled 语义）
    let settled: boolean = false;
    let settleOnce = (keepRunning: boolean): void => {
      if (settled) {
        return;
      }
      settled = true;
      callback(keepRunning);
    };
    let params = new CloseConfirmParams(settleOnce);
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
      settleOnce(true);
    }
  }

  // 协议总开关关闭二次确认弹窗（有进行中传输时触发）。
  // 正文列出将被中断的会话明细（每行：对端名 + 方向 + 文件名/数量，由调用方构建）。
  // 回调参数 confirmed：true = 确认关闭（中断传输并落取消终态），false = 取消（开关回弹）。
  // 交互式关闭（点击遮罩/返回键）等价于"取消"，避免误关中断传输。
  static showProtocolDisableConfirmDialog(protocolLabel: string, detailLines: Array<string>,
    callback: (confirmed: boolean) => void): void {
    // 解析标题/正文模板并填充协议名与会话明细（解析失败时保留空串，弹窗仍可展示明细行）
    let titleText: string = '';
    let messageText: string = '';
    if (DialogService.ctx !== null) {
      let hostContext = DialogService.ctx.getHostContext();
      if (hostContext !== undefined) {
        try {
          titleText = hostContext.resourceManager
            .getStringSync($r('app.string.protocol_disable_confirm_title').id)
            .replace('%s', protocolLabel);
          messageText = hostContext.resourceManager
            .getStringSync($r('app.string.protocol_disable_confirm_message').id)
            .replace('%s', detailLines.join('\n'));
        } catch (_e) {
          logger.warn('解析协议关闭确认弹窗文案失败');
        }
      }
    }
    DialogService.showDetailConfirmDialog(titleText, messageText, detailLines, callback,
      $r('app.string.protocol_disable_confirm_cancel'), $r('app.string.protocol_disable_confirm_ok'));
  }

  // 网页服务重启二次确认弹窗（修改加密/PIN/端口且存在进行中网页传输时触发）。
  static showWebServiceRestartConfirmDialog(detailLines: Array<string>,
    callback: (confirmed: boolean) => void): void {
    let titleText: string = '';
    let messageText: string = '';
    if (DialogService.ctx !== null) {
      let hostContext = DialogService.ctx.getHostContext();
      if (hostContext !== undefined) {
        try {
          titleText = hostContext.resourceManager
            .getStringSync($r('app.string.web_service_restart_title').id);
          messageText = hostContext.resourceManager
            .getStringSync($r('app.string.web_service_restart_message').id)
            .replace('%s', detailLines.join('\n'));
        } catch (_e) {
          logger.warn('解析网页服务重启确认弹窗文案失败');
        }
      }
    }
    DialogService.showDetailConfirmDialog(titleText, messageText, detailLines, callback,
      $r('app.string.web_service_restart_cancel'), $r('app.string.web_service_restart_ok'));
  }

  // 通用明细确认弹窗：标题/正文已由调用方解析，正文含明细行。
  private static showDetailConfirmDialog(titleText: string, messageText: string,
    detailLines: Array<string>, callback: (confirmed: boolean) => void,
    cancelLabel: ResourceStr, confirmLabel: ResourceStr): void {
    // 按钮与交互式关闭双调防护（同 PIN 弹窗 settled 语义）
    let settled: boolean = false;
    let settleOnce = (confirmed: boolean): void => {
      if (settled) {
        return;
      }
      settled = true;
      callback(confirmed);
    };
    let params =
      new ProtocolDisableConfirmParams(titleText, messageText, detailLines, settleOnce,
        cancelLabel, confirmLabel);
    let opened = DialogService.openDialog(params, wrapBuilder(buildProtocolDisableConfirmDialog), {
      alignment: DialogAlignment.Center,
      onWillDismiss: (action: DismissDialogAction) => {
        params.callback(false);
        params.contentNode = null;
        action.dismiss();
      }
    });
    // 打开失败（UIContext 未就绪）时按"取消"处理，不中断传输
    if (!opened) {
      params.callback(false);
    }
  }

  // ── 轻提示 ──

  /**
   * 屏幕中央短提示：供非 UI 层（Repository/Service）告知用户一次即时结果，
   * 如自动接收文本消息后已写入剪贴板。UIContext 未就绪时静默丢弃。
   */
  static showCenterToast(message: ResourceStr, duration: number = 2000): void {
    let promptAction = DialogService.getPromptAction();
    if (promptAction === null) {
      return;
    }
    promptAction.showToast({ message: message, duration: duration, alignment: Alignment.Center });
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

class ProtocolDisableConfirmParams extends DialogBaseParams {
  titleText: string;
  messageText: string;
  detailLines: Array<string>;
  callback: (confirmed: boolean) => void;
  cancelLabel: ResourceStr;
  confirmLabel: ResourceStr;

  constructor(titleText: string, messageText: string, detailLines: Array<string>,
    callback: (confirmed: boolean) => void, cancelLabel: ResourceStr, confirmLabel: ResourceStr) {
    super();
    this.titleText = titleText;
    this.messageText = messageText;
    this.detailLines = detailLines;
    this.callback = callback;
    this.cancelLabel = cancelLabel;
    this.confirmLabel = confirmLabel;
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
      // 次要操作按钮采用无填充样式（ButtonStyleMode.NORMAL），底色即所在卡片背景
      Button($r('app.string.dialog_cancel'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
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
      // 次要操作按钮采用无填充样式（ButtonStyleMode.NORMAL），底色即所在卡片背景
      Button($r('app.string.close_confirm_exit'))
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
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

// ── 协议总开关关闭二次确认弹窗 ──
// "关闭"中断列出的传输并落取消终态；"取消"保留传输（开关回弹）。

@Builder
function buildProtocolDisableConfirmDialog(params: ProtocolDisableConfirmParams) {
  Column() {
    Text(params.titleText)
      .fontSize(DesignTokens.font.subtitleL)
      .fontWeight(FontWeight.Bold)
      .margin({ bottom: DesignTokens.space.md })
      .id('protocol_disable_confirm_title')
    Text(params.messageText)
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_secondary'))
      .margin({ bottom: DesignTokens.space.lg })
      .id('protocol_disable_confirm_message')
    Row({ space: DesignTokens.space.sm }) {
      // 次要操作按钮采用无填充样式（ButtonStyleMode.NORMAL），底色即所在卡片背景
      Button(params.cancelLabel)
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .fontColor($r('app.color.text_primary'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .onClick(() => {
          params.callback(false);
          DialogService.closeDialogByParams(params);
        })
        .id('protocol_disable_confirm_cancel_btn')
      Button(params.confirmLabel)
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .borderRadius(DesignTokens.radius.max)
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
        .onClick(() => {
          params.callback(true);
          DialogService.closeDialogByParams(params);
        })
        .id('protocol_disable_confirm_ok_btn')
    }
  }
  .padding(DesignTokens.space.lg)
  .borderRadius(DesignTokens.radius.lg)
  .backgroundColor($r('app.color.card_background'))
  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
  .width('85%')
  .constraintSize({ maxWidth: 480 })
}
