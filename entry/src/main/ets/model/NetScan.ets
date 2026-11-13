import { connection, http, socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'NetScan';
const DOMAIN: number = 0x0001;

/** 扫描命中的一个服务 */
export class ScanHit {
  ip: string;
  port: number;
  /** 0=HTTP 目录，1=WebDAV，2=SMB（只探主机，共享名在添加页补） */
  kind: number;
  /** 服务器自报的 Server 头，便于用户辨认设备 */
  serverHeader: string;
  /** 根目录响应码 */
  code: number;

  constructor(ip: string, port: number, kind: number, serverHeader: string, code: number) {
    this.ip = ip;
    this.port = port;
    this.kind = kind;
    this.serverHeader = serverHeader;
    this.code = code;
  }

  kindLabel(): string {
    if (this.kind === 1) {
      return 'WebDAV';
    }
    if (this.kind === 2) {
      return 'SMB';
    }
    return 'HTTP';
  }

  /** 可作为服务器地址加入列表的方案（SMB 需用户补共享名，故返回空串） */
  url(): string {
    if (this.kind === 2) {
      return '';
    }
    const scheme: string = this.kind === 1 ? 'https' : 'http';
    const portPart: string = (scheme === 'http' && this.port === 80) || (scheme === 'https' && this.port === 443)
      ? '' : `:${this.port}`;
    return `${scheme}://${this.ip}${portPart}/`;
  }

  title(): string {
    const vendor: string = NetScan.serverName(this.serverHeader);
    const base: string = this.ip === '' ? '' : this.ip;
    return vendor.length > 0 ? `${base} · ${vendor}` : base;
  }

  subtitle(): string {
    if (this.kind === 2) {
      return `端口 ${this.port} · SMB 共享 · 添加时补共享名`;
    }
    const codeText: string = this.code === 401 || this.code === 403 ? '需要账号' : '可直接浏览';
    return `端口 ${this.port} · ${this.kindLabel()} · ${codeText}`;
  }
}

/**
 * 局域网发现：读取本机所在网段，逐个探测常见媒体/共享端口。
 * 只做 TCP/HTTP 层探测，不扫描非本机网段，不发送任何写操作。
 */
export class NetScan {
  /** 探测的 HTTP 端口（覆盖 nginx 目录、媒体服务器、常见 NAS/WebDAV） */
  static readonly HTTP_PORTS: number[] = [80, 8080, 5005, 5244, 8000, 9000];
  /** SMB 端口（仅探测存在性，浏览需 native 实现） */
  static readonly SMB_PORT: number = 445;
  /** 同时探测的主机数，控制峰值连接数 */
  static readonly HOST_CONCURRENCY: number = 24;

  /** 读本机 IPv4 地址与 /24 前缀 */
  static async localPrefix(): Promise<string> {
    try {
      const net: connection.NetHandle = await connection.getDefaultNet();
      const props: connection.ConnectionProperties = await connection.getConnectionProperties(net);
      const addrs: connection.LinkAddress[] = props.linkAddresses;
      for (let i = 0; i < addrs.length; i++) {
        const ip: string = addrs[i].address.address;
        if (ip.indexOf(':') >= 0) {
          continue;
        }
        const segs: string[] = ip.split('.');
        if (segs.length === 4) {
          return `${segs[0]}.${segs[1]}.${segs[2]}`;
        }
      }
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'get default net failed code=%{public}d', e.code);
    }
    return '';
  }

  /** 扫描本机 /24 网段；onProgress(done, total) 用于界面进度 */
  static async scan(onProgress: (done: number, total: number) => void): Promise<ScanHit[]> {
    const prefix: string = await NetScan.localPrefix();
    if (prefix.length === 0) {
      return [];
    }
    const ips: string[] = [];
    for (let i = 1; i <= 254; i++) {
      ips.push(`${prefix}.${i}`);
    }
    const hits: ScanHit[] = [];
    const total: number = ips.length;
    let done: number = 0;
    let cursor: number = 0;

    // 每批 HOST_CONCURRENCY 台主机并行，批内每台主机并行探测各端口
    while (cursor < total) {
      const batch: string[] = ips.slice(cursor, cursor + NetScan.HOST_CONCURRENCY);
      cursor += batch.length;
      const tasks: Promise<void>[] = batch.map((ip: string) => NetScan.probeHost(ip, hits));
      await Promise.all(tasks);
      done += batch.length;
      onProgress(done, total);
    }
    hits.sort((a: ScanHit, b: ScanHit) => {
      const ai: number = NetScan.ipValue(a.ip);
      const bi: number = NetScan.ipValue(b.ip);
      if (ai !== bi) {
        return ai - bi;
      }
      return a.port - b.port;
    });
    return hits;
  }

  private static async probeHost(ip: string, hits: ScanHit[]): Promise<void> {
    const jobs: Promise<void>[] = [];
    for (let i = 0; i < NetScan.HTTP_PORTS.length; i++) {
      jobs.push(NetScan.probeHttp(ip, NetScan.HTTP_PORTS[i], hits));
    }
    jobs.push(NetScan.probeSmb(ip, hits));
    await Promise.all(jobs);
  }

  private static async probeHttp(ip: string, port: number, hits: ScanHit[]): Promise<void> {
    const request: http.HttpRequest = http.createHttp();
    const url: string = `http://${ip}:${port}/`;
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 700,
        readTimeout: 900,
        usingCache: false,
        header: { 'Accept': '*/*' }
      };
      const resp: http.HttpResponse = await request.request(url, options);
      const code: number = resp.responseCode;
      const serverRaw: ESObject = resp.header['server'];
      const davRaw: ESObject = resp.header['dav'];
      const allowRaw: ESObject = resp.header['allow'];
      const server: string = typeof serverRaw === 'string' ? serverRaw as string : '';
      let dav: boolean = code === 207 || davRaw !== undefined ||
        (typeof allowRaw === 'string' && (allowRaw as string).toUpperCase().indexOf('PROPFIND') >= 0);
      if (!dav && (code === 200 || code === 401)) {
        // 根目录能访问时再发一次 PROPFIND，207 即判定为 WebDAV
        dav = await NetScan.classifyDav(ip, port);
      }
      if (code === 200 || code === 207 || code === 401 || code === 403 || code === 301 || code === 302) {
        hits.push(new ScanHit(ip, port, dav ? 1 : 0, server, code));
      }
    } catch (err) {
      // 端口未开放 / 超时：属正常扫描结果，不记录日志避免刷屏
    } finally {
      request.destroy();
    }
  }

  /** PROPFIND 探测：返回 207 或带 DAV 响应头即判为 WebDAV */
  private static async classifyDav(ip: string, port: number): Promise<boolean> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: 'PROPFIND' as http.RequestMethod,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 700,
        readTimeout: 900,
        usingCache: false,
        extraData: '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop>' +
          '<d:resourcetype/></d:prop></d:propfind>',
        header: { 'Depth': '0', 'Content-Type': 'application/xml; charset=utf-8' }
      };
      const resp: http.HttpResponse = await request.request(`http://${ip}:${port}/`, options);
      return resp.responseCode === 207 || resp.header['dav'] !== undefined;
    } catch (err) {
      return false;
    } finally {
      request.destroy();
    }
  }

  private static async probeSmb(ip: string, hits: ScanHit[]): Promise<void> {
    const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
    try {
      try {
        await tcp.bind({ address: '0.0.0.0', port: 0, family: 1 });
      } catch (err) {
        // 部分设备不允许 bind 到 0.0.0.0，直接 connect 由协议栈选源地址
      }
      const options: socket.TCPConnectOptions = {
        address: { address: ip, port: NetScan.SMB_PORT, family: 1 },
        timeout: 700
      };
      await tcp.connect(options);
      hits.push(new ScanHit(ip, NetScan.SMB_PORT, 2, '', 0));
    } catch (err) {
      // 未开放
    } finally {
      try {
        await tcp.close();
      } catch (err) {
      }
    }
  }

  private static ipValue(ip: string): number {
    const segs: string[] = ip.split('.');
    if (segs.length !== 4) {
      return 0;
    }
    return Number.parseInt(segs[3], 10);
  }

  /** 从 Server 头里提炼设备名，便于用户认出家中的 NAS */
  static serverName(server: string): string {
    const lower: string = server.toLowerCase();
    if (lower.indexOf('synology') >= 0) {
      return '群晖';
    }
    if (lower.indexOf('nginx') >= 0) {
      return 'nginx';
    }
    if (lower.indexOf('apache') >= 0) {
      return 'Apache';
    }
    if (lower.indexOf('microsoft-iis') >= 0) {
      return 'IIS';
    }
    if (lower.indexOf('openresty') >= 0) {
      return 'OpenResty';
    }
    if (lower.indexOf('alist') >= 0) {
      return 'AList';
    }
    if (lower.indexOf('lighttpd') >= 0) {
      return 'lighttpd';
    }
    if (server.length > 0) {
      const cut: number = server.indexOf('/');
      return cut > 0 ? server.substring(0, cut) : server;
    }
    return '';
  }
}
