/**
 * 直播播放页
 * 全屏播放器 + 左侧频道列表 + 右上角频道号 + 底部控制栏
 * 修复: 播放器切换频道重新加载 / 按键事件 / onError / loading状态 / 生命周期清理
 */
import { router, promptAction } from '@kit.ArkUI';
import { LiveChannelItem, LiveChannelGroup } from '../model/LiveChannel';
import { parseLiveContent } from '../api/LiveParser';
import { getApiConfig } from '../api/ApiConfig';
import { httpGet, formatError } from '../utils/HttpUtil';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { getTopSafeAreaVp, getTopSafeAreaSync, getBottomSafeAreaVp } from '../utils/ScreenAdapter';
import { Palette } from '../utils/ThemeManager';
import { statistics } from '@kit.NetworkKit';
import { bundleManager } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { audio } from '@kit.AudioKit';
import { media } from '@kit.MediaKit';
import { AVCastPicker } from '@kit.AVSessionKit';
import { AVCastPickerState } from '@ohos.multimedia.avCastPickerParam';
import { CastSessionHelper } from '../utils/CastSessionHelper';
import { PlayIcons } from '../../common/PlayIcons';
import { PlayIconSet } from '../../common/PlayIconSet';

const PREF_KEY_LIVE_URL: string = 'live_url';
const PREF_KEY_LIVE_GROUP_INDEX: string = 'live_group_index';
const PREF_KEY_LIVE_CHANNEL_INDEX: string = 'live_channel_index';
// 记录上次保存频道位置对应的直播源；若换源则频道位置作废
const PREF_KEY_LIVE_LAST_URL_FOR_INDEX: string = 'live_last_url_for_index';
const AUTO_HIDE_MS: number = 5000;
const CHANNEL_NUM_INDICATOR_MS: number = 3000;
const CHANNEL_NUM_INPUT_TIMEOUT_MS: number = 1500;
const RELOAD_DELAY_MS: number = 200;
const LIVE_SCALE_MODES: string[] = ['默认', '拉伸', '平铺'];
const LIVE_TIMEOUT_OPTIONS: number[] = [5, 10, 20, 30, 60];
const PREF_KEY_LIVE_TIMEOUT_ENABLED: string = 'live_timeout_enabled';
const PREF_KEY_LIVE_TIMEOUT_SEC: string = 'live_timeout_sec';
const TAG: string = 'YSC';
const DOMAIN: number = 0x0001;

interface SettingItemInfo {
  name: string;
  action: () => void;
}

interface LiveSizeResult {
  w: number | string;
  h: number | string;
}

@Entry
@Component
struct LivePlayPage {
  @State groupList: LiveChannelGroup[] = [];
  @State currentGroupIndex: number = 0;
  @State browsingGroupIndex: number = 0;
  @State currentChannelIndex: number = 0;
  @State loading: boolean = false;
  @State hasError: boolean = false;
  @State errorMsg: string = '';
  @State playUrl: string = '';
  @State sourceIndex: number = 0;
  @State sourceNum: number = 0;
  @StorageProp('isDarkMode') isDark: boolean = true;
  @State showChannelList: boolean = false;
  @State showLinePicker: boolean = false;
  @State showTimeoutPicker: boolean = false;
  @State liveUrl: string = '';
  @State channelNum: number = 0;
  @State channelName: string = '';
  @State showChannelNum: boolean = false;
  @State showControls: boolean = false;
  @State manualLandscape: boolean = false;
  @State isPlaying: boolean = true;
  @State channelNumInput: string = '';
  @State showChannelNumInput: boolean = false;
  @State showLiveSourceDialog: boolean = false;
  @State castPickerOpen: boolean = false;
  @State liveHistoryList: string[] = [];
  @State errorSourceCount: number = 0;
  @State topSafe: number = 0;
  @State bottomSafe: number = 0;
  @State scaleModeIndex: number = 0;
  @State netSpeed: string = '0KB/s';
  @State videoWidth: number = 0;
  @State videoHeight: number = 0;
  @State timeoutEnabled: boolean = false;
  @State timeoutSec: number = 30;
  private hasStartedPlaying: boolean = false;
  // 超时中断标记：为 true 时忽略后续 prepared/playing 回调，避免旧流延迟起播覆盖超时提示
  private aborting: boolean = false;
  private appUid: number = -1;
  private lastRxBytes: number = -1;
  private netTimerId: number = -1;
  private loadTimeoutId: number = -1;
  @State screenBrightness: number = 0.5;
  @State sysVolume: number = 0;
  @State sysMaxVolume: number = 15;
  @State playerVolume: number = 1.0;
  private gestureStartPlayerVolume: number = 1.0;
  private pendingVolume: number = -1;
  private volumeSetInFlight: boolean = false;
  private volumeQueued: number = -1;
  @State showGestureHud: boolean = false;
  @State gestureHudIcon: string = '';
  @State gestureHudText: string = '';
  private gestureIsLeft: boolean = false;
  private gestureStartBrightness: number = 0.5;
  private gestureStartVolume: number = 0;
  private gestureHudTimer: number = -1;
  @State containerW: number = 0;
  @State containerH: number = 0;
  private avPlayer: media.AVPlayer | null = null;
  private castHelper: CastSessionHelper = new CastSessionHelper();
  private xComponentController: XComponentController = new XComponentController();
  private surfaceId: string = '';
  private preparing: boolean = false;
  private hideTimerId: number = -1;
  private channelNumTimerId: number = -1;
  private channelNumInputTimer: number = -1;
  private reloadTimerId: number = -1;
  private pausedForBackground: boolean = false;
  private panAxis: string = '';
  private lastPanEndTime: number = 0;
  private pendingClickTimerId: number = -1;
  private lastDoubleTapTime: number = 0;
  private volumeCb: ((e: audio.VolumeEvent) => void) | null = null;

  aboutToAppear() {
    this.forceLandscape();
    this.loadTimeoutPref();
    this.loadLiveHistory();
    this.initAVPlayer();
    this.castHelper.ensure(this.getUIContext().getHostContext() as common.UIAbilityContext).then((): void => { this.updateCastMetadata(); });
    this.initLive();
    this.initSafeArea();
    this.hideSystemBars();
    this.keepScreenOn(true);
    this.initSystemVolume();
    this.startNetSpeedTimer();
  }

  async loadLiveHistory(): Promise<void> {
    const raw: string = await PreferencesUtil.get('live_history', '');
    if (!raw || raw.length === 0) { this.liveHistoryList = []; return; }
    try {
      const arr: string[] = JSON.parse(raw) as string[];
      this.liveHistoryList = Array.isArray(arr) ? arr.slice(0, 5) : [];
    } catch (e) {
      this.liveHistoryList = [];
    }
  }

  async switchLiveSource(url: string): Promise<void> {
    if (!url || url.length === 0) { return; }
    if (url === this.liveUrl) { this.showLiveSourceDialog = false; return; }
    this.showLiveSourceDialog = false;
    this.liveUrl = url;
    try {
      await PreferencesUtil.put(PREF_KEY_LIVE_URL, url);
      await PreferencesUtil.putInt(PREF_KEY_LIVE_GROUP_INDEX, 0);
      await PreferencesUtil.putInt(PREF_KEY_LIVE_CHANNEL_INDEX, 0);
      await PreferencesUtil.put(PREF_KEY_LIVE_LAST_URL_FOR_INDEX, url);
    } catch (e) {}
    getApiConfig().setLiveUrl(url);
    this.currentGroupIndex = 0;
    this.browsingGroupIndex = 0;
    this.currentChannelIndex = 0;
    this.sourceIndex = 0;
    this.sourceNum = 0;
    this.groupList = [];
    this.hasError = false;
    this.errorMsg = '';
    this.loading = true;
    this.initLive();
    promptAction.showToast({ message: '正在加载新直播源...', duration: 1500 });
  }

  private async forceLandscape(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      await win.setPreferredOrientation(window.Orientation.USER_ROTATION_LANDSCAPE);
      this.manualLandscape = true;
      // 横屏后状态栏应被系统隐藏，刷新 topSafe 为 0，避免顶栏残留竖屏留白
      this.topSafe = 0;
    } catch (e) {
      hilog.error(0x0001, 'YSC', 'forceLandscape failed: %{public}s', JSON.stringify(e));
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
    // 动态监听状态栏安全区：就绪/横竖屏切换时更新，避免控制栏顶栏压住状态栏
    try {
      const win = await window.getLastWindow(ctx);
      win.on('avoidAreaChange', (data): void => {
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM || data.type === window.AvoidAreaType.TYPE_CUTOUT) {
          this.topSafe = getTopSafeAreaSync(win);
        } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          const bh: number = data.area.bottomRect.height;
          if (bh > 0) { this.bottomSafe = px2vp(bh); }
        }
      });
    } catch (_e) {}
  }

  aboutToDisappear() {
    this.pausedForBackground = false;
    try { audio.getAudioManager().getVolumeManager().off('volumeChange'); } catch (_eVol) {}
    this.restoreAutoRotation();
    this.keepScreenOn(false);
    this.restoreSystemBars();
    this.clearAllTimers();
    if (this.pendingClickTimerId !== -1) { clearTimeout(this.pendingClickTimerId); this.pendingClickTimerId = -1; }
    this.releaseAVPlayer();
    if (!this.castHelper.isCasting) {
      this.castHelper.release();
    }
  }

  onPageHide() {
    if (this.avPlayer) {
      if (this.reloadTimerId !== -1) { clearTimeout(this.reloadTimerId); this.reloadTimerId = -1; }
      if (this.netTimerId !== -1) { clearInterval(this.netTimerId); this.netTimerId = -1; }
      this.hasStartedPlaying = false;
      this.loading = false;
      this.releaseAVPlayer();
      if (!this.castHelper.isCasting) {
        this.castHelper.release();
      }
      this.pausedForBackground = true;
      hilog.info(DOMAIN, TAG, 'onPageHide: AVPlayer released for background');
    }
  }

  onPageShow() {
    if (this.pausedForBackground && this.playUrl.length > 0) {
      this.pausedForBackground = false;
      this.loading = true;
      this.hasStartedPlaying = false;
      this.startNetSpeedTimer();
      this.initAVPlayer().then((): void => {
        this.startPlayback();
      });
      hilog.info(DOMAIN, TAG, 'onPageShow: resuming after background');
      this.castHelper.ensure(this.getUIContext().getHostContext() as common.UIAbilityContext).then((): void => { this.updateCastMetadata(); });
    }
  }

  async initAVPlayer(): Promise<void> {
    try {
      this.avPlayer = await media.createAVPlayer();
      this.setupAVPlayerEvents();
      hilog.info(DOMAIN, TAG, 'AVPlayer created');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'createAVPlayer failed: %{public}s', JSON.stringify(e));
    }
  }

  private async updateCastMetadata(): Promise<void> {
    const ch: LiveChannelItem | null = this.getCurrentChannel();
    const title: string = ch ? ch.channelName : this.channelName;
    const logo: string = ch ? ch.channelLogo : '';
    await this.castHelper.updateMetadata(title, logo, '', this.playUrl);
  }

  releaseAVPlayer(): void {
    if (this.avPlayer) {
      try { this.avPlayer.release(); } catch (_e) {}
      this.avPlayer = null;
    }
  }

  setupAVPlayerEvents(): void {
    if (!this.avPlayer) return;
    const player = this.avPlayer;
    player.on('stateChange', (state: string, reason: media.StateChangeReason) => {
      hilog.info(DOMAIN, TAG, 'AVPlayer state: %{public}s', state);
      switch (state) {
        case 'initialized':
          // 设置音频渲染信息，确保 AVPlayer.setVolume 的软件增益在平板/HarmonyOS 6 上能够作用到 AudioRenderer 输出
          try {
            player.audioRendererInfo = { usage: audio.StreamUsage.STREAM_USAGE_MOVIE, rendererFlags: 0 };
          } catch (_eAri) {}
          if (this.surfaceId.length === 0) {
            let waited: number = 0;
            const t = setInterval(() => {
              waited += 100;
              if (this.surfaceId.length > 0) { clearInterval(t); this.tryPrepare(); }
              else if (waited >= 3000) { clearInterval(t); this.tryPrepare(); }
            }, 100);
          } else {
            player.surfaceId = this.surfaceId;
            this.tryPrepare();
          }
          break;
        case 'prepared':
          if (this.aborting) { break; }
          // 保持宽高比显示（等比留黑边）。不能设 FIT：FIT 是拉伸铺满、不保持宽高比，
          // 直播源分辨率与容器比例不一致时画面会被拉扁/拉长。
          try { player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT; } catch (_eScale) {}
          // AVPlayer 始终满增益，实际音量由系统媒体音量控制
          try { player.setVolume(1.0); this.playerVolume = 1.0; } catch (_e) {}
          player.play().catch((err: Error) => { hilog.error(DOMAIN, TAG, 'play failed: %{public}s', err.message); });
          break;
        case 'playing':
          if (this.aborting) {
            try { player.pause(); } catch (_e) {}
            break;
          }
          this.isPlaying = true;
          this.loading = false;
          this.hasError = false;
          this.hasStartedPlaying = true;
          this.errorSourceCount = 0;
          this.clearLoadTimeout();
          break;
        case 'paused':
          this.isPlaying = false;
          break;
        case 'completed':
          // 直播流一般不会 completed，出现则尝试重载
          this.playCurrentChannel();
          break;
        case 'error':
          this.onPlayError();
          break;
        default:
          break;
      }
    });
    player.on('error', (err: Error) => {
      const msg: string = err.message || '';
      hilog.error(DOMAIN, TAG, 'AVPlayer error: %{public}s', msg);
      // 忽略 setVideoScale/getCurrentTime 等 API 时序性抛出的非致命错误，防止误触发换线路循环
      const nonFatal: boolean = msg.indexOf('Operate Not Permit') >= 0
        || msg.indexOf('unsupport video scale operation') >= 0
        || msg.indexOf('current state is not') >= 0;
      if (nonFatal) { return; }
      this.onPlayError();
    });
    player.on('videoSizeChange', (width: number, height: number) => {
      this.videoWidth = width;
      this.videoHeight = height;
      // 真实分辨率到手后补落一次：保持等比显示，避免全屏时被拉伸变形
      try { player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT; } catch (_eScale2) {}
    });
    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
      if (infoType === media.BufferingInfoType.BUFFERING_START) {
        if (!this.hasStartedPlaying) { this.loading = true; }
      } else if (infoType === media.BufferingInfoType.BUFFERING_END) {
        this.loading = false;
      }
    });
    // 音量设置回调：AVPlayer.setVolume 是异步的，需等本次完成后再发下一次，否则中间会被丢弃
    try {
      player.on('volumeChange', (_vol: number) => {
        this.volumeSetInFlight = false;
        if (this.volumeQueued >= 0) {
          const nv: number = this.volumeQueued;
          this.volumeQueued = -1;
          try { this.volumeSetInFlight = true; player.setVolume(nv); } catch (_ev) { this.volumeSetInFlight = false; }
        }
      });
    } catch (_eOn) {}
  }

  tryPrepare(): void {
    const player = this.avPlayer;
    if (!player) return;
    if (this.preparing) return;
    if (player.state !== 'initialized') return;
    this.preparing = true;
    player.prepare().then(() => {
      this.preparing = false;
      hilog.info(DOMAIN, TAG, 'AVPlayer prepared');
    }).catch((err: Error) => {
      this.preparing = false;
      hilog.error(DOMAIN, TAG, 'prepare failed: %{public}s', err.message);
      this.onPlayError();
    });
  }

  async startPlayback(): Promise<void> {
    const player = this.avPlayer;
    if (!player || this.playUrl.length === 0) return;
    this.preparing = false;
    try {
      if (player.state !== 'idle') {
        await player.reset();
      }
      // 直播频道可能带鉴权 header；HLS(.m3u8) 直连以规避 HiStreamer 分片下载 bug
      const ch: LiveChannelItem | null = this.getCurrentChannel();
      const headers: Map<string, string> = ch ? ch.channelHeader : new Map<string, string>();
      const lowerUrl: string = this.playUrl.toLowerCase();
      const isHls: boolean = lowerUrl.includes('m3u8');
      if (headers.size > 0 && !isHls) {
        const headerRecord: Record<string, string> = {};
        headers.forEach((v: string, k: string) => { headerRecord[k] = v; });
        const mediaSource: media.MediaSource = media.createMediaSourceWithUrl(this.playUrl, headerRecord);
        await player.setMediaSource(mediaSource);
      } else {
        player.url = this.playUrl;
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'startPlayback failed: %{public}s', JSON.stringify(e));
      try {
        if (this.avPlayer && this.avPlayer.state !== 'idle') { await this.avPlayer.reset(); }
        if (this.avPlayer) { this.avPlayer.url = this.playUrl; }
      } catch (_e2) {
        this.onPlayError();
      }
    }
  }

  clearAllTimers() {
    if (this.hideTimerId !== -1) {
      clearTimeout(this.hideTimerId);
      this.hideTimerId = -1;
    }
    if (this.channelNumTimerId !== -1) {
      clearTimeout(this.channelNumTimerId);
      this.channelNumTimerId = -1;
    }
    if (this.channelNumInputTimer !== -1) {
      clearTimeout(this.channelNumInputTimer);
      this.channelNumInputTimer = -1;
    }
    if (this.reloadTimerId !== -1) {
      clearTimeout(this.reloadTimerId);
      this.reloadTimerId = -1;
    }
    if (this.netTimerId !== -1) {
      clearInterval(this.netTimerId);
      this.netTimerId = -1;
    }
    if (this.pendingClickTimerId !== -1) {
      clearTimeout(this.pendingClickTimerId);
      this.pendingClickTimerId = -1;
    }
    this.clearLoadTimeout();
  }

  // ==================== 网速统计 ====================
  private resolveAppUid(): void {
    if (this.appUid >= 0) return;
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.appUid = info.appInfo.uid;
    } catch (e) {
    }
  }

  private async readRxBytes(): Promise<number> {
    if (this.appUid >= 0) {
      try {
        return await statistics.getUidRxBytes(this.appUid);
      } catch (e) {
      }
    }
    return await statistics.getAllRxBytes();
  }

  startNetSpeedTimer(): void {
    if (this.netTimerId !== -1) {
      clearInterval(this.netTimerId);
    }
    this.lastRxBytes = -1;
    this.resolveAppUid();
    this.netTimerId = setInterval((): void => {
      this.readRxBytes().then((total: number): void => {
        if (this.lastRxBytes >= 0 && total >= this.lastRxBytes) {
          this.netSpeed = this.formatSpeed(total - this.lastRxBytes);
        }
        this.lastRxBytes = total;
      }).catch((): void => {});
    }, 1000);
  }

  formatSpeed(bytesPerSec: number): string {
    if (bytesPerSec >= 1024 * 1024) {
      return (bytesPerSec / (1024 * 1024)).toFixed(1) + 'MB/s';
    } else if (bytesPerSec >= 1024) {
      return (bytesPerSec / 1024).toFixed(0) + 'KB/s';
    }
    return bytesPerSec + 'B/s';
  }

  // ==================== 画面比例 ====================
  private getVideoLayerSize(): LiveSizeResult {
    const cw: number = this.containerW;
    const ch: number = this.containerH;
    if (cw <= 0 || ch <= 0) {
      return { w: '100%', h: '100%' };
    }
    const mode: string = LIVE_SCALE_MODES[this.scaleModeIndex];
    if (mode === '拉伸') {
      return { w: cw, h: ch };
    }
    if (this.videoWidth <= 0 || this.videoHeight <= 0) {
      return { w: '100%', h: '100%' };
    }
    const ratio: number = this.videoWidth / this.videoHeight;
    const containerRatio: number = cw / ch;
    let w: number;
    let h: number;
    if (mode === '平铺') {
      if (ratio > containerRatio) { h = ch; w = ch * ratio; }
      else { w = cw; h = cw / ratio; }
    } else {
      if (ratio > containerRatio) { w = cw; h = cw / ratio; }
      else { h = ch; w = ch * ratio; }
    }
    return { w: w, h: h };
  }

  getScaleModeText(): string {
    return LIVE_SCALE_MODES[this.scaleModeIndex];
  }

  onScaleModeClick(): void {
    this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.closeOtherPopups(''); });
    this.scaleModeIndex = (this.scaleModeIndex + 1) % LIVE_SCALE_MODES.length;
    this.showControlsAutoHide();
  }

  // ==================== 超时换线路 ====================
  private loadTimeoutPref(): void {
    this.timeoutEnabled = PreferencesUtil.getBoolSync(PREF_KEY_LIVE_TIMEOUT_ENABLED, false);
    this.timeoutSec = PreferencesUtil.getIntSync(PREF_KEY_LIVE_TIMEOUT_SEC, 30);
  }

  private clearLoadTimeout(): void {
    if (this.loadTimeoutId !== -1) {
      clearTimeout(this.loadTimeoutId);
      this.loadTimeoutId = -1;
    }
  }

  private startLoadTimeout(): void {
    this.clearLoadTimeout();
    // 未启用"超时切换线路"时，不设置任何超时保护——用户明确关闭。
    if (!this.timeoutEnabled) return;
    // 仅当前频道存在多条线路时才开启超时切线路；仅一条线路时也不做超时。
    const ch0: LiveChannelItem | null = this.getCurrentChannel();
    const hasMultiSource: boolean = ch0 !== null && ch0.sourceNum > 1;
    if (!hasMultiSource) return;
    const secAtStart: number = this.timeoutSec;
    this.loadTimeoutId = setTimeout((): void => {
      this.loadTimeoutId = -1;
      if (this.hasStartedPlaying) { return; }
      hilog.warn(DOMAIN, TAG, 'load timeout %{public}ds, aborting current stream: %{public}s', secAtStart, this.channelName);
      // 同步中止旧流，避免延迟到达的 prepared/playing 回调把画面又拉起来
      this.aborting = true;
      this.loading = false;
      try { if (this.avPlayer) { this.avPlayer.stop(); } } catch (_e) {}
      try { if (this.avPlayer && this.avPlayer.state !== 'idle') { this.avPlayer.reset(); } } catch (_e) {}
      const ch: LiveChannelItem | null = this.getCurrentChannel();
      if (ch !== null && ch.sourceNum > 1) {
        promptAction.showToast({ message: '超时' + secAtStart + 's，自动切换线路', duration: 1500 });
        this.switchSource();
      } else {
        promptAction.showToast({ message: '超时' + secAtStart + 's，重新加载', duration: 1500 });
        this.playCurrentChannel();
      }
    }, secAtStart * 1000);
  }

  setTimeoutEnabled(enabled: boolean): void {
    this.timeoutEnabled = enabled;
    PreferencesUtil.putBool(PREF_KEY_LIVE_TIMEOUT_ENABLED, enabled);
    // 关闭后立即清掉现有 watchdog；开启后按最新设定重启（仅在多线路频道会真正生效）。
    this.clearLoadTimeout();
    if (enabled && !this.hasStartedPlaying && this.playUrl.length > 0) {
      this.startLoadTimeout();
    }
  }

  setTimeoutSec(sec: number): void {
    this.timeoutSec = sec;
    PreferencesUtil.putInt(PREF_KEY_LIVE_TIMEOUT_SEC, sec);
    if (!this.hasStartedPlaying && this.playUrl.length > 0) {
      this.startLoadTimeout();
    }
  }

  async initLive() {
    const config = getApiConfig();
    this.liveUrl = await PreferencesUtil.get(PREF_KEY_LIVE_URL, '');
    if (this.liveUrl.length === 0) {
      this.liveUrl = config.getLiveUrl();
    }
    if (this.liveUrl.length === 0) {
      this.hasError = true;
      this.errorMsg = '请先在设置中配置直播地址';
      return;
    }
    await this.loadLiveContent();
  }

  async loadLiveContent() {
    this.loading = true;
    this.hasError = false;
    try {
      const raw: string = await this.fetchLiveText(this.liveUrl);
      const groups: LiveChannelGroup[] = parseLiveContent(raw);
      if (groups.length === 0) {
        this.hasError = true;
        this.errorMsg = '解析直播源失败，未找到频道';
      } else {
        this.groupList = groups;
        const lastUrl: string = PreferencesUtil.getSync(PREF_KEY_LIVE_LAST_URL_FOR_INDEX, '');
        const sameUrl: boolean = lastUrl === this.liveUrl;
        const savedGroup: number = sameUrl ? PreferencesUtil.getIntSync(PREF_KEY_LIVE_GROUP_INDEX, 0) : 0;
        const savedChannel: number = sameUrl ? PreferencesUtil.getIntSync(PREF_KEY_LIVE_CHANNEL_INDEX, 0) : 0;
        if (!sameUrl) {
          await PreferencesUtil.put(PREF_KEY_LIVE_LAST_URL_FOR_INDEX, this.liveUrl);
          await PreferencesUtil.putInt(PREF_KEY_LIVE_GROUP_INDEX, 0);
          await PreferencesUtil.putInt(PREF_KEY_LIVE_CHANNEL_INDEX, 0);
        }
        if (savedGroup >= 0 && savedGroup < groups.length) {
          this.currentGroupIndex = savedGroup;
        } else {
          this.currentGroupIndex = 0;
        }
        const g: LiveChannelGroup = groups[this.currentGroupIndex];
        if (g && savedChannel >= 0 && savedChannel < g.liveChannelItems.length) {
          this.currentChannelIndex = savedChannel;
        } else {
          this.currentChannelIndex = 0;
        }
        this.browsingGroupIndex = this.currentGroupIndex;
        this.playCurrentChannel();
      }
    } catch (e) {
      this.hasError = true;
      this.errorMsg = formatError(e);
    } finally {
      this.loading = false;
    }
  }

  /** 获取直播源文本：builtin:// 走 rawfile 离线内置，其余走 HTTP */
  private async fetchLiveText(url: string): Promise<string> {
    if (url.startsWith('builtin://')) {
      const name: string = url.substring('builtin://'.length);
      const context = getContext() as common.UIAbilityContext;
      const mgr = context.resourceManager;
      const data = await mgr.getRawFileContent(name);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(data));
    }
    return httpGet(url, undefined, { ttlMs: 0 });
  }

  getCurrentGroup(): LiveChannelGroup | null {
    if (this.currentGroupIndex >= 0 && this.currentGroupIndex < this.groupList.length) {
      return this.groupList[this.currentGroupIndex];
    }
    return null;
  }

  // 右侧列表显示的是"正在浏览"的分类，可能不同于正在播放的分类
  getBrowsingGroup(): LiveChannelGroup | null {
    if (this.browsingGroupIndex >= 0 && this.browsingGroupIndex < this.groupList.length) {
      return this.groupList[this.browsingGroupIndex];
    }
    return null;
  }

  getCurrentChannel(): LiveChannelItem | null {
    const g: LiveChannelGroup | null = this.getCurrentGroup();
    if (g && this.currentChannelIndex >= 0 && this.currentChannelIndex < g.liveChannelItems.length) {
      return g.liveChannelItems[this.currentChannelIndex];
    }
    return null;
  }

  playCurrentChannel() {
    // 关闭其它悬浮弹框（保留频道列表以便继续换台）
    this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.closeOtherPopups('channel'); });
    const ch: LiveChannelItem | null = this.getCurrentChannel();
    if (!ch) return;
    this.channelNum = ch.channelNum;
    this.channelName = ch.channelName;
    this.updateCastMetadata();
    this.sourceIndex = ch.sourceIndex;
    this.sourceNum = ch.sourceNum;
    this.errorSourceCount = 0;
    this.hasError = false;
    this.hasStartedPlaying = false;
    this.aborting = false;

    // 切台：更新 URL 并用 AVPlayer 重新起播
    const newUrl: string = ch.getUrl();
    this.playUrl = newUrl;
    this.loading = true;

    if (this.reloadTimerId !== -1) {
      clearTimeout(this.reloadTimerId);
    }
    this.reloadTimerId = setTimeout((): void => {
      this.startPlayback();
      this.reloadTimerId = -1;
      this.startLoadTimeout();
    }, RELOAD_DELAY_MS);

    PreferencesUtil.putInt(PREF_KEY_LIVE_GROUP_INDEX, this.currentGroupIndex);
    PreferencesUtil.putInt(PREF_KEY_LIVE_CHANNEL_INDEX, this.currentChannelIndex);
    this.showChannelNumIndicator();
    this.showControlsAutoHide();
    hilog.info(DOMAIN, TAG, 'playChannel: %{public}s url=%{public}s', ch.channelName, this.playUrl);
  }

  switchSource() {
    const ch: LiveChannelItem | null = this.getCurrentChannel();
    if (!ch) return;
    if (ch.sourceNum <= 1) {
      promptAction.showToast({ message: '该频道仅一条线路', duration: 1500 });
      return;
    }
    ch.nextSource();
    this.sourceIndex = ch.sourceIndex;
    this.errorSourceCount = 0;
    this.hasError = false;
    this.hasStartedPlaying = false;
    this.aborting = false;

    this.playUrl = ch.getUrl();
    this.loading = true;

    if (this.reloadTimerId !== -1) {
      clearTimeout(this.reloadTimerId);
    }
    this.reloadTimerId = setTimeout((): void => {
      this.startPlayback();
      this.reloadTimerId = -1;
      this.startLoadTimeout();
    }, RELOAD_DELAY_MS);

    hilog.info(DOMAIN, TAG, 'switchSource: %{public}s source=%{public}d/%{public}d', ch.channelName, this.sourceIndex + 1, this.sourceNum);
    this.showControlsAutoHide();
  }

  selectSource(idx: number) {
    const ch: LiveChannelItem | null = this.getCurrentChannel();
    if (!ch) return;
    if (idx < 0 || idx >= ch.sourceNum) return;
    this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.showLinePicker = false; });
    if (idx === ch.sourceIndex) { this.showControlsAutoHide(); return; }
    ch.sourceIndex = idx;
    this.sourceIndex = idx;
    this.errorSourceCount = 0;
    this.hasError = false;
    this.hasStartedPlaying = false;
    this.aborting = false;
    this.playUrl = ch.getUrl();
    this.loading = true;
    if (this.reloadTimerId !== -1) { clearTimeout(this.reloadTimerId); }
    this.reloadTimerId = setTimeout((): void => {
      this.startPlayback();
      this.reloadTimerId = -1;
      this.startLoadTimeout();
    }, RELOAD_DELAY_MS);
    hilog.info(DOMAIN, TAG, 'selectSource: %{public}s source=%{public}d/%{public}d', ch.channelName, this.sourceIndex + 1, this.sourceNum);
    this.showControlsAutoHide();
  }

  getLineUrls(): string[] {
    const ch: LiveChannelItem | null = this.getCurrentChannel();
    return ch ? ch.channelUrls : [];
  }

  getLineName(idx: number): string {
    const ch: LiveChannelItem | null = this.getCurrentChannel();
    if (!ch) return '线路' + String(idx + 1);
    const name: string = ch.channelSourceNames[idx] ?? '';
    return name.length > 0 ? name : ('线路' + String(idx + 1));
  }

  showChannelNumIndicator() {
    this.showChannelNum = true;
    if (this.channelNumTimerId !== -1) {
      clearTimeout(this.channelNumTimerId);
    }
    this.channelNumTimerId = setTimeout((): void => {
      this.showChannelNum = false;
      this.channelNumTimerId = -1;
    }, CHANNEL_NUM_INDICATOR_MS);
  }

  // 点击左侧分类：仅切换右侧浏览的频道列表，不换台（保持当前播放）
  onGroupClick(index: number) {
    if (index === this.browsingGroupIndex) return;
    this.getUIContext()?.animateTo({ duration: 180, curve: Curve.EaseOut }, () => { this.browsingGroupIndex = index; });
  }

  // 点击右侧具体频道：切换到该分类的该频道并换台；保留频道列表方便继续换台
  onChannelClick(index: number) {
    if (this.browsingGroupIndex === this.currentGroupIndex && index === this.currentChannelIndex) {
      return;
    }
    this.currentGroupIndex = this.browsingGroupIndex;
    this.currentChannelIndex = index;
    this.playCurrentChannel();
  }

  // 跨分类循环切台：按当前分组顺序遍历，末尾自动跳到下一分组，全部结束回到第一个
  prevChannel() {
    const groups: LiveChannelGroup[] = this.groupList;
    if (!groups || groups.length === 0) return;
    let gi: number = this.currentGroupIndex;
    let ci: number = this.currentChannelIndex;
    for (let step: number = 0; step < 1024; step++) {
      if (ci > 0) {
        ci--;
      } else {
        gi = (gi - 1 + groups.length) % groups.length;
        const items: LiveChannelItem[] = groups[gi].liveChannelItems;
        if (!items || items.length === 0) continue;
        ci = items.length - 1;
      }
      const items2: LiveChannelItem[] = groups[gi].liveChannelItems;
      if (items2 && items2.length > 0) {
        this.currentGroupIndex = gi;
        this.currentChannelIndex = ci;
        this.playCurrentChannel();
        return;
      }
    }
  }

  nextChannel() {
    const groups: LiveChannelGroup[] = this.groupList;
    if (!groups || groups.length === 0) return;
    let gi: number = this.currentGroupIndex;
    let ci: number = this.currentChannelIndex;
    for (let step: number = 0; step < 1024; step++) {
      const items: LiveChannelItem[] = groups[gi].liveChannelItems;
      if (items && ci < items.length - 1) {
        ci++;
      } else {
        gi = (gi + 1) % groups.length;
        ci = 0;
      }
      const items2: LiveChannelItem[] = groups[gi].liveChannelItems;
      if (items2 && items2.length > 0) {
        this.currentGroupIndex = gi;
        this.currentChannelIndex = ci;
        this.playCurrentChannel();
        return;
      }
    }
  }

  // 按频道名称跨分类排序的全局切换：返回 [groupIndex, channelIndex, item] 数组
  private buildSortedChannels(): Array<[number, number, LiveChannelItem]> {
    const list: Array<[number, number, LiveChannelItem]> = [];
    for (let gi: number = 0; gi < this.groupList.length; gi++) {
      const items: LiveChannelItem[] = this.groupList[gi].liveChannelItems;
      for (let ci: number = 0; ci < items.length; ci++) {
        list.push([gi, ci, items[ci]]);
      }
    }
    list.sort((a: [number, number, LiveChannelItem], b: [number, number, LiveChannelItem]): number => {
      const na: string = a[2].channelName || '';
      const nb: string = b[2].channelName || '';
      return na.localeCompare(nb, 'zh-Hans-CN');
    });
    return list;
  }

  // 按频道名排序后，跨分类切换到 上一个/下一个 频道；首尾循环
  private jumpChannelSorted(delta: number): void {
    const sorted = this.buildSortedChannels();
    if (sorted.length === 0) return;
    let curIdx: number = -1;
    for (let i: number = 0; i < sorted.length; i++) {
      if (sorted[i][0] === this.currentGroupIndex && sorted[i][1] === this.currentChannelIndex) {
        curIdx = i;
        break;
      }
    }
    let nextIdx: number = curIdx < 0 ? 0 : (curIdx + delta);
    if (nextIdx < 0) nextIdx = sorted.length - 1;
    if (nextIdx >= sorted.length) nextIdx = 0;
    const target = sorted[nextIdx];
    this.currentGroupIndex = target[0];
    this.currentChannelIndex = target[1];
    this.playCurrentChannel();
  }

  prevChannelSorted(): void { this.jumpChannelSorted(-1); }
  nextChannelSorted(): void { this.jumpChannelSorted(1); }

  prevSource() {
    const ch: LiveChannelItem | null = this.getCurrentChannel();
    if (!ch || ch.sourceNum <= 1) return;
    ch.prevSource();
    this.sourceIndex = ch.sourceIndex;
    this.errorSourceCount = 0;
    this.hasError = false;
    this.hasStartedPlaying = false;

    this.playUrl = ch.getUrl();
    this.loading = true;

    if (this.reloadTimerId !== -1) {
      clearTimeout(this.reloadTimerId);
    }
    this.reloadTimerId = setTimeout((): void => {
      this.startPlayback();
      this.reloadTimerId = -1;
      this.startLoadTimeout();
    }, RELOAD_DELAY_MS);

    hilog.info(DOMAIN, TAG, 'prevSource: %{public}s source=%{public}d/%{public}d', ch.channelName, this.sourceIndex + 1, this.sourceNum);
    this.showControlsAutoHide();
  }

    // 一次只能打开一个弹框：关闭除 keep 之外的所有悬浮弹框
  closeOtherPopups(keep: string = ''): boolean {
    let closedAny = false;
    if (keep !== 'channel' && this.showChannelList) { this.showChannelList = false; closedAny = true; }
    if (keep !== 'line' && this.showLinePicker) { this.showLinePicker = false; closedAny = true; }
    if (keep !== 'timeout' && this.showTimeoutPicker) { this.showTimeoutPicker = false; closedAny = true; }
    if (keep !== 'source' && this.showLiveSourceDialog) { this.showLiveSourceDialog = false; closedAny = true; }
    return closedAny;
  }

  toggleChannelList() {
    const willOpen: boolean = !this.showChannelList;
    // 一次只能打开一个弹框：先关闭其他弹框，然后带动画切换频道列表
    this.getUIContext()?.animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.closeOtherPopups('channel');
      this.showChannelList = willOpen;
      if (willOpen) {
        // 打开列表时，浏览分类默认定位到当前正在播放的分类
        this.browsingGroupIndex = this.currentGroupIndex;
        this.showControls = false;
      }
    });
    if (!willOpen) {
      this.showControlsAutoHide();
    }
  }

  onLiveDoubleClick(): void {
    if (this.pendingClickTimerId !== -1) {
      clearTimeout(this.pendingClickTimerId);
      this.pendingClickTimerId = -1;
    }
    this.lastDoubleTapTime = Date.now();
    const player = this.avPlayer;
    if (!player) return;
    if (this.isPlaying) {
      try { player.pause(); } catch (_e) {}
      this.isPlaying = false;
    } else {
      try {
        player.play();
        this.isPlaying = true;
      } catch (_e) {}
    }
    this.showGestureFeedback('', this.isPlaying ? '播放' : '暂停');
  }

  togglePlay() {
    // 一次只能打开一个弹框：点击其他按钮时先关闭已开弹框
    this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.closeOtherPopups(''); });
    const player = this.avPlayer;
    if (!player) return;
    if (this.isPlaying) {
      player.pause();
      this.isPlaying = false;
    } else {
      player.play();
      this.isPlaying = true;
    }
    this.showControlsAutoHide();
  }

  onLiveClick() {
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
      this.toggleControls();
    }, 250);
  }

  toggleControls() {
    // 优先关闭已打开的悬浮弹框，保留控制栏
    if (this.showLinePicker || this.showTimeoutPicker || this.showLiveSourceDialog) {
      this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
        this.showLinePicker = false;
        this.showTimeoutPicker = false;
        this.showLiveSourceDialog = false;
      });
      this.showControlsAutoHide();
      return;
    }
    if (this.showControls || this.showChannelList) {
      this.getUIContext()?.animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
        this.showControls = false;
        this.showChannelList = false;
      });
      if (this.hideTimerId !== -1) {
        clearTimeout(this.hideTimerId);
        this.hideTimerId = -1;
      }
    } else {
      this.showControlsAutoHide();
    }
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
      // 弹框打开时不隐藏控制栏
      if (this.showLinePicker || this.showTimeoutPicker || this.showLiveSourceDialog || this.castPickerOpen) {
        this.startHideTimer();
        return;
      }
      this.showControls = false;
      this.hideTimerId = -1;
    }, AUTO_HIDE_MS);
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
      hilog.warn(DOMAIN, TAG, 'initSystemVolume failed: %{public}s', JSON.stringify(e) ?? '');
    }
  }

  private setSystemVolume(level: number): void {
    if (this.sysMaxVolume <= 0) return;
    const clamped: number = level < 0 ? 0 : (level > this.sysMaxVolume ? this.sysMaxVolume : level);
    if (clamped === this.sysVolume) return;
    try {
      const am = audio.getAudioManager();
      am.setVolume(audio.AudioVolumeType.MEDIA, clamped).catch((e: Object): void => {
        hilog.warn(DOMAIN, TAG, 'setSystemVolume failed: %{public}s', JSON.stringify(e) ?? '');
      });
      this.sysVolume = clamped;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setSystemVolume failed: %{public}s', JSON.stringify(e) ?? '');
    }
  }

  private onVerticalPanStart(fingerX: number, fingerY: number): void {
    // 规避系统手势区域：顶部下拉状态栏、底部上滑返回桌面
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

  private onVerticalPanUpdate(dy: number): void {
    if (this.panAxis !== 'v') return;
    const range: number = this.containerH > 0 ? this.containerH : 720;
    const delta: number = -dy / range;
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

  async toggleFullscreen(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      if (this.manualLandscape) {
        await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
        this.manualLandscape = false;
      } else {
        await win.setPreferredOrientation(window.Orientation.USER_ROTATION_LANDSCAPE);
        this.manualLandscape = true;
      }
    } catch (e) {
      hilog.error(0x0001, 'YSC', 'toggleFullscreen failed: %{public}s', JSON.stringify(e));
    }
    this.showControlsAutoHide();
  }

  private async restoreAutoRotation(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
    } catch (_e) {}
  }

  // 顶栏返回按钮：始终退出播放页（不受悬浮弹框拦截）
  exitPlayback(): void {
    // 先关闭所有悬浮弹框，避免动画残留
    this.getUIContext()?.animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
      this.closeOtherPopups('');
      this.showControls = false;
    });
    router.back();
  }

  goBack() {
    if (this.onBackPress()) { return; }
    router.back();
  }

  // ==================== Key Event Handling ====================

  onBackPress(): boolean {
    if (this.showLiveSourceDialog) {
      this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.showLiveSourceDialog = false; });
      return true;
    }
    if (this.showLinePicker) {
      this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.showLinePicker = false; });
      return true;
    }
    if (this.showTimeoutPicker) {
      this.getUIContext()?.animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.showTimeoutPicker = false; });
      return true;
    }
    if (this.showChannelList) {
      this.getUIContext()?.animateTo({ duration: 220, curve: Curve.EaseOut }, () => { this.showChannelList = false; });
      return true;
    }
    if (this.showControls) {
      this.showControls = false;
      return true;
    }
    return false;
  }


  handleKeyDown(keyCode: number): boolean {
    // Number keys 0-9
    if (keyCode >= 2000 && keyCode <= 2009) {
      const digit: string = String(keyCode - 2000);
      this.handleNumericKey(digit);
      return true;
    }

    switch (keyCode) {
      case 2012:
        this.prevChannel();
        return true;
      case 2013:
        this.nextChannel();
        return true;
      case 2014:
        if (this.sourceNum > 1) {
          this.prevSource();
        }
        return true;
      case 2015:
        if (this.sourceNum > 1) {
          this.switchSource();
        }
        return true;
      case 2017:
      case 2016:
        this.toggleControls();
        return true;
      case 2019:
        return this.onBackPress();
      case 2062:
        this.togglePlay();
        return true;
      case 2034:
        this.toggleChannelList();
        return true;
      default:
        break;
    }
    return false;
  }

  handleNumericKey(digit: string): void {
    // Limit to 4 digits
    if (this.channelNumInput.length >= 4) {
      this.channelNumInput = '';
    }
    this.channelNumInput += digit;
    this.showChannelNumInput = true;
    this.showChannelNum = false;
    this.channelNum = parseInt(this.channelNumInput);

    if (this.channelNumInputTimer !== -1) {
      clearTimeout(this.channelNumInputTimer);
    }
    this.channelNumInputTimer = setTimeout((): void => {
      const num: number = parseInt(this.channelNumInput);
      this.channelNumInput = '';
      this.showChannelNumInput = false;
      this.channelNumInputTimer = -1;
      if (!isNaN(num)) {
        this.jumpToChannelNum(num);
      }
    }, CHANNEL_NUM_INPUT_TIMEOUT_MS);
  }

  jumpToChannelNum(num: number) {
    for (const group of this.groupList) {
      for (let i = 0; i < group.liveChannelItems.length; i++) {
        if (group.liveChannelItems[i].channelNum === num) {
          this.currentGroupIndex = group.groupIndex;
          this.currentChannelIndex = i;
          this.playCurrentChannel();
          return;
        }
      }
    }
    hilog.info(DOMAIN, TAG, 'jumpToChannelNum: channel %{public}d not found', num);
  }

  // ==================== Video Error Handling ====================

  onPlayError() {
    hilog.error(DOMAIN, TAG, 'playError: %{public}s source=%{public}d/%{public}d hasStarted=%{public}s',
      this.channelName, this.sourceIndex + 1, this.sourceNum, String(this.hasStartedPlaying));
    // If playback already started successfully, ignore transient errors (the
    // HarmonyOS Video component can emit a spurious onError even while playing).
    if (this.hasStartedPlaying) {
      hilog.info(DOMAIN, TAG, 'ignore transient error, already playing: %{public}s', this.channelName);
      return;
    }
    // 若已开启"超时换线路"，交由超时定时器统一处理，避免错误触发的秒切；
    // 定时器到点后（timeoutSec 秒），仍未起播则自动换线路。
    if (this.timeoutEnabled && this.sourceNum > 1) {
      hilog.info(DOMAIN, TAG, 'error occurred, defer to timeout (%{public}ds): %{public}s', this.timeoutSec, this.channelName);
      // 保证定时器仍在运行；若已到期则由其分支自行切换
      if (this.loadTimeoutId === -1) {
        this.startLoadTimeout();
      }
      return;
    }
    this.loading = false;
    this.errorSourceCount++;

    // 用户已明确关闭"超时切换线路"：不做自动切换，直接停在错误状态；
    // 只有开启了超时切换的分支才会走 switchSource（那部分逻辑在上面的 timeoutEnabled 分支里已处理）
    this.hasError = true;
    this.errorMsg = '播放失败: ' + this.channelName;
  }


  // ==================== Build ====================

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // Full-screen video base layer (AVPlayer + XComponent)
      Stack({ alignContent: Alignment.Center }) {
        if (this.playUrl.length > 0) {
          // 视频层：Column 居中 + 裁剪，配合 getVideoLayerSize() 的 cover/fit
          XComponent({
            id: 'live_surface',
            type: XComponentType.SURFACE,
            controller: this.xComponentController
          })
            .onLoad(() => {
              try {
                this.surfaceId = this.xComponentController.getXComponentSurfaceId();
                hilog.info(DOMAIN, TAG, 'XComponent surfaceId: %{public}s', this.surfaceId);
                if (this.avPlayer && this.surfaceId.length > 0) {
                  const state: string = this.avPlayer.state;
                  if (state === 'initialized') {
                    this.avPlayer.surfaceId = this.surfaceId;
                    this.tryPrepare();
                  } else if (state === 'prepared' || state === 'playing' || state === 'paused' || state === 'completed') {
                    this.avPlayer.surfaceId = this.surfaceId;
                    this.avPlayer.play().catch((err: Error) => { hilog.error(DOMAIN, TAG, 'play from onLoad failed: %{public}s', err.message); });
                  }
                }
              } catch (e) {
                hilog.error(DOMAIN, TAG, 'getXComponentSurfaceId failed: %{public}s', JSON.stringify(e));
              }
            })
            .width(this.getVideoLayerSize().w)
            .height(this.getVideoLayerSize().h)
        }
      }
      .width('100%')
      .height('100%')
      .clip(true)
      .backgroundColor('#000000')
      .onAreaChange((_o: Area, n: Area) => { this.containerW = n.width as number; this.containerH = n.height as number; })
      .gesture(
        GestureGroup(GestureMode.Parallel,
          TapGesture({ count: 2 })
            .onAction((_e: GestureEvent): void => { this.onLiveDoubleClick(); }),
          TapGesture({ count: 1 })
            .onAction((_e: GestureEvent): void => { this.onLiveClick(); }),
          PanGesture({ direction: PanDirection.Vertical, distance: 8 })
            .onActionStart((e: GestureEvent): void => { this.onVerticalPanStart(e.fingerList[0]?.localX ?? 0, e.fingerList[0]?.localY ?? -1); })
            .onActionUpdate((e: GestureEvent): void => { this.onVerticalPanUpdate(e.offsetY); })
            .onActionEnd((_e: GestureEvent): void => { if (this.panAxis === 'v') { this.panAxis = ''; this.lastPanEndTime = Date.now(); } })
            .onActionCancel((): void => { if (this.panAxis === 'v') { this.panAxis = ''; this.lastPanEndTime = Date.now(); } })
        )
      )
      .onKeyEvent((event: KeyEvent) => { if (event.type === KeyType.Down) { this.handleKeyDown(event.keyCode); } })

      // Loading indicator（仅居中 spinner，无文字，与首页/搜索保持一致）
      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(56)
            .height(56)
            .color(Palette.textPrimary(this.isDark))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.None)
        .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
      }

      // Error overlay
      if (this.hasError) {
        Column({ space: 8 }) {
          Text('直播加载失败')
            .fontSize(18)
            .fontColor('#FF4444')
            .fontWeight(FontWeight.Bold)
          Text(this.errorMsg)
            .fontSize(13)
            .fontColor('#BBFFFFFF')
            .textAlign(TextAlign.Center)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('重试')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor(Palette.accent())
            .borderRadius(6)
            .padding({ left: 24, right: 24, top: 10, bottom: 10 })
            .margin({ top: 12 })
            .onClick(() => this.loadLiveContent())
        }
        .alignItems(HorizontalAlign.Center)
        .width('50%')
      }

      // Channel number input indicator (top-right, shows digits being typed)
      if (this.showChannelNumInput) {
        Text(this.channelNumInput)
          .fontSize(96)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Bold)
          .position({ x: '100%', y: 20 })
          .markAnchor({ x: '100%', y: 0 })
          .margin({ right: 24 })
          .hitTestBehavior(HitTestMode.None)
      }

      // Left channel list panel (two columns: group list + channel list)
      if (this.showChannelList) {
        Row() {
          // Group list (categories) - width ~220vp
          Column() {
            Text('频道分类')
              .fontSize(15)
              .fontColor(Palette.textPrimary(this.isDark))
              .fontWeight(FontWeight.Bold)
              .height(44)
              .textAlign(TextAlign.Center)
              .width('100%')
            List() {
              ForEach(this.groupList, (group: LiveChannelGroup, gIndex: number) => {
                ListItem() {
                  Text(group.groupName)
                    .fontSize(14)
                    .fontColor(gIndex === this.browsingGroupIndex ? Palette.textPrimary(this.isDark) : Palette.textSecondary(this.isDark))
                    .fontWeight(gIndex === this.browsingGroupIndex ? FontWeight.Bold : FontWeight.Normal)
                    .backgroundColor(gIndex === this.browsingGroupIndex ? (this.isDark ? '#22FFFFFF' : '#22000000') : '#00000000')
                    .height(48)
                    .width('100%')
                    .textAlign(TextAlign.Center)
                    .borderRadius(8)
                    .animation({ duration: 180, curve: Curve.EaseOut })
                    .clickEffect({ level: ClickEffectLevel.LIGHT })
                    .onClick(() => this.onGroupClick(gIndex))
                }
              }, (group: LiveChannelGroup, gIndex: number) => gIndex.toString())
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .divider({ strokeWidth: 0.5, color: Palette.border(this.isDark), startMargin: 8, endMargin: 8 })
            .edgeEffect(EdgeEffect.Spring)
          }
          .width(220)
          .height('100%')
          .backgroundColor(Palette.glass(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .border({ width: 1, color: Palette.glassBorder(this.isDark) })
          .padding({ left: 8, right: 8, top: 56 + this.topSafe, bottom: 12 + this.bottomSafe })

          // Channel list within selected group - width ~300vp
          Column() {
            Text(this.getBrowsingGroup()?.groupName ?? '')
              .fontSize(15)
              .fontColor(Palette.textPrimary(this.isDark))
              .fontWeight(FontWeight.Bold)
              .height(44)
              .textAlign(TextAlign.Center)
              .width('100%')
            List() {
              ForEach(this.getBrowsingGroup()?.liveChannelItems ?? [], (item: LiveChannelItem, cIndex: number) => {
                ListItem() {
                  Row() {
                    Text(item.channelName)
                      .fontSize(14)
                      .fontColor((this.browsingGroupIndex === this.currentGroupIndex && cIndex === this.currentChannelIndex) ? Palette.textPrimary(this.isDark) : Palette.textSecondary(this.isDark))
                      .fontWeight((this.browsingGroupIndex === this.currentGroupIndex && cIndex === this.currentChannelIndex) ? FontWeight.Bold : FontWeight.Normal)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    if (item.sourceNum > 1) {
                      Text(String(item.sourceNum))
                        .fontSize(11)
                        .fontColor(Palette.textSecondary(this.isDark))
                        .backgroundColor(this.isDark ? '#22FFFFFF' : '#22000000')
                        .borderRadius(4)
                        .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                    }
                  }
                  .width('100%')
                  .height(48)
                  .backgroundColor((this.browsingGroupIndex === this.currentGroupIndex && cIndex === this.currentChannelIndex) ? (this.isDark ? '#22FFFFFF' : '#22000000') : '#00000000')
                  .borderRadius(8)
                  .padding({ left: 8, right: 8 })
                  .alignItems(VerticalAlign.Center)
                  .animation({ duration: 180, curve: Curve.EaseOut })
                  .clickEffect({ level: ClickEffectLevel.LIGHT })
                  .onClick(() => this.onChannelClick(cIndex))
                }
              }, (item: LiveChannelItem, cIndex: number) => this.browsingGroupIndex + '_' + cIndex + '_' + item.channelName)
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .divider({ strokeWidth: 0.5, color: Palette.border(this.isDark), startMargin: 8, endMargin: 8 })
            .edgeEffect(EdgeEffect.Spring)
          }
          .width(300)
          .height('100%')
          .backgroundColor(Palette.glass(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .border({ width: 1, color: Palette.glassBorder(this.isDark) })
          .borderRadius({ topRight: 20, bottomRight: 20 })
          .padding({ left: 8, right: 8, top: 56 + this.topSafe, bottom: 12 + this.bottomSafe })

          // 点击右侧空白区域收起频道列表
          Column()
            .layoutWeight(1)
            .height('100%')
            .backgroundColor('#01000000')
            .onClick(() => this.toggleChannelList())
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Top)
        .hitTestBehavior(HitTestMode.Default)
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: -60 })).animation({ duration: 260, curve: Curve.Friction }),
          TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: -60 })).animation({ duration: 200, curve: Curve.EaseIn })
        ))
      }

      // Top + bottom control bars (when controls visible)
      if (this.showControls) {
        Column() {
          // Top control bar: gradient #99000000 to transparent
          Row() {
            Row() {
              SymbolGlyph($r('sys.symbol.chevron_left'))
                .fontSize(24)
                .fontColor(['#FFFFFF'])
                .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            }
            .width(44)
            .height(44)
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => this.exitPlayback())

            Text('直播')
              .fontSize(18)
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Bold)
              .margin({ left: 8 })

            Blank()

            if (this.videoWidth > 0 && this.videoHeight > 0) {
              Text('[' + this.videoWidth + ' X ' + this.videoHeight + ']')
                .fontSize(12)
                .fontColor(Palette.accent())
                .margin({ right: 12 })
            }

            Text(this.netSpeed)
              .fontSize(13)
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
          }
          .width('100%')
          .height(56 + this.topSafe)
          .padding({ left: 12, right: 16, top: this.topSafe })
          .alignItems(VerticalAlign.Center)
          .linearGradient({
            direction: GradientDirection.Bottom,
            colors: [['#99000000', 0.0], ['#00000000', 1.0]]
          })

          Blank()

          // Bottom control bar: gradient #99000000 to transparent (bottom to top)
          Row() {
            // 播放键与 TV 点播播放器同款：52vp 圆形底 + PlayIconSet 图标
            Row() {
              Image(PlayIconSet.playPause(this.isPlaying))
                .width(28)
                .height(28)
                .fillColor('#FFFFFF')
                .objectFit(ImageFit.Contain)
                .draggable(false)
            }
            .width(52)
            .height(52)
            .borderRadius(26)
            .backgroundColor('#33FFFFFF')
            .justifyContent(FlexAlign.Center)
            .onClick(() => this.togglePlay())

            Row() {
              Image(PlayIconSet.RESTART)
                .width(24)
                .height(24)
                .fillColor('#FFFFFF')
                .objectFit(ImageFit.Contain)
                .draggable(false)
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .justifyContent(FlexAlign.Center)
            .onClick(() => this.playCurrentChannel())

            Text(this.channelName)
              .fontSize(15)
              .fontColor('#FFFFFF')
              .margin({ left: 12 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            Row() {
              Image(PlayIconSet.aspect(this.scaleModeIndex))
                .width(24)
                .height(24)
                .fillColor('#FFFFFF')
                .objectFit(ImageFit.Contain)
                .draggable(false)
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .backgroundColor('#66000000')
            .justifyContent(FlexAlign.Center)
            .margin({ right: 8 })
            .onClick(() => this.onScaleModeClick())

            // 选择线路按钮：图标化（同点播播放器外观），多线路时下方带「当前/总数」角标
            Column() {
              Image(PlayIconSet.TRACK)
                .width(24)
                .height(24)
                .fillColor(this.showLinePicker ? Palette.accent() : '#FFFFFF')
                .objectFit(ImageFit.Contain)
                .draggable(false)
              if (this.sourceNum > 1) {
                Text((this.sourceIndex + 1) + '/' + this.sourceNum)
                  .fontSize(9)
                  .fontColor(this.showLinePicker ? Palette.accent() : '#FFFFFF')
                  .maxLines(1)
                  .margin({ top: 1 })
              }
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .backgroundColor('#66000000')
            .justifyContent(FlexAlign.Center)
            .margin({ right: 8 })
            .onClick(() => {
              if (this.sourceNum <= 1) {
                promptAction.showToast({ message: '当前频道只有一条线路', duration: 1500 });
                return;
              }
              this.getUIContext()?.animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
                const willOpen = !this.showLinePicker;
                this.closeOtherPopups('line');
                this.showLinePicker = willOpen;
              });
              this.showControlsAutoHide();
            })

            Column() {
              Image(PlayIconSet.TIMER)
                .width(24)
                .height(24)
                .fillColor(this.showTimeoutPicker ? Palette.accent() : '#FFFFFF')
                .objectFit(ImageFit.Contain)
                .draggable(false)
              Text(this.timeoutEnabled ? this.timeoutSec + 's' : '关')
                .fontSize(9)
                .fontColor(this.showTimeoutPicker ? Palette.accent() : '#FFFFFF')
                .maxLines(1)
                .margin({ top: 1 })
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .backgroundColor('#66000000')
            .justifyContent(FlexAlign.Center)
            .margin({ right: 8 })
            .onClick(() => {
              this.getUIContext()?.animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
                const willOpen = !this.showTimeoutPicker;
                this.closeOtherPopups('timeout');
                this.showTimeoutPicker = willOpen;
              });
              this.showControlsAutoHide();
            })

            Row() {
              Image(PlayIconSet.SOURCE)
                .width(24)
                .height(24)
                .fillColor(this.showLiveSourceDialog ? Palette.accent() : '#FFFFFF')
                .objectFit(ImageFit.Contain)
                .draggable(false)
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .backgroundColor('#66000000')
            .justifyContent(FlexAlign.Center)
            .margin({ right: 8 })
            .onClick(() => {
              if (this.liveHistoryList.length === 0) {
                promptAction.showToast({ message: '暂无历史直播源，请在设置中添加', duration: 1800 });
                return;
              }
              this.getUIContext()?.animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
                const willOpen = !this.showLiveSourceDialog;
                this.closeOtherPopups('source');
                this.showLiveSourceDialog = willOpen;
              });
              this.showControlsAutoHide();
            })

            Row() {
              Image(PlayIconSet.LIST)
                .width(24)
                .height(24)
                .fillColor(this.showChannelList ? Palette.accent() : '#FFFFFF')
                .objectFit(ImageFit.Contain)
                .draggable(false)
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .backgroundColor('#66000000')
            .justifyContent(FlexAlign.Center)
            .margin({ right: 8 })
            .onClick(() => this.toggleChannelList())

            Row() {
              Image(PlayIconSet.PREV)
                .width(24)
                .height(24)
                .fillColor('#FFFFFF')
                .objectFit(ImageFit.Contain)
                .draggable(false)
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .justifyContent(FlexAlign.Center)
            .margin({ left: 8 })
            .onClick(() => this.prevChannel())

            Row() {
              Image(PlayIconSet.NEXT)
                .width(24)
                .height(24)
                .fillColor('#FFFFFF')
                .objectFit(ImageFit.Contain)
                .draggable(false)
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .justifyContent(FlexAlign.Center)
            .margin({ left: 8 })
            .onClick(() => this.nextChannel())

          }
          .width('100%')
          .height(52)
          .padding({ left: 16, right: 16 })
          .alignItems(VerticalAlign.Center)
          .linearGradient({
            direction: GradientDirection.Top,
            colors: [['#99000000', 0.0], ['#00000000', 1.0]]
          })
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .hitTestBehavior(HitTestMode.Transparent)
        .onTouch((e: TouchEvent): void => { if (e.type === TouchType.Down) { this.showControlsAutoHide(); } })
      }


      // 手势反馈 HUD（亮度/音量）- 与 PlayerPage 一致：仅文字，不显示图标
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

      // 选择线路悬浮弹框：从底部控制栏上方弹出，不遮掩画面也不隐藏播放器UI
      if (this.showLinePicker) {
        Column() {
          Column() {
            Text('选择线路')
              .fontSize(14)
              .fontColor(Palette.textSecondary(this.isDark))
              .fontWeight(FontWeight.Medium)
              .height(32)
              .textAlign(TextAlign.Center)
              .width('100%')
            List() {
              ForEach(this.getLineUrls(), (url: string, idx: number) => {
                ListItem() {
                  Row() {
                    SymbolGlyph($r(idx === this.sourceIndex ? 'sys.symbol.checkmark_circle_fill' : 'sys.symbol.circle'))
                      .fontSize(18)
                      .fontColor([idx === this.sourceIndex ? Palette.accent() : Palette.textSecondary(this.isDark)])
                      .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                      .margin({ right: 10 })
                    Text(this.getLineName(idx))
                      .fontSize(13)
                      .fontColor(idx === this.sourceIndex ? Palette.accent() : Palette.textPrimary(this.isDark))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                  .onClick(() => this.selectSource(idx))
                }
              }, (url: string, idx: number): string => 'lp_' + idx)
            }
            .width('100%')
            .scrollBar(BarState.Off)
            .divider({ strokeWidth: 0.5, color: Palette.border(this.isDark), startMargin: 12, endMargin: 12 })
            .constraintSize({ maxHeight: 220 })
            .edgeEffect(EdgeEffect.Spring)
          }
          .width(280)
          .backgroundColor(Palette.glass(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .border({ width: 1, color: Palette.glassBorder(this.isDark) })
          .borderRadius(12)
          .shadow({ radius: 16, color: '#40000000', offsetX: 0, offsetY: 4 })
          .padding({ top: 4, bottom: 6 })
          // 锚在底部控制栏正上方
          .margin({ bottom: 60 + this.bottomSafe, right: 100 })
          .onClick(() => {})
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.End)
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 16 })).animation({ duration: 220, curve: Curve.EaseOut }))
      }

      // 超时换线路悬浮弹框：从母菜单上方弹出，无遮罩，保留播放器UI
      if (this.showTimeoutPicker) {
        Column() {
          Column({ space: 8 }) {
            Text('超时换线路')
              .fontSize(14)
              .fontColor(Palette.textSecondary(this.isDark))
              .fontWeight(FontWeight.Medium)
              .height(32)
              .textAlign(TextAlign.Center)
              .width('100%')
            Row() {
              Text('启用超时换线路')
                .fontSize(13)
                .fontColor(Palette.textPrimary(this.isDark))
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.timeoutEnabled })
                .selectedColor(Palette.accent())
                .onChange((isOn: boolean): void => { this.setTimeoutEnabled(isOn); })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 2, bottom: 2 })
            .alignItems(VerticalAlign.Center)

            if (this.timeoutEnabled) {
              Row() {
                ForEach(LIVE_TIMEOUT_OPTIONS, (sec: number, index: number) => {
                  Text(sec + 's')
                    .fontSize(13)
                    .fontColor(sec === this.timeoutSec ? Palette.accent() : Palette.textSecondary(this.isDark))
                    .fontWeight(sec === this.timeoutSec ? FontWeight.Bold : FontWeight.Normal)
                    .backgroundColor(sec === this.timeoutSec ? (this.isDark ? '#33FFFFFF' : '#22000000') : (this.isDark ? '#22FFFFFF' : '#11000000'))
                    .borderRadius(6)
                    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                    .margin({ right: 4 })
                    .onClick(() => this.setTimeoutSec(sec))
                }, (sec: number, index: number): string => 'tp_' + sec)
              }
              .width('100%')
              .padding({ left: 12, right: 12, bottom: 8 })
              .justifyContent(FlexAlign.Center)
            }
          }
          .width(240)
          .backgroundColor(Palette.glass(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .border({ width: 1, color: Palette.glassBorder(this.isDark) })
          .borderRadius(12)
          .shadow({ radius: 16, color: '#40000000', offsetX: 0, offsetY: 4 })
          // 锚在底部控制栏正上方（超时按钮附近）
          .margin({ bottom: 60 + this.bottomSafe, right: 20 })
          .onClick(() => {})
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.End)
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 16 })).animation({ duration: 220, curve: Curve.EaseOut }))
      }

      // 切换直播源悬浮弹框：从底部控制栏正上方弹出，无遮罩，保留播放器 UI
      if (this.showLiveSourceDialog) {
        Column() {
          Column() {
            Text('切换直播源')
              .fontSize(14)
              .fontColor(Palette.textSecondary(this.isDark))
              .fontWeight(FontWeight.Medium)
              .height(32)
              .textAlign(TextAlign.Center)
              .width('100%')
            List() {
              ForEach(this.liveHistoryList, (url: string, index: number) => {
                ListItem() {
                  Row() {
                    SymbolGlyph($r(url === this.liveUrl ? 'sys.symbol.checkmark_circle_fill' : 'sys.symbol.circle'))
                      .fontSize(18)
                      .fontColor([url === this.liveUrl ? Palette.accent() : Palette.textSecondary(this.isDark)])
                      .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                      .margin({ right: 10 })
                    Text(url)
                      .fontSize(13)
                      .fontColor(url === this.liveUrl ? Palette.accent() : Palette.textPrimary(this.isDark))
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                  .onClick(() => { this.switchLiveSource(url); })
                }
              }, (url: string, index: number): string => 'lh_' + index + '_' + url)
            }
            .width('100%')
            .scrollBar(BarState.Off)
            .divider({ strokeWidth: 0.5, color: Palette.border(this.isDark), startMargin: 12, endMargin: 12 })
            .constraintSize({ maxHeight: 260 })
            .edgeEffect(EdgeEffect.Spring)
          }
          .width(320)
          .backgroundColor(Palette.glass(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
          .border({ width: 1, color: Palette.glassBorder(this.isDark) })
          .borderRadius(12)
          .shadow({ radius: 16, color: '#40000000', offsetX: 0, offsetY: 4 })
          .padding({ top: 4, bottom: 6 })
          // 锚在底部控制栏"直播源"按钮正上方
          .margin({ bottom: 60 + this.bottomSafe, right: 160 })
          .onClick(() => {})
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.End)
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 16 })).animation({ duration: 220, curve: Curve.EaseOut }))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
      }
}
