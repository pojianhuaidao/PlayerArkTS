/**
 * 播放栏统一图标字形。
 *
 * 同一个软件内的播放栏（本地视频 / 网络电视 / 音乐）必须使用完全相同的字形，
 * 只在各自界面上按需调整尺寸与配色，禁止各页面自行写字面量图标，
 * 保证「播放、暂停、上一、下一、循环」三类界面看起来是同一套按钮。
 */
export class PlayIcons {
  /** 播放 */
  static readonly PLAY: string = '▶';
  /** 暂停 */
  static readonly PAUSE: string = '⏸';
  /** 上一个（曲目 / 剧集 / 频道） */
  static readonly PREV: string = '⏮';
  /** 下一个（曲目 / 剧集 / 频道） */
  static readonly NEXT: string = '⏭';
  /** 列表循环 */
  static readonly LOOP_ALL: string = '🔁';
  /** 单曲循环 */
  static readonly LOOP_ONE: string = '🔂';
  /** 画面比例：适应屏幕 */
  static readonly ASPECT_FIT: string = '⤢';
  /** 画面比例：裁剪铺满 */
  static readonly ASPECT_FILL: string = '⛶';
  /** 画面比例：原始比例 */
  static readonly ASPECT_ORIGIN: string = '▣';
  /** 手动横竖屏切换 */
  static readonly ROTATE: string = '🔄';

  /** 播放 / 暂停字形 */
  static playPause(isPlaying: boolean): string {
    return isPlaying ? PlayIcons.PAUSE : PlayIcons.PLAY;
  }

  /** 循环模式字形 */
  static loop(single: boolean): string {
    return single ? PlayIcons.LOOP_ONE : PlayIcons.LOOP_ALL;
  }
}
