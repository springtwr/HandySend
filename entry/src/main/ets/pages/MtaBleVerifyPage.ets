/**
 * MtaBleVerifyPage.ets — MTA BLE 验证页
 *
 * 开发者验证页面：分区块真机实测 HarmonyOS BLE 广播 / GATT Server / 扫描 / GATT Client。
 * 布局参照 MtaP2pVerifyPage（NavDestination + 断点限宽 + 卡片式分区）。
 * 每步操作结果统一写入 ViewModel 日志流。
 */

import { uiObserver } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { DesignTokens } from '../common/DesignTokens';
import { LogLevels } from '../common/LogLevels';
import { getMaxContentWidth, getPageMargin, isTabletPortrait } from '../common/Breakpoints';
import { MtaBleVerifyViewModel } from '../viewmodel/MtaBleVerifyViewModel';
import { VerifyLogEntry, ScannedMtaDeviceView } from '../model/mta/BleVerifyModels';
import { copyText } from '../utils/ClipboardUtil';

// @Builder 按引用传递所需的参数类（对象字面量需显式类型）
class VerifyRowParam {
  label: ResourceStr = '';
  value: ResourceStr = '';
}

class SectionTitleParam {
  title: ResourceStr = '';
}

@ComponentV2
export struct MtaBleVerifyPage {
  // 系统宽度断点（随窗口尺寸变化自动刷新，宽屏限宽用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: MtaBleVerifyViewModel = new MtaBleVerifyViewModel()
  // NavDestination 返回栈（onReady 注入）
  private pathStack: NavPathStack = new NavPathStack()

  aboutToAppear(): void {
    this.viewModel.loadInitial(this.getUIContext().getHostContext());
  }

  aboutToDisappear(): void {
    // 页面退出时释放全部 BLE 资源并反注册事件
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
            // ── 蓝牙状态与权限 ──
            this.buildBluetoothSection()
            // ── BLE 广播 ──
            this.buildAdvertiseSection()
            // ── GATT Server ──
            this.buildGattSection()
            // ── BLE 扫描 ──
            this.buildScanSection()
            // ── GATT Client ──
            this.buildGattClientSection()
            // ── 验证指引 ──
            this.buildGuidanceSection()
            // ── 验证日志 ──
            this.buildLogSection()
            // ── 一键清理 ──
            Button($r('app.string.mta_ble_verify_cleanup'))
              .width('100%')
              .height(DesignTokens.size.thumbSm)
              .backgroundColor($r('app.color.danger_red'))
              .fontColor($r('app.color.text_on_color'))
              .borderRadius(DesignTokens.radius.md)
              .margin({ bottom: DesignTokens.space.md })
              .onClick(() => {
                this.viewModel.cleanupAll();
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
    .title($r('app.string.mta_ble_verify_title'), { backgroundColor: $r('app.color.page_background') })
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }

  // ── 通用卡片容器与行组件 ──

  @Builder
  sectionTitle(param: SectionTitleParam) {
    Text(param.title)
      .fontSize(DesignTokens.font.subtitleM)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_primary'))
      .width('100%')
      .padding({ bottom: DesignTokens.space.tiny })
  }

  @Builder
  infoRow(param: VerifyRowParam) {
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
  sectionDesc(text: ResourceStr) {
    Text(text)
      .fontSize(DesignTokens.font.bodyS)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ top: DesignTokens.space.xxs, bottom: DesignTokens.space.tiny })
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

  // ── 蓝牙状态与权限 ──

  @Builder
  buildBluetoothSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_ble_verify_bt_section') })

      this.infoRow({ label: $r('app.string.mta_ble_verify_bt_state'), value: this.viewModel.bluetoothStateText })
      this.infoRow({
        label: $r('app.string.mta_ble_verify_permission_state'),
        value: this.viewModel.permissionChecked ?
          (this.viewModel.permissionGranted ? $r('app.string.mta_ble_verify_permission_granted') :
            $r('app.string.mta_ble_verify_permission_denied')) : $r('app.string.mta_ble_verify_permission_unknown')
      })

      Row({ space: DesignTokens.space.tiny }) {
        this.actionButton($r('app.string.mta_ble_verify_request_permission'), $r('app.color.accent_blue'), () => {
          let ctx = this.getUIContext().getHostContext();
          if (ctx !== undefined) {
            this.viewModel.onRequestPermission(ctx);
          }
        })
        this.actionButton($r('app.string.mta_ble_verify_enable_bt'), $r('app.color.accent_blue'), () => {
          this.viewModel.onEnableBluetooth();
        })
        this.actionButton($r('app.string.mta_ble_verify_refresh_bt'), $r('app.color.border_light'), () => {
          this.viewModel.refreshBluetoothState();
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

  // ── BLE 广播（接收端） ──

  @Builder
  buildAdvertiseSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_ble_verify_advertise_section') })
      this.sectionDesc($r('app.string.mta_ble_verify_advertise_hint'))

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

      this.infoRow({
        label: $r('app.string.mta_ble_verify_advertise_state'),
        value: this.viewModel.advertising ? $r('app.string.mta_ble_verify_advertise_running') :
          $r('app.string.mta_ble_verify_advertise_stopped')
      })
      this.infoRow({ label: $r('app.string.mta_ble_verify_sender_id'), value: this.viewModel.senderIdHex })

      Row({ space: DesignTokens.space.tiny }) {
        this.actionButton($r('app.string.mta_ble_verify_start_advertise'), $r('app.color.accent_blue'), () => {
          this.viewModel.onStartAdvertise();
        })
        this.actionButton($r('app.string.mta_ble_verify_stop_advertise'), $r('app.color.danger_red'), () => {
          this.viewModel.onStopAdvertise();
        })
      }
      .width('100%')
      .margin({ top: DesignTokens.space.tiny })

      if (this.viewModel.advPreview.length > 0) {
        this.sectionDesc($r('app.string.mta_ble_verify_adv_preview'))
        Text(this.viewModel.advPreview)
          .fontSize(DesignTokens.font.captionM)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .wordBreak(WordBreak.BREAK_ALL)
      }
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

  // ── GATT Server（接收端） ──

  @Builder
  buildGattSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_ble_verify_gatt_section') })
      this.sectionDesc($r('app.string.mta_ble_verify_gatt_hint'))

      this.infoRow({
        label: $r('app.string.mta_ble_verify_gatt_state'),
        value: this.viewModel.gattRunning ? $r('app.string.mta_ble_verify_gatt_running') :
          $r('app.string.mta_ble_verify_gatt_stopped')
      })
      this.infoRow({
        label: $r('app.string.mta_ble_verify_public_key'),
        value: this.viewModel.gattPublicKey.length > 0 ? this.viewModel.gattPublicKey :
          $r('app.string.mta_ble_verify_none')
      })
      this.infoRow({
        label: $r('app.string.mta_ble_verify_client_addr'),
        value: this.viewModel.gattClientId.length > 0 ? this.viewModel.gattClientId :
          $r('app.string.mta_ble_verify_none')
      })
      this.infoRow({
        label: $r('app.string.mta_ble_verify_read_count'),
        value: String(this.viewModel.gattReadCount)
      })
      this.infoRow({
        label: $r('app.string.mta_ble_verify_write_buffer'),
        value: `${this.viewModel.gattWriteBufferLength} B`
      })

      Row({ space: DesignTokens.space.tiny }) {
        this.actionButton($r('app.string.mta_ble_verify_start_gatt'), $r('app.color.accent_blue'), () => {
          this.viewModel.onStartGatt();
        })
        this.actionButton($r('app.string.mta_ble_verify_stop_gatt'), $r('app.color.danger_red'), () => {
          this.viewModel.onStopGatt();
        })
      }
      .width('100%')
      .margin({ top: DesignTokens.space.tiny })

      if (this.viewModel.lastPayloadText.length > 0) {
        this.sectionDesc($r('app.string.mta_ble_verify_last_payload'))
        Text(this.viewModel.lastPayloadText)
          .fontSize(DesignTokens.font.captionM)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .wordBreak(WordBreak.BREAK_ALL)
      }
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

  // ── BLE 扫描（发送端） ──

  @Builder
  buildScanSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_ble_verify_scan_section') })
      this.sectionDesc($r('app.string.mta_ble_verify_scan_hint'))

      this.infoRow({
        label: $r('app.string.mta_ble_verify_scan_state'),
        value: this.viewModel.scanning ? $r('app.string.mta_ble_verify_scanning') :
          $r('app.string.mta_ble_verify_not_scanning')
      })

      Row({ space: DesignTokens.space.tiny }) {
        this.actionButton($r('app.string.mta_ble_verify_start_scan'), $r('app.color.accent_blue'), () => {
          this.viewModel.onStartScan();
        })
        this.actionButton($r('app.string.mta_ble_verify_stop_scan'), $r('app.color.danger_red'), () => {
          this.viewModel.onStopScan();
        })
      }
      .width('100%')
      .margin({ top: DesignTokens.space.tiny })

      Text($r('app.string.mta_ble_verify_device_list'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: DesignTokens.space.tiny })

      if (this.viewModel.scannedDevices.length === 0) {
        this.infoRow({ label: $r('app.string.mta_ble_verify_no_device'), value: '' })
      } else {
        this.sectionDesc($r('app.string.mta_ble_verify_click_to_fill'))
        Column({ space: DesignTokens.space.mini }) {
          Repeat(this.viewModel.scannedDevices).each((ri: RepeatItem<ScannedMtaDeviceView>) => {
            Column() {
              Row() {
                Text(ri.item.deviceName)
                  .fontSize(DesignTokens.font.bodyM)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                Text(`${ri.item.rssi} dBm`)
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')

              Text(`id=${ri.item.deviceId} senderId=${ri.item.senderIdHex} brand=${ri.item.brandName} ` +
                `5GHz=${ri.item.is5Ghz ? 'Y' : 'N'} time=${ri.item.foundTimeText}`)
                .fontSize(DesignTokens.font.captionM)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .wordBreak(WordBreak.BREAK_ALL)
            }
            .width('100%')
            .padding(DesignTokens.space.tiny)
            .backgroundColor($r('app.color.page_background'))
            .borderRadius(DesignTokens.radius.sm)
            .onClick(() => {
              this.viewModel.onSelectTargetDevice(ri.item.deviceId);
            })
          }).key((item: ScannedMtaDeviceView, index: number) => item.deviceId)
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

  // ── GATT Client（发送端） ──

  @Builder
  buildGattClientSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_ble_verify_gatt_client_section') })
      this.sectionDesc($r('app.string.mta_ble_verify_gatt_client_hint'))

      Row() {
        Text($r('app.string.mta_ble_verify_target_device'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        TextInput({ text: this.viewModel.gattClientTargetInput })
          .layoutWeight(1)
          .fontSize(DesignTokens.font.bodyM)
          .onChange((value: string) => {
            this.viewModel.gattClientTargetInput = value;
          })
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      this.infoRow({
        label: $r('app.string.mta_ble_verify_client_state'),
        value: this.viewModel.gattClientState.connectionStateText
      })

      Row({ space: DesignTokens.space.tiny }) {
        this.actionButton($r('app.string.mta_ble_verify_connect'), $r('app.color.accent_blue'), () => {
          this.viewModel.onConnectGattClient();
        })
        this.actionButton($r('app.string.mta_ble_verify_read_device_info'), $r('app.color.accent_blue'), () => {
          this.viewModel.onReadRemoteDeviceInfo();
        })
        this.actionButton($r('app.string.mta_ble_verify_disconnect'), $r('app.color.danger_red'), () => {
          this.viewModel.onDisconnectGattClient();
        })
      }
      .width('100%')
      .margin({ top: DesignTokens.space.tiny })

      if (this.viewModel.gattClientState.deviceInfoText.length > 0) {
        this.sectionDesc($r('app.string.mta_ble_verify_device_info'))
        Text(this.viewModel.gattClientState.deviceInfoText)
          .fontSize(DesignTokens.font.captionM)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .wordBreak(WordBreak.BREAK_ALL)
      }
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

  // ── 验证指引 ──

  @Builder
  buildGuidanceSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_ble_verify_guidance_section') })
      Text($r('app.string.mta_ble_verify_guidance_text'))
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

  // ── 验证日志 ──

  @Builder
  buildLogSection() {
    Column() {
      Row() {
        Text($r('app.string.mta_ble_verify_log_section'))
          .fontSize(DesignTokens.font.subtitleM)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Button($r('app.string.mta_ble_verify_copy_logs'))
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
        Button($r('app.string.mta_ble_verify_clear_logs'))
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
        this.infoRow({ label: $r('app.string.mta_ble_verify_no_logs'), value: '' })
      } else {
        Column({ space: DesignTokens.space.mini }) {
          Repeat(this.viewModel.logs).each((ri: RepeatItem<VerifyLogEntry>) => {
            Column() {
              Row() {
                Text(ri.item.timeText)
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ right: DesignTokens.space.tiny })
                Text(ri.item.source)
                  .fontSize(DesignTokens.font.captionM)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(ri.item.level === LogLevels.ERROR ? $r('app.color.danger_red') : $r('app.color.text_primary'))
                  .layoutWeight(1)
              }
              .width('100%')

              Text(ri.item.content)
                .fontSize(DesignTokens.font.captionM)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .wordBreak(WordBreak.BREAK_ALL)
            }
            .width('100%')
            .padding(DesignTokens.space.tiny)
            .backgroundColor($r('app.color.page_background'))
            .borderRadius(DesignTokens.radius.sm)
          }).key((item: VerifyLogEntry, index: number) => index.toString())
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

// 路由表引用：MtaBleVerifyPageBuilder(name, param)
@Builder
export function MtaBleVerifyPageBuilder(_name: string, _param: Object) {
  MtaBleVerifyPage()
}
