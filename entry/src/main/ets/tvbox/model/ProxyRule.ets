/**
 * 代理规则
 */
export interface ProxyRule {
  host: string;   // 匹配的域名
  proxy: string;  // 代理地址
}

export function parseProxyRules(arr: Object[] | null): ProxyRule[] {
  const rules: ProxyRule[] = [];
  if (arr === null || !Array.isArray(arr)) return rules;
  for (const item of arr) {
    const obj = item as Record<string, Object>;
    const host = obj['host'] !== undefined ? String(obj['host']) : '';
    const proxy = obj['proxy'] !== undefined ? String(obj['proxy']) : '';
    if (host.length > 0) {
      rules.push({ host: host, proxy: proxy });
    }
  }
  return rules;
}
