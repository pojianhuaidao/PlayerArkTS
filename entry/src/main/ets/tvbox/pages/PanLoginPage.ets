/**
 * PanLoginPage - 内嵌 WebView 登录页（方案 A + C）
 * 用户在该页完成对应网盘登录，登录成功后：
 *  - 方案 A（夸克/UC/115/百度）：从 WebCookieManager 抓取域下 Cookie 写回 PanConfig；
 *  - 方案 C（阿里）：登录成功后从 localStorage 中读 refresh_token 写回 PanConfig。
 *
 * 通过 router.pushUrl 传入参数：
 *   kind: PanKind
 */
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { PanConfig, PanCredential, PanKind, PanCredentialSource } from '../utils/PanConfig';
import { syncCredentialToBackend } from '../util/BackendSync';
import { Palette } from '../utils/ThemeManager';
import { getTopSafeAreaVp, getTopSafeAreaSync, getBottomSafeAreaVp, getLeftSafeAreaVp, getRightSafeAreaVp } from '../utils/ScreenAdapter';
import { hilog } from '@kit.PerformanceAnalysisKit';

interface ToastOpt { message: string; duration?: number; }
interface RouteParams { kind?: string; }

interface KindMeta {
  loginUrl: string;
  cookieDomains: string[];
  ua: string;
  finishHints: string[];
}

const META: Record<string, KindMeta> = {
  'ali': {
    loginUrl: 'https://www.alipan.com/sign/in',
    cookieDomains: ['https://www.alipan.com'],
    ua: 'Mozilla/5.0 (Linux; U; HarmonyOS 6.1; TVBox) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36',
    finishHints: ['drive', 'pan']
  },
  'quark': {
    loginUrl: 'https://pan.quark.cn/',
    cookieDomains: ['https://pan.quark.cn', 'https://drive-pc.quark.cn'],
    ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
    finishHints: ['/list', '/mypan', 'index']
  },
  'uc': {
    loginUrl: 'https://drive.uc.cn/?public=false',
    cookieDomains: ['https://drive.uc.cn', 'https://pc-api.uc.cn'],
    ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
    finishHints: ['/list', '/mypan', 'index']
  },
  's115': {
    loginUrl: 'https://115.com/?mode=login',
    cookieDomains: ['https://115.com', 'https://webapi.115.com'],
    ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
    finishHints: ['/?ct=file', '/home', '/desk']
  },
  'baidu': {
    loginUrl: 'https://pan.baidu.com/',
    cookieDomains: ['https://pan.baidu.com', 'https://passport.baidu.com'],
    ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
    finishHints: ['/disk/home', '/disk/main']
  }
};

@Entry
@Component
struct PanLoginPage {
  @StorageProp('isDarkMode') isDark: boolean = false;
  @State kind: PanKind = 'ali';
  @State currentUrl: string = '';
  @State captured: boolean = false;
  @State busy: boolean = false;
  @State topSafe: number = 0;
  @State bottomSafe: number = 0;
  @State leftSafe: number = 0;
  @State rightSafe: number = 0;

  private controller: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    const p = router.getParams() as RouteParams;
    const raw: string = p && typeof p.kind === 'string' ? p.kind : 'ali';
    if (raw === 'ali' || raw === 'quark' || raw === 'uc' || raw === 's115' || raw === 'baidu') {
      this.kind = raw as PanKind;
    }
    this.initSafeArea();
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
  }

  private toast(msg: string): void {
    const opt: ToastOpt = { message: msg, duration: 1800 };
    promptAction.showToast(opt);
  }

  private meta(): KindMeta {
    const m = META[this.kind];
    return m ? m : META['ali'];
  }

  /** 尝试合并同域名下的所有 Cookie */
  private async collectCookies(): Promise<string> {
    const m = this.meta();
    const seen: Map<string, string> = new Map();
    for (const domain of m.cookieDomains) {
      try {
        const c: string = await webview.WebCookieManager.fetchCookie(domain);
        if (c && c.length > 0) {
          const parts: string[] = c.split(';');
          for (const kv of parts) {
            const eq: number = kv.indexOf('=');
            if (eq <= 0) continue;
            const k: string = kv.substring(0, eq).trim();
            const v: string = kv.substring(eq + 1).trim();
            if (k.length > 0) seen.set(k, v);
          }
        }
      } catch (e) {
        hilog.warn(0x0001, 'YSC', 'fetchCookie failed %{public}s', String(e));
      }
    }
    const kvs: string[] = [];
    seen.forEach((v: string, k: string) => { kvs.push(k + '=' + v); });
    return kvs.join('; ');
  }

  /** 阿里通过读取网页 localStorage 的 token 内包含的 refresh_token */
  private async fetchAliRefreshToken(): Promise<string> {
    const js: string = "(function(){try{var t=localStorage.getItem('token');if(!t){var keys=Object.keys(localStorage);for(var i=0;i<keys.length;i++){if(keys[i].indexOf('token')>=0){t=localStorage.getItem(keys[i]);break;}}}if(!t) return '';var obj=JSON.parse(t);return obj.refresh_token||obj.refreshToken||'';}catch(e){return '';}})();";
    try {
      const r: string = await this.controller.runJavaScript(js);
      if (!r) return '';
      const s: string = String(r);
      // runJavaScript 常见返回带引号字符串
      if (s.startsWith('"') && s.endsWith('"')) return s.substring(1, s.length - 1);
      if (s === 'null' || s === 'undefined') return '';
      return s;
    } catch (e) {
      hilog.warn(0x0001, 'YSC', 'aliRefreshToken JS failed %{public}s', String(e));
      return '';
    }
  }
  private async doCapture(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      if (this.kind === 'ali') {
        const rt: string = await this.fetchAliRefreshToken();
        if (rt.length === 0) {
          this.toast('未在页面 localStorage 中找到 refresh_token，请先完成登录再点【抓取凭证】');
          return;
        }
        const cred: PanCredential = await PanConfig.get('ali');
        cred.token = rt;
        cred.accessToken = '';
        cred.accessExpireAt = 0;
        await PanConfig.set(cred);
        this.captured = true;
        const sourceAli: PanCredentialSource = await PanConfig.getCredentialSource('ali');
        if (sourceAli === 'app') {
          await syncCredentialToBackend('ali', rt);
          this.toast('阿里 refresh_token 已保存并同步后端');
        } else {
          this.toast('阿里 refresh_token 已保存（后端优先，不覆盖后端配置）');
        }
        return;
      }
      const cookie: string = await this.collectCookies();
      if (cookie.length === 0) {
        this.toast('未抓到 Cookie，请确认已完成登录');
        return;
      }
      const cred: PanCredential = await PanConfig.get(this.kind);
      cred.cookie = cookie;
      cred.ua = this.meta().ua;
      await PanConfig.set(cred);
      this.captured = true;
      const source: PanCredentialSource = await PanConfig.getCredentialSource(this.kind);
      if (source === 'app') {
        const synced: boolean = await syncCredentialToBackend(this.kind, cookie);
        this.toast(PanConfig.kindLabel(this.kind) + ' Cookie 已保存' + (synced ? '并同步后端' : ''));
      } else {
        this.toast(PanConfig.kindLabel(this.kind) + ' Cookie 已保存（后端优先，不覆盖后端配置）');
      }
    } finally {
      this.busy = false;
    }
  }

  private async doClearCookies(): Promise<void> {
    try {
      await webview.WebCookieManager.clearAllCookies();
      this.toast('WebView Cookie 已清空，可重新登录');
    } catch (_e) {
      this.toast('清 Cookie 失败');
    }
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
        .clickEffect({ level: ClickEffectLevel.LIGHT })
        .onClick(() => this.goBack())

        Text('登录 ' + PanConfig.kindLabel(this.kind))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.textPrimary(this.isDark))
          .layoutWeight(1)
          .margin({ left: 4 })

        Text('抓取凭证')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.textPrimary(this.isDark))
          .backgroundColor(this.isDark ? '#33FFFFFF' : '#22000000')
          .borderRadius(8)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => this.doCapture())
      }
      .width('100%')
      .height(52 + this.topSafe)
      .padding({ left: 8 + this.leftSafe, right: 12 + this.rightSafe, top: this.topSafe })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(Palette.glass(this.isDark))
      .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })

      Text(this.currentUrl)
        .fontSize(11)
        .fontColor(Palette.textTertiary(this.isDark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ left: 12 + this.leftSafe, right: 12 + this.rightSafe, top: 2, bottom: 4 })

      Web({ src: this.meta().loginUrl, controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .onlineImageAccess(true)
        .userAgent(this.meta().ua)
        .width('100%')
        .layoutWeight(1)
        .onPageBegin((e) => {
          if (e && e.url) this.currentUrl = e.url;
        })
        .onPageEnd((e) => {
          if (e && e.url) this.currentUrl = e.url;
        })

      Row({ space: 12 }) {
        Text('清 Cookie')
          .fontSize(13)
          .fontColor(Palette.textPrimary(this.isDark))
          .backgroundColor(this.isDark ? '#22FFFFFF' : '#22000000')
          .borderRadius(10)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => this.doClearCookies())

        Text('重新加载')
          .fontSize(13)
          .fontColor(Palette.textPrimary(this.isDark))
          .backgroundColor(this.isDark ? '#22FFFFFF' : '#22000000')
          .borderRadius(10)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => {
            try { this.controller.loadUrl(this.meta().loginUrl); } catch (_e) {}
          })

        Blank()

        if (this.captured) {
          Text('已捕获')
            .fontSize(12)
            .fontColor(Palette.textPrimary(this.isDark))
        }
      }
      .width('100%')
      .padding({ left: 12 + this.leftSafe, right: 12 + this.rightSafe, top: 8, bottom: 8 + this.bottomSafe })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.bg(this.isDark))
  }
}