import { router } from '@kit.ArkUI';

interface CompletionNotifyParams {
  alias: string;
  type: string;
}

@Entry
@Component
struct CompletionNotifyPage {
  @State alias: string = ''
  @State isCancelled: boolean = false
  private dismissTimer: number = -1

  aboutToAppear(): void {
    const params = router.getParams() as CompletionNotifyParams;
    if (params !== undefined) {
      this.alias = params.alias ?? '';
      this.isCancelled = params.type === 'cancel';
    }
    this.dismissTimer = setTimeout(() => {
      router.back();
    }, 5000);
  }

  aboutToDisappear(): void {
    if (this.dismissTimer >= 0) {
      clearTimeout(this.dismissTimer);
    }
  }

  build() {
    Column() {
      Column() {
        Text(this.isCancelled ? '发送已取消' : '接收完成')
          .fontSize(22)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ bottom: 16 })

        Text('来自 ' + this.alias + ' 的文件' + (this.isCancelled ? '传输已被对方取消' : '已接收完成'))
          .fontSize(16)
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
      }
      .margin({ top: 120 })

      Button('确定')
        .width('80%')
        .height(48)
        .fontSize(16)
        .fontColor($r('app.color.text_on_color'))
        .backgroundColor($r('app.color.accent_blue'))
        .borderRadius(24)
        .margin({ top: 40 })
        .onClick(() => {
          router.back();
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
