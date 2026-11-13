import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppTheme, Palette } from '../common/AppTheme';
import { NetClient } from '../model/NetClient';
import { NetServer } from '../model/NetServer';
import { NetPrefs } from '../model/NetPrefs';
import { SmbBrowser } from '../model/smb/SmbBrowser';

/**
 * 添加 / 编辑局域网服务器：全屏输入页。
 * 车机上页面内嵌输入框容易被输入法遮挡、也不便点中，故新增地址统一走本页。
 * 保存结果写入 AppStorage('net_add_result')，由网络页取走后自动连接。
 */
@Entry
@Component
struct NetEditPage {
  @StorageProp('isDark') isDark: boolean = true;
  // 与主页面/SettingsPage 一致：窗口为全屏布局，需自行避让系统状态栏与底部手势条
  @StorageProp('safeTop') safeTop: number = 0;
  @StorageProp('safeBottom') safeBottom: number = 0;

  /** 0=HTTP 目录/直链，1=WebDAV，2=SMB 共享 */
  @State proto: number = 0;
  @State name: string = '';
  @State address: string = '';
  @State user: string = '';
  @State pass: string = '';
  @State showPass: boolean = false;
  /** 编辑已有服务器时的原 key，保存时先删旧项 */
  @State seedKey: string = '';
  @State seedProbe: number = -1;

  private pal(): Palette {
    return AppTheme.palette(this.isDark);
  }

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    NetPrefs.init(ctx).then(() => {
      this.readParams();
    });
  }

  private readParams(): void {
    const raw: ESObject = router.getParams();
    if (raw === undefined || raw === null) {
      return;
    }
    const params: Record<string, ESObject> = raw as Record<string, ESObject>;
    const serverRaw: ESObject = params['server'];
    if (typeof serverRaw === 'string' && (serverRaw as string).length > 0) {
      const item: NetServer | undefined = NetServer.fromJson(serverRaw as string);
      if (item !== undefined) {
        this.proto = item.proto;
        this.name = item.name;
        this.address = item.url;
        this.user = item.user;
        this.pass = item.pass;
        this.seedKey = item.key();
        return;
      }
    }
    // 从发现结果带过来的地址：带上协议与端口
    const addr: ESObject = params['address'];
    if (typeof addr === 'string') {
      this.address = addr as string;
    }
    const p: ESObject = params['proto'];
    if (typeof p === 'number') {
      this.proto = p as number;
    }
  }

  private isDav(): boolean {
    return this.proto === 1;
  }

  private isSmb(): boolean {
    return this.proto === 2;
  }

  private switchProto(p: number): void {
    if (this.proto === p) {
      return;
    }
    this.proto = p;
    if (p === 1 && this.address.length === 0) {
      this.address = NetPrefs.getDavUrl();
    }
    if (p === 2 && this.address.length > 0) {
      // 从 http 地址切到 SMB 时把协议头换成 smb，避免带着 http:// 保存
      const low: string = this.address.toLowerCase();
      if (low.startsWith('http://') || low.startsWith('https://')) {
        this.address = '';
      }
    }
  }

  private save(): void {
    const typed: string = this.address.trim();
    if (typed.length === 0) {
      promptAction.showToast({ message: '请输入局域网地址' });
      return;
    }
    if (this.isSmb()) {
      this.saveSmb(typed);
      return;
    }
    const scheme: string = NetClient.schemeOf(NetClient.normalize(typed));
    if (scheme === 'smb' || scheme === 'cifs') {
      promptAction.showToast({ message: '这是 SMB 地址，请把上面的类型切成「SMB 共享」再保存' });
      return;
    }
    const url: string = this.isDav() ? NetClient.davNormalize(typed) : NetClient.normalize(typed);
    const displayName: string = this.name.trim().length > 0 ? this.name.trim() : NetClient.pureName(url);
    const server: NetServer = new NetServer(displayName.length > 0 ? displayName : url, url, this.proto,
      this.user.trim(), this.pass);
    AppStorage.setOrCreate('net_add_result',
      JSON.stringify({ server: server.toJson(), drop: this.seedKey, seed: this.seedProbe }));
    router.back();
  }

  /** SMB：地址必须带共享名，如 smb://192.168.1.10/video */
  private saveSmb(typed: string): void {
    const url: string = SmbBrowser.normalizeUrl(typed);
    const why: string = SmbBrowser.checkUrl(url);
    if (why.length > 0) {
      promptAction.showToast({ message: why });
      return;
    }
    const typedName: string = this.name.trim();
    const shareName: string = SmbBrowser.titleOf(url);
    const displayName: string = typedName.length > 0 ? typedName : shareName;
    const server: NetServer = new NetServer(displayName.length > 0 ? displayName : url, url, 2,
      this.user.trim(), this.pass);
    AppStorage.setOrCreate('net_add_result',
      JSON.stringify({ server: server.toJson(), drop: this.seedKey, seed: this.seedProbe }));
    router.back();
  }

  @Builder
  topBar() {
    Row() {
      Text('‹ 返回')
        .fontSize(15)
        .fontColor(this.pal().textSecondary)
        .height(40)
        .padding({ right: 8 })
        .onClick(() => {
          router.back();
        })
      Text(this.seedKey.length > 0 ? '编辑服务器' : '添加局域网地址')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.pal().textPrimary)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
      Text('保存')
        .fontSize(15)
        .fontColor(this.pal().primary)
        .height(40)
        .padding({ left: 8 })
        .onClick(() => {
          this.save();
        })
    }
    .width('100%')
    .height(AppTheme.toolbarHeight + this.safeTop)
    .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: this.safeTop })
  }

  @Builder
  protoSwitch() {
    Row() {
      this.protoItem('局域网目录', 0)
      this.protoItem('WebDAV', 1)
      this.protoItem('SMB 共享', 2)
    }
    .width('100%')
    .padding(4)
    .backgroundColor(this.pal().bgChip)
    .borderRadius(12)
  }

  @Builder
  protoItem(label: string, value: number) {
    Text(label)
      .fontSize(14)
      .fontColor(this.proto === value ? Color.White : this.pal().textSecondary)
      .fontWeight(this.proto === value ? FontWeight.Medium : FontWeight.Normal)
      .textAlign(TextAlign.Center)
      .height(38)
      .layoutWeight(1)
      .borderRadius(9)
      .backgroundColor(this.proto === value ? this.pal().primary : Color.Transparent)
      .onClick(() => {
        this.switchProto(value);
      })
  }

  @Builder
  field(label: string, placeholder: string, value: string, onChange: (v: string) => void, password: boolean) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor(this.pal().textTertiary)
        .width('100%')
      TextInput({ placeholder: placeholder, text: value })
        .width('100%')
        .height(46)
        .margin({ top: 6 })
        .fontSize(15)
        .type(password ? InputType.Password : InputType.Normal)
        .showPasswordIcon(password)
        .backgroundColor(this.pal().bgChip)
        .fontColor(this.pal().textPrimary)
        .placeholderColor(this.pal().textTertiary)
        .onChange((v: string) => {
          onChange(v);
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 16 })
  }

  build() {
    Column() {
      this.topBar()

      Scroll() {
        Column() {
          this.protoSwitch()

          this.field('地址', this.isSmb() ? 'smb://192.168.1.10/video'
            : (this.isDav() ? 'https://192.168.1.10:5006/dav/' : '192.168.1.10:8080 或 http://…/video'),
            this.address, (v: string) => {
              this.address = v;
            }, false)

          this.field('名称（可留空）', '如：客厅 NAS', this.name, (v: string) => {
            this.name = v;
          }, false)

          if (this.isSmb()) {
            this.field('电脑账号', 'Windows 登录用户名，留空试匿名', this.user, (v: string) => {
              this.user = v;
            }, false)
            this.field('密码', 'Windows 登录密码', this.pass, (v: string) => {
              this.pass = v;
            }, true)
          }

          if (this.isDav()) {
            this.field('账号', 'WebDAV 账号', this.user, (v: string) => {
              this.user = v;
            }, false)
            this.field('密码', 'WebDAV 密码', this.pass, (v: string) => {
              this.pass = v;
            }, true)
          }

          Column() {
            Text('填写说明')
              .fontSize(12)
              .fontColor(this.pal().textSecondary)
              .width('100%')
            Text(this.isSmb()
              ? ('· 地址要写到共享名：smb://192.168.1.10/video，也可带子目录 smb://…/video/电影\n' +
                '· 账号填电脑的 Windows 登录用户，密码带域账号可用 域\\用户 形式\n' +
                '· 电脑端需开启文件共享，并给该账号读取权限\n' +
                '· 播放时本机会起 127.0.0.1 本地代理，把共享文件转给播放器')
              : ('· 只填 ip:端口 时会自动按 http:// 补全\n' +
                '· 目录地址可列出其中的视频，视频完整地址/m3u8/rtsp/rtmp 直链可直接播放\n' +
                '· NAS 请在系统里开启 HTTP 目录索引或 WebDAV 服务后再添加\n' +
                '· SMB 共享请把类型切到「SMB 共享」，填 smb://地址/共享名'))
              .fontSize(12)
              .fontColor(this.pal().textTertiary)
              .lineHeight(19)
              .width('100%')
              .margin({ top: 8 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 22 })

          Button('保存并连接')
            .width('100%')
            .height(46)
            .margin({ top: 28, bottom: 40 + this.safeBottom })
            .fontSize(16)
            .backgroundColor(this.pal().primary)
            .fontColor(Color.White)
            .onClick(() => {
              this.save();
            })
        }
        .width('100%')
        .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pal().bg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
