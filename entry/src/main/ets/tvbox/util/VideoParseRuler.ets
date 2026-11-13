/**
 * 视频解析规则
 * 管理按域名匹配的解析规则、过滤器、正则提取
 */
import { httpGet } from '../utils/HttpUtil';
import { isVideoFormat, isVipUrl } from '../util/DefaultConfig';

/** 单个解析规则 */
export interface ParseRule {
  host: string;
  rules: string[];
  redirectUrl: string;
}

/** 解析结果 */
export interface SniffResult {
  url: string;
  headers: Map<string, string>;
  isVideo: boolean;
}

/** 视频格式检查的扩展后缀 */
const VIDEO_EXTS: string[] = [
  '.m3u8', '.mp4', '.flv', '.mkv', '.avi', '.mov', '.wmv', '.ts', '.rmvb', '.rm',
  '.webm', '.mpg', '.mpeg', '.m4v', '.f4v', '.3gp', '.asf'
];

/** 检查 URL 是否为视频格式 */
export function checkVideoFormat(url: string): boolean {
  if (url.length === 0) return false;
  const lower: string = url.toLowerCase().split('?')[0].split('#')[0];
  for (const ext of VIDEO_EXTS) {
    if (lower.endsWith(ext)) return true;
  }
  // 检查 URL 参数中的格式
  const lowerFull: string = url.toLowerCase();
  for (const ext of VIDEO_EXTS) {
    if (lowerFull.includes(ext + '?') || lowerFull.includes(ext + '&')) return true;
  }
  return false;
}

/** 从 HTML 内容中嗅探视频 URL */
export function sniffVideoUrl(html: string, baseUrl: string): string {
  if (html.length === 0) return '';

  // 策略 1: 查找 player_aaaa 变量 (常见 CMS)
  const playerMatch: RegExpMatchArray | null = html.match(/player_aaaa\s*=\s*(\{[^}]+\})/);
  if (playerMatch) {
    try {
      const playerObj: Record<string, Object> = JSON.parse(playerMatch[1]) as Record<string, Object>;
      const playUrl: string = playerObj['url'] !== undefined ? String(playerObj['url']) : '';
      if (playUrl.length > 0 && checkVideoFormat(playUrl)) return resolveUrl(baseUrl, playUrl);
    } catch (_e) {}
  }

  // 策略 2: 查找 m3u8/mp4 直接链接
  const patterns: RegExp[] = [
    /https?:\/\/[^"'\s<>]+\.m3u8[^"'\s<>]*/gi,
    /https?:\/\/[^"'\s<>]+\.mp4[^"'\s<>]*/gi,
    /https?:\/\/[^"'\s<>]+\.flv[^"'\s<>]*/gi,
    /https?:\/\/[^"'\s<>]+\.mkv[^"'\s<>]*/gi
  ];

  for (const pattern of patterns) {
    const matches: RegExpMatchArray | null = html.match(pattern);
    if (matches && matches.length > 0) {
      return resolveUrl(baseUrl, matches[0]);
    }
  }

  // 策略 3: 查找 src 属性中的视频
  const srcMatch: RegExpMatchArray | null = html.match(/src\s*=\s*["']([^"']+)["']/i);
  if (srcMatch && srcMatch[1]) {
    const srcUrl: string = srcMatch[1];
    if (checkVideoFormat(srcUrl)) return resolveUrl(baseUrl, srcUrl);
  }

  // 策略 4: 查找 data-url 或 data-src
  const dataMatch: RegExpMatchArray | null = html.match(/data-(?:url|src)\s*=\s*["']([^"']+)["']/i);
  if (dataMatch && dataMatch[1]) {
    const dataUrl: string = dataMatch[1];
    if (checkVideoFormat(dataUrl)) return resolveUrl(baseUrl, dataUrl);
  }

  return '';
}

/** 解析相对 URL 为绝对 URL */
function resolveUrl(baseUrl: string, url: string): string {
  if (url.startsWith('http://') || url.startsWith('https://')) return url;
  if (url.startsWith('//')) return 'https:' + url;
  if (url.startsWith('/')) {
    const idx: number = baseUrl.indexOf('://');
    if (idx < 0) return url;
    const rest: string = baseUrl.substring(idx + 3);
    const slash: number = rest.indexOf('/');
    const host: string = slash < 0 ? rest : rest.substring(0, slash);
    return baseUrl.substring(0, idx + 3) + host + url;
  }
  // 相对路径
  const lastSlash: number = baseUrl.lastIndexOf('/');
  if (lastSlash > 8) return baseUrl.substring(0, lastSlash + 1) + url;
  return baseUrl + '/' + url;
}

/** 解析规则管理器 - 对应 VideoParseRuler */
export class VideoParseRulerManager {
  private static rules: ParseRule[] = [];

  static setRules(rules: ParseRule[]): void {
    VideoParseRulerManager.rules = rules;
  }

  static getRulesForHost(host: string): ParseRule | null {
    for (const rule of VideoParseRulerManager.rules) {
      if (host.includes(rule.host)) return rule;
    }
    return null;
  }

  /** 检查 URL 是否需要解析 (是 VIP 或非视频格式) */
  static needParse(url: string): boolean {
    if (url.length === 0) return false;
    if (checkVideoFormat(url)) return false;
    return isVipUrl(url);
  }

  /** 使用解析接口解析视频 */
  static async parseWithApi(parseUrl: string, videoUrl: string): Promise<string> {
    if (parseUrl.length === 0) return videoUrl;
    let url: string = parseUrl;
    if (url.includes('{url}')) {
      url = url.replace('{url}', encodeURIComponent(videoUrl));
    } else if (url.includes('{v}')) {
      url = url.replace('{v}', encodeURIComponent(videoUrl));
    } else {
      url = url + encodeURIComponent(videoUrl);
    }
    try {
      const body: string = await httpGet(url, undefined, { ttlMs: 0 });
      // 尝试从 JSON 中提取 URL
      const trimmed: string = body.trim();
      if (trimmed.startsWith('{')) {
        try {
          const obj: Record<string, Object> = JSON.parse(trimmed) as Record<string, Object>;
          const keys: string[] = ['url', 'data', 'playUrl', 'source'];
          for (const k of keys) {
            if (obj[k] !== undefined) {
              const val: string = String(obj[k]);
              if (val.startsWith('http')) return val;
            }
          }
        } catch (_e) {}
      } else if (trimmed.startsWith('http')) {
        return trimmed;
      }
    } catch (_e) {}
    return videoUrl;
  }

  /** 综合解析: 先检查是否需解析, 再嗅探或使用解析接口 */
  static async resolveVideoUrl(url: string, parseUrl: string, headers: Map<string, string>): Promise<SniffResult> {
    const result: SniffResult = { url: url, headers: headers, isVideo: false };

    // 如果已是视频格式, 直接返回
    if (checkVideoFormat(url)) {
      result.isVideo = true;
      return result;
    }

    // 如果需要解析
    if (VideoParseRulerManager.needParse(url)) {
      // 尝试使用解析接口
      if (parseUrl.length > 0) {
        const parsed: string = await VideoParseRulerManager.parseWithApi(parseUrl, url);
        if (checkVideoFormat(parsed)) {
          result.url = parsed;
          result.isVideo = true;
          return result;
        }
      }

      // 尝试嗅探页面
      try {
        const html: string = await httpGet(url, headers, { ttlMs: 0 });
        const sniffed: string = sniffVideoUrl(html, url);
        if (sniffed.length > 0) {
          result.url = sniffed;
          result.isVideo = true;
          return result;
        }
      } catch (_e) {}
    }

    result.url = url;
    result.isVideo = checkVideoFormat(url);
    return result;
  }


  /** 自动解析：按顺序尝试多个解析接口，直到有一个返回可播放地址 */
  static async resolveVideoUrlAuto(url: string, parseUrls: string[], headers: Map<string, string>): Promise<SniffResult> {
    const result: SniffResult = { url: url, headers: headers, isVideo: false };
    if (checkVideoFormat(url)) {
      result.isVideo = true;
      return result;
    }
    // 依次尝试每个解析接口（单个 5s 超时，失败即跳过下一个）
    const perParseTimeoutMs: number = 5000;
    for (const parseUrl of parseUrls) {
      if (!parseUrl || parseUrl.length === 0) continue;
      try {
        const parsePromise: Promise<string> = VideoParseRulerManager.parseWithApi(parseUrl, url);
        const timeoutPromise: Promise<string> = new Promise<string>((_resolve, reject) => {
          setTimeout((): void => { reject(new Error('parse-timeout')); }, perParseTimeoutMs);
        });
        const parsed: string = await Promise.race([parsePromise, timeoutPromise]);
        if (checkVideoFormat(parsed)) {
          result.url = parsed;
          result.isVideo = true;
          return result;
        }
      } catch (_e) {}
    }
    // 最后尝试嗅探页面
    if (VideoParseRulerManager.needParse(url)) {
      try {
        const html: string = await httpGet(url, headers, { ttlMs: 0 });
        const sniffed: string = sniffVideoUrl(html, url);
        if (sniffed.length > 0) {
          result.url = sniffed;
          result.isVideo = true;
          return result;
        }
      } catch (_e) {}
    }
    result.url = url;
    result.isVideo = checkVideoFormat(url);
    return result;
  }
}
