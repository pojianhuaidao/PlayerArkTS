/**
 * API 配置管理
 * 加?解?管理视频源、解析规则、直播配置、代理规
 */
import { SourceBean, isSearchable } from '../model/SourceBean';
import { ParseBean } from '../model/ParseBean';
import { ProxyRule, parseProxyRules } from '../model/ProxyRule';
import { IJKCode } from '../model/IJKCode';
import { LiveChannelGroup } from '../model/LiveChannel';
import { httpGet, formatError } from '../utils/HttpUtil';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { findResult, isJson } from '../util/AESUtil';
import { safeJsonString, safeJsonInt, safeJsonStringList, safeJsonObject, safeJsonArray, trimJsonObject, fixContentPath } from '../util/DefaultConfig';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Spider } from './Spider';
import { JsSpider } from './JsSpider';
import { T4Spider } from './T4Spider';
import { Gz360Spider } from './Gz360Spider';
import { SilidmSpider } from './SilidmSpider';
import { DubokuSpider } from './DubokuSpider';
import { MhysSpider } from './MhysSpider';

const PREF_KEY_CONFIG_URL = 'config_url';
const PREF_KEY_CURRENT_SOURCE = 'current_source_key';
const PREF_KEY_CONFIG_JSON = 'config_json';
const PREF_KEY_DEFAULT_PARSE = 'default_parse';
const PREF_KEY_LIVE_API_URL = 'live_api_url';
const PREF_KEY_HOME_API = 'home_api';
const PREF_KEY_FILTER_NONVIDEO = 'filter_nonvideo';
const PREF_KEY_SOURCE_FILTER_KEYWORDS = 'source_filter_keywords';
const PREF_KEY_HIDE_EMPTY_SOURCES = 'hide_empty_sources';
const PREF_KEY_EMPTY_SOURCE_KEYS = 'empty_source_keys';
const PREF_KEY_USE_BUILTIN_SOURCE = 'use_builtin_source';
const PREF_KEY_USE_BUILTIN_LIVE = 'use_builtin_live';

interface ConfigJson {
  spider: string;
  jarCache: string;
  wallpaper: string;
  homepage: string;
  sites: SourceBean[];
  parses: ParseBean[];
  flags: string[];
  hosts: Map<string, string>;
  lives: Object[];
  doh: Object[];
  ads: string[];
  rules: Object[];
  proxyRules: ProxyRule[];
}

export class ApiConfig {
  private static instance: ApiConfig | null = null;
  private sourceBeanList: Map<string, SourceBean> = new Map();
  private sourceKeyList: string[] = [];
  /** 内置源 key 集合（来自 rawfile/config_default.json），供"内置播放源"开关显隐过滤 */
  private builtinSourceKeys: Set<string> = new Set<string>();
  private homeSourceKey: string = '';
  private spiders: Map<string, Spider> = new Map();
  private jsSpiders: Map<string, JsSpider> = new Map();
  private configLoaded: boolean = false;
  private wallpaper: string = '';
  private homepageConfig: string = '';
  private spider: string = '';
  private jarCache: string = 'true';
  private vipParseFlags: string[] = [];
  private parseBeanList: ParseBean[] = [];
  private defaultParse: ParseBean | null = null;
  private myHosts: Map<string, string> = new Map();
  private liveChannelGroupList: LiveChannelGroup[] = [];
  private proxyRules: ProxyRule[] = [];
  private ijkCodes: IJKCode[] = [];
  private searchSourceBeanList: SourceBean[] = [];
  private loadedLiveConfigUrl: string = '';
  private adHosts: Set<string> = new Set();
  private liveUrl: string = '';
  private emptySourceKeys: Set<string> = new Set<string>();
  private emptyKeysLoaded: boolean = false;
  private lastFailedConfigUrls: string[] = [];

  private constructor() {}

  static getInstance(): ApiConfig {
    if (!ApiConfig.instance) {
      ApiConfig.instance = new ApiConfig();
    }
    return ApiConfig.instance;
  }

  /** Check if a source api is usable on HarmonyOS (HTTP CMS or JS file, not JAR/csp_) */
  private isUsableSource(bean: SourceBean): boolean {
    const api: string = bean.api;
    if (api.startsWith('http://') || api.startsWith('https://')) {
      return true;
    }
    if (api.endsWith('.js') || api.includes('.js?')) {
      return true;
    }
    return false;
  }

  /** Default config URL (empty means require user input) */
  private getDefaultConfigUrl(): string {
    return '';
  }

  /** 解析配置 URL, 提?;pk; 密?*/
  private tempKey: string | null = null;

  /** 规范化用户输入的 URL：修正全??中文标点、零宽字符、首尾空白?*/
  private normalizeUrl(raw: string): string {
    let s: string = raw;
    // 去除零宽字符BOM
    s = s.replace(/[\u200B-\u200D\uFEFF]/g, '');
    // 去除所有空??含中间意外空换?
    s = s.replace(/\s+/g, '');
    // 全角字?-> 半?
    s = s.replace(/\uFF1A/g, ':');   // ??> :
    s = s.replace(/\uFF1B/g, ':');   // ??全角分号误? 在URL里应:
    s = s.replace(/\uFF1F/g, '?');   // ??> ?
    s = s.replace(/\uFF0F/g, '/');   // ??> /
    s = s.replace(/\uFF0E/g, '.');   // ??> .
    s = s.replace(/\u3002/g, '.');   // ??> .
    s = s.replace(/\uFF1D/g, '=');   // ??> =
    s = s.replace(/\uFF06/g, '&');   // ??> &
    s = s.replace(/\uFF05/g, '%');   // ??> %
    // 修?scheme 里被误输成分号的冒? http;// ??https;// -> http:// 
    s = s.replace(/^(https?);\/\//i, '$1://');
    // 修正端口前误输的分? 域名与数字端口间??; -> :
    s = s.replace(/([A-Za-z0-9\.\-]);(\d{2,5})(\/|\?|$)/g, '$1:$2$3');
    return s;
  }

  private configUrl(apiUrl: string): string {
    this.tempKey = null;
    let url = this.normalizeUrl(apiUrl).replace('file://', 'clan://localhost/');
    const pk = ';pk;';
    if (url.includes(pk)) {
      const parts = url.split(pk);
      this.tempKey = parts[1];
      url = parts[0];
    }
    if (url.startsWith('clan')) {
      // clan:// 协议暂不支持，降级?http
      return url.replace('clan://localhost/', 'http://127.0.0.1/');
    }
    if (!url.startsWith('http')) {
      url = 'http://' + url;
    }
    return url;
  }

  /** 加载配置 (主入 */
  async loadConfig(configUrlStr: string): Promise<boolean> {
    try {
      let jsonStr = '';
      const url = configUrlStr.trim();

      if (url.startsWith('{') || url.startsWith('[')) {
        jsonStr = url;
      } else {
        const resolvedUrl = this.configUrl(url);
        const configKey = this.tempKey;
        const rawResponse = await httpGet(resolvedUrl, undefined, { ttlMs: 0 });

        // 解?
        jsonStr = await findResult(rawResponse, configKey);

        // 修复相对路?
        jsonStr = fixContentPath(resolvedUrl, jsonStr);
      }

      // 检查是否为 API 集?(??urls 数组sites)
      jsonStr = trimJsonObject(jsonStr);
      const trimmed = jsonStr.trim();
      if (isJson(trimmed)) {
        const checkObj = JSON.parse(trimmed) as Record<string, Object>;
        if (checkObj['urls'] !== undefined && checkObj['sites'] === undefined) {
          // API 集? 取第一URL
          const urls = checkObj['urls'] as Object[];
          if (urls && urls.length > 0) {
            const first = urls[0] as Record<string, Object>;
            const firstUrl = first['url'] !== undefined ? String(first['url']) : String(first);
            return await this.loadConfig(firstUrl);
          }
        }
      }

      this.parseConfigJson(jsonStr);

      const prevUrl: string = await PreferencesUtil.get(PREF_KEY_CONFIG_URL, '');
      const configUrlChanged: boolean = prevUrl !== url;
      if (configUrlChanged) {
        try { await this.clearEmptySourceKeys(); } catch (_e) {}
      }
      await PreferencesUtil.put(PREF_KEY_CONFIG_URL, url);
      await PreferencesUtil.put(PREF_KEY_CONFIG_JSON, jsonStr);
      // 切换配置后异步探测一次空源（不阻塞加载）
      if (configUrlChanged && this.isHideEmptySources()) {
        setTimeout((): void => {
          this.probeEmptySources().then((): void => {}).catch((): void => {});
        }, 5000);
      }

      this.configLoaded = true;
      return true;
    } catch (e) {
      const errMsg: string = formatError(e);
      console.error('loadConfig error: ' + errMsg);
      throw new Error(errMsg);
    }
  }

  /** 从本地 JSON 文本导入配置（设置页文件选择器读取后调用），与在线导入共用解析与持久化 */
  async loadConfigFromText(jsonStrIn: string): Promise<boolean> {
    try {
      const trimmedIn: string = jsonStrIn.trim();
      if (trimmedIn.length === 0 || (!trimmedIn.startsWith('{') && !trimmedIn.startsWith('['))) {
        throw new Error('本地导入仅支持 TVBox 标准 JSON 配置文件');
      }
      const jsonStr: string = trimJsonObject(jsonStrIn);
      this.parseConfigJson(jsonStr);
      const LOCAL_MARK: string = 'local://config_file';
      const prevUrl: string = await PreferencesUtil.get(PREF_KEY_CONFIG_URL, '');
      if (prevUrl !== LOCAL_MARK) {
        try { await this.clearEmptySourceKeys(); } catch (_e) {}
      }
      await PreferencesUtil.put(PREF_KEY_CONFIG_URL, LOCAL_MARK);
      await PreferencesUtil.put(PREF_KEY_CONFIG_JSON, jsonStr);
      // 导入外部配置后自动关闭内置播放源开关（内置源不显示）
      await this.setBuiltinSourceEnabled(false);
      if (prevUrl !== LOCAL_MARK && this.isHideEmptySources()) {
        setTimeout((): void => {
          this.probeEmptySources().then((): void => {}).catch((): void => {});
        }, 5000);
      }
      this.configLoaded = true;
      return true;
    } catch (e) {
      throw new Error(formatError(e));
    }
  }

  /** 抓取并解析单个配置地址，返回配置对象（跟随 urls 重定向） */
  private async fetchConfigObject(url: string, depth: number = 0): Promise<Record<string, Object> | null> {
    if (depth > 3) return null;
    let jsonStr = '';
    if (url.startsWith('{') || url.startsWith('[')) {
      jsonStr = url;
    } else {
      const resolvedUrl = this.configUrl(url);
      const configKey = this.tempKey;
      const rawResponse = await httpGet(resolvedUrl);
      jsonStr = await findResult(rawResponse, configKey);
      jsonStr = fixContentPath(resolvedUrl, jsonStr);
    }
    jsonStr = trimJsonObject(jsonStr);
    const trimmed = jsonStr.trim();
    if (!isJson(trimmed)) return null;
    const obj = JSON.parse(trimmed) as Record<string, Object>;
    if (obj['urls'] !== undefined && obj['sites'] === undefined) {
      const urls = obj['urls'] as Object[];
      if (urls && urls.length > 0) {
        const first = urls[0] as Record<string, Object>;
        const firstUrl = first['url'] !== undefined ? String(first['url']) : String(first);
        return await this.fetchConfigObject(firstUrl, depth + 1);
      }
      return null;
    }
    return obj;
  }

  /** 加载并聚合多个配置地址，合并所有源 */
  async loadConfigs(configUrls: string[]): Promise<boolean> {
    try {
      const validUrls: string[] = [];
      for (const u of configUrls) {
        const t = u.trim();
        if (t.length > 0 && validUrls.indexOf(t) < 0) validUrls.push(t);
      }
      if (validUrls.length === 0) {
        throw new Error('请输入配置地址');
      }

      this.lastFailedConfigUrls = [];

      const autoSwitch: boolean = PreferencesUtil.getBoolSync('history_auto_switch', false);
      let historyUrls: string[] = [];
      if (autoSwitch) {
        const historyRaw: string = PreferencesUtil.getSync('config_history', '');
        if (historyRaw.length > 0) {
          try {
            historyUrls = JSON.parse(historyRaw) as string[];
          } catch (_e) {
            historyUrls = [];
          }
        }
      }

      const configObjs: Record<string, Object>[] = [];
      const usedUrls: Set<string> = new Set<string>();

      for (const url of validUrls) {
        usedUrls.add(url);
        let obj: Record<string, Object> | null = null;
        try {
          obj = await this.fetchConfigObject(url);
        } catch (err) {
          hilog.warn(0x0001, 'YSC', 'loadConfigs: skip failed url=%{public}s err=%{public}s', url, formatError(err));
        }
        if (obj !== null) {
          configObjs.push(obj);
        } else {
          this.lastFailedConfigUrls.push(url);
          if (autoSwitch) {
            for (const hUrl of historyUrls) {
              if (usedUrls.has(hUrl)) continue;
              usedUrls.add(hUrl);
              try {
                const hObj = await this.fetchConfigObject(hUrl);
                if (hObj !== null) {
                  configObjs.push(hObj);
                  break;
                }
              } catch (_he) {
                hilog.warn(0x0001, 'YSC', 'loadConfigs: skip history url=%{public}s', hUrl);
              }
            }
          }
        }
      }

      if (configObjs.length === 0) {
        throw new Error('所有配置地址加载失败');
      }

      const allSites: Object[] = [];
      const allLives: Object[] = [];
      const allParses: Object[] = [];
      const allFlags: string[] = [];
      const allHosts: string[] = [];
      const allAds: string[] = [];
      const siteKeys: Set<string> = new Set<string>();
      const seenParses: Set<string> = new Set<string>();
      const seenFlags: Set<string> = new Set<string>();
      const seenHosts: Set<string> = new Set<string>();
      const seenAds: Set<string> = new Set<string>();

      let spider: string = '';
      let jarCache: string = 'true';
      let wallpaper: string = '';
      let homepage: string = '';
      let firstSet: boolean = false;

      for (const obj of configObjs) {
        if (!firstSet) {
          spider = safeJsonString(obj, 'spider', '');
          jarCache = safeJsonString(obj, 'jarCache', 'true');
          wallpaper = safeJsonString(obj, 'wallpaper', '');
          homepage = safeJsonString(obj, 'homepage', '');
          firstSet = true;
        }

        const sites = safeJsonArray(obj, 'sites');
        if (sites) {
          for (const site of sites) {
            const s = site as Record<string, Object>;
            const key = safeJsonString(s, 'key', '').trim();
            if (key.length === 0 || siteKeys.has(key)) continue;
            siteKeys.add(key);
            allSites.push(s);
          }
        }

        const lives = safeJsonArray(obj, 'lives');
        if (lives) {
          for (const l of lives) {
            allLives.push(l);
          }
        }

        const parses = safeJsonArray(obj, 'parses');
        if (parses) {
          for (const p of parses) {
            const po = p as Record<string, Object>;
            const name = safeJsonString(po, 'name', '');
            if (name.length === 0 || seenParses.has(name)) continue;
            seenParses.add(name);
            allParses.push(po);
          }
        }

        const flags = safeJsonStringList(obj, 'flags');
        for (const f of flags) {
          if (!seenFlags.has(f)) {
            seenFlags.add(f);
            allFlags.push(f);
          }
        }

        const hosts = safeJsonArray(obj, 'hosts');
        if (hosts) {
          for (const h of hosts) {
            const entry = String(h);
            if (!seenHosts.has(entry)) {
              seenHosts.add(entry);
              allHosts.push(entry);
            }
          }
        }

        const ads = safeJsonArray(obj, 'ads');
        if (ads) {
          for (const a of ads) {
            const entry = String(a);
            if (!seenAds.has(entry)) {
              seenAds.add(entry);
              allAds.push(entry);
            }
          }
        }
      }

      const combined: Record<string, Object> = {};
      combined['spider'] = spider;
      combined['jarCache'] = jarCache;
      combined['wallpaper'] = wallpaper;
      combined['homepage'] = homepage;
      combined['sites'] = allSites;
      combined['lives'] = allLives;
      combined['parses'] = allParses;
      combined['flags'] = allFlags;
      combined['hosts'] = allHosts;
      combined['ads'] = allAds;
      const combinedJson = JSON.stringify(combined);

      hilog.info(0x0001, 'YSC', 'loadConfigs: merged %{public}d configs, sites=%{public}d', configObjs.length, allSites.length);

      this.parseConfigJson(combinedJson);

      const prevUrl: string = await PreferencesUtil.get(PREF_KEY_CONFIG_URL, '');
      const joinedUrls: string = validUrls.join('\n');
      const configUrlChanged: boolean = prevUrl !== joinedUrls;
      if (configUrlChanged) {
        try { await this.clearEmptySourceKeys(); } catch (_e) {}
      }
      await PreferencesUtil.put(PREF_KEY_CONFIG_URL, joinedUrls);
      await PreferencesUtil.put(PREF_KEY_CONFIG_JSON, combinedJson);
      if (configUrlChanged && this.isHideEmptySources()) {
        setTimeout((): void => {
          this.probeEmptySources().then((): void => {}).catch((): void => {});
        }, 5000);
      }

      this.configLoaded = true;
      return true;
    } catch (e) {
      const errMsg: string = formatError(e);
      hilog.error(0x0001, 'YSC', 'loadConfigs error: %{public}s', errMsg);
      throw new Error(errMsg);
    }
  }

  /** 从缓存恢复配??*/
  async restoreConfig(): Promise<boolean> {
    const jsonStr = await PreferencesUtil.get(PREF_KEY_CONFIG_JSON, '');
    if (jsonStr.length === 0) return false;
    try {
      this.parseConfigJson(jsonStr);
      this.configLoaded = this.sourceKeyList.length > 0;
      return this.configLoaded;
    } catch (_e) {
      return false;
    }
  }

  /** 内置默认配置标记（rawfile/config_default.json），区别于用户填写的外部配置地址 */
  private static readonly BUILTIN_URL_MARK: string = 'builtin://config_default';

  /**
   * 加载内置看·电视默认配置（rawfile/config_default.json）
   * 首次启动无任何缓存配置时自动加载，实现开箱即用
   */
  async loadBuiltinConfig(): Promise<boolean> {
    try {
      const context = getContext() as common.UIAbilityContext;
      const mgr = context.resourceManager;
      const data = await mgr.getRawFileContent('config_default.json');
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const jsonStr: string = decoder.decodeToString(new Uint8Array(data));
      if (jsonStr.length === 0) {
        hilog.warn(0x0001, 'YSC', 'loadBuiltinConfig: empty builtin config');
        return false;
      }
      this.parseConfigJson(jsonStr);
      await PreferencesUtil.put(PREF_KEY_CONFIG_JSON, jsonStr);
      await PreferencesUtil.put(PREF_KEY_CONFIG_URL, ApiConfig.BUILTIN_URL_MARK);
      // 记录内置源 key 集合：开关关闭时用于从源列表隐藏内置源
      this.builtinSourceKeys.clear();
      for (const bk of this.sourceKeyList) {
        this.builtinSourceKeys.add(bk);
      }
      this.configLoaded = this.sourceKeyList.length > 0;
      hilog.info(0x0001, 'YSC', 'loadBuiltinConfig: loaded builtin config, sites=%{public}d', this.sourceKeyList.length);
      return this.configLoaded;
    } catch (e) {
      hilog.warn(0x0001, 'YSC', 'loadBuiltinConfig error: %{public}s', formatError(e));
      return false;
    }
  }

  /**
   * 旧版本用过的内置配置静默迁成「本地配置文件」标记：
   * 内置源不再随包分发，但已缓存到本地的源继续可用，用户无需重新导入。
   */
  async migrateBuiltinConfigToLocal(): Promise<boolean> {
    const savedUrl: string = await PreferencesUtil.get(PREF_KEY_CONFIG_URL, '');
    if (savedUrl !== ApiConfig.BUILTIN_URL_MARK) {
      return false;
    }
    const cached: string = await PreferencesUtil.get(PREF_KEY_CONFIG_JSON, '');
    if (cached.trim().length === 0) {
      return false;
    }
    await PreferencesUtil.put(PREF_KEY_CONFIG_URL, 'local://config_file');
    hilog.info(0x0001, 'YSC', 'migrateBuiltinConfigToLocal: builtin config -> local://config_file');
    return true;
  }

  /** 当前生效配置是否为内置默认配置（内置配置不参与后台联网刷新） */
  isBuiltinConfig(): boolean {
    const savedUrl: string = PreferencesUtil.getSync(PREF_KEY_CONFIG_URL, '');
    return savedUrl === ApiConfig.BUILTIN_URL_MARK;
  }

  /**
   * 内置默认配置是否有更新（rawfile 内容与已缓存配置不一致）。
   * 用于内置源调整后自动覆盖旧缓存，避免设备一直停留在旧源列表。
   */
  async isBuiltinDirty(): Promise<boolean> {
    try {
      const context = getContext() as common.UIAbilityContext;
      const mgr = context.resourceManager;
      const data = await mgr.getRawFileContent('config_default.json');
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const jsonStr: string = decoder.decodeToString(new Uint8Array(data));
      if (jsonStr.length === 0) {
        return false;
      }
      const saved: string = await PreferencesUtil.get(PREF_KEY_CONFIG_JSON, '');
      return saved.length > 0 && jsonStr !== saved;
    } catch (_e) {
      return false;
    }
  }

  /** 解析配置 JSON - 对?parseJson */
  private parseConfigJson(jsonStr: string): void {
    this.resetConfigData();
    const obj = JSON.parse(jsonStr) as Record<string, Object>;

    this.spider = safeJsonString(obj, 'spider', '');
    hilog.info(0x0001, 'YSC', 'parseConfig: spider=%{public}s', this.spider);
    this.jarCache = safeJsonString(obj, 'jarCache', 'true');
    this.wallpaper = safeJsonString(obj, 'wallpaper', '');
    this.homepageConfig = safeJsonString(obj, 'homepage', '');

    // 解?sites
    const sites = safeJsonArray(obj, 'sites');
    let firstUsableSite: SourceBean | null = null;
    if (sites) {
      for (const site of sites) {
        const s = site as Record<string, Object>;
        const key = safeJsonString(s, 'key', '').trim();
        if (key.length === 0) continue;
        const bean: SourceBean = {
          key: key,
          name: safeJsonString(s, 'name', key),
          api: safeJsonString(s, 'api', ''),
          type: safeJsonInt(s, 'type', 0),
          searchable: safeJsonInt(s, 'searchable', 1),
          quickSearch: safeJsonInt(s, 'quickSearch', 1),
          filterable: key.startsWith('py_') ? 1 : safeJsonInt(s, 'filterable', 1),
          playerUrl: safeJsonString(s, 'playUrl', ''),
          ext: safeJsonString(s, 'ext', ''),
          jar: safeJsonString(s, 'jar', ''),
          categories: safeJsonStringList(s, 'categories'),
          playerType: safeJsonInt(s, 'playerType', -1),
          timeout: safeJsonInt(s, 'timeout', 0),
          clickSelector: safeJsonString(s, 'click', ''),
          style: safeJsonString(s, 'style', '')
        };
        if (firstUsableSite === null && this.isUsableSource(bean)
          && (!this.isFilterNonVideo() || !this.isNonVideoSource(bean))) firstUsableSite = bean;
        this.sourceBeanList.set(key, bean);
        this.sourceKeyList.push(key);
      }
    }

    // 设置首页
    if (this.sourceKeyList.length > 0) {
      const savedKey = PreferencesUtil.getSync(PREF_KEY_HOME_API, '');
      const savedBean = savedKey.length > 0 ? this.sourceBeanList.get(savedKey) : null;
      let usableCount = 0;
      for (const sk of this.sourceKeyList) {
        const sb = this.sourceBeanList.get(sk);
        if (sb && this.isUsableSource(sb)) {
          usableCount++;
          hilog.info(0x0001, 'YSC', '  USABLE source key=%{public}s api=%{public}s type=%{public}d', sk, sb.api, sb.type);
        }
      }
      hilog.info(0x0001, 'YSC', 'parseConfig: savedKey=%{public}s totalSources=%{public}d usableCount=%{public}d',
        savedKey, this.sourceKeyList.length, usableCount);
      // Log first 3 sources for reference
      for (let logIdx = 0; logIdx < Math.min(3, this.sourceKeyList.length); logIdx++) {
        const sb2 = this.sourceBeanList.get(this.sourceKeyList[logIdx]);
        if (sb2) hilog.info(0x0001, 'YSC', '  source[%{public}d] key=%{public}s api=%{public}s type=%{public}d jar=%{public}s ext=%{public}s',
          logIdx, this.sourceKeyList[logIdx], sb2.api, sb2.type, sb2.jar, sb2.ext.substring(0, Math.min(100, sb2.ext.length)));
      }
      if (savedBean && this.isUsableSource(savedBean)) {
        this.homeSourceKey = savedKey;
      } else if (firstUsableSite) {
        this.homeSourceKey = firstUsableSite.key;
      } else {
        this.homeSourceKey = this.sourceKeyList[0];
      }
      hilog.info(0x0001, 'YSC', 'parseConfig: selectedHomeSource=%{public}s', this.homeSourceKey);
    }

    // VIP 解?flags
    this.vipParseFlags = safeJsonStringList(obj, 'flags');

    // 解?parses
    this.parseBeanList = [];
    const parses = safeJsonArray(obj, 'parses');
    if (parses) {
      for (const p of parses) {
        const po = p as Record<string, Object>;
        const pb: ParseBean = {
          name: safeJsonString(po, 'name', ''),
          url: safeJsonString(po, 'url', ''),
          ext: '',
          type: safeJsonInt(po, 'type', 0),
          isDefault: false
        };
        const extObj = safeJsonObject(po, 'ext');
        if (extObj) pb.ext = JSON.stringify(extObj);
        this.parseBeanList.push(pb);
      }
    }
    // 自动解析：置于列表首位，尝试所有可用解析器直到成功（仅在存在解析器时可用）
    if (this.parseBeanList.length > 0) {
      const autoParse: ParseBean = { name: '自动解析', url: '', ext: '', type: -1, isDefault: false };
      this.parseBeanList.unshift(autoParse);
    }

    // ?解?
    if (this.parseBeanList.length > 0) {
      const savedParse = PreferencesUtil.getSync(PREF_KEY_DEFAULT_PARSE, '');
      let found = false;
      if (savedParse.length > 0) {
        for (const pb of this.parseBeanList) {
          if (pb.name === savedParse) {
            pb.isDefault = true;
            this.defaultParse = pb;
            found = true;
            break;
          }
        }
      }
      if (!found) {
        this.parseBeanList[0].isDefault = true;
        this.defaultParse = this.parseBeanList[0];
      }
    }

    // hosts
    this.myHosts = new Map();
    const hostsArr = safeJsonArray(obj, 'hosts');
    if (hostsArr) {
      for (const h of hostsArr) {
        const entry = String(h);
        const eqIdx = entry.indexOf('=');
        if (eqIdx > 0) {
          this.myHosts.set(entry.substring(0, eqIdx), entry.substring(eqIdx + 1));
        }
      }
    }

    // 代理规则
    this.proxyRules = parseProxyRules(safeJsonArray(obj, 'proxy'));

    // 广告拦截
    const ads = safeJsonArray(obj, 'ads');
    if (ads) {
      for (const a of ads) {
        this.adHosts.add(String(a));
      }
    }

   // 清空搜索源缓??
   this.searchSourceBeanList = [];

    // 解析直播??
    this.liveUrl = '';
    const livesArr = safeJsonArray(obj, 'lives');
    if (livesArr && livesArr.length > 0) {
      const firstLive = livesArr[0] as Record<string, Object>;
      // type 0: 直?URL
      const liveType: string = firstLive['type'] !== undefined ? String(firstLive['type']) : '0';
      const liveApi: string = firstLive['api'] !== undefined ? String(firstLive['api']) : '';
      const liveUrlVal: string = firstLive['url'] !== undefined ? String(firstLive['url']) : '';
      if (liveType === '0' || liveType === '3') {
        let url: string = liveUrlVal.length > 0 ? liveUrlVal : liveApi;
        if (url.length > 0 && !url.startsWith('http://127.0.0.1')) {
          this.liveUrl = url;
        }
      }
    }
  }

  private resetConfigData(): void {
    this.sourceBeanList.clear();
    this.sourceKeyList = [];
    this.builtinSourceKeys.clear();
    this.spiders.clear();
    this.jsSpiders.clear();
    this.parseBeanList = [];
    this.liveChannelGroupList = [];
    this.vipParseFlags = [];
    this.myHosts.clear();
    this.proxyRules = [];
    this.searchSourceBeanList = [];
    this.defaultParse = null;
  }

  /** 判定源是否命中用户自定义的过滤关键字(空格分隔) */
  isNonVideoSource(bean: SourceBean): boolean {
    const kws: string[] = this.getSourceFilterKeywords();
    if (kws.length === 0) return false;
    const name: string = bean.name || '';
    for (const k of kws) {
      if (k.length > 0 && name.indexOf(k) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 用户自定义源过滤关键字，空格分隔，返回去重后的关键字数组 */
  getSourceFilterKeywords(): string[] {
    const raw: string = PreferencesUtil.getSync(PREF_KEY_SOURCE_FILTER_KEYWORDS, '');
    if (raw.length === 0) return [];
    const parts: string[] = raw.split(/\s+/);
    const out: string[] = [];
    for (const p of parts) {
      const t: string = p.trim();
      if (t.length > 0 && out.indexOf(t) < 0) out.push(t);
    }
    return out;
  }

  getSourceFilterKeywordsRaw(): string {
    return PreferencesUtil.getSync(PREF_KEY_SOURCE_FILTER_KEYWORDS, '');
  }

  async setSourceFilterKeywords(text: string): Promise<void> {
    await PreferencesUtil.put(PREF_KEY_SOURCE_FILTER_KEYWORDS, text);
  }

  /** 是否开启“过滤非视频源”开*/
  isFilterNonVideo(): boolean {
    return PreferencesUtil.getBoolSync(PREF_KEY_FILTER_NONVIDEO, false);
  }

  /** 设置“过滤非视频源”开*/
  async setFilterNonVideo(on: boolean): Promise<void> {
    await PreferencesUtil.putBool(PREF_KEY_FILTER_NONVIDEO, on);
  }

  /** 隐藏无资源的源（依赖尝试探测后得到的 empty 集合） */
  isHideEmptySources(): boolean {
    return PreferencesUtil.getBoolSync(PREF_KEY_HIDE_EMPTY_SOURCES, true);
  }
  async setHideEmptySources(on: boolean): Promise<void> {
    await PreferencesUtil.putBool(PREF_KEY_HIDE_EMPTY_SOURCES, on);
  }

  private ensureEmptyKeysLoaded(): void {
    if (this.emptyKeysLoaded) return;
    const raw: string = PreferencesUtil.getSync(PREF_KEY_EMPTY_SOURCE_KEYS, '');
    this.emptySourceKeys = new Set<string>();
    if (raw.length > 0) {
      try {
        const arr: Object = JSON.parse(raw) as Object;
        if (Array.isArray(arr)) {
          const list: string[] = arr as string[];
          for (const it of list) { if (typeof it === 'string' && it.length > 0) this.emptySourceKeys.add(it); }
        }
      } catch (_e) {}
    }
    this.emptyKeysLoaded = true;
  }

  isEmptySource(key: string): boolean {
    this.ensureEmptyKeysLoaded();
    return this.emptySourceKeys.has(key);
  }

  getEmptySourceKeys(): string[] {
    this.ensureEmptyKeysLoaded();
    const out: string[] = [];
    this.emptySourceKeys.forEach((k: string): void => { out.push(k); });
    return out;
  }

  async setEmptySourceKeys(keys: string[]): Promise<void> {
    this.emptySourceKeys = new Set<string>();
    for (const k of keys) { if (k && k.length > 0) this.emptySourceKeys.add(k); }
    this.emptyKeysLoaded = true;
    await PreferencesUtil.put(PREF_KEY_EMPTY_SOURCE_KEYS, JSON.stringify(keys));
  }

  async clearEmptySourceKeys(): Promise<void> {
    await this.setEmptySourceKeys([]);
  }

  /** 后台并发探测所有源是否有资源，标记空源。切换配置后自动调用。 */
  async probeEmptySources(perSourceTimeoutMs: number = 8000, concurrency: number = 4): Promise<void> {
    const alreadyProbing: boolean | undefined = AppStorage.get<boolean>('emptyProbing');
    if (alreadyProbing === true) return;
    const allKeys: string[] = this.sourceKeyList.slice();
    if (allKeys.length === 0) return;
    const effectiveConcurrency: number = allKeys.length > 200 ? 2 : concurrency;
    const emptyKeys: string[] = [];
    let idx: number = 0;
    let done: number = 0;
    AppStorage.setOrCreate('emptyProbing', true);
    AppStorage.setOrCreate('emptyProbeTotal', allKeys.length);
    AppStorage.setOrCreate('emptyProbeDone', 0);
    AppStorage.setOrCreate('emptyProbeFound', 0);
    const runOne = async (key: string): Promise<void> => {
      const bean = this.getSource(key);
      if (!bean) { emptyKeys.push(key); return; }
      const api: string = bean.api;
      const isJs: boolean = api.endsWith('.js') || api.includes('.js?');
      const isHttp: boolean = api.startsWith('http://') || api.startsWith('https://');
      if (!isHttp && !isJs) { emptyKeys.push(key); return; }
      let hasContent: boolean = false;
      try {
        const spider = this.getSpider(key);
        const probePromise: Promise<boolean> = (async (): Promise<boolean> => {
          const content: string = await spider.homeContent(true);
          if (!content || content.length === 0) return false;
          const t: string = content.trim();
          const looksJson: boolean = t.startsWith('{') || t.startsWith('[');
          if (looksJson) {
            return t.indexOf('"list"') > 0 || t.indexOf('"vod_id"') > 0 || t.indexOf('"class"') > 0 || t.indexOf('"vod_name"') > 0;
          }
          return t.indexOf('<video') > 0 || t.indexOf('<class') > 0 || t.indexOf('<list') > 0;
        })();
        const timeoutPromise: Promise<boolean> = new Promise<boolean>((_resolve, reject) => {
          setTimeout((): void => { reject(new Error('probe-timeout')); }, perSourceTimeoutMs);
        });
        hasContent = await Promise.race([probePromise, timeoutPromise]);
      } catch (_e) {
        hasContent = false;
      }
      if (!hasContent) emptyKeys.push(key);
      done = done + 1;
      AppStorage.setOrCreate('emptyProbeDone', done);
      AppStorage.setOrCreate('emptyProbeFound', emptyKeys.length);
    };
    const worker = async (): Promise<void> => {
      while (idx < allKeys.length) {
        const my: number = idx;
        idx = idx + 1;
        if (my >= allKeys.length) break;
        await runOne(allKeys[my]);
        await new Promise<void>((resolve: () => void): void => { setTimeout((): void => { resolve(); }, 50); });
      }
    };
    const workers: Promise<void>[] = [];
    for (let i = 0; i < effectiveConcurrency; i++) workers.push(worker());
    try {
      await Promise.all(workers);
      await this.setEmptySourceKeys(emptyKeys);
      hilog.info(0x0001, 'YSC', 'probeEmptySources: total=%{public}d empty=%{public}d', allKeys.length, emptyKeys.length);
    } finally {
      AppStorage.setOrCreate('emptyProbing', false);
      AppStorage.setOrCreate('emptyProbeShowResult', true);
      setTimeout((): void => { AppStorage.setOrCreate('emptyProbeShowResult', false); }, 4000);
    }
  }

  getSources(): SourceBean[] {
    const filterOn: boolean = this.isFilterNonVideo();
    const hideEmpty: boolean = this.isHideEmptySources();
    const builtinOn: boolean = this.isBuiltinSourceEnabled();
    if (hideEmpty) this.ensureEmptyKeysLoaded();
    const list: SourceBean[] = [];
    for (const key of this.sourceKeyList) {
      const sb = this.sourceBeanList.get(key);
      if (!sb) continue;
      // 内置播放源开关关闭时，隐藏内置源（外部导入源不受影响）
      if (!builtinOn && this.builtinSourceKeys.has(key)) continue;
      if (filterOn && this.isNonVideoSource(sb)) continue;
      if (hideEmpty && this.emptySourceKeys.has(key)) continue;
      list.push(sb);
    }
    return list;
  }

  getSourceKeys(): string[] {
    return this.sourceKeyList.slice();
  }

  getSource(key: string): SourceBean | null {
    return this.sourceBeanList.get(key) ?? null;
  }

  getHomeSource(): SourceBean | null {
    if (this.homeSourceKey.length === 0) return null;
    return this.sourceBeanList.get(this.homeSourceKey) ?? null;
  }

  getHomeSourceKey(): string {
    return this.homeSourceKey;
  }

  /** 判断 key 是否为内置源（供开关关闭时隐藏/首页失效用） */
  isBuiltinSourceKey(key: string): boolean {
    return this.builtinSourceKeys.has(key);
  }

  async setHomeSource(key: string): Promise<void> {
    if (this.sourceBeanList.has(key)) {
      this.homeSourceKey = key;
      await PreferencesUtil.put(PREF_KEY_HOME_API, key);
    }
  }

  getSpider(key: string): Spider {
    let sp = this.spiders.get(key);
    if (!sp) {
      const bean = this.getSource(key);
      if (!bean) throw new Error('source not found: ' + key);
      // 瓜子影视原生 ArkTS Spider（内置类，type=0）
      const isGz360: boolean = key === 'gz360' || bean.api.indexOf('uozvr.com') >= 0
        || bean.api.indexOf('w32z7vtd.com') >= 0 || bean.api.indexOf('6a7nnf7.com') >= 0
        || bean.api.indexOf('umygrx3.com') >= 0 || bean.api.indexOf('rmedphk.com') >= 0;
      if (isGz360) {
        const gz = new Gz360Spider();
        gz.init(bean);
        this.spiders.set(key, gz);
        return gz;
      }
      // 电影先生原生 ArkTS Spider（内置类，type=0）
      const isSilidm: boolean = key === 'silidm' || bean.api.indexOf('silidm.com') >= 0;
      if (isSilidm) {
        const sl = new SilidmSpider();
        sl.init(bean);
        this.spiders.set(key, sl);
        return sl;
      }
      // 麻花影视原生 ArkTS Spider（内置类，type=0，mh-ys.cc 页面站）
      const isMhys: boolean = key === 'mhys' || bean.api.indexOf('mh-ys.cc') >= 0;
      if (isMhys) {
        const mh = new MhysSpider();
        mh.init(bean);
        this.spiders.set(key, mh);
        return mh;
      }
      // 独播库原生 ArkTS Spider（内置类，type=0，dubokuys.com 镜像）
      const isDuboku: boolean = key === 'dubokuys' || key === 'duboku' || bean.api.indexOf('dubokuys.com') >= 0
        || bean.api.indexOf('duboku.tv') >= 0;
      if (isDuboku) {
        const db = new DubokuSpider();
        db.init(bean);
        this.spiders.set(key, db);
        return db;
      }
      // type=4 (T4 后端: ??T4Spider
      const isT4Source: boolean = bean.type === 4
        && (bean.api.startsWith('http://') || bean.api.startsWith('https://'));
      if (isT4Source) {
        const t4sp = new T4Spider();
        t4sp.init(bean);
        this.spiders.set(key, t4sp);
        return t4sp;
      }
      // JS spider 判定：JS (.js) ??
      const isJsSource: boolean = bean.api.endsWith('.js')
        || bean.api.includes('.js?');
      if (isJsSource) {
        let jsp = this.jsSpiders.get(key);
        if (!jsp) {
          jsp = new JsSpider();
          jsp.init(bean);
          this.jsSpiders.set(key, jsp);
        }
        return jsp;
      }
      // For type=3 JAR sources (csp_xxx), try CMS API approach
      // Build API URL from spider jar + class name
      sp = new Spider();
      sp.init(bean);
      this.spiders.set(key, sp);
    }
    return sp;
  }

  clearSpider(key: string): void {
    const sp = this.spiders.get(key);
    if (sp) {
      sp.destroy();
      this.spiders.delete(key);
    }
    const jsp = this.jsSpiders.get(key);
    if (jsp) {
      jsp.destroy();
      this.jsSpiders.delete(key);
    }
  }

  isConfigLoaded(): boolean {
    return this.configLoaded;
  }

  getWallpaper(): string {
    return this.wallpaper;
  }
  getLiveUrl(): string {
    return this.liveUrl;
  }

  setLiveUrl(url: string): void {
    this.liveUrl = url;
  }

  getHomepageConfig(): string {
    return this.homepageConfig;
  }

  getSpiderUrl(): string {
    return this.spider;
  }

  getVipParseFlags(): string[] {
    return this.vipParseFlags;
  }

  getParseBeanList(): ParseBean[] {
    return this.parseBeanList;
  }

  getDefaultParse(): ParseBean | null {
    return this.defaultParse;
  }

  async setDefaultParseByName(name: string): Promise<void> {
    let matched: ParseBean | null = null;
    for (const pb of this.parseBeanList) {
      pb.isDefault = pb.name === name;
      if (pb.isDefault) matched = pb;
    }
    this.defaultParse = matched;
    await PreferencesUtil.put(PREF_KEY_DEFAULT_PARSE, name);
  }

  getSearchableSources(): SourceBean[] {
    const filterOn: boolean = this.isFilterNonVideo();
    const hideEmpty: boolean = this.isHideEmptySources();
    const builtinOn: boolean = this.isBuiltinSourceEnabled();
    if (hideEmpty) this.ensureEmptyKeysLoaded();
    if (this.searchSourceBeanList.length === 0) {
      for (const key of this.sourceKeyList) {
        const sb = this.sourceBeanList.get(key);
        if (sb && isSearchable(sb)) this.searchSourceBeanList.push(sb);
      }
    }
    const out: SourceBean[] = [];
    for (const sb of this.searchSourceBeanList) {
      // 内置播放源开关关闭时，内置源不参与搜索
      if (!builtinOn && this.builtinSourceKeys.has(sb.key)) continue;
      if (filterOn && this.isNonVideoSource(sb)) continue;
      if (hideEmpty && this.emptySourceKeys.has(sb.key)) continue;
      out.push(sb);
    }
    return out;
  }

  getMyHosts(): Map<string, string> {
    return this.myHosts;
  }

  getProxyRules(): ProxyRule[] {
    return this.proxyRules;
  }

  isAdHost(host: string): boolean {
    return this.adHosts.has(host);
  }

  getLastFailedConfigUrls(): string[] {
    return this.lastFailedConfigUrls;
  }

  /** 内置播放源开关：开启时使用瓜子内置源（首页当前源显示"默认"） */
  isBuiltinSourceEnabled(): boolean {
    return PreferencesUtil.getBoolSync(PREF_KEY_USE_BUILTIN_SOURCE, false);
  }

  async setBuiltinSourceEnabled(v: boolean): Promise<void> {
    await PreferencesUtil.putBool(PREF_KEY_USE_BUILTIN_SOURCE, v);
  }

  /** 内置直播源开关：开启时直播使用内置直播源 */
  isBuiltinLiveEnabled(): boolean {
    return PreferencesUtil.getBoolSync(PREF_KEY_USE_BUILTIN_LIVE, false);
  }

  async setBuiltinLiveEnabled(v: boolean): Promise<void> {
    await PreferencesUtil.putBool(PREF_KEY_USE_BUILTIN_LIVE, v);
  }

  async getSavedConfigUrl(): Promise<string> {
    return await PreferencesUtil.get(PREF_KEY_CONFIG_URL, '');
  }
}

export function getApiConfig(): ApiConfig {
  return ApiConfig.getInstance();
}
