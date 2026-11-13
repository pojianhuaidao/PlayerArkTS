import { promptAction, window, mediaquery, router } from '@kit.ArkUI';
import { common, ConfigurationConstant, bundleManager } from '@kit.AbilityKit';
import { AppTheme, Palette } from '../common/AppTheme';
import { PlayerPrefs, PlaylistHolder, ResumeEntry } from '../model/PlayerPrefs';
import { VideoItem } from '../model/VideoItem';
import { NetPrefs } from '../model/NetPrefs';
import { MusicSettingsView } from './MusicSettingsView';
import { SettingsPage as TvSettingsEmbed } from '../tvbox/pages/SettingsPage';
import { PlaySession } from '../lx/core/player/PlaySession';
import { CacheCleaner } from '../utils/CacheCleaner';

/** 设置页「文件夹」分区用的轻量条目 */
class FolderItem {
  name: string = '';
  uris: string[] = [];
  titles: string[] = [];
}

@Component
export struct SettingsPanel {
  @StorageProp('isDark') isDark: boolean = true;
  @StorageProp('safeTop') safeTop: number = 0;
  @StorageProp('safeBottom') safeBottom: number = 0;
  /** Index 页把当前文件夹分组写入此处，本页据以展示原「文件夹」能力 */
  @StorageProp('folderBrief') folderBrief: string = '[]';

  @State expandedFolder: string = '';
  /** 「外观」折叠组（深浅色 / 页签悬浮位置 / 自动回缩），与下面的设置组一致：默认不展开 */
  @State expandAppearance: boolean = false;
  /** 「视频设置」折叠组（解码 / 字幕 / 播放 / 默认播放速度 / 后台播放，本地与局域网共用） */
  @State expandVideo: boolean = false;
  /** 「音乐设置」折叠组（音源 / 播放 / 下载 / 本地扫描） */
  @State expandMusic: boolean = false;
  @State expandTv: boolean = false;
  @State musicScanOn: boolean = true;
  @State musicIgnoreShort: boolean = true;
  @State musicShowCover: boolean = true;
  @State musicAudioFocus: boolean = true;

  /** 「关于」分区展示的版本号，启动时从包信息读取，避免写死过期 */
  @State appVersion: string = '';

  @State gestureEnabled: boolean = true;
  @State autoPlayNext: boolean = true;
  @State backgroundPlay: boolean = false;
  @State defaultSpeed: number = 1.0;
  @State themeMode: string = AppTheme.THEME_SYSTEM;
  /** 页签胶囊停留秒数：0 = 常驻展开；通过 AppStorage 与 Index 单向属性实时联动 */
  @StorageLink('capsuleRetractSec') @Watch('onCapsuleRetractChange') capsuleRetractSec: number = 1;
  /** 页签胶囊落点：left / center / right，与 Index 双向联动 */
  @StorageLink('capsuleAlign') capsuleAlign: string = 'center';
  /** 滑杆拖动中标记：拖动过程只做实时预览，松手才落盘，避免频繁写偏好 */
  private draggingRetract: boolean = false;
  @State decodeMode: string = 'auto';
  @State subLang: string = 'zh-cn';
  @State subApiKey: string = '';
  @State isWide: boolean = false;
  @State localResume: number = 0;
  @State netResume: number = 0;
  /** 缓存占用大小的可读文案，进页面时算一次，清完再算一次 */
  @State cacheSize: string = '';
  /** 其中 TV / 网络播放缓存占用（单独展示，便于确认清理是否生效） */
  @State cacheTvSize: string = '';

  private wideListener: mediaquery.MediaQueryListener =
    mediaquery.matchMediaSync('(min-width: 600vp)');

  pal(): Palette {
    return AppTheme.palette(this.isDark);
  }

  aboutToAppear(): void {
    this.isWide = this.wideListener.matches;
    this.wideListener.on('change', (r: mediaquery.MediaQueryResult) => {
      this.isWide = r.matches;
    });
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersion = info.versionName;
    } catch (e) {
      this.appVersion = '';
    }
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    PlayerPrefs.init(context).then(() => {
      this.gestureEnabled = PlayerPrefs.isGestureEnabled();
      this.autoPlayNext = PlayerPrefs.isAutoPlayNext();
      this.backgroundPlay = PlayerPrefs.isBackgroundPlay();
      this.defaultSpeed = PlayerPrefs.getDefaultSpeed();
      this.themeMode = PlayerPrefs.getThemeMode();
      this.decodeMode = PlayerPrefs.getDecodeMode();
      this.subLang = PlayerPrefs.getSubtitleLang();
      this.subApiKey = PlayerPrefs.getSubtitleApiKey();
      this.refreshRecordCount();
      this.refreshCacheSize();
    });
  }

  aboutToDisappear(): void {
    this.wideListener.off('change');
  }

  /** 「关于」详情弹窗：版本信息与能力说明 */
  private showAboutDetail(): void {
    const ver: string = this.appVersion.length > 0 ? this.appVersion : '—';
    promptAction.showDialog({
      title: '关于',
      message: `多媒体 v${ver}\n本地视频 / 音乐 / 网络播放器，基于 HarmonyOS AVPlayer / AVCodec 实现视频播放、手势控制、字幕与音轨切换，并支持局域网目录与 WebDAV 浏览。`,
      buttons: [{ text: '确定', color: this.pal().primary }]
    });
  }

  /** 胶囊停留秒数变化：落盘，AppStorage 变更会由 Index 的 Watch 立即应用到悬浮胶囊 */
  onCapsuleRetractChange(): void {
    // 拖动滑杆时不落盘，等 SliderChangeMode.End 由 onChange 统一写入
    if (this.draggingRetract) {
      return;
    }
    PlayerPrefs.setCapsuleRetractSec(this.capsuleRetractSec);
  }

  /** 切换主题：立即写 AppStorage 触达所有页面，并同步窗口底色避免切换瞬间闪白/闪黑 */
  private applyTheme(mode: string): void {
    this.themeMode = mode;
    PlayerPrefs.setThemeMode(mode);
    let dark: boolean = this.isDark;
    if (mode === AppTheme.THEME_DARK) {
      dark = true;
    } else if (mode === AppTheme.THEME_LIGHT) {
      dark = false;
    } else {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      dark = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    AppStorage.setOrCreate('isDark', dark);
    // TV 模块页面用isDarkMode，同步写入保证 TV 整体跟随主界面深浅色
    AppStorage.setOrCreate('isDarkMode', dark);
    try {
      window.getLastWindow(getContext(this)).then((win: window.Window) => {
        win.setWindowBackgroundColor(dark ? AppTheme.DARK.bg : AppTheme.LIGHT.bg);
      }).catch(() => {
      });
    } catch (err) {
    }
  }

  /** 解析 Index 写入的文件夹分组 */
  private folderList(): FolderItem[] {
    const out: FolderItem[] = [];
    if (this.folderBrief.length === 0) {
      return out;
    }
    try {
      const arr: ESObject[] = JSON.parse(this.folderBrief) as ESObject[];
      for (let i = 0; i < arr.length; i++) {
        const rec: Record<string, ESObject> = arr[i] as Record<string, ESObject>;
        const f: FolderItem = new FolderItem();
        const name: ESObject = rec['name'];
        f.name = typeof name === 'string' ? name as string : '其他';
        const uris: ESObject = rec['uris'];
        if (uris !== undefined && Array.isArray(uris)) {
          f.uris = uris as string[];
        }
        const titles: ESObject = rec['titles'];
        if (titles !== undefined && Array.isArray(titles)) {
          f.titles = titles as string[];
        }
        if (f.uris.length > 0) {
          out.push(f);
        }
      }
    } catch (err) {
    }
    return out;
  }

  private toggleFolder(name: string): void {
    this.expandedFolder = this.expandedFolder === name ? '' : name;
  }

  private titleAt(f: FolderItem, i: number): string {
    if (i < f.titles.length && f.titles[i].length > 0) {
      return f.titles[i];
    }
    return f.uris[i];
  }

  /** 播放某文件夹里的第 index 个视频（播放列表即该文件夹） */
  private playFolder(f: FolderItem, index: number): void {
    const items: VideoItem[] = [];
    for (let i = 0; i < f.uris.length; i++) {
      items.push(new VideoItem(f.uris[i], this.titleAt(f, i), 0, 0, 0, 0, f.name, '', i));
    }
    if (items.length === 0) {
      return;
    }
    PlaylistHolder.set(items, index < 0 ? 0 : index);
    router.pushUrl({ url: 'pages/PlayerPage' }).catch(() => {
    });
  }

  private musicTip(): void {
    promptAction.showToast({ message: '音乐功能待完善，该设置将在上线后生效' });
  }

  /** 统计已记忆的播放进度条数（本地/网络分开） */
  private refreshRecordCount(): void {
    const list: ResumeEntry[] = PlayerPrefs.getResumeList();
    let local: number = 0;
    let net: number = 0;
    for (let i = 0; i < list.length; i++) {
      if (list[i].isNet) {
        net++;
      } else {
        local++;
      }
    }
    this.localResume = local;
    this.netResume = net;
  }

  /** 清除本地记录：本地视频播放位置 + 音频播放位置 */
  private confirmClearLocal(): void {
    promptAction.showDialog({
      title: '清除本地记录',
      message: '将清除本地视频的播放位置与音频播放位置，清除后不再从上次位置续播，操作不可恢复。',
      buttons: [
        { text: '取消', color: this.pal().textSecondary },
        { text: '清除', color: this.pal().danger }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        PlayerPrefs.clearResumeKind(false).then(() => {
          this.clearAudioProgress();
          this.refreshRecordCount();
          promptAction.showToast({ message: '本地记录已清除' });
        });
      }
    }).catch(() => {
    });
  }

  /** 清除网络进度：直连网输入的地址、WebDAV 地址与网络音视频播放进度 */
  private confirmClearNet(): void {
    promptAction.showDialog({
      title: '清除网络进度',
      message: '将清除直连网输入的地址、WebDAV 连接记录与网络音视频的播放进度，操作不可恢复。',
      buttons: [
        { text: '取消', color: this.pal().textSecondary },
        { text: '清除', color: this.pal().danger }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        PlayerPrefs.clearResumeKind(true).then(() => {
          NetPrefs.clearHistory().then(() => {
            this.refreshRecordCount();
            promptAction.showToast({ message: '网络进度已清空' });
          });
        });
      }
    }).catch(() => {
    });
  }

  /** 清掉音乐播放位置（队列与歌单保留）*/
  private clearAudioProgress(): void {
    try {
      PlaySession.getInstance().clearSavedProgress();
    } catch (err) {
    }
  }

  /** 统计当前音视频缓存占用（音乐流缓存 / 封面歌词缓存 / 字幕缓存 / 在线视频与本地视频缓冲 / 临时文件） */
  private refreshCacheSize(): void {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const bytes: number = CacheCleaner.measure(context);
      this.cacheSize = CacheCleaner.sizeText(bytes);
      this.cacheTvSize = CacheCleaner.sizeText(CacheCleaner.measureTv(context));
    } catch (err) {
      this.cacheSize = '';
      this.cacheTvSize = '';
    }
  }

  /** 清理在线视频缓存：只清 tv_cache 与在线流缓冲，不动本地视频、音乐与用户数据 */
  private confirmClearOnline(): void {
    const sizeText: string = this.cacheTvSize.length > 0 ? this.cacheTvSize : '0 B';
    promptAction.showDialog({
      title: '清理在线视频缓存',
      message: `将清理在线视频（含订阅/直链播放）的播放缓存与缓冲分片，当前占用 ${sizeText}。\n已导入的本地视频、本地音乐、已下载歌曲与音源脚本不受影响。清理时正在播放的在线视频会被停止以释放缓冲文件。`,
      buttons: [
        { text: '取消', color: this.pal().textSecondary },
        { text: '清理', color: this.pal().danger }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index !== 1) {
        return;
      }
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      CacheCleaner.clearOnline(context).then((freed: number) => {
        this.refreshCacheSize();
        promptAction.showToast({
          message: freed > 0 ? `已释放 ${CacheCleaner.sizeText(freed)} 空间` : '在线视频缓存已清理'
        });
      }).catch(() => {
        this.refreshCacheSize();
        promptAction.showToast({ message: '清理失败，请稍后重试' });
      });
    }).catch(() => {
    });
  }

  /** 清除缓存：二次确认后清空全部音视频缓存 */
  private confirmClearCache(): void {
    const sizeText: string = this.cacheSize.length > 0 ? this.cacheSize : '未知';
    promptAction.showDialog({
      title: '清除缓存',
      message: `将清空本软件的全部音视频缓存（当前 ${sizeText}，其中在线视频缓存 ${this.cacheTvSize.length > 0 ? this.cacheTvSize : '0 B'}）：音乐播放缓存、封面/歌词缓存、在线字幕缓存、在线视频缓存（filesDir/tv_cache 与 AVPlayer 缓冲）以及应用临时文件。\n已下载的歌曲、已导入的本地音乐、本地视频与音源脚本不受影响。清除时正在播放的视频会被停止以便释放缓冲文件，清理后会重新统计并提示释放容量。此操作不可恢复。`,
      buttons: [
        { text: '取消', color: this.pal().textSecondary },
        { text: '清除', color: this.pal().danger }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
        // clear() 会先广播释放播放器缓冲再删盘，异步完成后重新统计并回报释放容量
        CacheCleaner.clear(context).then((freed: number) => {
          this.refreshCacheSize();
          promptAction.showToast({
            message: freed > 0 ? `已释放 ${CacheCleaner.sizeText(freed)} 空间` : '缓存已清除'
          });
        }).catch(() => {
          this.refreshCacheSize();
          promptAction.showToast({ message: '缓存清理失败，请稍后重试' });
        });
      }
    }).catch(() => {
    });
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(12)
      .fontColor(this.pal().textTertiary)
      .width('100%')
      .padding({ left: AppTheme.pagePadding, top: 20, bottom: 8 })
  }

  /** 折叠组标题行：整行可点，右侧箭头指示展开状态（沿用在线视频设置的折叠观感） */
  @Builder
  foldHeader(title: string, desc: string, expanded: boolean, onTap: () => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(15)
          .fontColor(this.pal().textPrimary)
          .width('100%')
        Text(desc)
          .fontSize(12)
          .fontColor(this.pal().textSecondary)
          .margin({ top: 4 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 收起态才显示三角，尖朝下（提示「点开往下展开」）；展开后隐藏，再收起又出现
      if (!expanded) {
        Text('▾')
          .fontSize(14)
          .fontColor(this.pal().textSecondary)
          .margin({ left: 10 })
      }
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 14, bottom: 14 })
    .onClick(() => {
      onTap();
    })
  }

  build() {
    Column() {

      Scroll() {
        Column() {
          Column() {
            // ===== 外观：深浅色 + 页签悬浮位置 / 回缩，收进折叠组（与下方设置组一致，默认不展开） =====
            this.sectionTitle('外观')

            Column() {
              this.foldHeader('外观', '深浅色、页签悬浮位置与自动回缩', this.expandAppearance, () => {
                this.expandAppearance = !this.expandAppearance;
              })

              if (this.expandAppearance) {

            Row() {
              Column() {
                Text('深浅色')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text('跟随系统时，系统切换深色会自动同步')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 10 })

            Row() {
              this.themeChip('跟随系统', AppTheme.THEME_SYSTEM)
              this.themeChip('浅色', AppTheme.THEME_LIGHT)
              this.themeChip('深色', AppTheme.THEME_DARK)
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 12 })

            Divider().color(this.pal().divider).margin({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })

            // ===== 页签胶囊：停留时长与自动回缩 =====
            Row() {
              Column() {
                Text('页签悬浮')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text(this.capsuleRetractSec > 0
                  ? `停留 ${this.capsuleRetractSec} 秒后自动回缩为小圆点，点一下即展开，不挡画面`
                  : '常驻展开，不自动回缩')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Text(this.capsuleRetractSec > 0 ? `${this.capsuleRetractSec} 秒` : '常驻')
                .fontSize(13)
                .fontColor(this.pal().primary)
                .margin({ left: 10 })
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 12, bottom: 4 })

            Slider({
              value: this.capsuleRetractSec,
              min: 0,
              max: 60,
              step: 1,
              style: SliderStyle.OutSet
            })
              .width('100%')
              .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })
              .selectedColor(this.pal().primary)
              .blockColor(this.pal().primary)
              .trackColor(this.pal().divider)
              .onChange((value: number, mode: SliderChangeMode) => {
                // Begin/Moving 只写运行时状态（AppStorage 实时预览），End/Click 才落盘
                this.draggingRetract = mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving;
                this.capsuleRetractSec = Math.round(value);
                if (!this.draggingRetract) {
                  PlayerPrefs.setCapsuleRetractSec(this.capsuleRetractSec);
                }
              })

            Row() {
              this.retractChip('常驻', 0)
              this.retractChip('1 秒', 1)
              this.retractChip('3 秒', 3)
              this.retractChip('5 秒', 5)
              this.retractChip('10 秒', 10)
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 6, bottom: 12 })

            // 回缩落点：靠左 / 居中 / 靠右
            Row() {
              Column() {
                Text('页签悬浮位置')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text('回缩成小圆点后，停靠在屏幕的哪个位置')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 2, bottom: 8 })

            Row() {
              this.alignChip('靠左', 'left')
              this.alignChip('居中', 'center')
              this.alignChip('靠右', 'right')
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 12 })

            Divider().color(this.pal().divider).margin({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })

              }
            }
            .width('100%')

            // ===== 视频设置：解码 / 字幕 / 播放 / 默认播放速度 / 后台播放，同时作用于本地与局域网视频 =====
            this.sectionTitle('视频设置')

            Column() {
              this.foldHeader('视频设置', '解码、字幕、播放速度、后台播放，本地与局域网视频通用', this.expandVideo, () => {
                this.expandVideo = !this.expandVideo;
              })

              if (this.expandVideo) {
                // ===== 解码 =====
                this.sectionTitle('解码')

            Row() {
              Column() {
                Text('解码方式')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text('自动：交给系统（一般走硬解）；强制硬解：失败即报错；强制软解：自建 AVCodec 管线，兼容性优先但更耗电')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 10 })

            Row() {
              this.decodeChip('自动', 'auto')
              this.decodeChip('强制硬解', 'hw')
              this.decodeChip('强制软解', 'sw')
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 12 })

            Text('软解为实验性功能：部分机型/编码下可能初始化失败，播放页会自动回退硬解并提示。')
              .fontSize(11)
              .fontColor(this.pal().textTertiary)
              .width('100%')
              .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 8 })

            Divider().color(this.pal().divider).margin({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })

            // ===== 字幕 =====
            this.sectionTitle('字幕')

            Row() {
              Column() {
                Text('免Key 字幕源（开箱即用）')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text('内置 射手网（伪）assrt.net 与 SubtitleCat，播放页字幕菜单里直接搜索下载，无需注册')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 4 })

            Row() {
              Column() {
                Text('搜索语言')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text('在线搜索时优先过滤该语言')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 10 })

            Row() {
              this.langChip('简体中文', 'zh-cn')
              this.langChip('繁體中文', 'zh-tw')
              this.langChip('English', 'en')
              this.langChip('日本語', 'ja')
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 12 })

            Row() {
              Column() {
                Text('OpenSubtitles Api-Key')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text('opensubtitles.com 免费注册后生成，仅保存在本机')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 8 })

            Row() {
              TextInput({ text: this.subApiKey, placeholder: '粘贴 Api-Key' })
                .type(InputType.Password)
                .fontSize(13)
                .fontColor(this.pal().textPrimary)
                .placeholderColor(this.pal().textTertiary)
                .backgroundColor(this.pal().bgChip)
                .height(40)
                .layoutWeight(1)
                .onChange((v: string) => {
                  this.subApiKey = v;
                })
                .onSubmit(() => {
                  PlayerPrefs.setSubtitleApiKey(this.subApiKey.trim());
                  promptAction.showToast({ message: '已保存 Api-Key' });
                })
              Text('保存')
                .fontSize(13)
                .fontColor(Color.White)
                .backgroundColor(this.pal().primary)
                .borderRadius(14)
                .height(30)
                .padding({ left: 14, right: 14 })
                .margin({ left: 8 })
                .onClick(() => {
                  PlayerPrefs.setSubtitleApiKey(this.subApiKey.trim());
                  promptAction.showToast({ message: '已保存 Api-Key' });
                })
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 12 })

            Divider().color(this.pal().divider).margin({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })

            // ===== 播放 =====
            this.sectionTitle('播放')

            Row() {
              Column() {
                Text('手势控制')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text('左滑右滑调进度，上下滑调音量/亮度，双击暂停，长按倍速')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.gestureEnabled })
                .selectedColor(this.pal().primary)
                .onChange((isOn: boolean) => {
                  this.gestureEnabled = isOn;
                  PlayerPrefs.setGestureEnabled(isOn);
                })
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 12, bottom: 12 })

            Divider().color(this.pal().divider).margin({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })

            Row() {
              Text('播完自动播放下一个')
                .fontSize(15)
                .fontColor(this.pal().textPrimary)
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.autoPlayNext })
                .selectedColor(this.pal().primary)
                .onChange((isOn: boolean) => {
                  this.autoPlayNext = isOn;
                  PlayerPrefs.setAutoPlayNext(isOn);
                })
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 12, bottom: 12 })

            Divider().color(this.pal().divider).margin({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })

            Row() {
              Column() {
                Text('后台播放')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text('离开播放页时不自动暂停')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.backgroundPlay })
                .selectedColor(this.pal().primary)
                .onChange((isOn: boolean) => {
                  this.backgroundPlay = isOn;
                  PlayerPrefs.setBackgroundPlay(isOn);
                })
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 12, bottom: 12 })

            this.sectionTitle('默认播放速度')

            Row() {
              ForEach([0.75, 1.0, 1.25, 1.5, 2.0], (s: number) => {
                Text(`${s.toFixed(2)}x`)
                  .fontSize(13)
                  .fontColor(this.defaultSpeed === s ? Color.White : this.pal().textSecondary)
                  .backgroundColor(this.defaultSpeed === s ? this.pal().primary : this.pal().bgChip)
                  .borderRadius(14)
                  .height(28)
                  .padding({ left: 12, right: 12 })
                  .margin({ right: 8 })
                  .textAlign(TextAlign.Center)
                  .onClick(() => {
                    this.defaultSpeed = s;
                    PlayerPrefs.setDefaultSpeed(s);
                  })
              }, (s: number) => `speed_${s}`)
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })

            this.sectionTitle('文件夹')

            if (this.folderList().length === 0) {
              Text('暂无视频文件夹，先在「视频」页添加视频后在此按文件夹浏览')
                .fontSize(12)
                .fontColor(this.pal().textTertiary)
                .width('100%')
                .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 6, bottom: 10 })
            } else {
              Column() {
                ForEach(this.folderList(), (g: FolderItem) => {
                  Column() {
                    Row() {
                      Text(this.expandedFolder === g.name ? '▾' : '▸')
                        .fontSize(12)
                        .fontColor(this.pal().textTertiary)
                        .width(20)
                      Text(g.name)
                        .fontSize(15)
                        .fontColor(this.pal().textPrimary)
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(`${g.uris.length} 个`)
                        .fontSize(12)
                        .fontColor(this.pal().textSecondary)
                    }
                    .width('100%')
                    .height(44)
                    .onClick(() => {
                      this.toggleFolder(g.name);
                    })

                    if (this.expandedFolder === g.name) {
                      ForEach(g.uris, (uri: string) => {
                        Row() {
                          Text('🎬')
                            .fontSize(13)
                            .width(20)
                          Text(this.titleAt(g, g.uris.indexOf(uri)))
                            .fontSize(13)
                            .fontColor(this.pal().textSecondary)
                            .layoutWeight(1)
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                        }
                        .width('100%')
                        .height(38)
                        .padding({ left: 20 })
                        .onClick(() => {
                          this.playFolder(g, g.uris.indexOf(uri));
                        })
                      }, (uri: string) => `sv_${g.name}_${uri}`)
                    }
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }, (g: FolderItem) => `sf_${g.name}`)
              }
              .width('100%')
              .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })
            }

              }
            }
            .width('100%')
            .backgroundColor(this.pal().bgCard)
            .borderRadius(AppTheme.radius)
            .clip(true)

            // ===== 音乐设置：折叠组（本地音乐 / 音源 / 播放 / 下载，去掉云同步与账号） =====
            this.sectionTitle('音乐设置')

            Column() {
              this.foldHeader('音乐设置', '本地音乐、音源、播放、下载', this.expandMusic, () => {
                this.expandMusic = !this.expandMusic;
              })

              if (this.expandMusic) {
                Column() {
                  MusicSettingsView()
                }
                .width('100%')
                .clip(true)
              }
            }
            .width('100%')
            .backgroundColor(this.pal().bgCard)
            .borderRadius(AppTheme.radius)
            .clip(true)
            .margin({ bottom: 10 })

            // ===== 在线视频设置：与视频设置 / 音乐设置一致，点击标题就地向下展开 =====
            this.sectionTitle('在线视频设置')

            Column() {
              this.foldHeader('在线视频设置', '数据 / 直播 / 解析等设置', this.expandTv, () => {
                this.expandTv = !this.expandTv;
              })

              if (this.expandTv) {
                Column() {
                  TvSettingsEmbed({ embedded: true })
                }
                .width('100%')
                .clip(true)
              }
            }
            .width('100%')
            .backgroundColor(this.pal().bgCard)
            .borderRadius(AppTheme.radius)
            .clip(true)
            .margin({ bottom: 10 })

            Divider().color(this.pal().divider).margin({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })

            this.sectionTitle('记忆')

            Row() {
              Column() {
                Text(`本地 ${this.localResume} 条 · 网络 ${this.netResume} 条`)
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text('播放时自动记录位置，再次打开自动续播')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
                Text(this.cacheSize.length > 0
                  ? `音视频缓存 ${this.cacheSize}（含本地及在线视频缓存 ${this.cacheTvSize.length > 0 ? this.cacheTvSize : '0 B'}）`
                  : '音视频缓存统计中…')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 12, bottom: 10 })

            // 四个按钮用 Flex 换行排布：窄屏（手机 / 车机竖屏）自动折行，避免「清理在线视频缓存」被截断
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Center }) {
              Button('清除本地记录')
                .fontSize(13)
                .height(34)
                .backgroundColor(this.pal().bgChip)
                .fontColor(this.pal().textPrimary)
                .margin({ right: 10, bottom: 8 })
                .onClick(() => {
                  this.confirmClearLocal();
                })
              Button('清除网络进度')
                .fontSize(13)
                .height(34)
                .backgroundColor(this.pal().bgChip)
                .fontColor(this.pal().textPrimary)
                .margin({ right: 10, bottom: 8 })
                .onClick(() => {
                  this.confirmClearNet();
                })
              Button('清理在线视频缓存')
                .fontSize(13)
                .height(34)
                .backgroundColor(this.pal().bgChip)
                .fontColor(this.pal().textPrimary)
                .margin({ right: 10, bottom: 8 })
                .onClick(() => {
                  this.confirmClearOnline();
                })
              Button('清除缓存')
                .fontSize(13)
                .height(34)
                .backgroundColor(this.pal().bgChip)
                .fontColor(this.pal().danger)
                .margin({ right: 10, bottom: 8 })
                .onClick(() => {
                  this.confirmClearCache();
                })
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 4 })

            Divider().color(this.pal().divider).margin({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })

            this.sectionTitle('关于')

            Row() {
              Column() {
                Text('多媒体')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text(`版本 ${this.appVersion.length > 0 ? this.appVersion : '—'} · HarmonyOS ArkTS 实现`)
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Text('详情')
                .fontSize(13)
                .fontColor(this.pal().primary)
                .onClick(() => {
                  this.showAboutDetail();
                })
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 12, bottom: 32 })

          }
          .width('100%')
          .constraintSize({ maxWidth: this.isWide ? 720 : AppTheme.contentMaxWidth })
        }
        .width('100%')
        .padding({ bottom: 104 + this.safeBottom })
        .alignItems(HorizontalAlign.Center)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pal().bg)
  }

  @Builder
  switchRow(title: string, desc: string, on: boolean, onChange: (v: boolean) => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(15)
          .fontColor(this.pal().textPrimary)
          .width('100%')
        Text(desc)
          .fontSize(12)
          .fontColor(this.pal().textSecondary)
          .margin({ top: 3 })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: on })
        .selectedColor(this.pal().primary)
        .onChange((v: boolean) => {
          onChange(v);
        })
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 8 })
  }

  @Builder
  themeChip(label: string, value: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.themeMode === value ? Color.White : this.pal().textSecondary)
      .backgroundColor(this.themeMode === value ? this.pal().primary : this.pal().bgChip)
      .borderRadius(14)
      .height(30)
      .padding({ left: 14, right: 14 })
      .margin({ right: 8 })
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.applyTheme(value);
      })
  }

  @Builder
  retractChip(label: string, sec: number) {
    Text(label)
      .fontSize(13)
      .fontColor(this.capsuleRetractSec === sec ? Color.White : this.pal().textSecondary)
      .backgroundColor(this.capsuleRetractSec === sec ? this.pal().primary : this.pal().bgChip)
      .borderRadius(14)
      .height(30)
      .padding({ left: 14, right: 14 })
      .margin({ right: 8 })
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.capsuleRetractSec = sec;
      })
  }

  @Builder
  alignChip(label: string, value: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.capsuleAlign === value ? Color.White : this.pal().textSecondary)
      .backgroundColor(this.capsuleAlign === value ? this.pal().primary : this.pal().bgChip)
      .borderRadius(14)
      .height(30)
      .padding({ left: 14, right: 14 })
      .margin({ right: 8 })
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.capsuleAlign = value;
        PlayerPrefs.setCapsuleAlign(value);
      })
  }

  @Builder
  decodeChip(label: string, value: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.decodeMode === value ? Color.White : this.pal().textSecondary)
      .backgroundColor(this.decodeMode === value ? this.pal().primary : this.pal().bgChip)
      .borderRadius(14)
      .height(30)
      .padding({ left: 14, right: 14 })
      .margin({ right: 8 })
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.decodeMode = value;
        PlayerPrefs.setDecodeMode(value);
      })
  }

  @Builder
  langChip(label: string, value: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.subLang === value ? Color.White : this.pal().textSecondary)
      .backgroundColor(this.subLang === value ? this.pal().primary : this.pal().bgChip)
      .borderRadius(14)
      .height(30)
      .padding({ left: 12, right: 12 })
      .margin({ right: 8 })
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.subLang = value;
        PlayerPrefs.setSubtitleLang(value);
      })
  }
}
