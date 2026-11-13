/**
 * 设置页 * 单列可滚动设置项列表，每行：左侧标签 + 右侧 ">" 箭头，点击弹出对话框或切换设置 */
import { router, promptAction } from '@kit.ArkUI';

import { getApiConfig } from '../api/ApiConfig';
import { SourceBean } from '../model/SourceBean';
import { ParseBean } from '../model/ParseBean';
import { formatError } from '../utils/HttpUtil';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { SourceViewModel } from '../viewmodel/SourceViewModel';
import { SortData, applyCustomOrder } from '../model/MovieSort';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { getTopSafeAreaVp, getTopSafeAreaSync, getBottomSafeAreaVp, getLeftSafeAreaVp, getRightSafeAreaVp, getTopCutoutVp, getBreakpoint, Breakpoint, BP_SM, isWide } from '../utils/ScreenAdapter';
import { DS, Motion } from '../utils/DesignSystem';
import { ThemeManager, ThemeMode, Palette } from '../utils/ThemeManager';
import { OrientationManager, OrientMode } from '../utils/OrientationManager';
import { display } from '@kit.ArkUI';
import { common, bundleManager } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
interface ToastOptions {
  message: string;
  duration?: number;
  bottom?: string;
}


interface NavRowParam {
  label: string;
  subtitle: string;
  value: string;
  isPill: boolean;
  action: () => void;
}

interface ToggleRowParam {
  label: string;
  subtitle: string;
  isOn: boolean;
  onChange: (v: boolean) => void;
}

interface SelectRowParam {
  label: string;
  subtitle: string;
  value: string;
  options: string[];
  onSelect: (index: number) => void;
}

const DOMAIN: number = 0x0007;
const TAG: string = 'SettingsPage';

@Component
export struct SettingsPage {
  /** 嵌入主界面设置页时为 true：隐藏顶栏，仅保留「数据」分组 */
  @Prop embedded: boolean = false;
  @State configUrl: string = '';
  @State failedConfigUrls: string[] = [];
  @State topSafe: number = 0;
  @State topCutout: number = 0;
  @State bottomSafe: number = 0;
  @State leftSafe: number = 0;
  @State rightSafe: number = 0;
  @State bp: Breakpoint = BP_SM;
    private foldListener: (s: display.FoldStatus) => void = (_s: display.FoldStatus): void => { this.displayListener(0); };
  private displayListener: (id: number) => void = (_id: number): void => {
    this.bp = getBreakpoint();
    // 旋转/挖孔位置变化时，重新读取左右安全区，避免横屏返回键被摄像头遮挡
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    getLeftSafeAreaVp(ctx).then((v: number): void => { this.leftSafe = v + DS.cornerInset(this.bp); });
    getRightSafeAreaVp(ctx).then((v: number): void => { this.rightSafe = v + DS.cornerInset(this.bp); });
    getTopCutoutVp(ctx).then((v: number): void => { this.topCutout = v; });
  };
  @State currentSourceKey: string = '';
  @StorageProp('isDarkMode') isDark: boolean = true;
  @StorageProp('emptyProbing') emptyProbing: boolean = false;
  @StorageProp('emptyProbeDone') emptyProbeDone: number = 0;
  @StorageProp('emptyProbeTotal') emptyProbeTotal: number = 0;
  @StorageProp('emptyProbeFound') emptyProbeFound: number = 0;
  @StorageProp('emptyProbeShowResult') emptyProbeShowResult: boolean = false;
  @State themeMode: ThemeMode = 'system';
  @State orientMode: OrientMode = 'system';
    @State filterNonVideo: boolean = false;
  @State sourceFilterKeywords: string = '';
  @State showSourceFilterDialog: boolean = false;
  @State inputSourceFilterKeywords: string = '';
  @State inputFilterNonVideo: boolean = false;
  @State hideEmptySources: boolean = false;
  @State showEmptySourceDialog: boolean = false;
  @State emptyKeysCount: number = 0;
  @State probing: boolean = false;
  @State probeDone: number = 0;
  @State probeTotal: number = 0;
  @State probeFoundEmpty: number = 0;
  @State sourceList: SourceBean[] = [];
  @State parseList: ParseBean[] = [];
  @State liveUrl: string = '';
  @State loading: boolean = false;

  // 弹窗显隐控制
  @State showConfigUrlDialog: boolean = false;
  @State showHistoryDialog: boolean = false;
  @State showSourceDialog: boolean = false;
  @State showLiveDialog: boolean = false;
  @State showParseDialog: boolean = false;

  // 弹窗内输入临时值
  @State inputConfigUrl: string = '';
  @State inputLiveUrl: string = '';
  @State inputHistoryUrls: string = '';
  @State liveHistoryList: string[] = [];
  @State historyList: string[] = [];
  @State historyEditList: string[] = [];
  @State editingHistoryIndex: number = -1;
  @State editingLiveIndex: number = -1;
  @State dragHistoryIndex: number = -1;
  @State dragHistoryHover: number = -1;
  @State dragHistoryOffset: number = 0;
  @State dragSortIndex: number = -1;
  @State dragSortHover: number = -1;
  @State dragSortOffset: number = 0;
  @State historyAutoSwitch: boolean = false;
  @State keyboardHeight: number = 0;

  @State showSortDialog: boolean = false;
  @State sortCategories: SortData[] = [];
  @State sortLoading: boolean = false;

  // 默认源（内置播放源/内置直播源）弹窗
  @State showDefaultSourceDialog: boolean = false;
  @State useBuiltinSource: boolean = false;
  @State useBuiltinLive: boolean = false;

  // 弹窗组件引用


  @State appVersion: string = '1.0.1';

  aboutToAppear(): void {
    this.bp = getBreakpoint();
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersion = info.versionName;
    } catch (_e) {}
    this.themeMode = ThemeManager.getSavedMode();
    this.orientMode = OrientationManager.getSavedMode();
    try { display.on('change', this.displayListener); display.on('foldStatusChange', this.foldListener); } catch (e) {}
    this.loadData();
    this.initSafeArea();
  }

  aboutToDisappear(): void {
    try { display.off('change', this.displayListener); display.off('foldStatusChange', this.foldListener); } catch (e) {}
  }

  private async initSafeArea(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.topSafe = await getTopSafeAreaVp(ctx);
    this.topCutout = await getTopCutoutVp(ctx);
    this.bottomSafe = await getBottomSafeAreaVp(ctx) + DS.cornerInset(this.bp);
    this.leftSafe = await getLeftSafeAreaVp(ctx) + DS.cornerInset(this.bp);
    this.rightSafe = await getRightSafeAreaVp(ctx) + DS.cornerInset(this.bp);
    try {
      const win: window.Window = await window.getLastWindow(ctx);
      win.on('avoidAreaChange', (data): void => {
        if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          const h: number = data.area.bottomRect.height;
          if (h > 0) { this.bottomSafe = px2vp(h) + DS.cornerInset(this.bp); }
        } else if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
          const th: number = getTopSafeAreaSync(win);
          if (th > 0) { this.topSafe = th; }
        } else if (data.type === window.AvoidAreaType.TYPE_CUTOUT) {
          const ch: number = data.area.topRect.height;
          this.topCutout = ch > 0 ? px2vp(ch) : 0;
          this.topSafe = getTopSafeAreaSync(win);
          // 横屏时挖孔从 topRect 转到 left/right Rect，需要同步更新左右安全区
          const lw: number = data.area.leftRect.width;
          const rw: number = data.area.rightRect.width;
          this.leftSafe = (lw > 0 ? px2vp(lw) : 0) + DS.cornerInset(this.bp);
          this.rightSafe = (rw > 0 ? px2vp(rw) : 0) + DS.cornerInset(this.bp);
        } else if (data.type === window.AvoidAreaType.TYPE_KEYBOARD) {
          const kh: number = data.area.bottomRect.height;
          this.keyboardHeight = kh > 0 ? px2vp(kh) : 0;
        }
      });
      try {
        win.on('keyboardHeightChange', (h: number): void => {
          this.keyboardHeight = h > 0 ? px2vp(h) : 0;
        });
      } catch (_e) {}
    } catch (e) {
    }
  }

  async loadData(): Promise<void> {
    try {
      const config = getApiConfig();
      this.configUrl = await config.getSavedConfigUrl();
      // 内置源地址强制隐藏：不向配置输入框回填 builtin:// 地址
      this.inputConfigUrl = this.configUrl.startsWith('builtin://') ? '' : this.configUrl;
      this.useBuiltinSource = config.isBuiltinSourceEnabled();
      this.useBuiltinLive = config.isBuiltinLiveEnabled();
      const failedRaw: string = await PreferencesUtil.get('failed_config_urls', '');
      if (failedRaw.length > 0) {
        try { this.failedConfigUrls = JSON.parse(failedRaw) as string[]; } catch (_e) { this.failedConfigUrls = []; }
      } else { this.failedConfigUrls = []; }
      this.liveUrl = await PreferencesUtil.get('live_url', '');
      this.inputLiveUrl = this.liveUrl;
      this.sourceList = config.getSources();
      this.currentSourceKey = config.getHomeSourceKey();
        this.filterNonVideo = config.isFilterNonVideo();
      this.sourceFilterKeywords = config.getSourceFilterKeywordsRaw();
      this.hideEmptySources = config.isHideEmptySources();
      this.emptyKeysCount = config.getEmptySourceKeys().length;
      this.parseList = config.getParseBeanList();
      // 默认选中自动解析
      for (let i = 0; i < this.parseList.length; i++) {
        if (this.parseList[i].type === -1) {
          this.parseList[i].isDefault = true;
        }
      }
      await this.loadHistory();
      await this.loadLiveHistory();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'loadData failed: %{public}s', formatError(e));
    }
  }

  async loadHistory(): Promise<void> {
    const raw: string = await PreferencesUtil.get('config_history', '');
    if (raw.length > 0) {
      try {
        const arr: string[] = (JSON.parse(raw) as string[]).filter((u: string): boolean => !u.startsWith('builtin://'));
        this.historyList = arr;
      } catch (_e) {
        this.historyList = [];
      }
    } else {
      this.historyList = [];
    }
    this.historyEditList = this.historyList.slice();
    this.historyAutoSwitch = await PreferencesUtil.getBool('history_auto_switch', false);
  }

  async toggleHistoryAutoSwitch(v: boolean): Promise<void> {
    this.historyAutoSwitch = v;
    await PreferencesUtil.putBool('history_auto_switch', v);
  }

  async persistHistoryList(list: string[]): Promise<void> {
    this.historyList = list;
    this.historyEditList = list.slice();
    await PreferencesUtil.put('config_history', JSON.stringify(list));
  }

  moveHistoryItem(index: number, delta: number): void {
    const target: number = index + delta;
    if (target < 0 || target >= this.historyEditList.length) return;
    const arr: string[] = this.historyEditList.slice();
    const tmp: string = arr[index];
    arr[index] = arr[target];
    arr[target] = tmp;
    this.historyEditList = arr;
  }

  private readonly HIST_ROW_H: number = 52;
  private readonly SORT_ROW_H: number = 44;

  startHistoryDrag(index: number): void {
    if (this.editingHistoryIndex === index) return;
    if (index < 0 || index >= this.historyEditList.length) return;
    this.dragHistoryIndex = index;
    this.dragHistoryHover = index;
    this.dragHistoryOffset = 0;
  }

  commitHistoryPan(offsetY: number): void {
    if (this.dragHistoryIndex < 0) return;
    this.dragHistoryOffset = offsetY;
    const len: number = this.historyEditList.length;
    let hover: number = this.dragHistoryIndex + Math.round(offsetY / this.HIST_ROW_H);
    if (hover < 0) hover = 0;
    if (hover > len - 1) hover = len - 1;
    if (hover !== this.dragHistoryHover) this.dragHistoryHover = hover;
  }

  endHistoryDrag(): void {
    const from: number = this.dragHistoryIndex;
    const to: number = this.dragHistoryHover;
    if (from >= 0 && to >= 0 && from !== to && from < this.historyEditList.length && to < this.historyEditList.length) {
      const arr: string[] = this.historyEditList.slice();
      const moved: string = arr[from];
      arr.splice(from, 1);
      arr.splice(to, 0, moved);
      this.historyEditList = arr;
    }
    this.dragHistoryIndex = -1;
    this.dragHistoryHover = -1;
    this.dragHistoryOffset = 0;
  }

  historyRowShift(index: number): number {
    const from: number = this.dragHistoryIndex;
    const hover: number = this.dragHistoryHover;
    if (from < 0 || hover < 0 || from === hover) return 0;
    if (index === from) return 0;
    if (from < hover) {
      if (index > from && index <= hover) return -this.HIST_ROW_H;
    } else {
      if (index >= hover && index < from) return this.HIST_ROW_H;
    }
    return 0;
  }

  startSortDrag(index: number): void {
    if (index < 0 || index >= this.sortCategories.length) return;
    this.dragSortIndex = index;
    this.dragSortHover = index;
    this.dragSortOffset = 0;
  }

  commitSortPan(offsetY: number): void {
    if (this.dragSortIndex < 0) return;
    this.dragSortOffset = offsetY;
    const len: number = this.sortCategories.length;
    let hover: number = this.dragSortIndex + Math.round(offsetY / this.SORT_ROW_H);
    if (hover < 0) hover = 0;
    if (hover > len - 1) hover = len - 1;
    if (hover !== this.dragSortHover) this.dragSortHover = hover;
  }

  endSortDrag(): void {
    const from: number = this.dragSortIndex;
    const to: number = this.dragSortHover;
    if (from >= 0 && to >= 0 && from !== to && from < this.sortCategories.length && to < this.sortCategories.length) {
      const arr: SortData[] = this.sortCategories.slice();
      const moved: SortData = arr[from];
      arr.splice(from, 1);
      arr.splice(to, 0, moved);
      this.sortCategories = arr;
    }
    this.dragSortIndex = -1;
    this.dragSortHover = -1;
    this.dragSortOffset = 0;
  }

  sortRowShift(index: number): number {
    const from: number = this.dragSortIndex;
    const hover: number = this.dragSortHover;
    if (from < 0 || hover < 0 || from === hover) return 0;
    if (index === from) return 0;
    if (from < hover) {
      if (index > from && index <= hover) return -this.SORT_ROW_H;
    } else {
      if (index >= hover && index < from) return this.SORT_ROW_H;
    }
    return 0;
  }

  updateHistoryItem(index: number, val: string): void {
    const arr: string[] = this.historyEditList.slice();
    arr[index] = val;
    this.historyEditList = arr;
  }

  async removeHistoryItem(index: number): Promise<void> {
    const arr: string[] = this.historyEditList.slice();
    arr.splice(index, 1);
    await this.persistHistoryList(arr);
  }

  async saveHistoryEdit(): Promise<void> {
    const lines: string[] = this.inputHistoryUrls.split('\n');
    const arr: string[] = [];
    for (const line of lines) {
      const t: string = line.trim();
      if (t.length > 0 && arr.indexOf(t) < 0) arr.push(t);
    }
    await this.persistHistoryList(arr);
  }

  async saveHistory(url: string): Promise<void> {
    const trimmed: string = url.trim();
    if (trimmed.length === 0) return;
    // 内置源地址强制隐藏：不写入历史
    if (trimmed.startsWith('builtin://')) return;
    let list: string[] = this.historyList.slice();
    const idx: number = list.indexOf(trimmed);
    if (idx >= 0) {
      list.splice(idx, 1);
    }
    list.unshift(trimmed);
    this.historyList = list;
    await PreferencesUtil.put('config_history', JSON.stringify(list));
  }

  async loadLiveHistory(): Promise<void> {
    const raw: string = await PreferencesUtil.get('live_history', '');
    if (raw.length > 0) {
      try {
        const arr: string[] = JSON.parse(raw) as string[];
        this.liveHistoryList = arr.slice(0, 5);
      } catch (_e) {
        this.liveHistoryList = [];
      }
    } else {
      this.liveHistoryList = [];
    }
  }

  async saveLiveHistory(url: string): Promise<void> {
    const trimmed: string = url.trim();
    if (trimmed.length === 0) return;
    let list: string[] = this.liveHistoryList.slice();
    const idx: number = list.indexOf(trimmed);
    if (idx >= 0) {
      list.splice(idx, 1);
    }
    list.unshift(trimmed);
    if (list.length > 5) {
      list = list.slice(0, 5);
    }
    this.liveHistoryList = list;
    await PreferencesUtil.put('live_history', JSON.stringify(list));
  }

  async removeLiveHistoryItem(index: number): Promise<void> {
    const arr: string[] = this.liveHistoryList.slice();
    if (index < 0 || index >= arr.length) return;
    arr.splice(index, 1);
    this.liveHistoryList = arr;
    // 使用：立即应用该直播地址并关闭弹窗
    if (this.editingLiveIndex === index) this.editingLiveIndex = -1;
    else if (this.editingLiveIndex > index) this.editingLiveIndex = this.editingLiveIndex - 1;
    await PreferencesUtil.put('live_history', JSON.stringify(arr));
  }

  updateLiveHistoryItem(index: number, url: string): void {
    const arr: string[] = this.liveHistoryList.slice();
    if (index < 0 || index >= arr.length) return;
    arr[index] = url;
    this.liveHistoryList = arr;
  }

  async commitLiveHistoryEdit(): Promise<void> {
    // 提交编辑：把当前列表写回偏好
    await PreferencesUtil.put('live_history', JSON.stringify(this.liveHistoryList));
    this.editingLiveIndex = -1;
  }

  async selectLiveHistoryUrl(url: string): Promise<void> {
    // 使用：立即应用该直播地址并关闭弹窗
    this.inputLiveUrl = url;
    this.liveUrl = url;
    await PreferencesUtil.put('live_url', url);
    await PreferencesUtil.putInt('live_group_index', 0);
    await PreferencesUtil.putInt('live_channel_index', 0);
    await PreferencesUtil.put('live_last_url_for_index', url);
    await this.saveLiveHistory(url);
    getApiConfig().setLiveUrl(url);
    this.showLiveDialog = false;
    promptAction.showToast({ message: '直播地址已启用' } as ToastOptions);
  }

  getCurrentSourceName(): string {
    for (const s of this.sourceList) {
      if (s.key === this.currentSourceKey) {
        return s.name;
      }
    }
    return '未选择';
  }

  getCurrentParseName(): string {
    for (const p of this.parseList) {
      if (p.isDefault) {
        return p.type === -1 ? '自动解析' : p.name;
      }
    }
    return '直连';
  }

  getConfigUrlDisplay(): string {
    if (this.configUrl.length === 0) return '未配置';
    // 本地文件导入的配置：显示来源而不是 local:// 内部标记
    if (this.configUrl.startsWith('local://')) return '本地文件导入';
    // 内置默认配置：地址强制隐藏，仅显示"默认"
    if (this.configUrl.startsWith('builtin://')) return '已废弃（请重新导入）';
    // 多配置聚合：换行分隔的多地址显示为“聚合配置(N个)”
    if (this.configUrl.includes('\n')) {
      const parts: string[] = this.configUrl.split('\n');
      let count: number = 0;
      for (const p of parts) {
        if (p.trim().length > 0) count++;
      }
      if (count > 1) {
        const failedCount: number = this.failedConfigUrls.length;
        if (failedCount > 0) {
          return '聚合配置(' + count + '个，' + failedCount + '个失效)';
        }
        return '聚合配置(' + count + '个)';
      }
      const single: string = parts.length > 0 ? parts[0].trim() : '';
      if (single.length > 40) return single.substring(0, 40) + '...';
      return single.length > 0 ? single : '未配置';
    }
    if (this.configUrl.length > 40) {
      return this.configUrl.substring(0, 40) + '...';
    }
    return this.configUrl;
  }

  private isFailedUrl(url: string): boolean {
    return this.failedConfigUrls.indexOf(url) >= 0;
  }

  private getConfigUrlLines(): string[] {
    const parts: string[] = this.inputConfigUrl.split('\n');
    const urls: string[] = [];
    for (const p of parts) {
      const t: string = p.trim();
      if (t.length > 0) urls.push(t);
    }
    return urls;
  }

  private removeFailedUrls(): void {
    const lines: string[] = this.inputConfigUrl.split('\n');
    const kept: string[] = [];
    for (const line of lines) {
      const t: string = line.trim();
      if (t.length === 0 || !this.isFailedUrl(t)) {
        kept.push(line);
      }
    }
    this.inputConfigUrl = kept.join('\n');
    this.failedConfigUrls = [];
    PreferencesUtil.put('failed_config_urls', '[]').catch((): void => {});
    try {
      promptAction.showToast({ message: '已删除失效地址' } as ToastOptions);
    } catch (_e) {}
  }

  getLiveUrlDisplay(): string {
    if (this.liveUrl.length === 0) return '未配置';
    if (this.liveUrl.startsWith('builtin://')) return '内置直播源';
    if (this.liveUrl.length > 40) {
      return this.liveUrl.substring(0, 40) + '...';
    }
    return this.liveUrl;
  }

    closeOtherPopups(keep: string = ''): void {
    if (keep !== 'configUrl' && this.showConfigUrlDialog) this.showConfigUrlDialog = false;
    if (keep !== 'history' && this.showHistoryDialog) this.showHistoryDialog = false;
    if (keep !== 'source' && this.showSourceDialog) this.showSourceDialog = false;
    if (keep !== 'sourceFilter' && this.showSourceFilterDialog) this.showSourceFilterDialog = false;
    if (keep !== 'emptySource' && this.showEmptySourceDialog) this.showEmptySourceDialog = false;
    if (keep !== 'live' && this.showLiveDialog) this.showLiveDialog = false;
    if (keep !== 'parse' && this.showParseDialog) this.showParseDialog = false;
    if (keep !== 'sort' && this.showSortDialog) this.showSortDialog = false;
    if (keep !== 'defaultSource' && this.showDefaultSourceDialog) this.showDefaultSourceDialog = false;
  }

  openConfigUrlDialog(): void {
    this.closeOtherPopups('configUrl');
    // 内置源地址强制隐藏：编辑框不显示内置地址
    this.inputConfigUrl = this.configUrl.startsWith('builtin://') ? '' : this.configUrl;
    this.showConfigUrlDialog = true;
  }

  openDefaultSourceDialog(): void {
    this.closeOtherPopups('defaultSource');
    this.showDefaultSourceDialog = true;
  }

  /** 内置播放源开关：开启时启用内置源并显示；关闭时隐藏内置源（外部导入源不受影响） */
  async toggleBuiltinSource(v: boolean): Promise<void> {
    const config = getApiConfig();
    await config.setBuiltinSourceEnabled(v);
    this.useBuiltinSource = v;
    if (v) {
      // 开启内置源：若当前不是内置配置，先保存外部地址到历史，再加载内置配置
      const savedUrl: string = await config.getSavedConfigUrl();
      if (!savedUrl.startsWith('builtin://') || config.getSourceKeys().length === 0) {
        if (savedUrl.length > 0 && !savedUrl.startsWith('builtin://') && !savedUrl.startsWith('local://')) {
          await this.saveHistory(savedUrl);
        }
        const ok: boolean = await config.loadBuiltinConfig();
        if (ok) {
          this.configUrl = 'builtin://config_default';
          this.inputConfigUrl = '';
        } else {
          promptAction.showToast({ message: '内置源加载失败' } as ToastOptions);
          return;
        }
      }
      this.sourceList = config.getSources();
      this.currentSourceKey = config.getHomeSourceKey();
      promptAction.showToast({ message: '已启用内置播放源' } as ToastOptions);
    } else {
      // 关闭内置源：仅隐藏内置源，不切换/清空外部配置；源列表由 getSources 过滤后刷新
      this.sourceList = config.getSources();
      this.currentSourceKey = config.getHomeSourceKey();
      promptAction.showToast({ message: '已关闭内置播放源' } as ToastOptions);
    }
  }

  /** 内置直播源开关：开启时直播使用内置直播源 */
  async toggleBuiltinLive(v: boolean): Promise<void> {
    const config = getApiConfig();
    await config.setBuiltinLiveEnabled(v);
    this.useBuiltinLive = v;
    if (v) {
      // 开启内置直播源：保存当前外部直播地址到历史后切换为内置
      const currentLive: string = this.liveUrl;
      if (currentLive.length > 0 && !currentLive.startsWith('builtin://')) {
        await this.saveLiveHistory(currentLive);
      }
      this.liveUrl = 'builtin://live_default.m3u';
      this.inputLiveUrl = this.liveUrl;
      await PreferencesUtil.put('live_url', this.liveUrl);
      config.setLiveUrl(this.liveUrl);
      promptAction.showToast({ message: '已启用内置直播源' } as ToastOptions);
    } else {
      // 关闭内置直播源：若当前是内置直播源，尝试恢复最近的外部直播地址
      const currentLive: string = this.liveUrl;
      if (currentLive.startsWith('builtin://')) {
        const external: string | undefined = this.liveHistoryList.find((h: string): boolean => !h.startsWith('builtin://'));
        if (external !== undefined) {
          this.liveUrl = external;
          this.inputLiveUrl = external;
          await PreferencesUtil.put('live_url', external);
          config.setLiveUrl(external);
        } else {
          this.liveUrl = '';
          this.inputLiveUrl = '';
          await PreferencesUtil.put('live_url', '');
          config.setLiveUrl('');
        }
      }
      promptAction.showToast({ message: '已关闭内置直播源' } as ToastOptions);
    }
  }

  /** 默认源入口显示文案 */
  getDefaultSourceDisplay(): string {
    const parts: string[] = [];
    if (this.useBuiltinSource) parts.push('播放源开');
    if (this.useBuiltinLive) parts.push('直播源开');
    if (parts.length === 0) return '默认关闭';
    return parts.join(' · ');
  }

  openHistoryDialog(): void {
    this.closeOtherPopups('history');
    this.inputHistoryUrls = this.historyList.join('\n');
    this.showHistoryDialog = true;
  }

  async selectHistoryUrl(url: string): Promise<void> {
    this.configUrl = url;
    this.inputConfigUrl = url;
    await this.loadConfig(url);
  }

    async toggleFilterNonVideo(): Promise<void> {
    const config = getApiConfig();
    const next: boolean = !this.filterNonVideo;
    await config.setFilterNonVideo(next);
    this.filterNonVideo = next;
    this.sourceList = config.getSources();
    this.currentSourceKey = config.getHomeSourceKey();
    promptAction.showToast({ message: next ? '已开启：过滤小说/听书等非视频' : '已关闭：显示全部' } as ToastOptions);
  }

  async setFilterNonVideo(next: boolean): Promise<void> {
    const config = getApiConfig();
    await config.setFilterNonVideo(next);
    this.filterNonVideo = next;
    this.sourceList = config.getSources();
    this.currentSourceKey = config.getHomeSourceKey();
    promptAction.showToast({ message: next ? '已开启：过滤小说/听书等非视频' : '已关闭：显示全部' } as ToastOptions);
  }

  openSourceDialog(): void {
    this.closeOtherPopups('source');
    this.showSourceDialog = true;
  }

  getSourceFilterSubtitle(): string {
    const kws: string[] = getApiConfig().getSourceFilterKeywords();
    if (!this.filterNonVideo) return '按关键字过滤，未开启';
    if (kws.length === 0) return '已开启，未设置关键字';
    return '已开启：' + kws.join(' ');
  }

  openSourceFilterDialog(): void {
    this.closeOtherPopups('sourceFilter');
    this.inputFilterNonVideo = this.filterNonVideo;
    this.inputSourceFilterKeywords = this.sourceFilterKeywords;
    this.showSourceFilterDialog = true;
  }

  async saveSourceFilterDialog(): Promise<void> {
    const config = getApiConfig();
    const kwText: string = this.inputSourceFilterKeywords.trim();
    await config.setSourceFilterKeywords(kwText);
    this.sourceFilterKeywords = kwText;
    if (this.filterNonVideo !== this.inputFilterNonVideo) {
      await config.setFilterNonVideo(this.inputFilterNonVideo);
      this.filterNonVideo = this.inputFilterNonVideo;
    }
    this.sourceList = config.getSources();
    this.currentSourceKey = config.getHomeSourceKey();
    this.showSourceFilterDialog = false;
    promptAction.showToast({ message: this.filterNonVideo ? (kwText.length > 0 ? '源过滤已开启' : '已开启，未设置关键字') : '源过滤已关闭' } as ToastOptions);
  }

  /** 空源过滤 */
  getEmptySourceSubtitle(): string {
    if (!this.hideEmptySources) return '一键检测并隐藏无资源的';
    if (this.emptyKeysCount === 0) return '未检测，点击弹窗立即检测';
    return '已隐藏' + this.emptyKeysCount + ' 个空源';
  }

  openEmptySourceDialog(): void {
    this.closeOtherPopups('emptySource');
    const cfg = getApiConfig();
    this.hideEmptySources = cfg.isHideEmptySources();
    this.emptyKeysCount = cfg.getEmptySourceKeys().length;
    this.probing = false;
    this.probeDone = 0;
    this.probeTotal = 0;
    this.probeFoundEmpty = 0;
    this.showEmptySourceDialog = true;
  }

  async toggleHideEmptySources(on: boolean): Promise<void> {
    const cfg = getApiConfig();
    await cfg.setHideEmptySources(on);
    this.hideEmptySources = on;
    this.sourceList = cfg.getSources();
    this.currentSourceKey = cfg.getHomeSourceKey();
  }

  async runProbeEmptySources(): Promise<void> {
    if (this.probing) return;
    const cfg = getApiConfig();
    this.probing = true;
    try {
      await cfg.probeEmptySources();
    } finally {
      this.probing = false;
      this.emptyKeysCount = cfg.getEmptySourceKeys().length;
      this.sourceList = cfg.getSources();
      this.currentSourceKey = cfg.getHomeSourceKey();
    }
    promptAction.showToast({ message: '检测完成，发现 ' + this.emptyKeysCount + ' 个空源' } as ToastOptions);
  }

  async clearEmptySourceCache(): Promise<void> {
    const cfg = getApiConfig();
    await cfg.clearEmptySourceKeys();
    this.emptyKeysCount = 0;
    this.sourceList = cfg.getSources();
    promptAction.showToast({ message: '已清除空源标记' } as ToastOptions);
  }

  openLiveDialog(): void {
    this.closeOtherPopups('live');
    this.inputLiveUrl = this.liveUrl;
    this.editingLiveIndex = -1;
    this.showLiveDialog = true;
  }

  openParseDialog(): void {
    this.closeOtherPopups('parse');
    this.showParseDialog = true;
  }

  async openSortDialog(): Promise<void> {
    this.closeOtherPopups('sort');
    this.showSortDialog = true;
    this.sortLoading = true;
    this.sortCategories = [];
    try {
      const homeKey: string = getApiConfig().getHomeSourceKey();
      const result = await SourceViewModel.getHomeContent(homeKey);
      const all: SortData[] = result.sort.sortList;
      // 首个分类(推荐/豆瓣)不参与排序
      let rest: SortData[] = all.length > 1 ? all.slice(1) : [];
      const orderStr: string = PreferencesUtil.getSync('home_sort_' + homeKey, '');
      if (orderStr.length > 0 && rest.length > 1) {
        const orderIds: string[] = orderStr.split(',');
        rest = applyCustomOrder(rest, orderIds);
      }
      this.sortCategories = rest;
    } catch (e) {
      promptAction.showToast({ message: '加载分类失败: ' + formatError(e) } as ToastOptions);
    }
    this.sortLoading = false;
  }

  moveSortItem(index: number, delta: number): void {
    const target: number = index + delta;
    if (target < 0 || target >= this.sortCategories.length) {
      return;
    }
    const arr: SortData[] = this.sortCategories.slice();
    const tmp: SortData = arr[index];
    arr[index] = arr[target];
    arr[target] = tmp;
    this.sortCategories = arr;
  }

  async saveSortOrder(): Promise<void> {
    const homeKey: string = getApiConfig().getHomeSourceKey();
    const ids: string[] = this.sortCategories.map((sd: SortData): string => sd.id);
    await PreferencesUtil.put('home_sort_' + homeKey, ids.join(','));
    this.showSortDialog = false;
    promptAction.showToast({ message: '已保存，重进首页生效' } as ToastOptions);
  }

  /** 尝试加载单个 URL，失败重试 3 次 */
  private async tryLoadOnce(url: string): Promise<boolean> {
    for (let i = 0; i < 3; i++) {
      try {
        const ok: boolean = await getApiConfig().loadConfig(url);
        if (ok) return true;
      } catch (_e) {
      }
      await new Promise<void>((resolve): void => { setTimeout(resolve, 1000); });
    }
    return false;
  }

  /** 加载配置 */
  async loadConfig(explicitUrl?: string): Promise<void> {
    const raw: string = (explicitUrl !== undefined ? explicitUrl : this.inputConfigUrl);
    // 按换行拆分为多个配置地址
    const rawParts: string[] = raw.split('\n');
    const urls: string[] = [];
    for (const p of rawParts) {
      const t: string = p.trim();
      if (t.length > 0 && urls.indexOf(t) < 0) urls.push(t);
    }
    if (urls.length === 0) {
      promptAction.showToast({ message: '请输入配置地址' } as ToastOptions);
      return;
    }
    if (urls.length > 10) {
      promptAction.showToast({ message: '配置地址最多 10 条，当前 ' + urls.length + ' 条，请删除多余地址' } as ToastOptions);
      return;
    }
    // 内置源地址强制隐藏：仅由"默认源"开关控制，不提供手动填写
    if (urls.length === 1 && urls[0].startsWith('builtin://')) {
      promptAction.showToast({ message: '内置源已移除，请用「导入本地文件」或填写订阅网址' } as ToastOptions);
      return;
    }
    this.loading = true;
    try {
      let successUrl: string = '';
      if (urls.length > 1) {
        // 多配置聚合模式
        const ok: boolean = await getApiConfig().loadConfigs(urls);
        if (ok) {
          successUrl = urls.join('\n');
          this.failedConfigUrls = getApiConfig().getLastFailedConfigUrls();
          await PreferencesUtil.put('failed_config_urls', JSON.stringify(this.failedConfigUrls));
        }
      } else {
        // 单配置模式：备选队列 + 失效自动切换
        const single: string = urls[0];
        const queue: string[] = [single];
        if (this.historyAutoSwitch) {
          for (const h of this.historyList) {
            if (h !== single && queue.indexOf(h) < 0) queue.push(h);
          }
        }
        const failedInSingle: string[] = [];
        for (const candidate of queue) {
          const ok: boolean = await this.tryLoadOnce(candidate);
          if (ok) { successUrl = candidate; break; }
          failedInSingle.push(candidate);
          if (this.historyAutoSwitch && queue.length > 1) {
            promptAction.showToast({ message: '尝试下一个历史地址' } as ToastOptions);
          }
        }
        if (successUrl.length > 0) {
          this.failedConfigUrls = failedInSingle;
          await PreferencesUtil.put('failed_config_urls', JSON.stringify(this.failedConfigUrls));
        }
      }
      if (successUrl.length > 0) {
        const config = getApiConfig();
        this.configUrl = successUrl;
        this.inputConfigUrl = successUrl;
        await PreferencesUtil.put('config_url', successUrl);
        // 多配置时为每个地址保存历史
        if (urls.length > 1) {
          for (const u of urls) {
            await this.saveHistory(u);
          }
        } else {
          await this.saveHistory(successUrl);
        }
        this.sourceList = config.getSources();
        this.currentSourceKey = config.getHomeSourceKey();
        this.filterNonVideo = config.isFilterNonVideo();
        this.sourceFilterKeywords = config.getSourceFilterKeywordsRaw();
        this.parseList = config.getParseBeanList();
        // 默认选中自动解析
        for (let i = 0; i < this.parseList.length; i++) {
          if (this.parseList[i].type === -1) {
            this.parseList[i].isDefault = true;
          }
        }
        const liveFromConfig: string = config.getLiveUrl();
        if (liveFromConfig.length > 0) {
          this.liveUrl = liveFromConfig;
          this.inputLiveUrl = liveFromConfig;
          await PreferencesUtil.put('live_url', liveFromConfig);
          await this.saveLiveHistory(liveFromConfig);
        }
        // 填写外部配置URL后强制自动关闭内置源开关（可手动重开；新配置无直播源时直播开关可不强制关）
        await config.setBuiltinSourceEnabled(false);
        this.useBuiltinSource = false;
        if (liveFromConfig.length > 0 && !liveFromConfig.startsWith('builtin://')) {
          await config.setBuiltinLiveEnabled(false);
          this.useBuiltinLive = false;
        }
        this.showConfigUrlDialog = false;
        this.showHistoryDialog = false;
        promptAction.showToast({ message: '配置加载成功' } as ToastOptions);
        setTimeout((): void => {
          router.back({ url: 'tvbox/pages/HomePage' });
        }, 500);
      } else {
        promptAction.showToast({ message: '配置加载失败' } as ToastOptions);
      }
    } catch (e) {
      promptAction.showToast({ message: formatError(e) } as ToastOptions);
      hilog.error(DOMAIN, TAG, 'loadConfig failed: %{public}s', formatError(e));
    } finally {
      this.loading = false;
    }
  }

  /** 配置地址弹窗里的「导入本地文件」：选一个 JSON 直接生效，等价于填网址 */
  private importConfigFile(): void {
    if (this.loading) {
      return;
    }
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      docPicker.select(options).then((uris: string[]): void => {
        if (uris.length === 0) {
          return;
        }
        this.applyConfigFile(uris[0]).then((): void => {}).catch((): void => {});
      }).catch((err: BusinessError): void => {
        hilog.info(DOMAIN, TAG, 'config file picker ended: %{public}s', err.message);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'open config file picker failed: %{public}s', JSON.stringify(e));
      promptAction.showToast({ message: '打不开文件选择器' } as ToastOptions);
    }
  }

  /** 读取选中的配置文件并按其内容加载（TVBox 标准 JSON），成功后刷新源列表并回首页 */
  private async applyConfigFile(uri: string): Promise<void> {
    this.loading = true;
    try {
      const text: string = this.readConfigText(uri);
      if (text.trim().length === 0) {
        throw new Error('文件是空的，请选择 TVBox 标准 JSON 配置文件');
      }
      const ok: boolean = await getApiConfig().loadConfigFromText(text);
      if (!ok) {
        throw new Error('配置解析失败，请确认文件是 TVBox 标准 JSON');
      }
      const config = getApiConfig();
      this.configUrl = 'local://config_file';
      this.inputConfigUrl = '';
      this.sourceList = config.getSources();
      this.currentSourceKey = config.getHomeSourceKey();
      this.filterNonVideo = config.isFilterNonVideo();
      this.sourceFilterKeywords = config.getSourceFilterKeywordsRaw();
      this.parseList = config.getParseBeanList();
      for (let i = 0; i < this.parseList.length; i++) {
        if (this.parseList[i].type === -1) {
          this.parseList[i].isDefault = true;
        }
      }
      // 本地文件导入即用户的配置，内置源概念不再参与
      this.useBuiltinSource = false;
      const liveFromConfig: string = config.getLiveUrl();
      if (liveFromConfig.length > 0) {
        this.liveUrl = liveFromConfig;
        this.inputLiveUrl = liveFromConfig;
        await PreferencesUtil.put('live_url', liveFromConfig);
        await this.saveLiveHistory(liveFromConfig);
      }
      this.showConfigUrlDialog = false;
      promptAction.showToast({ message: '本地配置已生效，共 ' + this.sourceList.length + ' 个源' } as ToastOptions);
      setTimeout((): void => {
        router.back({ url: 'tvbox/pages/HomePage' });
      }, 500);
    } catch (e) {
      promptAction.showToast({ message: formatError(e) } as ToastOptions);
      hilog.error(DOMAIN, TAG, 'applyConfigFile failed: %{public}s', formatError(e));
    } finally {
      this.loading = false;
    }
  }

  /** 读整份配置文本（picker 给的是 file://docs/... 的 uri，openSync 可直接打开） */
  private readConfigText(uri: string): string {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      if (stat.size <= 0) {
        return '';
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const readLen: number = fileIo.readSync(file.fd, buffer);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buffer.slice(0, readLen)));
    } finally {
      if (file !== null) {
        fileIo.closeSync(file);
      }
    }
  }

  /** 保存直播地址 */
  async saveLiveUrl(): Promise<void> {
    const url: string = this.inputLiveUrl.trim();
    this.liveUrl = url;
    await PreferencesUtil.put('live_url', url);
    // 换直播源时清空上次频道位置
    await PreferencesUtil.putInt('live_group_index', 0);
    await PreferencesUtil.putInt('live_channel_index', 0);
    await PreferencesUtil.put('live_last_url_for_index', url);
    await this.saveLiveHistory(url);
    const config = getApiConfig();
    config.setLiveUrl(url);
    this.showLiveDialog = false;
    promptAction.showToast({ message: '直播地址已保存' } as ToastOptions);
  }

  /** 选择源 */
  async selectSource(key: string): Promise<void> {
    const config = getApiConfig();
    await config.setHomeSource(key);
    config.clearSpider(key);
    this.currentSourceKey = key;
    this.showSourceDialog = false;
    promptAction.showToast({ message: '已切换源' } as ToastOptions);
  }

  /** 选择解析接口 */
  selectParse(name: string): void {
    for (const pb of this.parseList as ParseBean[]) {
      pb.isDefault = pb.name === name;
    }
    this.parseList = this.parseList.slice();
    this.showParseDialog = false;
    getApiConfig().setDefaultParseByName(name).then((): void => {}).catch((): void => {});
    promptAction.showToast({ message: '已切换解析' } as ToastOptions);
  }

  /** 返回主页 */
  goHome(): void {
    router.back();
  }

  private async cycleTheme(): Promise<void> {
    const order: ThemeMode[] = ['system', 'light', 'dark'];
    const next: ThemeMode = order[(order.indexOf(this.themeMode) + 1) % order.length];
    this.themeMode = next;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await ThemeManager.applyMode(ctx, next);
  }

  private async cycleOrient(): Promise<void> {
    const order: OrientMode[] = ['system', 'landscape', 'portrait'];
    const next: OrientMode = order[(order.indexOf(this.orientMode) + 1) % order.length];
    this.orientMode = next;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await OrientationManager.applyMode(ctx, next);
  }

  private async setThemeByIndex(index: number): Promise<void> {
    const order: ThemeMode[] = ['system', 'light', 'dark'];
    if (index < 0 || index >= order.length) { return; }
    const next: ThemeMode = order[index];
    this.themeMode = next;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await ThemeManager.applyMode(ctx, next);
  }

  private async setOrientByIndex(index: number): Promise<void> {
    const order: OrientMode[] = ['system', 'landscape', 'portrait'];
    if (index < 0 || index >= order.length) { return; }
    const next: OrientMode = order[index];
    this.orientMode = next;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await OrientationManager.applyMode(ctx, next);
  }

  // 分组卡片内的一行：主标题 + 副标题 + 右侧(胶囊下拉 / 箭头)
  @Builder
  SettingRow(p: NavRowParam) {
    Row() {
      Column({ space: 3 }) {
        Text(p.label)
          .fontSize(DS.bodyFont(this.bp))
          .fontColor(Palette.textPrimary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (p.subtitle.length > 0) {
          Text(p.subtitle)
            .fontSize(DS.smallFont(this.bp))
            .fontColor(Palette.textSecondary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (p.isPill) {
        Row() {
          Text(p.value)
            .fontSize(DS.smallFont(this.bp))
            .fontColor(Palette.textPrimary(this.isDark))
            .maxLines(1)
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(16)
            .constraintSize({ minWidth: 12, minHeight: 12 })
            .fontColor([Palette.textSecondary(this.isDark)])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .margin({ left: 6 })
        }
        .padding({ left: 14, right: 14, top: 7, bottom: 7 })
        .backgroundColor(this.isDark ? '#2C2C2E' : '#E9EAEE')
        .borderRadius(16)
      } else {
        Text(p.value)
          .fontSize(DS.smallFont(this.bp))
          .fontColor(Palette.textSecondary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: isWide(this.bp) ? 260 : 150 })
          .margin({ right: 6 })
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([Palette.textTertiary(this.isDark)])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      }
    }
    .width('100%')
    .height(DS.settingRowHeight(this.bp))
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => p.action())
  }

  @Builder
  AboutRow() {
    Row() {
      Text('版本')
        .fontSize(DS.bodyFont(this.bp))
        .fontColor(Palette.textPrimary(this.isDark))
        .maxLines(1)
        .layoutWeight(1)
      Text(this.appVersion)
        .fontSize(DS.bodyFont(this.bp))
        .fontColor(Palette.textSecondary(this.isDark))
        .maxLines(1)
    }
    .width('100%')
    .height(DS.settingRowHeight(this.bp))
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  // 带右侧 Toggle 开关的设置行
  @Builder
  SettingToggleRow(p: ToggleRowParam) {
    Row() {
      Column({ space: 3 }) {
        Text(p.label)
          .fontSize(DS.bodyFont(this.bp))
          .fontColor(Palette.textPrimary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (p.subtitle.length > 0) {
          Text(p.subtitle)
            .fontSize(DS.smallFont(this.bp))
            .fontColor(Palette.textSecondary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: p.isOn })
        .selectedColor(Palette.accent())
        .switchPointColor('#FFFFFF')
        .onChange((v: boolean): void => { p.onChange(v); })
    }
    .width('100%')
    .height(DS.settingRowHeight(this.bp))
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  // 带下拉菜单选择的设置行（点击弹出选项）
  @Builder
  SettingSelectRow(p: SelectRowParam) {
    Row() {
      Column({ space: 3 }) {
        Text(p.label)
          .fontSize(DS.bodyFont(this.bp))
          .fontColor(Palette.textPrimary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (p.subtitle.length > 0) {
          Text(p.subtitle)
            .fontSize(DS.smallFont(this.bp))
            .fontColor(Palette.textSecondary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row() {
        Text(p.value)
          .fontSize(DS.smallFont(this.bp))
          .fontColor(Palette.textPrimary(this.isDark))
          .maxLines(1)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(16)
          .constraintSize({ minWidth: 12, minHeight: 12 })
          .fontColor([Palette.textSecondary(this.isDark)])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .margin({ left: 6 })
      }
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .backgroundColor(this.isDark ? '#2C2C2E' : '#E9EAEE')
      .borderRadius(16)
      .clickEffect({ level: ClickEffectLevel.LIGHT })
      .bindMenu(this.buildMenuElements(p.options, p.value, p.onSelect))
    }
    .width('100%')
    .height(DS.settingRowHeight(this.bp))
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  SelectMenu(options: string[], current: string, onSelect: (index: number) => void) {
    // 自定义弹出菜单，跟随应用深色/浅色模式
    Column() {
      ForEach(options, (opt: string, index: number) => {
        Row() {
          Text(opt)
            .fontSize(14)
            .fontColor(opt === current ? Palette.accent() : Palette.textPrimary(this.isDark))
            .fontWeight(opt === current ? FontWeight.Bold : FontWeight.Normal)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (opt === current) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(16)
              .fontColor([Palette.accent()])
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              .margin({ left: 8 })
          }
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .clickEffect({ level: ClickEffectLevel.LIGHT })
        .onClick((): void => { onSelect(index); })
      }, (opt: string, index: number): string => opt + index)
    }
    .constraintSize({ minWidth: 160 })
    .backgroundColor(Palette.surface(this.isDark))
    .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .border({ width: 1, color: Palette.glassBorder(this.isDark) })
    .borderRadius(12)
    .padding({ top: 4, bottom: 4 })
    .shadow({ radius: 16, color: '#40000000', offsetX: 0, offsetY: 4 })
  }

  private buildMenuElements(options: string[], current: string, onSelect: (index: number) => void): MenuElement[] {
    const list: MenuElement[] = [];
    for (let i = 0; i < options.length; i++) {
      const idx: number = i;
      list.push({
        value: options[i],
        action: (): void => { onSelect(idx); }
      } as MenuElement);
    }
    return list;
  }

  @Builder
  DragPreviewBox(label: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(Palette.textPrimary(this.isDark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width(260)
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .borderRadius(10)
    .backgroundColor(this.isDark ? '#3A3A3C' : '#F1F1F4')
    .shadow({ radius: 12, color: '#33000000', offsetX: 0, offsetY: 4 })
  }

  @Builder
  HistoryDragPreview(index: number) {
    this.DragPreviewBox(this.historyEditList[index] || '')
  }

  @Builder
  SortDragPreview(index: number) {
    this.DragPreviewBox(this.sortCategories[index] ? this.sortCategories[index].name : '')
  }

  @Builder
  RowDivider() {
    Divider()
      .strokeWidth(0.5)
      .color(Palette.border(this.isDark))
      .margin({ left: 16, right: 16 })
  }

  @Builder
  DialogMask(onClose: () => void) {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('#80000000')
      .onClick(() => onClose())
  }

  @Builder
  GroupTitle(t: string) {
    Text(t)
      .fontSize(DS.smallFont(this.bp))
      .fontColor(Palette.textSecondary(this.isDark))
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .textAlign(TextAlign.Center)
      .margin({ bottom: 8, top: 4 })
  }

  /** TV 设置的「数据」组内容；embedded 时被主设置页平铺复用，不再自带滚动 */
  @Builder
  tvDataColumn() {
    Column() {
            if (this.emptyProbing || this.emptyProbeShowResult) {
              Row() {
                Text(this.emptyProbing
                  ? ('正在检测空源…' + this.emptyProbeDone + '/' + this.emptyProbeTotal + '，已发现 ' + this.emptyProbeFound + ' 个，请勿退出应用')
                  : ('检测完成，共发现 ' + this.emptyProbeFound + ' 个空源'))
                  .fontSize(12)
                  .fontColor(Palette.textPrimary(this.isDark))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .padding({ left: 20, right: 20, top: 8, bottom: 8 })
              .backgroundColor(Palette.glass(this.isDark))
              .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
              .border({ width: { bottom: 0.5 }, color: Palette.glassBorder(this.isDark) })
              .margin({ bottom: 12 })
              .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -8 })).animation({ duration: 220, curve: Curve.EaseOut }))
            }
            // 数据
            if (!this.embedded) {
              this.GroupTitle('数据')
            }
            Column() {
              this.SettingRow({ label: '配置地址', subtitle: '订阅配置的URL', value: this.getConfigUrlDisplay(), isPill: false, action: (): void => { this.openConfigUrlDialog(); } })
              this.RowDivider()
              this.SettingRow({ label: '直播地址', subtitle: '直播源URL', value: this.getLiveUrlDisplay(), isPill: false, action: (): void => { this.openLiveDialog(); } })
              this.RowDivider()
              this.SettingRow({ label: '配置历史', subtitle: '已保存的配置地址', value: this.historyList.length > 0 ? this.historyList.length + '条' : '', isPill: false, action: (): void => { this.openHistoryDialog(); } })
              this.RowDivider()
              this.SettingRow({ label: '源过滤', subtitle: this.getSourceFilterSubtitle(), value: this.filterNonVideo ? '已开启' : '未开启', isPill: false, action: (): void => { this.openSourceFilterDialog(); } })
              this.RowDivider()
              this.SettingRow({ label: '空源过滤', subtitle: this.getEmptySourceSubtitle(), value: this.hideEmptySources ? '已开启' : '未开启', isPill: false, action: (): void => { this.openEmptySourceDialog(); } })
              this.RowDivider()
              this.SettingRow({ label: '首页排序', subtitle: '自定义首页分类顺序', value: '点击配置', isPill: false, action: (): void => { this.openSortDialog(); } })
              this.RowDivider()
              this.SettingRow({ label: '网盘配置', subtitle: '阿里 / 夸克 / UC / 115 / 百度 凭证', value: '进入配置', isPill: false, action: (): void => { router.pushUrl({ url: 'tvbox/pages/PanConfigPage' }); } })
              this.RowDivider()
              this.SettingRow({ label: '解析接口', subtitle: '播放解析线路', value: this.getCurrentParseName(), isPill: false, action: (): void => { this.openParseDialog(); } })
            }
            .backgroundColor(this.embedded ? Color.Transparent : Palette.surface(this.isDark))
            .borderRadius(this.embedded ? 0 : 16)
            .margin({
              left: this.embedded ? 0 : 20,
              right: this.embedded ? 0 : 20,
              bottom: this.embedded ? 0 : 18
            })

            // 底部留白
            Column()
              .width('100%')
              .height(40)
    }
    .width('100%')
    .padding({ top: this.embedded ? 0 : 12, bottom: this.embedded ? 0 : 20 + this.bottomSafe })
    .constraintSize({ maxWidth: this.embedded ? 10000 : (isWide(this.bp) ? 680 : 10000) })
  }

  build() {
    Stack() {
      Column() {
        // 顶部导航栏
        Stack({ alignContent: Alignment.Center }) {
          // 居中标题层：使用绝对居中；下沉一点以避让平板挖孔摄像头
          Text('设置')
            .fontSize(DS.bodyFont(this.bp) + 2)
            .fontColor(Palette.textPrimary(this.isDark))
            .fontWeight(FontWeight.Bold)
            .textAlign(TextAlign.Center)
            .padding({ top: 6 })
            .animation({ duration: 200, curve: Curve.EaseOut })

          // 返回按钮层：左对齐
          Row() {
            Row() {
              SymbolGlyph($r('sys.symbol.chevron_left'))
                // 云测规则 7.1.1.4.4：图标宽/高不得小于 8vp（推荐 12vp）。chevron_left 字形窄，
                // fontSize 15 时实测仅 7*15vp → 不通过；这里兜到 16 并给最小尺寸约束。
                .fontSize(Math.max(DS.bodyFont(this.bp) + 4, 16))
                .constraintSize({ minWidth: 12, minHeight: 12 })
                .fontColor([Palette.accent()])
                .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              Text('返回')
                .fontSize(DS.smallFont(this.bp) + 2)
                .fontColor(Palette.textPrimary(this.isDark))
                .margin({ left: 2 })
            }
            .padding({ left: Math.max(this.leftSafe, 16) })
            .alignItems(VerticalAlign.Center)
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .animation({ duration: 200, curve: Curve.EaseOut })
            .onClick(() => { this.goHome(); })
            Blank()
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .height(this.embedded ? 0 : DS.topBarHeight(this.bp) + 6 + this.topSafe)
        .padding({ top: this.embedded ? 0 : this.topSafe })
        .alignContent(Alignment.Center)
        .visibility(this.embedded ? Visibility.None : Visibility.Visible)

        if (this.embedded) {
          this.tvDataColumn()
        } else {
          Scroll() {
            this.tvDataColumn()
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%')
      .height(this.embedded ? 'auto' : '100%')
      .padding({ left: Math.max(this.leftSafe, this.rightSafe), right: Math.max(this.leftSafe, this.rightSafe) })
      .backgroundColor(this.embedded ? Color.Transparent : Palette.bg(this.isDark))

      // ========== 配置地址对话框 ==========
      if (this.showConfigUrlDialog) {
        Stack() {
          this.DialogMask((): void => { this.showConfigUrlDialog = false; })
          Column() {
            Text('配置地址')
              .fontSize(18)
              .fontColor(Palette.textPrimary(this.isDark))
              .fontWeight(FontWeight.Bold)
              .margin({ bottom: 16 })

            TextArea({ text: this.inputConfigUrl, placeholder: '可输入多个配置地址，每行一个（最多 10 条），将聚合所有源' })
              .width('100%')
              .height(110)
              .fontSize(14)
              .fontColor(Palette.textPrimary(this.isDark))
              .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
              .borderRadius(8)
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .copyOption(CopyOptions.LocalDevice)
              .onChange((val: string): void => {
                this.inputConfigUrl = val;
              })

            Text('每行一个配置地址（最多 10 条），加载后合并所有源')
              .fontSize(DS.smallFont(this.bp) - 1)
              .fontColor(Palette.textTertiary(this.isDark))
              .width('100%')
              .margin({ top: 8 })

            if (this.failedConfigUrls.length > 0 && this.getConfigUrlLines().length > 0) {
              Scroll() {
                Column() {
                  ForEach(this.getConfigUrlLines(), (url: string, index: number) => {
                    Row() {
                      Text(this.isFailedUrl(url) ? '✕ 失效' : '✓ 正常')
                        .fontSize(11)
                        .fontColor(this.isFailedUrl(url) ? '#FF453A' : '#34C759')
                        .width(52)
                      Text(url.length > 42 ? url.substring(0, 42) + '...' : url)
                        .fontSize(12)
                        .fontColor(this.isFailedUrl(url) ? '#FF453A' : Palette.textSecondary(this.isDark))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                    }
                    .width('100%')
                    .margin({ top: 4 })
                  }, (url: string, index: number): string => 'cfg_status_' + index + '_' + url)
                }
                .width('100%')
              }
              .width('100%')
              .height(80)
              .margin({ top: 8 })
              .scrollBar(BarState.Off)
              .edgeEffect(EdgeEffect.Spring)

              Row() {
                Blank()
                Button('删除失效地址')
                  .fontSize(12)
                  .fontColor('#FF453A')
                  .backgroundColor((this.isDark ? '#33FF453A' : '#1AFF453A'))
                  .borderRadius(8)
                  .height(32)
                  .onClick(() => { this.removeFailedUrls(); })
              }
              .width('100%')
              .margin({ top: 4 })
            }

            if (this.loading) {
              LoadingProgress()
                .width(28)
                .height(28)
                .color(Palette.textPrimary(this.isDark))
                .margin({ top: 16 })
            }

            Row() {
              Button('导入本地文件')
                .fontSize(14)
                .fontColor(Palette.accent())
                .backgroundColor((this.isDark ? '#332F6BE0' : '#1A2F6BE0'))
                .borderRadius(8)
                .layoutWeight(1)
                .height(40)
                .enabled(!this.loading)
                .onClick(() => { this.importConfigFile(); })
            }
            .width('100%')
            .margin({ top: 12 })

            Text('也可以选本机上的 TVBox 标准 JSON 配置文件，导入后立即生效，下次启动无需再选')
              .fontSize(DS.smallFont(this.bp) - 1)
              .fontColor(Palette.textTertiary(this.isDark))
              .width('100%')
              .margin({ top: 6 })

            Row() {
              Button('取消')
                .fontSize(14)
                .fontColor(Palette.textPrimary(this.isDark))
                .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
                .borderRadius(8)
                .layoutWeight(1)
                .height(40)
                .onClick(() => { this.showConfigUrlDialog = false; })

              Button('加载')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Palette.textPrimary(this.isDark))
                .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
                .borderRadius(8)
                .layoutWeight(1)
                .height(40)
                .margin({ left: 12 })
                .enabled(!this.loading)
                .onClick(() => { this.loadConfig(); })
            }
            .width('100%')
            .margin({ top: 20 })
          }
          .width('80%')
          .constraintSize({ maxWidth: DS.dialogMaxWidth(this.bp) })
          .padding(20)
          .backgroundColor(Palette.surface(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .borderRadius(20)
          .margin({ bottom: this.keyboardHeight > 0 ? this.keyboardHeight / 2 : 0 })
        }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.94, y: 0.94 })).animation({ duration: 220, curve: Curve.EaseOut }))
      }

      // ========== 配置历史对话框（可编辑 + 拖动排序 + 失效自动切换） ==========
      if (this.showHistoryDialog) {
        Stack() {
          this.DialogMask((): void => { this.showHistoryDialog = false; })
          Column() {
            Text('配置历史')
              .fontSize(18)
              .fontColor(Palette.textPrimary(this.isDark))
              .fontWeight(FontWeight.Bold)
              .margin({ bottom: 6 })
            Text('每行一个配置地址，不限数量')
              .fontSize(12)
              .fontColor(Palette.textSecondary(this.isDark))
              .margin({ bottom: 12 })

            // 失效自动切换开启
            Row() {
              Column() {
                Text('失效自动切换')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Palette.textPrimary(this.isDark))
                Text('当前地址失效时，自动从历史配置地址替换')
                  .fontSize(11)
                  .fontColor(Palette.textSecondary(this.isDark))
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.historyAutoSwitch })
                .selectedColor(Palette.accent())
                .onChange((v: boolean): void => { this.toggleHistoryAutoSwitch(v); })
            }
            .width('100%')
            .padding({ top: 10, bottom: 10, left: 12, right: 8 })
            .borderRadius(10)
            .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
            .margin({ bottom: 12 })

            TextArea({ text: this.inputHistoryUrls, placeholder: '每行一个配置地址，将作为失效自动切换的备选' })
              .width('100%')
              .height(120)
              .fontSize(14)
              .fontColor(Palette.textPrimary(this.isDark))
              .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
              .borderRadius(8)
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .copyOption(CopyOptions.LocalDevice)
              .onChange((val: string): void => { this.inputHistoryUrls = val; })

            Row() {
              Button('取消')
                .fontSize(14)
                .fontColor(Palette.textPrimary(this.isDark))
                .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
                .borderRadius(8)
                .layoutWeight(1)
                .height(40)
                .onClick(() => { this.showHistoryDialog = false; })
              Button('保存')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Palette.textPrimary(this.isDark))
                .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
                .borderRadius(8)
                .layoutWeight(1)
                .height(40)
                .margin({ left: 12 })
                .onClick(() => { this.saveHistoryEdit(); this.showHistoryDialog = false; })
            }
            .width('100%')
            .margin({ top: 14 })
          }
          .width('86%')
          .constraintSize({ maxWidth: DS.dialogMaxWidth(this.bp) })
          .padding({ left: 16, right: 16, top: 20, bottom: 16 })
          .margin({ bottom: this.keyboardHeight > 0 ? this.keyboardHeight / 2 : 0 })
          .backgroundColor(Palette.surface(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .borderRadius(20)
        }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.94, y: 0.94 })).animation({ duration: 220, curve: Curve.EaseOut }))
      }

      // ========== 源选择对话框 ==========
      if (this.showSourceDialog) {
        Stack() {
          this.DialogMask((): void => { this.showSourceDialog = false; })
          Column() {
            Text('选择源(' + this.sourceList.length + ')')
              .fontSize(18)
              .fontColor(Palette.textPrimary(this.isDark))
              .fontWeight(FontWeight.Bold)
              .margin({ bottom: 16 })

            if (this.sourceList.length === 0) {
              Text('暂无可用源，请先加载配置')
                .fontSize(14)
                .fontColor(Palette.textSecondary(this.isDark))
                .margin({ top: 20, bottom: 20 })
            } else {
              Scroll() {
                Column() {
                  ForEach(this.sourceList, (item: SourceBean, index: number) => {
                    Row() {
                      Text(item.name)
                        .fontSize(14)
                        .fontColor(Palette.textPrimary(this.isDark))
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })

                      if (item.key === this.currentSourceKey) {
                        SymbolGlyph($r('sys.symbol.checkmark'))
                          .fontSize(18)
                          .fontColor([Palette.accent()])
                          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                          .margin({ left: 8 })
                      }
                    }
                    .width('100%')
                    .padding({ top: 12, bottom: 12, left: 12, right: 12 })
                    .borderRadius(8)
                    .backgroundColor(item.key === this.currentSourceKey ? Palette.border(this.isDark) : (this.isDark ? '#2C2C2E' : '#E9EAEE'))
                    .margin({ bottom: 6 })
                    .onClick(() => { this.selectSource(item.key); })
                  }, (item: SourceBean, index: number): string => item.key + '_' + index)
                }
                .width('100%')
              }
              .layoutWeight(1)
              .constraintSize({ maxHeight: 350 })
            }

            Button('关闭')
              .fontSize(14)
              .fontColor(Palette.textPrimary(this.isDark))
              .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
              .borderRadius(8)
              .width('100%')
              .height(40)
              .margin({ top: 16 })
              .onClick(() => { this.showSourceDialog = false; })
          }
          .width('80%')
          .constraintSize({ maxWidth: DS.dialogMaxWidth(this.bp) })
          .padding(20)
          .backgroundColor(Palette.surface(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .borderRadius(20)
        }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.94, y: 0.94 })).animation({ duration: 220, curve: Curve.EaseOut }))
      }

      // ========== 源过滤对话框 ==========
      if (this.showSourceFilterDialog) {
        Stack() {
          this.DialogMask((): void => { this.showSourceFilterDialog = false; })
          Column() {
            Text('源过滤')
              .fontSize(18)
              .fontColor(Palette.textPrimary(this.isDark))
              .fontWeight(FontWeight.Bold)
              .margin({ bottom: 16 })

            Row() {
              Column({ space: 3 }) {
                Text('启用源过滤')
                  .fontSize(DS.bodyFont(this.bp))
                  .fontColor(Palette.textPrimary(this.isDark))
                Text('按关键字过滤源，搜索/切换源均生效')
                  .fontSize(DS.smallFont(this.bp))
                  .fontColor(Palette.textSecondary(this.isDark))
                  .maxLines(2)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.inputFilterNonVideo })
                .selectedColor(Palette.accent())
                .onChange((v: boolean): void => { this.inputFilterNonVideo = v; })
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
            .alignItems(VerticalAlign.Center)

            Text('过滤关键字')
              .fontSize(DS.smallFont(this.bp))
              .fontColor(Palette.textSecondary(this.isDark))
              .width('100%')
              .margin({ top: 8, bottom: 6 })

            TextArea({ text: this.inputSourceFilterKeywords, placeholder: '多个关键字用空格分隔，例如：小说 听书 音乐' })
              .width('100%')
              .height(96)
              .fontSize(14)
              .fontColor(Palette.textPrimary(this.isDark))
              .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
              .borderRadius(8)
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .copyOption(CopyOptions.LocalDevice)
              .onChange((val: string): void => { this.inputSourceFilterKeywords = val; })

            Text('命中任一关键字的源，将不会出现在搜索、切换源、选择源等位置')
              .fontSize(DS.smallFont(this.bp) - 1)
              .fontColor(Palette.textTertiary(this.isDark))
              .width('100%')
              .margin({ top: 8 })

            Row() {
              Button('取消')
                .fontSize(14)
                .fontColor(Palette.textPrimary(this.isDark))
                .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
                .borderRadius(8)
                .layoutWeight(1)
                .height(40)
                .margin({ right: 8 })
                .onClick(() => { this.showSourceFilterDialog = false; })
              Button('保存')
                .fontSize(14)
                .fontColor('#FFFFFF')
                .backgroundColor(Palette.accent())
                .borderRadius(8)
                .layoutWeight(1)
                .height(40)
                .onClick(() => { this.saveSourceFilterDialog(); })
            }
            .width('100%')
            .margin({ top: 16 })
          }
          .width('80%')
          .constraintSize({ maxWidth: DS.dialogMaxWidth(this.bp) })
          .padding(20)
          .backgroundColor(Palette.surface(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .borderRadius(20)
          .margin({ bottom: this.keyboardHeight > 0 ? this.keyboardHeight / 2 : 0 })
        }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.94, y: 0.94 })).animation({ duration: 220, curve: Curve.EaseOut }))
      }

      // ========== 空源过滤对话框 ==========
      if (this.showEmptySourceDialog) {
        Stack() {
          this.DialogMask((): void => { this.showEmptySourceDialog = false; })
          Column() {
            Text('空源过滤')
              .fontSize(18)
              .fontColor(Palette.textPrimary(this.isDark))
              .fontWeight(FontWeight.Bold)
              .margin({ bottom: 8 })
            Text('检测每个源是否能获取到资源，无返回的源会被隐藏，搜索时也不参与')
              .fontSize(12)
              .fontColor(Palette.textSecondary(this.isDark))
              .margin({ bottom: 16 })

            Row() {
              Text('隐藏无资源的源')
                .fontSize(14)
                .fontColor(Palette.textPrimary(this.isDark))
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.hideEmptySources })
                .onChange((on: boolean): void => {
                  this.toggleHideEmptySources(on).then((): void => {}).catch((): void => {});
                })
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })

            Text(this.emptyKeysCount > 0 ? ('已标记空源：' + this.emptyKeysCount + ' 个') : '尚未检测')
              .fontSize(13)
              .fontColor(Palette.textSecondary(this.isDark))
              .width('100%')
              .margin({ top: 6, bottom: 6 })

            if (this.probing || this.emptyProbing) {
              Text('检测中…' + this.emptyProbeDone + '/' + this.emptyProbeTotal + '，发现空源 ' + this.emptyProbeFound + ' 个，请勿退出应用')
                .fontSize(12)
                .fontColor(Palette.textSecondary(this.isDark))
                .width('100%')
                .margin({ top: 4, bottom: 4 })
            }

            Row() {
              Button((this.probing || this.emptyProbing) ? '检测中…' : '立即检测')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Palette.textPrimary(this.isDark))
                .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
                .borderRadius(8)
                .layoutWeight(1)
                .height(40)
                .enabled(!this.probing && !this.emptyProbing)
                .onClick(() => { this.runProbeEmptySources().then((): void => {}).catch((): void => {}); })

              Button('清除标记')
                .fontSize(14)
                .fontColor(Palette.textPrimary(this.isDark))
                .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
                .borderRadius(8)
                .layoutWeight(1)
                .height(40)
                .margin({ left: 8 })
                .enabled(!this.probing && !this.emptyProbing && this.emptyKeysCount > 0)
                .onClick(() => { this.clearEmptySourceCache().then((): void => {}).catch((): void => {}); })
            }
            .width('100%')
            .margin({ top: 10 })

            Button('关闭')
              .fontSize(14)
              .fontColor(Palette.textPrimary(this.isDark))
              .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
              .borderRadius(8)
              .width('100%')
              .height(40)
              .margin({ top: 10 })
              .onClick(() => { this.showEmptySourceDialog = false; })
          }
          .width('80%')
          .constraintSize({ maxWidth: DS.dialogMaxWidth(this.bp) })
          .padding(20)
          .backgroundColor(Palette.surface(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .borderRadius(20)
        }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.94, y: 0.94 })).animation({ duration: 220, curve: Curve.EaseOut }))
      }

      // ========== 直播地址对话框 ==========
      if (this.showLiveDialog) {
        Stack() {
          this.DialogMask((): void => { this.showLiveDialog = false; })
          Column() {
            Text('直播地址')
              .fontSize(18)
              .fontColor(Palette.textPrimary(this.isDark))
              .fontWeight(FontWeight.Bold)
              .margin({ bottom: 16 })

            TextInput({ text: this.inputLiveUrl, placeholder: '请输入直播地址' })
              .type(InputType.Normal)
              .enterKeyType(EnterKeyType.Done)
              .width('100%')
              .height(48)
              .fontSize(14)
              .fontColor(Palette.textPrimary(this.isDark))
              .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
              .borderRadius(8)
              .padding({ left: 12, right: 12 })
              .copyOption(CopyOptions.LocalDevice)
              .onChange((val: string): void => {
                this.inputLiveUrl = val;
              })

            if (this.liveHistoryList.length > 0) {
              Text('历史地址 (最多 5 条)')
                .fontSize(12)
                .fontColor(Palette.textSecondary(this.isDark))
                .width('100%')
                .margin({ top: 14, bottom: 8 })
              List({ space: 6 }) {
                ForEach(this.liveHistoryList.slice(0, 5), (item: string, index: number) => {
                  ListItem() {
                    Row() {
                      if (this.editingLiveIndex === index) {
                        TextInput({ text: item, placeholder: '直播地址' })
                          .type(InputType.Normal)
                          .fontSize(13)
                          .fontColor(Palette.textPrimary(this.isDark))
                          .placeholderColor(Palette.textSecondary(this.isDark))
                          .layoutWeight(1)
                          .height(38)
                          .backgroundColor(Color.Transparent)
                          .style(TextInputStyle.Inline)
                          .textAlign(TextAlign.Start)
                          .padding({ left: 4, right: 4, top: 8, bottom: 8 })
                          .caretColor(Palette.accent())
                          .copyOption(CopyOptions.LocalDevice)
                          .onChange((v: string): void => { this.updateLiveHistoryItem(index, v); })
                          .onSubmit((): void => {
                            this.getUIContext()?.animateTo({ duration: 180, curve: Curve.EaseOut }, () => { this.commitLiveHistoryEdit(); });
                          })
                      } else {
                        Text(item)
                          .fontSize(13)
                          .fontColor(Palette.textPrimary(this.isDark))
                          .layoutWeight(1)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .padding({ left: 4, top: 8, bottom: 8 })
                      }

                      Text('使用')
                        .fontSize(12)
                        .fontColor(Palette.textPrimary(this.isDark))
                        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                        .borderRadius(6)
                        .backgroundColor((this.isDark ? '#3A3A3C' : '#DDDEE1'))
                        .margin({ left: 6 })
                        .clickEffect({ level: ClickEffectLevel.LIGHT })
                        .onClick(() => {
                          this.getUIContext()?.animateTo({ duration: 180, curve: Curve.EaseOut }, () => { this.selectLiveHistoryUrl(this.liveHistoryList[index]); });
                        })

                      SymbolGlyph(this.editingLiveIndex === index ? $r('sys.symbol.checkmark') : $r('sys.symbol.square_and_pencil'))
                        .fontSize(18)
                        .fontColor([this.editingLiveIndex === index ? Palette.accent() : Palette.textSecondary(this.isDark)])
                        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                        .padding(6)
                        .margin({ left: 4 })
                        .animation({ duration: 180, curve: Curve.EaseOut })
                        .clickEffect({ level: ClickEffectLevel.LIGHT })
                        .onClick(() => {
                          this.getUIContext()?.animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
                            if (this.editingLiveIndex === index) { this.commitLiveHistoryEdit(); }
                            else { this.editingLiveIndex = index; }
                          });
                        })

                      SymbolGlyph($r('sys.symbol.trash'))
                        .fontSize(18)
                        .fontColor([Palette.textSecondary(this.isDark)])
                        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                        .padding(6)
                        .margin({ left: 4 })
                        .clickEffect({ level: ClickEffectLevel.LIGHT })
                        .onClick(() => {
                          this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.removeLiveHistoryItem(index); });
                        })
                    }
                    .width('100%')
                    .padding({ top: 4, bottom: 4, left: 10, right: 6 })
                    .borderRadius(10)
                    .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
                  }
                }, (item: string, index: number): string => 'lh' + index + '_' + item)
              }
              .listDirection(Axis.Vertical)
              .scrollBar(BarState.Off)
              .width('100%')
              .clip(false)
              .constraintSize({ maxHeight: 5 * 54 + 4 })
            }

            Row() {
              Button('取消')
                .fontSize(14)
                .fontColor(Palette.textPrimary(this.isDark))
                .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
                .borderRadius(8)
                .layoutWeight(1)
                .height(40)
                .onClick(() => { this.showLiveDialog = false; })

              Button('保存')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Palette.textPrimary(this.isDark))
                .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
                .borderRadius(8)
                .layoutWeight(1)
                .height(40)
                .margin({ left: 12 })
                .onClick(() => { this.saveLiveUrl(); })
            }
            .width('100%')
            .margin({ top: 20 })
          }
          .width('80%')
          .constraintSize({ maxWidth: DS.dialogMaxWidth(this.bp) })
          .padding(20)
          .backgroundColor(Palette.surface(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .borderRadius(20)
          .margin({ bottom: this.keyboardHeight > 0 ? this.keyboardHeight / 2 : 0 })
        }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.94, y: 0.94 })).animation({ duration: 220, curve: Curve.EaseOut }))
      }

      // ========== 解析接口对话框 ==========
      if (this.showParseDialog) {
        Stack() {
          this.DialogMask((): void => { this.showParseDialog = false; })
          Column() {
            Text('选择解析接口')
              .fontSize(18)
              .fontColor(Palette.textPrimary(this.isDark))
              .fontWeight(FontWeight.Bold)
              .margin({ bottom: 16 })

            if (this.parseList.length === 0) {
              Text('暂无解析接口')
                .fontSize(14)
                .fontColor(Palette.textSecondary(this.isDark))
                .margin({ top: 20, bottom: 20 })
            } else {
              Scroll() {
                Column() {
                  ForEach(this.parseList, (item: ParseBean, index: number) => {
                    Row() {
                      Column() {
                        Text(item.name)
                          .fontSize(14)
                          .fontColor(item.isDefault ? Palette.accent() : Palette.textPrimary(this.isDark))
                          .fontWeight(item.isDefault ? FontWeight.Bold : FontWeight.Normal)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        if (item.type === -1) {
                          Text('自动尝试所有解析器直到成功')
                            .fontSize(11)
                            .fontColor(Palette.textSecondary(this.isDark))
                            .margin({ top: 2 })
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                        }
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)

                      if (item.isDefault) {
                        SymbolGlyph($r('sys.symbol.checkmark'))
                          .fontSize(18)
                          .fontColor([Palette.accent()])
                          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                          .margin({ left: 8 })
                      }
                    }
                    .width('100%')
                    .padding({ top: 12, bottom: 12, left: 12, right: 12 })
                    .borderRadius(8)
                    .backgroundColor(item.isDefault ? Palette.border(this.isDark) : (this.isDark ? '#2C2C2E' : '#E9EAEE'))
                    .margin({ bottom: 6 })
                    .animation({ duration: 180, curve: Curve.EaseOut })
                    .clickEffect({ level: ClickEffectLevel.LIGHT })
                    .onClick(() => {
                      this.getUIContext()?.animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
                        this.selectParse(item.name);
                      });
                    })
                  }, (item: ParseBean, index: number): string => item.name + '_' + index)
                }
                .width('100%')
              }
              .layoutWeight(1)
              .constraintSize({ maxHeight: 350 })
              .scrollBar(BarState.Off)
            }

            Button('关闭')
              .fontSize(14)
              .fontColor(Palette.textPrimary(this.isDark))
              .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
              .borderRadius(8)
              .width('100%')
              .height(40)
              .margin({ top: 16 })
              .onClick(() => { this.showParseDialog = false; })
          }
          .width('80%')
          .constraintSize({ maxWidth: DS.dialogMaxWidth(this.bp) })
          .padding(20)
          .backgroundColor(Palette.surface(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .borderRadius(20)
        }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.94, y: 0.94 })).animation({ duration: 220, curve: Curve.EaseOut }))
      }

      // ========== 首页排序对话框 ==========
      if (this.showSortDialog) {
        Stack() {
          this.DialogMask((): void => { this.showSortDialog = false; })
          Column() {
            Text('首页排序')
              .fontSize(DS.bodyFont(this.bp))
              .fontColor(Palette.textPrimary(this.isDark))
              .fontWeight(FontWeight.Bold)
              .margin({ bottom: 6 })
            Text('长按拖动排序（首页推荐分类固定）')
              .fontSize(DS.smallFont(this.bp))
              .fontColor(Palette.textSecondary(this.isDark))
              .margin({ bottom: 16 })

            if (this.sortLoading) {
              Text('加载中…')
                .fontSize(DS.smallFont(this.bp))
                .fontColor(Palette.textSecondary(this.isDark))
                .margin({ top: 20, bottom: 20 })
            } else if (this.sortCategories.length === 0) {
              Text('暂无可排序的分类')
                .fontSize(DS.smallFont(this.bp))
                .fontColor(Palette.textSecondary(this.isDark))
                .margin({ top: 20, bottom: 20 })
            } else {
              List({ space: 6 }) {
                ForEach(this.sortCategories, (item: SortData, index: number) => {
                  ListItem() {
                    Row() {
                      Text((index + 1) + '. ' + item.name)
                        .fontSize(DS.smallFont(this.bp))
                        .fontColor(Palette.textPrimary(this.isDark))
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })

                    }
                    .width('100%')
                    .padding({ top: 8, bottom: 8, left: 12, right: 6 })
                    .borderRadius(8)
                    .backgroundColor(this.dragSortIndex === index ? (this.isDark ? '#3A3A3C' : '#D0D2D8') : (this.isDark ? '#2C2C2E' : '#E9EAEE'))
                    .shadow(this.dragSortIndex === index ? { radius: 18, color: 'rgba(0,0,0,0.28)', offsetX: 0, offsetY: 6 } : { radius: 0, color: 'rgba(0,0,0,0)', offsetX: 0, offsetY: 0 })
                    .translate(this.dragSortIndex === index ? { x: 0, y: this.dragSortOffset } : { x: 0, y: this.sortRowShift(index) })
                    .zIndex(this.dragSortIndex === index ? 10 : 0)
                    .animation(this.dragSortIndex === index ? { duration: 0 } : { duration: 260, curve: Curve.FastOutSlowIn })
                    .gesture(
                      GestureGroup(GestureMode.Sequence,
                        LongPressGesture({ repeat: false, duration: 300 })
                          .onAction((): void => { this.startSortDrag(index); }),
                        PanGesture({ direction: PanDirection.Vertical, distance: 0 })
                          .onActionUpdate((ev: GestureEvent): void => { this.commitSortPan(ev.offsetY); })
                          .onActionEnd((): void => { this.endSortDrag(); })
                          .onActionCancel((): void => { this.endSortDrag(); })
                      )
                    )
                  }
                }, (item: SortData, index: number): string => item.id + '_' + index)
              }
              .listDirection(Axis.Vertical)
              .scrollBar(BarState.Off)
              .width('100%')
              .clip(false)
              .constraintSize({ maxHeight: 350 })
            }

            Row() {
              Button('取消')
                .fontSize(DS.smallFont(this.bp)).fontColor(Palette.textPrimary(this.isDark))
                .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
                .borderRadius(8).layoutWeight(1).height(40)
                .onClick(() => { this.showSortDialog = false; })
              Button('保存')
                .fontSize(DS.smallFont(this.bp)).fontWeight(FontWeight.Medium).fontColor(Palette.textPrimary(this.isDark))
                .backgroundColor((this.isDark ? '#2C2C2E' : '#E9EAEE'))
                .borderRadius(8).layoutWeight(1).height(40).margin({ left: 12 })
                .enabled(!this.sortLoading && this.sortCategories.length > 0)
                .onClick(() => { this.saveSortOrder(); })
            }
            .width('100%').margin({ top: 16 })
          }
          .width('80%').constraintSize({ maxWidth: DS.dialogMaxWidth(this.bp) }).padding(20)
          .backgroundColor(Palette.surface(this.isDark)).backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT }).borderRadius(20)
        }
        .width('100%').height('100%')
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.94, y: 0.94 })).animation({ duration: 220, curve: Curve.EaseOut }))
      }

    }
    .width('100%')
    .height(this.embedded ? 'auto' : '100%')
  }
}
