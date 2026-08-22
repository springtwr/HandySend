import { HttpLogsViewModel, SaveLogsResult } from '../viewmodel/HttpLogsViewModel';
import { LogEntry } from '../model/Types';
import { DesignTokens } from '../common/DesignTokens';
import { common } from '@kit.AbilityKit';

/**
 * HttpLogsPage
 * HTTP 日志页。整改为 MVVM 纯组装：
 * - 创建 ViewModel 实例（@Local + @ObservedV2 精准观测）
 * - aboutToAppear 调 vm.loadLogs
 * - onClick 调 vm.copyLogs / vm.clearLogs（Toast 留 Page 因需 UIContext）
 * - build 只渲染，无业务逻辑、无 AppService 调用、无剪贴板逻辑
 *
 * 列表项类型：方案 A（简洁折中）— Page 仍 import LogEntry 用于 Repeat 类型注解。
 * LogEntry 是只读 DTO，Page 不修改单条 entry。详见 VM 文件决策注释。
 */
@Entry
@ComponentV2
struct HttpLogsPage {
  @Local viewModel: HttpLogsViewModel = new HttpLogsViewModel();
  // 官方 MVVM V2 范式：Page（View）持有 UIAbilityContext，传给 VM 命令（如 saveLogs(context)）。
  // getHostContext() 在组件生命周期内稳定，设为私有字段避免重复获取。
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    this.viewModel.loadLogs();
  }

  aboutToDisappear(): void {
    // 退订日志变化通知，避免页面销毁后仍持有引用导致无意义刷新/内存泄漏
    this.viewModel.dispose();
  }

  /**
   * 保存日志（View 层职责：调 VM 命令、按结果弹 Toast）。
   * 文件 I/O 与 picker 调用已下沉到 AppCore.saveLogsToFile，VM 仅编排并返回 SaveLogsResult，
   * 本方法不触碰 fs/picker，context 由 Page 持有并传入，只负责 UI 反馈。
   * 应用名 %s 的 Resource→字符串转换属 UI 侧，在此用 resourceManager 完成
   * （showToast 不递归替换嵌套 Resource 参数）。
   */
  private async saveLogs(): Promise<void> {
    let result: SaveLogsResult = await this.viewModel.saveLogs(this.context);
    switch (result) {
      case 'empty':
        this.getUIContext()
          .getPromptAction()
          .showToast({ message: $r('app.string.no_logs'), duration: 2000 });
        break;
      case 'success':
        let appNameStr: string = this.context.resourceManager.getStringSync($r('app.string.EntryAbility_label').id);
        this.getUIContext()
          .getPromptAction()
          .showToast({ message: $r('app.string.save_success', appNameStr), duration: 2000 });
        break;
      case 'failed':
        this.getUIContext()
          .getPromptAction()
          .showToast({ message: $r('app.string.save_failed'), duration: 2000 });
        break;
      case 'cancelled':
        // 用户取消选择器，不弹 Toast
        break;
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

        Text($r('app.string.http_logs_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
          .layoutWeight(1)

        // 保存按钮（调起系统文件选择器，把日志写入用户指定路径，无需申请存储权限）
        Text($r('app.string.save_logs_button'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.accent_blue'))
          .margin({ right: DesignTokens.space.md })
          .responseRegion({
            x: -8,
            y: -8,
            width: 40,
            height: 40
          })
          .onClick(() => {
            this.saveLogs();
          })

        // 清空按钮
        Text($r('app.string.clear_logs_button'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.danger_red'))
          .responseRegion({
            x: -8,
            y: -8,
            width: 40,
            height: 40
          })
          .onClick(() => {
            this.viewModel.clearLogs();
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      if (this.viewModel.logEntries.length === 0) {
        Column() {
          Text($r('app.string.no_logs'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        // 正序展示（最早在上）；日志主要用于开发者 debug，不做倒序等展示优化。
        List() {
          Repeat(this.viewModel.logEntries).each((ri: RepeatItem<LogEntry>) => {
            ListItem() {
              Row() {
                Text(new Date(ri.item.timestamp).toLocaleTimeString())
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('25%')

                Text('[' + ri.item.level + ']')
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor(ri.item.level === 'error' ? $r('app.color.danger_red') :
                    ri.item.level === 'warn' ? $r('app.color.warning_orange') : $r('app.color.text_secondary'))
                  .width('12%')
                  .maxLines(1)
                  .textAlign(TextAlign.Start)

                Text(ri.item.message)
                  .fontSize(DesignTokens.font.bodyS)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                  .maxLines(2)
                  .wordBreak(WordBreak.BREAK_ALL)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .padding({
                left: DesignTokens.space.md,
                right: DesignTokens.space.md,
                top: 6,
                bottom: 6
              })
            }
          }).key((item: LogEntry, index: number) => index.toString())
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
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
