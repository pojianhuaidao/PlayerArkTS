import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Bytes } from './SmbCrypto';
import { SmbBrowser, SmbTarget } from './SmbBrowser';
import { SmbFileHandle, SmbSession } from './Smb2Client';

const DOMAIN: number = 0x0001;
const TAG: string = 'SmbProxy';
/** 候选端口：被占用就试下一个 */
const PORTS: number[] = [47825, 47826, 47831, 47836, 47842];
/** 单次向 SMB 读取的最大字节（实际还会被服务端协商的 MaxReadSize 截断） */
const CHUNK: number = 262144;
/** 同时保持打开的文件句柄上限，超出关掉最久未用的 */
const MAX_OPEN: number = 6;

class OpenFile {
  session: SmbSession;
  handle: SmbFileHandle;
  usedAt: number = 0;

  constructor(session: SmbSession, handle: SmbFileHandle, usedAt: number) {
    this.session = session;
    this.handle = handle;
    this.usedAt = usedAt;
  }
}

class RangePart {
  start: number = 0;
  end: number = 0;

  constructor(start: number, end: number) {
    this.start = start;
    this.end = end;
  }
}

class ClientState {
  buffer: Uint8Array = new Uint8Array(0);
  busy: boolean = false;
  closed: boolean = false;
}

class ServedInfo {
  target: SmbTarget;
  file: OpenFile;

  constructor(target: SmbTarget, file: OpenFile) {
    this.target = target;
    this.file = file;
  }
}

/**
 * 本地 HTTP 代理桥：把 smb:// 文件映射成 http://127.0.0.1:port/smb?... 给 AVPlayer。
 *
 * AVPlayer 只认本地文件或 HTTP 地址，不认识 SMB；这里起一个最小 HTTP/1.1 服务，
 * 支持 Range（206）与 HEAD，收到请求再去 SMB 侧按偏移读，边读边吐。
 */
export class SmbProxy {
  private static server: socket.TCPSocketServer | undefined = undefined;
  private static port: number = 0;
  private static startTask: Promise<number> | undefined = undefined;
  private static openFiles: Map<string, OpenFile> = new Map<string, OpenFile>();
  private static order: number = 0;

  static get currentPort(): number {
    return SmbProxy.port;
  }

  static get isRunning(): boolean {
    return SmbProxy.port > 0;
  }

  /** 起服务（幂等），返回监听端口 */
  static ensure(): Promise<number> {
    if (SmbProxy.port > 0) {
      return Promise.resolve(SmbProxy.port);
    }
    if (SmbProxy.startTask === undefined) {
      SmbProxy.startTask = SmbProxy.doStart();
      // 起失败时把任务清掉，下次还能重试，避免一次失败锁死整个 SMB 播放
      SmbProxy.startTask.catch(() => {
        SmbProxy.startTask = undefined;
      });
    }
    return SmbProxy.startTask;
  }

  private static async doStart(): Promise<number> {
    for (let i = 0; i < PORTS.length; i++) {
      const port: number = PORTS[i];
      const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      try {
        await server.listen({ address: '127.0.0.1', port: port, family: 1 });
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'listen %{public}d failed', port);
        continue;
      }
      server.on('connect', (client: socket.TCPSocketConnection) => {
        SmbProxy.onClient(client);
      });
      server.on('error', (err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'server error %{public}d', err.code);
      });
      SmbProxy.server = server;
      SmbProxy.port = port;
      hilog.info(DOMAIN, TAG, 'proxy listening 127.0.0.1:%{public}d', port);
      return port;
    }
    throw new Error('本地代理端口全部被占用，无法播放 SMB 视频');
  }

  /** 关闭服务并释放句柄（退出播放器 / 切换来源时调用） */
  static async shutdown(): Promise<void> {
    const server: socket.TCPSocketServer | undefined = SmbProxy.server;
    SmbProxy.server = undefined;
    SmbProxy.port = 0;
    SmbProxy.startTask = undefined;
    SmbProxy.openFiles.forEach((item: OpenFile) => {
      item.session.closeFile(item.handle).then(() => {
      }).catch(() => {
      });
    });
    SmbProxy.openFiles.clear();
    if (server !== undefined) {
      await server.close().catch(() => {
      });
    }
  }

  // ---------------- 连接处理 ----------------

  private static onClient(client: socket.TCPSocketConnection): void {
    const st: ClientState = new ClientState();
    client.on('close', () => {
      st.closed = true;
    });
    client.on('error', (err: BusinessError) => {
      st.closed = true;
    });
    client.on('message', (info: socket.SocketMessageInfo) => {
      if (st.busy || st.closed) {
        return;
      }
      st.buffer = Bytes.concat(st.buffer, new Uint8Array(info.message));
      const headEnd: number = SmbProxy.headEnd(st.buffer);
      if (headEnd < 0) {
        if (st.buffer.length > 16384) {
          st.closed = true;
          SmbProxy.closeQuiet(client);
        }
        return;
      }
      const head: string = Bytes.fromAscii(st.buffer.slice(0, headEnd));
      st.buffer = new Uint8Array(0);
      st.busy = true;
      SmbProxy.handle(client, st, head).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'serve failed: %{public}s', err.message);
        SmbProxy.closeQuiet(client);
      });
    });
  }

  /** 找到请求头结束位置（\r\n\r\n 的首字节偏移） */
  private static headEnd(b: Uint8Array): number {
    for (let i = 0; i + 3 < b.length; i++) {
      if (b[i] === 0x0d && b[i + 1] === 0x0a && b[i + 2] === 0x0d && b[i + 3] === 0x0a) {
        return i;
      }
    }
    return -1;
  }

  private static closeQuiet(client: socket.TCPSocketConnection): void {
    client.close().catch(() => {
    });
  }

  private static async handle(client: socket.TCPSocketConnection, st: ClientState,
    head: string): Promise<void> {
    const lines: string[] = head.split('\r\n');
    if (lines.length === 0) {
      SmbProxy.closeQuiet(client);
      return;
    }
    const first: string[] = lines[0].split(' ');
    if (first.length < 2) {
      await SmbProxy.fail(client, '400 Bad Request');
      return;
    }
    const method: string = first[0].toUpperCase();
    const target: string = first[1];
    let rangeHeader: string = '';
    for (let i = 1; i < lines.length; i++) {
      const colon: number = lines[i].indexOf(':');
      if (colon <= 0) {
        continue;
      }
      const key: string = lines[i].substring(0, colon).trim().toLowerCase();
      if (key === 'range') {
        rangeHeader = lines[i].substring(colon + 1).trim();
      }
    }
    const parsed: SmbTarget | undefined = SmbProxy.parseTarget(target);
    if (parsed === undefined) {
      await SmbProxy.fail(client, '404 Not Found');
      return;
    }
    let served: ServedInfo;
    try {
      served = await SmbProxy.acquire(parsed);
    } catch (err) {
      const e: Error = err as Error;
      hilog.warn(DOMAIN, TAG, 'open %{public}s failed: %{public}s', parsed.path, e.message);
      await SmbProxy.fail(client, '502 Bad Gateway');
      return;
    }
    const size: number = served.file.handle.size;
    const mime: string = SmbProxy.mimeOf(parsed.path);
    const part: RangePart = SmbProxy.parseRange(rangeHeader, size);
    const partial: boolean = part.end - part.start + 1 < size || rangeHeader.length > 0;
    const bodyLen: number = part.end - part.start + 1;
    let header: string = partial ? 'HTTP/1.1 206 Partial Content\r\n' : 'HTTP/1.1 200 OK\r\n';
    header += `Content-Type: ${mime}\r\n`;
    header += `Content-Length: ${bodyLen}\r\n`;
    header += 'Accept-Ranges: bytes\r\n';
    if (partial) {
      header += `Content-Range: bytes ${part.start}-${part.end}/${size}\r\n`;
    }
    header += 'Connection: close\r\n\r\n';
    await client.send({ data: header });
    if (method === 'HEAD' || bodyLen <= 0) {
      SmbProxy.closeQuiet(client);
      return;
    }
    let pos: number = part.start;
    const stop: number = part.end;
    while (pos <= stop && !st.closed) {
      const want: number = Math.min(CHUNK, stop - pos + 1);
      let chunk: Uint8Array = new Uint8Array(0);
      try {
        chunk = await served.file.session.readAt(served.file.handle, pos, want);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'read failed at %{public}d', pos);
        break;
      }
      if (chunk.length === 0) {
        break;
      }
      const exact: Uint8Array = new Uint8Array(chunk.length);
      exact.set(chunk, 0);
      try {
        await client.send({ data: exact.buffer as ArrayBuffer });
      } catch (err) {
        break;
      }
      pos += chunk.length;
    }
    SmbProxy.closeQuiet(client);
  }

  private static async fail(client: socket.TCPSocketConnection, status: string): Promise<void> {
    const body: string = 'smb proxy error';
    const header: string = `HTTP/1.1 ${status}\r\nContent-Type: text/plain\r\n` +
      `Content-Length: ${body.length}\r\nConnection: close\r\n\r\n${body}`;
    await client.send({ data: header }).catch(() => {
    });
    SmbProxy.closeQuiet(client);
  }

  // ---------------- URL 解析 ----------------

  /**
   * 代理地址形如 http://127.0.0.1:47825/smb?h=host&p=445&s=share&f=dir%2Fa.mp4
   * 不把账号密码写进 URL，凭据由 SmbBrowser 按 host:port 保存。
   */
  private static parseTarget(target: string): SmbTarget | undefined {
    const q: number = target.indexOf('?');
    if (q < 0 || !target.substring(0, q).startsWith('/smb')) {
      return undefined;
    }
    const query: string = target.substring(q + 1);
    const pieces: string[] = query.split('&');
    let host: string = '';
    let port: number = 445;
    let share: string = '';
    let path: string = '';
    for (let i = 0; i < pieces.length; i++) {
      const eq: number = pieces[i].indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const key: string = pieces[i].substring(0, eq);
      const val: string = decodeURIComponent(pieces[i].substring(eq + 1));
      if (key === 'h') {
        host = val;
      } else if (key === 'p') {
        const n: number = Number.parseInt(val, 10);
        if (!Number.isNaN(n) && n > 0) {
          port = n;
        }
      } else if (key === 's') {
        share = val;
      } else if (key === 'f') {
        path = val;
      }
    }
    if (host.length === 0 || share.length === 0) {
      return undefined;
    }
    return new SmbTarget(host, port, share, path);
  }

  private static parseRange(text: string, size: number): RangePart {
    const whole: RangePart = new RangePart(0, Math.max(size - 1, 0));
    if (text.length === 0 || size <= 0) {
      return whole;
    }
    const lower: string = text.toLowerCase();
    const eq: number = lower.indexOf('=');
    if (eq < 0) {
      return whole;
    }
    const spec: string = lower.substring(eq + 1).trim();
    const dash: number = spec.indexOf('-');
    if (dash < 0) {
      return whole;
    }
    const head: string = spec.substring(0, dash).trim();
    const tail: string = spec.substring(dash + 1).trim();
    let start: number = 0;
    let end: number = size - 1;
    if (head.length === 0) {
      // bytes=-N：最后 N 个字节
      const n: number = Number.parseInt(tail, 10);
      if (Number.isNaN(n) || n <= 0) {
        return whole;
      }
      start = Math.max(size - n, 0);
    } else {
      const s: number = Number.parseInt(head, 10);
      if (Number.isNaN(s)) {
        return whole;
      }
      start = s;
      if (tail.length > 0) {
        const e: number = Number.parseInt(tail, 10);
        if (!Number.isNaN(e) && e < end) {
          end = e;
        }
      }
    }
    if (start >= size) {
      return new RangePart(Math.max(size - 1, 0), Math.max(size - 1, 0));
    }
    if (end < start) {
      end = start;
    }
    return new RangePart(start, end);
  }

  private static mimeOf(path: string): string {
    const dot: number = path.lastIndexOf('.');
    const ext: string = dot >= 0 ? path.substring(dot).toLowerCase() : '';
    if (ext === '.mp4' || ext === '.m4v') {
      return 'video/mp4';
    }
    if (ext === '.mkv') {
      return 'video/x-matroska';
    }
    if (ext === '.webm') {
      return 'video/webm';
    }
    if (ext === '.ts' || ext === '.m2ts') {
      return 'video/mp2t';
    }
    if (ext === '.mov') {
      return 'video/quicktime';
    }
    if (ext === '.avi') {
      return 'video/x-msvideo';
    }
    if (ext === '.flv') {
      return 'video/x-flv';
    }
    return 'application/octet-stream';
  }

  // ---------------- 打开的句柄管理 ----------------

  private static async acquire(target: SmbTarget): Promise<ServedInfo> {
    const key: string = target.key();
    SmbProxy.order += 1;
    const exist: OpenFile | undefined = SmbProxy.openFiles.get(key);
    if (exist !== undefined) {
      exist.usedAt = SmbProxy.order;
      return new ServedInfo(target, exist);
    }
    const session: SmbSession = await SmbBrowser.sessionOf(target.host, target.port, target.share);
    const handle: SmbFileHandle = await session.openFile(target.path);
    const file: OpenFile = new OpenFile(session, handle, SmbProxy.order);
    SmbProxy.openFiles.set(key, file);
    await SmbProxy.trimOpen();
    return new ServedInfo(target, file);
  }

  private static async trimOpen(): Promise<void> {
    if (SmbProxy.openFiles.size <= MAX_OPEN) {
      return;
    }
    const keys: string[] = [];
    SmbProxy.openFiles.forEach((item: OpenFile, key: string) => {
      keys.push(key);
    });
    keys.sort((a: string, b: string) => {
      const ia: OpenFile = SmbProxy.openFiles.get(a) as OpenFile;
      const ib: OpenFile = SmbProxy.openFiles.get(b) as OpenFile;
      return ia.usedAt - ib.usedAt;
    });
    const drop: number = SmbProxy.openFiles.size - MAX_OPEN;
    for (let i = 0; i < drop; i++) {
      const item: OpenFile | undefined = SmbProxy.openFiles.get(keys[i]);
      SmbProxy.openFiles.delete(keys[i]);
      if (item !== undefined) {
        await item.session.closeFile(item.handle).catch(() => {
        });
      }
    }
  }

  /** 由 SMB 地址构造代理地址（同步，供列表项直接生成播放地址） */
  static async urlFor(smbUrl: string): Promise<string> {
    const port: number = await SmbProxy.ensure();
    const target: SmbTarget | undefined = SmbBrowser.targetOf(smbUrl);
    if (target === undefined) {
      throw new Error('SMB 地址不完整，需要 host/共享名/文件路径');
    }
    return `http://127.0.0.1:${port}/smb?h=${encodeURIComponent(target.host)}&p=${target.port}` +
      `&s=${encodeURIComponent(target.share)}&f=${encodeURIComponent(target.path)}`;
  }
}
