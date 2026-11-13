/**
 * S115Client - 115 网盘直链解析
 * 依赖 Cookie，直链换取端点为 webapi.115.com/files/download。
 * 直链要求特定 UA：Mozilla/5.0 QQBrowser/1.0。
 * rawUrl 支持：
 *   115://<pickCode>?ua=xxx
 *   https://115.com/s/<shareId>?password=xxx (仅识别；播放走 pickCode)
 */
import { PanClient, PanResolveResult, singleResolveResult, emptyResolveResult } from './PanTypes';
import { PanConfig, PanCredential } from '../../utils/PanConfig';
import { panRequest, PanHttpResponse } from './PanHttp';

const REFERER: string = 'https://115.com/';
const DEFAULT_UA: string = 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 QQBrowser/1.0';

export class S115Client implements PanClient {
  match(rawUrl: string): boolean {
    if (rawUrl.length === 0) return false;
    const lower: string = rawUrl.toLowerCase();
    return lower.startsWith('115://') || lower.includes('115.com/s/');
  }

  async resolve(rawUrl: string): Promise<PanResolveResult> {
    const cred: PanCredential = await PanConfig.get('s115');
    if (cred.cookie.length === 0) {
      return emptyResolveResult('115 网盘未配置：请在【设置】→【网盘配置】填入 Cookie');
    }
    const pickCode: string = this.extractPickCode(rawUrl);
    if (pickCode.length === 0) {
      return emptyResolveResult('115 链接缺少 pickCode，无法直接换取直链：' + rawUrl);
    }
    try {
      const url: string = await this.getDownloadUrl(cred, pickCode);
      const headers: Map<string, string> = new Map();
      headers.set('Cookie', cred.cookie);
      headers.set('Referer', REFERER);
      headers.set('User-Agent', cred.ua.length > 0 ? cred.ua : DEFAULT_UA);
      return singleResolveResult(url, headers, '原画');
    } catch (e) {
      return emptyResolveResult('115 换取直链失败：' + (e as Error).message);
    }
  }

  private extractPickCode(rawUrl: string): string {
    if (rawUrl.toLowerCase().startsWith('115://')) {
      const rest: string = rawUrl.substring(6);
      const q: number = rest.indexOf('?');
      return q >= 0 ? rest.substring(0, q) : rest;
    }
    return '';
  }

  private async getDownloadUrl(cred: PanCredential, pickCode: string): Promise<string> {
    const ts: number = Math.floor(Date.now() / 1000);
    const url: string = 'https://webapi.115.com/files/download?pickcode=' + encodeURIComponent(pickCode) + '&_=' + ts;
    const headers: Map<string, string> = new Map();
    headers.set('Cookie', cred.cookie);
    headers.set('Referer', REFERER);
    headers.set('User-Agent', cred.ua.length > 0 ? cred.ua : DEFAULT_UA);
    const resp: PanHttpResponse = await panRequest(url, { method: 'GET', headers });
    if (resp.status < 200 || resp.status >= 300) throw new Error('HTTP ' + resp.status + ' ' + resp.body);
    const obj = JSON.parse(resp.body) as Record<string, Object>;
    if (obj['state'] === false) throw new Error(String(obj['msg'] ?? resp.body));
    const fileUrl = obj['file_url'];
    if (fileUrl !== undefined && fileUrl !== null) {
      const s: string = String(fileUrl);
      if (s.length > 0) return s;
    }
    const fileObj = obj['file_info'] as Record<string, Object> | undefined;
    if (fileObj !== undefined && fileObj !== null) {
      const u = fileObj['url'];
      if (u !== undefined && u !== null) {
        const s: string = String(u);
        if (s.length > 0) return s;
      }
    }
    throw new Error('response missing file_url: ' + resp.body);
  }
}