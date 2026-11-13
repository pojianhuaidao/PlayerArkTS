import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'TvCacheStore';
const DOMAIN: number = 0x0001;

/** 播放记录缓存上限（条），超出按修改时间删最旧的 */
const MAX_ENTRIES: number = 200;

/** 缓存条目及其最后修改时间 */
interface CacheEntry {
  path: string;
  mtime: number;
}

/**
 * TV / 网络播放缓存仓库
 *
 * 落盘位置：{filesDir}/tv_cache
 *   play/<sha1>.json   每个播放地址的解析结果缓存（真实播放 url、请求头、剧集名、清晰度、时间戳）
 *
 * 用途：
 *   1. 起播前若命中同一个原始地址，可直接复用上次解析出的直链与请求头，少一次嗅探/解析；
 *   2. 这是 TV / 网络播放产生的、可独立统计与清除的磁盘缓存，
 *      CacheCleaner 已把 {filesDir}/tv_cache 纳入统计与清理范围。
 *
 * 注意：AVPlayer 播放 http(s) 流产生的缓冲分片由媒体框架写在 {cacheDir}，
 * 同样由 CacheCleaner 递归统计与清理，两者共同构成「TV 播放缓存」。
 */
export class TvCacheStore {
  private static baseDir: string = '';

  private static subDir(kind: string): string {
    return `${TvCacheStore.baseDir}/${kind}`;
  }

  private static ensureDir(path: string): boolean {
    try {
      if (!fs.accessSync(path)) {
        fs.mkdirSync(path, true);
      }
      return true;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'mkdir failed: %{public}s', path);
      return false;
    }
  }

  /** 由播放页在 aboutToAppear 用 context.filesDir 初始化 */
  static init(context: common.Context): void {
    TvCacheStore.baseDir = `${context.filesDir}/tv_cache`;
  }

  /** FNV-1a 32 位散列，避免文件名里出现 url 特殊字符 */
  private static hash(input: string): string {
    let h: number = 0x811c9dc5;
    for (let i: number = 0; i < input.length; i++) {
      h = h ^ input.charCodeAt(i);
      h = (h * 0x01000193) >>> 0;
    }
    return h.toString(16).padStart(8, '0');
  }

  static isReady(): boolean {
    return TvCacheStore.baseDir.length > 0;
  }

  /**
   * 记录一次播放（起播时调用），写入 play/<hash>.json。
   * 只做尽力而为的落盘，失败不影响播放。
   */
  static recordPlayback(originUrl: string, playUrl: string, title: string, headers?: Record<string, string>): void {
    if (!TvCacheStore.isReady() || originUrl.length === 0) {
      return;
    }
    const dir: string = TvCacheStore.subDir('play');
    if (!TvCacheStore.ensureDir(dir)) {
      return;
    }
    const file: string = `${dir}/${TvCacheStore.hash(originUrl)}.json`;
    const headerObj: Record<string, string> = headers ?? {};
    const payload: string = JSON.stringify({
      url: originUrl,
      play: playUrl,
      title: title,
      headers: headerObj,
      ts: Date.now()
    });
    try {
      const f = fs.openSync(file, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, payload);
      fs.closeSync(f);
      TvCacheStore.prune(dir);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'recordPlayback write failed');
    }
  }

  /** 读取播放缓存，未命中返回 null */
  static readPlayback(originUrl: string): Record<string, Object> | null {
    if (!TvCacheStore.isReady() || originUrl.length === 0) {
      return null;
    }
    const file: string = `${TvCacheStore.subDir('play')}/${TvCacheStore.hash(originUrl)}.json`;
    try {
      if (!fs.accessSync(file)) {
        return null;
      }
      const text: string = fs.readTextSync(file);
      return JSON.parse(text) as Record<string, Object>;
    } catch (e) {
      return null;
    }
  }

  /** 条目数超上限时删除最旧的文件 */
  private static prune(dir: string): void {
    try {
      const names: string[] = fs.listFileSync(dir);
      if (names.length <= MAX_ENTRIES) {
        return;
      }
      const items: CacheEntry[] = [];
      for (const name of names) {
        const full: string = `${dir}/${name}`;
        try {
          items.push({ path: full, mtime: fs.statSync(full).mtime * 1000 });
        } catch (e) {
        }
      }
      items.sort((a: CacheEntry, b: CacheEntry): number => {
        return a.mtime - b.mtime;
      });
      const overflow: number = items.length - MAX_ENTRIES;
      for (let i: number = 0; i < overflow; i++) {
        try {
          fs.unlinkSync(items[i].path);
        } catch (e) {
        }
      }
    } catch (e) {
    }
  }

  /** 清理缓存前让内存态失效（磁盘文件由 CacheCleaner 统一删除） */
  static clearIndex(): void {
    // 本仓库无内存索引，占位以便 CacheCleaner 统一调用
  }
}
