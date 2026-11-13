/**
 * 独播库 (dubokuys.com 镜像) 原生 ArkTS Spider (type=0 内置类)
 * 接口结构已 Python 实测验证（2026-10-17）：
 *   首页   GET https://dubokuys.com
 *          -> 导航分类 <a href="/list/{tid}/">...<span>{中文名}</span>（电影/电视剧/短剧/动漫/综艺/纪录片/福利）
 *          -> 卡片 <a href="/video/{id}/" title="{名称}" class="module-poster-item module-item">（data-src 封面 / module-item-note 备注）
 *   分类   GET /list/{tid}/              (第1页，导航真实链接，实测有效)
 *          GET /show-{tid}--------{pg}---/  (第N页，连字符版，实测第2页有效)
 *          -> 卡片同上；分页条链接为连字符版 /show-{tid}--------{n}---/，最大 n 即总页数
 *   详情   GET /video/{vid}/
 *          -> <h1> 标题 / module-info-poster 封面 / module-info-introduction-content 简介
 *          -> module-tab-item[aria-controls=panel{i}] 播放源；panel{i} > module-play-list-link 选集
 *   播放   GET /play/{vid}-{sid}-{nid}/
 *          -> var player_aaaa={...}.url 为百分号编码，decodeURIComponent 后取首个 & 之前即 m3u8 直链
 *   搜索   GET /index.php/ajax/suggest?wd={key}&mid=1 -> JSON {code,list:[{id,name,pic}]}
 */
import { Spider } from './Spider';
import { SourceBean } from '../model/SourceBean';
import { PlayInfo } from '../model/Movie';
import { httpGet } from '../utils/HttpUtil';

const BASE: string = 'https://dubokuys.com';
const UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';
const FALLBACK_CLASS: string = '[{"type_id":"dianying","type_name":"电影"},{"type_id":"dianshiju","type_name":"电视剧"},{"type_id":"duanju","type_name":"短剧"},{"type_id":"zongyi","type_name":"综艺"},{"type_id":"dongman","type_name":"动漫"}]';

/** Spider 返回的条目 JSON 结构 */
interface DubokuVodItem {
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

export class DubokuSpider extends Spider {
  /** 页面级缓存：相同 URL 在 TTL 内直接复用，避免每次点击重复加载页面 */
  private readonly pageCache: Map<string, string> = new Map<string, string>();
  private readonly pageCacheTs: Map<string, number> = new Map<string, number>();
  private static readonly CACHE_TTL_MS: number = 10 * 60 * 1000;
  private static readonly CACHE_MAX: number = 200;

  init(bean: SourceBean): void {
    super.init(bean);
  }

  /** 导航分类 -> class 数组字符串（按 type_id 去重） */
  private parseNavCats(html: string): string {
    const items: string[] = [];
    const seenTids: string[] = [];
    const re: RegExp = new RegExp('<a href="/list/([a-z]+)/"[^>]*>[\\s\\S]*?<span>([^<]+)</span>', 'g');
    let m: RegExpExecArray | null = re.exec(html);
    while (m !== null) {
      const tid: string = m[1];
      const tname: string = cleanText(m[2]);
      if (tname.length === 0 || seenTids.indexOf(tid) >= 0) {
        m = re.exec(html);
        continue;
      }
      seenTids.push(tid);
      items.push('{"type_id":"' + tid + '","type_name":"' + tname + '"}');
      m = re.exec(html);
    }
    return items.length > 0 ? '[' + items.join(',') + ']' : FALLBACK_CLASS;
  }

  /** 解析 module-poster-item 卡片（首页 / 分类页共用），按 vod_id 去重 */
  private parseModuleCards(html: string): DubokuVodItem[] {
    const items: DubokuVodItem[] = [];
    const seenIds: string[] = [];
    // 整卡片匹配：<a href="/video/{id}/" title="{名称}" ... class="module-poster-item module-item">...</a>
    // href/title 在 class 之前，必须整卡片捕获，不能按 class split
    const re: RegExp = new RegExp('<a href="/video/(\\d+)/" title="([^"]*)"[^>]*class="module-poster-item[^>]*>([\\s\\S]*?)</a>', 'g');
    let m: RegExpExecArray | null = re.exec(html);
    while (m !== null) {
      const id: string = m[1];
      if (seenIds.indexOf(id) >= 0) {
        m = re.exec(html);
        continue;
      }
      seenIds.push(id);
      let name: string = cleanText(m[2]);
      if (name.length === 0) {
        // 个别卡片无 title 时回退 alt
        const am: RegExpExecArray | null = new RegExp('alt="([^"]+)"').exec(m[3]);
        name = am !== null ? cleanText(am[1]) : id;
      }
      const pm: RegExpExecArray | null = new RegExp('data-src="([^"]+)"').exec(m[3]);
      let remark: string = '';
      const capIdx: number = m[3].indexOf('module-item-note');
      if (capIdx >= 0) {
        const capEnd: number = m[3].indexOf('</div>', capIdx);
        if (capEnd > capIdx) {
          remark = cleanText(m[3].substring(capIdx, capEnd));
        }
      }
      items.push({
        'vod_id': id,
        'vod_name': name,
        'vod_pic': pm !== null ? pm[1] : '',
        'vod_remarks': remark
      });
      m = re.exec(html);
    }
    return items;
  }

  async homeContent(filter: boolean): Promise<string> {
    try {
      const html: string = await this.fetch(BASE);
      return '{"class":' + this.parseNavCats(html) + ',"filters":{},"list":[]}';
    } catch (e) {
      console.error('[DubokuSpider] homeContent error: ' + String(e));
      return '{"class":' + FALLBACK_CLASS + ',"filters":{},"list":[]}';
    }
  }

  async homeVideoContent(): Promise<string> {
    try {
      const html: string = await this.fetch(BASE);
      const items: DubokuVodItem[] = this.parseModuleCards(html);
      return '{"list":' + JSON.stringify(items) + '}';
    } catch (e) {
      console.error('[DubokuSpider] homeVideoContent error: ' + String(e));
      return '{"list":[]}';
    }
  }

  async categoryContent(tid: string, pg: number, extend: Map<string, string>): Promise<string> {
    try {
      const url: string = pg <= 1
        ? BASE + '/list/' + tid + '/'
        : BASE + '/show-' + tid + '--------' + pg + '---/';
      const html: string = await this.fetch(url);
      const items: DubokuVodItem[] = this.parseModuleCards(html);
      // 分页条中最大页码即总页数（页面分页链接为连字符版 /show-{tid}--------{n}---/）
      let pagecount: number = 1;
      const re: RegExp = new RegExp('href="/show-' + tid + '--------(\\d+)---/"', 'g');
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
      console.error('[DubokuSpider] categoryContent error tid=' + tid + ': ' + String(e));
      return '{"list":[],"pagecount":0}';
    }
  }

  async detailContent(ids: string[]): Promise<string> {
    try {
      const vodId: string = ids.length > 0 ? ids[0] : '';
      if (vodId.length === 0) {
        return '{"list":[]}';
      }
      const html: string = await this.fetch(BASE + '/video/' + vodId + '/');
      const item: Record<string, Object> = {};
      const tm: RegExpExecArray | null = new RegExp('<h1>([^<]+)</h1>').exec(html);
      item['vod_id'] = vodId;
      item['vod_name'] = tm !== null ? cleanText(tm[1]) : vodId;
      const pm: RegExpExecArray | null = new RegExp('<div class="module-info-poster">[\\s\\S]*?data-src="([^"]+)"').exec(html);
      item['vod_pic'] = pm !== null ? pm[1] : '';
      const ym: RegExpExecArray | null = new RegExp('href="/show-1-----------([0-9]{4})/"').exec(html);
      item['vod_year'] = ym !== null ? ym[1] : '';
      const am: RegExpExecArray | null = new RegExp('href="/show-1-([^-]+)----------/"').exec(html);
      item['vod_area'] = am !== null ? am[1] : '';
      const ty: RegExpExecArray | null = new RegExp('href="/show-1---([^-]+)--------/"').exec(html);
      item['vod_type'] = ty !== null ? ty[1] : '';
      const dm: RegExpExecArray | null = new RegExp('<span class="module-info-item-title">导演[：:]</span>\\s*<div class="module-info-item-content">([\\s\\S]*?)</div>').exec(html);
      item['vod_director'] = dm !== null ? cleanText(dm[1]) : '';
      const cm: RegExpExecArray | null = new RegExp('<div class="module-info-introduction-content">([\\s\\S]*?)</div>').exec(html);
      item['vod_content'] = cm !== null ? cleanText(cm[1]) : '';
      item['vod_remarks'] = '';

      // 播放源：tab aria-controls="panel{i}" -> data-dropdown-value 源名
      const fromByPanel: Map<string, string> = new Map();
      const tre: RegExp = new RegExp('aria-controls="panel(\\d+)"[^>]*>\\s*<span data-dropdown-value="([^"]+)"', 'g');
      let tm2: RegExpExecArray | null = tre.exec(html);
      while (tm2 !== null) {
        if (fromByPanel.has(tm2[1])) {
          tm2 = tre.exec(html);
          continue;
        }
        fromByPanel.set(tm2[1], cleanText(tm2[2]));
        tm2 = tre.exec(html);
      }
      // 选集：按 id="panel{i}" 块切分，块内提取 play 链接
      const froms: string[] = [];
      const groups: string[] = [];
      const panels: string[] = html.split('id="panel');
      for (let pi = 1; pi < panels.length; pi++) {
        const head: string = panels[pi];
        const idxMatch: RegExpExecArray | null = new RegExp('^(\\d+)').exec(head);
        if (idxMatch === null) {
          continue;
        }
        const idx: string = idxMatch[1];
        const block: string = head;
        const eps: string[] = [];
        const ere: RegExp = new RegExp('href="/play/' + vodId + '-(\\d+)-(\\d+)/"[^>]*>[\\s\\S]*?<span>([^<]+)</span>', 'g');
        let em: RegExpExecArray | null = ere.exec(block);
        while (em !== null) {
          eps.push(cleanText(em[3]) + '$' + BASE + '/play/' + vodId + '-' + em[1] + '-' + em[2] + '/');
          em = ere.exec(block);
        }
        if (eps.length > 0) {
          froms.push(fromByPanel.has(idx) ? (fromByPanel.get(idx) as string) : '独播库');
          groups.push(eps.join('#'));
        }
      }
      item['vod_play_from'] = froms.join('$$$');
      item['vod_play_url'] = groups.join('$$$');
      return '{"list":[' + JSON.stringify(item) + ']}';
    } catch (e) {
      console.error('[DubokuSpider] detailContent error: ' + String(e));
      return '{"list":[]}';
    }
  }

  async searchContent(key: string, quick: boolean, pg?: number): Promise<string> {
    try {
      const url: string = BASE + '/index.php/ajax/suggest?wd=' + encodeURIComponent(key) + '&mid=1';
      const body: string = await this.fetch(url);
      const items: DubokuVodItem[] = [];
      try {
        const obj: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
        const list: Object | undefined = obj['list'];
        if (Array.isArray(list)) {
          for (let i = 0; i < (list as Object[]).length; i++) {
            const rec: Record<string, Object> = (list as Object[])[i] as Record<string, Object>;
            const id: Object | undefined = rec['id'];
            const name: Object | undefined = rec['name'];
            const pic: Object | undefined = rec['pic'];
            items.push({
              'vod_id': id !== undefined ? String(id) : '',
              'vod_name': name !== undefined ? String(name) : '',
              'vod_pic': pic !== undefined ? String(pic) : '',
              'vod_remarks': ''
            });
          }
        }
      } catch (_e) {
        // JSON 解析失败返回空列表
      }
      return '{"list":' + JSON.stringify(items) + '}';
    } catch (e) {
      console.error('[DubokuSpider] searchContent error: ' + String(e));
      return '{"list":[]}';
    }
  }

  async playerContent(flag: string, id: string): Promise<PlayInfo | null> {
    try {
      const html: string = await this.fetch(id);
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
      // 播放地址为百分号编码，解码后剥离尾部 &next= 参数
      let realUrl: string = playUrl;
      try {
        const decoded: string = decodeURIComponent(playUrl);
        if (decoded.indexOf('http') === 0) {
          realUrl = decoded;
        }
      } catch (_e) {
        // 非编码地址原样使用
      }
      const nxIdx: number = realUrl.indexOf('&');
      if (nxIdx >= 0) {
        realUrl = realUrl.substring(0, nxIdx);
      }
      const headers: Map<string, string> = new Map();
      headers.set('User-Agent', UA);
      headers.set('Referer', BASE + '/');
      const info: PlayInfo = { url: realUrl, header: headers, parse: 0, jx: 0 };
      return info;
    } catch (e) {
      console.error('[DubokuSpider] playerContent error: ' + String(e));
      return null;
    }
  }

  destroy(): void {
    super.destroy();
  }

  /** GET 请求（携带桌面 UA，避免被站点拦截）；带页面级缓存 */
  private async fetch(url: string): Promise<string> {
    const cached: string | undefined = this.pageCache.get(url);
    const cachedTs: number | undefined = this.pageCacheTs.get(url);
    if (cached !== undefined && cachedTs !== undefined && Date.now() - cachedTs < DubokuSpider.CACHE_TTL_MS) {
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
    if (this.pageCache.size > DubokuSpider.CACHE_MAX) {
      this.pageCache.clear();
      this.pageCacheTs.clear();
    }
    return html;
  }
}
