/**
 * 一台已保存的局域网服务器（HTTP 目录 / WebDAV）。
 * 与"最近连接"历史区分：历史只是地址串，服务器是可命名、可长期保留的入口。
 */
export class NetServer {
  /** 显示名（用户可改，默认取主机名或地址） */
  name: string;
  /** 完整地址（含协议头，目录建议带尾斜杠） */
  url: string;
  /** 0=HTTP 目录/直链，1=WebDAV，2=SMB 共享 */
  proto: number;
  /** WebDAV 账号 */
  user: string;
  /** WebDAV 密码（持久化前做 base64 混淆） */
  pass: string;

  constructor(name: string, url: string, proto: number, user: string, pass: string) {
    this.name = name;
    this.url = url;
    this.proto = proto;
    this.user = user;
    this.pass = pass;
  }

  /** 去重用键：协议 + 地址 */
  key(): string {
    return `${this.proto}|${this.url}`;
  }

  protoLabel(): string {
    if (this.proto === 2) {
      return 'SMB';
    }
    return this.proto === 1 ? 'WebDAV' : 'HTTP';
  }

  /** 卡片副标题：主机 + 路径 */
  subtitle(): string {
    return this.url.replace(/^[a-zA-Z][a-zA-Z0-9+.\-]*:\/\//, '');
  }

  toJson(): string {
    return JSON.stringify({ n: this.name, u: this.url, p: this.proto, a: this.user, s: this.pass });
  }

  static fromJson(text: string): NetServer | undefined {
    try {
      const raw: Record<string, ESObject> = JSON.parse(text) as Record<string, ESObject>;
      const url: ESObject = raw['u'];
      if (typeof url !== 'string' || (url as string).length === 0) {
        return undefined;
      }
      const name: ESObject = raw['n'];
      const proto: ESObject = raw['p'];
      const user: ESObject = raw['a'];
      const pass: ESObject = raw['s'];
      return new NetServer(
        typeof name === 'string' ? name as string : '',
        url as string,
        typeof proto === 'number' ? proto as number : 0,
        typeof user === 'string' ? user as string : '',
        typeof pass === 'string' ? pass as string : ''
      );
    } catch (err) {
      return undefined;
    }
  }
}
