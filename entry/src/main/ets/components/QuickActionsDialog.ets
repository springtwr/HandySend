import { DesignTokens } from '../common/DesignTokens';

interface QuickActionItem {
  key: string;
  label: ResourceStr;
}

@CustomDialog
export struct QuickActionsDialog {
  controller?: CustomDialogController
  onSelect?: (action: string) => void
  @State actions: Array<QuickActionItem> = []

  aboutToAppear(): void {
    this.actions = [
      { key: 'selectAll', label: $r('app.string.quick_action_select_all') } as QuickActionItem,
      { key: 'deselectAll', label: $r('app.string.quick_action_deselect_all') } as QuickActionItem,
      { key: 'onlyImages', label: $r('app.string.quick_action_only_images') } as QuickActionItem,
      { key: 'onlyVideos', label: $r('app.string.quick_action_only_videos') } as QuickActionItem
    ];
  }

  build() {
    Column() {
      Text($r('app.string.quick_actions_title'))
        .fontSize(DesignTokens.font.subtitleL)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: DesignTokens.space.md })

      ForEach(this.actions, (action: QuickActionItem) => {
        Row() {
          Text(action.label)
            .fontSize(DesignTokens.font.bodyM)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm, left: DesignTokens.space.md, right: DesignTokens.space.md })
        .onClick(() => {
          if (this.onSelect !== undefined) {
            this.onSelect(action.key);
          }
          this.controller?.close();
        })
      }, (action: QuickActionItem) => action.key)
    }
    .padding(DesignTokens.space.lg)
    .constraintSize({ maxWidth: '85%' })
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(DesignTokens.radius.lg)
  }
}
