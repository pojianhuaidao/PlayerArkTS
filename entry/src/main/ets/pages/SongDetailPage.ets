import { router, promptAction } from '@kit.ArkUI';
import { AppTheme, Palette } from '../common/AppTheme';
import {
  PlaySession,
  SongItem,
  K_CURRENT_NAME,
  K_CURRENT_SINGER,
  K_CURRENT_COVER,
  K_PLAYER_STATUS,
  K_PROGRESS,
  K_DURATION,
  K_PLAY_MODE,
  K_QUEUE_COUNT,
  K_LYRIC_LINES,
  K_LYRIC_STATUS,
  K_BUFFERING
} from '../lx/core/player/PlaySession';
import { LyricLine } from '../lx/core/music/Lyric';
import { PlayIcons } from '../common/PlayIcons';
import { PlayIconSet } from '../common/PlayIconSet';

/**
 * 歌曲详情页
 *
 * 从底部播放栏 / 迷你歌词点进来。中间是 Swiper，左右滑切换三页：
 *   0 封面（大封面 + 进度 + 控制）
 *   1 歌词（跟随进度自动滚动并高亮，点某行跳转播放）
 *   2 队列（当前播放队列，点哪首播哪首）
 */
@Entry
@Component
struct SongDetailPage {
  @StorageProp('isDark') isDark: boolean = true;
  /** 状态栏 / 挖孔区、底部手势条的真实高度（vp），全屏布局下自行补偿 */
  @StorageProp('safeTop') safeTop: number = 0;
  @StorageProp('safeBottom') safeBottom: number = 0;
  @StorageProp(K_CURRENT_NAME) curName: string = '';
  @StorageProp(K_CURRENT_SINGER) curSinger: string = '';
  @StorageProp(K_CURRENT_COVER) curCover: string = '';
  @StorageProp(K_PLAYER_STATUS) status: string = 'idle';
  @StorageProp(K_BUFFERING) buffering: boolean = false;
  @StorageProp(K_PROGRESS) @Watch('onProgressChanged') progressSec: number = 0;
  @StorageProp(K_DURATION) durationSec: number = 0;
  @StorageProp(K_PLAY_MODE) playMode: string = 'list';
  @StorageProp(K_QUEUE_COUNT) queueCount: number = 0;
  @StorageProp(K_LYRIC_STATUS) lyricStatus: string = 'none';

  @State pageIndex: number = 1;  // 默认落在歌词页，左右滑看封面 / 队列
  @State lyricLines: LyricLine[] = [];
  @State lyricIndex: number = -1;
  @State dragging: boolean = false;
  @State dragValue: number = 0;

  private swiperController: SwiperController = new SwiperController();
  private lyricScroller: Scroller = new Scroller();
  private lastScrolled: number = -1;

  pal(): Palette {
    return AppTheme.palette(this.isDark);
  }

  aboutToAppear(): void {
    this.loadLyricLines();
    this.lyricIndex = this.indexOfProgress(this.progressSec);
    this.lastScrolled = -1;
  }

  private loadLyricLines(): void {
    const raw: LyricLine[] | undefined = AppStorage.get<LyricLine[]>(K_LYRIC_LINES);
    this.lyricLines = raw === undefined ? [] : raw;
  }

  private indexOfProgress(sec: number): number {
    const arr: LyricLine[] = this.lyricLines;
    if (arr.length === 0) {
      return -1;
    }
    let idx: number = -1;
    for (let i = 0; i < arr.length; i++) {
      const t: number = arr[i].time;
      if (t < 0) {
        continue;
      }
      if (t <= sec + 0.2) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  onProgressChanged(): void {
    const arr: LyricLine[] | undefined = AppStorage.get<LyricLine[]>(K_LYRIC_LINES);
    const next: LyricLine[] = arr === undefined ? [] : arr;
    if (next.length !== this.lyricLines.length) {
      this.lyricLines = next;
    }
    const idx: number = this.indexOfProgress(this.progressSec);
    if (idx !== this.lyricIndex) {
      this.lyricIndex = idx;
    }
    if (this.pageIndex === 1 && idx >= 0 && idx !== this.lastScrolled) {
      this.lastScrolled = idx;
      try {
        this.lyricScroller.scrollToIndex(idx, true, ScrollAlign.CENTER);
      } catch (e) {
      }
    }
  }

  private sliderValue(): number {
    return this.dragging ? this.dragValue : this.progressSec;
  }

  private timeText(sec: number): string {
    const v: number = sec > 0 ? Math.floor(sec) : 0;
    const m: number = Math.floor(v / 60);
    const s: number = v % 60;
    return `${m < 10 ? '0' : ''}${m}:${s < 10 ? '0' : ''}${s}`;
  }

  private statusLabel(): string {
    if (this.status === 'playing') {
      return this.buffering ? '缓冲中' : '播放中';
    }
    if (this.status === 'paused') {
      return '已暂停';
    }
    if (this.status === 'loading') {
      return '加载中';
    }
    return '未播放';
  }

  private modeLabel(): string {
    try {
      return PlaySession.getInstance().playModeLabel();
    } catch (e) {
      return '列表循环';
    }
  }

  private togglePlay(): void {
    try {
      PlaySession.getInstance().toggle();
    } catch (e) {
    }
  }

  private nextSong(): void {
    try {
      PlaySession.getInstance().next();
    } catch (e) {
    }
  }

  private prevSong(): void {
    try {
      PlaySession.getInstance().prev();
    } catch (e) {
    }
  }

  private cycleMode(): void {
    try {
      PlaySession.getInstance().cyclePlayMode();
    } catch (e) {
    }
  }

  private queue(): SongItem[] {
    try {
      return PlaySession.getInstance().queue;
    } catch (e) {
      return [];
    }
  }

  private playAt(index: number): void {
    try {
      PlaySession.getInstance().playAt(index);
    } catch (e) {
    }
  }

  // ---------------- 页面片段 ----------------

  @Builder
  topBar() {
    Row() {
      Text('‹')
        .fontSize(30)
        .fontColor(this.pal().textPrimary)
        .width(44)
        .height(44)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          router.back();
        })
      Column() {
        Text(this.curName.length > 0 ? this.curName : '未在播放')
          .fontSize(15)
          .fontColor(this.pal().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)
        Text(this.statusLabel())
          .fontSize(11)
          .fontColor(this.pal().textTertiary)
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)

      Text('≡')
        .fontSize(20)
        .fontColor(this.pal().textSecondary)
        .width(44)
        .height(44)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.swiperController.changeIndex(2, true);
        })
    }
    .width('100%')
    .height(56)
    .padding({ left: 6, right: 6 })
  }

  @Builder
  pageCover() {
    Column() {
      Column() {
        if (this.curCover.length > 0) {
          Image(this.curCover)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .borderRadius(14)
        } else {
          Text('♪')
            .fontSize(56)
            .fontColor(this.pal().textTertiary)
        }
      }
      .width(240)
      .height(240)
      .borderRadius(14)
      .backgroundColor(this.pal().bgCard)
      .justifyContent(FlexAlign.Center)
      .shadow({ radius: 24, color: '#40000000', offsetX: 0, offsetY: 8 })

      Text(this.curName.length > 0 ? this.curName : '未在播放')
        .fontSize(19)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.pal().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 22 })
        .width('100%')
        .textAlign(TextAlign.Center)

      Text(this.curSinger.length > 0 ? this.curSinger : '—')
        .fontSize(13)
        .fontColor(this.pal().textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 6 })
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32, right: 32 })
  }

  @Builder
  pageLyric() {
    Column() {
      if (this.lyricLines.length === 0) {
        Column() {
          Text(this.lyricStatus === 'loading' ? '歌词加载中…' : '暂无歌词')
            .fontSize(14)
            .fontColor(this.pal().textTertiary)
          Text('可在下方左右滑动切换封面 / 队列')
            .fontSize(11)
            .fontColor(this.pal().textTertiary)
            .margin({ top: 8 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List({ scroller: this.lyricScroller }) {
          ForEach(this.lyricLines, (line: LyricLine, index: number) => {
            ListItem() {
              Column() {
                Text(line.text.length > 0 ? line.text : '♪')
                  .fontSize(this.lyricIndex === index ? 17 : 14)
                  .fontWeight(this.lyricIndex === index ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(this.lyricIndex === index ? this.pal().primary : this.pal().textSecondary)
                  .textAlign(TextAlign.Center)
                  .width('100%')
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (line.translation.length > 0) {
                  Text(line.translation)
                    .fontSize(this.lyricIndex === index ? 13 : 11)
                    .fontColor(this.lyricIndex === index ? this.pal().textSecondary : this.pal().textTertiary)
                    .textAlign(TextAlign.Center)
                    .width('100%')
                    .maxLines(2)
                    .margin({ top: 3 })
                }
              }
              .width('100%')
              .padding({ top: 9, bottom: 9, left: 24, right: 24 })
              .onClick(() => {
                try {
                  PlaySession.getInstance().seek(line.time);
                } catch (e) {
                }
              })
            }
          }, (line: LyricLine, index: number) => `${index}_${line.time}`)
          ListItem() {
            Row().width('100%').height(120)
          }
        }
        .width('100%')
        .height('100%')
        .cachedCount(8)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .contentStartOffset(90)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  pageQueue() {
    Column() {
      Row() {
        Text(`播放队列（${this.queueCount}）`)
          .fontSize(13)
          .fontColor(this.pal().textSecondary)
          .layoutWeight(1)
        Text(this.modeLabel())
          .fontSize(12)
          .fontColor(this.pal().primary)
          .onClick(() => {
            this.cycleMode();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 6, bottom: 8 })

      List() {
        ForEach(this.queue(), (item: SongItem, index: number) => {
          ListItem() {
            Row() {
              Text(`${index + 1}`)
                .fontSize(12)
                .fontColor(this.pal().textTertiary)
                .width(26)
                .textAlign(TextAlign.Center)
              Column() {
                Text(item.name)
                  .fontSize(14)
                  .fontColor(this.curName === item.name ? this.pal().primary : this.pal().textPrimary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(item.singer)
                  .fontSize(11)
                  .fontColor(this.pal().textTertiary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 2 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Text(item.interval)
                .fontSize(11)
                .fontColor(this.pal().textTertiary)
                .margin({ left: 8 })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 9, bottom: 9 })
            .onClick(() => {
              this.playAt(index);
            })
          }
        }, (item: SongItem, index: number) => `${index}_${item.id}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  progressRow() {
    Row() {
      Text(this.timeText(this.sliderValue()))
        .fontSize(11)
        .fontColor(this.pal().textTertiary)
        .width(42)
      Slider({
        value: this.sliderValue(),
        min: 0,
        max: this.durationSec > 0 ? this.durationSec : 1,
        step: 1,
        style: SliderStyle.OutSet
      })
        .layoutWeight(1)
        .blockColor(this.pal().primary)
        .trackColor(this.pal().trackUnplayed)
        .selectedColor(this.pal().primary)
        .trackThickness(3)
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
            this.dragging = true;
            this.dragValue = value;
          } else if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.dragging = false;
            this.dragValue = value;
            try {
              PlaySession.getInstance().seek(value);
            } catch (e) {
            }
          }
        })
      Text(this.timeText(this.durationSec))
        .fontSize(11)
        .fontColor(this.pal().textTertiary)
        .width(42)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .padding({ left: 24, right: 24 })
  }

  @Builder
  controlRow() {
    Row() {
      Text(this.modeLabel())
        .fontSize(12)
        .fontColor(this.pal().textSecondary)
        .layoutWeight(1)
        .height(56)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.cycleMode();
        })
      Row() {
        Image(PlayIconSet.PREV)
          .width(26)
          .height(26)
          .fillColor(this.pal().textPrimary)
          .objectFit(ImageFit.Contain)
          .draggable(false)
      }
      .layoutWeight(1)
      .height(56)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.prevSong();
      })
      Row() {
        Image(PlayIconSet.playPause(this.status === 'playing'))
          .width(34)
          .height(34)
          .fillColor(this.pal().textPrimary)
          .objectFit(ImageFit.Contain)
          .draggable(false)
      }
      .width(56)
      .height(56)
      .borderRadius(28)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.pal().bgChip)
      .onClick(() => {
        this.togglePlay();
      })
      Row() {
        Image(PlayIconSet.NEXT)
          .width(26)
          .height(26)
          .fillColor(this.pal().textPrimary)
          .objectFit(ImageFit.Contain)
          .draggable(false)
      }
      .layoutWeight(1)
      .height(56)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.nextSong();
      })
      Row() {
        Image(PlayIconSet.LIST)
          .width(22)
          .height(22)
          .fillColor(this.pal().textSecondary)
          .objectFit(ImageFit.Contain)
          .draggable(false)
      }
      .layoutWeight(1)
      .height(56)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.swiperController.changeIndex(2, true);
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16 })
  }

  @Builder
  indicator() {
    Row() {
      ForEach([0, 1, 2], (i: number) => {
        Text(i === 0 ? '封面' : (i === 1 ? '歌词' : '队列'))
          .fontSize(11)
          .fontColor(this.pageIndex === i ? this.pal().primary : this.pal().textTertiary)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick(() => {
            this.swiperController.changeIndex(i, true);
          })
      }, (i: number) => `${i}`)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[this.pal().bg, 0.0], [this.pal().bgCard, 0.55], [this.pal().bg, 1.0]]
        })

      Column() {
        this.topBar()

        Swiper(this.swiperController) {
          this.pageCover()
          this.pageLyric()
          this.pageQueue()
        }
        .index(this.pageIndex)
        .indicator(false)
        .loop(false)
        .effectMode(EdgeEffect.Spring)
        .layoutWeight(1)
        .onChange((index: number) => {
          this.pageIndex = index;
          if (index === 1) {
            const idx: number = this.indexOfProgress(this.progressSec);
            this.lastScrolled = idx;
            if (idx >= 0) {
              try {
                this.lyricScroller.scrollToIndex(idx, false, ScrollAlign.CENTER);
              } catch (e) {
              }
            }
          }
        })

        this.indicator()

        Column() {
          this.progressRow()
          this.controlRow()
        }
        .width('100%')
        .padding({ top: 6, bottom: 26 })
      }
      .width('100%')
      .height('100%')
      // 全屏布局：顶部让开状态栏 / 挖孔额头，底部让开手势条，歌词页才不会被压住
      .padding({ top: this.safeTop, bottom: this.safeBottom })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pal().bg)
  }
}
