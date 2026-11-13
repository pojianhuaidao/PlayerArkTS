import { media } from '@kit.MediaKit';
import { fileIo as fs, picker, fileShare, fileUri, Environment } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { dataSharePredicates } from '@kit.ArkData';
import { common, abilityAccessCtrl, bundleManager, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VideoItem, fileNameOf, folderNameOf, stripExt, decodeName } from './VideoItem';

const TAG: string = 'MediaRepository';
const DOMAIN: number = 0x0001;

/** Download 目录所需的受限权限（system_basic + ACL，用户级授权） */
const PERM_DOWNLOAD: Permissions = 'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY';
/** 提供公共 Download 目录路径的系统能力 */
const SYSCAP_FOLDER_OBTAIN: string = 'SystemCapability.FileManagement.File.Environment.FolderObtain';

/** 支持的本地容器格式，与 MX 本地列表主流程一致（容器级） */
export const VIDEO_EXTENSIONS: string[] = ['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'ts',
  'm3u8', 'mpg', 'mpeg', 'rmvb', 'rm', '3gp', 'm4v', 'm2ts', 'vob', 'asf', 'ogv', 'divx', 'f4v'];

export function isVideoName(name: string): boolean {
  const idx: number = name.lastIndexOf('.');
  if (idx < 0) {
    return false;
  }
  const ext: string = name.substring(idx + 1).toLowerCase();
  return VIDEO_EXTENSIONS.indexOf(ext) >= 0;
}

/** 目录遍历统计：用于把"目录里没视频"和"根本没权限读"区分开 */
class WalkStats {
  total: number = 0;
  listCode: number = 0;
}

/**
 * Download 目录扫描/权限诊断结果。
 * 每个字段对应一处失败节点，界面据此给出可定位的提示，而不是笼统的"未读到视频"。
 */
export class DownloadScanReport {
  /** getUserDownloadDir 返回的目录（空串表示系统没给路径） */
  dir: string = '';
  /** 本机是否具备 FolderObtain 能力 */
  syscap: boolean = false;
  /** 权限是否已真正授予（checkAccessToken 结果） */
  granted: boolean = false;
  /** requestPermissionsFromUser 抛错时的错误码，0 表示没抛错 */
  requestCode: number = 0;
  /** requestPermissionsFromUser 的 authResults[0]，0 表示授予，-1 表示拒绝 */
  requestResult: number = -1;
  /** fs.accessSync 打开目录的错误码，0 表示可访问 */
  accessCode: number = 0;
  /** fs.listFileSync 列目录的错误码，0 表示可读取 */
  listCode: number = 0;
  /** 目录内（含一级子目录）有效文件总数 */
  totalFiles: number = 0;
  /** 命中的视频绝对路径 */
  videos: string[] = [];
}

export class MediaRepository {
  /**
   * 通过系统视频选择器取视频。无需申请受限权限，安装即用。
   */
  static async pickVideos(maxCount: number): Promise<string[]> {
    const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE;
    options.maxSelectNumber = maxCount;
    const videoPicker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
    const result: photoAccessHelper.PhotoSelectResult = await videoPicker.select(options);
    return result.photoUris;
  }

  /**
   * 用文件选择器挑任意扩展名的视频文件（mkv/rmvb 等媒体库可能不收录的格式）。
   */
  static async pickVideoFiles(maxCount: number): Promise<string[]> {
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = maxCount;
    options.fileSuffixFilters = ['.mp4', '.mkv', '.avi', '.mov', '.flv', '.ts', '.webm', '.rmvb', '.m4v',
      '.3gp', '.wmv', '.mpg', '.mpeg'];
    const uris: string[] = await documentPicker.select(options);
    return uris;
  }

  /**
   * 持久化选择器返回 uri 的访问权限。
   * 不做持久授权的话，应用重启后这些 uri 就打不开了（播放侧表现为 5400102 / 打开失败）。
   */
  static async persistPermission(uris: string[]): Promise<void> {
    if (uris.length === 0) {
      return;
    }
    try {
      const policies: fileShare.PolicyInfo[] = [];
      for (let i = 0; i < uris.length; i++) {
        if (uris[i].startsWith('file://docs') || uris[i].startsWith('file://media')) {
          const policy: fileShare.PolicyInfo = {
            uri: uris[i],
            operationMode: fileShare.OperationMode.READ_MODE
          };
          policies.push(policy);
        }
      }
      if (policies.length === 0) {
        return;
      }
      await fileShare.persistPermission(policies);
      await fileShare.activatePermission(policies);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'persist permission failed code=%{public}d', e.code);
    }
  }

  /**
   * 把选择器 uri 复制进应用沙箱，返回沙箱内绝对路径。
   * 侧载应用拿不到 FILE_ACCESS_PERSIST（受限权限 + ACL），persistPermission 必然失败，
   * 系统 uri 重启后即失效——只有落在自己沙箱里的文件才长期可读，
   * 所以导入时就把视频复制一份进 filesDir/videos。
   */
  static async copyIntoApp(uri: string): Promise<string> {
    const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    const dir: string = `${context.filesDir}/videos`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'mkdir videos failed');
    }
    let raw: string = '';
    try {
      raw = new fileUri.FileUri(uri).name;
    } catch (err) {
      raw = fileNameOf(uri);
    }
    let name: string = decodeName(raw);
    // 沙箱文件名去掉路径分隔与非法字符，避免建文件失败
    name = name.replace(/[\\/:*?"<>|]/g, '_');
    if (name.length === 0) {
      name = `video_${Date.now()}.mp4`;
    }
    const dest: string = `${dir}/${name}`;
    try {
      if (fs.accessSync(dest)) {
        return dest;
      }
    } catch (err) {
    }
    let src: fs.File | undefined = undefined;
    try {
      src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      await fs.copyFile(src.fd, dest);
      return dest;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'copy into app failed code=%{public}d', e.code);
      throw new Error('copy failed');
    } finally {
      if (src !== undefined) {
        try {
          fs.closeSync(src);
        } catch (err) {
        }
      }
    }
  }

  /**
   * 读取单个视频的元信息（时长/分辨率/大小）。取不到时以 0 兜底，不阻断列表展示。
   */
  static async probe(uri: string): Promise<VideoItem> {
    let durationMs: number = 0;
    let width: number = 0;
    let height: number = 0;
    let mimeType: string = '';
    let size: number = 0;
    let extractor: media.AVMetadataExtractor | undefined = undefined;
    let file: fs.File | undefined = undefined;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        const st: fs.Stat = fs.statSync(file.fd);
        size = st.size;
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'stat failed');
      }
      extractor = await media.createAVMetadataExtractor();
      // length 传 0 会被当成空源，拿不到大小就只给 fd
      const fdSrc: media.AVFileDescriptor = size > 0
        ? { fd: file.fd, offset: 0, length: size }
        : { fd: file.fd };
      extractor.fdSrc = fdSrc;
      const meta: media.AVMetadata = await extractor.fetchMetadata();
      durationMs = meta.duration !== undefined ? Number(meta.duration) : 0;
      width = meta.videoWidth !== undefined ? Number(meta.videoWidth) : 0;
      height = meta.videoHeight !== undefined ? Number(meta.videoHeight) : 0;
      mimeType = meta.mimeType !== undefined ? meta.mimeType : '';
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'probe failed code=%{public}d msg=%{public}s', e.code, e.message);
    } finally {
      if (extractor !== undefined) {
        try {
          await extractor.release();
        } catch (err) {
        }
      }
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (err) {
        }
      }
    }
    // 名字优先走 FileUri.name（系统给的是解码后的真名），拿不到再回退 uri 解析
    let name: string = fileNameOf(uri);
    try {
      const picked: string = new fileUri.FileUri(uri).name;
      if (picked.length > 0 && picked.lastIndexOf('.') > 0) {
        name = decodeName(picked);
      }
    } catch (err) {
    }
    return new VideoItem(uri, stripExt(name), durationMs, size, width, height,
      folderNameOf(uri), mimeType, Date.now());
  }

  static async probeAll(uris: string[]): Promise<VideoItem[]> {
    const list: VideoItem[] = [];
    for (let i = 0; i < uris.length; i++) {
      const item: VideoItem = await MediaRepository.probe(uris[i]);
      list.push(item);
    }
    return list;
  }

  /**
   * 媒体库全量扫描视频。需要 ohos.permission.READ_IMAGEVIDEO（受限权限 + ACL）。
   * 未授权时抛错，由界面提示改走选择器。
   */
  static async scanMediaLibrary(): Promise<VideoItem[]> {
    const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(
      getContext() as common.UIAbilityContext);
    const cols: string[] = [
      photoAccessHelper.PhotoKeys.URI,
      photoAccessHelper.PhotoKeys.DISPLAY_NAME,
      photoAccessHelper.PhotoKeys.DURATION,
      photoAccessHelper.PhotoKeys.SIZE,
      photoAccessHelper.PhotoKeys.WIDTH,
      photoAccessHelper.PhotoKeys.HEIGHT,
      photoAccessHelper.PhotoKeys.DATE_MODIFIED
    ];
    const predicates: dataSharePredicates.DataSharePredicates = new dataSharePredicates.DataSharePredicates();
    predicates.equalTo(photoAccessHelper.PhotoKeys.PHOTO_TYPE, photoAccessHelper.PhotoType.VIDEO);
    predicates.orderByDesc(photoAccessHelper.PhotoKeys.DATE_MODIFIED);
    const options: photoAccessHelper.FetchOptions = {
      fetchColumns: cols,
      predicates: predicates
    };
    const resultSet: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset> = await helper.getAssets(options);
    const items: VideoItem[] = [];
    try {
      const assets: photoAccessHelper.PhotoAsset[] = await resultSet.getAllObjects();
      for (let i = 0; i < assets.length; i++) {
        const asset: photoAccessHelper.PhotoAsset = assets[i];
        const uri: string = asset.uri;
        const name: string = String(asset.get(photoAccessHelper.PhotoKeys.DISPLAY_NAME) ?? '');
        const durationMs: number = Number(asset.get(photoAccessHelper.PhotoKeys.DURATION) ?? 0);
        const size: number = Number(asset.get(photoAccessHelper.PhotoKeys.SIZE) ?? 0);
        const w: number = Number(asset.get(photoAccessHelper.PhotoKeys.WIDTH) ?? 0);
        const h: number = Number(asset.get(photoAccessHelper.PhotoKeys.HEIGHT) ?? 0);
        items.push(new VideoItem(uri, stripExt(name), durationMs, size, w, h,
          folderNameOf(uri), 'video/*', Number(asset.get(photoAccessHelper.PhotoKeys.DATE_MODIFIED) ?? 0)));
      }
    } finally {
      try {
        resultSet.close();
      } catch (err) {
      }
    }
    return items;
  }

  /**
   * Download 目录路径。需要受限权限 ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY（已在 AGC 过 ACL 审批）。
   * 设备不支持该 syscap 或未获授权时返回空串，由界面回退到选择器。
   */
  static downloadDir(): string {
    try {
      if (!canIUse(SYSCAP_FOLDER_OBTAIN)) {
        return '';
      }
      return Environment.getUserDownloadDir();
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'get download dir failed code=%{public}d', e.code);
      return '';
    }
  }

  /** 查询 Downloads 权限是否已真正授予（不触发弹窗，可安全用于诊断） */
  static hasDownloadPermission(): boolean {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const tokenId: number = info.appInfo.accessTokenId;
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const status: abilityAccessCtrl.GrantStatus =
        atManager.checkAccessTokenSync(tokenId, PERM_DOWNLOAD);
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'check download permission failed code=%{public}d', e.code);
      return false;
    }
  }

  /**
   * 向系统申请 Download 目录权限。
   * 返回 [错误码, authResults[0]]：错误码非 0 说明申请本身被拒（例如签名 profile 未包含该 ACL 权限），
   * 这种情况系统不会弹窗，必须换带 ACL 的签名 profile 重装。
   */
  static async requestDownloadPermission(): Promise<number[]> {
    try {
      const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const res: PermissionRequestResult =
        await atManager.requestPermissionsFromUser(context, [PERM_DOWNLOAD]) as PermissionRequestResult;
      const result: number = res.authResults.length > 0 ? res.authResults[0] : -1;
      hilog.info(DOMAIN, TAG, 'request download permission result=%{public}d', result);
      return [0, result];
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'request download permission failed code=%{public}d', e.code);
      return [e.code, -1];
    }
  }

  /**
   * 扫描 Download 目录并给出一份完整诊断。
   * 顺序：syscap -> 目录路径 -> 权限授予 -> 目录可访问 -> 目录可列举 -> 视频过滤，
   * 每一层都留下独立状态，界面可精确定位失败原因。
   */
  static async scanDownloadVideosReport(): Promise<DownloadScanReport> {
    const report: DownloadScanReport = new DownloadScanReport();
    report.syscap = canIUse(SYSCAP_FOLDER_OBTAIN);
    report.dir = MediaRepository.downloadDir();
    report.granted = MediaRepository.hasDownloadPermission();
    if (!report.granted) {
      const req: number[] = await MediaRepository.requestDownloadPermission();
      report.requestCode = req[0];
      report.requestResult = req[1];
      report.dir = MediaRepository.downloadDir();
      report.granted = MediaRepository.hasDownloadPermission();
    }
    if (report.dir.length === 0) {
      hilog.warn(DOMAIN, TAG, 'download dir empty syscap=%{public}s granted=%{public}s requestCode=%{public}d',
        String(report.syscap), String(report.granted), report.requestCode);
      return report;
    }
    try {
      fs.accessSync(report.dir);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      report.accessCode = e.code;
      hilog.warn(DOMAIN, TAG, 'access download dir failed code=%{public}d', e.code);
      return report;
    }
    const stats: WalkStats = new WalkStats();
    MediaRepository.walkVideos(report.dir, 1, report.videos, stats);
    report.listCode = stats.listCode;
    report.totalFiles = stats.total;
    hilog.info(DOMAIN, TAG,
      'download scan dir=%{public}s syscap=%{public}s granted=%{public}s access=%{public}d list=%{public}d total=%{public}d videos=%{public}d',
      report.dir, String(report.syscap), String(report.granted), report.accessCode, report.listCode,
      report.totalFiles, report.videos.length);
    return report;
  }

  private static walkVideos(dir: string, depthLeft: number, out: string[], stats: WalkStats): void {
    let names: string[] = [];
    try {
      names = fs.listFileSync(dir);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      if (stats.listCode === 0) {
        stats.listCode = e.code;
      }
      hilog.warn(DOMAIN, TAG, 'list download dir failed code=%{public}d path=%{public}s', e.code, dir);
      return;
    }
    for (let i = 0; i < names.length; i++) {
      if (out.length >= 2000) {
        return;
      }
      const full: string = `${dir}/${names[i]}`;
      let isDir: boolean = false;
      let size: number = 0;
      try {
        const st: fs.Stat = fs.statSync(full);
        isDir = st.isDirectory();
        size = st.size;
      } catch (err) {
        continue;
      }
      if (isDir) {
        if (depthLeft > 0) {
          MediaRepository.walkVideos(full, depthLeft - 1, out, stats);
        }
        continue;
      }
      stats.total++;
      if (size > 0 && isVideoName(names[i])) {
        out.push(full);
      }
    }
  }

  /**
   * 直接扫描 Download 目录里的视频（含一级子目录），返回绝对路径。
   * 这些路径在权限有效期内长期可读，不需要复制进沙箱。
   */
  static async scanDownloadVideos(): Promise<string[]> {
    const report: DownloadScanReport = await MediaRepository.scanDownloadVideosReport();
    return report.videos;
  }
}
