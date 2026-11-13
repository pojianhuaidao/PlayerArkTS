/**
 * 偏好存储工具 - 基于 @ohos.data.preferences
 * 用于存储配置 URL、当前源、历史记录等
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME = 'kandianshi_prefs';
let prefStore: preferences.Preferences | null = null;
let injectedContext: common.UIAbilityContext | null = null;

async function getStore(): Promise<preferences.Preferences> {
  if (prefStore) return prefStore;
  // 优先使用 EntryAbility 注入的 context；否则回退 getContext()（在早期生命周期可能为 undefined）
  const context = injectedContext ?? (getContext() as common.UIAbilityContext);
  if (!context) {
    throw new Error('preferences context not ready');
  }
  prefStore = await preferences.getPreferences(context, PREF_NAME);
  return prefStore;
}

export function setPreferencesContext(ctx: common.UIAbilityContext): void {
  injectedContext = ctx;
}

export class PreferencesUtil {
  static async put(key: string, value: string): Promise<void> {
    const store = await getStore();
    await store.put(key, value);
    await store.flush();
  }

  static async get(key: string, defaultValue: string): Promise<string> {
    const store = await getStore();
    return await store.get(key, defaultValue) as string;
  }

  static getSync(key: string, defaultValue: string): string {
    if (prefStore) {
      return prefStore.getSync(key, defaultValue) as string;
    }
    return defaultValue;
  }

  static async putInt(key: string, value: number): Promise<void> {
    const store = await getStore();
    await store.put(key, value);
    await store.flush();
  }

  static async getInt(key: string, defaultValue: number): Promise<number> {
    const store = await getStore();
    return await store.get(key, defaultValue) as number;
  }

  static getIntSync(key: string, defaultValue: number): number {
    if (prefStore) {
      return prefStore.getSync(key, defaultValue) as number;
    }
    return defaultValue;
  }

  static async putBool(key: string, value: boolean): Promise<void> {
    const store = await getStore();
    await store.put(key, value);
    await store.flush();
  }

  static async getBool(key: string, defaultValue: boolean): Promise<boolean> {
    const store = await getStore();
    return await store.get(key, defaultValue) as boolean;
  }

  static getBoolSync(key: string, defaultValue: boolean): boolean {
    if (prefStore) {
      return prefStore.getSync(key, defaultValue) as boolean;
    }
    return defaultValue;
  }

  static async delete(key: string): Promise<void> {
    const store = await getStore();
    await store.delete(key);
    await store.flush();
  }

  static async has(key: string): Promise<boolean> {
    const store = await getStore();
    return await store.has(key);
  }
}
