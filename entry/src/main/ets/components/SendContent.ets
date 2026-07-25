import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { router, promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferencesUtil } from '../utils/PreferencesUtil';
import { getDiscoveredDevices, rescanDevices, subscribe, unsubscribe,
  prepareSendFiles, createShareLink, stopShareLink,
  getShareLink, getLocalDeviceInfo, getDeviceType, getDeviceModel,
  isSendCompletedAndReset, processSharedUris } from '../service/AppService';
import { DiscoveredDevice, SendFileItem, StagedFile } from '../model/Types';
import { TextSendDialog } from './TextSendDialog';

const IMAGE_EXTENSIONS: Array<string> = ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'svg'];

@Component
export struct SendContent {
  @State stagedFiles: Array<StagedFile> = []

  @State discoveredDevices: Array<DiscoveredDevice> = []
  @State refreshAngle: number = 0
  @StorageLink('hideShareByLink') hideShareByLink: boolean = false
  @StorageLink('favoriteDevices') favoriteDevicesJson: string = '[]'
  @StorageLink('serverReady') serverReady: boolean = false
  @StorageLink('enablePickerSpring') enablePickerSpring: boolean = true
  @State isCreatingShareLink: boolean = false
  private refreshCallback: () => void = () => {}

  private textDialogController: CustomDialogController = new CustomDialogController({
    builder: TextSendDialog({
      onConfirm: (text: string): void => {
        this.onTextConfirmed(text);
      },
      onCancel: (): void => {}
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });

  aboutToAppear(): void {
    this.refreshCallback = () => {
      if (isSendCompletedAndReset()) {
        this.clearStagedFiles();
      }
      let pendingJson: string = AppStorage.get<string>('pendingSharedUris') ?? '';
      if (pendingJson.length > 0) {
        AppStorage.setOrCreate('pendingSharedUris', '');
        let sharedFiles: Array<StagedFile> = processSharedUris(pendingJson);
        if (sharedFiles.length > 0) {
          this.stagedFiles = sharedFiles;
        }
      }
      this.discoveredDevices = getDiscoveredDevices();
    };
    subscribe(this.refreshCallback);
    this.discoveredDevices = getDiscoveredDevices();
  }

  aboutToDisappear(): void {
    unsubscribe(this.refreshCallback);
  }

  async pickFiles(): Promise<void> {
    let context = getContext() as common.UIAbilityContext;
    let documentPicker = new picker.DocumentViewPicker(context);
    let options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 10;
    try {
      let uris: Array<string> = await documentPicker.select(options);
      for (let i = 0; i < uris.length; i++) {
        let uri = uris[i];
        let name = this.extractFileNameFromUri(uri);
        let ext = this.getExtension(name);
        let isImg = IMAGE_EXTENSIONS.indexOf(ext) >= 0;
        let mime = this.getMimeFromExt(ext);
        let staged: StagedFile = { uri: uri, fileName: name, fileType: mime, isImage: isImg };
        this.stagedFiles.push(staged);
      }
    } catch (e) {
      console.error('pickFiles error:', JSON.stringify(e));
    }
  }

  async pickImages(): Promise<void> {
    let context = getContext() as common.UIAbilityContext;
    let photoPicker = new picker.PhotoViewPicker(context);
    let options = new picker.PhotoSelectOptions();
    options.maxSelectNumber = 10;
    try {
      let result = await photoPicker.select(options);
      let uris: Array<string> = result.photoUris;
      for (let i = 0; i < uris.length; i++) {
        let uri = uris[i];
        let name = this.extractFileNameFromUri(uri);
        let ext = this.getExtension(name);
        let mime = this.getMimeFromExt(ext);
        let staged: StagedFile = { uri: uri, fileName: name, fileType: mime, isImage: true };
        this.stagedFiles.push(staged);
      }
    } catch (e) {
      console.error('pickImages error:', JSON.stringify(e));
    }
  }

  handlePasteData(text: string): void {
    try {
      if (text.length === 0) {
        promptAction.showToast({ message: $r('app.string.send_clipboard_empty'), duration: 2000 });
        return;
      }
      this.stageTextFile(text, 'clipboard_');
      promptAction.showToast({ message: $r('app.string.send_clipboard_pasted'), duration: 2000 });
    } catch (e) {
      hilog.error(0x0001, 'SendContent', 'handlePasteData error: %{public}s', JSON.stringify(e));
    }
  }

  pickJustify(): void {
    this.textDialogController.open();
  }

  onTextConfirmed(text: string): void {
    if (text.trim().length === 0) {
      this.textDialogController.close();
      return;
    }
    this.stageTextFile(text, 'text_');
    this.textDialogController.close();
  }

  stageTextFile(text: string, prefix: string): void {
    let context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    let sendDir: string = context.filesDir + '/send/';
    try {
      fs.mkdirSync(sendDir);
    } catch (_e) {}
    let fileName: string = prefix + Date.now() + '.txt';
    let filePath: string = sendDir + fileName;
    let file: fs.File = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    fs.writeSync(file.fd, text);
    fs.closeSync(file);
    let staged: StagedFile = { uri: filePath, fileName: fileName, fileType: 'text/plain', isImage: false };
    this.stagedFiles.push(staged);
  }

  removeStagedFile(index: number): void {
    let updated: Array<StagedFile> = [];
    for (let i = 0; i < this.stagedFiles.length; i++) {
      if (i !== index) {
        updated.push(this.stagedFiles[i]);
      }
    }
    this.stagedFiles = updated;
  }

  clearStagedFiles(): void {
    this.stagedFiles = [];
  }

  extractFileNameFromUri(uri: string): string {
    let decoded = decodeURIComponent(uri);
    let idx = decoded.lastIndexOf('/');
    if (idx >= 0 && idx < decoded.length - 1) {
      return decoded.substring(idx + 1);
    }
    return 'file_' + Date.now();
  }

  getExtension(fileName: string): string {
    let dot = fileName.lastIndexOf('.');
    if (dot >= 0 && dot < fileName.length - 1) {
      return fileName.substring(dot + 1).toLowerCase();
    }
    return '';
  }

  getMimeFromExt(ext: string): string {
    let map: Record<string, string> = {
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg',
      'png': 'image/png', 'gif': 'image/gif', 'bmp': 'image/bmp',
      'webp': 'image/webp', 'svg': 'image/svg+xml', 'heic': 'image/heic',
      'mp4': 'video/mp4', 'avi': 'video/x-msvideo',
      'mkv': 'video/x-matroska', 'mov': 'video/quicktime', 'webm': 'video/webm',
      'mp3': 'audio/mpeg', 'wav': 'audio/wav', 'ogg': 'audio/ogg',
      'flac': 'audio/flac', 'aac': 'audio/aac', 'm4a': 'audio/mp4',
      'pdf': 'application/pdf',
      'doc': 'application/msword', 'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel', 'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms.powerpoint', 'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'zip': 'application/zip', 'rar': 'application/vnd.rar', '7z': 'application/x-7z-compressed',
      'txt': 'text/plain', 'html': 'text/html', 'json': 'application/json',
      'apk': 'application/vnd.android.package-archive', 'exe': 'application/x-msdownload'
    };
    let mime = map[ext];
    if (mime !== undefined) {
      return mime;
    }
    return 'application/octet-stream';
  }

  refreshDevices(): void {
    this.getUIContext().animateTo({ duration: 800, curve: Curve.EaseInOut }, () => {
      this.refreshAngle = this.refreshAngle + 360;
    });
    if (this.serverReady) {
      rescanDevices();
    }
  }

  async shareByLink(): Promise<void> {
    if (this.isCreatingShareLink) {
      return;
    }

    if (this.stagedFiles.length === 0) {
      await this.pickFiles();
    }
    if (this.stagedFiles.length === 0) {
      return;
    }

    this.isCreatingShareLink = true;

    try {
      let uris: Array<string> = [];
      for (let i = 0; i < this.stagedFiles.length; i++) {
        uris.push(this.stagedFiles[i].uri);
      }
      let items: Array<SendFileItem> = await prepareSendFiles(uris);
      if (items.length > 0) {
        await createShareLink(items);
        let shareUrl = getShareLink();
        if (shareUrl.length > 0) {
          router.pushUrl({ url: 'pages/ShareLinkPage', params: { shareUrl: shareUrl } });
        }
      }
    } finally {
      this.isCreatingShareLink = false;
    }
  }

  sendToSelectedDevice(device: DiscoveredDevice): void {
    if (this.stagedFiles.length === 0) {
      return;
    }
    let uris: Array<string> = [];
    for (let i = 0; i < this.stagedFiles.length; i++) {
      uris.push(this.stagedFiles[i].uri);
    }
    let localInfo = getLocalDeviceInfo();
    let params: Record<string, Object | string | number | boolean | Array<string>> = {
      'mode': 'send',
      'sourceAlias': localInfo.alias,
      'sourceIp': localInfo.ip,
      'sourceDeviceType': getDeviceType(),
      'sourceDeviceModel': getDeviceModel(),
      'targetAlias': device.alias,
      'targetIp': device.ip,
      'targetDeviceType': device.deviceType,
      'targetDeviceModel': device.deviceModel,
      'fileUris': uris,
      'targetPort': device.port,
      'targetFingerprint': device.fingerprint,
      'targetProtocol': device.protocol,
      'sessionId': '',
      'autoConfirm': false,
      'fileCount': this.stagedFiles.length,
      'totalSize': -1
    };
    router.pushUrl({ url: 'pages/TransferPage', params: params });
  }

  isDeviceFavorite(fingerprint: string): boolean {
    let parsed: Array<string> = [];
    try {
      let arr: Object = JSON.parse(this.favoriteDevicesJson);
      if (Array.isArray(arr)) {
        parsed = arr as Array<string>;
      }
    } catch (_e) {
      return false;
    }
    for (let i = 0; i < parsed.length; i++) {
      if (parsed[i] === fingerprint) {
        return true;
      }
    }
    return false;
  }

  toggleFavorite(fingerprint: string): void {
    let parsed: Array<string> = [];
    try {
      let arr: Object = JSON.parse(this.favoriteDevicesJson);
      if (Array.isArray(arr)) {
        parsed = arr as Array<string>;
      }
    } catch (_e) {
      return;
    }
    let found = false;
    let updated: Array<string> = [];
    for (let i = 0; i < parsed.length; i++) {
      if (parsed[i] === fingerprint) {
        found = true;
      } else {
        updated.push(parsed[i]);
      }
    }
    if (!found) {
      updated.push(fingerprint);
    }
    this.favoriteDevicesJson = JSON.stringify(updated);
    preferencesUtil.setString('favoriteDevices', this.favoriteDevicesJson);
  }

  build() {
    Scroll() {
      Column() {
        Column() {
          if (this.stagedFiles.length === 0) {
            Text($r('app.string.send_select_title'))
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor('#182431')

            Text($r('app.string.send_select_subtitle'))
              .fontSize(13)
              .fontColor('#999999')
              .margin({ top: 6 })

            Scroll() {
              Row({ space: 10 }) {
                Column() {
                  Image($r('app.media.ic_public_file_filled'))
                    .width(20)
                    .height(20)
                    .fillColor('#182431')
                  Text($r('app.string.send_file'))
                    .fontSize(12)
                    .fontColor('#182431')
                    .margin({ top: 6 })
                }
                .width(80)
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 20, bottom: 20 })
                .borderRadius(12)
                .backgroundColor('#F2F3F5')
                .stateStyles({
                  pressed: {
                    .backgroundColor('#D8DADD')
                  }
                })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.pickFiles();
                })

                Column() {
                  Image($r('app.media.ic_public_picture_filled'))
                    .width(20)
                    .height(20)
                    .fillColor('#182431')
                  Text($r('app.string.send_image'))
                    .fontSize(12)
                    .fontColor('#182431')
                    .margin({ top: 6 })
                }
                .width(80)
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 20, bottom: 20 })
                .borderRadius(12)
                .backgroundColor('#F2F3F5')
                .stateStyles({
                  pressed: {
                    .backgroundColor('#D8DADD')
                  }
                })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.pickImages();
                })

                Column() {
                  PasteButton({ icon: PasteIconStyle.LINES, buttonType: ButtonType.Normal })
                    .width(48)
                    .height(48)
                    .iconSize(20)
                    .borderRadius(12)
                    .backgroundColor('#182431')
                    .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
                      if (PasteButtonOnClickResult.SUCCESS === result) {
                        pasteboard.getSystemPasteboard().getData((err: BusinessError, pasteData: pasteboard.PasteData) => {
                          if (err) {
                            hilog.error(0x0001, 'SendContent', 'Paste error: %{public}s', err.message);
                            promptAction.showToast({ message: 'Clipboard read failed', duration: 2000 });
                            return;
                          }
                          this.handlePasteData(pasteData.getPrimaryText());
                        });
                      }
                    })
                  Text($r('app.string.send_clipboard'))
                    .fontSize(12)
                    .fontColor('#182431')
                    .margin({ top: 6 })
                }
                .width(80)
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 6, bottom: 6 })
                .borderRadius(12)
                .backgroundColor('#F2F3F5')

                Column() {
                  Image($r('app.media.ic_justify'))
                    .width(20)
                    .height(20)
                    .fillColor('#182431')
                  Text($r('app.string.send_justify'))
                    .fontSize(12)
                    .fontColor('#182431')
                    .margin({ top: 6 })
                }
                .width(80)
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 20, bottom: 20 })
                .borderRadius(12)
                .backgroundColor('#F2F3F5')
                .stateStyles({
                  pressed: {
                    .backgroundColor('#D8DADD')
                  }
                })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.90 })
                .onClick(() => {
                  this.pickJustify();
                })
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .edgeEffect(this.enablePickerSpring ? EdgeEffect.Spring : EdgeEffect.None)
            .width('100%')
            .margin({ top: 16 })
          } else {
            Row() {
              Column() {
                Text($r('app.string.send_select_title'))
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#182431')

                Text(this.stagedFiles.length + ' file(s) selected')
                  .fontSize(13)
                  .fontColor('#999999')
                  .margin({ top: 6 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Image($r('app.media.ic_x'))
                .width(20)
                .height(20)
                .fillColor('#666666')
                .margin({ right: 4 })
                .responseRegion({ x: -10, y: -10, width: 40, height: 40 })
                .onClick(() => {
                  this.clearStagedFiles();
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)

            Scroll() {
              Row({ space: 10 }) {
                ForEach(this.stagedFiles, (file: StagedFile, index: number) => {
                  Stack({ alignContent: Alignment.TopEnd }) {
                    Column() {
                      if (file.isImage) {
                        Image(file.uri)
                          .width(48)
                          .height(48)
                          .objectFit(ImageFit.Cover)
                          .borderRadius(8)
                      } else {
                        Image($r('app.media.ic_public_file'))
                          .width(48)
                          .height(48)
                          .fillColor('#182431')
                      }
                      Text(file.fileName)
                        .fontSize(10)
                        .fontColor('#666666')
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width(64)
                        .textAlign(TextAlign.Center)
                        .margin({ top: 4 })
                    }
                    .width(64)
                    .height(80)
                    .alignItems(HorizontalAlign.Center)
                    .padding(4)

                    Text('\u00D7')
                      .fontSize(14)
                      .fontColor('#FFFFFF')
                      .textAlign(TextAlign.Center)
                      .width(16)
                      .height(16)
                      .backgroundColor('#FF4D4F')
                      .borderRadius(8)
                      .onClick(() => {
                        this.removeStagedFile(index);
                      })
                  }
                  .width(64)
                  .height(80)
                }, (file: StagedFile) => file.uri)
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .width('100%')
            .margin({ top: 16 })
          }
        }
        .padding(20)
        .borderRadius(16)
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#E8E8E8' })
        .margin({ top: 24, left: 16, right: 16 })

        Column() {
          Row() {
            Column() {
              Text($r('app.string.nearby_devices_title'))
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor('#182431')

              Text($r('app.string.nearby_devices_subtitle'))
                .fontSize(13)
                .fontColor('#999999')
                .margin({ top: 6 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Image($r('app.media.ic_public_refresh'))
              .width(24)
              .height(24)
              .fillColor('#182431')
              .rotate({ angle: this.refreshAngle })
              .onClick(() => {
                this.refreshDevices();
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (!this.hideShareByLink) {
            Row({ space: 8 }) {
              if (this.isCreatingShareLink) {
                LoadingProgress()
                  .width(16)
                  .height(16)
                  .color('#999999')
              }
              Text(this.isCreatingShareLink ? $r('app.string.creating_share_link') : $r('app.string.share_via_link'))
                .fontSize(14)
                .fontColor(this.isCreatingShareLink ? '#999999' : '#182431')
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding(12)
            .backgroundColor(this.isCreatingShareLink ? '#E8E8E8' : '#F2F3F5')
            .borderRadius(8)
            .margin({ top: 12 })
            .onClick(() => {
              this.shareByLink();
            })
          }

          Column({ space: 10 }) {
            ForEach(this.discoveredDevices, (device: DiscoveredDevice) => {
              Row({ space: 12 }) {
                if (device.deviceType === 'mobile') {
                  Image($r('app.media.ic_public_devices_phone'))
                    .width(40)
                    .height(40)
                    .fillColor('#182431')
                } else if (device.deviceType === 'desktop') {
                  Image($r('app.media.ic_device_matebook'))
                    .width(40)
                    .height(40)
                    .fillColor('#182431')
                } else if (device.deviceType === 'web') {
                  Image($r('app.media.ic_browser'))
                    .width(40)
                    .height(40)
                    .fillColor('#182431')
                } else if (device.deviceType === 'headless') {
                  Image($r('app.media.ic_terminal'))
                    .width(40)
                    .height(40)
                    .fillColor('#182431')
                } else if (device.deviceType === 'server') {
                  Image($r('app.media.ic_server'))
                    .width(40)
                    .height(40)
                    .fillColor('#182431')
                } else if (device.deviceType === 'tablet') {
                  Image($r('app.media.ic_device_pad'))
                    .width(40)
                    .height(40)
                    .fillColor('#182431')
                } else {
                  Image($r('app.media.ic_public_devices_phone'))
                    .width(40)
                    .height(40)
                    .fillColor('#182431')
                }

                Column() {
                  Text(device.alias)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#182431')

                  Row({ space: 8 }) {
                    Text('#' + device.ip.split('.').pop())
                      .fontSize(12)
                      .fontColor('#36D')
                      .backgroundColor('#E8F0FE')
                      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                      .borderRadius(4)

                    Text(device.deviceModel)
                      .fontSize(12)
                      .fontColor('#36D')
                      .backgroundColor('#E8F0FE')
                      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                      .borderRadius(4)
                  }
                  .margin({ top: 6 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Image(this.isDeviceFavorite(device.fingerprint) ? $r('app.media.ic_heart_fill') : $r('app.media.ic_heart'))
                  .width(22)
                  .height(22)
                  .responseRegion({ x: -10, y: -10, width: 42, height: 42 })
                  .fillColor(this.isDeviceFavorite(device.fingerprint) ? '#FF4D4F' : '#999999')
                  .onClick(() => {
                    this.toggleFavorite(device.fingerprint);
                  })
              }
              .width('100%')
              .padding(16)
              .backgroundColor('#F2F3F5')
              .borderRadius(12)
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                this.sendToSelectedDevice(device);
              })
            }, (device: DiscoveredDevice) => device.fingerprint)
          }
          .width('100%')
          .margin({ top: 16 })
        }
        .padding(20)
        .borderRadius(16)
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#E8E8E8' })
        .margin({ top: 16, left: 16, right: 16, bottom: 24 })


      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F3F5')
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
  }
}
