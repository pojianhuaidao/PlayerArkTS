/**
 * TV 设置的独立页面入口。
 * 主设置页只放一行入口，点击后进到这里，内部复用 TV 端原生设置页（非嵌入模式，自带顶栏与返回）。
 */
import { SettingsPage } from './SettingsPage';

@Entry
@Component
struct TvSettingsPage {
  build() {
    Column() {
      SettingsPage({ embedded: false })
    }
    .width('100%')
    .height('100%')
  }
}
