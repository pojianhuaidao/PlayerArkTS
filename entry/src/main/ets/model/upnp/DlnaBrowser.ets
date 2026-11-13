import { hilog } from '@kit.PerformanceAnalysisKit';
import { BrowsePage, ST_MEDIA_SERVER, UpnpCandidate, UpnpClient } from './UpnpClient';
import { DidlItem, UpnpDevice, UpnpService } from './UpnpProto';

const DOMAIN: number = 0x0001;
const TAG: string = 'DlnaBrowser';
/** 单个目录最多拉多少条（避免大库把列表撑爆） */
const MAX_ITEMS: number = 600;
/** 每次 Browse 请求条数 */
const PAGE_SIZE: number = 100;

/** 一台 DLNA 媒体服务器 */
export class DlnaServer {
  udn: string = '';
  name: string = '';
  model: string = '';
  ip: string = '';
  device: UpnpDevice | undefined = undefined;

  get subtitle(): string {
    const parts: string[] = [];
    if (this.model.length > 0) {
      parts.push(this.model);
    }
    if (this.ip.length > 0) {
      parts.push(this.ip);
    }
    return parts.join(' · ');
  }
}

/** DLNA 目录里的一条（给 UI 用） */
export class DlnaEntry {
  name: string = '';
  /** dlna://udn/objectId 形式，用于进入子目录或播放 */
  uri: string = '';
  isDir: boolean = false;
  /** 可播放的 http 直链（目录为空串） */
  playUrl: string = '';
  sizeText: string = '';
  durationText: string = '';
  itemId: string = '';
  /** 详情行，如 "1.2 GB · 01:32:10" */
  get detail(): string {
    const parts: string[] = [];
    if (this.sizeText.length > 0) {
      parts.push(this.sizeText);
    }
    if (this.durationText.length > 0) {
      parts.push(this.durationText);
    }
    return parts.join(' · ');
  }
}

/**
 * DLNA 浏览：ssdp 发现 MediaServer → device description → ContentDirectory Browse → DIDL-Lite。
 * 目录地址用 dlna://<udn>/<objectId> 表示，objectId 参与转义，可与现有 url 风格路由复用。
 */
export class DlnaBrowser {
  private static servers: DlnaServer[] = [];
  private static byUdn: Map<string, DlnaServer> = new Map<string, DlnaServer>();
  private static lastError: string = '';
  private static busy: boolean = false;

  static get errorText(): string {
    return DlnaBrowser.lastError;
  }

  static get list(): DlnaServer[] {
    return DlnaBrowser.servers;
  }

  static get discovered(): boolean {
    return DlnaBrowser.servers.length > 0;
  }

  static get discovering(): boolean {
    return DlnaBrowser.busy;
  }

  /** 发现媒体服务器（结果累积，重复发现不会重复添加） */
  static async discover(timeoutMs: number): Promise<DlnaServer[]> {
    if (DlnaBrowser.busy) {
      return DlnaBrowser.servers;
    }
    DlnaBrowser.busy = true;
    DlnaBrowser.lastError = '';
    try {
      const hits: UpnpCandidate[] = await UpnpClient.discover(ST_MEDIA_SERVER, timeoutMs);
      if (hits.length === 0) {
        DlnaBrowser.lastError = UpnpClient.errorText;
      }
      for (let i = 0; i < hits.length; i++) {
        const device: UpnpDevice | undefined = await UpnpClient.describe(hits[i]);
        if (device === undefined) {
          continue;
        }
        if (!device.isMediaServer && device.contentDirectory === undefined) {
          continue;
        }
        DlnaBrowser.add(device);
      }
      if (DlnaBrowser.servers.length === 0 && DlnaBrowser.lastError.length === 0) {
        DlnaBrowser.lastError = '发现设备但没有可用的 DLNA 媒体服务器（缺 ContentDirectory 服务）';
      }
      return DlnaBrowser.servers;
    } finally {
      DlnaBrowser.busy = false;
    }
  }

  static add(device: UpnpDevice): DlnaServer {
    const key: string = device.udn.length > 0 ? device.udn : device.location;
    const exists: DlnaServer | undefined = DlnaBrowser.byUdn.get(key);
    if (exists !== undefined) {
      exists.device = device;
      exists.name = device.friendlyName;
      exists.model = device.modelName;
      exists.ip = device.ip;
      return exists;
    }
    const server: DlnaServer = new DlnaServer();
    server.udn = key;
    server.name = device.friendlyName;
    server.model = device.modelName;
    server.ip = device.ip;
    server.device = device;
    DlnaBrowser.servers.push(server);
    DlnaBrowser.byUdn.set(key, server);
    hilog.info(DOMAIN, TAG, 'add server %{public}s', server.name);
    return server;
  }

  static serverOf(udn: string): DlnaServer | undefined {
    return DlnaBrowser.byUdn.get(udn);
  }

  static clear(): void {
    DlnaBrowser.servers = [];
    DlnaBrowser.byUdn.clear();
    DlnaBrowser.lastError = '';
  }

  /** 根目录地址 */
  static rootUri(udn: string): string {
    return `dlna://${udn}/0`;
  }

  /** dlna://<udn>/<objectId> → {udn, objectId} */
  static split(uri: string): DlnaServer | undefined {
    const prefix: string = 'dlna://';
    if (!uri.startsWith(prefix)) {
      return undefined;
    }
    const rest: string = uri.substring(prefix.length);
    const slash: number = rest.indexOf('/');
    const udn: string = slash < 0 ? rest : rest.substring(0, slash);
    return DlnaBrowser.byUdn.get(udn);
  }

  static objectIdOf(uri: string): string {
    const prefix: string = 'dlna://';
    if (!uri.startsWith(prefix)) {
      return '0';
    }
    const rest: string = uri.substring(prefix.length);
    const slash: number = rest.indexOf('/');
    if (slash < 0) {
      return '0';
    }
    const raw: string = rest.substring(slash + 1);
    if (raw.length === 0) {
      return '0';
    }
    try {
      return decodeURIComponent(raw);
    } catch (err) {
      return raw;
    }
  }

  static uriOf(udn: string, objectId: string): string {
    return `dlna://${udn}/${encodeURIComponent(objectId)}`;
  }

  /** 列目录（自动翻页，最多 MAX_ITEMS 条） */
  static async listDir(uri: string): Promise<DlnaEntry[]> {
    const server: DlnaServer | undefined = DlnaBrowser.split(uri);
    if (server === undefined || server.device === undefined) {
      DlnaBrowser.lastError = 'DLNA 服务器已失效，请重新发现设备';
      return [];
    }
    const objectId: string = DlnaBrowser.objectIdOf(uri);
    const out: DlnaEntry[] = [];
    let start: number = 0;
    let total: number = 0;
    while (out.length < MAX_ITEMS) {
      const page: BrowsePage = await UpnpClient.browse(server.device, objectId, start, PAGE_SIZE);
      if (page.result.items.length === 0) {
        if (out.length === 0) {
          DlnaBrowser.lastError = UpnpClient.errorText;
        }
        break;
      }
      total = page.result.totalMatches;
      for (let i = 0; i < page.result.items.length; i++) {
        out.push(DlnaBrowser.toEntry(server.udn, page.result.items[i]));
      }
      start += page.result.items.length;
      if (start >= total || !page.hasMore) {
        break;
      }
    }
    if (out.length === 0 && DlnaBrowser.lastError.length === 0) {
      DlnaBrowser.lastError = '该目录为空';
    }
    return out;
  }

  private static toEntry(udn: string, item: DidlItem): DlnaEntry {
    const entry: DlnaEntry = new DlnaEntry();
    entry.name = item.title;
    entry.itemId = item.id;
    entry.isDir = item.isContainer;
    entry.uri = DlnaBrowser.uriOf(udn, item.id);
    entry.playUrl = item.isContainer ? '' : item.url;
    entry.sizeText = item.sizeText;
    entry.durationText = item.durationText;
    return entry;
  }

  /** 播放前取该项的 DIDL 元数据（投屏要带 title/res/protocolInfo） */
  static async metadataOf(uri: string): Promise<DidlItem | undefined> {
    const server: DlnaServer | undefined = DlnaBrowser.split(uri);
    if (server === undefined || server.device === undefined) {
      return undefined;
    }
    return UpnpClient.browseMetadata(server.device, DlnaBrowser.objectIdOf(uri));
  }

  /** 抓取该服务器 ContentDirectory 支持的动作清单（诊断/日志用） */
  static async actionsOf(udn: string): Promise<string[]> {
    const server: DlnaServer | undefined = DlnaBrowser.byUdn.get(udn);
    if (server === undefined || server.device === undefined) {
      return [];
    }
    const svc: UpnpService | undefined = server.device.contentDirectory;
    if (svc === undefined) {
      return [];
    }
    return UpnpClient.describeService(server.device, svc);
  }
}
