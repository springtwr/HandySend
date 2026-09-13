/**
 * MtaTransferPage.ets — MTA 专用传输页
 *
 * 发送模式：复用发送页暂存文件，经 MtaTransferViewModel 驱动会话级进度与结果；
 * 接收模式：展示互传联盟设备发起的接收请求（发送方/文件信息）并提供接受/拒绝与进度。
 * 视觉结构与 LocalSend TransferPage 对齐（扁平布局：方向行 + 对端设备卡 + 文件清单 + 进度 + 底部按钮），
 * 标题统一使用 transfer_title，尺寸/颜色/圆角/间距一律取 DesignTokens 与资源。
 */

import { ComponentContent, uiObserver } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { DesignTokens } from '../common/DesignTokens';
import { getPageContentMaxWidth, getPageMargin } from '../common/Breakpoints';
import {
  MtaTransferViewModel,
  MtaTransferPageParams,
  MTA_MODE_SEND,
  MTA_MODE_RECEIVE,
  MediaFileInfo,
  GallerySaveResult,
  ReceivedFileEntry
} from '../viewmodel/MtaTransferViewModel';
import { TransferFileDescriptor } from '../model/Types';
import { formatSizeDetailed } from '../utils/FormatUtil';
import { getStringSync } from '../utils/ResourceUtil';
import { TransferDeviceCard } from '../views/TransferDeviceCard';
import { GallerySaveDialogParams, buildGallerySaveDialog } from '../views/SaveToGalleryDialog';
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
  // 相册保存弹窗 ComponentContent（与 openCustomDialog 使用同一实例，供 closeCustomDialog 关闭）
  private galleryContentNode: ComponentContent<GallerySaveDialogParams> | null = null
  // 上一次弹窗是否可见（用于检测 @Trace 变化，避免重复打开）
  private prevGalleryDialogVisible: boolean = false

  aboutToAppear(): void {
    let params: MtaTransferPageParams = this.pageParam as MtaTransferPageParams;
    if (params !== undefined && params.mode === MTA_MODE_SEND) {
      this.viewModel.loadSend(params, this.getUIContext().getHostContext() as common.UIAbilityContext);
    } else {
      this.viewModel.loadReceive(this.getUIContext().getHostContext() as common.UIAbilityContext);
      // 接收态：注入页面关闭回调，用户拒绝后自动返回上一页
      // （pathStack 在 onReady 注入，回调在用户交互时触发，此时已就绪）
      this.viewModel.setCloseCallback((): void => {
        this.pathStack.pop();
      });
    }
  }

  // 相册保存弹窗可见性变化：打开弹窗（与局域网 TransferPage 一致）
  @Monitor('viewModel.galleryDialogVisible')
  onGalleryDialogVisibleChanged(): void {
    if (this.viewModel.galleryDialogVisible && !this.prevGalleryDialogVisible) {
      this.prevGalleryDialogVisible = true;
      this.openGalleryDialog();
    } else if (!this.viewModel.galleryDialogVisible && this.prevGalleryDialogVisible) {
      this.prevGalleryDialogVisible = false;
    }
  }

  // 媒体数量描述文案（图片/视频分列，二者并存时合并展示）
  private buildMediaCountText(): string {
    let imageCount: number = 0;
    let videoCount: number = 0;
    let files: Array<MediaFileInfo> = this.viewModel.pendingMediaFiles;
    for (let i = 0; i < files.length; i++) {
      if (files[i].isImage) {
        imageCount = imageCount + 1;
      } else {
        videoCount = videoCount + 1;
      }
    }
    if (imageCount > 0 && videoCount > 0) {
      return getStringSync(this.getUIContext(), $r('app.string.gallery_save_media_count'))
        .replace('%d', String(imageCount)).replace('%d', String(videoCount));
    } else if (imageCount > 0) {
      return getStringSync(this.getUIContext(), $r('app.string.gallery_save_image_count'))
        .replace('%d', String(imageCount));
    } else if (videoCount > 0) {
      return getStringSync(this.getUIContext(), $r('app.string.gallery_save_video_count'))
        .replace('%d', String(videoCount));
    }
    return '';
  }

  // 打开相册保存弹窗（ComponentContent + wrapBuilder，默认 customStyle=true）
  private openGalleryDialog(): void {
    let params = new GallerySaveDialogParams();
    params.mediaFiles = this.viewModel.pendingMediaFiles;
    params.mediaCountText = this.buildMediaCountText();
    params.onPerformSave = (mediaFiles: Array<MediaFileInfo>): Promise<GallerySaveResult> => {
      return this.viewModel.performGallerySave(mediaFiles);
    };
    params.onSaveComplete = (result: GallerySaveResult): void => {
      this.viewModel.onGallerySaveComplete(result);
      this.showGallerySaveResultToast(result);
    };
    params.onDismiss = (): void => {
      this.viewModel.onGalleryDialogDismiss();
    };
    params.onCloseDialog = (): void => {
      this.closeGalleryDialog();
    };
    let contentNode = new ComponentContent(this.getUIContext(), wrapBuilder(buildGallerySaveDialog), params);
    // closeCustomDialog 必须复用与 openCustomDialog 相同的 ComponentContent 实例
    this.galleryContentNode = contentNode;
    params.contentNode = contentNode;
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(contentNode, {
        autoCancel: true,
        alignment: DialogAlignment.Center
      })
      .catch(() => {
      });
  }

  private closeGalleryDialog(): void {
    if (this.galleryContentNode !== null) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.galleryContentNode);
      this.galleryContentNode = null;
    }
  }

  // 保存结果反馈（成功/失败/部分成功）
  private showGallerySaveResultToast(result: GallerySaveResult): void {
    let message: string = '';
    if (result.failCount === 0 && result.successCount > 0) {
      message = getStringSync(this.getUIContext(), $r('app.string.gallery_save_success'));
    } else if (result.successCount === 0) {
      message = getStringSync(this.getUIContext(), $r('app.string.gallery_save_failed'));
    } else {
      let partial: string = getStringSync(this.getUIContext(), $r('app.string.gallery_save_partial'));
      message = partial.replace('%d', String(result.successCount)).replace('%d',
        String(result.successCount + result.failCount));
    }
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  aboutToDisappear(): void {
    this.viewModel.destroy();
  }

    // 内容最大宽度：按断点取值；平板竖屏收紧至 800；窄屏返回 '100%' 全宽
  private getContentMaxWidth(): Length {
    return getPageContentMaxWidth(this.breakpointInfo.widthBreakpoint,
      this.breakpointInfo.heightBreakpoint, deviceInfo.deviceType);
  }

  // 接收模式是否已有对端/请求信息（未收到请求时不渲染设备卡与文件列表，避免空白卡片）
  private hasReceivePeer(): boolean {
    return this.viewModel.requestSender.length > 0 || this.viewModel.awaitingConfirm ||
      this.viewModel.isReceiving || this.viewModel.finished;
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
    // 接收结果记忆态：优先展示记忆的结果文案（失败为错误信息，成功回退到完成文案）
    if (this.viewModel.completedSticky) {
      if (this.viewModel.completedText.length > 0) {
        return this.viewModel.completedText;
      }
      return $r('app.string.mta_transfer_received');
    }
    if (this.viewModel.errorMessage.length > 0) {
      return this.viewModel.errorMessage;
    }
    return this.viewModel.mode === MTA_MODE_RECEIVE ?
      $r('app.string.mta_transfer_received') : $r('app.string.mta_transfer_completed');
  }

  // 接收结果是否为失败态（用于结果文案强调色）
  private isResultFailed(): boolean {
    if (this.viewModel.completedSticky) {
      return this.viewModel.completedText.length > 0;
    }
    return this.viewModel.errorMessage.length > 0;
  }

  // 接收完成后展示的文件条目：记忆态用记忆副本，否则用当前快照
  private receiveListFiles(): Array<ReceivedFileEntry> {
    return this.viewModel.completedSticky ? this.viewModel.completedFiles : this.viewModel.receivedFiles;
  }

  // 接收确认/下载中的文件列表占位名：多文件时在主文件名后追加省略号
  private placeholderFileName(): string {
    let name = this.viewModel.requestFileName;
    if (name.length === 0) {
      return '';
    }
    return this.viewModel.requestFileCount > 1 ? name + '...' : name;
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

  // 对端设备卡：接收模式展示发送方名称与「互传」来源徽标；发送模式展示品牌徽标
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

  // 汇总行文件数量：发送=待发文件数（文本发送为 0，不展示），接收=请求文件数
  private summaryFileCount(): number {
    return this.viewModel.mode === MTA_MODE_SEND ?
      this.viewModel.files.length : this.viewModel.requestFileCount;
  }

  // 汇总行总大小：发送=文件清单累加，接收=请求总大小
  private summaryTotalSize(): number {
    return this.viewModel.mode === MTA_MODE_SEND ?
      this.totalFileSize() : this.viewModel.requestTotalSize;
  }

  // 汇总行：文件数量 + 总大小（左对齐）+ 总进度（强调色粗体右对齐），对齐 TransferFileList 头部
  @Builder
  buildTransferSummary() {
    Row({ space: DesignTokens.space.sm }) {
      if (this.summaryFileCount() > 0) {
        Text($r('app.string.transfer_file_count', this.summaryFileCount()))
          .fontSize(DesignTokens.font.subtitleM)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        if (this.summaryTotalSize() > 0) {
          Text(formatSizeDetailed(this.summaryTotalSize()))
            .fontSize(DesignTokens.font.subtitleM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      Blank().layoutWeight(1)
      Text(this.progressOverallText())
        .fontSize(DesignTokens.font.subtitleM)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.accent_blue'))
        .id('mta_transfer_progress_overall')
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  // 接收模式文件列表：完成后逐条展示实际接收文件（名 + 大小）；确认/下载中以主文件名占位
  @Builder
  buildReceiveFileList() {
    Column() {
      if (this.viewModel.receiveCompleted || this.viewModel.completedSticky) {
        ForEach(this.receiveListFiles(), (entry: ReceivedFileEntry, index: number) => {
          Row() {
            Text(entry.name)
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .maxLines(1)
              .layoutWeight(1)
            Text(formatSizeDetailed(entry.size))
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
          .id('mta_transfer_received_file_item')
        }, (entry: ReceivedFileEntry, index: number) => index + '_' + entry.name + '_' + entry.size)
      } else if (this.viewModel.awaitingConfirm || this.viewModel.isReceiving) {
        if (this.placeholderFileName().length > 0) {
          Row() {
            Text(this.placeholderFileName())
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .maxLines(1)
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding(DesignTokens.space.sm)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.md)
          .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
          .margin({ top: DesignTokens.space.tiny })
          .id('mta_transfer_placeholder_file_item')
        }
      }
    }
    .width('100%')
  }

  // 已选文件清单（发送文件模式）：逐条文件行（MTA 无逐文件进度，不渲染进度条；
  // 文件数与总大小已上移至汇总行）
  @Builder
  buildFileListSection() {
    Column() {
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

  // 实时速度 + 预计剩余时间（右对齐，与 TransferFileList 一致；非字节传输阶段为占位符）
  @Builder
  buildSpeedRow() {
    if (this.viewModel.isSending || this.viewModel.isReceiving) {
      Row({ space: DesignTokens.space.md }) {
        Blank().layoutWeight(1)
        Text(this.viewModel.speedText)
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .id('mta_transfer_speed_text')
        Text($r('app.string.transfer_eta_label'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_tertiary'))
          .id('mta_transfer_eta_label')
        Text(this.viewModel.etaText)
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .id('mta_transfer_eta_text')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: DesignTokens.space.mini })
    }
  }

  // 实际连接频段与受限提示（发送端建组后 / 接收端连接后展示；频段未知时不展示）
  @Builder
  buildBandSection() {
    if (this.viewModel.bandText.length > 0) {
      Column() {
        Text(this.viewModel.bandText)
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .id('mta_transfer_band_text')
        if (this.viewModel.bandWarning.length > 0) {
          Text(this.viewModel.bandWarning)
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.danger_red'))
            .width('100%')
            .margin({ top: DesignTokens.space.mini })
            .id('mta_transfer_band_warning')
        }
      }
      .width('100%')
      .margin({ top: DesignTokens.space.mini })
    }
  }

  // 进度区：进度条 + 阶段/字节/文件名 + 结果（总进度与速度行已上移至汇总行下方）
  @Builder
  buildProgressSection() {
    Column() {
      Progress({ value: this.viewModel.progressPercent, total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(DesignTokens.size.progressBarHeight)
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

      if (this.viewModel.finished || this.viewModel.completedSticky) {
        Text(this.resultText())
          .fontSize(DesignTokens.font.bodyS)
          .fontColor(this.isResultFailed() ? $r('app.color.danger_red') : $r('app.color.success_green'))
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
        .padding(DesignTokens.space.md)
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(DesignTokens.radius.lg)
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
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
        // 内容区：可滚动，占据剩余空间
        Scroll() {
          Row() {
            Column({ space: DesignTokens.space.sm }) {
              this.buildDirectionRow()

              if (this.viewModel.mode === MTA_MODE_SEND) {
                this.buildDeviceSection()
                this.buildTransferSummary()
                this.buildSpeedRow()
                this.buildBandSection()
                if (this.viewModel.files.length > 0) {
                  this.buildFileListSection()
                }
              } else {
                // 接收模式：对端设备卡 + 汇总行 + 文件列表（请求缺失时不渲染，避免出现空白卡片）
                if (this.hasReceivePeer()) {
                  this.buildDeviceSection()
                  this.buildTransferSummary()
                  this.buildSpeedRow()
                  this.buildBandSection()
                  this.buildReceiveFileList()
                }
              }

              if (this.viewModel.isSending || this.viewModel.isReceiving || this.viewModel.finished ||
                this.viewModel.completedSticky) {
                this.buildProgressSection()
              }

              if (this.viewModel.receivedText.length > 0) {
                this.buildTextSection()
              }
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

        // 底部操作区：固定置底，不随内容滚动而移出视野
        Row() {
          Column() {
            this.buildActionSection()
          }
          .width(this.getContentMaxWidth())
          .padding({
            left: getPageMargin(this.breakpointInfo.widthBreakpoint),
            right: getPageMargin(this.breakpointInfo.widthBreakpoint),
            bottom: DesignTokens.space.tiny
          })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
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
