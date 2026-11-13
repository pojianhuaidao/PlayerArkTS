import { util } from '@kit.ArkTS';

/**
 * 纯 ArkTS FTP 客户端（RFC 959 + RFC 3659 扩展）用到的公共类型与解析工具。
 *
 * 设计约定：
 *  - 地址统一用 ftp://host:port/path 形式，凭据不入 URL（与 SMB 一致，
 *    账号密码由 FtpBrowser 按 host:port 单独保存），避免 AVPlayer 遇到 userinfo 报 5400102；
 *  - 目录列表三种来源：MLSD（结构化，优先）、LIST（Unix/DOS 两种文本格式）、NLST（只有名字）；
 *  - 列表字节流先按 UTF-8 严格解码，出现非法字节（替换符）时回退 GB18030，
 *    覆盖国产 NAS/老服务端不发 UTF8 的情况。
 */
export class FtpException extends Error {
  /** FTP 回复码（554/550…），0 表示本地网络/协议错误 */
  code: number;

  constructor(message: string, code: number) {
    super(message);
    this.code = code;
  }
}

/** 一条目录项 */
export class FtpEntry {
  name: string;
  isDir: boolean;
  /** 字节数，未知为 0 */
  size: number;
  /** 修改时间（Unix 毫秒），未知为 0 */
  modifyMs: number;

  constructor(name: string, isDir: boolean, size: number, modifyMs: number) {
    this.name = name;
    this.isDir = isDir;
    this.size = size;
    this.modifyMs = modifyMs;
  }
}

/** ftp:// 地址拆解结果（不含凭据） */
export class FtpTarget {
  host: string;
  port: number;
  path: string;
  /** 主动模式/PASV 走不通时回退用的原始 URL */
  user: string;
  pass: string;

  constructor(host: string, port: number, path: string, user: string, pass: string) {
    this.host = host;
    this.port = port;
    this.path = path;
    this.user = user;
    this.pass = pass;
  }

  /** 会话缓存键：同一主机+账号共用一个控制连接 */
  key(): string {
    return `${this.host}:${this.port}:${this.user}`;
  }

  /** 文件定位键：同一路径复用同一个读流 */
  fileKey(): string {
    return `${this.host}:${this.port}:${this.path}`;
  }
}

/** ftp:// 地址的拼装与拆解 */
export class FtpUrl {
  static readonly DEFAULT_PORT: number = 21;

  /** 补协议头、补默认端口、规范化路径分隔符 */
  static normalize(input: string): string {
    let text: string = input.trim();
    if (text.length === 0) {
      return '';
    }
    if (/^ftps?:\/\//i.test(text)) {
      text = text.replace(/^ftps:\/\//i, 'ftp://');
    } else if (!/^[a-zA-Z][a-zA-Z0-9+.\-]*:\/\//.test(text)) {
      text = `ftp://${text}`;
    }
    // 去掉协议头之后的 userinfo（账号密码走 FtpBrowser 单独保存）
    const head: string = text.substring(6);
    const slash: number = head.indexOf('/');
    const hostPart: string = slash >= 0 ? head.substring(0, slash) : head;
    const rest: string = slash >= 0 ? head.substring(slash) : '/';
    const cleanHost: string = hostPart.indexOf('@') >= 0 ? hostPart.substring(hostPart.lastIndexOf('@') + 1) : hostPart;
    let path: string = rest.replace(/\\/g, '/');
    if (path.length === 0 || path.charAt(0) !== '/') {
      path = `/${path}`;
    }
    return `ftp://${cleanHost}${path}`;
  }

  static hostPort(url: string): string {
    const t: FtpTarget | undefined = FtpUrl.parse(url);
    return t === undefined ? '' : `${t.host}:${t.port}`;
  }

  /** 拆解 host/port/path；凭据由调用方补齐 */
  static parse(url: string): FtpTarget | undefined {
    const norm: string = FtpUrl.normalize(url);
    if (norm.length <= 6) {
      return undefined;
    }
    const head: string = norm.substring(6);
    const slash: number = head.indexOf('/');
    const hostPart: string = slash >= 0 ? head.substring(0, slash) : head;
    let path: string = slash >= 0 ? head.substring(slash) : '/';
    if (hostPart.length === 0) {
      return undefined;
    }
    let host: string = hostPart;
    let port: number = FtpUrl.DEFAULT_PORT;
    const colon: number = hostPart.lastIndexOf(':');
    if (colon > 0) {
      const portText: string = hostPart.substring(colon + 1);
      const parsed: number = Number.parseInt(portText, 10);
      if (!Number.isNaN(parsed) && parsed > 0 && parsed < 65536) {
        port = parsed;
        host = hostPart.substring(0, colon);
      }
    }
    path = decodeURIComponent(path);
    return new FtpTarget(host, port, path, '', '');
  }

  /** 校验地址是否可用，返回错误说明（空串表示通过） */
  static checkUrl(url: string): string {
    const t: FtpTarget | undefined = FtpUrl.parse(url);
    if (t === undefined || t.host.length === 0) {
      return 'FTP 地址不完整，请填 ftp://192.168.1.10:21/ 形式';
    }
    if (t.host.indexOf(' ') >= 0) {
      return 'FTP 主机名不能带空格';
    }
    return '';
  }

  /** 名称：路径最后一段，根目录取主机名 */
  static titleOf(url: string): string {
    const t: FtpTarget | undefined = FtpUrl.parse(url);
    if (t === undefined) {
      return url;
    }
    const segs: string[] = t.path.split('/').filter((s: string) => s.length > 0);
    if (segs.length === 0) {
      return t.host;
    }
    return segs[segs.length - 1];
  }

  /** 服务器展示名：host:port */
  static serverLabel(url: string): string {
    const t: FtpTarget | undefined = FtpUrl.parse(url);
    if (t === undefined) {
      return url;
    }
    return t.port === FtpUrl.DEFAULT_PORT ? t.host : `${t.host}:${t.port}`;
  }

  /** 目录路径（以 / 结尾） */
  static dirPath(url: string): string {
    const t: FtpTarget | undefined = FtpUrl.parse(url);
    if (t === undefined) {
      return '/';
    }
    let p: string = t.path;
    if (p.length === 0) {
      p = '/';
    }
    if (p.charAt(p.length - 1) !== '/') {
      p = `${p}/`;
    }
    return p;
  }

  /** 子项地址（目录自动补尾斜杠） */
  static childUrl(url: string, name: string, isDir: boolean): string {
    const t: FtpTarget | undefined = FtpUrl.parse(url);
    if (t === undefined) {
      return url;
    }
    const base: string = `ftp://${t.port === FtpUrl.DEFAULT_PORT ? t.host : `${t.host}:${t.port}`}`;
    let p: string = FtpUrl.dirPath(url);
    p = `${p}${encodeURIComponent(name)}`;
    if (isDir) {
      p = `${p}/`;
    }
    return `${base}${p}`;
  }

  /** 上级目录地址；已在根时返回空串 */
  static parentOf(url: string): string {
    const t: FtpTarget | undefined = FtpUrl.parse(url);
    if (t === undefined) {
      return '';
    }
    let p: string = FtpUrl.dirPath(url);
    if (p === '/') {
      return '';
    }
    p = p.substring(0, p.length - 1);
    const cut: number = p.lastIndexOf('/');
    if (cut <= 0) {
      const base: string = `ftp://${t.port === FtpUrl.DEFAULT_PORT ? t.host : `${t.host}:${t.port}`}`;
      return `${base}/`;
    }
    const base: string = `ftp://${t.port === FtpUrl.DEFAULT_PORT ? t.host : `${t.host}:${t.port}`}`;
    return `${base}${p.substring(0, cut + 1)}`;
  }
}

/** 列表解析：MLSD / LIST(Unix,DOS) / NLST */
export class FtpListing {
  /**
   * 字节转文本：先 UTF-8 严格解码，失败或含替换符则按 GB18030。
   * 返回文本与是否走了回退（供诊断显示）。
   */
  static decode(bytes: Uint8Array, prefer: string): string {
    if (bytes.length === 0) {
      return '';
    }
    const order: string[] = prefer === 'gb18030' ? ['gb18030', 'utf-8'] : ['utf-8', 'gb18030'];
    for (let i = 0; i < order.length; i++) {
      const text: string = FtpListing.tryDecode(bytes, order[i]);
      if (text.length > 0 || bytes.length === 0) {
        if (text.indexOf('\uFFFD') < 0) {
          return text;
        }
      }
    }
    return FtpListing.tryDecode(bytes, 'gb18030');
  }

  private static tryDecode(bytes: Uint8Array, charset: string): string {
    try {
      const decoder: util.TextDecoder = util.TextDecoder.create(charset, { fatal: true, ignoreBOM: true });
      return decoder.decodeToString(bytes);
    } catch (err) {
      return '';
    }
  }

  /** MLSD：`type=file;size=1234;modify=20240101120000;UNIX.mode=0644; name.mp4` */
  static parseMlsd(text: string): FtpEntry[] {
    const out: FtpEntry[] = [];
    const lines: string[] = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const sp: number = line.indexOf(' ');
      if (sp <= 0) {
        continue;
      }
      const facts: string = line.substring(0, sp);
      const name: string = line.substring(sp + 1).trim();
      if (name.length === 0 || name === '.' || name === '..') {
        continue;
      }
      let type: string = '';
      let size: number = 0;
      let modifyMs: number = 0;
      const pairs: string[] = facts.split(';');
      for (let j = 0; j < pairs.length; j++) {
        const eq: number = pairs[j].indexOf('=');
        if (eq <= 0) {
          continue;
        }
        const k: string = pairs[j].substring(0, eq).toLowerCase();
        const v: string = pairs[j].substring(eq + 1);
        if (k === 'type') {
          type = v.toLowerCase();
        } else if (k === 'size') {
          const n: number = Number.parseInt(v, 10);
          size = Number.isNaN(n) ? 0 : n;
        } else if (k === 'modify') {
          modifyMs = FtpListing.mlsdTime(v);
        }
      }
      if (type === 'cdir' || type === 'pdir') {
        continue;
      }
      const isDir: boolean = type === 'dir' || type === 'os.dir';
      out.push(new FtpEntry(name, isDir, size, modifyMs));
    }
    return out;
  }

  /** modify=YYYYMMDDHHmmss[.sss] */
  private static mlsdTime(v: string): number {
    if (v.length < 14) {
      return 0;
    }
    const y: number = Number.parseInt(v.substring(0, 4), 10);
    const mo: number = Number.parseInt(v.substring(4, 6), 10) - 1;
    const d: number = Number.parseInt(v.substring(6, 8), 10);
    const h: number = Number.parseInt(v.substring(8, 10), 10);
    const mi: number = Number.parseInt(v.substring(10, 12), 10);
    const s: number = Number.parseInt(v.substring(12, 14), 10);
    const dt: Date = new Date(y, mo, d, h, mi, s);
    return dt.getTime();
  }

  /** LIST：同一份结果里可能混 Unix 与 DOS 行，这里逐行判定 */
  static parseList(text: string): FtpEntry[] {
    const out: FtpEntry[] = [];
    const lines: string[] = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      if (line.trim().length === 0) {
        continue;
      }
      if (/^total\s+\d+/i.test(line.trim())) {
        continue;
      }
      const unix: FtpEntry | undefined = FtpListing.parseUnix(line);
      if (unix !== undefined) {
        out.push(unix);
        continue;
      }
      const dos: FtpEntry | undefined = FtpListing.parseDos(line);
      if (dos !== undefined) {
        out.push(dos);
        continue;
      }
      // 兜底：只取最后一个字段当名字（部分服务端自定义格式）
      const segs: string[] = line.trim().split(/\s+/);
      const tail: string = segs[segs.length - 1];
      if (tail.length > 0 && tail !== '.' && tail !== '..' && tail !== './' && tail !== '../') {
        out.push(new FtpEntry(tail.replace(/\/$/, ''), tail.endsWith('/'), 0, 0));
      }
    }
    return out;
  }

  /** -rw-r--r-- 1 owner group 4096 Jan 01 12:00 name */
  private static parseUnix(line: string): FtpEntry | undefined {
    const m: RegExpMatchArray | null =
      line.match(/^([\-dlbcpsD])([rwxsStT\-]{9})\s+\d*\s*\S*\s+\S*\s*\S*\s+(\d+)\s+([A-Za-z]{3}\s+\d{1,2}\s+[\d:]{4,5}|\d{4}-\d{2}-\d{2}\s+[\d:]{5})\s+(.+)$/);
    if (m === null) {
      return undefined;
    }
    const kind: string = m[1];
    const sizeText: string = m[3];
    const timeText: string = m[4];
    let name: string = m[5];
    // 符号链接：`name -> /target`，只取箭头前的部分
    const arrow: number = name.indexOf(' -> ');
    if (arrow > 0) {
      name = name.substring(0, arrow);
    }
    const isDir: boolean = kind === 'd' || kind === 'D' || name.endsWith('/');
    const clean: string = name.endsWith('/') ? name.substring(0, name.length - 1) : name;
    if (clean.length === 0 || clean === '.' || clean === '..') {
      return undefined;
    }
    const size: number = Number.parseInt(sizeText, 10);
    return new FtpEntry(clean, isDir, Number.isNaN(size) ? 0 : size, FtpListing.textTime(timeText));
  }

  /** 01-02-24  03:04PM       <DIR>          name */
  private static parseDos(line: string): FtpEntry | undefined {
    const m: RegExpMatchArray | null =
      line.match(/^(\d{2}-\d{2}-\d{2,4})\s+(\d{1,2}:\d{2}\s*[APap][Mm])\s+(<DIR>|\d+)\s+(.+)$/);
    if (m === null) {
      return undefined;
    }
    const sizeText: string = m[3];
    const name: string = m[4].trim();
    if (name.length === 0 || name === '.' || name === '..') {
      return undefined;
    }
    const isDir: boolean = sizeText.toUpperCase() === '<DIR>';
    const size: number = isDir ? 0 : Number.parseInt(sizeText, 10);
    return new FtpEntry(name, isDir, Number.isNaN(size) ? 0 : size, FtpListing.dosTime(m[1], m[2]));
  }

  /** NLST：只有文件名，目录不带标记 */
  static parseNlst(text: string): FtpEntry[] {
    const out: FtpEntry[] = [];
    const lines: string[] = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const raw: string = lines[i].trim();
      if (raw.length === 0 || raw === '.' || raw === '..') {
        continue;
      }
      // 有的服务端回完整路径，只保留最后一段
      const segs: string[] = raw.split('/').filter((s: string) => s.length > 0);
      const name: string = segs.length > 0 ? segs[segs.length - 1] : raw;
      out.push(new FtpEntry(name, raw.endsWith('/'), 0, 0));
    }
    return out;
  }

  /** DOS 时间 `01-02-24` + `03:04PM`：两位年份按 2000 后处理 */
  private static dosTime(dateText: string, timeText: string): number {
    const dp: string[] = dateText.split('-');
    if (dp.length !== 3) {
      return 0;
    }
    let year: number = Number.parseInt(dp[2], 10);
    if (!Number.isNaN(year) && year < 100) {
      year += 2000;
    }
    const month: number = Number.parseInt(dp[0], 10) - 1;
    const day: number = Number.parseInt(dp[1], 10);
    const tp: string = timeText.replace(/\s+/g, '').toUpperCase();
    const isPm: boolean = tp.indexOf('PM') > 0;
    const hm: string[] = tp.replace(/[AP]M/, '').split(':');
    let hour: number = Number.parseInt(hm[0], 10);
    const minute: number = hm.length > 1 ? Number.parseInt(hm[1], 10) : 0;
    if (isPm && hour < 12) {
      hour += 12;
    }
    if (!isPm && hour === 12) {
      hour = 0;
    }
    return new Date(year, month, day, hour, minute, 0).getTime();
  }

  /** Unix 风格 `Jan 01 12:00` / `2024-01-02 12:00` */
  private static textTime(text: string): number {
    const dash: RegExpMatchArray | null = text.match(/^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})$/);
    if (dash !== null) {
      return new Date(Number.parseInt(dash[1], 10), Number.parseInt(dash[2], 10) - 1,
        Number.parseInt(dash[3], 10), Number.parseInt(dash[4], 10), Number.parseInt(dash[5], 10), 0).getTime();
    }
    const months: string[] = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
    const parts: string[] = text.trim().split(/\s+/);
    if (parts.length !== 3) {
      return 0;
    }
    const mi: number = months.indexOf(parts[0].toLowerCase());
    if (mi < 0) {
      return 0;
    }
    const day: number = Number.parseInt(parts[1], 10);
    const now: Date = new Date();
    if (parts[2].indexOf(':') > 0) {
      const hm: string[] = parts[2].split(':');
      return new Date(now.getFullYear(), mi, day, Number.parseInt(hm[0], 10), Number.parseInt(hm[1], 10), 0).getTime();
    }
    const year: number = Number.parseInt(parts[2], 10);
    return new Date(Number.isNaN(year) ? now.getFullYear() : year, mi, day, 0, 0, 0).getTime();
  }
}

/** 字节缓冲工具（FTP 报文按行切分、数据流拼接都用到） */
export class FtpBytes {
  static concat(a: Uint8Array, b: Uint8Array): Uint8Array {
    if (a.length === 0) {
      return b;
    }
    if (b.length === 0) {
      return a;
    }
    const out: Uint8Array = new Uint8Array(a.length + b.length);
    out.set(a, 0);
    out.set(b, a.length);
    return out;
  }

  static fromAscii(text: string): Uint8Array {
    const out: Uint8Array = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i++) {
      out[i] = text.charCodeAt(i) & 0xff;
    }
    return out;
  }

  static toAscii(bytes: Uint8Array): string {
    let s: string = '';
    for (let i = 0; i < bytes.length; i++) {
      s += String.fromCharCode(bytes[i]);
    }
    return s;
  }
}
