/**
 * 播放�?
 * 视频播放、剧集切换、播放进度保�?
 */
import { Palette } from '../utils/ThemeManager';
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { getTopSafeAreaVp, getTopSafeAreaSync, getBottomSafeAreaVp, Breakpoint, BP_SM, BP_MD, BP_LG, getBreakpoint, isLandscape } from '../utils/ScreenAdapter';
import { DS, Motion } from '../utils/DesignSystem';
import { display } from '@kit.ArkUI';
import { audio } from '@kit.AudioKit';
import { SourceViewModel } from '../viewmodel/SourceViewModel';
import { VodInfo, VodSeries, VodSeriesFlag, PlayInfo } from '../model/Movie';
import { HistoryRepository, HistoryRecord } from '../data/Database';
import { formatError, httpGet } from '../utils/HttpUtil';
import { media } from '@kit.MediaKit';
import { statistics } from '@kit.NetworkKit';
import { bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PanResolver } from '../api/pan/PanResolver';
import { detectPan, PanHit } from '../util/PanDetector';
import { PanConfig, PanCredential, PanKind, PanCredentialSource } from '../utils/PanConfig';
import { AVCastPicker } from '@kit.AVSessionKit';
import { AVCastPickerState } from '@ohos.multimedia.avCastPickerParam';
import { CastSessionHelper } from '../utils/CastSessionHelper';
import { PlaybackManager } from '../utils/PlaybackManager';
import { PlayIcons } from '../../common/PlayIcons';
import { PlayIconSet } from '../../common/PlayIconSet';
import { emitter } from '@kit.BasicServicesKit';
import { TvCacheStore } from '../../utils/TvCacheStore';
import { CACHE_PREPARE_EVENT_ID } from '../../utils/CacheCleaner';

interface PlayerParams {
  vodId: string;
  sourceKey: string;
  name: string;
  flag: string;
  epIndex: number;
  epName: string;
  epUrl: string;
}

interface SizeResult {
  w: number | string;
  h: number | string;
}

const SPEED_OPTIONS: number[] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
const SCALE_MODES: string[] = ['默认', '拉伸', '平铺'];
const AUTO_HIDE_MS: number = 5000;

@Entry
@Component
struct PlayerPage {
  @State vodId: string = '';
  @State sourceKey: string = '';
  @State name: string = '';
  @State flag: string = '';
  @State epIndex: number = 0;
  @State epName: string = '';
  @State epUrl: string = '';
  @State playUrl: string = '';
  @State loading: boolean = false;
  @State hasError: boolean = false;
  @State errorMsg: string = '';
  @State vodInfo: VodInfo | null = null;
  @State currentFlagIndex: number = 0;
  @State showControls: boolean = true;
  @State manualLandscape: boolean = false;
  private avPlayer: media.AVPlayer | null = null;
  private castHelper: CastSessionHelper = new CastSessionHelper();
  private preparing: boolean = false;
  private playStarted: boolean = false;
  private xComponentController: XComponentController = new XComponentController();
  private surfaceId: string = '';
  @State playHeaders: Map<string, string> = new Map();
  @State showResumeDialog: boolean = false;
  @State resumePosition: number = 0;
  // 已看过的集合�?flag|epIndex' 集合，用于详情页/播放器区分已看集�?
  @State watchedEps: Set<string> = new Set<string>();
  // 每集播放进度�?flag|epIndex' �?'position|duration'（ms�?
  @State epProgress: Map<string, string> = new Map<string, string>();
  // 起播时自动跳转的记忆位置(ms)；用户点�?从头播放'后清 0；点�?恢复播放'再恢�?
  @State savedResumeMs: number = 0;
  @State savedResumeEpIndex: number = -1;
  @State restartFromZero: boolean = false;
  private progressSaveTimerId: number = -1;
  private loadingWatchdogId: number = -1;
  private restartRevertTimerId: number = -1;
  @State playbackSpeed: number = 1.0;
  @State showSpeedMenu: boolean = false;
  @State isPlaying: boolean = true;
  @State currentTime: number = 0;
  @State duration: number = 0;
  @State sliderValue: number = 0;
  @State isSeeking: boolean = false;
  @State netSpeed: string = '0kb/s';
  @State videoWidth: number = 0;
  @State videoHeight: number = 0;
  @State sysTime: string = '';
  @State scaleModeIndex: number = 0;
  @State containerW: number = 0;
  @State containerH: number = 0;
  @State topSafe: number = 0;
  @State bottomSafe: number = 0;
  @State screenBrightness: number = 0.5;
  @State sysVolume: number = 0;
  @State sysMaxVolume: number = 15;
  @State playerVolume: number = 1;
  @State showGestureHud: boolean = false;
  @State gestureHudIcon: string = '';
  @State gestureHudText: string = '';
  private gestureIsLeft: boolean = false;
  private panAxis: string = '';
  private gestureStartBrightness: number = 0.5;
  private gestureStartVolume: number = 1.0;
  private pendingVolume: number = -1;
  private volumeSetInFlight: boolean = false;
  private volumeQueued: number = -1;
  private volumeCb: ((e: audio.VolumeEvent) => void) | null = null;
  private gestureHudTimer: number = -1;
  private lastDoubleTapTime: number = 0;
  private lastPanEndTime: number = 0;
  private pendingClickTimerId: number = -1;
  private longPressActive: boolean = false;
  private speedBeforeLongPress: number = 1.0;
  private horizSeeking: boolean = false;
  private gestureStartSeekTime: number = 0;
  private gestureSeekTarget: number = 0;
  @State showEpisodes: boolean = false;
  @StorageProp('isDarkMode') isDark: boolean = true;
  @State castPickerOpen: boolean = false;
  @State bp: Breakpoint = BP_SM;
  @State isLand: boolean = false;
    private foldListener: (s: display.FoldStatus) => void = (_s: display.FoldStatus): void => { this.displayListener(0); };
  private displayListener: (id: number) => void = (id: number) => { this.bp = getBreakpoint(); this.isLand = isLandscape(); };
  private hideTimerId: number = -1;
  private netTimerId: number = -1;
  private lastRxBytes: number = -1;
  private appUid: number = -1;
  private errorRetryCount: number = 0;
  private maxRetryCount: number = 3;
  private playbackStartTime: number = 0;
  private hasActuallyPlayed: boolean = false;
  private isRetrying: boolean = false;
  private autoSwitchTriedFlags: Set<string> = new Set<string>();
  private lastRetryAt: number = 0;
  private pendingSeek: number = -1;
  private bgResumeMs: number = 0;
  private pausedForBackground: boolean = false;
  private winInstance: window.Window | null = null;
  /** 清除缓存已释放播放器，下次点播放需要重新 prepare */
  private needReprepare: boolean = false;
  private cachePrepareListener: (data: emitter.EventData) => void =
    (_data: emitter.EventData): void => {
      this.onCachePrepare();
    };

  async aboutToAppear() {
    const params = router.getParams() as PlayerParams;
    if (params) {
      this.vodId = params.vodId;
      this.sourceKey = params.sourceKey;
      this.name = params.name;
      this.flag = params.flag;
      this.epIndex = params.epIndex;
      this.epName = params.epName;
      this.epUrl = params.epUrl;
    }
    this.updateSysTime();
    this.startNetSpeedTimer();
    this.initSafeArea();
    this.hideSystemBars();
    this.keepScreenOn(true);
    this.bp = getBreakpoint();
    this.isLand = isLandscape();
    try { display.on('change', this.displayListener); display.on('foldStatusChange', this.foldListener); } catch (_e) {}
    this.initSystemVolume();
    this.initAVPlayer();
    this.castHelper.ensure(this.getUIContext().getHostContext() as common.UIAbilityContext).then((): void => { this.updateCastMetadata(); });
    this.loadPlayUrl();
    this.loadDetail();
    this.checkResume();
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      TvCacheStore.init(ctx);
      emitter.on(CACHE_PREPARE_EVENT_ID, this.cachePrepareListener);
    } catch (_e) {
    }
    ctx.eventHub.on('app-background', (): void => { this.onPageHide(); });
    ctx.eventHub.on('app-foreground', (): void => { this.onPageShow(); });
    PlaybackManager.setCallbacks((): void => { this.onPageHide(); }, (): void => { this.onPageShow(); });
  }

  private initSystemVolume(): void {
    try {
      const am = audio.getAudioManager();
      const vgm = am.getVolumeManager().getVolumeGroupManagerSync(audio.DEFAULT_VOLUME_GROUP_ID);
      this.sysMaxVolume = vgm.getMaxVolumeSync(audio.AudioVolumeType.MEDIA);
      this.sysVolume = vgm.getVolumeSync(audio.AudioVolumeType.MEDIA);
      const cb: (e: audio.VolumeEvent) => void = (e: audio.VolumeEvent): void => {
        if (e.volumeType === audio.AudioVolumeType.MEDIA) { this.sysVolume = e.volume; }
      };
      this.volumeCb = cb;
      am.getVolumeManager().on('volumeChange', cb);
    } catch (e) {
      hilog.warn(0x0001, 'YSC', 'initSystemVolume failed: %{public}s', JSON.stringify(e) ?? '');
    }
  }

  private setSystemVolume(level: number): void {
    if (this.sysMaxVolume <= 0) return;
    const clamped: number = level < 0 ? 0 : (level > this.sysMaxVolume ? this.sysMaxVolume : level);
    if (clamped === this.sysVolume) return;
    try {
      const am = audio.getAudioManager();
      am.setVolume(audio.AudioVolumeType.MEDIA, clamped).catch((e: Object): void => {
        hilog.warn(0x0001, 'YSC', 'setSystemVolume failed: %{public}s', JSON.stringify(e) ?? '');
      });
      this.sysVolume = clamped;
    } catch (e) {
      hilog.warn(0x0001, 'YSC', 'setSystemVolume failed: %{public}s', JSON.stringify(e) ?? '');
    }
  }

  // 播放页进入全屏沉浸：隐藏状态栏，避让区归零，顶栏贴屏幕顶部
  private async applyVideoOrientation(): Promise<void> {
    if (this.videoWidth <= 0 || this.videoHeight <= 0) {
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      if (this.videoWidth < this.videoHeight) {
        // 竖屏视频：自身独占竖屏全屏，不旋转横屏
        await win.setPreferredOrientation(window.Orientation.USER_ROTATION_PORTRAIT);
        this.manualLandscape = false;
      } else {
        // 横屏视频：横屏全屏
        await win.setPreferredOrientation(window.Orientation.USER_ROTATION_LANDSCAPE);
        this.manualLandscape = true;
      }
      this.topSafe = 0;
    } catch (e) {
      hilog.error(0x0001, 'YSC', 'applyVideoOrientation failed: %{public}s', JSON.stringify(e));
    }
  }

  private async hideSystemBars(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      await win.setWindowSystemBarEnable(['navigation']);
      this.topSafe = 0;
    } catch (_e) {}
  }

  private async restoreSystemBars(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      await win.setWindowSystemBarEnable(['status', 'navigation']);
    } catch (_e) {}
  }

  private async keepScreenOn(enable: boolean): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      await win.setWindowKeepScreenOn(enable);
    } catch (e) {
      hilog.warn(0x0001, 'YSC', 'setWindowKeepScreenOn(%{public}b) failed: %{public}s', enable, JSON.stringify(e) ?? '');
    }
  }

  private async initSafeArea() {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.topSafe = await getTopSafeAreaVp(ctx);
    this.bottomSafe = await getBottomSafeAreaVp(ctx);
    // 动态监听安全区：就�?横竖屏切换时更新，避免控制栏压住状态栏或小白条
    try {
      const win = await window.getLastWindow(ctx);
      this.winInstance = win;
      win.on('windowEvent', (event: window.WindowEventType): void => {
        if (event === window.WindowEventType.WINDOW_INACTIVE || event === window.WindowEventType.WINDOW_HIDDEN) {
          this.onPageHide();
        } else if (event === window.WindowEventType.WINDOW_ACTIVE || event === window.WindowEventType.WINDOW_SHOWN) {
          this.onPageShow();
        }
      });
      win.on('avoidAreaChange', (data): void => {
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM || data.type === window.AvoidAreaType.TYPE_CUTOUT) {
          const th: number = getTopSafeAreaSync(win);
          if (th > 0) { this.topSafe = th; }
        } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          const bh: number = data.area.bottomRect.height;
          if (bh > 0) { this.bottomSafe = px2vp(bh); }
        }
      });
    } catch (_e) {}
  }

  updateSysTime() {
    const now: Date = new Date();
    const h: number = now.getHours();
    const m: number = now.getMinutes();
    const hStr: string = h < 10 ? '0' + h.toString() : h.toString();
    const mStr: string = m < 10 ? '0' + m.toString() : m.toString();
    this.sysTime = hStr + ':' + mStr;
  }

  private resolveAppUid(): void {
    if (this.appUid >= 0) {
      return;
    }
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.appUid = info.appInfo.uid;
      hilog.info(0x0001, 'YSC', 'net speed appUid=%{public}d', this.appUid);
    } catch (e) {
      hilog.error(0x0001, 'YSC', 'resolveAppUid failed: %{public}s', JSON.stringify(e) ?? '');
    }
  }

  private async readRxBytes(): Promise<number> {
    // 优先统计本应�?UID 的下行流量（更精准），失败时回退设备总量
    if (this.appUid >= 0) {
      try {
        return await statistics.getUidRxBytes(this.appUid);
      } catch (e) {
        hilog.warn(0x0001, 'YSC', 'getUidRxBytes failed, fallback: %{public}s', JSON.stringify(e) ?? '');
      }
    }
    return await statistics.getAllRxBytes();
  }

  startNetSpeedTimer(): void {
    this.stopNetSpeedTimer();
    this.lastRxBytes = -1;
    this.resolveAppUid();
    this.netTimerId = setInterval((): void => {
      this.updateSysTime();
      this.readRxBytes().then((total: number): void => {
        if (this.lastRxBytes >= 0 && total >= this.lastRxBytes) {
          const diff: number = total - this.lastRxBytes;
          this.netSpeed = this.formatSpeed(diff);
        }
        this.lastRxBytes = total;
      }).catch((err: Object): void => {
        hilog.warn(0x0001, 'YSC', 'readRxBytes error: %{public}s', JSON.stringify(err) ?? '');
      });
    }, 1000);
  }

  stopNetSpeedTimer(): void {
    if (this.netTimerId !== -1) {
      clearInterval(this.netTimerId);
      this.netTimerId = -1;
    }
  }

  formatSpeed(bytesPerSec: number): string {
    if (bytesPerSec >= 1024 * 1024) {
      return (bytesPerSec / (1024 * 1024)).toFixed(1) + 'MB/s';
    } else if (bytesPerSec >= 1024) {
      return (bytesPerSec / 1024).toFixed(0) + 'KB/s';
    }
    return bytesPerSec + 'B/s';
  }

  aboutToDisappear() {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try { emitter.off(CACHE_PREPARE_EVENT_ID, this.cachePrepareListener); } catch (_e) {}
    ctx.eventHub.off('app-background');
    ctx.eventHub.off('app-foreground');
    PlaybackManager.setCallbacks(null, null);
    this.pausedForBackground = false;
    if (this.winInstance) { try { this.winInstance.off('windowEvent'); } catch (_e) {} this.winInstance = null; }
    try { display.off('change', this.displayListener); display.off('foldStatusChange', this.foldListener); } catch (_e) {}
    try { audio.getAudioManager().getVolumeManager().off('volumeChange'); } catch (_eVol) {}
    this.restoreAutoRotation();
    this.keepScreenOn(false);
    this.restoreSystemBars();
    this.stopNetSpeedTimer();
    this.stopProgressSaveTimer();
    this.clearLoadingWatchdog();
    this.clearRestartRevertTimer();
    // 关闭前再保存一次进�?
    if (this.hasActuallyPlayed && this.currentTime > 3000) {
      this.updateCurrentEpProgress(this.currentTime, this.duration);
      this.saveHistory(this.currentTime, this.duration);
    }
    if (this.hideTimerId !== -1) { clearTimeout(this.hideTimerId); this.hideTimerId = -1; }
    if (this.pendingClickTimerId !== -1) { clearTimeout(this.pendingClickTimerId); this.pendingClickTimerId = -1; }
    this.releaseAVPlayer();
    if (!this.castHelper.isCasting) {
      this.castHelper.release();
    }
  }

  onPageHide() {
    if (this.pausedForBackground) return;
    if (this.avPlayer && this.hasActuallyPlayed) {
      if (this.currentTime > 3000) {
        this.updateCurrentEpProgress(this.currentTime, this.duration);
        this.saveHistory(this.currentTime, this.duration);
      }
      this.bgResumeMs = this.currentTime;
      this.stopProgressSaveTimer();
      this.stopNetSpeedTimer();
      this.clearLoadingWatchdog();
      // 暂停本地播放器，保留缓冲数据供返回时续播
      try { this.avPlayer.pause(); } catch (_e) {}
      this.isPlaying = false;
      if (!this.castHelper.isCasting) {
        this.castHelper.release();
      }
      this.pausedForBackground = true;
      hilog.info(0x0001, 'YSC', 'onPageHide: background, isCasting=%{public}s, resumeMs=%{public}d', this.castHelper.isCasting.toString(), this.bgResumeMs);
    }
  }

  onPageShow() {
    if (this.pausedForBackground && this.playUrl.length > 0) {
      this.pausedForBackground = false;
      // 始终恢复本地播放器
      this.startNetSpeedTimer();
      if (this.avPlayer) {
        const state: string = this.avPlayer.state;
        if (state === 'paused' || state === 'prepared' || state === 'playing' || state === 'completed') {
          this.isPlaying = true;
          this.startProgressSaveTimer();
          this.avPlayer.play().then(() => {
            console.info('[Player] AVPlayer resumed after background');
          }).catch((err: Error) => {
            console.error('[Player] AVPlayer resume failed, recreating: ' + err.message);
            this.recreatePlayerForResume();
          });
          hilog.info(0x0001, 'YSC', 'onPageShow: resuming existing player, state=%{public}s', state);
          this.castHelper.ensure(this.getUIContext().getHostContext() as common.UIAbilityContext).then((): void => { this.updateCastMetadata(); });
          return;
        } else if (state === 'stopped') {
          this.loading = true;
          this.playStarted = false;
          this.pendingSeek = this.bgResumeMs;
          this.startProgressSaveTimer();
          this.avPlayer.prepare().then(() => {
            hilog.info(0x0001, 'YSC', 'AVPlayer re-prepared after background');
          }).catch((err: Error) => {
            hilog.error(0x0001, 'YSC', 'AVPlayer re-prepare failed, recreating: %{public}s', err.message);
            this.recreatePlayerForResume();
          });
          this.castHelper.ensure(this.getUIContext().getHostContext() as common.UIAbilityContext).then((): void => { this.updateCastMetadata(); });
          return;
        }
      }
      this.recreatePlayerForResume();
    }
  }

  private recreatePlayerForResume(): void {
    this.pendingSeek = this.bgResumeMs;
    this.loading = true;
    this.isPlaying = false;
    this.playStarted = false;
    this.hasActuallyPlayed = false;
    this.initAVPlayer().then((): void => {
      this.startPlayback();
    });
    hilog.info(0x0001, 'YSC', 'onPageShow: recreating player, seekMs=%{public}d', this.bgResumeMs);
    this.castHelper.ensure(this.getUIContext().getHostContext() as common.UIAbilityContext).then((): void => { this.updateCastMetadata(); });
  }

  async initAVPlayer(): Promise<void> {
    try {
      this.avPlayer = await media.createAVPlayer();
      this.setupAVPlayerEvents();
      console.info('[Player] AVPlayer created');
    } catch (e) {
      console.error('[Player] createAVPlayer failed');
    }
  }

  private async updateCastMetadata(): Promise<void> {
    const pic: string = this.vodInfo ? this.vodInfo.pic : '';
    const title: string = this.name.length > 0 ? this.name : (this.vodInfo ? this.vodInfo.name : '');
    await this.castHelper.updateMetadata(title, pic, this.epName, this.playUrl);
  }

  releaseAVPlayer(): void {
    if (this.avPlayer) {
      try { this.avPlayer.release(); } catch (_e) {}
      this.avPlayer = null;
    }
  }

  /** 起播逻辑：seek/倍�?play，带 guard 防止 stateChange �?prepare.then 重复触发 */
  /**
   * 画面缩放策略：跟随缩放模式落地到 AVPlayer.videoScaleType
   * （只能在 prepared/playing/paused/completed 状态下设置）。
   * 默认=SCALED_ASPECT(保持原始比例完整显示，留黑边不拉伸)；
   * 拉伸=FIT(变形填满)；平铺=FIT_CROP(等比裁剪填满)
   */
  applyScaleType(): void {
    const player = this.avPlayer;
    if (!player) return;
    const sm: string = SCALE_MODES[this.scaleModeIndex];
    try {
      if (sm === '拉伸') {
        player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
      } else if (sm === '平铺') {
        player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP;
      } else {
        player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
      }
    } catch (_eScale) {}
  }

  onPrepared(): void {
    const player = this.avPlayer;
    if (!player) return;
    if (this.playStarted) {
      console.info('[Player] onPrepared skipped: already started');
      return;
    }
    const st: string = player.state;
    if (st !== 'prepared' && st !== 'paused' && st !== 'completed') {
      console.info('[Player] onPrepared skipped (not ready): state=' + st);
      return;
    }
    // videoScaleType 跟随缩放模式（只能在 prepared/playing/paused/completed 状态下设置）：
    // 默认=FIT(保持原始比例完整显示，不拉伸不裁剪)；拉伸=STRETCH(变形填满)；平铺=FIT_CROP(等比裁剪填满)
    this.applyScaleType();
    this.playStarted = true;
    if (this.pendingSeek >= 0) {
      player.seek(this.pendingSeek);
      this.pendingSeek = -1;
    }
    // AVPlayer 始终满增益，实际音量由系统媒体音量控�?
    try { player.setVolume(1.0); this.playerVolume = 1.0; } catch (_e) {}
    if (this.playbackSpeed !== 1.0) {
      this.setPlayerSpeed(this.playbackSpeed);
    }
    player.play().then(() => {
      console.info('[Player] AVPlayer playing');
      this.isPlaying = true;
      this.hasActuallyPlayed = true;
      this.playbackStartTime = Date.now();
      this.applySavedResumeIfNeeded();
      this.startProgressSaveTimer();
    }).catch((err: Error) => {
      this.playStarted = false;
      console.error('[Player] AVPlayer play failed');
      this.handlePlaybackError();
    });
  }

    /** 统一�?prepare 入口，带重入保护，避�?onLoad �?stateChange 双重 prepare 导致卡死 */
  tryPrepare(): void {
    const player = this.avPlayer;
    if (!player) return;
    if (this.preparing) {
      console.info('[Player] prepare skipped: already preparing');
      return;
    }
    if (player.state !== 'initialized') {
      console.info('[Player] prepare skipped: state=' + player.state);
      return;
    }
    this.preparing = true;
    player.prepare().then(() => {
      this.preparing = false;
      console.info('[Player] AVPlayer prepared');
      // prepared 状态事件正常会触发 onPrepared 起播�?
      // 部分源不回调 prepared 事件，这里加兜底：稍后若仍未起播则主动尝�?
      setTimeout(() => {
        if (!this.playStarted) {
          this.onPrepared();
        }
      }, 1200);
    }).catch((err: Error) => {
      this.preparing = false;
      console.error('[Player] AVPlayer prepare failed: ' + err.message);
      this.handlePlaybackError();
    });
  }

  setupAVPlayerEvents(): void {
    if (!this.avPlayer) return;
    const player = this.avPlayer;

    player.on('stateChange', (state: string, reason: media.StateChangeReason) => {
      console.info('[Player] AVPlayer state: ' + state);
      switch (state) {
        case 'initialized':
          // 设置音频渲染信息，确�?AVPlayer.setVolume 的软件增益在平板/HarmonyOS 6 上能作用�?AudioRenderer
          try {
            player.audioRendererInfo = { usage: audio.StreamUsage.STREAM_USAGE_MOVIE, rendererFlags: 0 };
          } catch (_eAri) {}
          // Wait for surfaceId to be available before preparing
          if (this.surfaceId.length === 0) {
            console.info('[Player] surfaceId not ready, waiting...');
            let surfaceWait: number = 0;
            const surfaceTimer = setInterval(() => {
              surfaceWait += 100;
              if (this.surfaceId.length > 0) {
                clearInterval(surfaceTimer);
                console.info('[Player] surfaceId now available: ' + this.surfaceId);
                this.tryPrepare();
              } else if (surfaceWait >= 3000) {
                clearInterval(surfaceTimer);
                console.error('[Player] surfaceId timeout, preparing without surface');
                this.tryPrepare();
              }
            }, 100);
          } else {
            player.surfaceId = this.surfaceId;
            this.tryPrepare();
          }
          break;
        case 'prepared':
          this.onPrepared();
          break;
        case 'playing':
          this.isPlaying = true;
          this.hasActuallyPlayed = true;
          this.loading = false;
          this.clearLoadingWatchdog();
          this.castHelper.setPlaying(true);
          // 起播后若控制栏正显示，启动自动隐藏计时（修复首次进入不自动隐藏）
          if (this.showControls) {
            this.startHideTimer();
          }
          break;
        case 'paused':
          this.isPlaying = false;
          this.castHelper.setPlaying(false);
          break;
        case 'completed':
          if (this.hasActuallyPlayed && this.duration > 5000) {
            this.markCurrentWatched();
            if (this.duration > 0) { this.updateCurrentEpProgress(this.duration, this.duration); }
            this.saveHistory(0, this.duration);
            this.nextEpisode();
          } else if (this.hasActuallyPlayed) {
            console.info('[Player] completed with short duration, stopping');
            this.isPlaying = false;
          } else {
            this.handlePlaybackError();
          }
          break;
        case 'error':
          if (this.hasActuallyPlayed) {
            console.info('[Player] ignore state=error, already playing');
            break;
          }
          this.handlePlaybackError();
          break;
        default:
          break;
      }
    });

    player.on('error', (err: Error) => {
      const msg: string = err.message || '';
      console.error('[Player] AVPlayer error: ' + msg + ' hasActuallyPlayed=' + this.hasActuallyPlayed);
      // 非致命错误（如在 initialized 状态调�?setVideoScale/getCurrentTime 之类的时序�?API�?
      // AVPlayer 会照样抛 error 事件，这类错误不应该触发重试循环�?
      const nonFatal: boolean = msg.indexOf('Operate Not Permit') >= 0
        || msg.indexOf('unsupport video scale operation') >= 0
        || msg.indexOf('current state is not') >= 0;
      if (nonFatal) { return; }
      if (!this.hasActuallyPlayed) {
        this.handlePlaybackError(msg);
      }
    });

    player.on('timeUpdate', (time: number) => {
      if (!this.isSeeking) {
        this.currentTime = time;
        this.sliderValue = time;
      }
    });

    player.on('durationUpdate', (duration: number) => {
      this.duration = duration;
    });

    player.on('videoSizeChange', (width: number, height: number) => {
      this.videoWidth = width;
      this.videoHeight = height;
      this.applyVideoOrientation();
      // 真实分辨率到手后补落一次缩放策略：部分机型 prepared 阶段设的 videoScaleType
      // 会被解码器初始化重置，全屏时表现为画面被拉伸变形
      this.applyScaleType();
    });

    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
      if (this.hasError) { this.loading = false; return; }
      if (infoType === media.BufferingInfoType.BUFFERING_START) {
        this.loading = true;
      } else if (infoType === media.BufferingInfoType.BUFFERING_END) {
        this.loading = false;
      }
    });
    // 音量设置回调
    try {
      player.on('volumeChange', (_vol: number) => {
        this.volumeSetInFlight = false;
      });
    } catch (_eOn) {}
  }

  setPlayerSpeed(speed: number): void {
    if (!this.avPlayer) return;
    let ps: media.PlaybackSpeed = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    if (speed === 0.5) ps = media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
    else if (speed === 0.75) ps = media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    else if (speed === 1.0) ps = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    else if (speed === 1.25) ps = media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    else if (speed === 1.5) ps = media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
    else if (speed === 1.75) ps = media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    else if (speed === 2.0) ps = media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
    else if (speed === 3.0) ps = media.PlaybackSpeed.SPEED_FORWARD_3_00_X;
    this.avPlayer.setSpeed(ps);
  }

  private autoSwitchSource(reason: string): boolean {
    const info = this.vodInfo;
    if (!info || info.seriesFlags.length <= 1) return false;
    this.autoSwitchTriedFlags.add(this.flag);
    hilog.info(0x0001, 'YSC', 'autoSwitchSource: reason=%{public}s triedCount=%{public}d totalFlags=%{public}d', reason, this.autoSwitchTriedFlags.size, info.seriesFlags.length);
    for (let i = 0; i < info.seriesFlags.length; i++) {
      const nextFlag = info.seriesFlags[i];
      if (this.autoSwitchTriedFlags.has(nextFlag.name)) continue;
      const series = info.seriesMap.get(nextFlag.name);
      if (!series || this.epIndex >= series.length) continue;
      this.currentFlagIndex = i;
      this.flag = nextFlag.name;
      this.epName = series[this.epIndex].name;
      this.epUrl = series[this.epIndex].url;
      this.hasError = false;
      this.errorRetryCount = 0;
      this.hasActuallyPlayed = false;
      this.isRetrying = false;
      this.clearLoadingWatchdog();
      try { if (this.avPlayer) { this.avPlayer.stop(); } } catch (_e) {}
      try { if (this.avPlayer) { this.avPlayer.reset(); } } catch (_e) {}
      try {
        promptAction.showToast({ message: reason + '，正在尝试线路：' + nextFlag.name, duration: 3000 });
      } catch (_e) {}
      this.loadPlayUrl();
      return true;
    }
    return false;
  }

  private startLoadingWatchdog(): void {
    this.clearLoadingWatchdog();
    this.loadingWatchdogId = setTimeout((): void => {
      this.loadingWatchdogId = -1;
      if (!this.hasActuallyPlayed && !this.hasError && !this.isRetrying) {
        if (this.autoSwitchSource('当前线路加载超时')) {
          return;
        }
        this.loading = false;
        this.hasError = true;
        this.isRetrying = false;
        this.errorRetryCount = 0;
        this.errorMsg = '视频资源加载超时，已尝试所有线路';
        this.playStarted = false;
        this.preparing = false;
        try { if (this.avPlayer) { this.avPlayer.stop(); } } catch (_e) {}
        try { if (this.avPlayer) { this.avPlayer.reset(); } } catch (_e) {}
      }
    }, 15000);
  }

  private clearLoadingWatchdog(): void {
    if (this.loadingWatchdogId !== -1) {
      clearTimeout(this.loadingWatchdogId);
      this.loadingWatchdogId = -1;
    }
  }

  async loadPlayUrl() {
    this.loading = true;
    this.hasError = false;
    this.errorRetryCount = 0;
    this.hasActuallyPlayed = false;
    this.startLoadingWatchdog();
    try {
      const playInfo = await SourceViewModel.getPlayContentWithPrefetch(this.sourceKey, this.flag, this.epUrl);
      if (playInfo && playInfo.url.length > 0) {
        this.playUrl = playInfo.url;
        this.playHeaders = playInfo.header;
      } else {
        this.playUrl = this.epUrl;
        this.playHeaders = new Map();
      }
      this.updateCastMetadata();
      // 网盘播放前：探测 flag/url，未配置 Cookie 时提示去登录
      const panHit: PanHit | null = detectPan(this.flag, this.playUrl);
      if (panHit) {
        try {
          const cred: PanCredential = await PanConfig.get(panHit.kind);
          const hasCred: boolean = PanConfig.isConfigured(cred);
          const credentialSource: PanCredentialSource = await PanConfig.getCredentialSource(panHit.kind);
          if (!hasCred && credentialSource === 'app') {
            this.loading = false;
            const kindLabel: string = panHit.label;
            const kindKey: PanKind = panHit.kind;
            promptAction.showDialog({
              title: '需要登录网盘',
              message: '当前资源来自' + kindLabel + '，尚未登录该网盘，请先在【设置 > 网盘配置】完成登录。',
              buttons: [
                { text: '取消', color: '#8E8E93' },
                { text: '去登录', color: '#FFFFFF' }
              ]
            }).then((r): void => {
              if (r.index === 1) {
                router.pushUrl({ url: 'tvbox/pages/PanLoginPage', params: { kind: kindKey } });
              }
            }).catch((): void => {});
            return;
          }
        } catch (_pce) {}
      }

      // 网盘直链拦截：识�?ali:// quark:// uc:// 115:// baidu:// 等，换成短时直链
      if (PanResolver.isPanUrl(this.playUrl)) {
        try {
          const panRes = await PanResolver.resolve(this.playUrl);
          if (panRes.items.length > 0) {
            this.playUrl = panRes.items[0].url;
            const merged: Map<string, string> = new Map();
            this.playHeaders.forEach((v: string, k: string) => merged.set(k, v));
            panRes.items[0].headers.forEach((v: string, k: string) => merged.set(k, v));
            this.playHeaders = merged;
            hilog.info(0x0001, 'YSC', 'PanResolver ok, url=%{public}s headers=%{public}d', this.playUrl, this.playHeaders.size);
          } else {
            this.hasError = true;
            this.errorMsg = panRes.error;
            this.loading = false;
            return;
          }
        } catch (pe) {
          this.hasError = true;
          this.errorMsg = '网盘解析失败：' + formatError(pe);
          this.loading = false;
          return;
        }
      }
      if (!this.avPlayer) {
        let waitCount: number = 0;
        while (!this.avPlayer && waitCount < 60) {
          await new Promise<void>((resolve: () => void): void => { setTimeout((): void => { resolve(); }, 50); });
          waitCount++;
        }
      }
      this.startPlayback();
    } catch (e) {
      this.hasError = true;
      this.errorMsg = formatError(e);
      this.loading = false;
    }
    // Don't clear loading here - it will be cleared when playback actually starts (playing state)
  }

  async checkResume() {
    const record: HistoryRecord | null = await HistoryRepository.get(this.vodId, this.sourceKey);
    if (record) {
      this.loadWatchedEps(record.watchedEps ?? '');
      this.loadEpProgress(record.epProgress ?? '');
      if (record.position > 10000 && record.epIndex === this.epIndex) {
        this.savedResumeMs = record.position;
        this.savedResumeEpIndex = record.epIndex;
      }
    }
  }

  private loadWatchedEps(raw: string): void {
    const set: Set<string> = new Set<string>();
    if (raw && raw.length > 0) {
      try {
        const arr: Object = JSON.parse(raw) as Object;
        if (Array.isArray(arr)) {
          const list: string[] = arr as string[];
          for (const it of list) { if (typeof it === 'string' && it.length > 0) set.add(it); }
        }
      } catch (_e) {}
    }
    this.watchedEps = set;
  }

  private serializeWatchedEps(): string {
    const arr: string[] = [];
    this.watchedEps.forEach((v: string): void => { arr.push(v); });
    return JSON.stringify(arr);
  }

  private watchedKey(flag: string, epIndex: number): string { return flag + '|' + String(epIndex); }

  private loadEpProgress(raw: string): void {
    const map: Map<string, string> = new Map<string, string>();
    if (raw && raw.length > 0) {
      try {
        const obj: Object = JSON.parse(raw) as Object;
        if (obj && typeof obj === 'object') {
          const rec: Record<string, string> = obj as Record<string, string>;
          for (const k of Object.keys(rec)) {
            const v: string = rec[k];
            if (typeof v === 'string' && v.length > 0) map.set(k, v);
          }
        }
      } catch (_e) {}
    }
    this.epProgress = map;
  }

  private serializeEpProgress(): string {
    const obj: Record<string, string> = {};
    this.epProgress.forEach((v: string, k: string): void => { obj[k] = v; });
    return JSON.stringify(obj);
  }

  private updateCurrentEpProgress(position: number, duration: number): void {
    if (!this.flag || this.epIndex < 0) return;
    if (position < 3000 || duration <= 0) return;
    const key: string = this.watchedKey(this.flag, this.epIndex);
    const next: Map<string, string> = new Map<string, string>();
    this.epProgress.forEach((v: string, k: string): void => { next.set(k, v); });
    next.set(key, String(Math.floor(position)) + '|' + String(Math.floor(duration)));
    this.epProgress = next;
  }

  private markCurrentWatched(): void {
    if (!this.flag || this.epIndex < 0) return;
    const key: string = this.watchedKey(this.flag, this.epIndex);
    if (!this.watchedEps.has(key)) {
      const next: Set<string> = new Set<string>();
      this.watchedEps.forEach((v: string): void => { next.add(v); });
      next.add(key);
      this.watchedEps = next;
    }
  }

  private applySavedResumeIfNeeded(): void {
    if (this.restartFromZero) { return; }
    if (this.savedResumeMs > 10000 && this.savedResumeEpIndex === this.epIndex && this.avPlayer) {
      const target: number = this.savedResumeMs;
      try { this.avPlayer.seek(target); } catch (_e) {}
    }
  }

  restartCurrentEpisode(): void {
    this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.closeOtherPopups(''); });
    // 记住原恢复点，允许用户反�?
    if (!this.restartFromZero && this.currentTime > 5000) {
      this.savedResumeMs = this.currentTime;
      this.savedResumeEpIndex = this.epIndex;
    }
    this.restartFromZero = true;
    if (this.avPlayer) { try { this.avPlayer.seek(0); } catch (_e) {} }
    this.currentTime = 0;
    this.startRestartRevertTimer();
    this.showControlsAutoHide();
  }

  private startRestartRevertTimer(): void {
    this.clearRestartRevertTimer();
    this.restartRevertTimerId = setTimeout((): void => {
      this.restartRevertTimerId = -1;
      this.restartFromZero = false;
    }, 5000);
  }

  private clearRestartRevertTimer(): void {
    if (this.restartRevertTimerId !== -1) {
      clearTimeout(this.restartRevertTimerId);
      this.restartRevertTimerId = -1;
    }
  }

  resumeSavedPosition(): void {
    this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.closeOtherPopups(''); });
    this.clearRestartRevertTimer();
    if (this.savedResumeMs > 0 && this.avPlayer) {
      const target: number = this.savedResumeMs;
      try { this.avPlayer.seek(target); } catch (_e) {}
      this.currentTime = target;
    }
    this.restartFromZero = false;
    this.showControlsAutoHide();
  }

  resumeFromPosition() {
    if (this.avPlayer && this.savedResumeMs > 0) { this.avPlayer.seek(this.savedResumeMs); }
    this.showResumeDialog = false;
  }

  dismissResume() {
    this.showResumeDialog = false;
  }

  async loadDetail() {
    try {
      const info = await SourceViewModel.getDetailContent(this.sourceKey, [this.vodId]);
      if (info) {
        this.vodInfo = info;
        this.updateCastMetadata();
        for (let i = 0; i < info.seriesFlags.length; i++) {
          if (info.seriesFlags[i].name === this.flag) {
            this.currentFlagIndex = i;
            break;
          }
        }
      }
    } catch (_e) {
    }
  }

  async saveHistory(position: number = 0, duration: number = 0) {
    if (this.vodId.length === 0 || this.sourceKey.length === 0) return;
    await HistoryRepository.save({
      vodId: this.vodId,
      sourceKey: this.sourceKey,
      name: this.name,
      pic: this.vodInfo ? this.vodInfo.pic : '',
      epName: this.epName,
      epIndex: this.epIndex,
      flag: this.flag,
      updateTime: Date.now(),
      duration: duration,
      position: position,
      watchedEps: this.serializeWatchedEps(),
      epProgress: this.serializeEpProgress()
    });
  }

  private startProgressSaveTimer(): void {
    if (this.progressSaveTimerId !== -1) return;
    this.progressSaveTimerId = setInterval((): void => {
      if (this.avPlayer && this.hasActuallyPlayed && this.currentTime > 3000) {
        this.updateCurrentEpProgress(this.currentTime, this.duration);
        this.saveHistory(this.currentTime, this.duration);
      }
    }, 5000);
  }

  private stopProgressSaveTimer(): void {
    if (this.progressSaveTimerId !== -1) {
      clearInterval(this.progressSaveTimerId);
      this.progressSaveTimerId = -1;
    }
  }

  getCurrentSeries(): VodSeries[] {
    const info = this.vodInfo;
    if (!info || info.seriesFlags.length === 0) return [];
    const flag = info.seriesFlags[this.currentFlagIndex];
    if (!flag) return [];
    return info.seriesMap.get(flag.name) || [];
  }

  playEpisode(index: number) {
    const series = this.getCurrentSeries();
    if (index < 0 || index >= series.length) return;
    this.autoSwitchTriedFlags = new Set<string>();
    if (this.hasActuallyPlayed && this.currentTime > 30000) { this.markCurrentWatched(); }
    if (this.hasActuallyPlayed) { this.updateCurrentEpProgress(this.currentTime, this.duration); }
    // 切换到新集：清掉旧集的记忆恢复点
    this.savedResumeMs = 0;
    this.savedResumeEpIndex = -1;
    this.restartFromZero = false;
    this.currentTime = 0;
    this.epIndex = index;
    this.epName = series[index].name;
    this.epUrl = series[index].url;
    this.loadPlayUrl();
    this.showEpisodes = false;
  }

  private closeEpisodesPanel(): void {
    // 一次只能打开一个弹框：关闭所有悬浮弹框（
    this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
      this.closeOtherPopups('');
    });
  }

  prevEpisode() {
    this.closeEpisodesPanel();
    if (this.epIndex > 0) this.playEpisode(this.epIndex - 1);
    this.showControlsAutoHide();
  }

  nextEpisode() {
    this.closeEpisodesPanel();
    const series = this.getCurrentSeries();
    if (this.epIndex < series.length - 1) this.playEpisode(this.epIndex + 1);
    this.showControlsAutoHide();
  }

  onFlagClick(index: number) {
    this.currentFlagIndex = index;
    const info = this.vodInfo;
    if (info) {
      const flag = info.seriesFlags[index];
      if (flag) {
        this.flag = flag.name;
        this.playEpisode(0);
      }
    }
  }

  togglePlay() {
    this.closeEpisodesPanel();
    if (this.isPlaying) {
      if (this.avPlayer) { this.avPlayer.pause(); }
      this.isPlaying = false;
      this.castHelper.setPlaying(false);
    } else {
      // 清除缓存放掉过播放器时 state 已回到 idle，需要重新 prepare 而不是直接 play
      const st: string = this.avPlayer ? this.avPlayer.state : 'idle';
      if (st === 'idle' || st === 'initialized') {
        this.needReprepare = false;
        this.startPlayback();
      } else if (this.avPlayer) {
        this.avPlayer.play();
      }
      this.isPlaying = true;
      this.castHelper.setPlaying(true);
    }
    this.showControlsAutoHide();
  }

  /**
   * 清除缓存前释放 AVPlayer 缓冲分片：TV/网络流缓存被媒体服务持有，不释放 unlink 必失败
   */
  private onCachePrepare(): void {
    const player = this.avPlayer;
    if (!player) {
      return;
    }
    try {
      player.pause();
    } catch (_e) {
    }
    try {
      player.reset().then(() => {
        this.isPlaying = false;
        this.playStarted = false;
        this.hasActuallyPlayed = false;
        this.needReprepare = true;
      }).catch(() => {
      });
    } catch (_e) {
    }
  }

  toggleSpeedMenu() {
    this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
      const willOpen = !this.showSpeedMenu;
      this.closeOtherPopups('speed');
      this.showSpeedMenu = willOpen;
    });
    this.showControlsAutoHide();
  }

  onSpeedSelect(speed: number) {
    this.playbackSpeed = speed;
    this.setPlayerSpeed(speed);
    this.showSpeedMenu = false;
    this.showControlsAutoHide();
  }

  onScaleModeClick() {
    this.closeEpisodesPanel();
    this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.showSpeedMenu = false; });
    this.scaleModeIndex = (this.scaleModeIndex + 1) % SCALE_MODES.length;
    // 播放中切换缩放模式时同步 videoScaleType，使拉伸/平铺/默认立即生效
    const player = this.avPlayer;
    if (player) {
      this.applyScaleType();
    }
    this.showControlsAutoHide();
  }

  // 一次只能打开一个弹框：关闭所有悬浮弹框（
  closeOtherPopups(keep: string = ''): boolean {
    let closedAny = false;
    if (keep !== 'episodes' && this.showEpisodes) { this.showEpisodes = false; closedAny = true; }
    if (keep !== 'speed' && this.showSpeedMenu) { this.showSpeedMenu = false; closedAny = true; }
    if (keep !== 'resume' && this.showResumeDialog) { this.showResumeDialog = false; closedAny = true; }
    return closedAny;
  }

  toggleEpisodes() {
    this.getUIContext()?.animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      const willOpen = !this.showEpisodes;
      this.closeOtherPopups('episodes');
      this.showEpisodes = willOpen;
    });
    this.showControlsAutoHide();
  }

  onSliderChange(value: number, mode: SliderChangeMode) {
    if (mode === SliderChangeMode.Begin) {
      this.isSeeking = true;
      // 拖动/点击进度条：关闭所有悬浮弹框（
      this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.closeOtherPopups(''); });
    } else if (mode === SliderChangeMode.Click) {
      // 点击进度条：立即关闭所有悬浮弹�?
      this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.closeOtherPopups(''); });
    } else if (mode === SliderChangeMode.Moving) {
      this.currentTime = value;
    } else if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      if (this.avPlayer) { this.avPlayer.seek(value); }
      this.currentTime = value;
      this.isSeeking = false;
      this.showControlsAutoHide();
    }
  }

  formatTime(ms: number): string {
    if (ms <= 0) return '00:00';
    const totalSec: number = Math.floor(ms / 1000);
    const h: number = Math.floor(totalSec / 3600);
    const m: number = Math.floor((totalSec % 3600) / 60);
    const s: number = totalSec % 60;
    const mStr: string = m < 10 ? '0' + m.toString() : m.toString();
    const sStr: string = s < 10 ? '0' + s.toString() : s.toString();
    if (h > 0) {
      const hStr: string = h < 10 ? '0' + h.toString() : h.toString();
      return hStr + ':' + mStr + ':' + sStr;
    }
    return mStr + ':' + sStr;
  }

  /**
   * 播放控件图标按钮（TV 播放页）：触控热区 52vp，图标本体 26vp，
   * 全部使用 resources/base/media 下自绘 SVG，与手机播放页共用同一套资源。
   */
  @Builder
  ctrlIcon(icon: Resource, onTap: () => void, active: boolean) {
    Row() {
      Image(icon)
        .width(26)
        .height(26)
        .fillColor(active ? Palette.accent() : '#FFFFFF')
        .objectFit(ImageFit.Contain)
        .draggable(false)
    }
    .width(52)
    .height(52)
    .borderRadius(26)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#66000000')
    .border({ width: 1, color: active ? Palette.accent() : '#CCFFFFFF' })
    .margin({ left: 10 })
    .onClick(() => onTap())
  }

  /** 相对当前位置快进/快退（毫秒） */
  private seekBy(deltaMs: number): void {
    if (!this.avPlayer || this.duration <= 0) {
      return;
    }
    let target: number = this.currentTime + deltaMs;
    if (target < 0) { target = 0; }
    if (target > this.duration) { target = this.duration; }
    try {
      this.avPlayer.seek(target);
      this.currentTime = target;
    } catch (_e) {
    }
  }

  getScaleModeText(): string {
    return SCALE_MODES[this.scaleModeIndex];
  }

  /** 缩放模式图标：与本地视频播放栏共用同一套字形（默认/拉伸/平铺） */
  getScaleIcon(): string {
    const mode: string = SCALE_MODES[this.scaleModeIndex];
    if (mode === '拉伸') {
      return PlayIcons.ASPECT_ORIGIN;
    }
    if (mode === '平铺') {
      return PlayIcons.ASPECT_FILL;
    }
    return PlayIcons.ASPECT_FIT;
  }

  // 根据视频真实分辨率、容器尺寸与所选模式，计算视频渲染层的宽高(vp)
  // 平铺：保持比例不变，等比裁剪铺满播放窗口
  private getVideoLayerSize(): SizeResult {
    const cw: number = this.containerW;
    const ch: number = this.containerH;
    if (cw <= 0 || ch <= 0) {
      return { w: '100%', h: '100%' };
    }
    const mode: string = SCALE_MODES[this.scaleModeIndex];
    // 「默认」始终等比完整显示（上下/左右留黑边），不再按横屏或竖屏源偷换成「平铺」裁剪，
    // 否则竖屏短视频、超宽容器会被放大裁掉画面，观感就是「拉伸过头」。
    const effectiveMode: string = mode;
    // 拉伸：填充整个播放区域（可能变形）
    if (effectiveMode === '拉伸') {
      return { w: cw, h: ch };
    }
    // 默认/平铺 均依据视频真实比�?
    if (this.videoWidth <= 0 || this.videoHeight <= 0) {
      return { w: '100%', h: '100%' };
    }
    const ratio: number = this.videoWidth / this.videoHeight;
    const containerRatio: number = cw / ch;
    let w: number;
    let h: number;
    if (effectiveMode === '平铺') {
      // 平铺：保持比例不变，等比裁剪铺满播放窗口
      if (ratio > containerRatio) {
        h = ch;
        w = ch * ratio;
      } else {
        w = cw;
        h = cw / ratio;
      }
    } else {
      // 默认：保持原始宽高比，等比适配并留黑边
      if (ratio > containerRatio) {
        w = cw;
        h = cw / ratio;
      } else {
        h = ch;
        w = ch * ratio;
      }
    }
    return { w: w, h: h };
  }

  getSpeedText(): string {
    return 'x' + this.playbackSpeed.toFixed(1);
  }

  showControlsAutoHide() {
    this.showControls = true;
    this.startHideTimer();
  }

  startHideTimer() {
    if (this.hideTimerId !== -1) {
      clearTimeout(this.hideTimerId);
    }
    this.hideTimerId = setTimeout((): void => {
      // 选集/速率弹框打开时，延后隐藏
      if (this.showEpisodes || this.showSpeedMenu || this.castPickerOpen) {
        this.startHideTimer();
        return;
      }
      this.showControls = false;
      this.showSpeedMenu = false;
      this.hideTimerId = -1;
    }, AUTO_HIDE_MS);
  }

  onPlayerClick() {
    // 双击后 300ms 内忽略单击（双击第二下也会触发 TapGesture count=1）
    if (Date.now() - this.lastDoubleTapTime < 300) {
      return;
    }
    // 滑动手势进行中或刚结束 300ms 内忽略单击（Parallel 模式下 TapGesture 在手指抬起时仍会触发）
    if (this.panAxis !== '' || Date.now() - this.lastPanEndTime < 300) {
      return;
    }
    if (this.pendingClickTimerId !== -1) {
      clearTimeout(this.pendingClickTimerId);
    }
    this.pendingClickTimerId = setTimeout((): void => {
      this.pendingClickTimerId = -1;
      this.handleSingleTap();
    }, 250);
  }

  private handleSingleTap(): void {
    if (this.showEpisodes || this.showSpeedMenu) {
      this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
        this.showEpisodes = false;
        this.showSpeedMenu = false;
      });
      this.showControlsAutoHide();
      return;
    }
    if (this.showControls) {
      this.showControls = false;
      if (this.hideTimerId !== -1) {
        clearTimeout(this.hideTimerId);
        this.hideTimerId = -1;
      }
    } else {
      this.showControlsAutoHide();
      this.updateSysTime();
    }
  }

  // 双击：播�?暂停
  private onPlayerDoubleClick(): void {
    if (this.pendingClickTimerId !== -1) {
      clearTimeout(this.pendingClickTimerId);
      this.pendingClickTimerId = -1;
    }
    this.lastDoubleTapTime = Date.now();
    this.togglePlayPause();
    this.showGestureFeedback('', this.isPlaying ? '播放' : '暂停');
  }

  // 长按临时 2 倍速，松开恢复
  private onLongPressStart(): void {
    if (!this.avPlayer) return;
    if (this.avPlayer.state !== 'playing') return;
    this.longPressActive = true;
    this.speedBeforeLongPress = this.playbackSpeed;
    this.setPlayerSpeed(2.0);
    this.showGestureFeedback('', '2.0X 倍速');
  }

  private onLongPressEnd(): void {
    if (!this.longPressActive) return;
    this.longPressActive = false;
    this.setPlayerSpeed(this.speedBeforeLongPress);
    this.showGestureFeedback('', 'x' + this.speedBeforeLongPress.toFixed(1));
  }

  private togglePlayPause(): void {
    if (!this.avPlayer) return;
    const state: string = this.avPlayer.state;
    if (state === 'playing') {
      this.avPlayer.pause();
      this.isPlaying = false;
      this.castHelper.setPlaying(false);
    } else if (state === 'paused' || state === 'prepared' || state === 'completed') {
      this.avPlayer.play();
      this.isPlaying = true;
      this.castHelper.setPlaying(true);
    }
  }

  // 手势开始：记录起点在左半屏(亮度)还是右半�?音量)；同时关闭悬浮弹�?
  private onVerticalPanStart(fingerX: number, fingerY: number): void {
    if (this.panAxis !== '') return;
    // 规避系统手势区域：顶部下拉状态栏、底部上滑返回桌�?
    if (fingerY >= 0) {
      const topBound: number = Math.max(this.topSafe, 48);
      const bottomBound: number = this.containerH > 0 ? this.containerH - Math.max(this.bottomSafe, 48) : 99999;
      if (fingerY < topBound || fingerY > bottomBound) { return; }
    }
    this.panAxis = 'v';
    if (this.pendingClickTimerId !== -1) { clearTimeout(this.pendingClickTimerId); this.pendingClickTimerId = -1; }
    // 手势开始：关闭所有悬浮弹框（一次只能开一个弹框）
    this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.closeOtherPopups(''); });
    this.gestureIsLeft = this.containerW > 0 ? (fingerX < this.containerW / 2) : true;
    this.gestureStartBrightness = this.screenBrightness;
    this.gestureStartVolume = this.sysVolume;
  }

  // 手势更新：dy 向上为负，向上滑增大
  private onVerticalPanUpdate(dy: number): void {
    if (this.panAxis !== 'v') return;
    const range: number = this.containerH > 0 ? this.containerH : 720;
    const delta: number = -dy / range; // 向上为正
    if (this.gestureIsLeft) {
      let b: number = this.gestureStartBrightness + delta;
      b = b < 0 ? 0 : (b > 1 ? 1 : b);
      this.screenBrightness = b;
      this.applyBrightness(b);
      this.showGestureFeedback('', '亮度 ' + Math.round(b * 100) + '%');
    } else {
      // 系统音量调节：手势映射到系统媒体音量等级
      const deltaSteps: number = Math.round(delta * this.sysMaxVolume);
      let lvl: number = this.gestureStartVolume + deltaSteps;
      lvl = lvl < 0 ? 0 : (lvl > this.sysMaxVolume ? this.sysMaxVolume : lvl);
      this.setSystemVolume(lvl);
      const pct: number = this.sysMaxVolume > 0 ? Math.round(lvl / this.sysMaxVolume * 100) : 0;
      this.showGestureFeedback('', '音量 ' + pct + '%');
    }
  }

  // 水平滑动快进/快退：位移比例映射；同时关闭悬浮弹框
  private onHorizPanStart(): void {
    if (this.panAxis !== '') return;
    this.panAxis = 'h';
    if (this.pendingClickTimerId !== -1) { clearTimeout(this.pendingClickTimerId); this.pendingClickTimerId = -1; }
    // 手势开始：关闭所有悬浮弹框（一次只能开一个弹框）
    this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.closeOtherPopups(''); });
    this.horizSeeking = true;
    this.gestureStartSeekTime = this.currentTime;
    this.gestureSeekTarget = this.currentTime;
    if (this.gestureHudTimer !== -1) {
      clearTimeout(this.gestureHudTimer);
      this.gestureHudTimer = -1;
    }
  }

  private onHorizPanUpdate(dx: number): void {
    if (this.panAxis !== 'h') return;
    if (this.duration <= 0) return;
    const range: number = this.containerW > 0 ? this.containerW : 1280;
    // 整屏宽度映射整个视频时长，无单次快进/快退上限
    const deltaMs: number = (dx / range) * this.duration;
    let target: number = this.gestureStartSeekTime + deltaMs;
    if (target < 0) target = 0;
    if (target > this.duration) target = this.duration;
    this.gestureSeekTarget = target;
    const diffSec: number = Math.round((target - this.gestureStartSeekTime) / 1000);
    const sign: string = diffSec >= 0 ? '+' : '-';
    const icon: string = diffSec >= 0 ? '⏩' : '⏪';
    this.showGestureHud = true;
    this.gestureHudIcon = icon;
    this.gestureHudText = this.formatTime(target) + ' / ' + this.formatTime(this.duration) + '  (' + sign + Math.abs(diffSec) + 's)';
    this.sliderValue = target;
  }

  private onHorizPanEnd(): void {
    const wasH: boolean = this.panAxis === 'h';
    this.panAxis = '';
    this.lastPanEndTime = Date.now();
    if (!this.horizSeeking) return;
    if (!wasH) return;
    this.horizSeeking = false;
    if (this.avPlayer && this.duration > 0) {
      this.avPlayer.seek(this.gestureSeekTarget);
      this.currentTime = this.gestureSeekTarget;
    }
    this.showGestureFeedback('', this.formatTime(this.gestureSeekTarget));
  }

  private applyBrightness(b: number): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(ctx).then((win: window.Window): void => {
        win.setWindowBrightness(b).catch((e: Object): void => {});
      }).catch((e: Object): void => {});
    } catch (e) {
    }
  }

  private showGestureFeedback(icon: string, text: string): void {
    this.gestureHudIcon = icon;
    this.gestureHudText = text;
    this.showGestureHud = true;
    if (this.gestureHudTimer !== -1) {
      clearTimeout(this.gestureHudTimer);
    }
    this.gestureHudTimer = setTimeout((): void => {
      this.showGestureHud = false;
      this.gestureHudTimer = -1;
    }, 600);
  }


  private async restoreAutoRotation(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
    } catch (_e) {}
  }

  goBack() {
    if (this.onBackPress()) { return; }
    this.saveHistory();
    router.back();
  }

  // 返回键：优先收起选集/倍�?续播弹框，否则退出页�?
  onBackPress(): boolean {
    if (this.showEpisodes || this.showSpeedMenu || this.showResumeDialog) {
      this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
        this.showEpisodes = false;
        this.showSpeedMenu = false;
        this.showResumeDialog = false;
      });
      this.showControlsAutoHide();
      return true;
    }
    return false;
  }

  /** Start playback with AVPlayer */
  async startPlayback(): Promise<void> {
    if (this.playUrl.length === 0 || !this.avPlayer) return;
    console.info('[Player] startPlayback: ' + this.playUrl + ' headers: ' + this.playHeaders.size);

    this.hasActuallyPlayed = false;
    this.playStarted = false;
    this.loading = true;

    try {
      const player = this.avPlayer;

      // Reset to idle if not already
      if (player.state !== 'idle') {
        await player.reset();
      }

      // 视频缩放设为 FIT(拉伸铺满 surface，不保持比例)，只能在 prepared/playing/paused/completed 状态下设置
      // 网盘播放前：探测 flag/url，未配置 Cookie 时提示去登录
      // 绝大多数源的 ts 分片无需鉴权 header，直连可让引擎自带下载器正常拉流�?
      const lowerUrl: string = this.playUrl.toLowerCase();
      const isHls: boolean = lowerUrl.includes('.m3u8') || lowerUrl.includes('m3u8');
      if (this.playHeaders.size > 0 && !isHls) {
        // �?HLS（直链视频）：可能有防盗链，保留自定�?header
        const headerRecord: Record<string, string> = {};
        this.playHeaders.forEach((v: string, k: string) => {
          headerRecord[k] = v;
          console.info('[Player] header: ' + k + '=' + v);
        });
        const mediaSource: media.MediaSource = media.createMediaSourceWithUrl(this.playUrl, headerRecord);
        await player.setMediaSource(mediaSource);
      } else if (isHls && this.playHeaders.size > 0) {
        console.info('[Player] HLS source, using direct url (bypass MediaSource header bug)');
        player.url = this.playUrl;
      } else {
        player.url = this.playUrl;
      }
      // 记录一份 TV 播放缓存（filesDir/tv_cache/play），由「清除缓存」统一统计与回收
      try {
        const hdr: Record<string, string> = {};
        this.playHeaders.forEach((v: string, k: string) => {
          hdr[k] = v;
        });
        TvCacheStore.recordPlayback(this.epUrl.length > 0 ? this.epUrl : this.playUrl,
          this.playUrl, `${this.name} ${this.epName}`.trim(), hdr);
      } catch (_e) {
      }
    } catch (e) {
      console.error('[Player] startPlayback failed: ' + (e as Error).message);
      try {
      // Fallback: try direct URL
        if (this.avPlayer && this.avPlayer.state !== 'idle') {
          await this.avPlayer.reset();
        }
        if (this.avPlayer) {
          this.avPlayer.url = this.playUrl;
        }
      } catch (e2) {
        console.error('[Player] fallback also failed: ' + (e2 as Error).message);
        this.loading = false;
        this.hasError = true;
        this.errorMsg = '加载视频失败';
      }
    }
  }

  handlePlaybackError(errMsg?: string): void {
    const nowTs: number = Date.now();
    if (this.hasError) { this.loading = false; return; }
    if (this.isRetrying) { return; }
    if (nowTs - this.lastRetryAt < 800) { return; }
    const emStr: string = errMsg ? errMsg : '';
    const terminal: boolean = emStr.indexOf('unsupport video decoder') >= 0
      || emStr.indexOf('DEM_FMT_ERR') >= 0
      || emStr.indexOf('Unsupported Format') >= 0
      || emStr.indexOf('demuxer or parser failed') >= 0;
    if (terminal) {
      console.error('[Player] terminal error, no retry: ' + emStr);
      this.hasError = true;
      this.errorMsg = '该格式不支持（请切换线路或清晰度）';
      this.errorRetryCount = 0;
      this.isRetrying = false;
      return;
    }
    this.errorRetryCount++;
    this.lastRetryAt = nowTs;
    if (this.errorRetryCount <= this.maxRetryCount) {
      console.info('[Player] Playback error, retry ' + this.errorRetryCount + '/' + this.maxRetryCount);
      this.isRetrying = true;
      this.hasActuallyPlayed = false;
      if (this.avPlayer) { try { this.avPlayer.stop(); } catch(_e) {} }
      setTimeout(() => {
        if (this.avPlayer) {
          this.avPlayer.reset().then(() => { this.isRetrying = false; this.startPlayback(); }).catch(() => { this.isRetrying = false; this.startPlayback(); });
        } else {
          this.isRetrying = false;
        }
      }, 800);
    } else {
      if (this.autoSwitchSource('当前线路播放失败')) {
        return;
      }
      this.hasError = true;
      this.errorMsg = '播放失败，已重试' + this.maxRetryCount + '次';
      this.errorRetryCount = 0;
      this.isRetrying = false;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Stack({ alignContent: Alignment.Center }) {
        if (this.playUrl.length > 0) {
          XComponent({
            id: 'player_surface',
            type: XComponentType.SURFACE,
            controller: this.xComponentController
          })
            .onLoad(() => {
              try {
                this.surfaceId = this.xComponentController.getXComponentSurfaceId();
                console.info('[Player] XComponent surfaceId: ' + this.surfaceId);
                if (this.avPlayer && this.surfaceId.length > 0) {
                  const state: string = this.avPlayer.state;
                  // prepare 统一交给 stateChange �?initialized 分支处理，避免双�?prepare 卡死�?
                  // onLoad 仅负责补�?surfaceId，并在已就绪状�?返回页面恢复)时续播�?
                  if (state === 'initialized') {
                    this.avPlayer.surfaceId = this.surfaceId;
                    this.tryPrepare();
                  } else if (state === 'prepared' || state === 'playing' || state === 'paused' || state === 'completed') {
                    this.avPlayer.surfaceId = this.surfaceId;
                    this.avPlayer.play().then(() => {
                      console.info('[Player] AVPlayer play from onLoad, state was: ' + state);
                    }).catch((err: Error) => {
                      console.error('[Player] AVPlayer play failed from onLoad');
                    });
                  }
                }
              } catch (e) {
                console.error('[Player] getXComponentSurfaceId failed');
              }
            })
            .width(this.getVideoLayerSize().w)
            .height(this.getVideoLayerSize().h)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
      .clip(true)
      .onAreaChange((_o: Area, n: Area): void => {
        this.containerW = n.width as number;
        this.containerH = n.height as number;
      })
      .gesture(
        GestureGroup(GestureMode.Parallel,
          TapGesture({ count: 2 })
            .onAction((_e: GestureEvent): void => { this.onPlayerDoubleClick(); }),
          TapGesture({ count: 1 })
            .onAction((_e: GestureEvent): void => { this.onPlayerClick(); }),
          LongPressGesture({ repeat: false, duration: 400 })
            .onAction((_e: GestureEvent): void => { this.onLongPressStart(); })
            .onActionEnd((_e: GestureEvent): void => { this.onLongPressEnd(); })
            .onActionCancel((): void => { this.onLongPressEnd(); }),
          PanGesture({ direction: PanDirection.Vertical, distance: 8 })
            .onActionStart((e: GestureEvent): void => { this.onVerticalPanStart(e.fingerList[0]?.localX ?? 0, e.fingerList[0]?.localY ?? -1); })
            .onActionUpdate((e: GestureEvent): void => { this.onVerticalPanUpdate(e.offsetY); })
            .onActionEnd((_e: GestureEvent): void => { if (this.panAxis === 'v') { this.panAxis = ''; this.lastPanEndTime = Date.now(); } })
            .onActionCancel((): void => { if (this.panAxis === 'v') { this.panAxis = ''; this.lastPanEndTime = Date.now(); } }),
          PanGesture({ direction: PanDirection.Horizontal, distance: 12 })
            .onActionStart((_e: GestureEvent): void => { this.onHorizPanStart(); })
            .onActionUpdate((e: GestureEvent): void => { this.onHorizPanUpdate(e.offsetX); })
            .onActionEnd((_e: GestureEvent): void => { this.onHorizPanEnd(); })
            .onActionCancel((): void => { this.onHorizPanEnd(); })
        )
      )



      if (this.loading && !this.hasError) {
        LoadingProgress()
          .width(50)
          .height(50)
          .color('#FFFFFF')
      }

      // 手势反馈 HUD（亮�?音量/播放暂停�?
      if (this.showGestureHud) {
        Column() {
          Text(this.gestureHudText)
            .fontSize(16)
            .fontColor('#FFFFFF')
        }
        .padding({ left: 22, right: 22, top: 12, bottom: 12 })
        .backgroundColor('#B3000000')
        .borderRadius(12)
      }

      if (this.hasError) {
        Column() {
          Text('播放失败')
            .fontSize(16)
            .fontColor('#FF4444')
          Text(this.errorMsg)
            .fontSize(12)
            .fontColor('#BBFFFFFF')
            .margin({ top: 8 })
          Text('重试')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor(Palette.accent())
            .borderRadius(8)
            .padding({ left: 20, right: 20, top: 8, bottom: 8 })
            .margin({ top: 16 })
            .onClick(() => this.loadPlayUrl())
        }
      }

      Column() {
          // 顶部栏
          Row() {
            Row() {
              SymbolGlyph($r('sys.symbol.chevron_left'))
                .fontSize(24)
                .fontColor(['#FFFFFF'])
                .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            }
            .width(40)
            .height(40)
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .onClick(() => this.goBack())

            Column() {
              Text(this.name)
                .fontSize(16)
                .fontColor('#FFFFFF')
                .fontWeight(FontWeight.Medium)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Row() {
                Text(this.epName)
                  .fontSize(13)
                  .fontColor('#BBFFFFFF')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.videoWidth > 0 && this.videoHeight > 0) {
                  Text('[' + this.videoWidth + ' X ' + this.videoHeight + ']')
                    .fontSize(12)
                    .fontColor(Palette.accent())
                    .margin({ left: 8 })
                }
              }
              .margin({ top: 2 })
            }
            .layoutWeight(1)
            .margin({ left: 8 })
            .alignItems(HorizontalAlign.Start)

            Text(this.netSpeed)
              .fontSize(14)
              .fontColor('#BBFFFFFF')
              .margin({ right: 12 })
            // 投屏按钮（AVCastPicker）：系统默认投播图标，支持 DLNA / Cast+
            AVCastPicker({
              normalColor: '#FFFFFF',
              activeColor: Palette.accent(),
              sessionType: 'video',
              onStateChange: (state: AVCastPickerState): void => {
                if (state === AVCastPickerState.STATE_APPEARING) {
                  this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.closeOtherPopups(''); });
                  this.castPickerOpen = true;
                  this.showControls = true;
                  if (this.hideTimerId !== -1) { clearTimeout(this.hideTimerId); this.hideTimerId = -1; }
                } else if (state === AVCastPickerState.STATE_DISAPPEARING) {
                  this.castPickerOpen = false;
                  this.showControlsAutoHide();
                }
              }
            })
              .width(24)
              .height(24)
              .margin({ right: 8 })
              .onTouch((e: TouchEvent): void => { if (e.type === TouchType.Down) { this.showControlsAutoHide(); } })
            Text(this.sysTime)
              .fontSize(14)
              .fontColor('#FFFFFF')
              .margin({ right: 12 })
          }
          .width('100%')
          .height(56 + this.topSafe)
          .padding({ left: 12, right: 16, top: this.topSafe })
          .alignItems(VerticalAlign.Center)
          .linearGradient({
            direction: GradientDirection.Bottom,
            colors: [['#CC000000', 0.0], ['#66000000', 0.55], ['#00000000', 1.0]]
          })

          Blank()

          // 底部控制�?
          Column() {
            // 按钮行：播放键在左，其余控制按钮靠右（与直播UI一致）
            Row() {
              // 主播放键：52vp 圆形图标按钮（播放/暂停合并为一个键）
              Row() {
                Image(PlayIconSet.playPause(this.isPlaying))
                  .width(30)
                  .height(30)
                  .fillColor('#FFFFFF')
                  .objectFit(ImageFit.Contain)
                  .draggable(false)
              }
              .width(56)
              .height(56)
              .borderRadius(28)
              .justifyContent(FlexAlign.Center)
              .backgroundColor('#33FFFFFF')
              .onClick(() => this.togglePlay())

              Blank()

              // 右侧控制按钮组（窄屏横向滚动，保证任何屏宽都不出屏）
              Scroll() {
                Row() {
                  this.ctrlIcon(PlayIconSet.RESTART, (): void => {
                    if (this.restartFromZero) { this.resumeSavedPosition(); } else { this.restartCurrentEpisode(); }
                  }, this.restartFromZero)

                  this.ctrlIcon(PlayIconSet.LIST, (): void => this.toggleEpisodes(), this.showEpisodes)

                  this.ctrlIcon(PlayIconSet.PREV, (): void => this.prevEpisode(), false)

                  this.ctrlIcon(PlayIconSet.NEXT, (): void => this.nextEpisode(), false)

                  this.ctrlIcon(PlayIconSet.REWIND, (): void => this.seekBy(-10000), false)

                  this.ctrlIcon(PlayIconSet.FORWARD, (): void => this.seekBy(10000), false)

                  this.ctrlIcon(PlayIconSet.SPEED, (): void => this.toggleSpeedMenu(), this.showSpeedMenu)

                  // 倍速数值是参数而非控件标签，与图标并排展示
                  Text(this.playbackSpeed.toFixed(2) + 'x')
                    .fontSize(13)
                    .fontColor(this.showSpeedMenu ? Palette.accent() : '#FFFFFF')
                    .margin({ left: 6 })

                  this.ctrlIcon(PlayIconSet.aspect(this.scaleModeIndex), (): void => this.onScaleModeClick(), false)
                }
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .align(Alignment.End)
              .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ bottom: 4 })

            // 杩涘害鏉¤�?
            Row() {
              Text(this.formatTime(this.currentTime))
                .fontSize(13)
                .fontColor('#FFFFFF')
                .width(60)
                .textAlign(TextAlign.End)

              Slider({
                value: this.sliderValue,
                min: 0,
                max: this.duration > 0 ? this.duration : 1,
                step: 1,
                style: SliderStyle.OutSet
              })
                .layoutWeight(1)
                .blockColor('#FFFFFF')
                .trackColor('#55FFFFFF')
                .selectedColor(Palette.accent())
                .onChange((value: number, mode: SliderChangeMode) => this.onSliderChange(value, mode))

              Text(this.formatTime(this.duration))
                .fontSize(13)
                .fontColor('#BBFFFFFF')
                .width(60)
                .textAlign(TextAlign.Start)

            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 4 + this.bottomSafe })
          .linearGradient({
            direction: GradientDirection.Top,
            colors: [['#CC000000', 0.0], ['#66000000', 0.55], ['#00000000', 1.0]]
          })

          // 鍊嶉€熻彍鍗?
          // (鍊嶉€熻彍鍗曞凡绉诲埌鍙充笂鎮诞寮规锛屾涓嶅啀娓叉�?
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .hitTestBehavior(this.showControls ? HitTestMode.Transparent : HitTestMode.None)
        .onTouch((e: TouchEvent): void => { if (e.type === TouchType.Down) { this.showControlsAutoHide(); } })
        .visibility(this.showControls ? Visibility.Visible : Visibility.Hidden)


      // 选集悬浮弹框：从底部控制栏正上方弹出，无遮罩，保留播放器 UI（适配�?浅色�?
      if (this.showEpisodes) {
        Column() {
          Column() {
            if (this.vodInfo && this.vodInfo.seriesFlags.length > 1) {
              Scroll() {
                Row({ space: 6 }) {
                  ForEach(this.vodInfo.seriesFlags, (flag: VodSeriesFlag, index: number) => {
                    Text(flag.name)
                      .fontSize(12)
                      .fontColor(index === this.currentFlagIndex ? Palette.accent() : Palette.textPrimary(this.isDark))
                      .backgroundColor(index === this.currentFlagIndex
                        ? (this.isDark ? '#55FFFFFF' : '#22000000')
                        : (this.isDark ? '#33FFFFFF' : '#11000000'))
                      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                      .borderRadius(12)
                      .onClick(() => this.onFlagClick(index))
                  }, (flag: VodSeriesFlag, index: number): string => flag.name + index)
                }
                .padding({ left: 12, right: 12 })
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .width('100%')
              .height(32)
              .margin({ top: 4, bottom: 6 })
            }

            Text('剧集列表')
              .fontSize(13)
              .fontColor(Palette.textSecondary(this.isDark))
              .fontWeight(FontWeight.Medium)
              .height(28)
              .textAlign(TextAlign.Center)
              .width('100%')

            if (this.getCurrentSeries().length > 0) {
              Scroll() {
                Grid() {
                  ForEach(this.getCurrentSeries(), (series: VodSeries, index: number) => {
                    GridItem() {
                      Text(series.name)
                        .fontSize(12)
                        .fontColor(index === this.epIndex
                          ? Palette.accent()
                          : (this.watchedEps.has(this.watchedKey(this.flag, index))
                              ? Palette.textSecondary(this.isDark)
                              : Palette.textPrimary(this.isDark)))
                        .backgroundColor(index === this.epIndex
                          ? (this.isDark ? '#55FFFFFF' : '#22000000')
                          : (this.isDark ? '#22FFFFFF' : '#11000000'))
                        .borderRadius(4)
                        .padding({ top: 6, bottom: 6, left: 4, right: 4 })
                        .width('100%')
                        .textAlign(TextAlign.Center)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .onClick(() => this.playEpisode(index))
                  }, (series: VodSeries, index: number): string => series.name + index)
                }
                .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
                .rowsGap(6)
                .columnsGap(6)
                .width('100%')
              }
              .scrollBar(BarState.Off)
              .constraintSize({ maxHeight: 260 })
              .edgeEffect(EdgeEffect.Spring)
              .width('100%')
              .padding({ left: 8, right: 8, bottom: 8 })
            }
          }
          .width(this.bp === BP_SM ? 320 : 420)
          .backgroundColor(Palette.glass(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .border({ width: 1, color: Palette.glassBorder(this.isDark) })
          .borderRadius(12)
          .shadow({ radius: 16, color: '#40000000', offsetX: 0, offsetY: 4 })
          .padding({ top: 4, bottom: 6 })
          .margin({ bottom: 90 + this.bottomSafe, right: 40 })
          .onClick(() => {})
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.End)
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 16 })).animation({ duration: 220, curve: Curve.EaseOut }))
      }
      // 鍊嶉€熸偓娴姘綔锛氬彸涓婃偓娴紝鏃犻伄缃╋紝淇濈暀鎾斁鍣?UI
      if (this.showSpeedMenu) {
        Column() {
          Row({ space: 6 }) {
            ForEach(SPEED_OPTIONS, (speed: number, index: number) => {
              Text('x' + speed.toFixed(1))
                .fontSize(13)
                .fontColor(speed === this.playbackSpeed ? Palette.accent() : '#FFFFFF')
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .borderRadius(14)
                .backgroundColor('#66000000')
                .border({ width: 1, color: speed === this.playbackSpeed ? Palette.accent() : '#CCFFFFFF' })
                .maxLines(1)
                .onClick(() => this.onSpeedSelect(speed))
            }, (speed: number, index: number): string => 'speed' + index + speed.toFixed(1))
          }
          .margin({ bottom: 90 + this.bottomSafe, right: 40 })
          .onClick(() => {})
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.End)
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 16 })).animation({ duration: 220, curve: Curve.EaseOut }))
      }
      if (this.showResumeDialog) {
        Stack({ alignContent: Alignment.Center }) {
          Column() {
            Text('继续观看')
              .fontSize(18)
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Medium)
              .margin({ bottom: 12 })
            Text('是否从上次播放位置继续？')
              .fontSize(14)
              .fontColor('#BBFFFFFF')
              .margin({ bottom: 20 })
            Row() {
              Button('从头开始')
                .fontSize(14)
                .fontColor('#FFFFFF')
                .backgroundColor('#33FFFFFF')
                .borderRadius(8)
                .layoutWeight(1)
                .onClick(() => this.dismissResume())
              Button('继续播放')
                .fontSize(14)
                .fontColor('#FFFFFF')
                .backgroundColor(Palette.accent())
                .borderRadius(8)
                .layoutWeight(1)
                .margin({ left: 12 })
                .onClick(() => this.resumeFromPosition())
            }
            .width('100%')
          }
          .width('80%')
          .constraintSize({ maxWidth: DS.dialogMaxWidth(this.bp) })
          .padding(24)
          .backgroundColor('#CC1A1A1A')
          .backdropBlur(30)
          .borderRadius(20)
          .border({ width: 1, color: '#22FFFFFF' })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        .hitTestBehavior(HitTestMode.Block)
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.94, y: 0.94 })).animation({ duration: 220, curve: Curve.EaseOut }))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
















