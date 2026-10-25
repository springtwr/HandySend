import { uiObserver } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { buildImmersiveTitleBar } from '../common/ImmersiveTitleBar';
import { ShareLinkViewModel } from '../viewmodel/ShareLinkViewModel';
import { WebAccessEntryCard } from '../views/WebAccessEntryCard';
import { DesignTokens } from '../common/DesignTokens';
import { EmptyState } from '../components/EmptyState';
import { getPageContentMaxWidth, getPageMargin, WidthBreakpointType } from '../common/Breakpoints';
import { WEB_DOWNLOAD_KEY } from '../service/transfer/adapters/WebDownloadAdapter';
import { WEB_UPLOAD_KEY } from '../service/transfer/adapters/WebUploadAdapter';
import { cancelSessions, confirmDisableDirection } from '../service/transfer/ProtocolDisableGuard';
import { TransferSession } from '../model/transfer/TransferSession';
import { getStringSync } from '../utils/ResourceUtil';

// 二维码边长（vp）：sm/md 取设计令牌基准，lg/xl 逐档放大，避免大屏上相对过小
const QR_SIZE_BY_BREAKPOINT: WidthBreakpointType<number> =
  new WidthBreakpointType<number>(DesignTokens.size.qrCodeSize, 240, 280, 320)

/**
 * ShareLinkPage — 网页传输面板（MVVM：View 只做组装与渲染）。
 *
 * 按进入方向单模式渲染：发送模式只出示下载段，接收模式只出示上传段。
 * 页面状态与设置中的方向开关一致：开关关闭时中部提示服务已关闭、底部给出开启按钮；
 * 开关开启时顶部按需给出警告横幅，中部垂直居中显示地址与二维码，底部给出免确认开关与关闭按钮。
 * 关闭按钮只作用于自己这一方向，另一方向继续可用（与设置开关双向同步）。
 *
 * 进行中的传输由统一会话引擎呈现在任务页与详情页。
 * 关闭面板不停服务：服务由面板内的关闭按钮显式停止。
 */
@ComponentV2
export struct ShareLinkPage {
  // 系统宽度断点（随窗口尺寸变化自动刷新，宽屏限用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: ShareLinkViewModel = new ShareLinkViewModel();
  @Local private isNavigatingBack: boolean = false;
  // 路由参数（经 ShareLinkPageBuilder 传入，结构与旧 pushUrl params 一致）
  @Param pageParam: Object = new Object()
  // NavDestination 返回栈（onReady 注入）
  private pathStack: NavPathStack = new NavPathStack()
  // 内容滚动控制器：绑定到子页面容器以驱动标题栏滚动模糊
  private scroller: Scroller = new Scroller()

  onBackPress(): boolean {
    if (this.isNavigatingBack) {
      return true;
    }
    // 收起面板不停服务：服务由关闭按钮显式关闭
    this.isNavigatingBack = true;
    this.pathStack.pop();
    return true;
  }

  /** 进入方向：'receive' 为接收模式，其余一律为发送模式。 */
  private pageMode(): string {
    let params: Record<string, string> = this.pageParam as Record<string, string>;
    if (params !== undefined && params['mode'] === 'receive') {
      return 'receive';
    }
    return 'send';
  }

  aboutToAppear(): void {
    this.viewModel.loadShareInfo();
    // 开关开启而服务尚未恢复时补一次启动；开关关闭时页面只出示已关闭提示
    if (this.pageMode() === 'receive') {
      this.viewModel.ensureReceiveService();
    } else {
      this.viewModel.ensureSendService();
    }
  }

  aboutToDisappear(): void {
    // 只退订：服务在面板关闭后继续运行
    this.viewModel.unsubscribeFromRepository();
  }

  // 内容最大宽度：按断点取值；平板竖屏收紧至 800；窄屏返回 '100%' 全宽
  private getContentMaxWidth(): Length {
    return getPageContentMaxWidth(this.breakpointInfo.widthBreakpoint,
      this.breakpointInfo.heightBreakpoint, deviceInfo.deviceType);
  }

  /** 当前断点下的二维码边长。 */
  private qrSize(): number {
    return QR_SIZE_BY_BREAKPOINT.getValue(this.breakpointInfo.widthBreakpoint);
  }

  /** 复制地址：成功后给出轻提示。 */
  private copyAddress(url: string): void {
    if (!this.viewModel.copyShareUrl(url)) {
      return;
    }
    try {
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.copy_success'), duration: 1500 });
    } catch (_e) {
      // 提示展示失败不影响复制结果
    }
  }

  // 发送方向服务是否就绪（地址存在即已启动；未挂载文件时顶部给无文件警告）
  private isSendRunning(): boolean {
    return this.viewModel.shareUrl.length > 0;
  }

  // 接收方向是否在运行（上传入口已开放）。
  private isReceiveRunning(): boolean {
    return this.viewModel.shareUrl.length > 0 && this.viewModel.uploadEnabled;
  }

  /** 开启接收：上传入口未开时打开（幂等）。 */
  private async startReceiving(): Promise<void> {
    await this.viewModel.startWebReceive();
  }

  /** 关闭发送：有活跃下载（含待确认）时先确认，确认后停止并中断会话。 */
  private closeSendDirection(): void {
    let label: string = getStringSync(this.getUIContext(), $r('app.string.web_send_label'));
    confirmDisableDirection(label, [WEB_DOWNLOAD_KEY], (sessions: Array<TransferSession>) => {
      this.viewModel.stopSharingFiles();
      cancelSessions(sessions);
    });
  }

  /** 关闭接收：有活跃上传（含待确认）时先确认，确认后停止并中断会话。 */
  private closeReceiveDirection(): void {
    let label: string = getStringSync(this.getUIContext(), $r('app.string.web_receive_label'));
    confirmDisableDirection(label, [WEB_UPLOAD_KEY], (sessions: Array<TransferSession>) => {
      this.viewModel.stopReceivingFiles();
      cancelSessions(sessions);
    });
  }

  /**
   * 警告横幅（纯文字、无可点击元素）。
   * 面板内同一时刻最多只展示一条：调用方按优先级互斥展示。
   */
  @Builder
  buildWarningBanner(text: ResourceStr, centered: boolean = false) {
    Text(text)
      .fontSize(DesignTokens.font.bodyS)
      .fontColor($r('app.color.warning_orange'))
      .textAlign(centered ? TextAlign.Center : TextAlign.Start)
      .width('100%')
      .padding(DesignTokens.space.md)
      .backgroundColor($r('app.color.warning_bg'))
      .borderRadius(DesignTokens.radius.md)
  }

  /** 本次挂载的下载免确认开关：只作用于浏览器下载。 */
  @Builder
  autoAcceptRow() {
    Row() {
      // 标签与说明同列紧邻，避免说明被下方按钮挤住、又离开关过远
      Column({ space: DesignTokens.space.xxs }) {
        Text($r('app.string.web_access_auto_accept_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        Text($r('app.string.web_access_auto_accept_desc'))
          .fontSize(DesignTokens.font.bodyS)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.viewModel.autoAcceptDownload })
        .onChange((isOn: boolean) => {
          this.viewModel.setAutoAcceptDownload(isOn);
        })
        .id('web_access_auto_accept_toggle')
    }
    .width('100%')
    // 与警告横幅的内边距一致，使两处文字左边缘对齐
    .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
    .alignItems(VerticalAlign.Center)
  }

  /** 方向关闭按钮（红色胶囊，通栏沉底）。 */
  @Builder
  stopButton(label: Resource, action: () => void, id: string) {
    Button(label)
      .width('100%')
      .height(DesignTokens.size.thumbSm)
      .fontSize(DesignTokens.font.subtitleM)
      .fontColor($r('app.color.text_on_color'))
      .backgroundColor($r('app.color.stop_red'))
      .borderRadius(DesignTokens.radius.max)
      .onClick(action)
      .id(id)
  }

  /** 段内主操作按钮（蓝色胶囊，通栏沉底）。 */
  @Builder
  primaryButton(label: Resource, action: () => void, id: string) {
    Button(label)
      .width('100%')
      .height(DesignTokens.size.thumbSm)
      .fontSize(DesignTokens.font.subtitleM)
      .fontColor($r('app.color.text_on_color'))
      .backgroundColor($r('app.color.accent_blue'))
      .borderRadius(DesignTokens.radius.max)
      .onClick(action)
      .id(id)
  }

  /** 顶部是否会出现警告横幅：端口回退优先，其次是发送方向的无文件/证书提示。 */
  private hasTopWarning(): boolean {
    if (this.viewModel.webPortFallback) {
      return true;
    }
    if (this.pageMode() !== 'send' || this.viewModel.sendDisabled || !this.isSendRunning()) {
      return false;
    }
    return !this.viewModel.hasDownload || this.viewModel.showHttpsHint;
  }

  /** 端口回退提示文案：默认端口与实际端口。 */
  private portFallbackText(): string {
    let template: string = getStringSync(this.getUIContext(),
      $r('app.string.web_port_fallback_warning'));
    return template.replace('%d', String(this.viewModel.webPreferredPort))
      .replace('%d', String(this.viewModel.webActualPort));
  }

  /**
   * 顶部警告：端口回退优先；发送方向再按无文件 / 加密证书提示互斥展示。
   */
  @Builder
  buildTopWarning() {
    if (this.viewModel.webPortFallback) {
      this.buildWarningBanner(this.portFallbackText())
    } else if (this.pageMode() === 'send' && !this.viewModel.sendDisabled && this.isSendRunning()) {
      if (!this.viewModel.hasDownload) {
        this.buildWarningBanner($r('app.string.web_access_no_file_warning'), true)
      } else if (this.viewModel.showHttpsHint) {
        this.buildWarningBanner($r('app.string.web_share_https_hint'))
      }
    }
  }

  /** 发送模式中部：地址与二维码；关闭或服务未就绪时给出居中提示。 */
  @Builder
  buildSendMiddle() {
    if (this.viewModel.sendDisabled) {
      EmptyState({
        mainText: $r('app.string.share_link_disabled_hint'),
        useCard: false
      })
    } else if (!this.isSendRunning()) {
      EmptyState({
        mainText: $r('app.string.web_access_unavailable'),
        useCard: false
      })
    } else {
      WebAccessEntryCard({
        url: this.viewModel.shareUrl,
        qrSize: this.qrSize(),
        addresses: this.viewModel.webAddresses,
        selectedAddressIp: this.viewModel.selectedAddressIp,
        onCopy: (url: string) => {
          this.copyAddress(url);
        },
        onSelectAddress: (ip: string) => {
          this.viewModel.selectWebAddress(ip);
        }
      })
    }
  }

  /** 发送模式底栏：免确认开关（服务运行中）与启停按钮（常驻底部）。 */
  @Builder
  buildSendActions() {
    if (this.viewModel.sendDisabled) {
      this.primaryButton($r('app.string.web_access_start_send'),
        () => {
          this.viewModel.enableSendDirection();
        }, 'web_access_enable_send_btn')
    } else {
      if (this.isSendRunning()) {
        this.autoAcceptRow()
      }
      this.stopButton($r('app.string.stop_share'),
        () => {
          this.closeSendDirection();
        }, 'web_access_stop_share_btn')
    }
  }

  /** 接收模式中部：地址与二维码；关闭或服务未就绪时给出居中提示。 */
  @Builder
  buildReceiveMiddle() {
    if (this.viewModel.receiveDisabled) {
      EmptyState({
        mainText: $r('app.string.share_link_disabled_hint'),
        useCard: false
      })
    } else if (!this.isReceiveRunning()) {
      EmptyState({
        mainText: $r('app.string.web_access_unavailable'),
        useCard: false
      })
    } else {
      WebAccessEntryCard({
        url: this.viewModel.uploadUrl,
        qrSize: this.qrSize(),
        addresses: this.viewModel.webAddresses,
        selectedAddressIp: this.viewModel.selectedAddressIp,
        onCopy: (url: string) => {
          this.copyAddress(url);
        },
        onSelectAddress: (ip: string) => {
          this.viewModel.selectWebAddress(ip);
        }
      })
    }
  }

  /** 接收模式底栏：启停按钮（常驻底部）。 */
  @Builder
  buildReceiveActions() {
    if (this.viewModel.receiveDisabled) {
      this.primaryButton($r('app.string.web_access_start_receive'),
        () => {
          this.startReceiving();
        }, 'web_access_enable_receive_btn')
    } else {
      this.stopButton($r('app.string.stop_receive'),
        () => {
          this.closeReceiveDirection();
        }, 'web_access_stop_receive_btn')
    }
  }

  build() {
    HdsNavDestination() {
      Row() {
        Column() {
          // 顶部区：警告横幅（端口回退优先；发送方向再按无文件/证书提示），固定在页面顶端
          if (this.hasTopWarning()) {
            Column() {
              this.buildTopWarning()
            }
            .width('100%')
            .padding({
              left: getPageMargin(this.breakpointInfo.widthBreakpoint),
              right: getPageMargin(this.breakpointInfo.widthBreakpoint),
              top: DesignTokens.space.md
            })
          }

          // 中部区：在横幅与底栏之间的剩余空间内垂直居中（内容超高时仍可滚动）
          Scroll(this.scroller) {
            Column() {
              if (this.pageMode() === 'receive') {
                this.buildReceiveMiddle()
              } else {
                this.buildSendMiddle()
              }
            }
            .width('100%')
            .constraintSize({ minHeight: '100%' })
            .justifyContent(FlexAlign.Center)
            .padding({
              left: getPageMargin(this.breakpointInfo.widthBreakpoint),
              right: getPageMargin(this.breakpointInfo.widthBreakpoint),
              top: DesignTokens.space.md,
              bottom: DesignTokens.space.md
            })
          }
          .layoutWeight(1)
          // 滚动容器不裁剪：滚动中的内容可绘制到标题栏区域内，使毛玻璃背板有内容可透出
          .clip(false)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

          // 底栏：可能有的免确认开关 + 必定有的启停按钮（常驻底部，不随内容滚动）
          Column({ space: DesignTokens.space.md }) {
            if (this.pageMode() === 'receive') {
              this.buildReceiveActions()
            } else {
              this.buildSendActions()
            }
          }
          .width('100%')
          .padding({
            left: getPageMargin(this.breakpointInfo.widthBreakpoint),
            right: getPageMargin(this.breakpointInfo.widthBreakpoint),
            bottom: DesignTokens.space.md
          })
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
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
      title: this.pageMode() === 'receive' ? $r('app.string.web_access_title_receive') :
        $r('app.string.web_access_title_send')
    }))
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onBackPressed(() => {
      return this.onBackPress();
    })
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}

// 路由表引用：ShareLinkPageBuilder(name, param)
@Builder
export function ShareLinkPageBuilder(name: string, param: Object) {
  ShareLinkPage({ pageParam: param })
}
