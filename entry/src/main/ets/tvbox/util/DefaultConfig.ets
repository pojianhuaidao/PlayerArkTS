/**
 * 配置工具
 * 提供 JSON 安全读取方法
 */

/** 安全读取 JSON 字符串字段 */
export function safeJsonString(obj: Record<string, Object>, key: string, defaultVal: string): string {
  try {
    const val = obj[key];
    if (val === undefined || val === null) return defaultVal;
    if (typeof val === 'object') return JSON.stringify(val);
    return String(val).trim();
  } catch (_e) {
    return defaultVal;
  }
}

/** 安全读取 JSON 整数字段 */
export function safeJsonInt(obj: Record<string, Object>, key: string, defaultVal: number): number {
  try {
    const val = obj[key];
    if (val === undefined || val === null) return defaultVal;
    return Number(val);
  } catch (_e) {
    return defaultVal;
  }
}

/** 安全读取 JSON 布尔字段 */
export function safeJsonBool(obj: Record<string, Object>, key: string, defaultVal: boolean): boolean {
  try {
    const val = obj[key];
    if (val === undefined || val === null) return defaultVal;
    return Boolean(val);
  } catch (_e) {
    return defaultVal;
  }
}

/** 安全读取 JSON 字符串数组字段 */
export function safeJsonStringList(obj: Record<string, Object>, key: string): string[] {
  const result: string[] = [];
  try {
    const val = obj[key];
    if (val === undefined || val === null) return result;
    if (Array.isArray(val)) {
      for (const item of val as Object[]) {
        result.push(String(item));
      }
    } else {
      result.push(String(val));
    }
  } catch (_e) {
  }
  return result;
}

/** 从 JSON 对象中获取嵌套对象 */
export function safeJsonObject(obj: Record<string, Object>, key: string): Record<string, Object> | null {
  try {
    const val = obj[key];
    if (val !== undefined && val !== null && typeof val === 'object') {
      return val as Record<string, Object>;
    }
  } catch (_e) {
  }
  return null;
}

/** 从 JSON 对象中获取数组 */
export function safeJsonArray(obj: Record<string, Object>, key: string): Object[] | null {
  try {
    const val = obj[key];
    if (val !== undefined && val !== null && Array.isArray(val)) {
      return val as Object[];
    }
  } catch (_e) {
  }
  return null;
}

/** 提取 JSON 内容 (从第一个 { 到最后一个 }) */
export function trimJsonObject(content: string): string {
  const start = content.indexOf('{');
  const end = content.lastIndexOf('}');
  if (start >= 0 && end > start) {
    return content.substring(start, end + 1);
  }
  return content;
}

/** 修复相对路径 (./ 和 ../) */
export function fixContentPath(url: string, content: string): string {
  if (content.includes('"./') || content.includes('"../')) {
    let baseUrl = url;
    if (!baseUrl.startsWith('http') && !baseUrl.startsWith('clan://')) {
      baseUrl = 'http://' + baseUrl;
    }
    const base = baseUrl.substring(0, baseUrl.lastIndexOf('/') + 1);
    const parentBase = base.endsWith('/')
      ? base.substring(0, base.length - 1)
      : base;
    const parentEnd = parentBase.lastIndexOf('/');
    const parent = parentEnd >= 0 ? parentBase.substring(0, parentEnd + 1) : parentBase;
    content = content.replace(/\.\.\//g, parent);
    content = content.replace(/\.\//g, base);
  }
  return content;
}

/** 判断是否为 VIP 视频 URL */
export function isVipUrl(url: string): boolean {
  const hosts = ['iqiyi.com', 'v.qq.com', 'youku.com', 'le.com', 'tudou.com',
    'mgtv.com', 'sohu.com', 'acfun.cn', 'bilibili.com', 'baofeng.com', 'pptv.com'];
  for (const host of hosts) {
    if (url.includes(host)) return true;
  }
  return false;
}

/** 判断是否为视频格式 URL */
export function isVideoFormat(url: string): boolean {
  if (url.includes('url=http') || url.includes('.js') || url.includes('.css') || url.includes('.html')) {
    return false;
  }
  const rule = /http((?!http).){12,}?\.(m3u8|mp4|flv|avi|mkv|rm|wmv|mpg|m4a|mp3)\?.*|http((?!http).){12,}\.(m3u8|mp4|flv|avi|mkv|rm|wmv|mpg|m4a|mp3)|http((?!http).)*?video\/tos*/;
  return rule.test(url);
}

/** 无广告关键词判断 */
const NO_AD_KEYWORDS = ['tx', 'youku', 'qq', 'qiyi', 'letv', 'leshi', 'sohu', 'mgtv', 'bilibili', 'imgo'];
export function noAd(flag: string): boolean {
  if (!flag || flag.length === 0) return false;
  for (const keyword of NO_AD_KEYWORDS) {
    if (flag === keyword || flag.includes(keyword)) return true;
  }
  return false;
}
