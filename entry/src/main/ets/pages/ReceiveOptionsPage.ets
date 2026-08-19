import { DesignTokens } from '../common/DesignTokens';
import { DialogService } from '../service/DialogService';
import { ReceiveOptionsViewModel } from '../viewmodel/ReceiveOptionsViewModel';
import { ReceiveOptionsItemViewModel } from '../viewmodel/ReceiveOptionsItemViewModel';

@Entry
@ComponentV2
struct ReceiveOptionsPage {
  @Local viewModel: ReceiveOptionsViewModel = new ReceiveOptionsViewModel();

  aboutToAppear(): void {
    let params = this.getUIContext().getRouter().getParams() as Record<string, string | boolean>;
    if (params !== undefined) {
      const destination: string = params['destination'] !== undefined ? params['destination'] as string : '';
      const saveToGallery: boolean = params['saveToGallery'] !== undefined ? params['saveToGallery'] as boolean : true;
      const senderAlias: string = params['senderAlias'] !== undefined ? params['senderAlias'] as string : '';
      const filesJson: string = params['filesJson'] as string;
      this.viewModel.loadOptions(destination, saveToGallery, senderAlias, filesJson);
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
              this.viewModel.applyQuickAction(action);
            });
          })

        // Reset button
        Text($r('app.string.reset'))
          .fontSize(DesignTokens.font.bodyM)
          .fontColor($r('app.color.accent_blue'))
          .margin({ right: DesignTokens.space.md })
          .responseRegion({ x: -8, y: -8, width: 44, height: 44 })
          .onClick(() => {
            this.viewModel.resetSelection();
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

            Text(this.viewModel.destination.length > 0 ? this.viewModel.destination : $r('app.string.default_destination'))
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
            this.viewModel.changeDestination();
          })

          // Save to gallery toggle
          Row() {
            Text($r('app.string.save_to_gallery_label'))
              .fontSize(DesignTokens.font.bodyM)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.viewModel.saveToGallery })
              .onChange((isOn: boolean) => {
                this.viewModel.setSaveToGallery(isOn);
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
          if (this.viewModel.hasDirectoryPath) {
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

            Repeat(this.viewModel.fileItems).each((ri: RepeatItem<ReceiveOptionsItemViewModel>) => {
              Row() {
                // Checkbox
                Checkbox()
                  .select(ri.item.isSelected)
                  .onChange((isChecked: boolean) => {
                    this.viewModel.toggleSelect(ri.index, isChecked);
                  })
                  .margin({ right: DesignTokens.space.sm })

                // File info
                Column() {
                  Text(ri.item.file.fileName)
                    .fontSize(DesignTokens.font.bodyM)
                    .fontColor(ri.item.isSelected ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  if (ri.item.file.size !== undefined && ri.item.file.size > 0) {
                    Text(ri.item.formattedSize)
                      .fontSize(DesignTokens.font.bodyS)
                      .fontColor($r('app.color.text_tertiary'))
                  }
                }
                .layoutWeight(1)

                if (!ri.item.isSelected) {
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
                    DialogService.showFileNameDialog(ri.item.file.fileName, (newName: string) => {
                      this.viewModel.renameFile(ri.index, newName);
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

              if (ri.index < this.viewModel.fileItems.length - 1) {
                Divider().color($r('app.color.border_light'))
              }
            }).key((item: ReceiveOptionsItemViewModel, index: number) => index.toString())
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
