/**
 * 麻花影视 - 热播电视剧大全 - 韩剧/美剧/国产剧_最新电影电视剧免费在线观看 (mh-ys.cc 页面站) 原生 ArkTS Spider (type=0 内置类)
 * 结构（Python 实测验证）：首页导航 /mhys/{分类}/；详情 /mhml/{id}/；
 * 播放 /mhyskan/{id}-{sid}-{nid}/，内嵌 JSON 转义 m3u8 直链（\\/ 形式）。
 */
import { Spider } from './Spider';
import { SourceBean } from '../model/SourceBean';
import { PlayInfo } from '../model/Movie';
import { httpGet } from '../utils/HttpUtil';

const BASE: string = 'https://mh-ys.cc';
const UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';
const FALLBACK_CLASS: string = '[{"type_id":"dianying","type_name":"电影"},{"type_id":"dianshiju","type_name":"电视剧"},{"type_id":"zongyi","type_name":"综艺"},{"type_id":"dongman","type_name":"动漫"},{"type_id":"duanju","type_name":"短剧"},{"type_id":"yingshijieshuo","type_name":"影视解说"},{"type_id":"dongzuopian","type_name":"动作片"},{"type_id":"xijupian","type_name":"喜剧片"},{"type_id":"aiqingpian","type_name":"爱情片"},{"type_id":"kehuanpian","type_name":"科幻片"},{"type_id":"kongbupian","type_name":"恐怖片"},{"type_id":"juqingpian","type_name":"剧情片"},{"type_id":"jilupian","type_name":"纪录片"},{"type_id":"zhanzhengpian","type_name":"战争片"},{"type_id":"xuanyipian","type_name":"悬疑片"},{"type_id":"guochanju","type_name":"国产剧"},{"type_id":"gangtaiju","type_name":"港台剧"},{"type_id":"rihanju","type_name":"日韩剧"},{"type_id":"oumeiju","type_name":"欧美剧"},{"type_id":"haiwaiju","type_name":"海外剧"},{"type_id":"daluzongyi","type_name":"大陆综艺"},{"type_id":"rihanzongyi","type_name":"日韩综艺"},{"type_id":"gangtaizongyi","type_name":"港台综艺"},{"type_id":"oumeizongyi","type_name":"欧美综艺"},{"type_id":"haiwaizongyi","type_name":"海外综艺"},{"type_id":"guochandongman","type_name":"国产动漫"},{"type_id":"rihandongman","type_name":"日韩动漫"},{"type_id":"gangtaidongman","type_name":"港台动漫"},{"type_id":"oumeidongman","type_name":"欧美动漫"},{"type_id":"haiwaidongman","type_name":"海外动漫"},{"type_id":"donghuapian","type_name":"动画片"},{"type_id":"nvpinlianai","type_name":"女频恋爱"},{"type_id":"fanzhuanshuangju","type_name":"反转爽剧"},{"type_id":"guzhuangxianxia","type_name":"古装仙侠"},{"type_id":"niandaichuanyue","type_name":"年代穿越"},{"type_id":"naodongxuanyi","type_name":"脑洞悬疑"},{"type_id":"xiandaidushi","type_name":"现代都市"}]';

interface MhysVodItem {
  vod_id: string;
  vod_name: string;
  vod_pic: string;
  vod_remarks: string;
}

function cleanText(s: string): string {
  let t: string = s.replace(/<[^>]+>/g, ' ');
  t = t.replace(/\s+/g, ' ').trim();
  return t;
}

export class MhysSpider extends Spider {
  /** 页面级缓存：相同 URL 在 TTL 内直接复用，避免每次点击重复加载页面 */
  private readonly pageCache: Map<string, string> = new Map<string, string>();
  private readonly pageCacheTs: Map<string, number> = new Map<string, number>();
  private static readonly CACHE_TTL_MS: number = 10 * 60 * 1000;
  private static readonly CACHE_MAX: number = 200;

  init(bean: SourceBean): void {
    super.init(bean);
  }

  /** 导航分类 -> class 数组字符串（/mhys/{cat}/ 模式） */
  private parseNavCats(html: string): string {
    const items: string[] = [];
    const seenTids: string[] = [];
    const re: RegExp = new RegExp('href="/mhys/([a-z0-9]+)/"[^>]*>([^<]{1,20})<', 'g');
    let m: RegExpExecArray | null = re.exec(html);
    while (m !== null) {
      const tid: string = m[1];
      const tname: string = cleanText(m[2]);
      if (tname.length === 0 || tname === '更多' || tname === '查看更多' || seenTids.indexOf(tid) >= 0) {
        m = re.exec(html);
        continue;
      }
      seenTids.push(tid);
      items.push('{"type_id":"' + tid + '","type_name":"' + tname + '"}');
      m = re.exec(html);
    }
    return items.length > 0 ? '[' + items.join(',') + ']' : FALLBACK_CLASS;
  }

  /** 解析 show_play 卡片（首页/分类页共用），按 vod_id 去重 */
  private parseCards(html: string): MhysVodItem[] {
    const items: MhysVodItem[] = [];
    const seenIds: string[] = [];
    const re: RegExp = new RegExp('<a href="/mhml/(\\d+)/" class="tcl-img" title="([^"]*)"[^>]*>([\\s\\S]*?)</a>', 'g');
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
        const am: RegExpExecArray | null = new RegExp('title="([^"]+)"').exec(m[3]);
        name = am !== null ? cleanText(am[1]) : id;
      }
      const pm: RegExpExecArray | null = new RegExp('data-original="([^"]+)"').exec(m[3]);
      let remark: string = '';
      const capIdx: number = m[3].indexOf('tc_wz');
      if (capIdx >= 0) {
        // 定位到 class="tc_wz" 之后的正文起点，避免备注带 "tc_wz"> 前缀
        const tagEnd: number = m[3].indexOf('>', capIdx);
        const capStart: number = tagEnd >= 0 ? tagEnd + 1 : capIdx;
        const capEnd: number = m[3].indexOf('</p>', capStart);
        if (capEnd > capStart) {
          remark = cleanText(m[3].substring(capStart, capEnd));
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
      console.error('[MhysSpider] homeContent error: ' + String(e));
      return '{"class":' + FALLBACK_CLASS + ',"filters":{},"list":[]}';
    }
  }

  async homeVideoContent(): Promise<string> {
    try {
      const html: string = await this.fetch(BASE);
      const items: MhysVodItem[] = this.parseCards(html);
      return '{"list":' + JSON.stringify(items) + '}';
    } catch (e) {
      console.error('[MhysSpider] homeVideoContent error: ' + String(e));
      return '{"list":[]}';
    }
  }

  async categoryContent(tid: string, pg: number, extend: Map<string, string>): Promise<string> {
    try {
      const url: string = pg <= 1
        ? BASE + '/mhys/' + tid + '/'
        : BASE + '/mhys/' + tid + '/index_' + pg + '.html';
      const html: string = await this.fetch(url);
      const items: MhysVodItem[] = this.parseCards(html);
      let pagecount: number = 1;
      const re: RegExp = new RegExp('href="/mhys/' + tid + '/index_(\\d+)\\.html"', 'g');
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
      console.error('[MhysSpider] categoryContent error tid=' + tid + ': ' + String(e));
      return '{"list":[],"pagecount":0}';
    }
  }

  async detailContent(ids: string[]): Promise<string> {
    try {
      const vodId: string = ids.length > 0 ? ids[0] : '';
      if (vodId.length === 0) {
        return '{"list":[]}';
      }
      const html: string = await this.fetch(BASE + '/mhml/' + vodId + '/');
      const item: Record<string, Object> = {};
      const om: RegExpExecArray | null = new RegExp('property="og:title" content="([^"]+)"').exec(html);
      item['vod_id'] = vodId;
      item['vod_name'] = om !== null ? cleanText(om[1]) : vodId;
      const pm: RegExpExecArray | null = new RegExp('property="og:image" content="([^"]+)"').exec(html);
      item['vod_pic'] = pm !== null ? pm[1] : '';
      const dm: RegExpExecArray | null = new RegExp('id="[^"]*intro[^"]*"[\\s\\S]{0,80}?>([\\s\\S]*?)</(?:div|p)>').exec(html);
      item['vod_content'] = dm !== null ? cleanText(dm[1]) : '';
      item['vod_remarks'] = '';
      // 播放源：从 /mhyskan/{id}-{sid}-{nid}/ 提取
      const froms: string[] = [];
      const groups: string[] = [];
      const srcMap: Map<string, string[]> = new Map();
      const re: RegExp = new RegExp('href="/mhyskan/' + vodId + '-(\d+)-(\d+)/"[^>]*>([^<]{1,10})<', 'g');
      let m: RegExpExecArray | null = re.exec(html);
      while (m !== null) {
        const sid: string = m[1];
        const nid: string = m[2];
        const sname: string = cleanText(m[3]);
        if (!srcMap.has(sid)) {
          srcMap.set(sid, []);
        }
        (srcMap.get(sid) as string[]).push(sname + '$' + BASE + '/mhyskan/' + vodId + '-' + sid + '-' + nid + '/');
        m = re.exec(html);
      }
      srcMap.forEach((eps: string[], sid: string) => {
        if (eps.length > 0) {
          const first: string = eps[0];
          const doll: number = first.indexOf('$');
          const sname: string = doll >= 0 ? first.substring(0, doll) : ('源' + sid);
          froms.push(sname);
          groups.push(eps.join('#'));
        }
      });
      item['vod_play_from'] = froms.join('$$$');
      item['vod_play_url'] = groups.join('$$$');
      return '{"list":[' + JSON.stringify(item) + ']}';
    } catch (e) {
      console.error('[MhysSpider] detailContent error: ' + String(e));
      return '{"list":[]}';
    }
  }

  async searchContent(key: string, quick: boolean, pg?: number): Promise<string> {
    return '{"list":[]}';
  }

  async playerContent(flag: string, id: string): Promise<PlayInfo | null> {
    try {
      const html: string = await this.fetch(id);
      // JSON 转义直链：https:\/\/...\/index.m3u8
      const norm: string = html.replace(/\\u002F/g, '/').replace(/\\\//g, '/');
      let playUrl: string = '';
      const re1: RegExp = new RegExp('url["\']?\\s*[:=]\\s*["\']([^"\']+)["\']');
      const m1: RegExpExecArray | null = re1.exec(norm);
      if (m1 !== null) {
        let v: string = m1[1];
        v = v.replace(/\\u002F/g, '/').replace(/\\\//g, '/');
        if (v.indexOf('.m3u8') >= 0 || v.indexOf('.mp4') >= 0) {
          playUrl = v;
        }
      }
      if (playUrl.length === 0) {
        const m2: RegExpExecArray | null = new RegExp('https?://[^\\s"\'<>]+\\.m3u8[^\\s"\'<>]*').exec(norm);
        if (m2 !== null) {
          playUrl = m2[0];
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
      console.error('[MhysSpider] playerContent error: ' + String(e));
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
    if (cached !== undefined && cachedTs !== undefined && Date.now() - cachedTs < MhysSpider.CACHE_TTL_MS) {
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
    if (this.pageCache.size > MhysSpider.CACHE_MAX) {
      this.pageCache.clear();
      this.pageCacheTs.clear();
    }
    return html;
  }
}
