/**
 * 设计系统 - 响应式尺寸/间距/字号 + 统一动画曲线
 * 断点: sm(<600vp 手机竖屏) / md(<840vp 手机横屏·小平板) / lg(>=840vp 大平板·折叠展开)
 * 用法: 组件持有 @State bp: Breakpoint, 传入这里的取值函数按当前断点返回尺寸。
 */
import { curves } from '@kit.ArkUI';
import { Breakpoint, BP_SM, BP_MD, BP_LG } from './ScreenAdapter';

function pick<T>(bp: Breakpoint, sm: T, md: T, lg: T): T {
  if (bp === BP_SM) return sm;
  if (bp === BP_MD) return md;
  return lg;
}

export class DS {
  /** 内容区左右安全边距 */
  static hPadding(bp: Breakpoint): number { return pick(bp, 16, 24, 32); }

  /** 屏幕物理圆角安全边距(vp)：贴边/贴角内容额外内缩，避免被圆角裁切。手机圆角更大 */
  static cornerInset(bp: Breakpoint): number { return pick(bp, 6, 5, 4); }
  /** 海报网格列数 */
  static gridColumns(bp: Breakpoint): number { return pick(bp, 3, 8, 9); }
  /** 海报网格模板字符串 */
  static gridTemplate(bp: Breakpoint): string {
    const n: number = DS.gridColumns(bp);
    let t: string = '1fr';
    for (let i = 1; i < n; i++) { t += ' 1fr'; }
    return t;
  }
  /** 网格间距 */
  static gridGap(bp: Breakpoint): number { return pick(bp, 8, 10, 12); }
  /** 应用标题字号 */
  static titleFont(bp: Breakpoint): number { return pick(bp, 22, 26, 30); }
  /** 时钟字号 */
  static clockFont(bp: Breakpoint): number { return pick(bp, 14, 20, 24); }
  /** 分类标签字号 */
  static categoryFont(bp: Breakpoint): number { return pick(bp, 14, 15, 16); }
  /** 卡片标题字号 */
  static cardTitleFont(bp: Breakpoint): number { return pick(bp, 11, 12, 13); }
  /** 卡片角标字号 */
  static cardBadgeFont(bp: Breakpoint): number { return pick(bp, 9, 10, 10); }
  /** 顶部栏高度(不含安全区) */
  static topBarHeight(bp: Breakpoint): number { return pick(bp, 36, 38, 40); }
  /** 分类栏高度 */
  static categoryBarHeight(bp: Breakpoint): number { return pick(bp, 40, 42, 45); }
  /** 设置行高度 */
  static settingRowHeight(bp: Breakpoint): number { return pick(bp, 48, 50, 54); }
  /** 通用正文字号 */
  static bodyFont(bp: Breakpoint): number { return pick(bp, 15, 16, 18); }
  /** 通用小字号 */
  static smallFont(bp: Breakpoint): number { return pick(bp, 12, 13, 14); }
  /** 卡片圆角 */
  static cardRadius(bp: Breakpoint): number { return pick(bp, 8, 10, 12); }
  /** 弹窗最大宽度(横屏/平板时不要铺满) */
  static dialogMaxWidth(bp: Breakpoint): number { return pick(bp, 340, 460, 520); }
}

/** 统一动画时长/曲线 */
export class Motion {
  static readonly DUR_FAST: number = 180;
  static readonly DUR_BASE: number = 260;
  static readonly DUR_SLOW: number = 380;
  static readonly EASE: Curve = Curve.EaseInOut;
  /** 页面/面板进出用的弹性动画 */
  static spring(): ICurve { return curves.springMotion(0.42, 0.8); }
  /** 轻交互(按压/选中)用的弹性 */
  static springSoft(): ICurve { return curves.responsiveSpringMotion(0.34, 0.9); }
}
