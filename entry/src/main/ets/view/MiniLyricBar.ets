import { router } from '@kit.ArkUI';
import { AppTheme, Palette } from '../common/AppTheme';
import { LyricLine } from '../lx/core/music/Lyric';
import { K_LYRIC_LINES, K_LYRIC_STATUS } from '../lx/core/player/PlaySession';

/**
 * 音乐页「迷你歌词」
 *
 * 位置：主页签栏（capsuleBar）与播放栏（miniPlayer）之间的那条空白。
 * 只在音乐页签挂载，切到视频/网络/设置页签时整条不渲染（不是隐藏，是不存在）。
 *
 * 数据来自内核 PlaySession 发布的 AppStorage：
 *   ps_lyric_lines  解析好的 LyricLine[]（切歌时自动重载）
 *   ps_progress     当前进度（秒），跟随它算高亮行
 *   ps_lyric_status none / loading / ready
 */
@Component
export struct MiniLyricBar {
  @StorageProp('isDark') isDark: boolean = true;
  @StorageProp('ps_progress') progress: number = 0;
  @StorageProp('ps_current_name') curName: string = '';
  @StorageProp(K_LYRIC_STATUS) lyricStatus: string = 'none';

  pal(): Palette {
    return AppTheme.palette(this.isDark);
  }

  private lines(): LyricLine[] {
    const raw: LyricLine[] | undefined = AppStorage.get<LyricLine[]>(K_LYRIC_LINES);
    return raw === undefined ? [] : raw;
  }

  /** 当前时间点对应的歌词行下标，没有则 -1 */
  private currentIndex(): number {
    const arr: LyricLine[] = this.lines();
    if (arr.length === 0) {
      return -1;
    }
    const pos: number = this.progress > 0 ? this.progress : 0;
    let idx: number = -1;
    for (let i = 0; i < arr.length; i++) {
      const t: number = arr[i].time;
      if (t < 0) {
        continue;
      }
      if (t <= pos + 0.2) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  private mainText(): string {
    const arr: LyricLine[] = this.lines();
    const idx: number = this.currentIndex();
    if (idx >= 0 && idx < arr.length && arr[idx].text.length > 0) {
      return arr[idx].text;
    }
    if (arr.length > 0 && idx < 0) {
      return arr[0].text;
    }
    if (this.lyricStatus === 'loading') {
      return '歌词加载中…';
    }
    return this.curName.length > 0 ? `${this.curName} · 暂无歌词` : '暂无歌词';
  }

  private subText(): string {
    const arr: LyricLine[] = this.lines();
    const idx: number = this.currentIndex();
    if (idx >= 0 && idx < arr.length) {
      return arr[idx].translation;
    }
    return '';
  }

  build() {
    Row() {
      Text('♪')
        .fontSize(12)
        .fontColor(this.pal().primary)
        .margin({ right: 6 })
      Text(this.mainText())
        .fontSize(13)
        .fontColor(this.pal().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
      if (this.subText().length > 0) {
        Text(this.subText())
          .fontSize(10)
          .fontColor(this.pal().textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '42%' })
          .margin({ left: 6 })
      }
      Text('›')
        .fontSize(14)
        .fontColor(this.pal().textTertiary)
        .margin({ left: 6 })
    }
    .width('100%')
    .height(34)
    .padding({ left: 14, right: 14 })
    .borderRadius(10)
    // 与播放栏同一档玻璃：85% 不透明，背后内容能透出来
    .backgroundColor(this.pal().glassPlate)
    .backgroundBlurStyle(BlurStyle.Thick)
    .border({ width: 0.5, color: this.pal().glassEdge })
    .hitTestBehavior(HitTestMode.Default)
    .onClick(() => {
      router.pushUrl({ url: 'pages/SongDetailPage' }).catch(() => {
      });
    })
  }
}
