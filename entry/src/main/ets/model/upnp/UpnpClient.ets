import { http, socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NetClient, NetResult } from '../NetClient';
import { BrowseResult, DidlItem, DidlParser, SoapRequest, UpnpDevice, UpnpService, XmlDoc, XmlNode } from './UpnpProto';

const DOMAIN: number = 0x0001;
const TAG: string = 'UpnpClient';
/** SSDP 组播地址与端口 */
const SSDP_HOST: string = '239.255.255.250';
const SSDP_PORT: number = 1900;
/** 设备类型：媒体服务器（浏览）与媒体渲染器（投屏） */
export const ST_MEDIA_SERVER: string = 'urn:schemas-upnp-org:device:MediaServer:1';
export const ST_MEDIA_RENDERER: string = 'urn:schemas-upnp-org:device:MediaRenderer:1';
export const ST_ALL: string = 'ssdp:all';

/** 一条原始 SSDP 响应 */
export class SsdpHit {
  location: string = '';
  st: string = '';
  usn: string = '';
  server: string = '';
  address: string = '';
  raw: string = '';
}

/** SSDP 搜到的设备（描述还没拉）：给 UI 显示「发现中」用 */
export class UpnpCandidate {
  location: string = '';
  usn: string = '';
  server: string = '';
  ip: string = '';

  get udn(): string {
    const idx: number = this.usn.indexOf('::');
    return idx >= 0 ? this.usn.substring(0, idx) : this.usn;
  }
}

/** 一次 Browse 的额外上下文（分页） */
export class BrowsePage {
  result: BrowseResult = new BrowseResult();
  startIndex: number = 0;
  requested: number = 0;

  get hasMore(): boolean {
    return this.startIndex + this.result.items.length < this.result.totalMatches;
  }
}

export class UpnpClient {
  /** 最近一次错误，供 UI 展示 */
  private static lastError: string = '';

  static get errorText(): string {
    return UpnpClient.lastError;
  }

  // ---------------- SSDP 发现 ----------------

  /**
   * M-SEARCH 发现。先按目标设备类型搜，再用 ssdp:all 兜底（有些老 NAS 只回 ssdp:all）。
   * kind='server' 找 MediaServer，kind='renderer' 找 MediaRenderer。
   */
  static async discover(targetType: string, timeoutMs: number): Promise<UpnpCandidate[]> {
    UpnpClient.lastError = '';
    const hits: SsdpHit[] = [];
    const udp: socket.UDPSocket = socket.constructUDPSocketInstance();
    let bound: boolean = false;
    try {
      bound = await UpnpClient.bindUdp(udp);
      if (!bound) {
        UpnpClient.lastError = '无法创建 UDP 套接字用于 SSDP 搜索';
        return [];
      }
      udp.on('message', (info: socket.SocketMessageInfo) => {
        const text: string = UpnpClient.bytesToText(new Uint8Array(info.message));
        const hit: SsdpHit | undefined = UpnpClient.parseResponse(text);
        if (hit === undefined) {
          return;
        }
        if (info.remoteInfo !== undefined && info.remoteInfo.address !== undefined) {
          hit.address = info.remoteInfo.address;
        }
        hits.push(hit);
      });
      const watching: Promise<void> = UpnpClient.watchWindow(udp, hits, targetType, timeoutMs);
      await watching;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      UpnpClient.lastError = `SSDP 搜索失败（${e.code}）`;
      hilog.error(DOMAIN, TAG, 'ssdp failed %{public}d', e.code);
    } finally {
      await udp.close().catch(() => {
      });
    }
    const out: UpnpCandidate[] = UpnpClient.dedup(hits);
    if (out.length === 0 && UpnpClient.lastError.length === 0) {
      UpnpClient.lastError = '未发现设备：请确认设备与本机在同一网段且未开启「禁止局域网发现」';
    }
    hilog.info(DOMAIN, TAG, 'ssdp found %{public}d device(s)', out.length);
    return out;
  }

  private static async bindUdp(udp: socket.UDPSocket): Promise<boolean> {
    try {
      await udp.bind({ address: '0.0.0.0', port: 0, family: 1 });
      await udp.setExtraOptions({ broadcast: true, reuseAddress: true }).catch(() => {
      });
      return true;
    } catch (err) {
      try {
        await udp.bind({ address: '0.0.0.0', port: 51234, family: 1 });
        return true;
      } catch (err2) {
        return false;
      }
    }
  }

  /** 发 M-SEARCH 并在窗口期内收集响应 */
  private static async watchWindow(udp: socket.UDPSocket, hits: SsdpHit[], targetType: string,
    timeoutMs: number): Promise<void> {
    const msearch: string = UpnpClient.msearchText(targetType);
    const group: socket.NetAddress = { address: SSDP_HOST, port: SSDP_PORT, family: 1 };
    const sendOnce = async (payload: string): Promise<void> => {
      await udp.send({ data: payload, address: group }).catch((err: BusinessError) => {
        UpnpClient.lastError = `SSDP 组播发送失败（${err.code}），网络可能禁止了组播`;
      });
    };
    await sendOnce(msearch);
    // 1.2 秒后补一轮按 ssdp:all 与重复发送（UDP 会丢包）
    await UpnpClient.sleep(1200);
    if (hits.length === 0 && targetType !== ST_ALL) {
      await sendOnce(UpnpClient.msearchText(ST_ALL));
    }
    await sendOnce(msearch);
    const remain: number = timeoutMs - 1400;
    await UpnpClient.sleep(remain > 500 ? remain : 700);
  }

  private static msearchText(targetType: string): string {
    const lines: string[] = [
      'M-SEARCH * HTTP/1.1',
      `HOST: ${SSDP_HOST}:${SSDP_PORT}`,
      'MAN: "ssdp:discover"',
      'MX: 2',
      `ST: ${targetType}`,
      'USER-AGENT: ArkTS/1.0 UPnP/1.0 Player/1.0',
      '', ''
    ];
    return lines.join('\r\n');
  }

  private static parseResponse(text: string): SsdpHit | undefined {
    if (text.indexOf('200 OK') < 0 && text.indexOf('200 ok') < 0) {
      return undefined;
    }
    const hit: SsdpHit = new SsdpHit();
    hit.raw = text;
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].replace('\r', '').trim();
      const colon: number = line.indexOf(':');
      if (colon <= 0) {
        continue;
      }
      const key: string = line.substring(0, colon).trim().toLowerCase();
      const value: string = line.substring(colon + 1).trim();
      if (key === 'location') {
        hit.location = value;
      } else if (key === 'st') {
        hit.st = value;
      } else if (key === 'usn') {
        hit.usn = value;
      } else if (key === 'server') {
        hit.server = value;
      }
    }
    if (hit.location.length === 0) {
      return undefined;
    }
    return hit;
  }

  private static dedup(hits: SsdpHit[]): UpnpCandidate[] {
    const map: Map<string, UpnpCandidate> = new Map<string, UpnpCandidate>();
    for (let i = 0; i < hits.length; i++) {
      const hit: SsdpHit = hits[i];
      const cand: UpnpCandidate = new UpnpCandidate();
      cand.location = hit.location;
      cand.usn = hit.usn;
      cand.server = hit.server;
      cand.ip = UpnpClient.ipOf(hit.location);
      const key: string = hit.usn.length > 0 ? hit.usn : hit.location;
      const exists: UpnpCandidate | undefined = map.get(key);
      if (exists === undefined) {
        map.set(key, cand);
      }
    }
    const out: UpnpCandidate[] = [];
    map.forEach((value: UpnpCandidate) => {
      out.push(value);
    });
    return out;
  }

  /** 从 URL 里挖 IP（UDP 的 remoteInfo 有时是组播地址，不可靠） */
  static ipOf(url: string): string {
    const idx: number = url.indexOf('://');
    if (idx < 0) {
      return '';
    }
    const rest: string = url.substring(idx + 3);
    const slash: number = rest.indexOf('/');
    const hostPort: string = slash < 0 ? rest : rest.substring(0, slash);
    const colon: number = hostPort.indexOf(':');
    return colon < 0 ? hostPort : hostPort.substring(0, colon);
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private static bytesToText(bytes: Uint8Array): string {
    let out: string = '';
    for (let i = 0; i < bytes.length; i++) {
      out += String.fromCharCode(bytes[i]);
    }
    return out;
  }

  // ---------------- 设备描述 ----------------

  /** 拉 device description，补齐名称/型号/服务控制地址 */
  static async describe(candidate: UpnpCandidate): Promise<UpnpDevice | undefined> {
    const res: NetResult = await NetClient.fetch(candidate.location, 6000);
    if (!res.ok || res.body.length === 0) {
      UpnpClient.lastError = res.message.length > 0 ? res.message : '设备描述拉取失败';
      return undefined;
    }
    const device: UpnpDevice | undefined = UpnpClient.parseDescription(res.body, candidate.location);
    if (device === undefined) {
      UpnpClient.lastError = '设备描述不是合法的 UPnP 文档';
      return undefined;
    }
    if (device.udn.length === 0) {
      device.udn = candidate.udn;
    }
    if (device.server.length === 0) {
      device.server = candidate.server;
    }
    return device;
  }

  static parseDescription(xml: string, location: string): UpnpDevice | undefined {
    const doc: XmlDoc = XmlDoc.parse(xml);
    if (doc.root === undefined) {
      return undefined;
    }
    const urlBase: string = doc.root.find('URLBase') === undefined ? '' :
      (doc.root.find('URLBase') as XmlNode).text();
    const base: string = urlBase.length > 0 ? urlBase : DidlParser.originOf(location);
    const devices: XmlNode[] = doc.root.findAll('device');
    if (devices.length === 0) {
      return undefined;
    }
    let chosen: XmlNode = devices[0];
    for (let i = 0; i < devices.length; i++) {
      const type: string = devices[i].valueOf('deviceType');
      if (type.indexOf('MediaServer') >= 0 || type.indexOf('MediaRenderer') >= 0) {
        chosen = devices[i];
        break;
      }
    }
    const device: UpnpDevice = new UpnpDevice();
    device.udn = chosen.valueOf('UDN');
    device.friendlyName = chosen.valueOf('friendlyName');
    device.modelName = chosen.valueOf('modelName');
    device.deviceType = chosen.valueOf('deviceType');
    device.location = location;
    device.baseUrl = DidlParser.dirOf(base.endsWith('/') ? base : `${base}/`);
    device.ip = UpnpClient.ipOf(location);
    if (device.friendlyName.length === 0) {
      device.friendlyName = device.modelName.length > 0 ? device.modelName : device.ip;
    }
    const serviceNodes: XmlNode[] = chosen.all('serviceList');
    const allServiceNodes: XmlNode[] = serviceNodes.length > 0 ?
      serviceNodes[0].all('service') : chosen.findAll('service');
    for (let i = 0; i < allServiceNodes.length; i++) {
      const node: XmlNode = allServiceNodes[i];
      const svc: UpnpService = new UpnpService();
      svc.serviceType = node.valueOf('serviceType');
      svc.serviceId = node.valueOf('serviceId');
      svc.scpdURL = node.valueOf('SCPDURL');
      svc.controlURL = UpnpClient.resolveUrl(node.valueOf('controlURL'), base);
      svc.eventURL = UpnpClient.resolveUrl(node.valueOf('eventSubURL'), base);
      if (svc.serviceType.length > 0 && svc.controlURL.length > 0) {
        device.services.push(svc);
      }
    }
    return device;
  }

  static resolveUrl(url: string, base: string): string {
    return DidlParser.abs(url, base.endsWith('/') ? base : `${base}/`);
  }

  /** 读服务描述（SCPD）确认支持的动作，同时拿到服务类型（部分设备 description 里缺） */
  static async describeService(device: UpnpDevice, service: UpnpService): Promise<string[]> {
    const url: string = service.scpdURL.length > 0 ?
      UpnpClient.resolveUrl(service.scpdURL, device.baseUrl) : '';
    if (url.length === 0) {
      return [];
    }
    const res: NetResult = await NetClient.fetch(url, 6000);
    if (!res.ok) {
      return [];
    }
    const doc: XmlDoc = XmlDoc.parse(res.body);
    if (doc.root === undefined) {
      return [];
    }
    const actions: XmlNode[] = doc.root.findAll('action');
    const names: string[] = [];
    for (let i = 0; i < actions.length; i++) {
      const name: string = actions[i].valueOf('name');
      if (name.length > 0) {
        names.push(name);
      }
    }
    const typeNode: XmlNode | undefined = doc.root.find('serviceType');
    if (typeNode !== undefined && service.serviceType.length === 0) {
      service.serviceType = typeNode.text();
    }
    return names;
  }

  // ---------------- ContentDirectory Browse ----------------

  /** 浏览目录：BrowseDirectChildren（分页） */
  static async browse(device: UpnpDevice, objectId: string, startIndex: number,
    requested: number): Promise<BrowsePage> {
    const page: BrowsePage = new BrowsePage();
    page.startIndex = startIndex;
    page.requested = requested;
    const svc: UpnpService | undefined = device.contentDirectory;
    if (svc === undefined) {
      UpnpClient.lastError = '该设备不支持 ContentDirectory，无法浏览目录';
      return page;
    }
    const body: string = `<ObjectID>${XmlDoc.escape(objectId)}</ObjectID>` +
      '<BrowseFlag>BrowseDirectChildren</BrowseFlag>' +
      '<Filter>*</Filter>' +
      `<StartingIndex>${startIndex}</StartingIndex>` +
      `<RequestedCount>${requested}</RequestedCount>` +
      '<SortCriteria></SortCriteria>';
    const xml: string = await UpnpClient.invoke(device, svc, 'Browse', body);
    if (xml.length === 0) {
      return page;
    }
    page.result = DidlParser.parseEnvelope(xml, device.baseUrl);
    return page;
  }

  /** 读单个对象的元数据（DIDL 带 title/res/protocolInfo，投屏 SetAVTransportURI 要用） */
  static async browseMetadata(device: UpnpDevice, objectId: string): Promise<DidlItem | undefined> {
    const svc: UpnpService | undefined = device.contentDirectory;
    if (svc === undefined) {
      return undefined;
    }
    const body: string = `<ObjectID>${XmlDoc.escape(objectId)}</ObjectID>` +
      '<BrowseFlag>BrowseMetadata</BrowseFlag>' +
      '<Filter>*</Filter>' +
      '<StartingIndex>0</StartingIndex>' +
      '<RequestedCount>1</RequestedCount>' +
      '<SortCriteria></SortCriteria>';
    const xml: string = await UpnpClient.invoke(device, svc, 'Browse', body);
    if (xml.length === 0) {
      return undefined;
    }
    const result: BrowseResult = DidlParser.parseEnvelope(xml, device.baseUrl);
    return result.items.length > 0 ? result.items[0] : undefined;
  }

  // ---------------- SOAP 调用 ----------------

  /** 调一个 UPnP 动作，返回应答 XML（失败返回空串并把原因写进 errorText） */
  static async invoke(device: UpnpDevice, service: UpnpService, action: string,
    body: string): Promise<string> {
    const request: SoapRequest = new SoapRequest();
    request.action = action;
    request.serviceType = service.serviceType;
    request.body = body;
    const url: string = service.controlURL;
    const httpReq: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 12000,
        header: {
          'Content-Type': 'text/xml; charset="utf-8"',
          'SOAPAction': request.soapAction(),
          'Accept': '*/*'
        },
        extraData: request.envelope()
      };
      const resp: http.HttpResponse = await httpReq.request(url, options);
      const text: string = typeof resp.result === 'string' ? resp.result as string : '';
      if (resp.responseCode >= 400) {
        const err: string = UpnpClient.faultOf(text);
        UpnpClient.lastError = `${action} 失败（HTTP ${resp.responseCode}）${err.length > 0 ? `：${err}` : ''}`;
        hilog.warn(DOMAIN, TAG, '%{public}s -> %{public}d %{public}s', action, resp.responseCode, err);
        return '';
      }
      return text;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      UpnpClient.lastError = `${action} 调用失败（错误码 ${e.code}）；请确认设备在线且未禁用局域网控制`;
      hilog.error(DOMAIN, TAG, 'invoke %{public}s failed %{public}d', action, e.code);
      return '';
    } finally {
      httpReq.destroy();
    }
  }

  /** 从 SOAP Fault 里取 errorDescription，便于给用户看人话 */
  static faultOf(xml: string): string {
    if (xml.length === 0) {
      return '';
    }
    const doc: XmlDoc = XmlDoc.parse(xml);
    if (doc.root === undefined) {
      return '';
    }
    const desc: XmlNode | undefined = doc.root.find('errorDescription');
    if (desc !== undefined) {
      return desc.text();
    }
    const code: XmlNode | undefined = doc.root.find('errorCode');
    return code === undefined ? '' : `错误码 ${code.text()}`;
  }

  /** 取动作应答里某个出参的文本 */
  static outArg(xml: string, name: string): string {
    if (xml.length === 0) {
      return '';
    }
    const doc: XmlDoc = XmlDoc.parse(xml);
    if (doc.root === undefined) {
      return '';
    }
    return doc.root.valueOf(name);
  }
}
