/**
 * 搜索页
 * 左侧: 按源分组的命中数栏，点击切换筛选
 * 右侧: 结果网格
 */
import { router } from '@kit.ArkUI';
import { getApiConfig } from '../api/ApiConfig';
import { SourceViewModel } from '../viewmodel/SourceViewModel';
import { AbsXml, VodItem, emptyAbsXml } from '../model/Movie';
import { VodCard } from '../components/VodCard';
import { LoadingIndicator } from '../components/LoadingIndicator';
import { EmptyState } from '../components/EmptyState';
import { SourceBean } from '../model/SourceBean';
import { formatError } from '../utils/HttpUtil';
import { getTopSafeAreaVp, getTopSafeAreaSync, getBottomSafeAreaVp, getLeftSafeAreaVp, getRightSafeAreaVp, getBreakpoint, Breakpoint, BP_SM, isWide } from '../utils/ScreenAdapter';
import { DS } from '../utils/DesignSystem';
import { Palette } from '../utils/ThemeManager';
import { display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { HotSearchHelper } from '../utils/HotSearchHelper';

const ALL_SOURCE_KEY: string = '__ALL__';

@Entry
@Component
struct SearchPage {
  @State keyword: string = '';
  @State searchResults: VodItem[] = [];
  @State loading: boolean = false;
  @State hasSearched: boolean = false;
  @State errorMsg: string = '';
  @State sourceKeys: string[] = [];
  @State sourceNames: Map<string, string> = new Map();
  @State hitCounts: Map<string, number> = new Map();
  @State selectedSourceKey: string = ALL_SOURCE_KEY;
  @State searchHistory: string[] = [];
  @State hotWords: string[] = [];
  @State topSafe: number = 0;
  @State leftSafe: number = 0;
  @State rightSafe: number = 0;
  @State bottomSafe: number = 0;
  @State bp: Breakpoint = BP_SM;
  @StorageProp('isDarkMode') isDark: boolean = true;
    private foldListener: (s: display.FoldStatus) => void = (_s: display.FoldStatus): void => { this.displayListener(0); };
  private displayListener: (id: number) => void = (_id: number): void => {
    this.bp = getBreakpoint();
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    getLeftSafeAreaVp(ctx).then((v: number): void => { this.leftSafe = v + DS.cornerInset(this.bp); });
    getRightSafeAreaVp(ctx).then((v: number): void => { this.rightSafe = v + DS.cornerInset(this.bp); });
  };
  private searchGen: number = 0;

  aboutToAppear() {
    const config = getApiConfig();
    const sources = config.getSearchableSources();
    this.sourceKeys = sources.map((s: SourceBean) => s.key);
    const nameMap: Map<string, string> = new Map();
    for (const s of sources) { nameMap.set(s.key, s.name.length > 0 ? s.name : s.key); }
    this.sourceNames = nameMap;
    this.initSafeArea();
    this.loadSearchHistory();
    this.loadHotWords();
  }

  private async loadHotWords(): Promise<void> {
    const cached: string[] = await HotSearchHelper.getCached();
    if (cached.length > 0) { this.hotWords = cached; }
    const fresh: string[] = await HotSearchHelper.getHotWords();
    if (fresh.length > 0) { this.hotWords = fresh; }
  }

  private async loadSearchHistory(): Promise<void> {
    const raw: string = await PreferencesUtil.get('search_history', '');
    if (raw.length === 0) { this.searchHistory = []; return; }
    try {
      const arr: string[] = JSON.parse(raw) as string[];
      this.searchHistory = Array.isArray(arr) ? arr.slice(0, 10) : [];
    } catch (_e) {
      this.searchHistory = [];
    }
  }

  private async saveSearchHistory(kw: string): Promise<void> {
    const trimmed: string = kw.trim();
    if (trimmed.length === 0) return;
    let list: string[] = this.searchHistory.slice();
    const idx: number = list.indexOf(trimmed);
    if (idx >= 0) list.splice(idx, 1);
    list.unshift(trimmed);
    if (list.length > 10) list = list.slice(0, 10);
    this.searchHistory = list;
    await PreferencesUtil.put('search_history', JSON.stringify(list));
  }

  private async clearSearchHistory(): Promise<void> {
    this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.searchHistory = []; });
    await PreferencesUtil.put('search_history', '');
  }

  aboutToDisappear(): void {
    try { display.off('change', this.displayListener); display.off('foldStatusChange', this.foldListener); } catch (e) {}
  }

  private async initSafeArea() {
    this.bp = getBreakpoint();
    try { display.on('change', this.displayListener); display.on('foldStatusChange', this.foldListener); } catch (e) {}
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.topSafe = await getTopSafeAreaVp(ctx);
    this.leftSafe = await getLeftSafeAreaVp(ctx) + DS.cornerInset(this.bp);
    this.rightSafe = await getRightSafeAreaVp(ctx) + DS.cornerInset(this.bp);
    this.bottomSafe = await getBottomSafeAreaVp(ctx) + DS.cornerInset(this.bp);
    try {
      const win: window.Window = await window.getLastWindow(ctx);
      win.on('avoidAreaChange', (data): void => {
        if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          const h: number = data.area.bottomRect.height;
          if (h > 0) { this.bottomSafe = px2vp(h) + DS.cornerInset(this.bp); }
        } else if (data.type === window.AvoidAreaType.TYPE_SYSTEM || data.type === window.AvoidAreaType.TYPE_CUTOUT) {
          const th: number = getTopSafeAreaSync(win);
          if (th > 0) { this.topSafe = th; }
          if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
            const bh: number = data.area.bottomRect.height;
            if (bh > 0) { this.bottomSafe = Math.max(this.bottomSafe, px2vp(bh) + DS.cornerInset(this.bp)); }
          }
        }
      });
    } catch (e) {}
  }

  async doSearch() {
    const kw = this.keyword.trim();
    if (kw.length === 0) return;
    try { this.getUIContext().getFocusController().clearFocus(); } catch (e) {}
    this.saveSearchHistory(kw);
    if (this.sourceKeys.length === 0) {
      this.errorMsg = '暂无可用的搜索源';
      this.hasSearched = true;
      this.searchResults = [];
      this.hitCounts = new Map();
      return;
    }
    this.getUIContext()?.animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.loading = true;
      this.hasSearched = true;
      this.searchResults = [];
      this.hitCounts = new Map();
      this.selectedSourceKey = ALL_SOURCE_KEY;
    });
    this.errorMsg = '';
    const gen: number = ++this.searchGen;
    const kwLower: string = kw.toLowerCase();
    const kwNoSpace: string = kwLower.replace(/\s+/g, '');
    let pendingResults: VodItem[] = [];
    let pendingCounts: Map<string, number> = new Map();
    let flushTimer: number = -1;
    let isFirstBatch: boolean = true;
    const flush = (): void => {
      if (gen !== this.searchGen) { flushTimer = -1; return; }
      if (pendingResults.length > 0) {
        const merged: VodItem[] = this.searchResults.slice();
        for (const v of pendingResults) { merged.push(v); }
        this.searchResults = merged;
        const counts: Map<string, number> = new Map(this.hitCounts);
        pendingCounts.forEach((v: number, k: string): void => { counts.set(k, v); });
        this.hitCounts = counts;
        pendingResults = [];
        pendingCounts = new Map();
      }
      flushTimer = -1;
    };
    SourceViewModel.multiSearchStream(this.sourceKeys, kw, 10000,
      (key: string, xml: AbsXml, err: string): void => {
        if (gen !== this.searchGen) return;
        const rawList: VodItem[] = xml.videoList;
        const list: VodItem[] = [];
        const exactList: VodItem[] = [];
        for (const v of rawList) {
          const nm: string = (v.name || '').toString();
          if (nm.length === 0) { continue; }
          const nmLower: string = nm.toLowerCase();
          const nmNoSpace: string = nmLower.replace(/\s+/g, '');
          // 苹果CMS 搜索为分词模糊匹配，服务端结果名称不一定包含完整关键词，
          // 不做客户端严格过滤（否则结果几乎全被丢弃导致"搜索不起作用"）；
          // 名称包含关键词的排前，其余结果原样保留。
          if (nmNoSpace.indexOf(kwNoSpace) >= 0 || nmLower.indexOf(kwLower) >= 0) {
            exactList.push(v);
          } else {
            list.push(v);
          }
        }
        const merged: VodItem[] = exactList.concat(list);
        if (merged.length > 0) {
          for (const v of merged) { pendingResults.push(v); }
          pendingCounts.set(key, merged.length);
          if (isFirstBatch) {
            isFirstBatch = false;
            flush();
          } else if (flushTimer === -1) {
            flushTimer = setTimeout(flush, 300);
          }
        }
      },
      (): void => {
        if (gen !== this.searchGen) return;
        if (flushTimer !== -1) { clearTimeout(flushTimer); }
        flush();
        this.loading = false;
        if (this.searchResults.length === 0 && this.errorMsg.length === 0) {
          this.errorMsg = '未找到相关内容';
        }
      });
  }

  filteredResults(): VodItem[] {
    if (this.selectedSourceKey === ALL_SOURCE_KEY) return this.searchResults;
    const key: string = this.selectedSourceKey;
    return this.searchResults.filter((v: VodItem): boolean => v.sourceKey === key);
  }

  totalHits(): number { return this.searchResults.length; }

  goDetail(item: VodItem) {
    router.pushUrl({ url: 'tvbox/pages/DetailPage', params: { vodId: item.id, sourceKey: item.sourceKey, name: item.name } });
  }

  goBack() { router.back(); }

  @Builder
  SourceCell(label: string, key: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontWeight(this.selectedSourceKey === key ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.selectedSourceKey === key ? Palette.textPrimary(this.isDark) : Palette.textSecondary(this.isDark))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      // 结果数量徽标：直接从 state 读取以保持响应式；0 不显示；>=10 显示 N
      if (this.cellCount(key) > 0) {
        Text(this.cellCount(key) >= 10 ? 'N' : this.cellCount(key).toString())
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .backgroundColor(Palette.accent())
          .width(18)
          .height(18)
          .borderRadius(9)
          .textAlign(TextAlign.Center)
          .margin({ left: 6 })
          .animation({ duration: 180, curve: Curve.EaseOut })
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor(this.selectedSourceKey === key ? (this.isDark ? '#26FFFFFF' : '#12000000') : Color.Transparent)
    .borderRadius(10)
    .margin({ bottom: 4 })
    .animation({ duration: 180, curve: Curve.EaseOut })
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => {
      this.getUIContext()?.animateTo({ duration: 180, curve: Curve.EaseOut }, () => { this.selectedSourceKey = key; });
    })
  }

  /** 响应式获取某个源当前的搜索结果数量（key=ALL_SOURCE_KEY 时返回全部）*/
  private cellCount(key: string): number {
    if (key === ALL_SOURCE_KEY) return this.searchResults.length;
    return this.hitCounts.get(key) ?? 0;
  }

  build() {
    Column() {
      Column().width('100%').height(this.topSafe)

      Row() {
        if (this.hasSearched && this.sourceKeys.length > 0) {
          Column() {
            Text('搜索来源')
              .fontSize(12)
              .fontColor(Palette.textSecondary(this.isDark))
              .padding({ left: 10, top: 6, bottom: 6 })
            List() {
              ListItem() { this.SourceCell('全部来源', ALL_SOURCE_KEY) }
              ForEach(this.sourceKeys, (key: string) => {
                ListItem() {
                  this.SourceCell(this.sourceNames.get(key) ?? key, key)
                }
              }, (key: string): string => 'src_' + key)
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
          }
          .width(140)
          .height('100%')
          .padding({ top: 8, bottom: 8, left: 6, right: 4 })
          .backgroundColor(Palette.glass(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .border({ width: { right: 0.5 }, color: Palette.glassBorder(this.isDark) })
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: -20 })).animation({ duration: 220, curve: Curve.EaseOut }))
        }

        Column() {
          if (this.loading && this.searchResults.length === 0) {
            LoadingIndicator()
          } else if (this.hasSearched && this.filteredResults().length === 0) {
            EmptyState({ text: this.errorMsg.length > 0 ? this.errorMsg : '未找到相关内容', onRetry: (): void => { this.doSearch() } })
          } else if (this.filteredResults().length > 0) {
            Column() {
              Row() {
                Text(this.selectedSourceKey === ALL_SOURCE_KEY
                  ? '搜索结果: ' + this.filteredResults().length + ' 条'
                  : (this.sourceNames.get(this.selectedSourceKey) ?? this.selectedSourceKey) + ': ' + this.filteredResults().length + ' 条')
                  .fontSize(12)
                  .fontColor(Palette.textSecondary(this.isDark))
                  .layoutWeight(1)
                if (this.loading) {
                  Text('搜索中...')
                    .fontSize(11)
                    .fontColor(Palette.textSecondary(this.isDark))
                }
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 8, bottom: 4 })

              Grid() {
                ForEach(this.filteredResults(), (item: VodItem, index: number) => {
                  GridItem() {
                    VodCard({ item: item, bp: this.bp, onItemClick: (vod: VodItem): void => { this.goDetail(vod) } })
                  }
                }, (item: VodItem, index: number): string => index + '_' + item.id + '_' + item.sourceKey)
              }
              .columnsTemplate(DS.gridTemplate(this.bp))
              .rowsGap(12)
              .columnsGap(10)
              .padding(12)
              .width('100%')
              .layoutWeight(1)
              .edgeEffect(EdgeEffect.Spring)
            }
            .layoutWeight(1)
          } else {
            Column() {
              Text('输入关键词开始搜索')
                .fontSize(16)
                .fontColor(Palette.textSecondary(this.isDark))
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          }
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(VerticalAlign.Top)

      Column() {
        // 热门搜索（豆瓣热榜，6 小时缓存，横向可拖动）
        if (this.hotWords.length > 0) {
          Row() {
            Text('热搜')
              .fontSize(12)
              .fontColor(Palette.accent())
              .fontWeight(FontWeight.Medium)
              .margin({ right: 8 })
            Scroll() {
              Row({ space: 8 }) {
                ForEach(this.hotWords, (kw: string, idx: number) => {
                  Text(kw)
                    .fontSize(13)
                    .fontColor(Palette.textPrimary(this.isDark))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .constraintSize({ maxWidth: 160 })
                    .height(30)
                    .padding({ left: 12, right: 12 })
                    .backgroundColor(Palette.glass(this.isDark))
                    .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
                    .borderRadius(15)
                    .border({ width: 1, color: Palette.glassBorder(this.isDark) })
                    .textAlign(TextAlign.Center)
                    .animation({ duration: 180, curve: Curve.EaseOut })
                    .clickEffect({ level: ClickEffectLevel.LIGHT })
                    .onClick(() => { this.keyword = kw; this.doSearch(); })
                }, (kw: string, idx: number): string => 'hot_' + idx + '_' + kw)
              }
              .padding({ right: 8 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .layoutWeight(1)
            .height(30)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ bottom: 8 })
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -10 })).animation({ duration: 220, curve: Curve.EaseOut }))
        }

        // 搜索历史（横向可滚动，最多 10 条，右侧固定清除按钮）
        if (this.searchHistory.length > 0) {
          Row() {
            Text('搜索历史')
              .fontSize(12)
              .fontColor(Palette.accent())
              .fontWeight(FontWeight.Medium)
              .margin({ right: 8 })
            Scroll() {
              Row({ space: 8 }) {
                ForEach(this.searchHistory, (kw: string, idx: number) => {
                  Text(kw)
                    .fontSize(13)
                    .fontColor(Palette.textPrimary(this.isDark))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .constraintSize({ maxWidth: 140 })
                    .height(32)
                    .padding({ left: 12, right: 12 })
                    .backgroundColor(Palette.glass(this.isDark))
                    .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
                    .borderRadius(16)
                    .border({ width: 1, color: Palette.glassBorder(this.isDark) })
                    .textAlign(TextAlign.Center)
                    .animation({ duration: 180, curve: Curve.EaseOut })
                    .clickEffect({ level: ClickEffectLevel.LIGHT })
                    .onClick(() => { this.keyword = kw; this.doSearch(); })
                }, (kw: string, idx: number): string => 'sh_' + idx + '_' + kw)
              }
              .padding({ right: 8 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .layoutWeight(1)
            .height(32)

            Row() {
              SymbolGlyph($r('sys.symbol.trash'))
                .fontSize(16)
                .fontColor([Palette.textSecondary(this.isDark)])
                .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            }
            .width(32)
            .height(32)
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(Palette.glass(this.isDark))
            .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
            .borderRadius(16)
            .border({ width: 1, color: Palette.glassBorder(this.isDark) })
            .margin({ left: 8 })
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => this.clearSearchHistory())
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ bottom: 8 })
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -10 })).animation({ duration: 220, curve: Curve.EaseOut }))
        }

        Row() {
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(22)
              .fontColor([Palette.textPrimary(this.isDark)])
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          }
          .width(48)
          .height(48)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .backgroundColor(Palette.glass(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .borderRadius(24)
          .border({ width: 1, color: Palette.glassBorder(this.isDark) })
          .shadow({ radius: 24, color: '#66000000', offsetX: 0, offsetY: 8 })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => this.goBack())

          TextInput({ text: this.keyword, placeholder: '输入关键词搜索' })
            .fontSize(15)
            .fontColor(Palette.textPrimary(this.isDark))
            .placeholderColor(Palette.textSecondary(this.isDark))
            .backgroundColor(Palette.glass(this.isDark))
            .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
            .borderRadius(24)
            .border({ width: 1, color: Palette.glassBorder(this.isDark) })
            .shadow({ radius: 24, color: '#66000000', offsetX: 0, offsetY: 8 })
            .height(48)
            .padding({ left: 18, right: 18 })
            .layoutWeight(1)
            .margin({ left: 10, right: 10 })
            .copyOption(CopyOptions.LocalDevice)
            .onChange((value: string) => { this.keyword = value })
            .onSubmit(() => this.doSearch())

          Row() {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(22)
              .fontColor([Palette.textPrimary(this.isDark)])
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          }
          .width(48)
          .height(48)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .backgroundColor(Palette.glass(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .borderRadius(24)
          .border({ width: 1, color: Palette.glassBorder(this.isDark) })
          .shadow({ radius: 24, color: '#66000000', offsetX: 0, offsetY: 8 })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => this.doSearch())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ left: DS.hPadding(this.bp) + this.leftSafe, right: DS.hPadding(this.bp) + this.rightSafe, top: 8, bottom: Math.max(28, 8 + this.bottomSafe) })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.bg(this.isDark))
  }
}
