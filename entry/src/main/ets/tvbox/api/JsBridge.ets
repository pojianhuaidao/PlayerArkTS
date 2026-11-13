/**
 * JS Bridge - native function bridge for WebView JS engine
 * 提供 JS 侧可调用的原生桥接方法
 * Exposes: http, joinUrl, pd, pdfh, pdfa, pdfla, aesX, base64Encode/Decode, md5
 */
import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer } from '@kit.ArkTS';
import { rightPadding, bytesToHex, base64Decode, base64Encode } from '../util/AESUtil';

export interface HttpResult {
  content: string;
  headers: Record<string, string>;
  ok: boolean;
  status: number;
  url: string;
}

let httpRequestId: number = 0;
const httpResults: Map<number, HttpResult> = new Map();

/** Async HTTP - returns reqId, JS polls getHttpResult */
export function nativeHttpAsync(url: string, optionsJson: string): number {
  const reqId = ++httpRequestId;
    console.info('[JsBridge] nativeHttpAsync reqId=' + reqId + ' url=' + url);
  const result: HttpResult = { content: '', headers: {}, ok: false, status: 0, url: url };
  try {
    const options: Record<string, Object> = optionsJson.length > 0
      ? JSON.parse(optionsJson) as Record<string, Object>
      : {} as Record<string, Object>;
    const method: string = options['method'] !== undefined ? String(options['method']) : 'get';
    const headersObj: Object | undefined = options['headers'];
    const headers: Record<string, string> = {};
    if (headersObj !== undefined && headersObj !== null) {
      const hdrRecord = headersObj as Record<string, Object>;
      for (const k of Object.keys(hdrRecord)) { headers[k] = String(hdrRecord[k]); }
    }
    const body: string = options['body'] !== undefined ? String(options['body']) : '';
    const dataObj: Object | undefined = options['data'];
    const postType: string = options['postType'] !== undefined ? String(options['postType']) : 'json';
    let requestBody: string = body;
    if (dataObj !== undefined && dataObj !== null) {
      if (postType === 'form') {
        const dataRecord = dataObj as Record<string, Object>;
        const parts: string[] = [];
        for (const k of Object.keys(dataRecord)) {
          parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(dataRecord[k])));
        }
        requestBody = parts.join('&');
        headers['Content-Type'] = 'application/x-www-form-urlencoded';
      } else {
        requestBody = JSON.stringify(dataObj);
        if (headers['Content-Type'] === undefined) headers['Content-Type'] = 'application/json';
      }
    }
    const httpRequest = http.createHttp();
    const headerObj: Record<string, string> = { 'User-Agent': 'okhttp/3.15', 'Accept': '*/*', 'Connection': 'keep-alive' };
    for (const k of Object.keys(headers)) { headerObj[k] = headers[k]; }
    const reqMethod: http.RequestMethod = method.toLowerCase() === 'post' ? http.RequestMethod.POST
      : (method.toLowerCase() === 'head' ? http.RequestMethod.HEAD : http.RequestMethod.GET);
    const timeout: number = options['timeout'] !== undefined
      ? Math.max(5000, Math.min(30000, parseInt(String(options['timeout'])))) : 10000;
    const opts: http.HttpRequestOptions = {
      method: reqMethod, header: headerObj,
      extraData: requestBody.length > 0 ? requestBody : undefined,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: timeout, readTimeout: timeout, usingCache: false, priority: 0
    };
    httpRequest.request(url, opts).then((response) => {
      httpRequest.destroy();
      result.ok = response.responseCode === 200 || response.responseCode === 206;
      result.status = response.responseCode;
      result.content = response.result as string;
      console.info('[JsBridge] HTTP response reqId=' + reqId + ' status=' + response.responseCode + ' contentLen=' + (result.content ? result.content.length : 0));
      const respHeaders = response.header;
      if (respHeaders) {
        const hdrRecord = respHeaders as Record<string, Object>;
        for (const k of Object.keys(hdrRecord)) { result.headers[k] = String(hdrRecord[k]); }
      }
      httpResults.set(reqId, result);
    }).catch((err: Object) => {
      httpRequest.destroy();
      result.ok = false; result.status = 500; result.content = String(err);
      console.error('[JsBridge] HTTP error reqId=' + reqId + ' url=' + url + ' err=' + String(err));
      httpResults.set(reqId, result);
    });
  } catch (e) {
    result.ok = false; result.status = 500; result.content = String(e);
    httpResults.set(reqId, result);
  }
  return reqId;
}

export function isHttpDone(reqId: number): boolean {
  const done = httpResults.has(reqId);
  if (done) { console.info('[JsBridge] isHttpDone reqId=' + reqId + ' = true'); }
  return done;
}

export function getHttpResult(reqId: number): string {
  const result = httpResults.get(reqId);
  if (!result) {
    const pending: HttpResult = { content: '', headers: {}, ok: false, status: 0, url: '' };
    return JSON.stringify(pending);
  }
  httpResults.delete(reqId);
  return JSON.stringify(result);
}

export function nativeJoinUrl(parent: string, child: string): string {
  if (parent.length === 0) return child;
  if (child.startsWith('http://') || child.startsWith('https://') || child.startsWith('//')) {
    if (child.startsWith('//')) {
      const proto = parent.substring(0, parent.indexOf('://') + 3);
      return proto + child.substring(2);
    }
    return child;
  }
  try {
    let base = parent;
    const hashIdx = base.indexOf('#');
    if (hashIdx >= 0) base = base.substring(0, hashIdx);
    const protoIdx = base.indexOf('://');
    if (protoIdx < 0) return child;
    const proto = base.substring(0, protoIdx + 3);
    const afterProto = base.substring(protoIdx + 3);
    const slashIdx = afterProto.indexOf('/');
    let host: string;
    let path: string;
    if (slashIdx < 0) {
      host = afterProto;
      path = '';
    } else {
      host = afterProto.substring(0, slashIdx);
      path = afterProto.substring(slashIdx);
    }
    if (child.startsWith('/')) {
      return proto + host + child;
    }
    if (child.startsWith('?')) {
      const qIdx = path.indexOf('?');
      const cleanPath = qIdx >= 0 ? path.substring(0, qIdx) : path;
      return proto + host + cleanPath + child;
    }
    if (child.startsWith('#')) {
      return proto + host + path + child;
    }
    const lastSlash = path.lastIndexOf('/');
    const dirPath = lastSlash >= 0 ? path.substring(0, lastSlash + 1) : '/';
    return proto + host + dirPath + child;
  } catch (_e) {
    return child;
  }
}

export function nativePdfh(html: string, rule: string): string {
  return parseDomSingle(html, rule, '');
}

export function nativePd(html: string, rule: string, addUrl: string): string {
  return parseDomSingle(html, rule, addUrl);
}

export function nativePdfa(html: string, rule: string): string {
  return JSON.stringify(parseDomArray(html, rule));
}

export function nativePdfla(html: string, p1: string, listText: string, listUrl: string, addUrl: string): string {
  return JSON.stringify(parseDomList(html, p1, listText, listUrl, addUrl));
}

export function nativeBase64Encode(input: string): string {
  const bytes = new Uint8Array(buffer.from(input, 'utf-8').buffer);
  return base64Encode(bytes);
}

export function nativeBase64Decode(input: string): string {
  const bytes = base64Decode(input);
  return buffer.from(bytes).toString('utf-8');
}

export function nativeMd5(input: string): string {
  const md5Gen = cryptoFramework.createMd('MD5');
  md5Gen.updateSync({ data: new Uint8Array(buffer.from(input, 'utf-8').buffer) });
  const result = md5Gen.digestSync();
  return bytesToHex(result.data);
}

const URLJOIN_ATTR = /(url|src|href|-original|-src|-play|-url|style)$/i;
const SPECIAL_URL = /^(ftp|magnet|thunder|ws):/i;

function parseDomSingle(html: string, rule: string, addUrl: string): string {
  if (rule.length === 0) return '';
  const parts = rule.split('||');
  for (let pi = 0; pi < parts.length; pi++) {
    const part = parts[pi].trim();
    if (part.length === 0) continue;
    const result = extractByRule(html, part);
    if (result.length > 0) {
      if (addUrl.length > 0) {
        const attrName = getAttrName(part);
        if (URLJOIN_ATTR.test(attrName)) return nativeJoinUrl(addUrl, result);
      }
      return result;
    }
  }
  return '';
}

function getAttrName(rule: string): string {
  const atIdx = rule.lastIndexOf('@');
  if (atIdx >= 0) return rule.substring(atIdx + 1);
  return '';
}

function extractByRule(html: string, rule: string): string {
  const atIdx = rule.lastIndexOf('@');
  let selector: string;
  let attr: string;
  if (atIdx >= 0) { selector = rule.substring(0, atIdx); attr = rule.substring(atIdx + 1); }
  else { selector = rule; attr = 'text'; }
  let eqIndex = -1;
  const eqMatch = /:eq\((\d+)\)/.exec(selector);
  if (eqMatch) { eqIndex = parseInt(eqMatch[1]); selector = selector.replace(/:eq\(\d+\)/, ''); }
  const firstMatch = /:first/.exec(selector);
  if (firstMatch) { eqIndex = 0; selector = selector.replace(/:first/, ''); }
  const lastMatch = /:last/.exec(selector);
  if (lastMatch) { eqIndex = -2; selector = selector.replace(/:last/, ''); }
  const elements = selectElements(html, selector);
  if (elements.length === 0) return '';
  let targetIdx = eqIndex >= 0 ? eqIndex : (eqIndex === -2 ? elements.length - 1 : 0);
  if (targetIdx >= elements.length) targetIdx = elements.length - 1;
  if (targetIdx < 0) targetIdx = 0;
  const element = elements[targetIdx];
  if (attr === 'text' || attr === 'innerText' || attr === 'textContent') return extractText(element);
  if (attr === 'html' || attr === 'innerHTML') return extractInnerHtml(element);
  if (attr === 'outerHTML') return element;
  return getAttrValue(element, attr);
}

function parseDomArray(html: string, rule: string): string[] {
  if (rule.length === 0) return [];
  const selector = rule.split('@')[0];
  return selectElements(html, selector);
}

function parseDomList(html: string, p1: string, listText: string, listUrl: string, addUrl: string): Array<Record<string, string>> {
  const elements = selectElements(html, p1);
  const result: Array<Record<string, string>> = [];
  for (let i = 0; i < elements.length; i++) {
    const el = elements[i];
    const text = extractByRule(el, listText);
    let url = extractByRule(el, listUrl);
    if (addUrl.length > 0 && url.length > 0 && !SPECIAL_URL.test(url)) url = nativeJoinUrl(addUrl, url);
    const item: Record<string, string> = {} as Record<string, string>;
    item['title'] = text;
    item['url'] = url;
    result.push(item);
  }
  return result;
}

export function nativeAesX(mode: string, encrypt: boolean, input: string, inBase64: boolean,
  key: string, iv: string, outBase64: boolean): string {
  console.info('[JsBridge] aesX mode=' + mode + ' encrypt=' + encrypt + ' inputLen=' + input.length + ' inBase64=' + inBase64 + ' keyLen=' + key.length + ' ivLen=' + iv.length);
  try {
    let paddedKey = key.length >= 16 ? key.substring(0, 16) : key + '\0'.repeat(16 - key.length);
    const keyBytes = new Uint8Array(buffer.from(paddedKey, 'utf-8').buffer);
    const modeParts = mode.toUpperCase().split('/');
    const cipherMode = modeParts[1] === 'ECB' ? 'AES128|ECB|PKCS7' : 'AES128|CBC|PKCS7';
    const cipher = cryptoFramework.createCipher(cipherMode);
    const symKeyGen = cryptoFramework.createSymKeyGenerator('AES128');
    const keyBlob: cryptoFramework.DataBlob = { data: keyBytes };
    const symKey = symKeyGen.convertKeySync(keyBlob);
    let inputBytes: Uint8Array;
    if (inBase64) {
      const cleaned = input.replace(/_/g, '/').replace(/-/g, '+');
      inputBytes = base64Decode(cleaned);
    } else {
      inputBytes = new Uint8Array(buffer.from(input, 'utf-8').buffer);
    }
    if (encrypt) {
      if (modeParts[1] === 'ECB') {
        cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, null);
      } else {
        let paddedIv = iv.length >= 16 ? iv.substring(0, 16) : iv + '\0'.repeat(16 - iv.length);
        const ivBytes = new Uint8Array(buffer.from(paddedIv, 'utf-8').buffer);
        const ivSpec: cryptoFramework.IvParamsSpec = { algName: 'IvParamsSpec', iv: { data: ivBytes } };
        cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, ivSpec);
      }
      const encResult = cipher.doFinalSync({ data: inputBytes });
      if (outBase64) return base64Encode(encResult.data);
      return buffer.from(encResult.data).toString('utf-8');
    } else {
      if (modeParts[1] === 'ECB') {
        cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, null);
      } else {
        let paddedIv = iv.length >= 16 ? iv.substring(0, 16) : iv + '\0'.repeat(16 - iv.length);
        const ivBytes = new Uint8Array(buffer.from(paddedIv, 'utf-8').buffer);
        const ivSpec: cryptoFramework.IvParamsSpec = { algName: 'IvParamsSpec', iv: { data: ivBytes } };
        cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, ivSpec);
      }
      const decResult = cipher.doFinalSync({ data: inputBytes });
      console.info('[JsBridge] aesX decrypt resultLen=' + decResult.data.length);
      if (outBase64) return base64Encode(decResult.data);
      return buffer.from(decResult.data).toString('utf-8');
    }
  } catch (_e) {
    console.error('[JsBridge] aesX error: ' + String(_e));
    return '';
  }
}

function selectElements(html: string, selector: string): string[] {
  const results: string[] = [];
  const sel = selector.trim();
  if (sel.length === 0) return results;
  const parts = sel.split(/\s+/);
  let currentHtml = html;
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    const matches = findElements(currentHtml, part);
    if (i === parts.length - 1) { results.push(...matches); }
    else { currentHtml = matches.join(''); }
  }
  return results;
}

function findElements(html: string, selector: string): string[] {
  const results: string[] = [];
  let tag = '';
  let className = '';
  let id = '';
  const idMatch = /#([\w-]+)/.exec(selector);
  if (idMatch) id = idMatch[1];
  const classMatch = /\.([\w-]+)/.exec(selector);
  if (classMatch) className = classMatch[1];
  const tagMatch = /^([\w]+)/.exec(selector);
  if (tagMatch) tag = tagMatch[1].toLowerCase();
  if (tag.length === 0 && className.length === 0 && id.length === 0) return results;
  const allTags = ['div','span','a','p','img','li','ul','ol','table','tr','td','th','tbody','thead',
    'h1','h2','h3','h4','h5','h6','section','article','header','footer','nav','aside','figure',
    'figcaption','video','source','input','button','form','label','select','option','textarea',
    'iframe','dl','dt','dd','em','strong','small','mark','time','address'];
  if (tag.length === 0) {
    for (const t of allTags) { const found = findTagElements(html, t, className, id); results.push(...found); }
  } else {
    const found = findTagElements(html, tag, className, id); results.push(...found);
  }
  return results;
}

function findTagElements(html: string, tag: string, className: string, id: string): string[] {
  const results: string[] = [];
  const selfClosing = tag === 'img' || tag === 'input' || tag === 'br' || tag === 'hr'
    || tag === 'meta' || tag === 'link' || tag === 'source';
  const openTagRegex = new RegExp('<' + tag + '(\\s[^>]*)?>', 'gi');
  const closeTag = '</' + tag + '>';
  let match: RegExpExecArray | null;
  while ((match = openTagRegex.exec(html)) !== null) {
    const openTagStr = match[0];
    const attrs = match[1] || '';
    if (className.length > 0) {
      const clsMatch = new RegExp('class\\s*=\\s*["\'][^"\']*\\b' + className + '\\b[^"\']*["\']', 'i').exec(attrs);
      if (!clsMatch) continue;
    }
    if (id.length > 0) {
      const idMatch2 = new RegExp('id\\s*=\\s*["\']' + id + '["\']', 'i').exec(attrs);
      if (!idMatch2) continue;
    }
    if (selfClosing) { results.push(openTagStr); continue; }
    const startIdx = match.index + openTagStr.length;
    let depth = 1;
    let idx = startIdx;
    while (depth > 0 && idx < html.length) {
      const nextOpen = html.indexOf('<' + tag, idx);
      const nextClose = html.indexOf(closeTag, idx);
      if (nextClose < 0) break;
      if (nextOpen >= 0 && nextOpen < nextClose) { depth++; idx = nextOpen + 1; }
      else { depth--; idx = nextClose + closeTag.length; }
    }
    const fullElement = html.substring(match.index, idx);
    results.push(fullElement);
  }
  return results;
}

function extractText(element: string): string {
  return element.replace(/<[^>]+>/g, '').trim();
}

function extractInnerHtml(element: string): string {
  const firstGt = element.indexOf('>');
  const lastLt = element.lastIndexOf('</');
  if (firstGt >= 0 && lastLt > firstGt) return element.substring(firstGt + 1, lastLt);
  return '';
}

function getAttrValue(element: string, attr: string): string {
  const attrRegex = new RegExp(attr + '\\s*=\\s*["\']([^"\']*)["\']', 'i');
  const match = attrRegex.exec(element);
  if (match) return match[1];
  return '';
}

