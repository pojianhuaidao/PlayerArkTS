import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NetServer } from './NetServer';

const TAG: string = 'NetPrefs';
const DOMAIN: number = 0x0001;
const STORE_NAME: string = 'net_prefs';
const KEY_HISTORY: string = 'net_history';
const KEY_LAST: string = 'net_last_url';
const KEY_SERVERS: string = 'net_servers';
const KEY_DAV_URL: string = 'dav_url';
const KEY_DAV_USER: string = 'dav_user';
const KEY_DAV_PASS: string = 'dav_pass';
const MAX_HISTORY: number = 12;

/** 局域网地址、最近连接记录的持久化 */
export class NetPrefs {
  private static store: preferences.Preferences | undefined = undefined;

  static async init(context: common.UIAbilityContext): Promise<void> {
    if (NetPrefs.store !== undefined) {
      return;
    }
    try {
      NetPrefs.store = await preferences.getPreferences(context, STORE_NAME);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'init failed');
    }
  }

  static getHistory(): string[] {
    return NetPrefs.getString(KEY_HISTORY, '').split('\n').filter((s: string) => s.length > 0);
  }

  static getLastUrl(): string {
    return NetPrefs.getString(KEY_LAST, '');
  }

  /** 新地址插到队首，自动去重并截断 */
  static async pushHistory(url: string): Promise<void> {
    const old: string[] = NetPrefs.getHistory().filter((s: string) => s !== url);
    old.unshift(url);
    const cut: string[] = old.slice(0, MAX_HISTORY);
    await NetPrefs.putString(KEY_HISTORY, cut.join('\n'));
    await NetPrefs.putString(KEY_LAST, url);
  }

  static async clearHistory(): Promise<void> {
    await NetPrefs.putString(KEY_HISTORY, '');
    await NetPrefs.putString(KEY_LAST, '');
  }

  // ---------------- 已保存的服务器 ----------------

  /** 已保存服务器列表（按保存顺序） */
  static getServers(): NetServer[] {
    const raw: string = NetPrefs.getString(KEY_SERVERS, '');
    if (raw.length === 0) {
      return [];
    }
    const out: NetServer[] = [];
    const lines: string[] = raw.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      const item: NetServer | undefined = NetServer.fromJson(line);
      if (item !== undefined) {
        item.pass = NetPrefs.decodePass(item.pass);
        out.push(item);
      }
    }
    return out;
  }

  /** 新增或覆盖同 key 的服务器，返回写入后的完整列表 */
  static async upsertServer(server: NetServer): Promise<NetServer[]> {
    const list: NetServer[] = NetPrefs.getServers().filter((s: NetServer) => s.key() !== server.key());
    list.unshift(server);
    await NetPrefs.saveServers(list);
    return list;
  }

  static async removeServer(key: string): Promise<NetServer[]> {
    const list: NetServer[] = NetPrefs.getServers().filter((s: NetServer) => s.key() !== key);
    await NetPrefs.saveServers(list);
    return list;
  }

  private static async saveServers(list: NetServer[]): Promise<void> {
    const lines: string[] = list.map((s: NetServer) => {
      const copy: NetServer = new NetServer(s.name, s.url, s.proto, s.user, NetPrefs.encodePass(s.pass));
      return copy.toJson();
    });
    await NetPrefs.putString(KEY_SERVERS, lines.join('\n'));
  }

  // ---------------- WebDAV 记忆 ----------------

  /** 上次使用的 WebDAV 地址，默认带 https:// 前缀 */
  static getDavUrl(): string {
    const v: string = NetPrefs.getString(KEY_DAV_URL, '');
    return v.length > 0 ? v : 'https://';
  }

  static getDavUser(): string {
    return NetPrefs.getString(KEY_DAV_USER, '');
  }

  static getDavPass(): string {
    return NetPrefs.decodePass(NetPrefs.getString(KEY_DAV_PASS, ''));
  }

  static async saveDav(url: string, user: string, pass: string): Promise<void> {
    await NetPrefs.putString(KEY_DAV_URL, url);
    await NetPrefs.putString(KEY_DAV_USER, user);
    await NetPrefs.putString(KEY_DAV_PASS, NetPrefs.encodePass(pass));
  }

  static async clearDav(): Promise<void> {
    await NetPrefs.putString(KEY_DAV_URL, 'https://');
    await NetPrefs.putString(KEY_DAV_USER, '');
    await NetPrefs.putString(KEY_DAV_PASS, '');
  }

  /** 密码做 base64 混淆后存应用私有 preferences（非强加密） */
  private static encodePass(pass: string): string {
    if (pass.length === 0) {
      return '';
    }
    try {
      const helper: util.Base64Helper = new util.Base64Helper();
      const enc: util.TextEncoder = new util.TextEncoder();
      return helper.encodeToStringSync(enc.encodeInto(pass));
    } catch (err) {
      return '';
    }
  }

  private static decodePass(text: string): string {
    if (text.length === 0) {
      return '';
    }
    try {
      const helper: util.Base64Helper = new util.Base64Helper();
      const dec: util.TextDecoder = new util.TextDecoder();
      return dec.decodeToString(helper.decodeSync(text));
    } catch (err) {
      return '';
    }
  }

  private static getString(key: string, def: string): string {
    if (NetPrefs.store === undefined) {
      return def;
    }
    const v: preferences.ValueType = NetPrefs.store.getSync(key, def);
    return typeof v === 'string' ? v : def;
  }

  private static async putString(key: string, value: string): Promise<void> {
    if (NetPrefs.store === undefined) {
      return;
    }
    await NetPrefs.store.put(key, value);
    await NetPrefs.store.flush();
  }
}
