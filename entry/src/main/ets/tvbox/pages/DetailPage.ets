/**
 * 详情页
 * 展示视频详情、播放线路、剧集列表
 */
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { SourceViewModel } from '../viewmodel/SourceViewModel';
import { VodInfo, VodSeries, VodSeriesFlag, VodItem, AbsXml } from '../model/Movie';
import { getApiConfig } from '../api/ApiConfig';
import { SourceBean, isSearchable } from '../model/SourceBean';
import { VodCard } from '../components/VodCard';
import { NetworkImage } from '../components/NetworkImage';
import { LoadingIndicator } from '../components/LoadingIndicator';
import { EmptyState } from '../components/EmptyState';
import { CollectRepository, HistoryRepository, HistoryRecord } from '../data/Database';
import { formatError } from '../utils/HttpUtil';
import { Breakpoint, BP_SM, BP_MD, BP_LG, getBreakpoint, isWide, getBottomSafeAreaVp, getTopSafeAreaVp, getTopSafeAreaSync, getLeftSafeAreaVp, getRightSafeAreaVp } from '../utils/ScreenAdapter';
import { DS } from '../utils/DesignSystem';
import { Palette } from '../utils/ThemeManager';

interface DetailParams {
  vodId: string;
  sourceKey: string;
  name: string;
}

@Entry
@Component
struct DetailPage {
  @State vodId: string = '';
  @State sourceKey: string = '';
  @State name: string = '';
  @State vodInfo: VodInfo | null = null;
  @State loading: boolean = false;
  @State hasError: boolean = false;
  @State errorMsg: string = '';
  @State currentFlagIndex: number = 0;
  @State isCollected: boolean = false;
  @State watchedEps: Set<string> = new Set<string>();
  @State watchedCurrentEpIndex: number = -1;
  @State epProgress: Map<string, string> = new Map<string, string>();
  @State reverseSort: boolean = false;
  // 聚合搜索（豆瓣等推荐源无播放源时，按片名跨源搜索可播放结果）
  @State aggregateMode: boolean = false;
  @State searching: boolean = false;
  @State searchResults: VodItem[] = [];
  @State searchDoneCount: number = 0;
  @State searchTotalCount: number = 0;
  @State breakpoint: Breakpoint = BP_SM;
  @StorageProp('isDarkMode') isDark: boolean = true;
  @State bottomInset: number = 0;
  @State topInset: number = 0;
  @State leftInset: number = 0;
  @State rightInset: number = 0;
  private displayListener: ((id: number) => void) | null = null;
  private foldListener: ((s: display.FoldStatus) => void) | null = null;

  aboutToAppear() {
    const params = router.getParams() as DetailParams;
    if (params) {
      this.vodId = params.vodId;
      this.sourceKey = params.sourceKey;
      this.name = params.name;
    }
    this.breakpoint = getBreakpoint();
    this.initAdaptation();
    this.loadDetail();
    this.checkCollect();
    this.loadWatched();
  }

  async onPageShow(): Promise<void> {
    // 从播放器返回时强制锁定竖屏，避免先横屏再竖屏的闪烁
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      await win.setPreferredOrientation(window.Orientation.PORTRAIT);
    } catch (_e) {}
    // 每次回到详情页，刷新已看集数着色
    await this.loadWatched();
  }

  async loadWatched(): Promise<void> {
    try {
      const rec: HistoryRecord | null = await HistoryRepository.get(this.vodId, this.sourceKey);
      const set: Set<string> = new Set<string>();
      if (rec) {
        this.watchedCurrentEpIndex = rec.epIndex;
        const raw: string = rec.watchedEps ?? '';
        if (raw.length > 0) {
          try {
            const arr: Object = JSON.parse(raw) as Object;
            if (Array.isArray(arr)) {
              const list: string[] = arr as string[];
              for (const it of list) { if (typeof it === 'string' && it.length > 0) set.add(it); }
            }
          } catch (_e) {}
        }
      } else {
        this.watchedCurrentEpIndex = -1;
      }
      this.watchedEps = set;
      // 解析每集播放进度
      const pmap: Map<string, string> = new Map<string, string>();
      if (rec) {
        const rawP: string = rec.epProgress ?? '';
        if (rawP.length > 0) {
          try {
            const obj: Object = JSON.parse(rawP) as Object;
            if (obj && typeof obj === 'object') {
              const dict: Record<string, string> = obj as Record<string, string>;
              for (const k of Object.keys(dict)) {
                const v: string = dict[k];
                if (typeof v === 'string' && v.length > 0) pmap.set(k, v);
              }
            }
          } catch (_e) {}
        }
      }
      this.epProgress = pmap;
    } catch (_e) {}
  }

  private getEpProgressFraction(realIndex: number): number {
    const info: VodInfo | null = this.vodInfo;
    if (!info || info.seriesFlags.length === 0) return 0;
    const flag: VodSeriesFlag | undefined = info.seriesFlags[this.currentFlagIndex];
    if (!flag) return 0;
    const raw: string | undefined = this.epProgress.get(flag.name + '|' + String(realIndex));
    if (!raw) return 0;
    const parts: string[] = raw.split('|');
    if (parts.length < 2) return 0;
    const p: number = Number.parseInt(parts[0], 10);
    const d: number = Number.parseInt(parts[1], 10);
    if (!isFinite(p) || !isFinite(d) || d <= 0) return 0;
    let frac: number = p / d;
    if (frac < 0.02) frac = 0.02;
    if (frac > 1) frac = 1;
    return frac;
  }

  private isWatchedEp(index: number): boolean {
    const info: VodInfo | null = this.vodInfo;
    if (!info || info.seriesFlags.length === 0) return false;
    const flag: VodSeriesFlag | undefined = info.seriesFlags[this.currentFlagIndex];
    if (!flag) return false;
    return this.watchedEps.has(flag.name + '|' + String(index));
  }

  aboutToDisappear() {
    if (this.displayListener) {
      try {
        display.off('change', this.displayListener);
      } catch (e) {
      }
      this.displayListener = null;
    }
    if (this.foldListener) {
      try {
        display.off('foldStatusChange', this.foldListener);
      } catch (e) {
      }
      this.foldListener = null;
    }
  }

  private async initAdaptation() {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.bottomInset = await getBottomSafeAreaVp(ctx) + DS.cornerInset(this.breakpoint);
    this.topInset = await getTopSafeAreaVp(ctx);
    this.leftInset = await getLeftSafeAreaVp(ctx) + DS.cornerInset(this.breakpoint);
    this.rightInset = await getRightSafeAreaVp(ctx) + DS.cornerInset(this.breakpoint);
    this.displayListener = (_id: number): void => {
      this.breakpoint = getBreakpoint();
      getBottomSafeAreaVp(ctx).then((v: number): void => { this.bottomInset = v + DS.cornerInset(this.breakpoint); });
      getTopSafeAreaVp(ctx).then((v: number): void => { this.topInset = v; });
      getLeftSafeAreaVp(ctx).then((v: number): void => { this.leftInset = v + DS.cornerInset(this.breakpoint); });
      getRightSafeAreaVp(ctx).then((v: number): void => { this.rightInset = v + DS.cornerInset(this.breakpoint); });
    };
    this.foldListener = (_s: display.FoldStatus): void => {
      if (this.displayListener) {
        this.displayListener(0);
      }
    };
    try {
      display.on('change', this.displayListener);
      display.on('foldStatusChange', this.foldListener);
    } catch (e) {
    }
    // 监听安全区变化：状态栏/导航条高度就绪或横竖屏切换时动态更新，避免顶栏压住状态栏
    try {
      const win: window.Window = await window.getLastWindow(ctx);
      win.on('avoidAreaChange', (data): void => {
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM || data.type === window.AvoidAreaType.TYPE_CUTOUT) {
          const th: number = getTopSafeAreaSync(win);
          if (th > 0) { this.topInset = th; }
        } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          const bh: number = data.area.bottomRect.height;
          if (bh > 0) { this.bottomInset = px2vp(bh) + DS.cornerInset(this.breakpoint); }
        }
      });
    } catch (e) {
    }
  }

  async loadDetail() {
    this.loading = true;
    this.hasError = false;
    try {
      const info = await SourceViewModel.getDetailContent(this.sourceKey, [this.vodId]);
      if (info && info.seriesFlags.length > 0) {
        this.vodInfo = info;
        this.currentFlagIndex = 0;
      } else {
        if (info) {
          this.vodInfo = info;
        }
        this.loading = false;
        await this.startAggregateSearch();
      }
    } catch (e) {
      this.hasError = true;
      this.errorMsg = formatError(e);
    } finally {
      this.loading = false;
    }
  }

  private getSearchKeyword(): string {
    // 优先使用点击时传入的真实剧名(this.name)。豆瓣等推荐源的 detail() 常返回
    // 占位对象(name="片名")，不能用它作为搜索词。
    let kw: string = (this.name || '').trim();
    const placeholder: boolean = kw.length === 0 || kw === '片名';
    if (placeholder && this.vodInfo && this.vodInfo.name.length > 0 && this.vodInfo.name !== '片名') {
      kw = this.vodInfo.name.trim();
    }
    return kw;
  }

  async startAggregateSearch() {
    const keyword = this.getSearchKeyword();
    if (keyword.length === 0) {
      this.hasError = true;
      this.errorMsg = '未找到详情';
      return;
    }
    this.aggregateMode = true;
    this.searching = true;
    this.hasError = false;
    this.searchResults = [];
    this.searchDoneCount = 0;

    const config = getApiConfig();
    const sources: SourceBean[] = config.getSearchableSources();
    const targets: SourceBean[] = [];
    for (const s of sources) {
      if (s.key !== this.sourceKey) {
        targets.push(s);
      }
    }
    this.searchTotalCount = targets.length;

    const tasks: Promise<void>[] = [];
    for (const bean of targets) {
      tasks.push(this.searchOneSource(bean.key, keyword));
    }
    await Promise.all(tasks);
    this.searching = false;
    if (this.searchResults.length === 0) {
      this.hasError = true;
      this.errorMsg = '未搜索到「' + keyword + '」的可播放资源';
    }
  }

  private async searchOneSource(key: string, keyword: string): Promise<void> {
    try {
      const res: AbsXml = await SourceViewModel.searchContent(key, keyword, true);
      const list = res.videoList;
      if (list && list.length > 0) {
        const merged: VodItem[] = this.searchResults.slice();
        for (const v of list) {
          v.sourceKey = key;
          merged.push(v);
        }
        this.searchResults = merged;
      }
    } catch (_e) {
      // ignore single source failure
    } finally {
      this.searchDoneCount = this.searchDoneCount + 1;
    }
  }

  goSearchResult(item: VodItem) {
    router.pushUrl({
      url: 'tvbox/pages/DetailPage',
      params: {
        vodId: item.id,
        sourceKey: item.sourceKey,
        name: item.name
      }
    });
  }

  async checkCollect() {
    this.isCollected = await CollectRepository.has(this.vodId, this.sourceKey);
  }

  async toggleCollect() {
    if (this.isCollected) {
      await CollectRepository.remove(this.vodId, this.sourceKey);
      this.isCollected = false;
      promptAction.showToast({ message: '已取消收藏' });
    } else {
      const info = this.vodInfo;
      if (info) {
        await CollectRepository.add({
          vodId: this.vodId,
          sourceKey: this.sourceKey,
          name: info.name,
          pic: info.pic,
          updateTime: Date.now()
        });
        this.isCollected = true;
        promptAction.showToast({ message: '已收藏' });
      }
    }
  }

  onFlagClick(index: number) {
    this.currentFlagIndex = index;
  }

  toggleReverse() {
    this.reverseSort = !this.reverseSort;
  }

  goPlayer(epIndex: number) {
    const info = this.vodInfo;
    if (!info) return;
    const flag = info.seriesFlags[this.currentFlagIndex];
    if (!flag) return;
    const series = info.seriesMap.get(flag.name);
    if (!series || epIndex >= series.length) return;

    SourceViewModel.prefetchPlayContent(this.sourceKey, flag.name, series[epIndex].url);
    router.pushUrl({
      url: 'tvbox/pages/PlayerPage',
      params: {
        vodId: this.vodId,
        sourceKey: this.sourceKey,
        name: info.name,
        flag: flag.name,
        epIndex: epIndex,
        epName: series[epIndex].name,
        epUrl: series[epIndex].url
      }
    });
  }

  goBack() {
    router.back();
  }

  getCurrentSeries(): VodSeries[] {
    const info = this.vodInfo;
    if (!info || info.seriesFlags.length === 0) return [];
    const flag = info.seriesFlags[this.currentFlagIndex];
    if (!flag) return [];
    let series = info.seriesMap.get(flag.name) || [];
    if (this.reverseSort) {
      series = series.slice().reverse();
    }
    return series;
  }

  getSourceDisplayName(): string {
    const bean: SourceBean | null = getApiConfig().getSource(this.sourceKey);
    if (bean && bean.name.length > 0) return bean.name;
    return this.sourceKey || '-';
  }

  getPlayUrlPreview(): string {
    const list: VodSeries[] = this.getCurrentSeries();
    if (list.length === 0) return '';
    const url: string = list[0].url || '';
    return url;
  }

  private getGridColumns(): number {
    if (this.breakpoint === BP_LG) return 6;
    if (this.breakpoint === BP_SM) return 4;
    return 5;
  }

  private getGridHeight(): number {
    const count = this.getCurrentSeries().length;
    if (count === 0) return 0;
    const cols = this.getGridColumns();
    const rows = Math.ceil(count / cols);
    const cellH = 50;
    const gap = 10;
    // top padding 10 + rows*cellH + (rows-1)*gap + bottom padding
    return 10 + rows * cellH + (rows - 1) * gap + 10 + this.bottomInset;
  }

  @Builder
  AggregateSearchView() {
    Column() {
      // 顶部状态：搜索进度
      Row() {
        if (this.searching) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color(Palette.textPrimary(this.isDark))
        }
        Text(this.searching
          ? ('聚合搜索中 ' + this.searchDoneCount + '/' + this.searchTotalCount + ' · 已找到 ' + this.searchResults.length)
          : ('共找到 ' + this.searchResults.length + ' 个可播放资源'))
          .fontSize(DS.smallFont(this.breakpoint) + 2)
          .fontColor(Palette.textSecondary(this.isDark))
          .margin({ left: 8 })
      }
      .width('100%')
      .padding({ left: DS.hPadding(this.breakpoint), right: DS.hPadding(this.breakpoint), top: 8, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      if (this.searchResults.length > 0) {
        Grid() {
          ForEach(this.searchResults, (item: VodItem, index: number) => {
            GridItem() {
              Column() {
                VodCard({
                  item: item,
                  bp: this.breakpoint,
                  onItemClick: (vod: VodItem): void => { this.goSearchResult(vod) }
                })
                Text('[' + (getApiConfig().getSource(item.sourceKey)?.name ?? item.sourceKey) + ']')
                  .fontSize(DS.cardBadgeFont(this.breakpoint))
                  .fontColor(Palette.textSecondary(this.isDark))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 2 })
              }
            }
          }, (item: VodItem, index: number): string => index + '_' + item.sourceKey + '_' + item.id)
        }
        .columnsTemplate(DS.gridTemplate(this.breakpoint))
        .rowsGap(12)
        .columnsGap(DS.gridGap(this.breakpoint))
        .padding({ left: DS.hPadding(this.breakpoint), right: DS.hPadding(this.breakpoint), top: 8, bottom: 40 })
        .width('100%')
        .layoutWeight(1)
      } else if (!this.searching) {
        EmptyState({ text: this.errorMsg.length > 0 ? this.errorMsg : '未搜索到可播放资源', onRetry: (): void => { this.startAggregateSearch() } })
      } else {
        Column()
          .layoutWeight(1)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  PosterView() {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.vodInfo && this.vodInfo.pic.length > 0) {
        Column() {
          NetworkImage({ imageUrl: this.vodInfo.pic, radius: 8, imageFit: ImageFit.Cover })
        }
        .width('100%')
        .height('100%')
        .borderRadius(8)
      } else {
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(8)
      }

      // 仅保留"更新至XX集"角标
      if (this.vodInfo && this.vodInfo.note.length > 0) {
        Text(this.vodInfo.note)
          .fontSize(12)
          .fontColor('#FFFFFF')
          .backgroundColor('#CC000000')
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .borderRadius(6)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 6, bottom: 6 })
      }
    }
    .width(this.breakpoint === BP_SM ? 200 : 230)
    .height(this.breakpoint === BP_SM ? 280 : 300)
    .backgroundColor(this.isDark ? '#1C1C1E' : '#E9EAEE')
    .borderRadius(8)
  }

  @Builder
  InfoView() {
    // 标题
    Text(this.vodInfo ? this.vodInfo.name : '')
      .fontSize(this.breakpoint === BP_SM ? 22 : 28)
      .fontColor(Palette.textPrimary(this.isDark))
      .fontWeight(FontWeight.Bold)
      .maxLines(this.breakpoint === BP_SM ? 2 : 1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
      .margin({ bottom: 5 })

    // 来源 + 年份（同一行）
    Row() {
      Text('来源：')
        .fontSize(this.breakpoint === BP_SM ? 13 : 15)
        .fontColor(Palette.textSecondary(this.isDark))
      Text(this.getSourceDisplayName())
        .fontSize(this.breakpoint === BP_SM ? 13 : 15)
        .fontColor(Palette.textPrimary(this.isDark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 220 })
        .margin({ right: 16 })

      if (this.vodInfo && this.vodInfo.year > 0) {
        Text('年份：')
          .fontSize(this.breakpoint === BP_SM ? 13 : 15)
          .fontColor(Palette.textSecondary(this.isDark))
        Text(this.vodInfo.year.toString())
          .fontSize(this.breakpoint === BP_SM ? 13 : 15)
          .fontColor(Palette.textPrimary(this.isDark))
          .maxLines(1)
      }
    }
    .width('100%')
    .margin({ top: 4 })
    .alignItems(VerticalAlign.Center)

    // 演员行
    if (this.vodInfo && this.vodInfo.actor.length > 0) {
      Row() {
        Text('演员：')
          .fontSize(this.breakpoint === BP_SM ? 13 : 15)
          .fontColor(Palette.textSecondary(this.isDark))
        Text(this.vodInfo.actor)
          .fontSize(this.breakpoint === BP_SM ? 13 : 15)
          .fontColor(Palette.textPrimary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 6 })
    }

    // 导演行
    if (this.vodInfo && this.vodInfo.director.length > 0) {
      Row() {
        Text('导演：')
          .fontSize(this.breakpoint === BP_SM ? 13 : 15)
          .fontColor(Palette.textSecondary(this.isDark))
        Text(this.vodInfo.director)
          .fontSize(this.breakpoint === BP_SM ? 13 : 15)
          .fontColor(Palette.textPrimary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 6 })
    }

    // 播放地址行
    if (this.getPlayUrlPreview().length > 0) {
      Row() {
        Text('播放地址：')
          .fontSize(this.breakpoint === BP_SM ? 13 : 15)
          .fontColor(Palette.textSecondary(this.isDark))
        Text(this.getPlayUrlPreview())
          .fontSize(this.breakpoint === BP_SM ? 13 : 15)
          .fontColor(Palette.textPrimary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 6 })
    }

    // 内容简介
    if (this.vodInfo && this.vodInfo.des.length > 0) {
      Row() {
        Text('内容简介：')
          .fontSize(this.breakpoint === BP_SM ? 13 : 15)
          .fontColor(Palette.textSecondary(this.isDark))
          .alignSelf(ItemAlign.Start)
        Text(this.vodInfo.des)
          .fontSize(this.breakpoint === BP_SM ? 13 : 15)
          .fontColor(Palette.textPrimary(this.isDark))
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(this.breakpoint === BP_SM ? 20 : 22)
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 6 })
      .alignItems(VerticalAlign.Top)
    }

    // 宽屏时用 Blank 顶开按钮到底部；竖屏时用固定间距
    if (isWide(this.breakpoint)) {
      Blank()
    }

    // 底部按钮行
    Row({ space: 10 }) {
      Text('立即播放')
        .fontSize(this.breakpoint === BP_SM ? 16 : 20)
        .fontColor('#FFFFFF')
        .backgroundColor(Palette.accent())
        .borderRadius(8)
        .layoutWeight(this.breakpoint === BP_LG ? 0 : 1)
        .width(this.breakpoint === BP_LG ? 260 : undefined)
        .height(40)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          const seriesList = this.getCurrentSeries();
          if (seriesList.length > 0) {
            this.goPlayer(0);
          }
        })

      Row({ space: 6 }) {
        SymbolGlyph(this.isCollected ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
          .fontSize(this.breakpoint === BP_SM ? 16 : 20)
          .fontColor([this.isCollected ? Palette.accent() : Palette.textPrimary(this.isDark)])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        Text(this.isCollected ? '已收藏' : '加入收藏')
          .fontSize(this.breakpoint === BP_SM ? 16 : 20)
          .fontColor(this.isCollected ? Palette.accent() : Palette.textPrimary(this.isDark))
      }
      .layoutWeight(this.breakpoint === BP_LG ? 0 : 1)
      .width(this.breakpoint === BP_LG ? 260 : undefined)
      .height(40)
      .borderRadius(8)
      .backgroundColor(this.isDark ? '#2C2C2E' : '#E9EAEE')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .onClick(() => this.toggleCollect())
    }
    .width('100%')
    .margin({ top: this.breakpoint === BP_SM ? 14 : 10 })
  }

  build() {
    Column() {
      // 顶部栏：返回箭头 + 标题，透明背景
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([Palette.textPrimary(this.isDark)])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .margin({ left: 16 })
          .onClick(() => this.goBack())

        Text(this.aggregateMode ? this.getSearchKeyword() : (this.vodInfo ? this.vodInfo.name : this.name))
          .fontSize(DS.bodyFont(this.breakpoint) + 2)
          .fontColor(Palette.textPrimary(this.isDark))
          .fontWeight(FontWeight.Medium)
          .margin({ left: 16 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

      }
      .width('100%')
      .height(48 + this.topInset)
      .padding({ top: this.topInset })
      .alignItems(VerticalAlign.Center)

      if (this.aggregateMode) {
        this.AggregateSearchView()
      } else if (this.loading) {
        LoadingIndicator()
          .layoutWeight(1)
      } else if (this.hasError) {
        EmptyState({ text: this.errorMsg, onRetry: (): void => { this.loadDetail() } })
          .layoutWeight(1)
      } else if (this.vodInfo) {
        Scroll() {
          Column() {
            // 内容区：宽屏(横屏/平板)左右布局，竖屏上下布局
            if (isWide(this.breakpoint)) {
          Row() {
            this.PosterView()
            Column() {
              this.InfoView()
            }
            .layoutWeight(1)
            .height(this.breakpoint === BP_SM ? undefined : 300)
            .margin({ left: 20 })
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ left: DS.hPadding(this.breakpoint), right: DS.hPadding(this.breakpoint), top: 6, bottom: 6 })
        } else {
          Column() {
            this.PosterView()
            Column() {
              this.InfoView()
            }
            .width('100%')
            .margin({ top: 14 })
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ left: DS.hPadding(this.breakpoint), right: DS.hPadding(this.breakpoint), top: 6, bottom: 6 })
        }

        // 播放源标签栏 + 排序：同一行，标签可横向滚动，正序固定右侧
        if (this.vodInfo.seriesFlags.length > 0) {
          Row() {
            Scroll() {
              Row() {
                ForEach(this.vodInfo.seriesFlags, (flag: VodSeriesFlag, index: number) => {
                  Text(flag.name)
                    .fontSize(DS.bodyFont(this.breakpoint))
                    .fontColor(index === this.currentFlagIndex ? Palette.accent() : Palette.textPrimary(this.isDark))
                    .fontWeight(index === this.currentFlagIndex ? FontWeight.Bold : FontWeight.Normal)
                    .backgroundColor(this.isDark ? '#2C2C2E' : '#E9EAEE')
                    .borderRadius(8)
                    .height(36)
                    .padding({ left: 14, right: 14 })
                    .textAlign(TextAlign.Center)
                    .maxLines(1)
                    .margin({ right: 8 })
                    .onClick(() => this.onFlagClick(index))
                }, (flag: VodSeriesFlag, index: number): string => flag.name + index)
              }
              .justifyContent(FlexAlign.Start)
              .constraintSize({ minWidth: '100%' })
            }
            .align(Alignment.Start)
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .layoutWeight(1)

            Text(this.reverseSort ? '倒序' : '正序')
              .fontSize(DS.bodyFont(this.breakpoint))
              .fontColor(Palette.textPrimary(this.isDark))
              .backgroundColor(this.isDark ? '#2C2C2E' : '#E9EAEE')
              .borderRadius(8)
              .height(36)
              .textAlign(TextAlign.Center)
              .padding({ left: 14, right: 14 })
              .margin({ left: 8 })
              .onClick(() => this.toggleReverse())
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ left: DS.hPadding(this.breakpoint), right: DS.hPadding(this.breakpoint), top: 6, bottom: 4 })

          // 剧集网格：5列
          Grid() {
            ForEach(this.getCurrentSeries(), (series: VodSeries, index: number) => {
              GridItem() {
                Stack({ alignContent: Alignment.Center }) {
                  // 底层：圆角边框背景
                  Row() {}
                    .width('100%')
                    .height('100%')
                    .backgroundColor(this.isDark ? '#2C2C2E' : '#E9EAEE')
                    .borderRadius(10)
                  // 进度填充：根据播放比例从左向右填充
                  if (this.getEpProgressFraction(this.reverseSort ? this.getCurrentSeries().length - 1 - index : index) > 0) {
                    Row() {
                      Row()
                        .width((this.getEpProgressFraction(this.reverseSort ? this.getCurrentSeries().length - 1 - index : index) * 100) + '%')
                        .height('100%')
                        .backgroundColor(this.isDark ? '#553B82FF' : '#553B82FF')
                        .borderRadius(10)
                    }
                    .width('100%')
                    .height('100%')
                    .justifyContent(FlexAlign.Start)
                  }
                  // 顶层：集数文字
                  Text(series.name)
                    .fontSize(DS.smallFont(this.breakpoint))
                    .fontColor(this.isWatchedEp(this.reverseSort ? this.getCurrentSeries().length - 1 - index : index) ? Palette.accent() : Palette.textPrimary(this.isDark))
                    .textAlign(TextAlign.Center)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .padding({ left: 4, right: 4 })
                }
                .width('100%')
                .height(50)
                .borderRadius(10)
                .clip(true)
              }
              .onClick(() => {
                const realIndex = this.reverseSort ? this.getCurrentSeries().length - 1 - index : index;
                this.goPlayer(realIndex);
              })
            }, (series: VodSeries, index: number): string => series.name + index)
          }
          .columnsTemplate(this.breakpoint === BP_LG ? '1fr 1fr 1fr 1fr 1fr 1fr' : (this.breakpoint === BP_SM ? '1fr 1fr 1fr 1fr' : '1fr 1fr 1fr 1fr 1fr'))
          .rowsGap(10)
          .columnsGap(10)
          .padding({ left: DS.hPadding(this.breakpoint), right: DS.hPadding(this.breakpoint), top: 8, bottom: 10 + this.bottomInset })
          .height(this.getGridHeight())
          .edgeEffect(EdgeEffect.Spring)
          .width('100%')
          }
          }
          .width('100%')
        }
        .scrollable(ScrollDirection.Vertical)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: this.leftInset, right: this.rightInset })
    .backgroundColor(Palette.bg(this.isDark))
  }
}