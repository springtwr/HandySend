/**
 * SessionMetaSection.ets — 详情页完整信息区块
 *
 * 分区展示传输详情（性能 + 结果与错误合并为一个分区）、本机设备与标识；
 * 时间点信息由「时间线」区块承载，此处不重复展示。
 * 对实时会话与历史条目统一取数（数据来自 SessionDetailViewModel.meta），
 * 缺省字段按统一占位降级，不产生空白错位。
 */

import { AdvancedDialogV2Button, CustomContentDialogV2, promptAction } from '@kit.ArkUI';
import { DesignTokens } from '../../common/DesignTokens';
import { SessionStage } from '../../model/transfer/TransferSession';
import { SessionDetailMeta, canCopyMetaValue } from '../../viewmodel/SessionDetailViewModel';
import { formatDuration, formatSizeDetailed, formatSpeed } from '../../utils/FormatUtil';
import { copyText } from '../../utils/ClipboardUtil';
import { SessionStatusBadge } from './SessionStatusBadge';

@ComponentV2
export struct SessionMetaSection {
  @Require @Param meta: SessionDetailMeta
  @Require @Param stage: SessionStage

  // 完整值弹窗展示的标题与文本（值非空时点击值区域弹出）
  @Local dialogValueTitle: ResourceStr = ''
  @Local dialogValueText: string = ''
  // 弹窗内容区可用宽度（vp，由内容文本 onAreaChange 获取，用于判定单行/多行对齐）
  @Local dialogContentWidth: number = 0
  private valueDialogId: number = -1

  /** 空值统一降级为占位符。 */
  private valueOrPlaceholder(value: string): ResourceStr {
    return value.length > 0 ? value : $r('app.string.session_detail_placeholder');
  }

  /** 速度文案（非正值视为不可得）。 */
  private speedText(bytesPerSec: number): ResourceStr {
    return bytesPerSec > 0 ? formatSpeed(bytesPerSec) : $r('app.string.session_detail_placeholder');
  }

  /** 耗时文案（毫秒转秒；不可得为占位）。 */
  private durationText(durationMs: number): ResourceStr {
    return durationMs > 0 ? formatDuration(durationMs / 1000) : $r('app.string.session_detail_placeholder');
  }

  /** 本机 IP 与接口名组合文案。 */
  private localNetworkText(): ResourceStr {
    let ip: string = this.meta.localIp;
    let name: string = this.meta.localInterfaceName;
    if (ip.length === 0 && name.length === 0) {
      return $r('app.string.session_detail_placeholder');
    }
    if (name.length === 0) {
      return ip;
    }
    if (ip.length === 0) {
      return name;
    }
    return ip + ' · ' + name;
  }

  /** 分区标题。 */
  @Builder
  sectionTitle(title: ResourceStr) {
    Text(title)
      .fontSize(DesignTokens.font.subtitleS)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
  }

  /** 信息行：标签（左）+ 值（右，单行；放不下时系统原生中间省略）。 */
  @Builder
  metaRow(label: ResourceStr, value: ResourceStr) {
    Row({ space: DesignTokens.space.sm }) {
      Text(label)
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
      Text(value)
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .ellipsisMode(EllipsisMode.CENTER)
        .layoutWeight(1)
        .onClick(() => {
          // 值非空即可点击弹出完整值弹窗；空值（含占位）不触发
          if (typeof value === 'string') {
            if (value.length > 0) {
              this.openValueDialog(label, value);
            }
          }
        })
    }
    .width('100%')
    .padding({ top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
    .alignItems(VerticalAlign.Top)
  }

  /** 可复制信息行：标签 + 值（单行，放不下时系统原生中间省略）；长按值区域复制（空值不复制，无可见复制入口）。 */
  @Builder
  metaCopyRow(label: ResourceStr, value: string) {
    Row({ space: DesignTokens.space.sm }) {
      Text(label)
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
      Text(this.valueOrPlaceholder(value))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .ellipsisMode(EllipsisMode.CENTER)
        .layoutWeight(1)
        .gesture(
          LongPressGesture()
            .onAction(() => {
              if (canCopyMetaValue(value)) {
                this.copyMetaValue(value);
              }
            })
        )
        .onClick(() => {
          // 值非空即可点击弹出完整值弹窗；空值（占位）不触发
          if (value.length > 0) {
            this.openValueDialog(label, value);
          }
        })
        .id('session_meta_copy_value')
    }
    .width('100%')
    .padding({ top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
    .alignItems(VerticalAlign.Top)
  }

  /** 复制完整值并给出成功/失败提示。 */
  private copyMetaValue(value: string): void {
    if (copyText(value)) {
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

  /** 点击值区域：弹出完整值弹窗（弹窗文本可长按自由选择复制）。 */
  private openValueDialog(title: ResourceStr, value: string): void {
    this.dialogValueTitle = title;
    this.dialogValueText = value;
    let options: promptAction.CustomDialogOptions = {
      builder: () => {
        this.valueDialog();
      },
      onDidDisappear: () => {
        this.dialogValueTitle = '';
        this.dialogValueText = '';
        this.valueDialogId = -1;
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(options)
      .then((id: number) => {
        this.valueDialogId = id;
      })
      .catch(() => {
      });
  }

  private closeValueDialog(): void {
    if (this.valueDialogId >= 0) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.valueDialogId);
      this.valueDialogId = -1;
    }
    this.dialogValueTitle = '';
    this.dialogValueText = '';
  }

  /** 完整值弹窗（自定义内容区，文本可长按自由选择复制）。 */
  @Builder
  valueDialog() {
    CustomContentDialogV2({
      primaryTitle: this.dialogValueTitle,
      contentBuilder: () => {
        this.valueDialogContent();
      },
      buttons: [
        new AdvancedDialogV2Button({
          content: $r('app.string.close'),
          action: () => {
            this.closeValueDialog();
          }
        })
      ]
    })
      .constraintSize({ maxWidth: 480 })
  }

  /** 完整值弹窗内容区：长按可选中的完整值文本（单行居中、多行左对齐）。 */
  @Builder
  valueDialogContent() {
    Scroll() {
      Text(this.dialogValueText)
        .width('100%')
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .textAlign(this.valueDialogTextAlign())
        .wordBreak(WordBreak.BREAK_ALL)
        .copyOption(CopyOptions.LocalDevice)
        .onAreaChange((_oldValue: Area, newValue: Area) => {
          // 记录内容区可用宽度（vp），供单行/多行对齐判定
          if (typeof newValue.width === 'number') {
            this.dialogContentWidth = newValue.width;
          }
        })
    }
    .width('100%')
    .constraintSize({ maxHeight: 320 })
    .scrollBar(BarState.Auto)
  }

  /** 完整值弹窗文本对齐：单行居中、多行左对齐（按单行测量宽度与实际可用宽度比较判定）。 */
  private valueDialogTextAlign(): TextAlign {
    if (this.dialogContentWidth <= 0) {
      return TextAlign.Start;
    }
    let singleLineWidthPx: number = this.getUIContext().getMeasureUtils().measureText({
      textContent: this.dialogValueText,
      fontSize: DesignTokens.font.bodyM
    });
    let availableWidthPx: number = this.getUIContext().vp2px(this.dialogContentWidth);
    return singleLineWidthPx <= availableWidthPx ? TextAlign.Center : TextAlign.Start;
  }

  /** 信息区块容器。 */
  @Builder
  sectionCard() {
    Column({ space: DesignTokens.space.mini }) {
      this.sectionTitle($r('app.string.session_meta_performance_title'))
      this.metaRow($r('app.string.session_meta_total_size_label'), formatSizeDetailed(this.meta.totalBytes))
      this.metaRow($r('app.string.session_meta_duration_label'), this.durationText(this.meta.durationMs))
      this.metaRow($r('app.string.session_meta_average_speed_label'),
        this.speedText(this.meta.averageSpeedBps))
      this.metaRow($r('app.string.session_meta_peak_speed_label'), this.speedText(this.meta.peakSpeedBps))

      // 「结果」行并入传输详情区块，作为普通信息行（间距与其它信息行一致，不再以分隔线切分）
      Row({ space: DesignTokens.space.sm }) {
        Text($r('app.string.session_detail_result_label'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        SessionStatusBadge({ stage: this.stage, stageText: '' })
      }
      .width('100%')
      .padding({ top: DesignTokens.space.mini, bottom: DesignTokens.space.mini })
      .alignItems(VerticalAlign.Center)
      if (this.meta.errorCode.length > 0) {
        this.metaRow($r('app.string.session_meta_error_code_label'), this.meta.errorCode)
      }
      if (this.meta.errorMessage.length > 0) {
        this.metaRow($r('app.string.session_meta_error_message_label'), this.meta.errorMessage)
      }

      // 「本机」分组标题：与上方「传输」区块之间留出略大于普通行距的间距。
      // 普通相邻信息行距约 6vp（行内上下 2 + 容器 space 2）；此处额外 6vp，使区块间距约 10vp。
      Column() {
        this.sectionTitle($r('app.string.session_meta_local_title'))
      }
      .width('100%')
      .margin({ top: DesignTokens.space.xxs + DesignTokens.space.mini })
      this.metaRow($r('app.string.local_device_alias'), this.valueOrPlaceholder(this.meta.localAlias))
      this.metaRow($r('app.string.session_meta_local_network_label'), this.localNetworkText())
      this.metaCopyRow($r('app.string.session_meta_protocol_session_id_label'),
        this.meta.protocolSessionId)
      this.metaCopyRow($r('app.string.transfer_detail_session_id'),
        this.meta.sessionId)
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
    .alignItems(HorizontalAlign.Start)
    .id('session_detail_meta_section')
  }

  build() {
    this.sectionCard()
  }
}
