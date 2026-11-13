/**
 * 热门搜索助手：抓取豆瓣热门电影/电视片名作为搜索建议
 * 使用 6 小时本地缓存，尽量减少网络请求
 */
import { httpGet } from './HttpUtil';
import { PreferencesUtil } from './PreferencesUtil';
import { hilog } from '@kit.PerformanceAnalysisKit';

const CACHE_KEY: string = 'hot_search_words_cache';
const CACHE_TS_KEY: string = 'hot_search_words_cache_ts';
const CACHE_TTL_MS: number = 6 * 60 * 60 * 1000; // 6 小时
const DOMAIN: number = 0x0001;
const TAG: string = 'HotSearch';

interface DoubanSubject {
  title: string;
}

interface DoubanResp {
  subjects: DoubanSubject[];
}

export class HotSearchHelper {
  /** 读取本地缓存的热词列表；无缓存或过期则返回空数组 */
  static async getCached(): Promise<string[]> {
    try {
      const raw: string = await PreferencesUtil.get(CACHE_KEY, '');
      const tsStr: string = await PreferencesUtil.get(CACHE_TS_KEY, '');
      if (raw.length === 0 || tsStr.length === 0) return [];
      const ts: number = parseInt(tsStr, 10);
      if (isNaN(ts)) return [];
      if (Date.now() - ts > CACHE_TTL_MS) return [];
      const arr: string[] = JSON.parse(raw) as string[];
      return Array.isArray(arr) ? arr : [];
    } catch (_e) {
      return [];
    }
  }

  /** 从豆瓣拉取热门电影/电视片名，去重合并；失败则返回空数组 */
  static async fetchFromDouban(): Promise<string[]> {
    const merged: string[] = [];
    const seen: Set<string> = new Set<string>();
    const urls: string[] = [
      'https://movie.douban.com/j/search_subjects?type=tv&tag=热门&sort=recommend&page_limit=20&page_start=0',
      'https://movie.douban.com/j/search_subjects?type=movie&tag=热门&sort=recommend&page_limit=20&page_start=0'
    ];
    for (const url of urls) {
      try {
        const headers: Map<string, string> = new Map();
        headers.set('User-Agent', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15');
        headers.set('Referer', 'https://movie.douban.com/');
        const body: string = await httpGet(url, headers);
        const obj: DoubanResp = JSON.parse(body) as DoubanResp;
        const subs: DoubanSubject[] = obj && obj.subjects ? obj.subjects : [];
        for (const s of subs) {
          const t: string = (s && s.title ? s.title : '').trim();
          if (t.length === 0) continue;
          if (seen.has(t)) continue;
          seen.add(t);
          merged.push(t);
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'douban hot fetch failed: %{public}s', JSON.stringify(e) ?? '');
      }
    }
    return merged.slice(0, 20);
  }

  /** 优先读缓存；缓存过期/为空时联网刷新并写回缓存。任何失败都返回已有数据（可能是空）。 */
  static async getHotWords(forceRefresh: boolean = false): Promise<string[]> {
    if (!forceRefresh) {
      const cached: string[] = await HotSearchHelper.getCached();
      if (cached.length > 0) return cached;
    }
    const fresh: string[] = await HotSearchHelper.fetchFromDouban();
    if (fresh.length > 0) {
      await PreferencesUtil.put(CACHE_KEY, JSON.stringify(fresh));
      await PreferencesUtil.put(CACHE_TS_KEY, String(Date.now()));
      return fresh;
    }
    // 网络失败：兜底返回旧缓存（即便过期）
    try {
      const raw: string = await PreferencesUtil.get(CACHE_KEY, '');
      if (raw.length > 0) {
        const arr: string[] = JSON.parse(raw) as string[];
        return Array.isArray(arr) ? arr : [];
      }
    } catch (_e) {}
    return [];
  }
}