/**
 * T4Spider - T4 后端源支持 (type=4)
 * 后端 /api/:module 接口协议:
 *   首页(class+filters+推荐)  GET  <api>            (无 ac)
 *   分类   GET  <api>&ac=list&t=<tid>&pg=<pg>&<extend>
 *   详情   GET  <api>&ac=detail&ids=<id>
 *   搜索   GET  <api>&wd=<key>&pg=<pg>[&quick=1]
 *   播放   GET  <api>&play=<id>&flag=<flag>
 * api 通常已自带 ?pwd=xxx，故一律用 & 追加参数。
 * 播放/代理地址若为 127.0.0.1/localhost，回写为后端实际 host，供真机访问。
 */
import { PlayInfo } from '../model/Movie';
import { SourceBean } from '../model/SourceBean';
import { httpGet } from '../utils/HttpUtil';
import { VideoParseRulerManager, SniffResult, checkVideoFormat } from '../util/VideoParseRuler';
import { isVipUrl } from '../util/DefaultConfig';
import { getApiConfig } from './ApiConfig';
import { Spider } from './Spider';

export class T4Spider extends Spider {
  init(bean: SourceBean): void {
    super.init(bean);
  }

  /** 追加查询参数(api 可能已带 ?pwd=) */
  private t4Url(query: string): string {
    const api: string = this.siteApi;
    if (query.length === 0) {
      return api;
    }
    const sep: string = api.indexOf('?') >= 0 ? '&' : '?';
    return api + sep + query;
  }

  /** 后端实际 origin (scheme://host:port)，用于回写 127.0.0.1 代理地址 */
  private backendOrigin(): string {
    const api: string = this.siteApi;
    const schemeEnd: number = api.indexOf('://');
    if (schemeEnd < 0) {
      return '';
    }
    const rest: number = api.indexOf('/', schemeEnd + 3);
    if (rest < 0) {
      return api;
    }
    return api.substring(0, rest);
  }

  /** 把 127.0.0.1/localhost 的地址回写为后端实际 host */
  private fixLocalHost(url: string): string {
    const origin: string = this.backendOrigin();
    if (origin.length === 0) {
      return url;
    }
    let out: string = url;
    out = out.replace('http://127.0.0.1:5757', origin);
    out = out.replace('http://localhost:5757', origin);
    return out;
  }

  async homeContent(filter: boolean): Promise<string> {
    return await httpGet(this.t4Url(''));
  }

  async homeVideoContent(): Promise<string> {
    // 首页请求已返回 list(推荐)，直接复用
    return await httpGet(this.t4Url(''));
  }

  async categoryContent(tid: string, pg: number, extend: Map<string, string>): Promise<string> {
    let query: string = 'ac=list&t=' + encodeURIComponent(tid) + '&pg=' + pg;
    extend.forEach((v: string, k: string) => {
      query += '&' + k + '=' + encodeURIComponent(v);
    });
    return await httpGet(this.t4Url(query));
  }

  async detailContent(ids: string[]): Promise<string> {
    const id: string = ids.length > 0 ? ids[0] : '';
    const query: string = 'ac=detail&ids=' + encodeURIComponent(id);
    return await httpGet(this.t4Url(query));
  }

  async searchContent(key: string, quick: boolean, pg?: number): Promise<string> {
    const page: number = pg ?? 1;
    let query: string = 'wd=' + encodeURIComponent(key) + '&pg=' + page;
    if (quick) {
      query += '&quick=1';
    }
    return await httpGet(this.t4Url(query));
  }

  async playerContent(flag: string, id: string): Promise<PlayInfo | null> {
    // 播放接口: <api>&play=<id>&flag=<flag> 返回 {parse,url,header/headers}
    let backendJson: string = '';
    let backendErr: string = '';
    try {
      const query: string = 'play=' + encodeURIComponent(id) + '&flag=' + encodeURIComponent(flag);
      backendJson = await httpGet(this.t4Url(query));
    } catch (be) {
      backendErr = (be as Error).message;
    }

    if (backendJson.length > 0) {
      try {
        const parsed = JSON.parse(backendJson) as Record<string, Object>;
        if (parsed['url'] !== undefined) {
          const rawUrl = parsed['url'];
          let playUrl: string = '';
          if (Array.isArray(rawUrl)) {
            const arr = rawUrl as Object[];
            const urlList: string[] = [];
            for (let ai = 0; ai < arr.length; ai++) {
              const s: string = String(arr[ai]);
              const low: string = s.toLowerCase();
              if (low.startsWith('http://') || low.startsWith('https://')) {
                urlList.push(s);
              }
            }
            let bestTrans: string = '';
            let firstNonMkv: string = '';
            let firstAny: string = '';
            for (let ui = 0; ui < urlList.length; ui++) {
              const u: string = urlList[ui];
              const lu: string = u.toLowerCase();
              if (firstAny.length === 0) { firstAny = u; }
              const isMkv: boolean = lu.indexOf('.mkv') >= 0;
              const isTrans: boolean = lu.indexOf('video-play') >= 0 || lu.indexOf('.m3u8') >= 0 || lu.indexOf('.mp4') >= 0;
              if (isTrans && bestTrans.length === 0) { bestTrans = u; }
              if (!isMkv && firstNonMkv.length === 0) { firstNonMkv = u; }
            }
            let pickedRaw: string = bestTrans.length > 0 ? bestTrans : (firstNonMkv.length > 0 ? firstNonMkv : firstAny);
            const hashIdx: number = pickedRaw.indexOf('#');
            if (hashIdx > 0) { pickedRaw = pickedRaw.substring(0, hashIdx); }
            if (pickedRaw.length > 0) {
              playUrl = this.fixLocalHost(pickedRaw);
            } else if (arr.length > 0) {
              playUrl = this.fixLocalHost(String(arr[arr.length - 1]));
            }
          } else {
            playUrl = this.fixLocalHost(String(rawUrl));
          }
          const parse: number = parsed['parse'] !== undefined ? Number(parsed['parse']) : 0;
          const headers: Map<string, string> = new Map();
          const hdrObj = parsed['header'] !== undefined ? parsed['header'] : parsed['headers'];
          if (hdrObj !== undefined && hdrObj !== null) {
            const hdrRecord = hdrObj as Record<string, Object>;
            for (const k of Object.keys(hdrRecord)) {
              headers.set(k, String(hdrRecord[k]));
            }
          }
          if (parse === 0 && playUrl.length > 0) {
            const info: PlayInfo = { url: playUrl, header: headers, parse: 0, jx: 0 };
            return info;
          }
          const config = getApiConfig();
          const defaultParse = config.getDefaultParse();
          const isAuto: boolean = !!defaultParse && defaultParse.type === -1;
          const parseUrl: string = defaultParse ? defaultParse.url : '';
          const autoUrls: string[] = [];
          if (isAuto) {
            for (const pb of config.getParseBeanList()) {
              if (pb.type !== -1 && pb.url.length > 0) autoUrls.push(pb.url);
            }
          }
          if (parseUrl.length > 0 || isAuto) {
            const sniff: SniffResult = isAuto
              ? await VideoParseRulerManager.resolveVideoUrlAuto(playUrl, autoUrls, headers)
              : await VideoParseRulerManager.resolveVideoUrl(playUrl, parseUrl, headers);
            if (sniff.url.length > 0 && sniff.isVideo) {
              const info2: PlayInfo = { url: sniff.url, header: sniff.headers.size > 0 ? sniff.headers : headers, parse: 0, jx: 0 };
              return info2;
            }
          }
          const info3: PlayInfo = { url: playUrl, header: headers, parse: parse, jx: parse === 1 ? 1 : 0 };
          return info3;
        }
        // 后端返回了 JSON，但没有 url 字段（多半带 error/msg）
        const errMsg: string = parsed['error'] !== undefined ? String(parsed['error'])
          : (parsed['msg'] !== undefined ? String(parsed['msg']) : '后端返回缺少 url 字段');
        throw new Error('后端解析失败：' + errMsg);
      } catch (pe) {
        throw new Error('后端返回无法解析：' + (pe as Error).message);
      }
    }

    // 后端 HTTP 出错 / 空响应：如果 id 是原始 5 段字符串（含 '*'），直接报错，不要塞给播放器
    const looksLikeRawId: boolean = id.indexOf('*') >= 0 && id.indexOf('://') < 0;
    if (looksLikeRawId) {
      const hint: string = backendErr.length > 0 ? backendErr : '空响应';
      throw new Error('网盘后端解析失败（' + hint + '）。请确认后端服务运行正常，且相应网盘 Cookie/Token 已配置。');
    }

    // 兜底: 按基类嗅探逻辑处理 id
    const headers: Map<string, string> = new Map();
    let playUrl: string = id;
    let parse: number = 0;
    let jx: number = 0;
    const isVideo: boolean = checkVideoFormat(id);
    const isVip: boolean = isVipUrl(id);
    if (!isVideo || isVip) {
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
      if (parseUrl.length > 0 || isAuto) { jx = 1; }
      try {
        const sniff: SniffResult = isAuto
          ? await VideoParseRulerManager.resolveVideoUrlAuto(id, autoUrls, headers)
          : await VideoParseRulerManager.resolveVideoUrl(id, parseUrl, headers);
        if (sniff.url.length > 0) { playUrl = sniff.url; }
        if (sniff.headers.size > 0) { sniff.headers.forEach((v: string, k: string) => { headers.set(k, v); }); }
        if (!sniff.isVideo && (parseUrl.length > 0 || isAuto)) { parse = 1; }
      } catch (_e) { /* ignore */ }
    }
    const result: PlayInfo = { url: playUrl, header: headers, parse: parse, jx: jx };
    return result;
  }

  destroy(): void {
    super.destroy();
  }
}
