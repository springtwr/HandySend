/**
 * SingleLineValueRow.ets — 单行缩略值行（跨页公用组件）
 *
 * 单行展示「标签 + 值」，宽度不足时按中间省略；点击弹出完整值弹窗
 * （内容区由 SingleValueDialogContent 承载，文本可自由选择复制、单行居中多行左对齐、超高可滚动）；
 * 长按复制完整值并提示成功 / 失败。值为空时不渲染整行、也不触发任何交互。
 * 会话详情页传输详情区块（协议会话 ID / 统一会话标识）等跨页信息行共用本组件。
 */

import { AdvancedDialogV2Button, CustomContentDialogV2, promptAction } from '@kit.ArkUI';
import { DesignTokens } from '../common/DesignTokens';
import { copyText } from '../utils/ClipboardUtil';
import { SingleValueDialogContent } from './SingleValueDialogContent';

@ComponentV2
export struct SingleLineValueRow {
  @Require @Param label: ResourceStr
  @Require @Param value: string
  /** 是否启用行内长按复制（复制完整值并提示成功 / 失败） */
  @Param enableCopy: boolean = true
  /** 值是否靠右对齐（详情页信息行靠右；文件清单行随标签顺排） */
  @Param valueAlignEnd: boolean = true
  /** 行内字号（默认 bodyS 同详情页辅助信息；需要与主信息行同号时由调用方覆盖） */
  @Param rowFontSize: number = DesignTokens.font.bodyS
  private dialogId: number = -1

  /** 行内值对齐方式。 */
  private valueTextAlign(): TextAlign {
    return this.valueAlignEnd ? TextAlign.End : TextAlign.Start;
  }

  /** 复制完整值并给出成功 / 失败提示（值为空或未启用复制时不触发）。 */
  private copyValue(): void {
    if (!this.enableCopy || this.value.length === 0) {
      return;
    }
    if (copyText(this.value)) {
      this.getUIContext().getPromptAction().showToast({
        message: $r('app.string.copy_success'),
        duration: 2000
      });
    } else {
      this.getUIContext().getPromptAction().showToast({
        message: $r('app.string.copy_failed'),
        duration: 2000
      });
    }
  }

  private closeDialog(): void {
    if (this.dialogId >= 0) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.dialogId);
      this.dialogId = -1;
    }
  }

  /** 点击值区域：弹出完整值弹窗（弹窗文本可长按自由选择复制）。 */
  private openDialog(): void {
    if (this.value.length === 0) {
      return;
    }
    let options: promptAction.CustomDialogOptions = {
      builder: () => {
        this.valueDialog();
      },
      onDidDisappear: () => {
        this.dialogId = -1;
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(options)
      .then((id: number) => {
        this.dialogId = id;
      })
      .catch(() => {
      });
  }

  /** 完整值弹窗（内容区由公共组件承载，文本可长按自由选择复制）。 */
  @Builder
  valueDialog() {
    CustomContentDialogV2({
      primaryTitle: this.label,
      contentBuilder: () => {
        this.valueDialogContent();
      },
      buttons: [
        new AdvancedDialogV2Button({
          content: $r('app.string.close'),
          action: () => {
            this.closeDialog();
          }
        })
      ]
    })
      .constraintSize({ maxWidth: 480 })
  }

  /** 弹窗内容区：组件实例必须在 @Builder 上下文中创建（不能在普通回调里直接调用）。 */
  @Builder
  valueDialogContent() {
    SingleValueDialogContent({ value: this.value })
  }

  build() {
    // 值为空：不渲染该行，也不产生任何可点击 / 长按区域
    if (this.value.length > 0) {
      Row({ space: DesignTokens.space.tiny }) {
        Text(this.label)
          .fontSize(this.rowFontSize)
          .fontColor($r('app.color.text_secondary'))
        Text(this.value)
          .fontSize(this.rowFontSize)
          .fontColor($r('app.color.text_primary'))
          .textAlign(this.valueTextAlign())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .ellipsisMode(EllipsisMode.CENTER)
          .layoutWeight(1)
          .gesture(
            LongPressGesture()
              .onAction(() => {
                this.copyValue();
              })
          )
          .onClick(() => {
            this.openDialog();
          })
      }
      .width('100%')
      .padding({ top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
      .alignItems(VerticalAlign.Center)
      .id('single_line_value_row')
    }
  }
}
