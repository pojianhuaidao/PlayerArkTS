import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { storageRootDir } from '../common/StoragePaths';

const DOMAIN: number = 0x0001;
const TAG: string = 'DownloadSettings';
const FILE_NAME: string = 'download_settings.json';
/**
 * 落盘结构变了就 +1，读到不认识的版本按默认值处理。
 *
 * v1 -> v2：去掉「保存位置」相关字段（保存位置不再可选），新增 downloadDirUri。
 * v2 -> v3：新增 downloadDir（实际落盘的目录，默认系统公共「下载」目录）。
 * v3 -> v4：新增 dirVia（这个目录是怎么来的：ACL 直写 / 用户选的保存位置 / 应用内兜底）。
 * v4 -> v5：新增 dirUserSet / lastActualPath / dirNotice / aclHopeless / persistedUris，
 *           用来记住「用户显式指定的位置」「上次真实落盘到哪」「目录告警」以及
 *           「哪些目录 uri 已经申请过持久授权」。
 * v5 -> v6：**下载彻底沙箱化**。音乐下载改为只写应用内目录（files/Download），
 *           公共「下载」目录那条链路（受限 ACL + FILE_ACCESS_PERSIST 持久授权）
 *           整个拆掉 —— 它会触发 AGC 上传时的 ACL 一致性校验失败。
 *           因此 downloadDirUri / downloadDir / dirVia / dirUserSet / lastActualPath /
 *           dirNotice / aclHopeless / persistedUris **全部作废**：读到旧版本文件时
 *           一律丢弃这些字段，并立刻回写一次把旧配置从磁盘上清掉，绝不静默复用
 *           老的公共目录记录（复用了就等于还依赖那条已拆除的授权通道）。
 */
const SETTINGS_VERSION: number = 6;

/**
 * 音乐下载目录名（相对应用沙箱的 filesDir）
 *
 * 只放名字不放完整路径：沙箱路径由 running 时的 `context.filesDir` 拼出来，
 * 换设备 / 换安装形态都不会指错地方，也不需要任何权限。
 */
export const DOWNLOAD_DIR_NAME: string = 'Download';

export const NAME_FORMATS: string[] = ['song', 'artist-title', 'title-artist'];
export const NAME_FORMAT_LABELS: string[] = ['歌曲名', '艺术家-标题', '标题-艺术家'];

export const K_DOWNLOAD_NAME_FORMAT: string = 'cfg_download_name_format';
export const K_DOWNLOAD_MARK_QUALITY: string = 'cfg_download_mark_quality';

/**
 * 下载设置（设置 - 下载设置）
 *
 * 对应界面上两项：
 *   文件名称格式（歌曲名 / 艺术家-标题 / 标题-艺术家）
 *   下载文件标注音质（开/关：文件名后缀带上音质，如 `歌名-320k.mp3`）
 *
 * 保存位置**不在这里**：位置固定是应用沙箱的 files/Download，由 DownloadManager
 * 用 `context.filesDir` 拼出来，属于「算出来的」而不是「记下来的」，
 * 所以没必要落盘，也不存在「用户改位置」这回事（要给别人就用导出/分享）。
 *
 * 存法与播放设置一致：一份 JSON 落在沙箱（filesDir/download_settings.json），
 * 同时把每个值写进 AppStorage，界面用 @StorageLink 订阅即可实时响应。
 */
export const NAME_FORMAT_DEFAULT: string = 'song';

/** 落盘结构（字段全部可选：老文件可能缺字段） */
interface DownloadSettingsData {
  version?: number;
  nameFormat?: string;
  markQuality?: boolean;
}

export class DownloadSettings {
  private static instance: DownloadSettings | null = null;

  static getInstance(): DownloadSettings {
    if (DownloadSettings.instance === null) {
      DownloadSettings.instance = new DownloadSettings();
    }
    return DownloadSettings.instance;
  }

  private file: string = '';
  private inited: boolean = false;

  /** 文件名称格式：参考图里默认「歌曲名」 */
  private nameFormat: string = NAME_FORMAT_DEFAULT;
  /** 下载文件标注音质：默认开（参考图里也是开） */
  private markQuality: boolean = true;

  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    this.file = `${storageRootDir(context)}/${FILE_NAME}`;
    this.inited = true;
    const text: string = this.read();
    if (text.length > 0) {
      try {
        this.apply(JSON.parse(text) as DownloadSettingsData);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'failed to parse download settings: %{public}s', JSON.stringify(e));
      }
    }
    this.publish();
  }

  private read(): string {
    try {
      if (!fs.accessSync(this.file)) {
        return '';
      }
      return fs.readTextSync(this.file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to read download settings: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private write(): void {
    if (!this.inited) {
      return;
    }
    // 只写 v6 认识的两个字段：旧的位置相关配置到这一步就彻底从磁盘上消失了
    const data: DownloadSettingsData = {
      version: SETTINGS_VERSION,
      nameFormat: this.nameFormat,
      markQuality: this.markQuality,
    };
    try {
      const handle = fs.openSync(this.file, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(handle.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(handle);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to write download settings: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 读入旧文件
   *
   * 只认 nameFormat / markQuality；其余字段（下载位置、授权记忆等）一律无视。
   * 版本 < 6 时立刻写一次盘，把老配置清理掉 —— 迁移不能只是「读的时候忽略」，
   * 否则旧文件里那条公共目录 uri 会一直躺在磁盘上。
   */
  private apply(data: DownloadSettingsData): void {
    // 高于当前版本的（用户装回旧包）一律忽略，免得把新字段丢掉之后再写盘覆盖掉
    if (data.version !== undefined && data.version > SETTINGS_VERSION) {
      return;
    }
    const format: string | undefined = data.nameFormat;
    if (format !== undefined && NAME_FORMATS.includes(format)) {
      this.nameFormat = format;
    }
    if (data.markQuality !== undefined) {
      this.markQuality = data.markQuality;
    }
    const version: number = data.version === undefined ? 1 : data.version;
    if (version < SETTINGS_VERSION) {
      hilog.info(DOMAIN, TAG, 'migrate download settings v%{public}d -> v%{public}d, drop location fields',
        version, SETTINGS_VERSION);
      this.write();
    }
  }

  private publish(): void {
    try {
      AppStorage.setOrCreate(K_DOWNLOAD_NAME_FORMAT, this.nameFormat);
      AppStorage.setOrCreate(K_DOWNLOAD_MARK_QUALITY, this.markQuality);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to publish download settings: %{public}s', JSON.stringify(e));
    }
  }

  // ---------------------------------------------------------------- 读取

  getNameFormat(): string {
    return this.nameFormat;
  }

  isMarkQuality(): boolean {
    return this.markQuality;
  }

  // ---------------------------------------------------------------- 写入

  setNameFormat(value: string): void {
    if (!NAME_FORMATS.includes(value) || value === this.nameFormat) {
      return;
    }
    this.nameFormat = value;
    AppStorage.setOrCreate(K_DOWNLOAD_NAME_FORMAT, value);
    this.write();
  }

  setMarkQuality(value: boolean): void {
    if (value === this.markQuality) {
      return;
    }
    this.markQuality = value;
    AppStorage.setOrCreate(K_DOWNLOAD_MARK_QUALITY, value);
    this.write();
  }
}
