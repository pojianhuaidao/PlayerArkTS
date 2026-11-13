/**
 * 空状态/错误状态组件
 */
import { Palette } from '../utils/ThemeManager';

@Component
export struct EmptyState {
  text: string = '暂无数据';
  onRetry: () => void = () => {};

  build() {
    Column() {
      Text(this.text)
        .fontSize(16)
        .fontColor('#666666')
        .margin({ bottom: 16 })
        .textAlign(TextAlign.Center)
      Button('重试')
        .fontSize(14)
        .fontColor(Palette.accent())
        .backgroundColor('#333333')
        .borderRadius(8)
        .padding({ left: 24, right: 24, top: 8, bottom: 8 })
        .onClick(() => this.onRetry())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}