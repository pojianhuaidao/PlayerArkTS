import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

/**
 * 应用数据根目录
 *
 * 应用数据（书源、播放设置、下载索引、华为账号备份镜像）优先放在鸿蒙系统公共
 * Download 目录下的 MusicData 文件夹 —— 用户可见、可迁移、可参与华为云备份；
 * 该目录在本工程未声明任何受限权限的前提下能建就建，建不了就整体回退到
 * 应用私有沙箱（context.filesDir），功能不因权限缺失而崩。
 *
 * 注意与**音乐下载**的区别（1.1111.06 起）：
 *   音乐下载落盘位置固定在应用沙箱 `files/Download`（DownloadManager 用
 *   context.filesDir 拼），既不写公共 Download、也不再依赖任何受限 ACL
 *   （READ_WRITE_DOWNLOAD_DIRECTORY / FILE_ACCESS_PERSIST）或跨重启的目录 uri 授权。
 *   需要把下载的歌给别人时，走系统保存对话框「导出到系统文件」或系统分享面板。
 *   那份决策的原因：FILE_ACCESS_PERSIST 不在签名 profile 的 allowed-acls 里，
 *   声明了会让 AGC 上传时的 ACL 一致性校验直接不通过。
 *
 * 另：当前 SDK 的 fileIo 模块没有 fs.getDownloadDirectory()（API 12 环境不存在该函数），
 * 源码级只能按下方已知路径探测。
 *
 * 华为账号备份（core/account/HuaweiAccount）把备份文件写在这个根目录下的
 * huawei_backup 子目录，作为「华为远端数据」的端侧镜像，与页面层同一套数据链路。
 *
 * 迁移说明：应用数据目录由 LxMusicData 改为 MusicData（品牌切割）。旧版本数据位于
 * 公共 Download/LxMusicData 下，升级后如要找回旧备份 / 旧数据，可手动将该目录内容
 * 合并到 MusicData。
 */
const PUBLIC_DOWNLOAD_FALLBACK: string = '/storage/Users/currentUser/Download';
const APP_DATA_DIR: string = 'MusicData';

let cachedRoot: string = '';

/** 应用数据根目录（公共 Download/MusicData 优先，失败回退私有沙箱） */
export function storageRootDir(context: common.Context): string {
  if (cachedRoot.length > 0) {
    return cachedRoot;
  }
  // 公共 Download 目录（/storage/Users/currentUser/Download）：先尝试创建数据子目录，
  // 能建即视为可用；失败则回退应用私有沙箱，保证功能不因权限缺失而崩。
  const base: string = PUBLIC_DOWNLOAD_FALLBACK;
  const target: string = `${base}/${APP_DATA_DIR}`;
  try {
    fs.mkdirSync(target);
    fs.accessSync(target);
    cachedRoot = target;
  } catch (e) {
    cachedRoot = context.filesDir;
  }
  return cachedRoot;
}
