/**
 * AliClient - 阿里云盘（Aliyundrive / 小雅）直链解析
 * 使用 openapi.alipan.com 官方协议：
 *  - refresh_token -> access_token（含轮换回写）
 *  - shareId + shareToken + fileId -> 短时直链
 * 支持 rawUrl 格式：
 *   ali://<shareId>@<fileId>?share_pwd=xxx
 *   https://www.alipan.com/s/<shareId>[/folder/<fileId>][?pwd=xxx]
 */
import { PanClient, PanResolveResult, singleResolveResult, emptyResolveResult } from './PanTypes';
import { PanConfig, PanCredential } from '../../utils/PanConfig';
import { panPostJson, PanHttpResponse } from './PanHttp';

const API_BASE: string = 'https://openapi.alipan.com';
const REFERER: string = 'https://www.alipan.com/';
const DEFAULT_UA: string = 'Mozilla/5.0 (Linux; U; HarmonyOS; TVBox/1.0) AppleWebKit/537.36';

interface ShareFile { shareId: string; fileId: string; sharePwd: string; }

export class AliClient implements PanClient {
  match(rawUrl: string): boolean {
    if (rawUrl.length === 0) return false;
    const lower: string = rawUrl.toLowerCase();
    if (lower.startsWith('ali://')) return true;
    if (lower.includes('alipan.com/s/') || lower.includes('aliyundrive.com/s/')) return true;
    return false;
  }

  async resolve(rawUrl: string): Promise<PanResolveResult> {
    const cred: PanCredential = await PanConfig.get('ali');
    if (cred.token.length === 0) {
      return emptyResolveResult('阿里云盘未配置：请在【设置】→【网盘配置】填入 refresh_token');
    }
    const parsed: ShareFile = this.extractShareFile(rawUrl);
    if (parsed.shareId.length === 0 || parsed.fileId.length === 0) {
      return emptyResolveResult('阿里云盘链接缺少 shareId / fileId：' + rawUrl);
    }
    try { await this.ensureAccessToken(cred); }
    catch (e) { return emptyResolveResult('阿里刷新 access_token 失败：' + (e as Error).message); }
    let shareToken: string = '';
    try { shareToken = await this.getShareToken(parsed.shareId, parsed.sharePwd); }
    catch (e) { return emptyResolveResult('阿里获取 share_token 失败：' + (e as Error).message); }
    try {
      const url: string = await this.getDownloadUrl(cred, parsed.shareId, parsed.fileId, shareToken);
      const headers: Map<string, string> = new Map();
      headers.set('Referer', REFERER);
      headers.set('User-Agent', cred.ua.length > 0 ? cred.ua : DEFAULT_UA);
      return singleResolveResult(url, headers, '原画');
    } catch (e) {
      return emptyResolveResult('阿里换取直链失败：' + (e as Error).message);
    }
  }

  private extractShareFile(rawUrl: string): ShareFile {
    let shareId: string = '';
    let fileId: string = '';
    let sharePwd: string = '';
    if (rawUrl.toLowerCase().startsWith('ali://')) {
      const withoutScheme: string = rawUrl.substring(6);
      const qIdx: number = withoutScheme.indexOf('?');
      const path: string = qIdx >= 0 ? withoutScheme.substring(0, qIdx) : withoutScheme;
      const query: string = qIdx >= 0 ? withoutScheme.substring(qIdx + 1) : '';
      const atIdx: number = path.indexOf('@');
      if (atIdx >= 0) { shareId = path.substring(0, atIdx); fileId = path.substring(atIdx + 1); }
      else { shareId = path; }
      if (query.length > 0) {
        const kvs: string[] = query.split('&');
        for (const kv of kvs) {
          const eq: number = kv.indexOf('=');
          if (eq <= 0) continue;
          const k: string = kv.substring(0, eq);
          const v: string = decodeURIComponent(kv.substring(eq + 1));
          if (k === 'share_pwd' || k === 'pwd') sharePwd = v;
          else if (k === 'file_id' && fileId.length === 0) fileId = v;
        }
      }
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
        if (arr[i] === 's' && i + 1 < arr.length) shareId = arr[i + 1];
        if (arr[i] === 'folder' && i + 1 < arr.length) fileId = arr[i + 1];
        if (arr[i] === 'file' && i + 1 < arr.length) fileId = arr[i + 1];
      }
      if (query.length > 0) {
        const kvs: string[] = query.split('&');
        for (const kv of kvs) {
          const eq: number = kv.indexOf('=');
          if (eq <= 0) continue;
          const k: string = kv.substring(0, eq);
          const v: string = decodeURIComponent(kv.substring(eq + 1));
          if (k === 'pwd' || k === 'share_pwd') sharePwd = v;
          else if (k === 'file_id') fileId = v;
        }
      }
    } catch (_e) {}
    return { shareId, fileId, sharePwd };
  }

  private async ensureAccessToken(cred: PanCredential): Promise<void> {
    const now: number = Date.now();
    if (cred.accessToken.length > 0 && cred.accessExpireAt > now + 60000) return;
    const bodyObj: Record<string, Object> = { 'grant_type': 'refresh_token', 'refresh_token': cred.token };
    const resp: PanHttpResponse = await panPostJson(API_BASE + '/oauth/access_token', bodyObj);
    if (resp.status < 200 || resp.status >= 300) throw new Error('HTTP ' + resp.status + ' ' + resp.body);
    const obj = JSON.parse(resp.body) as Record<string, Object>;
    const newAccess: string = obj['access_token'] !== undefined ? String(obj['access_token']) : '';
    const newRefresh: string = obj['refresh_token'] !== undefined ? String(obj['refresh_token']) : '';
    const expiresIn: number = obj['expires_in'] !== undefined ? Number(obj['expires_in']) : 3600;
    if (newAccess.length === 0) throw new Error('response missing access_token: ' + resp.body);
    cred.accessToken = newAccess;
    cred.accessExpireAt = now + Math.max(60, expiresIn - 60) * 1000;
    if (newRefresh.length > 0) cred.token = newRefresh;
    await PanConfig.set(cred);
  }

  private async getShareToken(shareId: string, sharePwd: string): Promise<string> {
    const bodyObj: Record<string, Object> = { 'share_id': shareId, 'share_pwd': sharePwd };
    const resp: PanHttpResponse = await panPostJson(API_BASE + '/adrive/v1.0/share_link/get_share_token', bodyObj);
    if (resp.status < 200 || resp.status >= 300) throw new Error('HTTP ' + resp.status + ' ' + resp.body);
    const obj = JSON.parse(resp.body) as Record<string, Object>;
    return obj['share_token'] !== undefined ? String(obj['share_token']) : '';
  }

  private async getDownloadUrl(cred: PanCredential, shareId: string, fileId: string, shareToken: string): Promise<string> {
    const headers: Map<string, string> = new Map();
    headers.set('Authorization', 'Bearer ' + cred.accessToken);
    headers.set('x-share-token', shareToken);
    const bodyObj: Record<string, Object> = { 'share_id': shareId, 'file_id': fileId };
    const resp: PanHttpResponse = await panPostJson(API_BASE + '/adrive/v1.0/openFile/getShareLinkDownloadUrl', bodyObj, headers);
    if (resp.status < 200 || resp.status >= 300) throw new Error('HTTP ' + resp.status + ' ' + resp.body);
    const obj = JSON.parse(resp.body) as Record<string, Object>;
    const url: string = obj['url'] !== undefined ? String(obj['url']) : '';
    if (url.length === 0) throw new Error('response missing url: ' + resp.body);
    return url;
  }
}