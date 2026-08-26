import { common, OpenLinkOptions } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { TipsDialogV2, AdvancedDialogV2Button, promptAction } from '@kit.ArkUI';
import { DesignTokens } from '../common/DesignTokens';
import { ReceiveHistoryViewModel } from '../viewmodel/ReceiveHistoryViewModel';
import { ReceiveHistoryItemViewModel } from '../viewmodel/ReceiveHistoryItemViewModel';
import { copyText } from '../utils/ClipboardUtil';
import { getStringSync } from '../utils/ResourceUtil';

@Entry
@ComponentV2
struct ReceiveHistoryPage {
  @Local viewModel: ReceiveHistoryViewModel = new ReceiveHistoryViewModel();
  // 历史删除/清空确认弹窗（A 类 TipsDialogV2 带 checkTips）状态
  @Local deleteDialogTitle: string = ''
  @Local deleteDialogMessage: string = ''
  @Local deleteDialogCheck: boolean = false
  // 当前打开的弹窗 id（关闭时使用）
  private activeDialogId: number = -1
  // 确认回调（打开时暂存，确认时执行）
  private deleteConfirmCallback: (deleteFiles: boolean) => void = (_deleteFiles: boolean) => {
  }

  aboutToAppear(): void {
    this.withAnimation(() => {
      this.viewModel.loadHistory();
    });
  }

  private withAnimation(action: () => void): void {
    this.getUIContext()
      .animateTo({ duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn }, () => {
        action();
      });
  }

  // ── DialogV2 弹窗：历史删除/清空确认（A 类 TipsDialogV2 带 checkTips） ──

  private showHistoryDeleteConfirmDialog(title: ResourceStr, message: string,
    onConfirm: (deleteFiles: boolean) => void): void {
    this.deleteDialogTitle = typeof title === 'string' ? title : this.resolveTitleString(title);
    this.deleteDialogMessage = message;
    this.deleteDialogCheck = false;
    this.deleteConfirmCallback = onConfirm;
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.historyDeleteConfirmDialog();
      }
    };
    this.getUIContext().getPromptAction().openCustomDialog(dialogOptions).then((id: number) => {
      this.activeDialogId = id;
    }).catch(() => {
    });
  }

  private resolveTitleString(res: Resource): string {
    return getStringSync(this.getUIContext(), res);
  }

  private closeActiveDialog(): void {
    if (this.activeDialogId >= 0) {
      this.getUIContext().getPromptAction().closeCustomDialog(this.activeDialogId);
      this.activeDialogId = -1;
    }
  }

  @Builder
  historyDeleteConfirmDialog() {
    TipsDialogV2({
      imageRes: $r('sys.symbol.trash'),
      title: this.deleteDialogTitle,
      content: this.deleteDialogMessage,
      checkTips: $r('app.string.history_delete_files_label'),
      checked: this.deleteDialogCheck,
      onCheckedChange: (checked: boolean) => {
        this.deleteDialogCheck = checked;
      },
      primaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_cancel'),
        action: () => {
          this.closeActiveDialog();
        }
      }),
      secondaryButton: new AdvancedDialogV2Button({
        content: $r('app.string.dialog_confirm'),
        action: () => {
          this.deleteConfirmCallback(this.deleteDialogCheck);
          this.closeActiveDialog();
        }
      })
    })
  }

  // 解析带占位符（%s/%d）的字符串资源，用于确认弹窗的消息文本
  private formatHistoryMessage(resource: Resource, placeholder: string, value: string): string {
    let raw: string = getStringSync(this.getUIContext(), resource);
    if (raw.length === 0) {
      return '';
    }
    return raw.replace(placeholder, value);
  }

  // 文件类型图标：按 MIME 前缀分流（文本消息/图片/音频/视频/压缩包/其他文档）
  private getFileIcon(item: ReceiveHistoryItemViewModel): Resource {
    if (item.isMessage) {
      return $r('sys.symbol.text_aligncenter');
    }
    let type: string = item.fileType;
    if (type.startsWith('image/')) {
      return $r('sys.symbol.picture_fill');
    } else if (type.startsWith('audio/')) {
      return $r('sys.symbol.music_fill');
    } else if (type.startsWith('video/')) {
      return $r('sys.symbol.video_fill');
    } else if (type.startsWith('text/')) {
      return $r('sys.symbol.doc_text_fill');
    } else if (type === 'application/zip' || type.includes('rar') || type.includes('7z') ||
      type.includes('tar') || type.includes('gzip') || type.includes('bzip') || type.includes('x-xz')) {
      return $r('sys.symbol.doc_zipper_fill');
    }
    return $r('sys.symbol.doc_text_fill');
  }

  // 文件缺失提示（toast 展示失败静默忽略，不影响流程）
  private showFileMissingToast(): void {
    try {
      this.getUIContext().getPromptAction().showToast({
        message: $r('app.string.history_open_file_missing'),
        duration: 2000
      });
    } catch (_e) {
      // toast 展示失败不影响流程
    }
  }

  private isFileDefinitelyMissing(item: ReceiveHistoryItemViewModel): boolean {
    let checkTarget: string = item.path;
    try {
      return !fs.accessSync(checkTarget);
    } catch (e) {
      let err = e as BusinessError;
      return err.code === 13900002;
    }
  }

  // 通过系统文件管理器打开文件所在目录（filemanager://openDirectory）。
  // 打开前先确认文件未被移动/删除；缺失时提示而不打开目录。
  private openContainingFolder(item: ReceiveHistoryItemViewModel): void {
    let hostContext = this.getUIContext().getHostContext();
    if (hostContext === undefined) {
      return;
    }
    // 消息记录没有磁盘文件；路径为空时菜单已禁用，此处兜底不处理
    if (item.isMessage || item.path.length === 0) {
      return;
    }
    if (this.isFileDefinitelyMissing(item)) {
      this.showFileMissingToast();
      return;
    }
    let ctx = hostContext as common.UIAbilityContext;
    let openLinkOptions: OpenLinkOptions = {
      parameters: {
        'fileUri': fileUri.getUriFromPath(item.path)
      }
    };
    ctx.openLink('filemanager://openDirectory', openLinkOptions).catch(() => {
      // 打开失败（如系统不支持）——toast 提示，不发生崩溃
      this.getUIContext().getPromptAction().showToast({
        message: $r('app.string.history_open_dir_failed'),
        duration: 2000
      });
    });
  }

  // 复制文本消息内容到剪贴板
  private copyMessageText(text: string): void {
    copyText(text);
    try {
      this.getUIContext().getPromptAction().showToast({
        message: $r('app.string.copy_success'),
        duration: 1500
      });
    } catch (_e) {
      // toast 展示失败不影响流程
    }
  }

  // 列表项更多操作菜单：复制文本（消息）/ 打开所在目录（文件） / 删除记录
  @Builder
  historyMenuBuilder(item: ReceiveHistoryItemViewModel) {
    Menu() {
      if (item.isMessage && item.textContent.length > 0) {
        MenuItem({
          content: $r('app.string.copy'),
          startIcon: $r('sys.symbol.doc_plaintext_fill')
        })
          .onClick(() => {
            this.copyMessageText(item.textContent);
          })
      }
      MenuItem({
        content: $r('app.string.history_open_directory'),
        startIcon: $r('sys.symbol.folder')
      })
        .enabled(!item.isMessage && item.path.length > 0)
        .onClick(() => {
          this.openContainingFolder(item);
        })
      MenuItem({
        content: $r('app.string.delete_record'),
        startIcon: $r('sys.symbol.trash')
      })
        .contentFontColor($r('app.color.danger_red'))
        .onClick(() => {
          let message: string =
            this.formatHistoryMessage($r('app.string.history_delete_message_file'), '%s', item.fileName);
          this.showHistoryDeleteConfirmDialog(
            $r('app.string.history_delete_title'),
            message,
            (deleteFiles: boolean) => {
              this.withAnimation(() => {
                this.viewModel.deleteEntry(item.id, deleteFiles);
              });
            });
        })
    }
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_backward'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontColor([$r('app.color.text_primary')])
          .responseRegion({
            x: -12,
            y: -12,
            width: 48,
            height: 48
          })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })

        Text($r('app.string.receive_history_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
          .layoutWeight(1)

        if (this.viewModel.historyItems.length > 0) {
          Button($r('app.string.clear_history'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.danger_red'))
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              let countMsg: string = this.formatHistoryMessage($r('app.string.history_clear_message_count'),
                '%d', String(this.viewModel.historyItems.length));
              this.showHistoryDeleteConfirmDialog(
                $r('app.string.history_clear_title'),
                countMsg,
                (deleteFiles: boolean) => {
                  this.withAnimation(() => {
                    this.viewModel.clearAllHistory(deleteFiles);
                  });
                });
            })
        }
      }
      .width('100%')
      .height(DesignTokens.size.headerHeight)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      if (this.viewModel.historyItems.length === 0) {
        Column() {
          Text($r('app.string.receive_history_empty'))
            .fontSize(DesignTokens.font.subtitleM)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: DesignTokens.size.tabBarClearance })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Center)
      } else {
        Column() {
          List() {
            Repeat(this.viewModel.historyItems).each((ri: RepeatItem<ReceiveHistoryItemViewModel>) => {
              ListItem() {
                Row({ space: DesignTokens.space.sm }) {
                  // 左侧文件类型图标（居中 48×48 圆角块）；
                  // 图片且文件真实存在时显示缩略图预览，
                  // 视频生成缩略图 PixelMap 后显示，否则显示类型图标
                  Row() {
                    if (ri.item.previewUri.length > 0) {
                      Image(ri.item.previewUri)
                         .width(DesignTokens.size.thumbSm)
                         .height(DesignTokens.size.thumbSm)
                         .objectFit(ImageFit.Cover)
                         .borderRadius(DesignTokens.radius.md)
                     } else if (ri.item.previewPixelMap !== undefined) {
                       Image(ri.item.previewPixelMap)
                         .width(DesignTokens.size.thumbSm)
                         .height(DesignTokens.size.thumbSm)
                         .objectFit(ImageFit.Cover)
                         .borderRadius(DesignTokens.radius.md)
                     } else {
                       SymbolGlyph(this.getFileIcon(ri.item))
                         .fontSize(DesignTokens.font.displayS)
                        .fontColor([$r('app.color.text_secondary')])
                    }
                  }
                  .width(DesignTokens.size.thumbSm)
                  .height(DesignTokens.size.thumbSm)
                  .borderRadius(DesignTokens.radius.md)
                  .justifyContent(FlexAlign.Center)
                  .alignItems(VerticalAlign.Center)

                  // 三行文本：文件名 / 发送者·大小 / 时间
                  Column() {
                    Text(ri.item.isMessage && ri.item.textContent.length > 0 ? ri.item.textContent : ri.item.fileName)
                      .fontSize(DesignTokens.font.subtitleM)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })

                    Row({ space: DesignTokens.space.tiny }) {
                      Text(ri.item.senderAlias)
                        .fontSize(DesignTokens.font.bodyS)
                        .fontColor($r('app.color.text_secondary'))

                      if (ri.item.fileSize > 0) {
                        Text(ri.item.formattedSize)
                          .fontSize(DesignTokens.font.bodyS)
                          .fontColor($r('app.color.text_secondary'))
                      }

                      if (ri.item.savedToGallery) {
                        Image($r('app.media.ic_more_photoalbums'))
                          .width(DesignTokens.font.subtitleM)
                          .height(DesignTokens.font.subtitleM)
                      }
                    }
                    .margin({ top: DesignTokens.space.mini })

                    Text(ri.item.formattedTime)
                      .fontSize(DesignTokens.font.captionM)
                      .fontColor($r('app.color.text_tertiary'))
                      .margin({ top: DesignTokens.space.mini })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  // 更多操作菜单（下拉）：删除记录
                  SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
                    .fontSize(DesignTokens.font.subtitleM)
                    .fontColor([$r('app.color.text_secondary')])
                    .responseRegion({
                      x: -14,
                      y: -14,
                      width: 48,
                      height: 48
                    })
                    .bindMenu(this.historyMenuBuilder(ri.item))
                }
                .width('100%')
                .padding(DesignTokens.space.md)
                .backgroundColor($r('app.color.card_background'))
                .borderRadius(DesignTokens.radius.lg)
                .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
                .margin({ bottom: DesignTokens.space.tiny })
                .transition(
                  TransitionEffect.OPACITY
                    .combine(TransitionEffect.translate({ y: 20 }))
                    .animation({ duration: 300, curve: Curve.FastOutSlowIn })
                )
                // 行出现时懒加载视频缩略图（fire-and-forget，内部已捕获异常）
                .onAppear(() => {
                  ri.item.loadVideoPreview();
                })
              }
            }).key((item: ReceiveHistoryItemViewModel) => item.id)
          }
          .width('100%')
          .height('100%')
          .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.tiny })
          .divider({ strokeWidth: 0 })
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  pageTransition() {
    PageTransitionEnter(
      { type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
    PageTransitionEnter(
      { type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit(
      { type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit(
      { type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
  }
}
