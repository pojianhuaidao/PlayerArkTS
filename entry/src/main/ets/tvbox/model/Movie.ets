import { MovieSort } from './MovieSort';
/**
 * 视频数据模型
 */

/** 列表中的视频简略信息 */
export interface VodItem {
  id: string;
  tid: number;
  name: string;
  type: string;
  pic: string;
  lang: string;
  area: string;
  year: number;
  state: string;
  note: string;
  actor: string;
  director: string;
  des: string;
  sourceKey: string;
  tag: string;
  action: string;
  last: string;
}

/** 分页列表结果 */
export interface AbsXml {
  page: number;
  pagecount: number;
  pagesize: number;
  recordcount: number;
  videoList: VodItem[];
  sourceKey: string;
}

export function emptyAbsXml(): AbsXml {
  return { page: 1, pagecount: 0, pagesize: 0, recordcount: 0, videoList: [], sourceKey: '' };
}

/** 剧集信息 */
export interface VodSeries {
  name: string;
  url: string;
  selected: boolean;
}

/** 播放线路 (flag) */
export interface VodSeriesFlag {
  name: string;
  selected: boolean;
}

/** parsePlayUrl 返回结果 */
export interface PlayUrlResult {
  flags: VodSeriesFlag[];
  seriesMap: Map<string, VodSeries[]>;
}

/** 视频详情 (含剧集) - 对应 VodInfo.java */
export interface VodInfo {
  last: string;
  id: string;
  tid: number;
  name: string;
  type: string;
  dt: string;
  pic: string;
  lang: string;
  area: string;
  year: number;
  state: string;
  note: string;
  actor: string;
  director: string;
  des: string;
  seriesFlags: VodSeriesFlag[];
  seriesMap: Map<string, VodSeries[]>;
  playFlag: string;
  playIndex: number;
  playNote: string;
  sourceKey: string;
  playerCfg: string;
  reverseSort: boolean;
}

export function createVodInfo(item: VodItem): VodInfo {
  return {
    last: item.last, id: item.id, tid: item.tid,
    name: item.name, type: item.type, dt: '',
    pic: item.pic, lang: item.lang, area: item.area,
    year: item.year, state: item.state, note: item.note,
    actor: item.actor, director: item.director, des: item.des,
    seriesFlags: [], seriesMap: new Map(),
    playFlag: '', playIndex: 0, playNote: '',
    sourceKey: item.sourceKey, playerCfg: '',
    reverseSort: false
  };
}

/** 搜索结果项 */
export interface SearchResult {
  vodList: VodItem[];
  sourceKey: string;
}

/** 播放信息 */
export interface PlayInfo {
  url: string;
  header: Map<string, string>;
  parse: number;
  jx: number;
}

/** 首页聚合结果 */
export class HomeResult {
  sort: MovieSort;
  list: AbsXml;

  constructor(sort: MovieSort, list: AbsXml) {
    this.sort = sort;
    this.list = list;
  }
}

/**
 * 从 VodInfo 填充剧集信息 - 对应 VodInfo.setVideo 逻辑
 * 解析 playFrom$$$playUrl 格式
 */
export function parsePlayUrl(playFrom: string, playUrl: string): PlayUrlResult {
  const flags: VodSeriesFlag[] = [];
  const seriesMap = new Map<string, VodSeries[]>();

  if (playFrom.length > 0 && playUrl.length > 0) {
    const flagArr = playFrom.split('$$$');
    const urlGroups = playUrl.split('$$$');
    for (let i = 0; i < flagArr.length; i++) {
      const flagName = flagArr[i];
      const urlGroup = i < urlGroups.length ? urlGroups[i] : '';
      const series: VodSeries[] = [];
      const episodes = urlGroup.split('#');
      for (const ep of episodes) {
        const parts = ep.split('$');
        if (parts.length >= 2) {
          series.push({ name: parts[0].trim(), url: parts[1].trim(), selected: false });
        } else if (parts.length === 1 && parts[0].trim().length > 0) {
          series.push({ name: String(series.length + 1), url: parts[0].trim(), selected: false });
        }
      }
      if (series.length > 0) {
        flags.push({ name: flagName, selected: false });
        seriesMap.set(flagName, series);
      }
    }
  }
  return { flags, seriesMap };
}
