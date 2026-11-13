/**
 * M3U8 工具
 * 解析 M3U8 并过滤广告分片
 */
import { httpGet } from '../utils/HttpUtil';

/** M3U8 分片信息 */
export interface M3u8Segment {
  url: string;
  duration: number;
}

/** M3U8 解析结果 */
export interface M3u8Info {
  baseUrl: string;
  segments: M3u8Segment[];
  totalDuration: number;
  isMaster: boolean;
  variants: string[];
}

/** 解析 M3U8 内容 */
export function parseM3u8(content: string, baseUrl: string): M3u8Info {
  const info: M3u8Info = {
    baseUrl: baseUrl,
    segments: [],
    totalDuration: 0,
    isMaster: false,
    variants: []
  };

  const lines: string[] = content.split('\n');
  let currentDuration: number = 0;

  for (let i: number = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();

    if (line.startsWith('#EXT-X-STREAM-INF:')) {
      info.isMaster = true;
      // 下一行是子播放列表 URL
      if (i + 1 < lines.length) {
        const variantUrl: string = lines[i + 1].trim();
        if (variantUrl.length > 0 && !variantUrl.startsWith('#')) {
          info.variants.push(resolveM3u8Url(baseUrl, variantUrl));
        }
      }
    }

    if (line.startsWith('#EXTINF:')) {
      const parts: string[] = line.substring(8).split(',');
      currentDuration = parseFloat(parts[0]) || 0;
    }

    if (!line.startsWith('#') && line.length > 0) {
      const segUrl: string = resolveM3u8Url(baseUrl, line);
      info.segments.push({ url: segUrl, duration: currentDuration });
      info.totalDuration += currentDuration;
      currentDuration = 0;
    }
  }

  return info;
}

/** 解析 M3U8 URL 为绝对路径 */
function resolveM3u8Url(baseUrl: string, url: string): string {
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
  const lastSlash: number = baseUrl.lastIndexOf('/');
  if (lastSlash > 8) return baseUrl.substring(0, lastSlash + 1) + url;
  return baseUrl + '/' + url;
}

/** 获取 M3U8 内容并解析 */
export async function fetchM3u8(url: string): Promise<M3u8Info> {
  const content: string = await httpGet(url, undefined, { ttlMs: 0 });
  return parseM3u8(content, url);
}

/** 过滤广告分片 (根据时间间隔判断) */
export function filterAdSegments(info: M3u8Info, adThreshold: number = 3): M3u8Segment[] {
  return info.segments.filter((seg: M3u8Segment): boolean => {
    // 广告分片通常很短 (< 3 秒) 且不连续
    return seg.duration >= adThreshold || seg.duration === 0;
  });
}
