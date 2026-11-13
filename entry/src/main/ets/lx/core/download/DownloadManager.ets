import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
// Share Kit：系统分享面板（导出之外的另一条「把歌给出去」的路，不需要任何权限）
import systemShare from '@hms.collaboration.systemShare';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SongItem } from '../player/PlaySession';
import { LxPlayer } from '../player/LxPlayer';
import { mediaKeyOf } from '../music/MediaCache';
import { fallbackQuality, pickQuality } from '../music/Quality';
import { SourceEngine } from '../source/SourceEngine';
import { LxQuality } from '../source/LxTypes';
import { DownloadSettings } from './DownloadSettings';
import { DownloadTagData, collectDownloadTags, tagSummary } from './DownloadTags';
import { AutoDownloadSong, clearDownloadedFiles, removeDownloadedFile, setAutoDownloadHandler,
  setDownloadedFile } from './DownloadIndex';
import { TagSink } from './TagWriter';
import { isLocalSong } from '../local/LocalMusic';
import { isWebDavSong } from '../webdav/WebDavLibrary';

const DOMAIN: number = 0x0001;
const TAG: string = 'DownloadManager';

/** 下载列表 / 进度变化时递增，界面订阅它刷新 */
export const K_DOWNLOAD_VERSION: string = 'download_version';

/** 应用内的下载目录（沙箱 files/Download）：1.1111.06 起唯一的落盘位置，卸载应用才会删 */
const DIR_NAME: string = 'Download';
const INDEX_FILE: string = 'downloads.json';
const PART_SUFFIX: string = '.part';
/** 文件不存在（fileIo）的错误码：删文件时它不算失败（用户可能已经在文件管理里删过了） */
const ENOENT_CODE: number = 13900002;
/**
 * 回收临时文件时按这个块大小分块拷贝
 *
 * rename 不可用（部分机型的 docs uri 通道不支持改名）时退化成「拷贝到正式名再删临时名」，
 * 分块是为了别为了 60MB 的 flac 一次申请一大块内存。
 */
const COPY_CHUNK: number = 64 * 1024;
/** 同时下载数：跟着上游的 download.maxDownloadNum 取 2，少占带宽也少被平台限流 */
const MAX_ACTIVE: number = 2;
/** 文件名长度上限（含扩展名），太长的名字部分文件系统会写失败 */
const MAX_NAME_LEN: number = 90;
/** 进度刷新节流：每收一块数据都重绘列表太浪费 */
const PROGRESS_THROTTLE_MS: number = 400;
/**
 * 自动下载（「缓存时自动下载」排进来的）在播放挨饿时隔多久回来看一眼
 *
 * 与播放缓存那边的 WAIT_DELAY_MS 一个量级：只是回来看一眼，不占网络。
 */
const AUTO_WAIT_MS: number = 4000;

/** 音质 -> 扩展名（拿不到链接后缀时用） */
const EXT_BY_QUALITY: Record<string, string> = {
  '128k': 'mp3',
  '320k': 'mp3',
  'flac': 'flac',
  'flac24bit': 'flac',
  'hires': 'flac',
  'atmos': 'm4a',
  'atmos_plus': 'm4a',
  'master': 'flac',
};
const KNOWN_EXTS: string[] = ['mp3', 'flac', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'ape', 'wma'];

/** 下载状态 */
export type DownloadStatus = 'waiting' | 'downloading' | 'done' | 'error';

/** 一条下载记录 */
export interface DownloadItem {
  /** 唯一键：mediaKeyOf 的结果；没有 musicInfo 的条目退回条目 id */
  key: string;
  name: string;
  singer: string;
  source: string;
  quality: string;
  interval: string;
  coverUrl: string;
  art: boolean;
  musicInfoJson: string;
  /** 落盘文件名（含扩展名） */
  fileName: string;
  /** 完整落盘路径 / uri */
  uri: string;
  received: number;
  total: number;
  status: DownloadStatus;
  /** 失败原因（status = error 时有值） */
  error: string;
  /** 非致命提示（例如系统下载目录不可用、已改存到应用内目录），列表里跟在状态后面显示 */
  note: string;
  /** 标签（封面 / 歌词）嵌入结果：嵌进去了就写「已嵌入封面与歌词」，容器不支持就如实说明 */
  tagNote: string;
  /**
   * 是不是「缓存时自动下载」排进来的（不是用户点的那一下）
   *
   * 只影响调度：自动排进来的在播放挨饿时不抢网络（见 pump），用户点的立即开工。
   */
  auto: boolean;
  createdAt: number;
}

/**
 * 下一次下载会落到哪（设置页据此显示位置）
 *
 * 1.1111.06 起位置只有一处（应用沙箱 files/Download），所以结构只剩 path 一个字段；
 * 保留接口是为了设置页的调用方式不用变。
 */
export interface SaveLocationInfo {
  /** 沙箱里的下载目录物理路径（给人看） */
  path: string;
}

/** 一次下载要写的位置（只有一个来源：应用内沙箱目录） */
interface WriteTarget {
  /** 最终路径（记进索引，也用来播放） */
  path: string;
  /** 边下边写的临时文件（下完 rename 成正式名） */
  part: string;
  handle: fs.File;
}

/** 删除若干条下载记录的结果（删不掉的文件绝不静默吞掉，要汇报给用户） */
export interface RemoveOutcome {
  /** 真正从列表 / 索引里摘掉的条数 */
  removed: number;
  /** 文件没能删除、因而保留在列表里的条数 */
  failed: number;
  /** 给用户看的一句话（空串表示全部干净删掉） */
  message: string;
}

/** 落盘结构（字段可选：老文件可能缺） */
interface DownloadIndexData {
  version?: number;
  items?: DownloadItem[];
}

const INDEX_VERSION: number = 1;

/**
 * 下载记录的唯一键
 *
 * mediaKey（平台_歌曲id_哈希）优先：同一首歌在不同列表里 id 可能不同，
 * 但 musicInfo 是一样的；没有 musicInfo 的条目退回条目 id。
 */
export function downloadKeyOf(song: SongItem): string {
  const media: string = mediaKeyOf(song.musicInfoJson);
  return media.length > 0 ? media : song.id;
}

function asNumber(value: Object | undefined): number {
  if (typeof value === 'number') {
    return value as number;
  }
  if (typeof value === 'string') {
    const parsed: number = Number.parseInt(value as string, 10);
    return Number.isNaN(parsed) ? 0 : parsed;
  }
  return 0;
}

/**
 * 老索引文件里没有的字段补成空串
 *
 * 下载记录是 JSON 落盘的，加了新字段（如 tagNote）之后，升级前写下的文件里
 * 没有这个键，读出来就是 undefined —— 界面上一取 .length 就崩。
 */
function orEmpty(value: string | undefined): string {
  return value !== undefined && value !== null ? value : '';
}

/** 文件名不能带路径分隔符与系统保留字符，统一洗一遍 */
function sanitizeFileName(name: string): string {
  let out: string = '';
  for (let i = 0; i < name.length; i++) {
    const ch: string = name.charAt(i);
    if (ch === '/' || ch === '\\' || ch === ':' || ch === '*' || ch === '?' || ch === '"'
      || ch === '<' || ch === '>' || ch === '|' || ch.charCodeAt(0) < 32) {
      out += '_';
      continue;
    }
    out += ch;
  }
  const trimmed: string = out.trim().replace(/^\.+/, '');
  return trimmed.length > 0 ? trimmed : '未命名';
}

export class DownloadManager {
  private static instance: DownloadManager | null = null;

  static getInstance(): DownloadManager {
    if (DownloadManager.instance === null) {
      DownloadManager.instance = new DownloadManager();
    }
    return DownloadManager.instance;
  }

  /** 应用内下载目录（沙箱 files/Download，唯一落盘位置） */
  private dir: string = '';
  /** 导出 / 分享要用的 context（系统保存对话框与分享面板都需要） */
  private context: common.Context | null = null;
  private inited: boolean = false;
  private items: DownloadItem[] = [];
  private active: number = 0;
  /** 正在下载的请求句柄：删除 / 取消时要 destroy 掉 */
  private requests: Map<string, http.HttpRequest> = new Map<string, http.HttpRequest>();
  private lastBumpAt: number = 0;
  private persistTimer: number = 0;
  /** 自动下载等播放缓过来时的复查定时器 */
  private pumpTimer: number = 0;
  /**
   * 已占住、还没落定的正式文件名 / uri
   *
   * 两首同名曲并发下载时，「探测这个文件名有没有被占用」是同步跑完的，可两边的探测
   * 之间没有任何屏障 —— 都探测到「没占用」就会抢同一个文件名，先落定的那首会被
   * 后落定的覆盖掉（早期版本就是这么互相污染的）。占位集合把「探测 + 占位」合成
   * 一个原子动作：后一个进来时前一个的名字已经在集合里，自然跳到 (1)(2)。
   */
  private reserved: Set<string> = new Set<string>();
  /**
   * 每个落盘目录一条的文件系统收尾队列
   *
   * 写数据本身并发没问题（各写各的临时文件），但「收尾」是 rename / 覆盖写这种
   * 非原子序列，同一目录里两首歌同时收尾会交错。按目录排队，收尾一次只跑一个。
   */
  private fsQueues: Map<string, Promise<void>> = new Map<string, Promise<void>>();

  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    this.context = context;
    // 沙箱目录：context.filesDir 下的 Download，写它不需要任何权限
    this.dir = `${context.filesDir}/${DIR_NAME}`;
    try {
      if (!fs.accessSync(this.dir)) {
        fs.mkdirSync(this.dir);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'create download dir failed: %{public}s', JSON.stringify(e));
      return;
    }
    this.inited = true;
    this.loadIndex();
    // 「缓存时自动下载」的入口注册在这里：播放层不 import 下载器，只按
    // DownloadIndex 里的窄接口说话（那个模块是叶子，见它的说明）
    setAutoDownloadHandler((song: AutoDownloadSong): boolean => {
      return this.enqueueAuto(song) !== null;
    });
    this.bump();
    hilog.info(DOMAIN, TAG, 'download manager ready, %{public}d record(s)', this.items.length);
  }

  /**
   * 「缓存时自动下载」排进来的一首：与用户点的下载同一条队列
   *
   * 只把字段搬过来（DownloadIndex 里那份声明是为了不 import SongItem）。
   * 音质用播放用的那一档，别让听的和存下来的不是一个东西。
   */
  private enqueueAuto(song: AutoDownloadSong): DownloadItem | null {
    const item: SongItem = {
      id: song.id,
      name: song.name,
      singer: song.singer,
      coverUrl: song.coverUrl,
      art: song.art,
      source: song.source,
      quality: song.quality,
      interval: song.interval,
      musicInfoJson: song.musicInfoJson,
    };
    return this.enqueue(item, true);
  }

  isReady(): boolean {
    return this.inited;
  }

  /** 应用内下载目录（设置页显示用） */
  appDir(): string {
    return this.dir;
  }

  /** 下载列表：新的在前 */
  list(): DownloadItem[] {
    const out: DownloadItem[] = [];
    for (let i = this.items.length - 1; i >= 0; i--) {
      out.push(this.items[i]);
    }
    return out;
  }

  count(): number {
    return this.items.length;
  }

  /** 正在下载 / 排队中的条数（列表页的副标题用） */
  activeCount(): number {
    let n: number = 0;
    for (const item of this.items) {
      if (item.status === 'downloading' || item.status === 'waiting') {
        n++;
      }
    }
    return n;
  }

  stateOf(key: string): DownloadItem | null {
    for (const item of this.items) {
      if (item.key === key) {
        return item;
      }
    }
    return null;
  }

  isDownloaded(key: string): boolean {
    const item: DownloadItem | null = this.stateOf(key);
    return item !== null && item.status === 'done';
  }


  /** 下载记录 -> 可播放条目（下载管理页点一下就能放） */
  toSong(item: DownloadItem): SongItem {
    return {
      id: item.key,
      name: item.name,
      singer: item.singer,
      coverUrl: item.coverUrl,
      art: item.art,
      source: item.source,
      quality: item.quality,
      interval: item.interval,
      musicInfoJson: item.musicInfoJson,
    };
  }

  // ---------------------------------------------------------------- 入队

  /**
   * 下载一首歌
   *
   * 已经下过 / 正在下的直接返回已有记录（不重复下）；失败过的重新排一次队。
   * 返回 null 表示当前状态没法下（没有音源、条目没有 musicInfo 等）。
   *
   * @param auto 「缓存时自动下载」排进来的（见 pump 里的让路规则），用户点的下载传 false
   */
  enqueue(song: SongItem, auto: boolean = false): DownloadItem | null {
    if (!this.inited) {
      return null;
    }
    // 本地歌（从设备导入进来的音频）已经在本机了，没有下载的意义：
    // 在这里拦一道，任何入口都不会把它排进下载队列
    if (isLocalSong(song)) {
      return null;
    }
    // 云端歌（WebDAV）也不走这条队列：它没有音源链接，而是由播放缓存的
    // 「边听边下」自己带认证头下载（见 AudioCache / PlaySession.playWebDavItem）
    if (isWebDavSong(song)) {
      return null;
    }
    const key: string = downloadKeyOf(song);
    if (key.length === 0) {
      return null;
    }
    const existed: DownloadItem | null = this.stateOf(key);
    if (existed !== null) {
      // 用户点的那一下比自动排的更急：本来是自动排的，现在就当成手动下载（立即开工）
      existed.auto = existed.auto && auto;
      if (existed.status === 'error') {
        existed.status = 'waiting';
        existed.error = '';
        existed.tagNote = '';
        existed.received = 0;
        existed.total = 0;
        this.persist();
        this.pump();
      }
      return existed;
    }
    const item: DownloadItem = {
      key: key,
      name: song.name,
      singer: song.singer,
      source: song.source,
      quality: song.quality,
      interval: song.interval,
      coverUrl: song.coverUrl,
      art: song.art,
      musicInfoJson: song.musicInfoJson,
      fileName: '',
      uri: '',
      received: 0,
      total: 0,
      status: 'waiting',
      error: '',
      note: '',
      tagNote: '',
      auto: auto,
      createdAt: Date.now(),
    };
    this.items.push(item);
    this.persist();
    this.pump();
    return item;
  }

  /** 批量下载，返回真正排进队列的条数（已在列表里的不重复排） */
  enqueueMany(songs: SongItem[]): number {
    let added: number = 0;
    for (const song of songs) {
      const existed: DownloadItem | null = this.stateOf(downloadKeyOf(song));
      if (existed !== null && existed.status !== 'error') {
        continue;
      }
      if (this.enqueue(song) !== null) {
        added++;
      }
    }
    return added;
  }

  retry(key: string): void {
    const item: DownloadItem | null = this.stateOf(key);
    if (item === null || item.status === 'downloading' || item.status === 'waiting') {
      return;
    }
    item.status = 'waiting';
    item.error = '';
    item.note = '';
    item.tagNote = '';
    // 用户点的「重新下载」就按手动下载走：立即开工，不再等播放缓过来
    item.auto = false;
    item.received = 0;
    item.total = 0;
    this.persist();
    this.pump();
  }

  /**
   * 删除一条记录（正在下的先取消）；已下载的文件也一并删掉
   *
   * 文件删不掉时**不摘记录**：改成 error 状态并把原因写进 error，用户点开就能看到
   * 「文件还在、为什么还在」—— 早期这里用的是 unlinkQuietly，删失败就当没发生，
   * 结果是列表里歌没了、文件却还占着空间，用户完全无从下手。
   */
  remove(key: string): RemoveOutcome {
    const item: DownloadItem | null = this.stateOf(key);
    if (item === null) {
      return this.outcomeOf(0, 0, '');
    }
    const request: http.HttpRequest | undefined = this.requests.get(key);
    if (request !== undefined) {
      // 先改状态再销毁请求：下载协程收尾时会看到「已不是 downloading」，
      // 直接丢掉 .part，不会去 rename 或往列表里写一条已经删掉的记录
      item.status = 'error';
      item.error = '已取消';
      this.requests.delete(key);
      try {
        request.destroy();
      } catch (e) {
        // 已经结束的请求 destroy 报错无所谓
      }
    }
    const failure: string = this.deleteItemFile(item);
    if (failure.length > 0) {
      item.status = 'error';
      item.error = `文件没能删除：${failure}`;
      this.persist();
      this.bump();
      return this.outcomeOf(0, 1, `「${item.name}」的文件没能删除：${failure}`);
    }
    removeDownloadedFile(item.key);
    const next: DownloadItem[] = [];
    for (const one of this.items) {
      if (one.key !== key) {
        next.push(one);
      }
    }
    this.items = next;
    this.persist();
    this.bump();
    return this.outcomeOf(1, 0, '');
  }

  /**
   * 批量删除多条记录（正在下的先取消；已下载的文件一并删掉）
   *
   * 与逐条 remove 的区别：文件删除、索引删除、状态通知全部合并到一轮，
   * 只 persist 一次、只 bump 一次 —— 几百条一起删时不会触发几百次 UI 刷新，
   * 也不会在循环里反复重建数组（O(n²)），避免列表长时删除闪退。
   */
  removeBatch(keys: string[]): RemoveOutcome {
    if (keys.length === 0) {
      return this.outcomeOf(0, 0, '');
    }
    const targets: DownloadItem[] = [];
    for (const key of keys) {
      const item: DownloadItem | null = this.stateOf(key);
      if (item !== null) {
        targets.push(item);
      }
    }
    if (targets.length === 0) {
      return this.outcomeOf(0, 0, '');
    }
    // 1) 取消下载中请求 + 删除磁盘文件：删得掉的收集起来，删不掉的留在列表里
    const doomed: Set<string> = new Set<string>();
    const stuck: string[] = [];
    for (const item of targets) {
      const request: http.HttpRequest | undefined = this.requests.get(item.key);
      if (request !== undefined) {
        // 先改状态再销毁请求：下载协程收尾时会看到「已不是 downloading」，
        // 直接丢掉 .part，不会去 rename 或往列表里写一条已经删掉的记录
        item.status = 'error';
        item.error = '已取消';
        this.requests.delete(item.key);
        try {
          request.destroy();
        } catch (e) {
          // 已经结束的请求 destroy 报错无所谓
        }
      }
      const failure: string = this.deleteItemFile(item);
      if (failure.length > 0) {
        item.status = 'error';
        item.error = `文件没能删除：${failure}`;
        stuck.push(item.name);
        continue;
      }
      removeDownloadedFile(item.key);
      doomed.add(item.key);
    }
    // 2) 一次性过滤列表（只重建一次）
    const next: DownloadItem[] = [];
    for (const one of this.items) {
      if (!doomed.has(one.key)) {
        next.push(one);
      }
    }
    this.items = next;
    // 3) 只落一次盘、只通知一次
    this.persist();
    this.bump();
    return this.outcomeOf(doomed.size, stuck.length, this.stuckMessage(stuck));
  }

  /**
   * 清空已完成 / 失败的记录（正在下的留着）；删不掉的文件保留在列表里并写明原因
   *
   * 只负责「挑出该清的 key」，真正的删文件 / 重建列表 / 落盘 / 通知统一走 removeBatch ——
   * 删不掉的条目会带着原因留在列表里，并由 stuckMessage 汇总成一句话给 UI 弹给用户。
   */
  clearFinished(): RemoveOutcome {
    const keys: string[] = [];
    for (const item of this.items) {
      if (item.status === 'done' || item.status === 'error') {
        keys.push(item.key);
      }
    }
    if (keys.length === 0) {
      return this.outcomeOf(0, 0, '');
    }
    return this.removeBatch(keys);
  }

  /** 删不掉的文件汇总成一句话（最多列 3 首，其余按数量带过） */
  private stuckMessage(names: string[]): string {
    if (names.length === 0) {
      return '';
    }
    const head: string[] = names.slice(0, 3);
    const tail: string = names.length > head.length ? ` 等 ${names.length} 首` : '';
    return `有 ${names.length} 个文件没能删除，已保留在列表里：${head.join('、')}${tail}`;
  }

  private outcomeOf(removed: number, failed: number, message: string): RemoveOutcome {
    return { removed: removed, failed: failed, message: message };
  }

  /** 删掉一条记录对应的磁盘文件：返回空串表示删干净了，返回原因表示文件还在 */
  private deleteItemFile(item: DownloadItem): string {
    if (item.uri.length === 0) {
      return '';
    }
    let reason: string = this.dropFile(item.uri);
    const partReason: string = this.dropFile(`${item.uri}${PART_SUFFIX}`);
    if (reason.length === 0) {
      reason = partReason;
    }
    return reason;
  }

  /**
   * 删一个文件：本来就不存在算删干净，其余错误如实返回原因
   *
   * 「本来就不存在」不算失败：用户可能已经在文件管理里手动删过了，这时候还报
   * 「删除失败」只会让人困惑。
   */
  private dropFile(path: string): string {
    try {
      fs.unlinkSync(path);
      return '';
    } catch (e) {
      const error = e as BusinessError;
      const message: string = error.message !== undefined ? error.message : '';
      if (error.code === ENOENT_CODE || message.indexOf('No such file') >= 0) {
        return '';
      }
      hilog.warn(DOMAIN, TAG, 'delete file failed: %{public}s', JSON.stringify(e));
      return `${message}（错误码 ${error.code}）`;
    }
  }

  // ---------------------------------------------------------------- 保存位置

  // ---------------------------------------------------------------- 保存位置 / 导出

  /**
   * 下一次下载会落到哪（设置页那一行显示的就是它）
   *
   * 1.1111.06 起只有一处：应用沙箱的 files/Download。公共「下载」目录那条路已经整个拆掉
   * —— 它要么依赖受限 ACL（READ_WRITE_DOWNLOAD_DIRECTORY），要么依赖
   * FILE_ACCESS_PERSIST 的持久授权，两者都会让 AGC 上传时的 ACL 一致性校验不通过。
   * 位置只有一个，也就没有「用户指定 / 系统探测」的区别了。
   */
  saveLocation(): SaveLocationInfo {
    return {
      path: this.dir,
    };
  }

  /** 最近一条下载完成的记录（导出 / 分享的默认对象）；没有就返回 null */
  latestDone(): DownloadItem | null {
    for (let i = this.items.length - 1; i >= 0; i--) {
      const item: DownloadItem = this.items[i];
      if (item.status === 'done' && item.uri.length > 0) {
        return item;
      }
    }
    return null;
  }

  /**
   * 把最近一首下载完成的歌导出到系统文件（用户自己选目标位置）
   *
   * 走系统保存对话框（DocumentSaveOptions，默认 SAVE 模式）：用户挑目录和文件名，
   * 全程**不需要任何权限**，授权只在这一刻、只对这一个文件有效 —— 所以既不用声明
   * ACL，也不用 persistPermission。返回值是给用户看的一句话。
   */
  async exportLatest(): Promise<string> {
    const item: DownloadItem | null = this.latestDone();
    if (item === null) {
      return '还没有下载完成的歌曲，先下载一首再导出';
    }
    const context: common.Context | null = this.context;
    if (context === null) {
      return '应用还没准备好，请稍后再试';
    }
    const name: string = item.fileName.length > 0 ? item.fileName : this.nameOfTarget(item.uri);
    let dest: string = '';
    try {
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [name];
      const uris: string[] = await new picker.DocumentViewPicker(context).save(options);
      if (uris === undefined || uris.length === 0) {
        return '没有选择保存位置，已取消导出';
      }
      dest = uris[0];
    } catch (e) {
      const error: BusinessError = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'open save picker failed: %{public}s', JSON.stringify(e));
      return `导出失败：打不开系统保存对话框（${error.message}）`;
    }
    const failure: string = this.copyOut(item.uri, dest);
    if (failure.length > 0) {
      return `导出失败：${failure}`;
    }
    return `已导出「${name}」，应用内的原文件仍保留`;
  }

  /**
   * 把最近一首下载完成的歌交给系统分享面板（微信 / 蓝牙 / 其它播放器）
   *
   * 与导出同一条思路：分享面板只拿到这一个文件的临时读权限，不落任何长期授权。
   */
  async shareLatest(): Promise<string> {
    const item: DownloadItem | null = this.latestDone();
    if (item === null) {
      return '还没有下载完成的歌曲，先下载一首再分享';
    }
    const context: common.Context | null = this.context;
    if (context === null) {
      return '应用还没准备好，请稍后再试';
    }
    try {
      const record: systemShare.SharedRecord = {
        utd: 'general.audio',
        uri: fileUri.getUriFromPath(item.uri),
        title: item.name,
      };
      const data: systemShare.SharedData = new systemShare.SharedData(record);
      // 分享面板要求 UIAbilityContext（这里有的一定是 UIAbility 里拿到的 context）
      await new systemShare.ShareController(data).show(context as common.UIAbilityContext, {});
      return '已打开系统分享';
    } catch (e) {
      const error: BusinessError = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'share failed: %{public}s', JSON.stringify(e));
      return `分享失败：${error.message}（错误码 ${error.code}）。可改用「导出到系统文件」`;
    }
  }

  /** 把一个沙箱文件复制到外部给出的目标位置；返回空串表示成功，否则是失败原因 */
  private copyOut(src: string, dest: string): string {
    try {
      fs.copyFileSync(src, dest);
      return '';
    } catch (e) {
      // 某些机型的 docs uri 不接受 copyFileSync 直接写，退化成流式拷贝
      hilog.warn(DOMAIN, TAG, 'copyFile out failed, use chunk copy: %{public}s', JSON.stringify(e));
    }
    let from: fs.File | null = null;
    let to: fs.File | null = null;
    try {
      from = fs.openSync(src, fs.OpenMode.READ_ONLY);
      to = fs.openSync(dest, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      const buffer: ArrayBuffer = new ArrayBuffer(COPY_CHUNK);
      while (true) {
        const read: number = fs.readSync(from.fd, buffer, { offset: 0, length: COPY_CHUNK });
        if (read <= 0) {
          break;
        }
        fs.writeSync(to.fd, buffer, { offset: 0, length: read });
      }
      fs.fsyncSync(to.fd);
      return '';
    } catch (e) {
      const error: BusinessError = e as BusinessError;
      return `${error.message}（错误码 ${error.code}）`;
    } finally {
      this.closeQuietly(from);
      this.closeQuietly(to);
    }
  }

  /** 从路径 / uri 里取文件名（导出对话框里预填的名字） */
  private nameOfTarget(path: string): string {
    const cut: number = path.lastIndexOf('/');
    return cut >= 0 ? path.substring(cut + 1) : path;
  }

  // ---------------------------------------------------------------- 打开写目标

  /**
   * 打开这次下载要写的位置
   *
   * 只有一条路：应用沙箱的 files/Download（this.dir，init 里就建好）。不再向公共
   * 「下载」目录写、不再向系统要目录 uri、也不再申请持久授权 —— 沙箱里的文件本应用
   * 随时可读可播；要给外部应用 / 电脑用，走 exportLatest / shareLatest。
   *
   * 返回 null 表示这次下载没法开始（目录写不进去 / 文件名占不到）。
   */
  private async openTarget(fileName: string): Promise<WriteTarget | null> {
    return this.openSandboxTarget(fileName);
  }

  // ---------------------------------------------------------------- 占位 / 原子写

  /**
   * 占住一个正式文件名（uri 或沙箱路径都行）
   *
   * 返回 false 表示这个名字已经被另一首正在下的歌占住了。Set 的 add/check 在 ArkTS
   * 单线程事件循环里是原子的，「探测 + 占位」不会被打断，这正是并发同名必须的一步。
   */
  private reserve(path: string): boolean {
    if (this.reserved.has(path)) {
      return false;
    }
    this.reserved.add(path);
    return true;
  }

  /** 落定 / 失败 / 取消之后释放占位（不释放会让同名文件永远排到 (1)(2)…） */
  private releaseReserved(path: string): void {
    if (path.length === 0) {
      return;
    }
    this.reserved.delete(path);
  }

  /** 沙箱目录里挑一个没被占的正式路径（探测 + 占位一次完成） */
  private reserveSandboxTarget(dir: string, fileName: string): string {
    const dot: number = fileName.lastIndexOf('.');
    const stem: string = dot > 0 ? fileName.substring(0, dot) : fileName;
    const ext: string = dot > 0 ? fileName.substring(dot) : '';
    let candidate: string = `${dir}/${fileName}`;
    let index: number = 1;
    // exists 判的是磁盘，reserve 判的是「另一首正在下」—— 两个都要过
    while ((this.exists(candidate) || this.reserved.has(candidate)) && index < 100) {
      candidate = `${dir}/${stem} (${index})${ext}`;
      index++;
    }
    this.reserved.add(candidate);
    return candidate;
  }

  /**
   * 在应用内沙箱目录开一个待写文件（1.1111.06 起唯一的落盘路径）
   *
   * 目录固定是 files/Download，重名由 reserveSandboxTarget 追加 (1)(2)，全程不需要
   * 任何权限，也不需要向系统申请授权。
   */
  private openSandboxTarget(fileName: string): WriteTarget | null {
    const target: string = this.reserveSandboxTarget(this.dir, fileName);
    const handle: fs.File | null = this.openPart(target);
    if (handle === null) {
      this.releaseReserved(target);
      return null;
    }
    return {
      path: target,
      part: `${target}${PART_SUFFIX}`,
      handle: handle,
    };
  }

  // ---------------------------------------------------------------- 队列

  private pump(): void {
    if (!this.inited) {
      return;
    }
    while (this.active < MAX_ACTIVE) {
      const next: DownloadItem | null = this.nextWaiting();
      if (next === null) {
        return;
      }
      // 自动排进来的给播放让路：播放器正等着数据（起播 / 卡顿 / 缓冲不够）就先不开工，
      // 过几秒回来看一眼。用户自己点的下载不受这条约束 —— 那是用户正在等的活儿
      // （同一套判断见 LxPlayer.canUseBandwidthForCache 与 AudioCache 的让路调度）。
      if (next.auto && !LxPlayer.getInstance().canUseBandwidthForCache()) {
        this.schedulePump();
        return;
      }
      this.active++;
      void this.startTask(next);
    }
  }

  /**
   * 下一个该开工的：用户点的下载排在自动下载前面
   *
   * 自动排进来的可以等（就是「边听边下」那批），别让它们把用户正在等的下载堵在后面。
   */
  private nextWaiting(): DownloadItem | null {
    let auto: DownloadItem | null = null;
    for (const item of this.items) {
      if (item.status !== 'waiting') {
        continue;
      }
      if (!item.auto) {
        return item;
      }
      if (auto === null) {
        auto = item;
      }
    }
    return auto;
  }

  /** 自动下载等播放缓过来时的复查（不占网络，只是过一会儿回来看一眼） */
  private schedulePump(): void {
    if (this.pumpTimer !== 0) {
      return;
    }
    this.pumpTimer = setTimeout(() => {
      this.pumpTimer = 0;
      this.pump();
    }, AUTO_WAIT_MS);
  }

  /**
   * 跑一个下载任务
   *
   * 外面这层只管「一个任务占一个并发位、结束时一定还回去」：不管中途成功、失败、
   * 被取消，还是抛了没预料到的异常，finally 里统一收尾。真正的下载逻辑在 runTask，
   * 里面所有分支都只是 return —— 不再各自去动 active，避免漏减或重复减。
   */
  private async startTask(item: DownloadItem): Promise<void> {
    try {
      await this.runTask(item);
    } catch (e) {
      this.fail(item, (e as Error).message);
    } finally {
      this.active--;
      this.persist();
      this.bump();
      this.pump();
    }
  }

  private async runTask(item: DownloadItem): Promise<void> {
    item.status = 'downloading';
    item.error = '';
    item.tagNote = '';
    item.received = 0;
    item.total = 0;
    this.bump();

    // 1) 解析播放链接（要几秒，期间可能被删掉）
    //    封面与歌词同时开跑：标签必须赶在音频数据落盘之前凑齐（见 TagSink）
    const tagsTask: Promise<DownloadTagData> =
      collectDownloadTags(item.name, item.singer, item.musicInfoJson, item.coverUrl);
    let url: string = '';
    try {
      url = await this.resolveUrl(item);
    } catch (e) {
      this.fail(item, (e as Error).message);
      return;
    }
    if (item.status !== 'downloading') {
      return;
    }
    const tags: DownloadTagData = await tagsTask;

    // 2) 打开保存位置（只有应用内沙箱一条路，见 openTarget）
    const ext: string = this.extOf(url, item.quality);
    const fileName: string = this.buildFileName(item, ext);
    item.fileName = fileName;
    let write: WriteTarget | null = null;
    try {
      write = await this.openTarget(fileName);
    } catch (e) {
      this.fail(item, `保存位置不可用：${(e as Error).message}`);
      return;
    }
    if (write === null) {
      this.fail(item, `保存目录不可用：${this.dir}`);
      return;
    }
    // 位置固定是应用内目录，不用再挂「文件管理看不到」的说明（设置页已统一说明）
    item.note = '';
    if (item.status !== 'downloading') {
      // 还没开始收数据就被取消 / 排队失效：把手柄关掉、清掉 .part、放掉占位
      this.closeQuietly(write.handle);
      this.cleanupFailed(write.part, write.path);
      return;
    }
    const target: string = write.path;
    const part: string = write.part;

    // 3) 边收边写：一律先写 `<正式名>.part`（沙箱路径同样要先写临时名），
    //    下完再在目录级串行队列里落定成正式名 —— 半成品永远不会顶着正式文件名出现。
    const file: fs.File = write.handle;
    const request: http.HttpRequest = http.createHttp();
    this.requests.set(item.key, request);
    // 封面 / 歌词跟着音频一起写进文件：mp3 写 ID3v2、flac 写元数据块（见 TagSink）
    const sink: TagSink = new TagSink(file.fd, tags);

    request.on('headersReceive', (header: Object) => {
      const length: number = asNumber((header as Record<string, Object>)['content-length']);
      if (length > 0) {
        item.total = length;
        this.bump();
      }
    });
    request.on('dataReceive', (data: ArrayBuffer) => {
      try {
        sink.write(data);
        item.received += data.byteLength;
        this.throttledBump();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'write chunk failed: %{public}s', JSON.stringify(e));
      }
    });

    try {
      const code: number = await request.requestInStream(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 20000,
        readTimeout: 300000,
      });
      // 收尾：开头还攒着的（下载太短、没认出来）补写出去
      sink.finish();
      this.closeQuietly(file);
      this.requests.delete(item.key);
      if (item.status !== 'downloading') {
        // 期间被取消：丢掉半截文件
        this.cleanupFailed(part, target);
        return;
      }
      if (code !== 200 || item.received === 0) {
        this.cleanupFailed(part, target);
        this.fail(item, `下载失败（HTTP ${code}）`);
        return;
      }
      item.tagNote = this.tagNoteOf(sink, tags, ext);
      try {
        if (part.length > 0) {
          // 收尾（part -> 正式名）走目录级的串行队列：同一目录里两首歌同时收尾时，
          // 「删旧 + 改名」这种非原子序列会交错，排他执行才不会出现「A 的正式名里
          // 是 B 的内容」。写入阶段各写各的 .part，没有竞争，不必排队。
          const dirKey: string = this.dirKeyOf(target);
          await this.runInFsQueue(dirKey, (): void => {
            this.settleFile(part, target);
          });
        }
        item.uri = target;
        item.status = 'done';
        setDownloadedFile(item.key, target);
        hilog.info(DOMAIN, TAG, 'download done: %{public}s -> %{public}s', item.name, item.fileName);
      } catch (e) {
        this.cleanupFailed(part, target);
        this.fail(item, `写入文件失败：${(e as BusinessError).message}`);
      } finally {
        this.releaseReserved(target);
      }
    } catch (e) {
      this.closeQuietly(file);
      this.cleanupFailed(part, target);
      this.requests.delete(item.key);
      if (item.status === 'downloading') {
        this.fail(item, (e as BusinessError).message);
      }
    } finally {
      try {
        request.destroy();
      } catch (e) {
        // 已销毁
      }
    }
  }

  /** 按设置里选的音质协商出链接；拓展音质失败自动退回普通音质 */
  private async resolveUrl(item: DownloadItem): Promise<string> {
    const engine = SourceEngine.getInstance();
    if (!engine.isInited()) {
      throw new Error('音源没有加载，先去「设置 - 音源设置」加载一个音源');
    }
    if (item.musicInfoJson.length === 0) {
      throw new Error('这首歌没有可解析的歌曲信息（不是平台搜索结果）');
    }
    const quality: string = pickQuality(item.musicInfoJson, item.source, item.quality);
    item.quality = quality;
    try {
      return await engine.getMusicUrl(item.musicInfoJson, quality as LxQuality, item.source);
    } catch (err) {
      const retry: string = fallbackQuality(item.musicInfoJson, item.source, quality);
      if (retry.length === 0) {
        throw err as Error;
      }
      hilog.warn(DOMAIN, TAG, 'resolve %{public}s failed, retry with %{public}s', quality, retry);
      item.quality = retry;
      return await engine.getMusicUrl(item.musicInfoJson, retry as LxQuality, item.source);
    }
  }

  /** 标记失败（只管状态，并发位的收尾在 startTask 的 finally 里） */
  private fail(item: DownloadItem, message: string): void {
    item.status = 'error';
    item.error = message;
    item.received = 0;
    item.total = 0;
  }

  /**
   * 标签嵌入结果（列表里跟「已下载」一起显示）
   *
   * 三种情况分开说：真嵌进去了就说嵌了什么；容器是我们写不了标签的（m4a 等）
   * 如实说明，免得用户以为「封面歌词没嵌进去」是下载出了问题；其余（这首歌
   * 本来就取不到封面 / 歌词）不写，那不是异常。
   */
  private tagNoteOf(sink: TagSink, tags: DownloadTagData, ext: string): string {
    if (sink.embedded()) {
      return tagSummary(tags);
    }
    return sink.knownFormat() === 'other' ? `${ext} 暂不支持写入标签` : '';
  }

  // ---------------------------------------------------------------- 文件名

  /**
   * 文件名按「设置 - 下载设置」拼
   *   格式：歌曲名 / 艺术家-标题 / 标题-艺术家（参考图里的三种）
   *   标注音质：开就把音质缀在名字后面，例如 `夜、萤火虫和你-128k.mp3`
   * 扩展名先从链接里认（很多平台会给 .mp3/.flac），认不出按音质推。
   */
  private buildFileName(item: DownloadItem, ext: string): string {
    const settings = DownloadSettings.getInstance();
    const format: string = settings.getNameFormat();
    let base: string = item.name;
    if (format === 'artist-title' && item.singer.length > 0) {
      base = `${item.singer}-${item.name}`;
    } else if (format === 'title-artist' && item.singer.length > 0) {
      base = `${item.name}-${item.singer}`;
    }
    if (settings.isMarkQuality() && item.quality.length > 0) {
      base = `${base}-${item.quality}`;
    }
    let name: string = `${sanitizeFileName(base)}.${ext}`;
    if (name.length > MAX_NAME_LEN) {
      const keep: number = MAX_NAME_LEN - ext.length - 1;
      name = `${sanitizeFileName(base).substring(0, keep > 0 ? keep : 1)}.${ext}`;
    }
    return name;
  }

  private extOf(url: string, quality: string): string {
    const queryCut: number = url.indexOf('?');
    const path: string = queryCut >= 0 ? url.substring(0, queryCut) : url;
    const dot: number = path.lastIndexOf('.');
    if (dot > 0) {
      const ext: string = path.substring(dot + 1).toLowerCase();
      if (KNOWN_EXTS.includes(ext)) {
        return ext;
      }
    }
    return EXT_BY_QUALITY[quality] !== undefined ? EXT_BY_QUALITY[quality] : 'mp3';
  }

  private exists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  private openPart(target: string): fs.File | null {
    try {
      return fs.openSync(`${target}${PART_SUFFIX}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'open part file failed: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  /**
   * 收尾：把 `<正式名>.part` 变成正式名
   *
   * 首选 rename（原子、同目录内一次完成，绝不会出现半成品顶着正式名）。
   * rename 在某些机型 / 某些 docs uri 形态上会抛（跨卷、系统对 uri rename 支持不全）：
   * 这时退回「截断重写」—— 目标先 TRUNC 清空再整块拷过去。代价是可能留半截，
   * 但调用方已把它放在目录级串行队列里，且占位没释放，别的歌不会挤同一个名字，
   * 不会出现「两首同名曲互相污染」。
   */
  private settleFile(part: string, target: string): void {
    try {
      // 目标位置理论上不存在（开写时已探测过且占着位），这里清一次只为兜残留
      this.unlinkQuietly(target);
      fs.renameSync(part, target);
      return;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'rename part failed, fallback to trunc-copy: %{public}s', JSON.stringify(e));
    }
    try {
      fs.copyFileSync(part, target);
      this.unlinkQuietly(part);
      return;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'copyFile fallback failed, use chunk copy: %{public}s', JSON.stringify(e));
    }
    const src: fs.File = fs.openSync(part, fs.OpenMode.READ_ONLY);
    let dst: fs.File | null = null;
    try {
      // TRUNC：覆盖前先把目标清空，绝不把新数据接在旧内容后面
      dst = fs.openSync(target, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      let position: number = 0;
      const buffer: ArrayBuffer = new ArrayBuffer(COPY_CHUNK);
      while (true) {
        const read: number = fs.readSync(src.fd, buffer, { offset: position, length: COPY_CHUNK });
        if (read <= 0) {
          break;
        }
        fs.writeSync(dst.fd, buffer, { offset: 0, length: read });
        position += read;
      }
      fs.fsyncSync(dst.fd);
    } finally {
      this.closeQuietly(src);
      this.closeQuietly(dst);
    }
    this.unlinkQuietly(part);
  }

  /**
   * 在某个目录的串行队列里跑一段收尾逻辑
   *
   * 同一个目录（沙箱就是沙箱目录，uri 场景就是那串目录 uri）里的收尾一次只跑一个，
   * 前一个抛错也不堵后面的（catch 掉继续链）。
   */
  private async runInFsQueue(key: string, task: () => void): Promise<void> {
    const previous: Promise<void> | undefined = this.fsQueues.get(key);
    const current: Promise<void> = (previous === undefined ? Promise.resolve() : previous.catch((): void => {
      // 前一个失败不影响后一个继续排队
    })).then((): void => {
      task();
    });
    this.fsQueues.set(key, current.catch((): void => {
      // 队列尾巴吞掉异常，避免未处理的 Promise 拒绝
    }));
    await current;
  }

  /** 某个落盘路径所属的目录（uri 与普通路径都按最后一个 `/` 切） */
  private dirOf(path: string): string {
    const cut: number = path.lastIndexOf('/');
    return cut > 0 ? path.substring(0, cut) : path;
  }

  /** 队列分组键：uri 场景用目录 uri，沙箱场景用父目录 */
  private dirKeyOf(path: string): string {
    return this.dirOf(path);
  }

  /** 失败 / 取消时清掉半截文件（uri 场景删掉那个 .part） */
  private cleanupFailed(part: string, target: string): void {
    if (part.length > 0) {
      this.unlinkQuietly(part);
    } else {
      this.unlinkQuietly(target);
    }
    // 占位一定要放掉，否则这个文件名以后永远排到 (1)(2)…
    this.releaseReserved(target);
  }

  private closeQuietly(file: fs.File | null): void {
    if (file === null) {
      return;
    }
    try {
      fs.closeSync(file);
    } catch (e) {
      // 关不上就算了
    }
  }

  private unlinkQuietly(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      // 不存在或没权限，忽略
    }
  }

  // ---------------------------------------------------------------- 落盘 / 通知

  private loadIndex(): void {
    clearDownloadedFiles();
    let text: string = '';
    try {
      const path: string = `${this.dir}/${INDEX_FILE}`;
      if (fs.accessSync(path)) {
        text = fs.readTextSync(path);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'read download index failed: %{public}s', JSON.stringify(e));
    }
    if (text.length === 0) {
      return;
    }
    try {
      const data: DownloadIndexData = JSON.parse(text) as DownloadIndexData;
      if (data.version !== INDEX_VERSION || data.items === undefined) {
        return;
      }
      const kept: DownloadItem[] = [];
      for (const raw of data.items) {
        const item: DownloadItem = raw;
        // 老文件可能没有这几个字段（tagNote / auto 都是后加的）
        item.note = orEmpty(item.note);
        item.tagNote = orEmpty(item.tagNote);
        item.auto = item.auto === true;
        // 重启时正在下的那些没法接着下（链接带时效），标成可重试
        if (item.status === 'downloading' || item.status === 'waiting') {
          item.status = 'error';
          item.error = '上次没下完（应用重启过），可以重新下载';
          item.received = 0;
        }
        if (item.status === 'done') {
          if (item.uri.length === 0) {
            item.status = 'error';
            item.error = '文件找不到了（可能被清理过）';
          } else if (this.exists(item.uri)) {
            setDownloadedFile(item.key, item.uri);
          } else {
            item.status = 'error';
            item.error = '文件找不到了（可能被清理过）';
          }
        }
        kept.push(item);
      }
      this.items = kept;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse download index failed: %{public}s', JSON.stringify(e));
    }
  }

    private persist(): void {
    if (!this.inited) {
      return;
    }
    if (this.persistTimer !== 0) {
      return;
    }
    // 合并短时间内的多次写（批量下载时会连续变状态）
    this.persistTimer = setTimeout(() => {
      this.persistTimer = 0;
      this.writeIndex();
    }, 500);
  }

  private writeIndex(): void {
    const data: DownloadIndexData = { version: INDEX_VERSION, items: this.items };
    try {
      const path: string = `${this.dir}/${INDEX_FILE}`;
      const handle = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(handle.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(handle);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'write download index failed: %{public}s', JSON.stringify(e));
    }
  }

  private bump(): void {
    this.lastBumpAt = Date.now();
    AppStorage.setOrCreate(K_DOWNLOAD_VERSION, this.lastBumpAt);
  }

  private throttledBump(): void {
    const now: number = Date.now();
    if (now - this.lastBumpAt < PROGRESS_THROTTLE_MS) {
      return;
    }
    this.bump();
  }
}
