/**
 * 直播源解析器
 * 支持 M3U (#EXTINF)、TXT (#genre#) 和 JSON 三种格式
 */
import { LiveChannelItem, LiveChannelGroup, CatchupConfig, ParsedGroup, ParsedChannel } from '../model/LiveChannel';

const DEFAULT_GROUP_NAME: string = '直播';

const NAME_PATTERN: RegExp = /.*,(\S+)$/;
const GROUP_PATTERN: RegExp = /group-title="(.*?)"/;
const TVG_CHNO_PATTERN: RegExp = /tvg-chno="(.*?)"/;
const TVG_LOGO_PATTERN: RegExp = /tvg-logo="(.*?)"/;
const TVG_NAME_PATTERN: RegExp = /tvg-name="(.*?)"/;
const TVG_URL_PATTERN: RegExp = /tvg-url="(.*?)"/;
const TVG_ID_PATTERN: RegExp = /tvg-id="(.*?)"/;
const HTTP_USER_AGENT_PATTERN: RegExp = /http-user-agent="(.*?)"/;
const CATCHUP_PATTERN: RegExp = /catchup="(.*?)"/;
const CATCHUP_SOURCE_PATTERN: RegExp = /catchup-source="(.*?)"/;
const CATCHUP_REPLACE_PATTERN: RegExp = /catchup-replace="(.*?)"/;

function isUrl(url: string): boolean {
  if (url.length === 0) return false;
  return url.startsWith('http') || url.startsWith('rtp') || url.startsWith('rtsp') || url.startsWith('rtmp');
}

function regexGet(line: string, pattern: RegExp): string {
  const m: RegExpMatchArray | null = line.match(pattern);
  if (m && m.length >= 2) return m[1].trim();
  return '';
}

function getValue(line: string, key: string): string {
  const searchKey: string = key + '=';
  const idx: number = line.indexOf(searchKey);
  if (idx === -1) return '';
  return line.substring(idx + searchKey.length).trim().replace(/"/g, '');
}

function normalizeGroupName(name: string): string {
  if (name.length === 0) return DEFAULT_GROUP_NAME;
  return name;
}

function findOrCreateGroup(result: ParsedGroup[], groupName: string): ParsedGroup {
  for (const g of result) {
    if (g.group === groupName) return g;
  }
  const newGroup: ParsedGroup = { group: groupName, channels: [] };
  result.push(newGroup);
  return newGroup;
}

function addChannel(group: ParsedGroup, channel: ParsedChannel): void {
  if (channel.urls.length === 0) return;
  for (const existing of group.channels) {
    if (existing.name === channel.name) {
      for (const url of channel.urls) {
        if (!existing.urls.includes(url)) existing.urls.push(url);
      }
      if (existing.logo.length === 0 && channel.logo.length > 0) existing.logo = channel.logo;
      if (existing.epg.length === 0 && channel.epg.length > 0) existing.epg = channel.epg;
      if (existing.ua.length === 0 && channel.ua.length > 0) existing.ua = channel.ua;
      if (existing.tvgId.length === 0 && channel.tvgId.length > 0) existing.tvgId = channel.tvgId;
      if (existing.tvgName.length === 0 && channel.tvgName.length > 0) existing.tvgName = channel.tvgName;
      if (existing.catchup === null && channel.catchup !== null) existing.catchup = channel.catchup;
      if (existing.header === null && channel.header !== null) existing.header = channel.header;
      return;
    }
  }
  group.channels.push(channel);
}

function buildCatchup(line: string): CatchupConfig | null {
  const type: string = regexGet(line, CATCHUP_PATTERN);
  const source: string = regexGet(line, CATCHUP_SOURCE_PATTERN);
  const replace: string = regexGet(line, CATCHUP_REPLACE_PATTERN);
  if (type.length > 0 || source.length > 0 || replace.length > 0) {
    return { type: type, source: source, replace: replace };
  }
  return null;
}

function buildMeta(line: string, meta: Record<string, Object>): void {
  const logo: string = regexGet(line, TVG_LOGO_PATTERN);
  if (logo.length > 0) meta['logo'] = logo;
  const epg: string = regexGet(line, TVG_URL_PATTERN);
  if (epg.length > 0) meta['epg'] = epg;
  const tvgId: string = regexGet(line, TVG_ID_PATTERN);
  if (tvgId.length > 0) meta['tvg-id'] = tvgId;
  const tvgName: string = regexGet(line, TVG_NAME_PATTERN);
  if (tvgName.length > 0) meta['tvg-name'] = tvgName;
  const tvgChno: string = regexGet(line, TVG_CHNO_PATTERN);
  if (tvgChno.length > 0) meta['tvg-chno'] = tvgChno;
  const ua: string = regexGet(line, HTTP_USER_AGENT_PATTERN);
  if (ua.length > 0) meta['ua'] = ua;
  const catchup: CatchupConfig | null = buildCatchup(line);
  if (catchup !== null) meta['catchup'] = catchup;
}

function isSetting(line: string): boolean {
  return line.startsWith('ua') || line.startsWith('parse') || line.startsWith('click') || line.startsWith('player')
    || line.startsWith('header') || line.startsWith('format') || line.startsWith('origin') || line.startsWith('referer')
    || line.startsWith('#EXTHTTP:') || line.startsWith('#EXTVLCOPT:') || line.startsWith('#KODIPROP:');
}

function buildSetting(line: string, meta: Record<string, Object>): void {
  if (line.startsWith('ua')) {
    const v: string = getValue(line, 'ua');
    if (v.length > 0) meta['ua'] = v;
  } else if (line.startsWith('parse')) {
    const v: string = getValue(line, 'parse');
    if (v.length > 0) meta['parse'] = parseInt(v, 10) || 0;
  } else if (line.startsWith('click')) {
    const v: string = getValue(line, 'click');
    if (v.length > 0) meta['click'] = v;
  } else if (line.startsWith('header')) {
    const v: string = getValue(line, 'header');
    if (v.length > 0) {
      try { meta['header'] = JSON.parse(v) as Record<string, string>; } catch (_e) {}
    }
  } else if (line.startsWith('format')) {
    const v: string = getValue(line, 'format');
    if (v.length > 0) meta['format'] = v;
  } else if (line.startsWith('origin')) {
    const v: string = getValue(line, 'origin');
    if (v.length > 0) meta['origin'] = v;
  } else if (line.startsWith('referer')) {
    const v: string = getValue(line, 'referer');
    if (v.length > 0) meta['referer'] = v;
  } else if (line.startsWith('#EXTHTTP:')) {
    try { meta['header'] = JSON.parse(line.split('#EXTHTTP:')[1].trim()) as Record<string, string>; } catch (_e) {}
  } else if (line.startsWith('#EXTVLCOPT:')) {
    if (line.includes('http-user-agent')) meta['ua'] = getValue(line, 'http-user-agent');
    if (line.includes('http-origin')) meta['origin'] = getValue(line, 'http-origin');
    if (line.includes('http-referrer')) meta['referer'] = getValue(line, 'http-referrer');
  } else if (line.startsWith('#KODIPROP:') && line.includes('manifest_type=')) {
    meta['format'] = getValue(line, 'manifest_type');
  }
}

function mergeMeta(dst: Record<string, Object>, src: Record<string, Object>): void {
  const keys: string[] = Object.keys(src);
  for (const k of keys) dst[k] = src[k];
}

function metaToChannel(name: string, meta: Record<string, Object>): ParsedChannel {
  const ch: ParsedChannel = {
    name: name, urls: [], logo: '', epg: '', ua: '', click: '', format: '',
    origin: '', referer: '', tvgId: '', tvgName: '', tvgChno: '',
    parse: 0, header: null, catchup: null
  };
  if (meta['logo'] !== undefined) ch.logo = String(meta['logo']);
  if (meta['epg'] !== undefined) ch.epg = String(meta['epg']);
  if (meta['ua'] !== undefined) ch.ua = String(meta['ua']);
  if (meta['click'] !== undefined) ch.click = String(meta['click']);
  if (meta['format'] !== undefined) ch.format = String(meta['format']);
  if (meta['origin'] !== undefined) ch.origin = String(meta['origin']);
  if (meta['referer'] !== undefined) ch.referer = String(meta['referer']);
  if (meta['tvg-id'] !== undefined) ch.tvgId = String(meta['tvg-id']);
  if (meta['tvg-name'] !== undefined) ch.tvgName = String(meta['tvg-name']);
  if (meta['tvg-chno'] !== undefined) ch.tvgChno = String(meta['tvg-chno']);
  if (meta['parse'] !== undefined) ch.parse = meta['parse'] as number;
  if (meta['header'] !== undefined) ch.header = meta['header'] as Record<string, string>;
  if (meta['catchup'] !== undefined) ch.catchup = meta['catchup'] as CatchupConfig;
  return ch;
}

function parseM3uToJsonArray(str: string): ParsedGroup[] {
  const result: ParsedGroup[] = [];
  const lines: string[] = str.replace(/\r\n/g, '\n').replace(/\r/g, '').split('\n');
  let currentGroup: ParsedGroup | null = null;
  let pendingMeta: Record<string, Object> = {};
  let pendingName: string = '';
  for (let i: number = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    if (line.length === 0) continue;
    if (line.startsWith('#EXTM3U')) { buildMeta(line, pendingMeta); continue; }
    if (isSetting(line)) { buildSetting(line, pendingMeta); continue; }
    if (line.startsWith('#EXTINF') || line.includes('#EXTINF')) {
      const groupName: string = normalizeGroupName(regexGet(line, GROUP_PATTERN));
      currentGroup = findOrCreateGroup(result, groupName);
      const nm: RegExpMatchArray | null = line.match(NAME_PATTERN);
      pendingName = nm ? nm[1].trim() : '';
      buildMeta(line, pendingMeta);
      continue;
    }
    if (line.startsWith('#')) continue;
    if (currentGroup === null) currentGroup = findOrCreateGroup(result, DEFAULT_GROUP_NAME);
    const pipeIdx: number = line.indexOf('|');
    let url: string = line;
    if (pipeIdx >= 0) {
      url = line.substring(0, pipeIdx).trim();
      const headerStr: string = line.substring(pipeIdx + 1).trim();
      if (headerStr.length > 0) {
        try { pendingMeta['header'] = JSON.parse(headerStr) as Record<string, string>; } catch (_e) {}
      }
    }
    if (!isUrl(url)) { pendingMeta = {}; pendingName = ''; continue; }
    const ch: ParsedChannel = metaToChannel(pendingName, pendingMeta);
    if (!ch.urls.includes(url)) ch.urls.push(url);
    addChannel(currentGroup, ch);
    pendingMeta = {};
    pendingName = '';
  }
  return result;
}

function parseTxtToJsonArray(str: string): ParsedGroup[] {
  const result: ParsedGroup[] = [];
  const lines: string[] = str.replace(/\r\n/g, '\n').replace(/\r/g, '').split('\n');
  let currentGroup: ParsedGroup | null = null;
  let pendingMeta: Record<string, Object> = {};
  for (let i: number = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    if (line.length === 0) continue;
    if (line.startsWith('#')) { if (isSetting(line)) buildSetting(line, pendingMeta); continue; }
    if (line.includes('#genre#')) {
      const groupName: string = line.split(',')[0].trim();
      currentGroup = findOrCreateGroup(result, normalizeGroupName(groupName));
      pendingMeta = {};
      continue;
    }
    const commaIdx: number = line.indexOf(',');
    if (commaIdx < 0) continue;
    if (currentGroup === null) currentGroup = findOrCreateGroup(result, DEFAULT_GROUP_NAME);
    const channelName: string = line.substring(0, commaIdx).trim();
    let urlPart: string = line.substring(commaIdx + 1).trim();
    let url: string = urlPart;
    const dollarIdx: number = urlPart.indexOf('$');
    if (dollarIdx >= 0) url = urlPart.substring(0, dollarIdx).trim();
    if (!isUrl(url)) continue;
    const ch: ParsedChannel = metaToChannel(channelName, pendingMeta);
    ch.urls.push(url);
    addChannel(currentGroup, ch);
    pendingMeta = {};
  }
  return result;
}

function normalizeJsonArray(groups: Object[]): ParsedGroup[] {
  const result: ParsedGroup[] = [];
  for (const groupElement of groups) {
    const groupObj: Record<string, Object> = groupElement as Record<string, Object>;
    let groupName: string = groupObj['group'] !== undefined ? String(groupObj['group']) : '';
    if (groupName.length === 0) groupName = groupObj['name'] !== undefined ? String(groupObj['name']) : DEFAULT_GROUP_NAME;
    groupName = normalizeGroupName(groupName);
    const outGroup: ParsedGroup = { group: groupName, channels: [] };
    let channels: Object[] | null = null;
    if (groupObj['channels'] instanceof Array) channels = groupObj['channels'] as Object[];
    else if (groupObj['channel'] instanceof Array) channels = groupObj['channel'] as Object[];
    if (channels !== null) {
      for (const channelElement of channels) {
        const chObj: Record<string, Object> = channelElement as Record<string, Object>;
        const name: string = chObj['name'] !== undefined ? String(chObj['name']) : 'Unnamed';
        const ch: ParsedChannel = {
          name: name, urls: [],
          logo: chObj['logo'] !== undefined ? String(chObj['logo']) : '',
          epg: chObj['epg'] !== undefined ? String(chObj['epg']) : '',
          ua: chObj['ua'] !== undefined ? String(chObj['ua']) : '',
          click: chObj['click'] !== undefined ? String(chObj['click']) : '',
          format: chObj['format'] !== undefined ? String(chObj['format']) : '',
          origin: chObj['origin'] !== undefined ? String(chObj['origin']) : '',
          referer: chObj['referer'] !== undefined ? String(chObj['referer']) : '',
          tvgId: chObj['tvg-id'] !== undefined ? String(chObj['tvg-id']) : '',
          tvgName: chObj['tvg-name'] !== undefined ? String(chObj['tvg-name']) : '',
          tvgChno: chObj['tvg-chno'] !== undefined ? String(chObj['tvg-chno']) : '',
          parse: chObj['parse'] !== undefined ? (chObj['parse'] as number) : 0,
          header: null, catchup: null
        };
        if (chObj['urls'] instanceof Array) {
          for (const u of (chObj['urls'] as Object[])) {
            const urlStr: string = String(u).trim();
            if (isUrl(urlStr) && !ch.urls.includes(urlStr)) ch.urls.push(urlStr);
          }
        }
        if (chObj['header'] !== undefined && typeof chObj['header'] === 'object') {
          ch.header = chObj['header'] as Record<string, string>;
        }
        if (chObj['catchup'] !== undefined && typeof chObj['catchup'] === 'object') {
          const cu: Record<string, Object> = chObj['catchup'] as Record<string, Object>;
          ch.catchup = { type: String(cu['type'] ?? ''), source: String(cu['source'] ?? ''), replace: String(cu['replace'] ?? '') };
        }
        addChannel(outGroup, ch);
      }
    }
    result.push(outGroup);
  }
  return result;
}

/** 解析文本为 ParsedGroup 数组 */
export function parseToJsonArray(str: string): ParsedGroup[] {
  if (str === null) return [];
  const trimmed: string = str.trim();
  if (trimmed.length === 0) return [];
  try {
    const element: Object = JSON.parse(trimmed);
    if (element instanceof Array) return normalizeJsonArray(element as Object[]);
  } catch (_e) {}
  if (trimmed.startsWith('#EXTM3U')) return parseM3uToJsonArray(trimmed);
  return parseTxtToJsonArray(trimmed);
}

/** 将 ParsedGroup 数组转换为 LiveChannelGroup 数组 */
export function parseToChannelGroups(parsedGroups: ParsedGroup[]): LiveChannelGroup[] {
  const result: LiveChannelGroup[] = [];
  let groupIndex: number = 0;
  let channelIndex: number = 0;
  let channelNum: number = 0;
  for (const pg of parsedGroups) {
    const group: LiveChannelGroup = new LiveChannelGroup();
    group.groupIndex = groupIndex++;
    group.groupName = pg.group;
    for (const pc of pg.channels) {
      const item: LiveChannelItem = new LiveChannelItem();
      item.channelIndex = channelIndex++;
      item.channelNum = ++channelNum;
      item.channelName = pc.name;
      item.channelLogo = pc.logo;
      item.channelEpg = pc.epg;
      item.channelUa = pc.ua;
      item.channelClick = pc.click;
      item.channelFormat = pc.format;
      item.channelOrigin = pc.origin;
      item.channelReferer = pc.referer;
      item.channelTvgId = pc.tvgId;
      item.channelTvgName = pc.tvgName;
      item.channelCatchup = pc.catchup;
      item.channelParse = pc.parse;
      if (pc.header !== null) {
        const keys: string[] = Object.keys(pc.header);
        for (const k of keys) {
          item.channelHeader.set(k, pc.header![k]);
        }
      }
      // URL 列表
      item.channelUrls = pc.urls.slice();
      item.sourceNum = pc.urls.length;
      // 源名称
      item.channelSourceNames = [];
      for (let i: number = 0; i < pc.urls.length; i++) {
        item.channelSourceNames.push('线路' + (i + 1));
      }
      group.liveChannelItems.push(item);
    }
    result.push(group);
  }
  return result;
}

/** 快速解析: 直接从原始文本到 LiveChannelGroup 数组 */
export function parseLiveContent(content: string): LiveChannelGroup[] {
  const parsed: ParsedGroup[] = parseToJsonArray(content);
  return parseToChannelGroups(parsed);
}
