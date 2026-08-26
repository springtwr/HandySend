// SaveToGalleryDialog：相册保存弹窗组件
// 传输完成后弹出，包含 SaveButton 安全控件和关闭按钮。
// C 类弹窗：保持自定义样式（openCustomDialog 模式），去除 @CustomDialog/CustomDialogController。

import { common } from '@kit.AbilityKit';
import { DesignTokens } from '../common/DesignTokens';
import { MediaFileInfo, GallerySaveResult } from '../model/Types';
import { saveMediaToGallery } from '../service/AppService';

@ComponentV2
export struct SaveToGalleryDialog {
  // 待保存的媒体文件列表
  @Param mediaFiles: Array<MediaFileInfo> = []
  // 媒体数量描述文本
  @Param mediaCountText: string = ''
  // 应用上下文（由 TransferPage 传入）
  @Param appContext: common.UIAbilityContext | undefined = undefined
  // 保存完成回调
  @Param onSaveComplete: (result: GallerySaveResult) => void = (_result: GallerySaveResult) => {
  }
  // 弹窗关闭回调（用户未保存）
  @Param onDismiss: () => void = () => {
  }
  // 关闭弹窗回调（由宿主页面通过 openCustomDialog 的 id 关闭）
  @Param onCloseDialog: () => void = () => {
  }
  // 保存是否正在执行中
  @Local saving: boolean = false

  build() {
    Column() {
      // 标题
      Text($r('app.string.gallery_save_dialog_title'))
        .fontSize(DesignTokens.font.titleS)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)

      // 媒体数量描述
      Text(this.mediaCountText)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: DesignTokens.space.md })
        .width('100%')
        .textAlign(TextAlign.Center)

      // 按钮区域
      Row({ space: DesignTokens.space.md }) {
        // 关闭/跳过按钮
        Button() {
          Text($r('app.string.gallery_save_skip'))
            .fontSize(DesignTokens.font.subtitleM)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .height(DesignTokens.size.thumbSm)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_medium'), style: BorderStyle.Solid })
        .borderRadius(DesignTokens.radius.max)
        .enabled(!this.saving)
        .onClick(() => {
          this.onCloseDialog();
          this.onDismiss();
        })

        // SaveButton 安全控件（SaveButton 不支持 layoutWeight，用容器包裹实现等宽）
        Column() {
          SaveButton({
            icon: SaveIconStyle.FULL_FILLED,
            text: SaveDescription.SAVE_TO_GALLERY,
            buttonType: ButtonType.Capsule
          })
            .width('100%')
            .height(DesignTokens.size.thumbSm)
            .enabled(!this.saving)
            .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
              if (result === SaveButtonOnClickResult.SUCCESS) {
                this.performSave();
              } else {
                // TEMPORARY_AUTHORIZATION_FAILED — 授权失败，提示用户
                this.onSaveComplete({
                  successCount: 0,
                  failCount: this.mediaFiles.length,
                  errors: ['Authorization failed']
                });
              }
            })
        }
        .layoutWeight(1)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .margin({ top: DesignTokens.space.lg })
    }
    .padding(DesignTokens.space.lg)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .width('85%')
  }

  private async performSave(): Promise<void> {
    if (this.appContext === undefined || this.mediaFiles.length === 0) {
      return;
    }
    this.saving = true;
    try {
      let result: GallerySaveResult = await saveMediaToGallery(this.appContext, this.mediaFiles);
      this.onCloseDialog();
      this.onSaveComplete(result);
    } catch (_e) {
      this.onCloseDialog();
      this.onSaveComplete({
        successCount: 0,
        failCount: this.mediaFiles.length,
        errors: [String(_e)]
      });
    }
  }
}
