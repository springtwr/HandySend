import { picker } from '@kit.CoreFileKit';
import { setDestination, setSaveToGallery } from '../service/AppService';
import { isImage, isVideo, hasDirectoryPath } from '../utils/MimeUtils';
import { PendingRequestFile } from '../model/Types';
import { DesignTokens } from '../common/DesignTokens';
import { DialogService } from '../service/DialogService';


@Entry
@Component
struct ReceiveOptionsPage {
  @State fileItems: Array<PendingRequestFile> = []
  @State selectedFiles: Array<boolean> = []
  @State destination: string = ''
  @State saveToGallery: boolean = true
  @State senderAlias: string = ''
  @State hasDirectoryPath: boolean = false

  aboutToAppear(): void {
    let params = this.getUIContext().getRouter().getParams() as Record<string, string | boolean>;
    if (params !== undefined) {
      this.destination = params['destination'] !== undefined ? params['destination'] as string : '';
      this.saveToGallery = params['saveToGallery'] !== undefined ? params['saveToGallery'] as boolean : true;
      this.senderAlias = params['senderAlias'] !== undefined ? params['senderAlias'] as string : '';

      let filesJson = params['filesJson'] as string;
      if (filesJson !== undefined && filesJson.length > 0) {
        try {
          this.fileItems = JSON.parse(filesJson) as Array<PendingRequestFile>;
        } catch (_e) {
          this.fileItems = [];
        }
      }
    }

    // Initialize selection: all files selected by default
    this.selectedFiles = [];
    for (let i = 0; i < this.fileItems.length; i++) {
      this.selectedFiles.push(true);
    }

    // Check if any file has directory path
    for (let i = 0; i < this.fileItems.length; i++) {
      if (this.fileItems[i].fileName !== undefined && hasDirectoryPath(this.fileItems[i].fileName)) {
        this.hasDirectoryPath = true;
        break;
      }
    }
  }

  private selectAll(): void {
    for (let i = 0; i < this.selectedFiles.length; i++) {
      this.selectedFiles[i] = true;
    }
  }

  private deselectAll(): void {
    for (let i = 0; i < this.selectedFiles.length; i++) {
      this.selectedFiles[i] = false;
    }
  }

  private onlyImages(): void {
    for (let i = 0; i < this.fileItems.length; i++) {
      let mime = this.fileItems[i].fileType;
      this.selectedFiles[i] = isImage(mime);
    }
  }

  private onlyVideos(): void {
    for (let i = 0; i < this.fileItems.length; i++) {
      let mime = this.fileItems[i].fileType;
      this.selectedFiles[i] = isVideo(mime);
    }
  }

  private resetSelection(): void {
    for (let i = 0; i < this.selectedFiles.length; i++) {
      this.selectedFiles[i] = true;
    }
  }

  private formatFileSize(bytes: number): string {
    if (bytes < 1000) {
      return bytes + ' B';
    }
    if (bytes < 1000 * 1000) {
      return (bytes / 1000).toFixed(1) + ' KB';
    }
    if (bytes < 1000 * 1000 * 1000) {
      return (bytes / 1000 / 1000).toFixed(1) + ' MB';
    }
    return (bytes / 1000 / 1000 / 1000).toFixed(1) + ' GB';
  }

  private changeDestination(): void {
    try {
      let documentPicker = new picker.DocumentViewPicker();
      documentPicker.select().then((uris: Array<string>) => {
        if (uris.length > 0) {
          this.destination = uris[0];
          setDestination(uris[0]);
        }
      }).catch((_e: Object) => {
        // User cancelled picker or error
      });
    } catch (_e) {
      // DocumentViewPicker not available
    }
  }

  build() {
    Column() {
      // Header
      Row() {
        Image($r('sys.media.ohos_ic_public_arrow_left'))
          .width(24)
          .height(24)
          .fillColor($r('app.color.text_primary'))
          .responseRegion({ x: -12, y: -12, width: 48, height: 48 })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })

        Text($r('app.string.receive_options_title'))
          .fontSize(DesignTokens.font.subtitleL)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: DesignTokens.space.md })
          .layoutWeight(1)

        // Quick actions button (lightbulb icon)
        Text('\uD83D\uDCA1')
          .fontSize(DesignTokens.font.titleS)
          .margin({ right: DesignTokens.space.xs })
          .responseRegion({ x: -8, y: -8, width: 44, height: 44 })
          .onClick(() => {
            DialogService.showQuickActionsDialog((action: string) => {
              if (action === 'selectAll') {
                this.selectAll();
              } else if (action === 'deselectAll') {
                this.deselectAll();
              } else if (action === 'onlyImages') {
                this.onlyImages();
              } else if (action === 'onlyVideos') {
                this.onlyVideos();
              }
            });
          })

        // Reset button
        Text($r('app.string.reset'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.accent_blue'))
          .margin({ right: DesignTokens.space.md })
          .responseRegion({ x: -8, y: -8, width: 44, height: 44 })
          .onClick(() => {
            this.resetSelection();
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          // Destination directory
          Row() {
            Text($r('app.string.destination_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Text(this.destination.length > 0 ? this.destination : $r('app.string.default_destination'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            Text(' \uD83D\uDCC1')
              .fontSize(DesignTokens.font.subtitleM)
              .margin({ left: DesignTokens.space.xs })
          }
          .width('100%')
          .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.border_light') })
          .onClick(() => {
            this.changeDestination();
          })

          // Save to gallery toggle
          Row() {
            Text($r('app.string.save_to_gallery_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.saveToGallery })
              .onChange((isOn: boolean) => {
                this.saveToGallery = isOn;
                setSaveToGallery(isOn);
              })
          }
          .width('100%')
          .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
          .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
          .alignItems(VerticalAlign.Center)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.border_light') })
          .margin({ top: DesignTokens.space.xs })

          // Directory path warning
          if (this.hasDirectoryPath) {
            Text($r('app.string.save_to_gallery_desc'))
              .fontSize(DesignTokens.font.bodyS)
              .fontColor($r('app.color.warning_orange'))
              .margin({ top: DesignTokens.space.mini })
          }

          // File list
          Column() {
            Text($r('app.string.send_select_title'))
              .fontSize(DesignTokens.font.bodyM)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.sm, bottom: DesignTokens.space.xs })

            ForEach(this.fileItems, (file: PendingRequestFile, index: number) => {
              Row() {
                // Checkbox
                Checkbox()
                  .select(this.selectedFiles[index])
                  .onChange((isChecked: boolean) => {
                    this.selectedFiles[index] = isChecked;
                  })
                  .margin({ right: DesignTokens.space.sm })

                // File info
                Column() {
                  Text(file.fileName)
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor(this.selectedFiles[index] ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  if (file.size !== undefined && file.size > 0) {
                    Text(this.formatFileSize(file.size))
                      .fontSize(DesignTokens.font.bodyS)
                      .fontColor($r('app.color.text_tertiary'))
                  }
                }
                .layoutWeight(1)

                if (!this.selectedFiles[index]) {
                  Text($r('app.string.skipped'))
                    .fontSize(DesignTokens.font.bodyS)
                    .fontColor($r('app.color.warning_orange'))
                }

                // Rename button
                Text('\u270F')
                  .fontSize(DesignTokens.font.subtitleM)
                  .fontColor($r('app.color.text_secondary'))
                  .margin({ left: DesignTokens.space.xs })
                  .responseRegion({ x: -8, y: -8, width: 40, height: 40 })
                  .onClick(() => {
                    DialogService.showFileNameDialog(file.fileName, (newName: string) => {
                      this.fileItems[index].fileName = newName;
                    });
                  })
              }
              .width('100%')
              .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, top: DesignTokens.space.xs, bottom: DesignTokens.space.xs })
              .constraintSize({ minHeight: DesignTokens.hotspot.minSize })
              .alignItems(VerticalAlign.Center)
              .transition(
                TransitionEffect.OPACITY
                  .combine(TransitionEffect.translate({ y: 16 }))
                  .animation({ duration: 300, curve: Curve.FastOutSlowIn })
              )

              if (index < this.fileItems.length - 1) {
                Divider().color($r('app.color.border_light'))
              }
            }, (file: PendingRequestFile, index: number) => index.toString())
          }
          .width('100%')
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(DesignTokens.radius.lg)
          .border({ width: 1, color: $r('app.color.border_light') })
          .margin({ top: DesignTokens.space.md })
        }
        .padding(DesignTokens.space.md)
      }
      .layoutWeight(1)

      // Bottom action buttons
      Row({ space: DesignTokens.space.sm }) {
        Button($r('app.string.cancel_button'))
          .layoutWeight(1)
          .height(DesignTokens.hotspot.minSize)
          .backgroundColor($r('app.color.input_bg'))
          .fontColor($r('app.color.text_tertiary'))
          .borderRadius(DesignTokens.radius.lg)
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })

        Button($r('app.string.confirm_button'))
          .layoutWeight(1)
          .height(DesignTokens.hotspot.minSize)
          .backgroundColor($r('app.color.accent_blue'))
          .fontColor($r('app.color.text_on_color'))
          .borderRadius(DesignTokens.radius.lg)
          .onClick(() => {
            // TODO: Accept the receive with selected files and options
            this.getUIContext().getRouter().back();
          })
      }
      .width('100%')
      .padding(DesignTokens.space.md)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
    PageTransitionEnter({ type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Push, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit({ type: RouteType.Pop, duration: DesignTokens.animation.durationNormal, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
  }
}
