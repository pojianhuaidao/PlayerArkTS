import { media } from '@kit.MediaKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { window, router, promptAction, mediaquery } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError, emitter } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppTheme, Palette } from '../common/AppTheme';
import { VideoItem, formatDuration } from '../model/VideoItem';
import { PlaylistHolder, PlayerPrefs } from '../model/PlayerPrefs';
import { SubtitleCue, SubtitleFrame, SubtitleParser, SubtitleRun } from '../utils/Subtitle';
import { SubtitleFinder, SubtitleItem } from '../utils/SubtitleFinder';
import { SoftPipeline } from '../utils/SoftPipeline';
import { PlayIconSet } from '../common/PlayIconSet';
import { AVCastPicker } from '@kit.AVSessionKit';
import { AVCastPickerState } from '@ohos.multimedia.avCastPickerParam';
import { CastSessionHelper } from '../tvbox/utils/CastSessionHelper';
import { CastPhase, CastRenderer, CastStatus, DlnaCast } from '../model/upnp/DlnaCast';
import { TvCacheStore } from '../utils/TvCacheStore';
import { CACHE_PREPARE_EVENT_ID } from '../utils/CacheCleaner';

const TAG: string = 'PlayerPage';
const DOMAIN: number = 0x0001;
const SEEK_STEP_MS: number = 10000;
const CONTROLS_TIMEOUT_MS: number = 3500;
/** 与视图层手势判定阈值（vp） */
const PAN_THRESHOLD: number = 12;
/**
 * 屏幕方向的「请求令牌」。
 * 上一页 aboutToDisappear 里的方向恢复是异步的，它可能在新页面设置方向之后才落地，
 * 把新页面的横屏请求又刷回 UNSPECIFIED，表现就是「只有第一次打开会切屏」。
 * 用递增令牌作废过期请求，只让最新一次方向设置生效。
 */
let orientToken: number = 0;

enum AspectMode {
  CONTAIN = 0,
  COVER = 1,
  ORIGINAL = 2
}

enum GestureKind {
  NONE = 0,
  SEEK = 1,
  VOLUME = 2,
  BRIGHTNESS = 3
}

class TrackEntry {
  index: number;
  name: string;
  type: string;

  constructor(index: number, name: string, type: string) {
    this.index = index;
    this.name = name;
    this.type = type;
  }
}

/**
 * 播放内核（本地 / 网络源共用）。
 * 原 pages/PlayerPage.ets 的完整实现搬到这里，页面只做路由壳：
 * 本地点播走 pages/LocalPlayerPage，网络源与其它入口走 pages/PlayerPage。
 */
@Component
export struct PlayerCore {
  @StorageProp('isDark') isDark: boolean = true;

  pal(): Palette {
    return AppTheme.palette(this.isDark);
  }

  @State positionMs: number = 0;
  @State durationMs: number = 0;
  @State isPlaying: boolean = false;
  @State controlsVisible: boolean = true;
  @State locked: boolean = false;
  @State title: string = '';
  @State playlistIndex: number = 0;
  @State playlistSize: number = 0;
  @State speed: number = 1.0;
  @State aspect: AspectMode = AspectMode.CONTAIN;
  @State loopSingle: boolean = false;
  @State subtitleText: string = '';
  /** ASS/SSA 当前帧：多段样式文本（颜色/字号/粗斜体/描边/阴影） */
  @State subRuns: SubtitleRun[] = [];
  /** 当前帧整体透明度（\fad 淡入淡出） */
  @State subOpacity: number = 1;
  /** \an1~\an9 对齐 */
  @State subAlign: number = 2;
  /** \pos / \move 归一化坐标（-1 表示无绝对定位） */
  @State subXRatio: number = -1;
  @State subYRatio: number = -1;
  /** \frz 旋转角度 */
  @State subRotate: number = 0;
  @State overlayKind: GestureKind = GestureKind.NONE;
  @State overlayText: string = '';
  @State overlayPercent: number = 0;
  @State videoW: number = 0;
  @State videoH: number = 0;
  /** 播放画面盒子（vp）：按视频宽高比等比放进容器后的真实画面尺寸 */
  @State videoBoxW: number = 0;
  @State videoBoxH: number = 0;
  @State ready: boolean = false;
  @State errorMsg: string = '';
  @State subtitleLoaded: boolean = false;
  @State gestureEnabled: boolean = true;
  @State menuVisible: boolean = false;
  @State menuItems: MenuElement[] = [];
  @State isWide: boolean = false;
  /** 当前屏幕是否处于横屏（跟随真实旋转状态，供手动切换按钮判断） */
  @State screenLandscape: boolean = false;
  @State decodeHint: string = '';
  @State subDlgVisible: boolean = false;
  @State subLoading: boolean = false;
  @State subFailed: string = '';
  @State subKeyword: string = '';
  @State subResults: SubtitleItem[] = [];
  @State subDirectUrl: string = '';
  @State subFromOs: boolean = false;
  /** 「更多」浮层：放不下的次要控件收在这里，保证底部图标组永不出屏 */
  @State morePanelVisible: boolean = false;
  /** 音量浮层（图标点击后展开滑杆） */
  @State volumePanelVisible: boolean = false;
  /** 投屏会话（AVSession + AVCastPicker），投屏按钮的状态回显 */
  @State castActive: boolean = false;

  /** DLNA 投屏（发送端）：设备选择弹层 + 播放状态 */
  @State castSheetOpen: boolean = false;
  @State castBusy: boolean = false;
  @State castTip: string = '';
  @State castError: string = '';
  @State castRenderers: CastRenderer[] = [];
  @State castPhase: CastPhase = CastPhase.IDLE;
  @State castDevice: string = '';
  @State castPosition: number = -1;
  private castTimer: number = -1;
  /** 音量滑杆显示值（与 currentVolume 同步，供音量浮层使用） */
  @State volumeLevel: number = 1;
  private castHelper: CastSessionHelper = new CastSessionHelper();

  private avPlayer: media.AVPlayer | undefined = undefined;
  private xController: XComponentController = new XComponentController();
  private surfaceId: string = '';
  /** 等 XComponent 出 surface 的排队回调：surface 迟到时用它唤醒 openUri */
  private surfaceWaiters: Array<(id: string) => void> = [];
  /** prepared 之后才拿到 surface 时，允许重开一次播放器补绑 */
  private surfaceRetryUsed: boolean = false;
  private file: fs.File | undefined = undefined;
  private cues: SubtitleCue[] = [];
  private hideTimerId: number = -1;
  private gestureKind: GestureKind = GestureKind.NONE;
  private panStartPosition: number = 0;
  private panStartVolume: number = 1;
  private panStartBrightness: number = 0.5;
  private currentVolume: number = 1;
  private currentBrightness: number = 0.5;
  private longPressBoost: boolean = false;
  private seekPreviewMs: number = 0;
  private containerW: number = 0;
  private containerH: number = 0;
  private audioTracks: TrackEntry[] = [];
  private subtitleTracks: TrackEntry[] = [];
  private softPipeline: SoftPipeline | undefined = undefined;
  private softFile: fs.File | undefined = undefined;
  private currentUri: string = '';
  private decodeMode: string = 'auto';
  private posTimerId: number = -1;
  /** 5400102 自动重开只做一次，避免死循环 */
  private reopenTried: boolean = false;
  /** surface 是否已绑定到当前 player（prepared 之后再绑定会报 5400102）*/
  private surfaceBound: boolean = false;
  private lastSavedSec: number = -1;
  /** 用户是否手动指定过屏幕方向：指定后本条视频内不再按宽高比自动切 */
  private manualOrient: boolean = false;
  /** 页面是否已销毁，销毁后不再发起方向请求 */
  private disposed: boolean = false;
  /** 方向兜底重试定时器句柄 */
  private orientRetryTimer: number = -1;
  private wideListener: mediaquery.MediaQueryListener = mediaquery.matchMediaSync('(min-width: 600vp)');
  private orientListener: mediaquery.MediaQueryListener = mediaquery.matchMediaSync('(orientation: landscape)');
  /** 清除缓存放掉了播放器，下次点播放需要重新 open 当前条目 */
  private reloadAfterCacheClear: boolean = false;
  private cachePrepareListener: (data: emitter.EventData) => void =
    (_data: emitter.EventData): void => {
      this.onCachePrepare();
    };

  aboutToAppear(): void {
    // 作废上一页遗留的方向恢复请求，否则它会把本页的横屏请求覆盖掉
    orientToken++;
    this.enterFullScreen();
    this.gestureEnabled = PlayerPrefs.isGestureEnabled();
    this.speed = PlayerPrefs.getDefaultSpeed();
    this.decodeMode = PlayerPrefs.getDecodeMode();
    this.isWide = this.wideListener.matches;
    this.wideListener.on('change', (r: mediaquery.MediaQueryResult) => {
      this.isWide = r.matches;
    });
    this.screenLandscape = this.orientListener.matches;
    this.orientListener.on('change', (r: mediaquery.MediaQueryResult) => {
      this.screenLandscape = r.matches;
    });
    const items: VideoItem[] = PlaylistHolder.items;
    this.playlistIndex = PlaylistHolder.index;
    this.playlistSize = items.length;
    if (items.length === 0) {
      this.errorMsg = '没有可播放的视频';
      return;
    }
    this.openCurrent();
    this.scheduleHide();
    this.initCastSession();
    try {
      TvCacheStore.init(this.getUIContext().getHostContext() as common.UIAbilityContext);
      emitter.on(CACHE_PREPARE_EVENT_ID, this.cachePrepareListener);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'init cache bridge failed');
    }
  }

  /** 初始化投屏会话（失败不影响本地播放） */
  private initCastSession(): void {
    try {
      const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.castHelper.ensure(ctx).then((): void => {
        this.castActive = this.castHelper.isCasting;
        this.updateCastMeta();
      }).catch((): void => {
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'initCastSession failed');
    }
  }

  /**
   * 清除缓存前释放播放器：网络/局域网播放的缓冲分片被媒体服务持有，
   * 不释放文件句柄，CacheCleaner 的 unlink 会静默失败（缓存清不掉的根因）。
   * 本地文件播放不产生流缓存，不做打断。
   */
  private onCachePrepare(): void {
    if (!this.isNetworkUri(this.currentUri)) {
      return;
    }
    this.saveProgress();
    this.reloadAfterCacheClear = true;
    this.isPlaying = false;
    this.releasePlayer();
    promptAction.showToast({ message: '正在清理缓存，当前播放已停止' });
  }

  /** 同步投屏元数据（标题 + 当前播放地址） */
  private updateCastMeta(): void {
    try {
      this.castHelper.updateMetadata(this.title, '', `${this.playlistIndex + 1}/${this.playlistSize}`, this.currentUri)
        .catch((): void => {
        });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'updateCastMeta failed');
    }
  }

  // ---------------- DLNA 投屏（发送端） ----------------

  /** 投屏按钮文案：未连接 / 正在投屏 / 已暂停 */
  private castLabel(): string {
    if (this.castPhase === CastPhase.PLAYING) {
      return '投屏中';
    }
    if (this.castPhase === CastPhase.PAUSED) {
      return '已暂停';
    }
    if (this.castPhase === CastPhase.CONNECTING) {
      return '连接中';
    }
    if (this.castPhase === CastPhase.ERROR) {
      return '投屏失败';
    }
    return '投屏';
  }

  private castTint(): ResourceColor {
    return this.castPhase === CastPhase.IDLE || this.castPhase === CastPhase.ERROR ?
      Color.White : this.pal().primary;
  }

  /** 可投送的地址：仅 http(s) 直链，渲染器无法直接拉取本地文件 */
  private castableUrl(): string {
    const uri: string = this.currentUri;
    if (uri.startsWith('http://') || uri.startsWith('https://')) {
      return uri;
    }
    return '';
  }

  private castMime(title: string): string {
    const dot: number = title.lastIndexOf('.');
    const ext: string = dot >= 0 ? title.substring(dot + 1).toLowerCase() : '';
    if (ext === 'mp4' || ext === 'm4v') {
      return 'video/mp4';
    }
    if (ext === 'mkv') {
      return 'video/x-matroska';
    }
    if (ext === 'ts' || ext === 'm2ts') {
      return 'video/mp2t';
    }
    if (ext === 'mov') {
      return 'video/quicktime';
    }
    if (ext === 'avi') {
      return 'video/x-msvideo';
    }
    if (ext === 'webm') {
      return 'video/webm';
    }
    if (ext === 'flv') {
      return 'video/x-flv';
    }
    if (ext === 'mp3') {
      return 'audio/mpeg';
    }
    return 'video/mp4';
  }

  private openCastSheet(): void {
    this.castSheetOpen = true;
    this.scanCast();
  }

  /** SSDP 搜索 MediaRenderer（与 DLNA 浏览复用同一套发现逻辑） */
  private async scanCast(): Promise<void> {
    if (this.castBusy) {
      return;
    }
    this.castBusy = true;
    this.castError = '';
    this.castTip = '正在搜索可投屏设备…';
    const list: CastRenderer[] = await DlnaCast.discover(2600);
    this.castBusy = false;
    this.castRenderers = list;
    if (list.length === 0) {
      this.castTip = '未发现设备';
      this.castError = DlnaCast.errorText.length > 0 ? DlnaCast.errorText :
        '没有发现可投屏设备，请确认电视/盒子与手机在同一 Wi-Fi 且已开启投屏接收';
    } else {
      this.castTip = `发现 ${list.length} 台设备`;
    }
  }

  /** 选中设备：连接 → SetAVTransportURI + Play → 暂停本地播放 → 开始状态轮询 */
  private async pickCast(renderer: CastRenderer): Promise<void> {
    const url: string = this.castableUrl();
    if (url.length === 0) {
      promptAction.showToast({ message: '本地文件无法直接投送，请用网络源（http）播放后再投屏' });
      return;
    }
    this.castBusy = true;
    const ok: boolean = await DlnaCast.connect(renderer.udn);
    if (!ok) {
      this.castBusy = false;
      promptAction.showToast({ message: DlnaCast.errorText.length > 0 ? DlnaCast.errorText : '连接投屏设备失败' });
      return;
    }
    const casting: boolean = await DlnaCast.castUrl(url, this.title, this.castMime(this.title), 0);
    this.castBusy = false;
    if (!casting) {
      promptAction.showToast({ message: DlnaCast.errorText.length > 0 ? DlnaCast.errorText : '投屏指令被设备拒绝' });
      return;
    }
    this.castSheetOpen = false;
    this.castDevice = renderer.name;
    this.castPhase = DlnaCast.status;
    // 投屏期间本地播放器暂停，画面交给大屏
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (player !== undefined && this.isPlaying) {
      player.pause();
    }
    this.startCastPoll();
    promptAction.showToast({ message: `已投屏到 ${renderer.name}` });
  }

  private startCastPoll(): void {
    this.stopCastPoll();
    this.castTimer = setInterval((): void => {
      this.refreshCastStatus();
    }, 3000);
  }

  private stopCastPoll(): void {
    if (this.castTimer >= 0) {
      clearInterval(this.castTimer);
      this.castTimer = -1;
    }
  }

  /** 轮询传输状态：把电视端的进度与播放/暂停状态同步回控制条 */
  private async refreshCastStatus(): Promise<void> {
    if (!DlnaCast.connected) {
      this.stopCastPoll();
      this.castPhase = CastPhase.IDLE;
      return;
    }
    const st: CastStatus = await DlnaCast.fetchStatus();
    this.castPhase = st.phase;
    this.castDevice = DlnaCast.deviceName;
    if (st.positionSec >= 0) {
      this.castPosition = st.positionSec;
      this.positionMs = st.positionSec * 1000;
    }
    if (st.durationSec > 0) {
      this.durationMs = st.durationSec * 1000;
    }
    if (st.phase === CastPhase.IDLE) {
      this.stopCastPoll();
    }
  }

  /** 主动断开：Stop 通知渲染器并回到未连接态 */
  private async stopCasting(): Promise<void> {
    this.stopCastPoll();
    await DlnaCast.disconnect(true);
    this.castPhase = CastPhase.IDLE;
    this.castDevice = '';
    this.castPosition = -1;
    promptAction.showToast({ message: '已停止投屏' });
  }

  aboutToDisappear(): void {
    this.saveProgress();
    // 先恢复跟随系统方向，再标记销毁，避免残留的方向请求串到下一个页面
    this.restoreOrientation();
    if (this.orientRetryTimer >= 0) {
      clearTimeout(this.orientRetryTimer);
      this.orientRetryTimer = -1;
    }
    // 退出播放页断开 DLNA 投屏：通知渲染器停止，避免电视端继续播放
    this.stopCastPoll();
    if (DlnaCast.isCasting || DlnaCast.connected) {
      DlnaCast.disconnect(true).catch((): void => {
      });
    }
    this.disposed = true;
    this.exitFullScreen();
    this.releasePlayer();
    this.closeFile();
    this.castHelper.release().catch((): void => {
    });
    this.wideListener.off('change');
    this.orientListener.off('change');
    try {
      emitter.off(CACHE_PREPARE_EVENT_ID, this.cachePrepareListener);
    } catch (e) {
    }
  }

  onPageHide(): void {
    this.saveProgress();
    // 对应 MX 的后台播放开关；未开启则离开页面即暂停
    if (!PlayerPrefs.isBackgroundPlay() && this.avPlayer !== undefined && this.isPlaying) {
      this.avPlayer.pause();
    }
  }

  // ---------------- 播放器生命周期 ----------------

  private currentItem(): VideoItem | undefined {
    const items: VideoItem[] = PlaylistHolder.items;
    if (this.playlistIndex < 0 || this.playlistIndex >= items.length) {
      return undefined;
    }
    return items[this.playlistIndex];
  }

  private async openCurrent(retry: boolean = false): Promise<void> {
    if (!retry) {
      this.reopenTried = false;
    }
    this.saveProgress();
    const item: VideoItem | undefined = this.currentItem();
    if (item === undefined) {
      return;
    }
    this.title = item.title;
    this.ready = false;
    this.errorMsg = '';
    this.cues = [];
    this.subtitleLoaded = false;
    this.subtitleText = '';
    this.positionMs = 0;
    this.durationMs = item.durationMs;
    // 换片即恢复「按宽高比自动定方向」，并清掉上一条视频留下的画面尺寸与裁剪状态
    this.manualOrient = false;
    // 列表扫描时已拿到分辨率，先兜底用上：即便 videoSizeChange 没回调，
    // 也能立刻按片源宽高比定方向，不会出现「自适应不出来」
    this.videoW = item.width;
    this.videoH = item.height;
    this.videoBoxW = 0;
    this.videoBoxH = 0;
    this.aspect = AspectMode.CONTAIN;
    await this.openUri(item.uri, item.headers);
    // 起播后再按片源比例校正一次（探针数据缺失时靠视频真实回调补）
    this.applyOrientationByRatio();
    this.updateCastMeta();
  }

  /**
   * 把 XComponent 的 surfaceId 绑到播放器上。
   * 关键：surfaceId 在 idle 阶段设置会被播放器内部重置，必须在 initialized 之后设。
   * force=true 时忽略 surfaceBound 缓存重设一次，用于 initialized / prepared 阶段纠偏。
   */
  private applySurface(player: media.AVPlayer, force: boolean, phase: string): void {
    if (this.surfaceId.length === 0) {
      return;
    }
    if (!force && this.surfaceBound) {
      return;
    }
    try {
      player.surfaceId = this.surfaceId;
      this.surfaceBound = true;
      hilog.info(DOMAIN, TAG, 'surface bound at %{public}s', phase);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      this.surfaceBound = false;
      hilog.warn(DOMAIN, TAG, 'bind surfaceId failed at %{public}s code=%{public}d', phase, e.code);
    }
  }

  /** 读回播放器当前 surfaceId，判断绑定是否真的生效 */
  private surfaceMatched(player: media.AVPlayer): boolean {
    try {
      return String(player.surfaceId) === this.surfaceId;
    } catch (err) {
      return false;
    }
  }

  /**
   * 等 XComponent 的 surfaceId 就绪。
   * 首次进入播放页时 XComponent 的 onLoad 可能晚于 AVPlayer 建立，
   * 此时空 surfaceId 绑定会被静默跳过，prepared 之后再绑又会报 5400102，
   * 表现就是「只有声音没有画面」——所以起播前必须等 surface 到手。
   */
  private waitSurfaceId(timeoutMs: number): Promise<string> {
    if (this.surfaceId.length > 0) {
      return Promise.resolve(this.surfaceId);
    }
    return new Promise<string>((resolve: (id: string) => void) => {
      let settled: boolean = false;
      const timer: number = setTimeout(() => {
        if (!settled) {
          settled = true;
          resolve(this.surfaceId);
        }
      }, timeoutMs);
      this.surfaceWaiters.push((id: string) => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve(id);
        }
      });
    });
  }

  /** surface 就绪后唤醒所有等待者 */
  private notifySurfaceReady(id: string): void {
    const list: Array<(id: string) => void> = this.surfaceWaiters;
    this.surfaceWaiters = [];
    for (let i = 0; i < list.length; i++) {
      list[i](id);
    }
  }

  /**
   * 画面比例落地：硬解画面由 AVPlayer 自己按 videoScaleType 适配 surface，
   * 组件尺寸保持铺满、不随视频比例变化，避免 surface 反复重建导致黑屏。
   */
  private applyVideoScale(player: media.AVPlayer | undefined = this.avPlayer): void {
    const p: media.AVPlayer | undefined = player;
    if (p === undefined) {
      return;
    }
    try {
      // 注意：VIDEO_SCALE_TYPE_FIT 是「拉伸铺满 surface、不保持宽高比」，
      // 只要组件尺寸与视频比例有一点不一致就会明显变形（全屏时最刺眼）。
      // 因此一律不用 FIT：铺满走等比裁剪，其余（适应/原始）走等比留黑边。
      p.videoScaleType = this.aspect === AspectMode.COVER
        ? media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP
        : media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'set videoScaleType failed');
    }
  }

  /**
   * 本地文件打开候选：原样 → 解码 → 编码，任一成功即用。
   * 选择器/媒体库返回的 uri 可能带 %XX 转义或未转义的中文、空格，
   * 直接交给 fs 或 AVPlayer 都会失败（AVPlayer 侧表现为 5400102）。
   */
  private openLocalFile(uri: string): fs.File | undefined {
    const candidates: string[] = [uri];
    if (uri.indexOf('%') >= 0) {
      try {
        const dec: string = decodeURIComponent(uri);
        if (dec !== uri) {
          candidates.push(dec);
        }
      } catch (err) {
      }
    }
    if (uri.indexOf(' ') >= 0 || uri.indexOf('#') >= 0) {
      try {
        const enc: string = encodeURI(uri);
        if (enc !== uri) {
          candidates.push(enc);
        }
      } catch (err) {
      }
    }
    for (let i = 0; i < candidates.length; i++) {
      try {
        const opened: fs.File = fs.openSync(candidates[i], fs.OpenMode.READ_ONLY);
        // 打开后立刻验证可读长度，读不到长度的句柄一定播不了
        try {
          fs.statSync(opened.fd);
        } catch (statErr) {
          hilog.warn(DOMAIN, TAG, 'stat on opened fd failed, keep it anyway');
        }
        return opened;
      } catch (err) {
        const e: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'open candidate %{public}d failed code=%{public}d', i, e.code);
      }
    }
    return undefined;
  }

  private async openUri(uri: string, headers?: Record<string, string>): Promise<void> {
    try {
      await this.releasePlayer();
      this.closeFile();
      this.currentUri = uri;
      this.decodeHint = '';
      // 网络/局域网源起播时记录一份播放缓存（filesDir/tv_cache），由清除缓存统一回收
      if (this.isNetworkUri(uri)) {
        TvCacheStore.recordPlayback(uri, uri, this.title, headers);
      }
      // 等 XComponent 交出 surface 再建播放器：surface 必须在 prepare 之前绑定，
      // 晚了就只剩声音没有画面
      if (this.surfaceId.length === 0 && !this.isNetworkUri(uri)) {
        await this.waitSurfaceId(1500);
      }
      // 优先以 fd 方式打开（媒体库/文件选择器返回的 uri 均可读），失败时退回 url 直连
      this.file = this.openLocalFile(uri);
      const player: media.AVPlayer = await media.createAVPlayer();
      this.avPlayer = player;
      this.surfaceBound = false;
      // idle 阶段不绑 surface：此时设置会被播放器内部重置；真正绑定放在 initialized 回调
      this.bindPlayerEvents(player);
      if (this.file !== undefined) {
        // fd 方式起播：不要给 AVPlayer 传 length=0，那会被当作空源直接报 5400102
        let size: number = 0;
        try {
          size = fs.statSync(this.file.fd).size;
        } catch (statErr) {
          size = 0;
        }
        if (!(size > 0)) {
          try {
            size = fs.statSync(uri).size;
          } catch (statErr) {
            size = 0;
          }
        }
        if (size > 0) {
          player.fdSrc = { fd: this.file.fd, offset: 0, length: size };
        } else {
          player.fdSrc = { fd: this.file.fd };
        }
      } else if (!this.isNetworkUri(uri)) {
        // 本地源但句柄打不开（授权失效 / 文件被移动），再交给 url 只会换来 5400102，直接明确报错
        hilog.error(DOMAIN, TAG, 'local uri open failed, abort');
        this.errorMsg = '本地视频打不开：文件可能已被移动，或访问授权已失效，请在列表里重新导入';
        await this.releasePlayer();
      } else {
        const hdrs: Record<string, string> = headers !== undefined ? headers : {};
        if (Object.keys(hdrs).length > 0) {
          try {
            const source: media.MediaSource = media.createMediaSourceWithUrl(uri, hdrs);
            await player.setMediaSource(source);
          } catch (srcErr) {
            hilog.warn(DOMAIN, TAG, 'setMediaSource with headers failed, fallback to url');
            player.url = uri;
          }
        } else {
          player.url = uri;
        }
      }
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      if (!this.isNetworkUri(uri)) {
        this.errorMsg = `本地视频打开失败（${e.code}）：文件可能已移动或访问授权已失效，请重新导入`;
      } else {
        this.errorMsg = `打开失败（${e.code}）`;
      }
      hilog.error(DOMAIN, TAG, 'openUri failed code=%{public}d', e.code);
    }
  }

  /**
   * 软解模式：AVPlayer 只负责解封装时钟与音频，视频画面交给 native 软件解码器渲染。
   * 返回 true 表示软解已接管画面；false 表示调用方回退到 AVPlayer 原生硬解渲染。
   */
  private startSoftPipeline(): boolean {
    const surface: string = this.surfaceId;
    if (surface.length === 0) {
      this.decodeHint = '';
      return false;
    }
    let file: fs.File | undefined = undefined;
    try {
      file = fs.openSync(this.currentUri, fs.OpenMode.READ_ONLY);
    } catch (err) {
      file = undefined;
    }
    if (file === undefined) {
      this.decodeHint = '';
      return false;
    }
    const size: number = fs.statSync(file.fd).size;
    const pipeline: SoftPipeline = new SoftPipeline();
    try {
      const desc: string = pipeline.start(file, size, surface, true);
      this.softFile = file;
      this.softPipeline = pipeline;
      this.decodeHint = '软解';
      hilog.info(DOMAIN, TAG, 'soft decoder active: %{public}s', desc);
      this.startPosTimer();
      return true;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'soft decoder init failed: %{public}s', e.message);
      try {
        fs.closeSync(file);
      } catch (closeErr) {
      }
      pipeline.release();
      this.decodeHint = '';
      promptAction.showToast({ message: '软解器初始化失败，已回退硬解' });
      return false;
    }
  }

  // ---------------- 播放进度记忆 ----------------

  /** 恢复上次进度：距开头不足 5 秒或已接近结尾时不跳转 */
  private applyResume(player: media.AVPlayer): void {
    const saved: number = PlayerPrefs.getResumePos(this.currentUri);
    if (saved <= 5000) {
      return;
    }
    const dur: number = player.duration > 0 ? player.duration : this.durationMs;
    if (dur > 0 && saved > dur - 10000) {
      return;
    }
    try {
      player.seek(saved, media.SeekMode.SEEK_PREV_SYNC);
      this.positionMs = saved;
      this.seekPreviewMs = saved;
      promptAction.showToast({ message: `已从 ${formatDuration(saved)} 继续播放` });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'resume seek failed');
    }
  }

  /** 播放中周期性落盘（约每 5 秒一次），避免频繁写 preferences */
  private tickResume(time: number): void {
    const sec: number = Math.floor(time / 1000);
    if (sec === this.lastSavedSec) {
      return;
    }
    if (sec % 5 !== 0) {
      return;
    }
    this.lastSavedSec = sec;
    this.saveProgress();
  }

  private saveProgress(): void {
    if (this.currentUri.length === 0 || this.durationMs <= 0) {
      return;
    }
    const pos: number = this.positionMs;
    if (pos < 1000) {
      return;
    }
    const isNet: boolean = this.isNetworkUri(this.currentUri);
    PlayerPrefs.saveResume(this.currentUri, this.title, pos, this.durationMs, isNet);
  }

  private isNetworkUri(uri: string): boolean {
    // 局域网（SMB 走本地代理 http、FTP/DAV 直连、DLNA 投屏地址）与在线流统称网络地址：
    // 进度记忆归类、清缓存前打断播放、后台播放判定都按这个口径走。
    return uri.startsWith('http://') || uri.startsWith('https://') || uri.startsWith('rtsp://') ||
      uri.startsWith('rtmp://') || uri.startsWith('ftp://') || uri.startsWith('smb://') ||
      uri.startsWith('cifs://') || uri.startsWith('dav://') || uri.indexOf('m3u8') >= 0;
  }

  private startPosTimer(): void {
    this.stopPosTimer();
    this.posTimerId = setInterval(() => {
      const soft: SoftPipeline | undefined = this.softPipeline;
      const player: media.AVPlayer | undefined = this.avPlayer;
      if (soft === undefined || player === undefined) {
        return;
      }
      soft.setClock(player.currentTime);
    }, 200);
  }

  private stopPosTimer(): void {
    if (this.posTimerId >= 0) {
      clearInterval(this.posTimerId);
      this.posTimerId = -1;
    }
  }

  private bindPlayerEvents(player: media.AVPlayer): void {
    player.on('stateChange', (state: media.AVPlayerState, reason: media.StateChangeReason) => {
      if (state === 'initialized') {
        // 官方顺序：initialized 之后设 surfaceId，再 prepare。
        // 早先在 idle 阶段设过一次，会被播放器内部重置成 -1，画面就永远出不来。
        if (this.surfaceId.length === 0) {
          this.waitSurfaceId(1500).then((id: string) => {
            if (this.disposed || this.avPlayer !== player) {
              return;
            }
            this.applySurface(player, true, 'initialized-late');
            try {
              player.prepare();
            } catch (err) {
              hilog.warn(DOMAIN, TAG, 'prepare after late surface failed');
            }
          });
        } else {
          this.applySurface(player, true, 'initialized');
          player.prepare();
        }
      } else if (state === 'prepared') {
        let softOk: boolean = false;
        if (this.decodeMode === 'sw') {
          softOk = this.startSoftPipeline();
        }
        if (!softOk && !this.surfaceMatched(player)) {
          this.applySurface(player, true, 'prepared');
        }
        // 硬解但 surface 没绑上：画面不会出（只有声音），等 surface 到手后整条重开一次
        if (!softOk && !this.surfaceBound) {
          if (this.surfaceRetryUsed) {
            this.errorMsg = '画面初始化失败，请退出后重新进入';
          } else {
            this.surfaceRetryUsed = true;
            const waitId: Promise<string> = this.waitSurfaceId(1200);
            waitId.then((id: string) => {
              if (id.length > 0 && !this.disposed) {
                hilog.warn(DOMAIN, TAG, 'surface late, reopen once to bind');
                this.openCurrent(true);
              }
            });
          }
        }
        this.applyVideoScale(player);
        player.loop = this.loopSingle;
        this.applySpeed(player, this.speed);
        this.collectTracks(player);
        this.ready = true;
        if (this.durationMs <= 0) {
          this.durationMs = player.duration;
        }
        player.play();
        this.positionMs = 0;
        this.applyResume(player);
        // 探针已拿到分辨率时，prepared 就先定一次方向与画面比例
        this.applyOrientationByRatio();
      } else if (state === 'playing') {
        this.isPlaying = true;
        this.scheduleHide();
      } else if (state === 'paused') {
        this.isPlaying = false;
        this.showControls();
      } else if (state === 'completed') {
        this.onPlaybackCompleted();
      }
    });
    player.on('timeUpdate', (time: number) => {
      if (this.gestureKind === GestureKind.NONE) {
        this.positionMs = time;
      }
      this.updateSubtitle(time);
      this.tickResume(time);
    });
    player.on('durationUpdate', (duration: number) => {
      this.durationMs = duration;
    });
    player.on('videoSizeChange', (width: number, height: number) => {
      this.videoW = width;
      this.videoH = height;
      // 拿到真实宽高后：按比例定屏幕方向，并把画面盒子等比贴合
      this.applyOrientationByRatio();
      this.recomputeVideoBox();
      // 真实分辨率到手后再落一次缩放策略：部分机型 prepared 阶段设的 videoScaleType
      // 会被解码器初始化重置，表现为全屏后画面被拉伸变形（保持比例才正常）
      this.applyVideoScale(player);
    });
    player.on('seekDone', (time: number) => {
      this.positionMs = time;
      this.seekPreviewMs = time;
    });
    player.on('error', (error: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'player error code=%{public}d msg=%{public}s', error.code, error.message);
      // 5400102 多为「源设置时机/句柄状态不对」，自动重建播放器重开一次即可恢复
      if (error.code === 5400102 && !this.reopenTried && this.currentUri.length > 0) {
        this.reopenTried = true;
        this.errorMsg = '';
        hilog.warn(DOMAIN, TAG, 'retry open after 5400102');
        this.openCurrent(true);
        return;
      }
      this.errorMsg = `播放错误（${error.code}）`;
    });
  }

  private async releasePlayer(): Promise<void> {
    this.stopPosTimer();
    const soft: SoftPipeline | undefined = this.softPipeline;
    this.softPipeline = undefined;
    if (soft !== undefined) {
      try {
        soft.release();
      } catch (err) {
      }
    }
    if (this.softFile !== undefined) {
      try {
        fs.closeSync(this.softFile);
      } catch (err) {
      }
      this.softFile = undefined;
    }
    this.decodeHint = '';
    const player: media.AVPlayer | undefined = this.avPlayer;
    this.avPlayer = undefined;
    if (player !== undefined) {
      try {
        player.off('stateChange');
        player.off('timeUpdate');
        player.off('durationUpdate');
        player.off('videoSizeChange');
        player.off('seekDone');
        player.off('error');
      } catch (err) {
      }
      try {
        await player.release();
      } catch (err) {
      }
    }
  }

  private closeFile(): void {
    if (this.file !== undefined) {
      try {
        fs.closeSync(this.file);
      } catch (err) {
      }
      this.file = undefined;
    }
  }

  private onPlaybackCompleted(): void {
    this.positionMs = this.durationMs;
    this.isPlaying = false;
    // 正常看完即清掉该条进度记录，下次从头播放
    PlayerPrefs.clearResume(this.currentUri);
    if (PlayerPrefs.isAutoPlayNext() && this.playlistIndex + 1 < this.playlistSize) {
      this.playlistIndex = this.playlistIndex + 1;
      this.openCurrent();
    } else {
      this.showControls();
    }
  }

  private applySpeed(player: media.AVPlayer, value: number): void {
    let speedEnum: media.PlaybackSpeed = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    if (value <= 0.5) {
      speedEnum = media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
    } else if (value <= 0.75) {
      speedEnum = media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    } else if (value <= 1.0) {
      speedEnum = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    } else if (value <= 1.25) {
      speedEnum = media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    } else if (value <= 1.75) {
      speedEnum = media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    } else {
      speedEnum = media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
    }
    try {
      player.setSpeed(speedEnum);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setSpeed failed');
    }
  }

  private collectTracks(player: media.AVPlayer): void {
    this.audioTracks = [];
    this.subtitleTracks = [];
    player.getTrackDescription().then((tracks: Array<media.MediaDescription>) => {
      for (let i = 0; i < tracks.length; i++) {
        const t: media.MediaDescription = tracks[i];
        const id: number = Number(t[media.MediaDescriptionKey.MD_KEY_TRACK_INDEX] ?? -1);
        const type: number = Number(t[media.MediaDescriptionKey.MD_KEY_TRACK_TYPE] ?? -1);
        if (type === media.MediaType.MEDIA_TYPE_AUD) {
          this.audioTracks.push(new TrackEntry(id, `音轨 ${this.audioTracks.length + 1}`, 'audio'));
        } else if (type === media.MediaType.MEDIA_TYPE_SUBTITLE) {
          this.subtitleTracks.push(new TrackEntry(id, `字幕 ${this.subtitleTracks.length + 1}`, 'subtitle'));
        }
      }
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'getTrackDescription failed code=%{public}d', err.code);
    });
  }

  // ---------------- 播放控制 ----------------

  private togglePlay(): void {
    // 清除缓存时播放器已被释放，这里重新打开当前条目（按续播进度恢复）
    if (this.reloadAfterCacheClear) {
      this.reloadAfterCacheClear = false;
      this.openCurrent();
      this.scheduleHide();
      return;
    }
    // 投屏中：播放/暂停直接下发到渲染器，本地播放器保持静默
    if (DlnaCast.isCasting) {
      if (this.castPhase === CastPhase.PLAYING) {
        DlnaCast.pause().then((ok: boolean) => {
          if (ok) {
            this.castPhase = CastPhase.PAUSED;
          }
        });
      } else {
        DlnaCast.play().then((ok: boolean) => {
          if (ok) {
            this.castPhase = CastPhase.PLAYING;
          }
        });
      }
      this.scheduleHide();
      return;
    }
    const soft: SoftPipeline | undefined = this.softPipeline;
    if (soft !== undefined) {
      soft.setPaused(this.isPlaying);
    }
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (player === undefined) {
      return;
    }
    if (this.isPlaying) {
      player.pause();
    } else {
      player.play();
    }
    this.scheduleHide();
  }

  private seekTo(ms: number): void {
    let target: number = ms;
    if (target < 0) {
      target = 0;
    }
    if (this.durationMs > 0 && target > this.durationMs) {
      target = this.durationMs;
    }
    // 投屏中：拖动进度条同步 Seek 到渲染器
    this.castPosition = Math.floor(target / 1000);
    if (DlnaCast.isCasting) {
      DlnaCast.seek(this.castPosition);
      this.positionMs = target;
      this.updateSubtitle(target);
      return;
    }
    const soft: SoftPipeline | undefined = this.softPipeline;
    if (soft !== undefined) {
      soft.seekTo(target);
    }
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (player === undefined) {
      return;
    }
    try {
      player.seek(target, media.SeekMode.SEEK_PREV_SYNC);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'seek failed');
    }
    this.positionMs = target;
    this.updateSubtitle(target);
  }

  private seekBy(deltaMs: number): void {
    this.seekTo(this.positionMs + deltaMs);
    this.showControls();
  }

  private playPrev(): void {
    if (this.playlistIndex > 0) {
      this.playlistIndex = this.playlistIndex - 1;
      this.openCurrent();
    } else {
      promptAction.showToast({ message: '已经是第一个' });
    }
  }

  private playNext(): void {
    if (this.playlistIndex + 1 < this.playlistSize) {
      this.playlistIndex = this.playlistIndex + 1;
      this.openCurrent();
    } else {
      promptAction.showToast({ message: '已经是最后一个' });
    }
  }

  private setVolume(v: number): void {
    let value: number = v;
    if (value < 0) {
      value = 0;
    }
    if (value > 1) {
      value = 1;
    }
    this.currentVolume = value;
    this.volumeLevel = value;
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (player !== undefined) {
      try {
        player.setVolume(value);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'setVolume failed');
      }
    }
  }

  private async setBrightness(v: number): Promise<void> {
    let value: number = v;
    if (value < 0.05) {
      value = 0.05;
    }
    if (value > 1) {
      value = 1;
    }
    this.currentBrightness = value;
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(ctx);
      await win.setWindowBrightness(value);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setWindowBrightness failed');
    }
  }

  private async enterFullScreen(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(ctx);
      await win.setWindowLayoutFullScreen(true);
      await win.setWindowSystemBarEnable([]);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'enterFullScreen failed');
    }
  }

  private async exitFullScreen(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(ctx);
      await win.setWindowSystemBarEnable(['status', 'navigation']);
      // 保持全屏布局不变，由各页面按 AppStorage 里的安全区高度自行补偿，避免回到首页出现双重留白
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'exitFullScreen failed');
    }
  }

  // ---------------- 控制层显隐 ----------------

  private showControls(): void {
    this.controlsVisible = true;
    this.scheduleHide();
  }

  private toggleControls(): void {
    if (this.controlsVisible) {
      this.controlsVisible = false;
      if (this.hideTimerId >= 0) {
        clearTimeout(this.hideTimerId);
        this.hideTimerId = -1;
      }
    } else {
      this.showControls();
    }
  }

  private scheduleHide(): void {
    if (this.hideTimerId >= 0) {
      clearTimeout(this.hideTimerId);
    }
    this.hideTimerId = setTimeout(() => {
      if (this.isPlaying) {
        this.controlsVisible = false;
      }
      this.hideTimerId = -1;
    }, CONTROLS_TIMEOUT_MS);
  }

  // ---------------- 字幕 ----------------

  private updateSubtitle(positionMs: number): void {
    if (this.cues.length === 0) {
      return;
    }
    const cue: SubtitleCue | undefined = SubtitleParser.cueObjectAt(this.cues, positionMs);
    if (cue === undefined) {
      this.clearSubtitleFrame();
      return;
    }
    const frame: SubtitleFrame = SubtitleParser.frameAt(cue, positionMs);
    this.subRuns = frame.runs;
    this.subOpacity = frame.opacity;
    this.subAlign = frame.align;
    this.subXRatio = frame.xRatio;
    this.subYRatio = frame.yRatio;
    this.subRotate = frame.rotate;
    if (cue.text !== this.subtitleText) {
      this.subtitleText = cue.text;
    }
  }

  private clearSubtitleFrame(): void {
    if (this.subtitleText.length === 0 && this.subRuns.length === 0) {
      return;
    }
    this.subtitleText = '';
    this.subRuns = [];
    this.subOpacity = 1;
    this.subAlign = 2;
    this.subXRatio = -1;
    this.subYRatio = -1;
    this.subRotate = 0;
  }

  /** 字幕基准高度：优先用画面实测高度，没有时按横竖屏兜底 */
  private subtitleBaseHeight(): number {
    if (this.containerH > 0) {
      return this.containerH;
    }
    return this.isWide ? 405 : 720;
  }

  /** run 的最终字号：ASS 按 PlayResY 比例缩放，SRT 用默认字号 */
  private runFontSize(run: SubtitleRun): number {
    const base: number = this.subtitleBaseHeight();
    if (run.fontSizeRatio > 0) {
      const vp: number = run.fontSizeRatio * base;
      return Math.max(9, Math.min(vp, base * 0.22));
    }
    return (this.isWide ? 20 : 16) * this.uiScale();
  }

  /** 描边用零偏移同色阴影近似，阴影用右下偏移，都按 PlayResY 比例缩放 */
  private runShadow(run: SubtitleRun): ShadowOptions[] {
    const base: number = this.subtitleBaseHeight();
    const list: ShadowOptions[] = [];
    const outline: number = run.outlineRatio * base;
    if (outline > 0.25) {
      list.push({ radius: Math.min(outline, 6), color: run.outlineColor, offsetX: 0, offsetY: 0 });
    }
    const shadow: number = run.shadowRatio * base;
    if (shadow > 0.25) {
      list.push({ radius: Math.min(shadow, 6), color: '#99000000', offsetX: shadow, offsetY: shadow });
    }
    return list;
  }

  /** \an1~\an9 映射到容器对齐方式 */
  private subtitleAlignment(): Alignment {
    switch (this.subAlign) {
      case 1:
        return Alignment.BottomStart;
      case 2:
        return Alignment.Bottom;
      case 3:
        return Alignment.BottomEnd;
      case 4:
        return Alignment.Start;
      case 5:
        return Alignment.Center;
      case 6:
        return Alignment.End;
      case 7:
        return Alignment.TopStart;
      case 8:
        return Alignment.Top;
      default:
        return Alignment.TopEnd;
    }
  }

  // ---------------- 在线字幕 ----------------

  private openSubtitleSearch(): void {
    const item: VideoItem | undefined = this.currentItem();
    this.subKeyword = item !== undefined ? SubtitleFinder.keywordFromName(item.title) : this.title;
    this.subResults = [];
    this.subFailed = '';
    this.subDlgVisible = true;
    this.searchSubtitles();
  }

  private async searchSubtitles(): Promise<void> {
    const keyword: string = this.subKeyword.trim();
    if (keyword.length === 0) {
      this.subFailed = '请先输入片名关键词';
      return;
    }
    this.subLoading = true;
    this.subFailed = '';
    try {
      const apiKey: string = PlayerPrefs.getSubtitleApiKey();
      const lang: string = PlayerPrefs.getSubtitleLang();
      this.subFromOs = false;
      let list: SubtitleItem[] = [];
      let freeErr: string = '';
      try {
        // 免 Key 源优先：射手网（伪）+ SubtitleCat，开箱即用
        list = await SubtitleFinder.searchFree(keyword);
      } catch (err) {
        freeErr = (err as Error).message;
      }
      if (list.length === 0 && apiKey.trim().length > 0) {
        list = await SubtitleFinder.searchOpen(keyword, lang, apiKey);
        this.subFromOs = true;
      }
      this.subResults = list;
      if (list.length === 0) {
        this.subFailed = freeErr.length > 0 ? freeErr : '没有匹配结果，可换个关键词或粘贴直链导入';
      }
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      this.subFailed = e.message !== undefined && e.message.length > 0 ? e.message : '搜索失败，请检查网络';
      hilog.error(DOMAIN, TAG, 'subtitle search failed code=%{public}d', e.code);
    } finally {
      this.subLoading = false;
    }
  }

  private async applySubtitleFromPath(path: string): Promise<void> {
    const parsed: SubtitleCue[] = await SubtitleParser.loadFromPath(path);
    if (parsed.length === 0) {
      this.subFailed = '字幕解析失败（可能是不支持的格式）';
      return;
    }
    this.cues = parsed;
    this.subtitleLoaded = true;
    this.updateSubtitle(this.positionMs);
    this.subDlgVisible = false;
    this.subFailed = '';
    promptAction.showToast({ message: `已载入 ${parsed.length} 条字幕` });
  }

  private async pickSubtitle(item: SubtitleItem): Promise<void> {
    this.subLoading = true;
    this.subFailed = '';
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      let link: string = '';
      if (item.source === 'os') {
        const apiKey: string = PlayerPrefs.getSubtitleApiKey();
        link = await SubtitleFinder.resolveDownloadLink(item.fileId, apiKey);
      } else {
        link = await SubtitleFinder.resolveUrl(item);
      }
      const path: string = await SubtitleFinder.downloadToSandbox(ctx, link, item.title);
      await this.applySubtitleFromPath(path);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      this.subFailed = e.message !== undefined && e.message.length > 0 ? e.message : '下载失败';
    } finally {
      this.subLoading = false;
    }
  }

  /** 直链导入：任意 http(s) 的 srt/vtt/zip 地址，无需 Api-Key */
  private async importSubtitleByUrl(): Promise<void> {
    const url: string = this.subDirectUrl.trim();
    if (url.length === 0) {
      this.subFailed = '请先粘贴字幕直链';
      return;
    }
    this.subLoading = true;
    this.subFailed = '';
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const name: string = url.substring(url.lastIndexOf('/') + 1);
      const path: string = await SubtitleFinder.downloadToSandbox(ctx, url, name.length > 0 ? name : 'sub');
      await this.applySubtitleFromPath(path);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      this.subFailed = e.message !== undefined && e.message.length > 0 ? e.message : '导入失败';
    } finally {
      this.subLoading = false;
    }
  }

  private async loadExternalSubtitle(): Promise<void> {
    try {
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.srt', '.ass', '.ssa'];
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const name: string = uris[0].toLowerCase();
      if (name.indexOf('.ass') >= 0 || name.indexOf('.ssa') >= 0) {
        promptAction.showToast({ message: 'ASS/SSA 特效字幕暂不支持，请使用 SRT' });
        return;
      }
      const parsed: SubtitleCue[] = await SubtitleParser.loadFromUri(uris[0]);
      if (parsed.length === 0) {
        promptAction.showToast({ message: '字幕解析失败，请确认是 UTF-8 的 SRT 文件' });
        return;
      }
      this.cues = parsed;
      this.subtitleLoaded = true;
      this.updateSubtitle(this.positionMs);
      promptAction.showToast({ message: `已载入 ${parsed.length} 条字幕` });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'load subtitle failed');
    }
  }

  // ---------------- 手势 ----------------

  private onPanStart(event: GestureEvent): void {
    if (this.locked || !this.gestureEnabled) {
      return;
    }
    this.gestureKind = GestureKind.NONE;
    this.panStartPosition = this.positionMs;
  }

  private onPanUpdate(event: GestureEvent): void {
    if (this.locked || !this.gestureEnabled) {
      return;
    }
    const dx: number = event.offsetX;
    const dy: number = event.offsetY;
    if (this.gestureKind === GestureKind.NONE) {
      if (Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > PAN_THRESHOLD) {
        this.gestureKind = GestureKind.SEEK;
      } else if (Math.abs(dy) > Math.abs(dx) && Math.abs(dy) > PAN_THRESHOLD) {
        const firstFingerX: number = event.fingerList.length > 0 ? event.fingerList[0].localX : 0;
        const half: number = this.containerW > 0 ? this.containerW / 2 : 180;
        this.gestureKind = firstFingerX < half ? GestureKind.BRIGHTNESS : GestureKind.VOLUME;
        this.panStartVolume = this.currentVolume;
        this.panStartBrightness = this.currentBrightness;
      } else {
        return;
      }
    }
    if (this.gestureKind === GestureKind.SEEK) {
      const span: number = this.containerW > 0 ? this.containerW : 360;
      const ratio: number = dx / span;
      let target: number = this.panStartPosition + ratio * (this.durationMs > 0 ? this.durationMs : 0);
      if (target < 0) {
        target = 0;
      }
      if (target > this.durationMs) {
        target = this.durationMs;
      }
      this.seekPreviewMs = target;
      this.overlayKind = GestureKind.SEEK;
      this.overlayText = `${formatDuration(target)} / ${formatDuration(this.durationMs)}`;
      this.overlayPercent = this.durationMs > 0 ? target / this.durationMs * 100 : 0;
    } else if (this.gestureKind === GestureKind.VOLUME) {
      const span: number = this.containerH > 0 ? this.containerH : 640;
      const value: number = this.panStartVolume - dy / span;
      this.setVolume(value);
      this.overlayKind = GestureKind.VOLUME;
      this.overlayPercent = this.currentVolume * 100;
      this.overlayText = `音量 ${Math.round(this.currentVolume * 100)}%`;
    } else if (this.gestureKind === GestureKind.BRIGHTNESS) {
      const span: number = this.containerH > 0 ? this.containerH : 640;
      const value: number = this.panStartBrightness - dy / span;
      this.setBrightness(value);
      this.overlayKind = GestureKind.BRIGHTNESS;
      this.overlayPercent = this.currentBrightness * 100;
      this.overlayText = `亮度 ${Math.round(this.currentBrightness * 100)}%`;
    }
  }

  private onPanEnd(): void {
    if (this.locked || !this.gestureEnabled) {
      return;
    }
    if (this.gestureKind === GestureKind.SEEK) {
      this.seekTo(this.seekPreviewMs);
    }
    this.gestureKind = GestureKind.NONE;
    this.overlayKind = GestureKind.NONE;
    this.overlayText = '';
  }

  private onLongPressStart(): void {
    if (this.locked || !this.gestureEnabled) {
      return;
    }
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (player !== undefined && this.isPlaying) {
      this.longPressBoost = true;
      this.applySpeed(player, 2.0);
      this.overlayKind = GestureKind.NONE;
      this.overlayText = '2.0x 倍速中';
    }
  }

  private onLongPressEnd(): void {
    if (this.longPressBoost) {
      this.longPressBoost = false;
      const player: media.AVPlayer | undefined = this.avPlayer;
      if (player !== undefined) {
        this.applySpeed(player, this.speed);
      }
      this.overlayText = '';
    }
  }

  // ---------------- 更多菜单 ----------------

  private showMoreMenu(): void {
    promptAction.showActionMenu({
      title: this.title,
      buttons: [
        { text: `音轨（${this.audioTracks.length}）`, color: this.pal().textPrimary },
        { text: this.subtitleLoaded ? '字幕（已载入）' : '字幕', color: this.pal().textPrimary },
        { text: `播放速度 ${this.speed.toFixed(2)}x`, color: this.pal().textPrimary },
        { text: `画面比例 ${this.aspectLabel()}`, color: this.pal().textPrimary },
        { text: `单曲循环 ${this.loopSingle ? '开' : '关'}`, color: this.pal().textPrimary },
        { text: '媒体信息', color: this.pal().textPrimary }
      ]
    }).then((res: promptAction.ActionMenuSuccessResponse) => {
      if (res.index === 0) {
        this.showAudioTrackMenu();
      } else if (res.index === 1) {
        this.showSubtitleMenu();
      } else if (res.index === 2) {
        this.showSpeedMenu();
      } else if (res.index === 3) {
        this.cycleAspect();
      } else if (res.index === 4) {
        this.toggleLoop();
      } else {
        this.showMediaInfo();
      }
    }).catch(() => {
    });
  }

  private showSubtitleMenu(): void {
    promptAction.showActionMenu({
      title: '字幕',
      buttons: [
        { text: '加载本地字幕', color: this.pal().textPrimary },
        { text: '在线搜索字幕', color: this.pal().textPrimary },
        { text: '关闭字幕', color: this.pal().textPrimary }
      ]
    }).then((res: promptAction.ActionMenuSuccessResponse) => {
      if (res.index === 0) {
        this.loadExternalSubtitle();
      } else if (res.index === 1) {
        this.openSubtitleSearch();
      } else {
        this.cues = [];
        this.subtitleLoaded = false;
        this.subtitleText = '';
        promptAction.showToast({ message: '已关闭字幕' });
      }
    }).catch(() => {
    });
  }

  private showAudioTrackMenu(): void {
    if (this.audioTracks.length === 0) {
      promptAction.showToast({ message: '该视频没有可切换的音轨' });
      return;
    }
    const items: MenuElement[] = [];
    for (let i = 0; i < this.audioTracks.length; i++) {
      const idx: number = i;
      const label: string = this.audioTracks[i].name;
      items.push({
        value: label,
        action: () => {
          this.pickAudioTrack(idx);
        }
      });
    }
    this.menuItems = items;
    this.menuVisible = true;
  }

  private pickAudioTrack(index: number): void {
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (player === undefined || index < 0 || index >= this.audioTracks.length) {
      return;
    }
    const trackId: number = this.audioTracks[index].index;
    const name: string = this.audioTracks[index].name;
    player.selectTrack(trackId).then(() => {
      promptAction.showToast({ message: `已切换 ${name}` });
    }).catch(() => {
      promptAction.showToast({ message: '切换音轨失败' });
    });
  }

  private showSpeedMenu(): void {
    const speeds: number[] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    promptAction.showActionMenu({
      title: '播放速度',
      buttons: [
        { text: '0.50x', color: this.pal().textPrimary },
        { text: '0.75x', color: this.pal().textPrimary },
        { text: '1.00x', color: this.pal().textPrimary },
        { text: '1.25x', color: this.pal().textPrimary },
        { text: '1.50x', color: this.pal().textPrimary },
        { text: '2.00x', color: this.pal().textPrimary }
      ]
    })
      .then((res: promptAction.ActionMenuSuccessResponse) => {
        this.speed = speeds[res.index];
        const player: media.AVPlayer | undefined = this.avPlayer;
        if (player !== undefined) {
          this.applySpeed(player, this.speed);
        }
        PlayerPrefs.setDefaultSpeed(this.speed);
      }).catch(() => {
    });
  }

  private aspectLabel(): string {
    if (this.aspect === AspectMode.COVER) {
      return '裁剪铺满';
    }
    return '适应屏幕';
  }

  private cycleAspect(): void {
    // 只保留「适应屏幕 / 裁剪铺满」两态：都由 AVPlayer.videoScaleType 直接驱动，
    // 组件尺寸保持铺满不变，切比例时 surface 不重建，画面不会黑
    this.aspect = this.aspect === AspectMode.CONTAIN ? AspectMode.COVER : AspectMode.CONTAIN;
    this.applyVideoScale();
    promptAction.showToast({ message: this.aspectLabel() });
  }

  /** 解码方式标签：点一下就是切过去的那一档 */
  private decodeLabel(): string {
    return this.decodeMode === 'sw' ? '软解' : '硬解';
  }

  /**
   * 硬解 / 软解切换：硬解走 AVPlayer + surface（默认），
   * 软解由 native 解码器接管画面（应对部分机型硬解不兼容的片源）。
   * 切换后整条重开，保证解码器与 surface 重新握手。
   */
  private toggleDecode(): void {
    const next: string = this.decodeMode === 'sw' ? 'hw' : 'sw';
    this.decodeMode = next;
    PlayerPrefs.setDecodeMode(next).catch(() => {
    });
    promptAction.showToast({ message: next === 'sw' ? '已切换到软件解码' : '已切换到硬件解码' });
    this.openCurrent(true);
  }

  private toggleLoop(): void {
    this.loopSingle = !this.loopSingle;
    const player: media.AVPlayer | undefined = this.avPlayer;
    if (player !== undefined) {
      player.loop = this.loopSingle;
    }
    promptAction.showToast({ message: this.loopSingle ? '单曲循环 开' : '单曲循环 关' });
  }

  private showMediaInfo(): void {
    const item: VideoItem | undefined = this.currentItem();
    const msg: string = `标题：${this.title}\n时长：${formatDuration(this.durationMs)}` +
      `\n分辨率：${this.videoW}×${this.videoH}` +
      `\n大小：${item !== undefined ? item.sizeText() : '未知'}` +
      `\n音轨：${this.audioTracks.length} 字幕轨：${this.subtitleTracks.length}` +
      `\n外挂字幕：${this.subtitleLoaded ? '已加载' : '无'}`;
    promptAction.showDialog({
      title: '媒体信息',
      message: msg,
      buttons: [{ text: '确定', color: this.pal().primary }]
    });
  }

  /** 横屏片判定：宽高比 >= 1.15 视为横屏视频 */
  private isLandscapeVideo(): boolean {
    if (this.videoW <= 0 || this.videoH <= 0) {
      return false;
    }
    return this.videoW / this.videoH >= 1.15;
  }

  /** 竖屏片判定：高宽比 >= 1.15 视为竖屏视频 */
  private isPortraitVideo(): boolean {
    if (this.videoW <= 0 || this.videoH <= 0) {
      return false;
    }
    return this.videoH / this.videoW >= 1.15;
  }

  /**
   * 统一的方向设置入口：带令牌校验，只有最新一次请求会真正落地。
   * 同时吞掉所有异常，方向设置失败不影响播放。
   */
  private setOrientation(target: window.Orientation): void {
    // 页面已销毁时不再发方向请求，避免离场瞬间把下一个页面的方向设置顶掉
    if (this.disposed) {
      return;
    }
    orientToken++;
    const token: number = orientToken;
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      window.getLastWindow(context).then((win: window.Window) => {
        if (token !== orientToken) {
          return;
        }
        win.setPreferredOrientation(target).catch(() => {
        });
      }).catch(() => {
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setOrientation failed');
    }
  }

  /** 按视频宽高比请求屏幕方向：横片横屏、竖片竖屏，近方形不强制 */
  private applyOrientationByRatio(): void {
    if (this.videoW <= 0 || this.videoH <= 0 || this.manualOrient) {
      return;
    }
    let target: window.Orientation = window.Orientation.UNSPECIFIED;
    if (this.isLandscapeVideo()) {
      target = window.Orientation.LANDSCAPE;
    } else if (this.isPortraitVideo()) {
      target = window.Orientation.PORTRAIT;
    }
    this.setOrientation(target);
    // 窗口刚从后台/上一页切回时，第一次请求可能落在窗口尚未就绪的时间点，补发一次兜底
    const retryTarget: window.Orientation = target;
    if (this.orientRetryTimer >= 0) {
      clearTimeout(this.orientRetryTimer);
      this.orientRetryTimer = -1;
    }
    if (retryTarget !== window.Orientation.UNSPECIFIED) {
      this.orientRetryTimer = setTimeout(() => {
        this.orientRetryTimer = -1;
        if (!this.manualOrient && !this.disposed) {
          this.setOrientation(retryTarget);
        }
      }, 300);
    }
    // 竖屏播横片、横屏播竖片时默认完整显示（contain），不裁剪画面
    const screenLandscape: boolean = this.screenLandscape;
    const crossScreen: boolean = (screenLandscape && this.isPortraitVideo()) ||
      (!screenLandscape && this.isLandscapeVideo());
    if (crossScreen && this.aspect === AspectMode.COVER) {
      this.aspect = AspectMode.CONTAIN;
    }
  }

  /** 手动横竖屏切换：切换后本条视频内不再按宽高比自动切 */
  private toggleOrientation(): void {
    this.manualOrient = true;
    const toLandscape: boolean = !this.screenLandscape;
    this.setOrientation(toLandscape ? window.Orientation.LANDSCAPE : window.Orientation.PORTRAIT);
    // 横屏片放到竖屏里默认完整显示，不做裁剪
    if (!toLandscape && this.isLandscapeVideo() && this.aspect === AspectMode.COVER) {
      this.aspect = AspectMode.CONTAIN;
    }
    promptAction.showToast({ message: toLandscape ? '已切换横屏' : '已切换竖屏' });
    this.showControls();
  }

  /** 离开播放页恢复跟随系统方向 */
  private restoreOrientation(): void {
    this.setOrientation(window.Orientation.UNSPECIFIED);
  }

  /**
   * 重算播放画面尺寸：把视频按真实宽高比等比放进容器，
   * 画面区比例 == 视频比例，彻底消除拉伸变形与多余黑框。
   */
  private recomputeVideoBox(): void {
    const cw: number = this.containerW;
    const ch: number = this.containerH;
    if (cw <= 0 || ch <= 0) {
      return;
    }
    if (this.videoW <= 0 || this.videoH <= 0) {
      this.videoBoxW = cw;
      this.videoBoxH = ch;
      return;
    }
    const va: number = this.videoW / this.videoH;
    const ca: number = cw / ch;
    if (va > ca) {
      this.videoBoxW = cw;
      this.videoBoxH = cw / va;
    } else {
      this.videoBoxH = ch;
      this.videoBoxW = ch * va;
    }
  }

  /**
   * 控件缩放系数：只看屏幕（容器）短边，不看视频自身尺寸。
   * 视频画面怎么变，控件大小都稳定，不会出现忽大忽小把播放区挤乱。
   */
  private uiScale(): number {
    if (this.isWide) {
      return 1;
    }
    const shortSide: number = this.containerW > 0 && this.containerH > 0 ?
      Math.min(this.containerW, this.containerH) : 0;
    if (shortSide <= 0) {
      return 0.85;
    }
    return Math.max(0.72, Math.min(1, shortSide / 720));
  }

  private coverScale(): number {
    if (this.aspect !== AspectMode.COVER || this.videoW <= 0 || this.videoH <= 0 ||
      this.containerW <= 0 || this.containerH <= 0) {
      return 1.0;
    }
    const videoAspect: number = this.videoW / this.videoH;
    const containerAspect: number = this.containerW / this.containerH;
    const scale: number = videoAspect > containerAspect ? videoAspect / containerAspect : containerAspect / videoAspect;
    return Math.min(scale, 2.0);
  }

  // ---------------- UI ----------------

  // ---------------- 图标控件尺寸与列表 ----------------

  /** 图标本体视觉尺寸：横屏 26vp / 竖屏 24vp，再按 uiScale 缩放，且永不低于 24vp */
  private iconVisual(): number {
    const base: number = this.isWide ? 26 : 24;
    return Math.max(24, Math.round(base * this.uiScale()));
  }

  /** 播放/暂停主键图标本体尺寸（比常规图标大一档） */
  private playVisual(): number {
    const base: number = this.isWide ? 38 : 34;
    return Math.max(30, Math.round(base * this.uiScale()));
  }

  /** 底部控制条左右安全区 */
  private sideInset(): number {
    return this.isWide ? 32 : 8;
  }

  /**
   * 横屏且屏幕够宽时，进度与图标同排（单行）；否则降级为两行（上行进度、下行图标）。
   * 折叠态或极窄屏（<760vp）一律降级，确保排版绝不出屏。
   */
  private singleRowMode(): boolean {
    return this.isWide && this.containerW >= 760;
  }

  /** 底部图标组清单：横屏 9 个、竖屏 7 个，放不下的次要控件收进「更多」浮层 */
  private barIconIds(): string[] {
    if (this.isWide) {
      return ['prev', 'rewind', 'play', 'forward', 'next', 'volume', 'cast', 'speed', 'subtitle', 'more'];
    }
    return ['prev', 'rewind', 'play', 'forward', 'next', 'speed', 'more'];
  }

  private tintOf(active: boolean): ResourceColor {
    return active ? this.pal().primary : Color.White;
  }

  /** 图标按钮：触控热区不小于 48vp，图标本体不小于 24vp */
  @Builder
  iconBtn(icon: Resource, visual: number, tint: ResourceColor, badge: string, filled: boolean, id: string) {
    Column() {
      Image(icon)
        .width(visual)
        .height(visual)
        .fillColor(tint)
        .draggable(false)
        .objectFit(ImageFit.Contain)
      if (badge.length > 0) {
        Text(badge)
          .fontSize(9)
          .fontColor(tint)
          .maxLines(1)
          .margin({ top: 1 })
      }
    }
    .width(Math.max(48, visual + (badge.length > 0 ? 20 : 18)))
    .height(Math.max(48, visual + (badge.length > 0 ? 20 : 18)))
    .justifyContent(FlexAlign.Center)
    .borderRadius(24)
    .backgroundColor(filled ? '#33FFFFFF' : Color.Transparent)
    .onClick(() => {
      this.runIconAction(id);
      // 锁定 / 返回由各自分支处理控件可见性，避免锁屏后又被点亮
      if (id !== 'lock' && id !== 'back') {
        this.showControls();
      }
    })
  }

  /** 按 id 渲染单个底部图标（横竖屏共用，只按清单裁剪数量） */
  @Builder
  iconBtnFor(id: string) {
    if (id === 'prev') {
      this.iconBtn(PlayIconSet.PREV, this.iconVisual(), Color.White, '', false, 'prev')
    } else if (id === 'rewind') {
      this.iconBtn(PlayIconSet.REWIND, this.iconVisual(), Color.White, '', false, 'rewind')
    } else if (id === 'play') {
      if (this.isPlaying) {
        this.iconBtn(PlayIconSet.PAUSE, this.playVisual(), Color.White, '', true, 'play')
      } else {
        this.iconBtn(PlayIconSet.PLAY, this.playVisual(), Color.White, '', true, 'play')
      }
    } else if (id === 'forward') {
      this.iconBtn(PlayIconSet.FORWARD, this.iconVisual(), Color.White, '', false, 'forward')
    } else if (id === 'next') {
      this.iconBtn(PlayIconSet.NEXT, this.iconVisual(), Color.White, '', false, 'next')
    } else if (id === 'volume') {
      this.iconBtn(PlayIconSet.VOLUME, this.iconVisual(), this.tintOf(this.volumePanelVisible), '', false, 'volume')
    } else if (id === 'speed') {
      this.iconBtn(PlayIconSet.SPEED, this.iconVisual(), Color.White, `${this.speed.toFixed(1)}x`, false, 'speed')
    } else if (id === 'subtitle') {
      this.iconBtn(PlayIconSet.SUBTITLE, this.iconVisual(), this.tintOf(this.subtitleLoaded), '', false, 'subtitle')
    } else if (id === 'cast') {
      this.iconBtn(PlayIconSet.CAST, this.iconVisual(), this.castTint(), '', DlnaCast.isCasting, 'cast')
    } else if (id === 'more') {
      this.iconBtn(PlayIconSet.MORE, this.iconVisual(), this.tintOf(this.morePanelVisible), '', false, 'more')
    }
  }

  /** 图标点击统一分发 */
  private runIconAction(id: string): void {
    if (id === 'prev') {
      this.playPrev();
    } else if (id === 'next') {
      this.playNext();
    } else if (id === 'rewind') {
      this.seekBy(-SEEK_STEP_MS);
    } else if (id === 'forward') {
      this.seekBy(SEEK_STEP_MS);
    } else if (id === 'play') {
      this.togglePlay();
    } else if (id === 'volume') {
      this.volumePanelVisible = !this.volumePanelVisible;
    } else if (id === 'speed') {
      this.showSpeedMenu();
    } else if (id === 'subtitle') {
      this.showSubtitleMenu();
    } else if (id === 'aspect') {
      this.cycleAspect();
    } else if (id === 'track') {
      this.showAudioTrackMenu();
    } else if (id === 'decode') {
      this.toggleDecode();
    } else if (id === 'loop') {
      this.toggleLoop();
    } else if (id === 'fullscreen') {
      this.toggleOrientation();
    } else if (id === 'restart') {
      this.seekTo(0);
    } else if (id === 'info') {
      this.showMediaInfo();
    } else if (id === 'more') {
      this.morePanelVisible = !this.morePanelVisible;
    } else if (id === 'topmore') {
      this.showMoreMenu();
    } else if (id === 'cast') {
      if (DlnaCast.isCasting) {
        this.stopCasting();
      } else {
        this.openCastSheet();
      }
    } else if (id === 'lock') {
      this.locked = !this.locked;
      if (this.locked) {
        this.controlsVisible = false;
      } else {
        this.showControls();
      }
    } else if (id === 'back') {
      router.back();
    }
  }

  @Builder
  topBar() {
    Row() {
      this.iconBtn(PlayIconSet.BACK, Math.max(24, Math.round(26 * this.uiScale())), Color.White, '', false, 'back')
      Column() {
        Text(this.title)
          .fontSize(20 * this.uiScale())
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`${this.playlistIndex + 1}/${this.playlistSize}${this.decodeHint.length > 0 ? ' · ' + this.decodeHint : ''}`)
          .fontSize(14 * this.uiScale())
          .fontColor(this.pal().trackBuffered)
          .margin({ top: 2 })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 4 })

      this.iconBtn(this.locked ? PlayIconSet.LOCK : PlayIconSet.UNLOCK,
        Math.max(24, Math.round(22 * this.uiScale())), Color.White, '', false, 'lock')
      this.iconBtn(PlayIconSet.MORE, Math.max(24, Math.round(24 * this.uiScale())), Color.White, '', false, 'topmore')
    }
    .width('100%')
    .height((this.isWide ? 70 : 64) * this.uiScale())
    .padding({ left: this.sideInset(), right: this.sideInset() })
    .linearGradient({ direction: GradientDirection.Bottom, colors: [['#B3000000', 0], ['#00000000', 1]] })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  centerBar() {
    Row() {
      this.iconBtn(PlayIconSet.REWIND, Math.max(24, Math.round(26 * this.uiScale())), Color.White, '-10s', false, 'rewind')
      if (this.isPlaying) {
        this.iconBtn(PlayIconSet.PAUSE, Math.round(this.playVisual() * 1.5), Color.White, '', true, 'play')
      } else {
        this.iconBtn(PlayIconSet.PLAY, Math.round(this.playVisual() * 1.5), Color.White, '', true, 'play')
      }
      this.iconBtn(PlayIconSet.FORWARD, Math.max(24, Math.round(26 * this.uiScale())), Color.White, '+10s', false, 'forward')
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
  }

  /** 音量浮层（点击音量图标展开，替代原文字音量标签） */
  @Builder
  volumeRow() {
    Row() {
      Image(PlayIconSet.VOLUME)
        .width(18)
        .height(18)
        .fillColor(Color.White)
        .draggable(false)
      Slider({
        value: this.volumeLevel,
        min: 0,
        max: 1,
        step: 0.01,
        style: SliderStyle.OutSet
      })
        .layoutWeight(1)
        .blockColor(this.pal().primary)
        .trackColor(this.pal().trackUnplayed)
        .selectedColor(this.pal().primary)
        .trackThickness(4)
        .blockSize({ width: 16, height: 16 })
        .margin({ left: 10, right: 10 })
        .onChange((value: number, mode: SliderChangeMode) => {
          this.setVolume(value);
        })
      Text(`${Math.round(this.volumeLevel * 100)}%`)
        .fontSize(12)
        .fontColor(Color.White)
        .width(44)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .height(36)
    .padding({ left: 14, right: 14 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor('#33000000')
    .borderRadius(18)
  }

  /** 进度行：上行 */
  @Builder
  progressRow() {
    Row() {
      Text(formatDuration(this.positionMs))
        .fontSize(13 * this.uiScale())
        .fontColor(Color.White)
        .width(60 * this.uiScale())
        .textAlign(TextAlign.End)
      Slider({
        value: this.positionMs,
        min: 0,
        max: this.durationMs > 0 ? this.durationMs : 1,
        step: 1,
        style: SliderStyle.OutSet
      })
        .layoutWeight(1)
        .blockColor(this.pal().primary)
        .trackColor(this.pal().trackUnplayed)
        .selectedColor(this.pal().primary)
        .trackThickness(4)
        .blockSize({ width: 18 * this.uiScale(), height: 18 * this.uiScale() })
        .margin({ left: 8, right: 8 })
        .onChange((value: number, mode: SliderChangeMode) => {
          this.positionMs = value;
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.seekTo(value);
          }
        })
      Text(formatDuration(this.durationMs))
        .fontSize(13 * this.uiScale())
        .fontColor(Color.White)
        .width(60 * this.uiScale())
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .constraintSize({ minHeight: 36 })
    .alignItems(VerticalAlign.Center)
  }

  /** 图标行（换行模式）：屏宽不足时自动换行，绝不横向溢出 */
  @Builder
  iconRow() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center, alignItems: ItemAlign.Center }) {
      ForEach(this.barIconIds(), (id: string) => {
        this.iconBtnFor(id)
      }, (id: string) => this.iconKey(id))
    }
    .width('100%')
  }

  /** 图标行（单行模式）：横屏宽屏时与进度同排 */
  @Builder
  inlineIconRow() {
    Row() {
      ForEach(this.barIconIds(), (id: string) => {
        this.iconBtnFor(id)
      }, (id: string) => this.iconKey(id))
    }
    .alignItems(VerticalAlign.Center)
  }

  private iconKey(id: string): string {
    return `${id}_${this.isPlaying}_${this.speed}_${this.subtitleLoaded}_${this.volumePanelVisible}_${this.morePanelVisible}`;
  }

  /** 「更多」浮层：宽屏放不下的次要控件收在此处，仍全部使用图标 */
  @Builder
  morePanel() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
      this.moreCell(PlayIconSet.aspect(this.aspect), this.aspectLabel(), 'aspect', false)
      this.moreCell(PlayIconSet.TRACK, '音轨', 'track', false)
      this.moreCell(PlayIconSet.DECODE, this.decodeLabel(), 'decode', this.decodeMode === 'sw')
      this.moreCell(PlayIconSet.loop(this.loopSingle), this.loopSingle ? '单曲' : '列表', 'loop', this.loopSingle)
      this.moreCell(PlayIconSet.fullscreen(this.screenLandscape), this.screenLandscape ? '竖屏' : '横屏', 'fullscreen', false)
      this.castCell()
      this.dlnaCastCell()
      this.moreCell(PlayIconSet.SUBTITLE, '字幕文件', 'subtitle', this.subtitleLoaded)
      this.moreCell(PlayIconSet.RESTART, '从头播放', 'restart', false)
      this.moreCell(PlayIconSet.INFO, '媒体信息', 'info', false)
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 8, bottom: 2 })
    .backgroundColor('#4D000000')
    .borderRadius(12)
    .margin({ bottom: 6 })
  }

  @Builder
  moreCell(icon: Resource, label: string, id: string, active: boolean) {
    Column() {
      Image(icon)
        .width(24)
        .height(24)
        .fillColor(this.tintOf(active))
        .draggable(false)
      Text(label)
        .fontSize(10)
        .fontColor(this.tintOf(active))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 4 })
    }
    .width(64)
    .height(62)
    .justifyContent(FlexAlign.Center)
    .borderRadius(10)
    .backgroundColor('#26FFFFFF')
    .margin({ right: 6, bottom: 6 })
    .onClick(() => {
      this.runIconAction(id);
      this.showControls();
    })
  }

  /** 投屏入口：系统投播选择器（DLNA / Cast+），图标为系统投播图标 */
  @Builder
  castCell() {
    Column() {
      AVCastPicker({
        onStateChange: (state: AVCastPickerState): void => {
          if (state === AVCastPickerState.STATE_APPEARING) {
            this.castActive = true;
          } else if (state === AVCastPickerState.STATE_DISAPPEARING) {
            this.castActive = this.castHelper.isCasting;
          }
        }
      })
        .width(30)
        .height(30)
      Text(this.castActive ? '投屏中' : '投屏')
        .fontSize(10)
        .fontColor(this.tintOf(this.castActive))
        .maxLines(1)
        .margin({ top: 4 })
    }
    .width(64)
    .height(62)
    .justifyContent(FlexAlign.Center)
    .borderRadius(10)
    .backgroundColor('#26FFFFFF')
    .margin({ right: 6, bottom: 6 })
  }

  /** DLNA 投屏入口：设备发现弹层 + 当前投屏状态文案（未连接/正在投屏/已暂停） */
  @Builder
  dlnaCastCell() {
    Column() {
      Image(PlayIconSet.CAST)
        .width(24)
        .height(24)
        .fillColor(this.castTint())
        .draggable(false)
      Text(this.castLabel())
        .fontSize(10)
        .fontColor(this.castTint())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 4 })
    }
    .width(64)
    .height(62)
    .justifyContent(FlexAlign.Center)
    .borderRadius(10)
    .backgroundColor('#26FFFFFF')
    .margin({ right: 6, bottom: 6 })
    .onClick(() => {
      this.runIconAction('cast');
      this.showControls();
    })
  }

  /** 投屏设备选择弹层：发现中 / 无设备 / 错误 三态 + 断开当前投屏 */
  @Builder
  castSheet() {
    Column() {
      Row() {
        Text('投屏')
          .fontSize(16)
          .fontColor(Color.White)
          .layoutWeight(1)
        if (this.castBusy) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color(this.pal().primary)
        }
        Text('关闭')
          .fontSize(14)
          .fontColor(this.pal().trackBuffered)
          .padding({ left: 12, top: 6, bottom: 6 })
          .onClick(() => {
            this.castSheetOpen = false;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Text(this.castTip)
        .fontSize(12)
        .fontColor(this.pal().trackBuffered)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 6 })
        .maxLines(2)

      if (this.castError.length > 0) {
        Text(this.castError)
          .fontSize(12)
          .fontColor('#FFFF6B6B')
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 })
          .maxLines(3)
      }

      if (this.castRenderers.length > 0) {
        List() {
          ForEach(this.castRenderers, (item: CastRenderer) => {
            ListItem() {
              Row() {
                Image(PlayIconSet.CAST)
                  .width(22)
                  .height(22)
                  .fillColor(Color.White)
                  .draggable(false)
                Column() {
                  Text(item.name)
                    .fontSize(14)
                    .fontColor(Color.White)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(item.model.length > 0 ? item.model : item.ip)
                    .fontSize(11)
                    .fontColor(this.pal().trackBuffered)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .margin({ top: 2 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .margin({ left: 10 })
                if (this.castDevice === item.name && DlnaCast.isCasting) {
                  Text('已连接')
                    .fontSize(11)
                    .fontColor(this.pal().primary)
                }
              }
              .width('100%')
              .height(56)
              .padding({ left: 16, right: 16 })
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                this.pickCast(item);
              })
            }
          }, (item: CastRenderer) => item.udn)
        }
        .width('100%')
        .height(this.castRenderers.length > 4 ? 224 : this.castRenderers.length * 56)
        .scrollBar(BarState.Auto)
      }

      Row() {
        Button(this.castBusy ? '搜索中…' : '重新搜索')
          .fontSize(13)
          .height(34)
          .backgroundColor('#26FFFFFF')
          .fontColor(Color.White)
          .enabled(!this.castBusy)
          .onClick(() => {
            this.scanCast();
          })
        if (DlnaCast.isCasting) {
          Button('断开投屏')
            .fontSize(13)
            .height(34)
            .backgroundColor('#26FFFFFF')
            .fontColor('#FFFF6B6B')
            .margin({ left: 10 })
            .onClick(() => {
              this.stopCasting();
              this.castSheetOpen = false;
            })
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 8, bottom: 12 })
    }
    .width('86%')
    .constraintSize({ maxWidth: 460 })
    .backgroundColor('#F21A1A1A')
    .borderRadius(14)
    .onClick(() => {
    })
  }

  @Builder
  bottomBar() {
    Column() {
      if (this.morePanelVisible) {
        this.morePanel()
      }
      if (this.volumePanelVisible) {
        this.volumeRow()
      }
      if (this.singleRowMode()) {
        // 横屏单行：进度 + 图标同一行，左右留安全区
        Row() {
          Text(formatDuration(this.positionMs))
            .fontSize(13)
            .fontColor(Color.White)
            .width(58)
            .textAlign(TextAlign.End)
          Slider({
            value: this.positionMs,
            min: 0,
            max: this.durationMs > 0 ? this.durationMs : 1,
            step: 1,
            style: SliderStyle.OutSet
          })
            .layoutWeight(1)
            .blockColor(this.pal().primary)
            .trackColor(this.pal().trackUnplayed)
            .selectedColor(this.pal().primary)
            .trackThickness(4)
            .blockSize({ width: 18, height: 18 })
            .margin({ left: 8, right: 8 })
            .onChange((value: number, mode: SliderChangeMode) => {
              this.positionMs = value;
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                this.seekTo(value);
              }
            })
          Text(formatDuration(this.durationMs))
            .fontSize(13)
            .fontColor(Color.White)
            .width(58)
            .textAlign(TextAlign.Start)
          this.inlineIconRow()
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      } else {
        // 竖屏 / 极窄屏 / 折叠态：两行（上行进度、下行图标组）
        this.progressRow()
        this.iconRow()
      }
    }
    .width('100%')
    .padding({ left: this.sideInset(), right: this.sideInset(), bottom: 6 })
    .linearGradient({ direction: GradientDirection.Top, colors: [['#B3000000', 0], ['#00000000', 1]] })
  }

  @Builder
  gestureOverlay() {
    if (this.overlayText.length > 0) {
      Column() {
        Text(this.overlayText)
          .fontSize(14)
          .fontColor(Color.White)
        if (this.overlayKind !== GestureKind.NONE) {
          Progress({ value: this.overlayPercent, total: 100, type: ProgressType.Linear })
            .width(160)
            .color(this.pal().primary)
            .backgroundColor(this.pal().trackUnplayed)
            .margin({ top: 8 })
        }
      }
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor('#B3000000')
      .borderRadius(8)
    }
  }

  /** 画面宽度（\pos / \move 的横向偏移用） */
  private surfaceWidth(): number {
    if (this.containerW > 0) {
      return this.containerW;
    }
    return this.isWide ? 720 : 360;
  }

  /**
   * 字幕层总入口：
   * 整条字幕承载对齐（\an）、绝对定位（\pos/\move）、透明度（\fad）、旋转（\frz），
   * 段落样式交给 Span 承载。
   */
  @Builder
  subtitleLayer() {
    if (this.subtitleText.length > 0 && this.subRuns.length > 0) {
      Stack() {
        if (this.subXRatio >= 0) {
          Row() {
            this.subtitleTextBlock()
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .position({ x: 0, y: `${this.subYRatio * 100}%` })
          .offset({ x: (this.subXRatio - 0.5) * this.surfaceWidth(), y: -22 })
        } else {
          this.subtitleTextBlock()
        }
      }
      .width('100%')
      .height('100%')
      .alignContent(this.subtitleAlignment())
      .padding({ left: 20, right: 20, top: 40, bottom: this.controlsVisible ? 120 : 40 })
      .hitTestBehavior(HitTestMode.None)
    }
  }

  /** 一条字幕的样式化文本块：颜色 / 字号 / 粗斜体 / 下划线 / 描边 / 阴影 */
  @Builder
  subtitleTextBlock() {
    Text() {
      ForEach(this.subRuns, (run: SubtitleRun) => {
        Span(run.text)
          .fontSize(this.runFontSize(run))
          .fontColor(run.color.length > 0 ? run.color : '#FFFFFF')
          .fontWeight(run.bold ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(run.italic ? FontStyle.Italic : FontStyle.Normal)
          .decoration({
            type: run.underline ? TextDecorationType.Underline : TextDecorationType.None,
            color: run.color.length > 0 ? run.color : '#FFFFFF'
          })
          .textShadow(this.runShadow(run))
      }, (run: SubtitleRun, index: number) => `${index}_${run.text}`)
    }
    .fontSize((this.isWide ? 20 : 16) * this.uiScale())
    .fontColor(Color.White)
    .textAlign(TextAlign.Center)
    .maxLines(this.isWide ? 4 : 3)
    .padding(this.isWide ? 10 : 8)
    .backgroundColor('#80000000')
    .borderRadius(6)
    .opacity(this.subOpacity)
    .rotate({ angle: this.subRotate })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      XComponent({
        id: 'player_surface',
        type: XComponentType.SURFACE,
        controller: this.xController
      })
        .width('100%')
        .height('100%')
        .onLoad(() => {
          this.surfaceId = this.xController.getXComponentSurfaceId();
          const player: media.AVPlayer | undefined = this.avPlayer;
          if (player !== undefined) {
            this.applySurface(player, true, 'xcomponent-onload');
          }
          // 唤醒还在等 surface 的起播流程
          this.notifySurfaceReady(this.surfaceId);
        })
        .onDestroy(() => {
          this.surfaceId = '';
          this.surfaceBound = false;
        })

      // 外挂字幕层：SRT/VTT 走单段纯文本，ASS/SSA 走多段样式化渲染
      this.subtitleLayer()

      if (this.errorMsg.length > 0) {
        Column() {
          Text(this.errorMsg)
            .fontSize(14)
            .fontColor(Color.White)
          Button('返回')
            .fontSize(14)
            .margin({ top: 12 })
            .onClick(() => {
              router.back();
            })
        }
      }

      // 手势捕获层（不拦截已显示的控制层按钮由下层处理，此层仅处理滑动/点击）
      Stack()
        .width('100%')
        .height('100%')
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.containerW = Number(newValue.width);
          this.containerH = Number(newValue.height);
          this.recomputeVideoBox();
        })
        .gesture(
          GestureGroup(GestureMode.Exclusive,
            TapGesture({ count: 2 }).onAction(() => {
              if (!this.locked && this.gestureEnabled) {
                this.togglePlay();
              }
            }),
            TapGesture({ count: 1 }).onAction(() => {
              if (this.locked) {
                promptAction.showToast({ message: '已锁定，先点左上角解锁' });
                return;
              }
              this.toggleControls();
            }),
            LongPressGesture({ repeat: false }).onAction(() => {
              this.onLongPressStart();
            }).onActionEnd(() => {
              this.onLongPressEnd();
            }).onActionCancel(() => {
              this.onLongPressEnd();
            }),
            PanGesture({ fingers: 1, distance: PAN_THRESHOLD })
              .onActionStart((event: GestureEvent) => {
                this.onPanStart(event);
              })
              .onActionUpdate((event: GestureEvent) => {
                this.onPanUpdate(event);
              })
              .onActionEnd(() => {
                this.onPanEnd();
              })
              .onActionCancel(() => {
                this.onPanEnd();
              })
          )
        )

      this.gestureOverlay()

      if (this.controlsVisible && !this.locked) {
        Column() {
          this.topBar()
          Blank()
          this.centerBar()
          Blank()
          this.bottomBar()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.pal().controllerScrim)
        .onClick(() => {
          this.toggleControls();
        })
      }

      // 在线字幕面板
      if (this.subDlgVisible) {
        Column() {
          Row() {
            Text('在线字幕')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.pal().textPrimary)
              .layoutWeight(1)
            Text('关闭')
              .fontSize(13)
              .fontColor(this.pal().primary)
              .padding(6)
              .onClick(() => {
                this.subDlgVisible = false;
              })
          }
          .width('100%')

          Row() {
            TextInput({ text: this.subKeyword, placeholder: '片名关键词' })
              .fontSize(13)
              .fontColor(this.pal().textPrimary)
              .placeholderColor(this.pal().textTertiary)
              .backgroundColor(this.pal().bgChip)
              .height(38)
              .layoutWeight(1)
              .onChange((v: string) => {
                this.subKeyword = v;
              })
              .onSubmit(() => {
                this.searchSubtitles();
              })
            Text('搜索')
              .fontSize(13)
              .fontColor(Color.White)
              .backgroundColor(this.pal().primary)
              .borderRadius(10)
              .height(38)
              .padding({ left: 16, right: 16 })
              .margin({ left: 8 })
              .onClick(() => {
                this.searchSubtitles();
              })
          }
          .width('100%')
          .margin({ top: 10 })

          Row() {
            TextInput({ text: this.subDirectUrl, placeholder: '粘贴字幕直链（srt/vtt/zip，无需 Api-Key）' })
              .fontSize(12)
              .fontColor(this.pal().textPrimary)
              .placeholderColor(this.pal().textTertiary)
              .backgroundColor(this.pal().bgChip)
              .height(36)
              .layoutWeight(1)
              .onChange((v: string) => {
                this.subDirectUrl = v;
              })
            Text('导入')
              .fontSize(12)
              .fontColor(this.pal().primary)
              .height(36)
              .padding({ left: 12, right: 12 })
              .onClick(() => {
                this.importSubtitleByUrl();
              })
          }
          .width('100%')
          .margin({ top: 8 })

          if (this.subLoading) {
            Row() {
              LoadingProgress()
                .width(26)
                .height(26)
                .color(this.pal().primary)
              Text('处理中…')
                .fontSize(12)
                .fontColor(this.pal().textSecondary)
                .margin({ left: 8 })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .margin({ top: 12 })
          }

          if (this.subFailed.length > 0) {
            Text(this.subFailed)
              .fontSize(12)
              .fontColor(this.pal().danger)
              .width('100%')
              .margin({ top: 10 })
          }

          List({ space: 6 }) {
            ForEach(this.subResults, (it: SubtitleItem) => {
              ListItem() {
                Column() {
                  Text(it.label())
                    .fontSize(12)
                    .fontColor(this.pal().textPrimary)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(it.source === 'os' ? '点击下载并载入（需 Api-Key）' : '点击下载并载入')
                    .fontSize(10)
                    .fontColor(this.pal().textTertiary)
                    .width('100%')
                    .margin({ top: 3 })
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .padding(10)
                .backgroundColor(this.pal().bgChip)
                .borderRadius(8)
                .onClick(() => {
                  this.pickSubtitle(it);
                })
              }
            }, (it: SubtitleItem) => `${it.id}_${it.fileId}`)
          }
          .layoutWeight(1)
          .width('100%')
          .margin({ top: 10 })
          .scrollBar(BarState.Off)

          Text(this.subFromOs
            ? '结果来自 opensubtitles.com（已使用设置中的 Api-Key）'
            : '结果合并自 射手网（伪）assrt.net 与 SubtitleCat，均免注册；下载后自动转 UTF-8 并按简体优先挑选')
            .fontSize(10)
            .fontColor(this.pal().textTertiary)
            .width('100%')
            .margin({ top: 8 })
        }
        .width(this.isWide ? '60%' : '90%')
        .height('72%')
        .padding(16)
        .backgroundColor(this.pal().bgCard)
        .borderRadius(14)
        .onClick(() => {
        })
      }

      if (this.castSheetOpen) {
        Column() {
          this.castSheet()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#99000000')
        .onClick(() => {
          this.castSheetOpen = false;
        })
      }

      if (this.locked) {
        Text('🔒')
          .fontSize(18)
          .width(44)
          .height(44)
          .textAlign(TextAlign.Center)
          .backgroundColor('#66000000')
          .borderRadius(22)
          .position({ x: 8, y: 8 })
          .onClick(() => {
            this.locked = false;
            this.showControls();
          })
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .backgroundColor(this.pal().playerBg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindMenu(this.menuVisible, this.menuItems, {
      onDisappear: () => {
        this.menuVisible = false;
      }
    })
  }
}
