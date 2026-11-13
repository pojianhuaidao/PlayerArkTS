/**
 * 代理工具
 * 处理 proxy:// 协议、本地代理 URL 构建
 */
import { base64UrlSafeEncode, base64UrlSafeDecode } from './AESUtil';
import { ProxyRule } from '../model/ProxyRule';

const PROXY_PREFIX: string = 'proxy://';
const LOCAL_PROXY_BASE: string = 'http://127.0.0.1:9978/proxy?do=';

/** 检查 URL 是否为 proxy:// 协议 */
export function isProxyUrl(url: string): boolean {
  return url.startsWith(PROXY_PREFIX);
}

/** 解析 proxy:// URL, 返回真实的请求参数 */
export function parseProxyUrl(proxyUrl: string): Record<string, string> {
  const result: Record<string, string> = {};
  if (!isProxyUrl(proxyUrl)) return result;

  const queryStr: string = proxyUrl.substring(PROXY_PREFIX.length);
  const params: string[] = queryStr.split('&');
  for (const param of params) {
    const eqIdx: number = param.indexOf('=');
    if (eqIdx > 0) {
      const key: string = param.substring(0, eqIdx);
      const value: string = param.substring(eqIdx + 1);
      result[key] = value;
    }
  }
  return result;
}

/** 构建本地代理 URL (用于直播源) */
export function buildLiveProxyUrl(liveUrl: string): string {
  if (liveUrl.startsWith('http://127.0.0.1')) return liveUrl;
  if (liveUrl.startsWith('http')) {
    const encoded: string = base64UrlSafeEncode(new TextEncoder().encode(liveUrl));
    return LOCAL_PROXY_BASE + 'live&type=txt&ext=' + encoded;
  }
  return liveUrl;
}

/** 根据代理规则匹配 URL */
export function matchProxyRule(url: string, rules: ProxyRule[]): ProxyRule | null {
  for (const rule of rules) {
    if (url.includes(rule.host)) return rule;
  }
  return null;
}

/** 应用代理规则到 URL */
export function applyProxyRules(url: string, rules: ProxyRule[]): string {
  const rule: ProxyRule | null = matchProxyRule(url, rules);
  if (rule !== null && rule.proxy.length > 0) {
    // 如果代理地址不为空, 通过代理访问
    const proxyUrl: string = rule.proxy;
    if (proxyUrl.startsWith('http')) {
      return proxyUrl + encodeURIComponent(url);
    }
  }
  return url;
}

/** 检查是否需要使用代理 */
export function needsProxy(url: string, rules: ProxyRule[]): boolean {
  return matchProxyRule(url, rules) !== null;
}
