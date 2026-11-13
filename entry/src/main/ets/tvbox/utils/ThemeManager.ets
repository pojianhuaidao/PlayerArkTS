/**
 * 主题管理 - 深色/浅色/跟随系统
 * 用鸿蒙 ApplicationContext.setColorMode 切换，并用 AppStorage 广播当前是否深色。
 * 页面用 @StorageProp('isDarkMode') 响应式取色。
 */
import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { PreferencesUtil } from './PreferencesUtil';

export type ThemeMode = 'system' | 'light' | 'dark';
export const THEME_KEY: string = 'app_theme_mode';

export class ThemeManager {
  /** 读取已保存的主题模式（默认跟随系统） */
  static getSavedMode(): ThemeMode {
    const v: string = PreferencesUtil.getSync(THEME_KEY, 'system');
    if (v === 'light' || v === 'dark') { return v; }
    return 'system';
  }

  static modeToColorMode(mode: ThemeMode): number {
    if (mode === 'light') { return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT; }
    if (mode === 'dark') { return ConfigurationConstant.ColorMode.COLOR_MODE_DARK; }
    return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  }

  static modeLabel(mode: ThemeMode): string {
    if (mode === 'light') { return '浅色'; }
    if (mode === 'dark') { return '深色'; }
    return '跟随系统';
  }

  /** 应用主题模式：切换系统 colorMode 并持久化 */
  static async applyMode(ctx: common.UIAbilityContext, mode: ThemeMode): Promise<void> {
    try {
      ctx.getApplicationContext().setColorMode(ThemeManager.modeToColorMode(mode));
    } catch (e) {
    }
    await PreferencesUtil.put(THEME_KEY, mode);
  }

  /** 依据系统配置刷新 AppStorage 的 isDarkMode 标记 */
  static refreshIsDark(colorMode: number): void {
    const isDark: boolean = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.setOrCreate('isDarkMode', isDark);
  }
}

/** 语义化配色：按 isDark 返回对应色值 */
export class Palette {
  static pick(isDark: boolean, dark: string, light: string): string {
    return isDark ? dark : light;
  }
  /** 页面主背景（纯黑/纯白） */
  static bg(isDark: boolean): string { return isDark ? '#000000' : '#FFFFFF'; }
  /** 卡片/面板背景 */
  static surface(isDark: boolean): string { return isDark ? '#1C1C1E' : '#F2F3F5'; }
  /** 卡片描边 */
  static border(isDark: boolean): string { return isDark ? '#2A2A2C' : '#E5E6EA'; }
  /** 主文字 */
  static textPrimary(isDark: boolean): string { return isDark ? '#FFFFFF' : '#1A1A1A'; }
  /** 次要文字 */
  static textSecondary(isDark: boolean): string { return isDark ? '#8A8FA6' : '#6A6F80'; }
  /** 更弱文字/箭头 */
  static textTertiary(isDark: boolean): string { return isDark ? '#6A7089' : '#9AA0AE'; }
  /** 强调色（品牌蓝，两种模式通用） */
  static accent(): string { return '#8E8E93'; }
  /** 顶部栏背景 */
  static topBar(isDark: boolean): string { return isDark ? '#14FFFFFF' : '#0D000000'; }
  /** 悬浮玻璃背景（深色=透黑 / 浅色=透白） */
  static glass(isDark: boolean): string { return isDark ? '#40000000' : '#40FFFFFF'; }
  /** 悬浮玻璃描边 */
  static glassBorder(isDark: boolean): string { return isDark ? '#33FFFFFF' : '#33000000'; }
}
