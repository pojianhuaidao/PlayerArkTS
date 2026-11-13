import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppTheme, Palette } from '../common/AppTheme';
import { NetClient, NetEntry, NetResult, NetUrlInfo } from '../model/NetClient';
import { NetNavSnapshot, NetNavStore } from '../model/NetNavStore';
import { NetPrefs } from '../model/NetPrefs';
import { NetServer } from '../model/NetServer';
import { NetScan, ScanHit } from '../model/NetScan';
import { VideoItem, stripExt, formatSize } from '../model/VideoItem';
import { PlaylistHolder } from '../model/PlayerPrefs';
import { SmbBrowser } from '../model/smb/SmbBrowser';
import { SmbProxy } from '../model/smb/SmbProxy';
import { SmbLog } from '../model/smb/SmbLog';
import { SmbDirEntry } from '../model/smb/Smb2Client';
import { FtpBrowser } from '../model/ftp/FtpBrowser';
import { FtpProxy } from '../model/ftp/FtpProxy';
import { FtpEntry, FtpTarget, FtpUrl } from '../model/ftp/FtpProto';
import { DlnaBrowser, DlnaEntry, DlnaServer } from '../model/upnp/DlnaBrowser';

/** 跳转添加/编辑页时携带的参数（ArkTS 要求对象字面量有显式类型） */
interface NetEditParams {
  server?: string;
  address?: string;
  proto?: number;
}

/** 浏览态地址工具栏高度（addressBar 实测：上下 padding 10 + 操作行 36） */
const NET_TOOLBAR_H: number = 46;
/** 网络条目行高：双行文字 + 上下 padding 10 */
const NET_ROW_H: number = 58;

/**
 * 局域网页面：
 *  1) 已保存服务器列表（＋ 添加 / 长按删除），点条目直接进目录；
 *  2) 发现设备：扫描本机网段常见 HTTP/WebDAV/SMB 端口，结果可一键添加；
 *  3) 直接输入地址：支持 http/https 目录浏览与 rtsp/rtmp/m3u8 直链播放。
 * SMB 共享需要原生库，本版本只做探测提示，不做浏览。
 */
@Component
export struct NetPanel {
  @StorageProp('isDark') isDark: boolean = true;

  pal(): Palette {
    return AppTheme.palette(this.isDark);
  }

  /** 外部（页签清除按钮）触发刷新 */
  @Prop @Watch('onTickChange') tick: number = 0;

  /**
   * 目录/提示区已在顶部、用户继续下滑时回调父级（视频页整页翻页场景用于回上一页）。
   * 返回 true 表示父级已消费该手势，本组件不再下传滚动偏移。
   */
  onPullBack: () => boolean = (): boolean => false;

  /**
   * 浏览态变化回调：列表有数据时父级需要把本面板从「半屏」放大到「近乎整页」，
   * 否则上半部分固定区块会把目录列表压成 0 高（表现为「连上了但看不到目录」）。
   */
  onBrowseChange: (browsing: boolean) => void = (browsing: boolean): void => {};

  /**
   * 网络内容高度上报：父级据此判断网络区是否已占满一页（决定视频页要不要整页翻页）。
   * List 为虚拟化容器，实测拿不到全量内容高度，这里按条目数 × 行高估算。
   */
  onContentH: (h: number) => void = (h: number): void => {};

  @State address: string = '';
  @State currentUrl: string = '';
  @State @Watch('onEntriesChanged') entries: NetEntry[] = [];
  @State loading: boolean = false;
  @State status: string = '';
  @State history: string[] = [];
  @State servers: NetServer[] = [];
  /** 0=HTTP 目录/直链，1=WebDAV */
  @State protocol: number = 0;
  /** 用户配置的 WebDAV 根地址，用于「上级」顶层判定 */
  private davRoot: string = '';
  @State davUser: string = '';
  @State davPass: string = '';
  /** SMB 账号密码（来自服务器条目，供会话与本地代理按需取用） */
  @State smbUser: string = '';
  @State smbPass: string = '';

  /** 发现面板 */
  @State showDiscover: boolean = false;
  @State scanning: boolean = false;
  @State scanDone: number = 0;
  @State scanTotal: number = 0;
  @State hits: ScanHit[] = [];
  @State scanTip: string = '';

  /** FTP 配置弹层 */
  @State ftpOpen: boolean = false;
  @State ftpHost: string = '';
  @State ftpPort: string = '21';
  @State ftpUser: string = '';
  @State ftpPass: string = '';
  @State ftpAnon: boolean = true;
  @State ftpPassive: boolean = true;
  @State ftpBusy: boolean = false;

  /** DLNA 设备发现弹层 */
  @State dlnaOpen: boolean = false;
  @State dlnaBusy: boolean = false;
  @State dlnaTip: string = '';
  @State dlnaError: string = '';
  @State dlnaServers: DlnaServer[] = [];
  /** 当前 DLNA 目录项（携带 http 直链，供播放列表使用） */
  @State dlnaItems: DlnaEntry[] = [];
  /** DLNA 目录栈，用于「上级」 */
  private dlnaPath: string[] = [];
  /** 目录列表滚动控制器：整页翻页时用它判断「已在顶端继续下滑」 */
  private listScroller: Scroller = new Scroller();

  /** 目录内排序：0=名称升序 1=名称降序 2=大小降序 3=类型 */
  @State netSort: number = 0;
  /** 目录内搜索：按钮就地展开输入行，只过滤当前目录条目 */
  @State netSearchOn: boolean = false;
  @State netKeyword: string = '';

  private netSortLabel(): string {
    const names: string[] = ['⇅ 名称↑', '⇅ 名称↓', '⇅ 大小↓', '⇅ 类型'];
    return names[this.netSort];
  }

  private openNetSortMenu(): void {
    promptAction.showActionMenu({
      title: '排序方式',
      buttons: [
        { text: '名称 ↑', color: this.pal().textPrimary },
        { text: '名称 ↓', color: this.pal().textPrimary },
        { text: '大小 ↓', color: this.pal().textPrimary },
        { text: '类型', color: this.pal().textPrimary }
      ]
    }).then((res: promptAction.ActionMenuSuccessResponse) => {
      this.netSort = res.index;
      this.reportContentH();
    }).catch(() => {
    });
  }

  private toggleNetSearch(): void {
    this.netSearchOn = !this.netSearchOn;
    if (!this.netSearchOn) {
      this.netKeyword = '';
    }
    this.reportContentH();
  }

  /** 当前目录实际要渲染的条目：先按关键字过滤，再排序，目录恒排在文件之前 */
  private shownEntries(): NetEntry[] {
    const kw: string = this.netKeyword.trim().toLowerCase();
    let list: NetEntry[] = this.entries;
    if (kw.length > 0) {
      list = list.filter((e: NetEntry) => e.name.toLowerCase().indexOf(kw) >= 0);
    }
    const arr: NetEntry[] = list.slice();
    const mode: number = this.netSort;
    arr.sort((a: NetEntry, b: NetEntry): number => {
      if (a.isDir !== b.isDir) {
        return a.isDir ? -1 : 1;
      }
      if (mode === 1) {
        return b.name.localeCompare(a.name);
      }
      if (mode === 2) {
        return (b.sizeBytes || 0) - (a.sizeBytes || 0);
      }
      if (mode === 3) {
        const ea: string = a.isDir ? '' : (a.name.indexOf('.') >= 0 ? a.name.substring(a.name.lastIndexOf('.')).toLowerCase() : '');
        const eb: string = b.isDir ? '' : (b.name.indexOf('.') >= 0 ? b.name.substring(b.name.lastIndexOf('.')).toLowerCase() : '');
        return ea === eb ? a.name.localeCompare(b.name) : ea.localeCompare(eb);
      }
      return a.name.localeCompare(b.name);
    });
    return arr;
  }

  /**
   * 是否已在顶层目录（再往上就该回「我的服务器」列表）。
   * 注意：SMB / WebDAV 不能直接用 NetClient.parentOf 判断——
   * SMB 的 smb://host/共享名 已经是共享根，通用算法会认为还能上跳到 smb://host/（无共享名，不可列），
   * 结果「上级」既不回服务器列表也列不出目录；DAV 同理会爬到站点根。
   */
  private atTopLevel(): boolean {
    // 以地址本身的 scheme 为准：直连地址输入 smb://、发现设备里带出的 smb 地址等
    // 都可能没同步 protocol，只看 protocol 会让「上级」永远判不出顶层。
    const sch: string = this.currentScheme();
    if (this.isDlna() || sch === 'dlna' || sch === 'upnp') {
      return this.dlnaPath.length <= 1;
    }
    if (this.isFtp() || sch === 'ftp') {
      return FtpUrl.parentOf(this.currentUrl) === this.currentUrl;
    }
    if (this.isSmb() || sch === 'smb' || sch === 'cifs') {
      // SmbBrowser.parentOf 在「共享根」返回空串，正好用作顶层判定；
      // 再兜一层：地址写法差异（尾斜杠、cifs:// 前缀）会让父路径算回自身或算成
      // smb://host/（无共享名、列不出来），这两种情况同样必须回服务器列表，
      // 否则「上级」点下去只会原地重载，用户看到的就是“点了没反应”。
      const cur: string = this.trimSlash(this.currentUrl);
      const up: string = this.trimSlash(SmbBrowser.parentOf(this.currentUrl));
      if (up.length === 0 || up === cur) {
        return true;
      }
      return SmbBrowser.checkUrl(up).length > 0;
    }
    if (this.isDav() || sch === 'http' || sch === 'https') {
      const up: string = NetClient.parentOf(this.currentUrl);
      if (up.length === 0) {
        return true;
      }
      const root: string = this.davRoot;
      if (root.length > 0) {
        const cur: string = this.trimSlash(this.currentUrl);
        // 已回到（或已越过）配置里的 DAV 根，就当顶层处理，避免爬到站点根报 404
        return cur.length <= this.trimSlash(root).length;
      }
      return false;
    }
    return NetClient.parentOf(this.currentUrl).length === 0;
  }

  /** 当前地址的 scheme（小写），空地址返回空串 */
  private currentScheme(): string {
    const u: string = this.currentUrl;
    const i: number = u.indexOf('://');
    return i > 0 ? u.substring(0, i).toLowerCase() : '';
  }

  /** 是否为 SMB 会话（protocol 或地址 scheme 任一命中即可） */
  private isSmbUrl(): boolean {
    if (this.isSmb()) {
      return true;
    }
    const sch: string = this.currentScheme();
    return sch === 'smb' || sch === 'cifs';
  }

  /** 去掉末尾斜杠，便于按长度比较目录层级 */
  private trimSlash(url: string): string {
    let s: string = url;
    while (s.length > 0 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /** 「‹ 上级」：目录内上跳一级；已在顶层就直接退回服务器列表 */
  private onUpAction(): void {
    if (this.atTopLevel()) {
      this.backToServers();
      return;
    }
    this.goParent();
  }

  /** 顶部继续下滑：把手势交给父级翻页；返回 true 表示已被父级消费 */
  private tryPullBack(offset: number): boolean {
    if (offset <= 1) {
      return false;
    }
    // 浏览目录时不翻页：目录条目常常刚好铺满一屏（List 无滚动余量），
    // 此时任何下滑都会被判定为「滚到顶继续滑」，用户只觉得刚点进去就被弹回本地页。
    // 回本地页改由页位点 / 胶囊承担，目录内手势只用于列表滚动。
    if (this.isBrowsing()) {
      return false;
    }
    try {
      if (this.listScroller.currentOffset().yOffset > 0) {
        return false;
      }
    } catch (err) {
      return false;
    }
    return this.onPullBack();
  }

  /** 目录条目数变化：通知父级切「半屏/近整页」高度，保证列表有可见高度 */
  onEntriesChanged(): void {
    this.onBrowseChange(this.isBrowsing());
    this.reportContentH();
    this.saveNav();
  }

  /**
   * 浏览态快照：视频页「同屏 / 整页」两种形态各挂一个 NetPanel，
   * 形态切换会销毁旧实例，不落快照就会丢掉协议、地址、当前目录与条目
   * （表现：点进子目录突然回到「待连接」）。
   */
  private saveNav(): void {
    const snap: NetNavSnapshot = new NetNavSnapshot();
    snap.valid = this.currentUrl.length > 0 || this.entries.length > 0;
    snap.proto = this.protocol;
    snap.address = this.address;
    snap.currentUrl = this.currentUrl;
    snap.status = this.status;
    snap.entries = this.entries;
    snap.davUser = this.davUser;
    snap.davPass = this.davPass;
    NetNavStore.save(snap);
  }

  /** 组件重建后读回快照：恢复协议、地址、当前目录、条目与状态文案 */
  private restoreNav(): void {
    const snap: NetNavSnapshot = NetNavStore.peek();
    if (!snap.valid) {
      return;
    }
    this.protocol = snap.proto;
    if (snap.address.length > 0) {
      this.address = snap.address;
    }
    this.currentUrl = snap.currentUrl;
    this.status = snap.status;
    if (snap.davUser.length > 0) {
      this.davUser = snap.davUser;
      this.davPass = snap.davPass;
    }
    // 赋值会触发 @Watch onEntriesChanged，父级据此重算高度与形态
    this.entries = snap.entries;
  }

  /** 浏览目录时内容高度 = 地址工具行 + 条目行；未连接 / 发现 / 空目录只报 0（工具面板不算列表内容） */
  private reportContentH(): void {
    let h: number = 0;
    if (this.isBrowsing()) {
      h = NET_TOOLBAR_H + (this.netSearchOn ? 40 : 0) + this.shownEntries().length * NET_ROW_H;
    }
    this.onContentH(h);
  }

  /** 添加/编辑页回传结果 */
  @StorageLink('net_add_result') @Watch('onAddResult') addResult: string = '';

  onTickChange(): void {
    this.history = NetPrefs.getHistory();
    this.servers = NetPrefs.getServers();
    if (this.protocol === 1) {
      this.davUser = NetPrefs.getDavUser();
      this.davPass = NetPrefs.getDavPass();
    }
  }

  aboutToAppear(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    // SMB 诊断日志落到沙箱 files/logs/smb_*.log；不初始化则日志器不落盘
    SmbLog.setBaseDir(context.filesDir);
    NetPrefs.init(context).then(() => {
      this.history = NetPrefs.getHistory();
      this.servers = NetPrefs.getServers();
      this.davUser = NetPrefs.getDavUser();
      this.davPass = NetPrefs.getDavPass();
      const last: string = NetPrefs.getLastUrl();
      if (last.length > 0 && this.address.length === 0) {
        this.address = last;
      }
      // 形态切换导致的实例重建：读回上一次的浏览态，避免目录浏览被清成「待连接」
      this.restoreNav();
      // 网络页尚未创建时用户就从标题栏「＋」添加了服务器：此处补一次回传处理
      if (this.addResult.length > 0) {
        this.onAddResult();
      }
    });
  }

  /** 添加/编辑页保存后回传：落盘并直接连接 */
  private async onAddResult(): Promise<void> {
    const raw: string = this.addResult;
    if (raw.length === 0) {
      return;
    }
    this.addResult = '';
    let server: NetServer | undefined = undefined;
    let drop: string = '';
    try {
      const obj: Record<string, ESObject> = JSON.parse(raw) as Record<string, ESObject>;
      const s: ESObject = obj['server'];
      const d: ESObject = obj['drop'];
      if (typeof s === 'string') {
        server = NetServer.fromJson(s as string);
      }
      if (typeof d === 'string') {
        drop = d as string;
      }
    } catch (err) {
      return;
    }
    if (server === undefined) {
      return;
    }
    if (drop.length > 0 && drop !== server.key()) {
      await NetPrefs.removeServer(drop);
    }
    this.servers = await NetPrefs.upsertServer(server);
    await this.openServer(server);
  }

  private isDav(): boolean {
    // SMB 走自己的浏览与代理链路，不能落进 WebDAV 分支
    return this.protocol === 1;
  }

  /**
   * 地址栏直接点「连接」时没有协议上下文（protocol 仍是 0）：
   * 与已保存的 WebDAV 服务器同源就按 WebDAV 走，否则 https 目录会被当普通 HTTP 去拉，
   * 请求不带 Basic 认证，服务端一律 401（表现为「WebDAV 突然连不上」）。
   */
  private adoptSavedProto(url: string): void {
    if (this.protocol !== 0) {
      return;
    }
    const scheme: string = NetClient.schemeOf(url);
    if (scheme !== 'http' && scheme !== 'https') {
      return;
    }
    const info: NetUrlInfo = NetClient.parseUrlInfo(url);
    const list: NetServer[] = NetPrefs.getServers();
    for (let i = 0; i < list.length; i++) {
      const s: NetServer = list[i];
      if (s.proto !== 1) {
        continue;
      }
      const si: NetUrlInfo = NetClient.parseUrlInfo(s.url);
      if (si.host.length > 0 && si.host === info.host) {
        this.protocol = 1;
        if (this.davUser.length === 0 && s.user.length > 0) {
          this.davUser = s.user;
          this.davPass = s.pass;
        }
        return;
      }
    }
  }

  private isSmb(): boolean {
    return this.protocol === 2;
  }

  /** 3=FTP，4=DLNA */
  private isFtp(): boolean {
    return this.protocol === 3;
  }

  private isDlna(): boolean {
    return this.protocol === 4;
  }

  /** 交给播放器的地址：WebDAV 凭据不再写进 URL（AVPlayer 带 userinfo 取流会报 5400102） */
  private streamUrl(url: string): string {
    return NetClient.safeUrl(NetClient.stripAuth(url));
  }

  /** 交给播放器的请求头：WebDAV 用 Basic 认证，未填账号则为空 */
  private streamHeaders(): Record<string, string> {
    const h: Record<string, string> = {};
    if (this.isDav() && this.davUser.length > 0) {
      h['Authorization'] = `Basic ${NetClient.basicAuth(this.davUser, this.davPass)}`;
    }
    return h;
  }

  // ---------------- 入口动作 ----------------

  private addServer(): void {
    router.pushUrl({ url: 'pages/NetEditPage' }).catch(() => {
      promptAction.showToast({ message: '编辑页打开失败' });
    });
  }

  private editServer(server: NetServer): void {
    const params: NetEditParams = { server: server.toJson() };
    router.pushUrl({
      url: 'pages/NetEditPage',
      params: params
    }).catch(() => {
      promptAction.showToast({ message: '编辑页打开失败' });
    });
  }

  private async openServer(server: NetServer): Promise<void> {
    this.protocol = server.proto;
    this.address = server.url;
    if (server.proto === 1) {
      this.davUser = server.user;
      this.davPass = server.pass;
      // 记录用户配置的 DAV 根，供「上级」判断顶层（避免爬到站点根）
      this.davRoot = server.url;
      NetPrefs.saveDav(NetClient.davNormalize(server.url), server.user, server.pass).then(() => {
      });
    } else if (server.proto === 2) {
      this.smbUser = server.user;
      this.smbPass = server.pass;
      // 先把账号登记到 SMB 会话表，本地代理按 host:port 取用
      SmbBrowser.useServer(server.url, server.user, server.pass);
    }
    await this.submit();
  }

  private confirmRemoveServer(server: NetServer): void {
    promptAction.showDialog({
      title: '删除服务器',
      message: `将从列表中移除「${server.name}」，不影响家庭网络中的共享本身。`,
      buttons: [
        { text: '取消', color: this.pal().textSecondary },
        { text: '删除', color: this.pal().danger }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index !== 1) {
        return;
      }
      NetPrefs.removeServer(server.key()).then((list: NetServer[]) => {
        this.servers = list;
      });
    }).catch(() => {
    });
  }

  private async startDiscover(): Promise<void> {
    if (this.scanning) {
      return;
    }
    this.showDiscover = true;
    this.scanning = true;
    this.hits = [];
    this.scanDone = 0;
    this.scanTotal = 0;
    this.scanTip = '正在读取本机网段…';
    const result: ScanHit[] = await NetScan.scan((done: number, total: number) => {
      this.scanDone = done;
      this.scanTotal = total;
      this.scanTip = `正在探测 ${done}/${total} 个地址`;
    });
    this.scanning = false;
    this.hits = result;
    if (result.length === 0) {
      this.scanTip = '当前网段没有发现可用的 HTTP/WebDAV 服务；可手动添加地址';
    } else {
      this.scanTip = `发现 ${result.length} 个地址`;
    }
  }

  private onHit(hit: ScanHit): void {
    if (hit.kind === 2) {
      // 探到 SMB 主机：协议预置为 SMB，共享名到添加页里补（如 smb://192.168.1.10/video）
      const smbParams: NetEditParams = { address: `smb://${hit.ip}`, proto: 2 };
      router.pushUrl({
        url: 'pages/NetEditPage',
        params: smbParams
      }).catch(() => {
        promptAction.showToast({ message: '编辑页打开失败' });
      });
      return;
    }
    const params: NetEditParams = { address: hit.url(), proto: hit.kind };
    router.pushUrl({
      url: 'pages/NetEditPage',
      params: params
    }).catch(() => {
      promptAction.showToast({ message: '编辑页打开失败' });
    });
  }

  // ---------------- 目录与播放 ----------------

  private async submit(): Promise<void> {
    const url: string = NetClient.normalize(this.address);
    if (url.length === 0) {
      promptAction.showToast({ message: '请先输入局域网地址' });
      return;
    }
    const scheme: string = NetClient.schemeOf(url);
    if (scheme === 'smb' || scheme === 'cifs') {
      this.address = url;
      // 协议标记同步成 SMB，避免工具栏/上级判定仍按 HTTP 处理
      this.protocol = 2;
      await this.loadSmb(url);
      return;
    }
    if (scheme === 'ftp') {
      this.address = url;
      this.protocol = 3;
      await this.loadFtp(url);
      return;
    }
    if (scheme === 'dlna' || scheme === 'upnp') {
      this.address = url;
      this.protocol = 4;
      this.dlnaPath = [url];
      await this.loadDlna(url);
      return;
    }
    this.address = url;
    // 地址栏/根地址直接连接时补齐协议上下文，避免 https 目录被当普通 HTTP 拉取而 401
    this.adoptSavedProto(url);
    if (this.isDav()) {
      if (this.davRoot.length === 0) {
        this.davRoot = url;
      }
      NetPrefs.saveDav(NetClient.davNormalize(url), this.davUser, this.davPass).then(() => {
      });
      if (NetClient.isPlayable(url)) {
        this.playUrl(url, NetClient.pureName(url));
        return;
      }
      await this.loadDav(url);
      return;
    }
    if (NetClient.isPlayable(url)) {
      this.playUrl(url, NetClient.pureName(url));
      return;
    }
    await this.loadDir(url);
  }

  private async loadDav(url: string): Promise<void> {
    const target: string = NetClient.davNormalize(url);
    if (target === 'https://' || target === 'http://') {
      promptAction.showToast({ message: '请输入完整 WebDAV 地址，例如 https://dav.example.com/dav/' });
      return;
    }
    this.loading = true;
    this.status = '正在连接…';
    this.currentUrl = target;
    this.address = target;
    let res: NetResult = await NetClient.davList(target, this.davUser, this.davPass, 12000);
    let base: string = res.url.length > 0 ? res.url : target;
    let list: NetEntry[] = res.ok ? NetClient.parseDav(base, res.body) : [];
    if (res.ok && list.length === 0) {
      // 具名 prop 取不到内容时，换 allprop 再试一次（部分 NAS 只对 allprop 返回完整 response）
      const res2: NetResult = await NetClient.davList(target, this.davUser, this.davPass, 12000, true);
      const list2: NetEntry[] = res2.ok ? NetClient.parseDav(res2.url.length > 0 ? res2.url : target, res2.body) : [];
      if (list2.length > 0) {
        res = res2;
        base = res2.url.length > 0 ? res2.url : target;
        list = list2;
      } else {
        res.detail = res2.detail.length > 0 ? `${res.detail}\nallprop：${res2.detail}` : res.detail;
      }
    }
    this.loading = false;
    if (!res.ok) {
      this.entries = [];
      this.status = res.message.length > 0 ? res.message : '无法访问该 WebDAV 地址';
      if (res.detail.length > 0) {
        this.status = `${this.status}\n${res.detail}`;
      }
      return;
    }
    this.entries = list;
    // 空目录时把解析统计 + 响应诊断一并回显：可区分服务端真空、跳转、压缩体、解析失败、条目被全部过滤
    const stats: string = NetClient.davStats;
    const trailTip: string = res.attempts.length > 0 && res.attempts !== `${base}` ? `\n跳转：${res.attempts}` : '';
    this.status = list.length === 0
      ? `该目录为空或无可列出条目\n${stats.length > 0 ? `${stats}\n` : ''}${res.detail}${trailTip}`
      : `共 ${list.length} 项`;
    NetPrefs.pushHistory(base).then(() => {
      this.history = NetPrefs.getHistory();
    });
    this.saveNav();
  }

  private async loadDir(url: string): Promise<void> {
    this.loading = true;
    this.status = '正在连接…';
    this.currentUrl = url;
    const res: NetResult = await NetClient.fetch(url, 8000);
    this.loading = false;
    if (!res.ok) {
      this.entries = [];
      this.status = res.message.length > 0 ? res.message : '无法访问该地址';
      return;
    }
    const list: NetEntry[] = NetClient.parseListing(url, res.body);
    this.entries = list;
    if (list.length === 0) {
      this.status = '该地址没有可列出的条目，可能不支持目录浏览；可直接填视频完整地址播放';
    } else {
      this.status = `共 ${list.length} 项`;
    }
    NetPrefs.pushHistory(url).then(() => {
      this.history = NetPrefs.getHistory();
    });
    this.saveNav();
  }

  /** SMB：连共享、列目录（smb 地址里的共享名必须填） */
  private async loadSmb(url: string): Promise<void> {
    const why: string = SmbBrowser.checkUrl(url);
    if (why.length > 0) {
      promptAction.showToast({ message: why });
      return;
    }
    if (this.smbUser.length > 0 || this.smbPass.length > 0) {
      SmbBrowser.useServer(url, this.smbUser, this.smbPass);
    }
    this.loading = true;
    this.status = '正在连接共享…';
    this.currentUrl = url;
    this.address = url;
    let list: SmbDirEntry[] = [];
    try {
      list = await SmbBrowser.listDir(url);
    } catch (err) {
      this.loading = false;
      this.entries = [];
      const why2: string = (err as Error).message;
      const logPath: string = SmbLog.currentFilePath();
      // 把诊断日志路径一并显示：用户可用 hdc file recv 直接取回原始报文
      this.status = logPath.length > 0 ? `${why2}\n诊断日志：${logPath}` : why2;
      return;
    }
    this.loading = false;
    const out: NetEntry[] = [];
    for (let i = 0; i < list.length; i++) {
      out.push(new NetEntry(list[i].name, SmbBrowser.childUrl(url, list[i].name), list[i].isDir, list[i].size));
    }
    this.entries = out;
    this.status = out.length === 0 ? '该目录为空' : `共 ${out.length} 项`;
    NetPrefs.pushHistory(url).then(() => {
      this.history = NetPrefs.getHistory();
    });
  }

  /** SMB 播放：同目录可播放项统一换成 127.0.0.1 代理地址后再进播放页 */
  private async playSmb(entry: NetEntry): Promise<void> {
    if (!NetClient.isVideoName(entry.name)) {
      promptAction.showToast({ message: '该文件不是可播放的视频' });
      return;
    }
    const videos: NetEntry[] = this.entries.filter((e: NetEntry) => !e.isDir && NetClient.isVideoName(e.name));
    const noHeaders: Record<string, string> = {};
    const folder: string = SmbBrowser.titleOf(this.currentUrl);
    const items: VideoItem[] = [];
    let start: number = 0;
    for (let i = 0; i < videos.length; i++) {
      let httpUrl: string = '';
      try {
        httpUrl = await SmbProxy.urlFor(videos[i].url);
      } catch (err) {
        httpUrl = '';
      }
      if (httpUrl.length === 0) {
        continue;
      }
      items.push(new VideoItem(httpUrl, stripExt(videos[i].name), 0, videos[i].sizeBytes, 0, 0, folder, '',
        items.length, noHeaders));
      if (videos[i].url === entry.url) {
        start = items.length - 1;
      }
    }
    if (items.length === 0) {
      promptAction.showToast({ message: '无法生成播放地址，请检查共享权限' });
      return;
    }
    PlaylistHolder.set(items, start);
    router.pushUrl({ url: 'pages/PlayerPage' });
  }

  // ---------------- FTP ----------------

  /** 打开 FTP 配置弹层（沿用添加服务器的字段风格） */
  private openFtp(): void {
    if (this.ftpHost.length === 0 && this.address.startsWith('ftp://')) {
      const t: FtpTarget | undefined = FtpUrl.parse(this.address);
      if (t !== undefined) {
        this.ftpHost = t.host;
        this.ftpPort = `${t.port}`;
      }
    }
    this.ftpOpen = true;
  }

  /** 匿名勾选时账号密码留空，交给 FtpBrowser 按 anonymous 登录 */
  private async connectFtp(): Promise<void> {
    const raw: string = this.ftpHost.trim();
    if (raw.length === 0) {
      promptAction.showToast({ message: '请填写 FTP 服务器地址' });
      return;
    }
    const withScheme: string = raw.startsWith('ftp://') ? raw : `ftp://${raw}`;
    const parsed: FtpTarget | undefined = FtpUrl.parse(withScheme);
    if (parsed === undefined) {
      promptAction.showToast({ message: 'FTP 服务器地址格式不正确' });
      return;
    }
    let port: number = parsed.port > 0 ? parsed.port : 21;
    const typed: number = Number.parseInt(this.ftpPort, 10);
    if (!Number.isNaN(typed) && typed > 0 && typed < 65536) {
      port = typed;
    }
    const user: string = this.ftpAnon ? '' : this.ftpUser;
    const pass: string = this.ftpAnon ? '' : this.ftpPass;
    const url: string = `ftp://${parsed.host}:${port}/`;
    if (FtpBrowser.useServer(url, user, pass, this.ftpPassive) === undefined) {
      promptAction.showToast({ message: 'FTP 地址无法解析' });
      return;
    }
    this.protocol = 3;
    this.address = url;
    this.ftpOpen = false;
    await this.loadFtp(url);
  }

  /** 列 FTP 目录（MLSD 优先，回退 LIST/NLST，UTF-8 失败按 GB18030 解码） */
  private async loadFtp(url: string): Promise<void> {
    if (url.indexOf('ftp://') !== 0) {
      promptAction.showToast({ message: 'FTP 地址需以 ftp:// 开头' });
      return;
    }
    this.loading = true;
    this.status = '正在连接 FTP…';
    this.currentUrl = url;
    this.address = url;
    let list: FtpEntry[] = [];
    try {
      list = await FtpBrowser.listDir(url);
    } catch (err) {
      this.loading = false;
      this.entries = [];
      this.status = (err as Error).message;
      return;
    }
    this.loading = false;
    const out: NetEntry[] = [];
    for (let i = 0; i < list.length; i++) {
      out.push(new NetEntry(list[i].name, FtpUrl.childUrl(url, list[i].name, list[i].isDir), list[i].isDir,
        list[i].size));
    }
    this.entries = out;
    this.status = out.length === 0 ? '该目录为空' : `共 ${out.length} 项 · ${FtpBrowser.note}`;
    NetPrefs.pushHistory(url).then(() => {
      this.history = NetPrefs.getHistory();
    });
  }

  /** FTP 播放：同目录视频统一换成 127.0.0.1 代理地址（Range 支持拖动） */
  private async playFtp(entry: NetEntry): Promise<void> {
    if (!NetClient.isVideoName(entry.name)) {
      promptAction.showToast({ message: '该文件不是可播放的视频' });
      return;
    }
    this.loading = true;
    this.status = '正在建立 FTP 数据通道…';
    const videos: NetEntry[] = this.entries.filter((e: NetEntry) => !e.isDir && NetClient.isVideoName(e.name));
    const noHeaders: Record<string, string> = {};
    const folder: string = FtpUrl.titleOf(this.currentUrl);
    const items: VideoItem[] = [];
    let start: number = 0;
    for (let i = 0; i < videos.length; i++) {
      let httpUrl: string = '';
      try {
        httpUrl = await FtpProxy.urlFor(videos[i].url);
      } catch (err) {
        httpUrl = '';
      }
      if (httpUrl.length === 0) {
        continue;
      }
      items.push(new VideoItem(httpUrl, stripExt(videos[i].name), 0, videos[i].sizeBytes, 0, 0, folder, '',
        items.length, noHeaders));
      if (videos[i].url === entry.url) {
        start = items.length - 1;
      }
    }
    this.loading = false;
    if (items.length === 0) {
      promptAction.showToast({ message: 'FTP 取流失败，请检查账号权限或改用被动模式' });
      return;
    }
    PlaylistHolder.set(items, start);
    router.pushUrl({ url: 'pages/PlayerPage' });
  }

  // ---------------- DLNA ----------------

  /** 打开 DLNA 发现弹层（SSDP M-SEARCH，ST=MediaServer） */
  private async openDlna(): Promise<void> {
    this.dlnaOpen = true;
    await this.scanDlna();
  }

  private async scanDlna(): Promise<void> {
    if (this.dlnaBusy) {
      return;
    }
    this.dlnaBusy = true;
    this.dlnaError = '';
    this.dlnaTip = '正在搜索局域网内的 DLNA 媒体服务器…';
    const list: DlnaServer[] = await DlnaBrowser.discover(2600);
    this.dlnaBusy = false;
    this.dlnaServers = list;
    if (list.length === 0) {
      const why: string = DlnaBrowser.errorText;
      this.dlnaError = why.length > 0 ? why : '没有发现媒体服务器，请确认设备与播放器在同一局域网';
      this.dlnaTip = '未发现设备';
    } else {
      this.dlnaTip = `发现 ${list.length} 台设备`;
    }
  }

  private async openDlnaServer(server: DlnaServer): Promise<void> {
    this.dlnaOpen = false;
    this.protocol = 4;
    const root: string = DlnaBrowser.rootUri(server.udn);
    this.dlnaPath = [root];
    await this.loadDlna(root);
  }

  private async loadDlna(uri: string): Promise<void> {
    this.loading = true;
    this.status = '正在浏览 DLNA 目录…';
    this.currentUrl = uri;
    this.address = uri;
    const list: DlnaEntry[] = await DlnaBrowser.listDir(uri);
    this.loading = false;
    this.dlnaItems = list;
    if (list.length === 0) {
      this.entries = [];
      const why: string = DlnaBrowser.errorText;
      this.status = why.length > 0 ? why : '该目录为空';
      return;
    }
    const out: NetEntry[] = [];
    for (let i = 0; i < list.length; i++) {
      out.push(new NetEntry(list[i].name, list[i].uri, list[i].isDir, 0));
    }
    this.entries = out;
    this.status = `共 ${out.length} 项`;
    NetPrefs.pushHistory(uri).then(() => {
      this.history = NetPrefs.getHistory();
    });
  }

  /** DLNA 播放：直接吃服务器给出的 http 直链 */
  private async playDlna(entry: NetEntry): Promise<void> {
    if (!NetClient.isVideoName(entry.name)) {
      promptAction.showToast({ message: '该文件不是可播放的视频' });
      return;
    }
    const videos: DlnaEntry[] = this.dlnaItems.filter((e: DlnaEntry) => !e.isDir &&
      NetClient.isVideoName(e.name) && e.playUrl.length > 0);
    if (videos.length === 0) {
      promptAction.showToast({ message: '该文件没有可播放的直链' });
      return;
    }
    const noHeaders: Record<string, string> = {};
    const folder: string = entry.name;
    const items: VideoItem[] = [];
    let start: number = 0;
    for (let i = 0; i < videos.length; i++) {
      items.push(new VideoItem(videos[i].playUrl, stripExt(videos[i].name), 0, 0, 0, 0, folder, '', i, noHeaders));
      if (videos[i].uri === entry.url) {
        start = i;
      }
    }
    PlaylistHolder.set(items, start);
    router.pushUrl({ url: 'pages/PlayerPage' });
  }

  private async goParent(): Promise<void> {
    if (this.isDlna() || this.currentScheme() === 'dlna' || this.currentScheme() === 'upnp') {
      if (this.dlnaPath.length <= 1) {
        promptAction.showToast({ message: '已经是顶层目录' });
        return;
      }
      this.dlnaPath.pop();
      await this.loadDlna(this.dlnaPath[this.dlnaPath.length - 1]);
      return;
    }
    if (this.isFtp() || this.currentScheme() === 'ftp') {
      const up: string = FtpUrl.parentOf(this.currentUrl);
      if (up === this.currentUrl) {
        promptAction.showToast({ message: '已经是顶层目录' });
        return;
      }
      this.address = up;
      await this.loadFtp(up);
      return;
    }
    if (this.isSmbUrl()) {
      // SMB 必须用 SmbBrowser 的父路径算法：通用 parentOf 会把 smb://host/共享 再削一层成 smb://host/（无共享名，列不出来）
      const up: string = SmbBrowser.parentOf(this.currentUrl);
      // 共享根 / 地址写法异常（父路径算回自身、算成无共享名的 smb://host/）一律退回服务器列表
      if (up.length === 0 || this.trimSlash(up) === this.trimSlash(this.currentUrl) ||
        SmbBrowser.checkUrl(this.trimSlash(up)).length > 0) {
        this.backToServers();
        return;
      }
      this.address = up;
      await this.loadSmb(up);
      return;
    }
    const parent: string = NetClient.parentOf(this.currentUrl);
    if (parent.length === 0) {
      promptAction.showToast({ message: '已经是顶层目录' });
      return;
    }
    this.address = parent;
    if (this.isDav()) {
      await this.loadDav(parent);
    } else {
      await this.loadDir(parent);
    }
  }

  private async refresh(): Promise<void> {
    if (this.currentUrl.length === 0) {
      await this.submit();
      return;
    }
    if (this.isFtp()) {
      await this.loadFtp(this.currentUrl);
      return;
    }
    if (this.isDlna()) {
      await this.loadDlna(this.currentUrl);
      return;
    }
    if (this.isSmb()) {
      await this.loadSmb(this.currentUrl);
      return;
    }
    if (this.isDav()) {
      await this.loadDav(this.currentUrl);
      return;
    }
    await this.loadDir(this.currentUrl);
  }

  private onEntry(entry: NetEntry): void {
    if (entry.isDir) {
      this.address = entry.url;
      if (this.isFtp()) {
        this.loadFtp(entry.url);
      } else if (this.isDlna()) {
        this.dlnaPath.push(entry.url);
        this.loadDlna(entry.url);
      } else if (this.isSmb()) {
        this.loadSmb(entry.url);
      } else if (this.isDav()) {
        this.loadDav(entry.url);
      } else {
        this.loadDir(entry.url);
      }
      return;
    }
    if (this.isFtp()) {
      this.playFtp(entry);
      return;
    }
    if (this.isDlna()) {
      this.playDlna(entry);
      return;
    }
    if (this.isSmb()) {
      this.playSmb(entry);
      return;
    }
    if (!NetClient.isVideoName(entry.name)) {
      promptAction.showToast({ message: '该文件不是可播放的视频' });
      return;
    }
    const videos: NetEntry[] = this.entries.filter((e: NetEntry) => !e.isDir && NetClient.isVideoName(e.name));
    const items: VideoItem[] = [];
    const hdrs: Record<string, string> = this.streamHeaders();
    let start: number = 0;
    for (let i = 0; i < videos.length; i++) {
      items.push(new VideoItem(this.streamUrl(videos[i].url), stripExt(videos[i].name), 0, videos[i].sizeBytes, 0, 0,
        NetClient.pureName(this.currentUrl), '', i, hdrs));
      if (videos[i].url === entry.url) {
        start = i;
      }
    }
    PlaylistHolder.set(items, start);
    router.pushUrl({ url: 'pages/PlayerPage' });
  }

  private playUrl(url: string, name: string): void {
    const title: string = stripExt(name.length > 0 ? name : url);
    const items: VideoItem[] = [new VideoItem(this.streamUrl(url), title, 0, 0, 0, 0, '网络', '', 0,
      this.streamHeaders())];
    PlaylistHolder.set(items, 0);
    NetPrefs.pushHistory(url).then(() => {
      this.history = NetPrefs.getHistory();
    });
    router.pushUrl({ url: 'pages/PlayerPage' });
  }

  private useHistory(url: string): void {
    this.address = url;
    if (NetClient.isPlayable(url)) {
      this.playUrl(url, NetClient.pureName(url));
    } else if (this.isDav()) {
      this.loadDav(url);
    } else {
      this.loadDir(url);
    }
  }

  // ---------------- 视图 ----------------

  /** 在线视频入口：进入 TvBoxHarmony 移植的影视点播/直播模块 */
  @Builder
  tvEntry() {
    Column() {
      this.navCard('📺', '在线视频', '影视点播 · 电视直播 · 网盘播放', '进入 ›', true, '#2F6BE0', () => {
        router.pushUrl({ url: 'tvbox/pages/HomePage' }).catch(() => {
          promptAction.showToast({ message: '在线视频页面打开失败' });
        });
      })
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 2 })
  }

  /** 通用入口卡片：在线视频 / 局域网入口共用同一套渐变卡片样式 */
  @Builder
  navCard(icon: string, title: string, subtitle: string, tag: string, active: boolean, gradientStart: string,
    action: () => void) {
    Row() {
      Text(icon)
        .fontSize(20)
        .width(34)
        .textAlign(TextAlign.Center)
      Column() {
        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(active ? '#FFFFFF' : this.pal().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(subtitle)
          .fontSize(11)
          .fontColor(active ? '#CCFFFFFF' : this.pal().textSecondary)
          .margin({ top: 3 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 8 })

      if (tag.length > 0) {
        Text(tag)
          .fontSize(13)
          .fontColor('#E6FFFFFF')
      }
    }
    .width('100%')
    .height(62)
    .padding({ left: 12, right: 14 })
    .borderRadius(14)
    .linearGradient({
      angle: 90,
      colors: active
        ? [[gradientStart, 0.0], ['#7B4BE0', 1.0]]
        : [[this.pal().bgCard, 0.0], [this.pal().bgCard, 1.0]]
    })
    .border({ width: 1, color: active ? '#00000000' : this.pal().divider })
    .onClick(action)
  }

  /** 局域网来源入口：SMB / FTP / DLNA 并列 */
  @Builder
  sourceRow() {
    Row({ space: 8 }) {
      this.sourceChip('💾', 'SMB', this.isSmb(), () => {
        const params: NetEditParams = { address: 'smb://', proto: 2 };
        router.pushUrl({
          url: 'pages/NetEditPage',
          params: params
        }).catch(() => {
          promptAction.showToast({ message: '编辑页打开失败' });
        });
      })
      this.sourceChip('📂', 'FTP', this.isFtp(), () => {
        this.openFtp();
      })
      this.sourceChip('📡', 'DLNA', this.isDlna(), () => {
        this.openDlna();
      })
      Blank()
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 6, bottom: 2 })
  }

  @Builder
  sourceChip(icon: string, label: string, active: boolean, action: () => void) {
    Row() {
      Text(icon)
        .fontSize(13)
      Text(label)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(active ? Color.White : this.pal().textPrimary)
        .margin({ left: 4 })
    }
    .height(32)
    .padding({ left: 10, right: 12 })
    .borderRadius(16)
    .backgroundColor(active ? this.pal().primary : this.pal().bgChip)
    .onClick(action)
  }

  /** FTP 配置弹层：地址 / 端口 / 用户名 / 密码 / 匿名 / 被动模式 */
  @Builder
  ftpPanel() {
    Column() {
      Column() {
        Row() {
          Text('FTP 服务器')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal().textPrimary)
            .layoutWeight(1)
          Text('关闭')
            .fontSize(13)
            .fontColor(this.pal().textSecondary)
            .height(28)
            .padding({ left: 10, right: 10 })
            .borderRadius(14)
            .backgroundColor(this.pal().bgChip)
            .onClick(() => {
              this.ftpOpen = false;
            })
        }
        .width('100%')
        .height(40)

        Row() {
          TextInput({ placeholder: '192.168.1.10 或 ftp://192.168.1.10', text: this.ftpHost })
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .backgroundColor(this.pal().bgChip)
            .fontColor(this.pal().textPrimary)
            .placeholderColor(this.pal().textTertiary)
            .onChange((v: string) => {
              this.ftpHost = v;
            })
          TextInput({ placeholder: '21', text: this.ftpPort })
            .width(70)
            .height(40)
            .fontSize(14)
            .margin({ left: 8 })
            .type(InputType.Number)
            .backgroundColor(this.pal().bgChip)
            .fontColor(this.pal().textPrimary)
            .placeholderColor(this.pal().textTertiary)
            .onChange((v: string) => {
              this.ftpPort = v;
            })
        }
        .width('100%')
        .margin({ top: 8 })

        Row() {
          Toggle({ type: ToggleType.Switch, isOn: this.ftpAnon })
            .onChange((v: boolean) => {
              this.ftpAnon = v;
            })
          Text('匿名登录')
            .fontSize(13)
            .fontColor(this.pal().textPrimary)
            .margin({ left: 8 })
            .layoutWeight(1)
          Text('被动模式')
            .fontSize(13)
            .fontColor(this.pal().textSecondary)
            .margin({ right: 8 })
          Toggle({ type: ToggleType.Switch, isOn: this.ftpPassive })
            .onChange((v: boolean) => {
              this.ftpPassive = v;
            })
        }
        .width('100%')
        .margin({ top: 8 })

        if (!this.ftpAnon) {
          TextInput({ placeholder: '用户名，如 admin', text: this.ftpUser })
            .width('100%')
            .height(40)
            .fontSize(14)
            .margin({ top: 8 })
            .backgroundColor(this.pal().bgChip)
            .fontColor(this.pal().textPrimary)
            .placeholderColor(this.pal().textTertiary)
            .onChange((v: string) => {
              this.ftpUser = v;
            })
          TextInput({ placeholder: '密码', text: this.ftpPass })
            .width('100%')
            .height(40)
            .fontSize(14)
            .margin({ top: 8 })
            .type(InputType.Password)
            .backgroundColor(this.pal().bgChip)
            .fontColor(this.pal().textPrimary)
            .placeholderColor(this.pal().textTertiary)
            .onChange((v: string) => {
              this.ftpPass = v;
            })
        }

        Row() {
          Text('取消')
            .fontSize(14)
            .fontColor(this.pal().textSecondary)
            .height(40)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .borderRadius(12)
            .backgroundColor(this.pal().bgChip)
            .onClick(() => {
              this.ftpOpen = false;
            })
          Text('连接')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .height(40)
            .layoutWeight(1)
            .margin({ left: 10 })
            .textAlign(TextAlign.Center)
            .borderRadius(12)
            .backgroundColor(this.pal().primary)
            .onClick(() => {
              this.connectFtp();
            })
        }
        .width('100%')
        .margin({ top: 12 })

        Text('· 默认被动模式；老服务器/防火墙拦截可切主动模式\n' +
          '· 目录优先 MLSD，回退 LIST/NLST；中文乱码按 GB18030 回退解码')
          .fontSize(11)
          .fontColor(this.pal().textTertiary)
          .lineHeight(17)
          .width('100%')
          .margin({ top: 10 })
      }
      .width('86%')
      .padding(16)
      .borderRadius(16)
      .backgroundColor(this.pal().bgCard)
      .border({ width: 1, color: this.pal().divider })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#66000000')
  }

  /** DLNA 设备发现弹层：发现中 / 无设备 / 错误态 / 设备列表 */
  @Builder
  dlnaPanel() {
    Column() {
      Column() {
        Row() {
          Text('DLNA 媒体服务器')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal().textPrimary)
            .layoutWeight(1)
          Text('关闭')
            .fontSize(13)
            .fontColor(this.pal().textSecondary)
            .height(28)
            .padding({ left: 10, right: 10 })
            .borderRadius(14)
            .backgroundColor(this.pal().bgChip)
            .onClick(() => {
              this.dlnaOpen = false;
            })
        }
        .width('100%')
        .height(40)

        Row() {
          if (this.dlnaBusy) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(this.pal().primary)
              .margin({ right: 8 })
          }
          Text(this.dlnaTip.length > 0 ? this.dlnaTip : '准备搜索')
            .fontSize(12)
            .fontColor(this.pal().textTertiary)
            .layoutWeight(1)
            .maxLines(2)
          if (!this.dlnaBusy) {
            Text('重新搜索')
              .fontSize(12)
              .fontColor(this.pal().primary)
              .height(28)
              .padding({ left: 10, right: 10 })
              .borderRadius(14)
              .backgroundColor(this.pal().bgChip)
              .onClick(() => {
                this.scanDlna();
              })
          }
        }
        .width('100%')
        .height(34)

        List({ space: 0 }) {
          ForEach(this.dlnaServers, (server: DlnaServer) => {
            ListItem() {
              Row() {
                Text('📡')
                  .fontSize(18)
                  .width(32)
                  .textAlign(TextAlign.Center)
                Column() {
                  Text(server.name)
                    .fontSize(15)
                    .fontColor(this.pal().textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(server.subtitle)
                    .fontSize(12)
                    .fontColor(this.pal().textSecondary)
                    .margin({ top: 3 })
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .padding({ left: 8 })

                Text('浏览')
                  .fontSize(12)
                  .fontColor(this.pal().primary)
                  .height(30)
                  .padding({ left: 12, right: 12 })
                  .borderRadius(15)
                  .backgroundColor(this.pal().bgChip)
              }
              .width('100%')
              .height(56)
              .onClick(() => {
                this.openDlnaServer(server);
              })
            }
          }, (server: DlnaServer) => `dlna_${server.udn}`)
        }
        .width('100%')
        .height(this.dlnaServers.length > 0 ? Math.min(240, this.dlnaServers.length * 56) : 0)
        .divider({ strokeWidth: 0.5, color: this.pal().divider, startMargin: 40 })
        .scrollBar(BarState.Off)

        if (this.dlnaError.length > 0) {
          Text(this.dlnaError)
            .fontSize(12)
            .fontColor(this.pal().danger)
            .lineHeight(18)
            .width('100%')
            .margin({ top: 8 })
        }
        if (!this.dlnaBusy && this.dlnaServers.length === 0) {
          Text('· 请确认播放器与 NAS/电视连在同一个 Wi-Fi（组播 239.255.255.250:1900）\n' +
            '· 部分路由器默认屏蔽组播，可改用 SMB / FTP 直接访问\n' +
            '· 若设备仅支持投屏不接受浏览，可用播放页的投屏按钮')
            .fontSize(11)
            .fontColor(this.pal().textTertiary)
            .lineHeight(17)
            .width('100%')
            .margin({ top: 8 })
        }
      }
      .width('86%')
      .padding(16)
      .borderRadius(16)
      .backgroundColor(this.pal().bgCard)
      .border({ width: 1, color: this.pal().divider })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#66000000')
  }

  @Builder
  actionRow() {
    Row({ space: 10 }) {
      Row() {
        Text('＋')
          .fontSize(17)
          .fontColor(Color.White)
        Text('添加服务器')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .margin({ left: 4 })
      }
      .layoutWeight(1)
      .height(44)
      .borderRadius(12)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.pal().primary)
      .onClick(() => {
        this.addServer();
      })

      Row() {
        Text('发现设备')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().textPrimary)
      }
      .layoutWeight(1)
      .height(44)
      .borderRadius(12)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.pal().bgCard)
      .border({ width: 1, color: this.pal().divider })
      .onClick(() => {
        this.startDiscover();
      })
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 10, bottom: 4 })
  }

  @Builder
  serverSection() {
    if (this.servers.length > 0) {
      Column() {
        Row() {
          Text('我的服务器')
            .fontSize(12)
            .fontColor(this.pal().textTertiary)
            .layoutWeight(1)
          Text(`${this.servers.length}`)
            .fontSize(12)
            .fontColor(this.pal().textTertiary)
        }
        .width('100%')
        .padding({ top: 10, bottom: 4 })

        ForEach(this.servers, (server: NetServer) => {
          Row() {
            Text(server.proto === 1 ? '☁️' : (server.proto === 2 ? '💾' : '🗄️'))
              .fontSize(18)
              .width(32)
              .textAlign(TextAlign.Center)
            Column() {
              Text(server.name)
                .fontSize(15)
                .fontColor(this.pal().textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(`${server.protoLabel()} · ${server.subtitle()}`)
                .fontSize(12)
                .fontColor(this.pal().textSecondary)
                .margin({ top: 3 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 8 })

            Text('编辑')
              .fontSize(12)
              .fontColor(this.pal().textSecondary)
              .height(30)
              .padding({ left: 10, right: 10 })
              .borderRadius(15)
              .backgroundColor(this.pal().bgChip)
              .onClick(() => {
                this.editServer(server);
              })

            Text('删除')
              .fontSize(12)
              .fontColor(this.pal().danger)
              .height(30)
              .padding({ left: 10, right: 10 })
              .borderRadius(15)
              .backgroundColor(this.pal().bgChip)
              .margin({ left: 6 })
              .onClick(() => {
                this.confirmRemoveServer(server);
              })
          }
          .width('100%')
          .height(56)
          .onClick(() => {
            this.openServer(server);
          })
          .gesture(LongPressGesture().onAction(() => {
            this.confirmRemoveServer(server);
          }))
        }, (server: NetServer) => `srv_${server.key()}`)
      }
      .width('100%')
      .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 2 })
    }
  }

  /** 是否已进入目录浏览（有可列出条目）：浏览态收起顶部固定区块，把高度让给列表 */
  private isBrowsing(): boolean {
    // 不能只看条目数：进入新目录/刷新时 entries 会先被清空再回填，
    // 这一瞬间若判成「非浏览」，父级会认为网络区没内容而回落同屏形态，
    // NetPanel 被销毁重建，用户看到的就是「一点目录就被弹回服务器列表」。
    return !this.showDiscover && (this.entries.length > 0 || this.currentUrl.length > 0);
  }

  /** 退出浏览，回到「我的服务器」列表 */
  private backToServers(): void {
    this.entries = [];
    this.status = '';
    this.loading = false;
    this.currentUrl = '';
    this.address = '';
    // 搜索/排序是目录内的临时态，回列表一并收起
    this.netSearchOn = false;
    this.netKeyword = '';
    // 服务器列表以磁盘为准重读一次：避免内存里的 servers 被清/过期后回列表是空的
    this.servers = NetPrefs.getServers();
    this.protocol = 0;
    this.dlnaPath = [];
    // 主动退出不保留浏览态，避免下次进页还看到旧目录
    NetNavStore.clear();
    // 通知父级恢复「非浏览」形态：不通知的话父级仍按整页目录排版，列表会被挤出可视区
    this.onBrowseChange(false);
    this.reportContentH();
    this.saveNav();
  }

  @Builder
  addressBar() {
    Column() {
      if (!this.isBrowsing()) {
        Row() {
          TextInput({
            placeholder: this.isSmb() ? 'smb://192.168.1.10/video'
              : (this.isDav() ? 'https://dav.example.com/dav/' : '192.168.1.10:8080 或 http://…/video.mp4'),
            text: this.address
          })
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .backgroundColor(this.pal().bgChip)
            .fontColor(this.pal().textPrimary)
            .placeholderColor(this.pal().textTertiary)
            .enterKeyType(EnterKeyType.Go)
            .onChange((v: string) => {
              this.address = v;
            })
            .onSubmit(() => {
              this.submit();
            })
          Button('连接')
            .fontSize(14)
            .height(40)
            .margin({ left: 8 })
            .backgroundColor(this.pal().primary)
            .fontColor(Color.White)
            .onClick(() => {
              this.submit();
            })
        }
        .width('100%')
      }

      Row() {
        this.plainAction('‹ 上级', () => {
          this.onUpAction();
        })
        this.plainAction('刷新', () => {
          this.refresh();
        })
        Text(this.loading ? '连接中' : (this.status.length > 0 ? this.status : '待连接'))
          .fontSize(12)
          .fontColor(this.pal().textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .flexShrink(1)
          .constraintSize({ maxWidth: '32%' })
          .margin({ left: 2 })
        Blank()
        if (this.isBrowsing()) {
          this.plainAction(this.netSortLabel(), () => {
            this.openNetSortMenu();
          })
          this.plainAction(this.netSearchOn ? '收起' : '搜索', () => {
            this.toggleNetSearch();
          })
        }
      }
      .width('100%')
      .height(36)
      .margin({ top: 4 })

      if (this.netSearchOn && this.isBrowsing()) {
        Row() {
          TextInput({ placeholder: '在当前目录搜索', text: this.netKeyword })
            .layoutWeight(1)
            .height(34)
            .fontSize(13)
            .backgroundColor(this.pal().bgChip)
            .fontColor(this.pal().textPrimary)
            .placeholderColor(this.pal().textTertiary)
            .borderRadius(17)
            .enterKeyType(EnterKeyType.Search)
            .onChange((v: string) => {
              this.netKeyword = v;
              this.reportContentH();
            })
        }
        .width('100%')
        .height(40)
        .padding({ bottom: 4 })
      }
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 6, bottom: 4 })
  }

  @Builder
  discoverView() {
    Column() {
      Row() {
        Text('发现设备')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().textPrimary)
          .layoutWeight(1)
        Text('关闭')
          .fontSize(13)
          .fontColor(this.pal().textSecondary)
          .height(30)
          .padding({ left: 10, right: 10 })
          .borderRadius(15)
          .backgroundColor(this.pal().bgChip)
          .onClick(() => {
            this.showDiscover = false;
          })
      }
      .width('100%')
      .height(44)

      Row() {
        if (this.scanning) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(this.pal().primary)
            .margin({ right: 8 })
        }
        Text(this.scanTip.length > 0 ? this.scanTip : '准备扫描')
          .fontSize(12)
          .fontColor(this.pal().textTertiary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (!this.scanning) {
          Text('重新扫描')
            .fontSize(12)
            .fontColor(this.pal().primary)
            .height(28)
            .padding({ left: 10, right: 10 })
            .borderRadius(14)
            .backgroundColor(this.pal().bgChip)
            .onClick(() => {
              this.startDiscover();
            })
        }
      }
      .width('100%')
      .height(36)

      if (this.scanning) {
        Progress({ value: this.scanDone, total: Math.max(this.scanTotal, 1), type: ProgressType.Linear })
          .width('100%')
          .height(4)
          .color(this.pal().primary)
          .margin({ top: 4 })
      }

      List({ space: 0 }) {
        ForEach(this.hits, (hit: ScanHit) => {
          ListItem() {
            Row() {
              Text(hit.kind === 2 ? '💻' : (hit.kind === 1 ? '☁️' : '🗄️'))
                .fontSize(18)
                .width(32)
                .textAlign(TextAlign.Center)
              Column() {
                Text(hit.title())
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(hit.subtitle())
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 3 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .padding({ left: 8 })

              Text('添加')
                .fontSize(12)
                .fontColor(hit.kind === 2 ? this.pal().textTertiary : this.pal().primary)
                .height(30)
                .padding({ left: 12, right: 12 })
                .borderRadius(15)
                .backgroundColor(this.pal().bgChip)
            }
            .width('100%')
            .height(56)
            .onClick(() => {
              this.onHit(hit);
            })
          }
        }, (hit: ScanHit) => `hit_${hit.ip}_${hit.port}`)
      }
      .width('100%')
      .layoutWeight(1)
      .divider({ strokeWidth: 0.5, color: this.pal().divider, startMargin: 40 })
      .scrollBar(BarState.Off)

      if (!this.scanning && this.hits.length === 0) {
        Text('· 请确认播放器与共享设备连在同一个 Wi-Fi / 局域网\n' +
          '· 只探测常见端口（80/8080/5005/5244/8000/9000 与 SMB 445）\n' +
          '· 没扫到也可以手动「添加服务器」填地址')
          .fontSize(12)
          .fontColor(this.pal().textTertiary)
          .lineHeight(19)
          .width('100%')
          .margin({ top: 12, bottom: 12 })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 10 })
  }

  @Builder
  plainAction(label: string, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(this.pal().textSecondary)
      .height(32)
      .padding({ left: 10, right: 10 })
      .backgroundColor(this.pal().bgCard)
      .borderRadius(16)
      .margin({ right: 8 })
      .textAlign(TextAlign.Center)
      .onClick(action)
  }

  @Builder
  entryRow(entry: NetEntry) {
    Row() {
      Text(entry.isDir ? '📁' : '🎬')
        .fontSize(18)
        .width(32)
        .textAlign(TextAlign.Center)
      Column() {
        Text(entry.name)
          .fontSize(15)
          .fontColor(this.pal().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(entry.isDir ? '文件夹' : (entry.sizeBytes > 0 ? formatSize(entry.sizeBytes) : '文件'))
          .fontSize(12)
          .fontColor(this.pal().textSecondary)
          .margin({ top: 4 })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 8 })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      this.onEntry(entry);
    })
  }

  @Builder
  emptyHint() {
    Column() {
      Text('🌐')
        .fontSize(40)
      Text(this.servers.length > 0 ? '点上方服务器进入共享' : '点「＋ 添加服务器」或「发现设备」')
        .fontSize(14)
        .fontColor(this.pal().textSecondary)
        .margin({ top: 12 })
        .textAlign(TextAlign.Center)
      Text('· 目录地址可列出其中的视频，支持 nginx/自建目录索引与返回 JSON 的服务\n' +
        '· 视频完整地址或 m3u8/rtsp/rtmp 直链点「连接」直接播放\n' +
        '· WebDAV：添加时选 WebDAV，填 https 地址与账号密码，可浏览目录并带认证播放\n' +
        '· SMB：添加时选 SMB，填 smb://192.168.1.10/共享名 与电脑账号，可浏览共享并播放\n' +
        '· 例：192.168.1.10:5005/video 或 http://192.168.1.10:8080/a.m3u8')
        .fontSize(12)
        .fontColor(this.pal().textTertiary)
        .lineHeight(18)
        .margin({ top: 10 })
        .textAlign(TextAlign.Center)

      if (this.history.length > 0) {
        Row() {
          Text('最近连接')
            .fontSize(12)
            .fontColor(this.pal().textTertiary)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ top: 18, bottom: 6 })

        ForEach(this.history, (url: string) => {
          Text(url)
            .fontSize(13)
            .fontColor(this.pal().primary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .height(36)
            .onClick(() => {
              this.useHistory(url);
            })
        }, (url: string) => `h_${url}`)
      }
    }
    .width('100%')
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 24 })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        if (!this.isBrowsing()) {
          this.tvEntry()
          this.sourceRow()
          this.actionRow()
        }

      if (this.showDiscover) {
        this.discoverView()
      } else {
        if (!this.isBrowsing()) {
          this.serverSection()
        }
        this.addressBar()

        if (this.loading) {
          Column() {
            LoadingProgress()
              .width(36)
              .height(36)
              .color(this.pal().primary)
            Text('正在读取目录…')
              .fontSize(12)
              .fontColor(this.pal().textSecondary)
              .margin({ top: 8 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.shownEntries().length > 0) {
          List({ space: 0, scroller: this.listScroller }) {
            ForEach(this.shownEntries(), (entry: NetEntry) => {
              ListItem() {
                this.entryRow(entry)
              }
            }, (entry: NetEntry) => `${entry.url}_${entry.isDir}`)
          }
          .width('100%')
          .layoutWeight(1)
          .divider({ strokeWidth: 0.5, color: this.pal().divider, startMargin: 40 })
          .padding({ left: AppTheme.pagePadding, right: 8 })
          .scrollBar(BarState.Off)
          .onScrollFrameBegin((offset: number, state: ScrollState) => {
            const consumed: boolean = this.tryPullBack(offset);
            return { offsetRemain: consumed ? 0 : offset };
          })
        } else {
          Scroll() {
            this.emptyHint()
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .onScrollFrameBegin((offset: number, state: ScrollState) => {
            // 空目录/提示态没有可滚内容，下滑直接交给父级回翻
            const consumed: boolean = offset > 1 ? this.onPullBack() : false;
            return { offsetRemain: consumed ? 0 : offset };
          })
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pal().bg)

      if (this.ftpOpen) {
        this.ftpPanel()
      }
      if (this.dlnaOpen) {
        this.dlnaPanel()
      }
    }
    .width('100%')
    .height('100%')
  }
}
