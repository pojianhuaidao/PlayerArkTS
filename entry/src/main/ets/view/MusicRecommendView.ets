import { AppTheme, Palette } from '../common/AppTheme';
import { getBoards, getRecommendPlaylists, LxBoardItem, LxPlaylistItem, LxSortItem,
  platformName, sortListOf } from '../lx/core/music/MusicList';

/**
 * 音乐页「推荐」界面：照搬隔壁「听·音乐」(D:\lxmusic-harmony) 的 views/RecommendView.ets
 *
 * 布局与那边一致：顶部一排五平台按钮（TX / KW / KG / MG / WY）→ 「在线榜单」小卡网格 →
 * 「推荐歌单」列表（标题栏右侧排序下拉）→ 上拉加载更多。配色不抄那边的资源 token，
 * 走本工程的 AppTheme.palette(isDark)，所以深浅色跟随主界面。
 *
 * 数据全部来自内核 MusicList 的平台接口，与音源无关（音源只决定能否解析出播放链接）。
 */

/** 平台顺序与按钮一致：TX / KW / KG / MG / WY */
const R_TAB_SOURCES: string[] = ['tx', 'kw', 'kg', 'mg', 'wy'];
const R_TAB_LABELS: string[] = ['TX', 'KW', 'KG', 'MG', 'WY'];

const F_ITEM: number = 15;
const F_SUB: number = 12.5;

/** 榜单卡配色（按榜单位置循环，颜色与深浅模式无关） */
const BOARD_COLORS: string[][] = [
  ['#7B6CF6', '#4E3FD6'],
  ['#3FD07A', '#17A94F'],
  ['#FF7A59', '#E2432F'],
  ['#4FA8FF', '#1E6FD9'],
  ['#FFB13D', '#E0810F'],
  ['#F26DB4', '#C22C86'],
];

function boardColors(index: number): string[] {
  return BOARD_COLORS[index % BOARD_COLORS.length];
}

/** 榜单小卡：边长 64vp，五字榜名两行放得下 */
const BOARD_CARD_HEIGHT: number = 64;
const BOARD_MIN_WIDTH: number = 72;
const BOARD_GAP: number = 8;

/** 空条目哨兵：数据源刷新期间框架可能按旧 totalCount 请求越界索引 */
const EMPTY_PLAYLIST_ITEM: LxPlaylistItem = {
  id: '',
  name: '',
  author: '',
  img: '',
  desc: '',
  playCount: '',
  total: 0,
  time: '',
  source: '',
};

/** 在线榜单卡片 */
@Component
struct RankCard {
  @Prop title: string = '';
  @Prop platform: string = '';
  @Prop colorA: string = '#7B6CF6';
  @Prop colorB: string = '#4E3FD6';
  onTap: () => void = () => {
  };

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({ angle: 160, colors: [[this.colorA, 0.0], [this.colorB, 1.0]] })

      Column({ space: 2 }) {
        Row({ space: 3 }) {
          Circle().width(7).height(7).fill('#FFFFFF').opacity(0.85)
          Text(this.platform)
            .fontSize(8.5)
            .fontColor('#CCFFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')

        Blank()

        Text(this.title)
          .fontSize(11.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
          .lineHeight(14)
          .textShadow({ radius: 5, color: '#33000000', offsetX: 0, offsetY: 1 })

        Blank()
      }
      .width('100%')
      .height('100%')
      .padding({ left: 8, right: 8, top: 7, bottom: 7 })
    }
    .width('100%')
    .height('100%')
    .borderRadius(12)
    .clip(true)
    .shadow({ radius: 6, color: '#12000000', offsetX: 0, offsetY: 2 })
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 歌单 / 榜单封面：网络图，失败或无图回落为音符底 */
@Component
struct LxCover {
  @Prop @Watch('onUrlChanged') url: string = '';
  @Prop name: string = '';
  @Prop boxSize: number = 58;
  @Prop radius: number = 14;
  @State failed: boolean = false;

  onUrlChanged(): void {
    this.failed = false;
  }

  pal(): Palette {
    return AppTheme.palette(true);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.url.length > 0 && !this.failed) {
        Image(this.url)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .onError(() => {
            this.failed = true;
          })
      } else {
        Column() {
          Text('♪')
            .fontSize(this.boxSize * 0.4)
            .fontColor('#B3FFFFFF')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .linearGradient({ angle: 145, colors: [['#3A3A3E', 0.0], ['#222226', 1.0]] })
      }
    }
    .width(this.boxSize)
    .height(this.boxSize)
    .borderRadius(this.radius)
    .clip(true)
    .backgroundColor('#1C1C1E')
  }
}

/** 推荐歌单的懒加载数据源（一页 30 条、可继续上拉） */
class PlaylistSource implements IDataSource {
  private items: LxPlaylistItem[] = [];
  private listeners: DataChangeListener[] = [];

  setItems(items: LxPlaylistItem[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): LxPlaylistItem {
    if (index < 0 || index >= this.items.length) {
      return EMPTY_PLAYLIST_ITEM;
    }
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }
}

@Component
export struct MusicRecommendView {
  /** 底部浮层（歌词条 + 播放栏 + 页签栏）占掉的高度，列表尾部让出这么多 */
  @Prop bottomInset: number = 0;
  /** 打开歌单（点歌单行） */
  onOpenPlaylist: (item: LxPlaylistItem) => void = () => {
  };
  /** 打开榜单（点榜单卡） */
  onOpenBoard: (board: LxBoardItem) => void = () => {
  };
  /** 平台切换回调：壳层的「本地音乐」入口与本页的平台提示要跟着变 */
  onPlatformChange: (source: string) => void = () => {
  };

  @StorageProp('isDark') isDark: boolean = true;
  @State platform: string = 'tx';
  @State sorts: LxSortItem[] = [];
  @State sortIndex: number = 0;
  @State boards: LxBoardItem[] = [];
  @State boardAreaWidth: number = 0;
  @State playlists: LxPlaylistItem[] = [];
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State refreshing: boolean = false;
  @State error: string = '';
  @State page: number = 0;
  @State noMore: boolean = false;
  private playlistSource: PlaylistSource = new PlaylistSource();

  pal(): Palette {
    return AppTheme.palette(this.isDark);
  }

  aboutToAppear(): void {
    this.sorts = sortListOf(this.platform);
    this.sortIndex = 0;
    this.onPlatformChange(this.platform);
    void this.reload();
  }

  private currentSortId(): string {
    if (this.sortIndex >= 0 && this.sortIndex < this.sorts.length) {
      return this.sorts[this.sortIndex].id;
    }
    return '';
  }

  private currentSortName(): string {
    if (this.sortIndex >= 0 && this.sortIndex < this.sorts.length) {
      return this.sorts[this.sortIndex].name;
    }
    return '';
  }

  /** 拉第一页（换来源、换排序、下拉刷新都走它） */
  private async reload(): Promise<void> {
    this.error = '';
    if (this.playlists.length === 0) {
      this.loading = true;
    }
    this.boards = getBoards(this.platform);
    try {
      const list: LxPlaylistItem[] = await getRecommendPlaylists(this.platform, this.currentSortId(), 1);
      this.playlists = list;
      this.playlistSource.setItems(this.playlists);
      this.page = 1;
      this.noMore = list.length === 0;
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.loading = false;
      this.refreshing = false;
    }
  }

  /** 上拉加载下一页 */
  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || this.noMore || this.error.length > 0) {
      return;
    }
    this.loadingMore = true;
    try {
      const list: LxPlaylistItem[] =
        await getRecommendPlaylists(this.platform, this.currentSortId(), this.page + 1);
      if (list.length === 0) {
        this.noMore = true;
        return;
      }
      this.playlists = this.playlists.concat(list);
      this.playlistSource.setItems(this.playlists);
      this.page = this.page + 1;
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.loadingMore = false;
    }
  }

  private switchPlatform(source: string): void {
    if (this.platform === source) {
      return;
    }
    this.platform = source;
    this.sorts = sortListOf(source);
    this.sortIndex = 0;
    this.playlists = [];
    this.playlistSource.setItems(this.playlists);
    this.page = 0;
    this.noMore = false;
    this.onPlatformChange(source);
    void this.reload();
  }

  private switchSort(index: number): void {
    if (index === this.sortIndex) {
      return;
    }
    this.sortIndex = index;
    this.playlists = [];
    this.playlistSource.setItems(this.playlists);
    this.page = 0;
    void this.reload();
  }

  private boardColumnCount(): number {
    if (this.boardAreaWidth <= 0) {
      return 4;
    }
    const count: number = Math.floor((this.boardAreaWidth + BOARD_GAP) / (BOARD_MIN_WIDTH + BOARD_GAP));
    return Math.max(4, count);
  }

  private boardColumnsTemplate(): string {
    let tpl: string = '';
    const cols: number = this.boardColumnCount();
    for (let i = 0; i < cols; i++) {
      tpl = tpl.length === 0 ? '1fr' : `${tpl} 1fr`;
    }
    return tpl;
  }

  private boardRows(): number {
    const cols: number = this.boardColumnCount();
    return Math.max(1, Math.ceil(this.boards.length / cols));
  }

  private boardRowsTemplate(): string {
    let tpl: string = '';
    const rows: number = this.boardRows();
    for (let i = 0; i < rows; i++) {
      tpl = tpl.length === 0 ? '1fr' : `${tpl} 1fr`;
    }
    return tpl;
  }

  private boardGridHeight(): number {
    const rows: number = this.boardRows();
    return rows * BOARD_CARD_HEIGHT + (rows - 1) * BOARD_GAP;
  }

  /** 歌单行第二行：作者 · 播放量 · 曲目数 */
  private playlistMeta(item: LxPlaylistItem): string {
    const parts: string[] = [];
    if (item.author.length > 0) {
      parts.push(item.author);
    }
    if (item.playCount.length > 0) {
      parts.push(item.playCount);
    }
    if (item.total > 0) {
      parts.push(`${item.total} 首`);
    }
    return parts.join(' · ');
  }

  // ------------------------------------------------------------ 构建

  @Builder
  platformTabs() {
    Row({ space: 4 }) {
      ForEach(R_TAB_SOURCES, (source: string, index: number) => {
        Text(R_TAB_LABELS[index])
          .fontSize(13.5)
          .fontWeight(this.platform === source ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.platform === source ? Color.White : this.pal().textSecondary)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(32)
          .borderRadius(16)
          .backgroundColor(this.platform === source ? this.pal().primary : Color.Transparent)
          .animation({ duration: 160, curve: Curve.EaseOut })
          .onClick(() => {
            this.switchPlatform(source);
          })
          .accessibilityText(`切换到${platformName(source)}`)
          .accessibilityLevel('yes')
      }, (source: string) => source)
    }
    .width('100%')
    .padding(3)
    .borderRadius(19)
    .backgroundColor(this.pal().bgChip)
    .margin({ bottom: 4 })
  }

  @Builder
  sortMenu() {
    Menu() {
      ForEach(this.sorts, (item: LxSortItem, index: number) => {
        MenuItem({ content: item.name })
          .onClick(() => {
            this.switchSort(index);
          })
      }, (item: LxSortItem, index: number) => `${index}_${item.id}`)
    }
  }

  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.pal().textPrimary)
  }

  @Builder
  playlistRow(item: LxPlaylistItem) {
    Row({ space: 12 }) {
      LxCover({ url: item.img, name: item.name, boxSize: 58, radius: 14 })

      Column({ space: 5 }) {
        Text(item.name)
          .fontSize(F_ITEM)
          .fontColor(this.pal().textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        if (this.playlistMeta(item).length > 0) {
          Text(this.playlistMeta(item))
            .fontSize(F_SUB)
            .fontColor(this.pal().textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›')
        .fontSize(18)
        .fontColor(this.pal().textTertiary)
    }
    .width('100%')
    .height(78)
    .onClick(() => {
      this.onOpenPlaylist(item);
    })
  }

  @Builder
  statusBlock() {
    Column({ space: 10 }) {
      if (this.loading) {
        Text(`正在加载${platformName(this.platform)}的推荐…`)
          .fontSize(14.5)
          .fontColor(this.pal().textSecondary)
      } else if (this.error.length > 0) {
        Text(this.error)
          .fontSize(13.5)
          .fontColor(this.pal().textSecondary)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .padding({ left: 26, right: 26 })
        Text('点击重试')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().primary)
          .padding({ left: 18, right: 18, top: 8, bottom: 8 })
          .borderRadius(18)
          .backgroundColor(this.pal().bgChip)
          .onClick(() => {
            void this.reload();
          })
      } else {
        Text('这个来源暂时没有推荐内容')
          .fontSize(14.5)
          .fontColor(this.pal().textSecondary)
      }
    }
    .width('100%')
    .padding({ left: 32, right: 32, top: 40, bottom: 30 })
  }

  build() {
    Column() {
      this.platformTabs()

      Refresh({ refreshing: $$this.refreshing }) {
        List({ space: 0 }) {
          if (this.boards.length > 0) {
            // -------------------------------------------- 在线榜单
            ListItem() {
              Row({ space: 8 }) {
                this.sectionTitle('在线榜单')
                Text(platformName(this.platform))
                  .fontSize(12)
                  .fontColor(this.pal().primary)
                  .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                  .borderRadius(9)
                  .backgroundColor(this.pal().bgChip)
                Blank()
              }
              .width('100%')
              .padding({ top: 8, bottom: 12 })
            }

            ListItem() {
              Grid() {
                ForEach(this.boards, (board: LxBoardItem, index: number) => {
                  GridItem() {
                    RankCard({
                      title: board.name,
                      platform: platformName(board.source),
                      colorA: boardColors(index)[0],
                      colorB: boardColors(index)[1],
                      onTap: () => {
                        this.onOpenBoard(board);
                      },
                    })
                  }
                }, (board: LxBoardItem) => board.id)
              }
              .columnsTemplate(this.boardColumnsTemplate())
              .rowsTemplate(this.boardRowsTemplate())
              .columnsGap(BOARD_GAP)
              .rowsGap(BOARD_GAP)
              .width('100%')
              .height(this.boardGridHeight())
              .scrollBar(BarState.Off)
              .onAreaChange((_oldArea: Area, newArea: Area) => {
                const width: number = (newArea.width as number);
                if (width > 0 && Math.abs(width - this.boardAreaWidth) > 1) {
                  this.boardAreaWidth = width;
                }
              })
            }
          }

          // -------------------------------------------- 推荐歌单
          ListItem() {
            Row({ space: 8 }) {
              this.sectionTitle('推荐歌单')
              Blank()
              if (this.loadingMore) {
                Text('加载中…')
                  .fontSize(12)
                  .fontColor(this.pal().textTertiary)
              }
              if (this.sorts.length > 1) {
                Row({ space: 3 }) {
                  Text(this.currentSortName())
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.pal().primary)
                    .maxLines(1)
                  Text('▾')
                    .fontSize(12)
                    .fontColor(this.pal().primary)
                }
                .height(30)
                .padding({ left: 12, right: 8 })
                .borderRadius(15)
                .backgroundColor(this.pal().bgChip)
                .bindMenu(this.sortMenu())
                .accessibilityText(`排序：${this.currentSortName()}，点按切换`)
                .accessibilityLevel('yes')
              }
            }
            .width('100%')
            .padding({ top: this.boards.length > 0 ? 22 : 4, bottom: 10 })
          }

          if (this.playlists.length === 0) {
            ListItem() {
              this.statusBlock()
            }
          } else {
            LazyForEach(this.playlistSource, (item: LxPlaylistItem) => {
              ListItem() {
                this.playlistRow((item === undefined || item === null) ? EMPTY_PLAYLIST_ITEM : item)
              }
            }, (item: LxPlaylistItem) => {
              const safe: LxPlaylistItem = (item === undefined || item === null) ? EMPTY_PLAYLIST_ITEM : item;
              return `${safe.id}_${safe.name}`;
            })

            if (this.error.length > 0) {
              ListItem() {
                Column({ space: 8 }) {
                  Text(this.error)
                    .fontSize(13)
                    .fontColor(this.pal().textTertiary)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text('点击重试')
                    .fontSize(13.5)
                    .fontColor(this.pal().primary)
                    .onClick(() => {
                      this.error = '';
                      void this.loadMore();
                    })
                }
                .width('100%')
                .padding({ top: 14, bottom: 14 })
              }
            } else {
              ListItem() {
                Text(this.loadingMore ? '正在加载更多…' : (this.noMore ? '没有更多了' : '上拉加载更多'))
                  .fontSize(13)
                  .fontColor(this.pal().textTertiary)
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 16, bottom: 16 })
              }
            }
          }

          ListItem() {
            Column().height(this.bottomInset + 12).width('100%')
          }
        }
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .height('100%')
        .onReachEnd(() => {
          void this.loadMore();
        })
      }
      .layoutWeight(1)
      .width('100%')
      .onRefreshing(() => {
        void this.reload();
      })
    }
    .width('100%')
    .height('100%')
  }
}
