import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'SubtitleFinder';
const DOMAIN: number = 0x0001;
const UA: string = 'PlayerArkTS v1.0';
const HTML_UA: string = 'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

/** 一条在线字幕候选 */
export class SubtitleItem {
  id: string = '';
  fileId: number = 0;
  title: string = '';
  lang: string = '';
  release: string = '';
  downloadCount: number = 0;
  url: string = '';
  isZip: boolean = false;
  /** 来源：assrt | cat | os */
  source: string = 'os';
  /** 详情页地址（部分源需要二次解析才能拿到下载直链） */
  detailUrl: string = '';
  /** 字幕格式，例如 srt / ass */
  format: string = '';

  label(): string {
    const lang: string = this.lang.length > 0 ? this.lang : '未知语言';
    const rel: string = this.release.length > 0 ? ` · ${this.release}` : '';
    const dl: string = this.downloadCount > 0 ? ` · ↓${this.downloadCount}` : '';
    const src: string = this.source === 'assrt' ? '射手' : (this.source === 'cat' ? 'Cat' : 'OS');
    return `[${src}] ${this.title} [${lang}]${rel}${dl}`;
  }
}

interface OsFile {
  file_id: number;
  file_name: string;
}

interface OsAttributes {
  language: string;
  release: string;
  download_count: number;
  url: string;
  files: OsFile[];
}

interface OsDatum {
  id: string;
  attributes: OsAttributes;
}

interface OsSearchResp {
  data: OsDatum[];
  total_count: number;
}

interface OsLinkResp {
  link: string;
  file_name: string;
  remaining: number;
}

/**
 * 在线字幕：搜索 + 下载 + 落地到沙箱。
 * 源一 OpenSubtitles REST v1（需免费 Api-Key）；源二"直链导入"（任意 http/https 的 srt/zip 地址）。
 */
export class SubtitleFinder {
  /** 从视频文件名推导搜索关键词：去扩展名、去方括号内容、去常见压制标记 */
  static keywordFromName(name: string): string {
    let s: string = name;
    const dot: number = s.lastIndexOf('.');
    if (dot > 0) {
      s = s.substring(0, dot);
    }
    s = s.replace(/\.[^.]+$/, '');
    s = s.replace(/\[[^\]]*\]/g, ' ');
    s = s.replace(/\([^)]*\)/g, ' ');
    s = s.replace(/2160p|1080p|720p|480p|WEB-?DL|BluRay|BRRip|HDRip|HDTV|x264|x265|H\.?264|H\.?265|HEVC|AAC|DTS|10bit|60fps/gi, ' ');
    s = s.replace(/[-_.]+/g, ' ');
    s = s.replace(/\s+/g, ' ').trim();
    return s;
  }

  // ===================== OpenSubtitles =====================
  static async searchOpen(query: string, lang: string, apiKey: string): Promise<SubtitleItem[]> {
    if (apiKey.trim().length === 0) {
      throw new Error('未配置 OpenSubtitles Api-Key，请到设置里填写');
    }
    const url: string =
      `https://api.opensubtitles.com/api/v1/subtitles?query=${encodeURIComponent(query)}&languages=${encodeURIComponent(lang)}&order_by=download_count&order_direction=desc`;
    const body: string = await SubtitleFinder.httpText(url, apiKey);
    const resp: OsSearchResp = JSON.parse(body) as OsSearchResp;
    const list: SubtitleItem[] = [];
    const data: OsDatum[] = resp.data !== undefined && resp.data !== null ? resp.data : [];
    for (let i = 0; i < data.length; i++) {
      const d: OsDatum = data[i];
      const a: OsAttributes = d.attributes;
      if (a === undefined || a === null) {
        continue;
      }
      const files: OsFile[] = a.files !== undefined && a.files !== null ? a.files : [];
      if (files.length === 0) {
        continue;
      }
      const it: SubtitleItem = new SubtitleItem();
      it.id = d.id;
      it.fileId = files[0].file_id;
      it.title = files[0].file_name !== undefined ? files[0].file_name : `字幕 ${d.id}`;
      it.lang = a.language !== undefined ? a.language : '';
      it.release = a.release !== undefined ? a.release : '';
      it.downloadCount = a.download_count !== undefined ? a.download_count : 0;
      it.url = a.url !== undefined ? a.url : '';
      it.isZip = it.title.toLowerCase().endsWith('.zip');
      list.push(it);
    }
    return list;
  }

  /** 用 file_id 换取一次性下载直链（OpenSubtitles 有每日配额） */
  static async resolveDownloadLink(fileId: number, apiKey: string): Promise<string> {
    const url: string = 'https://api.opensubtitles.com/api/v1/download';
    const body: string = JSON.stringify({ file_id: fileId, sub_format: 'srt' });
    const respText: string = await SubtitleFinder.httpPostJson(url, body, apiKey);
    const r: OsLinkResp = JSON.parse(respText) as OsLinkResp;
    if (r.link === undefined || r.link.length === 0) {
      throw new Error('该字幕暂时无法获取下载链接（可能已达当日配额）');
    }
    return r.link;
  }

  // ===================== 免 Key 源一：射手网（伪）assrt.net =====================
  /** 中文资源覆盖最好，站点免费无需注册；返回结果直接带 zip/srt 下载直链 */
  static async searchAssrt(query: string): Promise<SubtitleItem[]> {
    const url: string = `https://assrt.net/sub/?searchword=${encodeURIComponent(query)}`;
    const html: string = await SubtitleFinder.httpTextPlain(url, 'https://assrt.net/');
    const list: SubtitleItem[] = [];
    const re: RegExp = /class="introtitle"[^>]*href="(\/xml\/sub\/\d+\/\d+\.xml)"[^>]*>([\s\S]*?)<\/a>/g;
    let m: RegExpExecArray | null = re.exec(html);
    while (m !== null) {
      const detail: string = `https://assrt.net${m[1]}`;
      const title: string = SubtitleFinder.stripTags(m[2]).trim();
      const tail: string = html.substring(m.index, Math.min(html.length, m.index + 3000));
      const fmtMatch: RegExpMatchArray | null = tail.match(/格式：\s*([^<]{1,40})/);
      const langMatch: RegExpMatchArray | null = tail.match(/语言：([^<]{1,60})/);
      const dlMatch: RegExpMatchArray | null = tail.match(/下载次数：(\d+)次/);
      const zipMatch: RegExpMatchArray | null = tail.match(/'((\/download\/[^']+))'/);
      const it: SubtitleItem = new SubtitleItem();
      it.id = m[1];
      it.source = 'assrt';
      it.detailUrl = detail;
      it.title = title.length > 0 ? title : '射手字幕';
      it.format = fmtMatch !== null ? fmtMatch[1].trim() : '';
      it.lang = langMatch !== null ? langMatch[1].replace(/&nbsp;/g, ' ').trim() : '';
      it.downloadCount = dlMatch !== null ? Number(dlMatch[1]) : 0;
      if (zipMatch !== null) {
        it.url = `https://assrt.net${zipMatch[1]}`;
        it.isZip = zipMatch[1].toLowerCase().endsWith('.zip');
      }
      list.push(it);
      if (list.length >= 30) {
        break;
      }
      m = re.exec(html);
    }
    return list;
  }

  /** 射手详情页兜底：从详情页解析下载直链（搜索页没有直链时使用） */
  static async resolveAssrtLink(detailUrl: string): Promise<string> {
    const html: string = await SubtitleFinder.httpTextPlain(detailUrl, 'https://assrt.net/');
    const m: RegExpMatchArray | null = html.match(/id="btn_download"[^>]*href="([^"]+)"/);
    if (m === null || m[1].length === 0) {
      throw new Error('该条目未提供可下载文件');
    }
    return m[1].startsWith('http') ? m[1] : `https://assrt.net${m[1]}`;
  }

  // ===================== 免 Key 源二：SubtitleCat =====================
  /** 聚合站，多语种 srt 直链，无需 Key；中文资源较少，作为备选 */
  static async searchCat(query: string): Promise<SubtitleItem[]> {
    const url: string = `https://subtitlecat.com/index.php?search=${encodeURIComponent(query)}`;
    const html: string = await SubtitleFinder.httpTextPlain(url, 'https://subtitlecat.com/');
    const list: SubtitleItem[] = [];
    const re: RegExp = /href="(subs\/\d+\/[^"]+\.html)"/g;
    let m: RegExpExecArray | null = re.exec(html);
    while (m !== null) {
      const path: string = m[1];
      const seg: string = path.substring(path.lastIndexOf('/') + 1).replace(/\.html$/, '');
      const it: SubtitleItem = new SubtitleItem();
      it.id = path;
      it.source = 'cat';
      it.detailUrl = `https://subtitlecat.com/${path}`;
      it.title = decodeURIComponent(seg);
      it.lang = '多语种';
      it.format = 'srt';
      list.push(it);
      if (list.length >= 25) {
        break;
      }
      m = re.exec(html);
    }
    return list;
  }

  /** 从 Cat 详情页挑一个中文 srt 直链，没有中文则退英文 */
  static async resolveCatLink(detailUrl: string): Promise<string> {
    const html: string = await SubtitleFinder.httpTextPlain(detailUrl, 'https://subtitlecat.com/');
    const re: RegExp = /href="(\/subs\/\d+\/[^"]+?-([a-zA-Z][a-zA-Z0-9-]{0,6}))\.srt"/g;
    let zh: string = '';
    let other: string = '';
    let m: RegExpExecArray | null = re.exec(html);
    while (m !== null) {
      const code: string = m[2].toLowerCase();
      if (zh.length === 0 && (code === 'zh' || code === 'zh-cn' || code === 'zh-tw' || code === 'chs' || code === 'cht' || code === 'chi')) {
        zh = m[1];
      }
      if (other.length === 0 && code === 'en') {
        other = m[1];
      }
      m = re.exec(html);
    }
    const pick: string = zh.length > 0 ? zh : other;
    if (pick.length === 0) {
      throw new Error('该条目没有可直接下载的 srt');
    }
    return `https://subtitlecat.com${pick}.srt`;
  }

  /** 统一免 Key 搜索：射手优先，结果过少时补充 SubtitleCat */
  static async searchFree(query: string): Promise<SubtitleItem[]> {
    let all: SubtitleItem[] = [];
    let errMsg: string = '';
    try {
      const a: SubtitleItem[] = await SubtitleFinder.searchAssrt(query);
      all = all.concat(a);
    } catch (err) {
      errMsg = (err as Error).message;
    }
    if (all.length < 8) {
      try {
        const c: SubtitleItem[] = await SubtitleFinder.searchCat(query);
        all = all.concat(c);
      } catch (err) {
        errMsg = (err as Error).message;
      }
    }
    if (all.length === 0) {
      throw new Error(errMsg.length > 0 ? `免 Key 字幕站不可用：${errMsg}` : '免 Key 字幕站没有匹配结果');
    }
    return all;
  }

  /** 把候选解析成可直接下载的直链 */
  static async resolveUrl(item: SubtitleItem): Promise<string> {
    if (item.source === 'assrt') {
      if (item.url.length > 0) {
        return item.url;
      }
      return SubtitleFinder.resolveAssrtLink(item.detailUrl);
    }
    if (item.source === 'cat') {
      return SubtitleFinder.resolveCatLink(item.detailUrl);
    }
    if (item.fileId > 0) {
      throw new Error('OpenSubtitles 源需要 Api-Key，请到设置中配置');
    }
    return item.url;
  }

  /** GET 纯文本（网页解析用），带 Referer 规避异地盗链拦截 */
  static async httpTextPlain(url: string, referer: string): Promise<string> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': HTML_UA,
          'Accept': 'text/html,application/xhtml+xml,*/*',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
          'Referer': referer
        },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 20000
      });
      if (resp.responseCode !== 200) {
        throw new Error(`站点返回 ${resp.responseCode}`);
      }
      return resp.result as string;
    } finally {
      req.destroy();
    }
  }

  /** 去 HTML 标签与实体，得到纯文本 */
  private static stripTags(s: string): string {
    let out: string = s.replace(/<[^>]*>/g, '');
    out = out.replace(/&nbsp;/g, ' ');
    out = out.replace(/&amp;/g, '&');
    out = out.replace(/&lt;/g, '<');
    out = out.replace(/&gt;/g, '>');
    out = out.replace(/&#x2913;/g, '');
    out = out.replace(/\s+/g, ' ');
    return out;
  }

  // ===================== 通用下载落地 =====================
  /**
   * 下载字幕并落地为沙箱内的 .srt 文件，返回绝对路径。
   * 支持 srt / vtt(转粗处理) / zip(解压取第一个 srt)。
   */
  static async downloadToSandbox(ctx: common.UIAbilityContext, url: string, displayName: string): Promise<string> {
    const dir: string = `${ctx.filesDir}/subtitles`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir);
    }
    const safe: string = SubtitleFinder.safeName(displayName);
    const rawPath: string = `${dir}/${safe}_raw`;
    await SubtitleFinder.httpToFile(url, rawPath);

    let srcPath: string = rawPath;
    const head: string = SubtitleFinder.peekText(rawPath, 8).toLowerCase();
    if (head.startsWith('pk')) {
      const outDir: string = `${dir}/${safe}_unzip`;
      if (!fs.accessSync(outDir)) {
        fs.mkdirSync(outDir);
      }
      await zlib.decompressFile(rawPath, outDir);
      const picked: string = SubtitleFinder.pickSubtitleFile(outDir);
      if (picked.length === 0) {
        throw new Error('压缩包里没有找到 .srt 字幕');
      }
      srcPath = picked;
    }

    const finalPath: string = `${dir}/${safe}.srt`;
    SubtitleFinder.normalizeToUtf8Srt(srcPath, finalPath);
    return finalPath;
  }

  /** 把二进制 buffer 直接写成字幕文件（例如从网络源拿到后另存） */
  static async saveBuffer(ctx: common.UIAbilityContext, buf: ArrayBuffer, displayName: string): Promise<string> {
    const dir: string = `${ctx.filesDir}/subtitles`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir);
    }
    const finalPath: string = `${dir}/${SubtitleFinder.safeName(displayName)}.srt`;
    const f: fs.File = fs.openSync(finalPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(f.fd, buf);
    fs.closeSync(f);
    return finalPath;
  }

  // ===================== 内部工具 =====================
  private static async httpText(url: string, apiKey: string): Promise<string> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'Api-Key': apiKey,
          'User-Agent': UA,
          'Accept': 'application/json'
        },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 20000
      });
      if (resp.responseCode !== 200) {
        if (resp.responseCode === 401) {
          throw new Error('Api-Key 无效（401）');
        }
        if (resp.responseCode === 429) {
          throw new Error('请求过于频繁或配额用尽（429）');
        }
        throw new Error(`字幕服务返回 ${resp.responseCode}`);
      }
      return resp.result as string;
    } finally {
      req.destroy();
    }
  }

  private static async httpPostJson(url: string, body: string, apiKey: string): Promise<string> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Api-Key': apiKey,
          'User-Agent': UA,
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        },
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 20000
      });
      if (resp.responseCode !== 200) {
        throw new Error(`获取下载链接失败（${resp.responseCode}）`);
      }
      return resp.result as string;
    } finally {
      req.destroy();
    }
  }

  /** 二进制下载到文件 */
  static async httpToFile(url: string, path: string): Promise<void> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': UA },
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 60000
      });
      if (resp.responseCode !== 200) {
        throw new Error(`下载失败（${resp.responseCode}）`);
      }
      const buf: ArrayBuffer = resp.result as ArrayBuffer;
      const f: fs.File = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, buf);
      fs.closeSync(f);
    } finally {
      req.destroy();
    }
  }

  private static safeName(s: string): string {
    let out: string = '';
    for (let i = 0; i < s.length && i < 60; i++) {
      const c: string = s.charAt(i);
      if (/[\\/:*?"<>|\s]/.test(c)) {
        out += '_';
      } else {
        out += c;
      }
    }
    return out.length > 0 ? out : `sub_${Date.now()}`;
  }

  /** 读文件头部若干字节并转文本，用于判断 zip 魔数 */
  private static peekText(path: string, n: number): string {
    try {
      const f: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const buf: ArrayBuffer = new ArrayBuffer(n);
      fs.readSync(f.fd, buf);
      fs.closeSync(f);
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
    } catch (err) {
      return '';
    }
  }

  /** 解压目录里挑一个字幕文件（优先 srt，其次 ass/vtt 提示） */
  private static pickSubtitleFile(dir: string): string {
    try {
      const names: string[] = fs.listFileSync(dir, { recursion: true });
      let firstSrt: string = '';
      let zhSrt: string = '';
      let fallback: string = '';
      for (let i = 0; i < names.length; i++) {
        const full: string = `${dir}/${names[i]}`;
        const low: string = names[i].toLowerCase();
        if (low.endsWith('.srt')) {
          if (firstSrt.length === 0) {
            firstSrt = full;
          }
          // 压缩包里常同时带 chs/cht/eng 多版，优先简体，其次繁体
          if (zhSrt.length === 0 && (low.indexOf('.chs') >= 0 || low.indexOf('zh-cn') >= 0 || low.indexOf('.zh') >= 0 || low.indexOf('simp') >= 0)) {
            zhSrt = full;
          }
        }
        if (fallback.length === 0 && (low.endsWith('.ass') || low.endsWith('.ssa') || low.endsWith('.vtt'))) {
          fallback = full;
        }
      }
      if (zhSrt.length > 0) {
        return zhSrt;
      }
      if (firstSrt.length > 0) {
        return firstSrt;
      }
      return fallback;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'listFile failed');
      return '';
    }
  }

  /**
   * 统一下载结果：优先 UTF-8，发现乱码再按 GB18030 解码；VTT/ASS 做简单规范化后另存为 .srt
   */
  private static normalizeToUtf8Srt(srcPath: string, dstPath: string): void {
    const bytes: ArrayBuffer = SubtitleFinder.readAll(srcPath);
    const u8: Uint8Array = new Uint8Array(bytes);
    let text: string = '';
    try {
      const dec: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: false, ignoreBOM: true });
      text = dec.decodeToString(u8);
    } catch (err) {
      text = '';
    }
    const bad: number = SubtitleFinder.countBad(text);
    if (bad > 3) {
      try {
        const dec2: util.TextDecoder = util.TextDecoder.create('gb18030', { fatal: false, ignoreBOM: true });
        const t2: string = dec2.decodeToString(u8);
        if (t2.length > 0 && SubtitleFinder.countBad(t2) < bad) {
          text = t2;
        }
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'gb18030 decode unavailable');
      }
    }
    text = SubtitleFinder.toSrt(text);
    const f: fs.File = fs.openSync(dstPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(f.fd, text);
    fs.closeSync(f);
  }

  private static countBad(s: string): number {
    let n: number = 0;
    for (let i = 0; i < s.length; i++) {
      if (s.charAt(i) === '\uFFFD') {
        n++;
      }
    }
    return n;
  }

  /** VTT 时间轴写法与 SRT 兼容（(,)→(.) 与去 WEBVTT 头），ASS 抽不了样式只保留纯文本时间轴 */
  private static toSrt(text: string): string {
    let t: string = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    if (t.startsWith('WEBVTT')) {
      t = t.substring(t.indexOf('\n') + 1);
      t = t.replace(/(\d{2}:\d{2}:\d{2})\.(\d{3})/g, '$1,$2');
      t = t.trim();
    }
    return t;
  }

  private static readAll(path: string): ArrayBuffer {
    const st: fs.Stat = fs.statSync(path);
    const buf: ArrayBuffer = new ArrayBuffer(st.size);
    const f: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    fs.readSync(f.fd, buf);
    fs.closeSync(f);
    return buf;
  }
}
