import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import { AppTheme, Palette } from '../common/AppTheme';
import { PlayIconSet } from '../common/PlayIconSet';
import { SourceEngine } from '../lx/core/source/SourceEngine';
import { SourceInfo } from '../lx/core/source/LxTypes';
import { MAX_SCRIPT_SIZE } from '../lx/core/source/LxMetadata';
import {
  PlaySettings,
  PLAYER_DOCK_DEFAULT,
  PLAYER_DOCKS,
  PLAYER_DOCK_LABELS
} from '../lx/core/settings/PlaySettings';
import { DownloadSettings, NAME_FORMATS, NAME_FORMAT_LABELS } from '../lx/core/download/DownloadSettings';
import { DownloadManager, SaveLocationInfo, RemoveOutcome, DownloadItem } from '../lx/core/download/DownloadManager';
import { LocalMusic, ImportResult } from '../lx/core/local/LocalMusic';
import { PlaySession, SongItem } from '../lx/core/player/PlaySession';

const DOMAIN: number = 0x0001;
const TAG: string = 'MusicSettings';

/** 播放音质候选（与内核取链逻辑一致） */
const QUALITYS: string[] = ['128k', '320k', 'flac', 'flac24bit'];
const QUALITY_LABELS: string[] = ['标准', '较高', '无损', 'Hi-Res'];
const LYRIC_SIZES: number[] = [15, 17, 19, 21, 23];

function fileNameOf(uri: string): string {
  const cut: number = uri.lastIndexOf('/');
  return cut >= 0 ? uri.substring(cut + 1) : uri;
}

/** 读源脚本正文（picker 给的是 file://docs/... 的 uri，openSync 可直接打开） */
function readScriptText(uri: string): string {
  let file: fs.File | null = null;
  try {
    file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const stat: fs.Stat = fs.statSync(file.fd);
    if (stat.size <= 0) {
      return '';
    }
    if (stat.size > MAX_SCRIPT_SIZE) {
      throw new Error(`脚本超过大小上限（${Math.round(MAX_SCRIPT_SIZE / 1024)}KB）`);
    }
    const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
    fs.readSync(file.fd, buffer);
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(buffer));
  } finally {
    if (file !== null) {
      fs.closeSync(file);
    }
  }
}

function formatBytes(bytes: number): string {
  if (bytes <= 0) {
    return '0 B';
  }
  const units: string[] = ['B', 'KB', 'MB', 'GB'];
  let value: number = bytes;
  let unit: number = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value = value / 1024;
    unit++;
  }
  return `${value.toFixed(unit === 0 ? 0 : 1)} ${units[unit]}`;
}

/**
 * 音乐设置面板：本地音乐 / 音源设置 / 播放设置 / 下载设置。
 *
 * 直接复用内核（lxmusic-harmony）的设置单例（SourceEngine、PlaySettings、
 * DownloadSettings、LocalMusic），不再保留云同步、华为账号、显示设置 ——
 * 外观统一跟随播放器整体深浅色。
 */
@Component
export struct MusicSettingsView {
  @StorageProp('isDark') isDark: boolean = true;
  @StorageProp('local_version') localVersion: number = 0;
  @StorageProp('local_progress') localProgress: string = '';
  @StorageProp('ps_current_name') curName: string = '';

  @State sources: SourceInfo[] = [];
  @State curSourceId: string = '';
  @State sandboxStatus: string = '';
  @State busy: boolean = false;
  @State urlInput: string = '';

  @State quality: string = '320k';
  @State extendQuality: boolean = false;
  @State playWithOthers: boolean = false;
  @State showMiniLyric: boolean = true;
  /**
   * 播放控件悬浮位置。
   *
   * 这里必须用本组件自己的 @State：早前用 @StorageProp(K_PLAYER_DOCK) 时，
   * chip 选中态由「单向绑定 + 本地赋值」驱动，本地赋值会与 AppStorage 同源关系
   * 打架，表现是切一次档位后，后续档位点了高亮不再刷新。现在改为：
   * 页面以自身 @State 为准渲染高亮，点击同时写回 PlaySettings（由它推 AppStorage
   * 给音乐页用），两条链路互不干扰。
   */
  @State playerDock: string = PLAYER_DOCK_DEFAULT;
  @State lyricBlur: boolean = true;
  @State lyricCentered: boolean = true;
  @State lyricKeepScreen: boolean = false;
  @State lyricFont: number = 19;
  @State autoMatchLyric: boolean = true;
  @State autoResume: boolean = true;

  @State nameFormat: string = 'song';
  @State markQuality: boolean = true;
  /**
   * 下一次下载会落到哪（应用沙箱 files/Download 的物理路径）
   *
   * 1.1111.06 起位置不可选，只有这一处，所以不再需要「来源 / 是否用户指定 /
   * 上次实际落哪 / 目录告警」这一串状态 —— 它们都是为公共「下载」目录那条已拆除的
   * 链路服务的。
   */
  @State savePath: string = '';
  /** 正在导出 / 分享（避免连点，导出对话框重入会拿到两个选择器） */
  @State exporting: boolean = false;
  /** 下载记录总条数 / 其中已完成或失败、可清理的条数 */
  @State downloadCount: number = 0;
  @State downloadFinished: number = 0;
  /** 上一次清理的结果汇总（有文件删不掉时把原因留在页面上，不随 toast 消失） */
  @State downloadNotice: string = '';

  @State localCount: number = 0;
  @State localBytes: number = 0;
  @State localOpen: boolean = false;
  @State localSongs: SongItem[] = [];
  @State importing: boolean = false;

  aboutToAppear(): void {
    this.refreshSource();
    this.refreshPlay();
    this.refreshDownload();
    this.refreshDownloadRecords();
    this.refreshLocal();
  }

  pal(): Palette {
    return AppTheme.palette(this.isDark);
  }

  private ctx(): common.UIAbilityContext | null {
    try {
      return this.getUIContext().getHostContext() as common.UIAbilityContext;
    } catch (e) {
      return null;
    }
  }

  // ------------------------------------------------------------ 刷新

  private refreshSource(): void {
    try {
      const engine: SourceEngine = SourceEngine.getInstance();
      this.sources = engine.listSources();
      this.curSourceId = engine.getLoadedSourceId();
      this.sandboxStatus = engine.getStatus();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'refresh source failed: %{public}s', JSON.stringify(e));
    }
  }

  private refreshPlay(): void {
    try {
      const s: PlaySettings = PlaySettings.getInstance();
      this.quality = s.getQuality();
      this.extendQuality = s.isExtendQuality();
      this.playWithOthers = s.isPlayWithOthers();
      this.showMiniLyric = s.isShowMiniLyric();
      this.playerDock = s.getPlayerDock();
      this.lyricBlur = s.isLyricBlur();
      this.lyricCentered = s.isLyricCentered();
      this.lyricKeepScreen = s.isLyricKeepScreenOn();
      this.lyricFont = s.getLyricFontSize();
      this.autoMatchLyric = s.getAutoMatchLyric();
      this.autoResume = s.isAutoResumeAfterInterrupt();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'refresh play settings failed: %{public}s', JSON.stringify(e));
    }
  }

  private refreshDownload(): void {
    try {
      const s: DownloadSettings = DownloadSettings.getInstance();
      this.nameFormat = s.getNameFormat();
      this.markQuality = s.isMarkQuality();
      // 下一首歌会落在哪：由 DownloadManager 用 context.filesDir 拼出来（应用沙箱
      // files/Download），全应用只有一个位置，这里只负责显示
      const loc: SaveLocationInfo = DownloadManager.getInstance().saveLocation();
      this.savePath = loc.path;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'refresh download settings failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 导出最近一首下载完成的歌到系统文件（用户自己挑位置）
   *
   * 为什么需要它：音乐只落在应用沙箱（files/Download），本应用能直接播放，但
   * 「文件管理」/ 电脑/ 其它应用看不到。要给出去就走系统保存对话框 —— 用户选目录、
   * 系统给一次性授权，**不需要任何权限**，也不用 persistPermission 长期记住，
   * 所以不会像公共「下载」目录那样触发 ACL 一致性校验。
   */
  private async exportLatest(): Promise<void> {
    if (this.exporting) {
      return;
    }
    this.exporting = true;
    try {
      const message: string = await DownloadManager.getInstance().exportLatest();
      this.toast(message);
    } catch (e) {
      const error: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'export failed: %{public}s', JSON.stringify(e));
      this.toast(`导出失败：${error.message}（错误码 ${error.code}）`);
    } finally {
      this.exporting = false;
    }
  }

  /** 把最近一首下载完成的歌交给系统分享面板（微信 / 蓝牙 / 其它播放器） */
  private async shareLatest(): Promise<void> {
    if (this.exporting) {
      return;
    }
    this.exporting = true;
    try {
      const message: string = await DownloadManager.getInstance().shareLatest();
      this.toast(message);
    } catch (e) {
      const error: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'share failed: %{public}s', JSON.stringify(e));
      this.toast(`分享失败：${error.message}（错误码 ${error.code}）`);
    } finally {
      this.exporting = false;
    }
  }

  /** 刷新下载记录条数（列表视图 / 设置页共用一套口径） */
  private refreshDownloadRecords(): void {
    try {
      const dm: DownloadManager = DownloadManager.getInstance();
      this.downloadCount = dm.count();
      let finished: number = 0;
      for (const item of dm.list()) {
        if (item.status === 'done' || item.status === 'error') {
          finished++;
        }
      }
      this.downloadFinished = finished;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'refresh download records failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 清空已完成 / 失败的下载记录
   *
   * 删不掉的文件**不会**从列表里悄悄消失：内核把它们留在列表里并写明原因，
   * 这里把汇总消息同时落到页面上的 downloadNotice（常驻）和 toast（即时）——
   * 早期这里是 unlinkQuietly，删失败就当没发生过，结果是歌没了、文件还占着空间，
   * 用户在界面上完全无从下手。
   */
  private clearFinishedRecords(): void {
    try {
      const outcome: RemoveOutcome = DownloadManager.getInstance().clearFinished();
      this.refreshDownloadRecords();
      if (outcome.failed > 0) {
        this.downloadNotice = outcome.message;
        this.toast(outcome.message);
        return;
      }
      this.downloadNotice = '';
      this.toast(outcome.removed > 0 ? `已清理 ${outcome.removed} 条下载记录` : '没有可清理的下载记录');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'clear finished downloads failed: %{public}s', JSON.stringify(e));
      this.toast(`清理失败：${(e as BusinessError).message}`);
    }
  }

  private refreshLocal(): void {
    try {
      const lm: LocalMusic = LocalMusic.getInstance();
      this.localCount = lm.count();
      this.localBytes = lm.totalBytes();
      if (this.localOpen) {
        this.localSongs = lm.songsForUi();
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'refresh local music failed: %{public}s', JSON.stringify(e));
    }
  }

  private toast(message: string): void {
    promptAction.showToast({ message: message });
  }

  // ------------------------------------------------------------ 本地音乐

  /** 扫描本地音乐：拉起文件管理的音频聚合视图，选中后交给内核的 LocalMusic 导入 */
  private scanLocalMusic(): void {
    if (this.importing) {
      return;
    }
    const context: common.UIAbilityContext | null = this.ctx();
    if (context === null) {
      this.toast('当前环境不支持选择文件');
      return;
    }
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.mergeMode = picker.MergeTypeMode.AUDIO;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      documentPicker.select(options)
        .then((uris: string[]) => {
          void this.runLocalImport(uris);
        })
        .catch((err: BusinessError) => {
          hilog.info(DOMAIN, TAG, 'scan audio ended: %{public}s', err.message);
        });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'open audio picker failed: %{public}s', JSON.stringify(e));
      this.toast('打不开文件管理的音频视图');
    }
  }

  private async runLocalImport(uris: string[]): Promise<void> {
    if (uris.length === 0) {
      return;
    }
    this.importing = true;
    try {
      const result: ImportResult = await LocalMusic.getInstance().importUris(uris);
      this.toast(`导入完成：新增 ${result.added} 首，跳过 ${result.skipped}，不支持 ${result.unsupported}，失败 ${result.failed}`);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'local import failed: %{public}s', JSON.stringify(e));
      this.toast('导入失败，请重试');
    } finally {
      this.importing = false;
      this.refreshLocal();
      if (this.localOpen) {
        this.localSongs = LocalMusic.getInstance().songsForUi();
      }
    }
  }

  private confirmClearLocal(): void {
    this.getUIContext().showAlertDialog({
      title: '清空本地音乐库',
      message: '只清掉导入记录的索引，不会删除设备上的原始音频文件。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: this.pal().danger,
        action: () => {
          LocalMusic.getInstance().clear();
          this.refreshLocal();
          this.localSongs = [];
          this.toast('已清空本地音乐库');
        }
      }
    });
  }

  private playLocal(index: number): void {
    if (this.localSongs.length === 0) {
      return;
    }
    PlaySession.getInstance().setQueueAndPlay(this.localSongs, index);
  }

  // ------------------------------------------------------------ 音源

  private pickSourceFile(): void {
    if (this.busy) {
      return;
    }
    const context: common.UIAbilityContext | null = this.ctx();
    if (context === null) {
      this.toast('当前环境不支持选择文件');
      return;
    }
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 20;
      options.fileSuffixFilters = ['音源脚本 (.js)|.js'];
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      documentPicker.select(options)
        .then((uris: string[]) => {
          void this.importSourceFiles(uris);
        })
        .catch((err: BusinessError) => {
          hilog.info(DOMAIN, TAG, 'pick source ended: %{public}s', err.message);
        });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'open source picker failed: %{public}s', JSON.stringify(e));
      this.toast('打不开文件选择器');
    }
  }

  private async importSourceFiles(uris: string[]): Promise<void> {
    if (uris.length === 0 || this.busy) {
      return;
    }
    this.busy = true;
    const okNames: string[] = [];
    const fails: string[] = [];
    for (let i = 0; i < uris.length; i++) {
      const name: string = fileNameOf(uris[i]);
      try {
        const text: string = readScriptText(uris[i]);
        if (text.trim().length === 0) {
          fails.push(`「${name}」是空文件`);
          continue;
        }
        const info: SourceInfo = SourceEngine.getInstance().importSource(text);
        okNames.push(info.name);
        await SourceEngine.getInstance().loadSource(info.id);
      } catch (e) {
        fails.push(`「${name}」：${(e as Error).message}`);
      }
    }
    this.busy = false;
    this.refreshSource();
    this.toast(okNames.length > 0
      ? `已导入 ${okNames.length} 个音源${fails.length > 0 ? `，${fails.length} 个失败` : ''}`
      : `导入失败：${fails.length > 0 ? fails[0] : '未知原因'}`);
  }

  private async importFromUrl(): Promise<void> {
    const url: string = this.urlInput.trim();
    if (url.length === 0 || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const info: SourceInfo = await SourceEngine.getInstance().importFromUrl(url);
      this.urlInput = '';
      await SourceEngine.getInstance().loadSource(info.id);
      this.toast(`已导入「${info.name}」`);
    } catch (e) {
      this.toast(`导入失败：${(e as Error).message}`);
    }
    this.busy = false;
    this.refreshSource();
  }

  private async loadSource(id: string): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await SourceEngine.getInstance().loadSource(id);
      this.toast('音源已启用');
    } catch (e) {
      this.toast(`启用失败：${(e as Error).message}`);
    }
    this.busy = false;
    this.refreshSource();
  }

  private confirmRemoveSource(info: SourceInfo): void {
    this.getUIContext().showAlertDialog({
      title: '删除音源',
      message: `将从本机移除「${info.name}」，脚本文件不再保留。`,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: this.pal().danger,
        action: () => {
          SourceEngine.getInstance().removeSource(info.id);
          this.refreshSource();
        }
      }
    });
  }

  // ------------------------------------------------------------ UI

  @Builder
  subTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.pal().textSecondary)
      .width('100%')
      .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 14, bottom: 6 })
  }

  @Builder
  hint(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor(this.pal().textTertiary)
      .width('100%')
      .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 2, bottom: 8 })
  }

  @Builder
  switchRow(title: string, desc: string, checked: boolean, onChange: (v: boolean) => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(15)
          .fontColor(this.pal().textPrimary)
          .width('100%')
        if (desc.length > 0) {
          Text(desc)
            .fontSize(12)
            .fontColor(this.pal().textSecondary)
            .margin({ top: 3 })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: checked })
        .selectedColor(this.pal().primary)
        .switchPointColor(Color.White)
        .onChange((value: boolean) => {
          onChange(value);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 8 })
  }

  /**
   * 选项 chip。
   *
   * 关键点：这里**不接收 active 布尔参数**，只接收 label / kind / value 三个不变的值，
   * 选中态由组件自己在 build 期间调用 isChipActive() 现算。
   * 原因有两个：
   * 1) ForEach 的 key 稳定时不会重新执行 itemGenerator，按值传进来的 active 会被
   *    冻结在首次渲染的值，表现为高亮永远停在初始档位、点了不动；
   * 2) @Builder 按值传参本身也不保证随状态刷新。
   * 现算则让 Text 的属性直接依赖组件状态，状态一变就重算，绕开上面两个坑。
   */
  @Builder
  chip(label: string, kind: string, value: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.isChipActive(kind, value) ? Color.White : this.pal().textSecondary)
      .backgroundColor(this.isChipActive(kind, value) ? this.pal().primary : this.pal().bgChip)
      .borderRadius(14)
      .height(28)
      .padding({ left: 12, right: 12 })
      .margin({ right: 8, bottom: 6 })
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.onChip(kind, value);
      })
  }

  /** chip 是否选中：由 kind 决定跟哪个状态比 */
  private isChipActive(kind: string, value: string): boolean {
    if (kind === 'quality') {
      return this.quality === value;
    }
    if (kind === 'dock') {
      return this.playerDock === value;
    }
    if (kind === 'font') {
      return this.lyricFont === Number.parseInt(value, 10);
    }
    if (kind === 'nameFormat') {
      return this.nameFormat === value;
    }
    return false;
  }

  /** chip 点击统一派发（kind + value，避免 @Builder 传函数） */
  private onChip(kind: string, value: string): void {
    hilog.info(DOMAIN, TAG, 'chip tap: %{public}s / %{public}s', kind, value);
    if (kind === 'quality') {
      this.quality = value;
      PlaySettings.getInstance().setQuality(value);
      return;
    }
    if (kind === 'dock') {
      this.playerDock = value;
      PlaySettings.getInstance().setPlayerDock(value);
      return;
    }
    if (kind === 'font') {
      const size: number = Number.parseInt(value, 10);
      if (!Number.isNaN(size)) {
        this.lyricFont = size;
        PlaySettings.getInstance().setLyricFontSize(size);
      }
      return;
    }
    if (kind === 'nameFormat') {
      this.nameFormat = value;
      DownloadSettings.getInstance().setNameFormat(value);
      return;
    }
    if (kind === 'export') {
      this.exportLatest();
      return;
    }
    if (kind === 'share') {
      this.shareLatest();
      return;
    }
    if (kind === 'clearDone') {
      this.clearFinishedRecords();
      return;
    }
  }

  @Builder
  localSection() {
    this.subTitle('本地音乐')

    Row() {
      Column() {
        Text(`已导入 ${this.localCount} 首`)
          .fontSize(15)
          .fontColor(this.pal().textPrimary)
          .width('100%')
        Text(this.localProgress.length > 0
          ? `正在导入 ${this.localProgress}`
          : `占用 ${formatBytes(this.localBytes)} · 音频索引在本机，原始文件不动`)
          .fontSize(12)
          .fontColor(this.pal().textSecondary)
          .margin({ top: 3 })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 8 })

    Row() {
      Text(this.importing ? '扫描中…' : '扫描本地音乐')
        .fontSize(13)
        .fontColor(Color.White)
        .height(32)
        .padding({ left: 14, right: 14 })
        .borderRadius(16)
        .backgroundColor(this.pal().primary)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.scanLocalMusic();
        })
      Text(this.localOpen ? '收起列表' : '查看列表')
        .fontSize(13)
        .fontColor(this.pal().textPrimary)
        .height(32)
        .padding({ left: 14, right: 14 })
        .borderRadius(16)
        .backgroundColor(this.pal().bgChip)
        .textAlign(TextAlign.Center)
        .margin({ left: 8 })
        .onClick(() => {
          this.localOpen = !this.localOpen;
          this.refreshLocal();
          if (this.localOpen) {
            this.localSongs = LocalMusic.getInstance().songsForUi();
          }
        })
      if (this.localCount > 0) {
        Text('清空')
          .fontSize(13)
          .fontColor(this.pal().danger)
          .height(32)
          .padding({ left: 14, right: 14 })
          .borderRadius(16)
          .backgroundColor(this.pal().bgChip)
          .textAlign(TextAlign.Center)
          .margin({ left: 8 })
          .onClick(() => {
            this.confirmClearLocal();
          })
      }
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 8 })

    if (this.localOpen) {
      if (this.localSongs.length === 0) {
        this.hint('还没有本地歌曲，点上面的「扫描本地音乐」从文件管理的音频分类里选。')
      } else {
        Column() {
          List() {
            ForEach(this.localSongs, (item: SongItem, index: number) => {
              ListItem() {
                Row() {
                  Column() {
                    Text(item.name)
                      .fontSize(14)
                      .fontColor(this.pal().textPrimary)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                    Text(item.singer.length > 0 ? item.singer : '未知歌手')
                      .fontSize(11)
                      .fontColor(this.pal().textTertiary)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 2 })
                      .width('100%')
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Image(PlayIconSet.PLAY)
                    .width(16)
                    .height(16)
                    .fillColor(this.pal().primary)
                    .objectFit(ImageFit.Contain)
                    .draggable(false)
                    .margin({ left: 6, right: 6 })
                }
                .width('100%')
                .height(48)
                .onClick(() => {
                  this.playLocal(index);
                })
              }
            }, (item: SongItem) => item.id)
          }
          .width('100%')
          .height(240)
          .scrollBar(BarState.Off)
          .divider({ strokeWidth: 0.5, color: this.pal().divider })
        }
        .width('100%')
        .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 8 })
      }
    }
  }

  @Builder
  sourceSection() {
    this.subTitle('音源设置')

    Row() {
      Column() {
        Text(this.sources.length === 0 ? '未导入音源' : `已导入 ${this.sources.length} 个音源`)
          .fontSize(15)
          .fontColor(this.pal().textPrimary)
          .width('100%')
        Text(this.sandboxStatus.length > 0 ? this.sandboxStatus : '音源用于解析在线歌曲的播放链接')
          .fontSize(12)
          .fontColor(this.pal().textSecondary)
          .margin({ top: 3 })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 8 })

    Row() {
      Text(this.busy ? '处理中…' : '导入音源脚本')
        .fontSize(13)
        .fontColor(Color.White)
        .height(32)
        .padding({ left: 14, right: 14 })
        .borderRadius(16)
        .backgroundColor(this.pal().primary)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.pickSourceFile();
        })
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 8 })

    Row() {
      TextInput({ text: this.urlInput, placeholder: '从链接导入音源脚本（http/https）' })
        .fontSize(13)
        .fontColor(this.pal().textPrimary)
        .placeholderColor(this.pal().textTertiary)
        .backgroundColor(this.pal().bgChip)
        .height(38)
        .layoutWeight(1)
        .onChange((v: string) => {
          this.urlInput = v;
        })
      Text('导入')
        .fontSize(13)
        .fontColor(this.pal().textPrimary)
        .height(32)
        .padding({ left: 12, right: 12 })
        .borderRadius(16)
        .backgroundColor(this.pal().bgChip)
        .textAlign(TextAlign.Center)
        .margin({ left: 8 })
        .onClick(() => {
          this.importFromUrl();
        })
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 8 })

    if (this.sources.length === 0) {
      this.hint('还没有音源：导入 .js 音源脚本后，「音乐」页的五个平台歌单才能播放。')
    } else {
      Column() {
        ForEach(this.sources, (info: SourceInfo) => {
          Row() {
            Column() {
              Text(info.name)
                .fontSize(14)
                .fontColor(this.curSourceId === info.id ? this.pal().primary : this.pal().textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(`v${info.version}${info.author.length > 0 ? ` · ${info.author}` : ''}${this.curSourceId === info.id ? ' · 使用中' : ''}`)
                .fontSize(11)
                .fontColor(this.pal().textTertiary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 2 })
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text(this.curSourceId === info.id ? '已启用' : '启用')
              .fontSize(12)
              .fontColor(this.curSourceId === info.id ? this.pal().textTertiary : Color.White)
              .backgroundColor(this.curSourceId === info.id ? this.pal().bgChip : this.pal().primary)
              .borderRadius(12)
              .height(26)
              .padding({ left: 10, right: 10 })
              .textAlign(TextAlign.Center)
              .onClick(() => {
                if (this.curSourceId !== info.id) {
                  this.loadSource(info.id);
                }
              })
            Text('删除')
              .fontSize(12)
              .fontColor(this.pal().danger)
              .height(26)
              .padding({ left: 10, right: 10 })
              .textAlign(TextAlign.Center)
              .margin({ left: 6 })
              .onClick(() => {
                this.confirmRemoveSource(info);
              })
          }
          .width('100%')
          .height(52)
          .alignItems(VerticalAlign.Center)
        }, (info: SourceInfo) => info.id)
      }
      .width('100%')
      .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 8 })
    }
  }

  @Builder
  playSection() {
    this.subTitle('播放设置')

    Row() {
      Column() {
        Text('播放音质')
          .fontSize(15)
          .fontColor(this.pal().textPrimary)
          .width('100%')
        Text('在线歌曲向音源申请的规格，音源不支持时自动降级')
          .fontSize(12)
          .fontColor(this.pal().textSecondary)
          .margin({ top: 3 })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 8 })

    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(QUALITYS, (q: string, index: number) => {
        this.chip(QUALITY_LABELS[index], 'quality', q)
      }, (q: string) => `q_${q}`)
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 6 })

    this.switchRow('请求高规格音质', '向音源申请 Hi-Res / 全景声 / 母带等扩展规格', this.extendQuality,
      (v: boolean) => {
        this.extendQuality = v;
        PlaySettings.getInstance().setExtendQuality(v);
      })
    this.switchRow('与其他应用同时播放', '不抢占音频焦点，导航播报时压低音乐音量', this.playWithOthers,
      (v: boolean) => {
        this.playWithOthers = v;
        PlaySettings.getInstance().setPlayWithOthers(v);
      })
    Row() {
      Column() {
        Text('播放控件控制')
          .fontSize(15)
          .fontColor(this.pal().textPrimary)
          .width('100%')
        Text('音乐页播放控件的悬浮位置：上排贴标题右侧（避让「音乐」二字），下排落在页签之上（避让任务栏）')
          .fontSize(12)
          .fontColor(this.pal().textSecondary)
          .margin({ top: 3 })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 4 })

    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(PLAYER_DOCKS, (d: string, index: number) => {
        this.chip(PLAYER_DOCK_LABELS[index], 'dock', d)
      }, (d: string) => `dock_${d}`)
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 6 })

    this.switchRow('显示迷你歌词', '音乐页底部迷你播放条上显示当前歌词', this.showMiniLyric,
      (v: boolean) => {
        this.showMiniLyric = v;
        PlaySettings.getInstance().setShowMiniLyric(v);
      })
    this.switchRow('歌词模糊背景', '播放页歌词使用模糊封面做背景', this.lyricBlur,
      (v: boolean) => {
        this.lyricBlur = v;
        PlaySettings.getInstance().setLyricBlur(v);
      })
    this.switchRow('歌词居中显示', '当前行始终居中高亮', this.lyricCentered,
      (v: boolean) => {
        this.lyricCentered = v;
        PlaySettings.getInstance().setLyricCentered(v);
      })
    this.switchRow('歌词常亮屏', '播放页显示歌词时不自动熄屏', this.lyricKeepScreen,
      (v: boolean) => {
        this.lyricKeepScreen = v;
        PlaySettings.getInstance().setLyricKeepScreenOn(v);
      })

    Row() {
      Text('歌词字号')
        .fontSize(15)
        .fontColor(this.pal().textPrimary)
        .layoutWeight(1)
      Text(`${this.lyricFont}`)
        .fontSize(13)
        .fontColor(this.pal().textSecondary)
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 4 })

    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(LYRIC_SIZES, (size: number) => {
        this.chip(`${size}`, 'font', `${size}`)
      }, (size: number) => `fs_${size}`)
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 6 })

    this.switchRow('自动匹配歌词', '本地歌曲在线匹配平台歌词', this.autoMatchLyric,
      (v: boolean) => {
        this.autoMatchLyric = v;
        PlaySettings.getInstance().setAutoMatchLyric(v);
      })
    this.switchRow('中断后自动恢复', '电话/导航播报结束后自动继续播放', this.autoResume,
      (v: boolean) => {
        this.autoResume = v;
        PlaySettings.getInstance().setAutoResumeAfterInterrupt(v);
      })
  }

  @Builder
  downloadSection() {
    this.subTitle('下载设置')

    Row() {
      Column() {
        Text('文件名称格式')
          .fontSize(15)
          .fontColor(this.pal().textPrimary)
          .width('100%')
        Text('保存在应用内目录，重启可直接播放；需要分享时用「导出到系统文件」')
          .fontSize(12)
          .fontColor(this.pal().textSecondary)
          .margin({ top: 3 })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 8 })

    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(NAME_FORMATS, (fmt: string, index: number) => {
        this.chip(NAME_FORMAT_LABELS[index], 'nameFormat', fmt)
      }, (fmt: string) => `nf_${fmt}`)
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 6 })

    this.switchRow('文件名标注音质', '例如「歌曲名 [flac]」', this.markQuality, (v: boolean) => {
      this.markQuality = v;
      DownloadSettings.getInstance().setMarkQuality(v);
    })

    // 保存位置：1.1111.06 起固定为应用内沙箱，没有「换位置」这回事，只说明清楚
    // 「存在哪、重启还在、怎么给出去」
    Row() {
      Column() {
        Text('保存位置')
          .fontSize(15)
          .fontColor(this.pal().textPrimary)
          .width('100%')
        Text('应用内目录（无需权限）')
          .fontSize(12)
          .fontColor(this.pal().textSecondary)
          .margin({ top: 3 })
          .width('100%')
        Text('保存在应用内，重启可直接播放；卸载应用会一并删除，需要分享时用导出')
          .fontSize(11)
          .fontColor(this.pal().textTertiary)
          .margin({ top: 3 })
          .width('100%')
        Text(this.savePath.length > 0 ? this.savePath : '正在初始化…')
          .fontSize(11)
          .fontColor(this.pal().textTertiary)
          .margin({ top: 3 })
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 6 })

    // 导出 / 分享：替代原来的「写公共下载目录」，两条路都不需要任何权限
    Flex({ wrap: FlexWrap.Wrap }) {
      this.chip(this.exporting ? '正在导出…' : '导出到系统文件', 'export', '')
      this.chip('分享到其它应用', 'share', '')
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 6 })

    // 下载记录：删不掉的文件必须让用户看见，不能让它从列表里悄悄消失
    Row() {
      Column() {
        Text('下载记录')
          .fontSize(15)
          .fontColor(this.pal().textPrimary)
          .width('100%')
        Text(this.downloadCount > 0
          ? `共 ${this.downloadCount} 条，其中 ${this.downloadFinished} 条已完成/失败可清理`
          : '暂无下载记录')
          .fontSize(12)
          .fontColor(this.pal().textSecondary)
          .margin({ top: 3 })
          .width('100%')
        Text('清理时只删文件、不删记录源；文件删不掉会留在列表里并由下方提示说明原因')
          .fontSize(11)
          .fontColor(this.pal().textTertiary)
          .margin({ top: 3 })
          .width('100%')
        if (this.downloadNotice.length > 0) {
          Text(this.downloadNotice)
            .fontSize(12)
            .fontColor(this.pal().danger)
            .margin({ top: 4 })
            .width('100%')
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 6 })

    Flex({ wrap: FlexWrap.Wrap }) {
      this.chip(this.downloadFinished > 0 ? `清空已完成记录（${this.downloadFinished}）` : '清空已完成记录', 'clearDone', '')
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 6 })


    this.hint('下载只写应用内目录：不申请任何存储权限，也不需要跨重启的目录授权 —— '
      + '这样才算彻底摆脱受限 ACL。要给别的设备或应用用，点「导出到系统文件」自己选位置，'
      + '或「分享到其它应用」。')
  }

  build() {
    Column() {
      this.localSection()
      Divider().color(this.pal().divider).margin({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })
      this.sourceSection()
      Divider().color(this.pal().divider).margin({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })
      this.playSection()
      Divider().color(this.pal().divider).margin({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })
      this.downloadSection()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
