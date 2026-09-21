import { common, OpenLinkOptions } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { TipsDialogV2, CustomContentDialogV2, AdvancedDialogV2Button, promptAction, uiObserver } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  HdsNavigationMenuContentOptions,
  HdsNavigationMenuItemOptions
} from '@kit.UIDesignKit';
import { buildImmersiveTitleBar } from '../common/ImmersiveTitleBar';
import { DesignTokens } from '../common/DesignTokens';
import { getPageContentMaxWidth, getPageMargin } from '../common/Breakpoints';
import { ReceiveHistoryViewModel } from '../viewmodel/ReceiveHistoryViewModel';
import { ReceiveHistoryItemViewModel } from '../viewmodel/ReceiveHistoryItemViewModel';
import { copyText } from '../utils/ClipboardUtil';
import { readTextOfLocation } from '../utils/FileTextUtil';
import { getStringSync } from '../utils/ResourceUtil';
import { getFileTypeIconResource } from '../utils/FileTypeIconUtil';

@ComponentV2
export struct ReceiveHistoryPage {
  // 系统宽度断点（随窗口尺寸变化自动刷新，宽屏限宽用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: ReceiveHistoryViewModel = new ReceiveHistoryViewModel();
  // NavDestination 返回栈（onReady 注入）
  // 列表滚动控制器：绑定到子页面容器以驱动标题栏滚动模糊
  private scroller: Scroller = new Scroller()
  // 历史删除/清空确认弹窗（A 类 TipsDialogV2 带 checkTips）状态
  @Local deleteDialogTitle: string = ''
  @Local deleteDialogMessage: string = ''
  @Local deleteDialogCheck: boolean = false
  // 当前打开的弹窗 id（关闭时使用）
  private activeDialogId: number = -1
  // 文本消息完整内容弹窗：打开时暂存当前条目的完整文本，关闭时清空
  @Local fullTextDialogContent: string = ''
  // 全文弹窗内容不可用（文件缺失/读取失败）：弹窗内给出明确提示
  @Local fullTextDialogUnavailable: boolean = false
  // 确认回调（打开时暂存，确认时执行）
  private deleteConfirmCallback: (deleteFiles: boolean) => void = (_deleteFiles: boolean) => {
  }
  // 标题省略位置策略：系统 API >= 24 支持多行行中省略（末尾字符可见），
  // 低版本设备降级为行尾省略；版本能力在页面创建时确定一次
  private ellipsisMode: EllipsisMode =
    deviceInfo.sdkApiVersion >= 24 ? EllipsisMode.MULTILINE_CENTER : EllipsisMode.END

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

  /**
   * 标题栏结束端入口：清空接收历史。无历史时返回空菜单，标题栏结束端不占位。
   * 图标以资源引用传入、档位留空（组件默认档位），尺寸与返回箭头相当；
   * 返回箭头由组件承载，保持系统默认尺寸。
   */
  private buildTitleMenu(): HdsNavigationMenuContentOptions {
    if (this.viewModel.historyItems.length === 0) {
      return { value: [] };
    }
    let clearItem: HdsNavigationMenuItemOptions = {
      content: {
        icon: $r('sys.symbol.trash'),
        label: $r('app.string.clear_history'),
        action: () => {
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
        }
      }
    };
    let items: Array<HdsNavigationMenuItemOptions> = [clearItem];
    return { value: items };
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
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(dialogOptions)
      .then((id: number) => {
        this.activeDialogId = id;
      })
      .catch(() => {
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
    // 宽屏下限制弹窗最大宽度，避免铺满过宽
      .constraintSize({ maxWidth: 480 })
      .id('receive_history_delete_dialog')
  }

  // 解析带占位符（%s/%d）的字符串资源，用于确认弹窗的消息文本
  private formatHistoryMessage(resource: Resource, placeholder: string, value: string): string {
    let raw: string = getStringSync(this.getUIContext(), resource);
    if (raw.length === 0) {
      return '';
    }
    return raw.replace(placeholder, value);
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

  // 复制文本类条目的内容：读取文件本身（不再依赖偏好存储中的正文字段）
  private copyItemText(item: ReceiveHistoryItemViewModel): void {
    let content = readTextOfLocation(item.path);
    if (content === undefined) {
      this.getUIContext().getPromptAction().showToast({
        message: $r('app.string.session_file_preview_unavailable'),
        duration: 2000
      });
      return;
    }
    this.copyMessageText(content);
  }

  // 复制已读取的文本内容到剪贴板
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

  // ── DialogV2 弹窗：文本消息完整内容（B 类 CustomContentDialogV2） ──

  // 打开文本弹窗：仅文本类条目且可读时有效，其余情况不产生任何副作用
  private openFullTextDialog(item: ReceiveHistoryItemViewModel): void {
    if (!item.canViewFullText) {
      return;
    }
    let content = readTextOfLocation(item.path);
    this.fullTextDialogUnavailable = content === undefined;
    this.fullTextDialogContent = content !== undefined ? content : '';
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.fullTextDialog();
      },
      onDidDisappear: () => {
        // 弹窗关闭（含点击遮罩/返回键）后清空暂存内容
        this.fullTextDialogContent = '';
        this.fullTextDialogUnavailable = false;
      }
    };
    this.getUIContext()
      .getPromptAction()
      .openCustomDialog(dialogOptions)
      .then((id: number) => {
        this.activeDialogId = id;
      })
      .catch(() => {
      });
  }

  // 关闭文本弹窗并清空暂存内容
  private closeFullTextDialog(): void {
    this.closeActiveDialog();
    this.fullTextDialogContent = '';
  }

  @Builder
  fullTextDialog() {
    CustomContentDialogV2({
      primaryTitle: $r('app.string.history_text_content_title'),
      contentBuilder: () => {
        this.fullTextDialogContentBuilder();
      },
      buttons: [
        new AdvancedDialogV2Button({
          content: $r('app.string.dialog_cancel'),
          action: () => {
            this.closeFullTextDialog();
          }
        }),
        new AdvancedDialogV2Button({
          content: $r('app.string.copy'),
          action: () => {
            this.copyMessageText(this.fullTextDialogContent);
            this.closeFullTextDialog();
          }
        })
      ]
    })
    // 宽屏下限制弹窗最大宽度，避免铺满过宽
      .constraintSize({ maxWidth: 480 })
  }

  // 弹窗内容区：完整文本，超出最大高度时在弹窗内滚动阅读；不可用时明确提示
  @Builder
  fullTextDialogContentBuilder() {
    if (this.fullTextDialogUnavailable) {
      Text($r('app.string.session_file_preview_unavailable'))
        .width('100%')
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
    } else {
      Scroll() {
        Text(this.fullTextDialogContent)
          .width('100%')
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.Start)
          .wordBreak(WordBreak.BREAK_ALL)
      }
      .width('100%')
      .constraintSize({ maxHeight: 320 })
      .scrollBar(BarState.Auto)
    }
  }

  // 列表项更多操作菜单：复制文本（文本类，读取文件）/ 打开所在目录 / 删除记录
  @Builder
  historyMenuBuilder(item: ReceiveHistoryItemViewModel) {
    Menu() {
      if (item.canViewFullText) {
        MenuItem({
          content: $r('app.string.copy'),
          startIcon: $r('sys.symbol.doc_plaintext_fill')
        })
          .onClick(() => {
            this.copyItemText(item);
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

  // 内容最大宽度：按断点取值；平板竖屏收紧至 800；窄屏返回 '100%' 全宽
  private getContentMaxWidth(): Length {
    return getPageContentMaxWidth(this.breakpointInfo.widthBreakpoint,
      this.breakpointInfo.heightBreakpoint, deviceInfo.deviceType);
  }

  build() {
    HdsNavDestination() {
      Row() {
        Column() {
          if (this.viewModel.historyItems.length === 0) {
            Column() {
              Text($r('app.string.receive_history_empty'))
                .fontSize(DesignTokens.font.subtitleM)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: DesignTokens.size.tabBarClearance })
                .id('receive_history_empty')
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Start)
            .alignItems(HorizontalAlign.Center)
          } else {
            Column() {
              List({ scroller: this.scroller }) {
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
                          Image(getFileTypeIconResource(ri.item.isMessage, ri.item.fileName, ri.item.fileType))
                            .width(DesignTokens.size.thumbSm)
                            .height(DesignTokens.size.thumbSm)
                        }
                      }
                      .width(DesignTokens.size.thumbSm)
                      .height(DesignTokens.size.thumbSm)
                      .borderRadius(DesignTokens.radius.md)
                      .justifyContent(FlexAlign.Center)
                      .alignItems(VerticalAlign.Center)

                      // 三行文本：文件名 / 发送者·大小 / 时间
                      Column() {
                        Text(ri.item.fileName)
                          .fontSize(DesignTokens.font.subtitleM)
                          .fontWeight(FontWeight.Medium)
                          .fontColor($r('app.color.text_primary'))
                          // 最多两行，超出时按系统能力选择行中/行尾省略；
                          // 按字符断行保证无空格长串（如哈希文件名）的末尾字符可见
                          .maxLines(2)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .ellipsisMode(this.ellipsisMode)
                          .wordBreak(WordBreak.BREAK_ALL)

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
                        .margin({ top: DesignTokens.space.xxs })

                        Text(ri.item.formattedTime)
                          .fontSize(DesignTokens.font.captionM)
                          .fontColor($r('app.color.text_tertiary'))
                          .margin({ top: DesignTokens.space.xxs })
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
                    .id('receive_history_item')
                    // 点击文本消息记录查看完整内容；文件类/空内容记录由判定拦截，不产生任何副作用
                    .onClick(() => {
                      this.openFullTextDialog(ri.item);
                    })
                    // 点击态反馈：仅可查看完整文本的条目启用系统点击缩放反馈
                    .clickEffect(ri.item.canViewFullText ? { level: ClickEffectLevel.LIGHT } : null)
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
                })
                  .key((item: ReceiveHistoryItemViewModel) => item.id)
                  // 开启虚拟滚动：仅加载可见区与预加载区内的条目，控制长历史列表的渲染与内存开销
                  .virtualScroll()
              }
              .width('100%')
              .height('100%')
              .edgeEffect(EdgeEffect.Spring)
              // 滚动容器不裁剪：滚动中的条目可绘制到标题栏区域内，使毛玻璃背板有内容可透出
              .clip(false)
              // 与不裁剪配套：预加载条目一并参与绘制，避免条目离开视口即被回收，
              // 表现为内容尚未到达标题栏区域便消失
              .cachedCount(3, true)
              .padding({
                left: getPageMargin(this.breakpointInfo.widthBreakpoint),
                right: getPageMargin(this.breakpointInfo.widthBreakpoint),
                top: DesignTokens.space.tiny
              })
              .divider({ strokeWidth: 0 })
              .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
            }
            .width('100%')
            .layoutWeight(1)
            .width('100%')
            .height('100%')
            .backgroundColor($r('app.color.page_background'))
            .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
          }
        }
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: this.getContentMaxWidth() })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      // 内容从顶部排列，避免内容不满一屏时被交叉轴默认居中
      .alignItems(VerticalAlign.Top)
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    // 子页面容器背景覆盖至标题栏区域：无内容经过时标题栏底色与页面背景一致，不露出系统默认底色
    .backgroundColor($r('app.color.page_background'))
    .titleBar(buildImmersiveTitleBar({
      title: $r('app.string.receive_history_title'),
      menu: this.buildTitleMenu()
    }))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

// 路由表引用：ReceiveHistoryPageBuilder(name, param)
@Builder
export function ReceiveHistoryPageBuilder(_name: string, _param: Object) {
  ReceiveHistoryPage()
}
