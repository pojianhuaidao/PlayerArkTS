/**
 * PanDetector - 通过 flag / 播放 URL 探测网盘类型
 * 用于在播放前提示用户是否已配置对应网盘 Cookie/Token
 */
import { PanKind } from '../utils/PanConfig';

export interface PanHit {
  kind: PanKind;
  label: string;
}

const NONE: PanHit = { kind: 'ali', label: '' };

/** 通过 lazy 里 flag 前缀识别网盘类型 */
export function detectPanByFlag(flag: string): PanHit | null {
  if (!flag || flag.length === 0) return null;
  const f: string = flag;
  if (f.indexOf('夸克') >= 0 || f.toLowerCase().indexOf('quark') >= 0) return { kind: 'quark', label: '夸克网盘' };
  if (f.indexOf('UC') >= 0 || f.toLowerCase().indexOf('yousee') >= 0 || f.indexOf('优汐') >= 0) return { kind: 'uc', label: 'UC 网盘' };
  if (f.indexOf('阿里') >= 0 || f.toLowerCase().indexOf('ali') >= 0) return { kind: 'ali', label: '阿里云盘' };
  if (f.indexOf('百度') >= 0 || f.toLowerCase().indexOf('baidu') >= 0) return { kind: 'baidu', label: '百度网盘' };
  if (f.indexOf('115') >= 0) return { kind: 's115', label: '115 网盘' };
  return null;
}

/** 通过 URL 域名识别网盘类型 */
export function detectPanByUrl(url: string): PanHit | null {
  if (!url || url.length === 0) return null;
  const u: string = url.toLowerCase();
  if (u.startsWith('ali://') || u.indexOf('alipan.com') >= 0 || u.indexOf('aliyundrive') >= 0 || u.indexOf('alist') >= 0) return { kind: 'ali', label: '阿里云盘' };
  if (u.startsWith('quark://') || u.indexOf('pan.quark.cn') >= 0 || u.indexOf('.quark.cn') >= 0) return { kind: 'quark', label: '夸克网盘' };
  if (u.startsWith('uc://') || u.indexOf('drive.uc.cn') >= 0 || u.indexOf('pc-api.uc.cn') >= 0) return { kind: 'uc', label: 'UC 网盘' };
  if (u.startsWith('baidu://') || u.indexOf('pan.baidu.com') >= 0 || u.indexOf('yun.baidu.com') >= 0) return { kind: 'baidu', label: '百度网盘' };
  if (u.startsWith('115://') || u.indexOf('115.com') >= 0) return { kind: 's115', label: '115 网盘' };
  return null;
}

/** 综合：优先 flag，其次 url */
export function detectPan(flag: string, url: string): PanHit | null {
  const byFlag = detectPanByFlag(flag);
  if (byFlag) return byFlag;
  return detectPanByUrl(url);
}
