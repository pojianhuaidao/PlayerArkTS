/**
 * Spider 接口
 * HarmonyOS NEXT 版本, 通过 HTTP 调用 CMS API
 * 支持 type 0 (XML) / type 1 (JSON) 两种源类型
 * type 3 (Spider/JS/JAR) 暂通过 JSON API 兼容处理
 */
import { PlayInfo } from '../model/Movie';
import { SourceBean } from '../model/SourceBean';
import { httpGet } from '../utils/HttpUtil';
import { VideoParseRulerManager, SniffResult, checkVideoFormat } from '../util/VideoParseRuler';
import { isVipUrl } from '../util/DefaultConfig';
import { getApiConfig } from './ApiConfig';

export class Spider {
  siteKey: string = '';
  siteApi: string = '';
  sourceBean: SourceBean | null = null;

  init(bean: SourceBean): void {
    this.siteKey = bean.key;
    this.siteApi = bean.api;
    this.sourceBean = bean;
  }

  /** Check if this source api is a usable HTTP URL (not a JAR/csp_ source) */
  private isJarSource(): boolean {
    const api: string = this.siteApi;
    if (api.startsWith('http://') || api.startsWith('https://')) {
      return false;
    }
    if (api.endsWith('.js') || api.includes('.js?')) {
      return false;
    }
    return true;
  }

  /** Empty home JSON for unsupported JAR sources */
  private emptyHomeJson(): string {
    return '{"class":[],"filters":{},"list":[]}';
  }

  /** Empty list JSON for unsupported JAR sources */
  private emptyListJson(): string {
    return '{"list":[],"pagecount":0}';
  }

  /** 首页内容 */
  async homeContent(filter: boolean): Promise<string> {
    if (this.isJarSource()) {
      return this.emptyHomeJson();
    }
    const api = this.cmsBase() + '?ac=list';
    return await httpGet(api);
  }

  /** 首页推荐视频 */
  async homeVideoContent(): Promise<string> {
    if (this.isJarSource()) {
      return '{"list":[]}';
    }
    // CMS 采集源(type 0 XML / type 1 JSON): 首页 ac=list 不返回封面(vod_pic)，
    // 需用 ac=detail 拉取带封面的最新视频列表作为首页推荐。
    if (this.sourceBean && this.sourceBean.type === 0) {
      const xmlUrl = this.cmsBase() + '?ac=videolist';
      return await httpGet(xmlUrl);
    }
    const url = this.cmsBase() + '?ac=detail';
    return await httpGet(url);
  }

  /** 分类内容 */
  async categoryContent(tid: string, pg: number, extend: Map<string, string>): Promise<string> {
    if (this.isJarSource()) {
      return this.emptyListJson();
    }
    const isXml: boolean = this.sourceBean !== null && this.sourceBean !== undefined && this.sourceBean.type === 0;
    const buildUrl = (paramName: string): string => {
      let u: string;
      if (isXml) {
        u = `${this.cmsBase()}?ac=xml&${paramName}=${tid}&pg=${pg}`;
      } else {
        u = `${this.cmsBase()}?ac=detail&${paramName}=${tid}&pg=${pg}`;
      }
      extend.forEach((v: string, k: string) => {
        u += `&${k}=${encodeURIComponent(v)}`;
      });
      return u;
    };
    // 优先使用标准 CMS 参数 t=；若返回空列表则回退 tid=（兼容部分不规范源）
    const primary: string = await httpGet(buildUrl('t'));
    if (this.categoryHasList(primary)) return primary;
    try {
      const fallback: string = await httpGet(buildUrl('tid'));
      if (this.categoryHasList(fallback)) return fallback;
    } catch (_e) {}
    return primary;
  }

  /** 判断分类接口响应中是否包含有效条目 */
  private categoryHasList(body: string): boolean {
    if (!body || body.length === 0) return false;
    const t: string = body.trim();
    if (t.length === 0) return false;
    const looksJson: boolean = t.startsWith('{') || t.startsWith('[');
    if (looksJson) {
      try {
        const obj: Object = JSON.parse(t) as Object;
        const rec: Record<string, Object> = obj as Record<string, Object>;
        const list: Object | undefined = rec['list'];
        if (Array.isArray(list)) return (list as Object[]).length > 0;
        return false;
      } catch (_e) { return false; }
    }
    // XML: 粗判 <video> 或 <list> 内的条目
    return t.indexOf('<video') > 0 || t.indexOf('<list') > 0;
  }

  /** 详情内容 */
  async detailContent(ids: string[]): Promise<string> {
    if (this.isJarSource()) {
      return this.emptyListJson();
    }
    const id = ids.length > 0 ? ids[0] : '';
    let url: string;
    if (this.sourceBean && this.sourceBean.type === 0) {
      url = `${this.cmsBase()}?ac=xml&ids=${id}`;
    } else {
      url = `${this.cmsBase()}?ac=detail&ids=${id}`;
    }
    return await httpGet(url);
  }

  /** 搜索 */
  async searchContent(key: string, quick: boolean, pg?: number): Promise<string> {
    if (this.isJarSource()) {
      return this.emptyListJson();
    }
    const page = pg ?? 1;
    const wd = encodeURIComponent(key);
    let url: string;
    if (this.sourceBean && this.sourceBean.type === 0) {
      url = `${this.cmsBase()}?ac=xml&wd=${wd}&pg=${page}`;
    } else {
      url = `${this.cmsBase()}?ac=detail&wd=${wd}&pg=${page}`;
    }
    return await httpGet(url);
  }

  /** 播放信息 */
  async playerContent(flag: string, id: string): Promise<PlayInfo | null> {
    const headers: Map<string, string> = new Map();
    let playUrl: string = id;
    let parse: number = 0;
    let jx: number = 0;

    // 检查是否为视频格式
    const isVideo: boolean = checkVideoFormat(id);

    // 检查是否为 VIP URL
    const isVip: boolean = isVipUrl(id);

    // 如果不是视频格式或是 VIP URL, 则需要进行嗅探/解析
    if (!isVideo || isVip) {
      // 获取默认解析接口
      const cfg = getApiConfig();
      const defaultParse = cfg.getDefaultParse();
      const isAuto: boolean = !!defaultParse && defaultParse.type === -1;
      const parseUrl: string = defaultParse ? defaultParse.url : '';
      const autoUrls: string[] = [];
      if (isAuto) {
        for (const pb of cfg.getParseBeanList()) {
          if (pb.type !== -1 && pb.url.length > 0) autoUrls.push(pb.url);
        }
      }

      if (parseUrl.length > 0 || isAuto) {
        jx = 1;
      }

      try {
        const sniffResult: SniffResult = isAuto
          ? await VideoParseRulerManager.resolveVideoUrlAuto(id, autoUrls, headers)
          : await VideoParseRulerManager.resolveVideoUrl(id, parseUrl, headers);
        if (sniffResult.url.length > 0) {
          playUrl = sniffResult.url;
        }
        if (sniffResult.headers.size > 0) {
          sniffResult.headers.forEach((v: string, k: string) => {
            headers.set(k, v);
          });
        }
        // 嗅探成功后仍需解析则标记 parse
        if (!sniffResult.isVideo && (parseUrl.length > 0 || isAuto)) {
          parse = 1;
        }
      } catch (_e) {
        // 解析失败, 返回原始 URL
      }
    }

    const result: PlayInfo = {
      url: playUrl,
      header: headers,
      parse: parse,
      jx: jx
    };
    return result;
  }

  /** 是否为视频格式 */
  isVideoFormat(url: string): boolean {
    const lower = url.toLowerCase();
    return lower.endsWith('.m3u8') || lower.endsWith('.mp4') ||
      lower.endsWith('.flv') || lower.endsWith('.mkv') || lower.endsWith('.avi') ||
      lower.includes('.m3u8?') || lower.includes('.mp4?');
  }

  destroy(): void {
  }

  /**
   * CMS 采集源的 api 可能已自带查询串(如 ?ac=list)。
   * 直接拼接 ?ac=detail 会产生非法的 ...?ac=list?ac=detail，服务端只认第一个 ac。
   * 此方法剥离已有查询串，返回纯净基址用于重新拼接 ac 参数。
   */
  private cmsBase(): string {
    const api: string = this.siteApi;
    const qIndex: number = api.indexOf('?');
    if (qIndex >= 0) {
      return api.substring(0, qIndex);
    }
    return api;
  }

  private buildUrl(base: string, urlPath: string): string {
    if (urlPath.length === 0) {
      return base;
    }
    if (urlPath.startsWith('?')) {
      if (base.endsWith('?') || base.endsWith('&')) {
        return base + urlPath.substring(1);
      }
      return base + urlPath;
    }
    if (base.endsWith('/') && urlPath.startsWith('/')) {
      return base + urlPath.substring(1);
    }
    if (!base.endsWith('/') && !urlPath.startsWith('/') && urlPath.length > 0) {
      return base + '/' + urlPath;
    }
    return base + urlPath;
  }
}
