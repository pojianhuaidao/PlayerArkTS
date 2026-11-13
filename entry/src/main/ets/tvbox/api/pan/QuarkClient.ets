/**
 * QuarkClient - 夸克网盘 & UC 网盘直链解析
 * 二者接口几乎一致：pan.quark.cn 与 drive.uc.cn 只是域名不同。
 * rawUrl 支持：
 *   quark://<shareId>@<fileId>?pwd=xxx
 *   uc://<shareId>@<fileId>?pwd=xxx
 *   https://pan.quark.cn/s/<shareId>[?pwd=xxx]
 *   https://drive.uc.cn/s/<shareId>[?pwd=xxx]
 */
import { PanClient, PanResolveResult, singleResolveResult, emptyResolveResult } from './PanTypes';
import { PanConfig, PanCredential, PanKind } from '../../utils/PanConfig';
import { panRequest, panPostJson, PanHttpResponse } from './PanHttp';

const REFERER_QUARK: string = 'https://pan.quark.cn/';
const REFERER_UC: string = 'https://drive.uc.cn/';
const UA_QUARK: string = 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 Quark/1.0';
const UA_UC: string = 'Mozilla/5.0 (Linux; U; Android 10) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 UCBrowser/13.0';

interface ShareFile { shareId: string; fileId: string; sharePwd: string; }

export class QuarkClient implements PanClient {
  private kind: PanKind;

  constructor(kind: PanKind) {
    this.kind = kind === 'uc' ? 'uc' : 'quark';
  }

  match(rawUrl: string): boolean {
    if (rawUrl.length === 0) return false;
    const lower: string = rawUrl.toLowerCase();
    if (this.kind === 'quark') {
      return lower.startsWith('quark://') || lower.includes('pan.quark.cn/s/');
    }
    return lower.startsWith('uc://') || lower.includes('drive.uc.cn/s/');
  }

  async resolve(rawUrl: string): Promise<PanResolveResult> {
    const cred: PanCredential = await PanConfig.get(this.kind);
    if (cred.cookie.length === 0) {
      return emptyResolveResult((this.kind === 'quark' ? '夸克' : 'UC') + '网盘未配置：请在【设置】→【网盘配置】填入 Cookie');
    }
    const parsed: ShareFile = this.extractShareFile(rawUrl);
    if (parsed.shareId.length === 0) {
      return emptyResolveResult('链接缺少 shareId：' + rawUrl);
    }
    try {
      const stoken: string = await this.getStoken(cred, parsed.shareId, parsed.sharePwd);
      const fileId: string = parsed.fileId.length > 0 ? parsed.fileId : await this.getFirstFileId(cred, parsed.shareId, stoken);
      if (fileId.length === 0) throw new Error('未找到可播放文件');
      const url: string = await this.getDownloadUrl(cred, parsed.shareId, stoken, fileId);
      const headers: Map<string, string> = new Map();
      headers.set('Referer', this.kind === 'quark' ? REFERER_QUARK : REFERER_UC);
      headers.set('User-Agent', cred.ua.length > 0 ? cred.ua : (this.kind === 'quark' ? UA_QUARK : UA_UC));
      headers.set('Cookie', cred.cookie);
      return singleResolveResult(url, headers, '原画');
    } catch (e) {
      return emptyResolveResult('换取直链失败：' + (e as Error).message);
    }
  }

  private domain(): string {
    return this.kind === 'quark' ? 'https://drive-pc.quark.cn' : 'https://pc-api.uc.cn';
  }

  private commonHeaders(cred: PanCredential): Map<string, string> {
    const map: Map<string, string> = new Map();
    map.set('Cookie', cred.cookie);
    map.set('Referer', this.kind === 'quark' ? REFERER_QUARK : REFERER_UC);
    map.set('User-Agent', cred.ua.length > 0 ? cred.ua : (this.kind === 'quark' ? UA_QUARK : UA_UC));
    return map;
  }

  private extractShareFile(rawUrl: string): ShareFile {
    let shareId: string = '';
    let fileId: string = '';
    let sharePwd: string = '';
    const scheme: string = this.kind === 'quark' ? 'quark://' : 'uc://';
    if (rawUrl.toLowerCase().startsWith(scheme)) {
      const withoutScheme: string = rawUrl.substring(scheme.length);
      const qIdx: number = withoutScheme.indexOf('?');
      const path: string = qIdx >= 0 ? withoutScheme.substring(0, qIdx) : withoutScheme;
      const query: string = qIdx >= 0 ? withoutScheme.substring(qIdx + 1) : '';
      const atIdx: number = path.indexOf('@');
      if (atIdx >= 0) { shareId = path.substring(0, atIdx); fileId = path.substring(atIdx + 1); }
      else { shareId = path; }
      this.parseQuery(query, (k: string, v: string): void => {
        if (k === 'pwd' || k === 'share_pwd') sharePwd = v;
        else if (k === 'file_id' && fileId.length === 0) fileId = v;
      });
      return { shareId, fileId, sharePwd };
    }
    try {
      const proto: number = rawUrl.indexOf('://');
      const rest: string = rawUrl.substring(proto + 3);
      const slash: number = rest.indexOf('/');
      const pathAll: string = slash >= 0 ? rest.substring(slash) : '';
      const q: number = pathAll.indexOf('?');
      const path: string = q >= 0 ? pathAll.substring(0, q) : pathAll;
      const query: string = q >= 0 ? pathAll.substring(q + 1) : '';
      const arr: string[] = path.split('/');
      for (let i = 0; i < arr.length; i++) {
        if (arr[i] === 's' && i + 1 < arr.length) { shareId = arr[i + 1]; break; }
      }
      this.parseQuery(query, (k: string, v: string): void => {
        if (k === 'pwd' || k === 'share_pwd') sharePwd = v;
        else if (k === 'file_id' || k === 'fid') fileId = v;
      });
    } catch (_e) {}
    return { shareId, fileId, sharePwd };
  }

  private parseQuery(query: string, cb: (k: string, v: string) => void): void {
    if (query.length === 0) return;
    const kvs: string[] = query.split('&');
    for (const kv of kvs) {
      const eq: number = kv.indexOf('=');
      if (eq <= 0) continue;
      const k: string = kv.substring(0, eq);
      const v: string = decodeURIComponent(kv.substring(eq + 1));
      cb(k, v);
    }
  }

  private async getStoken(cred: PanCredential, shareId: string, sharePwd: string): Promise<string> {
    const bodyObj: Record<string, Object> = { 'pwd_id': shareId, 'passcode': sharePwd };
    const resp: PanHttpResponse = await panPostJson(this.domain() + '/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc', bodyObj, this.commonHeaders(cred));
    if (resp.status < 200 || resp.status >= 300) throw new Error('HTTP ' + resp.status + ' ' + resp.body);
    const obj = JSON.parse(resp.body) as Record<string, Object>;
    const data = obj['data'] as Record<string, Object> | undefined;
    if (data === undefined || data === null) throw new Error('response missing data: ' + resp.body);
    return data['stoken'] !== undefined ? String(data['stoken']) : '';
  }

  private async getFirstFileId(cred: PanCredential, shareId: string, stoken: string): Promise<string> {
    const url: string = this.domain() + '/1/clouddrive/share/sharepage/detail'
      + '?pr=ucpro&fr=pc&pwd_id=' + encodeURIComponent(shareId)
      + '&stoken=' + encodeURIComponent(stoken)
      + '&pdir_fid=0&force=0&_page=1&_size=50&_fetch_banner=0&_fetch_share=0&_fetch_total=1&_sort=file_type:asc,updated_at:desc';
    const resp: PanHttpResponse = await panRequest(url, { method: 'GET', headers: this.commonHeaders(cred) });
    if (resp.status < 200 || resp.status >= 300) throw new Error('HTTP ' + resp.status + ' ' + resp.body);
    const obj = JSON.parse(resp.body) as Record<string, Object>;
    const data = obj['data'] as Record<string, Object> | undefined;
    if (data === undefined || data === null) throw new Error('response missing data');
    const list = data['list'] as Object[] | undefined;
    if (list === undefined || list === null || list.length === 0) return '';
    for (const it of list) {
      const rec = it as Record<string, Object>;
      if (rec['dir'] === false || rec['dir'] === undefined) {
        return rec['fid'] !== undefined ? String(rec['fid']) : '';
      }
    }
    const rec0 = list[0] as Record<string, Object>;
    return rec0['fid'] !== undefined ? String(rec0['fid']) : '';
  }

  private async getDownloadUrl(cred: PanCredential, shareId: string, stoken: string, fileId: string): Promise<string> {
    const bodyObj: Record<string, Object> = {
      'pwd_id': shareId,
      'stoken': stoken,
      'fids': [fileId],
      'fetch_share': 0
    };
    const url: string = this.domain() + '/1/clouddrive/file/download?pr=ucpro&fr=pc';
    const resp: PanHttpResponse = await panPostJson(url, bodyObj, this.commonHeaders(cred));
    if (resp.status < 200 || resp.status >= 300) throw new Error('HTTP ' + resp.status + ' ' + resp.body);
    const obj = JSON.parse(resp.body) as Record<string, Object>;
    const data = obj['data'] as Object[] | undefined;
    if (data === undefined || data === null || data.length === 0) throw new Error('response missing data: ' + resp.body);
    const rec = data[0] as Record<string, Object>;
    const dl: string = rec['download_url'] !== undefined ? String(rec['download_url']) : '';
    if (dl.length === 0) throw new Error('response missing download_url: ' + resp.body);
    return dl;
  }
}