/**
 * 方向管理 - 跟随系统/横屏/竖屏
 * 用 window.setPreferredOrientation 控制，并持久化。
 */
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { PreferencesUtil } from './PreferencesUtil';

export type OrientMode = 'system' | 'landscape' | 'portrait';
export const ORIENT_KEY: string = 'app_orient_mode';

export class OrientationManager {
  static getSavedMode(): OrientMode {
    const v: string = PreferencesUtil.getSync(ORIENT_KEY, 'system');
    if (v === 'landscape' || v === 'portrait') { return v; }
    return 'system';
  }

  static modeLabel(mode: OrientMode): string {
    if (mode === 'landscape') { return '横屏'; }
    if (mode === 'portrait') { return '竖屏'; }
    return '跟随系统';
  }

  static modeToOrientation(mode: OrientMode): window.Orientation {
    if (mode === 'landscape') { return window.Orientation.AUTO_ROTATION_LANDSCAPE_RESTRICTED; }
    if (mode === 'portrait') { return window.Orientation.AUTO_ROTATION_PORTRAIT_RESTRICTED; }
    return window.Orientation.AUTO_ROTATION_RESTRICTED;
  }

  static async applyMode(ctx: common.UIAbilityContext, mode: OrientMode): Promise<void> {
    try {
      const win = await window.getLastWindow(ctx);
      await win.setPreferredOrientation(OrientationManager.modeToOrientation(mode));
    } catch (e) {
    }
    await PreferencesUtil.put(ORIENT_KEY, mode);
  }
}
