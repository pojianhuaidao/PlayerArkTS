/**
 * HTTP 网络请求工具
 * 基于 @ohos.net.http (HarmonyOS NEXT)
 */
import { http } from '@kit.NetworkKit';

const DEFAULT_TIMEOUT = 20000;
const DEFAULT_RETRY = 2;
const DEFAULT_UA = 'okhttp/3.15';

/**
 * 把任意异常转为可读的错误信息。
 * HarmonyOS 的 http 接口抛出的是 BusinessError（含 code/message/data），
 * 它不是 Error 实例，对于系统异常 String(err) 会返回 "[object Object]"。
 */
export function formatError(err: Object): string {
  if (err instanceof Error) {
    return err.message;
  }
  if (err !== null && typeof err === 'object') {
    const be = err as Record<string, Object>;
    const code = be['code'];
    const msg = be['message'];
    const msgStr = msg !== undefined ? String(msg) : '';
    if (code !== undefined) {
      return '[' + String(code) + '] ' + msgStr;
    }
    if (msgStr.length > 0) {
      return msgStr;
    }
    try {
      return JSON.stringify(err);
    } catch (_e) {
      return String(err);
    }
  }
  return String(err);
}

/**
 * Punycode 编码常量 (RFC 3492)
 */
const PC_BASE = 36;
const PC_TMIN = 1;
const PC_TMAX = 26;
const PC_SKEW = 38;
const PC_DAMP = 700;
const PC_INITIAL_BIAS = 72;
const PC_INITIAL_N = 128;
const PC_DELIMITER = '-';

function pcAdapt(delta: number, numPoints: number, firstTime: boolean): number {
  let d = delta;
  d = firstTime ? Math.floor(d / PC_DAMP) : (d >> 1);
  d += Math.floor(d / numPoints);
  let k = 0;
  while (d > ((PC_BASE - PC_TMIN) * PC_TMAX) >> 1) {
    d = Math.floor(d / (PC_BASE - PC_TMIN));
    k += PC_BASE;
  }
  return k + Math.floor((PC_BASE - PC_TMIN + 1) * d / (d + PC_SKEW));
}

function pcDigitToBasic(digit: number, flag: boolean): number {
  return digit + 22 + 75 * (digit < 26 ? 1 : 0) - (flag ? 32 : 0);
}

/**
 * 把单个域名标签（如 "肥猫"）转为 Punycode（如 "z7x900a"）。
 * 仅含 ASCII 的标签原样返回。
 */
function punycodeEncodeLabel(label: string): string {
  const codePoints: number[] = [];
  for (let i = 0; i < label.length; i++) {
    const cp: number = label.codePointAt(i) ?? 0;
    codePoints.push(cp);
    if (cp > 0xFFFF) i++;
  }

  const output: string[] = [];
  const basicCPs: number[] = [];
  for (const cp of codePoints) {
    if (cp < 128) basicCPs.push(cp);
  }
  const basicLength = basicCPs.length;
  let handledCPCount = basicLength;

  for (const cp of basicCPs) {
    output.push(String.fromCharCode(cp));
  }

  let n = PC_INITIAL_N;
  let delta = 0;
  let bias = PC_INITIAL_BIAS;

  while (handledCPCount < codePoints.length) {
    let m = Infinity;
    for (const cp of codePoints) {
      if (cp >= n && cp < m) m = cp;
    }
    delta += (m - n) * (handledCPCount + 1);
    n = m;
    for (const cp of codePoints) {
      if (cp < n) delta++;
      if (cp === n) {
        let q = delta;
        let k = PC_BASE;
        while (true) {
          const t = k <= bias ? PC_TMIN : (k >= bias + PC_TMAX ? PC_TMAX : k - bias);
          if (q < t) break;
          const digit = t + (q - t) % (PC_BASE - t);
          output.push(String.fromCharCode(pcDigitToBasic(digit, false)));
          q = Math.floor((q - t) / (PC_BASE - t));
          k += PC_BASE;
        }
        output.push(String.fromCharCode(pcDigitToBasic(q, false)));
        bias = pcAdapt(delta, handledCPCount + 1, handledCPCount === basicLength);
        delta = 0;
        handledCPCount++;
      }
    }
    delta++;
    n++;
  }

  if (basicLength > 0) {
    const basicPart = output.slice(0, basicLength).join('');
    const extendedPart = output.slice(basicLength).join('');
    if (extendedPart.length > 0) {
      return basicPart + PC_DELIMITER + extendedPart;
    }
    return basicPart;
  }
  return output.join('');
}

/**
 * 对 URL 进行规范化：
 * 1. 把含非 ASCII 字符的域名标签转为 Punycode（如 肥猫 -> xn--z7x900a）
 * 2. 对路径中的非 ASCII 字符做百分号编码
 * 例如 http://肥猫.net/tv -> http://xn--z7x900a.net/tv
 */
/**
 * 对 path/query 编码：编码中文及 [ ] 等不安全字符，但保留已有的 %XX 转义，避免二次编码。
 */
function encodePreservingEscapes(part: string): string {
  let out: string = '';
  for (let i = 0; i < part.length; i++) {
    const ch: string = part.charAt(i);
    // 已经是 %XX 转义序列，原样保留
    if (ch === '%' && i + 2 < part.length) {
      const h1: string = part.charAt(i + 1);
      const h2: string = part.charAt(i + 2);
      const isHex: boolean = /[0-9A-Fa-f]/.test(h1) && /[0-9A-Fa-f]/.test(h2);
      if (isHex) {
        out += ch + h1 + h2;
        i += 2;
        continue;
      }
    }
    const code: number = part.charCodeAt(i);
    // 保留 URL 结构与安全字符
    if (code < 128 && !/[\s\[\]<>"'{}|\\^`]/.test(ch)) {
      out += ch;
    } else {
      out += encodeURI(ch);
    }
  }
  return out;
}

function encodeUrl(rawUrl: string): string {
  try {
    if (rawUrl.length === 0) return rawUrl;
    const idx = rawUrl.indexOf('://');
    if (idx < 0) return rawUrl;
    const scheme = rawUrl.substring(0, idx + 3);
    const rest = rawUrl.substring(idx + 3);
    const slash = rest.indexOf('/');
    let host: string;
    let pathPart: string;
    if (slash < 0) {
      host = rest;
      pathPart = '';
    } else {
      host = rest.substring(0, slash);
      pathPart = rest.substring(slash);
    }
    const encodedHost = host.split('.').map((label: string): string => {
      if (label.length === 0) return label;
      let hasNonAscii = false;
      for (let i = 0; i < label.length; i++) {
        if (label.charCodeAt(i) > 127) { hasNonAscii = true; break; }
      }
      if (!hasNonAscii) return label;
      return 'xn--' + punycodeEncodeLabel(label);
    }).join('.');
    let encodedPath = pathPart;
    let hasNonAsciiPath = false;
    for (let i = 0; i < pathPart.length; i++) {
      if (pathPart.charCodeAt(i) > 127) { hasNonAsciiPath = true; break; }
    }
    if (hasNonAsciiPath) encodedPath = encodePreservingEscapes(pathPart);
    return scheme + encodedHost + encodedPath;
  } catch (_e) {
    return rawUrl;
  }
}

/** GET 缓存选项 */
export interface HttpCacheOptions {
  /** 缓存有效期（毫秒）。缺省用默认 TTL；传 0 表示禁用缓存（如配置/播放/解析等实时请求） */
  ttlMs?: number;
}

/** 默认缓存有效期：10 分钟。过期后下次访问自动重新拉取，等效"定时刷新" */
const HTTP_CACHE_TTL: number = 10 * 60 * 1000;
/** 缓存条目上限，超出后淘汰最旧条目，防止内存无限增长 */
const HTTP_CACHE_MAX: number = 200;

interface HttpCacheEntry {
  ts: number;
  data: string;
}

const httpCache: Map<string, HttpCacheEntry> = new Map();

/** 清空 HTTP 缓存（下拉刷新/手动刷新时调用，强制下次请求重新拉取） */
export function clearHttpCache(): void {
  httpCache.clear();
}

/**
 * GET 请求
 * @param opts.ttlMs 缓存有效期毫秒；缺省默认 10 分钟；传 0 禁用缓存
 */
export async function httpGet(url: string, headers?: Map<string, string>, opts?: HttpCacheOptions): Promise<string> {
  const encoded: string = encodeUrl(url);
  const ttlMs: number = opts !== undefined && opts.ttlMs !== undefined ? opts.ttlMs : HTTP_CACHE_TTL;
  if (ttlMs > 0) {
    const entry = httpCache.get(encoded);
    if (entry !== undefined && Date.now() - entry.ts < ttlMs) {
      return entry.data;
    }
  }
  const data: string = await httpRequest(encoded, http.RequestMethod.GET, '', headers);
  if (ttlMs > 0) {
    if (httpCache.size >= HTTP_CACHE_MAX) {
      // 淘汰最旧条目
      let oldestKey: string = '';
      let oldestTs: number = Number.MAX_SAFE_INTEGER;
      httpCache.forEach((e: HttpCacheEntry, k: string): void => {
        if (e.ts < oldestTs) {
          oldestTs = e.ts;
          oldestKey = k;
        }
      });
      if (oldestKey.length > 0) {
        httpCache.delete(oldestKey);
      }
    }
    httpCache.set(encoded, { ts: Date.now(), data: data });
  }
  return data;
}

/**
 * POST 请求
 */
export async function httpPost(url: string, body?: string, headers?: Map<string, string>): Promise<string> {
  return await httpRequest(encodeUrl(url), http.RequestMethod.POST, body ?? '', headers);
}

/**
 * 底层请求封装
 */
async function httpRequest(
  url: string,
  method: http.RequestMethod,
  body: string,
  headers?: Map<string, string>
): Promise<string> {
  const headerObj: Record<string, string> = {
    'User-Agent': DEFAULT_UA,
    'Accept': '*/*',
    'Connection': 'keep-alive'
  };

  if (headers) {
    headers.forEach((v: string, k: string) => {
      headerObj[k] = v;
    });
  }

  const options: http.HttpRequestOptions = {
    method: method,
    header: headerObj,
    extraData: body,
    expectDataType: http.HttpDataType.STRING,
    connectTimeout: DEFAULT_TIMEOUT,
    readTimeout: DEFAULT_TIMEOUT,
    usingCache: false,
    priority: 0
  };

  let lastErr: string = '';
  for (let attempt = 0; attempt <= DEFAULT_RETRY; attempt++) {
    const httpReq = http.createHttp();
    try {
      const response = await httpReq.request(url, options);
      const code: number = response.responseCode;
      httpReq.destroy();
      if (code === 200 || code === 206) {
        return response.result as string;
      }
      // 5xx/429 等服务端瞬时错误：重试；4xx(除429) 直接失败
      lastErr = 'HTTP ' + code + ': ' + url;
      if (!(code >= 500 || code === 429) || attempt === DEFAULT_RETRY) {
        throw new Error(lastErr);
      }
    } catch (err) {
      httpReq.destroy();
      lastErr = formatError(err);
      if (attempt === DEFAULT_RETRY) {
        throw new Error(lastErr);
      }
    }
    // 退避后重试
    await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 300 + attempt * 400); });
  }
  throw new Error(lastErr);
}
