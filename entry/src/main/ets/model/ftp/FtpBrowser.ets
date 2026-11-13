import { hilog } from '@kit.PerformanceAnalysisKit';
import { FtpConnection, FtpReader } from './FtpConnection';
import { FtpEntry, FtpException, FtpTarget, FtpUrl } from './FtpProto';

const DOMAIN: number = 0x0001;
const TAG: string = 'FtpBrowser';

/** 一台 FTP 服务器的连接参数 */
export class FtpCredential {
  host: string = '';
  port: number = 21;
  user: string = 'anonymous';
  pass: string = '';
  /** true = 被动模式（默认），false = 主动模式（PORT/EPRT） */
  passive: boolean = true;

  constructor(host: string, port: number, user: string, pass: string, passive: boolean) {
    this.host = host;
    this.port = port;
    this.user = user;
    this.pass = pass;
    this.passive = passive;
  }

  key(): string {
    return `${this.host}:${this.port}`;
  }

  /** 匿名登录（国内很多 NAS 允许 anonymous） */
  get anonymous(): boolean {
    return this.user.length === 0 || this.user.toLowerCase() === 'anonymous';
  }
}

/** 一条流式读句柄：ownConnection=true 表示独占连接，close() 时要一并断开 */
export class FtpStream {
  reader: FtpReader;
  conn: FtpConnection;
  ownConnection: boolean;

  constructor(reader: FtpReader, conn: FtpConnection, ownConnection: boolean) {
    this.reader = reader;
    this.conn = conn;
    this.ownConnection = ownConnection;
  }

  get size(): number {
    return this.reader.size;
  }

  async next(): Promise<Uint8Array> {
    return this.reader.next();
  }

  async close(): Promise<void> {
    await this.reader.close();
    if (this.ownConnection) {
      await this.conn.close();
    }
  }
}

/**
 * FTP 会话管理：
 *  - 按 host:port 记住凭据（不进 URL，避免 AVPlayer 拒播带 userinfo 的地址）；
 *  - 按 host:port:user 缓存控制连接，目录浏览复用同一会话；
 *  - 视频流走独立连接，避免与目录浏览抢控制连接的问答通道。
 */
export class FtpBrowser {
  private static pool: Map<string, FtpConnection> = new Map<string, FtpConnection>();
  private static creds: Map<string, FtpCredential> = new Map<string, FtpCredential>();
  /** 最近一次列目录用的字符集（诊断用） */
  private static lastNote: string = '';

  static get note(): string {
    return FtpBrowser.lastNote;
  }

  /** 登记凭据（打开服务器、播放前调用） */
  static useServer(url: string, user: string, pass: string, passive: boolean): FtpCredential | undefined {
    const target: FtpTarget | undefined = FtpUrl.parse(url);
    if (target === undefined) {
      return undefined;
    }
    const cred: FtpCredential = new FtpCredential(target.host, target.port,
      user.length > 0 ? user : 'anonymous', pass, passive);
    FtpBrowser.creds.set(cred.key(), cred);
    // 账号变了就丢掉旧会话
    const old: FtpConnection | undefined = FtpBrowser.pool.get(target.key());
    if (old !== undefined && old.user !== cred.user) {
      FtpBrowser.pool.delete(target.key());
      old.close().catch(() => {
      });
    }
    return cred;
  }

  static credentialOf(host: string, port: number): FtpCredential {
    const hit: FtpCredential | undefined = FtpBrowser.creds.get(`${host}:${port}`);
    if (hit !== undefined) {
      return hit;
    }
    return new FtpCredential(host, port, 'anonymous', '', true);
  }

  static forget(hostPort: string): void {
    FtpBrowser.creds.delete(hostPort);
    FtpBrowser.pool.forEach((conn: FtpConnection, key: string) => {
      if (key.startsWith(`${hostPort}:`)) {
        FtpBrowser.pool.delete(key);
        conn.close().catch(() => {
        });
      }
    });
  }

  /** ftp:// 地址 + 已登记凭据 → 完整目标 */
  static targetOf(url: string): FtpTarget | undefined {
    const parsed: FtpTarget | undefined = FtpUrl.parse(url);
    if (parsed === undefined) {
      return undefined;
    }
    const cred: FtpCredential = FtpBrowser.credentialOf(parsed.host, parsed.port);
    return new FtpTarget(parsed.host, parsed.port, parsed.path, cred.user, cred.pass);
  }

  /** 取（或建）一条控制连接 */
  static async sessionOf(host: string, port: number, user: string, pass: string,
    passive: boolean): Promise<FtpConnection> {
    const key: string = `${host}:${port}:${user}`;
    const cached: FtpConnection | undefined = FtpBrowser.pool.get(key);
    if (cached !== undefined && cached.alive) {
      return cached;
    }
    if (cached !== undefined) {
      await cached.close().catch(() => {
      });
      FtpBrowser.pool.delete(key);
    }
    const conn: FtpConnection = new FtpConnection();
    await conn.open(host, port, user, pass, passive);
    FtpBrowser.pool.set(key, conn);
    hilog.info(DOMAIN, TAG, 'session ready %{public}s utf8=%{public}s', key, `${conn.utf8On}`);
    return conn;
  }

  /** 列目录（会先做一次存活检查，断线自动重连一次） */
  static async listDir(url: string): Promise<FtpEntry[]> {
    const target: FtpTarget | undefined = FtpBrowser.targetOf(url);
    if (target === undefined) {
      throw new FtpException('FTP 地址不完整，请填 ftp://192.168.1.10/ 形式', 0);
    }
    const cred: FtpCredential = FtpBrowser.credentialOf(target.host, target.port);
    const conn: FtpConnection = await FtpBrowser.sessionOf(target.host, target.port, cred.user, cred.pass,
      cred.passive);
    try {
      await conn.ensureAlive();
      const entries: FtpEntry[] = await conn.list(target.path);
      FtpBrowser.lastNote = conn.utf8On ? 'UTF-8' : 'GB18030 回退';
      return FtpBrowser.sort(entries);
    } catch (err) {
      // 断线重连一次再试
      const e: Error = err as Error;
      hilog.warn(DOMAIN, TAG, 'list failed, retry once: %{public}s', e.message);
      await conn.close().catch(() => {
      });
      FtpBrowser.pool.delete(`${target.host}:${target.port}:${cred.user}`);
      const retried: FtpConnection = await FtpBrowser.sessionOf(target.host, target.port, cred.user, cred.pass,
        cred.passive);
      const entries: FtpEntry[] = await retried.list(target.path);
      FtpBrowser.lastNote = retried.utf8On ? 'UTF-8（重连后）' : 'GB18030 回退（重连后）';
      return FtpBrowser.sort(entries);
    }
  }

  private static sort(list: FtpEntry[]): FtpEntry[] {
    const dirs: FtpEntry[] = list.filter((e: FtpEntry) => e.isDir);
    const files: FtpEntry[] = list.filter((e: FtpEntry) => !e.isDir);
    dirs.sort((a: FtpEntry, b: FtpEntry) => a.name.localeCompare(b.name));
    files.sort((a: FtpEntry, b: FtpEntry) => a.name.localeCompare(b.name));
    return dirs.concat(files);
  }

  /** 文件大小；失败返回 -1 */
  static async sizeOf(url: string): Promise<number> {
    const target: FtpTarget | undefined = FtpBrowser.targetOf(url);
    if (target === undefined) {
      return -1;
    }
    const cred: FtpCredential = FtpBrowser.credentialOf(target.host, target.port);
    try {
      const conn: FtpConnection = await FtpBrowser.sessionOf(target.host, target.port, cred.user, cred.pass,
        cred.passive);
      return await conn.size(target.path);
    } catch (err) {
      return -1;
    }
  }

  /**
   * 打开一条读取流。视频播放走独占连接（不与目录浏览抢问答通道），
   * offset>0 时用 REST 做断点/seek。
   */
  static async openStream(url: string, offset: number, knownSize: number): Promise<FtpStream> {
    const target: FtpTarget | undefined = FtpBrowser.targetOf(url);
    if (target === undefined) {
      throw new FtpException('FTP 地址不完整', 0);
    }
    const cred: FtpCredential = FtpBrowser.credentialOf(target.host, target.port);
    const conn: FtpConnection = new FtpConnection();
    await conn.open(target.host, target.port, cred.user, cred.pass, cred.passive);
    try {
      const reader: FtpReader = await conn.openRead(target.path, offset, knownSize);
      return new FtpStream(reader, conn, true);
    } catch (err) {
      await conn.close().catch(() => {
      });
      throw err as Error;
    }
  }

  /** 退出播放器/切换来源时释放全部连接 */
  static async closeAll(): Promise<void> {
    const tasks: Promise<void>[] = [];
    FtpBrowser.pool.forEach((conn: FtpConnection) => {
      tasks.push(conn.close().catch(() => {
      }));
    });
    FtpBrowser.pool.clear();
    for (let i = 0; i < tasks.length; i++) {
      await tasks[i];
    }
  }
}
