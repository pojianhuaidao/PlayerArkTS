import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlayerCore } from '../view/PlayerCore';

const TAG: string = 'LocalPlayerPage';
const DOMAIN: number = 0x0001;

/**
 * 本地视频独立播放页。
 * 从视频页「本地视频」列表点播进入；页面级返回（返回按钮 / 系统返回键 / 侧滑）
 * 行为一致：都交给路由栈出栈回到视频页，视频页在 onPageShow 恢复滚动位置与选中态。
 */
@Entry
@Component
struct LocalPlayerPage {
  aboutToAppear(): void {
    hilog.info(DOMAIN, TAG, 'local player page appear');
  }

  /** 系统返回与页面内返回按钮走同一条出栈路径 */
  onBackPress(): boolean {
    router.back();
    return true;
  }

  build() {
    Column() {
      PlayerCore()
    }
    .width('100%')
    .height('100%')
  }
}
