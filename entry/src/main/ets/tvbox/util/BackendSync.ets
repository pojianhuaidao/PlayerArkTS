/**
 * BackendSync - 把 App 端网盘凭证同步到后端 env.json
 * 通过 POST /api/admin/config  {key, value}  写入。
 * 后端 origin 从 ApiConfig 里找到的任一 type=4 源的 api URL 推导。
 */
import { PanKind, PanConfig, PanCredentialSource } from '../utils/PanConfig';
import { httpPost } from '../utils/HttpUtil';
import { getApiConfig } from '../api/ApiConfig';
import { SourceBean } from '../model/SourceBean';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 从任一 type=4 源的 api 推导后端 origin(scheme://host:port) */
export function detectBackendOrigin(): string {
  const cfg = getApiConfig();
  const sources: SourceBean[] = cfg.getSources();
  for (const s of sources) {
    if (s.type !== 4) continue;
    const api: string = s.api;
    const schemeEnd: number = api.indexOf('://');
    if (schemeEnd < 0) continue;
    const slash: number = api.indexOf('/', schemeEnd + 3);
    return slash < 0 ? api : api.substring(0, slash);
  }
  return '';
}

/** 网盘类型 -> 后端 env.json 里的键名 */
function envKey(kind: PanKind): string {
  if (kind === 'quark') return 'quark_cookie';
  if (kind === 'uc') return 'uc_cookie';
  if (kind === 'ali') return 'ali_token';
  if (kind === 'baidu') return 'baidu_cookie';
  if (kind === 's115') return '115_cookie';
  return '';
}

/** 把凭证 POST 到后端；无后端 origin 时安静返回 false */
export async function syncCredentialToBackend(kind: PanKind, value: string): Promise<boolean> {
  const source: PanCredentialSource = await PanConfig.getCredentialSource(kind);
  if (source === 'backend') {
    hilog.info(0x0001, 'YSC', 'BackendSync skipped (%{public}s backend-first)', kind);
    return false;
  }
  const origin: string = detectBackendOrigin();
  if (origin.length === 0) return false;
  const k: string = envKey(kind);
  if (k.length === 0 || value.length === 0) return false;
  const url: string = origin + '/api/admin/config';
  const body: string = JSON.stringify({ 'key': k, 'value': value });
  const headers: Map<string, string> = new Map();
  headers.set('Content-Type', 'application/json');
  try {
    const resp: string = await httpPost(url, body, headers);
    hilog.info(0x0001, 'YSC', 'BackendSync %{public}s -> %{public}s bytes=%{public}d',
      k, url, resp.length);
    return resp.indexOf('success') >= 0 || resp.indexOf('true') >= 0;
  } catch (e) {
    hilog.warn(0x0001, 'YSC', 'BackendSync failed %{public}s: %{public}s', k, (e as Error).message);
    return false;
  }
}
