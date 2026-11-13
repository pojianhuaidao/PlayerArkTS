/**
 * 神马影院 (ihumanism.org) 原生 ArkTS Spider (type=0 内置类)
 * 结构已通过本地 HTML 样本 + Python 正则验证（2026-10-16）：
 *   首页   GET https://ihumanism.org
 *          -> 导航分类 /ihvodtype/dianying.html(电影) /dianshiju.html(电视剧) /zongyi.html(综艺) /dongman.html(动漫)
 *          -> 热播卡片 div.myui-vodlist__box > a.myui-vodlist__thumb.lazyload
 *   分类   GET /ihvodtype/{tid}-{pg}.html   -> 同卡片结构, 分页号取 /ihvodtype/{tid}-{N}.html 最大值
 *   详情   GET /ihvoddetail/{vid}.html
 *          -> h1.title 标题; img.lazyload[data-original] 封面; p.data 内导演/主演/年份/地区/简介
 *          -> ul.nav.nav-tabs 播放源; div#playlist{N} > ul.myui-content__list 剧集
 *   播放   GET /ihvodplay/{vid}-{sid}-{nid}.html
 *          -> 提取 var player_xxxx={...}.url 得到 m3u8 直链 (encrypt=0)
 *   搜索   GET /ihvodsearch/{关键词URL编码}-------------.html
 *          -> ul#searchList 下 li.thumb a.myui-vodlist__thumb.lazyload 卡片
 */
import { Spider } from './Spider';
import { SourceBean } from '../model/SourceBean';
import { PlayInfo } from '../model/Movie';
import { httpGet } from '../utils/HttpUtil';

const BASE: string = 'https://ihumanism.org';
const UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';
const FALLBACK_CLASS: string = '[{"type_id":"dianying","type_name":"电影"},{"type_id":"dianshiju","type_name":"电视剧"},{"type_id":"zongyi","type_name":"综艺"},{"type_id":"dongman","type_name":"动漫"}]';

/** Spider 返回的条目 JSON 结构 */
interface IhumanismVodItem {
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

/** HTML 实体反转义（搜索页 title 常带 <font color=red> 标签实体） */
function htmlDecode(s: string): string {
  let t: string = s;
  t = t.replace(/&lt;/g, '<');
  t = t.replace(/&gt;/g, '>');
  t = t.replace(/&quot;/g, '"');
  t = t.replace(/&#39;/g, "'");
  t = t.replace(/&amp;/g, '&');
  return t;
}

/** 提取 p.data 信息段内 <a> 标签文本（导演/主演/分类/地区/年份等） */
function pickLinkTexts(html: string, label: string): string {
  const re: RegExp = new RegExp('<span class="text-muted[^"]*">' + label + '：</span>([\\s\\S]*?)</p>');
  const m: RegExpExecArray | null = re.exec(html);
  if (m === null) {
    return '';
  }
  const seg: string = m[1];
  const texts: string[] = [];
  const are: RegExp = new RegExp('<a[^>]*>([^<]+)</a>', 'g');
  let am: RegExpExecArray | null = are.exec(seg);
  while (am !== null) {
    texts.push(cleanText(am[1]));
    am = are.exec(seg);
  }
  return texts.length > 0 ? texts.join(' ') : cleanText(seg);
}

export class IhumanismSpider extends Spider {
  /** 页面级缓存：相同 URL 在 TTL 内直接复用，避免每次点击重复加载页面 */
  private readonly pageCache: Map<string, string> = new Map<string, string>();
  private readonly pageCacheTs: Map<string, number> = new Map<string, number>();
  private static readonly CACHE_TTL_MS: number = 10 * 60 * 1000;
  private static readonly CACHE_MAX: number = 200;

  init(bean: SourceBean): void {
    super.init(bean);
  }

  /** 导航分类 -> class 数组字符串（仅保留电影/电视剧/综艺/动漫四类） */
  private parseNavCats(html: string): string {
    const items: string[] = [];
    const keepTids: string[] = ['dianying', 'dianshiju', 'zongyi', 'dongman'];
    for (let k = 0; k < keepTids.length; k++) {
      const tid: string = keepTids[k];
      const re: RegExp = new RegExp('<a href="/ihvodtype/' + tid + '\\.html"[^>]*>([^<]+)</a>');
      const m: RegExpExecArray | null = re.exec(html);
      const tname: string = m !== null ? cleanText(m[1]) : '';
      items.push('{"type_id":"' + tid + '","type_name":"' + tname + '"}');
    }
    return items.length >= 4 ? '[' + items.join(',') + ']' : FALLBACK_CLASS;
  }

  /** 解析 myui-vodlist__box 卡片（首页热播 / 分类页共用） */
  private parseBoxCards(html: string): IhumanismVodItem[] {
    const items: IhumanismVodItem[] = [];
    const parts: string[] = html.split('class="myui-vodlist__box"');
    for (let i = 1; i < parts.length; i++) {
      const block: string = parts[i];
      const vm: RegExpExecArray | null = new RegExp('href="/ihvoddetail/(\\d+)\\.html"').exec(block);
      if (vm === null) {
        continue;
      }
      const id: string = vm[1];
      const tm: RegExpExecArray | null = new RegExp('title="([^"]+)"').exec(block);
      const pm: RegExpExecArray | null = new RegExp('background:\\s*url\\(([^)]+)\\)').exec(block);
      let remark: string = '';
      const rm: RegExpExecArray | null = new RegExp('pic-tag-top[^>]*>\\s*([^<]+?)\\s*</span>').exec(block);
      if (rm !== null) {
        remark = cleanText(rm[1]);
      }
      items.push({
        'vod_id': id,
        'vod_name': tm !== null ? cleanText(htmlDecode(tm[1])) : id,
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
      console.error('[IhumanismSpider] homeContent error: ' + String(e));
      return '{"class":' + FALLBACK_CLASS + ',"filters":{},"list":[]}';
    }
  }

  async homeVideoContent(): Promise<string> {
    try {
      const html: string = await this.fetch(BASE);
      const items: IhumanismVodItem[] = this.parseBoxCards(html);
      return '{"list":' + JSON.stringify(items) + '}';
    } catch (e) {
      console.error('[IhumanismSpider] homeVideoContent error: ' + String(e));
      return '{"list":[]}';
    }
  }

  async categoryContent(tid: string, pg: number, extend: Map<string, string>): Promise<string> {
    try {
      const url: string = BASE + '/ihvodtype/' + tid + '-' + pg + '.html';
      const html: string = await this.fetch(url);
      const items: IhumanismVodItem[] = this.parseBoxCards(html);
      // 分页号取分页链接最大值
      let pagecount: number = 1;
      const re: RegExp = new RegExp('href="/ihvodtype/' + tid + '-(\\d+)\\.html"', 'g');
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
      console.error('[IhumanismSpider] categoryContent error tid=' + tid + ': ' + String(e));
      return '{"list":[],"pagecount":0}';
    }
  }

  async detailContent(ids: string[]): Promise<string> {
    try {
      const vodId: string = ids.length > 0 ? ids[0] : '';
      if (vodId.length === 0) {
        return '{"list":[]}';
      }
      const html: string = await this.fetch(BASE + '/ihvoddetail/' + vodId + '.html');
      const item: Record<string, Object> = {};
      const tm: RegExpExecArray | null = new RegExp('<h1 class="title">([^<]+)</h1>').exec(html);
      item['vod_id'] = vodId;
      item['vod_name'] = tm !== null ? cleanText(htmlDecode(tm[1])) : vodId;
      const pm: RegExpExecArray | null = new RegExp('img class="lazyload"[^>]*data-original="([^"]+)"').exec(html);
      item['vod_pic'] = pm !== null ? pm[1] : '';
      const director: string = pickLinkTexts(html, '导演');
      const actor: string = pickLinkTexts(html, '主演');
      item['vod_director'] = director;
      item['vod_actor'] = actor;
      // 年份/地区从"分类"信息段取三个链接：分类、地区、年份
      const catM: RegExpExecArray | null = new RegExp('<span class="text-muted">分类：</span>([\\s\\S]*?)</p>').exec(html);
      if (catM !== null) {
        const links: string[] = [];
        const are: RegExp = new RegExp('<a[^>]*>([^<]+)</a>', 'g');
        let am: RegExpExecArray | null = are.exec(catM[1]);
        while (am !== null) {
          links.push(cleanText(am[1]));
          am = are.exec(catM[1]);
        }
        if (links.length >= 1) {
          item['vod_class'] = links[0];
        }
        if (links.length >= 2) {
          item['vod_area'] = links[1];
        }
        if (links.length >= 3) {
          item['vod_year'] = links[2];
        }
      }
      // 备注：取更新行"HD国语/2026-10-12"的斜杠前部分
      const rm: RegExpExecArray | null = new RegExp('<span class="text-muted">更新：</span><span class="text-red">([^<]+)</span>').exec(html);
      if (rm !== null) {
        const remark: string = rm[1];
        const slash: number = remark.indexOf('/');
        item['vod_remarks'] = slash > 0 ? remark.substring(0, slash) : remark;
      } else {
        item['vod_remarks'] = '';
      }
      // 简介
      const cm: RegExpExecArray | null = new RegExp('<span class="text-muted">简介：</span>([\\s\\S]*?)<a class="text-link"').exec(html);
      item['vod_content'] = cm !== null ? cleanText(cm[1]) : '';
      // 播放源分组
      const froms: string[] = [];
      const groups: string[] = [];
      const tabRe: RegExp = new RegExp('<li[^>]*><a href="#playlist\\d+"[^>]*>([^<]+)</a>', 'g');
      let tabM: RegExpExecArray | null = tabRe.exec(html);
      let srcIdx: number = 1;
      while (tabM !== null) {
        const fromName: string = cleanText(tabM[1]);
        const plRe: RegExp = new RegExp('id="playlist' + srcIdx + '"[^>]*>[\\s\\S]*?<ul class="myui-content__list[^>]*>([\\s\\S]*?)</ul>');
        const plM: RegExpExecArray | null = plRe.exec(html);
        if (plM !== null) {
          const eps: string[] = [];
          const ere: RegExp = new RegExp('href="/ihvodplay/' + vodId + '-(\\d+)-(\\d+)\\.html"[^>]*>\\s*([^<]{1,30})\\s*</a>', 'g');
          let em: RegExpExecArray | null = ere.exec(plM[1]);
          while (em !== null) {
            eps.push(cleanText(em[3]) + '$' + BASE + '/ihvodplay/' + vodId + '-' + em[1] + '-' + em[2] + '.html');
            em = ere.exec(plM[1]);
          }
          if (eps.length > 0) {
            froms.push(fromName);
            groups.push(eps.join('#'));
          }
        }
        srcIdx++;
        tabM = tabRe.exec(html);
      }
      item['vod_play_from'] = froms.join('$$$');
      item['vod_play_url'] = groups.join('$$$');
      return '{"list":[' + JSON.stringify(item) + ']}';
    } catch (e) {
      console.error('[IhumanismSpider] detailContent error: ' + String(e));
      return '{"list":[]}';
    }
  }

  async searchContent(key: string, quick: boolean, pg?: number): Promise<string> {
    try {
      const url: string = BASE + '/ihvodsearch/' + encodeURIComponent(key) + '-------------.html';
      const html: string = await this.fetch(url);
      const items: IhumanismVodItem[] = [];
      const listM: RegExpExecArray | null = new RegExp('<ul class="myui-vodlist__media clearfix"[^>]*>([\\s\\S]*?)</ul>').exec(html);
      if (listM !== null) {
        const parts: string[] = listM[1].split('<li class="active  clearfix">');
        for (let i = 1; i < parts.length; i++) {
          const block: string = parts[i];
          const vm: RegExpExecArray | null = new RegExp('href="/ihvoddetail/(\\d+)\\.html"').exec(block);
          if (vm === null) {
            continue;
          }
          const id: string = vm[1];
          const tm: RegExpExecArray | null = new RegExp('title="([^"]+)"').exec(block);
          const pm: RegExpExecArray | null = new RegExp('data-original="([^"]+)"').exec(block);
          let remark: string = '';
          const rm: RegExpExecArray | null = new RegExp('pic-text[^>]*>\\s*([^<]{1,30})\\s*</span>').exec(block);
          if (rm !== null) {
            remark = cleanText(rm[1]);
          }
          items.push({
            'vod_id': id,
            'vod_name': tm !== null ? cleanText(htmlDecode(tm[1])) : id,
            'vod_pic': pm !== null ? pm[1] : '',
            'vod_remarks': remark
          });
        }
      }
      return '{"list":' + JSON.stringify(items) + '}';
    } catch (e) {
      console.error('[IhumanismSpider] searchContent error: ' + String(e));
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
      console.error('[IhumanismSpider] playerContent error: ' + String(e));
      return null;
    }
  }

  destroy(): void {
    super.destroy();
  }

  /** GET 请求（携带桌面 UA，避免被站点拦截）；带页面级缓存 + https 失败自动降级 http */
  private async fetch(url: string): Promise<string> {
    const cached: string | undefined = this.pageCache.get(url);
    const cachedTs: number | undefined = this.pageCacheTs.get(url);
    if (cached !== undefined && cachedTs !== undefined && Date.now() - cachedTs < IhumanismSpider.CACHE_TTL_MS) {
      return cached;
    }
    const headers: Map<string, string> = new Map();
    headers.set('User-Agent', UA);
    headers.set('Referer', BASE + '/');
    let html: string;
    try {
      html = await httpGet(url, headers);
    } catch (httpsErr) {
      const httpUrl: string = url.startsWith('https://') ? 'http://' + url.substring(8) : url;
      console.error('[IhumanismSpider] https fetch failed ' + url + ': ' + String(httpsErr) + ' -> try http');
      if (httpUrl !== url) {
        html = await httpGet(httpUrl, headers);
      } else {
        throw new Error(String(httpsErr));
      }
    }
    if (html.length === 0) {
      console.error('[IhumanismSpider] fetch empty html: ' + url);
      return html;
    }
    this.pageCache.set(url, html);
    this.pageCacheTs.set(url, Date.now());
    if (this.pageCache.size > IhumanismSpider.CACHE_MAX) {
      this.pageCache.clear();
      this.pageCacheTs.clear();
    }
    return html;
  }
}
