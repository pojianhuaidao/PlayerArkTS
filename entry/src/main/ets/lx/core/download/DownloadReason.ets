/**
 * 访问公共「下载」目录失败原因的统一口径
 *
 * 为什么单独放一个文件：同一条权限链上有两个功能在报错 —— 音乐下载
 * （DownloadManager.openPublicDownload）和视频「从 Download 目录导入」
 * （MediaRepository.scanDownloadVideosReport + Index.reportDownloadFailure）。
 * 两边各写一套文案的结果是：同一个错误码，音乐说「没有读写权限」、视频说
 * 「权限未授予（申请结果 -1）」，用户对不上号。这里按「失败的节点」分层出结论，
 * 两边都只调这一个函数，文案天然一致。
 *
 * 分层顺序与检查顺序一致：
 *   能力（syscap）-> 授权（granted / 申请错误码 / 申请结果）-> 打开目录 -> 列目录 -> 文件数
 */

/** 「下载」目录读写权限名（受限权限，提示语里要写出来，统一从这儿取） */
export const DOWNLOAD_PERM_NAME: string = 'READ_WRITE_DOWNLOAD_DIRECTORY';

/** 一次诊断的结论：给人看的一句话 + 是不是「功能不可用」（不是「目录里没文件」） */
export class AccessReason {
  /** 给人看的一句话原因 */
  text: string = '';
  /**
   * 是不是卡在能力/权限这一步（true：功能不可用，该给「改用文件选择器」的出口；
   * false：链路是通的，只是目录里没有能识别的文件）
   */
  blocked: boolean = true;
}

/**
 * 按失败节点给出一句话原因
 *
 * @param syscap        本机是否具备 FolderObtain 能力
 * @param granted       权限是否已真正授予
 * @param requestCode   requestPermissionsFromUser 抛错时的错误码（0 表示没抛错）
 * @param requestResult authResults[0]（0 授予 / -1 拒绝 / 其它系统值）
 * @param accessCode    fs.accessSync 打开目录的错误码（0 表示可访问）
 * @param listCode      fs.listFileSync 列目录的错误码（0 表示可读取）
 * @param totalFiles    扫描到的文件总数（只在最后一步兜底时用于说明）
 */
export function accessReasonOf(syscap: boolean, granted: boolean, requestCode: number,
  requestResult: number, accessCode: number, listCode: number, totalFiles: number): AccessReason {
  const out: AccessReason = new AccessReason();
  if (!syscap) {
    out.text = '本机不支持直接读取公共「下载」目录（缺少 FolderObtain 能力）';
    out.blocked = true;
    return out;
  }
  if (!granted) {
    if (requestCode !== 0) {
      // 受限权限（ACL）在 profile 里没配时，申请环节就被系统拦下，连弹窗机会都没有
      out.text = `申请「下载」目录读写权限失败（错误码 ${requestCode}）：签名 profile 里没有 `
        + `${DOWNLOAD_PERM_NAME} 的 ACL，受限权限申请直接被系统拦下，换签名包前重试也没有用`;
    } else if (requestResult === -1) {
      out.text = `「下载」目录读写权限未授予（你点了拒绝；受限权限还需要签名 profile 带 `
        + `${DOWNLOAD_PERM_NAME} 的 ACL 才会弹窗）`;
    } else {
      out.text = `「下载」目录读写权限未授予（申请结果 ${requestResult}）`;
    }
    out.blocked = true;
    return out;
  }
  if (accessCode !== 0) {
    out.text = `已拿到授权，但打不开公共「下载」目录（错误码 ${accessCode}）：目录可能不存在，或被系统策略限制`;
    out.blocked = true;
    return out;
  }
  if (listCode !== 0) {
    out.text = `已拿到授权，但列不出公共「下载」目录的内容（错误码 ${listCode}）`;
    out.blocked = true;
    return out;
  }
  out.text = `公共「下载」目录可以读，但里面没有能识别的文件（已扫描 ${totalFiles} 个文件）`;
  out.blocked = false;
  return out;
}

/**
 * 把下载四级兜底各层的原因串成一句话（写进下载记录的 note，用户点开就能看到卡在哪层）
 *
 * 空串表示这一层没有失败（或者根本没走），直接跳过，避免出现「权限直写：；复用已存位置：」这种空壳。
 */
export function joinLayerReasons(direct: string, reused: string, picker: string): string {
  const parts: string[] = [];
  if (direct.length > 0) {
    parts.push(`权限直写：${direct}`);
  }
  if (reused.length > 0) {
    parts.push(`复用已存位置：${reused}`);
  }
  if (picker.length > 0) {
    parts.push(`系统下载目录：${picker}`);
  }
  return parts.join('；');
}
