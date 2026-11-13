/**
 * XML 源解析器
 * 解析标准 CMS XML API 响应 (type=0)
 * 使用正则 + 简易 XML 解析
 */
import { AbsXml, VodItem, VodInfo, VodSeries, emptyAbsXml, HomeResult } from '../model/Movie';
import { MovieSort, SortData, createSortData, createMovieSort } from '../model/MovieSort';
import { AbsXml as AbsXmlType } from '../model/Movie';

interface JsonClassItem {
  type_id: string | number;
  type_name: string;
  type_pid?: string | number;
}

export function parseXmlHome(str: string): HomeResult {
  const sort = createMovieSort();
  const list: AbsXml = emptyAbsXml();
  const trimmed = str.trim();
  if (trimmed.startsWith('{')) {
    return parseJsonHomeCompat(str);
  }
  if (trimmed.startsWith('<')) {
    const tyPattern = /<ty\s+id="([^"]*)"[^>]*>([^<]*)<\/ty>/g;
    let m: RegExpExecArray | null;
    while ((m = tyPattern.exec(str)) !== null) {
      const sd = createSortData(m[1], m[2]);
      sort.sortList.push(sd);
    }
    list.videoList = parseXmlVideoList(str);
  }
  return new HomeResult(sort, list);
}

export function parseXmlCategory(str: string): AbsXml {
  const list = emptyAbsXml();
  const trimmed = str.trim();
  if (trimmed.startsWith('{')) {
    return parseJsonCategoryCompat(str);
  }
  if (trimmed.startsWith('<')) {
    list.page = parseIntAttr(str, 'page', 1);
    list.pagecount = parseIntAttr(str, 'pagecount', 0);
    list.pagesize = parseIntAttr(str, 'pagesize', 0);
    list.recordcount = parseIntAttr(str, 'recordcount', 0);
    list.videoList = parseXmlVideoList(str);
  }
  return list;
}

export function parseXmlDetail(str: string): VodInfo | null {
  const trimmed = str.trim();
  if (trimmed.startsWith('{')) {
    return parseJsonDetailCompat(str);
  }
  if (trimmed.startsWith('<')) {
    const videoMatch = /<video\b[^>]*>([\s\S]*?)<\/video>/.exec(str);
    if (!videoMatch) return null;
    const vc = videoMatch[1];
    const info: VodInfo = {
      last: getTagContent(vc, 'last'),
      id: getTagContent(vc, 'id'),
      tid: parseInt(getTagContent(vc, 'tid') || '0', 10),
      name: getTagContent(vc, 'name'),
      type: getTagContent(vc, 'type'),
      dt: getTagContent(vc, 'dt'),
      pic: getTagContent(vc, 'pic'),
      lang: getTagContent(vc, 'lang'),
      area: getTagContent(vc, 'area'),
      year: parseInt(getTagContent(vc, 'year') || '0', 10),
      state: getTagContent(vc, 'state'),
      note: getTagContent(vc, 'note'),
      actor: getTagContent(vc, 'actor'),
      director: getTagContent(vc, 'director'),
      des: getTagContent(vc, 'des'),
      seriesFlags: [],
      seriesMap: new Map(),
      playFlag: '',
      playIndex: 0,
      playNote: '',
      sourceKey: '',
      playerCfg: '',
      reverseSort: false
    };

    const dlMatch = /<dl\b[^>]*>([\s\S]*?)<\/dl>/.exec(vc);
    if (dlMatch) {
      const ddPattern = /<dd\s+flag="([^"]*)"[^>]*>([\s\S]*?)<\/dd>/g;
      let dd: RegExpExecArray | null;
      while ((dd = ddPattern.exec(dlMatch[1])) !== null) {
        const flagName = dd[1];
        const urlContent = dd[2].trim();
        const series: VodSeries[] = [];
        const episodes = urlContent.split('#');
        for (const ep of episodes) {
          const parts = ep.split('$');
          if (parts.length >= 2) {
            series.push({ name: parts[0].trim(), url: parts[1].trim(), selected: false });
          } else if (parts.length === 1 && parts[0].trim().length > 0) {
            series.push({ name: String(series.length + 1), url: parts[0].trim(), selected: false });
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
  }
  return null;
}

export function parseXmlSearch(str: string): AbsXml {
  const list = emptyAbsXml();
  const trimmed = str.trim();
  if (trimmed.startsWith('{')) {
    return parseJsonSearchCompat(str);
  }
  if (trimmed.startsWith('<')) {
    list.videoList = parseXmlVideoList(str);
  }
  return list;
}

function parseXmlVideoList(str: string): VodItem[] {
  const result: VodItem[] = [];
  const videoPattern = /<video\b[^>]*>([\s\S]*?)<\/video>/g;
  let m: RegExpExecArray | null;
  while ((m = videoPattern.exec(str)) !== null) {
    const vc = m[1];
    result.push({
      id: getTagContent(vc, 'id'),
      tid: parseInt(getTagContent(vc, 'tid') || '0', 10),
      name: getTagContent(vc, 'name'),
      type: getTagContent(vc, 'type'),
      pic: getTagContent(vc, 'pic'),
      lang: getTagContent(vc, 'lang'),
      area: getTagContent(vc, 'area'),
      year: parseInt(getTagContent(vc, 'year') || '0', 10),
      state: getTagContent(vc, 'state'),
      note: getTagContent(vc, 'note'),
      actor: getTagContent(vc, 'actor'),
      director: getTagContent(vc, 'director'),
      des: getTagContent(vc, 'des'),
      sourceKey: '',
      tag: getTagContent(vc, 'tag'),
      action: getTagContent(vc, 'action'),
      last: getTagContent(vc, 'last')
    });
  }
  return result;
}

function getTagContent(content: string, tag: string): string {
  const pattern = new RegExp('<' + tag + '\b[^>]*>([\s\S]*?)<\/' + tag + '>', 'i');
  const m = pattern.exec(content);
  if (m) return decodeXml(m[1].trim());
  // self-closing or attribute-only
  const attrPattern = new RegExp('<' + tag + '\b[^>]*\svalue="([^"]*)"[^>]*/?>');
  const am = attrPattern.exec(content);
  if (am) return decodeXml(am[1]);
  return '';
}

function parseIntAttr(str: string, attr: string, defaultValue: number): number {
  const pattern = new RegExp('\\b' + attr + '="(\\d+)"');
  const m = pattern.exec(str);
  return m ? parseInt(m[1], 10) : defaultValue;
}

function decodeXml(s: string): string {
  return s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_: string, code: string) => String.fromCharCode(parseInt(code, 10)));
}

// JSON 兼容解析 (部分 XML 源可能返回 JSON)
function parseJsonHomeCompat(str: string): HomeResult {
  const sort = createMovieSort();
  const list = emptyAbsXml();
  try {
    const obj = JSON.parse(str) as Record<string, Object>;
    const classList = obj['class'] as Object[];
    if (classList && Array.isArray(classList)) {
      for (const c of classList as Record<string, Object>[]) {
        if (c['type_pid'] !== undefined && c['type_pid'] !== 0 && c['type_pid'] !== '0') continue;
        sort.sortList.push(createSortData(String(c['type_id'] ?? ''), String(c['type_name'] ?? '')));
      }
    }
    list.videoList = jsonToVodList(obj['list']);
  } catch (_e) { /* ignore */ }
  return new HomeResult(sort, list);
}

function parseJsonCategoryCompat(str: string): AbsXml {
  const list = emptyAbsXml();
  try {
    const obj = JSON.parse(str) as Record<string, Object>;
    list.page = Number(obj['page'] ?? 1);
    list.pagecount = Number(obj['pagecount'] ?? 0);
    list.pagesize = Number(obj['limit'] ?? 0);
    list.recordcount = Number(obj['total'] ?? 0);
    list.videoList = jsonToVodList(obj['list']);
  } catch (_e) { /* ignore */ }
  return list;
}

function parseJsonDetailCompat(str: string): VodInfo | null {
  try {
    const obj = JSON.parse(str) as Record<string, Object>;
    const arr = obj['list'] as Object[];
    if (!arr || arr.length === 0) return null;
    const v = arr[0] as Record<string, Object>;
    const info: VodInfo = {
      last: '', id: String(v['vod_id'] ?? ''), tid: 0,
      name: String(v['vod_name'] ?? ''), type: String(v['type_name'] ?? ''),
      dt: '', pic: String(v['vod_pic'] ?? ''),
      lang: String(v['vod_lang'] ?? ''), area: String(v['vod_area'] ?? ''),
      year: Number(v['vod_year'] ?? 0), state: '',
      note: String(v['vod_remarks'] ?? ''),
      actor: String(v['vod_actor'] ?? ''), director: String(v['vod_director'] ?? ''),
      des: String(v['vod_content'] ?? ''),
      seriesFlags: [], seriesMap: new Map(),
      playFlag: '', playIndex: 0, playNote: '',
      sourceKey: '', playerCfg: '', reverseSort: false
    };
    const playFrom = String(v['vod_play_from'] ?? '');
    const playUrl = String(v['vod_play_url'] ?? '');
    if (playFrom && playUrl) {
      const flags = playFrom.split('$$$');
      const groups = playUrl.split('$$$');
      for (let i = 0; i < flags.length; i++) {
        const series: VodSeries[] = [];
        const eps = (groups[i] || '').split('#');
        for (const ep of eps) {
          const parts = ep.split('$');
          if (parts.length >= 2) series.push({ name: parts[0], url: parts[1], selected: false });
          else if (parts.length === 1 && parts[0]) series.push({ name: String(series.length + 1), url: parts[0], selected: false });
        }
        if (series.length > 0) {
          info.seriesFlags.push({ name: flags[i], selected: false });
          info.seriesMap.set(flags[i], series);
        }
      }
      if (info.seriesFlags.length > 0) info.playFlag = info.seriesFlags[0].name;
    }
    return info;
  } catch (_e) { return null; }
}

function parseJsonSearchCompat(str: string): AbsXml {
  const list = emptyAbsXml();
  try {
    const obj = JSON.parse(str) as Record<string, Object>;
    list.videoList = jsonToVodList(obj['list']);
  } catch (_e) { /* ignore */ }
  return list;
}

function jsonToVodList(raw: Object | undefined): VodItem[] {
  const result: VodItem[] = [];
  if (!raw || !Array.isArray(raw)) return result;
  const arr = raw as Record<string, Object>[];
  for (const v of arr) {
    result.push({
      id: String(v['vod_id'] ?? ''), tid: 0,
      name: String(v['vod_name'] ?? ''),
      type: String(v['type_name'] ?? ''),
      pic: String(v['vod_pic'] ?? ''),
      lang: String(v['vod_lang'] ?? ''),
      area: String(v['vod_area'] ?? ''),
      year: Number(v['vod_year'] ?? 0),
      state: '', note: String(v['vod_remarks'] ?? ''),
      actor: String(v['vod_actor'] ?? ''),
      director: String(v['vod_director'] ?? ''),
      des: String(v['vod_content'] ?? ''),
      sourceKey: '', tag: String(v['vod_tag'] ?? ''),
      action: '', last: ''
    });
  }
  return result;
}
