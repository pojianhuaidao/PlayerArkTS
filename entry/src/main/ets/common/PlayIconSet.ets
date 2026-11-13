/**
 * 播放控件图标资源集（线面混合风格，参考 PotPlayer）。
 *
 * 所有图标均为 resources/base/media 下自绘的 24x24 viewBox 单色 SVG，
 * 使用时通过 Image(...).fillColor(tint) 着色，因此同一份资源可以在
 * 深色播放器遮罩（白色）与主题色高亮（primary）之间自由切换。
 *
 * 约束：
 * - 图标本体视觉尺寸不得小于 24vp，触控热区不得小于 48vp；
 * - 横竖屏共用同一套资源，只按 uiScale 缩放，禁止各页面写字面量图标。
 */
export class PlayIconSet {
  static readonly BACK: Resource = $r('app.media.ic_back');
  static readonly PLAY: Resource = $r('app.media.ic_play');
  static readonly PAUSE: Resource = $r('app.media.ic_pause');
  static readonly PREV: Resource = $r('app.media.ic_prev');
  static readonly NEXT: Resource = $r('app.media.ic_next');
  static readonly REWIND: Resource = $r('app.media.ic_rewind');
  static readonly FORWARD: Resource = $r('app.media.ic_forward');
  static readonly VOLUME: Resource = $r('app.media.ic_volume');
  static readonly SPEED: Resource = $r('app.media.ic_speed');
  static readonly SUBTITLE: Resource = $r('app.media.ic_subtitle');
  static readonly TRACK: Resource = $r('app.media.ic_track');
  static readonly ASPECT_FIT: Resource = $r('app.media.ic_aspect_fit');
  static readonly ASPECT_FILL: Resource = $r('app.media.ic_aspect_fill');
  static readonly ASPECT_ORIGIN: Resource = $r('app.media.ic_aspect_origin');
  static readonly FULLSCREEN: Resource = $r('app.media.ic_fullscreen');
  static readonly FULLSCREEN_EXIT: Resource = $r('app.media.ic_fullscreen_exit');
  static readonly CAST: Resource = $r('app.media.ic_cast');
  static readonly LOCK: Resource = $r('app.media.ic_lock');
  static readonly UNLOCK: Resource = $r('app.media.ic_unlock');
  static readonly MORE: Resource = $r('app.media.ic_more_vert');
  static readonly RESTART: Resource = $r('app.media.ic_restart');
  static readonly LIST: Resource = $r('app.media.ic_list');
  static readonly DECODE: Resource = $r('app.media.ic_decode');
  static readonly LOOP_ALL: Resource = $r('app.media.ic_loop_all');
  static readonly LOOP_ONE: Resource = $r('app.media.ic_loop_one');
  static readonly INFO: Resource = $r('app.media.ic_info');
  static readonly ADD: Resource = $r('app.media.ic_add');
  /** 超时/计时（直播自动换线超时） */
  static readonly TIMER: Resource = $r('app.media.ic_timer');
  /** 直播源/信号源选择 */
  static readonly SOURCE: Resource = $r('app.media.ic_source');

  /** 播放 / 暂停图标 */
  static playPause(isPlaying: boolean): Resource {
    return isPlaying ? PlayIconSet.PAUSE : PlayIconSet.PLAY;
  }

  /** 循环模式图标 */
  static loop(single: boolean): Resource {
    return single ? PlayIconSet.LOOP_ONE : PlayIconSet.LOOP_ALL;
  }

  /** 画面比例图标（适应 / 铺满 / 原始） */
  static aspect(mode: number): Resource {
    if (mode === 1) {
      return PlayIconSet.ASPECT_FILL;
    }
    if (mode === 2) {
      return PlayIconSet.ASPECT_ORIGIN;
    }
    return PlayIconSet.ASPECT_FIT;
  }

  /** 全屏 / 退出全屏图标 */
  static fullscreen(landscape: boolean): Resource {
    return landscape ? PlayIconSet.FULLSCREEN_EXIT : PlayIconSet.FULLSCREEN;
  }
}
