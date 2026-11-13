import { router, promptAction, mediaquery } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppTheme, Palette } from '../common/AppTheme';
import { PlayIconSet } from '../common/PlayIconSet';
import { VideoItem, folderNameOf, fileNameOf, stripExt, formatDuration } from '../model/VideoItem';
import { MediaRepository, DownloadScanReport } from '../model/MediaRepository';
import { PlayerPrefs, PlaylistHolder, ResumeEntry } from '../model/PlayerPrefs';
import { ThumbnailLoader } from '../utils/ThumbnailLoader';
import { NetPanel } from '../view/NetPanel';
import { SettingsPanel } from '../view/SettingsPanel';
import { MusicPanel } from '../view/MusicPanel';
import { SourceSandboxHost } from '../lx/components/SourceSandboxHost';
import { NetPrefs } from '../model/NetPrefs';
// 失败文案与音乐下载共用同一套分层口径，避免同一个错误码在两处说法不一样
import { AccessReason, accessReasonOf } from '../lx/core/download/DownloadReason';

const TAG: string = 'Index';
const DOMAIN: number = 0x0001;

// ---------------- 视频页分页（按内容高度自动分页） ----------------
/** 区标题行占位：本地区与网络区共用同一口径 */
const SECTION_HEADER_H: number = 48;
/** 列表内联搜索框占位（开启搜索时计入内容高度） */
const INLINE_SEARCH_H: number = 44;
/** 本地视频行高：封面 72 + 上下 padding 8*2 */
const VIDEO_ROW_H: number = 88;
/** 内容高度达到一页可用高度的该比例即视为「占满」 */
const FULL_THRESHOLD: number = 0.98;
/** 形态切换最小滞留时间：避免临界抖动导致整块布局来回跳 */
const PAGING_MIN_HOLD_MS: number = 300;

// ---------------- 页签胶囊悬浮回缩 ----------------
/** 回缩态热区尺寸（触控不小于 44vp） */
const CAPSULE_COLLAPSED_SIZE: number = 48;
const CAPSULE_ANIM_OUT_MS: number = 220;
const CAPSULE_ANIM_IN_MS: number = 240;
/** 胶囊动效期间的点击防抖，避免回缩动画被当成页签点击 */
const CAPSULE_TAP_GUARD_MS: number = 600;
const CAPSULE_RETRACT_DEFAULT: number = 1;

enum SortMode {
  NAME = 0,
  DURATION = 1,
  SIZE = 2,
  ADDED = 3
}

class FolderGroup {
  name: string;
  items: VideoItem[];

  constructor(name: string, items: VideoItem[]) {
    this.name = name;
    this.items = items;
  }
}

/** 供设置页展示的轻量文件夹信息（只带 uri 与标题） */
class FolderBrief {
  name: string = '';
  uris: string[] = [];
  titles: string[] = [];

  constructor(name: string) {
    this.name = name;
  }
}

/** 列表左侧封面：加载首帧，失败回落为占位图。*/
@Component
struct ThumbView {
  @StorageProp('isDark') isDark: boolean = true;

  pal(): Palette {
    return AppTheme.palette(this.isDark);
  }

  uri: string = '';
  @State pm: image.PixelMap | undefined = undefined;

  aboutToAppear(): void {
    const cached: image.PixelMap | undefined = ThumbnailLoader.get(this.uri);
    if (cached !== undefined) {
      this.pm = cached;
      return;
    }
    ThumbnailLoader.load(this.uri).then((p: image.PixelMap | undefined) => {
      if (p !== undefined) {
        this.pm = p;
      }
    });
  }

  build() {
    Stack() {
      if (this.pm !== undefined) {
        Image(this.pm)
          .width(AppTheme.thumbWidth)
          .height(AppTheme.thumbHeight)
          .objectFit(ImageFit.Cover)
          .borderRadius(AppTheme.radius)
      } else {
        Column() {
          Image(PlayIconSet.PLAY)
            .width(20)
            .height(20)
            .fillColor(this.pal().textTertiary)
            .objectFit(ImageFit.Contain)
            .draggable(false)
        }
        .width(AppTheme.thumbWidth)
        .height(AppTheme.thumbHeight)
        .backgroundColor(this.pal().bgChip)
        .borderRadius(AppTheme.radius)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width(AppTheme.thumbWidth)
    .height(AppTheme.thumbHeight)
  }
}

@Entry
@Component
struct Index {
  @StorageProp('isDark') isDark: boolean = true;
  @StorageProp('safeTop') safeTop: number = 0;
  @StorageProp('safeBottom') safeBottom: number = 0;

  @State items: VideoItem[] = [];
  @State loadedUris: string[] = [];
  @State loading: boolean = false;
  @State currentTab: number = 0;
  @State searching: boolean = false;
  @State keyword: string = '';
  @State sortMode: SortMode = SortMode.ADDED;
  @State selectionMode: boolean = false;
  @State selectedUris: string[] = [];
  @State isWide: boolean = false;
  @State isPad: boolean = false;
  @State resumeList: ResumeEntry[] = [];
  @State localResume: number = 0;
  @State netResume: number = 0;
  @State netTick: number = 0;
  /** 网络面板是否已进入目录浏览：浏览态把它放大到近乎整页，否则目录列表会被压成 0 高 */
  @State netBrowsing: boolean = false;

  @State viewH: number = 0;
  /** 视频页整页翻页索引：0=本地视频页，1=局域网页 */
  @State videoPage: number = 0;
  /** 视频页内部页签：0=局域网（最左），1=本地视频；每页各占一整页 */
  @State videoTab: number = 1;

  // ---- 视频页分页形态（按内容高度自动判定，见 PagingState 说明） ----
  /** 分页形态：true=两个整页 Swiper（现状），false=上下半屏同屏 */
  @State paged: boolean = false;
  /** 首帧测量是否已完成：待定期间沿用旧口径 hasLocal()，不做强制回落 */
  @State pagingReady: boolean = false;
  /** 网络区内容高度（由 NetPanel 上报：虚拟化列表无法实测，按条目数估算） */
  private netContentH: number = 0;
  /** 本地全量内容高度（按整行行高估算：预览只显 2~3 行，实测拿不到全量高度） */
  private localContentH: number = 0;
  private lastSwitchAt: number = 0;
  /** 回落需连续两次判定一致才生效，避免临界抖动 */
  private fallbackPending: boolean = false;
  private recalcScheduled: boolean = false;

  // ---- 页签胶囊悬浮回缩 ----
  @StorageProp('capsuleRetractSec') @Watch('onRetractSecChanged') capsuleRetractSec: number = CAPSULE_RETRACT_DEFAULT;
  /** 回缩后胶囊落点：left / center / right（设置-外观） */
  @StorageProp('capsuleAlign') @Watch('onCapsuleAlignChanged') capsuleAlign: string = 'center';
  @State capsuleCollapsed: boolean = false;
  private retractTimer: number = -1;
  private capsuleTapAt: number = 0;
  private pageScroll: Scroller = new Scroller();
  /** 整页模式下的两个页内滚动控制器 */
  private localScroll: Scroller = new Scroller();
  private swiperCtrl: SwiperController = new SwiperController();
  /** 翻页冷却：避免一次滑动连续触发多页 */
  private flipLock: boolean = false;
  /** 程序性切页进行中：抑制 Swiper onChange 把旧索引写回状态（否则首帧 changeIndex 失效后会被覆盖为 0 而永久停错页） */
  private syncingVideoPage: boolean = false;
  /** 跳转播放页/全部列表页前记下的滚动位置，返回时恢复 */
  private savedScrollY: number = 0;
  private tabsController: TabsController = new TabsController();
  private wideListener: mediaquery.MediaQueryListener = mediaquery.matchMediaSync('(min-width: 600vp)');
  private padListener: mediaquery.MediaQueryListener = mediaquery.matchMediaSync('(min-width: 840vp)');

  pal(): Palette {
    return AppTheme.palette(this.isDark);
  }

  aboutToAppear(): void {
    this.isWide = this.wideListener.matches;
    this.isPad = this.padListener.matches;
    this.wideListener.on('change', (r: mediaquery.MediaQueryResult) => {
      this.isWide = r.matches;
    });
    this.padListener.on('change', (r: mediaquery.MediaQueryResult) => {
      this.isPad = r.matches;
    });
    this.initData();
  }

  aboutToDisappear(): void {
    this.wideListener.off('change');
    this.padListener.off('change');
    if (this.retractTimer >= 0) {
      clearTimeout(this.retractTimer);
      this.retractTimer = -1;
    }
  }

  onPageShow(): void {
    this.refreshMeta();
    this.refreshResume();
    // 从添加/编辑服务器页、播放页返回时 Swiper 可能已重建回第 0 页，
    // 这里把页位强制对齐一次（浏览态一律回网络页），否则用户会停在空白本地页且无翻页入口。
    if (this.paged) {
      setTimeout(() => {
        if (this.paged) {
          this.alignVideoPage(this.netBrowsing ? 1 : this.videoPage, true, true);
        }
      }, 0);
    }
    // 从播放页 / 全部列表页返回：恢复视频页滚动位置（选中态由 @State 保留）
    if (this.savedScrollY > 0) {
      const y: number = this.savedScrollY;
      setTimeout(() => {
        // 整页模式下滚动发生在页内 List（localScroll），同屏模式下在外层 pageScroll，两处都试一次
        try {
          this.localScroll.scrollTo({ xOffset: 0, yOffset: y, animation: { duration: 0 } });
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'restore local scroll failed');
        }
        try {
          this.pageScroll.scrollTo({ xOffset: 0, yOffset: y, animation: { duration: 0 } });
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'restore scroll failed');
        }
      }, 0);
    }
  }

  // ---------------- 数据 ----------------

  private async initData(): Promise<void> {
    this.loading = true;
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    await PlayerPrefs.init(context);
    // 外观偏好必须在首帧前落到 AppStorage，避免胶囊先展开再回缩
    AppStorage.setOrCreate('capsuleRetractSec', PlayerPrefs.getCapsuleRetractSec());
    AppStorage.setOrCreate('capsuleAlign', PlayerPrefs.getCapsuleAlign());
    this.armCapsuleRetract();
    this.loadedUris = PlayerPrefs.getPlaylistUris();
    this.refreshResume();
    await this.refreshMeta();
    this.loading = false;
    this.scheduleRecalc();
  }

  /** 重新探测已保存的 uri，失效项自动剔除 */
  private async refreshMeta(): Promise<void> {
    const uris: string[] = this.loadedUris;
    if (uris.length === 0) {
      this.items = [];
      this.scheduleRecalc();
      return;
    }
    try {
      const probed: VideoItem[] = await MediaRepository.probeAll(uris);
      const alive: VideoItem[] = probed.filter((it: VideoItem) => it !== undefined && it.uri.length > 0);
      this.items = this.sortItems(alive);
      const aliveUris: string[] = alive.map((it: VideoItem) => it.uri);
      if (aliveUris.length !== uris.length) {
        this.loadedUris = aliveUris;
        await PlayerPrefs.savePlaylistUris(aliveUris);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'refresh meta failed');
    }
    // 条目数变化会影响「内容是否占满一页」的判定
    this.scheduleRecalc();
  }

  private sortItems(list: VideoItem[]): VideoItem[] {
    const arr: VideoItem[] = list.slice();
    const mode: SortMode = this.sortMode;
    arr.sort((a: VideoItem, b: VideoItem) => {
      if (mode === SortMode.NAME) {
        return a.title.localeCompare(b.title);
      }
      if (mode === SortMode.DURATION) {
        return b.durationMs - a.durationMs;
      }
      if (mode === SortMode.SIZE) {
        return b.sizeBytes - a.sizeBytes;
      }
      return b.addedAt - a.addedAt;
    });
    return arr;
  }

  private filtered(): VideoItem[] {
    const kw: string = this.keyword.trim().toLowerCase();
    if (kw.length === 0) {
      return this.items;
    }
    return this.items.filter((it: VideoItem) =>
      it.title.toLowerCase().includes(kw) || it.folder.toLowerCase().includes(kw));
  }

  private folders(): FolderGroup[] {
    const groups: FolderGroup[] = [];
    const list: VideoItem[] = this.filtered();
    for (let i = 0; i < list.length; i++) {
      const name: string = list[i].folder.length > 0 ? list[i].folder : '其他';
      let found: FolderGroup | undefined = undefined;
      for (let j = 0; j < groups.length; j++) {
        if (groups[j].name === name) {
          found = groups[j];
          break;
        }
      }
      if (found === undefined) {
        found = new FolderGroup(name, []);
        groups.push(found);
      }
      found.items.push(list[i]);
    }
    return groups;
  }

  private play(list: VideoItem[], index: number): void {
    if (list.length === 0) {
      return;
    }
    PlaylistHolder.set(list, index < 0 ? 0 : index);
    this.savedScrollY = this.currentScrollY();
    // 本地点播走独立播放页；网络源仍走 pages/PlayerPage，两条路径返回栈一致
    router.pushUrl({ url: 'pages/LocalPlayerPage' }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'push LocalPlayerPage failed code=%{public}d', err.code);
      router.pushUrl({ url: 'pages/PlayerPage' }).catch((err2: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'push PlayerPage failed code=%{public}d', err2.code);
      });
    });
  }

  /** 当前视频页滚动位置（异常时返回 0，不影响跳转） */
  private currentScrollY(): number {
    try {
      const offset: OffsetResult = this.localScroll.currentOffset();
      if (offset.yOffset > 0) {
        return offset.yOffset;
      }
    } catch (err) {
    }
    try {
      const offset: OffsetResult = this.pageScroll.currentOffset();
      return offset.yOffset > 0 ? offset.yOffset : 0;
    } catch (err) {
      return 0;
    }
  }

  /** 「查看全部」：进入本地视频全量列表页（独立页，避免视频页嵌套滚动） */
  private openAllLocal(): void {
    this.savedScrollY = this.currentScrollY();
    router.pushUrl({ url: 'pages/LocalListPage' }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'push LocalListPage failed code=%{public}d', err.code);
    });
  }

  /** 从系统媒体库选择视频（保留原选择器链路：复制进沙箱，重启可播） */
  private async addFromMediaLibrary(): Promise<void> {
    try {
      const picked: string[] = await MediaRepository.pickVideos(50);
      await this.importPicked(picked, '媒体库');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'add videos failed');
    }
  }

  /** 兜底：Download 目录不可用时，用系统文件选择器挑视频并复制进沙箱 */
  private async importViaFilePicker(): Promise<void> {
    try {
      const picked: string[] = await MediaRepository.pickVideoFiles(50);
      await this.importPicked(picked, '文件选择器');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'import via file picker failed');
    }
  }

  /** 统一的导入落盘流程：持久化权限 → 复制进沙箱 → 去重入列表 */
  private async importPicked(picked: string[], source: string): Promise<void> {
    if (picked.length === 0) {
      return;
    }
    try {
      // 持久化访问权限，避免重启后打不开（播放侧会报 5400102）
      await MediaRepository.persistPermission(picked);
      this.loading = true;
      // 侧载包拿不到 FILE_ACCESS_PERSIST，系统 uri 重启必失效，
      // 因此导入时把文件复制进应用沙箱，用沙箱路径入列表，重启后照样能播
      promptAction.showToast({ message: `正在导入 ${picked.length} 个视频到应用内…` });
      const stored: string[] = [];
      let copied: number = 0;
      for (let i = 0; i < picked.length; i++) {
        try {
          stored.push(await MediaRepository.copyIntoApp(picked[i]));
          copied++;
        } catch (err) {
          // 复制失败退回原 uri：本次会话可播，重启后可能要重新导入
          stored.push(picked[i]);
        }
      }
      const all: string[] = this.loadedUris.slice();
      for (let i = 0; i < stored.length; i++) {
        if (!all.includes(stored[i])) {
          all.push(stored[i]);
        }
      }
      this.loadedUris = all;
      await PlayerPrefs.savePlaylistUris(all);
      await this.refreshMeta();
      promptAction.showToast({ message: `已从${source}导入 ${stored.length} 个视频（${copied} 个已存入应用内）` });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'import picked failed');
    } finally {
      this.loading = false;
    }
  }

  /**
   * 直接扫描系统 Download 目录导入（READ_WRITE_DOWNLOAD_DIRECTORY，ACL 已审批）。
   * 这类路径靠权限长期可读，不复制进沙箱，删除时也只移出列表、不动原文件。
   */
  private async addFromDownload(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    try {
      const report: DownloadScanReport = await MediaRepository.scanDownloadVideosReport();
      hilog.info(DOMAIN, TAG,
        'download report syscap=%{public}s granted=%{public}s reqCode=%{public}d reqResult=%{public}d access=%{public}d list=%{public}d total=%{public}d',
        String(report.syscap), String(report.granted), report.requestCode, report.requestResult,
        report.accessCode, report.listCode, report.totalFiles);
      const found: string[] = report.videos;
      if (found.length === 0) {
        this.loading = false;
        await this.reportDownloadFailure(report);
        return;
      }
      const all: string[] = this.loadedUris.slice();
      let added: number = 0;
      for (let i = 0; i < found.length; i++) {
        if (!all.includes(found[i])) {
          all.push(found[i]);
          added++;
        }
      }
      if (added === 0) {
        promptAction.showToast({ message: `Download 目录里的 ${found.length} 个视频已在列表中` });
        return;
      }
      this.loadedUris = all;
      await PlayerPrefs.savePlaylistUris(all);
      await this.refreshMeta();
      promptAction.showToast({ message: `已从 Download 导入 ${added} 个视频` });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'add from download failed');
      promptAction.showToast({ message: '导入失败，请检查 Download 目录权限' });
    } finally {
      this.loading = false;
    }
  }

  /**
   * 把 Download 导入失败的原因按发生节点讲清楚：
   * 无 FolderObtain 能力 / 权限未授予 / 目录打不开 / 列目录失败 / 目录里确实没视频。
   * 前四种属于"功能不可用"，给出改用系统文件选择器的出口。
   */
  private async reportDownloadFailure(report: DownloadScanReport): Promise<void> {
    // 文案统一走 accessReasonOf：音乐下载与视频导入对同一个错误码给出同一句话，
    // 用户在两处看到的说法对得上，排查时不会以为是两个不同的毛病
    const verdict: AccessReason = accessReasonOf(report.syscap, report.granted, report.requestCode,
      report.requestResult, report.accessCode, report.listCode, report.totalFiles);
    const reason: string = verdict.text;
    const blocked: boolean = verdict.blocked;
    hilog.warn(DOMAIN, TAG, 'download import blocked reason=%{public}s', reason);
    promptAction.showToast({ message: reason });
    if (!blocked) {
      return;
    }
    promptAction.showDialog({
      title: 'Download 目录不可用',
      message: `${reason}。是否改用系统文件选择器导入视频？`,
      buttons: [
        { text: '取消', color: this.pal().textSecondary },
        { text: '改用选择器', color: this.pal().primary }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        this.importViaFilePicker();
      }
    }).catch(() => {
    });
  }

  private toggleSelect(uri: string): void {
    const idx: number = this.selectedUris.indexOf(uri);
    if (idx >= 0) {
      const next: string[] = this.selectedUris.slice();
      next.splice(idx, 1);
      this.selectedUris = next;
    } else {
      this.selectedUris = this.selectedUris.concat([uri]);
    }
  }

  /** 是否为导入时复制进应用沙箱的副本（这类可以从磁盘真删） */
  private isSandboxCopy(uri: string): boolean {
    return uri.indexOf('/files/videos/') >= 0;
  }

  /** 删除沙箱内的导入副本；系统媒体库里的文件只移出列表，不动原文件 */
  private deleteSandboxCopies(uris: string[]): number {
    let removed: number = 0;
    for (let i = 0; i < uris.length; i++) {
      const u: string = uris[i];
      if (!this.isSandboxCopy(u)) {
        continue;
      }
      try {
        fs.unlinkSync(u);
        removed++;
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'delete imported copy failed: %{public}s', u);
      }
    }
    return removed;
  }

  /** 单条删除：本地导入的会删掉沙箱文件，媒体库的仅移出列表 */
  private deleteOne(item: VideoItem): void {
    const sandbox: boolean = this.isSandboxCopy(item.uri);
    promptAction.showDialog({
      title: '删除视频',
      message: sandbox
        ? `「${item.title}」是导入时复制到本应用的副本，将从磁盘删除并移出列表。`
        : `「${item.title}」来自系统媒体库，只会移出列表，原文件保留。`,
      buttons: [
        { text: '取消', color: this.pal().textSecondary },
        { text: '删除', color: this.pal().danger }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index !== 1) {
        return;
      }
      this.deleteSandboxCopies([item.uri]);
      const all: string[] = this.loadedUris.filter((u: string) => u !== item.uri);
      this.loadedUris = all;
      PlayerPrefs.savePlaylistUris(all).then(() => {
        this.items = this.items.filter((it: VideoItem) => it.uri !== item.uri);
        PlayerPrefs.clearResume(item.uri);
        this.refreshResume();
        this.scheduleRecalc();
        promptAction.showToast({ message: '已删除' });
      });
    }).catch(() => {
    });
  }

  private removeSelected(): void {
    if (this.selectedUris.length === 0) {
      return;
    }
    let copyCount: number = 0;
    for (let i = 0; i < this.selectedUris.length; i++) {
      if (this.isSandboxCopy(this.selectedUris[i])) {
        copyCount++;
      }
    }
    const tail: string = copyCount > 0
      ? `其中 ${copyCount} 个是导入副本，会从磁盘删除；其余仅移出列表。`
      : '系统媒体库里的原文件不会被删除。';
    promptAction.showDialog({
      title: '删除视频',
      message: `将处理 ${this.selectedUris.length} 个视频，${tail}`,
      buttons: [
        { text: '取消', color: this.pal().textSecondary },
        { text: '删除', color: this.pal().danger }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index !== 1) {
        return;
      }
      const sel: string[] = this.selectedUris;
      this.deleteSandboxCopies(sel);
      const all: string[] = this.loadedUris.filter((u: string) => !sel.includes(u));
      this.loadedUris = all;
      PlayerPrefs.savePlaylistUris(all).then(() => {
        this.items = this.items.filter((it: VideoItem) => !sel.includes(it.uri));
        for (let i = 0; i < sel.length; i++) {
          PlayerPrefs.clearResume(sel[i]);
        }
        this.refreshResume();
        this.scheduleRecalc();
        this.selectionMode = false;
        this.selectedUris = [];
        this.armCapsuleRetract();
        promptAction.showToast({ message: '已删除' });
      });
    }).catch(() => {
    });
  }

  // ---------------- 播放进度缓存 ----------------

  private refreshResume(): void {
    this.resumeList = PlayerPrefs.getResumeList();
    let local: number = 0;
    let net: number = 0;
    for (let i = 0; i < this.resumeList.length; i++) {
      if (this.resumeList[i].isNet) {
        net++;
      } else {
        local++;
      }
    }
    this.localResume = local;
    this.netResume = net;
    this.syncFolderBrief();
  }

  /** 把文件夹分组写入 AppStorage，供设置页「文件夹」入口读取 */
  private syncFolderBrief(): void {
    const groups: FolderGroup[] = this.folders();
    const brief: FolderBrief[] = [];
    for (let i = 0; i < groups.length; i++) {
      const one: FolderBrief = new FolderBrief(groups[i].name);
      for (let j = 0; j < groups[i].items.length; j++) {
        one.uris.push(groups[i].items[j].uri);
        one.titles.push(groups[i].items[j].title);
      }
      brief.push(one);
    }
    AppStorage.setOrCreate<string>('folderBrief', JSON.stringify(brief));
  }

  private resumeTip(uri: string): string {
    for (let i = 0; i < this.resumeList.length; i++) {
      const e: ResumeEntry = this.resumeList[i];
      if (e.uri === uri && e.posMs > 5000) {
        if (e.durMs > 0 && e.posMs >= e.durMs - 3000) {
          return '已看完';
        }
        const tail: string = e.durMs > 0 ? ` / ${formatDuration(e.durMs)}` : '';
        return `上次看到 ${formatDuration(e.posMs)}${tail}`;
      }
    }
    return '';
  }

  // ---------------- 视图辅助 ----------------

  private sidePad(): number {
    if (this.isPad) {
      return 28;
    }
    if (this.isWide) {
      return 20;
    }
    return AppTheme.pagePadding;
  }

  private tabTitle(): string {
    if (this.currentTab === 1) {
      return '音乐';
    }
    if (this.currentTab === 2) {
      return '设置';
    }
    return '多媒体';
  }

  private statusText(): string {
    // 按需求隐藏：设置页不再显示「设置」、音乐页不再显示「在线歌单广场 · TX/KW/KG/MG/WY」
    if (this.currentTab === 2 || this.currentTab === 1) {
      return '';
    }
    // 视频页合并了网络源：本地与网络进度一起报
    return `共 ${this.items.length} 个视频 · 已记忆 ${this.localResume + this.netResume} 条进度`;
  }

  /** 底部所有浮层（页签胶囊 52 + 底距 14 + 间隙）占掉的高度 */
  private overlayTop(): number {
    return 74 + this.safeBottom;
  }

  private capsuleColor(): ResourceColor {
    return this.pal().glassPlate;
  }

  private switchTab(index: number): void {
    if (this.currentTab === index) {
      return;
    }
    this.currentTab = index;
    this.searching = false;
    this.keyword = '';
    this.selectionMode = false;
    this.selectedUris = [];
    this.refreshResume();
    // 切页后重新计一次胶囊悬浮时间，别刚切过来就看到回缩态
    this.armCapsuleRetract();
    try {
      this.tabsController.changeIndex(index);
    } catch (err) {
    }
  }

  private showSortMenu(): void {
    promptAction.showActionMenu({
      title: '排序方式',
      buttons: [
        { text: '名称', color: this.pal().textPrimary },
        { text: '时长', color: this.pal().textPrimary },
        { text: '大小', color: this.pal().textPrimary },
        { text: '添加时间', color: this.pal().textPrimary }
      ]
    }).then((res: promptAction.ActionMenuSuccessResponse) => {
      if (res.index === 0) {
        this.sortMode = SortMode.NAME;
      } else if (res.index === 1) {
        this.sortMode = SortMode.DURATION;
      } else if (res.index === 2) {
        this.sortMode = SortMode.SIZE;
      } else {
        this.sortMode = SortMode.ADDED;
      }
      this.items = this.sortItems(this.items);
      this.scheduleRecalc();
    }).catch(() => {
    });
  }

  // ---------------- 组件 ----------------

  @Builder
  buildToolbar() {
    Row() {
      if (this.currentTab === 0 || this.currentTab === 1) {
        Text(this.tabTitle())
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().textPrimary)
          .layoutWeight(1)
        if (this.currentTab === 0 && this.selectionMode) {
          Text(`${this.selectedUris.length} 项`)
            .fontSize(13)
            .fontColor(this.pal().textSecondary)
            .margin({ right: 10 })
          Text('删除')
            .fontSize(13)
            .fontColor(this.pal().danger)
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              this.removeSelected();
            })
          Text('取消')
            .fontSize(13)
            .fontColor(this.pal().textSecondary)
            .padding({ left: 8 })
            .onClick(() => {
              this.selectionMode = false;
              this.selectedUris = [];
              this.armCapsuleRetract();
            })
        } else if (this.currentTab === 0) {
          // 顶栏不再放「+」：导入入口只保留在「本地视频」页签右侧
          Blank()
            .layoutWeight(1)
        }
      } else if (this.currentTab === 2) {
        // 设置页：顶栏不重复放「设置」标题（页面内已有分区，重复且难看），只留高度占位
        Blank()
          .layoutWeight(1)
      }
    }
    .width('100%')
    .height(AppTheme.toolbarHeight + this.safeTop)
    .padding({ left: this.sidePad(), right: this.sidePad(), top: this.safeTop })
  }

  /**
   * 「本地视频」页签右侧的「+」：导入视频的入口只在本页签出现。
   * 与页签同为 30vp 高度，视觉上属于页签行；触控热区靠外层 padding 撑到 40vp。
   */
  @Builder
  addChip() {
    Column() {
      Text('+')
        .fontSize(19)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
    }
    .width(30)
    .height(30)
    .borderRadius(15)
    .backgroundColor(this.pal().primary)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.openAddMenu();
    })
  }

  @Builder
  statusRow() {
    Row() {
      Text(this.statusText())
        .fontSize(11)
        .fontColor(this.pal().textTertiary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.loading) {
        Text('读取中…')
          .fontSize(11)
          .fontColor(this.pal().textTertiary)
          .margin({ right: 8 })
      }
    }
    .width(this.isWide ? 420 : '86%')
    .constraintSize({ maxWidth: 460 })
    .padding({ left: 6, right: 6 })
    .margin({ bottom: 6 })
  }

  /** 页位指示点：分页形态下常驻；可点击直接跳页（本地页为空、手势翻页被禁时的唯一入口） */
  @Builder
  pageDots() {
    Row() {
      this.pageDot(0)
      this.pageDot(1)
    }
    .margin({ right: 2 })
  }

  @Builder
  pageDot(index: number) {
    Row() {
      Column()
        .width(this.videoPage === index ? 12 : 5)
        .height(4)
        .borderRadius(2)
        .backgroundColor(this.videoPage === index ? this.pal().primary : this.pal().textTertiary)
    }
    .height(24)
    .padding({ left: 6, right: 6 })
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.jumpVideoPage(index);
    })
  }

  /** 底部悬浮胶囊页签：85% 玻璃底、四等分、不贴底，背后内容透出来；停留数秒后回缩成小圆点 */
  @Builder
  capsuleBar() {
    Row() {
      if (this.capsuleCollapsed) {
        // 回缩态：三点标记，点击整体展开（触控热区仍是 48vp）
        Row({ space: 3 }) {
          Column()
            .width(5)
            .height(5)
            .borderRadius(3)
            .backgroundColor(this.currentTab === 0 ? this.pal().primary : this.pal().textSecondary)
          Column()
            .width(5)
            .height(5)
            .borderRadius(3)
            .backgroundColor(this.currentTab === 1 ? this.pal().primary : this.pal().textSecondary)
          Column()
            .width(5)
            .height(5)
            .borderRadius(3)
            .backgroundColor(this.currentTab === 2 ? this.pal().primary : this.pal().textSecondary)
        }
        .width(CAPSULE_COLLAPSED_SIZE)
        .height(CAPSULE_COLLAPSED_SIZE)
        .justifyContent(FlexAlign.Center)
      } else {
        this.capsuleItem('视频', 0)
        this.capsuleItem('音乐', 1)
        this.capsuleItem('设置', 2)
      }
    }
    .width(this.capsuleWidth())
    .constraintSize({ maxWidth: 460 })
    .height(this.capsuleCollapsed ? CAPSULE_COLLAPSED_SIZE : 52)
    .padding(this.capsuleCollapsed ? { left: 0, right: 0 } : { left: 6, right: 6 })
    .borderRadius(this.capsuleCollapsed ? 24 : 26)
    .backgroundColor(this.capsuleColor())
    .backgroundBlurStyle(BlurStyle.Thick)
    .border({ width: 0.5, color: this.isDark ? '#33FFFFFF' : '#1F000000' })
    .shadow({ radius: 16, color: '#33000000', offsetY: 4 })
    .margin({ bottom: 14 + this.safeBottom })
    .accessibilityText(this.capsuleCollapsed ? '页签已回缩，点按展开' : this.capsuleA11yText())
    .accessibilityLevel('yes')
    .accessibilityDescription(this.capsuleCollapsed ? '单击展开为三页签胶囊' : '单击切换页签，停止操作后自动回缩')
    .animation({
      duration: this.capsuleCollapsed ? CAPSULE_ANIM_OUT_MS : CAPSULE_ANIM_IN_MS,
      curve: Curve.EaseOut
    })
    .onClick(() => {
      if (this.capsuleCollapsed) {
        this.onCapsuleTouch();
      }
    })
  }

  @Builder
  capsuleItem(label: string, index: number) {
    Column() {
      Text(label)
        .fontSize(13)
        .fontColor(this.currentTab === index ? Color.White : this.pal().textSecondary)
        .fontWeight(this.currentTab === index ? FontWeight.Medium : FontWeight.Normal)
        .height(18)
        .textAlign(TextAlign.Center)
    }
    .layoutWeight(1)
    .height(40)
    .margin({ left: 2, right: 2 })
    .borderRadius(20)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.currentTab === index ? this.pal().primary : Color.Transparent)
    .onClick(() => {
      if (this.onCapsuleTouch()) {
        return;
      }
      this.switchTab(index);
    })
  }

  /** 「+」的添加菜单：右上角按钮与空列表按钮共用 */
  private openAddMenu(): void {
    promptAction.showActionMenu({
      title: '添加视频',
      buttons: [
        { text: '从媒体库选择', color: this.pal().textPrimary },
        { text: '从文件选择', color: this.pal().textPrimary },
        { text: '从 Download 目录导入', color: this.pal().textPrimary }
      ]
    }).then((res: promptAction.ActionMenuSuccessResponse) => {
      if (res.index === 0) {
        this.addFromMediaLibrary();
      } else if (res.index === 1) {
        this.importViaFilePicker();
      } else if (res.index === 2) {
        this.addFromDownload();
      }
    }).catch(() => {
    });
  }

  @Builder
  emptyView() {
    Column() {
      Image(PlayIconSet.PLAY)
        .width(46)
        .height(46)
        .fillColor(this.pal().textTertiary)
        .objectFit(ImageFit.Contain)
        .draggable(false)
      Text(this.loading ? '正在读取视频信息…' : '暂无视频，点右上角 + 添加')
        .fontSize(14)
        .fontColor(this.pal().textSecondary)
        .margin({ top: 12 })
        .textAlign(TextAlign.Center)
      Row() {
        Button('从媒体库添加')
          .fontSize(14)
          .height(36)
          .backgroundColor(this.pal().bgChip)
          .fontColor(this.pal().textPrimary)
          .onClick(() => {
            this.addFromMediaLibrary();
          })
        Button('从文件添加')
          .fontSize(14)
          .height(36)
          .backgroundColor(this.pal().bgChip)
          .fontColor(this.pal().textPrimary)
          .margin({ left: 10 })
          .onClick(() => {
            this.importViaFilePicker();
          })
      }
      .margin({ top: 16 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  videoRow(item: VideoItem, index: number) {
    Row() {
      Stack() {
        ThumbView({ uri: item.uri })
        if (this.selectionMode) {
          Column() {
            Text(this.selectedUris.includes(item.uri) ? '✓' : '')
              .fontSize(13)
              .fontColor(Color.White)
          }
          .width(22)
          .height(22)
          .borderRadius(11)
          .backgroundColor(this.selectedUris.includes(item.uri) ? this.pal().primary : '#66000000')
          .justifyContent(FlexAlign.Center)
          .margin({ left: 4, top: 4 })
          .align(Alignment.TopEnd)
        }
      }
      .width(AppTheme.thumbWidth)
      .height(AppTheme.thumbHeight)

      Column() {
        Text(item.title)
          .fontSize(15)
          .fontColor(this.pal().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(item.metaLine())
          .fontSize(12)
          .fontColor(this.pal().textSecondary)
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.resumeTip(item.uri).length > 0) {
          Text(this.resumeTip(item.uri))
            .fontSize(11)
            .fontColor(this.pal().primary)
            .margin({ top: 3 })
            .maxLines(1)
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 12 })

      // 单条删除入口：选择模式下让位给勾选
      if (!this.selectionMode) {
        Text('删除')
          .fontSize(12)
          .fontColor(this.pal().textTertiary)
          .height(32)
          .padding({ left: 10, right: 4 })
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.deleteOne(item);
          })
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .borderRadius(AppTheme.radius)
    .onClick(() => {
      if (this.selectionMode) {
        this.toggleSelect(item.uri);
        return;
      }
      const list: VideoItem[] = this.filtered();
      let idx: number = list.findIndex((it: VideoItem) => it.uri === item.uri);
      if (idx < 0) {
        idx = 0;
      }
      this.play(list, idx);
    })
    .gesture(LongPressGesture().onAction(() => {
      if (!this.selectionMode) {
        this.selectionMode = true;
        this.toggleSelect(item.uri);
        // 进入多选即暂停回缩，保证胶囊在选中过程中始终可点
        this.armCapsuleRetract();
      }
    }))
  }

  @Builder
  folderHeader(name: string, count: number) {
    Row() {
      Text(name)
        .fontSize(13)
        .fontColor(this.pal().textSecondary)
        .fontWeight(FontWeight.Medium)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(`${count}`)
        .fontSize(12)
        .fontColor(this.pal().textTertiary)
    }
    .width('100%')
    .height(36)
    .padding({ left: 0, right: 8 })
    .backgroundColor(this.pal().bg)
  }

  /** 视频页分组标题：左侧竖条 + 标题 + 右侧计数 */
  @Builder
  sectionHeader(title: string, meta: string) {
    Row() {
      Row()
        .width(3)
        .height(14)
        .borderRadius(2)
        .backgroundColor(this.pal().primary)
        .margin({ right: 8 })
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.pal().textPrimary)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (meta.length > 0) {
        Text(meta)
          .fontSize(12)
          .fontColor(this.pal().textTertiary)
      }
    }
    .width('100%')
    .height(36)
    .padding({ left: this.sidePad(), right: this.sidePad() })
  }

  /** 视频页可视高度（onAreaChange 实测，未测到时按 720 兜底） */
  private pageHeight(): number {
    return this.viewH > 0 ? this.viewH : 720;
  }

  /** 是否已导入本地视频：同屏形态下用它决定首帧先按哪一态渲染 */
  private hasLocal(): boolean {
    return this.items.length > 0;
  }

  // ---------------- 视频页分页：按内容高度自动判定 ----------------

  /** 一页可用高度：与各页布局同一口径（屏高 - 底部浮层占位） */
  private hAvail(): number {
    return Math.floor(this.pageHeight() - this.overlayTop());
  }

  /** 本地视频全量内容高度：预览列表只展示 2~3 行，实测拿不到全量高度，按整行行高换算 */
  private localContentHeight(): number {
    const n: number = this.filtered().length;
    if (n === 0) {
      return 0;
    }
    const cols: number = this.isWide ? (this.isPad ? 3 : 2) : 1;
    const rows: number = Math.ceil(n / cols);
    let h: number = SECTION_HEADER_H + rows * VIDEO_ROW_H;
    if (this.searching) {
      h += INLINE_SEARCH_H;
    }
    return h;
  }

  /** 内容是否已占满一页：阈值 98%，留出取整误差 */
  private fillsPage(h: number): boolean {
    const avail: number = this.hAvail();
    if (avail <= 0) {
      return false;
    }
    return h >= avail * FULL_THRESHOLD;
  }

  /** 形态取用：首帧测量完成前沿用 hasLocal()，避免首帧按空内容判定而闪一下 */
  private effectivePaged(): boolean {
    return this.pagingReady ? this.paged : this.hasLocal();
  }

  /** 合并同一帧内的多次触发，避免测量与状态写入互相引发重排风暴 */
  private scheduleRecalc(): void {
    if (this.recalcScheduled) {
      return;
    }
    this.recalcScheduled = true;
    setTimeout(() => {
      this.recalcScheduled = false;
      this.recalcPaging();
    }, 0);
  }

  /** 网络区内容高度上报（来自 NetPanel：虚拟化列表无法实测，按条目数估算） */
  private onNetContentH(h: number): void {
    // NetPanel 只报自身内容高；网络区整块还要带上区标题行
    const v: number = h > 0 ? Math.round(h) + SECTION_HEADER_H : 0;
    if (Math.abs(v - this.netContentH) < 1) {
      return;
    }
    this.netContentH = v;
    this.scheduleRecalc();
  }

  /**
   * 分页形态判定：
   *  - 任一区内容占满一页 → 分页形态，否则上下半屏同屏；
   *  - 首帧判定立即生效；此后回落需连续两次一致，并受最小滞留时间约束，避免临界抖动。
   */
  private recalcPaging(): void {
    // 视频页已改为页签制（局域网 / 本地视频各占一整页），不再按内容高度切换形态；
    // 这里只保留本地内容高度记录，其余判定逻辑与 Swiper 翻页一并废弃。
    if (this.hAvail() <= 0) {
      return;
    }
    this.localContentH = this.localContentHeight();
    this.pagingReady = true;
  }

  /** 期望的视频页：网络区满页而本地未满 → 网络页（浏览态由 onBrowseChange 单独定位，避免和手动切页打架） */
  private desiredVideoPage(): number {
    const localFull: boolean = this.fillsPage(this.localContentH);
    const netFull: boolean = this.netBrowsing || this.fillsPage(this.netContentH);
    return (netFull && !localFull) ? 1 : 0;
  }

  /**
   * 把 Swiper 对齐到目标页。
   *  - force=false：只在状态页位不一致时切，用于常规重算，避免每帧调用 changeIndex 抖动；
   *  - force=true：即使状态已一致也强制切一次；
   *  - heal=true：280ms 后再补一次索引对齐——Swiper 刚重建时 controller 可能尚未挂载，
   *    首帧 changeIndex 会静默失效且不抛错，状态对而显示错位就成了「卡在空白页」。
   */
  private alignVideoPage(target: number, force: boolean, heal: boolean = false): void {
    const page: number = this.paged ? target : 0;
    const changed: boolean = this.videoPage !== page;
    this.videoPage = page;
    if (!force && !changed) {
      return;
    }
    this.syncingVideoPage = true;
    try {
      this.swiperCtrl.changeIndex(page, false);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'swiper changeIndex failed page=%{public}d', page);
    }
    setTimeout(() => {
      this.syncingVideoPage = false;
    }, 400);
    if (!heal || !this.paged) {
      return;
    }
    setTimeout(() => {
      if (!this.paged) {
        return;
      }
      this.syncingVideoPage = true;
      try {
        this.swiperCtrl.changeIndex(this.videoPage, false);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'swiper heal failed page=%{public}d', this.videoPage);
      }
      setTimeout(() => {
        this.syncingVideoPage = false;
      }, 400);
    }, 280);
  }

  /** 点页位点直接跳页：本地页为空、翻页手势被禁时，这是用户唯一的翻到网络页入口 */
  private jumpVideoPage(target: number): void {
    if (!this.paged || this.videoPage === target) {
      return;
    }
    this.alignVideoPage(target, true, false);
  }

  // ---------------- 页签胶囊：悬浮回缩 ----------------

  /** 多选态与搜索输入中暂停回缩：胶囊必须保持可见可点，避免操作途中突然缩小造成误触 */
  private capsuleRetractPaused(): boolean {
    return this.selectionMode || this.searching;
  }

  /** 重置胶囊悬浮计时：任何一次点击或切页都重新计时，0 秒表示常驻展开 */
  private armCapsuleRetract(): void {
    if (this.retractTimer >= 0) {
      clearTimeout(this.retractTimer);
      this.retractTimer = -1;
    }
    if (this.capsuleRetractPaused()) {
      this.capsuleCollapsed = false;
      return;
    }
    const sec: number = this.capsuleRetractSec;
    if (!(sec > 0)) {
      this.capsuleCollapsed = false;
      return;
    }
    this.retractTimer = setTimeout(() => {
      this.retractTimer = -1;
      if (!this.capsuleCollapsed) {
        this.capsuleCollapsed = true;
      }
    }, sec * 1000);
  }

  /** 设置里改秒数：立即回到展开态并重新计时 */
  onRetractSecChanged(): void {
    this.capsuleCollapsed = false;
    this.armCapsuleRetract();
  }

  /** 设置里改落点：立刻按新对齐重排，同样重新计时 */
  onCapsuleAlignChanged(): void {
    this.armCapsuleRetract();
  }

  /** 点触胶囊：回缩态先展开并吃掉本次点击；返回 true 表示点击已被消费 */
  private onCapsuleTouch(): boolean {
    const now: number = Date.now();
    if (now - this.capsuleTapAt < CAPSULE_TAP_GUARD_MS) {
      return true;
    }
    this.capsuleTapAt = now;
    if (this.capsuleCollapsed) {
      this.capsuleCollapsed = false;
      this.armCapsuleRetract();
      return true;
    }
    this.armCapsuleRetract();
    return false;
  }

  /** 无障碍朗读文案：展开态告知当前选中页签 */
  private capsuleA11yText(): string {
    if (this.currentTab === 0) {
      return '页签：视频，已选中';
    }
    if (this.currentTab === 1) {
      return '页签：音乐，已选中';
    }
    return '页签：设置，已选中';
  }

  /** 胶囊宽度：回缩固定 48，展开按屏宽 86%（宽屏 420） */
  private capsuleWidth(): Length {
    if (this.capsuleCollapsed) {
      return CAPSULE_COLLAPSED_SIZE;
    }
    return this.isWide ? 420 : '86%';
  }

  /** 胶囊回缩后的落点（设置-外观-页签悬浮位置）：靠左 / 居中 / 靠右；展开态始终居中 */
  private capsuleAlignMode(): HorizontalAlign {
    if (this.capsuleAlign === 'left') {
      return HorizontalAlign.Start;
    }
    if (this.capsuleAlign === 'right') {
      return HorizontalAlign.End;
    }
    return HorizontalAlign.Center;
  }

  /** 「本地视频」区在同屏模式下占半屏（约 50%），整页模式下由整页接管 */
  private localSectionHeight(): number {
    return Math.round(this.pageHeight() * 0.5);
  }

  /** 「局域网 / 网络源」区高度：至少容下 TV 卡 + 协议行 + 按钮行 + 服务器列表，避免内容溢出被裁而点不到 */
  private netSectionHeight(): number {
    const rest: number = this.pageHeight() - this.localSectionHeight() - 48 - this.overlayTop();
    return Math.max(430, rest);
  }

  /** 已进入目录浏览时网络区放大到近乎整页，保证目录列表有足够的可见高度 */
  private netFillHeight(): number {
    return Math.max(320, this.pageHeight() - 48 - this.overlayTop());
  }

  /** 本地页里空态占的高度：半屏，避免首屏大片空白 */
  private emptyBlockHeight(): number {
    return Math.max(160, Math.round(this.pageHeight() * 0.5) - 40);
  }

  /**
   * 翻到指定整页：带冷却锁 + 动画，返回 true 表示本次真的翻了页。
   * 调用方（页内滚动到边界的手势回调）据此决定是否吃掉这一帧的滚动偏移。
   */
  private flipTo(target: number): boolean {
    if (this.flipLock || this.videoTab === target || target < 0 || target > 1) {
      return false;
    }
    this.flipLock = true;
    this.videoTab = target;
    setTimeout(() => {
      this.flipLock = false;
    }, 420);
    return true;
  }

  /** 本地页：已滚到内容尽头后继续上滑 → 翻到局域网页 */
  private onLocalFrameBegin(offset: number): number {
    if (offset >= -1) {
      return offset;
    }
    let atEnd: boolean = false;
    try {
      atEnd = this.localScroll.isAtEnd();
    } catch (err) {
      atEnd = false;
    }
    if (atEnd && this.flipTo(1)) {
      return 0;
    }
    return offset;
  }

  /** 局域网页：已在顶部还继续下滑 → 回本地页（父级回调给 NetPanel 用） */
  private pullBackToLocal(): boolean {
    return this.flipTo(0);
  }

  /** 本地视频默认展示行数：按分区高度算，限 2~3 行 */
  private previewRows(): number {
    const usable: number = this.localSectionHeight() - 40;
    const rowH: number = 92;
    const rows: number = Math.floor(usable / rowH);
    return Math.max(2, Math.min(3, rows));
  }

  /** 本地视频默认展示条数（宽屏按多列换算） */
  private previewCount(): number {
    const rows: number = this.previewRows();
    if (!this.isWide) {
      return rows;
    }
    return rows * (this.isPad ? 3 : 2);
  }

  /** 预览条目：超出上限的部分交给「查看全部」 */
  private previewItems(): VideoItem[] {
    const list: VideoItem[] = this.filtered();
    const limit: number = this.previewCount();
    return list.length <= limit ? list : list.slice(0, limit);
  }

  /** 「本地视频」分组标题：右侧计数 + 排序/搜索入口（不再常驻顶栏）+ 超量时的「查看全部」 */
  @Builder
  localSectionHeader() {
    Row() {
      Row()
        .width(3)
        .height(14)
        .borderRadius(2)
        .backgroundColor(this.pal().primary)
        .margin({ right: 8 })
      Text('本地视频')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.pal().textPrimary)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.filtered().length > 0) {
        Text(`${this.filtered().length} 个`)
          .fontSize(12)
          .fontColor(this.pal().textTertiary)
          .margin({ right: 6 })
      }
      if (this.filtered().length > this.previewCount()) {
        Text('查看全部 ›')
          .fontSize(12)
          .fontColor(this.pal().primary)
          .height(26)
          .padding({ left: 10, right: 2 })
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.openAllLocal();
          })
      }
      this.listChipIcon('↕', this.sortLabel(), this.sortMode !== SortMode.ADDED, () => {
        this.showSortMenu();
      })
      this.listChipIcon(this.searching ? '×' : '⌕', '', this.searching, () => {
        this.searching = !this.searching;
        if (!this.searching) {
          this.keyword = '';
        }
        // 搜索输入中暂停回缩，退出搜索后重新计时
        this.armCapsuleRetract();
      })
    }
    .width('100%')
    .height(40)
    .padding({ left: this.sidePad(), right: this.sidePad() })
  }

  /** 列表内的小图标按钮：28vp 玻璃底，触控热区用 padding 撑到 40vp */
  @Builder
  listChipIcon(glyph: string, label: string, active: boolean, action: () => void) {
    Row() {
      Text(glyph)
        .fontSize(16)
        .fontColor(active ? Color.White : this.pal().textSecondary)
      if (label.length > 0 && this.isWide) {
        Text(label)
          .fontSize(11)
          .fontColor(active ? Color.White : this.pal().textSecondary)
          .margin({ left: 2 })
      }
    }
    .height(28)
    .padding({ left: 8, right: 8 })
    .borderRadius(14)
    .backgroundColor(active ? this.pal().primary : this.pal().bgChip)
    .justifyContent(FlexAlign.Center)
    .margin({ left: 6 })
    .onClick(action)
  }

  /** 当前排序方式的短名 */
  private sortLabel(): string {
    if (this.sortMode === SortMode.NAME) {
      return '名称';
    }
    if (this.sortMode === SortMode.DURATION) {
      return '时长';
    }
    if (this.sortMode === SortMode.SIZE) {
      return '大小';
    }
    return '添加';
  }

  /** 列表内展开的搜索框：从列表头部唤起，不再占用顶栏空间 */
  @Builder
  inlineSearch() {
    Row() {
      TextInput({ placeholder: '搜索标题或文件夹', text: this.keyword })
        .layoutWeight(1)
        .height(36)
        .fontSize(14)
        .backgroundColor(this.pal().bgChip)
        .fontColor(this.pal().textPrimary)
        .placeholderColor(this.pal().textTertiary)
        .borderRadius(18)
        .onChange((v: string) => {
          this.keyword = v;
          this.scheduleRecalc();
        })
      Text('取消')
        .fontSize(13)
        .fontColor(this.pal().primary)
        .padding({ left: 10 })
        .height(36)
        .onClick(() => {
          this.searching = false;
          this.keyword = '';
          this.scheduleRecalc();
          this.armCapsuleRetract();
        })
    }
    .width('100%')
    .height(44)
    .padding({ left: this.sidePad(), right: this.sidePad() })
  }

  /** 本地视频预览：固定高度、不内嵌滚动，超量条目交给「查看全部」页 */
  @Builder
  localPreviewList() {
    Column() {
      if (this.filtered().length === 0) {
        this.emptyView()
      } else if (this.isWide) {
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Start }) {
          ForEach(this.previewItems(), (item: VideoItem, index: number) => {
            Column() {
              this.videoRow(item, index)
            }
            .width(this.isPad ? '33.3%' : '50%')
            .padding({ left: this.sidePad() / 2, right: this.sidePad() / 2 })
          }, (item: VideoItem) => `${item.uri}_${item.durationMs}`)
        }
        .width('100%')
      } else {
        Column() {
          ForEach(this.previewItems(), (item: VideoItem, index: number) => {
            this.videoRow(item, index)
          }, (item: VideoItem) => `${item.uri}_${item.durationMs}`)
        }
        .width('100%')
        .padding({ left: AppTheme.pagePadding, right: 4 })
      }
    }
    .width('100%')
    .height(this.localSectionHeight() - 40)
    .clip(true)
  }

  // ---------------- 视频页：整页翻页布局 ----------------
  // 第 1 页「本地视频」：整页高，列表在页内滚动，滚到尽头继续上滑即翻到第 2 页。
  // 第 2 页「局域网 / 网络源」：整页高，NetPanel 内部列表滚到顶后继续下滑回第 1 页。
  // 外层 Swiper 关闭自身滑动（disableSwipe），手势完全交给页内列表，翻页由边界回调驱动，
  // 避免 Swiper 与内嵌列表抢滑动。

  /** 视频页顶部页签：局域网（最左） / 本地视频，各占一整页 */
  @Builder
  videoTabBar() {
    Row() {
      this.videoTabItem('局域网', 0)
      this.videoTabItem('本地视频', 1)
      if (this.videoTab === 1) {
        this.addChip()
      }
      Blank()
    }
    .width('100%')
    .height(44)
    .padding({ left: this.sidePad(), right: this.sidePad() })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  videoTabItem(label: string, index: number) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.videoTab === index ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.videoTab === index ? Color.White : this.pal().textSecondary)
      .backgroundColor(this.videoTab === index ? this.pal().primary : this.pal().bgChip)
      .borderRadius(15)
      .height(30)
      .padding({ left: 16, right: 16 })
      .margin({ right: 8 })
      .textAlign(TextAlign.Center)
      .onClick(() => {
        if (this.videoTab === index) {
          return;
        }
        this.videoTab = index;
        this.armCapsuleRetract();
      })
  }

  /** 第 1 页：本地视频整页 */
  @Builder
  videoLocalPage() {
    List({ space: 0, scroller: this.localScroll }) {
      ListItem() {
        Column() {
          this.localSectionHeader()
          if (this.searching) {
            this.inlineSearch()
          }
        }
        .width('100%')
      }
      if (this.filtered().length === 0) {
        ListItem() {
          Column() {
            this.emptyView()
          }
          .width('100%')
          .height(this.emptyBlockHeight())
        }
      } else if (this.isWide) {
        ListItem() {
          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Start }) {
            ForEach(this.filtered(), (item: VideoItem, index: number) => {
              Column() {
                this.videoRow(item, index)
              }
              .width(this.isPad ? '33.3%' : '50%')
              .padding({ left: this.sidePad() / 2, right: this.sidePad() / 2 })
            }, (item: VideoItem) => `${item.uri}_${item.durationMs}`)
          }
          .width('100%')
        }
      } else {
        ListItem() {
          Column() {
            ForEach(this.filtered(), (item: VideoItem, index: number) => {
              this.videoRow(item, index)
            }, (item: VideoItem) => `${item.uri}_${item.durationMs}`)
          }
          .width('100%')
          .padding({ left: AppTheme.pagePadding, right: 4 })
        }
      }
      // 页尾留白：保证最后一条内容能滚到胶囊上方，不被底部浮层压住
      ListItem() {
        Row()
          .width('100%')
          .height(this.overlayTop())
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onScrollFrameBegin((offset: number, state: ScrollState) => {
      return { offsetRemain: this.onLocalFrameBegin(offset) };
    })
  }

  /** 第 2 页：局域网整页（网络源面板，底部留白避让胶囊与页签） */
  @Builder
  videoNetPage() {
    Column() {
      Column() {
        NetPanel({
          tick: this.netTick,
          onPullBack: (): boolean => this.pullBackToLocal(),
          onBrowseChange: (browsing: boolean): void => {
            // 分页形态下同样要跟踪浏览态：退出浏览（服务器列表）时要能回落到同屏形态
            this.netBrowsing = browsing;
            this.scheduleRecalc();
          },
          onContentH: (h: number): void => {
            this.onNetContentH(h);
          }
        })
      }
      .width('100%')
      .layoutWeight(1)
      Row()
        .width('100%')
        .height(this.overlayTop())
    }
    .width('100%')
    .height('100%')
  }

  /** 未导入本地视频时：本地空态与网络源上下半屏同屏可见（不启用整页翻页） */
  @Builder
  videoStacked() {
    Scroll(this.pageScroll) {
      Column() {
        if (!this.netBrowsing) {
          this.localSectionHeader()
          if (this.searching) {
            this.inlineSearch()
          }
          this.localPreviewList()

          Divider()
            .strokeWidth(0.5)
            .color(this.pal().divider)
            .margin({ top: 6, bottom: 2 })
        }

        this.sectionHeader('局域网 / 网络源', '')
        Column() {
          NetPanel({
            tick: this.netTick,
            onBrowseChange: (browsing: boolean): void => {
              this.netBrowsing = browsing;
              // 浏览态切换会改变网络区高度，需重算「是否占满一页」
              this.scheduleRecalc();
              if (browsing) {
                // 进入目录浏览：把网络区顶到屏幕顶部，让目录列表占满可视区
                try {
                  this.pageScroll.scrollEdge(Edge.Top);
                } catch (err) {
                }
                // 分页形态下同步切到网络页：目录内容全在网络区，停在本地页等于什么都看不到
                if (this.paged) {
                  this.alignVideoPage(1, true, true);
                }
              }
            },
            onContentH: (h: number): void => {
              this.onNetContentH(h);
            }
          })
        }
        .width('100%')
        .height(this.netBrowsing ? this.netFillHeight() : this.netSectionHeight())

        Row()
          .width('100%')
          .height(this.overlayTop())
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        this.buildToolbar()

      Stack({ alignContent: Alignment.Bottom }) {
        Tabs({ barPosition: BarPosition.Start, index: this.currentTab, controller: this.tabsController }) {
          TabContent() {
            // 视频页：页签制（局域网 | 本地视频），各自占一整页，互不挤占
            Column() {
              this.videoTabBar()
              Column() {
                if (this.videoTab === 0) {
                  this.videoNetPage()
                } else {
                  this.videoLocalPage()
                }
              }
              .width('100%')
              .layoutWeight(1)
            }
            .width('100%')
            .height('100%')
          }
          .tabBar('')

          TabContent() {
            Column() {
              MusicPanel({ capsuleReserve: this.overlayTop() })
            }
            .width('100%')
            .height('100%')
          }
          .tabBar('')

          TabContent() {
            SettingsPanel()
          }
          .tabBar('')
        }
        .barHeight(0)
        .barMode(BarMode.Fixed)
        .width('100%')
        .height('100%')
        .onChange((index: number) => {
          this.currentTab = index;
          this.searching = false;
          this.keyword = '';
          this.selectionMode = false;
          this.selectedUris = [];
          this.refreshResume();
          this.armCapsuleRetract();
        })

        Column() {
          // 视频页不显示「共 N 个视频 · 已记忆 M 条进度」；设置/音乐页的状态行文案已按要求隐藏，
          // 文案为空时不再渲染该行，避免留下空白占位
          if (this.currentTab !== 0 && this.statusText().length > 0) {
            Row() {
              this.statusRow()
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
          }
          this.capsuleBar()
        }
        .width('100%')
        .padding({ left: 8, right: 8 })
        // 回缩态按设置停靠（靠左 / 居中 / 靠右），为了不挡内容；展开后一律居中摆正
        .alignItems(this.capsuleCollapsed ? this.capsuleAlignMode() : HorizontalAlign.Center)
        .zIndex(10)
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .width('100%')
      .layoutWeight(1)
      // 实测可视高度：本地视频区按屏高 38% 计算，局域网源区吃余下空间
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const h: number = Number(newValue.height);
        if (h > 0 && Math.abs(h - this.viewH) > 1) {
          this.viewH = h;
          // 屏高变化（旋转 / 分屏 / 软键盘）会改变一页可用高度，需重算分页形态
          this.scheduleRecalc();
        }
      })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pal().bg)

      // 「+」已固定在视频页右上角顶栏内（addButton），不再挂右下角悬浮按钮

      // 音源沙箱宿主：全局唯一挂载（x1 近透明），音乐页与音乐设置都依赖它
      SourceSandboxHost()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pal().bg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
