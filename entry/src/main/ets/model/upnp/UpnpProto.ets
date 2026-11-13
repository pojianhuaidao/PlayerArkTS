/** UPnP/DLNA 用到的 XML 与协议基础件：轻量 XML 解析、SOAP 封装、DIDL-Lite 解析 */

/** 解析后的一个 XML 元素 */
export class XmlNode {
  /** 原始标签名（含命名空间前缀，如 d:title） */
  rawName: string = '';
  /** 去掉前缀的本地名（小写，用于匹配） */
  name: string = '';
  attrs: Map<string, string> = new Map<string, string>();
  children: XmlNode[] = [];
  texts: string[] = [];

  constructor(rawName: string) {
    this.rawName = rawName;
    const colon: number = rawName.indexOf(':');
    this.name = (colon >= 0 ? rawName.substring(colon + 1) : rawName).toLowerCase();
  }

  /** 属性值（属性名按本地名匹配，忽略命名空间前缀） */
  attr(key: string): string {
    const direct: string | undefined = this.attrs.get(key);
    if (direct !== undefined) {
      return direct;
    }
    const lower: string = key.toLowerCase();
    let found: string = '';
    this.attrs.forEach((value: string, name: string) => {
      const colon: number = name.indexOf(':');
      const local: string = (colon >= 0 ? name.substring(colon + 1) : name).toLowerCase();
      if (local === lower && found.length === 0) {
        found = value;
      }
    });
    return found;
  }

  /** 直接文本内容（已去首尾空白） */
  text(): string {
    return this.texts.join('').trim();
  }

  /** 第一个同名子元素 */
  child(tag: string): XmlNode | undefined {
    const lower: string = tag.toLowerCase();
    for (let i = 0; i < this.children.length; i++) {
      if (this.children[i].name === lower) {
        return this.children[i];
      }
    }
    return undefined;
  }

  /** 同名子元素全收集 */
  all(tag: string): XmlNode[] {
    const lower: string = tag.toLowerCase();
    return this.children.filter((n: XmlNode) => n.name === lower);
  }

  /** 深层查找第一个同名后代 */
  find(tag: string): XmlNode | undefined {
    const lower: string = tag.toLowerCase();
    for (let i = 0; i < this.children.length; i++) {
      const node: XmlNode = this.children[i];
      if (node.name === lower) {
        return node;
      }
      const deeper: XmlNode | undefined = node.find(lower);
      if (deeper !== undefined) {
        return deeper;
      }
    }
    return undefined;
  }

  /** 深层查找全部同名后代 */
  findAll(tag: string): XmlNode[] {
    const lower: string = tag.toLowerCase();
    const out: XmlNode[] = [];
    for (let i = 0; i < this.children.length; i++) {
      const node: XmlNode = this.children[i];
      if (node.name === lower) {
        out.push(node);
      }
      const deeper: XmlNode[] = node.findAll(lower);
      for (let k = 0; k < deeper.length; k++) {
        out.push(deeper[k]);
      }
    }
    return out;
  }

  /** 指定后代标签的文本（找不到返回空串） */
  valueOf(tag: string): string {
    const node: XmlNode | undefined = this.find(tag);
    return node === undefined ? '' : node.text();
  }
}

/** XML 文档（容错解析：跳过声明/注释/DTD，非法片段忽略） */
export class XmlDoc {
  root: XmlNode | undefined = undefined;
  error: string = '';

  static parse(text: string): XmlDoc {
    const doc: XmlDoc = new XmlDoc();
    if (text.length === 0) {
      doc.error = '空文档';
      return doc;
    }
    const stack: XmlNode[] = [];
    let i: number = 0;
    const n: number = text.length;
    while (i < n) {
      const lt: number = text.indexOf('<', i);
      if (lt < 0) {
        XmlDoc.addText(stack, text.substring(i));
        break;
      }
      if (lt > i) {
        XmlDoc.addText(stack, text.substring(i, lt));
      }
      const gt: number = text.indexOf('>', lt);
      if (gt < 0) {
        break;
      }
      const inner: string = text.substring(lt + 1, gt);
      i = gt + 1;
      if (inner.length === 0) {
        continue;
      }
      if (inner.startsWith('?') || inner.startsWith('!')) {
        if (inner.startsWith('![CDATA[')) {
          const close: number = text.indexOf(']]>', i);
          const cdata: string = close < 0 ? text.substring(i) : text.substring(i, close);
          XmlDoc.addText(stack, cdata);
          i = close < 0 ? n : close + 3;
        }
        continue;
      }
      if (inner.startsWith('/')) {
        if (stack.length > 0) {
          stack.pop();
        }
        continue;
      }
      const selfClose: boolean = inner.endsWith('/');
      const body: string = selfClose ? inner.substring(0, inner.length - 1) : inner;
      const node: XmlNode = XmlDoc.makeNode(body);
      if (stack.length === 0) {
        if (doc.root === undefined) {
          doc.root = node;
        }
      } else {
        stack[stack.length - 1].children.push(node);
      }
      if (!selfClose) {
        stack.push(node);
      }
    }
    if (doc.root === undefined) {
      doc.error = '未找到根元素';
    }
    return doc;
  }

  private static addText(stack: XmlNode[], raw: string): void {
    if (stack.length === 0) {
      return;
    }
    const decoded: string = XmlDoc.decode(raw);
    if (decoded.length === 0) {
      return;
    }
    stack[stack.length - 1].texts.push(decoded);
  }

  private static makeNode(body: string): XmlNode {
    let space: number = -1;
    for (let i = 0; i < body.length; i++) {
      const c: string = body.charAt(i);
      if (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
        space = i;
        break;
      }
    }
    const name: string = space < 0 ? body : body.substring(0, space);
    const node: XmlNode = new XmlNode(name.trim());
    if (space >= 0) {
      const rest: string = body.substring(space);
      XmlDoc.parseAttrs(node, rest);
    }
    return node;
  }

  private static parseAttrs(node: XmlNode, rest: string): void {
    let i: number = 0;
    while (i < rest.length) {
      const eq: number = rest.indexOf('=', i);
      if (eq < 0) {
        return;
      }
      const key: string = rest.substring(i, eq).trim();
      let quoteStart: number = eq + 1;
      while (quoteStart < rest.length && (rest.charAt(quoteStart) === ' ' ||
        rest.charAt(quoteStart) === '\t' || rest.charAt(quoteStart) === '\n')) {
        quoteStart++;
      }
      const quote: string = rest.charAt(quoteStart);
      if (quote !== '"' && quote !== '\'') {
        i = eq + 1;
        continue;
      }
      const end: number = rest.indexOf(quote, quoteStart + 1);
      if (end < 0) {
        return;
      }
      const value: string = XmlDoc.decode(rest.substring(quoteStart + 1, end));
      if (key.length > 0) {
        node.attrs.set(key, value);
      }
      i = end + 1;
    }
  }

  /** 实体解码（含数字实体） */
  static decode(raw: string): string {
    if (raw.indexOf('&') < 0) {
      return raw;
    }
    let out: string = raw;
    out = out.replace(/&lt;/g, '<');
    out = out.replace(/&gt;/g, '>');
    out = out.replace(/&quot;/g, '"');
    out = out.replace(/&apos;/g, '\'');
    out = out.replace(/&#(\d+);/g, (match: string, dec: string) => String.fromCharCode(Number.parseInt(dec, 10)));
    out = out.replace(/&#x([0-9a-fA-F]+);/g, (match: string, hex: string) => String.fromCharCode(Number.parseInt(hex, 16)));
    out = out.replace(/&amp;/g, '&');
    return out;
  }

  /** 供 SOAP/XML 拼装时转义 */
  static escape(raw: string): string {
    return raw.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
  }
}

/** UPnP 服务标识 */
export class UpnpServiceIds {
  static readonly CONTENT_DIRECTORY: string = 'ContentDirectory';
  static readonly AV_TRANSPORT: string = 'AVTransport';
  static readonly RENDERING_CONTROL: string = 'RenderingControl';
  static readonly CONNECTION_MANAGER: string = 'ConnectionManager';
}

/** 一个 UPnP 服务（含控制地址） */
export class UpnpService {
  serviceType: string = '';
  serviceId: string = '';
  controlURL: string = '';
  eventURL: string = '';
  scpdURL: string = '';

  /** 服务类型里的短名，如 ContentDirectory */
  get shortName(): string {
    const parts: string[] = this.serviceType.split(':');
    return parts.length >= 4 ? parts[3] : this.serviceType;
  }

  get isContentDirectory(): boolean {
    return this.serviceType.indexOf(UpnpServiceIds.CONTENT_DIRECTORY) >= 0;
  }

  get isAvTransport(): boolean {
    return this.serviceType.indexOf(UpnpServiceIds.AV_TRANSPORT) >= 0;
  }

  get isRenderingControl(): boolean {
    return this.serviceType.indexOf(UpnpServiceIds.RENDERING_CONTROL) >= 0;
  }
}

/** 发现到的一台设备 */
export class UpnpDevice {
  udn: string = '';
  friendlyName: string = '';
  modelName: string = '';
  deviceType: string = '';
  location: string = '';
  /** SSDP 响应里的 SERVER 头，诊断用 */
  server: string = '';
  /** 由 LOCATION 推出的 base（去掉最后一段文件名） */
  baseUrl: string = '';
  /** 设备的 IP（从 LOCATION 提取，用于显示与排序） */
  ip: string = '';
  services: UpnpService[] = [];

  get isMediaServer(): boolean {
    return this.deviceType.indexOf('MediaServer') >= 0;
  }

  get isMediaRenderer(): boolean {
    return this.deviceType.indexOf('MediaRenderer') >= 0;
  }

  get contentDirectory(): UpnpService | undefined {
    return this.services.find((s: UpnpService) => s.isContentDirectory);
  }

  get avTransport(): UpnpService | undefined {
    return this.services.find((s: UpnpService) => s.isAvTransport);
  }

  get renderingControl(): UpnpService | undefined {
    return this.services.find((s: UpnpService) => s.isRenderingControl);
  }

  /** 列表展示副标题 */
  get subtitle(): string {
    const parts: string[] = [];
    if (this.modelName.length > 0) {
      parts.push(this.modelName);
    }
    if (this.ip.length > 0) {
      parts.push(this.ip);
    }
    return parts.join(' · ');
  }
}

/** SOAP 请求封装（UPnP 用 SOAP 1.1 + action 头） */
export class SoapRequest {
  action: string = '';
  serviceType: string = '';
  body: string = '';

  /** 组装完整 XML */
  envelope(): string {
    return '<?xml version="1.0" encoding="utf-8"?>' +
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ' +
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">' +
      '<s:Body>' +
      `<u:${this.action} xmlns:u="${this.serviceType}">` +
      this.body +
      `</u:${this.action}>` +
      '</s:Body></s:Envelope>';
  }

  /** SOAPAction 头 */
  soapAction(): string {
    return `"${this.serviceType}#${this.action}"`;
  }
}

/** DIDL-Lite 里的一条对象（目录或媒体） */
export class DidlItem {
  id: string = '';
  parentId: string = '';
  title: string = '';
  /** item / container / videoItem / audioItem / imageItem */
  upnpClass: string = '';
  /** 可直接播放的资源地址 */
  url: string = '';
  /** 资源大小（字节，未知为 -1） */
  size: number = -1;
  /** 时长（秒，未知为 -1） */
  duration: number = -1;
  protocolInfo: string = '';
  thumbUrl: string = '';
  artist: string = '';
  album: string = '';
  /** 文件扩展名 */
  ext: string = '';

  get isContainer(): boolean {
    return this.upnpClass.indexOf('container') >= 0 || this.upnpClass.length === 0;
  }

  get isVideo(): boolean {
    if (this.upnpClass.indexOf('videoItem') >= 0) {
      return true;
    }
    const p: string = this.protocolInfo.toLowerCase();
    return p.indexOf('video') >= 0;
  }

  get sizeText(): string {
    if (this.size <= 0) {
      return '';
    }
    if (this.size >= 1024 * 1024 * 1024) {
      return `${(this.size / (1024 * 1024 * 1024)).toFixed(2)} GB`;
    }
    if (this.size >= 1024 * 1024) {
      return `${(this.size / (1024 * 1024)).toFixed(1)} MB`;
    }
    if (this.size >= 1024) {
      return `${(this.size / 1024).toFixed(0)} KB`;
    }
    return `${this.size} B`;
  }

  get durationText(): string {
    if (this.duration <= 0) {
      return '';
    }
    const total: number = Math.floor(this.duration);
    const h: number = Math.floor(total / 3600);
    const m: number = Math.floor((total % 3600) / 60);
    const s: number = total % 60;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const ss: string = s < 10 ? `0${s}` : `${s}`;
    return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
  }
}

/** Browse 结果 */
export class BrowseResult {
  items: DidlItem[] = [];
  totalMatches: number = 0;
  numberReturned: number = 0;
}

/** DIDL-Lite 解析 */
export class DidlParser {
  /** 解析 Browse 的 SOAP 应答，取出 DIDL-Lite 字符串再解析 */
  static parseEnvelope(xml: string, baseUrl: string): BrowseResult {
    const result: BrowseResult = new BrowseResult();
    const doc: XmlDoc = XmlDoc.parse(xml);
    if (doc.root === undefined) {
      return result;
    }
    const totalNode: XmlNode | undefined = doc.root.find('TotalMatches');
    if (totalNode !== undefined) {
      const n: number = Number.parseInt(totalNode.text(), 10);
      if (!Number.isNaN(n)) {
        result.totalMatches = n;
      }
    }
    const returnedNode: XmlNode | undefined = doc.root.find('NumberReturned');
    if (returnedNode !== undefined) {
      const n: number = Number.parseInt(returnedNode.text(), 10);
      if (!Number.isNaN(n)) {
        result.numberReturned = n;
      }
    }
    const resultNode: XmlNode | undefined = doc.root.find('Result');
    const inner: string = resultNode === undefined ? '' : resultNode.text();
    if (inner.length === 0) {
      return result;
    }
    result.items = DidlParser.parseDidl(inner, baseUrl);
    if (result.numberReturned === 0) {
      result.numberReturned = result.items.length;
    }
    if (result.totalMatches === 0) {
      result.totalMatches = result.items.length;
    }
    return result;
  }

  /** 解析 DIDL-Lite 文档 */
  static parseDidl(xml: string, baseUrl: string): DidlItem[] {
    const doc: XmlDoc = XmlDoc.parse(xml);
    if (doc.root === undefined) {
      return [];
    }
    const nodes: XmlNode[] = doc.root.findAll('container').concat(doc.root.findAll('item'));
    const out: DidlItem[] = [];
    for (let i = 0; i < nodes.length; i++) {
      const node: XmlNode = nodes[i];
      const item: DidlItem = new DidlItem();
      item.id = node.attr('id');
      item.parentId = node.attr('parentID');
      item.title = node.valueOf('title');
      item.upnpClass = node.valueOf('class');
      item.artist = node.valueOf('artist');
      item.album = node.valueOf('album');
      item.thumbUrl = DidlParser.abs(node.valueOf('albumArtURI'), baseUrl);
      const res: XmlNode | undefined = node.child('res');
      if (res !== undefined) {
        item.url = DidlParser.abs(res.text(), baseUrl);
        item.protocolInfo = res.attr('protocolInfo');
        const size: number = Number.parseInt(res.attr('size'), 10);
        if (!Number.isNaN(size)) {
          item.size = size;
        }
        item.duration = DidlParser.durationOf(res.attr('duration'));
      }
      if (item.title.length === 0) {
        const last: number = item.url.lastIndexOf('/');
        item.title = item.url.length > 0 ? item.url.substring(last + 1) : '(未命名)';
      }
      const dot: number = item.title.lastIndexOf('.');
      if (dot > 0) {
        item.ext = item.title.substring(dot + 1).toLowerCase();
      } else {
        const slash: number = item.url.lastIndexOf('.');
        if (slash > 0) {
          item.ext = item.url.substring(slash + 1).toLowerCase();
        }
      }
      out.push(item);
    }
    return out;
  }

  /** 相对地址补全 */
  static abs(url: string, baseUrl: string): string {
    const trimmed: string = url.trim();
    if (trimmed.length === 0) {
      return '';
    }
    const lower: string = trimmed.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return trimmed;
    }
    if (trimmed.startsWith('//')) {
      return `http:${trimmed}`;
    }
    if (trimmed.startsWith('/')) {
      const origin: string = DidlParser.originOf(baseUrl);
      return `${origin}${trimmed}`;
    }
    return `${baseUrl}${trimmed}`;
  }

  /** 从任意 URL 取 scheme://host:port */
  static originOf(url: string): string {
    const idx: number = url.indexOf('://');
    if (idx < 0) {
      return url;
    }
    const head: string = url.substring(0, idx + 3);
    const rest: string = url.substring(idx + 3);
    const slash: number = rest.indexOf('/');
    return slash < 0 ? url : `${head}${rest.substring(0, slash)}`;
  }

  /** 从 URL 取上一级目录（拼相对资源用） */
  static dirOf(url: string): string {
    const q: number = url.indexOf('?');
    const clean: string = q >= 0 ? url.substring(0, q) : url;
    const slash: number = clean.lastIndexOf('/');
    return slash < 0 ? clean : clean.substring(0, slash + 1);
  }

  /** UPnP duration 形如 0:01:23.000 / 01:23:45 → 秒 */
  static durationOf(text: string): number {
    if (text.length === 0) {
      return -1;
    }
    const parts: string[] = text.trim().split(':');
    if (parts.length < 2) {
      return -1;
    }
    let seconds: number = 0;
    for (let i = 0; i < parts.length; i++) {
      const v: number = Number.parseFloat(parts[i]);
      if (Number.isNaN(v)) {
        return -1;
      }
      seconds = seconds * 60 + v;
    }
    return Math.round(seconds);
  }
}
