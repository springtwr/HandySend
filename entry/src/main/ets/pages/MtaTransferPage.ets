/**
 * MtaTransferPage.ets — MTA 专用传输页
 *
 * 发送模式：复用发送页暂存文件，经 MtaTransferViewModel 驱动会话级进度与结果；
 * 接收模式：展示互传联盟设备发起的接收请求（发送方/文件信息）并提供接受/拒绝与进度。
 * 视觉结构与 LocalSend TransferPage 对齐（扁平布局：方向行 + 对端设备卡 + 文件清单 + 进度 + 底部按钮），
 * 标题统一使用 transfer_title，尺寸/颜色/圆角/间距一律取 DesignTokens 与资源。
 */

import { uiObserver } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { DesignTokens } from '../common/DesignTokens';
import { getMaxContentWidth, getPageMargin, isTabletPortrait } from '../common/Breakpoints';
import {
  MtaTransferViewModel,
  MtaTransferPageParams,
  MTA_MODE_SEND,
  MTA_MODE_RECEIVE
} from '../viewmodel/MtaTransferViewModel';
import { TransferFileDescriptor } from '../model/Types';
import { formatSizeDetailed } from '../utils/FormatUtil';
import { getStringSync } from '../utils/ResourceUtil';
import { TransferDeviceCard } from '../views/TransferDeviceCard';
import { copyText } from '../utils/ClipboardUtil';

@ComponentV2
export struct MtaTransferPage {
  // 系统宽度断点（随窗口尺寸变化自动刷新，宽屏限宽用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: MtaTransferViewModel = new MtaTransferViewModel()
  // 路由参数（经 MtaTransferPageBuilder 传入）
  @Param pageParam: Object = new Object()
  // NavDestination 返回栈（onReady 注入）
  private pathStack: NavPathStack = new NavPathStack()

  aboutToAppear(): void {
    let params: MtaTransferPageParams = this.pageParam as MtaTransferPageParams;
    if (params !== undefined && params.mode === MTA_MODE_SEND) {
      this.viewModel.loadSend(params, this.getUIContext().getHostContext() as common.UIAbilityContext);
    } else {
      this.viewModel.loadReceive();
    }
  }

  aboutToDisappear(): void {
    this.viewModel.destroy();
  }

  // 内容最大宽度：按断点取值；平板竖屏收紧至 800；窄屏返回 '100%' 全宽
  private getContentMaxWidth(): Length {
    let maxWidth: number = getMaxContentWidth(this.breakpointInfo.widthBreakpoint);
    if (isTabletPortrait(deviceInfo.deviceType, this.breakpointInfo.heightBreakpoint)) {
      maxWidth = 800;
    }
    if (maxWidth === 0) {
      return '100%';
    }
    return maxWidth;
  }

  // 文件清单总大小（字节，从文件元数据累加）
  private totalFileSize(): number {
    let total: number = 0;
    for (let i = 0; i < this.viewModel.files.length; i++) {
      total = total + this.viewModel.files[i].size;
    }
    return total;
  }

  // 总体进度文案：标签 + 百分比（与 TransferFileList 风格一致）
  private progressOverallText(): string {
    let label: string = getStringSync(this.getUIContext(), $r('app.string.transfer_progress_overall'));
    if (label.length === 0) {
      return Math.round(this.viewModel.progressPercent) + '%';
    }
    return label + ' ' + Math.round(this.viewModel.progressPercent) + '%';
  }

  // 字节进度文案：已传输 / 总量
  private progressBytesText(): string {
    return `${formatSizeDetailed(this.viewModel.currentBytes)} / ${formatSizeDetailed(this.viewModel.totalBytes)}`;
  }

  private resultText(): ResourceStr {
    if (this.viewModel.errorMessage.length > 0) {
      return this.viewModel.errorMessage;
    }
    return this.viewModel.mode === MTA_MODE_RECEIVE ?
      $r('app.string.mta_transfer_received') : $r('app.string.mta_transfer_completed');
  }

  @Builder
  infoRow(label: ResourceStr, value: ResourceStr) {
    Row() {
      Text(label)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .width('38%')
      Text(value)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .wordBreak(WordBreak.BREAK_ALL)
    }
    .width('100%')
    .padding({ top: DesignTokens.space.xxs, bottom: DesignTokens.space.xxs })
    .constraintSize({ minHeight: DesignTokens.size.thumbSm })
  }

  // 方向行：发送「发送到 {对端}」，接收「来自 {发送方}」
  @Builder
  buildDirectionRow() {
    if (this.viewModel.mode === MTA_MODE_SEND) {
      Text($r('app.string.transfer_direction_to', this.viewModel.targetAlias))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .id('mta_transfer_direction_to')
    } else {
      Text($r('app.string.transfer_direction_from', this.viewModel.requestSender))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .id('mta_transfer_direction_from')
    }
  }

  // 对端设备卡：本地化来源徽标 + 品牌徽标（未知品牌回退 Android）
  @Builder
  buildDeviceSection() {
    TransferDeviceCard({
      alias: this.viewModel.targetAlias,
      ip: '',
      deviceType: this.viewModel.deviceType,
      deviceModel: this.viewModel.deviceModel,
      leadingBadge: $r('app.string.mta_source_badge'),
      showLeadingBadge: true,
      badgeText: this.viewModel.badgeText
    })
  }

  // 已选文件清单（发送文件模式）：头部汇总 + 逐条文件行（MTA 无逐文件进度，不渲染进度条）
  @Builder
  buildFileListSection() {
    Column() {
      Row({ space: DesignTokens.space.sm }) {
        Text($r('app.string.transfer_file_count', this.viewModel.files.length))
          .fontSize(DesignTokens.font.subtitleM)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        if (this.totalFileSize() > 0) {
          Text(formatSizeDetailed(this.totalFileSize()))
            .fontSize(DesignTokens.font.subtitleM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: DesignTokens.space.tiny })

      ForEach(this.viewModel.files, (file: TransferFileDescriptor) => {
        Row() {
          Text(file.fileName)
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .maxLines(1)
            .layoutWeight(1)
          Text(formatSizeDetailed(file.size))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ left: DesignTokens.space.sm })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding(DesignTokens.space.sm)
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(DesignTokens.radius.md)
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.tiny })
        .id('mta_transfer_file_item')
      }, (file: TransferFileDescriptor) => file.fileId + '_' + file.fileName + '_' + file.size)
    }
    .width('100%')
  }

  // 接收请求信息（接收模式）：文件 / 数量 / 大小 / 状态
  @Builder
  buildReceiveRequestSection() {
    Column() {
      Text($r('app.string.mta_transfer_receive_title'))
        .fontSize(DesignTokens.font.subtitleM)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: DesignTokens.space.tiny })
        .id('mta_receive_request_title')

      this.infoRow($r('app.string.mta_transfer_file_label'), this.viewModel.requestFileName)
      this.infoRow($r('app.string.mta_transfer_file_count_label'), String(this.viewModel.requestFileCount))
      this.infoRow($r('app.string.mta_transfer_total_size_label'), formatSizeDetailed(this.viewModel.requestTotalSize))
      this.infoRow($r('app.string.mta_transfer_stage_label'), this.viewModel.stageText)
    }
    .width('100%')
  }

  // 进度区：总体进度（强调色粗体）+ 进度条 + 阶段/字节/文件名 + 结果
  @Builder
  buildProgressSection() {
    Column() {
      Text(this.progressOverallText())
        .fontSize(DesignTokens.font.subtitleM)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.accent_blue'))
        .width('100%')
        .id('mta_transfer_progress_overall')

      Progress({ value: this.viewModel.progressPercent, total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(4)
        .color($r('app.color.accent_blue'))
        .backgroundColor($r('app.color.border_light'))
        .margin({ top: DesignTokens.space.tiny, bottom: DesignTokens.space.tiny })

      Text(this.viewModel.stageText)
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Text(this.progressBytesText())
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: DesignTokens.space.mini })

      if (this.viewModel.currentFileName.length > 0) {
        Text(this.viewModel.currentFileName)
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .maxLines(1)
          .margin({ top: DesignTokens.space.mini })
      }

      if (this.viewModel.finished) {
        Text(this.resultText())
          .fontSize(DesignTokens.font.bodyM)
          .fontColor(this.viewModel.errorMessage.length > 0 ? $r('app.color.danger_red') :
            $r('app.color.accent_blue'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: DesignTokens.space.sm })
      }
    }
    .width('100%')
  }

  // 接收到的文本展示（可复制）
  @Builder
  buildTextSection() {
    Column() {
      Row({ space: DesignTokens.space.tiny }) {
        Text($r('app.string.mta_transfer_received_text'))
          .fontSize(DesignTokens.font.subtitleM)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Button($r('app.string.mta_transfer_copy_text'))
          .height(DesignTokens.size.inlineButton)
          .fontSize(DesignTokens.font.bodyS)
          .backgroundColor($r('app.color.accent_blue_bg'))
          .fontColor($r('app.color.ip_blue_text'))
          .borderRadius(DesignTokens.radius.sm)
          .onClick(() => {
            if (copyText(this.viewModel.receivedText)) {
              this.getUIContext().getPromptAction().showToast({ message: $r('app.string.copy_success') });
            }
          })
          .id('mta_transfer_copy_text_btn')
      }
      .width('100%')

      Text(this.viewModel.receivedText)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .wordBreak(WordBreak.BREAK_ALL)
        .maxLines(12)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding(DesignTokens.space.tiny)
        .backgroundColor($r('app.color.page_background'))
        .borderRadius(DesignTokens.radius.sm)
        .margin({ top: DesignTokens.space.tiny })
    }
    .width('100%')
  }

  // 返回按钮（单个动作、主色、60% 宽）
  @Builder
  backButton(btnId: string) {
    Button() {
      Row({ space: DesignTokens.space.tiny }) {
        Text($r('app.string.mta_transfer_back'))
          .fontSize(DesignTokens.font.subtitleM)
          .fontColor($r('app.color.text_on_color'))
      }
      .justifyContent(FlexAlign.Center)
    }
    .width('60%')
    .height(DesignTokens.size.thumbSm)
    .backgroundColor($r('app.color.accent_blue'))
    .borderRadius(DesignTokens.radius.max)
    .margin({ top: DesignTokens.space.tiny })
    .onClick(() => {
      this.pathStack.pop();
    })
    .id(btnId)
  }

  // 取消按钮（单个动作、危险色、60% 宽）
  @Builder
  cancelButton(btnId: string, action: () => void) {
    Button() {
      Row({ space: DesignTokens.space.tiny }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontColor([$r('app.color.text_on_color')])
        Text($r('app.string.mta_transfer_cancel'))
          .fontSize(DesignTokens.font.subtitleM)
          .fontColor($r('app.color.text_on_color'))
      }
      .justifyContent(FlexAlign.Center)
    }
    .width('60%')
    .height(DesignTokens.size.thumbSm)
    .backgroundColor($r('app.color.danger_red'))
    .borderRadius(DesignTokens.radius.max)
    .margin({ top: DesignTokens.space.tiny })
    .onClick(() => {
      action();
    })
    .id(btnId)
  }

  // 底部操作按钮：与 TransferPage 风格一致（thumbSm 高、radius.max、主色/危险色）
  @Builder
  buildActionSection() {
    Column() {
      if (this.viewModel.mode === MTA_MODE_SEND) {
        if (this.viewModel.isSending) {
          this.cancelButton('mta_transfer_cancel_btn', () => {
            this.viewModel.cancel().then((): void => {
            }).catch((): void => {
            });
            this.pathStack.pop();
          })
        } else {
          this.backButton('mta_transfer_back_btn')
        }
      } else {
        if (this.viewModel.awaitingConfirm) {
          // 接受/拒绝成对按钮：负向在左、正向在右，各占一半
          Row({ space: DesignTokens.space.md }) {
            Button() {
              Row({ space: DesignTokens.space.tiny }) {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(DesignTokens.font.subtitleL)
                  .fontColor([$r('app.color.danger_red')])
                Text($r('app.string.mta_transfer_reject'))
                  .fontSize(DesignTokens.font.subtitleM)
                  .fontColor($r('app.color.danger_red'))
              }
              .justifyContent(FlexAlign.Center)
            }
            .layoutWeight(1)
            .height(DesignTokens.size.thumbSm)
            .backgroundColor($r('app.color.card_background'))
            .border({
              width: DesignTokens.component.borderSlim,
              color: $r('app.color.danger_red'),
              style: BorderStyle.Solid
            })
            .borderRadius(DesignTokens.radius.max)
            .onClick(() => {
              this.viewModel.rejectRequest();
            })
            .id('mta_transfer_reject_btn')

            Button() {
              Row({ space: DesignTokens.space.tiny }) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(DesignTokens.font.subtitleL)
                  .fontColor([$r('app.color.text_on_color')])
                Text($r('app.string.mta_transfer_accept'))
                  .fontSize(DesignTokens.font.subtitleM)
                  .fontColor($r('app.color.text_on_color'))
              }
              .justifyContent(FlexAlign.Center)
            }
            .layoutWeight(1)
            .height(DesignTokens.size.thumbSm)
            .backgroundColor($r('app.color.accent_blue'))
            .borderRadius(DesignTokens.radius.max)
            .onClick(() => {
              this.viewModel.acceptRequest();
            })
            .id('mta_transfer_accept_btn')
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: DesignTokens.space.tiny })
        } else if (this.viewModel.isReceiving) {
          this.cancelButton('mta_transfer_cancel_receive_btn', () => {
            this.viewModel.cancelReceive();
          })
        } else {
          this.backButton('mta_transfer_receive_back_btn')
        }
      }
    }
    .width('100%')
  }

  build() {
    NavDestination() {
      Column() {
        Scroll() {
          Row() {
            Column({ space: DesignTokens.space.sm }) {
              this.buildDirectionRow()

              if (this.viewModel.mode === MTA_MODE_SEND) {
                this.buildDeviceSection()
                if (this.viewModel.files.length > 0) {
                  this.buildFileListSection()
                }
              } else {
                this.buildReceiveRequestSection()
              }

              if (this.viewModel.isSending || this.viewModel.isReceiving || this.viewModel.finished) {
                this.buildProgressSection()
              }

              if (this.viewModel.receivedText.length > 0) {
                this.buildTextSection()
              }

              this.buildActionSection()
            }
            .width(this.getContentMaxWidth())
            .padding({
              left: getPageMargin(this.breakpointInfo.widthBreakpoint),
              right: getPageMargin(this.breakpointInfo.widthBreakpoint),
              bottom: DesignTokens.space.lg
            })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }
        .layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .title($r('app.string.transfer_title'), { backgroundColor: $r('app.color.page_background') })
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}

// 路由表引用：MtaTransferPageBuilder(name, param)
@Builder
export function MtaTransferPageBuilder(_name: string, _param: Object) {
  MtaTransferPage({ pageParam: _param })
}
