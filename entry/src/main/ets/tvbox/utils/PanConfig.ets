/**
 * PanConfig - 网盘凭证仓
 * 每种网盘一段独立配置，落到 PreferencesUtil。所有 Pan Client 共享读写。
 * 支持的类型：ali(阿里云盘) / quark(夸克) / uc(UC 网盘) / s115(115) / baidu(百度网盘)
 */
import { PreferencesUtil } from './PreferencesUtil';

export type PanKind = 'ali' | 'quark' | 'uc' | 's115' | 'baidu';

/** 凭证来源：app=App 凭证同步后端；backend=保留后端自己的配置 */
export type PanCredentialSource = 'app' | 'backend';

/** 单个网盘的持久化凭证 */
export interface PanCredential {
  kind: PanKind;
  /** 阿里：refresh_token；其他：Cookie / BDUSS 主令牌 */
  token: string;
  /** 完整 Cookie（Quark/UC/115/百度 需要） */
  cookie: string;
  /** 运行期缓存：短期 access_token 或 stoken 等（本地缓存，不算凭证） */
  accessToken: string;
  /** access_token 过期时间戳（毫秒），0 表示未知 */
  accessExpireAt: number;
  /** 自定义 User-Agent（部分网盘转直链要求特定 UA） */
  ua: string;
  /** 额外字段（阿里 drive_id、resource_drive_id 等），JSON 字符串 */
  extra: string;
  updatedAt: number;
}

export function emptyCredential(kind: PanKind): PanCredential {
  return {
    kind, token: '', cookie: '', accessToken: '', accessExpireAt: 0,
    ua: '', extra: '', updatedAt: 0
  };
}

const PREF_KEY_PREFIX: string = 'pan_config_';
const PREF_SOURCE_PREFIX: string = 'pan_credential_source_';
const KINDS: PanKind[] = ['ali', 'quark', 'uc', 's115', 'baidu'];

export class PanConfig {
  /** 读取指定网盘凭证；不存在返回空凭证 */
  static async get(kind: PanKind): Promise<PanCredential> {
    const raw: string = await PreferencesUtil.get(PREF_KEY_PREFIX + kind, '');
    if (raw.length === 0) return emptyCredential(kind);
    try {
      const obj = JSON.parse(raw) as Record<string, Object>;
      const cred: PanCredential = emptyCredential(kind);
      if (obj['token'] !== undefined) cred.token = String(obj['token']);
      if (obj['cookie'] !== undefined) cred.cookie = String(obj['cookie']);
      if (obj['accessToken'] !== undefined) cred.accessToken = String(obj['accessToken']);
      if (obj['accessExpireAt'] !== undefined) cred.accessExpireAt = Number(obj['accessExpireAt']);
      if (obj['ua'] !== undefined) cred.ua = String(obj['ua']);
      if (obj['extra'] !== undefined) cred.extra = String(obj['extra']);
      if (obj['updatedAt'] !== undefined) cred.updatedAt = Number(obj['updatedAt']);
      return cred;
    } catch (_e) {
      return emptyCredential(kind);
    }
  }

  /** 同步读取；仅在 PreferencesUtil 已初始化后有效，否则返回空凭证 */
  static getSync(kind: PanKind): PanCredential {
    const raw: string = PreferencesUtil.getSync(PREF_KEY_PREFIX + kind, '');
    if (raw.length === 0) return emptyCredential(kind);
    try {
      const obj = JSON.parse(raw) as Record<string, Object>;
      const cred: PanCredential = emptyCredential(kind);
      if (obj['token'] !== undefined) cred.token = String(obj['token']);
      if (obj['cookie'] !== undefined) cred.cookie = String(obj['cookie']);
      if (obj['accessToken'] !== undefined) cred.accessToken = String(obj['accessToken']);
      if (obj['accessExpireAt'] !== undefined) cred.accessExpireAt = Number(obj['accessExpireAt']);
      if (obj['ua'] !== undefined) cred.ua = String(obj['ua']);
      if (obj['extra'] !== undefined) cred.extra = String(obj['extra']);
      if (obj['updatedAt'] !== undefined) cred.updatedAt = Number(obj['updatedAt']);
      return cred;
    } catch (_e) {
      return emptyCredential(kind);
    }
  }

  /** 读取凭证来源偏好；默认 app，保持历史行为 */
  static async getCredentialSource(kind: PanKind): Promise<PanCredentialSource> {
    const value: string = await PreferencesUtil.get(PREF_SOURCE_PREFIX + kind, 'app');
    return value === 'backend' ? 'backend' : 'app';
  }

  /** 设置凭证来源偏好 */
  static async setCredentialSource(kind: PanKind, source: PanCredentialSource): Promise<void> {
    await PreferencesUtil.put(PREF_SOURCE_PREFIX + kind, source);
  }

  /** 写回整份凭证；调用方通常先 get 再改再 set */
  static async set(cred: PanCredential): Promise<void> {
    cred.updatedAt = Date.now();
    const payload: Record<string, Object> = {
      'token': cred.token,
      'cookie': cred.cookie,
      'accessToken': cred.accessToken,
      'accessExpireAt': cred.accessExpireAt,
      'ua': cred.ua,
      'extra': cred.extra,
      'updatedAt': cred.updatedAt
    };
    await PreferencesUtil.put(PREF_KEY_PREFIX + cred.kind, JSON.stringify(payload));
  }

  /** 部分更新：仅更新调用方传入的字段 */
  static async patch(kind: PanKind, patch: Partial<PanCredential>): Promise<PanCredential> {
    const cred: PanCredential = await PanConfig.get(kind);
    if (patch.token !== undefined) cred.token = patch.token;
    if (patch.cookie !== undefined) cred.cookie = patch.cookie;
    if (patch.accessToken !== undefined) cred.accessToken = patch.accessToken;
    if (patch.accessExpireAt !== undefined) cred.accessExpireAt = patch.accessExpireAt;
    if (patch.ua !== undefined) cred.ua = patch.ua;
    if (patch.extra !== undefined) cred.extra = patch.extra;
    await PanConfig.set(cred);
    return cred;
  }

  /** 清空指定网盘凭证 */
  static async clear(kind: PanKind): Promise<void> {
    await PreferencesUtil.delete(PREF_KEY_PREFIX + kind);
  }

  /** 是否已有可用主凭证 */
  static isConfigured(cred: PanCredential): boolean {
    if (cred.kind === 'ali') return cred.token.length > 0;
    return cred.cookie.length > 0;
  }

  /** 遍历所有网盘 */
  static kinds(): PanKind[] {
    return KINDS.slice();
  }

  /** 展示用标签 */
  static kindLabel(kind: PanKind): string {
    if (kind === 'ali') return '阿里云盘';
    if (kind === 'quark') return '夸克网盘';
    if (kind === 'uc') return 'UC 网盘';
    if (kind === 's115') return '115 网盘';
    if (kind === 'baidu') return '百度网盘';
    return kind;
  }
}
