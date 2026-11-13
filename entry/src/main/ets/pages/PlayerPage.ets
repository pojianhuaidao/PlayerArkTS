import { PlayerCore } from '../view/PlayerCore';

const TAG: string = 'PlayerPage';

/**
 * 通用播放页（网络源 / 局域网 / 电视端入口）。
 * 播放实现统一收口到 view/PlayerCore，本页仅承担路由与返回栈职责。
 */
@Entry
@Component
struct PlayerPage {
  build() {
    Column() {
      PlayerCore()
    }
    .width('100%')
    .height('100%')
  }
}
