import { AbilityConstant, UIAbility, Want, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppTheme } from '../common/AppTheme';
import { PlayerPrefs } from '../model/PlayerPrefs';
// TV（TvBoxHarmony 移植）模块：偏好存储上下文注入
import { setPreferencesContext } from '../tvbox/utils/PreferencesUtil';
// 音乐内核（lxmusic-harmony 搬运）
import { PlaybackService } from '../lx/core/player/PlaybackService';
import { PlaySession } from '../lx/core/player/PlaySession';
import { LocalMusic } from '../lx/core/local/LocalMusic';
import { MediaCache } from '../lx/core/music/MediaCache';
import { AudioCache } from '../lx/core/music/AudioCache';
import { PlaySettings } from '../lx/core/settings/PlaySettings';
import { DownloadSettings } from '../lx/core/download/DownloadSettings';
import { DownloadManager } from '../lx/core/download/DownloadManager';

const TAG: string = 'EntryAbility';
const DOMAIN: number = 0x0001;

export default class EntryAbility extends UIAbility {
  private mainWin: window.Window | undefined = undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
    // TV 模块的 PreferencesUtil 需要在早期注入 context
    try {
      setPreferencesContext(this.context);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setPreferencesContext failed');
    }
    this.initMusicCore();
  }

  /** 音乐内核初始化：逐个安全初始化，任一失败只记日志，不阻断启动 */
  private initMusicCore(): void {
    const safe = (name: string, fn: () => void): void => {
      try {
        fn();
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'music core %{public}s init failed: %{public}s', name,
          (err as Error).message === undefined ? JSON.stringify(err) : (err as Error).message);
      }
    };
    safe('PlaybackService', () => { PlaybackService.getInstance().init(this.context); });
    safe('PlaySession', () => { PlaySession.getInstance().init(this.context); });
    safe('LocalMusic', () => { LocalMusic.getInstance().init(this.context); });
    safe('MediaCache', () => { MediaCache.getInstance().init(this.context); });
    safe('PlaySettings', () => { PlaySettings.getInstance().init(this.context); });
    safe('PlaySessionBootstrap', () => { PlaySession.getInstance().bootstrap(); });
    setTimeout(() => {
      safe('AudioCache', () => { AudioCache.getInstance().init(this.context); });
      // DownloadSettings 必须先于 DownloadManager：后者 init 里就要读「用户是否显式指定过位置」
      // 「ACL 是否已判定无望」「哪些 uri 已持久化」，设置还没 init 时读到的全是默认值，
      // 冷启动会白撞一次 ACL，用户显式选的位置也会被当成没指定。
      safe('DownloadSettings', () => { DownloadSettings.getInstance().init(this.context); });
      safe('DownloadManager', () => { DownloadManager.getInstance().init(this.context); });
    }, 0);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    try {
      PlaybackService.getInstance().close();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'PlaybackService close failed');
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 先按"全屏布局 + 自管安全区"配置窗口，避免系统重复避让导致首页上下出现大留白
    this.applyImmersiveLayout(windowStage);
    // 主题需在页面创建前定稿，否则首帧会用错颜色
    this.prepareTheme().then(() => {
      windowStage.loadContent('pages/Index', (err: BusinessError) => {
        if (err.code) {
          hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
          return;
        }
        hilog.info(DOMAIN, TAG, 'loadContent done');
      });
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
    try {
      PlaySession.getInstance().persistPlayState(true);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'persistPlayState failed');
    }
  }

  /** 跟随系统深浅色时，系统切换配置后同步刷新应用内主题 */
  onConfigurationUpdate(newConfig: Configuration): void {
    if (PlayerPrefs.getThemeMode() !== AppTheme.THEME_SYSTEM) {
      return;
    }
    const dark: boolean = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.applyThemeToWindow(dark);
  }

  private async prepareTheme(): Promise<void> {
    try {
      await PlayerPrefs.init(this.context);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'PlayerPrefs init failed');
    }
    const mode: string = PlayerPrefs.getThemeMode();
    let dark: boolean = true;
    if (mode === AppTheme.THEME_DARK) {
      dark = true;
    } else if (mode === AppTheme.THEME_LIGHT) {
      dark = false;
    } else {
      dark = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    this.applyThemeToWindow(dark);
  }

  private applyThemeToWindow(dark: boolean): void {
    AppStorage.setOrCreate('isDark', dark);
    // TV 页面使用 isDarkMode 作为主题标记，保持同步
    AppStorage.setOrCreate('isDarkMode', dark);
    try {
      if (this.mainWin !== undefined) {
        this.mainWin.setWindowBackgroundColor(dark ? AppTheme.DARK.bg : AppTheme.LIGHT.bg);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setWindowBackgroundColor failed');
    }
  }

  /** 全屏布局，并把状态栏/导航条占用的真实高度（vp）写入 AppStorage 供页面自行补偿 */
  private applyImmersiveLayout(windowStage: window.WindowStage): void {
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      this.mainWin = win;
      const density: number = display.getDefaultDisplaySync().densityPixels;
      // 全屏切换前先取一次系统避让区：setWindowLayoutFullScreen(true) 之后 TYPE_SYSTEM 常回 0，
      // 只取一次会得到 safeTop=0，顶栏文字顶到挖孔区（AGC 云测「挖孔区有文字重叠」）。
      const sysTopBefore: number = this.avoidHeight(win, window.AvoidAreaType.TYPE_SYSTEM, density);
      const cutoutTop: number = this.avoidHeight(win, window.AvoidAreaType.TYPE_CUTOUT, density);
      win.setWindowLayoutFullScreen(true);
      const sysTopAfter: number = this.avoidHeight(win, window.AvoidAreaType.TYPE_SYSTEM, density);
      // 取系统栏与挖孔区下沿的较大值，保证顶栏一定能避开摄像头挖孔
      const safeTop: number = Math.max(sysTopBefore, Math.max(sysTopAfter, cutoutTop), 24);
      const safeBottom: number = this.avoidHeight(win, window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR, density);
      AppStorage.setOrCreate('safeTop', safeTop);
      AppStorage.setOrCreate('safeBottom', safeBottom);
      hilog.info(DOMAIN, TAG, 'safe area top=%{public}d bottom=%{public}d', safeTop, safeBottom);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'applyImmersiveLayout failed code=%{public}d', e.code);
      AppStorage.setOrCreate('safeTop', 0);
      AppStorage.setOrCreate('safeBottom', 0);
    }
  }

  private avoidHeight(win: window.Window, type: window.AvoidAreaType, density: number): number {
    try {
      const area: window.AvoidArea = win.getWindowAvoidArea(type);
      const top: number = area.topRect.height;
      const bottom: number = area.bottomRect.height;
      const px: number = top > bottom ? top : bottom;
      if (px <= 0 || density <= 0) {
        return 0;
      }
      return Math.round(px / density);
    } catch (err) {
      return 0;
    }
  }
}
