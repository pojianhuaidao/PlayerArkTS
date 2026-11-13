/**
 * 主题与尺寸。主色 #3c8cf0 为播放/进度高亮色，深色与浅色两套色板成对维护。
 * 深浅色通过 AppTheme.palette(isDark) 取色板，页面用 @StorageProp('isDark') 驱动刷新。
 */

/** 一套配色（颜色值统一用 #RRGGBB 或 #AARRGGBB 字符串） */
export interface Palette {
  primary: string;
  bg: string;
  bgCard: string;
  bgCardPressed: string;
  bgChip: string;
  playerBg: string;
  textPrimary: string;
  textSecondary: string;
  textTertiary: string;
  divider: string;
  controllerScrim: string;
  trackUnplayed: string;
  trackBuffered: string;
  danger: string;
  /** 底部悬浮层（页签栏 / 播放栏 / 歌词条）的玻璃底：85% 不透明，余下透出背后内容 */
  glassPlate: string;
  /** 玻璃层描边 */
  glassEdge: string;
}

export class AppTheme {
  static readonly DARK: Palette = {
    primary: '#3C8CF0',
    bg: '#121212',
    bgCard: '#1C1C1C',
    bgCardPressed: '#2A2A2A',
    bgChip: '#242424',
    playerBg: '#000000',
    textPrimary: '#FFFFFF',
    textSecondary: '#C9C9C9',
    textTertiary: '#9C9C9C',
    divider: '#262626',
    controllerScrim: '#1A000000',
    trackUnplayed: '#4CFFFFFF',
    trackBuffered: '#7FFFFFFF',
    danger: '#FF5A5A',
    glassPlate: '#D91C1C1E',
    glassEdge: '#33FFFFFF'
  };

  static readonly LIGHT: Palette = {
    primary: '#2F7FE0',
    bg: '#F4F5F7',
    bgCard: '#FFFFFF',
    bgCardPressed: '#E9EBEF',
    bgChip: '#E4E6EA',
    playerBg: '#000000',
    textPrimary: '#17191C',
    textSecondary: '#5B6067',
    textTertiary: '#8B9098',
    divider: '#E1E3E7',
    controllerScrim: '#1A000000',
    trackUnplayed: '#4C000000',
    trackBuffered: '#7F000000',
    danger: '#D93A31',
    glassPlate: '#D9F6F7F9',
    glassEdge: '#1F000000'
  };

  static palette(isDark: boolean): Palette {
    return isDark ? AppTheme.DARK : AppTheme.LIGHT;
  }

  // 兼容旧引用（默认深色），新代码请走 palette()
  static readonly primary: string = '#3C8CF0';
  static readonly bg: string = '#121212';
  static readonly bgCard: string = '#1C1C1C';
  static readonly bgCardPressed: string = '#2A2A2A';
  static readonly playerBg: string = '#000000';
  static readonly textPrimary: string = '#FFFFFF';
  static readonly textSecondary: string = '#C9C9C9';
  static readonly textTertiary: string = '#9C9C9C';
  static readonly divider: string = '#262626';
  static readonly controllerScrim: string = '#1A000000';
  static readonly trackUnplayed: string = '#4CFFFFFF';
  static readonly trackBuffered: string = '#7FFFFFFF';
  static readonly danger: string = '#FF5A5A';

  // 以下尺寸单位均为 vp
  static readonly pagePadding: number = 16;
  static readonly rowGap: number = 12;
  static readonly toolbarHeight: number = 56;
  static readonly controllerHeight: number = 48;
  static readonly thumbWidth: number = 128;
  static readonly thumbHeight: number = 72;
  static readonly radius: number = 8;

  /** 内容最大宽度：平板/车机上加宽屏不限宽会拉得很散，用居中卡片式布局 */
  static readonly contentMaxWidth: number = 900;

  /** 主题模式枚举值（持久化用字符串，避免数字魔法值） */
  static readonly THEME_SYSTEM: string = 'system';
  static readonly THEME_LIGHT: string = 'light';
  static readonly THEME_DARK: string = 'dark';
}
