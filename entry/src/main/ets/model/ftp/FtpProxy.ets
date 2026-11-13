import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FtpBrowser, FtpCredential, FtpStream } from './FtpBrowser';
import { FtpBytes } from './FtpProto';

const DOMAIN: number = 0x0001;
const TAG: string = 'FtpProxy';
/** 候选端口：被占用就试下一个（与 SMB 代理错开） */
const PORTS: number[] = [47850, 47851, 47856, 47860, 47866];

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

class Target {
  host: string = '';
  port: number = 21;
  path: string = '';
}

/**
 * 本地 HTTP 代理桥：把 ftp:// 文件映射成 http://127.0.0.1:port/ftp?h=&p=&f= 给 AVPlayer。
 *
 * 与 SmbProxy 同一套思路（AVPlayer 只认本地文件或 HTTP 地址）：起一个最小 HTTP/1.1 服务，
 * 支持 Range（206）与 HEAD，收到请求后按偏移用 REST + RETR 去 FTP 侧读，边读边吐，
 * 因此拖动进度条只需换一个 Range，不用整段下载。
 */
export class FtpProxy {
  private static server: socket.TCPSocketServer | undefined = undefined;
  private static port: number = 0;
  private static startTask: Promise<number> | undefined = undefined;
  /** 进行中的流，退出播放器时统一掐断 */
  private static streams: Map<number, FtpStream> = new Map<number, FtpStream>();
  private static seq: number = 0;

  static get currentPort(): number {
    return FtpProxy.port;
  }

  static get isRunning(): boolean {
    return FtpProxy.port > 0;
  }

  /** 起服务（幂等），返回监听端口 */
  static ensure(): Promise<number> {
    if (FtpProxy.port > 0) {
      return Promise.resolve(FtpProxy.port);
    }
    if (FtpProxy.startTask === undefined) {
      FtpProxy.startTask = FtpProxy.doStart();
      FtpProxy.startTask.catch(() => {
        FtpProxy.startTask = undefined;
      });
    }
    return FtpProxy.startTask;
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
        FtpProxy.onClient(client);
      });
      server.on('error', (err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'server error %{public}d', err.code);
      });
      FtpProxy.server = server;
      FtpProxy.port = port;
      hilog.info(DOMAIN, TAG, 'proxy listening 127.0.0.1:%{public}d', port);
      return port;
    }
    throw new Error('本地 FTP 代理端口全部被占用，无法播放');
  }

  /** 关闭服务并释放所有 FTP 流（退出播放器时调用） */
  static async shutdown(): Promise<void> {
    const server: socket.TCPSocketServer | undefined = FtpProxy.server;
    FtpProxy.server = undefined;
    FtpProxy.port = 0;
    FtpProxy.startTask = undefined;
    const pending: FtpStream[] = [];
    FtpProxy.streams.forEach((item: FtpStream) => {
      pending.push(item);
    });
    FtpProxy.streams.clear();
    for (let i = 0; i < pending.length; i++) {
      await pending[i].close().catch(() => {
      });
    }
    if (server !== undefined) {
      await server.close().catch(() => {
      });
    }
  }

  /** 由 ftp:// 地址构造代理地址（同步返回，供列表项直接生成播放地址） */
  static async urlFor(ftpUrl: string): Promise<string> {
    const port: number = await FtpProxy.ensure();
    const parsed: Target | undefined = FtpProxy.parseFtpUrl(ftpUrl);
    if (parsed === undefined) {
      throw new Error('FTP 地址不完整，需要 ftp://host[:port]/路径');
    }
    return `http://127.0.0.1:${port}/ftp?h=${encodeURIComponent(parsed.host)}&p=${parsed.port}` +
      `&f=${encodeURIComponent(parsed.path)}`;
  }

  private static parseFtpUrl(url: string): Target | undefined {
    const norm: string = url.trim().replace(/^ftps?:\/\//i, 'ftp://');
    if (!norm.startsWith('ftp://')) {
      return undefined;
    }
    const head: string = norm.substring(6);
    const slash: number = head.indexOf('/');
    const hostPart: string = slash >= 0 ? head.substring(0, slash) : head;
    const path: string = slash >= 0 ? decodeURIComponent(head.substring(slash)) : '/';
    if (hostPart.length === 0) {
      return undefined;
    }
    const t: Target = new Target();
    let host: string = hostPart;
    let port: number = 21;
    const colon: number = hostPart.lastIndexOf(':');
    if (colon > 0) {
      const n: number = Number.parseInt(hostPart.substring(colon + 1), 10);
      if (!Number.isNaN(n) && n > 0) {
        port = n;
        host = hostPart.substring(0, colon);
      }
    }
    t.host = host;
    t.port = port;
    t.path = path;
    return t;
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
      st.buffer = FtpBytes.concat(st.buffer, new Uint8Array(info.message));
      const headEnd: number = FtpProxy.headEnd(st.buffer);
      if (headEnd < 0) {
        if (st.buffer.length > 16384) {
          st.closed = true;
          FtpProxy.closeQuiet(client);
        }
        return;
      }
      const head: string = FtpBytes.toAscii(st.buffer.slice(0, headEnd));
      st.buffer = new Uint8Array(0);
      st.busy = true;
      FtpProxy.handle(client, st, head).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'serve failed: %{public}s', err.message);
        FtpProxy.closeQuiet(client);
      });
    });
  }

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
      FtpProxy.closeQuiet(client);
      return;
    }
    const first: string[] = lines[0].split(' ');
    if (first.length < 2) {
      await FtpProxy.fail(client, '400 Bad Request');
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
    const parsed: Target | undefined = FtpProxy.parseTarget(target);
    if (parsed === undefined) {
      await FtpProxy.fail(client, '404 Not Found');
      return;
    }
    const ftpUrl: string = `ftp://${parsed.port === 21 ? parsed.host : `${parsed.host}:${parsed.port}`}${parsed.path}`;
    const cred: FtpCredential = FtpBrowser.credentialOf(parsed.host, parsed.port);
    let size: number = await FtpBrowser.sizeOf(ftpUrl);
    let stream: FtpStream | undefined = undefined;
    let part: RangePart = new RangePart(0, 0);
    if (size > 0) {
      part = FtpProxy.parseRange(rangeHeader, size);
    }
    try {
      stream = await FtpBrowser.openStream(ftpUrl, part.start, size);
      if (size <= 0 && stream.size > 0) {
        size = stream.size;
        part = FtpProxy.parseRange(rangeHeader, size);
        if (part.start > 0) {
          // SIZE 晚到：重开一次带上偏移
          await stream.close().catch(() => {
          });
          stream = await FtpBrowser.openStream(ftpUrl, part.start, size);
        }
      }
    } catch (err) {
      const e: Error = err as Error;
      hilog.warn(DOMAIN, TAG, 'open %{public}s failed: %{public}s', parsed.path, e.message);
      await FtpProxy.fail(client, '502 Bad Gateway');
      return;
    }
    FtpProxy.seq += 1;
    const token: number = FtpProxy.seq;
    FtpProxy.streams.set(token, stream);
    const mime: string = FtpProxy.mimeOf(parsed.path);
    const hasRange: boolean = size > 0;
    const bodyLen: number = hasRange ? part.end - part.start + 1 : -1;
    const partial: boolean = hasRange && (rangeHeader.length > 0 || bodyLen < size);
    let header: string = partial ? 'HTTP/1.1 206 Partial Content\r\n' : 'HTTP/1.1 200 OK\r\n';
    header += `Content-Type: ${mime}\r\n`;
    if (hasRange) {
      header += `Content-Length: ${bodyLen}\r\n`;
      header += 'Accept-Ranges: bytes\r\n';
      if (partial) {
        header += `Content-Range: bytes ${part.start}-${part.end}/${size}\r\n`;
      }
    }
    header += 'Connection: close\r\n\r\n';
    await client.send({ data: header });
    if (method === 'HEAD' || bodyLen === 0) {
      await stream.close().catch(() => {
      });
      FtpProxy.streams.delete(token);
      FtpProxy.closeQuiet(client);
      return;
    }
    let sent: number = 0;
    const stop: number = hasRange ? bodyLen : -1;
    while (!st.closed) {
      if (stop >= 0 && sent >= stop) {
        break;
      }
      let chunk: Uint8Array = new Uint8Array(0);
      try {
        chunk = await stream.next();
      } catch (err) {
        break;
      }
      if (chunk.length === 0) {
        break;
      }
      let piece: Uint8Array = chunk;
      if (stop >= 0 && sent + piece.length > stop) {
        piece = piece.slice(0, stop - sent);
      }
      sent += piece.length;
      const exact: Uint8Array = new Uint8Array(piece.length);
      exact.set(piece, 0);
      try {
        await client.send({ data: exact.buffer as ArrayBuffer });
      } catch (err) {
        break;
      }
    }
    await stream.close().catch(() => {
    });
    FtpProxy.streams.delete(token);
    hilog.info(DOMAIN, TAG, '%{public}s %{public}s sent=%{public}d cred=%{public}s',
      method, parsed.path, sent, cred.key());
    FtpProxy.closeQuiet(client);
  }

  private static async fail(client: socket.TCPSocketConnection, status: string): Promise<void> {
    const body: string = 'ftp proxy error';
    const header: string = `HTTP/1.1 ${status}\r\nContent-Type: text/plain\r\n` +
      `Content-Length: ${body.length}\r\nConnection: close\r\n\r\n${body}`;
    await client.send({ data: header }).catch(() => {
    });
    FtpProxy.closeQuiet(client);
  }

  /** 代理地址形如 http://127.0.0.1:47850/ftp?h=host&p=21&f=%2Fvideo%2Fa.mp4 */
  private static parseTarget(target: string): Target | undefined {
    const q: number = target.indexOf('?');
    if (q < 0 || !target.substring(0, q).startsWith('/ftp')) {
      return undefined;
    }
    const pieces: string[] = target.substring(q + 1).split('&');
    const t: Target = new Target();
    for (let i = 0; i < pieces.length; i++) {
      const eq: number = pieces[i].indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const key: string = pieces[i].substring(0, eq);
      const val: string = decodeURIComponent(pieces[i].substring(eq + 1));
      if (key === 'h') {
        t.host = val;
      } else if (key === 'p') {
        const n: number = Number.parseInt(val, 10);
        if (!Number.isNaN(n) && n > 0) {
          t.port = n;
        }
      } else if (key === 'f') {
        t.path = val;
      }
    }
    if (t.host.length === 0 || t.path.length === 0) {
      return undefined;
    }
    return t;
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
    if (ext === '.rmvb' || ext === '.rm') {
      return 'video/vnd.rn-realmedia-vbr';
    }
    if (ext === '.flv') {
      return 'video/x-flv';
    }
    return 'application/octet-stream';
  }
}
