import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FtpBytes, FtpEntry, FtpException, FtpListing } from './FtpProto';

const DOMAIN: number = 0x0001;
const TAG: string = 'FtpConn';
/** 控制命令默认超时 */
const CMD_TIMEOUT: number = 12000;
/** 登录等慢操作超时 */
const LOGIN_TIMEOUT: number = 15000;
/** 一次数据连接的读块超时（大文件卡流也要能感知） */
const DATA_TIMEOUT: number = 20000;
/** 主动模式候选端口（监听失败顺延） */
const ACTIVE_PORTS: number[] = [47861, 47862, 47867, 47872, 47877];

/** 一条 FTP 回复（可能多行，code 取首行三位码） */
export class FtpReply {
  code: number = 0;
  text: string = '';

  constructor(code: number, text: string) {
    this.code = code;
    this.text = text;
  }

  get ok(): boolean {
    return this.code >= 200 && this.code < 400;
  }

  get preliminary(): boolean {
    return this.code >= 100 && this.code < 200;
  }
}

/**
 * 数据连接：PASV/EPSV 是「客户端连服务端」，PORT/EPRT 是「服务端连客户端」。
 * 对上暴露同样的读接口：next() 拿到一块数据，返回空数组表示 EOF。
 */
export class FtpDataChannel {
  /** 被动模式下要连的目标（由 PASV/EPSV 应答解析得到） */
  host: string = '';
  port: number = 0;
  private tcp: socket.TCPSocket | undefined = undefined;
  private server: socket.TCPSocketServer | undefined = undefined;
  private incoming: socket.TCPSocketConnection | undefined = undefined;
  private queue: Uint8Array[] = [];
  private waiter: ((chunk: Uint8Array) => void) | undefined = undefined;
  private eof: boolean = false;
  private failed: string = '';
  private acceptWaiter: ((ok: boolean) => void) | undefined = undefined;

  /** 被动模式：连过去 */
  async connectTo(host: string, port: number, timeoutMs: number): Promise<void> {
    const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    tcp.on('message', (info: socket.SocketMessageInfo) => {
      this.push(new Uint8Array(info.message));
    });
    tcp.on('close', () => {
      this.markEof();
    });
    tcp.on('error', (err: BusinessError) => {
      this.failed = `数据连接异常（${err.code}）`;
      this.markEof();
    });
    await new Promise<void>((resolve: () => void, reject: (e: FtpException) => void) => {
      tcp.connect({
        address: { address: host, port: port, family: 1 },
        timeout: timeoutMs
      }).then(() => {
        resolve();
      }).catch((err: BusinessError) => {
        reject(new FtpException(`无法建立 FTP 数据连接 ${host}:${port}（错误码 ${err.code}）`, err.code));
      });
    });
  }

  /** 主动模式：先监听，等服务器连进来 */
  async listen(): Promise<number> {
    for (let i = 0; i < ACTIVE_PORTS.length; i++) {
      const port: number = ACTIVE_PORTS[i];
      const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      try {
        await server.listen({ address: '0.0.0.0', port: port, family: 1 });
      } catch (err) {
        continue;
      }
      server.on('connect', (client: socket.TCPSocketConnection) => {
        this.incoming = client;
        client.on('message', (info: socket.SocketMessageInfo) => {
          this.push(new Uint8Array(info.message));
        });
        client.on('close', () => {
          this.markEof();
        });
        client.on('error', (err: BusinessError) => {
          this.failed = `主动模式数据连接异常（${err.code}）`;
          this.markEof();
        });
        const waiter: ((ok: boolean) => void) | undefined = this.acceptWaiter;
        this.acceptWaiter = undefined;
        if (waiter !== undefined) {
          waiter(true);
        }
      });
      server.on('error', (err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'active server error %{public}d', err.code);
      });
      this.server = server;
      return port;
    }
    throw new FtpException('本机端口被占用，无法进入主动模式（PORT）', 0);
  }

  /** 主动模式等待服务器回连 */
  async waitAccept(timeoutMs: number): Promise<void> {
    if (this.incoming !== undefined) {
      return;
    }
    await new Promise<void>((resolve: () => void, reject: (e: FtpException) => void) => {
      let settled: boolean = false;
      this.acceptWaiter = (ok: boolean) => {
        if (settled) {
          return;
        }
        settled = true;
        resolve();
      };
      setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        this.acceptWaiter = undefined;
        reject(new FtpException('服务器未回连（主动模式常被 NAT/防火墙拦截，建议切回被动模式）', 0));
      }, timeoutMs);
    });
  }

  private push(chunk: Uint8Array): void {
    if (chunk.length === 0) {
      return;
    }
    const waiter: ((c: Uint8Array) => void) | undefined = this.waiter;
    if (waiter !== undefined) {
      this.waiter = undefined;
      waiter(chunk);
      return;
    }
    this.queue.push(chunk);
  }

  private markEof(): void {
    this.eof = true;
    const waiter: ((c: Uint8Array) => void) | undefined = this.waiter;
    if (waiter !== undefined) {
      this.waiter = undefined;
      waiter(new Uint8Array(0));
    }
  }

  get errorText(): string {
    return this.failed;
  }

  /** 取下一块数据；空数组代表结束 */
  async next(timeoutMs: number): Promise<Uint8Array> {
    if (this.queue.length > 0) {
      return this.queue.shift() as Uint8Array;
    }
    if (this.eof) {
      return new Uint8Array(0);
    }
    return new Promise<Uint8Array>((resolve: (c: Uint8Array) => void) => {
      let settled: boolean = false;
      this.waiter = (chunk: Uint8Array) => {
        if (settled) {
          return;
        }
        settled = true;
        resolve(chunk);
      };
      setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        this.waiter = undefined;
        hilog.warn(DOMAIN, TAG, 'data read timeout %{public}d', timeoutMs);
        this.markEof();
        resolve(new Uint8Array(0));
      }, timeoutMs);
    });
  }

  /** 一次性读完（目录列表用） */
  async readAll(timeoutMs: number): Promise<Uint8Array> {
    let out: Uint8Array = new Uint8Array(0);
    while (true) {
      const chunk: Uint8Array = await this.next(timeoutMs);
      if (chunk.length === 0) {
        break;
      }
      out = FtpBytes.concat(out, chunk);
    }
    return out;
  }

  async close(): Promise<void> {
    const tcp: socket.TCPSocket | undefined = this.tcp;
    const incoming: socket.TCPSocketConnection | undefined = this.incoming;
    const server: socket.TCPSocketServer | undefined = this.server;
    this.tcp = undefined;
    this.incoming = undefined;
    this.server = undefined;
    this.queue = [];
    this.markEof();
    if (tcp !== undefined) {
      await tcp.close().catch(() => {
      });
    }
    if (incoming !== undefined) {
      await incoming.close().catch(() => {
      });
    }
    if (server !== undefined) {
      await server.close().catch(() => {
      });
    }
  }
}

/**
 * 一条下载流：持有控制连接的「传输锁」，直到 close() 才放行下一条命令。
 * 这样 AVPlayer 连续发 Range 请求时不会把 PASV/RETR 应答交错踩乱。
 */
export class FtpReader {
  private conn: FtpConnection;
  private channel: FtpDataChannel;
  private release: () => void;
  private closed: boolean = false;
  /** 文件总长（SIZE 拿到，拿不到为 -1） */
  readonly size: number;

  constructor(conn: FtpConnection, channel: FtpDataChannel, release: () => void, size: number) {
    this.conn = conn;
    this.channel = channel;
    this.release = release;
    this.size = size;
  }

  async next(): Promise<Uint8Array> {
    if (this.closed) {
      return new Uint8Array(0);
    }
    return this.channel.next(DATA_TIMEOUT);
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    await this.channel.close();
    await this.conn.finishTransfer();
    this.release();
  }
}

/**
 * FTP 控制连接。所有命令串行执行（FTP 本身就是一问一答），
 * 数据连接按每条传输单独建立，读流结束后再把控制连接还给队列。
 */
export class FtpConnection {
  host: string = '';
  port: number = 21;
  user: string = 'anonymous';
  private pass: string = 'anonymous@';
  private tcp: socket.TCPSocket | undefined = undefined;
  private rx: Uint8Array = new Uint8Array(0);
  private stash: FtpReply[] = [];
  private waiter: ((r: FtpReply) => void) | undefined = undefined;
  private multiline: FtpReply | undefined = undefined;
  private multilineLines: string[] = [];
  private tail: Promise<void> = Promise.resolve();
  private closed: boolean = false;
  private lastError: string = '';
  /** 服务端是否接受了 OPTS UTF8 ON */
  utf8On: boolean = false;
  /** 被动模式开关（默认 true，主动模式作为兼容兜底） */
  passive: boolean = true;
  /** 目录名解码优先字符集 */
  charset: string = 'utf-8';
  /** 登录后服务器 pwd */
  home: string = '/';
  /** 是否支持 MLSD（RFC 3659） */
  mlsd: boolean = false;
  /** 服务器欢迎语（诊断用） */
  banner: string = '';
  connectedAt: number = 0;
  usedAt: number = 0;

  get alive(): boolean {
    return this.tcp !== undefined && !this.closed;
  }

  get errorText(): string {
    return this.lastError;
  }

  private setError(text: string): void {
    this.lastError = text;
    hilog.warn(DOMAIN, TAG, '%{public}s', text);
  }

  // ---------------- 连接与登录 ----------------

  async open(host: string, port: number, user: string, pass: string, passive: boolean): Promise<void> {
    this.host = host;
    this.port = port;
    this.user = user.length > 0 ? user : 'anonymous';
    this.pass = pass.length > 0 ? pass : 'anonymous@';
    this.passive = passive;
    const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    this.closed = false;
    tcp.on('message', (info: socket.SocketMessageInfo) => {
      this.onData(new Uint8Array(info.message));
    });
    tcp.on('close', () => {
      this.closed = true;
      this.setError('FTP 服务器关闭了控制连接');
      const waiter: ((r: FtpReply) => void) | undefined = this.waiter;
      this.waiter = undefined;
      if (waiter !== undefined) {
        waiter(new FtpReply(-1, '连接已断开'));
      }
    });
    tcp.on('error', (err: BusinessError) => {
      this.closed = true;
      this.setError(`FTP 控制连接异常（${err.code}）`);
      const waiter: ((r: FtpReply) => void) | undefined = this.waiter;
      this.waiter = undefined;
      if (waiter !== undefined) {
        waiter(new FtpReply(-1, '连接异常'));
      }
    });
    await new Promise<void>((resolve: () => void, reject: (e: FtpException) => void) => {
      tcp.connect({
        address: { address: host, port: port, family: 1 },
        timeout: LOGIN_TIMEOUT
      }).then(() => {
        resolve();
      }).catch((err: BusinessError) => {
        reject(new FtpException(`无法连接 FTP 服务器 ${host}:${port}（错误码 ${err.code}）；` +
          '请确认地址、端口可达，且设备与服务器在同一网段', err.code));
      });
    });
    this.connectedAt = Date.now();
    this.usedAt = this.connectedAt;
    const welcome: FtpReply = await this.takeReply(LOGIN_TIMEOUT);
    this.banner = welcome.text;
    if (welcome.code !== 220) {
      throw new FtpException(`服务器未就绪：${welcome.code} ${welcome.text}`, welcome.code);
    }
    await this.login();
  }

  private async login(): Promise<void> {
    let reply: FtpReply = await this.cmd(`USER ${this.user}`, LOGIN_TIMEOUT);
    if (reply.code === 331 || reply.code === 332) {
      reply = await this.cmd(`PASS ${this.pass}`, LOGIN_TIMEOUT);
    }
    if (reply.code !== 230 && reply.code !== 202) {
      throw new FtpException(`登录失败（${reply.code} ${reply.text}）`, reply.code);
    }
    // 编码协商：先要 UTF-8，失败就按 GB18030 解码目录
    try {
      const feat: FtpReply = await this.cmd('FEAT', CMD_TIMEOUT);
      if (feat.text.toUpperCase().indexOf('MLSD') >= 0 || feat.text.toUpperCase().indexOf('MLST') >= 0) {
        this.mlsd = true;
      }
    } catch (err) {
      hilog.info(DOMAIN, TAG, 'FEAT unsupported');
    }
    try {
      const opts: FtpReply = await this.cmd('OPTS UTF8 ON', CMD_TIMEOUT);
      this.utf8On = opts.code === 200;
    } catch (err) {
      this.utf8On = false;
    }
    this.charset = this.utf8On ? 'utf-8' : 'gb18030';
    const type: FtpReply = await this.cmd('TYPE I', CMD_TIMEOUT);
    if (!type.ok) {
      throw new FtpException(`设置二进制传输失败（${type.code}）`, type.code);
    }
    const pwd: FtpReply = await this.cmd('PWD', CMD_TIMEOUT);
    if (pwd.code === 257) {
      const m: RegExpMatchArray | null = pwd.text.match(/"([^"]*)"/);
      this.home = m !== null ? m[1] : '/';
    }
  }

  /** 断线重连（目录操作前调用，失败抛异常） */
  async ensureAlive(): Promise<void> {
    if (!this.alive) {
      await this.close();
      await this.open(this.host, this.port, this.user, this.pass, this.passive);
      return;
    }
    try {
      const noop: FtpReply = await this.cmd('NOOP', 6000);
      if (noop.code < 0 || noop.code >= 400) {
        throw new FtpException('NOOP 失败', noop.code);
      }
    } catch (err) {
      hilog.info(DOMAIN, TAG, 'reconnect after NOOP failure');
      await this.close();
      await this.open(this.host, this.port, this.user, this.pass, this.passive);
    }
  }

  // ---------------- 收发 ----------------

  private onData(chunk: Uint8Array): void {
    this.rx = FtpBytes.concat(this.rx, chunk);
    this.drain();
  }

  private drain(): void {
    while (true) {
      let cut: number = -1;
      for (let i = 0; i + 1 < this.rx.length; i++) {
        if (this.rx[i] === 0x0d && this.rx[i + 1] === 0x0a) {
          cut = i;
          break;
        }
      }
      if (cut < 0) {
        if (this.rx.length > 65536) {
          this.rx = new Uint8Array(0);
        }
        return;
      }
      const line: string = FtpBytes.toAscii(this.rx.slice(0, cut));
      this.rx = this.rx.slice(cut + 2);
      this.feed(line);
    }
  }

  private feed(line: string): void {
    const current: FtpReply | undefined = this.multiline;
    if (current === undefined) {
      if (line.length < 3) {
        return;
      }
      const code: number = Number.parseInt(line.substring(0, 3), 10);
      if (Number.isNaN(code)) {
        return;
      }
      const sep: string = line.length > 3 ? line.charAt(3) : ' ';
      if (sep === '-') {
        this.multiline = new FtpReply(code, line);
        this.multilineLines = [line];
        return;
      }
      this.deliver(new FtpReply(code, line));
      return;
    }
    this.multilineLines.push(line);
    if (line.length >= 4 && line.substring(0, 3) === `${current.code}` && line.charAt(3) === ' ') {
      const text: string = this.multilineLines.join('\n');
      this.multiline = undefined;
      this.multilineLines = [];
      this.deliver(new FtpReply(current.code, text));
    }
  }

  private deliver(reply: FtpReply): void {
    const waiter: ((r: FtpReply) => void) | undefined = this.waiter;
    if (waiter !== undefined) {
      this.waiter = undefined;
      waiter(reply);
      return;
    }
    // 没有人在等（例如 ABOR 的 226、传输中的 226 提前到达），先存着
    this.stash.push(reply);
  }

  private async takeReply(timeoutMs: number): Promise<FtpReply> {
    if (this.stash.length > 0) {
      return this.stash.shift() as FtpReply;
    }
    return new Promise<FtpReply>((resolve: (r: FtpReply) => void) => {
      let settled: boolean = false;
      this.waiter = (reply: FtpReply) => {
        if (settled) {
          return;
        }
        settled = true;
        resolve(reply);
      };
      setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        this.waiter = undefined;
        resolve(new FtpReply(-1, `服务器 ${timeoutMs}ms 无响应（可能被防火墙静默丢弃）`));
      }, timeoutMs);
    });
  }

  private async lockAcquire(): Promise<() => void> {
    const prev: Promise<void> = this.tail;
    let unlock: () => void = () => {
    };
    this.tail = new Promise<void>((resolve: () => void) => {
      unlock = () => {
        resolve();
      };
    });
    await prev;
    return unlock;
  }

  /** 发一条命令并等应答（三行以上的多行应答会合并进 text） */
  async cmd(command: string, timeoutMs: number): Promise<FtpReply> {
    const unlock: () => void = await this.lockAcquire();
    try {
      return await this.cmdLocked(command, timeoutMs);
    } finally {
      unlock();
    }
  }

  private async cmdLocked(command: string, timeoutMs: number): Promise<FtpReply> {
    const tcp: socket.TCPSocket | undefined = this.tcp;
    if (tcp === undefined || this.closed) {
      return new FtpReply(-1, '控制连接已断开');
    }
    this.usedAt = Date.now();
    try {
      await tcp.send({ data: `${command}\r\n` });
    } catch (err) {
      this.closed = true;
      return new FtpReply(-1, '命令发送失败，控制连接可能已断开');
    }
    return this.takeReply(timeoutMs);
  }

  // ---------------- 目录 ----------------

  async cwd(path: string): Promise<boolean> {
    const reply: FtpReply = await this.cmd(`CWD ${path}`, CMD_TIMEOUT);
    return reply.ok;
  }

  async cdup(): Promise<boolean> {
    const reply: FtpReply = await this.cmd('CDUP', CMD_TIMEOUT);
    return reply.ok;
  }

  /** SIZE 拿文件字节数，拿不到返回 -1（部分服务端只在 TYPE I 下支持） */
  async size(path: string): Promise<number> {
    const reply: FtpReply = await this.cmd(`SIZE ${path}`, CMD_TIMEOUT);
    if (reply.code === 213) {
      const m: RegExpMatchArray | null = reply.text.match(/(\d+)\s*$/);
      if (m !== null) {
        const n: number = Number.parseInt(m[1], 10);
        if (!Number.isNaN(n)) {
          return n;
        }
      }
    }
    return -1;
  }

  /** 目录列表：MLSD → LIST → NLST 逐级回退 */
  async list(path: string): Promise<FtpEntry[]> {
    const target: string = path.length === 0 ? '' : path;
    if (this.mlsd) {
      const entries: FtpEntry[] | undefined = await this.listWith('MLSD', target);
      if (entries !== undefined) {
        return entries;
      }
    }
    const listed: FtpEntry[] | undefined = await this.listWith('LIST', target);
    if (listed !== undefined && listed.length > 0) {
      return listed;
    }
    const fallback: FtpEntry[] | undefined = await this.listWith('LIST -a', target);
    if (fallback !== undefined && fallback.length > 0) {
      return fallback;
    }
    const names: FtpEntry[] | undefined = await this.listWith('NLST', target);
    if (names !== undefined) {
      return names;
    }
    if (listed !== undefined) {
      return listed;
    }
    throw new FtpException('服务器拒绝列目录（LIST/MLSD/NLST 均失败）', 0);
  }

  private async listWith(command: string, path: string): Promise<FtpEntry[] | undefined> {
    const unlock: () => void = await this.lockAcquire();
    let channel: FtpDataChannel | undefined = undefined;
    try {
      const prepared: FtpDataChannel | undefined = await this.prepareData();
      if (prepared === undefined) {
        return undefined;
      }
      channel = prepared;
      const full: string = path.length > 0 ? `${command} ${path}` : command;
      const reply: FtpReply = await this.cmdLocked(full, CMD_TIMEOUT);
      if (reply.code >= 400 || reply.code < 0) {
        return undefined;
      }
      if (this.passive) {
        await channel.connectTo(prepared.host, prepared.port, CMD_TIMEOUT).catch(() => {
        });
      }
      const bytes: Uint8Array = await channel.readAll(DATA_TIMEOUT);
      await this.takeReply(CMD_TIMEOUT);
      const text: string = FtpListing.decode(bytes, this.charset);
      if (text.indexOf('\uFFFD') >= 0 && this.charset !== 'gb18030') {
        hilog.info(DOMAIN, TAG, 'listing decode fallback to gb18030');
        const retried: string = FtpListing.decode(bytes, 'gb18030');
        return this.parseByCommand(command, retried);
      }
      return this.parseByCommand(command, text);
    } catch (err) {
      const e: Error = err as Error;
      hilog.warn(DOMAIN, TAG, 'list %{public}s failed: %{public}s', command, e.message);
      return undefined;
    } finally {
      const ch: FtpDataChannel | undefined = channel;
      if (ch !== undefined) {
        await ch.close();
      }
      unlock();
    }
  }

  private parseByCommand(command: string, text: string): FtpEntry[] {
    if (command.startsWith('MLSD')) {
      return FtpListing.parseMlsd(text);
    }
    if (command.startsWith('NLST')) {
      return FtpListing.parseNlst(text);
    }
    return FtpListing.parseList(text);
  }

  /** 准备数据通道：被动模式解析 PASV/EPSV 端口；主动模式监听并发 PORT/EPRT */
  private async prepareData(): Promise<FtpDataChannel | undefined> {
    const channel: FtpDataChannel = new FtpDataChannel();
    if (this.passive) {
      let reply: FtpReply = await this.cmdLocked('EPSV', CMD_TIMEOUT);
      let host: string = this.host;
      let port: number = -1;
      if (reply.code === 229) {
        const m: RegExpMatchArray | null = reply.text.match(/\(\|\|\|(\d+)\|\)/);
        if (m !== null) {
          port = Number.parseInt(m[1], 10);
        }
      }
      if (port <= 0) {
        reply = await this.cmdLocked('PASV', CMD_TIMEOUT);
        if (reply.code !== 227) {
          this.setError(`服务器拒绝被动模式（${reply.code}）；可在设置里切到主动模式`);
          return undefined;
        }
        const m: RegExpMatchArray | null =
          reply.text.match(/(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)/);
        if (m === null) {
          return undefined;
        }
        const ip: string = `${m[1]}.${m[2]}.${m[3]}.${m[4]}`;
        port = Number.parseInt(m[5], 10) * 256 + Number.parseInt(m[6], 10);
        // 服务器在 NAT 后常回 0.0.0.0 或内网地址，退回控制连接的目标地址
        if (ip !== '0.0.0.0' && ip.length > 0) {
          const remote: string = await this.remoteAddress();
          host = remote.length > 0 && ip !== remote ? remote : ip;
        }
      }
      if (port <= 0) {
        return undefined;
      }
      channel.host = host;
      channel.port = port;
      return channel;
    }
    const port: number = await channel.listen();
    const local: string = await this.localAddress();
    const ip: string = local.length > 0 ? local : '127.0.0.1';
    let reply: FtpReply = await this.cmdLocked(`EPRT |1|${ip}|${port}|`, CMD_TIMEOUT);
    if (reply.code !== 200) {
      const parts: string[] = ip.split('.');
      if (parts.length === 4) {
        const p1: number = Math.floor(port / 256);
        const p2: number = port % 256;
        reply = await this.cmdLocked(`PORT ${parts[0]},${parts[1]},${parts[2]},${parts[3]},${p1},${p2}`, CMD_TIMEOUT);
      }
    }
    if (reply.code !== 200) {
      await channel.close();
      this.setError(`服务器拒绝主动模式（${reply.code}）`);
      return undefined;
    }
    return channel;
  }

  private async localAddress(): Promise<string> {
    const tcp: socket.TCPSocket | undefined = this.tcp;
    if (tcp === undefined) {
      return '';
    }
    try {
      const addr: socket.NetAddress = await tcp.getLocalAddress();
      return addr.address;
    } catch (err) {
      return '';
    }
  }

  private async remoteAddress(): Promise<string> {
    const tcp: socket.TCPSocket | undefined = this.tcp;
    if (tcp === undefined) {
      return '';
    }
    try {
      const addr: socket.NetAddress = await tcp.getRemoteAddress();
      return addr.address;
    } catch (err) {
      return '';
    }
  }

  // ---------------- 下载 ----------------

  /**
   * 打开一条下载流：REST 定位（断点续传/seek）→ PASV → RETR。
   * 读流期间持有控制连接锁，close() 后释放。
   */
  async openRead(path: string, offset: number, knownSize: number): Promise<FtpReader> {
    const unlock: () => void = await this.lockAcquire();
    let channel: FtpDataChannel | undefined = undefined;
    try {
      let size: number = knownSize;
      if (size <= 0) {
        size = await this.size(path);
      }
      const prepared: FtpDataChannel | undefined = await this.prepareData();
      if (prepared === undefined) {
        throw new FtpException(this.lastError.length > 0 ? this.lastError : '数据通道建立失败', 0);
      }
      channel = prepared;
      if (offset > 0) {
        const rest: FtpReply = await this.cmdLocked(`REST ${offset}`, CMD_TIMEOUT);
        if (rest.code !== 350) {
          hilog.warn(DOMAIN, TAG, 'REST rejected %{public}d，将从 0 开始读', rest.code);
        }
      }
      const reply: FtpReply = await this.cmdLocked(`RETR ${path}`, CMD_TIMEOUT);
      if (reply.code >= 400 || reply.code < 0) {
        throw new FtpException(`无法读取文件（${reply.code} ${reply.text}）`, reply.code);
      }
      if (this.passive) {
        await channel.connectTo(prepared.host, prepared.port, LOGIN_TIMEOUT);
      } else {
        await channel.waitAccept(LOGIN_TIMEOUT);
      }
      const reader: FtpReader = new FtpReader(this, channel, unlock, size);
      return reader;
    } catch (err) {
      const ch: FtpDataChannel | undefined = channel;
      if (ch !== undefined) {
        await ch.close();
      }
      unlock();
      throw err as Error;
    }
  }

  /** 传输结束：把数据连接后的 226/250 收掉，避免污染下一条命令 */
  async finishTransfer(): Promise<void> {
    if (!this.alive) {
      return;
    }
    const reply: FtpReply = await this.takeReply(8000);
    if (reply.code >= 400) {
      hilog.warn(DOMAIN, TAG, 'transfer end %{public}d %{public}s', reply.code, reply.text);
    }
  }

  async close(): Promise<void> {
    const tcp: socket.TCPSocket | undefined = this.tcp;
    this.tcp = undefined;
    this.closed = true;
    this.rx = new Uint8Array(0);
    this.waiter = undefined;
    this.multiline = undefined;
    this.multilineLines = [];
    this.stash = [];
    if (tcp !== undefined) {
      tcp.send({ data: 'QUIT\r\n' }).catch(() => {
      });
      await tcp.close().catch(() => {
      });
    }
  }
}
