/**
 * BaiduClient - 百度网盘直链解析
 * 依赖 BDUSS Cookie。直链请求端点：pan.baidu.com/api/download 或 pcs.baidu.com/rest/2.0/pcs/file
 * rawUrl 支持：
 *   baidu://<shareId>@<fs_id>?pwd=xxx
 *   https://pan.baidu.com/s/<shareId>[?pwd=xxx]
 */
import { PanClient, PanResolveResult, singleResolveResult, emptyResolveResult } from './PanTypes';
import { PanConfig, PanCredential } from '../../utils/PanConfig';
import { panRequest, PanHttpResponse } from './PanHttp';

const REFERER: string = 'https://pan.baidu.com/';
const DEFAULT_UA: string = 'netdisk;11.14.5;PC;PC-Windows;10.0.22631;WindowsBaiduYunGuanJia';

interface ShareFile { shareId: string; fsId: string; sharePwd: string; }

export class BaiduClient implements PanClient {
  match(rawUrl: string): boolean {
    if (rawUrl.length === 0) return false;
    const lower: string = rawUrl.toLowerCase();
    return lower.startsWith('baidu://') || lower.includes('pan.baidu.com/s/');
  }

  async resolve(rawUrl: string): Promise<PanResolveResult> {
    const cred: PanCredential = await PanConfig.get('baidu');
    if (cred.cookie.length === 0) {
      return emptyResolveResult('百度网盘未配置：请在【设置】→【网盘配置】填入 BDUSS Cookie');
    }
    const parsed: ShareFile = this.extractShareFile(rawUrl);
    if (parsed.shareId.length === 0 || parsed.fsId.length === 0) {
      return emptyResolveResult('百度网盘链接缺少 shareId / fs_id：' + rawUrl);
    }
    try {
      const url: string = await this.getDownloadUrl(cred, parsed);
      const headers: Map<string, string> = new Map();
      headers.set('Cookie', cred.cookie);
      headers.set('Referer', REFERER);
      headers.set('User-Agent', cred.ua.length > 0 ? cred.ua : DEFAULT_UA);
      return singleResolveResult(url, headers, '原画');
    } catch (e) {
      return emptyResolveResult('百度换取直链失败：' + (e as Error).message);
    }
  }

  private extractShareFile(rawUrl: string): ShareFile {
    let shareId: string = '';
    let fsId: string = '';
    let sharePwd: string = '';
    if (rawUrl.toLowerCase().startsWith('baidu://')) {
      const withoutScheme: string = rawUrl.substring(8);
      const qIdx: number = withoutScheme.indexOf('?');
      const path: string = qIdx >= 0 ? withoutScheme.substring(0, qIdx) : withoutScheme;
      const query: string = qIdx >= 0 ? withoutScheme.substring(qIdx + 1) : '';
      const atIdx: number = path.indexOf('@');
      if (atIdx >= 0) { shareId = path.substring(0, atIdx); fsId = path.substring(atIdx + 1); }
      else { shareId = path; }
      if (query.length > 0) {
        const kvs: string[] = query.split('&');
        for (const kv of kvs) {
          const eq: number = kv.indexOf('=');
          if (eq <= 0) continue;
          const k: string = kv.substring(0, eq);
          const v: string = decodeURIComponent(kv.substring(eq + 1));
          if (k === 'pwd' || k === 'share_pwd') sharePwd = v;
          else if (k === 'fs_id' && fsId.length === 0) fsId = v;
        }
      }
    }
    return { shareId, fsId, sharePwd };
  }

  private async getDownloadUrl(cred: PanCredential, parsed: ShareFile): Promise<string> {
    const url: string = 'https://pan.baidu.com/api/sharedownload'
      + '?sign=&timestamp=' + Math.floor(Date.now() / 1000)
      + '&channel=chunlei&web=1&app_id=250528&clienttype=0';
    const headers: Map<string, string> = new Map();
    headers.set('Cookie', cred.cookie);
    headers.set('Referer', REFERER);
    headers.set('User-Agent', cred.ua.length > 0 ? cred.ua : DEFAULT_UA);
    headers.set('Content-Type', 'application/x-www-form-urlencoded');
    const form: string = 'encrypt=0&extra=' + encodeURIComponent(JSON.stringify({ 'sekey': parsed.sharePwd }))
      + '&fid_list=' + encodeURIComponent('[' + parsed.fsId + ']')
      + '&primaryid=' + encodeURIComponent(parsed.shareId)
      + '&product=share&type=nolimit&uk=';
    const resp: PanHttpResponse = await panRequest(url, { method: 'POST', body: form, headers });
    if (resp.status < 200 || resp.status >= 300) throw new Error('HTTP ' + resp.status + ' ' + resp.body);
    const obj = JSON.parse(resp.body) as Record<string, Object>;
    const errno: number = obj['errno'] !== undefined ? Number(obj['errno']) : -1;
    if (errno !== 0) throw new Error('errno=' + errno + ' body=' + resp.body);
    const list = obj['list'] as Object[] | undefined;
    if (list === undefined || list === null || list.length === 0) throw new Error('empty list');
    const rec = list[0] as Record<string, Object>;
    const dl: string = rec['dlink'] !== undefined ? String(rec['dlink']) : '';
    if (dl.length === 0) throw new Error('response missing dlink: ' + resp.body);
    return dl;
  }
}