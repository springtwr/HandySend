/**
 * MtaP2pVerifyPage.ets — MTA P2P 验证页
 *
 * 开发者验证页面：分区块真机实测 HarmonyOS WiFi P2P API 行为。
 * 布局参照 DebugPage（NavDestination + 断点限宽 + 卡片式分区）。
 * 每步操作结果统一写入 ViewModel 日志流，日志条目可点击添加人工备注。
 */

import { promptAction, uiObserver } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { DesignTokens } from '../common/DesignTokens';
import { LogLevels } from '../common/LogLevels';
import { getMaxContentWidth, getPageMargin, isTabletPortrait } from '../common/Breakpoints';
import {
  MtaP2pVerifyViewModel,
  GO_BAND_AUTO,
  GO_BAND_2GHZ,
  GO_BAND_5GHZ
} from '../viewmodel/MtaP2pVerifyViewModel';
import { VerifyLogEntry, NetworkListEntry, P2pDiscoveredDeviceView } from '../model/mta/P2pVerifyModels';
import { PRESET_STANDARD, PRESET_PERSISTENT, PRESET_MTA_CREDENTIAL } from '../model/mta/P2pVerifyModels';
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
export struct MtaP2pVerifyPage {
  // 系统宽度断点（随窗口尺寸变化自动刷新，宽屏限宽用）
  @Env(SystemProperties.BREAK_POINT) breakpointInfo: uiObserver.WindowSizeLayoutBreakpointInfo
  @Local viewModel: MtaP2pVerifyViewModel = new MtaP2pVerifyViewModel();
  // NavDestination 返回栈（onReady 注入）
  private pathStack: NavPathStack = new NavPathStack()
  // 备注弹窗状态
  @Local remarkInput: string = ''
  @Local activeRemarkLogIndex: number = -1
  // HTTP 服务端口输入
  @Local httpPortInput: string = '8080'
  // 当前打开的弹窗 id（关闭时使用）
  private activeDialogId: number = -1

  aboutToAppear(): void {
    // 注入应用上下文（P2P 发现申请定位权限需要）
    this.viewModel.injectContext(this.getUIContext().getHostContext());
    this.viewModel.loadInitial();
  }

  aboutToDisappear(): void {
    // 页面退出时反注册事件并清理资源
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
            // ── 建组验证 ──
            this.buildGroupSection()
            // ── 本机 p2p0 MAC 结论 ──
            this.buildDeviceSection()
            // ── 凭据直连 ──
            this.buildCredentialSection()
            // ── p2pConnect 实验 ──
            this.buildP2pConnectExperimentSection()
            // ── 网络状态 ──
            this.buildNetworkSection()
            // ── HTTP 服务 ──
            this.buildHttpSection()
            // ── 与安卓设备互通验证 ──
            this.buildInteropSection()
            // ── 验证日志 ──
            this.buildLogSection()
            // ── 一键清理 ──
            Button($r('app.string.mta_p2p_verify_cleanup'))
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
    .title($r('app.string.mta_p2p_verify_title'), { backgroundColor: $r('app.color.page_background') })
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }

  // ── 通用卡片容器与行组件 ──

  @Builder
  sectionCard(param: SectionTitleParam) {
    Column() {
      this.sectionTitle(param)
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

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

  // ── 建组验证 ──

  @Builder
  buildGroupSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_p2p_verify_group_section') })

      // 群组名输入
      Row() {
        Text($r('app.string.mta_p2p_verify_group_name_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        TextInput({ text: this.viewModel.groupNameInput })
          .layoutWeight(1)
          .fontSize(DesignTokens.font.bodyM)
          .onChange((value: string) => {
            this.viewModel.groupNameInput = value;
          })
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      // 密码输入
      Row() {
        Text($r('app.string.mta_p2p_verify_passphrase_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        TextInput({ text: this.viewModel.passphraseInput })
          .layoutWeight(1)
          .fontSize(DesignTokens.font.bodyM)
          .onChange((value: string) => {
            this.viewModel.passphraseInput = value;
          })
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      // 频段选择
      Row() {
        Text($r('app.string.mta_p2p_verify_band_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        Row({ space: DesignTokens.space.tiny }) {
          this.bandButton(GO_BAND_AUTO, $r('app.string.mta_p2p_verify_band_auto'))
          this.bandButton(GO_BAND_2GHZ, $r('app.string.mta_p2p_verify_band_2ghz'))
          this.bandButton(GO_BAND_5GHZ, $r('app.string.mta_p2p_verify_band_5ghz'))
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      // 操作按钮行
      Row({ space: DesignTokens.space.tiny }) {
        this.actionButton($r('app.string.mta_p2p_verify_generate'), $r('app.color.border_light'), () => {
          this.viewModel.refreshNames();
        })
        this.actionButton($r('app.string.mta_p2p_verify_create_group'), $r('app.color.accent_blue'), () => {
          this.viewModel.onCreateGroup();
        })
        this.actionButton($r('app.string.mta_p2p_verify_remove_group'), $r('app.color.danger_red'), () => {
          this.viewModel.onRemoveGroup();
        })
      }
      .width('100%')
      .margin({ top: DesignTokens.space.tiny })

      // 群组信息展示
      if (this.viewModel.groupInfo === null) {
        this.infoRow({ label: $r('app.string.mta_p2p_verify_group_no_group'), value: '' })
      } else {
        this.infoRow({ label: $r('app.string.mta_p2p_verify_group_name_label'),
          value: this.viewModel.groupInfo.groupName })
        this.infoRow({ label: $r('app.string.mta_p2p_verify_passphrase_label'),
          value: this.viewModel.groupInfo.passphrase })
        this.infoRow({ label: $r('app.string.ip_address_label'), value: this.viewModel.groupInfo.goIpAddress })
        this.infoRow({ label: $r('app.string.default_network_badge'),
          value: this.viewModel.groupInfo.isGo ? 'isP2pGo=true' : 'isP2pGo=false' })
        this.infoRow({ label: $r('app.string.device_fingerprint_label'),
          value: 'ownerAddr=' + this.viewModel.groupInfo.ownerAddress })
        this.infoRow({ label: $r('app.string.network_interface_label'),
          value: this.viewModel.groupInfo.interfaceName })
        this.infoRow({ label: $r('app.string.mta_p2p_verify_band_label'),
          value: 'frequency=' + this.viewModel.groupInfo.frequency })
        this.infoRow({ label: $r('app.string.discovered_devices_count'),
          value: 'clientCount=' + this.viewModel.groupInfo.clientCount })
        Text('clients: ' + (this.viewModel.groupInfo.clientDeviceAddresses.length > 0 ?
          this.viewModel.groupInfo.clientDeviceAddresses.join(', ') : '-'))
          .fontSize(DesignTokens.font.captionM)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .wordBreak(WordBreak.BREAK_ALL)
          .padding({ top: DesignTokens.space.xxs })
      }

      Button($r('app.string.mta_p2p_verify_query_group'))
        .height(DesignTokens.size.inlineButton)
        .fontSize(DesignTokens.font.bodyS)
        .backgroundColor($r('app.color.accent_blue_bg'))
        .fontColor($r('app.color.ip_blue_text'))
        .borderRadius(DesignTokens.radius.sm)
        .margin({ top: DesignTokens.space.tiny })
        .onClick(() => {
          this.viewModel.onQueryGroup();
        })
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

  @Builder
  bandButton(band: number, label: ResourceStr) {
    Button(label)
      .height(DesignTokens.size.inlineButton)
      .fontSize(DesignTokens.font.bodyS)
      .backgroundColor(this.viewModel.selectedGoBand === band ? $r('app.color.accent_blue') : $r('app.color.border_light'))
      .fontColor($r('app.color.text_on_color'))
      .borderRadius(DesignTokens.radius.sm)
      .onClick(() => {
        this.viewModel.selectedGoBand = band;
      })
  }

  // ── 本机 p2p0 MAC 验证结论 ──

  @Builder
  buildDeviceSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_p2p_verify_device_section') })

      // getCurrentGroup().ownerInfo.deviceAddress 实测返回本机真实 p2p0 MAC（建组后可用）
      this.infoRow({ label: $r('app.string.mta_p2p_verify_device_owner_label'),
        value: this.viewModel.groupInfo === null || this.viewModel.groupInfo.ownerAddress.length === 0 ?
          $r('app.string.mta_p2p_verify_group_no_group') : this.viewModel.groupInfo.ownerAddress })

      this.sectionDesc($r('app.string.mta_p2p_verify_device_hint'))
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

  // ── 凭据直连 ──

  @Builder
  buildCredentialSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_p2p_verify_credential_section') })

      Row() {
        Text($r('app.string.mta_p2p_verify_credential_ssid'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        TextInput({ placeholder: 'DIRECT-xxxx', text: this.viewModel.credentialSsidInput })
          .layoutWeight(1)
          .fontSize(DesignTokens.font.bodyM)
          .onChange((value: string) => {
            this.viewModel.credentialSsidInput = value;
          })
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      Row() {
        Text($r('app.string.mta_p2p_verify_credential_psk'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        TextInput({ placeholder: '8 位密码', text: this.viewModel.credentialPskInput })
          .layoutWeight(1)
          .fontSize(DesignTokens.font.bodyM)
          .onChange((value: string) => {
            this.viewModel.credentialPskInput = value;
          })
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      Row() {
        Text($r('app.string.mta_p2p_verify_with_user_action'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.viewModel.withUserAction })
          .onChange((isOn: boolean) => {
            this.viewModel.withUserAction = isOn;
          })
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      Row({ space: DesignTokens.space.tiny }) {
        this.actionButton($r('app.string.mta_p2p_verify_connect'), $r('app.color.accent_blue'), () => {
          this.viewModel.onConnectByCredential();
        })
        this.actionButton($r('app.string.mta_p2p_verify_disconnect'), $r('app.color.border_light'), () => {
          this.viewModel.onDisconnectCandidate();
        })
      }
      .width('100%')
      .margin({ top: DesignTokens.space.tiny })

      if (this.viewModel.credentialResult.length > 0) {
        this.sectionDesc(this.viewModel.credentialResult)
      }
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

  // ── p2pConnect 实验 ──

  @Builder
  addrTypeButton(type: number, label: ResourceStr) {
    Button(label)
      .height(DesignTokens.size.inlineButton)
      .fontSize(DesignTokens.font.bodyS)
      .backgroundColor(this.viewModel.p2pAddressTypeIndex === type ? $r('app.color.accent_blue') : $r('app.color.border_light'))
      .fontColor($r('app.color.text_on_color'))
      .borderRadius(DesignTokens.radius.sm)
      .onClick(() => {
        this.viewModel.p2pAddressTypeIndex = type;
      })
  }

  @Builder
  p2pBandButton(band: number, label: ResourceStr) {
    Button(label)
      .height(DesignTokens.size.inlineButton)
      .fontSize(DesignTokens.font.bodyS)
      .backgroundColor(this.viewModel.p2pGoBandIndex === band ? $r('app.color.accent_blue') : $r('app.color.border_light'))
      .fontColor($r('app.color.text_on_color'))
      .borderRadius(DesignTokens.radius.sm)
      .onClick(() => {
        this.viewModel.p2pGoBandIndex = band;
      })
  }

  @Builder
  buildP2pConnectExperimentSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_p2p_verify_p2p_section') })

      // 设备地址输入（人工采集：A 组取群组快照客户端地址，C 组取 MVP 接收页 P2pInfo.mac）
      Row() {
        Text($r('app.string.mta_p2p_verify_p2p_device_addr'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        TextInput({ placeholder: 'XX:XX:XX:XX:XX:XX', text: this.viewModel.p2pDeviceAddressInput })
          .layoutWeight(1)
          .fontSize(DesignTokens.font.bodyM)
          .onChange((value: string) => {
            this.viewModel.p2pDeviceAddressInput = value;
          })
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      // 地址类型选择
      Row() {
        Text($r('app.string.mta_p2p_verify_p2p_addr_type'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        Row({ space: DesignTokens.space.tiny }) {
          this.addrTypeButton(0, $r('app.string.mta_p2p_verify_p2p_addr_random'))
          this.addrTypeButton(1, $r('app.string.mta_p2p_verify_p2p_addr_real'))
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      // netId 输入
      Row() {
        Text($r('app.string.mta_p2p_verify_p2p_netid'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        TextInput({ placeholder: '-1 临时 / -2 永久', text: this.viewModel.p2pNetIdInput })
          .layoutWeight(1)
          .fontSize(DesignTokens.font.bodyM)
          .onChange((value: string) => {
            this.viewModel.p2pNetIdInput = value;
          })
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      // 组名/SSID 输入
      Row() {
        Text($r('app.string.mta_p2p_verify_p2p_group_name'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        TextInput({ placeholder: 'DIRECT-xxxx', text: this.viewModel.p2pGroupNameInput })
          .layoutWeight(1)
          .fontSize(DesignTokens.font.bodyM)
          .onChange((value: string) => {
            this.viewModel.p2pGroupNameInput = value;
          })
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      // 密码输入
      Row() {
        Text($r('app.string.mta_p2p_verify_p2p_passphrase'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        TextInput({ placeholder: '8 位密码', text: this.viewModel.p2pPassphraseInput })
          .layoutWeight(1)
          .fontSize(DesignTokens.font.bodyM)
          .onChange((value: string) => {
            this.viewModel.p2pPassphraseInput = value;
          })
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      // 频段选择
      Row() {
        Text($r('app.string.mta_p2p_verify_band_label'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        Row({ space: DesignTokens.space.tiny }) {
          this.p2pBandButton(GO_BAND_AUTO, $r('app.string.mta_p2p_verify_band_auto'))
          this.p2pBandButton(GO_BAND_2GHZ, $r('app.string.mta_p2p_verify_band_2ghz'))
          this.p2pBandButton(GO_BAND_5GHZ, $r('app.string.mta_p2p_verify_band_5ghz'))
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      // 场景预设按钮行
      Row({ space: DesignTokens.space.tiny }) {
        this.actionButton($r('app.string.mta_p2p_verify_p2p_preset_standard'), $r('app.color.border_light'), () => {
          this.viewModel.onApplyPreset(PRESET_STANDARD);
        })
        this.actionButton($r('app.string.mta_p2p_verify_p2p_preset_persistent'), $r('app.color.border_light'), () => {
          this.viewModel.onApplyPreset(PRESET_PERSISTENT);
        })
        this.actionButton($r('app.string.mta_p2p_verify_p2p_preset_mta'), $r('app.color.accent_blue'), () => {
          this.viewModel.onApplyPreset(PRESET_MTA_CREDENTIAL);
        })
      }
      .width('100%')
      .margin({ top: DesignTokens.space.tiny })

      // 连接动作按钮行
      Row({ space: DesignTokens.space.tiny }) {
        this.actionButton($r('app.string.mta_p2p_verify_p2p_connect'), $r('app.color.accent_blue'), () => {
          this.viewModel.onP2pConnect();
        })
        this.actionButton($r('app.string.mta_p2p_verify_p2p_cancel'), $r('app.color.danger_red'), () => {
          this.viewModel.onP2pCancelConnect();
        })
      }
      .width('100%')
      .margin({ top: DesignTokens.space.tiny })

      if (this.viewModel.p2pConnectResult.length > 0) {
        this.sectionDesc(this.viewModel.p2pConnectResult)
      }

      // P2P 设备发现子节
      Text($r('app.string.mta_p2p_verify_p2p_discover'))
        .fontSize(DesignTokens.font.bodyM)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })

      Row({ space: DesignTokens.space.tiny }) {
        this.actionButton($r('app.string.mta_p2p_verify_p2p_discover_start'), $r('app.color.accent_blue'), () => {
          this.viewModel.onStartDiscovery();
        })
        this.actionButton($r('app.string.mta_p2p_verify_p2p_discover_stop'), $r('app.color.border_light'), () => {
          this.viewModel.onStopDiscovery();
        })
      }
      .width('100%')

      if (this.viewModel.discoveredDevices.length > 0) {
        Column({ space: DesignTokens.space.mini }) {
          Repeat(this.viewModel.discoveredDevices).each((ri: RepeatItem<P2pDiscoveredDeviceView>) => {
            Column() {
              Row() {
                Text(ri.item.deviceName.length > 0 ? ri.item.deviceName : ri.item.deviceAddress)
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                Text(ri.item.deviceAddress)
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.text_secondary'))
                  .wordBreak(WordBreak.BREAK_ALL)
              }
              .width('100%')

              Row({ space: DesignTokens.space.tiny }) {
                Button($r('app.string.mta_p2p_verify_p2p_discover_connect'))
                  .height(DesignTokens.size.inlineButton)
                  .fontSize(DesignTokens.font.bodyS)
                  .backgroundColor($r('app.color.accent_blue'))
                  .fontColor($r('app.color.text_on_color'))
                  .borderRadius(DesignTokens.radius.sm)
                  .onClick(() => {
                    this.viewModel.onConnectDiscoveredDevice(ri.item);
                  })
                Button($r('app.string.mta_p2p_verify_p2p_discover_fill'))
                  .height(DesignTokens.size.inlineButton)
                  .fontSize(DesignTokens.font.bodyS)
                  .backgroundColor($r('app.color.border_light'))
                  .fontColor($r('app.color.text_primary'))
                  .borderRadius(DesignTokens.radius.sm)
                  .onClick(() => {
                    this.viewModel.onPickDiscoveredDevice(ri.item);
                  })
              }
              .width('100%')
              .justifyContent(FlexAlign.End)
              .margin({ top: DesignTokens.space.xxs })
            }
            .width('100%')
            .padding(DesignTokens.space.tiny)
            .backgroundColor($r('app.color.page_background'))
            .borderRadius(DesignTokens.radius.sm)
          }).key((item: P2pDiscoveredDeviceView, index: number) => index.toString())
        }
        .width('100%')
        .margin({ top: DesignTokens.space.tiny })
      } else {
        this.sectionDesc($r('app.string.mta_p2p_verify_p2p_discover_empty'))
      }

      // 网络列表子节
      Text($r('app.string.mta_p2p_verify_p2p_network_list'))
        .fontSize(DesignTokens.font.bodyM)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })

      Button($r('app.string.mta_p2p_verify_p2p_refresh_nets'))
        .height(DesignTokens.size.inlineButton)
        .fontSize(DesignTokens.font.bodyS)
        .backgroundColor($r('app.color.accent_blue_bg'))
        .fontColor($r('app.color.ip_blue_text'))
        .borderRadius(DesignTokens.radius.sm)
        .width('100%')
        .onClick(() => {
          this.viewModel.onRefreshNetworkList();
        })

      if (this.viewModel.networkList.length > 0) {
        Column({ space: DesignTokens.space.mini }) {
          Repeat(this.viewModel.networkList).each((ri: RepeatItem<NetworkListEntry>) => {
            Column() {
              Text(`${ri.item.netId}  ${ri.item.interfaceName}${ri.item.isLikelyP2p ? '  [疑似P2P]' : ''}`)
                .fontSize(DesignTokens.font.captionM)
                .fontWeight(FontWeight.Medium)
                .fontColor(ri.item.isLikelyP2p ? $r('app.color.accent_blue') : $r('app.color.text_primary'))
                .width('100%')
              Text(ri.item.addresses.length > 0 ? ri.item.addresses.join(', ') : '-')
                .fontSize(DesignTokens.font.captionM)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .wordBreak(WordBreak.BREAK_ALL)
            }
            .width('100%')
            .padding(DesignTokens.space.tiny)
            .backgroundColor($r('app.color.page_background'))
            .borderRadius(DesignTokens.radius.sm)
          }).key((item: NetworkListEntry, index: number) => index.toString())
        }
        .width('100%')
        .margin({ top: DesignTokens.space.tiny })
      }

      // TCP 探测子节
      Text($r('app.string.mta_p2p_verify_p2p_probe'))
        .fontSize(DesignTokens.font.bodyM)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.tiny })

      Row() {
        Text($r('app.string.mta_p2p_verify_p2p_probe_ip'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        TextInput({ placeholder: '192.168.49.1', text: this.viewModel.probeIpInput })
          .layoutWeight(1)
          .fontSize(DesignTokens.font.bodyM)
          .onChange((value: string) => {
            this.viewModel.probeIpInput = value;
          })
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      Row() {
        Text($r('app.string.mta_p2p_verify_p2p_probe_port'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        TextInput({ text: this.viewModel.probePortInput })
          .layoutWeight(1)
          .type(InputType.Number)
          .fontSize(DesignTokens.font.bodyM)
          .onChange((value: string) => {
            this.viewModel.probePortInput = value;
          })
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      Button($r('app.string.mta_p2p_verify_p2p_probe_btn'))
        .height(DesignTokens.size.inlineButton)
        .fontSize(DesignTokens.font.bodyS)
        .backgroundColor($r('app.color.accent_blue'))
        .fontColor($r('app.color.text_on_color'))
        .borderRadius(DesignTokens.radius.sm)
        .width('100%')
        .margin({ top: DesignTokens.space.tiny })
        .onClick(() => {
          this.viewModel.onProbeTcp();
        })

      if (this.viewModel.probeResult !== null) {
        this.sectionDesc(`${this.viewModel.probeResult.targetText}  ${this.viewModel.probeResult.detail}`)
      }
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

  // ── 网络状态 ──

  @Builder
  buildNetworkSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_p2p_verify_network_section') })

      if (this.viewModel.networkSnapshot === null) {
        this.infoRow({ label: $r('app.string.mta_p2p_verify_group_no_group'), value: '' })
      } else {
        this.infoRow({ label: $r('app.string.ip_address_label'),
          value: this.viewModel.networkSnapshot.ipAddressText })
        this.infoRow({ label: $r('app.string.default_network_badge'),
          value: this.viewModel.networkSnapshot.gatewayText })
        this.infoRow({ label: $r('app.string.mta_p2p_verify_band_label'),
          value: this.viewModel.networkSnapshot.netmaskText })
        this.infoRow({ label: 'P2P 状态', value: this.viewModel.networkSnapshot.p2pConnectStateText })
        this.infoRow({ label: 'isGO', value: String(this.viewModel.networkSnapshot.isGroupOwner) })
        // getP2pLinkedInfo().groupOwnerAddr 普通应用返回全零，真实 GO IP 取自 p2pConnectionChange 事件
        this.infoRow({ label: 'GO IP',
          value: this.viewModel.eventGroupOwnerAddr.length > 0 ? this.viewModel.eventGroupOwnerAddr : '-' })
      }

      Button($r('app.string.mta_p2p_verify_refresh_network'))
        .height(DesignTokens.size.inlineButton)
        .fontSize(DesignTokens.font.bodyS)
        .backgroundColor($r('app.color.accent_blue_bg'))
        .fontColor($r('app.color.ip_blue_text'))
        .borderRadius(DesignTokens.radius.sm)
        .margin({ top: DesignTokens.space.tiny })
        .onClick(() => {
          this.viewModel.refreshNetwork();
        })
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

  // ── HTTP 服务 ──

  @Builder
  buildHttpSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_p2p_verify_http_section') })

      this.sectionDesc($r('app.string.mta_p2p_verify_http_hint'))

      Row() {
        Text($r('app.string.mta_p2p_verify_http_port'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        TextInput({ text: this.httpPortInput })
          .layoutWeight(1)
          .type(InputType.Number)
          .fontSize(DesignTokens.font.bodyM)
          .onChange((value: string) => {
            this.httpPortInput = value;
          })
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })

      this.infoRow({ label: '服务状态',
        value: this.viewModel.httpServerState.running ?
          `${this.viewModel.httpServerState.bindAddress}:${this.viewModel.httpServerState.port} (请求 ${this.viewModel.httpServerState.requestCount} 次)` :
          '未运行' })

      Row({ space: DesignTokens.space.tiny }) {
        this.actionButton($r('app.string.mta_p2p_verify_http_start'), $r('app.color.accent_blue'), () => {
          let port = parseInt(this.httpPortInput);
          if (isNaN(port) || port <= 0 || port > 65535) {
            this.viewModel.appendLog('HTTP 服务', '端口无效: ' + this.httpPortInput, LogLevels.ERROR);
            return;
          }
          this.viewModel.onStartHttpServer(port);
        })
        this.actionButton($r('app.string.mta_p2p_verify_http_stop'), $r('app.color.danger_red'), () => {
          this.viewModel.onStopHttpServer();
        })
      }
      .width('100%')
      .margin({ top: DesignTokens.space.tiny })

      Row() {
        Text($r('app.string.mta_p2p_verify_http_url'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.text_secondary'))
          .width('38%')
        TextInput({ placeholder: 'http://192.168.49.1:8080/', text: this.viewModel.httpUrlInput })
          .layoutWeight(1)
          .fontSize(DesignTokens.font.bodyM)
          .onChange((value: string) => {
            this.viewModel.httpUrlInput = value;
          })
      }
      .width('100%')
      .constraintSize({ minHeight: DesignTokens.size.thumbSm })
      .margin({ top: DesignTokens.space.tiny })

      Row({ space: DesignTokens.space.tiny }) {
        this.actionButton($r('app.string.mta_p2p_verify_http_send'), $r('app.color.accent_blue'), () => {
          this.viewModel.onHttpGet();
        })
      }
      .width('100%')

      if (this.viewModel.httpRequestResult.length > 0) {
        this.sectionDesc(this.viewModel.httpRequestResult)
      }
    }
    .width('100%')
    .padding(DesignTokens.space.md)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
  }

  // ── 与安卓设备互通验证 ──

  @Builder
  buildInteropSection() {
    Column() {
      this.sectionTitle({ title: $r('app.string.mta_p2p_verify_interop_section') })

      Text($r('app.string.mta_p2p_verify_interop_hint'))
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
        Text($r('app.string.mta_p2p_verify_log_section'))
          .fontSize(DesignTokens.font.subtitleM)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Button($r('app.string.mta_p2p_verify_copy_logs'))
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
        Button($r('app.string.mta_p2p_verify_clear_logs'))
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

      this.sectionDesc($r('app.string.mta_p2p_verify_remark_hint'))

      if (this.viewModel.logs.length === 0) {
        this.infoRow({ label: $r('app.string.mta_p2p_verify_no_logs'), value: '' })
      } else {
        Column({ space: DesignTokens.space.mini }) {
          Repeat(this.viewModel.logs).each((ri: RepeatItem<VerifyLogEntry>) => {
            Column() {
              Row() {
                Text(ri.item.timeText)
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ right: DesignTokens.space.tiny })
                Text(ri.item.action)
                  .fontSize(DesignTokens.font.captionM)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(ri.item.level === LogLevels.ERROR ? $r('app.color.danger_red') : $r('app.color.text_primary'))
                  .layoutWeight(1)
              }
              .width('100%')

              Text(ri.item.resultText)
                .fontSize(DesignTokens.font.captionM)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .wordBreak(WordBreak.BREAK_ALL)

              if (ri.item.remark.length > 0) {
                Text(`备注: ${ri.item.remark}`)
                  .fontSize(DesignTokens.font.captionM)
                  .fontColor($r('app.color.accent_blue'))
                  .width('100%')
                  .wordBreak(WordBreak.BREAK_ALL)
              }
            }
            .width('100%')
            .padding(DesignTokens.space.tiny)
            .backgroundColor($r('app.color.page_background'))
            .borderRadius(DesignTokens.radius.sm)
            .onClick(() => {
              this.openRemarkDialog(ri.index);
            })
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

  // ── 备注弹窗 ──

  private openRemarkDialog(index: number): void {
    this.activeRemarkLogIndex = index;
    this.remarkInput = '';
    let dialogOptions: promptAction.CustomDialogOptions = {
      builder: () => {
        this.remarkDialog();
      },
      autoCancel: true
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

  private closeActiveDialog(): void {
    if (this.activeDialogId >= 0) {
      try {
        this.getUIContext().getPromptAction().closeCustomDialog(this.activeDialogId);
      } catch (_e) {
        // 忽略关闭失败
      }
      this.activeDialogId = -1;
    }
  }

  @Builder
  remarkDialog() {
    Column() {
      Text($r('app.string.mta_p2p_verify_add_remark_title'))
        .fontSize(DesignTokens.font.subtitleM)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: DesignTokens.space.sm })

      TextInput({ placeholder: $r('app.string.mta_p2p_verify_remark_placeholder'), text: this.remarkInput })
        .width('100%')
        .fontSize(DesignTokens.font.bodyM)
        .onChange((value: string) => {
          this.remarkInput = value;
        })

      Row({ space: DesignTokens.space.tiny }) {
        Button($r('app.string.dialog_cancel'))
          .height(DesignTokens.size.inlineButton)
          .fontSize(DesignTokens.font.bodyM)
          .backgroundColor($r('app.color.border_light'))
          .fontColor($r('app.color.text_primary'))
          .borderRadius(DesignTokens.radius.sm)
          .layoutWeight(1)
          .onClick(() => {
            this.closeActiveDialog();
          })
        Button($r('app.string.dialog_confirm'))
          .height(DesignTokens.size.inlineButton)
          .fontSize(DesignTokens.font.bodyM)
          .backgroundColor($r('app.color.accent_blue'))
          .fontColor($r('app.color.text_on_color'))
          .borderRadius(DesignTokens.radius.sm)
          .layoutWeight(1)
          .onClick(() => {
            this.viewModel.onAddRemark(this.activeRemarkLogIndex, this.remarkInput);
            this.closeActiveDialog();
          })
      }
      .width('100%')
      .margin({ top: DesignTokens.space.md })
    }
    .width('100%')
    .padding(DesignTokens.space.lg)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .constraintSize({ maxWidth: 480 })
  }
}

// 路由表引用：MtaP2pVerifyPageBuilder(name, param)
@Builder
export function MtaP2pVerifyPageBuilder(_name: string, _param: Object) {
  MtaP2pVerifyPage()
}
