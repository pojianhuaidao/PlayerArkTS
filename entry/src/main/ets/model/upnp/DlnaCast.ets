import { hilog } from '@kit.PerformanceAnalysisKit';
import { ST_MEDIA_RENDERER, UpnpCandidate, UpnpClient } from './UpnpClient';
import { DidlItem, DidlParser, UpnpDevice, UpnpService, XmlDoc } from './UpnpProto';

const DOMAIN: number = 0x0001;
const TAG: string = 'DlnaCast';
/** AVTransport / RenderingControl 的 InstanceID 固定为 0（DLNA 约定） */
const INSTANCE_ID: string = '0';

/** 投屏阶段（UI 三态 + 连接中/错误） */
export enum CastPhase {
  IDLE = 0,
  CONNECTING = 1,
  PLAYING = 2,
  PAUSED = 3,
  STOPPED = 4,
  ERROR = 5
}

/** 一台可投屏的渲染器（电视/盒子/音箱） */
export class CastRenderer {
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

/** 投屏状态快照 */
export class CastStatus {
  phase: CastPhase = CastPhase.IDLE;
  /** 对端报告的播放位置（秒，未知为 -1） */
  positionSec: number = -1;
  /** 对端报告的媒体时长（秒，未知为 -1） */
  durationSec: number = -1;
  volume: number = -1;
  message: string = '';
}

/**
 * DLNA 投屏发送端：SSDP 找 MediaRenderer → AVTransport 控制播放 + RenderingControl 调音量。
 * 本地播放器与电视端是两套解码，因此投屏期间本地暂停，进度条拖动转成 Seek。
 */
export class DlnaCast {
  private static renderers: CastRenderer[] = [];
  private static byUdn: Map<string, CastRenderer> = new Map<string, CastRenderer>();
  private static phase: CastPhase = CastPhase.IDLE;
  private static active: UpnpDevice | undefined = undefined;
  private static avt: UpnpService | undefined = undefined;
  private static rcs: UpnpService | undefined = undefined;
  private static activeUdn: string = '';
  private static activeName: string = '';
  private static castingUri: string = '';
  private static castingTitle: string = '';
  private static lastError: string = '';
  private static discovering: boolean = false;

  static get list(): CastRenderer[] {
    return DlnaCast.renderers;
  }

  static get status(): CastPhase {
    return DlnaCast.phase;
  }

  static get deviceName(): string {
    return DlnaCast.activeName;
  }

  static get errorText(): string {
    return DlnaCast.lastError;
  }

  static get busy(): boolean {
    return DlnaCast.discovering;
  }

  static get isCasting(): boolean {
    return DlnaCast.active !== undefined && DlnaCast.phase !== CastPhase.IDLE &&
      DlnaCast.phase !== CastPhase.ERROR;
  }

  /** 投屏按钮上的三态文案 */
  static get phaseLabel(): string {
    if (DlnaCast.phase === CastPhase.PLAYING) {
      return '正在投屏';
    }
    if (DlnaCast.phase === CastPhase.PAUSED) {
      return '已暂停';
    }
    if (DlnaCast.phase === CastPhase.CONNECTING) {
      return '连接中';
    }
    if (DlnaCast.phase === CastPhase.ERROR) {
      return '投屏异常';
    }
    return '未连接';
  }

  // ---------------- 发现 ----------------

  static async discover(timeoutMs: number): Promise<CastRenderer[]> {
    if (DlnaCast.discovering) {
      return DlnaCast.renderers;
    }
    DlnaCast.discovering = true;
    DlnaCast.lastError = '';
    try {
      const hits: UpnpCandidate[] = await UpnpClient.discover(ST_MEDIA_RENDERER, timeoutMs);
      if (hits.length === 0) {
        DlnaCast.lastError = UpnpClient.errorText;
      }
      for (let i = 0; i < hits.length; i++) {
        const device: UpnpDevice | undefined = await UpnpClient.describe(hits[i]);
        if (device === undefined) {
          continue;
        }
        if (device.avTransport === undefined && !device.isMediaRenderer) {
          hilog.info(DOMAIN, TAG, 'skip %{public}s: no AVTransport', device.friendlyName);
          continue;
        }
        DlnaCast.remember(device);
      }
      if (DlnaCast.renderers.length === 0 && DlnaCast.lastError.length === 0) {
        DlnaCast.lastError = '没有找到支持投屏的设备（需电视/盒子开启 DLNA 投屏）';
      }
      return DlnaCast.renderers;
    } finally {
      DlnaCast.discovering = false;
    }
  }

  private static remember(device: UpnpDevice): void {
    const key: string = device.udn.length > 0 ? device.udn : device.location;
    const exists: CastRenderer | undefined = DlnaCast.byUdn.get(key);
    if (exists !== undefined) {
      exists.device = device;
      exists.name = device.friendlyName;
      exists.model = device.modelName;
      exists.ip = device.ip;
      return;
    }
    const renderer: CastRenderer = new CastRenderer();
    renderer.udn = key;
    renderer.name = device.friendlyName;
    renderer.model = device.modelName;
    renderer.ip = device.ip;
    renderer.device = device;
    DlnaCast.renderers.push(renderer);
    DlnaCast.byUdn.set(key, renderer);
    hilog.info(DOMAIN, TAG, 'renderer %{public}s', renderer.name);
  }

  static clear(): void {
    DlnaCast.renderers = [];
    DlnaCast.byUdn.clear();
  }

  // ---------------- 连接 ----------------

  /** 选中一台渲染器：补齐 AVTransport / RenderingControl 控制地址 */
  static async connect(udn: string): Promise<boolean> {
    const renderer: CastRenderer | undefined = DlnaCast.byUdn.get(udn);
    if (renderer === undefined || renderer.device === undefined) {
      DlnaCast.lastError = '设备已失效，请重新发现';
      return false;
    }
    DlnaCast.phase = CastPhase.CONNECTING;
    const device: UpnpDevice = renderer.device;
    const avt: UpnpService | undefined = device.avTransport;
    if (avt === undefined) {
      DlnaCast.lastError = '该设备没有 AVTransport 服务，无法投屏';
      DlnaCast.phase = CastPhase.ERROR;
      return false;
    }
    DlnaCast.active = device;
    DlnaCast.activeUdn = udn;
    DlnaCast.activeName = device.friendlyName;
    DlnaCast.avt = avt;
    DlnaCast.rcs = device.renderingControl;
    // 拉一次服务描述，确认动作名（不同厂商略有差异，同时补齐 serviceType）
    const actions: string[] = await UpnpClient.describeService(device, avt);
    if (actions.length > 0 && actions.indexOf('SetAVTransportURI') < 0) {
      DlnaCast.lastError = '该设备不支持 SetAVTransportURI，无法投屏';
      DlnaCast.phase = CastPhase.ERROR;
      DlnaCast.active = undefined;
      return false;
    }
    const info: string = await UpnpClient.invoke(device, avt, 'GetTransportInfo',
      `<InstanceID>${INSTANCE_ID}</InstanceID>`);
    if (info.length === 0) {
      DlnaCast.lastError = UpnpClient.errorText.length > 0 ? UpnpClient.errorText : '设备无响应';
      DlnaCast.phase = CastPhase.ERROR;
      DlnaCast.active = undefined;
      return false;
    }
    DlnaCast.phase = CastPhase.STOPPED;
    return true;
  }

  /** 当前是否已连接到某个渲染器 */
  static get connected(): boolean {
    return DlnaCast.active !== undefined && DlnaCast.avt !== undefined;
  }

  static get currentUdn(): string {
    return DlnaCast.activeUdn;
  }

  private static requireTransport(): UpnpService | undefined {
    const svc: UpnpService | undefined = DlnaCast.avt;
    if (svc === undefined || DlnaCast.active === undefined) {
      DlnaCast.lastError = '尚未连接投屏设备';
    }
    return svc;
  }

  // ---------------- 媒体投放 ----------------

  /** 组装 SetAVTransportURI 的 DIDL-Lite 元数据 */
  static buildMetadata(title: string, url: string, mime: string, size: number): string {
    const protocol: string = `http-get:*:${mime}:*`;
    const sizeAttr: string = size > 0 ? ` size="${size}"` : '';
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" ' +
      'xmlns:dc="http://purl.org/dc/elements/1.1/" ' +
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">' +
      '<item id="0" parentID="-1" restricted="1">' +
      `<dc:title>${XmlDoc.escape(title)}</dc:title>` +
      '<upnp:class>object.item.videoItem</upnp:class>' +
      `<res protocolInfo="${protocol}"${sizeAttr}>${XmlDoc.escape(url)}</res>` +
      '</item></DIDL-Lite>';
  }

  /**
   * 投放一个 http 地址并起播。
   * 注意：电视端必须能直接访问该 url —— ftp/smb 源要先经本地代理转成 http，
   * 且代理监听在 127.0.0.1 时电视访问不到，这种情况请直接投 DLNA 服务器自身的 http 直链。
   */
  static async castUrl(url: string, title: string, mime: string, size: number): Promise<boolean> {
    const svc: UpnpService | undefined = DlnaCast.requireTransport();
    const device: UpnpDevice | undefined = DlnaCast.active;
    if (svc === undefined || device === undefined) {
      return false;
    }
    const meta: string = DlnaCast.buildMetadata(title, url, mime, size);
    const body: string = `<InstanceID>${INSTANCE_ID}</InstanceID>` +
      `<CurrentURI>${XmlDoc.escape(url)}</CurrentURI>` +
      `<CurrentURIMetaData>${XmlDoc.escape(meta)}</CurrentURIMetaData>`;
    const setRes: string = await UpnpClient.invoke(device, svc, 'SetAVTransportURI', body);
    if (setRes.length === 0) {
      DlnaCast.lastError = UpnpClient.errorText;
      DlnaCast.phase = CastPhase.ERROR;
      return false;
    }
    DlnaCast.castingUri = url;
    DlnaCast.castingTitle = title;
    const played: boolean = await DlnaCast.play();
    if (played) {
      DlnaCast.phase = CastPhase.PLAYING;
    }
    return played;
  }

  /** 用 DLNA 服务器上的 DIDL 元数据直接投放（保真度最高） */
  static async castItem(item: DidlItem): Promise<boolean> {
    if (item.url.length === 0) {
      DlnaCast.lastError = '该条目没有可播放的 http 资源地址';
      return false;
    }
    const mime: string = DlnaCast.mimeOf(item);
    return DlnaCast.castUrl(item.url, item.title, mime, item.size);
  }

  static mimeOf(item: DidlItem): string {
    const info: string = item.protocolInfo;
    const parts: string[] = info.split(':');
    if (parts.length >= 3 && parts[2].length > 0 && parts[2] !== '*') {
      return parts[2];
    }
    const ext: string = item.ext.toLowerCase();
    if (ext === 'mp4' || ext === 'm4v') {
      return 'video/mp4';
    }
    if (ext === 'mkv') {
      return 'video/x-matroska';
    }
    if (ext === 'ts' || ext === 'm2ts') {
      return 'video/mp2t';
    }
    if (ext === 'mov') {
      return 'video/quicktime';
    }
    if (ext === 'avi') {
      return 'video/x-msvideo';
    }
    if (ext === 'mp3') {
      return 'audio/mpeg';
    }
    if (ext === 'flac') {
      return 'audio/flac';
    }
    if (ext === 'jpg' || ext === 'jpeg') {
      return 'image/jpeg';
    }
    if (ext === 'png') {
      return 'image/png';
    }
    return 'video/mp4';
  }

  // ---------------- 传输控制 ----------------

  static async play(): Promise<boolean> {
    const svc: UpnpService | undefined = DlnaCast.requireTransport();
    const device: UpnpDevice | undefined = DlnaCast.active;
    if (svc === undefined || device === undefined) {
      return false;
    }
    const res: string = await UpnpClient.invoke(device, svc, 'Play',
      `<InstanceID>${INSTANCE_ID}</InstanceID><Speed>1</Speed>`);
    if (res.length === 0) {
      DlnaCast.lastError = UpnpClient.errorText;
      return false;
    }
    DlnaCast.phase = CastPhase.PLAYING;
    return true;
  }

  static async pause(): Promise<boolean> {
    const svc: UpnpService | undefined = DlnaCast.requireTransport();
    const device: UpnpDevice | undefined = DlnaCast.active;
    if (svc === undefined || device === undefined) {
      return false;
    }
    const res: string = await UpnpClient.invoke(device, svc, 'Pause',
      `<InstanceID>${INSTANCE_ID}</InstanceID>`);
    if (res.length === 0) {
      DlnaCast.lastError = UpnpClient.errorText;
      return false;
    }
    DlnaCast.phase = CastPhase.PAUSED;
    return true;
  }

  static async stop(): Promise<boolean> {
    const svc: UpnpService | undefined = DlnaCast.requireTransport();
    const device: UpnpDevice | undefined = DlnaCast.active;
    if (svc === undefined || device === undefined) {
      return false;
    }
    const res: string = await UpnpClient.invoke(device, svc, 'Stop',
      `<InstanceID>${INSTANCE_ID}</InstanceID>`);
    if (res.length === 0) {
      DlnaCast.lastError = UpnpClient.errorText;
      return false;
    }
    DlnaCast.phase = CastPhase.STOPPED;
    return true;
  }

  /** 拖动进度条同步到电视：目标时间格式 HH:MM:SS */
  static async seek(seconds: number): Promise<boolean> {
    const svc: UpnpService | undefined = DlnaCast.requireTransport();
    const device: UpnpDevice | undefined = DlnaCast.active;
    if (svc === undefined || device === undefined) {
      return false;
    }
    let sec: number = Math.floor(seconds);
    if (sec < 0) {
      sec = 0;
    }
    const target: string = DlnaCast.timeText(sec);
    const res: string = await UpnpClient.invoke(device, svc, 'Seek',
      `<InstanceID>${INSTANCE_ID}</InstanceID><Unit>REL_TIME</Unit><Target>${target}</Target>`);
    if (res.length === 0) {
      DlnaCast.lastError = UpnpClient.errorText;
      return false;
    }
    return true;
  }

  /** 相对当前位置快进/快退（部分设备不支持 Seek，会失败） */
  static async seekBy(deltaSec: number, currentSec: number): Promise<boolean> {
    return DlnaCast.seek(currentSec + deltaSec);
  }

  static timeText(totalSec: number): string {
    const total: number = Math.max(0, Math.floor(totalSec));
    const h: number = Math.floor(total / 3600);
    const m: number = Math.floor((total % 3600) / 60);
    const s: number = total % 60;
    const hh: string = h < 10 ? `0${h}` : `${h}`;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const ss: string = s < 10 ? `0${s}` : `${s}`;
    return `${hh}:${mm}:${ss}`;
  }

  /** UPnP 的 RelTime 可能是 0:01:23 → 秒 */
  static parseTime(text: string): number {
    return DidlParser.durationOf(text);
  }

  // ---------------- 音量 ----------------

  static async setVolume(ratio: number): Promise<boolean> {
    const device: UpnpDevice | undefined = DlnaCast.active;
    const rcs: UpnpService | undefined = DlnaCast.rcs;
    if (device === undefined || rcs === undefined) {
      DlnaCast.lastError = '该设备不支持音量控制';
      return false;
    }
    let value: number = Math.round(ratio * 100);
    if (value < 0) {
      value = 0;
    }
    if (value > 100) {
      value = 100;
    }
    const res: string = await UpnpClient.invoke(device, rcs, 'SetVolume',
      `<InstanceID>${INSTANCE_ID}</InstanceID><Channel>Master</Channel><DesiredVolume>${value}</DesiredVolume>`);
    return res.length > 0;
  }

  static async volume(): Promise<number> {
    const device: UpnpDevice | undefined = DlnaCast.active;
    const rcs: UpnpService | undefined = DlnaCast.rcs;
    if (device === undefined || rcs === undefined) {
      return -1;
    }
    const res: string = await UpnpClient.invoke(device, rcs, 'GetVolume',
      `<InstanceID>${INSTANCE_ID}</InstanceID><Channel>Master</Channel>`);
    if (res.length === 0) {
      return -1;
    }
    const text: string = UpnpClient.outArg(res, 'CurrentVolume');
    const n: number = Number.parseInt(text, 10);
    return Number.isNaN(n) ? -1 : n / 100;
  }

  // ---------------- 状态轮询 ----------------

  /** 拉对端状态：播放/暂停、位置、时长（进度条与本地播放器同步用） */
  static async fetchStatus(): Promise<CastStatus> {
    const status: CastStatus = new CastStatus();
    status.phase = DlnaCast.phase;
    const device: UpnpDevice | undefined = DlnaCast.active;
    const avt: UpnpService | undefined = DlnaCast.avt;
    if (device === undefined || avt === undefined) {
      return status;
    }
    const info: string = await UpnpClient.invoke(device, avt, 'GetTransportInfo',
      `<InstanceID>${INSTANCE_ID}</InstanceID>`);
    if (info.length === 0) {
      status.phase = CastPhase.ERROR;
      status.message = UpnpClient.errorText;
      DlnaCast.phase = CastPhase.ERROR;
      return status;
    }
    const state: string = UpnpClient.outArg(info, 'CurrentTransportState');
    if (state === 'PLAYING') {
      status.phase = CastPhase.PLAYING;
    } else if (state === 'PAUSED_PLAYBACK' || state === 'PAUSED_RECORDING') {
      status.phase = CastPhase.PAUSED;
    } else if (state === 'TRANSITIONING') {
      status.phase = CastPhase.PLAYING;
    } else if (state === 'STOPPED' || state === 'NO_MEDIA_PRESENT') {
      status.phase = CastPhase.STOPPED;
    }
    DlnaCast.phase = status.phase;
    const pos: string = await UpnpClient.invoke(device, avt, 'GetPositionInfo',
      `<InstanceID>${INSTANCE_ID}</InstanceID>`);
    if (pos.length > 0) {
      status.positionSec = DlnaCast.parseTime(UpnpClient.outArg(pos, 'RelTime'));
      status.durationSec = DlnaCast.parseTime(UpnpClient.outArg(pos, 'TrackDuration'));
    }
    const vol: number = await DlnaCast.volume();
    status.volume = vol;
    return status;
  }

  /** 断开投屏：Stop 后清空引用（播放页退出时调用） */
  static async disconnect(notifyStop: boolean): Promise<void> {
    if (DlnaCast.connected && notifyStop) {
      await DlnaCast.stop().catch(() => {
      });
    }
    DlnaCast.active = undefined;
    DlnaCast.avt = undefined;
    DlnaCast.rcs = undefined;
    DlnaCast.phase = CastPhase.IDLE;
    DlnaCast.activeUdn = '';
    DlnaCast.activeName = '';
    DlnaCast.castingUri = '';
    DlnaCast.castingTitle = '';
  }

  /** 供日志/调试 */
  static get castingUrl(): string {
    return DlnaCast.castingUri;
  }
}
