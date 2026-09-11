/**
 * MtaReceivePage.ets — MTA 接收调试页
 *
 * 开发者调试页面：一键启动接收服务（BLE 广播 + GATT Server），
 * 展示凭据解密/直连结果、WS 接收请求确认、下载进度与已保存文件，并提供统一日志区。
 * 布局参照 MtaBleVerifyPage（NavDestination + 断点限宽 + 卡片式分区）。
 */

import { uiObserver, promptAction } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { DesignTokens } from '../common/DesignTokens';
import { getMaxContentWidth, getPageMargin, isTabletPortrait } from '../common/Breakpoints';
import { MtaReceiveViewModel } from '../viewmodel/MtaReceiveViewModel';
import { P2pPeerDeviceView, ReceiverLogEntry, ReceiveRequest, formatBytes } from '../model/mta/MtaReceiveModels';
import { copyText } from '../utils/ClipboardUtil';

/** @Builder 按引用传递所需的参数类 */
class MtaRowParam {
  label: ResourceStr = '';
  value: ResourceStr = '';
}

class MtaSectionTitleParam {
  title: ResourceStr = '';
}

@ComponentV2
export struct MtaReceivePage {
  // 系统宽度断点（随窗口尺寸变化自动刷新，宽屏限宽用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: MtaReceiveViewModel = new MtaReceiveViewModel()
  // NavDestination 返回栈（onReady 注入）
  private pathStack: NavPathStack = new NavPathStack()

  aboutToAppear(): void {
    this.viewModel.onNewRequest = (request: ReceiveRequest): void => {
      this.showReceiveDialog(request);
    };
    this.viewModel.loadInitial(this.getUIContext().getHostContext());
  }

  /** 弹出接收确认对话框（比内联卡片更醒目，确保用户能及时确认） */
  private showReceiveDialog(request: ReceiveRequest): void {
    let message = `发送方：${request.senderName}\n文件：${request.fileName}\n` +
      `${request.fileCount} 个文件 / ${formatBytes(request.totalSize)}`;
    this.getUIContext().getPromptAction().showDialog({
      title: $r('app.string.mta_receive_request_section'),
      message: message,
      buttons: [
        {
          text: $r('app.string.mta_receive_reject'),
          color: $r('app.color.danger_red')
        },
        {
          text: $r('app.string.mta_receive_accept'),
          color: $r('app.color.accent_blue')
        }
      ]
    })
      .then((result: promptAction.ShowDialogSuccessResponse) => {
        if (result.index === 1) {
          this.viewModel.onAcceptRequest();
        } else {
          this.viewModel.onRejectRequest();
        }
      })
      .catch(() => {
        this.viewModel.onRejectRequest();
      });
  }

  aboutToDisappear(): void {
    // 页面退出时释放全部资源（停广播、关 GATT、断 WS 与 P2P）
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

  build() {
    NavDestination() {
      Row() {
        Scroll() {
          Column({ space: DesignTokens.space.sm }) {
            // ── 接收服务 ──
            this.buildServiceSection()
            // ── P2P 凭据 ──
            this.buildCredentialSection()
            // ── WS 握手诊断 ──
            this.buildWsDiagnosticsSection()
            // ── 接收请求确认 ──
            if (this.viewModel.isWaitingConfirm()) {
              this.buildRequestSection()
            }
            // ── 下载进度 ──
            if (this.viewModel.isTransferring()) {
              this.buildProgressSection()
            }
            // ── 已保存文件 ──
            if (this.viewModel.state.savedFiles.length > 0) {
              this.buildSavedFilesSection()
            }
            // ── 操作指引 ──
            this.buildGuidanceSection()
            // ── 日志区 ──
            this.buildLogSection()
            // ── 一键清理 ──
            Button($r('app.string.mta_receive_cleanup'))
              .width('100%')
              .height(DesignTokens.size.thumbSm)
              .backgroundColor($r('app.color.danger_red'))
              .fontColor($r('app.color.text_on_color'))
              .borderRadius(DesignTokens.radius.md)
              .margin({ bottom: DesignTokens.space.md })
              .onClick(() => {
                this.viewModel.onCleanup();
              })
          }
          .padding({
            left: getPageMargin(this.breakpointInfo.widthBreakpoint),
            right: getPageMargin(this.breakpointInfo.widthBreakpoint),
            top: DesignTokens.space.md,
            bottom: DesignTokens.space.md
          })
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
        .constraintSize({ maxWidth: this.getContentMaxWidth() })
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Top)
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .title($r('app.string.mta_receive_title'), { backgroundColor: $r('app.color.page_background') })
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }

  // ── 通用卡片容器与行组件 ──

  @Builder
  sectionTitle(param: MtaSectionTitleParam) {
    Text(param.title)
      .fontSize(DesignTokens.font.subtitleM)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_primary'))
      .width('100%')
      .padding({ bottom: DesignTokens.space.tiny })
  }

  @Builder
  infoRow(param: MtaRowParam) {
    Row() {
      Text(param.label)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .width('38%')
      Text(param.value)
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

  @Builder
  routeOption(label: ResourceStr, index: number) {
    Button(label)
      .height(DesignTokens.size.inlineButton)
      .fontSize(DesignTokens.font.bodyS)
      .backgroundColor(this.viewModel.connectRouteIndex === index ? $r('app.color.accent_blue') :
        $r('app.color.border_light'))
      .fontColor(this.viewModel.connectRouteIndex === index ? $r('app.color.text_on_color') :
        $r('app.color.text_primary'))
      .borderRadius(DesignTokens.radius.sm)
      .layoutWeight(1)
      .onClick(() => {
        this.viewModel.onSelectRoute(index);
      })
  }

  @Builder
  netIdOption(label: ResourceStr, index: number) {
    Button(label)
      .height(DesignTokens.size.inlineButton)
      .fontSize(DesignTokens.font.bodyS)
      .backgroundColor(this.viewModel.p2pNetIdIndex === index ? $r('app.color.accent_blue') :
        $r('app.color.border_light'))
      .fontColor(this.viewModel.p2pNetIdIndex === index ? $r('app.color.text_on_color') :
        $r('app.color.text_primary'))
      .borderRadius(DesignTokens.radius.sm)
      .layoutWeight(1)
      .onClick(() => {
        this.viewModel.onSelectP2pNetId(index);
      })
  }

  @Builder
  credentialJoinOption(label: ResourceStr, enabled: boolean) {
    Button(label)
      .height(DesignTokens.size.inlineButton)
      .fontSize(DesignTokens.font.bodyS)
      .backgroundColor(this.viewModel.credentialJoinEnabled === enabled ? $r('app.color.accent_blue') :
        $r('app.color.border_light'))
      .fontColor(this.viewModel.credentialJoinEnabled === enabled ? $r('app.color.text_on_color') :
        $r('app.color.text_primary'))
      .borderRadius(DesignTokens.radius.sm)
      .layoutWeight(1)
      .onClick(() => {
        this.viewModel.onToggleCredentialJoin(enabled);
      })
  }

  @Builder
  actionButton(label: ResourceStr, color: Resource, onClick: () => void) {
    Button(label)
      .height(DesignTokens.size.inlineButton)
      .fontSize(DesignTokens.font.bodyS)
      .backgroundColor(color)
      .fontColor($r('app.color.text_on_color'))
      .borderRadius(DesignTokens.radius.sm)
      .layoutWeight(1)
      .onClick(() => {
        onClick();
      })
  }

  // ── 接收服务 ──

  @Builder
  buildServiceSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_receive_service_section') })

      Row() {
        Text($r('app.string.mta_ble_verify_device_name_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        TextInput({ text: this.viewModel.deviceNameInput })
          .layoutWeight(1)
          .fontSize(DesignTokens.font.bodyM)
          .onChange((value: string) => {
            this.viewModel.deviceNameInput = value;
          })
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      this.infoRow({ label: $r('app.string.mta_receive_stage'), value: this.viewModel.stageText() })
      this.infoRow({
        label: $r('app.string.mta_receive_service_state'),
        value: this.viewModel.state.serviceRunning ? $r('app.string.mta_receive_running') :
          $r('app.string.mta_receive_stopped')
      })
      this.infoRow({
        label: $r('app.string.mta_receive_advertising_state'),
        value: this.viewModel.state.advertisingRunning ? $r('app.string.mta_receive_advertising_on') :
          $r('app.string.mta_receive_advertising_off')
      })
      this.infoRow({
        label: $r('app.string.mta_receive_gatt_state'),
        value: this.viewModel.state.gattRunning ? $r('app.string.mta_receive_gatt_on') :
          $r('app.string.mta_receive_gatt_off')
      })
      this.infoRow({
        label: $r('app.string.mta_receive_public_key'),
        value: this.viewModel.state.ecdhPublicKey.length > 0 ? this.viewModel.state.ecdhPublicKey :
          $r('app.string.mta_receive_none')
      })
      this.infoRow({
        label: $r('app.string.mta_receive_peer'),
        value: this.viewModel.state.connectedPeerId.length > 0 ? this.viewModel.state.connectedPeerId :
          $r('app.string.mta_receive_none')
      })

      Row() {
        Text($r('app.string.mta_receive_route_section'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        Row({ space: DesignTokens.space.tiny }) {
          this.routeOption($r('app.string.mta_receive_route_credential'), 0)
          this.routeOption($r('app.string.mta_receive_route_p2p_connect'), 1)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: DesignTokens.space.xxs, bottom: DesignTokens.space.xxs })
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      if (this.viewModel.connectRouteIndex === 1) {
        Row() {
          Text($r('app.string.mta_receive_join_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_secondary'))
            .width('38%')
          Row({ space: DesignTokens.space.tiny }) {
            this.credentialJoinOption($r('app.string.mta_receive_join_standard'), false)
            this.credentialJoinOption($r('app.string.mta_receive_join_credential'), true)
          }
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ top: DesignTokens.space.xxs, bottom: DesignTokens.space.xxs })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })

        Row() {
          Text($r('app.string.mta_receive_netid_label'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_secondary'))
            .width('38%')
          Row({ space: DesignTokens.space.tiny }) {
            this.netIdOption($r('app.string.mta_receive_netid_temp'), 0)
            this.netIdOption($r('app.string.mta_receive_netid_persistent'), 1)
          }
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ top: DesignTokens.space.xxs, bottom: DesignTokens.space.xxs })
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })

        Row() {
          Text($r('app.string.mta_receive_peer_target'))
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_secondary'))
            .width('38%')
          Text(this.viewModel.manualPeerText.length > 0 ? this.viewModel.manualPeerText :
            $r('app.string.mta_receive_peer_auto'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .textAlign(TextAlign.End)
            .wordBreak(WordBreak.BREAK_ALL)
        }
        .width('100%')
        .constraintSize({ minHeight: DesignTokens.size.thumbSm })

        Row({ space: DesignTokens.space.tiny }) {
          this.actionButton($r('app.string.mta_receive_peer_discover'), $r('app.color.accent_blue'), () => {
            this.viewModel.onDiscoverPeers();
          })
          this.actionButton($r('app.string.mta_receive_peer_clear'), $r('app.color.border_light'), () => {
            this.viewModel.onClearManualPeer();
          })
        }
        .width('100%')
        .margin({ top: DesignTokens.space.tiny })

        if (this.viewModel.discoveredPeers.length === 0) {
          Text($r('app.string.mta_receive_peer_empty'))
            .fontSize(DesignTokens.font.captionM)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ top: DesignTokens.space.tiny })
        } else {
          Column({ space: DesignTokens.space.mini }) {
            ForEach(this.viewModel.discoveredPeers, (peer: P2pPeerDeviceView, index: number) => {
              Row() {
                Text(peer.deviceName.length > 0 ? `${peer.deviceName} ${peer.deviceAddress}` : peer.deviceAddress)
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                  .wordBreak(WordBreak.BREAK_ALL)
                Button($r('app.string.mta_receive_peer_set_target'))
                  .height(DesignTokens.size.inlineButton)
                  .fontSize(DesignTokens.font.bodyS)
                  .backgroundColor($r('app.color.accent_blue'))
                  .fontColor($r('app.color.text_on_color'))
                  .borderRadius(DesignTokens.radius.sm)
                  .onClick(() => {
                    this.viewModel.onSelectManualPeer(peer);
                  })
              }
              .width('100%')
              .padding(DesignTokens.space.tiny)
              .backgroundColor($r('app.color.page_background'))
              .borderRadius(DesignTokens.radius.sm)
            }, (peer: P2pPeerDeviceView, index: number) => `${index}-${peer.deviceAddress}`)
          }
          .width('100%')
          .margin({ top: DesignTokens.space.tiny })
        }
      }

      Row({ space: DesignTokens.space.tiny }) {
        this.actionButton($r('app.string.mta_receive_start_service'), $r('app.color.accent_blue'), () => {
          this.viewModel.onStartService();
        })
        this.actionButton($r('app.string.mta_receive_stop_service'), $r('app.color.danger_red'), () => {
          this.viewModel.onStopService();
        })
      }
      .width('100%')
      .margin({ top: DesignTokens.space.tiny })
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

  // ── P2P 凭据 ──

  @Builder
  buildCredentialSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_receive_credential_section') })
      this.infoRow({
        label: $r('app.string.mta_receive_ssid'),
        value: this.viewModel.credentialsSsid().length > 0 ? this.viewModel.credentialsSsid() :
          $r('app.string.mta_receive_none')
      })
      this.infoRow({
        label: $r('app.string.mta_receive_psk'),
        value: this.viewModel.credentialsPsk().length > 0 ? this.viewModel.credentialsPsk() :
          $r('app.string.mta_receive_none')
      })
      this.infoRow({
        label: $r('app.string.mta_receive_mac'),
        value: this.viewModel.credentialsMac().length > 0 ? this.viewModel.credentialsMac() :
          $r('app.string.mta_receive_none')
      })
      this.infoRow({
        label: $r('app.string.mta_receive_go_ip'),
        value: this.viewModel.state.goIpAddress.length > 0 ? this.viewModel.state.goIpAddress :
          $r('app.string.mta_receive_none')
      })
      this.infoRow({
        label: $r('app.string.mta_receive_port'),
        value: this.viewModel.state.transferPort > 0 ? String(this.viewModel.state.transferPort) :
          $r('app.string.mta_receive_none')
      })
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

  // ── WS 握手诊断 ──

  @Builder
  buildWsDiagnosticsSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_receive_ws_diag_section') })
      this.infoRow({
        label: $r('app.string.mta_receive_ws_target'),
        value: this.viewModel.wsTargetText().length > 0 ? this.viewModel.wsTargetText() :
          $r('app.string.mta_receive_none')
      })
      this.infoRow({ label: $r('app.string.mta_receive_ws_result'), value: this.viewModel.wsResultText() })
      this.infoRow({ label: $r('app.string.mta_receive_ws_total_time'), value: this.viewModel.wsTotalText() })
      this.infoRow({ label: $r('app.string.mta_receive_net_bind_result'), value: this.viewModel.netBindResultText() })
      this.infoRow({
        label: $r('app.string.mta_receive_network_summary'),
        value: this.viewModel.networkSummaryText()
      })

      Text($r('app.string.mta_receive_ws_attempts'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ top: DesignTokens.space.tiny })

      if (this.viewModel.wsAttemptLines().length === 0) {
        this.infoRow({ label: $r('app.string.mta_receive_none'), value: '' })
      } else {
        Column({ space: DesignTokens.space.mini }) {
          ForEach(this.viewModel.wsAttemptLines(), (line: string, index: number) => {
            Text(line)
              .fontSize(DesignTokens.font.captionM)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .wordBreak(WordBreak.BREAK_ALL)
              .padding(DesignTokens.space.tiny)
              .backgroundColor($r('app.color.page_background'))
              .borderRadius(DesignTokens.radius.sm)
          }, (line: string, index: number) => `${index}-${line}`)
        }
        .width('100%')
      }

      Button($r('app.string.mta_receive_refresh_network'))
        .width('100%')
        .height(DesignTokens.size.inlineButton)
        .fontSize(DesignTokens.font.bodyS)
        .backgroundColor($r('app.color.accent_blue_bg'))
        .fontColor($r('app.color.ip_blue_text'))
        .borderRadius(DesignTokens.radius.sm)
        .margin({ top: DesignTokens.space.tiny })
        .onClick(() => {
          this.viewModel.onRefreshNetwork();
        })
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

  // ── 接收请求确认 ──

  @Builder
  buildRequestSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_receive_request_section') })
      this.infoRow({ label: $r('app.string.mta_receive_sender'), value: this.viewModel.requestSender() })
      this.infoRow({ label: $r('app.string.mta_receive_file_name'), value: this.viewModel.requestFileName() })
      this.infoRow({ label: $r('app.string.mta_receive_file_count'), value: this.viewModel.requestFileCountText() })
      this.infoRow({ label: $r('app.string.mta_receive_total_size'), value: this.viewModel.requestTotalSizeText() })

      Row({ space: DesignTokens.space.tiny }) {
        this.actionButton($r('app.string.mta_receive_accept'), $r('app.color.accent_blue'), () => {
          this.viewModel.onAcceptRequest();
        })
        this.actionButton($r('app.string.mta_receive_reject'), $r('app.color.danger_red'), () => {
          this.viewModel.onRejectRequest();
        })
      }
      .width('100%')
      .margin({ top: DesignTokens.space.tiny })
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

  // ── 下载进度 ──

  @Builder
  buildProgressSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_receive_progress_section') })
      Progress({ value: this.viewModel.progressPercent(), total: 100, type: ProgressType.Linear })
        .width('100%')
        .margin({ top: DesignTokens.space.tiny, bottom: DesignTokens.space.tiny })
      this.infoRow({ label: $r('app.string.mta_receive_progress'), value: this.viewModel.progressText() })
      Button($r('app.string.mta_receive_cancel_download'))
        .width('100%')
        .height(DesignTokens.size.inlineButton)
        .fontSize(DesignTokens.font.bodyS)
        .backgroundColor($r('app.color.danger_red'))
        .fontColor($r('app.color.text_on_color'))
        .borderRadius(DesignTokens.radius.sm)
        .margin({ top: DesignTokens.space.tiny })
        .onClick(() => {
          this.viewModel.onCancelDownload();
        })
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

  // ── 已保存文件 ──

  @Builder
  buildSavedFilesSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_receive_saved_files') })
      Column({ space: DesignTokens.space.mini }) {
        ForEach(this.viewModel.state.savedFiles, (path: string, index: number) => {
          Text(path)
            .fontSize(DesignTokens.font.captionM)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .wordBreak(WordBreak.BREAK_ALL)
            .padding(DesignTokens.space.tiny)
            .backgroundColor($r('app.color.page_background'))
            .borderRadius(DesignTokens.radius.sm)
        }, (path: string, index: number) => `${index}-${path}`)
      }
      .width('100%')
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

  // ── 操作指引 ──

  @Builder
  buildGuidanceSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_receive_guidance_section') })
      Text($r('app.string.mta_receive_guidance_text'))
        .fontSize(DesignTokens.font.bodyS)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .lineHeight(20)
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

  // ── 日志区 ──

  @Builder
  buildLogSection() {
    Column() {
      Row() {
        Text($r('app.string.mta_receive_log_section'))
          .fontSize(DesignTokens.font.subtitleM)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Button($r('app.string.mta_receive_copy_logs'))
          .height(DesignTokens.size.inlineButton)
          .fontSize(DesignTokens.font.bodyS)
          .backgroundColor($r('app.color.accent_blue_bg'))
          .fontColor($r('app.color.ip_blue_text'))
          .borderRadius(DesignTokens.radius.sm)
          .margin({ right: DesignTokens.space.tiny })
          .onClick(() => {
            let text = this.viewModel.buildLogText();
            if (copyText(text)) {
              this.getUIContext().getPromptAction().showToast({ message: $r('app.string.copy_success') });
            }
          })
        Button($r('app.string.mta_receive_clear_logs'))
          .height(DesignTokens.size.inlineButton)
          .fontSize(DesignTokens.font.bodyS)
          .backgroundColor($r('app.color.border_light'))
          .fontColor($r('app.color.text_primary'))
          .borderRadius(DesignTokens.radius.sm)
          .onClick(() => {
            this.viewModel.clearLogs();
          })
      }
      .width('100%')
      .padding({ bottom: DesignTokens.space.tiny })

      if (this.viewModel.logs.length === 0) {
        this.infoRow({ label: $r('app.string.mta_receive_no_logs'), value: '' })
      } else {
        Column({ space: DesignTokens.space.mini }) {
          ForEach(this.viewModel.logs, (entry: ReceiverLogEntry, index: number) => {
            Column() {
              Row() {
                Text(entry.timeText)
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ right: DesignTokens.space.tiny })
                Text(entry.source)
                  .fontSize(DesignTokens.font.captionM)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(entry.level === '错误' ? $r('app.color.danger_red') : $r('app.color.text_primary'))
                  .layoutWeight(1)
                Text(entry.level)
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor(entry.level === '错误' ? $r('app.color.danger_red') : $r('app.color.text_secondary'))
              }
              .width('100%')

              Text(entry.content)
                .fontSize(DesignTokens.font.captionM)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .wordBreak(WordBreak.BREAK_ALL)
            }
            .width('100%')
            .padding(DesignTokens.space.tiny)
            .backgroundColor($r('app.color.page_background'))
            .borderRadius(DesignTokens.radius.sm)
          }, (entry: ReceiverLogEntry, index: number) => `${index}-${entry.timeText}-${entry.content}`)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }
}

// 路由表引用：MtaReceivePageBuilder(name, param)
@Builder
export function MtaReceivePageBuilder(_name: string, _param: Object) {
  MtaReceivePage()
}
