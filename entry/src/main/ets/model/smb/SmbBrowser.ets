import { hilog } from '@kit.PerformanceAnalysisKit';
import { SmbDirEntry, SmbException, SmbSession, SmbUrl } from './Smb2Client';

const DOMAIN: number = 0x0001;
const TAG: string = 'SmbBrowser';

/** 一个 SMB 文件目标（代理侧也用它定位句柄） */
export class SmbTarget {
  host: string = '';
  port: number = 445;
  share: string = '';
  path: string = '';

  constructor(host: string, port: number, share: string, path: string) {
    this.host = host;
    this.port = port > 0 ? port : 445;
    this.share = share;
    this.path = path;
  }

  key(): string {
    return `${this.host}:${this.port}/${this.share}/${this.path}`;
  }

  sessionKey(): string {
    return `${this.host}:${this.port}/${this.share}`;
  }
}

class SmbCred {
  user: string = '';
  pass: string = '';

  constructor(user: string, pass: string) {
    this.user = user;
    this.pass = pass;
  }
}

/**
 * SMB 会话管理：
 * - 按 host:port 记住账号（由服务器条目带入，代理按需取用）
 * - 按 host:port/share 复用会话，避免每次列目录都重新协商认证
 * - 会话出错即丢弃，下次调用重连一次
 */
export class SmbBrowser {
  private static creds: Map<string, SmbCred> = new Map<string, SmbCred>();
  private static sessions: Map<string, SmbSession> = new Map<string, SmbSession>();

  /** 进入某台服务器前登记账号密码 */
  static useServer(url: string, user: string, pass: string): void {
    const u: SmbUrl = SmbUrl.parse(url);
    if (!u.ok) {
      return;
    }
    SmbBrowser.creds.set(`${u.host}:${u.port}`, new SmbCred(user, pass));
  }

  static credOf(host: string, port: number): SmbCred {
    const hit: SmbCred | undefined = SmbBrowser.creds.get(`${host}:${port}`);
    return hit !== undefined ? hit : new SmbCred('', '');
  }

  /** 把 smb 地址解析成目标对象，地址不完整返回 undefined */
  static targetOf(url: string): SmbTarget | undefined {
    const u: SmbUrl = SmbUrl.parse(url);
    if (!u.ok) {
      return undefined;
    }
    return new SmbTarget(u.host, u.port, u.share, u.path);
  }

  /** 地址自检：给出可直接展示给用户的中文原因 */
  static checkUrl(url: string): string {
    const u: SmbUrl = SmbUrl.parse(url);
    if (u.ok) {
      return '';
    }
    return 'SMB 地址需要写成 smb://192.168.1.10/共享名，也可以带子目录 smb://192.168.1.10/共享名/电影';
  }

  /** 取（或建立）一个可用的会话 */
  static async sessionOf(host: string, port: number, share: string): Promise<SmbSession> {
    const key: string = `${host}:${port}/${share}`;
    const exist: SmbSession | undefined = SmbBrowser.sessions.get(key);
    if (exist !== undefined) {
      return exist;
    }
    const cred: SmbCred = SmbBrowser.credOf(host, port);
    const session: SmbSession = new SmbSession(host, port, share, cred.user, cred.pass);
    await session.connect();
    SmbBrowser.sessions.set(key, session);
    return session;
  }

  private static async drop(key: string): Promise<void> {
    const old: SmbSession | undefined = SmbBrowser.sessions.get(key);
    SmbBrowser.sessions.delete(key);
    if (old !== undefined) {
      await old.disconnect().catch(() => {
      });
    }
  }

  /** 列目录；会话失效时重连重试一次 */
  static async listDir(url: string): Promise<SmbDirEntry[]> {
    const why: string = SmbBrowser.checkUrl(url);
    if (why.length > 0) {
      throw new SmbException(why, -100);
    }
    const target: SmbTarget = SmbBrowser.targetOf(url) as SmbTarget;
    const key: string = target.sessionKey();
    try {
      const session: SmbSession = await SmbBrowser.sessionOf(target.host, target.port, target.share);
      return await session.listDir(target.path);
    } catch (err) {
      const e: Error = err as Error;
      hilog.warn(DOMAIN, TAG, 'listDir retry: %{public}s', e.message);
      await SmbBrowser.drop(key);
      const session: SmbSession = await SmbBrowser.sessionOf(target.host, target.port, target.share);
      return await session.listDir(target.path);
    }
  }

  /** 上传地址：把 smb 目标包装成清单里的展示用地址 */
  static childUrl(baseUrl: string, name: string): string {
    const u: SmbUrl = SmbUrl.parse(baseUrl);
    if (!u.ok) {
      return baseUrl;
    }
    return SmbUrl.join(u, name);
  }

  /** 上一级地址；已在共享根时返回空串 */
  static parentOf(url: string): string {
    const u: SmbUrl = SmbUrl.parse(url);
    if (!u.ok) {
      return '';
    }
    const parts: string[] = u.path.length > 0 ? u.path.split('/') : [];
    if (parts.length === 0) {
      return '';
    }
    parts.pop();
    const portPart: string = u.port === 445 ? '' : `:${u.port}`;
    const rest: string = parts.length > 0 ? `/${parts.join('/')}` : '';
    return `smb://${u.host}${portPart}/${u.share}${rest}`;
  }

  /** 把用户输入的地址统一成 smb://host/share/... 形式 */
  static normalizeUrl(input: string): string {
    let s: string = input.trim().replace(/\\/g, '/');
    if (s.length === 0) {
      return '';
    }
    const lower: string = s.toLowerCase();
    if (!lower.startsWith('smb://') && !lower.startsWith('cifs://')) {
      s = `smb://${s}`;
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /** 目录标题：有子路径用子路径，否则用共享名 */
  static titleOf(url: string): string {
    const t: SmbTarget | undefined = SmbBrowser.targetOf(url);
    if (t === undefined) {
      return 'SMB';
    }
    return t.path.length > 0 ? t.path : t.share;
  }

  /** 清空所有会话（退出网络页 / 换服务器时） */
  static async reset(): Promise<void> {
    const keys: string[] = [];
    SmbBrowser.sessions.forEach((s: SmbSession, k: string) => {
      keys.push(k);
    });
    for (let i = 0; i < keys.length; i++) {
      await SmbBrowser.drop(keys[i]);
    }
  }
}
