import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VideoItem } from './VideoItem';

const TAG: string = 'PlayerPrefs';
const DOMAIN: number = 0x0001;
const STORE_NAME: string = 'player_settings';
const KEY_PLAYLIST: string = 'playlist_uris';
const KEY_SPEED: string = 'default_speed';
const KEY_GESTURE: string = 'gesture_enabled';
const KEY_AUTONEXT: string = 'auto_play_next';
const KEY_BACKGROUND: string = 'background_play';
const KEY_THEME: string = 'theme_mode';
const KEY_DECODE: string = 'decode_mode';
const KEY_SUB_LANG: string = 'subtitle_lang';
const KEY_SUB_APIKEY: string = 'subtitle_apikey';
const KEY_SUB_SOURCE: string = 'subtitle_source';
const KEY_RESUME: string = 'resume_map';
/** 页签胶囊停留多久后自动回缩（秒，0 = 常驻展开） */
const KEY_CAPSULE_RETRACT: string = 'capsule_retract_sec';
const CAPSULE_RETRACT_DEFAULT: number = 1;
const CAPSULE_RETRACT_MIN: number = 0;
const CAPSULE_RETRACT_MAX: number = 60;
/** 回缩后页签胶囊的横向落点：left / center / right */
const KEY_CAPSULE_ALIGN: string = 'capsule_align';
const CAPSULE_ALIGN_DEFAULT: string = 'center';

/** 单条播放进度记录：本地 uri 与网络 url 共用同一套结构 */
export interface ResumeEntry {
  uri: string;
  title: string;
  posMs: number;
  durMs: number;
  isNet: boolean;
  updatedAt: number;
}

/** 设置项 + 播放列表 uri 的本地持久化（对应 MX 的 preferences 行为） */
export class PlayerPrefs {
  private static store: preferences.Preferences | undefined = undefined;

  static async init(context: common.UIAbilityContext): Promise<void> {
    if (PlayerPrefs.store !== undefined) {
      return;
    }
    try {
      PlayerPrefs.store = await preferences.getPreferences(context, STORE_NAME);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'init failed');
    }
  }

  static getPlaylistUris(): string[] {
    const raw: string = PlayerPrefs.getString(KEY_PLAYLIST, '');
    if (raw.length === 0) {
      return [];
    }
    return raw.split('\n').filter((s: string) => s.length > 0);
  }

  static async savePlaylistUris(uris: string[]): Promise<void> {
    await PlayerPrefs.putString(KEY_PLAYLIST, uris.join('\n'));
  }

  static getDefaultSpeed(): number {
    return PlayerPrefs.getNumber(KEY_SPEED, 1.0);
  }

  static async setDefaultSpeed(v: number): Promise<void> {
    await PlayerPrefs.putNumber(KEY_SPEED, v);
  }

  static isGestureEnabled(): boolean {
    return PlayerPrefs.getBoolean(KEY_GESTURE, true);
  }

  static async setGestureEnabled(v: boolean): Promise<void> {
    await PlayerPrefs.putBoolean(KEY_GESTURE, v);
  }

  static isAutoPlayNext(): boolean {
    return PlayerPrefs.getBoolean(KEY_AUTONEXT, true);
  }

  static async setAutoPlayNext(v: boolean): Promise<void> {
    await PlayerPrefs.putBoolean(KEY_AUTONEXT, v);
  }

  static isBackgroundPlay(): boolean {
    return PlayerPrefs.getBoolean(KEY_BACKGROUND, false);
  }

  static async setBackgroundPlay(v: boolean): Promise<void> {
    await PlayerPrefs.putBoolean(KEY_BACKGROUND, v);
  }

  // ===== 主题 =====
  /** system / light / dark */
  static getThemeMode(): string {
    return PlayerPrefs.getString(KEY_THEME, 'system');
  }

  static async setThemeMode(v: string): Promise<void> {
    await PlayerPrefs.putString(KEY_THEME, v);
  }

  // ===== 解码模式 =====
  /** auto（AVPlayer，硬解优先）/ hw（强制走系统硬解管线）/ sw（AVCodec 软解管线） */
  static getDecodeMode(): string {
    return PlayerPrefs.getString(KEY_DECODE, 'auto');
  }

  static async setDecodeMode(v: string): Promise<void> {
    await PlayerPrefs.putString(KEY_DECODE, v);
  }

  // ===== 外观：页签胶囊悬浮回缩 =====
  /** 页签胶囊停留秒数，0 表示常驻展开；越界自动收敛到 0~60 并写回修正值 */
  static getCapsuleRetractSec(): number {
    const raw: number = PlayerPrefs.getNumber(KEY_CAPSULE_RETRACT, CAPSULE_RETRACT_DEFAULT);
    if (!(raw >= CAPSULE_RETRACT_MIN)) {
      PlayerPrefs.putNumber(KEY_CAPSULE_RETRACT, CAPSULE_RETRACT_DEFAULT);
      return CAPSULE_RETRACT_DEFAULT;
    }
    if (raw > CAPSULE_RETRACT_MAX) {
      PlayerPrefs.putNumber(KEY_CAPSULE_RETRACT, CAPSULE_RETRACT_MAX);
      return CAPSULE_RETRACT_MAX;
    }
    const out: number = Math.round(raw);
    if (out !== raw) {
      PlayerPrefs.putNumber(KEY_CAPSULE_RETRACT, out);
    }
    return out;
  }

  static async setCapsuleRetractSec(v: number): Promise<void> {
    let sec: number = Math.round(v);
    if (!(sec >= CAPSULE_RETRACT_MIN)) {
      sec = CAPSULE_RETRACT_DEFAULT;
    }
    if (sec > CAPSULE_RETRACT_MAX) {
      sec = CAPSULE_RETRACT_MAX;
    }
    await PlayerPrefs.putNumber(KEY_CAPSULE_RETRACT, sec);
  }

  // ===== 外观：页签胶囊回缩落点 =====
  /** 回缩后胶囊停靠位置：left / center / right，非法值回落为 center */
  static getCapsuleAlign(): string {
    const raw: string = PlayerPrefs.getString(KEY_CAPSULE_ALIGN, CAPSULE_ALIGN_DEFAULT);
    if (raw === 'left' || raw === 'center' || raw === 'right') {
      return raw;
    }
    return CAPSULE_ALIGN_DEFAULT;
  }

  static async setCapsuleAlign(v: string): Promise<void> {
    const val: string = (v === 'left' || v === 'right') ? v : CAPSULE_ALIGN_DEFAULT;
    await PlayerPrefs.putString(KEY_CAPSULE_ALIGN, val);
  }

  // ===== 在线字幕 =====
  /** 字幕搜索语言，默认简体中文 */
  static getSubtitleLang(): string {
    return PlayerPrefs.getString(KEY_SUB_LANG, 'zh-cn');
  }

  static async setSubtitleLang(v: string): Promise<void> {
    await PlayerPrefs.putString(KEY_SUB_LANG, v);
  }

  /** OpenSubtitles 的 Api-Key（免费注册获取，本机保存） */
  static getSubtitleApiKey(): string {
    return PlayerPrefs.getString(KEY_SUB_APIKEY, '');
  }

  static async setSubtitleApiKey(v: string): Promise<void> {
    await PlayerPrefs.putString(KEY_SUB_APIKEY, v);
  }

  /** open (OpenSubtitles) / stub（内置示例源，无需 Key） */
  static getSubtitleSource(): string {
    return PlayerPrefs.getString(KEY_SUB_SOURCE, 'open');
  }

  static async setSubtitleSource(v: string): Promise<void> {
    await PlayerPrefs.putString(KEY_SUB_SOURCE, v);
  }

  // ---------------- 播放进度记忆 ----------------

  static getResumeList(): ResumeEntry[] {
    const raw: string = PlayerPrefs.getString(KEY_RESUME, '');
    if (raw.length === 0) {
      return [];
    }
    try {
      const arr: ResumeEntry[] = JSON.parse(raw) as ResumeEntry[];
      const out: ResumeEntry[] = [];
      for (let i = 0; i < arr.length; i++) {
        const e: ResumeEntry = arr[i];
        if (e !== null && e !== undefined && e.uri !== undefined && e.uri.length > 0) {
          out.push(e);
        }
      }
      return out;
    } catch (err) {
      return [];
    }
  }

  /** 取某资源的上次播放位置（毫秒），无记录返回 0 */
  static getResumePos(uri: string): number {
    const list: ResumeEntry[] = PlayerPrefs.getResumeList();
    for (let i = 0; i < list.length; i++) {
      if (list[i].uri === uri) {
        return list[i].posMs;
      }
    }
    return 0;
  }

  static getResumeEntry(uri: string): ResumeEntry | undefined {
    const list: ResumeEntry[] = PlayerPrefs.getResumeList();
    for (let i = 0; i < list.length; i++) {
      if (list[i].uri === uri) {
        return list[i];
      }
    }
    return undefined;
  }

  static getResumeCount(): number {
    return PlayerPrefs.getResumeList().length;
  }

  /** 保存播放进度；同一 uri 覆盖更新，最多保留 60 条，末尾（最旧）自动淘汰 */
  static async saveResume(uri: string, title: string, posMs: number, durMs: number, isNet: boolean): Promise<void> {
    if (uri.length === 0) {
      return;
    }
    const old: ResumeEntry[] = PlayerPrefs.getResumeList().filter((e: ResumeEntry) => e.uri !== uri);
    const rec: ResumeEntry = {
      uri: uri,
      title: title,
      posMs: Math.floor(posMs),
      durMs: Math.floor(durMs),
      isNet: isNet,
      updatedAt: Date.now()
    };
    old.unshift(rec);
    const cut: ResumeEntry[] = old.slice(0, 60);
    await PlayerPrefs.putString(KEY_RESUME, JSON.stringify(cut));
  }

  static async clearResume(uri: string): Promise<void> {
    const old: ResumeEntry[] = PlayerPrefs.getResumeList().filter((e: ResumeEntry) => e.uri !== uri);
    await PlayerPrefs.putString(KEY_RESUME, JSON.stringify(old));
  }

  static async clearAllResume(): Promise<void> {
    await PlayerPrefs.putString(KEY_RESUME, '');
  }

  /** 按来源清理：isNet=true 只清网络进度，false 只清本地进度 */
  static async clearResumeKind(isNet: boolean): Promise<void> {
    const left: ResumeEntry[] = PlayerPrefs.getResumeList().filter((e: ResumeEntry) => e.isNet !== isNet);
    await PlayerPrefs.putString(KEY_RESUME, JSON.stringify(left));
  }

  private static getString(key: string, def: string): string {
    if (PlayerPrefs.store === undefined) {
      return def;
    }
    const v: preferences.ValueType = PlayerPrefs.store.getSync(key, def);
    return typeof v === 'string' ? v : def;
  }

  private static getNumber(key: string, def: number): number {
    if (PlayerPrefs.store === undefined) {
      return def;
    }
    const v: preferences.ValueType = PlayerPrefs.store.getSync(key, def);
    return typeof v === 'number' ? v : def;
  }

  private static getBoolean(key: string, def: boolean): boolean {
    if (PlayerPrefs.store === undefined) {
      return def;
    }
    const v: preferences.ValueType = PlayerPrefs.store.getSync(key, def);
    return typeof v === 'boolean' ? v : def;
  }

  private static async putString(key: string, value: string): Promise<void> {
    if (PlayerPrefs.store === undefined) {
      return;
    }
    await PlayerPrefs.store.put(key, value);
    await PlayerPrefs.store.flush();
  }

  private static async putNumber(key: string, value: number): Promise<void> {
    if (PlayerPrefs.store === undefined) {
      return;
    }
    await PlayerPrefs.store.put(key, value);
    await PlayerPrefs.store.flush();
  }

  private static async putBoolean(key: string, value: boolean): Promise<void> {
    if (PlayerPrefs.store === undefined) {
      return;
    }
    await PlayerPrefs.store.put(key, value);
    await PlayerPrefs.store.flush();
  }
}

/** 播放列表在运行时传递给播放页的载体（避免超长 uri 走路由参数） */
export class PlaylistHolder {
  static items: VideoItem[] = [];
  static index: number = 0;

  static set(items: VideoItem[], index: number): void {
    PlaylistHolder.items = items;
    PlaylistHolder.index = index;
  }
}
