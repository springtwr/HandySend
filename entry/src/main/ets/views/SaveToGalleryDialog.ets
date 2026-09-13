// SaveToGalleryDialog：相册保存弹窗组件
// 传输完成后弹出，包含 SaveButton 安全控件和关闭按钮。
// C 类弹窗：保持自定义样式（openCustomDialog 模式），去除 @CustomDialog/CustomDialogController。

import { ComponentContent } from '@kit.ArkUI';
import { DesignTokens } from '../common/DesignTokens';
import { MediaFileInfo, GallerySaveResult } from '../viewmodel/TransferViewModel';

@ComponentV2
export struct SaveToGalleryDialog {
  // 待保存的媒体文件列表
  @Param mediaFiles: Array<MediaFileInfo> = []
  // 媒体数量描述文本
  @Param mediaCountText: string = ''
  // 执行保存回调（经 ViewModel 上抛数据层操作；返回保存结果）
  @Param onPerformSave: (mediaFiles: Array<MediaFileInfo>) => Promise<GallerySaveResult> =
    async (_mediaFiles: Array<MediaFileInfo>): Promise<GallerySaveResult> => {
      return { successCount: 0, failCount: 0, errors: [] };
    }
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
        .id('transfer_gallery_dialog_title')

      // 媒体数量描述
      Text(this.mediaCountText)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: DesignTokens.space.md })
        .width('100%')
        .textAlign(TextAlign.Center)
        .id('transfer_gallery_media_count')

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
        .border(
          { width: DesignTokens.component.borderSlim, color: $r('app.color.border_medium'), style: BorderStyle.Solid })
        .borderRadius(DesignTokens.radius.max)
        .enabled(!this.saving)
        .onClick(() => {
          this.onCloseDialog();
          this.onDismiss();
        })
        .id('transfer_gallery_skip_btn')

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
        .id('transfer_gallery_save_btn')
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .margin({ top: DesignTokens.space.lg })
    }
    .padding(DesignTokens.space.lg)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
    .width('85%')
    // 宽屏下限制弹窗最大宽度，避免铺满过宽（手机 85% 屏宽 < 480vp 不受影响）
    .constraintSize({ maxWidth: 480 })
  }

  private async performSave(): Promise<void> {
    if (this.mediaFiles.length === 0) {
      return;
    }
    this.saving = true;
    try {
      let result: GallerySaveResult = await this.onPerformSave(this.mediaFiles);
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

// ── ComponentContent 参数类与全局 Builder（TransferPage/MtaTransferPage 共用） ──
// 采用与 DialogService 一致的 ComponentContent + wrapBuilder 模式（默认 customStyle=true），
// 使弹窗内容样式完全由 SaveToGalleryDialog 自定义，避免 Builder 方式的系统默认背板产生双层弹窗。

export class GallerySaveDialogParams {
  mediaFiles: Array<MediaFileInfo> = []
  mediaCountText: string = ''
  onPerformSave: (mediaFiles: Array<MediaFileInfo>) => Promise<GallerySaveResult> =
    async (_mediaFiles: Array<MediaFileInfo>): Promise<GallerySaveResult> => {
      return { successCount: 0, failCount: 0, errors: [] };
    }
  onSaveComplete: (result: GallerySaveResult) => void = (_result: GallerySaveResult) => {
  }
  onDismiss: () => void = () => {
  }
  onCloseDialog: () => void = () => {
  }
  contentNode: ComponentContent<GallerySaveDialogParams> | null = null
}

@Builder
export function buildGallerySaveDialog(params: GallerySaveDialogParams) {
  SaveToGalleryDialog({
    mediaFiles: params.mediaFiles,
    mediaCountText: params.mediaCountText,
    onPerformSave: params.onPerformSave,
    onSaveComplete: params.onSaveComplete,
    onDismiss: params.onDismiss,
    onCloseDialog: params.onCloseDialog
  })
}
