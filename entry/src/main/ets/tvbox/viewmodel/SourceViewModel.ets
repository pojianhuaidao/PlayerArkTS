/**
 * 源 ViewModel
 * 业务逻辑层: 首页/分类/详情/搜索/播放
 */
import { AbsXml, VodInfo, VodItem, PlayInfo, emptyAbsXml, HomeResult } from '../model/Movie';
import { MovieSort, SortData, applyCategoryOrder } from '../model/MovieSort';
import { getApiConfig } from '../api/ApiConfig';
import { parseXmlHome, parseXmlCategory, parseXmlDetail, parseXmlSearch } from '../api/XmlParser';
import { parseJsonHome, parseJsonCategory, parseJsonDetail, parseJsonSearch } from '../api/JsonParser';
import { formatError } from '../utils/HttpUtil';
import { PanConfig } from '../utils/PanConfig';
import { detectPanByFlag } from '../util/PanDetector';
import { syncCredentialToBackend } from '../util/BackendSync';

export class SourceViewModel {

  static async getHomeContent(sourceKey: string): Promise<HomeResult> {
    const config = getApiConfig();
    const spider = config.getSpider(sourceKey);
    const bean = config.getSource(sourceKey);
    if (!bean) throw new Error('源不存在');

    const content = await spider.homeContent(true);
    let result: HomeResult;

    // JS sources (type=3 or api ends with .js) always return JSON
    const isJsSource: boolean = bean.api.endsWith('.js') || bean.api.includes('.js?');
    if (bean.type === 0 && !isJsSource) {
      result = parseXmlHome(content);
    } else {
      result = parseJsonHome(content);
    }

    result.list.sourceKey = sourceKey;
    for (const v of result.list.videoList) {
      v.sourceKey = sourceKey;
    }

    // 首页推荐: JS 源需要主动拉一次推荐列表
    // real recommend list from homeVod() (e.g. Douban hot). home() usually only
    // returns categories plus at most a placeholder item, so we must call homeVod
    // whenever home() didn't return a proper recommend list (> 1 items).
    // CMS 采集源(ac=list)只返回分类和无封面的列表，需要用 ac=detail 补全带封面的推荐。
    const homeHasPic: boolean = result.list.videoList.some((v: VodItem): boolean => v.pic.length > 0);
    const needRec: boolean = isJsSource || bean.type === 3 || !homeHasPic;
    if (needRec && (result.list.videoList.length <= 1 || !homeHasPic)) {
      try {
        const recContent = await spider.homeVideoContent();
        if (recContent.length > 0) {
          const isXmlSource: boolean = bean.type === 0 && !isJsSource;
          const recResult = isXmlSource ? parseXmlCategory(recContent) : parseJsonCategory(recContent);
          recResult.sourceKey = sourceKey;
          for (const rv of recResult.videoList) {
            rv.sourceKey = sourceKey;
          }
          const recHasPic: boolean = recResult.videoList.some((v: VodItem): boolean => v.pic.length > 0);
          // 推荐列表更长，或当前列表无封面而推荐有封面时，用推荐列表替换
          if (recResult.videoList.length > result.list.videoList.length || (recHasPic && !homeHasPic)) {
            result.list = recResult;
          }
        }
      } catch (_e) {
        console.warn('[SourceViewModel] homeVideoContent failed: ' + String(_e));
      }
    }

    // 用 filter.init 作为每个分类的默认 filterSelect，避免所有分类都返回相同的默认列表
    // (与 Android TVBox 一致：categoryContent 首次调用会带上 init 值)
    for (const sd of result.sort.sortList) {
      for (const fi of sd.filters) {
        if (fi.init && fi.init.length > 0 && !sd.filterSelect.has(fi.key)) {
          sd.filterSelect.set(fi.key, fi.init);
        }
      }
    }

    if (bean.categories && bean.categories.length > 0) {
      applyCategoryOrder(result.sort, bean.categories);
    }

    return result;
  }

  static async getCategoryContent(
    sourceKey: string,
    tid: string,
    page: number,
    extend: Map<string, string>
  ): Promise<AbsXml> {
    const config = getApiConfig();
    const spider = config.getSpider(sourceKey);
    const bean = config.getSource(sourceKey);
    if (!bean) throw new Error('源不存在');

    const content = await spider.categoryContent(tid, page, extend);
    let result: AbsXml;

    const isJsSourceCat: boolean = bean.api.endsWith('.js') || bean.api.includes('.js?');
    if (bean.type === 0 && !isJsSourceCat) {
      result = parseXmlCategory(content);
    } else {
      result = parseJsonCategory(content);
    }

    result.sourceKey = sourceKey;
    for (const v of result.videoList) {
      v.sourceKey = sourceKey;
    }
    return result;
  }

  static async getDetailContent(sourceKey: string, ids: string[]): Promise<VodInfo | null> {
    const config = getApiConfig();
    const spider = config.getSpider(sourceKey);
    const bean = config.getSource(sourceKey);
    if (!bean) throw new Error('源不存在');

    const content = await spider.detailContent(ids);
    let info: VodInfo | null;

    const isJsSourceDet: boolean = bean.api.endsWith('.js') || bean.api.includes('.js?');
    if (bean.type === 0 && !isJsSourceDet) {
      info = parseXmlDetail(content);
    } else {
      info = parseJsonDetail(content);
    }

    if (info) {
      info.sourceKey = sourceKey;
    }
    return info;
  }

  static async searchContent(
    sourceKey: string,
    keyword: string,
    quick: boolean,
    page?: number
  ): Promise<AbsXml> {
    const config = getApiConfig();
    const spider = config.getSpider(sourceKey);
    const bean = config.getSource(sourceKey);
    if (!bean) throw new Error('源不存在');

    const content = await spider.searchContent(keyword, quick, page);
    let result: AbsXml;

    const isJsSourceSch: boolean = bean.api.endsWith('.js') || bean.api.includes('.js?');
    if (bean.type === 0 && !isJsSourceSch) {
      result = parseXmlSearch(content);
    } else {
      result = parseJsonSearch(content);
    }

    result.sourceKey = sourceKey;
    for (const v of result.videoList) {
      v.sourceKey = sourceKey;
    }
    return result;
  }

  static async multiSearch(
    sourceKeys: string[],
    keyword: string,
    timeoutMs: number = 8000
  ): Promise<AbsXml[]> {
    const tasks: Promise<AbsXml>[] = [];
    for (const key of sourceKeys) {
      const task = SourceViewModel.searchWithTimeout(key, keyword, timeoutMs);
      tasks.push(task);
    }
    const results = await Promise.allSettled(tasks);
    const list: AbsXml[] = [];
    for (const r of results) {
      if (r.status === 'fulfilled' && r.value.videoList.length > 0) {
        list.push(r.value);
      }
    }
    return list;
  }

  static multiSearchStream(
    sourceKeys: string[],
    keyword: string,
    timeoutMs: number,
    onEach: (key: string, xml: AbsXml, err: string) => void,
    onDone: () => void
  ): void {
    let remaining: number = sourceKeys.length;
    if (remaining === 0) { onDone(); return; }
    for (const key of sourceKeys) {
      SourceViewModel.searchWithTimeout(key, keyword, timeoutMs)
        .then((xml: AbsXml): void => {
          try { onEach(key, xml, ''); } catch (_e) {}
          remaining--;
          if (remaining <= 0) { try { onDone(); } catch (_e2) {} }
        })
        .catch((e: Error): void => {
          try { onEach(key, emptyAbsXml(), formatError(e)); } catch (_e) {}
          remaining--;
          if (remaining <= 0) { try { onDone(); } catch (_e2) {} }
        });
    }
  }

  private static async searchWithTimeout(
    sourceKey: string,
    keyword: string,
    timeoutMs: number
  ): Promise<AbsXml> {
    return new Promise<AbsXml>((resolve) => {
      const timer = setTimeout(() => {
        resolve(emptyAbsXml());
      }, timeoutMs);

      SourceViewModel.searchContent(sourceKey, keyword, false)
        .then((result: AbsXml) => {
          clearTimeout(timer);
          resolve(result);
        })
        .catch(() => {
          clearTimeout(timer);
          resolve(emptyAbsXml());
        });
    });
  }

  /** App 优先时，确保 T4 后端使用 App 侧最新网盘凭证 */
  private static async ensurePanCredential(flag: string): Promise<void> {
    const hit = detectPanByFlag(flag);
    if (!hit) return;
    const source = await PanConfig.getCredentialSource(hit.kind);
    if (source !== 'app') return;
    const cred = await PanConfig.get(hit.kind);
    const value: string = hit.kind === 'ali' ? cred.token : cred.cookie;
    if (value.length === 0) return;
    await syncCredentialToBackend(hit.kind, value);
  }

  static async getPlayContent(
    sourceKey: string,
    flag: string,
    id: string
  ): Promise<PlayInfo | null> {
    await SourceViewModel.ensurePanCredential(flag);
    const config = getApiConfig();
    const spider = config.getSpider(sourceKey);
    return await spider.playerContent(flag, id);
  }

  private static pendingPlayPromise: Promise<PlayInfo | null> | null = null;

  static prefetchPlayContent(sourceKey: string, flag: string, id: string): void {
    SourceViewModel.pendingPlayPromise = SourceViewModel.getPlayContent(sourceKey, flag, id);
  }

  static async getPlayContentWithPrefetch(
    sourceKey: string,
    flag: string,
    id: string
  ): Promise<PlayInfo | null> {
    if (SourceViewModel.pendingPlayPromise) {
      const promise = SourceViewModel.pendingPlayPromise;
      SourceViewModel.pendingPlayPromise = null;
      try {
        return await promise;
      } catch (_e) {
        // Fall through to fresh request
      }
    }
    return await SourceViewModel.getPlayContent(sourceKey, flag, id);
  }
}
