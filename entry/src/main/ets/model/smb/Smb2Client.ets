/**
 * SMB2 客户端（纯 ArkTS / TCP 直连 445）。
 *
 * 设计取舍：
 *  - 协商方言按 MS-SMB2 2.2.3 的要求**升序**给出 2.0.2(0x0202) / 2.1(0x0210) /
 *    3.0(0x0300) / 3.0.2(0x0302)；1.1111.07 之前是「2.1 在前、2.0.2 在后」的降序，
 *    违反规范（Windows 直接回 STATUS_INVALID_PARAMETER，部分 NAS 视为协议违规断开）；
 *  - 认证走 NTLMv2（NTOWFv2 + NTProofStr + TargetInfo blob），同时兼容匿名/guest；
 *  - 支持 SMB2 报文签名（HMAC-SHA256），服务器强制签名时可正常工作；
 *  - 能力范围：树连接 → 目录枚举 → 文件句柄随机读（Range 播放用）→ 关闭；
 *  - 1.1111.07：失败原因按阶段区分（不再统一兜底成「服务器关闭了连接」），
 *    并把请求/响应字节转储到沙箱 files/logs/smb_*.log（见 SmbLog）。
 */
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Bytes, SmbHash } from './SmbCrypto';
import { SmbLog } from './SmbLog';
import { isSystemHiddenName } from '../FileFilter';

const TAG: string = 'Smb2';
const DOMAIN_ID: number = 0x0002;

/** 连接阶段名：把失败定位到具体报文，而不是笼统的「服务器关闭了连接」 */
const STAGE_CONNECT: string = 'TCP 连接';
const STAGE_NEGOTIATE: string = '协议协商(NEGOTIATE)';
const STAGE_SESSION: string = '身份认证(SESSION_SETUP)';
const STAGE_TREE: string = '打开共享(TREE_CONNECT)';
const STAGE_LIST: string = '列目录(QUERY_DIRECTORY)';
const STAGE_OPEN: string = '打开文件(CREATE)';
const STAGE_READ: string = '读文件(READ)';
const STAGE_CLOSE: string = '关闭句柄(CLOSE)';
const STAGE_OTHER: string = '其他请求';

/** 对端直接断链时的排查提示（NAS 侧没有连接日志时，这几乎是要先确认的三件事） */
const HINT_LINK: string = '请先确认：① NAS 已开启 SMB2/SMB3 服务（只开 SMB1 的设备收到 SMB2 报文会直接断开）；' +
  '② 未强制「传输加密 / SMB 签名」，或已放行 SMB2.1 明文；③ 445 端口没有被路由器、AP 隔离或防火墙拦截' +
  '（可在电脑上用「测试网络连接 445」验证）';

const CMD_NEGOTIATE: number = 0;
const CMD_SESSION_SETUP: number = 1;
const CMD_LOGOFF: number = 2;
const CMD_TREE_CONNECT: number = 3;
const CMD_TREE_DISCONNECT: number = 4;
const CMD_CREATE: number = 5;
const CMD_CLOSE: number = 6;
const CMD_READ: number = 8;
const CMD_QUERY_DIRECTORY: number = 14;

const FLAG_SERVER_TO_REDIR: number = 0x00000001;
const FLAG_SIGNED: number = 0x00000008;

const STATUS_SUCCESS: number = 0;
const STATUS_MORE_PROCESSING_REQUIRED: number = 0xc0000016;
const STATUS_NO_MORE_FILES: number = 0x80000006;

const SMB2_NEGOTIATE_SIGNING_ENABLED: number = 0x0001;
const SMB2_NEGOTIATE_SIGNING_REQUIRED: number = 0x0002;

/** NTLM Type3 中填写的机器名（不能放用户名，那是字段语义错误） */
const CLIENT_NAME: string = 'PlayerArkTS';

const FILE_DIRECTORY_INFORMATION: number = 0x01;

/** 小端读写工具 */
class Bin {
  static u8(b: Uint8Array, o: number): number {
    return b[o];
  }

  static u16(b: Uint8Array, o: number): number {
    return (b[o] | (b[o + 1] << 8)) & 0xffff;
  }

  static u32(b: Uint8Array, o: number): number {
    return (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0;
  }

  /** 64 位小端转 number（SMB 中用到的值都远小于 2^53，高 32 位仅做校验） */
  static u64(b: Uint8Array, o: number): number {
    const lo: number = Bin.u32(b, o);
    const hi: number = Bin.u32(b, o + 4);
    return hi * 4294967296 + lo;
  }

  /** Uint8Array 转精确长度的 ArrayBuffer（socket.send 需要） */
  static ab(u: Uint8Array): ArrayBuffer {
    const out: ArrayBuffer = new ArrayBuffer(u.length);
    const view: Uint8Array = new Uint8Array(out);
    view.set(u, 0);
    return out;
  }
}

/** 顺序写缓冲 */
class Buf {
  private b: Uint8Array;
  private p: number = 0;

  constructor(size: number) {
    this.b = new Uint8Array(size);
  }

  u8(v: number): void {
    this.b[this.p] = v & 0xff;
    this.p += 1;
  }

  u16(v: number): void {
    this.b[this.p] = v & 0xff;
    this.b[this.p + 1] = (v >>> 8) & 0xff;
    this.p += 2;
  }

  u32(v: number): void {
    this.b[this.p] = v & 0xff;
    this.b[this.p + 1] = (v >>> 8) & 0xff;
    this.b[this.p + 2] = (v >>> 16) & 0xff;
    this.b[this.p + 3] = (v >>> 24) & 0xff;
    this.p += 4;
  }

  u64(v: number): void {
    const lo: number = v % 4294967296;
    const hi: number = Math.floor(v / 4294967296);
    this.u32(lo >>> 0);
    this.u32(hi >>> 0);
  }

  raw(u: Uint8Array): void {
    this.b.set(u, this.p);
    this.p += u.length;
  }

  zeros(n: number): void {
    this.p += n;
  }

  /** 回填指定偏移（用于 SecurityBufferOffset 之类的定长字段） */
  patch16(offset: number, v: number): void {
    this.b[offset] = v & 0xff;
    this.b[offset + 1] = (v >>> 8) & 0xff;
  }

  patch32(offset: number, v: number): void {
    this.b[offset] = v & 0xff;
    this.b[offset + 1] = (v >>> 8) & 0xff;
    this.b[offset + 2] = (v >>> 16) & 0xff;
    this.b[offset + 3] = (v >>> 24) & 0xff;
  }

  data(): Uint8Array {
    return this.p === this.b.length ? this.b : this.b.slice(0, this.p);
  }
}

/** DER/SPNEGO 编码 */
class Der {
  static tlv(tag: number, content: Uint8Array): Uint8Array {
    const n: number = content.length;
    let head: Uint8Array;
    if (n < 0x80) {
      head = new Uint8Array([tag, n]);
    } else if (n < 0x100) {
      head = new Uint8Array([tag, 0x81, n]);
    } else {
      head = new Uint8Array([tag, 0x82, (n >>> 8) & 0xff, n & 0xff]);
    }
    return Bytes.concat(head, content);
  }
}

const OID_SPNEGO: number[] = [0x06, 0x06, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x02];
const OID_NTLMSSP: number[] = [0x06, 0x0a, 0x2b, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0a];

function fixedBytes(list: number[]): Uint8Array {
  const out: Uint8Array = new Uint8Array(list.length);
  for (let i = 0; i < list.length; i++) {
    out[i] = list[i];
  }
  return out;
}

/** SMB 协议异常 */
export class SmbException extends Error {
  code: number = 0;

  constructor(message: string, code: number) {
    super(message);
    this.code = code;
  }
}

/** 目录条目 */
export class SmbDirEntry {
  name: string = '';
  isDir: boolean = false;
  size: number = 0;

  constructor(name: string, isDir: boolean, size: number) {
    this.name = name;
    this.isDir = isDir;
    this.size = size;
  }
}

/** 已打开的文件句柄 */
export class SmbFileHandle {
  id: Uint8Array = new Uint8Array(16);
  size: number = 0;
  path: string = '';

  constructor(id: Uint8Array, size: number, path: string) {
    this.id = id;
    this.size = size;
    this.path = path;
  }
}

/** 一次请求的响应 */
class SmbReply {
  status: number = 0;
  treeId: number = 0;
  body: Uint8Array = new Uint8Array(0);
}

/** TCP 传输层：NBSS 分帧 + 单请求串行收发 */
class SmbTransport {
  private tcp: socket.TCPSocket | undefined = undefined;
  private rx: Uint8Array = new Uint8Array(0);
  private resolver: ((u: Uint8Array) => void) | undefined = undefined;
  private rejecter: ((e: SmbException) => void) | undefined = undefined;
  private dead: string = '';
  /** 当前所处阶段（由 SmbSession 在每个请求前设置，断链时用于定位） */
  private stage: string = STAGE_CONNECT;
  /** 已发出 / 已收到的字节数：判断「报文有没有真的到对端」的关键证据 */
  private sentBytes: number = 0;
  private recvBytes: number = 0;

  get isDead(): boolean {
    return this.dead.length > 0;
  }

  get stageName(): string {
    return this.stage;
  }

  get stats(): string {
    return `sent=${this.sentBytes}B recv=${this.recvBytes}B stage=${this.stage}`;
  }

  setStage(stage: string): void {
    this.stage = stage;
  }

  /**
   * 把「连接被对端结束」翻译成落在具体阶段的失败原因：
   *  - 一个字节都没发就被关：TCP 通了但对端不像 SMB 服务，或被中间设备劫持；
   *  - 发了请求却一个字节都没收到：报文在服务端 SMB 层之前就被丢弃或 RST
   *    （端口不是 SMB、只有 SMB1、强制加密、防火墙）—— 这正是 NAS 侧看不到日志的形态；
   *  - 收过报文后再中断：会话在后续阶段被策略性断链（签名/加密/方言/凭据）。
   */
  private describeLoss(reason: string): string {
    if (this.sentBytes === 0 && this.recvBytes === 0) {
      return `TCP 已连通，但服务器未等待任何数据就断开（${reason}）：对端 445 可能不是 SMB 服务，` +
        `或被中间网络设备拦截。${HINT_LINK}`;
    }
    if (this.recvBytes === 0) {
      return `服务器在「${this.stage}」阶段收到 ${this.sentBytes} 字节请求后直接断开，` +
        `一个字节的 SMB2 响应都没返回（${reason}）；说明报文没被当作合法 SMB2 处理。${HINT_LINK}`;
    }
    return `服务器在「${this.stage}」阶段中断连接（已发 ${this.sentBytes}B / 已收 ${this.recvBytes}B，${reason}），` +
      `后续阶段可能被服务端策略拒绝（签名、加密、方言或凭据）。`;
  }

  async open(host: string, port: number, timeoutMs: number): Promise<void> {
    const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    this.stage = STAGE_CONNECT;
    SmbLog.info(TAG, `connect ${host}:${port} timeout=${timeoutMs}ms`);
    tcp.on('message', (info: socket.SocketMessageInfo) => {
      this.onData(new Uint8Array(info.message));
    });
    tcp.on('close', () => {
      this.dead = this.describeLoss('服务器关闭了连接');
      SmbLog.warn(TAG, `close event ${this.stats}`);
      this.flushError(new SmbException(this.dead, -1));
    });
    tcp.on('error', (err: BusinessError) => {
      this.dead = this.describeLoss(`连接异常 ${err.code}`);
      SmbLog.warn(TAG, `error event ${this.stats} code=${err.code}`);
      this.flushError(new SmbException(this.dead, -1));
    });
    await new Promise<void>((resolve: () => void, reject: (e: SmbException) => void) => {
      tcp.connect({
        address: { address: host, port: port, family: 1 },
        timeout: timeoutMs
      }).then(() => {
        SmbLog.info(TAG, `tcp established ${host}:${port}`);
        resolve();
      }).catch((err: BusinessError) => {
        this.dead = err.code === 1
          ? `无法建立 TCP 连接 ${host}:${port}（请确认地址、端口 445 可达、设备与手机在同一网段）`
          : `无法建立 TCP 连接 ${host}:${port}（错误码 ${err.code}；请确认 445 未被拦截、SMB 服务已开启）`;
        SmbLog.warn(TAG, `connect failed code=${err.code} msg=${err.message}`);
        reject(new SmbException(this.dead, err.code));
      });
    });
  }

  private onData(chunk: Uint8Array): void {
    this.recvBytes += chunk.length;
    this.rx = Bytes.concat(this.rx, chunk);
    this.drain();
  }

  /** 从接收缓冲切出一个完整 NBSS 帧；不足一帧返回 undefined。长度 0 的空帧直接丢弃 */
  private take(): Uint8Array | undefined {
    while (this.rx.length >= 4) {
      const type: number = this.rx[0];
      const len: number = (this.rx[1] << 16) | (this.rx[2] << 8) | this.rx[3];
      if (len === 0) {
        this.rx = this.rx.slice(4);
        SmbLog.warn(TAG, 'drop empty nbss frame');
        continue;
      }
      if (this.rx.length < 4 + len) {
        return undefined;
      }
      if (type !== 0x00) {
        SmbLog.warn(TAG, `unexpected nbss type=0x${type.toString(16)} len=${len}（445 上应恒为 0x00）`);
      }
      const frame: Uint8Array = this.rx.slice(4, 4 + len);
      this.rx = this.rx.slice(4 + len);
      return frame;
    }
    return undefined;
  }

  private drain(): void {
    if (this.resolver === undefined) {
      return;
    }
    const frame: Uint8Array | undefined = this.take();
    if (frame === undefined) {
      return;
    }
    const fn: (u: Uint8Array) => void = this.resolver;
    this.resolver = undefined;
    this.rejecter = undefined;
    fn(frame);
  }

  private flushError(err: SmbException): void {
    const fn: ((e: SmbException) => void) | undefined = this.rejecter;
    this.resolver = undefined;
    this.rejecter = undefined;
    if (fn !== undefined) {
      fn(err);
    }
  }

  async send(pdu: Uint8Array): Promise<void> {
    if (this.tcp === undefined) {
      throw new SmbException('连接未建立', -1);
    }
    if (this.dead.length > 0) {
      throw new SmbException(this.dead, -1);
    }
    const frame: Uint8Array = new Uint8Array(4 + pdu.length);
    frame[0] = 0;
    frame[1] = (pdu.length >>> 16) & 0xff;
    frame[2] = (pdu.length >>> 8) & 0xff;
    frame[3] = pdu.length & 0xff;
    frame.set(pdu, 4);
    try {
      await this.tcp.send({ data: Bin.ab(frame) });
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      this.dead = `发送失败(错误码 ${e.code})，连接可能已被对端重置`;
      SmbLog.warn(TAG, `send failed ${this.stats} code=${e.code}`);
      throw new SmbException(this.dead, e.code);
    }
    this.sentBytes += frame.length;
    SmbLog.info(TAG, `tx len=${frame.length} (nbss=4 payload=${pdu.length}) ${this.stats}`);
    SmbLog.dump(TAG, 'tx', frame);
  }

  async recv(timeoutMs: number): Promise<Uint8Array> {
    const buffered: Uint8Array | undefined = this.take();
    if (buffered !== undefined) {
      return buffered;
    }
    if (this.dead.length > 0) {
      throw new SmbException(this.dead, -1);
    }
    return new Promise<Uint8Array>((resolve: (u: Uint8Array) => void, reject: (e: SmbException) => void) => {
      let done: boolean = false;
      const timer: number = setTimeout(() => {
        if (done) {
          return;
        }
        done = true;
        this.resolver = undefined;
        this.rejecter = undefined;
        SmbLog.warn(TAG, `recv timeout ${this.stats}`);
        reject(new SmbException(`服务器无响应：在「${this.stage}」阶段等待 ${timeoutMs}ms 未收到任何 SMB2 报文` +
          `（${this.stats}）；请确认 445 未被中间设备丢弃。`, -2));
      }, timeoutMs);
      this.resolver = (u: Uint8Array) => {
        if (done) {
          return;
        }
        done = true;
        clearTimeout(timer);
        resolve(u);
      };
      this.rejecter = (e: SmbException) => {
        if (done) {
          return;
        }
        done = true;
        clearTimeout(timer);
        reject(e);
      };
      this.drain();
    });
  }

  async close(): Promise<void> {
    // 保留首个失败原因：连接失败后 close() 不应把「真实断链原因」覆盖成「连接已关闭」
    if (this.dead.length === 0) {
      this.dead = '连接已关闭';
    }
    if (this.tcp !== undefined) {
      const tcp: socket.TCPSocket = this.tcp;
      this.tcp = undefined;
      try {
        tcp.off('message');
      } catch (err) {
      }
      try {
        await tcp.close();
      } catch (err) {
      }
    }
  }
}

/** NTLM Type2 消息解析结果 */
class NtlmChallenge {
  serverChallenge: Uint8Array = new Uint8Array(8);
  targetInfo: Uint8Array = new Uint8Array(0);
  flags: number = 0;
  targetName: string = '';
}

/** SMB 状态码转中文提示 */
export function smbStatusText(status: number): string {
  if (status === 0xc0000022) {
    return '账号或密码错误，或该账号没有访问权限';
  }
  if (status === 0xc000006d || status === 0xc0000064 || status === 0xc000006a) {
    return '登录失败，请检查用户名与密码';
  }
  if (status === 0xc00000cc) {
    return '找不到该共享名，请确认共享目录名称';
  }
  if (status === 0xc000000f || status === 0xc0000034) {
    return '路径不存在';
  }
  if (status === 0xc00000ba) {
    return '不支持的操作（可能是只读共享）';
  }
  if (status === 0xc0000205 || status === 0xc000023c) {
    return '网络不可达，请检查网络连接';
  }
  if (status === 0xc0000178 || status === 0xc0000183) {
    return '账号未授权访问该共享';
  }
  if (status === 0xc00000bb) {
    return '服务器不支持该功能，通常是 SMB 方言不被接受（设备可能只开了 SMB1）';
  }
  if (status === 0xc000000d) {
    return '请求参数非法：服务器认为报文格式不符合 SMB2 规范';
  }
  if (status === 0xc00000c9 || status === 0xc0000203) {
    return '会话或共享连接已被服务器断开，需要重新连接';
  }
  if (status === 0xc0000128) {
    return '文件句柄已被服务器关闭';
  }
  if (status === 0xc0000016) {
    return '认证尚未完成（服务器要求继续交换认证消息）';
  }
  const hex: string = status.toString(16).toUpperCase();
  return `操作失败（0x${hex}）`;
}

/** smb:// 地址解析：兼容 smb://host/share/path、\\\\host\\share\\path、host/share/path */
export class SmbUrl {
  ok: boolean = false;
  host: string = '';
  port: number = 445;
  share: string = '';
  path: string = '';

  static parse(input: string): SmbUrl {
    const out: SmbUrl = new SmbUrl();
    let s: string = input.trim();
    if (s.length === 0) {
      return out;
    }
    const lower: string = s.toLowerCase();
    if (lower.startsWith('smb://')) {
      s = s.substring(6);
    } else if (lower.startsWith('cifs://')) {
      s = s.substring(7);
    }
    s = s.replace(/\\/g, '/');
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    if (s.length === 0) {
      return out;
    }
    const parts: string[] = s.split('/').filter((t: string) => t.length > 0);
    if (parts.length < 2) {
      return out;
    }
    let host: string = parts[0];
    let port: number = 445;
    const colon: number = host.indexOf(':');
    if (colon > 0) {
      const p: number = Number.parseInt(host.substring(colon + 1), 10);
      if (!Number.isNaN(p) && p > 0 && p < 65536) {
        port = p;
      }
      host = host.substring(0, colon);
    }
    if (host.length === 0 || parts[1].length === 0) {
      return out;
    }
    const rest: string[] = parts.slice(2);
    out.ok = true;
    out.host = host;
    out.port = port;
    out.share = parts[1];
    out.path = rest.join('/');
    return out;
  }

  /** 由基础地址 + 子项名拼出新的 smb 地址 */
  static join(base: SmbUrl, name: string): string {
    const path: string = base.path.length > 0 ? `${base.path}/${name}` : name;
    const portPart: string = base.port === 445 ? '' : `:${base.port}`;
    return `smb://${base.host}${portPart}/${base.share}/${path}`;
  }
}

/** 一个 SMB 会话（协商 + 认证 + 树连接），可反复列目录/读文件，用尽后 logoff */
export class SmbSession {
  private host: string;
  private port: number;
  private share: string;
  private user: string;
  private pass: string;
  private tr: SmbTransport = new SmbTransport();
  private sessionId: number = 0;
  private treeId: number = 0;
  private messageId: number = 0;
  private sessionKey: Uint8Array = new Uint8Array(0);
  private pendingKey: Uint8Array = new Uint8Array(0);
  private signing: boolean = false;
  /** 服务器 SecurityMode 是否强制签名（诊断用） */
  private signingRequired: boolean = false;
  /** 协商出的方言（诊断用） */
  private dialect: number = 0;
  private maxRead: number = 65536;
  private maxTransact: number = 65536;
  private timeoutMs: number = 12000;
  private connected: boolean = false;

  constructor(host: string, port: number, share: string, user: string, pass: string) {
    this.host = host;
    this.port = port > 0 ? port : 445;
    this.share = share;
    this.user = user;
    this.pass = pass;
  }

  get shareRoot(): string {
    return `\\\\${this.host}\\${this.share}`;
  }

  // ---------------- 连接流程 ----------------

  async connect(): Promise<void> {
    if (this.connected) {
      return;
    }
    try {
      this.tr.setStage(STAGE_CONNECT);
      await this.tr.open(this.host, this.port, 8000);
      try {
        // 首选集合只给 SMB 2.0.2 / 2.1：这两个方言的报文签名是 HMAC-SHA256，本实现完整支持
        this.tr.setStage(STAGE_NEGOTIATE);
        await this.negotiate(false);
      } catch (err) {
        const e: SmbException = err as SmbException;
        const dialectRejected: boolean = e.code === 0xc00000bb || e.code === 0xc000000d;
        if (!dialectRejected) {
          throw err as Error;
        }
        // 服务器不接受 2.x：换一条连接再以 2.0.2/2.1/3.0/3.0.2 升序重试（3.x 用明文+可选签名）
        SmbLog.warn(TAG, `negotiate rejected (0x${e.code.toString(16)}), retry with SMB3 dialects`);
        await this.tr.close();
        this.tr = new SmbTransport();
        await this.tr.open(this.host, this.port, 8000);
        this.tr.setStage(STAGE_NEGOTIATE);
        await this.negotiate(true);
      }
      this.tr.setStage(STAGE_SESSION);
      await this.authenticate();
      this.tr.setStage(STAGE_TREE);
      await this.treeConnect();
    } catch (err) {
      const e: Error = err as Error;
      SmbLog.warn(TAG, `connect aborted: ${e.message}`);
      await this.tr.close();
      throw err as Error;
    }
    this.connected = true;
    SmbLog.info(TAG, `connected ${this.host}:${this.port} share=${this.share} dialect=0x${this.dialect.toString(16)}`);
  }

  private async negotiate(allowSmb3: boolean): Promise<void> {
    // MS-SMB2 2.2.3：Dialects 必须**升序**排列。旧实现写成 0x0210/0x0202 降序，
    // 属协议违规（Windows 回 STATUS_INVALID_PARAMETER，部分 SMB 服务实现直接断链）。
    const dialects: number[] = allowSmb3 ? [0x0202, 0x0210, 0x0300, 0x0302] : [0x0202, 0x0210];
    const body: Buf = new Buf(36 + dialects.length * 2);
    body.u16(36);
    body.u16(dialects.length);
    body.u16(SMB2_NEGOTIATE_SIGNING_ENABLED);
    body.u16(0);              // Reserved
    body.u32(0);              // Capabilities
    body.raw(Bytes.random(16)); // ClientGuid
    // 后 8 字节：SMB2.0.2/2.1 视作 ClientStartTime(u64)；3.1.1 视作
    // NegotiateContextOffset(4)+NegotiateContextCount(2)+Reserved2(2)，这里统一置 0
    body.u32(0);              // ClientStartTime / NegotiateContextOffset
    body.u16(0);              // NegotiateContextCount
    body.u16(0);              // Reserved2
    for (let i = 0; i < dialects.length; i++) {
      body.u16(dialects[i]);
    }
    const reply: SmbReply = await this.call(CMD_NEGOTIATE, 0, 0, body.data(), false);
    if (reply.status !== STATUS_SUCCESS) {
      throw new SmbException(`协议协商失败：${smbStatusText(reply.status)}；` +
        `本次提供的方言为 ${dialects.map((d: number) => `0x${d.toString(16)}`).join('/')}` +
        `，若设备只支持 SMB1 需在 NAS 上开启 SMB2/SMB3`, reply.status);
    }
    const b: Uint8Array = reply.body;
    if (b.length < 64) {
      throw new SmbException(`协议协商响应格式异常（响应体仅 ${b.length} 字节，规范应至少 64 字节，` +
        `StructureSize 应为 65）`, -3);
    }
    const mode: number = Bin.u16(b, 2);
    const dialect: number = Bin.u16(b, 4);
    this.dialect = dialect;
    this.maxTransact = Bin.u32(b, 28);
    this.maxRead = Bin.u32(b, 32);
    if (this.maxRead <= 0 || this.maxRead > 1048576) {
      this.maxRead = 65536;
    }
    if (this.maxTransact <= 0) {
      this.maxTransact = 65536;
    }
    this.signingRequired = (mode & SMB2_NEGOTIATE_SIGNING_REQUIRED) !== 0;
    if (dialect >= 0x0300 && this.signingRequired) {
      // SMB3 的签名是 AES-CMAC + KDF 派生密钥，本实现只做了 SMB2.x 的 HMAC-SHA256，
      // 与其发出必然被拒的签名，不如在协商阶段就把原因说清楚。
      throw new SmbException('服务器强制要求 SMB3 报文签名/加密，当前实现仅支持 SMB2.1 签名；' +
        '请在 NAS 的 SMB 高级设置中关闭「强制签名 / 强制传输加密」，或把最高协议设为 SMB2', -9);
    }
    SmbLog.info(TAG, `negotiate ok dialect=0x${dialect.toString(16)} securityMode=0x${mode.toString(16)} ` +
      `maxRead=${this.maxRead} maxTransact=${this.maxTransact} signingRequired=${this.signingRequired}`);
  }

  /** NTLMv2 认证（含匿名/guest 兜底） */
  private async authenticate(): Promise<void> {
    SmbLog.info(TAG, `session setup begin user=${this.user.length > 0 ? this.maskedUser() : '(匿名)'}`);
    if (this.user.length === 0) {
      // 匿名：不带安全缓冲区，服务器若允许 guest 会直接通过
      const anon: Buf = new Buf(24);
      anon.u16(25);
      anon.u8(0);
      anon.u8(SMB2_NEGOTIATE_SIGNING_ENABLED);
      anon.u32(0);
      anon.u32(0);
      anon.u16(88);
      anon.u16(0);
      anon.u64(0);
      const r: SmbReply = await this.call(CMD_SESSION_SETUP, 0, 0, anon.data(), true);
      if (r.status === STATUS_SUCCESS) {
        this.readSession(r);
        return;
      }
      if (r.status !== STATUS_MORE_PROCESSING_REQUIRED) {
        throw new SmbException(`匿名访问被拒绝：${smbStatusText(r.status)}`, r.status);
      }
    }
    const type1: Uint8Array = this.buildNegTokenInit();
    SmbLog.dump(TAG, 'ntlm-type1', type1);
    const r1: SmbReply = await this.sessionSetup(type1);
    SmbLog.info(TAG, `session setup #1 status=0x${r1.status.toString(16)}`);
    if (r1.status !== STATUS_MORE_PROCESSING_REQUIRED && r1.status !== STATUS_SUCCESS) {
      throw new SmbException(`认证失败：${smbStatusText(r1.status)}`, r1.status);
    }
    if (r1.status === STATUS_SUCCESS) {
      this.readSession(r1);
      return;
    }
    const token: Uint8Array = this.sliceToken(r1.body, 4);
    SmbLog.dump(TAG, 'ntlm-type2', token);
    const challenge: NtlmChallenge | undefined = this.parseType2(token);
    if (challenge === undefined) {
      throw new SmbException('服务器认证消息无法解析（可能要求 NTLMv1/Kerberos，或服务端未开启 NTLM）', -4);
    }
    SmbLog.info(TAG, `type2 target=${challenge.targetName} flags=0x${challenge.flags.toString(16)} ` +
      `targetInfoLen=${challenge.targetInfo.length}`);
    const type3: Uint8Array = this.buildNegTokenResp(this.buildType3(challenge));
    SmbLog.dump(TAG, 'ntlm-type3', type3);
    const r2: SmbReply = await this.sessionSetup(type3);
    SmbLog.info(TAG, `session setup #2 status=0x${r2.status.toString(16)}`);
    if (r2.status !== STATUS_SUCCESS) {
      throw new SmbException(`登录失败：${smbStatusText(r2.status)}`, r2.status);
    }
    // 会话密钥与签名在认证成功后才生效（最后一次 SessionSetup 本身不签名）
    this.sessionKey = this.pendingKey;
    // SMB2.x 的签名是 HMAC-SHA256；SMB3 是 AES-CMAC（未实现），故只在 2.x 主动签名
    this.signing = this.sessionKey.length > 0 && this.dialect < 0x0300;
    this.readSession(r2);
  }

  /** 日志里只保留用户名首尾，避免把完整账号写进文件 */
  private maskedUser(): string {
    const u: string = this.userOf();
    if (u.length <= 2) {
      return `${u.charAt(0)}*`;
    }
    return `${u.charAt(0)}***${u.charAt(u.length - 1)}`;
  }

  private async sessionSetup(token: Uint8Array): Promise<SmbReply> {
    const total: number = 24 + token.length;
    const body: Buf = new Buf(total);
    body.u16(25);
    body.u8(0);
    body.u8(SMB2_NEGOTIATE_SIGNING_ENABLED);
    body.u32(0);
    body.u32(0);
    body.u16(88);
    body.u16(token.length);
    body.u64(0);
    body.raw(token);
    return this.call(CMD_SESSION_SETUP, 0, 0, body.data(), true);
  }

  private readSession(reply: SmbReply): void {
    const b: Uint8Array = reply.body;
    if (b.length >= 8) {
      const flags: number = Bin.u16(b, 2);
      if ((flags & 0x0001) !== 0) {
        hilog.info(DOMAIN_ID, TAG, 'guest session');
      }
    }
  }

  private sliceToken(body: Uint8Array, base: number): Uint8Array {
    if (body.length < 8) {
      return new Uint8Array(0);
    }
    const off: number = Bin.u16(body, base);
    const len: number = Bin.u16(body, base + 2);
    if (len === 0) {
      return new Uint8Array(0);
    }
    const start: number = off - 64;
    if (start < 0 || start + len > body.length) {
      return new Uint8Array(0);
    }
    return body.slice(start, start + len);
  }

  private async treeConnect(): Promise<void> {
    const unc: string = `\\\\${this.host}\\${this.share}`;
    SmbLog.info(TAG, `tree connect ${unc}`);
    const path: Uint8Array = Bytes.utf16le(unc);
    const body: Buf = new Buf(8 + path.length);
    body.u16(9);
    body.u16(0);
    body.u16(72);             // PathOffset：64(头) + 8(结构) = 72
    body.u16(path.length);
    body.raw(path);
    const reply: SmbReply = await this.call(CMD_TREE_CONNECT, 0, 0, body.data(), true);
    if (reply.status !== STATUS_SUCCESS) {
      // 0xc0000022 常见于「该共享只允许 SMB3 加密」或账号无共享权限
      throw new SmbException(`打开共享失败：${smbStatusText(reply.status)}（共享名 ${this.share}）`, reply.status);
    }
    this.treeId = reply.treeId;
    SmbLog.info(TAG, `tree connect ok treeId=${this.treeId}`);
  }

  // ---------------- 业务接口 ----------------

  /** 列目录（path 为共享内的相对路径，空串表示共享根） */
  async listDir(path: string): Promise<SmbDirEntry[]> {
    this.tr.setStage(STAGE_LIST);
    const rel: string = SmbSession.cleanPath(path);
    const open: SmbFileHandle = await this.create(SmbSession.dirName(rel), true);
    const out: SmbDirEntry[] = [];
    const pattern: Uint8Array = Bytes.utf16le('*');
    let first: boolean = true;
    for (let guard = 0; guard < 64; guard++) {
      const body: Buf = new Buf(32 + pattern.length);
      body.u16(33);
      body.u8(FILE_DIRECTORY_INFORMATION);
      body.u8(first ? 0x01 : 0x00);
      body.u32(0);            // FileIndex
      body.raw(open.id);      // FileId
      // MS-SMB2 2.2.26：FileNameOffset 是「相对 SMB2 头起始」的偏移，
      // 头 64 + 请求结构 32 = 96；旧实现写 0（且长度写 0），等于声明「没有搜索模板」，
      // 服务器按默认 * 处理，Windows 上通常不报错但语义错误、部分 NAS 会直接拒绝。
      body.u16(96);           // FileNameOffset
      body.u16(pattern.length); // FileNameLength
      body.u32(65536);        // OutputBufferLength
      body.raw(pattern);
      const reply: SmbReply = await this.call(CMD_QUERY_DIRECTORY, 0, this.treeId, body.data(), true);
      if (reply.status === STATUS_NO_MORE_FILES) {
        break;
      }
      if (reply.status !== STATUS_SUCCESS) {
        await this.closeFile(open);
        throw new SmbException(`读取目录失败：${smbStatusText(reply.status)}`, reply.status);
      }
      first = false;
      const before: number = out.length;
      this.parseDirEntries(reply.body, out);
      if (out.length === before) {
        break;
      }
    }
    await this.closeFile(open);
    out.sort((a: SmbDirEntry, b: SmbDirEntry) => {
      if (a.isDir !== b.isDir) {
        return a.isDir ? -1 : 1;
      }
      return a.name.localeCompare(b.name);
    });
    return out;
  }

  private parseDirEntries(body: Uint8Array, out: SmbDirEntry[]): void {
    if (body.length < 8) {
      return;
    }
    const outLen: number = Bin.u32(body, 4);
    const dataOff: number = Bin.u16(body, 2) - 64;
    if (dataOff < 0 || dataOff >= body.length) {
      return;
    }
    const end: number = Math.min(body.length, dataOff + outLen);
    let p: number = dataOff;
    while (p + 64 <= end) {
      const next: number = Bin.u32(body, p);
      const size: number = Bin.u64(body, p + 40);
      const attr: number = Bin.u32(body, p + 56);
      const nameLen: number = Bin.u32(body, p + 60);
      if (nameLen % 2 !== 0 || p + 64 + nameLen > end) {
        break;
      }
      const name: string = SmbSession.utf16leToString(body, p + 64, nameLen);
      if (!isSystemHiddenName(name)) {
        const isDir: boolean = (attr & 0x10) !== 0;
        out.push(new SmbDirEntry(name, isDir, size));
      }
      if (next === 0) {
        break;
      }
      p += next;
    }
  }

  /** 打开文件用于随机读 */
  async openFile(path: string): Promise<SmbFileHandle> {
    return this.create(SmbSession.cleanPath(path), false);
  }

  private async create(rel: string, isDir: boolean): Promise<SmbFileHandle> {
    this.tr.setStage(STAGE_OPEN);
    const path: string = rel;
    const nameBytes: Uint8Array = Bytes.utf16le(path);
    // Samba 校验 in_name_offset 与 input_buffer 长度（含 64 字节头）时边界判定严格：根目录
    // 名字为空时整报文恰好 120 字节，NameOffset=120 落在边界被判非法，返回 0xc000000d。
    // 故空名时让报文比 NameOffset 多 2 字节（'pad'），NameLength 仍为 0。
    const pad: number = nameBytes.length === 0 ? 2 : 0;
    const body: Buf = new Buf(56 + nameBytes.length + pad);
    body.u16(57);
    body.u8(0);
    body.u8(0);
    body.u32(2);              // ImpersonationLevel = Impersonation
    body.u64(0);              // SmbCreateFlags
    body.u64(0);              // Reserved
    body.u32(isDir ? 0x00000081 : 0x00000001); // DesiredAccess
    body.u32(0);              // FileAttributes
    body.u32(0x00000003);     // ShareAccess = READ | WRITE（去掉 DELETE 位）
    body.u32(1);              // CreateDisposition = FILE_OPEN
    body.u32(isDir ? 0x00000001 : 0x00000040); // CreateOptions
    // NameOffset 固定为请求体固定部分长度 120，即便根目录无名字也指向 Buffer 起点
    body.u16(120);
    body.u16(nameBytes.length);
    body.u32(0);              // CreateContextsOffset
    body.u32(0);              // CreateContextsLength
    body.raw(nameBytes);
    for (let k = 0; k < pad; k++) {
      body.u8(0);
    }
    SmbLog.info(TAG, `CREATE rel="${path}" chars=${path.length} nameBytes=${nameBytes.length} ` +
      `bodyLen=${body.data().length} shareAccess=0x3 offset=120`);
    const reply: SmbReply = await this.call(CMD_CREATE, 0, this.treeId, body.data(), true);
    if (reply.status !== STATUS_SUCCESS) {
      const what: string = isDir ? '打开目录失败' : '打开文件失败';
      throw new SmbException(`${what}：${smbStatusText(reply.status)}`, reply.status);
    }
    const b: Uint8Array = reply.body;
    if (b.length < 88) {
      throw new SmbException('打开文件响应异常', -5);
    }
    const size: number = Bin.u64(b, 48);
    const id: Uint8Array = b.slice(64, 80);
    return new SmbFileHandle(id, size, path);
  }

  /** 从 offset 读取最多 len 字节，返回实际读到的数据（可能因文件末尾而不足） */
  async readAt(file: SmbFileHandle, offset: number, len: number): Promise<Uint8Array> {
    this.tr.setStage(STAGE_READ);
    let want: number = len;
    if (want > this.maxRead) {
      want = this.maxRead;
    }
    const remain: number = file.size - offset;
    if (remain <= 0) {
      return new Uint8Array(0);
    }
    if (want > remain) {
      want = remain;
    }
    const body: Buf = new Buf(49);
    body.u16(49);
    body.u8(0);
    body.u8(0);
    body.u32(want);
    body.u64(offset);
    body.raw(file.id);
    body.u32(0);              // MinimumCount
    body.u32(0);              // Channel
    body.u32(0);              // RemainingBytes
    body.u16(0);              // ReadChannelInfoOffset
    body.u16(0);              // ReadChannelInfoLength
    body.u8(0);               // Buffer
    const reply: SmbReply = await this.call(CMD_READ, 0, this.treeId, body.data(), true);
    if (reply.status !== STATUS_SUCCESS) {
      throw new SmbException(`读取文件失败：${smbStatusText(reply.status)}`, reply.status);
    }
    const b: Uint8Array = reply.body;
    if (b.length < 16) {
      throw new SmbException('读取响应异常', -6);
    }
    const dataOff: number = Bin.u8(b, 2) - 64;
    const dataLen: number = Bin.u32(b, 4);
    if (dataLen === 0 || dataOff < 0 || dataOff >= b.length) {
      return new Uint8Array(0);
    }
    const end: number = Math.min(b.length, dataOff + dataLen);
    return b.slice(dataOff, end);
  }

  async closeFile(file: SmbFileHandle): Promise<void> {
    this.tr.setStage(STAGE_CLOSE);
    const body: Buf = new Buf(24);
    body.u16(24);
    body.u16(0);
    body.u32(0);
    body.raw(file.id);
    try {
      await this.call(CMD_CLOSE, 0, this.treeId, body.data(), true);
    } catch (err) {
      hilog.warn(DOMAIN_ID, TAG, 'close handle failed');
    }
  }

  async disconnect(): Promise<void> {
    if (this.connected) {
      const tree: Buf = new Buf(4);
      tree.u16(4);
      tree.u16(0);
      try {
        await this.call(CMD_TREE_DISCONNECT, 0, this.treeId, tree.data(), true);
      } catch (err) {
      }
      const off: Buf = new Buf(4);
      off.u16(4);
      off.u16(0);
      try {
        await this.call(CMD_LOGOFF, 0, 0, off.data(), true);
      } catch (err) {
      }
    }
    this.connected = false;
    await this.tr.close();
  }

  // ---------------- PDU 编解码 ----------------

  /**
   * 串行闸门：一条 TCP 连接上并发收发会把响应配错，多个播放连接同时读同一文件时
   * 必须把请求排成队列，逐个发完再发下一个。
   */
  private callGate: Promise<void> = Promise.resolve();

  /** 发送一个请求并等待对应响应，返回状态码与响应体 */
  private async call(command: number, flags: number, treeId: number, body: Uint8Array,
    useSession: boolean): Promise<SmbReply> {
    const prev: Promise<void> = this.callGate;
    let release: () => void = () => {
    };
    this.callGate = new Promise<void>((resolve: () => void) => {
      release = resolve;
    });
    await prev;
    try {
      return await this.callOnce(command, flags, treeId, body, useSession);
    } finally {
      release();
    }
  }

  private async callOnce(command: number, flags: number, treeId: number, body: Uint8Array,
    useSession: boolean): Promise<SmbReply> {
    const msgId: number = this.messageId;
    this.messageId += 1;
    let pduFlags: number = flags;
    if (this.signing && this.sessionKey.length > 0 && useSession) {
      pduFlags |= FLAG_SIGNED;
    }
    const total: number = 64 + body.length;
    const pdu: Uint8Array = new Uint8Array(total);
    const head: Buf = new Buf(64);
    head.u32(0x424d53fe);     // ProtocolId "\xfeSMB"
    head.u16(64);             // StructureSize
    head.u16(1);              // CreditCharge
    head.u32(0);              // Status / ChannelSequence
    head.u16(command);
    head.u16(1);              // CreditRequest
    head.u32(pduFlags);
    head.u32(0);              // NextCommand
    head.u64(msgId);
    head.u32(0);              // Reserved / ProcessId
    head.u32(treeId);
    head.u64(useSession ? this.sessionId : 0);
    head.zeros(16);           // Signature
    pdu.set(head.data(), 0);
    pdu.set(body, 64);
    if (pduFlags === (flags | FLAG_SIGNED)) {
      const mac: Uint8Array = SmbHash.hmacSha256(this.sessionKey, pdu);
      pdu.set(mac.slice(0, 16), 48);
    }
    await this.tr.send(pdu);
    let raw: Uint8Array = await this.tr.recv(this.timeoutMs);
    // Samba 对大块 READ 会先回 STATUS_PENDING 的「异步中间响应」，随后在同一 MessageId 上
    // 回最终响应；中间帧带 FLAG_ASYNC(0x1)、TreeId 位置换成 AsyncId。旧实现把 PENDING 当失败，
    // 表现为「目录能列出、点视频就播放错误」。此处循环丢弃中间帧，直到拿到最终响应。
    let pendingGuard: number = 0;
    while (raw.length >= 64 && Bin.u32(raw, 8) === 0x00000103 && pendingGuard < 16) {
      pendingGuard += 1;
      SmbLog.info(TAG, `async pending cmd=${command} msgId=${msgId} ` +
        `flags=0x${Bin.u32(raw, 16).toString(16)} wait#${pendingGuard}`);
      raw = await this.tr.recv(this.timeoutMs);
    }
    if (raw.length < 64) {
      throw new SmbException(`响应报文过短（${raw.length} 字节，不足 SMB2 头长度 64）` +
        `，阶段：${this.tr.stageName}`, -7);
    }
    if (raw[0] === 0xfd && raw[1] === 0x53 && raw[2] === 0x4d && raw[3] === 0x42) {
      // 0xFD 'SMB' 是 SMB3 的加密传输帧（Transform Header）
      throw new SmbException('服务器返回了加密报文（SMB3 传输加密已启用），' +
        '本实现不解析加密帧；请在 NAS 的共享高级设置中关闭「传输加密 / SMB3 encryption」', -10);
    }
    if (raw[0] !== 0xfe || raw[1] !== 0x53 || raw[2] !== 0x4d || raw[3] !== 0x42) {
      throw new SmbException(`响应不是 SMB2 报文（首字节 0x${raw[0].toString(16)}，` +
        `期望 0xfe 'SMB'），阶段：${this.tr.stageName}，` +
        `常见原因：对端是 SMB1-only 服务，或用 139 端口连到了非 SMB2 服务`, -8);
    }
    const reply: SmbReply = new SmbReply();
    reply.status = Bin.u32(raw, 8);
    const tid: number = Bin.u32(raw, 36);
    const sid: number = Bin.u64(raw, 40);
    if (sid !== 0) {
      this.sessionId = sid;
    }
    reply.treeId = tid;
    reply.body = raw.slice(64);
    if (reply.status !== STATUS_SUCCESS && reply.status !== STATUS_MORE_PROCESSING_REQUIRED) {
      SmbLog.info(TAG, `cmd=${command} status=0x${reply.status.toString(16)}`);
      SmbLog.dump(TAG, `resp cmd=${command}`, raw);
    }
    return reply;
  }

  // ---------------- NTLM 消息构造 ----------------

  /** NegotiateFlags：支持 Unicode / NTLM / NTLMv2 / 128 位会话密钥 / 目标信息 等 */
  /**
   * NegotiateFlags：只宣布本端真正实现的位。
   *
   * 旧值 0xa2888277 同时打开了 NEGOTIATE_VERSION(0x02000000) 和 SIGN/SEAL/LM_KEY，
   * 但 Type1/Type3 报文里并没有写 Version(8 字节) 字段（Type1 基线 32 字节、Type3 基线
   * 64 字节都是「无 Version」布局），于是「说带 Version、实际不给」——按 [MS-NLMP]
   * 这是报文结构自相矛盾，严格的服务器会把 Type3 判为非法并直接断开连接，正好对应
   * 「NAS 侧看不到登录失败日志、客户端只看到连接被关闭」的现象。
   * 这里改成不含 VERSION 的标准 NTLMv2 位集合（UNICODE|REQUEST_TARGET|NTLM|ALWAYS_SIGN|
   * EXTENDED_SESSIONSECURITY|TARGET_INFO|128|56），与报文实际布局一致。
   */
  private static readonly NTLM_FLAGS: number = 0xa08a8205 | 0;
  // 0xa08a8205 = UNICODE(0x1)|REQUEST_TARGET(0x4)|NTLM(0x200)|ALWAYS_SIGN(0x8000)
  //   |TARGET_INFO(0x20000)|EXT_SESSION_SECURITY(0x80000)|NTLM2_KEY(0x800000)
  //   |128(0x20000000)|56(0x80000000)；不含 VERSION(0x2000000)/KEY_EXCH(0x10000000)。
  // TARGET_INFO 必须声明：否则部分服务端（Samba/TrueNAS）不回 TargetInfo AV 对，
  // NTLMv2 blob 里就缺服务器时间戳/域信息，会被判为非 NTLMv2 报文而断链。

  private buildNegTokenInit(): Uint8Array {
    const type1: Uint8Array = this.buildType1();
    // OID_NTLMSSP 常量本身已是完整的 OBJECT IDENTIFIER TLV（06 0A ...），
    // 不可再用 Der.tlv(0x06, ...) 套一层，否则生成 06 0C 06 0A ... 的双重编码，
    // Samba 解析 SPNEGO mech 失败并回 STATUS_INVALID_PARAMETER(0xC000000D)。
    const mech: Uint8Array = fixedBytes(OID_NTLMSSP);
    const mechList: Uint8Array = Der.tlv(0x30, mech);
    const mechTypes: Uint8Array = Der.tlv(0xa0, mechList);
    const octet: Uint8Array = Der.tlv(0x04, type1);
    const payload: Uint8Array = Der.tlv(0xa2, octet);
    const initSeq: Uint8Array = Der.tlv(0x30, Bytes.concat(mechTypes, payload));
    const inner: Uint8Array = Der.tlv(0xa0, initSeq);
    const oid: Uint8Array = fixedBytes(OID_SPNEGO);
    return Der.tlv(0x60, Bytes.concat(oid, inner));
  }

  private buildNegTokenResp(type3: Uint8Array): Uint8Array {
    // NegTokenResp 不带 APPLICATION 0x60 外层（只有 NegTokenInit 才需要）；
    // 多包一层 0x60+OID 会让 Samba/fnOS 严格解析器直接回 STATUS_INVALID_PARAMETER(0xC000000D)
    const octet: Uint8Array = Der.tlv(0x04, type3);
    return Der.tlv(0xa1, Der.tlv(0x30, Der.tlv(0xa2, octet)));
  }

  private buildType1(): Uint8Array {
    const domainBytes: Uint8Array = Bytes.ascii(this.domainOf());
    const buf: Buf = new Buf(32 + domainBytes.length);
    buf.raw(Bytes.ascii('NTLMSSP'));
    buf.u8(0);
    buf.u32(1);
    buf.u32(SmbSession.NTLM_FLAGS);
    // DomainNameFields
    buf.u16(domainBytes.length);
    buf.u16(domainBytes.length);
    buf.u32(32);
    // WorkstationFields（留空）
    buf.u16(0);
    buf.u16(0);
    buf.u32(0);
    buf.raw(domainBytes);
    return buf.data();
  }

  private domainOf(): string {
    if (this.user.indexOf('\\') >= 0) {
      return this.user.substring(0, this.user.indexOf('\\'));
    }
    return '';
  }

  private userOf(): string {
    if (this.user.indexOf('\\') >= 0) {
      return this.user.substring(this.user.indexOf('\\') + 1);
    }
    if (this.user.indexOf('@') > 0) {
      return this.user.substring(0, this.user.indexOf('@'));
    }
    return this.user;
  }

  private parseType2(token: Uint8Array): NtlmChallenge | undefined {
    if (token.length < 48) {
      return undefined;
    }
    if (token[0] !== 0x4e || token[1] !== 0x54 || token[2] !== 0x4c || token[3] !== 0x4d) {
      // 可能外层还带 SPNEGO NegTokenResp，尝试定位 NTLMSSP 签名
      const idx: number = SmbSession.findSignature(token);
      if (idx < 0) {
        return undefined;
      }
      return this.parseType2(token.slice(idx));
    }
    const out: NtlmChallenge = new NtlmChallenge();
    out.flags = Bin.u32(token, 20);
    out.serverChallenge = token.slice(24, 32);
    if (token.length >= 48) {
      const tiLen: number = Bin.u16(token, 40);
      const tiOff: number = Bin.u32(token, 44);
      if (tiLen > 0 && tiOff + tiLen <= token.length) {
        out.targetInfo = token.slice(tiOff, tiOff + tiLen);
      }
    }
    if (token.length >= 20) {
      const tnLen: number = Bin.u16(token, 12);
      const tnOff: number = Bin.u32(token, 16);
      if (tnLen > 0 && tnOff + tnLen <= token.length) {
        out.targetName = SmbSession.utf16leToString(token, tnOff, tnLen);
      }
    }
    return out;
  }

  private static findSignature(u: Uint8Array): number {
    for (let i = 0; i + 8 <= u.length; i++) {
      if (u[i] === 0x4e && u[i + 1] === 0x54 && u[i + 2] === 0x4c && u[i + 3] === 0x4d &&
        u[i + 4] === 0x53 && u[i + 5] === 0x53 && u[i + 6] === 0x50 && u[i + 7] === 0x00) {
        return i;
      }
    }
    return -1;
  }

  /** 去掉 TargetInfo 末尾的 MsvAvEOL(4 个 0)，便于在其后追加本端 AV 对且整段只留一个终止符 */
  static stripAvEol(info: Uint8Array): Uint8Array {
    const n: number = info.length;
    if (n >= 4 && info[n - 4] === 0 && info[n - 3] === 0 && info[n - 2] === 0 && info[n - 1] === 0) {
      return info.slice(0, n - 4);
    }
    return info;
  }

  /** 构造 NTLMv2 Type3（同时算出 sessionBaseKey 存入 pendingKey） */
  private buildType3(challenge: NtlmChallenge): Uint8Array {
    const domain: string = this.domainOf().length > 0 ? this.domainOf() : challenge.targetName;
    const user: string = this.userOf();
    const workstation: string = CLIENT_NAME;
    // NTOWFv2 = HMAC_MD5(MD4(UNICODE(pass)), UNICODE(UPPER(user) + domain))
    const ntowf1: Uint8Array = SmbHash.md4(Bytes.utf16le(this.pass));
    const responseKey: Uint8Array = SmbHash.hmacMd5(ntowf1, Bytes.utf16le(user.toUpperCase() + domain));
    // NTLMv2 blob：01010000 + reserved + FILETIME + clientChallenge + reserved + AV pairs(以 EOL 结束)
    const clientChallenge: Uint8Array = Bytes.random(8);
    const blobHead: Buf = new Buf(28);
    blobHead.u32(0x01010000);
    blobHead.u32(0);
    blobHead.u64(SmbSession.fileTimeNow());
    blobHead.raw(clientChallenge);
    blobHead.u32(0);
    // AV 对只能有**一个**终止符：服务器给的 TargetInfo 自带末尾 EOL，
    // 旧实现先在自造 AV 对后写 EOL，再把服务器 TargetInfo 整段拼在后面，
    // 形成「EOL 之后还有 AV 对」的非法结构（服务器会忽略其后的时间戳 AV，
    // 严格实现甚至直接判为报文非法）。这里改成：服务器 TargetInfo（去掉尾部 EOL）
    // + 本端 NbDomainName / NbComputerName + 唯一 EOL。
    const serverInfo: Uint8Array = SmbSession.stripAvEol(challenge.targetInfo);
    const avPairs: Buf = new Buf(4 + domain.length * 2 + 4 + workstation.length * 2 + 4);
    avPairs.u16(2);           // MsvAvNbDomainName
    avPairs.u16(domain.length * 2);
    avPairs.raw(Bytes.utf16le(domain));
    avPairs.u16(1);           // MsvAvNbComputerName
    avPairs.u16(workstation.length * 2);
    avPairs.raw(Bytes.utf16le(workstation));
    avPairs.u32(0);           // MsvAvEOL（整段 AV 链的唯一终止符）
    const blob: Uint8Array = Bytes.concat(Bytes.concat(Bytes.concat(blobHead.data(), serverInfo),
      avPairs.data()), new Uint8Array(0));
    const ntProofInput: Uint8Array = Bytes.concat(challenge.serverChallenge, blob);
    const ntProof: Uint8Array = SmbHash.hmacMd5(responseKey, ntProofInput);
    const sessionKey: Uint8Array = SmbHash.hmacMd5(responseKey, ntProof);
    this.pendingKey = sessionKey;
    const ntResponse: Uint8Array = Bytes.concat(ntProof, blob);
    // LMv2：HMAC(key, serverChallenge + clientChallenge) + clientChallenge
    const lmResponse: Uint8Array = Bytes.concat(
      SmbHash.hmacMd5(responseKey, Bytes.concat(challenge.serverChallenge, clientChallenge)), clientChallenge);
    const domainBytes: Uint8Array = Bytes.utf16le(domain);
    const userBytes: Uint8Array = Bytes.utf16le(user);
    const wsBytes: Uint8Array = Bytes.utf16le(workstation);
    const base: number = 64;
    let cursor: number = base;
    const domainOff: number = cursor;
    cursor += domainBytes.length;
    const userOff: number = cursor;
    cursor += userBytes.length;
    const wsOff: number = cursor;
    cursor += wsBytes.length;
    const lmOff: number = cursor;
    cursor += lmResponse.length;
    const ntOff: number = cursor;
    cursor += ntResponse.length;
    const skOff: number = cursor;
    cursor += sessionKey.length;
    const buf: Buf = new Buf(cursor);
    buf.raw(Bytes.ascii('NTLMSSP'));
    buf.u8(0);
    buf.u32(3);
    buf.u16(lmResponse.length);
    buf.u16(lmResponse.length);
    buf.u32(lmOff);
    buf.u16(ntResponse.length);
    buf.u16(ntResponse.length);
    buf.u32(ntOff);
    buf.u16(domainBytes.length);
    buf.u16(domainBytes.length);
    buf.u32(domainOff);
    buf.u16(userBytes.length);
    buf.u16(userBytes.length);
    buf.u32(userOff);
    buf.u16(wsBytes.length);
    buf.u16(wsBytes.length);
    buf.u32(wsOff);
    buf.u16(sessionKey.length);
    buf.u16(sessionKey.length);
    buf.u32(skOff);
    buf.u32(SmbSession.NTLM_FLAGS);
    buf.raw(domainBytes);
    buf.raw(userBytes);
    buf.raw(wsBytes);
    buf.raw(lmResponse);
    buf.raw(ntResponse);
    buf.raw(sessionKey);
    return buf.data();
  }

  // ---------------- 工具 ----------------

  /** 当前时间的 FILETIME（100ns 自 1601-01-01，分为 hi/lo 两部分写） */
  static fileTimeNow(): number {
    return Date.now() * 10000 + 116444736000000000;
  }

  static cleanPath(path: string): string {
    let p: string = path.replace(/\//g, '\\');
    while (p.startsWith('\\')) {
      p = p.substring(1);
    }
    while (p.endsWith('\\')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  /** 目录路径补尾反斜杠（SMB2 要求目录名以 \ 结尾） */
  static dirName(rel: string): string {
    const p: string = SmbSession.cleanPath(rel);
    return p.length === 0 ? '' : `${p}\\`;
  }

  static utf16leToString(u: Uint8Array, offset: number, byteLen: number): string {
    let s: string = '';
    for (let i = 0; i + 1 < byteLen; i += 2) {
      s += String.fromCharCode(u[offset + i] | (u[offset + i + 1] << 8));
    }
    return s;
  }
}