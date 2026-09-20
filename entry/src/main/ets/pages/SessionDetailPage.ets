/**
 * SessionDetailPage.ets — 唯一通用会话详情页
 *
 * 一套协议无关的页面外壳，按旧传输页的卡片风格呈现：
 * 方向说明 → 设备卡 → 总进度与速度/剩余时间 → 逐文件进度卡 → 结果 → 时间线，
 * 底部固定操作按钮。协议差异仅经适配器展示描述符、能力声明与可选插槽表达。
 * 返回操作不取消会话；取消是独立显式操作。
 */

import { common } from '@kit.AbilityKit';
import { ComponentContent, SymbolGlyphModifier } from '@kit.ArkUI';
import { DesignTokens } from '../common/DesignTokens';
import { SessionDetailParams, SessionDetailViewModel } from '../viewmodel/SessionDetailViewModel';
import { SessionHeader } from '../views/transfer/SessionHeader';
import { SessionFileList } from '../views/transfer/SessionFileList';
import { SessionActions } from '../views/transfer/SessionActions';
import { SessionStatusBadge } from '../views/transfer/SessionStatusBadge';
import { SessionTimeline } from '../views/transfer/SessionTimeline';
import { GallerySaveDialogParams, buildGallerySaveDialog } from '../views/SaveToGalleryDialog';
import { VerifyPageParams, GallerySaveResult, MediaFileInfo } from '../model/Types';
import { isTerminalStage } from '../model/transfer/TransferSession';
import { hasDisplayText } from '../service/transfer/adapters/SessionAdapter';
import { consumeRecvMediaFiles, getServerFingerprint, saveMediaToGallery } from '../service/AppService';
import { formatSizeDetailed, formatSpeed, formatDuration } from '../utils/FormatUtil';
import { isUrl } from '../utils/IPValidator';
import { copyText } from '../utils/ClipboardUtil';
import { getStringSync } from '../utils/ResourceUtil';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:SessionDetail', '会话详情');

// 自动完成（自动返回）延迟：会话进入终态后约 2s 返回（与旧传输页一致）
const AUTO_FINISH_DELAY_MS: number = 2000;

@ComponentV2
export struct SessionDetailPage {
  @Param pageParam: Object = new Object()
  @Local viewModel: SessionDetailViewModel = new SessionDetailViewModel()
  private pathStack: NavPathStack = new NavPathStack()
  private context: common.UIAbilityContext | undefined = undefined
  // 相册保存弹窗 ComponentContent（与 openCustomDialog 使用同一实例，供 closeCustomDialog 关闭）
  private galleryContentNode: ComponentContent<GallerySaveDialogParams> | null = null
  // 相册保存弹窗是否可见：可见期间不自动返回，弹窗关闭后恢复
  private galleryDialogVisible: boolean = false
  // 因弹窗可见而被推迟的自动返回请求
  private autoFinishPending: boolean = false
  private autoFinishTimer: number = -1
  private autoFinishDone: boolean = false

  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let params: SessionDetailParams = this.pageParam as SessionDetailParams;
    this.viewModel.load(params.sessionId);
  }

  aboutToDisappear(): void {
    this.viewModel.unload();
    this.clearAutoFinishTimer();
  }

  private clearAutoFinishTimer(): void {
    if (this.autoFinishTimer >= 0) {
      clearTimeout(this.autoFinishTimer);
      this.autoFinishTimer = -1;
    }
  }

  /** 请求自动返回：弹窗可见时推迟到弹窗关闭后，已返回过则忽略。 */
  private requestAutoFinish(): void {
    if (this.autoFinishDone) {
      return;
    }
    if (this.galleryDialogVisible) {
      this.autoFinishPending = true;
      return;
    }
    this.clearAutoFinishTimer();
    this.autoFinishTimer = setTimeout(() => {
      this.autoFinishTimer = -1;
      if (this.autoFinishDone) {
        return;
      }
      this.autoFinishDone = true;
      logger.debug('auto finish: exit detail page');
      this.goBack();
    }, AUTO_FINISH_DELAY_MS);
  }

  /** 相册保存弹窗关闭：恢复被推迟的自动返回。 */
  private onGalleryDialogClosed(): void {
    this.galleryDialogVisible = false;
    if (this.autoFinishPending) {
      this.autoFinishPending = false;
      this.requestAutoFinish();
    }
  }

  /** 会话进入终态且「自动完成」开启时自动返回（文本消息阅读与弹窗可见时不返回）。 */
  @Monitor('viewModel.autoFinishRequested')
  onAutoFinishRequested(): void {
    if (!this.viewModel.autoFinishRequested) {
      return;
    }
    // 消费信号，避免重复触发
    this.viewModel.autoFinishRequested = false;
    this.requestAutoFinish();
  }

  /** 复制文本消息内容：写剪贴板成功后由协议适配器完成收尾（对照原 MTA 文本接收流程）。 */
  private copyTextMessage(): void {
    let text: string = this.viewModel.textPreview();
    if (text.length === 0) {
      return;
    }
    if (!copyText(text)) {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.copy_failed'), duration: 2000 });
      return;
    }
    // 协议收尾：文本消息会话经适配器 confirm 回接受 ack，不进入下载流程
    this.viewModel.confirm();
    this.getUIContext()
      .getPromptAction()
      .showToast({ message: $r('app.string.copy_success'), duration: 2000 });
  }

  /** 该会话可保存到相册的媒体文件：优先取适配器提供，缺失时回退既有接收媒体信号。 */
  private collectGalleryMediaFiles(): Array<MediaFileInfo> {
    let mediaFiles: Array<MediaFileInfo> = this.viewModel.galleryMediaFiles();
    if (mediaFiles.length > 0) {
      return mediaFiles;
    }
    let json: string = consumeRecvMediaFiles();
    if (json.length === 0) {
      return [];
    }
    try {
      return JSON.parse(json) as Array<MediaFileInfo>;
    } catch (e) {
      logger.warn('parse media files failed: ' + String(e));
      return [];
    }
  }

  /** 存相册：经既有 SaveToGalleryDialog（SaveButton 安全控件）完成保存（保留既有能力）。 */
  private saveToGallery(): void {
    let mediaFiles: Array<MediaFileInfo> = this.collectGalleryMediaFiles();
    if (mediaFiles.length === 0) {
      return;
    }
    this.openGalleryDialog(mediaFiles);
  }

  private buildMediaCountText(count: number): string {
    return getStringSync(this.getUIContext(), $r('app.string.gallery_save_media_count')).replace('%d',
      String(count));
  }

  private openGalleryDialog(mediaFiles: Array<MediaFileInfo>): void {
    let params = new GallerySaveDialogParams();
    params.mediaFiles = mediaFiles;
    params.mediaCountText = this.buildMediaCountText(mediaFiles.length);
    params.onPerformSave = (files: Array<MediaFileInfo>): Promise<GallerySaveResult> => {
      let context = this.context;
      if (context === undefined) {
        let failed: GallerySaveResult = { successCount: 0, failCount: files.length, errors: ['no context'] };
        return Promise.resolve(failed);
      }
      return saveMediaToGallery(context, files);
    };
    params.onSaveComplete = (result: GallerySaveResult): void => {
      this.showGallerySaveResultToast(result);
    };
    params.onDismiss = (): void => {
      this.onGalleryDialogClosed();
    };
    params.onCloseDialog = (): void => {
      this.closeGalleryDialog();
    };
    let contentNode = new ComponentContent(this.getUIContext(), wrapBuilder(buildGallerySaveDialog), params);
    // closeCustomDialog 必须复用与 openCustomDialog 相同的 ComponentContent 实例
    this.galleryContentNode = contentNode;
    params.contentNode = contentNode;
    // 弹窗可见期间不自动返回：先取消已排定的自动返回，弹窗关闭后恢复
    this.clearAutoFinishTimer();
    this.galleryDialogVisible = true;
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
    this.onGalleryDialogClosed();
  }

  private showGallerySaveResultToast(result: GallerySaveResult): void {
    let message: ResourceStr = result.successCount > 0 ? $r('app.string.gallery_save_success') :
      $r('app.string.gallery_save_failed');
    this.getUIContext()
      .getPromptAction()
      .showToast({ message: message, duration: 2000 });
  }

  /** 指纹验证：跳转验证页（本地指纹 ↔ 对端指纹）。 */
  private openVerify(): void {
    let params: VerifyPageParams = {
      localFingerprint: getServerFingerprint(),
      remoteFingerprint: this.viewModel.peerFingerprint()
    };
    this.pathStack.pushPathByName('VerifyPage', params);
  }

  private stageTextOf(): ResourceStr {
    let session = this.viewModel.session;
    if (session === undefined) {
      return '';
    }
    return session.stageText;
  }

  /** 离散阶段文案是否非空（资源对象视为非空）。 */
  private hasStageText(): boolean {
    let text = this.stageTextOf();
    return typeof text === 'string' ? text.length > 0 : true;
  }

  /** 对端标题解析为可拼接字符串：字符串直出，资源经当前 UI 上下文解析。 */
  private peerTitleText(): string {
    let title = this.viewModel.display.peerTitle;
    if (typeof title === 'string') {
      return title;
    }
    return getStringSync(this.getUIContext(), title);
  }

  /** 是否展示底部动作区（会话或历史摘要存在即展示：待确认 / 进行中 / 终态各有一组动作）。 */
  private hasActions(): boolean {
    return this.viewModel.isLoaded();
  }

  /** 历史只读摘要行：标签（左）+ 值（右）。 */
  @Builder
  summaryRow(label: ResourceStr, value: ResourceStr) {
    Row({ space: DesignTokens.space.sm }) {
      Text(label)
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
      Text(value)
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 文件数与总大小文案（复用发送页「共 N 个文件，大小」资源）。 */
  private fileCountSizeText(): string {
    return getStringSync(this.getUIContext(), $r('app.string.send_file_count_total'))
      .replace('%d', String(this.viewModel.historyFileCount()))
      .replace('%s', formatSizeDetailed(this.viewModel.historyTotalBytes()));
  }

  /**
   * 历史会话只读摘要：会话已终结并从注册表回收后，仍可按历史条目标识进入详情，
   * 展示对端/方向/来源协议/结果/时间/文件数与总大小；逐文件进度与时间线不保留。
   */
  @Builder
  historySummaryCard() {
    Column({ space: DesignTokens.space.sm }) {
      this.summaryRow($r('app.string.session_detail_source_label'), this.viewModel.historySourceLabel())

      Row({ space: DesignTokens.space.sm }) {
        Text($r('app.string.session_detail_result_label'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        SessionStatusBadge({ stage: this.viewModel.historyStage(), stageText: '' })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      this.summaryRow($r('app.string.session_detail_time_label'), this.viewModel.historyTimeText())
      this.summaryRow($r('app.string.session_detail_files'), this.fileCountSizeText())
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
    .alignItems(HorizontalAlign.Start)
    .id('session_detail_history_summary')
  }

  /** 标题栏菜单：指纹验证与保存到相册（次级入口，不占用底部动作区）。 */
  private buildTitleMenus(): Array<NavigationMenuItem> {
    let items: Array<NavigationMenuItem> = [];
    if (this.viewModel.canVerify()) {
      items.push({
        value: $r('app.string.verify_button'),
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.checkmark_shield_fill')),
        action: () => {
          this.openVerify();
        }
      });
    }
    if (this.viewModel.canSaveToGallery() && !this.viewModel.hasTextPreview()) {
      items.push({
        value: $r('app.string.session_detail_save_gallery'),
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.square_and_arrow_down')),
        action: () => {
          this.saveToGallery();
        }
      });
    }
    return items;
  }

  /** 取消为独立显式操作：先确认再执行（对齐旧传输页的中止确认）。 */
  private confirmCancel(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.session_detail_cancel_confirm_title'),
      message: $r('app.string.session_detail_cancel_confirm_message'),
      primaryButton: {
        value: $r('app.string.dialog_cancel'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.dialog_confirm'),
        action: () => {
          this.viewModel.cancelTransfer();
        }
      }
    });
  }

  /** 终态返回：仅退出详情页，不改变会话状态（返回不取消会话）。 */
  private goBack(): void {
    this.pathStack.pop();
  }

  /** 打开文本消息内容中的链接（仅内容为 URL 时可达）。 */
  private openTextLink(): void {
    let url: string = this.viewModel.textPreview().trim();
    let context = this.context;
    if (context === undefined || url.length === 0) {
      return;
    }
    context.openLink(url).catch((e: Object): void => {
      logger.warn('open text link failed: ' + String(e));
    });
  }

  /** 已传/总字节文案（不可用时以占位符呈现，对齐旧传输页口径）。 */
  private bytesText(): string {
    let session = this.viewModel.session;
    if (session === undefined) {
      return getStringSync(this.getUIContext(), $r('app.string.session_detail_placeholder'));
    }
    return formatSizeDetailed(session.bytesSent) + ' / ' + formatSizeDetailed(session.totalBytes);
  }

  private speedText(): string {
    if (this.viewModel.speed <= 0) {
      return getStringSync(this.getUIContext(), $r('app.string.session_detail_placeholder'));
    }
    return formatSpeed(this.viewModel.speed);
  }

  private etaText(): string {
    if (this.viewModel.etaSeconds < 0) {
      return getStringSync(this.getUIContext(), $r('app.string.session_detail_placeholder'));
    }
    return formatDuration(this.viewModel.etaSeconds);
  }

  /** 总进度与速度/剩余时间（字节口径；无字节进度协议回退离散阶段文案）。 */
  @Builder
  progressBlock() {
    if (this.viewModel.hasByteProgress()) {
      Column({ space: DesignTokens.space.tiny }) {
        // 汇总行：文件数 + 总大小（左）与整体进度（右）
        Row({ space: DesignTokens.space.sm }) {
          Text($r('app.string.send_file_count_total', this.viewModel.files.length,
            formatSizeDetailed(this.viewModel.session?.totalBytes ?? 0)))
            .fontSize(DesignTokens.font.subtitleM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Text(Math.round(this.viewModel.percent()) + '%')
            .fontSize(DesignTokens.font.subtitleM)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.accent_blue'))
            .id('session_detail_overall_percent')
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Progress({ value: this.viewModel.percent(), total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(DesignTokens.size.progressBarHeight)
          .color($r('app.color.accent_blue'))
          .backgroundColor($r('app.color.border_light'))

        // 已传/总字节 + 实时速度 + 预计剩余时间（不可用时占位符）
        Row({ space: DesignTokens.space.md }) {
          Text(getStringSync(this.getUIContext(), $r('app.string.session_detail_bytes')) + ' ' + this.bytesText())
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
          Text(getStringSync(this.getUIContext(), $r('app.string.session_detail_speed')) + ' ' + this.speedText())
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
          Text(getStringSync(this.getUIContext(), $r('app.string.session_detail_eta')) + ' ' + this.etaText())
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
      }
      .width('100%')
    } else if (this.hasStageText()) {
      Text(this.stageTextOf())
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    }
  }

  /** 终态结果文案（完成 / 失败原因）。 */
  @Builder
  resultBlock() {
    Column({ space: DesignTokens.space.tiny }) {
      if (this.viewModel.session !== undefined && isTerminalStage(this.viewModel.session.stage)) {
        if ((this.viewModel.session.errorMessage).length > 0) {
          Text(this.viewModel.session.errorMessage)
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.danger_red'))
            .width('100%')
            .id('session_detail_error_message')
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 文本消息预览卡片（文本会话不展示文件清单与字节进度）：
   * 可滚动文本区 + 内容为 URL 时的「打开链接」入口。
   */
  @Builder
  textPreviewCard() {
    Column({ space: DesignTokens.space.md }) {
      Text($r('app.string.clipboard_from_device', this.peerTitleText()))
        .fontSize(DesignTokens.font.subtitleM)
        .fontColor($r('app.color.clipboard_text'))
        .width('100%')
        .id('session_detail_text_title')

      // 文本卡片：内容超出时可滚动查看（不再限制显示行数）
      Column() {
        Scroll() {
          Text(this.viewModel.textPreview())
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .lineHeight(20)
            .width('100%')
            .id('session_detail_text_content')
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
        .width('100%')
        .constraintSize({ maxHeight: 240 })
      }
      .width('100%')
      .padding(DesignTokens.space.md)
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(DesignTokens.radius.lg)
      .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })

      if (isUrl(this.viewModel.textPreview())) {
        Button($r('app.string.open_link'))
          .width('100%')
          .height(DesignTokens.size.thumbSm)
          .backgroundColor($r('app.color.accent_blue'))
          .fontColor($r('app.color.text_on_color'))
          .borderRadius(DesignTokens.radius.max)
          .onClick(() => {
            this.openTextLink();
          })
          .id('session_detail_text_open_link')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    NavDestination() {
      Column() {
        Scroll() {
          Column({ space: DesignTokens.space.md }) {
            // ── 方向说明（实时会话与历史只读摘要共用；由展示描述符驱动） ──
            if (this.viewModel.isLoaded() && hasDisplayText(this.viewModel.display.directionLabel)) {
              Text(this.viewModel.display.directionLabel)
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .id('session_detail_direction')
            }

            if (this.viewModel.session !== undefined) {
              // ── 设备卡 ──
              SessionHeader({
                display: this.viewModel.display,
                stage: this.viewModel.session.stage,
                stageText: this.stageTextOf(),
                peerIp: this.viewModel.session.peer.ip ?? ''
              })

              if (this.viewModel.hasTextPreview()) {
                // ── 文本消息：文本预览卡片（不展示文件清单与字节进度） ──
                this.textPreviewCard()
              } else {
                // ── 总进度与速度/剩余时间 ──
                this.progressBlock()

                // ── 文件清单（逐文件进度卡 + 状态徽标） ──
                Text($r('app.string.session_detail_files'))
                  .fontSize(DesignTokens.font.subtitleS)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                SessionFileList({
                  files: this.viewModel.files,
                  showByteProgress: this.viewModel.hasByteProgress()
                })
              }

              // ── 结果 ──
              this.resultBlock()

              // ── 时间线 ──
              Text($r('app.string.session_detail_timeline'))
                .fontSize(DesignTokens.font.subtitleS)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
              SessionTimeline({ events: this.viewModel.timeline })
            } else if (this.viewModel.isReadOnly()) {
              // ── 历史条目：只读摘要（设备卡 + 摘要卡，无逐文件进度与时间线） ──
              SessionHeader({
                display: this.viewModel.display,
                stage: this.viewModel.historyStage(),
                stageText: '',
                peerIp: ''
              })
              this.historySummaryCard()
              // 逐文件进度与时间线在会话回收后不再保留，给出明确说明而非空白
              Text($r('app.string.session_detail_history_note'))
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .id('session_detail_history_note')
            } else {
              // 会话不存在（无效会话标识）：展示明确提示而非空白占位
              Text($r('app.string.session_detail_unavailable'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: DesignTokens.space.xl })
                .width('100%')
                .textAlign(TextAlign.Center)
            }
          }
          .width('100%')
          .padding(DesignTokens.space.md)
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)

        // ── 底部固定操作区（按状态与能力渲染；同一时刻只呈现一组动作） ──
        if (this.hasActions()) {
          SessionActions({
            canConfirm: this.viewModel.canConfirm(),
            canDecline: this.viewModel.canDecline(),
            canCancel: this.viewModel.canCancel(),
            canRetry: this.viewModel.canRetry(),
            canCopyText: this.viewModel.hasTextPreview() && this.viewModel.canConfirm(),
            onConfirm: () => {
              this.viewModel.confirm();
            },
            onDecline: () => {
              this.viewModel.decline();
            },
            onCancel: () => {
              this.confirmCancel();
            },
            onRetry: () => {
              this.viewModel.retry();
            },
            onCopyText: () => {
              this.copyTextMessage();
            },
            onBack: () => {
              this.goBack();
            }
          })
            .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.md })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
    }
    .title($r('app.string.session_detail_title'), { backgroundColor: $r('app.color.page_background') })
    // 指纹验证与保存到相册移入标题栏菜单（次级入口，不占用底部动作区）
    .menus(this.buildTitleMenus())
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}

// 路由表引用：SessionDetailPageBuilder(name, param)
@Builder
export function SessionDetailPageBuilder(name: string, param: Object) {
  SessionDetailPage({ pageParam: param })
}
