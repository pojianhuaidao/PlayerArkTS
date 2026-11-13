/**
 * 电影先生 (silidm.com) 原生 ArkTS Spider (type=0 内置类)
 * 协议已 Python 原型验证（2026-10-15）：
 *   首页   GET https://silidm.com
 *          -> 导航分类 /type/dy.html(电影) /type/juji.html(剧集) /type/dongman.html(动漫) /type/zongyi.html(综艺)
 *          -> 热播卡片 class="module-item"
 *   分类   GET /show/{tid}--------{pg}---.html   -> module-item 卡片, 分页号取分页链接最大值
 *   详情   GET /video/{vid}.html
 *          -> 标题/年份/导演/主演/备注/简介 + play-source-content 按播放源分组
 *   播放   GET /play/{vid}-{sid}-{nid}.html
 *          -> 提取 var player_xxxx={...}.url 得到 m3u8 直链
 *   搜索   GET /search/-------------.html?wd={key}  -> module-search-item 卡片
 */
import { Spider } from './Spider';
import { SourceBean } from '../model/SourceBean';
import { PlayInfo } from '../model/Movie';
import { httpGet } from '../utils/HttpUtil';

const BASE: string = 'https://silidm.com';
const UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';
const FALLBACK_CLASS: string = '[{"type_id":"dy","type_name":"电影"},{"type_id":"juji","type_name":"剧集"},{"type_id":"dongman","type_name":"动漫"},{"type_id":"zongyi","type_name":"综艺"}]';

/** Spider 返回的条目 JSON 结构 */
interface SilidmVodItem {
  vod_id: string;
  vod_name: string;
  vod_pic: string;
  vod_remarks: string;
}

/** 去掉 HTML 标签与多余空白 */
function cleanText(s: string): string {
  let t: string = s.replace(/<[^>]+>/g, ' ');
  t = t.replace(/\s+/g, ' ').trim();
  return t;
}

export class SilidmSpider extends Spider {
  private readonly pageCache: Map<string, string> = new Map<string, string>();
  private readonly pageCacheTs: Map<string, number> = new Map<string, number>();
  private static readonly CACHE_TTL_MS: number = 10 * 60 * 1000;
  private static readonly CACHE_MAX: number = 200;

  init(bean: SourceBean): void {
    super.init(bean);
  }

  /** 导航分类 -> class 数组字符串 */
  private parseNavCats(html: string): string {
    const items: string[] = [];
    const seenTids: string[] = [];
    const re: RegExp = new RegExp('<a href="/type/([a-z]+)\\.html"[^>]*title="([^"]+)"', 'g');
    let m: RegExpExecArray | null = re.exec(html);
    while (m !== null) {
      const tid: string = m[1];
      const tname: string = m[2];
      // 过滤"查看更多电影""查看更多"等非分类导航项，避免混入页签；同时按 type_id 去重
      if (tname.indexOf('查看更多') >= 0 || tname.indexOf('更多') >= 0) {
        m = re.exec(html);
        continue;
      }
      if (seenTids.indexOf(tid) >= 0) {
        m = re.exec(html);
        continue;
      }
      seenTids.push(tid);
      items.push('{"type_id":"' + tid + '","type_name":"' + tname + '"}');
      m = re.exec(html);
    }
    return items.length > 0 ? '[' + items.join(',') + ']' : FALLBACK_CLASS;
  }

  /** 解析 class="module-item" 卡片（首页热播 / 分类页共用） */
  private parseModuleCards(html: string): SilidmVodItem[] {
    const items: SilidmVodItem[] = [];
    const parts: string[] = html.split('class="module-item"');
    for (let i = 1; i < parts.length; i++) {
      const block: string = parts[i];
      const vm: RegExpExecArray | null = new RegExp('href="/video/(\\d+)\\.html"').exec(block);
      if (vm === null) {
        continue;
      }
      const id: string = vm[1];
      const tm: RegExpExecArray | null = new RegExp('title="([^"]+)"').exec(block);
      const pm: RegExpExecArray | null = new RegExp('data-src="([^"]+)"').exec(block);
      let remark: string = '';
      const capIdx: number = block.indexOf('module-item-caption');
      if (capIdx >= 0) {
        const capEnd: number = block.indexOf('</div>', capIdx);
        if (capEnd > capIdx) {
          remark = cleanText(block.substring(capIdx, capEnd));
        }
      }
      items.push({
        'vod_id': id,
        'vod_name': tm !== null ? tm[1] : id,
        'vod_pic': pm !== null ? pm[1] : '',
        'vod_remarks': remark
      });
    }
    return items;
  }

  async homeContent(filter: boolean): Promise<string> {
    try {
      const html: string = await this.fetch(BASE);
      return '{"class":' + this.parseNavCats(html) + ',"filters":{},"list":[]}';
    } catch (e) {
      console.error('[SilidmSpider] homeContent error: ' + String(e));
      return '{"class":' + FALLBACK_CLASS + ',"filters":{},"list":[]}';
    }
  }

  async homeVideoContent(): Promise<string> {
    try {
      const html: string = await this.fetch(BASE);
      const items: SilidmVodItem[] = this.parseModuleCards(html);
      return '{"list":' + JSON.stringify(items) + '}';
    } catch (e) {
      console.error('[SilidmSpider] homeVideoContent error: ' + String(e));
      return '{"list":[]}';
    }
  }

  async categoryContent(tid: string, pg: number, extend: Map<string, string>): Promise<string> {
    try {
      const url: string = BASE + '/show/' + tid + '--------' + pg + '---.html';
      const html: string = await this.fetch(url);
      const items: SilidmVodItem[] = this.parseModuleCards(html);
      // 分页号取分页链接最大值
      let pagecount: number = 1;
      const re: RegExp = new RegExp('href="/show/' + tid + '[^"]*--------(\\d+)---\\.html"', 'g');
      let m: RegExpExecArray | null = re.exec(html);
      while (m !== null) {
        const p: number = parseInt(m[1]);
        if (p > pagecount) {
          pagecount = p;
        }
        m = re.exec(html);
      }
      return '{"page":' + pg + ',"pagecount":' + pagecount + ',"limit":30,"total":' + items.length +
        ',"list":' + JSON.stringify(items) + '}';
    } catch (e) {
      console.error('[SilidmSpider] categoryContent error tid=' + tid + ': ' + String(e));
      return '{"list":[],"pagecount":0}';
    }
  }

  async detailContent(ids: string[]): Promise<string> {
    try {
      const vodId: string = ids.length > 0 ? ids[0] : '';
      if (vodId.length === 0) {
        return '{"list":[]}';
      }
      const html: string = await this.fetch(BASE + '/video/' + vodId + '.html');
      const item: Record<string, Object> = {};
      const tm: RegExpExecArray | null = new RegExp('<h1 class="page-title">([^<]+)</h1>').exec(html);
      item['vod_id'] = vodId;
      item['vod_name'] = tm !== null ? cleanText(tm[1]) : vodId;
      const pm: RegExpExecArray | null = new RegExp('<div class="mobile-vod-info">\\s*<img src="([^"]+)"').exec(html);
      if (pm !== null) {
        item['vod_pic'] = pm[1];
      } else {
        const pm2: RegExpExecArray | null = new RegExp('<img class="lazyload"[^>]*data-src="([^"]+)"').exec(html);
        item['vod_pic'] = pm2 !== null ? pm2[1] : '';
      }
      // 信息项（导演/主演/上映/备注）
      const infoDefs: string[][] = [
        ['导演', 'vod_director'],
        ['主演', 'vod_actor'],
        ['上映', 'vod_year'],
        ['备注', 'vod_remarks']
      ];
      for (let di = 0; di < infoDefs.length; di++) {
        const label: string = infoDefs[di][0];
        const key: string = infoDefs[di][1];
        const ire: RegExp = new RegExp('<span class="video-info-itemtitle">\\s*' + label + '[：:]\\s*</span>\\s*<div class="video-info-item[^"]*">([\\s\\S]*?)</div>');
        const im: RegExpExecArray | null = ire.exec(html);
        item[key] = im !== null ? cleanText(im[1]) : '';
      }
      // 地区从 video-info-aux 的分类链接旁提取（辅助信息）
      const areaM: RegExpExecArray | null = new RegExp('/show/\\d+-([^-]+)----------\\.html"').exec(html);
      if (areaM !== null) {
        item['vod_area'] = areaM[1];
      } else {
        item['vod_area'] = '';
      }
      const cm: RegExpExecArray | null = new RegExp('<div class="video-info-item video-info-content vod_content">\\s*([\\s\\S]{0,500})').exec(html);
      item['vod_content'] = cm !== null ? cleanText(cm[1]) : '';
      // 播放源分组
      const froms: string[] = [];
      const groups: string[] = [];
      const parts: string[] = html.split('class="play-source-content"');
      for (let i = 1; i < parts.length; i++) {
        const block: string = parts[i];
        const fm: RegExpExecArray | null = new RegExp('id="source-([^"]+)"').exec(block);
        if (fm === null) {
          continue;
        }
        const frm: string = fm[1];
        const eps: string[] = [];
        const ere: RegExp = new RegExp('href="/play/' + vodId + '-(\\d+)-(\\d+)\\.html"[^>]*>\\s*([^<]{1,30})\\s*</a>', 'g');
        let em: RegExpExecArray | null = ere.exec(block);
        while (em !== null) {
          eps.push(cleanText(em[3]) + '$' + BASE + '/play/' + vodId + '-' + em[1] + '-' + em[2] + '.html');
          em = ere.exec(block);
        }
        if (eps.length > 0) {
          froms.push(frm);
          groups.push(eps.join('#'));
        }
      }
      item['vod_play_from'] = froms.join('$$$');
      item['vod_play_url'] = groups.join('$$$');
      return '{"list":[' + JSON.stringify(item) + ']}';
    } catch (e) {
      console.error('[SilidmSpider] detailContent error: ' + String(e));
      return '{"list":[]}';
    }
  }

  async searchContent(key: string, quick: boolean, pg?: number): Promise<string> {
    try {
      const url: string = BASE + '/search/-------------.html?wd=' + encodeURIComponent(key);
      const html: string = await this.fetch(url);
      const items: SilidmVodItem[] = [];
      const parts: string[] = html.split('class="module-search-item"');
      for (let i = 1; i < parts.length; i++) {
        const block: string = parts[i];
        const vm: RegExpExecArray | null = new RegExp('href="/video/(\\d+)\\.html"').exec(block);
        if (vm === null) {
          continue;
        }
        const id: string = vm[1];
        const tm: RegExpExecArray | null = new RegExp('<h3><a href="/video/\\d+\\.html" title="([^"]+)"').exec(block);
        const pm: RegExpExecArray | null = new RegExp('data-src="([^"]+)"').exec(block);
        let remark: string = '';
        const sr: RegExpExecArray | null = new RegExp('class="video-serial"[^>]*>([^<]+)</a>').exec(block);
        if (sr !== null) {
          remark = cleanText(sr[1]);
        }
        items.push({
          'vod_id': id,
          'vod_name': tm !== null ? cleanText(tm[1]) : id,
          'vod_pic': pm !== null ? pm[1] : '',
          'vod_remarks': remark
        });
      }
      return '{"list":' + JSON.stringify(items) + '}';
    } catch (e) {
      console.error('[SilidmSpider] searchContent error: ' + String(e));
      return '{"list":[]}';
    }
  }

  async playerContent(flag: string, id: string): Promise<PlayInfo | null> {
    try {
      const html: string = await this.fetch(id);
      // 提取 player_xxxx={...}.url
      let playUrl: string = '';
      const re1: RegExp = new RegExp('var player_\\w+=\\s*(\\{[\\s\\S]*?\\})\\s*</script>');
      const m1: RegExpExecArray | null = re1.exec(html);
      if (m1 !== null) {
        try {
          const obj: Record<string, Object> = JSON.parse(m1[1]) as Record<string, Object>;
          const u: Object | undefined = obj['url'];
          if (u !== undefined && u !== null) {
            playUrl = String(u);
          }
        } catch (_e) {
          // 解析失败走正则兜底
        }
      }
      if (playUrl.length === 0) {
        const re2: RegExp = new RegExp('"url":"([^"]+)"');
        const m2: RegExpExecArray | null = re2.exec(html);
        if (m2 !== null) {
          playUrl = m2[1];
        }
      }
      if (playUrl.length === 0) {
        return null;
      }
      const headers: Map<string, string> = new Map();
      headers.set('User-Agent', UA);
      headers.set('Referer', BASE + '/');
      const info: PlayInfo = { url: playUrl, header: headers, parse: 0, jx: 0 };
      return info;
    } catch (e) {
      console.error('[SilidmSpider] playerContent error: ' + String(e));
      return null;
    }
  }

  destroy(): void {
    super.destroy();
  }

  /** GET 请求（携带桌面 UA，避免被站点拦截） */
  private async fetch(url: string): Promise<string> {
    const cached: string | undefined = this.pageCache.get(url);
    const cachedTs: number | undefined = this.pageCacheTs.get(url);
    if (cached !== undefined && cachedTs !== undefined && Date.now() - cachedTs < SilidmSpider.CACHE_TTL_MS) {
      return cached;
    }
    const headers: Map<string, string> = new Map();
    headers.set('User-Agent', UA);
    headers.set('Referer', BASE + '/');
    const html: string = await httpGet(url, headers);
    if (html.length === 0) {
      return html;
    }
    this.pageCache.set(url, html);
    this.pageCacheTs.set(url, Date.now());
    if (this.pageCache.size > SilidmSpider.CACHE_MAX) {
      this.pageCache.clear();
      this.pageCacheTs.clear();
    }
    return html;
  }
}
