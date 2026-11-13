/**
 * 搜索助手
 * 管理搜索历史、热搜词、 API 历史
 */
import { PreferencesUtil } from '../utils/PreferencesUtil';

const PREF_KEY_SEARCH_HISTORY: string = 'search_history';
const PREF_KEY_API_HISTORY: string = 'api_history';
const PREF_KEY_LIVE_API_HISTORY: string = 'live_api_history';
const MAX_HISTORY: number = 20;

const DEFAULT_HOT_WORDS: string[] = [
  '新闻', '体育', '电影', '电视剧', '综艺',
  '动漫', '纪录片', '教育', '少儿', '旅游'
];

export class SearchHelper {
  /** 获取搜索历史 */
  static async getSearchHistory(): Promise<string[]> {
    const json: string = await PreferencesUtil.get(PREF_KEY_SEARCH_HISTORY, '');
    if (json.length === 0) return [];
    try {
      return JSON.parse(json) as string[];
    } catch (_e) {
      return [];
    }
  }

  /** 添加搜索历史 */
  static async addSearchHistory(keyword: string): Promise<void> {
    if (keyword.trim().length === 0) return;
    let history: string[] = await SearchHelper.getSearchHistory();
    // 去重
    history = history.filter((s: string): boolean => s !== keyword);
    history.unshift(keyword);
    if (history.length > MAX_HISTORY) history = history.slice(0, MAX_HISTORY);
    await PreferencesUtil.put(PREF_KEY_SEARCH_HISTORY, JSON.stringify(history));
  }

  /** 删除单条搜索历史 */
  static async removeSearchHistory(keyword: string): Promise<void> {
    let history: string[] = await SearchHelper.getSearchHistory();
    history = history.filter((s: string): boolean => s !== keyword);
    await PreferencesUtil.put(PREF_KEY_SEARCH_HISTORY, JSON.stringify(history));
  }

  /** 清空搜索历史 */
  static async clearSearchHistory(): Promise<void> {
    await PreferencesUtil.put(PREF_KEY_SEARCH_HISTORY, '');
  }

  /** 获取默认热搜词 */
  static getHotWords(): string[] {
    return DEFAULT_HOT_WORDS.slice();
  }

  /** 获取 API 配置历史 */
  static async getApiHistory(): Promise<string[]> {
    const json: string = await PreferencesUtil.get(PREF_KEY_API_HISTORY, '');
    if (json.length === 0) return [];
    try {
      return JSON.parse(json) as string[];
    } catch (_e) {
      return [];
    }
  }

  /** 添加 API 历史 */
  static async addApiHistory(url: string): Promise<void> {
    if (url.trim().length === 0) return;
    let history: string[] = await SearchHelper.getApiHistory();
    history = history.filter((s: string): boolean => s !== url);
    history.unshift(url);
    if (history.length > MAX_HISTORY) history = history.slice(0, MAX_HISTORY);
    await PreferencesUtil.put(PREF_KEY_API_HISTORY, JSON.stringify(history));
  }

  /** 获取直播 API 历史 */
  static async getLiveApiHistory(): Promise<string[]> {
    const json: string = await PreferencesUtil.get(PREF_KEY_LIVE_API_HISTORY, '');
    if (json.length === 0) return [];
    try {
      return JSON.parse(json) as string[];
    } catch (_e) {
      return [];
    }
  }

  /** 添加直播 API 历史 */
  static async addLiveApiHistory(url: string): Promise<void> {
    if (url.trim().length === 0) return;
    let history: string[] = await SearchHelper.getLiveApiHistory();
    history = history.filter((s: string): boolean => s !== url);
    history.unshift(url);
    if (history.length > MAX_HISTORY) history = history.slice(0, MAX_HISTORY);
    await PreferencesUtil.put(PREF_KEY_LIVE_API_HISTORY, JSON.stringify(history));
  }
}
