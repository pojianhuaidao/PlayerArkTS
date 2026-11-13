import { promptAction } from '@kit.ArkUI';
import { AppTheme, Palette } from '../common/AppTheme';
import { getBoardSongs, getPlaylistDetailAll, LxBoardItem, LxPlaylistItem, LxListDetail,
  platformName } from '../lx/core/music/MusicList';
import { SongItem, PlaySession, songFromSearch } from '../lx/core/player/PlaySession';
import { SourceEngine } from '../lx/core/source/SourceEngine';
import { LocalMusic, ImportResult } from '../lx/core/local/LocalMusic';
import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { MiniLyricBar } from './MiniLyricBar';
import { MusicRecommendView } from './MusicRecommendView';
import { PlayIcons } from '../common/PlayIcons';
import { PlayIconSet } from '../common/PlayIconSet';
import { K_PLAYER_DOCK, PLAYER_DOCK_DEFAULT } from '../lx/core/settings/PlaySettings';

function fmtTime(seconds: number): string {
  const total: number = Math.max(0, Math.floor(seconds));
  const m: number = Math.floor(total / 60);
  const s: number = total % 60;
  return `${m < 10 ? '0' : ''}${m}:${s < 10 ? '0' : ''}${s}`;
}

/**
 * 音乐页
 *
 * 结构：上方内容区（推荐界面 / 歌单曲目 / 本地音乐）+ 底部悬浮层（迷你歌词条 + 播放栏）。
 * 底部悬浮层与页签胶囊都是 85% 半透明玻璃，列表内容一直延伸到屏幕最底部、从玻璃层下面
 * 透出来，所以内容区不再预留底部空白（滚到底时靠列表尾部除距把最后一项顶到玻璃层上方）。
 */
@Component
export struct MusicPanel {
  /** 页签胶囊占掉的高度：底部悬浮层要抬到它上面 */
  @Prop capsuleReserve: number = 72;
  @StorageProp('isDark') isDark: boolean = true;
  @StorageProp('safeBottom') safeBottom: number = 0;
  @StorageProp('cfg_show_mini_lyric') showMiniLyric: boolean = true;
  /** 播放控件悬浮位置：上中 / 右上 / 左下 / 下中 / 右下（设置 - 音乐设置 - 播放控件控制） */
  /**
   * 播放控件悬浮档位。用 @StorageLink 双向订阅 AppStorage（设置页写、这里读，
   * 任一侧变动都能把最新的档位推进本组件，避免单向绑定的副本取值不刷新）。
   */
  @StorageLink(K_PLAYER_DOCK) @Watch('onDockChanged') playerDock: string = PLAYER_DOCK_DEFAULT;
  /** 播放控件展开态；收缩后只露一个小封面，点一下再展开 */
  @State playerExpanded: boolean = true;

  @State platformTip: string = 'QQ音乐 · 推荐歌单';
  @State detailOpen: boolean = false;
  @State localOpen: boolean = false;
  @State localSongs: SongItem[] = [];
  @State localImporting: boolean = false;
  @StorageProp('local_version') @Watch('onLocalVer') localVer: number = 0;
  @State detailName: string = '';
  @State detailPlatform: string = '';
  @State detailSongs: SongItem[] = [];
  @State detailLoading: boolean = false;
  @State playingIndex: number = -1;

  @StorageProp('ps_current_name') curName: string = '';
  @StorageProp('ps_current_singer') curSinger: string = '';
  @StorageProp('ps_current_cover') curCover: string = '';
  @StorageProp('ps_player_status') playerStatus: string = '';
  @StorageProp('ps_progress') progress: number = 0;
  @StorageProp('ps_duration') duration: number = 0;

  private songScroller: Scroller = new Scroller();

  pal(): Palette {
    return AppTheme.palette(this.isDark);
  }

  /** 底部玻璃层占掉的总高度：内容列表尾部让出这么多，滚到底时最后一项露在玻璃层上方 */
  private contentInset(): number {
    let h: number = this.capsuleReserve;
    if (this.curName.length > 0) {
      h = h + 56;
      if (this.showMiniLyric) {
        h = h + 36;
      }
    }
    return h + 12;
  }

  private onDockChanged(): void {
    // 切了悬浮位置就回到展开态，让用户直接看到新位置的效果
    this.playerExpanded = true;
  }

  /** 是否贴页面顶部（上排两档） */
  private dockAtTop(): boolean {
    return this.playerDock.indexOf('top') === 0;
  }

  /**
   * 展开态水平对齐。
   *
   * 上排三档要能互相区分，否则用户点「上中」看不出任何变化会误判成点击失效：
   * top-center 水平居中并整体下移到工具栏标题下方，top-right 贴右上角。
   * 下排居中，选左下 / 右下时贴对应边。
   */
  private dockJustify(): FlexAlign {
    if (this.playerDock === 'top-center') {
      return FlexAlign.Center;
    }
    if (this.dockAtTop()) {
      return FlexAlign.End;
    }
    if (this.playerDock === 'bottom-left') {
      return FlexAlign.Start;
    }
    if (this.playerDock === 'bottom-right') {
      return FlexAlign.End;
    }
    return FlexAlign.Center;
  }

  /** 上排两档离页面顶部多远：居中那档要避开左侧工具栏标题，整体下移 */
  private dockTopPadding(): number {
    return this.playerDock === 'top-center' ? 76 : 12;
  }

  /** 收缩态（小封面）严格按档位吸附 */
  private dockJustifyCollapsed(): FlexAlign {
    if (this.playerDock.indexOf('left') >= 0 && this.playerDock.indexOf('bottom') >= 0) {
      return FlexAlign.Start;
    }
    if (this.playerDock.indexOf('right') >= 0) {
      return FlexAlign.End;
    }
    if (this.playerDock === 'top-center' || this.playerDock === 'bottom-center') {
      return FlexAlign.Center;
    }
    return this.dockAtTop() ? FlexAlign.End : FlexAlign.Center;
  }

  private onLocalVer(): void {
    if (this.localOpen) {
      this.localSongs = LocalMusic.getInstance().songsForUi();
    }
  }

  // ------------------------------------------------------------ 本地音乐

  private openLocal(): void {
    this.detailOpen = false;
    this.localOpen = true;
    this.localSongs = LocalMusic.getInstance().songsForUi();
  }

  /** 扫描本地音乐：文件管理的音频聚合视图 → 内核 LocalMusic 导入 */
  private scanLocal(): void {
    if (this.localImporting) {
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.mergeMode = picker.MergeTypeMode.AUDIO;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      documentPicker.select(options)
        .then((uris: string[]) => {
          this.runLocalImport(uris);
        })
        .catch(() => {
        });
    } catch (e) {
      promptAction.showToast({ message: '打不开文件管理的音频视图' });
    }
  }

  private async runLocalImport(uris: string[]): Promise<void> {
    if (uris.length === 0) {
      return;
    }
    this.localImporting = true;
    try {
      const result: ImportResult = await LocalMusic.getInstance().importUris(uris);
      promptAction.showToast({
        message: `新增 ${result.added} 首，跳过 ${result.skipped}，不支持 ${result.unsupported}，失败 ${result.failed}`
      });
    } catch (e) {
      promptAction.showToast({ message: '导入失败，请重试' });
    }
    this.localImporting = false;
    this.localSongs = LocalMusic.getInstance().songsForUi();
  }

  private playLocalAt(index: number): void {
    if (this.localSongs.length === 0) {
      return;
    }
    this.playingIndex = index;
    PlaySession.getInstance().setQueueAndPlay(this.localSongs, index);
  }

  // ------------------------------------------------------------ 歌单 / 榜单

  private openPlaylist(item: LxPlaylistItem): void {
    this.localOpen = false;
    this.detailOpen = true;
    this.detailName = item.name;
    this.detailPlatform = platformName(item.source);
    this.detailSongs = [];
    this.playingIndex = -1;
    this.detailLoading = true;
    this.loadDetail(item.source, item.id, item.name);
  }

  private openBoard(board: LxBoardItem): void {
    this.localOpen = false;
    this.detailOpen = true;
    this.detailName = board.name;
    this.detailPlatform = platformName(board.source);
    this.detailSongs = [];
    this.playingIndex = -1;
    this.detailLoading = true;
    this.loadDetail(board.source, board.id, board.name);
  }

  private async loadDetail(source: string, id: string, name: string): Promise<void> {
    try {
      let detail: LxListDetail;
      // 榜单与歌单在五个平台上的取法不同：歌单走 playlist 接口，榜单走 board 接口，
      // 内核里两者都以 LxListDetail 返回，这里按"歌单取不到就按榜单再取一次"兜底。
      try {
        detail = await getPlaylistDetailAll(source, id);
      } catch (e1) {
        detail = await getBoardSongs(source, id, 1, name);
      }
      const quality: string = PlaySession.getInstance().quality;
      const arr: SongItem[] = [];
      for (let i = 0; i < detail.list.length; i++) {
        arr.push(songFromSearch(detail.list[i], quality));
      }
      this.detailSongs = arr;
      if (detail.info.name.length > 0) {
        this.detailName = detail.info.name;
      }
    } catch (e) {
      const msg: string = (e as Error).message === undefined ? '歌单加载失败' : (e as Error).message;
      promptAction.showToast({ message: `歌单加载失败：${msg}` });
    }
    this.detailLoading = false;
  }

  private async playAt(index: number): Promise<void> {
    if (this.detailSongs.length === 0) {
      return;
    }
    if (SourceEngine.getInstance().getLoadedSourceId().length === 0) {
      promptAction.showToast({ message: '尚未导入音源：设置 → 音乐设置 → 音源设置 里导入自定义音源后再播放' });
      return;
    }
    this.playingIndex = index;
    try {
      await PlaySession.getInstance().setQueueAndPlay(this.detailSongs, index);
    } catch (e) {
      const msg: string = (e as Error).message === undefined ? '播放失败' : (e as Error).message;
      promptAction.showToast({ message: `播放失败：${msg}` });
    }
  }

  private async togglePlay(): Promise<void> {
    try {
      await PlaySession.getInstance().toggle();
    } catch (e) {
    }
  }

  private isPlaying(): boolean {
    return this.playerStatus === 'playing' || this.playerStatus === 'buffering';
  }

  // ------------------------------------------------------------ 组件

  /** 顶部信息条：来源提示 + 本地音乐入口（推荐界面本身不含这条） */
  @Builder
  headerBar() {
    Row() {
      Text(this.localOpen ? '本地音乐 · 设备内音频索引' : (this.detailOpen ? '歌单曲目' : this.platformTip))
        .fontSize(12)
        .fontColor(this.pal().textTertiary)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.localOpen || this.detailOpen) {
        Text('返回推荐')
          .fontSize(12)
          .fontColor(this.pal().primary)
          .padding({ left: 10, right: 10, top: 3, bottom: 3 })
          .borderRadius(11)
          .backgroundColor(this.pal().bgChip)
          .onClick(() => {
            this.localOpen = false;
            this.detailOpen = false;
          })
      } else {
        Text(`本地 ${LocalMusic.getInstance().count()} 首 ›`)
          .fontSize(12)
          .fontColor(this.pal().primary)
          .padding({ left: 10, right: 10, top: 3, bottom: 3 })
          .borderRadius(11)
          .backgroundColor(this.pal().bgChip)
          .onClick(() => {
            this.openLocal();
          })
      }
    }
    .width('100%')
    .height(36)
  }

  @Builder
  localView() {
    Column() {
      Row() {
        Text('扫描本地音乐')
          .fontSize(13)
          .fontColor(Color.White)
          .height(32)
          .padding({ left: 14, right: 14 })
          .borderRadius(16)
          .backgroundColor(this.pal().primary)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.scanLocal();
          })
        Text(this.localImporting ? '导入中…' : `${this.localSongs.length} 首`)
          .fontSize(12)
          .fontColor(this.pal().textTertiary)
          .margin({ left: 10 })
      }
      .width('100%')
      .padding({ bottom: 8 })

      if (this.localSongs.length === 0) {
        Column() {
          Text('♪')
            .fontSize(42)
            .fontColor(this.pal().textTertiary)
          Text('还没有本地歌曲')
            .fontSize(13)
            .fontColor(this.pal().textSecondary)
            .margin({ top: 10 })
          Text('点「扫描本地音乐」从文件管理的音频分类里选')
            .fontSize(11)
            .fontColor(this.pal().textTertiary)
            .margin({ top: 6 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ scroller: this.songScroller }) {
          ForEach(this.localSongs, (item: SongItem, index: number) => {
            ListItem() {
              this.songRow(item, index)
            }
          }, (item: SongItem) => item.id)
          ListItem() {
            Column().height(this.contentInset()).width('100%')
          }
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .divider({ strokeWidth: 0.5, color: this.pal().divider, startMargin: 34 })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  songRow(item: SongItem, index: number) {
    Row() {
      Text(`${index + 1}`)
        .fontSize(12)
        .fontColor(this.pal().textTertiary)
        .width(30)
        .textAlign(TextAlign.Center)
      Column() {
        Text(item.name)
          .fontSize(14)
          .fontColor(this.playingIndex === index ? this.pal().primary : this.pal().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(item.singer.length > 0 ? item.singer : '未知歌手')
          .fontSize(11)
          .fontColor(this.pal().textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(item.interval.length > 0 ? item.interval : '--:--')
        .fontSize(11)
        .fontColor(this.pal().textTertiary)
        .margin({ left: 8 })
    }
    .width('100%')
    .height(54)
    .padding({ left: 4, right: 8 })
    .onClick(() => {
      this.playAt(index);
    })
  }

  @Builder
  detailHeader() {
    Column() {
      Row() {
        Text('‹')
          .fontSize(26)
          .fontColor(this.pal().textPrimary)
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.detailOpen = false;
          })
        Column() {
          Text(this.detailName)
            .fontSize(15)
            .fontColor(this.pal().textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.detailLoading ? '正在获取歌曲…' : `共 ${this.detailSongs.length} 首 · ${this.detailPlatform}`)
            .fontSize(11)
            .fontColor(this.pal().textTertiary)
            .margin({ top: 2 })
            .width('100%')
        }
        .layoutWeight(1)
        .margin({ left: 6 })
        .alignItems(HorizontalAlign.Start)

        Text('播放全部')
          .fontSize(12)
          .fontColor(Color.White)
          .height(30)
          .padding({ left: 12, right: 12 })
          .borderRadius(15)
          .backgroundColor(this.pal().primary)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.playAt(0);
          })
      }
      .width('100%')
      .height(48)
    }
    .width('100%')
  }

  @Builder
  detailView() {
    Column() {
      this.detailHeader()
      if (this.detailLoading) {
        Column() {
          LoadingProgress()
            .width(34)
            .height(34)
            .color(this.pal().primary)
          Text('正在获取歌单歌曲…')
            .fontSize(12)
            .fontColor(this.pal().textTertiary)
            .margin({ top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.detailSongs.length === 0) {
        Column() {
          Text('这个歌单没有取到歌曲')
            .fontSize(13)
            .fontColor(this.pal().textSecondary)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ scroller: this.songScroller }) {
          ForEach(this.detailSongs, (item: SongItem, index: number) => {
            ListItem() {
              this.songRow(item, index)
            }
          }, (item: SongItem) => item.id)
          ListItem() {
            Column().height(this.contentInset()).width('100%')
          }
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .divider({ strokeWidth: 0.5, color: this.pal().divider })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 收缩态：只露一个封面小方块，点一下展开播放控件（不挡内容，和页签回缩一个逻辑） */
  @Builder
  coverDock() {
    Column() {
      if (this.curCover.length > 0) {
        Image(this.curCover)
          .width(48)
          .height(48)
          .objectFit(ImageFit.Cover)
      } else {
        Text('♪')
          .fontSize(20)
          .fontColor(this.pal().textSecondary)
      }
    }
    .width(48)
    .height(48)
    .borderRadius(12)
    .clip(true)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.pal().glassPlate)
    .backgroundBlurStyle(BlurStyle.Thick)
    .border({ width: 0.5, color: this.pal().glassEdge })
    .shadow({ radius: 10, color: '#33000000', offsetY: 3 })
    .accessibilityText('播放控件已收起，点按展开')
    .accessibilityLevel('yes')
    .onClick(() => {
      this.playerExpanded = true;
    })
  }

  /** 播放栏：85% 半透明玻璃，背后（含上一页内容）能透出来 */
  @Builder
  miniPlayer() {
    Row() {
      if (this.curCover.length > 0) {
        Image(this.curCover)
          .width(36)
          .height(36)
          .borderRadius(8)
          .objectFit(ImageFit.Cover)
      } else {
        Column() {
          Text('♪')
            .fontSize(16)
            .fontColor(this.pal().textSecondary)
        }
        .width(36)
        .height(36)
        .borderRadius(8)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.pal().bgChip)
      }
      Column() {
        Text(this.curName)
          .fontSize(13)
          .fontColor(this.pal().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.curSinger.length > 0 ? this.curSinger : fmtTime(this.progress))
          .fontSize(11)
          .fontColor(this.pal().textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 1 })
          .width('100%')
      }
      .layoutWeight(1)
      .margin({ left: 8 })
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        // 点歌曲信息进详情（封面/歌词/队列左右滑），播控键独立响应
        router.pushUrl({ url: 'pages/SongDetailPage' }).catch(() => {
        });
      })

      // 播控键统一用 PlayIconSet 图标（与 SMB/本地视频播放器同一套外观），图标本体 24vp、热区 44vp
      Row() {
        Image(PlayIconSet.PREV)
          .width(24)
          .height(24)
          .fillColor(this.pal().textSecondary)
          .objectFit(ImageFit.Contain)
          .draggable(false)
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        PlaySession.getInstance().prev();
      })
      Row() {
        Image(PlayIconSet.playPause(this.isPlaying()))
          .width(30)
          .height(30)
          .fillColor(this.pal().textPrimary)
          .objectFit(ImageFit.Contain)
          .draggable(false)
      }
      .width(44)
      .height(44)
      .borderRadius(22)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.pal().bgChip)
      .onClick(() => {
        this.togglePlay();
      })
      Row() {
        Image(PlayIconSet.NEXT)
          .width(24)
          .height(24)
          .fillColor(this.pal().textSecondary)
          .objectFit(ImageFit.Contain)
          .draggable(false)
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        PlaySession.getInstance().next();
      })
      // 收起成小封面：与页签胶囊一样，收起只为不挡内容，点封面随时展开
      Row() {
        Text('⌄')
          .fontSize(18)
          .fontColor(this.pal().textSecondary)
      }
      .width(34)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .accessibilityText('收起播放控件')
      .onClick(() => {
        this.playerExpanded = false;
      })
    }
    .width('100%')
    .height(50)
    .padding({ left: 8, right: 8 })
    .borderRadius(12)
    .backgroundColor(this.pal().glassPlate)
    .backgroundBlurStyle(BlurStyle.Thick)
    .border({ width: 0.5, color: this.pal().glassEdge })
    .shadow({ radius: 12, color: '#22000000', offsetY: 3 })
    .margin({ top: 6 })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 内容区：铺满，列表自己把尾部让给底部玻璃层
      Column() {
        this.headerBar()
        if (this.localOpen) {
          this.localView()
        } else if (this.detailOpen) {
          this.detailView()
        } else {
          MusicRecommendView({
            bottomInset: this.contentInset(),
            onOpenPlaylist: (item: LxPlaylistItem) => {
              this.openPlaylist(item);
            },
            onOpenBoard: (board: LxBoardItem) => {
              this.openBoard(board);
            },
            onPlatformChange: (source: string) => {
              this.platformTip = `${platformName(source)} · 推荐歌单`;
            },
          })
        }
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: AppTheme.contentMaxWidth })
      .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })

      // 悬浮播放层：按「设置 - 音乐设置 - 播放控件控制」的档位吸附。
      // 上排贴在工具栏「音乐」标题下方靠右（避免压住标题），下排落在页签胶囊之上（避让任务栏）。
      if (this.curName.length > 0) {
        Column() {
          Row() {
            if (this.playerExpanded) {
              Column() {
                if (this.showMiniLyric) {
                  MiniLyricBar()
                }
                this.miniPlayer()
              }
              .width('86%')
              .constraintSize({ maxWidth: 420 })
            } else {
              this.coverDock()
            }
          }
          .width('100%')
          .justifyContent(this.playerExpanded ? this.dockJustify() : this.dockJustifyCollapsed())
        }
        .width('100%')
        .height('100%')
        .justifyContent(this.dockAtTop() ? FlexAlign.Start : FlexAlign.End)
        .padding(this.dockAtTop()
          ? { left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: this.dockTopPadding() }
          : { left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: this.capsuleReserve })
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pal().bg)
  }
}
