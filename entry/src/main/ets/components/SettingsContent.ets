import { preferencesUtil } from '../utils/PreferencesUtil';
import { setHttpsEnabled, refreshDeviceInfo, reloadServerSettings } from '../service/AppService';
import { deviceInfo } from '@kit.BasicServicesKit';
import { InputDialog } from './settings/InputDialog';
import { DeviceTypePickerDialog } from './settings/DeviceTypePickerDialog';
import { DeviceTypeOption } from './settings/SettingsTypes';

@Component
export struct SettingsContent {
  @Prop showFloatingOption: boolean = false
  @StorageLink('nekoshare_floating') useFloating: boolean = true
  @StorageLink('hideShareByLink') hideShareByLink: boolean = false
  @StorageLink('silentReceive') silentReceive: boolean = false
  @StorageLink('enablePickerSpring') enablePickerSpring: boolean = true
  @StorageLink('encryptedTransfer') encryptedTransfer: boolean = true
  @State customAlias: string = ''
  @State customDeviceType: string = 'mobile'
  @State customDeviceModel: string = ''

  private aliasDialogController: CustomDialogController | null = null
  private modelDialogController: CustomDialogController | null = null
  private deviceTypeDialogController: CustomDialogController | null = null

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
    this.aliasDialogController = new CustomDialogController({
      builder: InputDialog({
        title: '设备名称',
        placeholder: '请输入设备名称',
        initialValue: this.customAlias,
        onConfirm: (value: string) => {
          this.customAlias = value;
          preferencesUtil.setString('customAlias', value);
          refreshDeviceInfo();
          reloadServerSettings();
          this.aliasDialogController?.close();
        },
        onCancel: () => {
          this.aliasDialogController?.close();
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.aliasDialogController.open();
  }

  private showModelDialog(): void {
    this.modelDialogController = new CustomDialogController({
      builder: InputDialog({
        title: '设备型号',
        placeholder: '请输入设备型号',
        initialValue: this.customDeviceModel,
        onConfirm: (value: string) => {
          this.customDeviceModel = value;
          preferencesUtil.setString('customDeviceModel', value);
          refreshDeviceInfo();
          reloadServerSettings();
          this.modelDialogController?.close();
        },
        onCancel: () => {
          this.modelDialogController?.close();
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.modelDialogController.open();
  }

  private showDeviceTypeDialog(): void {
    this.deviceTypeDialogController = new CustomDialogController({
      builder: DeviceTypePickerDialog({
        options: this.deviceTypeOptions,
        currentType: this.customDeviceType,
        onSelect: (value: string) => {
          this.customDeviceType = value;
          preferencesUtil.setString('customDeviceType', value);
          refreshDeviceInfo();
          reloadServerSettings();
          this.deviceTypeDialogController?.close();
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.deviceTypeDialogController.open();
  }

  private restoreDefaults(): void {
    this.customAlias = '';
    this.customDeviceType = 'mobile';
    this.customDeviceModel = '';
    preferencesUtil.setString('customAlias', '');
    preferencesUtil.setString('customDeviceType', '');
    preferencesUtil.setString('customDeviceModel', '');
    refreshDeviceInfo();
    reloadServerSettings();
  }

  build() {
    Scroll() {
      Column() {
        Column() {
          Text('通用')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#182431')
            .alignSelf(ItemAlign.Start)

          if (this.showFloatingOption) {
            Row() {
              Text($r('app.string.floating_label'))
                .fontSize(14)
                .fontColor('#182431')
                .layoutWeight(1)

              Row() {
                Toggle({ type: ToggleType.Switch, isOn: this.useFloating })
                  .onChange((isOn: boolean) => {
                    this.useFloating = isOn;
                  })
              }
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .backgroundColor('#FFFFFF')
              .borderRadius(12)
              .border({ width: 1, color: '#E8E8E8' })
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            .alignItems(VerticalAlign.Center)

            Text($r('app.string.floating_desc'))
              .fontSize(12)
              .fontColor('#999999')
              .margin({ bottom: 4 })
          }

          Row() {
            Text($r('app.string.hide_share_by_link'))
              .fontSize(14)
              .fontColor('#182431')
              .layoutWeight(1)

            Row() {
              Toggle({ type: ToggleType.Switch, isOn: this.hideShareByLink })
                .onChange((isOn: boolean) => {
                  this.hideShareByLink = isOn;
                  preferencesUtil.setBoolean('hideShareByLink', isOn);
                })
            }
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .border({ width: 1, color: '#E8E8E8' })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .alignItems(VerticalAlign.Center)

          Row() {
            Text($r('app.string.silent_receive_label'))
              .fontSize(14)
              .fontColor('#182431')
              .layoutWeight(1)

            Row() {
              Toggle({ type: ToggleType.Switch, isOn: this.silentReceive })
                .onChange((isOn: boolean) => {
                  this.silentReceive = isOn;
                  preferencesUtil.setBoolean('silentReceive', isOn);
                })
            }
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .border({ width: 1, color: '#E8E8E8' })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .alignItems(VerticalAlign.Center)

          Text($r('app.string.silent_receive_desc'))
            .fontSize(12)
            .fontColor('#999999')
            .margin({ bottom: 4 })

          Row() {
            Text($r('app.string.picker_spring_label'))
              .fontSize(14)
              .fontColor('#182431')
              .layoutWeight(1)

            Row() {
              Toggle({ type: ToggleType.Switch, isOn: this.enablePickerSpring })
                .onChange((isOn: boolean) => {
                  this.enablePickerSpring = isOn;
                  preferencesUtil.setBoolean('enablePickerSpring', isOn);
                })
            }
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .border({ width: 1, color: '#E8E8E8' })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .alignItems(VerticalAlign.Center)

          Text($r('app.string.picker_spring_desc'))
            .fontSize(12)
            .fontColor('#999999')
            .margin({ bottom: 4 })
        }
        .padding(20)
        .borderRadius(16)
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#E8E8E8' })
        .margin({ top: 24, left: 16, right: 16 })

        Column() {
          Text('网络')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#182431')
            .alignSelf(ItemAlign.Start)

          Row() {
            Text('加密传输')
              .fontSize(14)
              .fontColor('#182431')
              .layoutWeight(1)

            Row() {
              Toggle({ type: ToggleType.Switch, isOn: this.encryptedTransfer })
                .onChange((isOn: boolean) => {
                  this.encryptedTransfer = isOn;
                  setHttpsEnabled(isOn);
                  preferencesUtil.setBoolean('encryptedTransfer', isOn);
                  reloadServerSettings();
                })
            }
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .border({ width: 1, color: '#E8E8E8' })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .alignItems(VerticalAlign.Center)

          Row() {
            Text('设备名称')
              .fontSize(14)
              .fontColor('#182431')
              .layoutWeight(1)

            Row() {
              Text(this.customAlias || this.getDefaultAlias())
                .fontSize(14)
                .fontColor('#666666')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .border({ width: 1, color: '#E8E8E8' })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.showAliasDialog();
          })

          Row() {
            Text('设备类型')
              .fontSize(14)
              .fontColor('#182431')
              .layoutWeight(1)

            Row({ space: 6 }) {
              Image(this.getCurrentDeviceTypeOption().icon)
                .width(18)
                .height(18)
                .fillColor('#182431')

              Text(this.getCurrentDeviceTypeOption().label)
                .fontSize(14)
                .fontColor('#182431')

              Text('\u25BC')
                .fontSize(10)
                .fontColor('#999999')
            }
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .border({ width: 1, color: '#E8E8E8' })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.showDeviceTypeDialog();
          })

          Row() {
            Text('设备型号')
              .fontSize(14)
              .fontColor('#182431')
              .layoutWeight(1)

            Row() {
              Text(this.customDeviceModel || deviceInfo.productModel)
                .fontSize(14)
                .fontColor('#666666')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .border({ width: 1, color: '#E8E8E8' })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.showModelDialog();
          })

          Button($r('app.string.restore_defaults'))
            .width('100%')
            .backgroundColor('#FF4D4F')
            .fontColor('#FFFFFF')
            .borderRadius(8)
            .margin({ top: 16 })
            .onClick(() => {
              this.restoreDefaults();
            })
        }
        .padding(20)
        .borderRadius(16)
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#E8E8E8' })
        .margin({ top: 16, left: 16, right: 16, bottom: 24 })
      }
      .width('100%')
      .padding({ bottom: 100 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F3F5')
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }
}
