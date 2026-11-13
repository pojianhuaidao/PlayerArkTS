/**
 * 屏幕适配工具 - 断点(vp) + 底部安全区(小白条)高度
 * 参考 HarmonyOS 多设备/折叠屏适配：断点基于 vp 宽度而非物理像素。
 */
import { display, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';

export type Breakpoint = 'sm' | 'md' | 'lg';

export const BP_SM: Breakpoint = 'sm'; // <600vp 手机竖屏
export const BP_MD: Breakpoint = 'md'; // <840vp 手机横屏/小平板
export const BP_LG: Breakpoint = 'lg'; // >=840vp 大平板/折叠展开

/** 依据当前默认屏幕的 vp 宽度返回断点 */
export function getBreakpoint(): Breakpoint {
  try {
    const d = display.getDefaultDisplaySync();
    const density: number = d.densityPixels > 0 ? d.densityPixels : 1;
    const widthVp: number = d.width / density;
    if (widthVp < 600) {
      return BP_SM;
    }
    if (widthVp < 840) {
      return BP_MD;
    }
    return BP_LG;
  } catch (e) {
    return BP_SM;
  }
}

/** 是否横向布局（手机横屏/平板） */
/** Compute breakpoint from a window width in px (for windowSizeChange, avoids display timing issues on rotation). */
export function getBreakpointByWidth(widthPx: number): Breakpoint {
  try {
    const d = display.getDefaultDisplaySync();
    const density: number = d.densityPixels > 0 ? d.densityPixels : 1;
    const widthVp: number = widthPx / density;
    if (widthVp < 600) {
      return BP_SM;
    }
    if (widthVp < 840) {
      return BP_MD;
    }
    return BP_LG;
  } catch (e) {
    return BP_SM;
  }
}

export function isWide(bp: Breakpoint): boolean {
  return bp === BP_MD || bp === BP_LG;
}

/** 真实横屏判定：物理宽 > 高（区分平板竖屏与横屏） */
export function isLandscape(): boolean {
  try {
    const d = display.getDefaultDisplaySync();
    return d.width > d.height;
  } catch (e) {
    return false;
  }
}

/**
 * 获取底部导航条(小白条)高度(vp)。取系统避让区底部高度。
 * 无窗口上下文或异常时返回 0。
 */
export async function getBottomSafeAreaVp(ctx: common.UIAbilityContext | undefined): Promise<number> {
  try {
    const win: window.Window = ctx
      ? await window.getLastWindow(ctx)
      : await window.getLastWindow(getContext() as common.UIAbilityContext);
    const avoid = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    const h: number = avoid.bottomRect.height;
    if (h > 0) {
      return px2vp(h);
    }
    const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    return px2vp(sys.bottomRect.height);
  } catch (e) {
    return 0;
  }
}

/** 左侧安全区(vp)：横屏时摄像头挖孔/系统避让可能在左侧 */
export async function getLeftSafeAreaVp(ctx: common.UIAbilityContext | undefined): Promise<number> {
  try {
    const win: window.Window = ctx
      ? await window.getLastWindow(ctx)
      : await window.getLastWindow(getContext() as common.UIAbilityContext);
    const cutout = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
    const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const l: number = Math.max(cutout.leftRect.width, sys.leftRect.width);
    return l > 0 ? px2vp(l) : 0;
  } catch (e) {
    return 0;
  }
}

/** 右侧安全区(vp)：横屏时摄像头挖孔/系统避让可能在右侧 */
export async function getRightSafeAreaVp(ctx: common.UIAbilityContext | undefined): Promise<number> {
  try {
    const win: window.Window = ctx
      ? await window.getLastWindow(ctx)
      : await window.getLastWindow(getContext() as common.UIAbilityContext);
    const cutout = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
    const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const r: number = Math.max(cutout.rightRect.width, sys.rightRect.width);
    return r > 0 ? px2vp(r) : 0;
  } catch (e) {
    return 0;
  }
}

/** Sync top safe area (vp): max of status bar and cutout to avoid punch-hole overlap */
export function getTopSafeAreaSync(win: window.Window): number {
  try {
    const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const cutout = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
    const th: number = Math.max(sys.topRect.height, cutout.topRect.height);
    return th > 0 ? px2vp(th) : 0;
  } catch (e) {
    return 0;
  }
}


/** 顶部状态栏安全区高度(vp) */
export async function getTopSafeAreaVp(ctx: common.UIAbilityContext | undefined): Promise<number> {
  try {
    const win: window.Window = ctx
      ? await window.getLastWindow(ctx)
      : await window.getLastWindow(getContext() as common.UIAbilityContext);
    const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const cutout = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
    const th: number = Math.max(sys.topRect.height, cutout.topRect.height);
    return th > 0 ? px2vp(th) : 0;
  } catch (e) {
    return 0;
  }
}

/** 顶部挖孔/刘海摄像头避让高度(vp)。用于给标题等元素加一点下沉，避免被摄像头挡住。 */
export async function getTopCutoutVp(ctx: common.UIAbilityContext | undefined): Promise<number> {
  try {
    const win: window.Window = ctx
      ? await window.getLastWindow(ctx)
      : await window.getLastWindow(getContext() as common.UIAbilityContext);
    const cutout = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
    const h: number = cutout.topRect.height;
    return h > 0 ? px2vp(h) : 0;
  } catch (e) {
    return 0;
  }
}