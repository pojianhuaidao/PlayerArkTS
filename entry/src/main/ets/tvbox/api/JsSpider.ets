/**
 * JsSpider - Spider implementation for type=3 (JS) sources
 * JS 源 Spider 实现
 *
 * Uses JsEngine (WebView-based) to execute JS spider code.
 * All Spider interface methods delegate to the JS spider object
 * loaded in the WebView.
 *
 * Method mapping (ArkTS -> JS spider):
 *   homeContent(filter)     -> spider.home(filter)
 *   homeVideoContent()      -> spider.homeVod()
 *   categoryContent(tid,pg) -> spider.category(tid, pg, filter, extend)
 *   detailContent(ids)      -> spider.detail(ids[0])
 *   searchContent(key,quick)-> spider.search(key, quick)
 *   playerContent(flag,id)  -> spider.play(flag, id, vipFlags)
 *   isVideoFormat(url)      -> spider.isVideo(url)
 *   manualVideoCheck()      -> spider.sniffer()
 *   liveContent(url)        -> spider.live(url)
 */
import { PlayInfo } from '../model/Movie';
import { SourceBean } from '../model/SourceBean';
import { httpGet } from '../utils/HttpUtil';
import { VideoParseRulerManager, SniffResult, checkVideoFormat } from '../util/VideoParseRuler';
import { isVipUrl } from '../util/DefaultConfig';
import { getApiConfig } from './ApiConfig';
import { initSpider, callSpiderMethodAsync, isSpiderLoaded, isJsEngineReady } from './JsEngine';
import { Spider } from './Spider';

export class JsSpider extends Spider {
  private initialized: boolean = false;
  init(bean: SourceBean): void {
    super.init(bean);
  }

  /** Ensure spider JS code is loaded into JsEngine */
  private async ensureLoaded(): Promise<boolean> {
    if (this.initialized && isSpiderLoaded(this.siteKey)) {
      return true;
    }

    if (!isJsEngineReady()) {
      console.warn('[JsSpider] JsEngine not ready, cannot load spider');
      return false;
    }

    const ext: string = this.sourceBean ? this.sourceBean.ext : '';
    const success = await initSpider(this.siteKey, this.siteApi, ext);
    if (success) {
      this.initialized = true;
    }
    return success;
  }

  /** Home content - calls spider.home(filter) */
  async homeContent(filter: boolean): Promise<string> {
    const loaded = await this.ensureLoaded();
    if (!loaded) return '';

    const result = await callSpiderMethodAsync(this.siteKey, 'home', JSON.stringify([filter]));
    if (result.success && result.result.length > 0) {
      try {
        const raw: string = result.result;
        const trimmed: string = raw.trim();
        if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
          return String(JSON.parse(raw));
        }
        return raw;
      } catch (_e) {
        return result.result;
      }
    }
    return '';
  }

  /** Home video content - calls spider.homeVod() */
  async homeVideoContent(): Promise<string> {
    const loaded = await this.ensureLoaded();
    if (!loaded) return '';

    const result = await callSpiderMethodAsync(this.siteKey, 'homeVod', '[]');
    if (result.success && result.result.length > 0) {
      try {
        const raw: string = result.result;
        const trimmed: string = raw.trim();
        if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
          return String(JSON.parse(raw));
        }
        return raw;
      } catch (_e) {
        return result.result;
      }
    }
    return '';
  }

  /** Category content - calls spider.category(tid, pg, filter, extend) */
  async categoryContent(tid: string, pg: number, extend: Map<string, string>): Promise<string> {
    const loaded = await this.ensureLoaded();
    if (!loaded) return '';

    const extendObj: Record<string, string> = {};
    extend.forEach((v: string, k: string) => { extendObj[k] = v; });

    const args = JSON.stringify([tid, String(pg), true, extendObj]);
    const result = await callSpiderMethodAsync(this.siteKey, 'category', args);
    if (result.success && result.result.length > 0) {
      try {
        const raw: string = result.result;
        const trimmed: string = raw.trim();
        if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
          return String(JSON.parse(raw));
        }
        return raw;
      } catch (_e) {
        return result.result;
      }
    }
    return '';
  }

  /** Detail content - calls spider.detail(id) */
  async detailContent(ids: string[]): Promise<string> {
    const loaded = await this.ensureLoaded();
    if (!loaded) return '';

    const id = ids.length > 0 ? ids[0] : '';
    const result = await callSpiderMethodAsync(this.siteKey, 'detail', JSON.stringify([id]));
    if (result.success && result.result.length > 0) {
      try {
        const raw: string = result.result;
        const trimmed: string = raw.trim();
        if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
          return String(JSON.parse(raw));
        }
        return raw;
      } catch (_e) {
        return result.result;
      }
    }
    return '';
  }

  /** Search content - calls spider.search(key, quick) */
  async searchContent(key: string, quick: boolean, pg?: number): Promise<string> {
    const loaded = await this.ensureLoaded();
    if (!loaded) return '';

    const page = pg ?? 1;
    const args = JSON.stringify([key, quick, String(page)]);
    const result = await callSpiderMethodAsync(this.siteKey, 'search', args);
    if (result.success && result.result.length > 0) {
      try {
        const raw: string = result.result;
        const trimmed: string = raw.trim();
        if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
          return String(JSON.parse(raw));
        }
        return raw;
      } catch (_e) {
        return result.result;
      }
    }
    return '';
  }

  /** Player content - calls spider.play(flag, id, vipFlags) */
  async playerContent(flag: string, id: string): Promise<PlayInfo | null> {
    const loaded = await this.ensureLoaded();

    // Try JS spider play method first
    if (loaded) {
      const config = getApiConfig();
      const vipFlags = config.getVipParseFlags();
      const args = JSON.stringify([flag, id, vipFlags]);
      const result = await callSpiderMethodAsync(this.siteKey, 'play', args);

      if (result.success && result.result.length > 0) {
        try {
          const parsed = JSON.parse(result.result) as Record<string, Object>;
          const playUrl: string = parsed['url'] !== undefined ? String(parsed['url']) : id;
          const parse: number = parsed['parse'] !== undefined ? Number(parsed['parse']) : 0;
          const jx: number = parsed['jx'] !== undefined ? Number(parsed['jx']) : 0;
          const headers: Map<string, string> = new Map();
          const headerObj = parsed['header'];
          if (headerObj !== undefined && headerObj !== null) {
            const hdrRecord = headerObj as Record<string, Object>;
            for (const k of Object.keys(hdrRecord)) {
              headers.set(k, String(hdrRecord[k]));
            }
          }

          // If parse or jx is set, or URL is not a direct video, do sniffing
          if (jx === 1 || parse === 1) {
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
              const sniffResult: SniffResult = isAuto
                ? await VideoParseRulerManager.resolveVideoUrlAuto(playUrl, autoUrls, headers)
                : await VideoParseRulerManager.resolveVideoUrl(playUrl, parseUrl, headers);
              if (sniffResult.url.length > 0 && sniffResult.isVideo) {
                const playInfo: PlayInfo = {
                  url: sniffResult.url,
                  header: sniffResult.headers.size > 0 ? sniffResult.headers : headers,
                  parse: 0,
                  jx: 0
                };
                return playInfo;
              }
            }
          }

          const playInfo: PlayInfo = { url: playUrl, header: headers, parse: parse, jx: jx };
          return playInfo;
        } catch (_e) {
          // Fall through to default behavior
        }
      }
    }

    // Fallback: use sniffing/parse like the base Spider
    const headers: Map<string, string> = new Map();
    let playUrl: string = id;
    let parse: number = 0;
    let jx: number = 0;

    const isVideo: boolean = checkVideoFormat(id);
    const isVip: boolean = isVipUrl(id);

    if (!isVideo || isVip) {
      const cfg2 = getApiConfig();
      const defaultParse = cfg2.getDefaultParse();
      const isAuto: boolean = !!defaultParse && defaultParse.type === -1;
      const parseUrl: string = defaultParse ? defaultParse.url : '';
      const autoUrls: string[] = [];
      if (isAuto) {
        for (const pb of cfg2.getParseBeanList()) {
          if (pb.type !== -1 && pb.url.length > 0) autoUrls.push(pb.url);
        }
      }
      if (parseUrl.length > 0 || isAuto) { jx = 1; }

      try {
        const sniffResult: SniffResult = isAuto
          ? await VideoParseRulerManager.resolveVideoUrlAuto(id, autoUrls, headers)
          : await VideoParseRulerManager.resolveVideoUrl(id, parseUrl, headers);
        if (sniffResult.url.length > 0) { playUrl = sniffResult.url; }
        if (sniffResult.headers.size > 0) {
          sniffResult.headers.forEach((v: string, k: string) => { headers.set(k, v); });
        }
        if (!sniffResult.isVideo && (parseUrl.length > 0 || isAuto)) { parse = 1; }
      } catch (_e) {
        // ignore
      }
    }

    const result: PlayInfo = { url: playUrl, header: headers, parse: parse, jx: jx };
    return result;
  }

  /** Is video format - calls spider.isVideo(url) */
  isVideoFormat(url: string): boolean {
    return checkVideoFormat(url);
  }

  /** Manual video check (sniffer) - calls spider.sniffer() */
  manualVideoCheck(): boolean {
    return false;
  }

  /** Live content - calls spider.live(url) */
  async liveContent(url: string): Promise<string> {
    const loaded = await this.ensureLoaded();
    if (!loaded) return '';

    const result = await callSpiderMethodAsync(this.siteKey, 'live', JSON.stringify([url]));
    if (result.success && result.result.length > 0) {
      try {
        const raw: string = result.result;
        const trimmed: string = raw.trim();
        if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
          return String(JSON.parse(raw));
        }
        return raw;
      } catch (_e) {
        return result.result;
      }
    }
    return '';
  }

  destroy(): void {
    this.initialized = false;
    super.destroy();
  }
}
