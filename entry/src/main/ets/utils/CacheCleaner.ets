import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { emitter } from '@kit.BasicServicesKit';
import { AudioCache } from '../lx/core/music/AudioCache';
import { MediaCache } from '../lx/core/music/MediaCache';
import { storageRootDir } from '../lx/core/common/StoragePaths';
import { ThumbnailLoader } from './ThumbnailLoader';
import { TvCacheStore } from './TvCacheStore';

const TAG: string = 'CacheCleaner';
const DOMAIN: number = 0x0001;

/** 清理开始前广播：正在播放的本地/网络(TV)播放器收到后 stop + reset，释放 AVPlayer 缓冲句柄 */
export const CACHE_PREPARE_EVENT_ID: string = 'player_cache_prepare';
/** 清理结束后广播 */
export const CACHE_DONE_EVENT_ID: string = 'player_cache_done';

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/**
 * 音视频缓存清理
 *
 * 只清理「可以重新下载/重新生成」的缓存，覆盖五个落盘点：
 *   1. {数据根}/lx_media_audio   音乐播放流缓存（AudioCache，切歌即失效）
 *   2. {数据根}/lx_media_cache   音乐取链地址 / 封面地址 / 歌词缓存（MediaCache）
 *   3. {filesDir}/subtitles      在线字幕下载缓存（SubtitleFinder）
 *   4. {filesDir}/tv_cache       TV / 网络播放缓存（TvCacheStore：播放地址、请求头、分片清单）
 *   5. {cacheDir}                应用系统缓存目录：AVPlayer 播放 http(s) 流的缓冲分片、
 *                                @ohos.net.http usingCache 响应缓存（TV 海报墙图片）等，递归统计
 *
 * 明确不动：local_music（本地音乐索引与封面）、webdav_music（网盘库索引）、
 * lx_sources（用户导入的音源脚本）、Download（用户下载的歌曲）、
 * local_videos（已导入的本地视频），这些是用户数据，清掉就得重新导入，不属于「缓存」。
 */
export class CacheCleaner {
  /** TV / 网络播放缓存目录（filesDir 下，与用户数据隔离） */
  static tvCacheDir(context: common.Context): string {
    return `${context.filesDir}/tv_cache`;
  }

  private static cacheDirs(context: common.Context): string[] {
    const root: string = storageRootDir(context);
    return [
      `${root}/lx_media_audio`,
      `${root}/lx_media_cache`,
      `${context.filesDir}/subtitles`,
      CacheCleaner.tvCacheDir(context),
      context.cacheDir
    ];
  }

  private static dirSize(path: string): number {
    let total: number = 0;
    try {
      if (!fs.accessSync(path)) {
        return 0;
      }
    } catch (e) {
      return 0;
    }
    let names: string[] = [];
    try {
      names = fs.listFileSync(path);
    } catch (e) {
      return 0;
    }
    for (const name of names) {
      const full: string = `${path}/${name}`;
      try {
        const st: fs.Stat = fs.statSync(full);
        if (st.isDirectory()) {
          total += CacheCleaner.dirSize(full);
        } else {
          total += st.size;
        }
      } catch (e) {
      }
    }
    return total;
  }

  /** 递归删除目录内容（保留目录本身），返回删掉的字节数；删不掉的路径收集进 failed 待重试 */
  private static purge(path: string, failed: string[]): number {
    let freed: number = 0;
    let names: string[] = [];
    try {
      if (!fs.accessSync(path)) {
        return 0;
      }
      names = fs.listFileSync(path);
    } catch (e) {
      return 0;
    }
    for (const name of names) {
      const full: string = `${path}/${name}`;
      let isDir: boolean = false;
      let size: number = 0;
      try {
        const st: fs.Stat = fs.statSync(full);
        isDir = st.isDirectory();
        size = st.size;
      } catch (e) {
        continue;
      }
      if (isDir) {
        freed += CacheCleaner.purge(full, failed);
        try {
          fs.rmdirSync(full);
        } catch (e) {
        }
      } else {
        try {
          fs.unlinkSync(full);
          freed += size;
        } catch (e) {
          // 被媒体服务占用的缓存文件（TV/网络流缓冲）首轮可能删不掉，记录下来重试
          failed.push(full);
        }
      }
    }
    return freed;
  }

  /** 缓存总占用（字节） */
  static measure(context: common.Context): number {
    let total: number = 0;
    for (const dir of CacheCleaner.cacheDirs(context)) {
      total += CacheCleaner.dirSize(dir);
    }
    return total;
  }

  /** TV / 网络播放缓存占用（字节），设置页单独展示 */
  static measureTv(context: common.Context): number {
    return CacheCleaner.dirSize(CacheCleaner.tvCacheDir(context));
  }

  /** 在线视频缓存占用（字节）：tv_cache + cacheDir 里 AVPlayer 拉 http(s) 流留下的缓冲分片 */
  static measureOnline(context: common.Context): number {
    return CacheCleaner.dirSize(CacheCleaner.tvCacheDir(context)) + CacheCleaner.dirSize(context.cacheDir);
  }

  /**
   * 只清「在线视频缓存」：tv_cache（在线视频播放地址 / 请求头 / 分片清单）
   * + cacheDir 里 AVPlayer 拉在线流的缓冲分片。
   * 不动音乐流缓存、封面歌词、字幕、本地视频与用户数据，属于「记忆」组里的单项清理。
   */
  static async clearOnline(context: common.Context): Promise<number> {
    let freed: number = 0;
    try {
      emitter.emit(CACHE_PREPARE_EVENT_ID);
      await sleep(450);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'emit cache prepare failed');
    }
    try {
      ThumbnailLoader.clear();
    } catch (e) {
    }
    try {
      TvCacheStore.clearIndex();
    } catch (e) {
    }
    const failed: string[] = [];
    const dirs: string[] = [CacheCleaner.tvCacheDir(context), context.cacheDir];
    for (const dir of dirs) {
      freed += CacheCleaner.purge(dir, failed);
    }
    if (failed.length > 0) {
      await sleep(300);
      for (const path of failed) {
        try {
          const st: fs.Stat = fs.statSync(path);
          fs.unlinkSync(path);
          freed += st.size;
        } catch (e) {
        }
      }
    }
    try {
      emitter.emit(CACHE_DONE_EVENT_ID);
    } catch (e) {
    }
    hilog.info(DOMAIN, TAG, 'online video cache cleared: %{public}d bytes', freed);
    return freed;
  }

  /** 占用大小的可读文案 */
  static sizeText(bytes: number): string {
    if (bytes <= 0) {
      return '0 B';
    }
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    const kb: number = bytes / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB`;
    }
    const mb: number = kb / 1024;
    if (mb < 1024) {
      return `${mb.toFixed(1)} MB`;
    }
    return `${(mb / 1024).toFixed(2)} GB`;
  }

  /**
   * 清理全部音视频缓存，返回释放的字节数。
   * 顺序：先广播让正在播放的播放器 stop + reset（释放 AVPlayer 缓冲的文件句柄）
   * → 内存侧索引失效 → 删磁盘文件 → 首轮失败的再重试一次。
   * 不先释放播放器的话，正在播放的 TV / 网络流缓存分片被媒体服务持有，
   * unlink 静默失败、界面显示已清除但空间没变（TV 缓存清不掉的根因）。
   */
  static async clear(context: common.Context): Promise<number> {
    let freed: number = 0;

    // 0. 通知播放器释放缓冲
    try {
      emitter.emit(CACHE_PREPARE_EVENT_ID);
      await sleep(450);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'emit cache prepare failed');
    }

    // 1. 内存索引与图片
    try {
      ThumbnailLoader.clear();
    } catch (e) {
    }
    try {
      MediaCache.getInstance().clearMusicUrls();
      MediaCache.getInstance().clearPics();
      MediaCache.getInstance().clearLyrics();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'media cache index clear failed');
    }
    try {
      AudioCache.getInstance().clear();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'audio cache clear failed');
    }
    try {
      TvCacheStore.clearIndex();
    } catch (e) {
    }

    // 2. 磁盘（AudioCache.clear 已删过音频目录，再扫一遍把残留的 .part 等一起收掉）
    const failed: string[] = [];
    for (const dir of CacheCleaner.cacheDirs(context)) {
      freed += CacheCleaner.purge(dir, failed);
    }

    // 3. 首轮删不掉的（reset 后句柄回收有延迟）重试一次
    if (failed.length > 0) {
      await sleep(300);
      for (const path of failed) {
        try {
          const st: fs.Stat = fs.statSync(path);
          fs.unlinkSync(path);
          freed += st.size;
        } catch (e) {
        }
      }
    }

    try {
      emitter.emit(CACHE_DONE_EVENT_ID);
    } catch (e) {
    }
    hilog.info(DOMAIN, TAG, 'cache cleared: %{public}d bytes, first-round failures: %{public}d',
      freed, failed.length);
    return freed;
  }
}
