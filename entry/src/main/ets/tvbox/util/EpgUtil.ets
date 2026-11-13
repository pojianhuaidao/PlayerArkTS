/**
 * EPG 电子节目单
 * 根据频道名称查找 EPG 信息并获取节目表
 */
import { httpGet } from '../utils/HttpUtil';
import { EpgInfo } from '../model/LiveChannel';

/** EPG 频道定义 */
interface EpgChannel {
  name: string;
  logo: string;
  epgId: string;
}

const EPG_API_BASE: string = 'https://epg.112114.xyz';

export class EpgUtil {
  private static channelMap: Map<string, EpgChannel> = new Map();
  private static epgCache: Map<string, EpgInfo[]> = new Map();

  /** 初始化 EPG 频道名称映射 */
  static initChannelMap(channels: EpgChannel[]): void {
    EpgUtil.channelMap.clear();
    for (const ch of channels) {
      const names: string[] = ch.name.split(',');
      for (const n of names) {
        EpgUtil.channelMap.set(n.trim().toLowerCase(), ch);
      }
    }
  }

  /** 根据频道名获取 EPG 信息 */
  static getChannelEpgInfo(channelName: string): EpgChannel | null {
    const key: string = channelName.trim().toLowerCase();
    if (EpgUtil.channelMap.has(key)) {
      return EpgUtil.channelMap.get(key) ?? null;
    }
    // 模糊匹配: 去掉常见后缀
    const cleanName: string = channelName
      .replace(/[高清]/g, '')
      .replace(/HD|hd|4K|8K/g, '')
      .trim()
      .toLowerCase();
    if (EpgUtil.channelMap.has(cleanName)) {
      return EpgUtil.channelMap.get(cleanName) ?? null;
    }
    // 包含匹配
    const keys: string[] = Array.from(EpgUtil.channelMap.keys());
    for (const k of keys) {
      if (k.includes(cleanName) || cleanName.includes(k)) {
        return EpgUtil.channelMap.get(k) ?? null;
      }
    }
    return null;
  }

  /** 获取频道当日节目表 */
  static async fetchEpg(epgId: string, date: string): Promise<EpgInfo[]> {
    const cacheKey: string = epgId + '_' + date;
    if (EpgUtil.epgCache.has(cacheKey)) {
      return EpgUtil.epgCache.get(cacheKey) ?? [];
    }

    const url: string = `${EPG_API_BASE}/${date}/${epgId}.json`;
    try {
      const body: string = await httpGet(url, undefined, { ttlMs: 0 });
      const epgList: EpgInfo[] = EpgUtil.parseEpgJson(body);
      EpgUtil.epgCache.set(cacheKey, epgList);
      return epgList;
    } catch (_e) {
      return [];
    }
  }

  /** 解析 EPG JSON */
  static parseEpgJson(body: string): EpgInfo[] {
    const result: EpgInfo[] = [];
    try {
      const obj: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
      const epgList: Object[] | undefined = obj['epg_data'] as Object[];
      if (epgList === undefined) return result;

      for (const item of epgList) {
        const epgObj: Record<string, Object> = item as Record<string, Object>;
        const startStr: string = epgObj['start'] !== undefined ? String(epgObj['start']) : '';
        const endStr: string = epgObj['end'] !== undefined ? String(epgObj['end']) : '';
        const title: string = epgObj['title'] !== undefined ? String(epgObj['title']) : '';
        if (title.length > 0) {
          result.push({
            title: title,
            start: EpgUtil.parseTimeStr(startStr),
            end: EpgUtil.parseTimeStr(endStr),
            startStr: startStr,
            endStr: endStr
          });
        }
      }
    } catch (_e) {}
    return result;
  }

  /** 将 "12:30" 转为当日毫秒数 */
  static parseTimeStr(timeStr: string): number {
    const parts: string[] = timeStr.split(':');
    if (parts.length < 2) return 0;
    const h: number = parseInt(parts[0], 10) || 0;
    const m: number = parseInt(parts[1], 10) || 0;
    return h * 3600000 + m * 60000;
  }

  /** 获取当前时间正在播出的节目 */
  static getCurrentProgram(epgList: EpgInfo[], currentTimeMs: number): EpgInfo | null {
    const now: number = currentTimeMs % 86400000;  // 当日时间
    for (const epg of epgList) {
      if (now >= epg.start && now < epg.end) {
        return epg;
      }
    }
    return null;
  }

  /** 获取今天的日期字符串 (YYYY-MM-DD) */
  static getTodayStr(): string {
    const d: Date = new Date();
    const year: number = d.getFullYear();
    const month: string = String(d.getMonth() + 1).padStart(2, '0');
    const day: string = String(d.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
  }
}
