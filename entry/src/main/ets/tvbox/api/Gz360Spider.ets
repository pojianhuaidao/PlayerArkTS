/**
 * 瓜子影视 (csp_Gz360) 原生 ArkTS Spider
 * 依据 lubin.php 中 Gz360 类反编译协议实现，type=0 内置类，编译进 App
 * 协议要点：
 *  - 请求体 AES-128-CBC(PKCS7) 加密（固定 key/iv）后 hex 大写 -> request_key
 *  - 动态 key 用 RSA-1024/PKCS1 公钥加密 base64 -> keys
 *  - MD5 签名（盐 *&zvdvdvddbfikkkumtmdwqppp?|4Y!s!2br）
 *  - 响应 data.response_key 为业务密文(hex)，data.keys 为 RSA 密文，解出动态 AES key/iv 后解密业务 JSON
 *  - 设备注册 signUp -> token / app_user_id，token 持久化以便下次 signIn
 */
import { Spider } from './Spider';
import { SourceBean } from '../model/SourceBean';
import { PlayInfo } from '../model/Movie';
import { httpPost } from '../utils/HttpUtil';
import { PreferencesUtil } from '../utils/PreferencesUtil';
import { aesCBCDecrypt, md5, base64Encode, base64Decode } from '../util/AESUtil';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

const AES_KEY_STR: string = 'OITxa5OqAYjhswxx';
const AES_IV_STR: string = 'rCMNwZASNBKZ8mXV';
const SALT: string = '*&zvdvdvddbfikkkumtmdwqppp?|4Y!s!2br';
const OLD_KEY: string = 'aLFBMWpxBrIDAD1Si/KVvm41';
const PUB_DER_B64: string = 'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDUM5+/y8sPsWkd1/RQS64X259EUwxFXFE5HlA65MqrxnPs0JqoSRojSDy5QhwvROlaD6TwRQHKMY2OAZ6SnQeUJsChTEFIR9qUkwrs3/MVUMxjsv6JS6Oe/juclyJGTgVmDhB55EafXsD0SQYVj/QXXsxR6ewR5E2kL52yAAD4yQIDAQAB';
const PRI_DER_B64: string = 'MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGAe6hKrWLi1zQmjTT1ozbE4QdFeJGNxubxld6GrFGximxfMsMB6BpJhpcTouAqywAFppiKetUBBbXwYsYU1wNr648XVmPmCMCy4rY8vdliFnbMUj086DU6Z+/oXBdWU3/b1G0DN3E9wULRSwcKZT3wj/cCI1vsCm3gj2R5SqkA9Y0CAwEAAQKBgAJH+4CxV0/zBVcLiBCHvSANm0l7HetybTh/j2p0Y1sTXro4ALwAaCTUeqdBjWiLSo9lNwDHFyq8zX90+gNxa7c5EqcWV9FmlVXr8VhfBzcZo1nXeNdXFT7tQ2yah/odtdcx+vRMSGJd1t/5k5bDd9wAvYdIDblMAg+wiKKZ5KcdAkEA1cCakEN4NexkF5tHPRrR6XOY/XHfkqXxEhMqmNbB9U34saTJnLWIHC8IXys6Qmzz30TtzCjuOqKRRy+FMM4TdwJBAJQZFPjsGC+RqcG5UvVMiMPhnwe/bXEehShK86yJK/g/UiKrO87h3aEu5gcJqBygTq3BBBoH2md3pr/W+hUMWBsCQQChfhTIrdDinKi6lRxrdBnn0Ohjg2cwuqK5zzU9p/N+S9x7Ck8wUI53DKm8jUJE8WAG7WLj/oCOWEh+ic6NIwTdAkEAj0X8nhx6AXsgCYRql1klbqtVmL8+95KZK7PnLWG/IfjQUy3pPGoSaZ7fdquG8bq8oyf5+dzjE/oTXcByS+6XRQJAP/5ciy1bL3NhUhsaOVy55MHXnPjdcTX0FaLi+ybXZIfIQ2P4rb19mVq1feMbCXhz+L1rG8oat5lYKfpe8k83ZA==';
const HOSTS: string[] = [
  'https://apinew.uozvr.com',
  'https://api.w32z7vtd.com',
  'https://api.6a7nnf7.com',
  'https://api.umygrx3.com',
  'https://api.rmedphk.com'
];
const PACKAGE_NAME: string = 'com.ae06aebdbb.y286327f5a.ofe849883320260517';
const PREF_PREFIX: string = 'gz360_';
const HOME_CLASS: string = '[{"type_id":"1","type_name":"电影"},{"type_id":"2","type_name":"电视剧"},{"type_id":"3","type_name":"动漫"},{"type_id":"4","type_name":"综艺"},{"type_id":"64","type_name":"短剧"}]';
const HOME_FILTERS: string = `{"1":[{"key":"area","name":"地区","value":[{"n":"地区","v":"0"},{"n":"大陆","v":"大陆"},{"n":"香港","v":"香港"},{"n":"台湾","v":"台湾"},{"n":"欧美","v":"俄罗斯,加拿大,德国,意大利,法国,欧美,美国,英国,西班牙"},{"n":"日本","v":"日本"},{"n":"韩国","v":"韩国"},{"n":"泰国","v":"泰国"},{"n":"其他","v":"其他,印度,新加坡,马来西亚"}]},{"key":"year","name":"年份","value":[{"n":"年份","v":"0"},{"n":"2026","v":"2026"},{"n":"2025","v":"2025"},{"n":"2024","v":"2024"},{"n":"2023","v":"2023"},{"n":"2022","v":"2022"},{"n":"2021","v":"2021"},{"n":"2020","v":"2020"},{"n":"2019","v":"2019"},{"n":"2018","v":"2018"},{"n":"2017","v":"2017"},{"n":"2016","v":"2016"},{"n":"10-15年","v":"2015,2014,2013,2012,2011,2010"},{"n":"00年代","v":"2000,2001,2002,2003,2004,2005,2006,2007,2008,2009"},{"n":"90年代","v":"1990,1991,1992,1993,1994,1995,1996,1997,1998,1999"},{"n":"80年代","v":"1980,1981,1982,1983,1984,1985,1986,1987,1988,1989"},{"n":"更早","v":"2"}]},{"key":"sub","name":"类型","value":[{"n":"动作片","v":"5"},{"n":"悬疑片","v":"29"},{"n":"喜剧片","v":"6"},{"n":"爱情片","v":"7"},{"n":"科幻片","v":"8"},{"n":"恐怖片","v":"9"},{"n":"剧情片","v":"10"},{"n":"战争片","v":"11"},{"n":"动画片","v":"36"},{"n":"纪录片","v":"20"},{"n":"灾难片","v":"38"},{"n":"犯罪片","v":"61"}]},{"key":"sort","name":"排序","value":[{"n":"综合","v":"d_id"},{"n":"最新","v":"d_addtime"},{"n":"最热","v":"d_score"},{"n":"高分","v":"d_score"}]}],"2":[{"key":"area","name":"地区","value":[{"n":"地区","v":"0"},{"n":"大陆","v":"大陆"},{"n":"香港","v":"香港"},{"n":"台湾","v":"台湾"},{"n":"欧美","v":"俄罗斯,加拿大,德国,意大利,法国,欧美,美国,英国,西班牙"},{"n":"日本","v":"日本"},{"n":"韩国","v":"韩国"},{"n":"泰国","v":"泰国"},{"n":"其他","v":"其他,印度,新加坡,马来西亚"}]},{"key":"year","name":"年份","value":[{"n":"年份","v":"0"},{"n":"2026","v":"2026"},{"n":"2025","v":"2025"},{"n":"2024","v":"2024"},{"n":"2023","v":"2023"},{"n":"2022","v":"2022"},{"n":"2021","v":"2021"},{"n":"2020","v":"2020"},{"n":"2019","v":"2019"},{"n":"2018","v":"2018"},{"n":"2017","v":"2017"},{"n":"2016","v":"2016"},{"n":"10-15年","v":"2015,2014,2013,2012,2011,2010"},{"n":"00年代","v":"2000,2001,2002,2003,2004,2005,2006,2007,2008,2009"},{"n":"90年代","v":"1990,1991,1992,1993,1994,1995,1996,1997,1998,1999"},{"n":"80年代","v":"1980,1981,1982,1983,1984,1985,1986,1987,1988,1989"},{"n":"更早","v":"2"}]},{"key":"sub","name":"类型","value":[{"n":"国产剧","v":"12"},{"n":"香港剧","v":"13"},{"n":"台湾剧","v":"14"},{"n":"欧美剧","v":"15"},{"n":"日本剧","v":"16"},{"n":"韩国剧","v":"17"},{"n":"海外剧","v":"18"},{"n":"泰国剧","v":"19"},{"n":"新加坡","v":"69"}]},{"key":"sort","name":"排序","value":[{"n":"综合","v":"d_id"},{"n":"最新","v":"d_addtime"},{"n":"最热","v":"d_score"},{"n":"高分","v":"d_score"}]}],"3":[{"key":"area","name":"地区","value":[{"n":"地区","v":"0"},{"n":"大陆","v":"大陆"},{"n":"香港","v":"香港"},{"n":"台湾","v":"台湾"},{"n":"欧美","v":"俄罗斯,加拿大,德国,意大利,法国,欧美,美国,英国,西班牙"},{"n":"日本","v":"日本"},{"n":"韩国","v":"韩国"},{"n":"泰国","v":"泰国"},{"n":"其他","v":"其他,印度,新加坡,马来西亚"}]},{"key":"year","name":"年份","value":[{"n":"年份","v":"0"},{"n":"2026","v":"2026"},{"n":"2025","v":"2025"},{"n":"2024","v":"2024"},{"n":"2023","v":"2023"},{"n":"2022","v":"2022"},{"n":"2021","v":"2021"},{"n":"2020","v":"2020"},{"n":"2019","v":"2019"},{"n":"2018","v":"2018"},{"n":"2017","v":"2017"},{"n":"2016","v":"2016"},{"n":"10-15年","v":"2015,2014,2013,2012,2011,2010"},{"n":"00年代","v":"2000,2001,2002,2003,2004,2005,2006,2007,2008,2009"},{"n":"90年代","v":"1990,1991,1992,1993,1994,1995,1996,1997,1998,1999"},{"n":"80年代","v":"1980,1981,1982,1983,1984,1985,1986,1987,1988,1989"},{"n":"更早","v":"2"}]},{"key":"sub","name":"类型","value":[{"n":"中国动漫","v":"30"},{"n":"日本动漫","v":"31"},{"n":" 欧美动漫","v":"33"}]},{"key":"sort","name":"排序","value":[{"n":"综合","v":"d_id"},{"n":"最新","v":"d_addtime"},{"n":"最热","v":"d_score"},{"n":"高分","v":"d_score"}]}],"4":[{"key":"area","name":"地区","value":[{"n":"地区","v":"0"},{"n":"大陆","v":"大陆"},{"n":"香港","v":"香港"},{"n":"台湾","v":"台湾"},{"n":"欧美","v":"俄罗斯,加拿大,德国,意大利,法国,欧美,美国,英国,西班牙"},{"n":"日本","v":"日本"},{"n":"韩国","v":"韩国"},{"n":"泰国","v":"泰国"},{"n":"其他","v":"其他,印度,新加坡,马来西亚"}]},{"key":"year","name":"年份","value":[{"n":"年份","v":"0"},{"n":"2026","v":"2026"},{"n":"2025","v":"2025"},{"n":"2024","v":"2024"},{"n":"2023","v":"2023"},{"n":"2022","v":"2022"},{"n":"2021","v":"2021"},{"n":"2020","v":"2020"},{"n":"2019","v":"2019"},{"n":"2018","v":"2018"},{"n":"2017","v":"2017"},{"n":"2016","v":"2016"},{"n":"10-15年","v":"2015,2014,2013,2012,2011,2010"},{"n":"00年代","v":"2000,2001,2002,2003,2004,2005,2006,2007,2008,2009"},{"n":"90年代","v":"1990,1991,1992,1993,1994,1995,1996,1997,1998,1999"},{"n":"80年代","v":"1980,1981,1982,1983,1984,1985,1986,1987,1988,1989"},{"n":"更早","v":"2"}]},{"key":"sub","name":"类型","value":[{"n":"大陆综艺","v":"22"},{"n":"港台综艺","v":"23"},{"n":"日韩综艺","v":"24"},{"n":"欧美综艺","v":"25"}]},{"key":"sort","name":"排序","value":[{"n":"综合","v":"d_id"},{"n":"最新","v":"d_addtime"},{"n":"最热","v":"d_score"},{"n":"高分","v":"d_score"}]}],"64":[{"key":"sort","name":"排序","value":[{"n":"综合","v":"d_id"},{"n":"最新","v":"d_addtime"},{"n":"最热","v":"d_score"},{"n":"高分","v":"d_score"}]}]}`;

export class Gz360Spider extends Spider {
  private hostsIdx: number = 0;
  private base: string = HOSTS[0];
  private token: string = '';
  private tokenId: string = '';
  private deviceId: string = '';
  private deviceKey: string = '';
  private registered: boolean = false;
  private authed: boolean = false;
  private stateLoaded: boolean = false;
  private inited: boolean = false;
  /** 列表接口响应缓存：首页/分类/搜索 在 TTL 内直接复用，避免每次进入界面重复请求 */
  private readonly listCache: Map<string, string> = new Map<string, string>();
  private readonly listCacheTs: Map<string, number> = new Map<string, number>();
  private static readonly CACHE_TTL_MS: number = 10 * 60 * 1000;
  private static readonly CACHE_MAX: number = 200;

  init(bean: SourceBean): void {
    super.init(bean);
    if (this.inited) {
      return;
    }
    this.inited = true;
    // 持久化状态在首次请求前异步加载（见 loadState）
  }

  async homeContent(filter: boolean): Promise<string> {
    return '{"class":' + HOME_CLASS + ',"filters":' + HOME_FILTERS + ',"list":[]}';
  }

  async homeVideoContent(): Promise<string> {
    try {
      const resp = await this.request('/App/IndexList/index', { 'pid': '1' }, 0);
      const groups: Object[] | undefined = resp['list'] as Object[] | undefined;
      const items: Object[] = [];
      if (groups !== undefined && groups !== null) {
        for (let i = 1; i < groups.length; i++) {
          const g: Record<string, Object> = groups[i] as Record<string, Object>;
          const lst: Object[] | undefined = g['list'] as Object[] | undefined;
          if (lst !== undefined && lst !== null) {
            for (const it of lst) {
              items.push(this.toVodItem(it as Record<string, Object>));
            }
          }
        }
      }
      return '{"list":' + JSON.stringify(items) + '}';
    } catch (e) {
      console.error('[Gz360Spider] homeVideoContent error: ' + String(e));
      return '{"list":[]}';
    }
  }

  async categoryContent(tid: string, pg: number, extend: Map<string, string>): Promise<string> {
    try {
      const tMap: Record<string, string> = { '1': '1', '2': '2', '3': '3', '4': '4', '64': '64' };
      const subMap: Record<string, string> = { '1': '5', '2': '12', '3': '30', '4': '22', '64': '' };
      let area: string = '0';
      let year: string = '0';
      let sort: string = 'd_id';
      let sub: string = subMap[tid] !== undefined ? subMap[tid] : '';
      if (extend !== undefined && extend !== null) {
        const a: string | undefined = extend.get('area');
        if (a !== undefined) {
          area = a;
        }
        const y: string | undefined = extend.get('year');
        if (y !== undefined) {
          year = y;
        }
        const s: string | undefined = extend.get('sort');
        if (s !== undefined) {
          sort = s;
        }
        const sb: string | undefined = extend.get('sub');
        if (sb !== undefined) {
          sub = sb;
        }
      }
      const tidReq: string = tMap[tid] !== undefined ? tMap[tid] : tid;
      const params: Record<string, string> = {
        'tid': tidReq,
        'page': String(pg),
        'pageSize': '30',
        'area': area,
        'year': year,
        'sort': sort,
        'sub': sub
      };
      const resp = await this.request('/App/IndexList/indexList', params, 0);
      const lst: Object[] | undefined = resp['list'] as Object[] | undefined;
      const items: Object[] = [];
      if (lst !== undefined && lst !== null) {
        for (const it of lst) {
          items.push(this.toVodItem(it as Record<string, Object>));
        }
      }
      const total: number = items.length;
      const pagecount: number = Math.max(1, Math.ceil(total / 30));
      return '{"page":' + pg + ',"pagecount":' + pagecount + ',"limit":30,"total":' + total +
        ',"list":' + JSON.stringify(items) + '}';
    } catch (e) {
      console.error('[Gz360Spider] categoryContent error tid=' + tid + ': ' + String(e));
      return '{"list":[],"pagecount":0}';
    }
  }

  async detailContent(ids: string[]): Promise<string> {
    try {
      const vodId: string = ids.length > 0 ? ids[0] : '';
      if (vodId.length === 0) {
        return '{"list":[]}';
      }
      const p1: Record<string, string> = {
        'token_id': this.tokenId,
        'vod_id': vodId,
        'mobile_time': String(Math.floor(Date.now() / 1000)),
        'token': this.token
      };
      const info = await this.request('/App/IndexPlay/playInfo', p1, 0);
      const p2: Record<string, string> = { 'vurl_cloud_id': '2', 'vod_d_id': vodId };
      const vurl = await this.request('/App/Resource/Vurl/show', p2, 0);
      const item: Record<string, Object> = {};
      const vi: Record<string, Object> | undefined = info['vodInfo'] as Record<string, Object> | undefined;
      if (vi !== undefined && vi !== null) {
        item['vod_id'] = vodId;
        item['vod_name'] = Gz360Spider.getStr(vi, 'vod_name');
        const pic: string = Gz360Spider.getStr(vi, 'vod_pic');
        item['vod_pic'] = pic.length > 0 ? pic + '@User-Agent=Dalvik/2.1.0' : pic;
        item['vod_year'] = Gz360Spider.getStr(vi, 'vod_year');
        item['vod_area'] = Gz360Spider.getStr(vi, 'vod_area');
        item['vod_actor'] = Gz360Spider.getStr(vi, 'vod_actor');
        item['vod_director'] = Gz360Spider.getStr(vi, 'vod_director');
        let desc: string = Gz360Spider.getStr(vi, 'vod_use_content');
        if (desc.length === 0) {
          desc = Gz360Spider.getStr(vi, 'vod_content');
        }
        if (desc.length === 0) {
          desc = Gz360Spider.getStr(vi, 'content');
        }
        item['vod_content'] = desc.replaceAll('　', '\n').trim();
        item['vod_remarks'] = this.makeRemarks(vi);
      }
      const playFrom: string[] = [];
      const playUrlGroups: string[] = [];
      const vlist: Object[] | undefined = vurl['list'] as Object[] | undefined;
      if (vlist !== undefined && vlist !== null && vlist.length > 0) {
        // Vurl/show 的 list 每一项是一集（title 为集号），play 内 480/720/1080 为清晰度；
        // 整部剧只有一个播放源，源名固定取 Gz360。
        const sourceName: string = 'Gz360';
        const eps: string[] = [];
        for (let idx = 0; idx < vlist.length; idx++) {
          const v: Record<string, Object> = vlist[idx] as Record<string, Object>;
          let param: string = Gz360Spider.getStr(v, 'default_param');
          if (param.length === 0) {
            const play: Record<string, Object> | undefined = v['play'] as Record<string, Object> | undefined;
            if (play !== undefined && play !== null) {
              for (const srcKey of Object.keys(play)) {
                const epObj: Record<string, Object> = play[srcKey] as Record<string, Object>;
                if (epObj === undefined || epObj === null) {
                  continue;
                }
                const p2: string = Gz360Spider.getStr(epObj, 'param');
                if (p2.length > 0) {
                  param = p2;
                  break;
                }
              }
            }
          }
          if (param.length === 0) {
            continue;
          }
          let epName: string = Gz360Spider.getStr(v, 'title');
          if (epName.length === 0) {
            epName = '第' + (idx + 1) + '集';
          }
          eps.push(epName + '$' + param + '||' + sourceName);
        }
        if (eps.length > 0) {
          playFrom.push(sourceName);
          playUrlGroups.push(eps.join('#'));
        }
      }
      item['vod_play_from'] = playFrom.join('$$$');
      item['vod_play_url'] = playUrlGroups.join('$$$');
      return '{"list":[' + JSON.stringify(item) + ']}';
    } catch (e) {
      return '{"list":[]}';
    }
  }

  async searchContent(key: string, quick: boolean, pg?: number): Promise<string> {
    try {
      const resp = await this.request('/App/Index/findMoreVod', { 'keywords': key, 'order_val': '1' }, 0);
      const lst: Object[] | undefined = resp['list'] as Object[] | undefined;
      const items: Object[] = [];
      if (lst !== undefined && lst !== null) {
        for (const it of lst) {
          items.push(this.toVodItem(it as Record<string, Object>));
        }
      }
      return '{"list":' + JSON.stringify(items) + '}';
    } catch (e) {
      return '{"list":[]}';
    }
  }

  async playerContent(flag: string, id: string): Promise<PlayInfo | null> {
    try {
      const parts: string[] = id.split('||');
      let paramPart: string = parts.length > 0 ? parts[0] : '';
      const dollarIdx: number = paramPart.indexOf('$');
      if (dollarIdx >= 0) {
        paramPart = paramPart.substring(dollarIdx + 1);
      }
      const params: Record<string, string> = {};
      if (paramPart.length > 0) {
        const kvs: string[] = paramPart.split('&');
        for (const kv of kvs) {
          const eq: number = kv.indexOf('=');
          if (eq > 0) {
            let k: string = kv.substring(0, eq);
            const v: string = kv.substring(eq + 1);
            if (k === 'vod_d_id') {
              k = 'vod_id';
            }
            params[k] = v;
          }
        }
      }
      const resp = await this.request('/App/Resource/VurlDetail/showOne', params, 0);
      const url: string = Gz360Spider.getStr(resp, 'url');
      const headers: Map<string, string> = new Map();
      headers.set('User-Agent', 'Lavf/57.83.100');
      headers.set('Referer', 'http://WJiZxLXA2.com/');
      const info: PlayInfo = { url: url, header: headers, parse: 0, jx: 0 };
      return info;
    } catch (e) {
      return null;
    }
  }

  destroy(): void {
    this.authed = false;
  }

  /** 持久化状态恢复（首次请求前调用一次） */
  private async loadState(): Promise<void> {
    if (this.stateLoaded) {
      return;
    }
    this.stateLoaded = true;
    this.token = await PreferencesUtil.get(PREF_PREFIX + 'token', '');
    this.tokenId = await PreferencesUtil.get(PREF_PREFIX + 'token_id', '');
    this.deviceId = await PreferencesUtil.get(PREF_PREFIX + 'device_id', '');
    this.deviceKey = await PreferencesUtil.get(PREF_PREFIX + 'device_key', '');
    this.registered = await PreferencesUtil.getBool(PREF_PREFIX + 'registered', false);
    if (this.deviceId.length === 0 || this.deviceKey.length === 0) {
      this.deviceId = String(864150060000000 + Math.floor(Math.random() * 10000));
      let k: string = '';
      for (let i = 0; i < 20; i++) {
        k += Math.floor(Math.random() * 256).toString(16).padStart(2, '0');
      }
      this.deviceKey = k.toUpperCase();
      await PreferencesUtil.put(PREF_PREFIX + 'device_id', this.deviceId);
      await PreferencesUtil.put(PREF_PREFIX + 'device_key', this.deviceKey);
    }
  }

  /** 业务请求统一入口：AES/RSA/MD5 组装 + 解密响应 */
  private async request(path: string, params: Record<string, string>, retry: number): Promise<Record<string, Object>> {
    // 列表类接口先查响应缓存（key=path+params，TTL 10min）
    const isList: boolean = path === '/App/IndexList/index' || path === '/App/IndexList/indexList' || path === '/App/Index/findMoreVod';
    const cacheKey: string = path + JSON.stringify(params);
    if (retry === 0 && isList) {
      const cachedRaw: string | undefined = this.listCache.get(cacheKey);
      const cachedTs: number | undefined = this.listCacheTs.get(cacheKey);
      if (cachedRaw !== undefined && cachedTs !== undefined && Date.now() - cachedTs < Gz360Spider.CACHE_TTL_MS) {
        return JSON.parse(cachedRaw) as Record<string, Object>;
      }
    }
    if (!path.startsWith('/App/Authentication/')) {
      await this.ensureAuth();
    }
    const body: Record<string, string> = {};
    for (const k of Object.keys(params)) {
      body[k] = params[k];
    }
    body['token'] = this.token;
    body['token_id'] = this.tokenId;
    const plain: string = JSON.stringify(body);
    const requestKey: string = (await Gz360Spider.aesEncrypt(plain)).toUpperCase();
    const keysPayload: string = '{"iv":"' + AES_IV_STR + '","key":"' + AES_KEY_STR + '"}';
    const keys: string = base64Encode(await Gz360Spider.rsaPublicEncrypt(new util.TextEncoder().encodeInto(keysPayload)));
    const t: string = String(Math.floor(Date.now() / 1000));
    const signSrc: string = 'token_id=,token=' + this.token + ',phone_type=1,request_key=' + requestKey +
      ',app_id=1,time=' + t + ',keys=' + keys + SALT;
    const sign: string = (await md5(signSrc)).toUpperCase();
    const form: string =
      'token=' + encodeURIComponent(this.token) +
      '&token_id=' +
      '&phone_type=1' +
      '&time=' + t +
      '&phone_model=xiaomi-25031' +
      '&keys=' + encodeURIComponent(keys) +
      '&request_key=' + encodeURIComponent(requestKey) +
      '&signature=' + sign +
      '&app_id=1' +
      '&ad_version=1';
    const headers: Map<string, string> = new Map();
    headers.set('User-Agent', 'Lavf/57.83.100');
    headers.set('code', 'GZ0369');
    headers.set('deviceId', this.deviceId);
    headers.set('lang', 'zh_cn');
    headers.set('Cache-Control', 'no-cache');
    headers.set('Content-Type', 'application/x-www-form-urlencoded');
    headers.set('Version', '2604028');
    headers.set('PackageName', PACKAGE_NAME);
    headers.set('Ver', '3.0.3.2');
    headers.set('api-ver', '3.0.3.2');

    let raw: string = '';
    try {
      raw = await httpPost(this.base + path, form, headers);
    } catch (e) {
      console.error('[Gz360Spider] httpPost fail path=' + path + ' host=' + this.base + ' err=' + String(e));
      if (retry < 1) {
        this.hostsIdx = (this.hostsIdx + 1) % HOSTS.length;
        this.base = HOSTS[this.hostsIdx];
        return await this.request(path, params, retry + 1);
      }
      throw new Error(e instanceof Error ? e.message : String(e));
    }
    const obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
    const code: number = Gz360Spider.getNum(obj, 'code');
    if (code === 200) {
      const data: Record<string, Object> | undefined = obj['data'] as Record<string, Object> | undefined;
      if (data !== undefined && data !== null) {
        const rk: string = Gz360Spider.getStr(data, 'response_key');
        const kb: string = Gz360Spider.getStr(data, 'keys');
        if (rk.length > 0 && kb.length > 0) {
          const dynObj: Record<string, Object> = JSON.parse(
            Gz360Spider.bytesToStr(await Gz360Spider.rsaPrivateDecrypt(base64Decode(kb)))
          ) as Record<string, Object>;
          const dKey: string = Gz360Spider.getStr(dynObj, 'key');
          const dIv: string = Gz360Spider.getStr(dynObj, 'iv');
          const biz: string = await aesCBCDecrypt(rk, dKey, dIv);
          const parsed: Record<string, Object> = JSON.parse(biz) as Record<string, Object>;
          if (isList && retry === 0) {
            this.listCache.set(cacheKey, JSON.stringify(parsed));
            this.listCacheTs.set(cacheKey, Date.now());
            if (this.listCache.size > Gz360Spider.CACHE_MAX) {
              this.listCache.clear();
              this.listCacheTs.clear();
            }
          }
          return parsed;
        }
      }
      return data !== undefined ? data : {};
    }
    if (retry < 1 && !path.startsWith('/App/Authentication/')) {
      this.authed = false;
      await this.ensureAuth();
      return await this.request(path, params, retry + 1);
    }
    console.error('[Gz360Spider] api error code=' + code + ' path=' + path + ' host=' + this.base);
    throw new Error('gz360 api code=' + code + ' path=' + path);
  }

  /** 设备认证：注册 / 登录 / 刷新 token；失败时清空旧状态重新注册 */
  private async ensureAuth(): Promise<void> {
    await this.loadState();
    if (this.authed && this.token.length > 0) {
      return;
    }
    try {
      if (this.token.length === 0) {
        if (this.registered) {
          await this.signIn();
        } else {
          await this.signUp();
        }
      } else {
        const resp = await this.request('/App/Authentication/Authenticator/refresh', {}, 0);
        this.saveToken(resp);
      }
    } catch (e) {
      console.error('[Gz360Spider] auth failed, reset and re-register: ' + String(e));
      this.token = '';
      this.tokenId = '';
      this.registered = false;
      this.authed = false;
      await PreferencesUtil.delete(PREF_PREFIX + 'token');
      await PreferencesUtil.delete(PREF_PREFIX + 'token_id');
      await PreferencesUtil.delete(PREF_PREFIX + 'registered');
      await this.signUp();
    }
    this.authed = true;
  }

  private async signUp(): Promise<void> {
    const params: Record<string, string> = {
      'new_key': this.deviceKey,
      'old_key': OLD_KEY,
      'phone_type': '1',
      'code': ''
    };
    try {
      const resp = await this.request('/App/Authentication/Device/signUp', params, 0);
      this.saveToken(resp);
      this.registered = true;
      await PreferencesUtil.putBool(PREF_PREFIX + 'registered', true);
    } catch (e) {
      if (String(e).includes('code=403')) {
        console.error('[Gz360Spider] signUp 403(device exists), switch to signIn');
        await this.signIn();
        this.registered = true;
        await PreferencesUtil.putBool(PREF_PREFIX + 'registered', true);
      } else {
        throw (e instanceof Error ? e : new Error(String(e)));
      }
    }
  }

  private async signIn(): Promise<void> {
    const params: Record<string, string> = {
      'new_key': this.deviceKey,
      'old_key': OLD_KEY
    };
    try {
      const resp = await this.request('/App/Authentication/Device/signIn', params, 0);
      this.saveToken(resp);
    } catch (e) {
      if (String(e).includes('code=403')) {
        console.error('[Gz360Spider] signIn 403(device invalid), reset device and re-register');
        await this.resetDevice();
        await this.signUp();
      } else {
        throw (e instanceof Error ? e : new Error(String(e)));
      }
    }
  }

  private async resetDevice(): Promise<void> {
    this.token = '';
    this.tokenId = '';
    this.registered = false;
    this.authed = false;
    this.deviceId = String(864150060000000 + Math.floor(Math.random() * 10000));
    let k: string = '';
    for (let i = 0; i < 20; i++) {
      k += Math.floor(Math.random() * 256).toString(16).padStart(2, '0');
    }
    this.deviceKey = k.toUpperCase();
    await PreferencesUtil.delete(PREF_PREFIX + 'token');
    await PreferencesUtil.delete(PREF_PREFIX + 'token_id');
    await PreferencesUtil.delete(PREF_PREFIX + 'registered');
    await PreferencesUtil.put(PREF_PREFIX + 'device_id', this.deviceId);
    await PreferencesUtil.put(PREF_PREFIX + 'device_key', this.deviceKey);
  }

  private async saveToken(resp: Record<string, Object>): Promise<void> {
    this.token = Gz360Spider.getStr(resp, 'token');
    this.tokenId = Gz360Spider.getStr(resp, 'app_user_id');
    if (this.token.length > 0) {
      await PreferencesUtil.put(PREF_PREFIX + 'token', this.token);
      await PreferencesUtil.put(PREF_PREFIX + 'token_id', this.tokenId);
      this.registered = true;
      await PreferencesUtil.putBool(PREF_PREFIX + 'registered', true);
    }
  }

  /** 列表项映射：vod_pic 追加 UA 参数，备注取更新状态/评分/年份 */
  private toVodItem(rec: Record<string, Object>): Record<string, Object> {
    const pic: string = Gz360Spider.getStr(rec, 'vod_pic');
    const item: Record<string, Object> = {
      'vod_id': Gz360Spider.getStr(rec, 'vod_id'),
      'vod_name': Gz360Spider.getStr(rec, 'vod_name'),
      'vod_pic': pic.length > 0 ? pic + '@User-Agent=Dalvik/2.1.0' : pic,
      'vod_remarks': this.makeRemarks(rec),
      'vod_year': Gz360Spider.getStr(rec, 'vod_year')
    };
    return item;
  }

  private makeRemarks(rec: Record<string, Object>): string {
    const dTotal: string = Gz360Spider.getStr(rec, 'd_total');
    if (dTotal.length === 0 || dTotal === '0') {
      const score: string = Gz360Spider.getStr(rec, 'vod_score');
      if (score.length > 0) {
        return score;
      }
      return Gz360Spider.getStr(rec, 'vod_year');
    }
    const continu: string = Gz360Spider.getStr(rec, 'vod_continu');
    if (continu === '0' || continu === dTotal) {
      return '全' + dTotal;
    }
    return '更新至' + continu + '集';
  }

  private static getStr(rec: Record<string, Object>, key: string): string {
    const v: Object | undefined = rec[key];
    if (v === undefined || v === null) {
      return '';
    }
    return String(v);
  }

  private static getNum(rec: Record<string, Object>, key: string): number {
    const v: Object | undefined = rec[key];
    if (v === undefined || v === null) {
      return -1;
    }
    return Number(v);
  }

  private static bytesToStr(data: Uint8Array): string {
    return new util.TextDecoder().decodeToString(data);
  }

  /** AES-128-CBC(PKCS7) 加密，返回 hex 大写 */
  private static async aesEncrypt(plain: string): Promise<string> {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const keyBytes: Uint8Array = encoder.encodeInto(AES_KEY_STR);
    const ivBytes: Uint8Array = encoder.encodeInto(AES_IV_STR);
    const keyGen: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
    const symKey: cryptoFramework.SymKey = await keyGen.convertKey({ data: keyBytes });
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES128|CBC|PKCS7');
    const ivSpec: cryptoFramework.IvParamsSpec = {
      algName: 'IvParamsSpec',
      iv: { data: ivBytes }
    };
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, ivSpec);
    const out: cryptoFramework.DataBlob = await cipher.doFinal({ data: encoder.encodeInto(plain) });
    let hex: string = '';
    for (let i = 0; i < out.data.length; i++) {
      hex += out.data[i].toString(16).padStart(2, '0');
    }
    return hex;
  }

  /** RSA-1024/PKCS1 公钥加密 */
  private static async rsaPublicEncrypt(data: Uint8Array): Promise<Uint8Array> {
    const gen: cryptoFramework.AsyKeyGenerator = cryptoFramework.createAsyKeyGenerator('RSA1024');
    const keyPair: cryptoFramework.KeyPair = await gen.convertKey({ data: base64Decode(PUB_DER_B64) }, null);
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('RSA|PKCS1');
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, keyPair.pubKey, null);
    const out: cryptoFramework.DataBlob = await cipher.doFinal({ data: data });
    return out.data;
  }

  /** RSA-1024/PKCS1 私钥解密 */
  private static async rsaPrivateDecrypt(data: Uint8Array): Promise<Uint8Array> {
    const gen: cryptoFramework.AsyKeyGenerator = cryptoFramework.createAsyKeyGenerator('RSA1024');
    const keyPair: cryptoFramework.KeyPair = await gen.convertKey(null, { data: base64Decode(PRI_DER_B64) });
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('RSA|PKCS1');
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, keyPair.priKey, null);
    const out: cryptoFramework.DataBlob = await cipher.doFinal({ data: data });
    return out.data;
  }
}
