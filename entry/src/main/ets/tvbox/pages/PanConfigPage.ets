/**
 * PanConfigPage - 网盘凭证配置页（M1-M5）
 */
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { PanConfig, PanCredential, PanKind, PanCredentialSource, emptyCredential } from '../utils/PanConfig';
import { syncCredentialToBackend } from '../util/BackendSync';
import { Palette } from '../utils/ThemeManager';
import { getTopSafeAreaVp, getTopSafeAreaSync, getBottomSafeAreaVp, getLeftSafeAreaVp, getRightSafeAreaVp, getBreakpoint, Breakpoint, BP_SM } from '../utils/ScreenAdapter';

interface ToastOpt { message: string; duration?: number; }

@Entry
@Component
struct PanConfigPage {
  @StorageProp('isDarkMode') isDark: boolean = false;
  @State bp: Breakpoint = BP_SM;
  @State topSafe: number = 0;
  @State bottomSafe: number = 0;
  @State keyboardHeight: number = 0;
  @State leftSafe: number = 0;
  @State rightSafe: number = 0;

  @State ali: PanCredential = emptyCredential('ali');
  @State quark: PanCredential = emptyCredential('quark');
  @State uc: PanCredential = emptyCredential('uc');
  @State s115: PanCredential = emptyCredential('s115');
  @State baidu: PanCredential = emptyCredential('baidu');
  @State expanded: string = '';
  @State showRawAli: boolean = false;
  @State showRawQuark: boolean = false;
  @State showRawUc: boolean = false;
  @State showRawS115: boolean = false;
  @State showRawBaidu: boolean = false;
  @State sourceAli: PanCredentialSource = 'app';
  @State sourceQuark: PanCredentialSource = 'app';
  @State sourceUc: PanCredentialSource = 'app';
  @State sourceS115: PanCredentialSource = 'app';
  @State sourceBaidu: PanCredentialSource = 'app';

  aboutToAppear() {
    this.bp = getBreakpoint();
    this.initSafeArea();
    this.reload();
  }

  onPageShow() {
    this.reload();
  }

  private async initSafeArea(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.topSafe = await getTopSafeAreaVp(ctx);
    this.bottomSafe = await getBottomSafeAreaVp(ctx);
    this.leftSafe = await getLeftSafeAreaVp(ctx);
    this.rightSafe = await getRightSafeAreaVp(ctx);
    try {
      const win = await window.getLastWindow(ctx);
      win.on('avoidAreaChange', (data): void => {
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM || data.type === window.AvoidAreaType.TYPE_CUTOUT) {
          this.topSafe = getTopSafeAreaSync(win);
        } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          const bh: number = data.area.bottomRect.height;
          if (bh > 0) this.bottomSafe = px2vp(bh);
        }
      });
    } catch (_e) {}
      try {
        const win2 = await window.getLastWindow(ctx);
        const kb = win2.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD);
        const kh = kb && kb.bottomRect ? kb.bottomRect.height : 0;
        this.keyboardHeight = kh > 0 ? px2vp(kh) : 0;
        win2.on('keyboardHeightChange', (h: number): void => {
          this.keyboardHeight = h > 0 ? px2vp(h) : 0;
        });
      } catch (_e2) {}
  }

  private async reload(): Promise<void> {
    this.ali = await PanConfig.get('ali');
    this.quark = await PanConfig.get('quark');
    this.uc = await PanConfig.get('uc');
    this.s115 = await PanConfig.get('s115');
    this.baidu = await PanConfig.get('baidu');
    this.sourceAli = await PanConfig.getCredentialSource('ali');
    this.sourceQuark = await PanConfig.getCredentialSource('quark');
    this.sourceUc = await PanConfig.getCredentialSource('uc');
    this.sourceS115 = await PanConfig.getCredentialSource('s115');
    this.sourceBaidu = await PanConfig.getCredentialSource('baidu');
  }

  private toast(msg: string): void {
    const opt: ToastOpt = { message: msg, duration: 1500 };
    promptAction.showToast(opt);
  }

  private getSourceByKind(kind: PanKind): PanCredentialSource {
    if (kind === 'ali') return this.sourceAli;
    if (kind === 'quark') return this.sourceQuark;
    if (kind === 'uc') return this.sourceUc;
    if (kind === 's115') return this.sourceS115;
    return this.sourceBaidu;
  }

  private setSourceByKind(kind: PanKind, source: PanCredentialSource): void {
    if (kind === 'ali') this.sourceAli = source;
    else if (kind === 'quark') this.sourceQuark = source;
    else if (kind === 'uc') this.sourceUc = source;
    else if (kind === 's115') this.sourceS115 = source;
    else this.sourceBaidu = source;
  }

  private async changeSource(kind: PanKind, source: PanCredentialSource): Promise<void> {
    this.setSourceByKind(kind, source);
    await PanConfig.setCredentialSource(kind, source);
    const label: string = source === 'app' ? 'App 凭证优先' : '后端配置优先';
    this.toast(PanConfig.kindLabel(kind) + '已切换为' + label);
  }

  private getStateByKind(kind: PanKind): PanCredential {
    if (kind === 'ali') return this.ali;
    if (kind === 'quark') return this.quark;
    if (kind === 'uc') return this.uc;
    if (kind === 's115') return this.s115;
    return this.baidu;
  }

  private setStateByKind(kind: PanKind, cred: PanCredential): void {
    if (kind === 'ali') this.ali = cred;
    else if (kind === 'quark') this.quark = cred;
    else if (kind === 'uc') this.uc = cred;
    else if (kind === 's115') this.s115 = cred;
    else this.baidu = cred;
  }

  private async saveAli(): Promise<void> {
    const cred: PanCredential = await PanConfig.get('ali');
    cred.token = this.ali.token.trim();
    cred.ua = this.ali.ua.trim();
    cred.accessToken = '';
    cred.accessExpireAt = 0;
    await PanConfig.set(cred);
    this.ali = cred;
    let suffix: string = '';
    if (this.sourceAli === 'app' && cred.token.length > 0) {
      const synced: boolean = await syncCredentialToBackend('ali', cred.token);
      suffix = synced ? '，已同步后端' : '';
    }
    this.toast('阿里云盘已保存' + suffix);
  }

  private async saveCookieKind(kind: PanKind): Promise<void> {
    const cred: PanCredential = await PanConfig.get(kind);
    const src: PanCredential = this.getStateByKind(kind);
    cred.cookie = src.cookie.trim();
    cred.ua = src.ua.trim();
    await PanConfig.set(cred);
    this.setStateByKind(kind, cred);
    let suffix: string = '';
    if (this.getSourceByKind(kind) === 'app' && cred.cookie.length > 0) {
      const synced: boolean = await syncCredentialToBackend(kind, cred.cookie);
      suffix = synced ? '，已同步后端' : '';
    }
    this.toast(PanConfig.kindLabel(kind) + '已保存' + suffix);
  }

  private async clearKind(kind: PanKind): Promise<void> {
    await PanConfig.clear(kind);
    this.setStateByKind(kind, emptyCredential(kind));
    this.toast(PanConfig.kindLabel(kind) + '已清除');
  }

  private isLogged(kind: PanKind): boolean {
    const c: PanCredential = this.getStateByKind(kind);
    if (kind === 'ali') return c.token.trim().length > 0;
    return c.cookie.trim().length > 0;
  }

  private loginTimeStr(kind: PanKind): string {
    const t: number = this.getStateByKind(kind).updatedAt;
    if (t <= 0) return '';
    const d: Date = new Date(t);
    const pad = (n: number): string => n < 10 ? '0' + n : String(n);
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  private getShowRaw(kind: PanKind): boolean {
    if (kind === 'ali') return this.showRawAli;
    if (kind === 'quark') return this.showRawQuark;
    if (kind === 'uc') return this.showRawUc;
    if (kind === 's115') return this.showRawS115;
    return this.showRawBaidu;
  }

  private toggleShowRaw(kind: PanKind): void {
    if (kind === 'ali') this.showRawAli = !this.showRawAli;
    else if (kind === 'quark') this.showRawQuark = !this.showRawQuark;
    else if (kind === 'uc') this.showRawUc = !this.showRawUc;
    else if (kind === 's115') this.showRawS115 = !this.showRawS115;
    else this.showRawBaidu = !this.showRawBaidu;
  }

  private goBack(): void {
    router.back();
  }
  build() {
    Column() {
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(22)
            .fontColor([Palette.textPrimary(this.isDark)])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        }
        .width(44).height(44)
        .justifyContent(FlexAlign.Center)
        .onClick(() => this.goBack())

        Text('网盘配置')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.textPrimary(this.isDark))
          .margin({ left: 4 })
        Blank()
      }
      .width('100%')
      .height(52 + this.topSafe)
      .padding({ left: 8 + this.leftSafe, right: 8 + this.rightSafe, top: this.topSafe })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(Palette.glass(this.isDark))
      .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })

      Scroll() {
        Column({ space: 12 }) {
          this.AliSection()
          this.CookieSection('quark', '夸克网盘', '在浏览器登录 pan.quark.cn 后复制完整 Cookie')
          this.CookieSection('uc', 'UC 网盘', '在浏览器登录 drive.uc.cn 后复制完整 Cookie')
          this.CookieSection('s115', '115 网盘', '登录 115.com 后复制含 UID/CID/SEID 的 Cookie')
          this.CookieSection('baidu', '百度网盘', '登录 pan.baidu.com 后复制含 BDUSS/STOKEN 的 Cookie')
          Column().height(24 + this.bottomSafe + this.keyboardHeight)
        }
        .width('100%')
        .padding({ left: 16 + this.leftSafe, right: 16 + this.rightSafe, top: 8 })
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.bg(this.isDark))
  }

  @Builder
  AliSection() {
    Column() {
      this.SectionHeader('ali', '阿里云盘', 'refresh_token（open.alipan.com）')
      if (this.expanded === 'ali') {
        Column({ space: 10 }) {
          this.CredentialSourceRow('ali')
          this.StatusRow('ali')
          if (this.getShowRaw('ali') || !this.isLogged('ali')) {
            this.LabeledInput('refresh_token', this.ali.token, (v: string): void => { this.ali.token = v; })
            this.LabeledInput('User-Agent（可选）', this.ali.ua, (v: string): void => { this.ali.ua = v; })
            this.ActionRow('ali', (): void => { this.saveAli(); }, (): void => { this.clearKind('ali'); })
          }
        }
        .padding({ left: 12, right: 12, top: 4, bottom: 12 })
        .alignItems(HorizontalAlign.Start)
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -8 })).animation({ duration: 240, curve: Curve.EaseOut }))
      }
    }
    .width('100%')
    .backgroundColor(Palette.glass(this.isDark))
    .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .borderRadius(16)
    .border({ width: 1, color: Palette.glassBorder(this.isDark) })
  }

  @Builder
  CookieSection(kind: PanKind, title: string, hint: string) {
    Column() {
      this.SectionHeader(kind, title, hint)
      if (this.expanded === kind) {
        Column({ space: 10 }) {
          this.CredentialSourceRow(kind)
          this.StatusRow(kind)
          if (this.getShowRaw(kind) || !this.isLogged(kind)) {
            this.LabeledInput('Cookie', this.getStateByKind(kind).cookie, (v: string): void => {
              const cred: PanCredential = this.getStateByKind(kind);
              cred.cookie = v;
              this.setStateByKind(kind, cred);
            })
            this.LabeledInput('User-Agent（可选）', this.getStateByKind(kind).ua, (v: string): void => {
              const cred: PanCredential = this.getStateByKind(kind);
              cred.ua = v;
              this.setStateByKind(kind, cred);
            })
            this.ActionRow(kind, (): void => { this.saveCookieKind(kind); }, (): void => { this.clearKind(kind); })
          }
        }
        .padding({ left: 12, right: 12, top: 4, bottom: 12 })
        .alignItems(HorizontalAlign.Start)
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -8 })).animation({ duration: 240, curve: Curve.EaseOut }))
      }
    }
    .width('100%')
    .backgroundColor(Palette.glass(this.isDark))
    .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .borderRadius(16)
    .border({ width: 1, color: Palette.glassBorder(this.isDark) })
  }

  @Builder
  CredentialSourceRow(kind: PanKind) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text('凭证来源')
          .fontSize(12)
          .fontColor(Palette.textSecondary(this.isDark))
        Text(this.getSourceByKind(kind) === 'app' ? 'App 优先' : '后端优先')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.textPrimary(this.isDark))
          .layoutWeight(1)
        Text('App 优先')
          .fontSize(12)
          .fontColor(this.getSourceByKind(kind) === 'app' ? '#FFFFFF' : Palette.textPrimary(this.isDark))
          .backgroundColor(this.getSourceByKind(kind) === 'app' ? Palette.accent() : (this.isDark ? '#22FFFFFF' : '#11000000'))
          .borderRadius(8)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.changeSource(kind, 'app'); })
        Text('后端优先')
          .fontSize(12)
          .fontColor(this.getSourceByKind(kind) === 'backend' ? '#FFFFFF' : Palette.textPrimary(this.isDark))
          .backgroundColor(this.getSourceByKind(kind) === 'backend' ? Palette.accent() : (this.isDark ? '#22FFFFFF' : '#11000000'))
          .borderRadius(8)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.changeSource(kind, 'backend'); })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.getSourceByKind(kind) === 'app'
        ? 'App 优先：保存/登录后同步 App 凭证到 T4 后端，后端使用该凭证解析。'
        : '后端优先：不覆盖后端已有 Cookie/Token，适合局域网自建后端已配置网盘。')
        .fontSize(11)
        .fontColor(Palette.textTertiary(this.isDark))
        .width('100%')
    }
    .width('100%')
    .padding({ top: 2, bottom: 2 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  StatusRow(kind: PanKind) {
    Row({ space: 10 }) {
      if (this.isLogged(kind)) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(18)
          .fontColor([Palette.textPrimary(this.isDark)])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        Column() {
          Text('已登录')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.textPrimary(this.isDark))
          if (this.loginTimeStr(kind).length > 0) {
            Text('登录时间：' + this.loginTimeStr(kind))
              .fontSize(11)
              .fontColor(Palette.textTertiary(this.isDark))
              .margin({ top: 2 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text('重新登录')
          .fontSize(12)
          .fontColor(Palette.textPrimary(this.isDark))
          .backgroundColor(this.isDark ? '#22FFFFFF' : '#22000000')
          .borderRadius(8)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { router.pushUrl({ url: 'tvbox/pages/PanLoginPage', params: { kind: kind } }); })

        Text(this.getShowRaw(kind) ? '收起' : '查看凭证')
          .fontSize(12)
          .fontColor(Palette.textPrimary(this.isDark))
          .backgroundColor(this.isDark ? '#22FFFFFF' : '#22000000')
          .borderRadius(8)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.toggleShowRaw(kind); })

        Text('退出')
          .fontSize(12)
          .fontColor(Palette.textPrimary(this.isDark))
          .backgroundColor(this.isDark ? '#22FFFFFF' : '#22000000')
          .borderRadius(8)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.clearKind(kind); })
      } else {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
          .fontSize(18)
          .fontColor([Palette.textSecondary(this.isDark)])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        Text('未登录')
          .fontSize(13)
          .fontColor(Palette.textSecondary(this.isDark))
          .layoutWeight(1)

        Text('登录')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.textPrimary(this.isDark))
          .backgroundColor(this.isDark ? '#33FFFFFF' : '#22000000')
          .borderRadius(10)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { router.pushUrl({ url: 'tvbox/pages/PanLoginPage', params: { kind: kind } }); })
      }
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  SectionHeader(kind: string, title: string, hint: string) {
    Row() {
      Column() {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.textPrimary(this.isDark))
        Text(hint)
          .fontSize(11)
          .fontColor(Palette.textTertiary(this.isDark))
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph(this.expanded === kind ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
        .fontSize(18)
        .fontColor([Palette.textSecondary(this.isDark)])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: this.expanded === kind ? 4 : 14 })
    .animation({ duration: 200, curve: Curve.EaseOut })
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => {
      this.getUIContext()?.animateTo({ duration: 240, curve: Curve.EaseOut }, () => {
        this.expanded = this.expanded === kind ? '' : kind;
      });
    })
  }

  @Builder
  LabeledInput(label: string, value: string, onChange: (v: string) => void) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor(Palette.textSecondary(this.isDark))
        .margin({ bottom: 4 })
      TextArea({ text: value })
        .fontSize(13)
        .fontColor(Palette.textPrimary(this.isDark))
        .backgroundColor(this.isDark ? '#222226' : '#F2F2F5')
        .borderRadius(10)
        .padding(10)
        .width('100%')
        .height(72)
        .copyOption(CopyOptions.LocalDevice)
        .onChange((v: string) => { onChange(v); })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  ActionRow(kind: PanKind, save: () => void, clear: () => void) {
    Row({ space: 12 }) {
      Text('保存凭证')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.textPrimary(this.isDark))
        .backgroundColor(this.isDark ? '#33FFFFFF' : '#22000000')
        .borderRadius(10)
        .padding({ left: 18, right: 18, top: 8, bottom: 8 })
        .clickEffect({ level: ClickEffectLevel.LIGHT })
        .onClick(() => save())

      Text('清除')
        .fontSize(14)
        .fontColor(Palette.textPrimary(this.isDark))
        .backgroundColor(this.isDark ? '#22FFFFFF' : '#22000000')
        .borderRadius(10)
        .padding({ left: 18, right: 18, top: 8, bottom: 8 })
        .clickEffect({ level: ClickEffectLevel.LIGHT })
        .onClick(() => clear())
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
    .margin({ top: 4 })
  }
}