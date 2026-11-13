/**
 * 加载指示器组件
 * 默认无文字（与 HomePage 首次加载空白的中央 spinner 一致）；
 * 需要显示文字时传入 text 属性即可。
 */
import { Palette } from '../utils/ThemeManager';

@Component
export struct LoadingIndicator {
  text: string = '';
  iconSize: number = 48;
  @StorageProp('isDarkMode') isDark: boolean = true;

  build() {
    Column({ space: this.text.length > 0 ? 8 : 0 }) {
      LoadingProgress()
        .width(this.iconSize)
        .height(this.iconSize)
        .color(Palette.textPrimary(this.isDark))
      if (this.text.length > 0) {
        Text(this.text)
          .fontSize(14)
          .fontColor(Palette.textSecondary(this.isDark))
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
  }
}
