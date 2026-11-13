import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { isSystemHiddenName } from './FileFilter';

const TAG: string = 'NetClient';
const DOMAIN: number = 0x0001;

/** 局域网目录中的一项：子目录或文件 */
export class NetEntry {
  name: string;
  url: string;
  isDir: boolean;
  sizeBytes: number;

  constructor(name: string, url: string, isDir: boolean, sizeBytes: number) {
    this.name = name;
    this.url = url;
    this.isDir = isDir;
    this.sizeBytes = sizeBytes;
  }
}

/** 一次目录请求的结果 */
export class NetResult {
  ok: boolean = false;
  code: number = 0;
  message: string = '';
  contentType: string = '';
  body: string = '';
  entries: NetEntry[] = [];
  /** 重定向跟随后的最终地址 */
  url: string = '';
  /** 3xx 响应给出的 Location（未跟随的原始值） */
  location: string = '';
  /** 实际走过的地址链，便于排查跳转问题 */
  attempts: string = '';
  /** 响应诊断串：code / content-type / 长度 / 报文开头，目录为空时回显给用户 */
  detail: string = '';
}

/** 地址拆解结果：path 为空表示根目录 */
export class NetUrlInfo {
  scheme: string = '';
  host: string = '';
  port: string = '';
  path: string = '';

  toString(): string {
    return `scheme=${this.scheme} host=${this.host} port=${this.port.length > 0 ? this.port : '(空)'} path=${this.path.length > 0 ? this.path : '(空)'}`;
  }
}

export class NetClient {
  static readonly VIDEO_EXT: string[] = ['.mp4', '.mkv', '.avi', '.ts', '.m2ts', '.mov', '.flv', '.webm',
    '.wmv', '.rmvb', '.rm', '.mpg', '.mpeg', '.m4v', '.3gp', '.asf', '.ogv', '.m3u8', '.mpd'];

  /** 可识别的协议名白名单：只有这些词加冒号才当协议头看待，避免把 host:port 误判 */
  static readonly SCHEMES: string[] = ['http', 'https', 'smb', 'cifs', 'ftp', 'ftps', 'sftp', 'rtsp',
    'rtmp', 'rtmps', 'udp', 'mms', 'dlna', 'upnp', 'file', 'dav', 'davs', 'webdav'];

  /** 最近一次 multistatus 解析统计（响应块数 / 剔除自身数 / 丢弃无效数），用于空目录诊断 */
  static davBlockCount: number = 0;
  static davSelfCount: number = 0;
  static davSkipCount: number = 0;
  /** 最近一次解析的统计文案，UI 空态回显用 */
  static davStats: string = '';

  /**
   * 剥离被错误叠加的协议前缀：http://https:\\host → https://host。
   * 仅当剩余部分本身又带 http(s) 前缀时才继续剥，主机名形如 httpbin.org 不会被误伤。
   */
  private static peel(u: string): string {
    let s: string = u;
    let guard: number = 0;
    while (guard < 4) {
      const lower: string = s.toLowerCase();
      let cut: number = -1;
      if (lower.startsWith('https://')) {
        cut = 8;
      } else if (lower.startsWith('http://')) {
        cut = 7;
      } else if (lower.startsWith('https:/')) {
        cut = 7;
      } else if (lower.startsWith('http:/')) {
        cut = 6;
      } else {
        break;
      }
      const rest: string = s.substring(cut);
      const restLower: string = rest.toLowerCase();
      const nested: boolean = restLower.startsWith('https://') || restLower.startsWith('http://') ||
        restLower.startsWith('https:/') || restLower.startsWith('http:/');
      if (!nested) {
        break;
      }
      s = rest;
      guard++;
    }
    return s;
  }

  /** 协议名是否可识别（不含点号，host:port 不会被误判为协议） */
  private static isKnownScheme(name: string): boolean {
    for (let i = 0; i < NetClient.SCHEMES.length; i++) {
      if (NetClient.SCHEMES[i] === name) {
        return true;
      }
    }
    return false;
  }

  /** 补全协议头：反斜杠归一为斜杠、清洗叠加前缀、已有 http(s) 不重复加、纯 ip:port 才补 http:// */
  static normalize(input: string): string {
    let u: string = input.trim();
    if (u.length === 0) {
      return u;
    }
    // 1) 反斜杠一律归一为斜杠（粘贴或遥控输入常把 // 敲成 \\，是本次 2300003 的根因）
    u = u.replace(/\\/g, '/');
    // 2) 剥掉被错误叠加的协议前缀
    u = NetClient.peel(u);
    // 3) 协议头规范化：https:/host、https:host、HTTP://host 统一成 scheme://host
    const colon: number = u.indexOf(':');
    if (colon > 0) {
      const name: string = u.substring(0, colon).toLowerCase();
      if (NetClient.isKnownScheme(name)) {
        const after: string = u.substring(colon + 1);
        let rest: string = after;
        while (rest.startsWith('/')) {
          rest = rest.substring(1);
        }
        u = `${name}://${rest}`;
      }
    }
    // 4) 连续斜杠收敛（不影响 :// 本身），避免出现 host//path
    u = u.replace(/([^:])\/{2,}/g, '$1/');
    // 5) 仍无协议头才补 http://；协议相对地址 //host 补 http:
    if (/^[a-zA-Z][a-zA-Z0-9+.\-]*:\/\//.test(u)) {
      return u;
    }
    if (u.startsWith('//')) {
      return `http:${u}`;
    }
    return `http://${u}`;
  }

  /** 拆解地址：返回 scheme / host / port / path 四段（path 为空表示根目录） */
  static parseUrlInfo(input: string): NetUrlInfo {
    const info: NetUrlInfo = new NetUrlInfo();
    const u: string = NetClient.normalize(input);
    const idx: number = u.indexOf('://');
    if (idx < 0) {
      info.path = u;
      return info;
    }
    info.scheme = u.substring(0, idx).toLowerCase();
    const rest: string = u.substring(idx + 3);
    const slash: number = rest.indexOf('/');
    const authority: string = slash >= 0 ? rest.substring(0, slash) : rest;
    const rawPath: string = slash >= 0 ? rest.substring(slash) : '';
    // 去掉 userinfo，仅按最后一处 @ 切分
    const at: number = authority.lastIndexOf('@');
    const hostPort: string = at >= 0 ? authority.substring(at + 1) : authority;
    const portColon: number = hostPort.lastIndexOf(':');
    if (portColon > 0 && !hostPort.startsWith('[')) {
      info.host = hostPort.substring(0, portColon);
      info.port = hostPort.substring(portColon + 1);
    } else {
      info.host = hostPort;
    }
    info.path = rawPath === '/' ? '' : rawPath;
    return info;
  }

  static schemeOf(url: string): string {
    const idx: number = url.indexOf('://');
    return idx > 0 ? url.substring(0, idx).toLowerCase() : '';
  }

  static pureName(url: string): string {
    let u: string = url;
    const q: number = u.indexOf('?');
    if (q >= 0) {
      u = u.substring(0, q);
    }
    const h: number = u.indexOf('#');
    if (h >= 0) {
      u = u.substring(0, h);
    }
    while (u.endsWith('/') && u.length > 1) {
      u = u.substring(0, u.length - 1);
    }
    const idx: number = u.lastIndexOf('/');
    const name: string = idx >= 0 ? u.substring(idx + 1) : u;
    try {
      return decodeURIComponent(name);
    } catch (err) {
      return name;
    }
  }

  static isVideoName(name: string): boolean {
    const lower: string = name.toLowerCase();
    for (let i = 0; i < NetClient.VIDEO_EXT.length; i++) {
      if (lower.endsWith(NetClient.VIDEO_EXT[i])) {
        return true;
      }
    }
    return false;
  }

  /** 该地址能否直接丢给播放器：直链协议或常见视频后缀 */
  static isPlayable(url: string): boolean {
    const scheme: string = NetClient.schemeOf(url);
    if (scheme === 'rtsp' || scheme === 'rtmp' || scheme === 'rtmps' || scheme === 'udp' || scheme === 'mms') {
      return true;
    }
    return NetClient.isVideoName(NetClient.pureName(url));
  }

  /** 相对/绝对链接拼成完整地址，并归一化 ./ ../ */
  static resolve(baseUrl: string, href: string): string {
    const schemeIdx: number = baseUrl.indexOf('://');
    if (schemeIdx < 0) {
      return href;
    }
    if (/^[a-zA-Z][a-zA-Z0-9+.\-]*:\/\//.test(href)) {
      return href;
    }
    const scheme: string = baseUrl.substring(0, schemeIdx);
    const rest: string = baseUrl.substring(schemeIdx + 3);
    const slash: number = rest.indexOf('/');
    const host: string = slash >= 0 ? rest.substring(0, slash) : rest;
    const basePath: string = slash >= 0 ? rest.substring(slash) : '/';
    let full: string = '';
    if (href.startsWith('/')) {
      full = `${scheme}://${host}${href}`;
    } else {
      const dir: string = basePath.endsWith('/') ? basePath : basePath.substring(0, basePath.lastIndexOf('/') + 1);
      full = `${scheme}://${host}${dir}${href}`;
    }
    if (full.indexOf('/./') < 0 && full.indexOf('/../') < 0) {
      return full;
    }
    // 归一化路径中的 . / ..
    const head: number = full.indexOf('://') + 3;
    const headPart: string = full.substring(0, head);
    const pathPart: string = full.substring(head);
    const segs: string[] = pathPart.split('/');
    const out: string[] = [];
    for (let i = 0; i < segs.length; i++) {
      const s: string = segs[i];
      if (s === '.' || s.length === 0) {
        if (i === segs.length - 1) {
          out.push('');
        }
        continue;
      }
      if (s === '..') {
        if (out.length > 0) {
          out.pop();
        }
        continue;
      }
      out.push(s);
    }
    return `${headPart}/${out.join('/')}`;
  }

  /** 目录的上一级地址；已是根时返回空串 */
  static parentOf(url: string): string {
    const idx: number = url.indexOf('://');
    if (idx < 0) {
      return '';
    }
    let u: string = url;
    if (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    const schemeEnd: number = idx + 3;
    const slash: number = u.indexOf('/', schemeEnd);
    if (slash < 0 || slash <= schemeEnd) {
      return '';
    }
    const cut: number = u.lastIndexOf('/');
    if (cut <= schemeEnd) {
      return `${u.substring(0, schemeEnd)}/`;
    }
    return `${u.substring(0, cut + 1)}`;
  }

  /** 拉取目录/文件正文 */
  static async fetch(url: string, timeoutMs: number): Promise<NetResult> {
    const res: NetResult = new NetResult();
    const request: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        header: { 'Accept': '*/*' }
      };
      const resp: http.HttpResponse = await request.request(url, options);
      res.code = resp.responseCode;
      res.contentType = `${resp.header['content-type'] !== undefined ? resp.header['content-type'] : ''}`;
      if (typeof resp.result === 'string') {
        res.body = resp.result as string;
      }
      if (resp.responseCode >= 200 && resp.responseCode < 400) {
        res.ok = true;
      } else {
        res.message = `服务器返回 ${resp.responseCode}`;
      }
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      res.message = `连接失败（${e.code}）`;
      hilog.error(DOMAIN, TAG, 'fetch failed code=%{public}d', e.code);
    } finally {
      request.destroy();
    }
    return res;
  }

  /** 解析目录正文：优先 JSON（部分 NAS/自建服务），否则解析 HTML 的 <a href> */
  static parseListing(baseUrl: string, body: string): NetEntry[] {
    const trimmed: string = body.trim();
    if (trimmed.length === 0) {
      return [];
    }
    const first: string = trimmed.substring(0, 1);
    if (first === '[' || first === '{') {
      const asJson: NetEntry[] = NetClient.parseJson(trimmed, baseUrl);
      if (asJson.length > 0) {
        return NetClient.sortEntries(asJson);
      }
    }
    return NetClient.sortEntries(NetClient.parseHtml(baseUrl, body));
  }

  private static parseJson(text: string, baseUrl: string): NetEntry[] {
    const out: NetEntry[] = [];
    try {
      const data: ESObject = JSON.parse(text) as ESObject;
      let list: ESObject[] = [];
      if (Array.isArray(data)) {
        list = data as ESObject[];
      } else if (data !== null && data !== undefined) {
        const files: ESObject = (data as Record<string, ESObject>)['files'];
        const items: ESObject = (data as Record<string, ESObject>)['items'];
        const children: ESObject = (data as Record<string, ESObject>)['children'];
        if (files !== undefined && Array.isArray(files)) {
          list = files as ESObject[];
        } else if (items !== undefined && Array.isArray(items)) {
          list = items as ESObject[];
        } else if (children !== undefined && Array.isArray(children)) {
          list = children as ESObject[];
        }
      }
      for (let i = 0; i < list.length; i++) {
        const raw: Record<string, ESObject> = list[i] as Record<string, ESObject>;
        const name: string = NetClient.pickString(raw, ['name', 'title', 'filename', 'file_name', 'display_name']);
        const href: string = NetClient.pickString(raw, ['url', 'href', 'path', 'link']);
        if (name.length === 0 && href.length === 0) {
          continue;
        }
        const typeStr: string = NetClient.pickString(raw, ['type', 'kind', 'file_type']).toLowerCase();
        const dirFlag: ESObject = raw['isDir'] !== undefined ? raw['isDir'] : raw['is_dir'];
        const isDir: boolean = typeStr === 'dir' || typeStr === 'directory' || typeStr === 'folder' ||
          dirFlag === true;
        const sizeNum: ESObject = raw['size'] !== undefined ? raw['size'] :
          (raw['length'] !== undefined ? raw['length'] : raw['bytes']);
        let size: number = 0;
        if (typeof sizeNum === 'number') {
          size = sizeNum as number;
        } else if (typeof sizeNum === 'string') {
          size = Number.parseInt(sizeNum as string, 10);
          if (isNaN(size)) {
            size = 0;
          }
        }
        const url: string = (href.length > 0 && /^[a-zA-Z][a-zA-Z0-9+.\-]*:\/\//.test(href))
          ? href : NetClient.resolve(baseUrl, href.length > 0 ? href : name);
        const display: string = name.length > 0 ? name : NetClient.pureName(url);
        out.push(new NetEntry(display, url, isDir, size));
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'parseJson failed');
    }
    return out;
  }

  private static pickString(raw: Record<string, ESObject>, keys: string[]): string {
    for (let i = 0; i < keys.length; i++) {
      const v: ESObject = raw[keys[i]];
      if (typeof v === 'string') {
        return v as string;
      }
    }
    return '';
  }

  private static parseHtml(baseUrl: string, body: string): NetEntry[] {
    const out: NetEntry[] = [];
    const re: RegExp = /<a\s[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi;
    const seen: string[] = [];
    let m: RegExpExecArray | null = re.exec(body);
    while (m !== null) {
      const href: string = m[1];
      const label: string = m[2].replace(/<[^>]+>/g, '').trim();
      const lower: string = href.toLowerCase();
      const skip: boolean = href.length === 0 || href === '#' || lower.startsWith('javascript:') ||
        lower.startsWith('mailto:') || href.startsWith('?') || href === '/' || href === '../' ||
        lower.indexOf('c=n;o=d') >= 0 || lower.indexOf('c=m;o=a') >= 0 || lower.indexOf('c=s;o=a') >= 0 ||
        lower.indexOf('c=d;o=a') >= 0 || href.startsWith('/');
      if (!skip) {
        const url: string = NetClient.resolve(baseUrl, href);
        if (seen.indexOf(url) < 0) {
          seen.push(url);
          const isDir: boolean = href.endsWith('/');
          let name: string = label;
          if (name.length === 0 || name === href) {
            name = NetClient.pureName(url);
          }
          if (name.length > 0 && name !== '..') {
            out.push(new NetEntry(name, url, isDir, 0));
          }
        }
      }
      m = re.exec(body);
    }
    return out;
  }

  private static sortEntries(list: NetEntry[]): NetEntry[] {
    const dirs: NetEntry[] = list.filter((e: NetEntry) => e.isDir);
    const files: NetEntry[] = list.filter((e: NetEntry) => !e.isDir);
    const cmp = (a: NetEntry, b: NetEntry): number => a.name.localeCompare(b.name);
    return dirs.sort(cmp).concat(files.sort(cmp));
  }

  // ---------------- WebDAV ----------------

  /** Base64（UTF-8 之外的字符按 Latin-1 处理，够用于常见账号密码） */
  static basicAuth(user: string, pass: string): string {
    const raw: string = `${user}:${pass}`;
    const table: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let out: string = '';
    for (let i = 0; i < raw.length; i += 3) {
      const has2: boolean = i + 1 < raw.length;
      const has3: boolean = i + 2 < raw.length;
      const c1: number = raw.charCodeAt(i);
      const c2: number = has2 ? raw.charCodeAt(i + 1) : 0;
      const c3: number = has3 ? raw.charCodeAt(i + 2) : 0;
      const n: number = (c1 << 16) | (c2 << 8) | c3;
      out += table.charAt((n >> 18) & 63);
      out += table.charAt((n >> 12) & 63);
      out += has2 ? table.charAt((n >> 6) & 63) : '=';
      out += has3 ? table.charAt(n & 63) : '=';
    }
    return out;
  }

  /** 目录地址补尾部斜杠：先规范化，再把尾部多余斜杠收敛成一个，空 path 不产生 // */
  static davNormalize(input: string): string {
    const u: string = NetClient.normalize(input);
    if (u.length === 0) {
      return u;
    }
    const info: NetUrlInfo = NetClient.parseUrlInfo(u);
    if (info.host.length === 0) {
      // 只有 scheme（如 https://）时保持原样，交给调用方提示补全
      return u;
    }
    let base: string = u;
    while (base.length > 0 && base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return `${base}/`;
  }

  /** 把账号密码塞进 URL 的 userinfo，便于播放器直接带认证取流 */
  static withAuth(url: string, user: string, pass: string): string {
    if (user.length === 0) {
      return url;
    }
    const schemeIdx: number = url.indexOf('://');
    if (schemeIdx < 0) {
      return url;
    }
    const scheme: string = url.substring(0, schemeIdx);
    const rest: string = url.substring(schemeIdx + 3);
    const slash: number = rest.indexOf('/');
    const host: string = slash >= 0 ? rest.substring(0, slash) : rest;
    if (host.indexOf('@') >= 0) {
      return url;
    }
    const cred: string = `${encodeURIComponent(user)}:${encodeURIComponent(pass)}`;
    const path: string = slash >= 0 ? rest.substring(slash) : '';
    return `${scheme}://${cred}@${host}${path}`;
  }

  /** 去掉 URL 里的 userinfo（AVPlayer 无法用带凭据的 URL 取流，会报 5400102） */
  static stripAuth(url: string): string {
    const schemeIdx: number = url.indexOf('://');
    if (schemeIdx < 0) {
      return url;
    }
    const scheme: string = url.substring(0, schemeIdx);
    const rest: string = url.substring(schemeIdx + 3);
    const slash: number = rest.indexOf('/');
    const host: string = slash >= 0 ? rest.substring(0, slash) : rest;
    const at: number = host.lastIndexOf('@');
    if (at < 0) {
      return url;
    }
    const path: string = slash >= 0 ? rest.substring(slash) : '';
    return `${scheme}://${host.substring(at + 1)}${path}`;
  }

  /** URL 安全化：AVPlayer 拒绝含中文、空格等未编码字符的地址（同样会报 5400102） */
  static safeUrl(url: string): string {
    if (url.length === 0) {
      return url;
    }
    // 仅处理 URL 中出现未编码非 ASCII / 空格的情况，已有的 %XX 不会被二次编码
    if (/[^\x21-\x7E]/.test(url)) {
      try {
        return encodeURI(url);
      } catch (err) {
        return url;
      }
    }
    return url;
  }

  /** PROPFIND 请求体：默认精确取常用属性；allprop 用于部分服务端对具名 prop 返回空 response 的情况 */
  private static davBody(allprop: boolean): string {
    const head: string = '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:">';
    if (allprop) {
      return `${head}<d:allprop/></d:propfind>`;
    }
    return `${head}<d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/>` +
      `<d:getcontenttype/><d:getlastmodified/></d:prop></d:propfind>`;
  }

  /** 读响应头（键名大小写不敏感，值兼容 string / string[]） */
  private static headerOf(headers: Record<string, ESObject>, name: string): string {
    if (headers === undefined || headers === null) {
      return '';
    }
    const want: string = name.toLowerCase();
    const keys: string[] = Object.keys(headers);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i].toLowerCase() !== want) {
        continue;
      }
      const v: ESObject = headers[keys[i]];
      if (typeof v === 'string') {
        return v as string;
      }
      if (Array.isArray(v) && (v as string[]).length > 0) {
        return (v as string[])[0];
      }
    }
    return '';
  }

  /** 报文开头片段，用于空目录诊断 */
  private static xmlHead(xml: string): string {
    let s: string = xml;
    if (s.length > 0 && s.charCodeAt(0) === 0xFEFF) {
      s = s.substring(1);
    }
    s = s.replace(/[\r\n\t]+/g, ' ').trim();
    return s.length > 160 ? `${s.substring(0, 160)}…` : s;
  }

  /** 单次 PROPFIND（不跟随重定向，由 davList 负责跟随） */
  private static async davOnce(target: string, user: string, pass: string, timeoutMs: number,
    depth: string, allprop: boolean): Promise<NetResult> {
    const res: NetResult = new NetResult();
    res.url = target;
    const request: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Depth': depth,
        'Content-Type': 'application/xml; charset=utf-8',
        'Accept': '*/*',
        // 明确不要压缩：http 模块不会自动解压，压缩体会被当成乱码导致解析为空
        'Accept-Encoding': 'identity'
      };
      // 未填账号时不发 Authorization，避免空凭据被服务端直接 401
      if (user.length > 0) {
        header['Authorization'] = `Basic ${NetClient.basicAuth(user, pass)}`;
      }
      // RequestMethod 枚举未收录 PROPFIND，底层按字符串透传，故在此做类型断言
      const davMethod: http.RequestMethod = 'PROPFIND' as http.RequestMethod;
      const options: http.HttpRequestOptions = {
        method: davMethod,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        extraData: NetClient.davBody(allprop),
        header: header
      };
      const resp: http.HttpResponse = await request.request(target, options);
      res.code = resp.responseCode;
      if (resp.header !== undefined && resp.header !== null) {
        const hs: Record<string, ESObject> = resp.header as Record<string, ESObject>;
        res.contentType = NetClient.headerOf(hs, 'content-type');
        res.location = NetClient.headerOf(hs, 'location');
      }
      if (typeof resp.result === 'string') {
        res.body = resp.result as string;
      }
      if (res.body.length > 0 && res.body.charCodeAt(0) === 0xFEFF) {
        res.body = res.body.substring(1);
      }
      hilog.info(DOMAIN, TAG, 'PROPFIND %{public}s code=%{public}d type=%{public}s len=%{public}d',
        target, res.code, res.contentType, res.body.length);
      if (res.code === 301 || res.code === 302 || res.code === 303 || res.code === 307 || res.code === 308) {
        res.message = res.location.length > 0 ? `重定向 ${res.code} → ${res.location}` : `重定向 ${res.code} 但缺少 Location`;
      } else if (res.code === 207 || (res.code >= 200 && res.code < 300)) {
        res.ok = true;
      } else if (res.code === 401) {
        res.message = '认证失败（401），请检查账号密码';
      } else if (res.code === 403) {
        res.message = '无权限访问（403）';
      } else if (res.code === 404) {
        res.message = '路径不存在（404），请检查地址是否缺少 /dav、/remote.php/dav 等前缀';
      } else if (res.code === 405) {
        res.message = '服务器不支持 PROPFIND（405）';
      } else {
        res.message = `服务器返回 ${res.code}`;
      }
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      res.message = `连接失败（${e.code}）`;
      hilog.error(DOMAIN, TAG, 'davList failed code=%{public}d', e.code);
    } finally {
      request.destroy();
    }
    return res;
  }

  /**
   * WebDAV 列目录：PROPFIND + Depth:1 + Basic 认证。
   * 关键点：手动跟随 3xx（PROPFIND 属自定义方法，底层不保证自动重定向），并用绝对 URI 重算 Location。
   */
  static async davList(url: string, user: string, pass: string, timeoutMs: number,
    allprop: boolean = false): Promise<NetResult> {
    let target: string = NetClient.davNormalize(url);
    const trail: string[] = [target];
    let res: NetResult = new NetResult();
    for (let hop = 0; hop < 4; hop++) {
      res = await NetClient.davOnce(target, user, pass, timeoutMs, '1', allprop);
      if (res.location.length === 0 || res.ok) {
        break;
      }
      const next: string = NetClient.davNormalize(NetClient.resolve(target, res.location));
      if (next.length === 0 || next === target || trail.indexOf(next) >= 0) {
        break;
      }
      trail.push(next);
      target = next;
    }
    res.url = target;
    res.attempts = trail.join(' → ');
    if (res.body.length > 0) {
      res.detail = `HTTP ${res.code} · ${res.contentType.length > 0 ? res.contentType : '无 Content-Type'} · ` +
        `${res.body.length} 字节 · ${NetClient.xmlHead(res.body)}`;
    } else {
      res.detail = `HTTP ${res.code} · 响应体为空`;
    }
    if (trail.length > 1) {
      hilog.info(DOMAIN, TAG, 'davList trail=%{public}s', res.attempts);
    }
    return res;
  }

  /** 两个地址是否指向同一资源：忽略大小写、尾斜杠与百分号编码差异 */
  static sameUrl(a: string, b: string): boolean {
    const norm = (u: string): string => {
      let s: string = u.trim().toLowerCase();
      try {
        s = decodeURIComponent(s);
      } catch (err) {
        // 非法转义按原样比较
      }
      while (s.endsWith('/')) {
        s = s.substring(0, s.length - 1);
      }
      return s;
    };
    return norm(a) === norm(b);
  }

  /** 解析 WebDAV 的 multistatus 响应 */
  static parseDav(baseUrl: string, xml: string): NetEntry[] {
    const selfUrl: string = NetClient.davNormalize(baseUrl);
    const out: NetEntry[] = NetClient.parseDavBlocks(selfUrl, xml);
    if (out.length > 0) {
      NetClient.setDavStats(out.length, xml);
      return NetClient.sortEntries(out);
    }
    // 兜底：个别服务端返回的 response 块不规则（如 prop 用默认命名空间、缺闭合标签），
    // 按任意 <x:href> 宽松扫描，只要 href 存在就足以列目录
    const relaxed: NetEntry[] = [];
    const hrefRe: RegExp = /<[a-zA-Z0-9_.\-]*:?href[^>]*>([\s\S]*?)<\/[a-zA-Z0-9_.\-]*:?href>/gi;
    let m: RegExpExecArray | null = hrefRe.exec(xml);
    while (m !== null) {
      const rawHref: string = m[1].trim();
      if (rawHref.length > 0) {
        const url: string = /^[a-zA-Z][a-zA-Z0-9+.\-]*:\/\//.test(rawHref)
          ? rawHref : NetClient.resolve(selfUrl, rawHref);
        if (!NetClient.sameUrl(url, selfUrl)) {
          const isDir: boolean = rawHref.endsWith('/');
          let name: string = NetClient.pureName(url);
          if (name.length > 0 && name !== '..' && name !== '.' && name !== 'self') {
            relaxed.push(new NetEntry(name, isDir && !url.endsWith('/') ? `${url}/` : url, isDir, 0));
          }
        }
      }
      m = hrefRe.exec(xml);
    }
    return NetClient.sortEntries(relaxed);
  }

  /** 汇出解析统计与报文形态，供空目录诊断使用（207 但被全部过滤时可一眼看出原因） */
  private static setDavStats(count: number, xml: string): void {
    const parts: string[] = [`响应块 ${NetClient.davBlockCount} 条`];
    if (NetClient.davSelfCount > 0) {
      parts.push(`剔除自身 ${NetClient.davSelfCount} 条`);
    }
    if (NetClient.davSkipCount > 0) {
      parts.push(`丢弃无效 ${NetClient.davSkipCount} 条`);
    }
    parts.push(`解析出 ${count} 条`);
    let s: string = parts.join(' · ');
    if (xml.length === 0) {
      s = `${s} · 响应体为空`;
    } else if (xml.length > 1 && xml.charCodeAt(0) === 0x1F && xml.charCodeAt(1) === 0x8B) {
      s = `${s} · 响应疑似 gzip 压缩体（服务端未按 identity 返回）`;
    } else if (xml.indexOf('<') < 0) {
      s = `${s} · 响应不是 XML 报文`;
    }
    NetClient.davStats = s;
    hilog.info(DOMAIN, TAG, 'parseDav %{public}s', s);
  }

  /** 按 response 块解析 multistatus 主体 */
  private static parseDavBlocks(selfUrl: string, xml: string): NetEntry[] {
    const out: NetEntry[] = [];
    NetClient.davBlockCount = 0;
    NetClient.davSelfCount = 0;
    NetClient.davSkipCount = 0;
    const blocks: RegExp = /<[a-zA-Z0-9_.\-]*:?response[\s\S]*?<\/[a-zA-Z0-9_.\-]*:?response>/gi;
    let m: RegExpExecArray | null = blocks.exec(xml);
    while (m !== null) {
      const block: string = m[0];
      NetClient.davBlockCount++;
      const href: string = NetClient.davTag(block, 'href');
      if (href.length > 0) {
        const url: string = /^[a-zA-Z][a-zA-Z0-9+.\-]*:\/\//.test(href)
          ? href : NetClient.resolve(selfUrl, href);
        const isDir: boolean = /:collection/i.test(block) || href.endsWith('/');
        if (!NetClient.sameUrl(url, selfUrl)) {
          const display: string = NetClient.davTag(block, 'displayname');
          let name: string = display.length > 0 ? display : NetClient.pureName(url);
          if (name.length === 0 || name === '..') {
            name = NetClient.pureName(url);
          }
          if (name.length > 0 && !isSystemHiddenName(name)) {
            const sizeText: string = NetClient.davTag(block, 'getcontentlength');
            let size: number = 0;
            if (sizeText.length > 0) {
              const parsed: number = Number.parseInt(sizeText, 10);
              size = isNaN(parsed) ? 0 : parsed;
            }
            out.push(new NetEntry(name, isDir && !url.endsWith('/') ? `${url}/` : url, isDir, size));
          } else {
            NetClient.davSkipCount++;
          }
        } else {
          NetClient.davSelfCount++;
        }
      } else {
        NetClient.davSkipCount++;
      }
      m = blocks.exec(xml);
    }
    return out;
  }

  private static davTag(block: string, tag: string): string {
    // 前缀命名空间不限字符集：兼容 d: / D: / lp1: / ns0: / x1_ 等写法；自闭合空元素匹配不到闭合标签时返回空串
    const name: string = `[a-zA-Z0-9_.\\-]*:?${tag}`;
    const re: RegExp = new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)</${name}>`, 'i');
    const m: RegExpExecArray | null = re.exec(block);
    if (m === null) {
      return '';
    }
    let v: string = m[1].trim();
    if (v.indexOf('&amp;') >= 0) {
      v = v.replace(/&amp;/g, '&');
    }
    if (v.indexOf('&lt;') >= 0) {
      v = v.replace(/&lt;/g, '<').replace(/&gt;/g, '>');
    }
    return v;
  }
}
