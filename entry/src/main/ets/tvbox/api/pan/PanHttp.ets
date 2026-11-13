/**
 * PanHttp - Pan Client 专用 HTTP 工具
 *
 * 相比 utils/HttpUtil，PanHttp 需要：
 * 1. 返回 responseCode + headers + body（含 Set-Cookie）
 * 2. 支持关闭自动跟随 302，拿到 Location 直接作为直链
 * 3. 支持自定义 UA / Referer / Cookie
 * 4. 请求错误不做重试，交由上层业务判定
 */
import { http } from '@kit.NetworkKit';
import { formatError } from '../../utils/HttpUtil';

export interface PanHttpResponse {
  status: number;
  body: string;
  headers: Map<string, string>;
  /** 合并后的所有 Set-Cookie 项（多值场景） */
  setCookies: string[];
}

export interface PanHttpOptions {
  method?: string;
  body?: string;
  headers?: Map<string, string>;
  /** 关闭自动跟随重定向，用于换直链场景 */
  noFollow?: boolean;
  connectTimeout?: number;
  readTimeout?: number;
}

/** 把 header record 的多值 Set-Cookie 拆解为字符串数组 */
function extractSetCookies(header: Record<string, Object>): string[] {
  const out: string[] = [];
  for (const k of Object.keys(header)) {
    if (k.toLowerCase() !== 'set-cookie') continue;
    const v: Object = header[k];
    if (Array.isArray(v)) {
      const arr = v as Object[];
      for (const item of arr) out.push(String(item));
    } else {
      const s: string = String(v);
      // 有些实现把多条 Set-Cookie 用 ", " 拼在一起；粗略按 "expires=" 之间的边界切分不可靠，
      // 这里保持一整段返回，上层自己按需 parse
      out.push(s);
    }
  }
  return out;
}

function toHeaderMap(header: Record<string, Object>): Map<string, string> {
  const map: Map<string, string> = new Map();
  for (const k of Object.keys(header)) {
    const v: Object = header[k];
    if (Array.isArray(v)) {
      const arr = v as Object[];
      map.set(k, arr.map(x => String(x)).join('; '));
    } else {
      map.set(k, String(v));
    }
  }
  return map;
}

const DEFAULT_UA: string = 'Mozilla/5.0 (Linux; HarmonyOS; TVBox) AppleWebKit/537.36';

export async function panRequest(url: string, opts: PanHttpOptions): Promise<PanHttpResponse> {
  const headerObj: Record<string, string> = {
    'User-Agent': DEFAULT_UA,
    'Accept': '*/*',
    'Connection': 'keep-alive'
  };
  if (opts.headers) {
    opts.headers.forEach((v: string, k: string) => { headerObj[k] = v; });
  }
  const method: string = (opts.method ?? 'GET').toUpperCase();
  const reqMethod: http.RequestMethod = method === 'POST' ? http.RequestMethod.POST
    : (method === 'HEAD' ? http.RequestMethod.HEAD
      : (method === 'PUT' ? http.RequestMethod.PUT
        : (method === 'DELETE' ? http.RequestMethod.DELETE : http.RequestMethod.GET)));

  const options: http.HttpRequestOptions = {
    method: reqMethod,
    header: headerObj,
    extraData: opts.body ?? '',
    expectDataType: http.HttpDataType.STRING,
    connectTimeout: opts.connectTimeout ?? 15000,
    readTimeout: opts.readTimeout ?? 15000,
    usingCache: false,
    priority: 0
  };
  // 关闭跟随重定向
  if (opts.noFollow === true) {
    (options as Record<string, Object>)['usingProtocol'] = http.HttpProtocol.HTTP1_1;
    // 兼容不同 SDK 版本：followRedirects 字段可能不存在，做防御性赋值
    (options as Record<string, Object>)['followRedirect'] = false;
    (options as Record<string, Object>)['followRedirects'] = false;
  }

  const httpReq = http.createHttp();
  try {
    const response = await httpReq.request(url, options);
    const headerRecord: Record<string, Object> = (response.header ?? {}) as Record<string, Object>;
    const map: Map<string, string> = toHeaderMap(headerRecord);
    const setCookies: string[] = extractSetCookies(headerRecord);
    const bodyStr: string = typeof response.result === 'string' ? response.result as string : '';
    const out: PanHttpResponse = {
      status: response.responseCode,
      body: bodyStr,
      headers: map,
      setCookies
    };
    return out;
  } catch (err) {
    throw new Error(formatError(err));
  } finally {
    httpReq.destroy();
  }
}

/** 便捷 GET，返回 body 文本；非 2xx 抛出 */
export async function panGetText(url: string, headers?: Map<string, string>): Promise<string> {
  const resp = await panRequest(url, { method: 'GET', headers });
  if (resp.status < 200 || resp.status >= 300) {
    throw new Error('HTTP ' + resp.status + ': ' + url);
  }
  return resp.body;
}

/** 便捷 POST-JSON */
export async function panPostJson(url: string, body: Record<string, Object>, headers?: Map<string, string>): Promise<PanHttpResponse> {
  const merged: Map<string, string> = new Map();
  merged.set('Content-Type', 'application/json;charset=UTF-8');
  if (headers) headers.forEach((v: string, k: string) => merged.set(k, v));
  return await panRequest(url, { method: 'POST', body: JSON.stringify(body), headers: merged });
}

/** 便捷 POST-form */
export async function panPostForm(url: string, form: Map<string, string>, headers?: Map<string, string>): Promise<PanHttpResponse> {
  const parts: string[] = [];
  form.forEach((v: string, k: string) => {
    parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(v));
  });
  const merged: Map<string, string> = new Map();
  merged.set('Content-Type', 'application/x-www-form-urlencoded;charset=UTF-8');
  if (headers) headers.forEach((v: string, k: string) => merged.set(k, v));
  return await panRequest(url, { method: 'POST', body: parts.join('&'), headers: merged });
}

/** 提取响应头某个字段（大小写不敏感） */
export function getRespHeader(resp: PanHttpResponse, name: string): string {
  const lower: string = name.toLowerCase();
  let found: string = '';
  resp.headers.forEach((v: string, k: string) => {
    if (k.toLowerCase() === lower && found.length === 0) found = v;
  });
  return found;
}
