/**
 * 首页
 * 顶部栏(应用名+时钟) + 横向分类滚动条 + 用户面板/视频网格
 */
import { router, promptAction } from '@kit.ArkUI';
import { curves } from '@kit.ArkUI';
import { getApiConfig } from '../api/ApiConfig';
import { SourceViewModel } from '../viewmodel/SourceViewModel';
import { AbsXml, VodItem, emptyAbsXml, HomeResult } from '../model/Movie';
import { MovieSort, SortData, SortFilter, applyCustomOrder } from '../model/MovieSort';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { SourceBean } from '../model/SourceBean';
import { VodCard } from '../components/VodCard';
import { preloadImages } from '../components/NetworkImage';
import { LoadingIndicator } from '../components/LoadingIndicator';
import { EmptyState } from '../components/EmptyState';
import { formatError, clearHttpCache } from '../utils/HttpUtil';
import { JsEngineHost } from '../components/JsEngineHost';
import { isJsEngineReady } from '../api/JsEngine';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { getBottomSafeAreaVp, getTopSafeAreaVp, getTopSafeAreaSync, getLeftSafeAreaVp, getRightSafeAreaVp, getBreakpoint, getBreakpointByWidth, Breakpoint, BP_SM, isWide, isLandscape } from '../utils/ScreenAdapter';
import { DS, Motion } from '../utils/DesignSystem';
import { Palette } from '../utils/ThemeManager';
import { display } from '@kit.ArkUI';
const WEEK_DAYS: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

interface RowData {
  rowIndex: number;
  items: VodItem[];
}

@Entry
@Component
struct HomePage {
  @State sortList: SortData[] = [];
  @State currentTid: string = '';
  @State currentTidIndex: number = 0;
  /** Swiper 实际停留页（渲染依据）：与 currentTidIndex 解耦，防止程序化跳转被连续点击/动画打断后渲染错位 */
  @State pageIndex: number = 0;
  private swiperController: SwiperController = new SwiperController();
  /** 程序化跳转标志：点击分类标签后 Swiper 动画期间屏蔽中间页 onChange，防止目标被劫持 */
  private swiperBusy: boolean = false;
  /** 内容加载请求序号：用于丢弃过期响应，防止分类内容串台 */
  private contentReqSeq: number = 0;
  @State videoList: VodItem[] = [];
  @State currentPage: number = 1;
  @State pagecount: number = 0;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State hasError: boolean = false;
  @State errorMsg: string = '';
  @State sourceName: string = '';
  private lastBuiltinOn: boolean | null = null;
  @State configLoaded: boolean = false;
  @State hasHomeSource: boolean = false;
  @State currentDate: string = '';
  private sourceKey: string = '';
  private homeTid: string = '';
  private homeVideoList: VodItem[] = [];
  private scroller: Scroller = new Scroller();
  @State bottomInset: number = 0;
  @State topInset: number = 0;
  @State leftInset: number = 0;
  @State rightInset: number = 0;
  @State showTabBar: boolean = true;
  @State refreshing: boolean = false;
  @State showFilter: boolean = false;
  @State filterVersion: number = 0;
  // 面板内暂存的筛选选择，点击 完成 后才会提交到 sd.filterSelect 并触发拉取
  @State pendingFilterSelect: Map<string, string> = new Map();
  private scrollAccum: number = 0;
  private categoryScroller: Scroller = new Scroller();
  private clockTimer: number = -1;
  private lastBackTime: number = 0;
  @State bp: Breakpoint = BP_SM;
  @State isLand: boolean = false;
  @State scrollContentHeight: number = 0;
  @State scrollViewportHeight: number = 0;
  @StorageProp('isDarkMode') isDark: boolean = true;
  @StorageProp('emptyProbing') emptyProbing: boolean = false;
  @StorageProp('emptyProbeDone') emptyProbeDone: number = 0;
  @StorageProp('emptyProbeTotal') emptyProbeTotal: number = 0;
  @StorageProp('emptyProbeFound') emptyProbeFound: number = 0;
  @StorageProp('emptyProbeShowResult') emptyProbeShowResult: boolean = false;

    private foldListener: (s: display.FoldStatus) => void = (_s: display.FoldStatus): void => { this.recomputeLayout(); };
  private displayListener: (id: number) => void = (_id: number): void => { this.recomputeLayout(); };
  private winListener: (size: window.Size) => void = (size: window.Size): void => { this.applyWindowSize(size.width, size.height); };
  private winInstance: window.Window | null = null;
  @State winW: number = 0;
  @State winH: number = 0;

  private densityVp(): number {
    try {
      const d = display.getDefaultDisplaySync();
      return d.densityPixels > 0 ? d.densityPixels : 1;
    } catch (e) {
      return 1;
    }
  }

  private applyWindowSize(widthPx: number, heightPx: number): void {
    const den: number = this.densityVp();
    const newIsLand: boolean = widthPx > heightPx;
    const orientationChanged: boolean = newIsLand !== this.isLand;
    this.winW = widthPx / den;
    this.winH = heightPx / den;
    this.bp = getBreakpointByWidth(widthPx);
    this.isLand = newIsLand;
    if (orientationChanged) {
      setTimeout((): void => {
        try { this.scroller.scrollTo({ xOffset: 0, yOffset: 1 }); } catch (e) {}
        setTimeout((): void => {
          try { this.scroller.scrollTo({ xOffset: 0, yOffset: 0 }); } catch (e) {}
        }, 50);
      }, 120);
    }
  }

  private recomputeLayout(): void {
    try {
      if (this.winInstance) {
        const rect = this.winInstance.getWindowProperties().windowRect;
        this.applyWindowSize(rect.width, rect.height);
        return;
      }
    } catch (e) {}
    try {
      const d = display.getDefaultDisplaySync();
      this.applyWindowSize(d.width, d.height);
    } catch (e) {
      this.bp = getBreakpoint();
      this.isLand = isLandscape();
    }
  }

  private initBreakpoint(): void {
    this.recomputeLayout();
  }

  async aboutToAppear() {
    this.initBreakpoint();
    try { display.on('change', this.displayListener); display.on('foldStatusChange', this.foldListener); } catch (e) {}
    await this.initInset();
    this.initApp();
  }

  // 从设置页返回时，如果订阅源发生变化（或此前未配置），重新加载首页数据
  onPageShow(): void {
    const config = getApiConfig();
    // 内置源开关状态变化（设置页切换"内置播放源"开关）时，刷新当前源显示并重载首页
    const builtinOn: boolean = config.isBuiltinSourceEnabled();
    const builtinChanged: boolean = this.lastBuiltinOn === null || builtinOn !== this.lastBuiltinOn;
    this.lastBuiltinOn = builtinOn;
    const currentKey: string = config.getHomeSourceKey();
    const bean = config.getHomeSource();
    // 内置播放源开关关闭且当前源为内置源：隐藏内置源，首页显示无源状态
    if (!builtinOn && config.isBuiltinSourceKey(currentKey)) {
      this.sourceKey = '';
      this.sourceName = '';
      this.hasHomeSource = false;
      this.sortList = [];
      this.videoList = [];
      this.homeVideoList = [];
      this.hasError = false;
      this.loading = false;
      this.loadingMore = false;
      this.configLoaded = true;
      hilog.info(0x0001, 'YSC', 'builtin source switch off, home hidden');
      return;
    }
    const hasSource: boolean = bean !== null || currentKey.length > 0;
    if (!hasSource) return;
    // 订阅源变化，或此前未成功加载过首页数据时，重新加载
    const keyChanged: boolean = currentKey !== this.sourceKey;
    const notLoaded: boolean = this.sortList.length === 0;
    if (keyChanged || notLoaded || builtinChanged) {
      this.configLoaded = true;
      this.hasHomeSource = true;
      this.sourceKey = currentKey;
      this.sourceName = this.getHomeSourceName(bean);
      this.loadHomeContent();
    } else {
      // 源未变但显示名可能变化（如内置源开关被设置页关闭后返回），同步刷新
      this.sourceName = this.getHomeSourceName(bean);
    }
  }

  onPageHide(): void {
    // 离开首页时自动收起筛选面板，回来时不残留
    this.showFilter = false;
  }

  // 返回键：先收起频道/面板类状态，否则双击退出
  onBackPress(): boolean {
    const now: number = Date.now();
    if (now - this.lastBackTime < 2000) {
      // 2 秒内再次按下：退出应用
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ctx.terminateSelf();
      return true;
    }
    this.lastBackTime = now;
    try {
      promptAction.showToast({ message: '再按一次返回键退出', duration: 2000 });
    } catch (e) {
    }
    return true;
  }

  // 滚动方向控制底部 Tab 栏显隐：向下滚动累计超阈值隐藏，向上则显示
  private onContentScroll(dy: number): void {
    // 接近顶部时始终显示 Tab 栏，避免隐藏后找不回来
    let curY = 0;
    try {
      curY = this.scroller.currentOffset().yOffset;
    } catch (e) {
      curY = 0;
    }
    if (curY <= 20) {
      this.scrollAccum = 0;
      if (!this.showTabBar) {
        this.showTabBar = true;
      }
      return;
    }
    if (Math.abs(dy) < 1) {
      return;
    }
    // 方向反转时清零累计，避免抖动
    if ((dy > 0 && this.scrollAccum < 0) || (dy < 0 && this.scrollAccum > 0)) {
      this.scrollAccum = 0;
    }
    this.scrollAccum += dy;
    const threshold = 12;
    if (this.scrollAccum > threshold && this.showTabBar) {
      this.showTabBar = false;
      this.scrollAccum = 0;
    } else if (this.scrollAccum < -threshold && !this.showTabBar) {
      this.showTabBar = true;
      this.scrollAccum = 0;
    }
  }

  private async initInset() {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.bottomInset = await getBottomSafeAreaVp(ctx) + DS.cornerInset(this.bp);
    this.topInset = await getTopSafeAreaVp(ctx);
    this.leftInset = await getLeftSafeAreaVp(ctx) + DS.cornerInset(this.bp);
    this.rightInset = await getRightSafeAreaVp(ctx) + DS.cornerInset(this.bp);
    this.isLand = isLandscape();
    this.bp = getBreakpoint();
    // 监听安全区变化：横竖屏/导航条模式切换时动态更新，避免 Tab 栏压住小白条
    try {
      const win: window.Window = await window.getLastWindow(ctx);
      this.winInstance = win;
      const rect = win.getWindowProperties().windowRect;
      this.applyWindowSize(rect.width, rect.height);
      win.on('windowSizeChange', this.winListener);
      win.on('avoidAreaChange', async (data): Promise<void> => {
        this.recomputeLayout();
        if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          const h: number = data.area.bottomRect.height;
          if (h > 0) {
            this.bottomInset = px2vp(h) + DS.cornerInset(this.bp);
          }
        } else if (data.type === window.AvoidAreaType.TYPE_SYSTEM || data.type === window.AvoidAreaType.TYPE_CUTOUT) {
          const th: number = getTopSafeAreaSync(win);
          if (th > 0) {
            this.topInset = th;
          }
          this.leftInset = await getLeftSafeAreaVp(ctx) + DS.cornerInset(this.bp);
          this.rightInset = await getRightSafeAreaVp(ctx) + DS.cornerInset(this.bp);
        }
      });
    } catch (e) {
    }
  }

  aboutToDisappear() {
    try { display.off('change', this.displayListener); display.off('foldStatusChange', this.foldListener); } catch (e) {}
    if (this.winInstance) { try { this.winInstance.off('windowSizeChange', this.winListener); } catch (e) {} this.winInstance = null; }
    if (this.clockTimer !== -1) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
  }

  updateClock(): void {
    const now: Date = new Date();
    const y: number = now.getFullYear();
    const m: number = now.getMonth() + 1;
    const d: number = now.getDate();
    const w: string = WEEK_DAYS[now.getDay()];
    const hh: number = now.getHours();
    const mm: number = now.getMinutes();
    const hhStr: string = hh < 10 ? '0' + hh : '' + hh;
    const mmStr: string = mm < 10 ? '0' + mm : '' + mm;
    this.currentDate = y + '/' + (m < 10 ? '0' + m : '' + m) + '/' + (d < 10 ? '0' + d : '' + d) + '  ' + w + '  ' + hhStr + ':' + mmStr;
  }

  async initApp() {
    hilog.info(0x0001, 'YSC', 'initApp started');
    const config = getApiConfig();
    let restored = await config.restoreConfig();
    hilog.info(0x0001, 'YSC', 'restoreConfig result: %{public}s', String(restored));
    this.configLoaded = true;
    // 不再内置源：无缓存配置时不自带任何源，等用户在设置里导入配置文件或填配置地址
    if (!restored) {
      this.configLoaded = true;
      this.hasHomeSource = false;
      this.sourceKey = '';
      this.sourceName = '';
      this.sortList = [];
      this.videoList = [];
      this.homeVideoList = [];
      hilog.info(0x0001, 'YSC', 'no cached config, waiting for user import');
      return;
    }
    // 老版本遗留在本地的内置配置：静默转成本地配置文件，源继续可用
    const migrated: boolean = await config.migrateBuiltinConfigToLocal();
    if (migrated) {
      hilog.info(0x0001, 'YSC', 'builtin config migrated to local config file');
    }
    if (restored) {
      // 内置播放源开关已关闭：不加载内置源首页（源列表/搜索同步隐藏内置源）
      if (!config.isBuiltinSourceEnabled() && config.isBuiltinSourceKey(config.getHomeSourceKey())) {
        this.configLoaded = true;
        this.hasHomeSource = false;
        this.sourceKey = '';
        this.sourceName = '';
        this.sortList = [];
        this.videoList = [];
        this.homeVideoList = [];
        hilog.info(0x0001, 'YSC', 'builtin source switch off at startup, home hidden');
        return;
      }
      this.sourceKey = config.getHomeSourceKey();
      const bean = config.getHomeSource();
      this.sourceName = this.getHomeSourceName(bean);
      this.hasHomeSource = bean !== null || this.sourceKey.length > 0;
      hilog.info(0x0001, 'YSC', 'sourceKey=%{public}s sourceName=%{public}s api=%{public}s type=%{public}d',
        this.sourceKey, this.sourceName, bean ? bean.api : 'null', bean ? bean.type : -1);
      if (bean && (bean.api.endsWith('.js') || bean.api.includes('.js?'))) {
        let waitCount = 0;
        while (!isJsEngineReady() && waitCount < 100) {
          await new Promise<void>(resolve => setTimeout(resolve, 100));
          waitCount++;
        }
        if (!isJsEngineReady()) {
          this.hasError = true;
          this.errorMsg = 'JS引擎初始化超时';
          this.loading = false;
          return;
        }
      }
      await this.loadHomeContent();
      // 启动后后台刷新配置（联网重新拉取，检测失效地址）
      this.refreshConfigInBackground();
    }
  }

  private async refreshConfigInBackground(): Promise<void> {
    try {
      const config = getApiConfig();
      const savedUrl: string = await config.getSavedConfigUrl();
      if (savedUrl.length === 0) return;
      // 内置/本地文件配置都是离线固定的，不参与后台联网刷新
      if (savedUrl.startsWith('builtin://') || savedUrl.startsWith('local://')) return;

      const urls: string[] = [];
      const parts: string[] = savedUrl.split('\n');
      for (const p of parts) {
        const t: string = p.trim();
        if (t.length > 0) urls.push(t);
      }
      if (urls.length === 0) return;

      const prevHomeKey: string = this.sourceKey;
      let success: boolean = false;
      try {
        success = await config.loadConfigs(urls);
      } catch (_e) {
        this.showConfigFailedToast(urls, urls.length);
        return;
      }
      if (!success) return;

      const failed: string[] = config.getLastFailedConfigUrls();
      if (failed.length > 0) {
        this.showConfigFailedToast(failed, urls.length);
      }

      const newHomeKey: string = config.getHomeSourceKey();
      if (newHomeKey !== prevHomeKey) {
        this.sourceKey = newHomeKey;
        const bean = config.getHomeSource();
        this.sourceName = this.getHomeSourceName(bean);
        this.hasHomeSource = bean !== null || this.sourceKey.length > 0;
        await this.loadHomeContent();
      }
      // 空源过滤开启但空源列表为空（上次检测可能被中断），自动重新探测
      if (config.isHideEmptySources() && config.getSources().length > 0 && config.getEmptySourceKeys().length === 0) {
        hilog.info(0x0001, 'YSC', 'auto re-probe empty sources: keys empty after refresh (delayed 5s)');
        setTimeout((): void => {
          config.probeEmptySources().then((): void => {}).catch((): void => {});
        }, 5000);
      }

    } catch (e) {
      hilog.error(0x0001, 'YSC', 'refreshConfigInBackground error: %{public}s', formatError(e));
    }
  }

  private showConfigFailedToast(failedUrls: string[], total: number): void {
    const displayUrls: string[] = [];
    for (const u of failedUrls) {
      if (u.length > 45) {
        displayUrls.push(u.substring(0, 45) + '...');
      } else {
        displayUrls.push(u);
      }
    }
    let msg: string;
    if (failedUrls.length === total) {
      msg = '配置地址全部失效：' + displayUrls.join('；');
    } else {
      msg = failedUrls.length + '/' + total + ' 个配置地址失效：' + displayUrls.join('；');
    }
    promptAction.showToast({ message: msg, duration: 5000 });
  }

  private isPhoneClass(): boolean {
    if (this.winW > 0 && this.winH > 0) {
      return Math.min(this.winW, this.winH) < 600;
    }
    try {
      const d = display.getDefaultDisplaySync();
      const density: number = d.densityPixels > 0 ? d.densityPixels : 1;
      const shortEdge: number = Math.min(d.width, d.height) / density;
      return shortEdge < 600;
    } catch (e) {
      return true;
    }
  }

  private gridCols(): number {
    if (this.isPhoneClass()) {
      if (!this.isLand) {
        return 3;
      }
      const wVp: number = this.winW > 0 ? this.winW : 800;
      const hVp: number = this.winH > 0 ? this.winH : 400;
      const availW: number = wVp - 124;
      const availH: number = hVp - 130;
      const gap: number = DS.gridGap(this.bp);
      const targetPosterH: number = availH / 2 - 46;
      if (targetPosterH > 0) {
        const targetCardW: number = targetPosterH * 0.72;
        let cols: number = Math.ceil(availW / (targetCardW + gap));
        if (cols < 4) { cols = 4; }
        if (cols > 12) { cols = 12; }
        return cols;
      }
      return 6;
    }
    const wVp: number = this.winW > 0 ? this.winW : 800;
    const availW: number = wVp - DS.hPadding(this.bp) * 2 - (this.isLand ? 88 : 0);
    let cols: number = Math.round(availW / 180);
    if (cols < 4) { cols = 4; }
    if (cols > 8) { cols = 8; }
    return cols;
  }

  private getRows(): RowData[] {
    const cols: number = this.gridCols();
    const rows: RowData[] = [];
    const list: VodItem[] = this.videoList;
    for (let i = 0; i < list.length; i += cols) {
      rows.push({ rowIndex: i / cols, items: list.slice(i, i + cols) });
    }
    return rows;
  }

  private checkReachEnd(): void {
    if (this.loadingMore || this.loading) return;
    if (this.scrollContentHeight <= 0 || this.scrollViewportHeight <= 0) return;
    try {
      const offset = this.scroller.currentOffset();
      if (offset.yOffset + this.scrollViewportHeight >= this.scrollContentHeight - 300) {
        this.loadMore();
      }
    } catch (e) {}
  }

  /** 当前源显示名：直接显示源名称（内置源如"瓜子影视""电影先生"也显示本名），不再统一显示"默认" */
  getHomeSourceName(bean: SourceBean | null): string {
    return bean ? bean.name : '';
  }

  async loadHomeContent() {
    hilog.info(0x0001, 'YSC', 'loadHomeContent started, sourceKey=%{public}s', this.sourceKey);
    const seq = ++this.contentReqSeq;
    this.loading = true;
    this.hasError = false;
    try {
      const result = await SourceViewModel.getHomeContent(this.sourceKey);
      if (seq !== this.contentReqSeq) {
        return; // 已有更新的加载请求（如切分类），丢弃本次过期结果
      }
      hilog.info(0x0001, 'YSC', 'loadHomeContent result: sortList=%{public}d videoList=%{public}d',
        result.sort.sortList.length, result.list.videoList.length);
      let loadedSort: SortData[] = result.sort.sortList;
      let orderStr: string = PreferencesUtil.getSync('home_sort_' + this.sourceKey, '');
      if (orderStr.length > 0 && loadedSort.length > 1) {
        // 过滤旧排序中已不存在的分类 id（如已移除的港台/欧美/日韩页签），避免残留 id 干扰
        const validIds: string[] = loadedSort.map((sd: SortData): string => sd.id);
        let orderIds: string[] = orderStr.split(',').filter((x: string): boolean => validIds.indexOf(x) >= 0);
        // 保持首个分类(推荐/豆瓣)不参与排序，其余按保存顺序
        const head: SortData[] = loadedSort.slice(0, 1);
        const rest: SortData[] = applyCustomOrder(loadedSort.slice(1), orderIds);
        loadedSort = head.concat(rest);
      }
      this.sortList = loadedSort;
      this.pageIndex = 0;
      if (this.sortList.length > 0) {
        this.hasHomeSource = true;
        this.currentTid = this.sortList[0].id;
        this.currentTidIndex = 0;
        this.homeTid = this.sortList[0].id;
        this.homeVideoList = result.list.videoList.length > 0 ? result.list.videoList : [];
        this.videoList = result.list.videoList.length > 0 ? result.list.videoList : [];
        preloadImages(this.videoList.map((v: VodItem): string => v.pic));
        this.currentPage = 1;
        this.pagecount = result.list.pagecount;
        if (this.videoList.length === 0) {
          await this.loadCategoryContent(this.currentTid, 1, true);
        }
      } else {
        const bean = getApiConfig().getSource(this.sourceKey);
        if (bean && bean.type === 3) {
          const isJar: boolean = !bean.api.startsWith('http://') && !bean.api.startsWith('https://') && !bean.api.endsWith('.js') && !bean.api.includes('.js?');
          if (isJar) {
            this.hasError = true;
            this.errorMsg = '当前源为JAR源(' + bean.api + ')，鸿蒙暂不支持\n请在设置中切换HTTP或JS类型的源';
          } else {
            this.hasError = true;
            this.errorMsg = '首页无数据，请检查源配置';
          }
        } else {
          this.hasError = true;
          this.errorMsg = '首页无数据，请检查源配置';
        }
      }
    } catch (e) {
      this.hasError = true;
      this.errorMsg = formatError(e);
      hilog.error(0x0001, 'YSC', 'loadHomeContent error: %{public}s', formatError(e));
    } finally {
      if (seq === this.contentReqSeq) {
        this.loading = false;
      }
      hilog.info(0x0001, 'YSC', 'loadHomeContent finished, loading=false');
    }
  }

  async loadCategoryContent(tid: string, page: number, isRefresh: boolean) {
    const seq = ++this.contentReqSeq;
    if (isRefresh) {
      this.loading = true;
    } else {
      this.loadingMore = true;
    }
    this.hasError = false;
    try {
      const extend = new Map<string, string>();
      const curSort: SortData | undefined = this.sortList[this.currentTidIndex];
      if (curSort && curSort.filterSelect) {
        curSort.filterSelect.forEach((v: string, k: string): void => {
          if (v && v.length > 0) extend.set(k, v);
        });
      }
      // 棣栦釜鍒嗙被(濡?鎴戠殑璞嗙摚)鏃犵瓫閫夋椂锛屽唴瀹规潵鑷?getHomeContent 缂撳瓨锛岄伩鍏嶇┖鐧?
      if (isRefresh && tid === this.homeTid && extend.size === 0 && this.homeVideoList.length > 0) {
        this.videoList = this.homeVideoList;
        this.currentPage = 1;
        this.pagecount = 1;
        this.loading = false;
        return;
      }
      const result = await SourceViewModel.getCategoryContent(this.sourceKey, tid, page, extend);
      if (seq !== this.contentReqSeq) {
        return; // 过期响应（已切到其他分类），丢弃，避免内容串台
      }
      if (isRefresh) {
        this.videoList = result.videoList;
        this.currentPage = 1;
      } else {
        this.videoList = this.videoList.concat(result.videoList);
        this.currentPage = page;
      }
      this.pagecount = result.pagecount;
      preloadImages(result.videoList.map((v: VodItem): string => v.pic));
    } catch (e) {
      if (seq !== this.contentReqSeq) {
        return; // 过期请求的异常不覆盖当前状态
      }
      this.hasError = true;
      this.errorMsg = formatError(e);
    } finally {
      if (seq === this.contentReqSeq) {
        this.loading = false;
        this.loadingMore = false;
      }
    }
  }

  toggleFilter(): void {
    if (!this.showFilter) { this.seedPendingFilter(); }
    this.animateFilter(!this.showFilter);
  }

  closeFilter(): void {
    this.animateFilter(false);
  }

  /** 打开面板前，把当前生效的筛选拷贝一份作为待编辑草稿 */
  private seedPendingFilter(): void {
    const sd: SortData | undefined = this.sortList[this.currentTidIndex];
    const map: Map<string, string> = new Map();
    if (sd && sd.filterSelect) {
      sd.filterSelect.forEach((v: string, k: string): void => { map.set(k, v); });
    }
    this.pendingFilterSelect = map;
    this.filterVersion++;
  }

  /** 点击"完成"：把草稿提交，重新拉取该分类 */
  applyFilter(): void {
    const sd: SortData | undefined = this.sortList[this.currentTidIndex];
    if (sd) {
      const map: Map<string, string> = new Map();
      this.pendingFilterSelect.forEach((v: string, k: string): void => { map.set(k, v); });
      sd.filterSelect = map;
      // 先清空旧内容，避免按新筛选条件加载期间残留旧列表
      this.videoList = [];
      this.loadCategoryContent(this.currentTid, 1, true);
    }
    this.closeFilter();
  }

  private animateFilter(next: boolean): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.showFilter = next;
    });
  }

    onCategoryClick(index: number) {
    // 点击当前分类且带筛选项时，切换筛选面板显示
    if (index === this.currentTidIndex) {
      const cur = this.sortList[index];
      if (cur && cur.filters && cur.filters.length > 0) {
        this.animateFilter(!this.showFilter);
      }
      return;
    }
    // 程序化跳转期间屏蔽 Swiper 中间页 onChange，防止跨多页点击时目标被中间分类劫持
    this.swiperBusy = true;
    setTimeout((): void => { this.swiperBusy = false; }, 400);
    this.animateFilter(false);
    this.currentTidIndex = index;
    this.pageIndex = index;
    this.currentTid = this.sortList[index].id;
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
    // 首个分类(如"我的豆瓣")内容来自首页推荐，切回时用缓存恢复，避免空白
    if (this.currentTid === this.homeTid && this.homeVideoList.length > 0) {
      this.videoList = this.homeVideoList;
      this.currentPage = 1;
      this.hasError = false;
      return;
    }
    // 先清空旧分类内容，避免新分类加载期间残留上一分类的列表（显示串台）
    this.videoList = [];
    this.loadCategoryContent(this.currentTid, 1, true);
  }

  /** 左右滑动切换标签页（跳过筛选面板/未加载完成的情况）*/
  switchTabRelative(delta: number): void {
    if (!this.configLoaded || !this.hasHomeSource) return;
    if (this.sortList.length <= 1) return;
    const next: number = this.currentTidIndex + delta;
    if (next < 0 || next >= this.sortList.length) return;
    if (delta > 0) { this.swiperController.showNext(); }
    else { this.swiperController.showPrevious(); }
  }

  loadMore() {
    if (this.loadingMore || this.loading) return;
    // pagecount 大于 0 时按 pagecount 判断；
    // pagecount 为 0/1 但当前已加载的数量是 20 的倍数（drpy 常见页大小），继续尝试加载下一页
    // 直到某一页返回空为止（result.videoList.length === 0 表示到底）
    if (this.pagecount > 1 && this.currentPage >= this.pagecount) return;
    if (this.pagecount <= 1 && this.videoList.length > 0 && this.videoList.length % 20 !== 0) return;
    this.loadCategoryContent(this.currentTid, this.currentPage + 1, false);
  }

  goSearch() {
    this.animateFilter(false);
    router.pushUrl({ url: 'tvbox/pages/SearchPage' });
  }

  goSettings() {
    this.animateFilter(false);
    // TV 设置已内嵌到播放器主界面「设置」页签，不再有独立路由页，直接返回主界面
    this.backToMain();
  }

  /** 返回播放器主界面（TV 设置已上移到外层播放器设置） */
  backToMain() {
    this.animateFilter(false);
    try {
      const stackLen: number = Number(router.getLength());
      if (stackLen > 1) {
        router.back();
      } else {
        router.replaceUrl({ url: 'pages/Index' });
      }
    } catch (e) {
      router.replaceUrl({ url: 'pages/Index' });
    }
  }

  

  

  goLive() {
    this.animateFilter(false);
    router.pushUrl({ url: 'tvbox/pages/LivePlayPage' });
  }

  goHistory() {
    this.animateFilter(false);
    router.pushUrl({ url: 'tvbox/pages/HistoryPage' });
  }

  goCollect() {
    this.animateFilter(false);
    router.pushUrl({ url: 'tvbox/pages/FavoritePage' });
  }

  goDetail(item: VodItem) {
    this.animateFilter(false);
    router.pushUrl({
      url: 'tvbox/pages/DetailPage',
      params: {
        vodId: item.id,
        sourceKey: item.sourceKey,
        name: item.name
      }
    });
  }

  @Builder
  TopBar() {
    Row() {
      // 返回播放器主界面
      Row({ space: 3 }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          // 同上：字形窄的 chevron，fontSize 兜到 16，保证图标宽高 ≥ 8vp
          .fontSize(Math.max(DS.bodyFont(this.bp), 16))
          .constraintSize({ minWidth: 12, minHeight: 12 })
          .fontColor([Palette.textPrimary(this.isDark)])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        Text('返回')
          .fontSize(DS.smallFont(this.bp))
          .fontColor(Palette.textPrimary(this.isDark))
          .maxLines(1)
      }
      .padding({ left: 6, right: 10, top: 5, bottom: 5 })
      .margin({ right: 10 })
      .borderRadius(12)
      .backgroundColor(Palette.glass(this.isDark))
      .border({ width: 1, color: Palette.glassBorder(this.isDark) })
      .onClick(() => this.backToMain())

      if (this.sourceName.length > 0) {
        Row() {
          Text('当前源：')
            .fontSize(DS.bodyFont(this.bp))
            .fontColor(Palette.textPrimary(this.isDark))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
          Text(this.sourceName)
            .fontSize(DS.smallFont(this.bp))
            .fontColor(Palette.textPrimary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 220 })
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(16)
            .constraintSize({ minWidth: 12, minHeight: 12 })
            .fontColor([Palette.textPrimary(this.isDark)])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .margin({ left: 4 })
        }
        .padding({ left: 0, right: 8, top: 4, bottom: 4 })
        .borderRadius(10)
        .bindMenu(this.SourceSwitchMenu())
      }
    }
    .width('100%')
    .height((isWide(this.bp) ? 30 : DS.topBarHeight(this.bp)) + this.topInset)
    .padding({ left: DS.hPadding(this.bp) + this.leftInset, right: (this.isLand ? 88 : DS.hPadding(this.bp)) + this.rightInset, top: this.topInset })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  SourceSwitchMenu() {
    Menu() {
      ForEach(getApiConfig().getSources(), (bean: SourceBean, index: number) => {
        MenuItem({ content: bean.name.length > 0 ? bean.name : bean.key })
          .selected(bean.key === this.sourceKey)
          .contentFontColor(bean.key === this.sourceKey ? Palette.textPrimary(this.isDark) : Palette.textPrimary(this.isDark))
          .onClick((): void => { this.switchHomeSource(bean.key); })
      }, (bean: SourceBean, index: number): string => bean.key + '_' + index)
    }
    .backgroundColor(Palette.surface(this.isDark))
    .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .radius(12)
  }

  async switchHomeSource(key: string): Promise<void> {
    if (key === this.sourceKey) return;
    const config = getApiConfig();
    await config.setHomeSource(key);
    config.clearSpider(key);
    this.sourceKey = key;
    const bean = config.getHomeSource();
    this.sourceName = this.getHomeSourceName(bean);
    this.sortList = [];
    this.videoList = [];
    this.homeVideoList = [];
    this.currentPage = 1;
    this.pagecount = 0;
    this.currentTid = '';
    this.currentTidIndex = 0;
    this.pageIndex = 0;
    this.homeTid = '';
    this.hasError = false;
    this.errorMsg = '';
    await this.loadHomeContent();
  }

  @Builder
  CategoryBar() {
    Row() {
      Scroll(this.categoryScroller) {
      Row() {
        ForEach(this.sortList, (item: SortData, index: number) => {
          Row() {
            Text(item.name)
              .fontSize(index === this.currentTidIndex ? DS.categoryFont(this.bp) + 2 : DS.categoryFont(this.bp))
              .fontColor(index === this.currentTidIndex ? Palette.textPrimary(this.isDark) : Palette.textSecondary(this.isDark))
              .fontWeight(index === this.currentTidIndex ? FontWeight.Bold : FontWeight.Normal)
              .maxLines(1)
            if (item.filters.length > 0) {
              SymbolGlyph((index === this.currentTidIndex && this.showFilter) ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
                .fontSize(16)
                .constraintSize({ minWidth: 12, minHeight: 12 })
                .fontColor([index === this.currentTidIndex ? Palette.textPrimary(this.isDark) : Palette.textSecondary(this.isDark)])
                .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                .margin({ left: 4 })
            }
          }
          .padding({ top: 6, bottom: 6 })
          .margin({ right: 18 })
          .onClick(() => this.onCategoryClick(index))
        }, (item: SortData, index: number) => item.id + index)
      }
      .padding({ left: DS.hPadding(this.bp) + this.leftInset, right: DS.hPadding(this.bp) })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .clip(true)
      .layoutWeight(1)
      .height(isWide(this.bp) ? 38 : DS.categoryBarHeight(this.bp))
    }
    .width('100%')
    .padding({ right: (this.isLand ? 88 : 0) + this.rightInset })
    .height(isWide(this.bp) ? 38 : DS.categoryBarHeight(this.bp))
  }

  @Builder
  TabItem(label: string, icon: Resource, action: () => void) {
    Column({ space: 3 }) {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([Palette.textPrimary(this.isDark)])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      Text(label)
        .fontSize(11)
        .fontColor(Palette.textSecondary(this.isDark))
    }
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => action())
  }

  // 悬浮胶囊玻璃 Tab 栏（历史/直播/搜索/收藏）
  // 竖屏：底部横排；横屏/平板：屏幕左侧竖排
  @Builder
  BottomTabBar() {
    if (this.isLand) {
      // 横屏：右侧竖排胶囊，垂直居中常驻
      Column() {
        Column() {
          this.TabItem('历史', $r('sys.symbol.clock'), (): void => { this.goHistory() })
          this.TabItem('直播', $r('sys.symbol.video'), (): void => { this.goLive() })
          this.TabItem('搜索', $r('sys.symbol.magnifyingglass'), (): void => { this.goSearch() })
          this.TabItem('收藏', $r('sys.symbol.star'), (): void => { this.goCollect() })
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .width(72)
        .padding({ top: 10, bottom: 10 })
        .backgroundColor(Palette.glass(this.isDark))
        .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
        .borderRadius(32)
        .border({ width: 1, color: Palette.glassBorder(this.isDark) })
        .shadow({ radius: 24, color: '#66000000', offsetX: 0, offsetY: 8 })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.End)
      .padding({ right: 8 + this.rightInset })
      .hitTestBehavior(HitTestMode.Transparent)
    } else {
      // 竖屏：底部横排胶囊
      Row() {
        Row() {
          this.TabItem('历史', $r('sys.symbol.clock'), (): void => { this.goHistory() })
          this.TabItem('直播', $r('sys.symbol.video'), (): void => { this.goLive() })
          this.TabItem('搜索', $r('sys.symbol.magnifyingglass'), (): void => { this.goSearch() })
          this.TabItem('收藏', $r('sys.symbol.star'), (): void => { this.goCollect() })
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .height(64)
        .padding({ left: 10, right: 10 })
        .backgroundColor(Palette.glass(this.isDark))
        .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
        .borderRadius(32)
        .border({ width: 1, color: Palette.glassBorder(this.isDark) })
        .shadow({ radius: 24, color: '#66000000', offsetX: 0, offsetY: 8 })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ bottom: Math.max(this.bottomInset - DS.cornerInset(this.bp) - 6, 0) })
      .opacity(this.showTabBar ? 1 : 0)
      .translate({ y: this.showTabBar ? 0 : 160 })
      .animation({ duration: Motion.DUR_BASE, curve: Motion.spring() })
      .hitTestBehavior(this.showTabBar ? HitTestMode.Transparent : HitTestMode.None)
    }
  }

  @Builder
  UserDashboard() {
    this.GridContent()
  }

  @Builder
  GridContent() {
    Refresh({ refreshing: $$this.refreshing, offset: 40 }) {
      Scroll(this.scroller) {
      Column({ space: DS.gridGap(this.bp) }) {
        ForEach(this.getRows(), (rowData: RowData) => {
          Row() {
            ForEach(rowData.items, (item: VodItem) => {
              Column() {
                VodCard({
                  item: item,
                  bp: this.bp,
                  onItemClick: (vod: VodItem): void => { this.goDetail(vod) }
                })
              }
              .layoutWeight(1)
              .padding({ left: DS.gridGap(this.bp) / 2, right: DS.gridGap(this.bp) / 2 })
            }, (item: VodItem): string => item.id + '_' + item.sourceKey)
          }
          .width('100%')
          .margin({ left: -(DS.gridGap(this.bp) / 2), right: -(DS.gridGap(this.bp) / 2) })
        }, (rowData: RowData): string => 'row_' + rowData.rowIndex + '_c' + rowData.items.length)
      }
      .width('100%')
      .padding({ left: DS.hPadding(this.bp) + this.leftInset, right: (this.isLand ? 88 : DS.hPadding(this.bp)) + this.rightInset, top: 12, bottom: 80 + this.bottomInset })
      .onAreaChange((_: Area, newArea: Area): void => {
        this.scrollContentHeight = newArea.height as number;
        this.checkReachEnd();
      })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .key('homeScroll_' + this.isLand + '_' + this.bp)
    .onAreaChange((_: Area, newArea: Area): void => {
      this.scrollViewportHeight = newArea.height as number;
      this.checkReachEnd();
    })
    .onDidScroll((xOffset: number, yOffset: number): void => {
      this.onContentScroll(yOffset);
      this.checkReachEnd();
    })
    }
    .width('100%')
    .layoutWeight(1)
    .onRefreshing(() => { this.doManualRefresh(); })
  }

  /** 下拉刷新：清空应用层缓存后强制重拉当前页数据 */
  private async doManualRefresh(): Promise<void> {
    clearHttpCache();
    try {
      if (this.currentTid === this.homeTid) {
        await this.loadHomeContent();
      } else {
        await this.loadCategoryContent(this.currentTid, 1, true);
      }
    } catch (e) {
      this.hasError = true;
      this.errorMsg = formatError(e);
    } finally {
      this.refreshing = false;
    }
  }

  @Builder
  VideoGrid() {
    if (this.loading && this.videoList.length === 0) {
      LoadingIndicator()
        .layoutWeight(1)
    } else if (this.hasError && this.videoList.length === 0) {
      EmptyState({ text: this.errorMsg, onRetry: (): void => { this.loadCategoryContent(this.currentTid, 1, true) } })
        .layoutWeight(1)
    } else if (this.videoList.length === 0 && !this.loading) {
      Column() {
        Text('暂无数据')
          .fontSize(16)
          .fontColor(Palette.textSecondary(this.isDark))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .layoutWeight(1)
    } else {
      this.GridContent()
    }
  }

  // 分类筛选面板（年份/地区/类型/排序等）
  @Builder
  FilterPanel() {
    Column() {
      Scroll() {
        Column() {
          ForEach(this.sortList[this.currentTidIndex].filters, (filter: SortFilter, fIndex: number) => {
            Column() {
              Text(filter.name)
                .fontSize(DS.smallFont(this.bp))
                .fontWeight(FontWeight.Bold)
                .fontColor(Palette.textPrimary(this.isDark))
                .margin({ bottom: 8 })
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.filterKeys(filter), (key: string, kIndex: number) => {
                  Text(this.filterLabel(filter, key))
                    .fontSize(this.isFilterSelected(filter.key, key) ? DS.smallFont(this.bp) + 1 : DS.smallFont(this.bp))
                    .fontWeight(this.isFilterSelected(filter.key, key) ? FontWeight.Bold : FontWeight.Normal)
                    .fontColor(this.isFilterSelected(filter.key, key) ? Palette.textPrimary(this.isDark) : Palette.textSecondary(this.isDark))
                    .backgroundColor(this.isFilterSelected(filter.key, key) ? (this.isDark ? '#33FFFFFF' : '#22000000') : (this.isDark ? '#2C2C2E' : '#E9EAEE'))
                    .borderRadius(14)
                    .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                    .margin({ right: 8, bottom: 8 })
                    .onClick(() => { this.onFilterSelect(filter.key, key); })
                }, (key: string, kIndex: number): string => filter.key + key + kIndex)
              }
              .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .margin({ bottom: 12 })
          }, (filter: SortFilter, fIndex: number): string => filter.key + fIndex + '_' + this.filterVersion)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 8 })
      }
      .scrollBar(BarState.Off)
      .constraintSize({ maxHeight: '55%' })

      // 完成 / 收起 操作条
      Row() {
        Blank()
        Text('重置')
          .fontSize(DS.smallFont(this.bp))
          .fontColor(Palette.textSecondary(this.isDark))
          .backgroundColor(this.isDark ? '#22FFFFFF' : '#11000000')
          .borderRadius(14)
          .padding({ left: 18, right: 18, top: 8, bottom: 8 })
          .margin({ right: 10 })
          .onClick(() => {
            this.pendingFilterSelect = new Map();
            this.filterVersion++;
            this.applyFilter();
          })
        Text('筛选')
          .fontSize(DS.smallFont(this.bp))
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.textPrimary(this.isDark))
          .backgroundColor(Palette.accent())
          .borderRadius(14)
          .padding({ left: 22, right: 22, top: 8, bottom: 8 })
          .onClick(() => { this.applyFilter(); })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 4, bottom: 14 })
    }
    .margin({
      left: DS.hPadding(this.bp) + this.leftInset,
      right: (this.isLand ? 88 : DS.hPadding(this.bp)) + this.rightInset
    })
    .backgroundColor(Palette.glass(this.isDark))
    .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .border({ width: 1, color: Palette.glassBorder(this.isDark) })
    .borderRadius(20)
    .shadow({ radius: 24, color: this.isDark ? '#66000000' : '#22000000', offsetY: 6 })
  }

  private filterKeys(filter: SortFilter): string[] {
    const keys: string[] = [];
    if (filter.values) {
      const entries: Array<[string, string]> = Array.from(filter.values.entries());
      for (const entry of entries) { keys.push(entry[0]); }
    }
    return keys;
  }

  private filterLabel(filter: SortFilter, key: string): string {
    if (filter.values) {
      const val: string | undefined = filter.values.get(key);
      return val !== undefined ? val : key;
    }
    return key;
  }

  private isFilterSelected(filterKey: string, value: string): boolean {
    const sd: SortData | undefined = this.sortList[this.currentTidIndex];
    if (!sd) return false;
    // 面板打开时以草稿为准，关闭时以已提交的选择为准
    const src: Map<string, string> = this.showFilter ? this.pendingFilterSelect : sd.filterSelect;
    const sel: string | undefined = src.get(filterKey);
    if (sel === undefined || sel === '') {
      // 未选择时，默认高亮"全部"(空值)对应项
      const f: SortFilter | undefined = sd.filters.find((x: SortFilter): boolean => x.key === filterKey);
      return f !== undefined && (value === f.init || value === '');
    }
    return sel === value;
  }

  private onFilterSelect(filterKey: string, value: string): void {
    // 仅更新草稿，不立即刷新；点击"完成"后再统一提交
    this.pendingFilterSelect.set(filterKey, value);
    this.filterVersion++;
  }

  

  build() {
    Stack() {
      JsEngineHost()
      Column() {
        // 顶部栏：应用名 + 时钟
        this.TopBar()

        // 空源检测提示条
        if (this.emptyProbing || this.emptyProbeShowResult) {
          Row() {
            Text(this.emptyProbing
        ? ('正在检测空源… ' + this.emptyProbeDone + '/' + this.emptyProbeTotal + '，已发现 ' + this.emptyProbeFound + ' 个，请勿退出应用')
              : ('检测完成，共发现 ' + this.emptyProbeFound + ' 个空源'))
              .fontSize(12)
              .fontColor(Palette.textPrimary(this.isDark))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          .backgroundColor(Palette.glass(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .border({ width: { bottom: 0.5 }, color: Palette.glassBorder(this.isDark) })
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -8 })).animation({ duration: 220, curve: Curve.EaseOut }))
        }

        // 分类横向滚动条
        this.CategoryBar()

        // 内容区域
        if (!this.configLoaded) {
          Column() {
            LoadingProgress()
              .width(48)
              .height(48)
              .color(Palette.textPrimary(this.isDark))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else if (!this.hasHomeSource) {
          // 未配置订阅
          Column() {
            Text('请先在播放器「设置 - 在线视频设置」中配置订阅地址')
              .fontSize(18)
              .fontColor(Palette.textPrimary(this.isDark))
              .margin({ bottom: 20 })
            Button('返回主界面')
              .fontSize(16)
              .fontColor(Palette.textPrimary(this.isDark))
              .backgroundColor(Palette.glass(this.isDark))
              .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
              .borderRadius(24)
              .border({ width: 1, color: Palette.glassBorder(this.isDark) })
              .padding({ left: 32, right: 32, top: 12, bottom: 12 })
              .animation({ duration: 180, curve: Curve.EaseOut })
              .clickEffect({ level: ClickEffectLevel.MIDDLE, scale: 0.96 })
              .onClick(() => {
                this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.backToMain(); });
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else {
          // Swiper：原生 GPU 合成的水平滑动，代替手动 translate 动画
          Swiper(this.swiperController) {
            ForEach(this.sortList, (sd: SortData, idx: number) => {
              Column() {
                if (idx === this.pageIndex && idx === 0) {
                  this.UserDashboard()
                } else if (idx === this.pageIndex) {
                  this.VideoGrid()
                } else {
                  LoadingProgress()
                    .width(48)
                    .height(48)
                    .color(Palette.textPrimary(this.isDark))
                }
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
            }, (sd: SortData, idx: number): string => 'tab_' + idx + '_' + sd.id + '_' + this.isLand)
          }
          .index(this.pageIndex)
          .loop(false)
          .indicator(false)
          .autoPlay(false)
          .effectMode(EdgeEffect.Spring)
          .duration(300)
          .curve(Curve.FastOutSlowIn)
          .layoutWeight(1)
          .width('100%')
          .onChange((index: number): void => {
            // 始终同步 Swiper 实际停留页：动画被打断/快速连续点击后，渲染依据跟随真实位置，避免页签与内容错位
            this.pageIndex = index;
            if (this.swiperBusy) {
              return; // 点击标签触发的程序化跳转，动画途中经过的中间页回调忽略，防止劫持
            }
            if (index !== this.currentTidIndex) { this.onCategoryClick(index); }
          })
        }

        // 底部加载更多 / 已到底提示
        if (this.loadingMore) {
          Row() {
            LoadingProgress()
              .width(20)
              .height(20)
              .color(Palette.textPrimary(this.isDark))
            Text('加载更多...')
              .fontSize(12)
              .fontColor('#999999')
              .margin({ left: 8 })
          }
          .width('100%')
          .height(36)
          .justifyContent(FlexAlign.Center)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Palette.bg(this.isDark))

      // 首页内容加载指示（无内容时中央显示 spinner）
      if (this.configLoaded && this.hasHomeSource && this.loading
          && this.videoList.length === 0 && this.homeVideoList.length === 0) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color(Palette.textPrimary(this.isDark))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
      }

      // 分类筛选面板（全屏遮罩 + 顶部下拉卡片 + 动画）
      if (this.showFilter && this.sortList.length > this.currentTidIndex
          && this.sortList[this.currentTidIndex].filters.length > 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => { this.closeFilter(); })
          .transition(TransitionEffect.opacity(0).animation({ duration: 200, curve: Curve.EaseOut }))

        Column() {
          Column()
            .width('100%')
            .height((isWide(this.bp) ? 30 : DS.topBarHeight(this.bp)) + this.topInset + (isWide(this.bp) ? 38 : DS.categoryBarHeight(this.bp)))
            .hitTestBehavior(HitTestMode.Transparent)
          this.FilterPanel()
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -20 })).animation({ duration: 220, curve: Curve.EaseOut }))
      }

      // 底部悬浮玻璃 Tab 栏
      if (this.configLoaded) {
        this.BottomTabBar()
      }
    }
    .alignContent(Alignment.BottomStart)
    .width('100%')
    .height('100%')

  
  }
}
