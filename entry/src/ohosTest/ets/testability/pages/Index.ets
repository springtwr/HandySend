// Instrument Test 入口页面
@Entry
@Component
struct Index {
  build() {
    Column() {
      Text('Instrument Test')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
