import { http } from '@kit.NetworkKit';
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLog } from '../log/AppLog';

const DOMAIN: number = 0x0001;
const TAG: string = 'LxHttp';

/**
 * 上游自定义音源网络代理
 *
 * 移植自 lx-music-mobile/src/core/init/userApi/request.js + src/utils/request.js：
 * 源脚本里的 lx.request(url, options) 最终会走到这里，由宿主 App 发起真实请求，
 * 再把响应回灌给沙箱。请求语义（默认 UA / Content-Type 推断 / body 处理 /
 * 响应 JSON 自动解析）都与上游保持一致。
 */

/** 与上游默认 UA 一致，部分平台的 API 会校验 UA */
const DEFAULT_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36';

/**
 * 默认超时。调成 20s：部分音源（如 V6 的 /v4s/url 代理接口）要跨网转发、
 * 冷启动较慢，13s 在弱网下容易先超时（表现为「Failed to connect to the server」）。
 */
const DEFAULT_TIMEOUT: number = 20000;

export interface LxRequestOptions {
  method?: string;
  headers?: Record<string, string>;
  body?: string | Object;
  form?: Record<string, string>;
  formData?: Record<string, string>;
  timeout?: number;
  binary?: boolean;
  /** 为 true 时不做 JSON 解析，body 始终返回原始文本（用于下载源脚本） */
  rawText?: boolean;
  /**
   * 最大重定向次数。0 = 由调用方自己处理 3xx（从响应的 Location 头里读下一跳），
   * 用于把短链（163cn.tv / c.migu.cn / t1.kugou.com 这类）解析成最终地址。
   * 不传时保持系统默认（30 次自动跟随），与源脚本的请求语义一致。
   */
  maxRedirects?: number;
}

export interface LxResponse {
  statusCode: number;
  statusMessage: string;
  headers: Record<string, string>;
  /** 非二进制：解析后的 JSON 对象或原始文本；二进制：字节数组 */
  body: string | Object | number[];
  url: string;
  ok: boolean;
}

export interface LxRequestHandle {
  abort: () => void;
}

function encodeForm(form: Record<string, string>): string {
  const parts: string[] = [];
  const keys: string[] = Object.keys(form);
  for (const key of keys) {
    parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(form[key])}`);
  }
  return parts.join('&');
}

function encodeMultipart(formData: Record<string, string>, boundary: string): string {
  const lines: string[] = [];
  const keys: string[] = Object.keys(formData);
  for (const key of keys) {
    lines.push(`--${boundary}`);
    lines.push(`Content-Disposition: form-data; name="${key}"`);
    lines.push('');
    lines.push(formData[key]);
  }
  lines.push(`--${boundary}--`);
  lines.push('');
  return lines.join('\r\n');
}

function stringifyBody(body: string | Object): string {
  if (typeof body === 'string') {
    return body;
  }
  return JSON.stringify(body);
}

function arrayBufferToBytes(buffer: ArrayBuffer): number[] {
  const view = new Uint8Array(buffer);
  const out: number[] = [];
  for (let i = 0; i < view.length; i++) {
    out.push(view[i]);
  }
  return out;
}

function toHeaderRecord(header: Object): Record<string, string> {
  const out: Record<string, string> = {};
  if (header === null || header === undefined) {
    return out;
  }
  try {
    const parsed = JSON.parse(JSON.stringify(header)) as Record<string, Object>;
    const keys: string[] = Object.keys(parsed);
    for (const key of keys) {
      const value: Object = parsed[key];
      out[key] = typeof value === 'string' ? value as string : JSON.stringify(value);
    }
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'failed to normalize response headers: %{public}s', JSON.stringify(e));
  }
  return out;
}

function toHttpMethod(method: string): http.RequestMethod {
  switch (method) {
    case 'GET':
      return http.RequestMethod.GET;
    case 'HEAD':
      return http.RequestMethod.HEAD;
    case 'PUT':
      return http.RequestMethod.PUT;
    case 'DELETE':
      return http.RequestMethod.DELETE;
    case 'OPTIONS':
      return http.RequestMethod.OPTIONS;
    case 'TRACE':
      return http.RequestMethod.TRACE;
    case 'CONNECT':
      return http.RequestMethod.CONNECT;
    default:
      return http.RequestMethod.POST;
  }
}

/** 从 URL 里取出 host（含端口），拿不到时返回原 url 截断的前 60 字符 */
function hostOf(url: string): string {
  const schemeEnd: number = url.indexOf('://');
  const start: number = schemeEnd >= 0 ? schemeEnd + 3 : 0;
  let end: number = url.length;
  const slash: number = url.indexOf('/', start);
  if (slash >= 0 && slash < end) {
    end = slash;
  }
  const q: number = url.indexOf('?', start);
  if (q >= 0 && q < end) {
    end = q;
  }
  const hash: number = url.indexOf('#', start);
  if (hash >= 0 && hash < end) {
    end = hash;
  }
  const host: string = url.substring(start, end);
  return host.length > 0 ? host : url;
}

/** 是否含非 ASCII 字符（中文域名等 IDN）；http 栈对 IDN 支持不稳定，命中时预警 */
function hasNonAscii(s: string): boolean {
  for (let i = 0; i < s.length; i++) {
    if (s.charCodeAt(i) > 127) {
      return true;
    }
  }
  return false;
}

/**
 * TCP 分层诊断：绕过 http 栈直接对目标 host:port 发起 TCP 连接，
 * 用于区分 V6 code=2300007（Failed to connect）到底是 DNS 解析失败、
 * 网络不可达还是对端拒绝连接；若 TCP 通而 http 失败，问题在 TLS/应用层。
 */
function tcpDiag(host: string, port: number): void {
  const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
  const startMs: number = Date.now();
  tcp.connect({
    address: { address: host, port: port, family: 1 },
    timeout: 8000,
  })
    .then(() => {
      const elapsed: number = Date.now() - startMs;
      AppLog.info(TAG, `TCP诊断 host=${host} port=${port} 成功 耗时=${elapsed}ms`);
      hilog.info(DOMAIN, TAG, 'tcpDiag ok host=%{public}s port=%{public}d elapsed=%{public}dms', host, port, elapsed);
      try {
        tcp.close();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'tcpDiag close failed: %{public}s', JSON.stringify(e));
      }
    })
    .catch((err: BusinessError) => {
      const elapsed: number = Date.now() - startMs;
      const errCode: string = err.code !== undefined ? `${err.code}` : '?';
      AppLog.error(TAG, `TCP诊断 host=${host} port=${port} 失败 code=${errCode} msg=${err.message} 耗时=${elapsed}ms`);
      hilog.error(DOMAIN, TAG, 'tcpDiag failed host=%{public}s port=%{public}d code=%{public}s elapsed=%{public}dms',
        host, err.message, errCode, elapsed);
      try {
        tcp.close();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'tcpDiag close failed: %{public}s', JSON.stringify(e));
      }
    });
}

/**
 * 发起一次请求。
 * @returns 句柄，调用 abort() 可中断请求（对应源脚本里 lx.request 返回的 cancel 函数）
 */
export function lxRequest(
  url: string,
  options: LxRequestOptions,
  onSuccess: (resp: LxResponse) => void,
  onError: (message: string) => void
): LxRequestHandle {
  const httpRequest: http.HttpRequest = http.createHttp();
  let destroyed: boolean = false;
  const method: string = options.method !== undefined ? options.method.toUpperCase() : 'GET';
  const timeout: number = (options.timeout !== undefined && options.timeout > 0) ? options.timeout : DEFAULT_TIMEOUT;
  const host: string = hostOf(url);

  // IDN 预警：源脚本若把中文域名原样交给宿主，http 栈可能解析失败；V6 域名
  // 88.lxmusic.xn--fiqs8s 已是 punycode，正常不会命中，但其它音源可能踩坑
  if (hasNonAscii(host)) {
    AppLog.warn(TAG, `IDN 域名「${host}」含非 ASCII 字符，http 栈可能解析失败，建议改用 punycode（xn-- 形式）`);
    hilog.warn(DOMAIN, TAG, 'idn host detected: %{public}s', host);
  }
  const startMs: number = Date.now();
  AppLog.info(TAG, `请求发起 ${method} ${url} timeout=${timeout}ms`);

  const headers: Record<string, string> = {};
  // 上游默认带 Accept: application/json
  headers['Accept'] = 'application/json';
  headers['User-Agent'] = DEFAULT_UA;
  if (options.headers !== undefined) {
    const keys: string[] = Object.keys(options.headers);
    for (const key of keys) {
      headers[key] = options.headers[key];
    }
  }

  let contentType: string = '';
  const headerKeys: string[] = Object.keys(headers);
  for (const key of headerKeys) {
    if (key.toLowerCase() === 'content-type') {
      contentType = headers[key];
    }
  }

  let bodyText: string | undefined = undefined;
  if (method === 'POST' && contentType.length === 0) {
    if (options.form !== undefined) {
      contentType = 'application/x-www-form-urlencoded';
      bodyText = encodeForm(options.form);
    } else if (options.formData !== undefined) {
      const boundary: string = `----lxboundary${Date.now().toString(16)}`;
      contentType = `multipart/form-data; boundary=${boundary}`;
      bodyText = encodeMultipart(options.formData, boundary);
    } else {
      contentType = 'application/json';
      if (options.body !== undefined) {
        bodyText = stringifyBody(options.body);
      }
    }
  } else if (contentType.toLowerCase() === 'application/json' && options.body !== undefined) {
    bodyText = JSON.stringify(options.body);
  } else if (options.body !== undefined) {
    bodyText = stringifyBody(options.body);
  }
  if (contentType.length > 0) {
    headers['Content-Type'] = contentType;
  }

  const requestOptions: http.HttpRequestOptions = {
    method: toHttpMethod(method),
    header: headers,
    expectDataType: options.binary === true ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING,
    connectTimeout: timeout,
    readTimeout: timeout,
  };
  if (bodyText !== undefined && method !== 'GET' && method !== 'HEAD') {
    requestOptions.extraData = bodyText;
  }
  if (options.maxRedirects !== undefined) {
    requestOptions.maxRedirects = options.maxRedirects;
  }

  httpRequest.request(url, requestOptions)
    .then((resp: http.HttpResponse) => {
      if (destroyed) {
        return;
      }
      const statusCode: number = resp.responseCode;
      const elapsed: number = Date.now() - startMs;
      AppLog.info(TAG, `请求成功 ${url} HTTP ${statusCode} 耗时=${elapsed}ms`);
      let body: string | Object | number[];
      if (options.binary === true) {
        const raw: string | Object | ArrayBuffer = resp.result;
        body = (raw instanceof ArrayBuffer) ? arrayBufferToBytes(raw) : [];
      } else {
        const raw: string | Object | ArrayBuffer = resp.result;
        const text: string = typeof raw === 'string' ? raw as string : JSON.stringify(raw);
        if (options.rawText === true) {
          body = text;
        } else {
          try {
            const parsed: Object = JSON.parse(text) as Object;
            body = (parsed !== null && typeof parsed === 'object') ? parsed : text;
          } catch (e) {
            body = text;
          }
        }
      }
      onSuccess({
        statusCode: statusCode,
        statusMessage: '',
        headers: toHeaderRecord(resp.header),
        body: body,
        url: url,
        ok: statusCode >= 200 && statusCode < 300,
      });
    })
    .catch((err: BusinessError) => {
      if (destroyed) {
        return;
      }
      const elapsed: number = Date.now() - startMs;
      const errCode: string = err.code !== undefined ? `${err.code}` : '?';
      // UA 显示实际值（截断前 100 字符），便于与安卓端/curl 对比请求指纹
      const uaInfo: string = (headers['User-Agent'] !== undefined ? headers['User-Agent'] : '').substring(0, 100);
      // 诊断日志进 AppLog（关于页可见）：URL/域名/错误码/原始信息/耗时/UA/超时，
      // 用户真机复现后可直接复制反馈；DNS 解析对端 IP 由系统栈负责，日志以 host 为准
      AppLog.error(TAG,
        `请求失败 url=${url} host=${host} code=${errCode} msg=${err.message} 耗时=${elapsed}ms UA=${uaInfo} timeout=${timeout}ms`);
      hilog.error(DOMAIN, TAG, 'request failed: %{public}s %{public}s code=%{public}s elapsed=%{public}dms',
        url, err.message, errCode, elapsed);
      // HTTP(S) 请求失败时追加 TCP 分层诊断：区分 DNS / TCP / TLS 层
      const colonIdx: number = url.indexOf(':');
      const scheme: string = colonIdx >= 0 ? url.substring(0, colonIdx).toLowerCase() : '';
      if (scheme === 'https' || scheme === 'http') {
        let diagPort: number = scheme === 'https' ? 443 : 80;
        const hostColon: number = host.lastIndexOf(':');
        if (hostColon >= 0) {
          const tail: string = host.substring(hostColon + 1);
          const parsedPort: number = parseInt(tail, 10);
          if (!isNaN(parsedPort) && parsedPort > 0 && parsedPort <= 65535) {
            diagPort = parsedPort;
          }
        }
        tcpDiag(host, diagPort);
      }
      onError(err.message);
    });

  return {
    abort: () => {
      destroyed = true;
      httpRequest.destroy();
    },
  };
}
