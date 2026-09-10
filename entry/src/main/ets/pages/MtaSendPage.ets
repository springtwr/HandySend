/**
 * MtaSendPage.ets — MTA 发送调试页
 *
 * 开发者调试页面：扫描并列出处于接收模式的 MTA 设备（CatShare），选中后发起发送，
 * 展示 GATT 连接 / 建组 / 协商 / 传输进度与运行日志，并提供取消与一键清理。
 * 布局参照 MtaReceivePage（NavDestination + 断点限宽 + 卡片式分区）。
 */

import { uiObserver } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { DesignTokens } from '../common/DesignTokens';
import { getMaxContentWidth, getPageMargin, isTabletPortrait } from '../common/Breakpoints';
import { MtaSendViewModel } from '../viewmodel/MtaSendViewModel';
import { MtaDiscoveredDevice, MtaSendFile } from '../model/mta/MtaSendModels';
import { ReceiverLogEntry } from '../model/mta/MtaReceiveModels';
import { copyText } from '../utils/ClipboardUtil';

/** @Builder 按引用传递所需的参数类 */
class MtaSendRowParam {
  label: ResourceStr = '';
  value: ResourceStr = '';
}

class MtaSendSectionTitleParam {
  title: ResourceStr = '';
}

@ComponentV2
export struct MtaSendPage {
  // 系统宽度断点（随窗口尺寸变化自动刷新，宽屏限宽用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: MtaSendViewModel = new MtaSendViewModel()
  // NavDestination 返回栈（onReady 注入）
  private pathStack: NavPathStack = new NavPathStack()

  aboutToAppear(): void {
    this.viewModel.loadInitial(this.getUIContext().getHostContext());
  }

  aboutToDisappear(): void {
    // 页面退出时释放全部资源（停扫描、断 GATT、删组、停服务器）
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
            // ── 扫描控制 ──
            this.buildScanSection()
            // ── 设备列表 ──
            this.buildDeviceSection()
            // ── 发送链路（选中设备后显示） ──
            if (this.viewModel.state.selected !== undefined) {
              this.buildLinkSection()
            }
            // ── 文件选择 ──
            this.buildFilesSection()
            // ── 传输进度（传输中或已结束显示） ──
            if (this.viewModel.isTransferring() || this.viewModel.isFinished()) {
              this.buildProgressSection()
            }
            // ── 操作指引 ──
            this.buildGuidanceSection()
            // ── 日志区 ──
            this.buildLogSection()
            // ── 一键清理 ──
            Button($r('app.string.mta_send_cleanup'))
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
    .title($r('app.string.mta_send_title'), { backgroundColor: $r('app.color.page_background') })
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }

  // ── 通用卡片容器与行组件 ──

  @Builder
  sectionTitle(param: MtaSendSectionTitleParam) {
    Text(param.title)
      .fontSize(DesignTokens.font.subtitleM)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_primary'))
      .width('100%')
      .padding({ bottom: DesignTokens.space.tiny })
  }

  @Builder
  infoRow(param: MtaSendRowParam) {
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

  // ── 扫描控制 ──

  @Builder
  buildScanSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_send_scan_section') })
      this.infoRow({ label: $r('app.string.mta_send_stage'), value: this.viewModel.stageText() })
      this.infoRow({
        label: $r('app.string.mta_send_device_count'),
        value: String(this.viewModel.state.devices.length)
      })
      this.infoRow({
        label: $r('app.string.mta_send_selected'),
        value: this.viewModel.state.selected !== undefined ? this.viewModel.state.selected.deviceName :
          $r('app.string.mta_send_none')
      })

      Row({ space: DesignTokens.space.tiny }) {
        this.actionButton($r('app.string.mta_send_start_scan'), $r('app.color.accent_blue'), () => {
          this.viewModel.onStartScan();
        })
        this.actionButton($r('app.string.mta_send_stop_scan'), $r('app.color.danger_red'), () => {
          this.viewModel.onStopScan();
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

  // ── 设备列表 ──

  @Builder
  buildDeviceSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_send_device_list') })
      if (this.viewModel.state.devices.length === 0) {
        this.infoRow({ label: $r('app.string.mta_send_device_empty'), value: '' })
      } else {
        Column({ space: DesignTokens.space.mini }) {
          ForEach(this.viewModel.deviceList(), (device: MtaDiscoveredDevice, index: number) => {
            Column() {
              Row() {
                Text(device.deviceName.length > 0 ? device.deviceName : $r('app.string.mta_send_unknown_device'))
                  .fontSize(DesignTokens.font.bodyM)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                Text(`${device.rssi} dBm`)
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')

              Row() {
                Text(`${device.brandName} · ${device.is5Ghz ? '5GHz' : '2.4GHz'} · ${device.senderIdHex}`)
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.text_secondary'))
                  .layoutWeight(1)
                if (this.viewModel.isSelected(device)) {
                  Text($r('app.string.mta_send_selected_tag'))
                    .fontSize(DesignTokens.font.captionM)
                    .fontColor($r('app.color.accent_blue'))
                }
              }
              .width('100%')
              .margin({ top: DesignTokens.space.xxs })
            }
            .width('100%')
            .padding(DesignTokens.space.tiny)
            .backgroundColor(this.viewModel.isSelected(device) ? $r('app.color.accent_blue_bg') :
              $r('app.color.page_background'))
            .borderRadius(DesignTokens.radius.sm)
            .onClick(() => {
              this.viewModel.onSelectDevice(device);
            })
          }, (device: MtaDiscoveredDevice, index: number) => `${index}-${device.bleAddress}`)
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

  // ── 发送链路 ──

  @Builder
  buildLinkSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_send_link_section') })
      this.infoRow({ label: $r('app.string.mta_send_stage'), value: this.viewModel.stageText() })
      this.infoRow({
        label: $r('app.string.mta_send_task_id'),
        value: this.viewModel.sessionTaskId().length > 0 ? this.viewModel.sessionTaskId() :
          $r('app.string.mta_send_none')
      })
      this.infoRow({
        label: $r('app.string.mta_send_group_ssid'),
        value: this.viewModel.sessionSsid().length > 0 ? this.viewModel.sessionSsid() :
          $r('app.string.mta_send_none')
      })
      this.infoRow({
        label: $r('app.string.mta_send_local_mac'),
        value: this.viewModel.sessionMac().length > 0 ? this.viewModel.sessionMac() :
          $r('app.string.mta_send_none')
      })
      this.infoRow({
        label: $r('app.string.mta_send_go_ip'),
        value: this.viewModel.sessionGoIp().length > 0 ? this.viewModel.sessionGoIp() :
          $r('app.string.mta_send_none')
      })

      if (this.viewModel.state.lastError.length > 0) {
        Text(this.viewModel.state.lastError)
          .fontSize(DesignTokens.font.captionM)
          .fontColor($r('app.color.danger_red'))
          .width('100%')
          .wordBreak(WordBreak.BREAK_ALL)
      }

      Row() {
        Text($r('app.string.mta_send_plain_credential'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.viewModel.plainCredentialMode })
          .onChange((isOn: boolean) => {
            this.viewModel.plainCredentialMode = isOn;
          })
      }
      .width('100%')
      .margin({ top: DesignTokens.space.tiny })

      Button($r('app.string.mta_send_start_send'))
        .width('100%')
        .height(DesignTokens.size.inlineButton)
        .fontSize(DesignTokens.font.bodyS)
        .backgroundColor($r('app.color.accent_blue'))
        .fontColor($r('app.color.text_on_color'))
        .borderRadius(DesignTokens.radius.sm)
        .margin({ top: DesignTokens.space.tiny })
        .enabled(this.viewModel.canSend())
        .onClick(() => {
          this.viewModel.onSendToDevice();
        })
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

  // ── 文件选择 ──

  @Builder
  buildFilesSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_send_files_section') })
      if (this.viewModel.pendingFiles.length === 0) {
        this.infoRow({ label: $r('app.string.mta_send_no_files'), value: '' })
      } else {
        Column({ space: DesignTokens.space.mini }) {
          ForEach(this.viewModel.pendingFiles, (file: MtaSendFile, index: number) => {
            Row() {
              Text(file.displayName)
                .fontSize(DesignTokens.font.bodyS)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Button($r('app.string.mta_send_remove_file'))
                .height(DesignTokens.size.inlineButton)
                .fontSize(DesignTokens.font.captionM)
                .backgroundColor($r('app.color.border_light'))
                .fontColor($r('app.color.text_primary'))
                .borderRadius(DesignTokens.radius.sm)
                .onClick(() => {
                  this.viewModel.onRemoveFile(index);
                })
            }
            .width('100%')
            .padding(DesignTokens.space.xxs)
          }, (file: MtaSendFile, index: number) => `${index}-${file.uri}`)
        }
        .width('100%')
      }

      this.infoRow({ label: $r('app.string.mta_send_total_size'), value: this.viewModel.pendingTotalText() })

      Row({ space: DesignTokens.space.tiny }) {
        this.actionButton($r('app.string.mta_send_pick_files'), $r('app.color.accent_blue'), () => {
          this.viewModel.onPickFiles();
        })
        this.actionButton($r('app.string.mta_send_clear_files'), $r('app.color.danger_red'), () => {
          this.viewModel.onClearFiles();
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

  // ── 传输进度 ──

  @Builder
  buildProgressSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_send_progress_section') })
      Progress({ value: this.viewModel.progressPercent(), total: 100, type: ProgressType.Linear })
        .width('100%')
        .margin({ top: DesignTokens.space.tiny, bottom: DesignTokens.space.tiny })
      this.infoRow({ label: $r('app.string.mta_send_progress'), value: this.viewModel.progressText() })
      this.infoRow({
        label: $r('app.string.mta_send_current_file'),
        value: this.viewModel.state.currentFileName.length > 0 ? this.viewModel.state.currentFileName :
          $r('app.string.mta_send_none')
      })
      if (this.viewModel.isTransferring()) {
        Button($r('app.string.mta_send_cancel'))
          .width('100%')
          .height(DesignTokens.size.inlineButton)
          .fontSize(DesignTokens.font.bodyS)
          .backgroundColor($r('app.color.danger_red'))
          .fontColor($r('app.color.text_on_color'))
          .borderRadius(DesignTokens.radius.sm)
          .margin({ top: DesignTokens.space.tiny })
          .onClick(() => {
            this.viewModel.onCancel();
          })
      }
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
      this.sectionTitle({ title: $r('app.string.mta_send_guidance_section') })
      Text($r('app.string.mta_send_guidance_text'))
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
        Text($r('app.string.mta_send_log_section'))
          .fontSize(DesignTokens.font.subtitleM)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Button($r('app.string.mta_send_copy_logs'))
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
        Button($r('app.string.mta_send_clear_logs'))
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
        this.infoRow({ label: $r('app.string.mta_send_no_logs'), value: '' })
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

// 路由表引用：MtaSendPageBuilder(name, param)
@Builder
export function MtaSendPageBuilder(_name: string, _param: Object) {
  MtaSendPage()
}
