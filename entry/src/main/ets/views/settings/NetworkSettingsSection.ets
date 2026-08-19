import {
  deviceInfo
} from '@kit.BasicServicesKit';
import {
  DeviceTypeOption
} from '../../components/settings/SettingsTypes';
import {
  DialogService
} from '../../service/DialogService';
import {
  DesignTokens
} from '../../common/DesignTokens';
import {
  SettingsViewModel
} from '../../viewmodel/SettingsViewModel';

// 网络与设备身份设置分组（服务器重启提示/状态/加密/设备身份/高级设置，从 SettingsContent 拆出）。
@ComponentV2
export struct NetworkSettingsSection {
  @Require @Param viewModel: SettingsViewModel
  @Local isRestarting: boolean = false

  private deviceTypeOptions: Array<DeviceTypeOption> = [
    { value: 'mobile', label: $r('app.string.device_type_mobile'), icon: $r('app.media.ic_public_devices_phone') },
    { value: 'desktop', label: $r('app.string.device_type_desktop'), icon: $r('app.media.ic_device_matebook') },
    { value: 'web', label: $r('app.string.device_type_web'), icon: $r('app.media.ic_browser') },
    { value: 'headless', label: $r('app.string.device_type_headless'), icon: $r('app.media.ic_terminal') },
    { value: 'server', label: $r('app.string.device_type_server'), icon: $r('app.media.ic_server') },
    { value: 'tablet', label: $r('app.string.device_type_tablet'), icon: $r('app.media.ic_device_pad') }
  ]

  private getDefaultAlias(): string {
    return deviceInfo.manufacture + ' ' + deviceInfo.productModel;
  }

  private getCurrentDeviceTypeOption(): DeviceTypeOption {
    for (let i = 0; i < this.deviceTypeOptions.length; i++) {
      if (this.deviceTypeOptions[i].value === this.viewModel.customDeviceType) {
        return this.deviceTypeOptions[i];
      }
    }
    return this.deviceTypeOptions[0];
  }

  private showAliasDialog(): void {
    DialogService.showInputDialog($r('app.string.input_alias_title'), this.viewModel.customAlias, (value: string) => {
      this.viewModel.setAlias(value);
    });
  }

  private showModelDialog(): void {
    DialogService.showInputDialog($r('app.string.input_model_title'), this.viewModel.customDeviceModel, (value: string) => {
      this.viewModel.setDeviceModel(value);
    });
  }

  private showDeviceTypeDialog(): void {
    DialogService.showDeviceTypePicker(this.viewModel.customDeviceType, (value: string) => {
      this.viewModel.setDeviceType(value);
    });
  }

  private showEncryptionNotice(): void {
    DialogService.showEncryptionNotice(() => {
      this.viewModel.setEncryptionEnabled(false);
    });
  }

  // Run an async server action with a minimum 800ms loading animation
  private runServerAction(action: () => Promise<string | void>): void {
    this.isRestarting = true;
    let startTime = Date.now();
    action().then(() => {
      let remaining = 800 - (Date.now() - startTime);
      if (remaining > 0) {
        setTimeout(() => { this.isRestarting = false; }, remaining);
      } else {
        this.isRestarting = false;
      }
    }).catch(() => {
      this.isRestarting = false;
    });
  }

  build() {
    Column() {
if (this.viewModel.serverNeedsRestart) {
  Row() {
    Text($r('app.string.server_needs_restart'))
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.warning_orange'))
      .layoutWeight(1)

    if (this.isRestarting) {
      LoadingProgress()
        .width(20)
        .height(20)
        .color($r('app.color.accent_blue'))
    }
    Button($r('app.string.restart_server'))
      .fontSize(DesignTokens.font.bodyS)
      .height(28)
      .fontColor($r('app.color.text_on_color'))
      .backgroundColor($r('app.color.accent_blue'))
      .borderRadius(DesignTokens.radius.max)
      .enabled(!this.isRestarting)
      .onClick(() => {
        this.runServerAction(() => this.viewModel.restartServer());
      })
  }
  .width('100%')
  .padding(DesignTokens.space.md)
  .borderRadius(DesignTokens.radius.lg)
  .backgroundColor($r('app.color.warning_bg'))
  .border({ width: 1, color: $r('app.color.warning_orange') })
  .margin({ top: DesignTokens.space.md })
}

// ── Network settings ──
Column() {
  Text($r('app.string.settings_network'))
    .fontSize(DesignTokens.font.subtitleM)
    .fontWeight(FontWeight.Medium)
    .fontColor($r('app.color.text_primary'))
    .alignSelf(ItemAlign.Start)

  // Server status (first item in network section)
  Row() {
    if (this.isRestarting) {
      LoadingProgress()
        .width(16)
        .height(16)
        .color($r('app.color.text_secondary'))
        .margin({ right: DesignTokens.space.xs })
    }
    Text(this.viewModel.serverReady ? $r('app.string.server_status_running') : $r('app.string.server_status_offline'))
      .fontSize(DesignTokens.font.bodyM)
      .fontColor(this.viewModel.serverReady ? $r('app.color.success_green') : $r('app.color.text_secondary'))
      .layoutWeight(1)

    Row({ space: DesignTokens.space.xs }) {
      if (!this.viewModel.serverReady) {
        Button($r('app.string.start_server'))
          .fontSize(DesignTokens.font.bodyS)
          .height(28)
          .fontColor($r('app.color.text_on_color'))
          .backgroundColor($r('app.color.accent_blue'))
          .borderRadius(DesignTokens.radius.max)
          .enabled(!this.isRestarting)
          .onClick(() => {
            this.runServerAction(() => this.viewModel.startServer());
          })
      } else {
        Button($r('app.string.restart_server'))
          .fontSize(DesignTokens.font.bodyS)
          .height(28)
          .fontColor($r('app.color.text_on_color'))
          .backgroundColor($r('app.color.accent_blue'))
          .borderRadius(DesignTokens.radius.max)
          .enabled(!this.isRestarting)
          .onClick(() => {
            this.runServerAction(() => this.viewModel.restartServer());
          })
        Button($r('app.string.stop_server'))
          .fontSize(DesignTokens.font.bodyS)
          .height(28)
          .fontColor($r('app.color.text_on_color'))
          .backgroundColor($r('app.color.danger_red'))
          .borderRadius(DesignTokens.radius.max)
          .enabled(!this.isRestarting)
          .onClick(() => {
            this.runServerAction(() => this.viewModel.stopServer());
          })
      }
    }
  }
  .width('100%')
  .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
  .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
  .alignItems(VerticalAlign.Center)

  // Encryption
  Row() {
    Text($r('app.string.encrypted_transfer'))
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_primary'))
      .layoutWeight(1)

    Toggle({ type: ToggleType.Switch, isOn: this.viewModel.encryptedTransfer })
      .hitTestBehavior(HitTestMode.None)
  }
  .width('100%')
  .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
  .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
  .alignItems(VerticalAlign.Center)
  .onClick(() => {
    if (this.viewModel.encryptedTransfer) {
      // Currently ON: show confirmation before turning OFF
      this.showEncryptionNotice();
    } else {
      // Currently OFF: turn ON directly
      this.viewModel.setEncryptionEnabled(true);
      this.viewModel.setEncryptionEnabled(true);
    }
  })

  // Device name with dice and system name buttons
  Row() {
    Text($r('app.string.input_alias_title'))
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_primary'))
      .layoutWeight(1)

    Row({ space: DesignTokens.space.xs }) {
      // Dice button responseRegion→48vp
      SymbolGlyph($r('sys.symbol.shuffle'))
        .fontSize(DesignTokens.font.subtitleL)
        .fontColor([$r('app.color.text_primary')])
        .responseRegion({ x: -8, y: -8, width: 48, height: 48 })
        .onClick(() => {
          this.viewModel.randomizeAlias();
        })

      // Monitor button responseRegion→48vp
      SymbolGlyph($r('sys.symbol.computer_fill'))
        .fontSize(DesignTokens.font.subtitleL)
        .fontColor([$r('app.color.text_primary')])
        .responseRegion({ x: -8, y: -8, width: 48, height: 48 })
        .onClick(() => {
          this.viewModel.useSystemAlias();
        })

      Text(this.viewModel.customAlias || this.getDefaultAlias())
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
  }
  .width('100%')
  .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
  .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
  .alignItems(VerticalAlign.Center)
  .onClick(() => {
    this.showAliasDialog();
  })

  // Device type
  Row() {
    Text($r('app.string.select_device_type_title'))
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_primary'))
      .layoutWeight(1)

    Row({ space: 6 }) {
      Image(this.getCurrentDeviceTypeOption().icon)
        .width(DesignTokens.font.subtitleL)
        .height(DesignTokens.font.subtitleL)
        .fillColor($r('app.color.text_primary'))

      Text(this.getCurrentDeviceTypeOption().label)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))

      Text('\u25BC')
        .fontSize(DesignTokens.font.captionM)
        .fontColor($r('app.color.text_secondary'))
    }
  }
  .width('100%')
  .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
  .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
  .alignItems(VerticalAlign.Center)
  .onClick(() => {
    this.showDeviceTypeDialog();
  })

  // Device model
  Row() {
    Text($r('app.string.input_model_title'))
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_primary'))
      .layoutWeight(1)

    Row() {
      Text(this.viewModel.customDeviceModel || deviceInfo.productModel)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
  }
  .width('100%')
  .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
  .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
  .alignItems(VerticalAlign.Center)
  .onClick(() => {
    this.showModelDialog();
  })

  // Advanced settings toggle
  Row() {
    Text($r('app.string.advanced_settings_label'))
      .fontSize(DesignTokens.font.bodyM)
      .fontColor($r('app.color.text_primary'))
      .layoutWeight(1)

    Toggle({ type: ToggleType.Switch, isOn: this.viewModel.advancedSettings })
      .onChange((isOn: boolean) => {
        this.getUIContext().animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
          this.viewModel.setAdvancedSettingsEnabled(isOn);
        });
      })
  }
  .width('100%')
  .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
  .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
  .alignItems(VerticalAlign.Center)

  // Advanced settings (shown when toggle is on)
  if (this.viewModel.advancedSettings) {
    // Port
    Row() {
      Text($r('app.string.port_label'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)

      Text(this.viewModel.port.toString())
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
    .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      DialogService.showInputDialog($r('app.string.port_label'), this.viewModel.port.toString(), (value: string) => {
        this.viewModel.setPortValue(value);
      });
    })

    if (this.viewModel.port !== 53317) {
      Text($r('app.string.port_warning'))
        .fontSize(DesignTokens.font.captionM)
        .fontColor($r('app.color.warning_orange'))
        .margin({ bottom: DesignTokens.space.xs })
    }

    // Multicast group
    Row() {
      Text($r('app.string.multicast_group_label'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)

      Text(this.viewModel.multicastGroup)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
    .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      DialogService.showInputDialog($r('app.string.multicast_group_label'), this.viewModel.multicastGroup, (value: string) => {
        this.viewModel.setMulticastGroupValue(value);
      });
    })

    if (this.viewModel.multicastGroup !== '224.0.0.167') {
      Text($r('app.string.multicast_warning'))
        .fontSize(DesignTokens.font.captionM)
        .fontColor($r('app.color.warning_orange'))
        .margin({ bottom: DesignTokens.space.xs })
    }

    // Discovery timeout
    Row() {
      Text($r('app.string.discovery_timeout_label'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)

      Text(this.viewModel.discoveryTimeout.toString())
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
    .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      DialogService.showInputDialog($r('app.string.discovery_timeout_label'), this.viewModel.discoveryTimeout.toString(), (value: string) => {
        this.viewModel.setDiscoveryTimeoutValue(value);
      });
    })

    // Network whitelist
    Row() {
      Text($r('app.string.network_whitelist_label'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)

      Text(this.viewModel.networkWhitelist.length > 0 ? this.viewModel.networkWhitelist : $r('app.string.network_whitelist_empty'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
    .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      DialogService.showInputDialog($r('app.string.network_whitelist_label'), this.viewModel.networkWhitelist, (value: string) => {
        this.viewModel.setNetworkWhitelistValue(value);
      });
    })
    Row() {
      Text($r('app.string.network_blacklist_label'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)

      Text(this.viewModel.networkBlacklist.length > 0 ? this.viewModel.networkBlacklist : $r('app.string.network_blacklist_empty'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
    .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      DialogService.showInputDialog($r('app.string.network_blacklist_label'), this.viewModel.networkBlacklist, (value: string) => {
        this.viewModel.setNetworkBlacklistValue(value);
      });
    })

    // Checksums (single toggle: create + verify are inseparable)
    Row() {
      Text($r('app.string.create_checksums_label'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.viewModel.createChecksums })
        .onChange((isOn: boolean) => {
          this.viewModel.setChecksumsEnabled(isOn);
          this.viewModel.setChecksumsEnabled(isOn);
        })
    }
    .width('100%')
    .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
    .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
    .alignItems(VerticalAlign.Center)

    Text($r('app.string.checksum_create_desc'))
      .fontSize(DesignTokens.font.bodyS)
      .fontColor($r('app.color.text_secondary'))
  }

  Button($r('app.string.restore_defaults'))
    .width('100%')
    .backgroundColor($r('app.color.danger_red'))
    .fontColor($r('app.color.text_on_color'))
    .borderRadius(DesignTokens.radius.md)
    .margin({ top: DesignTokens.space.md })
    .onClick(() => {
      this.getUIContext().showAlertDialog({
        title: $r('app.string.restore_defaults'),
        message: $r('app.string.restore_defaults_confirm'),
        primaryButton: {
          value: $r('app.string.dialog_cancel'),
          action: () => {}
        },
        secondaryButton: {
          value: $r('app.string.dialog_confirm'),
          action: () => {
            this.viewModel.restoreDefaults();
          }
        }
      });
    })
}
.padding(DesignTokens.space.lg)
.borderRadius(DesignTokens.radius.lg)
.backgroundColor($r('app.color.card_background'))
.border({ width: 1, color: $r('app.color.border_light') })
.margin({ top: DesignTokens.space.md })


    }
    .width('100%')
  }
}
