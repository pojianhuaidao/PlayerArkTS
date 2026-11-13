/**
 * JSON 源解析器
 * 解析标准 CMS JSON API 响应 (type=1)
 */
import { AbsXml, VodItem, VodInfo, VodSeries, VodSeriesFlag, PlayInfo, emptyAbsXml, HomeResult } from '../model/Movie';
import { MovieSort, SortData, SortFilter, createSortData, createMovieSort } from '../model/MovieSort';

interface JsonClass {
  type_id: string | number;
  type_name: string;
  type_pid?: string | number;
  type_flag?: string;
}

interface JsonVod {
  vod_id?: string | number;
  vod_name?: string;
  vod_pic?: string;
  vod_remarks?: string;
  type_name?: string;
  vod_lang?: string;
  vod_area?: string;
  vod_year?: string | number;
  vod_actor?: string;
  vod_director?: string;
  vod_content?: string;
  vod_play_from?: string;
  vod_play_url?: string;
  vod_tag?: string;
}

interface FilterValue { n: string; v: string; }
interface JsonFilter {
  key: string;
  name: string;
  init: string;
  value: FilterValue[];
}

export function parseJsonHome(jsonStr: string): HomeResult {
  const sort = createMovieSort();
  const list = emptyAbsXml();
  console.info('[JsonParser] parseJsonHome input length=' + jsonStr.length + ' preview=' + jsonStr.substring(0, Math.min(200, jsonStr.length)));
  try {
    const obj = JSON.parse(jsonStr) as Record<string, Object>;
    const classList = obj['class'] as JsonClass[];
    if (classList && Array.isArray(classList)) {
      for (const c of classList) {
        if (c.type_pid !== undefined && c.type_pid !== 0 && c.type_pid !== '0') continue;
        const sd = createSortData(String(c.type_id ?? ''), String(c.type_name ?? ''));
        sd.flag = c.type_flag ?? '';
        sort.sortList.push(sd);
      }
    }
    const filters = obj['filters'] as Record<string, JsonFilter[]> | undefined;
    if (filters) {
      for (const sd of sort.sortList) {
        const fl = filters[sd.id];
        if (fl && Array.isArray(fl)) {
          for (const fi of fl) {
            const sf: SortFilter = {
              key: String(fi.key ?? ''),
              name: String(fi.name ?? ''),
              values: new Map(),
              init: String(fi.init ?? '')
            };
            const vals = fi.value;
            if (vals && Array.isArray(vals)) {
              for (const v of vals) {
                sf.values.set(v.v, v.n);
              }
            }
            sd.filters.push(sf);
          }
        }
      }
    }
    list.videoList = parseJsonVodList(obj['list'] as JsonVod[]);
    console.info('[JsonParser] parseJsonHome classList=' + (classList ? classList.length : 0) + ' videoList=' + list.videoList.length);
  } catch (_e) { console.error('[JsonParser] parseJsonHome error: ' + String(_e)); }
  return new HomeResult(sort, list);
}

export function parseJsonCategory(jsonStr: string): AbsXml {
  const list = emptyAbsXml();
  console.info('[JsonParser] parseJsonCategory input length=' + jsonStr.length + ' preview=' + jsonStr.substring(0, Math.min(200, jsonStr.length)));
  try {
    const obj = JSON.parse(jsonStr) as Record<string, Object>;
    list.page = Number(obj['page'] ?? 1);
    list.pagecount = Number(obj['pagecount'] ?? 0);
    list.pagesize = Number(obj['limit'] ?? 0);
    list.recordcount = Number(obj['total'] ?? 0);
    list.videoList = parseJsonVodList(obj['list'] as JsonVod[]);
    console.info('[JsonParser] parseJsonCategory videoList=' + list.videoList.length);
  } catch (_e) { console.error('[JsonParser] parseJsonCategory error: ' + String(_e)); }
  return list;
}

export function parseJsonDetail(jsonStr: string): VodInfo | null {
  try {
    const obj = JSON.parse(jsonStr) as Record<string, Object>;
    const list = obj['list'] as JsonVod[];
    if (!list || list.length === 0) return null;
    const v = list[0];
    const info: VodInfo = {
      last: '',
      id: String(v.vod_id ?? ''),
      tid: 0,
      name: v.vod_name ?? '',
      type: v.type_name ?? '',
      dt: '',
      pic: v.vod_pic ?? '',
      lang: v.vod_lang ?? '',
      area: v.vod_area ?? '',
      year: v.vod_year ? Number(v.vod_year) : 0,
      state: '',
      note: v.vod_remarks ?? '',
      actor: v.vod_actor ?? '',
      director: v.vod_director ?? '',
      des: v.vod_content ?? '',
      seriesFlags: [],
      seriesMap: new Map(),
      playFlag: '',
      playIndex: 0,
      playNote: '',
      sourceKey: '',
      playerCfg: '',
      reverseSort: false
    };
    const playFrom = v.vod_play_from ?? '';
    const playUrl = v.vod_play_url ?? '';
    if (playFrom.length > 0 && playUrl.length > 0) {
      const flags = playFrom.split('$$$');
      const urlGroups = playUrl.split('$$$');
      for (let i = 0; i < flags.length; i++) {
        const flagName = flags[i];
        const urlGroup = i < urlGroups.length ? urlGroups[i] : '';
        const series: VodSeries[] = [];
        const episodes = urlGroup.split('#');
        for (const ep of episodes) {
          const parts = ep.split('$');
          if (parts.length >= 2) {
            series.push({ name: parts[0], url: parts[1], selected: false });
          } else if (parts.length === 1 && parts[0].length > 0) {
            series.push({ name: String(series.length + 1), url: parts[0], selected: false });
          }
        }
        if (series.length > 0) {
          info.seriesFlags.push({ name: flagName, selected: false });
          info.seriesMap.set(flagName, series);
        }
      }
      if (info.seriesFlags.length > 0) {
        info.playFlag = info.seriesFlags[0].name;
      }
    }
    return info;
  } catch (_e) { return null; }
}

export function parseJsonSearch(jsonStr: string): AbsXml {
  const list = emptyAbsXml();
  try {
    const obj = JSON.parse(jsonStr) as Record<string, Object>;
    list.videoList = parseJsonVodList(obj['list'] as JsonVod[]);
  } catch (_e) { /* ignore */ }
  return list;
}

export function parseJsonPlay(jsonStr: string): PlayInfo | null {
  try {
    const obj = JSON.parse(jsonStr) as Record<string, Object>;
    const url = String(obj['url'] ?? '');
    const parse = Number(obj['parse'] ?? 0);
    const jx = Number(obj['jx'] ?? 0);
    const headerMap = new Map<string, string>();
    const header = obj['header'] as Record<string, string> | undefined;
    if (header) {
      for (const k of Object.keys(header)) {
        headerMap.set(k, header[k]);
      }
    }
    return { url, header: headerMap, parse, jx };
  } catch (_e) {
    return null;
  }
}

function isPlaceholderVod(name: string, remarks: string): boolean {
  const markers: string[] = ['防无限请求', '不要点', '无数据', '404', 'ERROR', '会崩'];
  const hay: string = name + ' ' + remarks;
  for (const m of markers) {
    if (hay.includes(m)) return true;
  }
  return false;
}

function parseJsonVodList(list: JsonVod[] | undefined): VodItem[] {
  const result: VodItem[] = [];
  if (!list || !Array.isArray(list)) {
    console.info('[JsonParser] parseJsonVodList: list is ' + (list ? 'not array' : 'undefined'));
    return result;
  }
  console.info('[JsonParser] parseJsonVodList: list.length=' + list.length);
  for (const v of list) {
    const vName: string = String(v.vod_name ?? '');
    const vRemarks: string = String(v.vod_remarks ?? '');
    if (isPlaceholderVod(vName, vRemarks)) {
      continue;
    }
    result.push({
      id: String(v.vod_id ?? ''),
      tid: 0,
      name: v.vod_name ?? '',
      type: v.type_name ?? '',
      pic: v.vod_pic ?? '',
      lang: v.vod_lang ?? '',
      area: v.vod_area ?? '',
      year: v.vod_year ? Number(v.vod_year) : 0,
      state: '',
      note: v.vod_remarks ?? '',
      actor: v.vod_actor ?? '',
      director: v.vod_director ?? '',
      des: v.vod_content ?? '',
      sourceKey: '',
      tag: v.vod_tag ?? '',
      action: '',
      last: ''
    });
  }
  return result;
}
