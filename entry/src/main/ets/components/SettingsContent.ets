import { router } from '@kit.ArkUI';
import { preferencesUtil } from '../utils/PreferencesUtil';
import { setHttpsEnabled, refreshDeviceInfo,
  setReceivePin, setAutoFinish, setSaveToHistory, setSaveToGallery,
  setDestination, setTheme, setLocale,
  setEnableAnimations, setAdvancedSettings, setPort, setMulticastGroup,
  setDiscoveryTimeout, setNetworkWhitelist, setNetworkBlacklist,
  setCreateChecksums, setVerifyChecksums, setSendMode,
  setQuickSaveMode,clearServerNeedsRestart, restartServer,
  startServer, stopServer
} from '../service/AppService';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { DeviceTypeOption } from './settings/SettingsTypes';
import { SendMode, QuickSaveMode } from '../model/Types';
import { generateAlias, getSystemDeviceName } from '../utils/AliasGenerator';
import { DesignTokens } from '../common/DesignTokens';
import { DialogService } from '../service/DialogService';
import { getLanguageDisplayName } from '../pages/LanguagePage';

@Component
export struct SettingsContent {
  @Prop showFloatingOption: boolean = false
  @StorageLink('nekoshare_floating') useFloating: boolean = true
  @StorageLink('hideShareByLink') hideShareByLink: boolean = false
  @StorageLink('silentReceive') silentReceive: boolean = false

  @StorageLink('encryptedTransfer') encryptedTransfer: boolean = true
  @StorageLink('autoSaveMode') autoSaveMode: string = 'paired'
  @StorageLink('receivePin') receivePin: string = ''
  @StorageLink('autoFinish') autoFinishEnabled: boolean = false
  @StorageLink('saveToHistory') saveToHistoryEnabled: boolean = true
  @StorageLink('saveToGallery') saveToGalleryEnabled: boolean = true
  @StorageLink('destination') destination: string = ''
  @StorageLink('advancedSettings') advancedSettingsEnabled: boolean = false
  @StorageLink('port') portSetting: number = 53317
  @StorageLink('multicastGroup') multicastGroupSetting: string = '224.0.0.167'
  @StorageLink('discoveryTimeout') discoveryTimeoutSetting: number = 3000
  @StorageLink('networkWhitelist') networkWhitelistSetting: string = ''
  @StorageLink('networkBlacklist') networkBlacklistSetting: string = ''
  @StorageLink('createChecksums') createChecksumsEnabled: boolean = true
  @StorageLink('verifyChecksums') verifyChecksumsEnabled: boolean = true
  @StorageLink('sendMode') sendModeSetting: string = 'single'
  @StorageLink('serverNeedsRestart') serverNeedsRestart: boolean = false
  @StorageLink('enableAnimations') enableAnimationsSetting: boolean = true
  @StorageLink('theme') themeSetting: string = 'system'
  @StorageLink('locale') localeSetting: string = ''
  @State customAlias: string = ''
  @State customDeviceType: string = 'mobile'
  @State customDeviceModel: string = ''
  @StorageLink('serverReady') serverReady: boolean = false
  @State isRestarting: boolean = false

  private deviceTypeOptions: Array<DeviceTypeOption> = [
    { value: 'mobile', label: $r('app.string.device_type_mobile'), icon: $r('app.media.ic_public_devices_phone') },
    { value: 'desktop', label: $r('app.string.device_type_desktop'), icon: $r('app.media.ic_device_matebook') },
    { value: 'web', label: $r('app.string.device_type_web'), icon: $r('app.media.ic_browser') },
    { value: 'headless', label: $r('app.string.device_type_headless'), icon: $r('app.media.ic_terminal') },
    { value: 'server', label: $r('app.string.device_type_server'), icon: $r('app.media.ic_server') },
    { value: 'tablet', label: $r('app.string.device_type_tablet'), icon: $r('app.media.ic_device_pad') }
  ]

  aboutToAppear(): void {
    this.customAlias = preferencesUtil.getString('customAlias', '');
    this.customDeviceType = preferencesUtil.getString('customDeviceType', 'mobile');
    this.customDeviceModel = preferencesUtil.getString('customDeviceModel', '');

    // Apply saved theme color mode on appear
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let appCtx = context.getApplicationContext();
      if (this.themeSetting === 'light') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else if (this.themeSetting === 'dark') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
    } catch (_e) {
      // Ignore if context not available
    }
  }

  private getDefaultAlias(): string {
    return deviceInfo.manufacture + ' ' + deviceInfo.productModel;
  }

  private getCurrentDeviceTypeOption(): DeviceTypeOption {
    for (let i = 0; i < this.deviceTypeOptions.length; i++) {
      if (this.deviceTypeOptions[i].value === this.customDeviceType) {
        return this.deviceTypeOptions[i];
      }
    }
    return this.deviceTypeOptions[0];
  }

  private showAliasDialog(): void {
    DialogService.showInputDialog($r('app.string.input_alias_title'), this.customAlias, (value: string) => {
      this.customAlias = value;
      preferencesUtil.setString('customAlias', value);
      refreshDeviceInfo();
    });
  }

  private showModelDialog(): void {
    DialogService.showInputDialog($r('app.string.input_model_title'), this.customDeviceModel, (value: string) => {
      this.customDeviceModel = value;
      preferencesUtil.setString('customDeviceModel', value);
      refreshDeviceInfo();
    });
  }

  private showDeviceTypeDialog(): void {
    DialogService.showDeviceTypePicker(this.customDeviceType, (value: string) => {
      this.customDeviceType = value;
      preferencesUtil.setString('customDeviceType', value);
      refreshDeviceInfo();
    });
  }

  private showEncryptionNotice(): void {
    DialogService.showEncryptionNotice(() => {
      this.encryptedTransfer = false;
      setHttpsEnabled(false);
      preferencesUtil.setBoolean('encryptedTransfer', false);
    });
  }

  private restoreDefaults(): void {
    // Reset all settings to their default values
    // Device identity — empty strings trigger auto-detection from system info
    this.customAlias = '';
    this.customDeviceType = '';
    this.customDeviceModel = '';
    preferencesUtil.setString('customAlias', '');
    preferencesUtil.setString('customDeviceType', '');
    preferencesUtil.setString('customDeviceModel', '');

    // Receive settings
    setQuickSaveMode(QuickSaveMode.off);
    setReceivePin('');
    setAutoFinish(false);
    setSaveToHistory(true);
    setSaveToGallery(false);
    setDestination('');

    // Theme & appearance
    setTheme('system');
    setEnableAnimations(true);
    this.hideShareByLink = false;
    preferencesUtil.setBoolean('hideShareByLink', false);
    AppStorage.setOrCreate('hideShareByLink', false);
    this.silentReceive = false;
    preferencesUtil.setBoolean('silentReceive', false);
    AppStorage.setOrCreate('silentReceive', false);
    AppStorage.setOrCreate('nekoshare_floating', true);

    // Language — reset to follow system (use setLocale for full pipeline)
    setLocale('');

    // Send settings
    setSendMode(SendMode.single);

    // Security
    setHttpsEnabled(true);

    // Advanced settings
    setAdvancedSettings(false);
    setPort(53317);
    setMulticastGroup('224.0.0.167');
    setDiscoveryTimeout(3000);
    setNetworkWhitelist('');
    setNetworkBlacklist('');
    setCreateChecksums(true);
    setVerifyChecksums(true);

    // Refresh device info (server restart banner will show automatically)
    refreshDeviceInfo();

    // Clear the restart banner since all settings are now at defaults
    clearServerNeedsRestart();
  }

  build() {
    Scroll() {
      Column() {
        // ── Receive settings section ──
        Column() {
          Text($r('app.string.receive_settings'))
            .fontSize(DesignTokens.font.subtitleM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .alignSelf(ItemAlign.Start)

          // Auto-save 3-segment selector
          Row() {
            Text($r('app.string.auto_save_title'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
          .alignItems(VerticalAlign.Center)

          Row({ space: 0 }) {
            Row() {
              Text($r('app.string.auto_save_off'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor(this.autoSaveMode === 'off' ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
                .fontWeight(this.autoSaveMode === 'off' ? FontWeight.Bold : FontWeight.Normal)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: 6, bottom: 6 })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .backgroundColor(this.autoSaveMode === 'off' ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
            .borderRadius({ topLeft: DesignTokens.radius.md, bottomLeft: DesignTokens.radius.md })
            .onClick(() => {
              this.autoSaveMode = 'off';
              preferencesUtil.setString('autoSaveMode', 'off');
              setQuickSaveMode(QuickSaveMode.off);
            })

            Row() {
              Text($r('app.string.auto_save_favorites'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor(this.autoSaveMode === 'paired' ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
                .fontWeight(this.autoSaveMode === 'paired' ? FontWeight.Bold : FontWeight.Normal)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: 6, bottom: 6 })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .backgroundColor(this.autoSaveMode === 'paired' ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
            .onClick(() => {
              if (this.autoSaveMode !== 'paired') {
                DialogService.showAutoSaveWarning($r('app.string.auto_save_paired_warning'), () => {
                  this.autoSaveMode = 'paired';
                  preferencesUtil.setString('autoSaveMode', 'paired');
                  setQuickSaveMode(QuickSaveMode.paired);
                });
              }
            })

            Row() {
              Text($r('app.string.auto_save_on'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor(this.autoSaveMode === 'on' ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
                .fontWeight(this.autoSaveMode === 'on' ? FontWeight.Bold : FontWeight.Normal)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: 6, bottom: 6 })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .backgroundColor(this.autoSaveMode === 'on' ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
            .borderRadius({ topRight: DesignTokens.radius.md, bottomRight: DesignTokens.radius.md })
            .onClick(() => {
              if (this.autoSaveMode !== 'on') {
                DialogService.showAutoSaveWarning($r('app.string.auto_save_on_warning'), () => {
                  this.autoSaveMode = 'on';
                  preferencesUtil.setString('autoSaveMode', 'on');
                  setQuickSaveMode(QuickSaveMode.on);
                });
              }
            })
          }
          .width('100%')

          // PIN
          Row() {
            Text($r('app.string.receive_pin_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            if (this.receivePin.length > 0) {
              Text('****')
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_tertiary'))
            } else {
              Text($r('app.string.pin_set_label'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_tertiary'))
            }
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            DialogService.showInputDialog($r('app.string.receive_pin_label'), this.receivePin, (value: string) => {
              this.receivePin = value;
              setReceivePin(value);
            });
          })

          Text($r('app.string.receive_pin_desc'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .margin({ bottom: DesignTokens.space.xs })

          // Auto-finish
          Row() {
            Text($r('app.string.auto_finish_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.autoFinishEnabled })
              .onChange((isOn: boolean) => {
                this.autoFinishEnabled = isOn;
                setAutoFinish(isOn);
              })
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)

          Text($r('app.string.auto_finish_desc'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .margin({ bottom: DesignTokens.space.xs })

          // Save to gallery
          Row() {
            Text($r('app.string.save_to_gallery_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.saveToGalleryEnabled })
              .onChange((isOn: boolean) => {
                this.saveToGalleryEnabled = isOn;
                setSaveToGallery(isOn);
              })
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)

          // Save to history
          Row() {
            Text($r('app.string.save_to_history_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.saveToHistoryEnabled })
              .onChange((isOn: boolean) => {
                this.saveToHistoryEnabled = isOn;
                setSaveToHistory(isOn);
              })
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)

          Text($r('app.string.save_to_history_desc'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .margin({ bottom: DesignTokens.space.xs })
        }
        .padding(DesignTokens.space.lg)
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.lg })

        // ── General settings ──
        Column() {
          Text($r('app.string.settings_general'))
            .fontSize(DesignTokens.font.subtitleM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .alignSelf(ItemAlign.Start)

          if (this.showFloatingOption) {
            Row() {
              Text($r('app.string.floating_label'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)

              Toggle({ type: ToggleType.Switch, isOn: this.useFloating })
                .onChange((isOn: boolean) => {
                  this.useFloating = isOn;
                })
            }
            .width('100%')
            .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .alignItems(VerticalAlign.Center)

            Text($r('app.string.floating_desc'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_secondary'))
              .margin({ bottom: DesignTokens.space.xs })
          }

          Row() {
            Text($r('app.string.hide_share_by_link'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.hideShareByLink })
              .onChange((isOn: boolean) => {
                this.hideShareByLink = isOn;
                preferencesUtil.setBoolean('hideShareByLink', isOn);
              })
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)

          Row() {
            Text($r('app.string.silent_receive_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.silentReceive })
              .onChange((isOn: boolean) => {
                this.silentReceive = isOn;
                preferencesUtil.setBoolean('silentReceive', isOn);
              })
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)


        }
        .padding(DesignTokens.space.lg)
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.md })

        // ── Appearance settings ──
        Column() {
          Text($r('app.string.appearance_settings'))
            .fontSize(DesignTokens.font.subtitleM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .alignSelf(ItemAlign.Start)

          // Theme mode
          Row() {
            Text($r('app.string.theme_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
          .alignItems(VerticalAlign.Center)

          Row({ space: 0 }) {
            Row() {
              Text($r('app.string.theme_light'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor(this.themeSetting === 'light' ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
                .fontWeight(this.themeSetting === 'light' ? FontWeight.Bold : FontWeight.Normal)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: 6, bottom: 6 })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .backgroundColor(this.themeSetting === 'light' ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
            .borderRadius({ topLeft: DesignTokens.radius.md, bottomLeft: DesignTokens.radius.md })
            .onClick(() => {
              this.themeSetting = 'light';
              setTheme('light');
              try {
                let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
                context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
              } catch (_e) {}
            })

            Row() {
              Text($r('app.string.theme_dark'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor(this.themeSetting === 'dark' ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
                .fontWeight(this.themeSetting === 'dark' ? FontWeight.Bold : FontWeight.Normal)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: 6, bottom: 6 })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .backgroundColor(this.themeSetting === 'dark' ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
            .onClick(() => {
              this.themeSetting = 'dark';
              setTheme('dark');
              try {
                let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
                context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
              } catch (_e) {}
            })

            Row() {
              Text($r('app.string.theme_system'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor(this.themeSetting === 'system' ? $r('app.color.accent_blue') : $r('app.color.text_secondary'))
                .fontWeight(this.themeSetting === 'system' ? FontWeight.Bold : FontWeight.Normal)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ top: 6, bottom: 6 })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .backgroundColor(this.themeSetting === 'system' ? $r('app.color.accent_blue_bg') : $r('app.color.page_background'))
            .borderRadius({ topRight: DesignTokens.radius.md, bottomRight: DesignTokens.radius.md })
            .onClick(() => {
              this.themeSetting = 'system';
              setTheme('system');
              try {
                let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
                context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
              } catch (_e) {}
            })
          }
          .width('100%')

          // Animations toggle
          Row() {
            Text($r('app.string.animations_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.enableAnimationsSetting })
              .onChange((isOn: boolean) => {
                this.enableAnimationsSetting = isOn;
                setEnableAnimations(isOn);
              })
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)

          Text($r('app.string.animations_desc'))
            .fontSize(DesignTokens.font.bodyS)
            .fontColor($r('app.color.text_secondary'))
            .margin({ bottom: DesignTokens.space.xs })

          // Language selection entry
          Row() {
            Text($r('app.string.language_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Row() {
              Text(this.localeSetting.length === 0 ? $r('app.string.language_system') : getLanguageDisplayName(this.localeSetting))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_tertiary'))
              Text('›')
                .fontSize(DesignTokens.font.subtitleL)
                .fontColor($r('app.color.text_secondary'))
                .margin({ left: DesignTokens.space.xs })
            }
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            router.pushUrl({ url: 'pages/LanguagePage' });
          })
        }
        .padding(DesignTokens.space.lg)
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.md })

        // ── Server restart warning banner ──
        if (this.serverNeedsRestart) {
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
                this.isRestarting = true;
                restartServer().then(() => {
                  this.isRestarting = false;
                }).catch(() => {
                  this.isRestarting = false;
                });
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

          // Encryption
          Row() {
            Text($r('app.string.encrypted_transfer'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.encryptedTransfer })
              .onChange((isOn: boolean) => {
                if (!isOn) {
                  // Show encryption notice before disabling
                  this.showEncryptionNotice();
                } else {
                  this.encryptedTransfer = isOn;
                  setHttpsEnabled(isOn);
                  preferencesUtil.setBoolean('encryptedTransfer', isOn);
                }
              })
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)

          // Device name with dice and system name buttons
          Row() {
            Text($r('app.string.input_alias_title'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Row({ space: DesignTokens.space.xs }) {
              // T029: Dice button responseRegion→48vp
              SymbolGlyph($r('sys.symbol.shuffle'))
                .fontSize(DesignTokens.font.subtitleL)
                .fontColor([$r('app.color.text_primary')])
                .responseRegion({ x: -8, y: -8, width: 48, height: 48 })
                .onClick(() => {
                  let newAlias = generateAlias();
                  this.customAlias = newAlias;
                  preferencesUtil.setString('customAlias', newAlias);
                  refreshDeviceInfo();
                })

              // T029: Monitor button responseRegion→48vp
              SymbolGlyph($r('sys.symbol.computer_fill'))
                .fontSize(DesignTokens.font.subtitleL)
                .fontColor([$r('app.color.text_primary')])
                .responseRegion({ x: -8, y: -8, width: 48, height: 48 })
                .onClick(() => {
                  let sysName = getSystemDeviceName();
                  this.customAlias = sysName;
                  preferencesUtil.setString('customAlias', sysName);
                  refreshDeviceInfo();
                })

              Text(this.customAlias || this.getDefaultAlias())
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
              Text(this.customDeviceModel || deviceInfo.productModel)
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

          // Server status
          Row() {
            if (this.isRestarting) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color($r('app.color.text_secondary'))
                .margin({ right: DesignTokens.space.xs })
            }
            Text(this.serverReady ? $r('app.string.server_status_running') : $r('app.string.server_status_offline'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor(this.serverReady ? $r('app.color.success_green') : $r('app.color.text_secondary'))
              .layoutWeight(1)

            Row({ space: DesignTokens.space.xs }) {
              if (!this.serverReady) {
                Button($r('app.string.start_server'))
                  .fontSize(DesignTokens.font.bodyS)
                  .height(28)
                  .fontColor($r('app.color.text_on_color'))
                  .backgroundColor($r('app.color.accent_blue'))
                  .borderRadius(DesignTokens.radius.max)
                  .enabled(!this.isRestarting)
                  .onClick(() => {
                    this.isRestarting = true;
                    startServer().then(() => {
                      this.isRestarting = false;
                    }).catch(() => {
                      this.isRestarting = false;
                    });
                  })
              } else {
                Button($r('app.string.stop_server'))
                  .fontSize(DesignTokens.font.bodyS)
                  .height(28)
                  .fontColor($r('app.color.text_on_color'))
                  .backgroundColor($r('app.color.danger_red'))
                  .borderRadius(DesignTokens.radius.max)
                  .enabled(!this.isRestarting)
                  .onClick(() => {
                    this.isRestarting = true;
                    stopServer().then(() => {
                      this.isRestarting = false;
                    }).catch(() => {
                      this.isRestarting = false;
                    });
                  })
                Button($r('app.string.restart_server'))
                  .fontSize(DesignTokens.font.bodyS)
                  .height(28)
                  .fontColor($r('app.color.text_on_color'))
                  .backgroundColor($r('app.color.accent_blue'))
                  .borderRadius(DesignTokens.radius.max)
                  .enabled(!this.isRestarting)
                  .onClick(() => {
                    this.isRestarting = true;
                    restartServer().then(() => {
                      this.isRestarting = false;
                    }).catch(() => {
                      this.isRestarting = false;
                    });
                  })
              }
            }
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)

          // Advanced settings toggle
          Row() {
            Text($r('app.string.advanced_settings_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.advancedSettingsEnabled })
              .onChange((isOn: boolean) => {
                this.getUIContext().animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
                  this.advancedSettingsEnabled = isOn;
                });
                setAdvancedSettings(isOn);
              })
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)

          // Advanced settings (shown when toggle is on)
          if (this.advancedSettingsEnabled) {
            // Port
            Row() {
              Text($r('app.string.port_label'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)

              Text(this.portSetting.toString())
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_tertiary'))
            }
            .width('100%')
            .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              DialogService.showInputDialog($r('app.string.port_label'), this.portSetting.toString(), (value: string) => {
                let p = parseInt(value);
                if (!isNaN(p) && p > 0 && p <= 65535) {
                  this.portSetting = p;
                  setPort(p);
                }
              });
            })

            if (this.portSetting !== 53317) {
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

              Text(this.multicastGroupSetting)
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_tertiary'))
            }
            .width('100%')
            .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              DialogService.showInputDialog($r('app.string.multicast_group_label'), this.multicastGroupSetting, (value: string) => {
                this.multicastGroupSetting = value;
                setMulticastGroup(value);
              });
            })

            if (this.multicastGroupSetting !== '224.0.0.167') {
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

              Text(this.discoveryTimeoutSetting.toString())
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_tertiary'))
            }
            .width('100%')
            .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })
            .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              DialogService.showInputDialog($r('app.string.discovery_timeout_label'), this.discoveryTimeoutSetting.toString(), (value: string) => {
                let t = parseInt(value);
                if (!isNaN(t) && t > 0) {
                  this.discoveryTimeoutSetting = t;
                  setDiscoveryTimeout(t);
                }
              });
            })

            // Network whitelist
            Row() {
              Text($r('app.string.network_whitelist_label'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)

              Text(this.networkWhitelistSetting.length > 0 ? this.networkWhitelistSetting : $r('app.string.network_whitelist_empty'))
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
              DialogService.showInputDialog($r('app.string.network_whitelist_label'), this.networkWhitelistSetting, (value: string) => {
                this.networkWhitelistSetting = value;
                setNetworkWhitelist(value);
              });
            })
            Row() {
              Text($r('app.string.network_blacklist_label'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)

              Text(this.networkBlacklistSetting.length > 0 ? this.networkBlacklistSetting : $r('app.string.network_blacklist_empty'))
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
              DialogService.showInputDialog($r('app.string.network_blacklist_label'), this.networkBlacklistSetting, (value: string) => {
                this.networkBlacklistSetting = value;
                setNetworkBlacklist(value);
              });
            })

            // Checksums (single toggle: create + verify are inseparable)
            Row() {
              Text($r('app.string.create_checksums_label'))
                .fontSize(DesignTokens.font.bodyM)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)

              Toggle({ type: ToggleType.Switch, isOn: this.createChecksumsEnabled })
                .onChange((isOn: boolean) => {
                  this.createChecksumsEnabled = isOn;
                  this.verifyChecksumsEnabled = isOn;
                  setCreateChecksums(isOn);
                  setVerifyChecksums(isOn);
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
              AlertDialog.show({
                title: $r('app.string.restore_defaults'),
                message: $r('app.string.restore_defaults_confirm'),
                primaryButton: {
                  value: $r('app.string.dialog_cancel'),
                  action: () => {}
                },
                secondaryButton: {
                  value: $r('app.string.dialog_confirm'),
                  action: () => {
                    this.restoreDefaults();
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

        // ── About ──
        Column() {
          Text($r('app.string.about_title'))
            .fontSize(DesignTokens.font.subtitleM)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .alignSelf(ItemAlign.Start)

          Row() {
            Text($r('app.string.about_card_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Text('\u203A')
              .fontSize(DesignTokens.font.titleS)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            router.pushUrl({ url: 'pages/AboutPage' });
          })
        }
        .padding(DesignTokens.space.lg)
        .borderRadius(DesignTokens.radius.lg)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.border_light') })
        .margin({ top: DesignTokens.space.md, bottom: DesignTokens.space.xl })
      }
      .width('100%')
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: this.showFloatingOption ? 100 : 0 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }
}
