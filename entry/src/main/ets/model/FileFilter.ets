/**
 * 网络源（SMB / WebDAV）目录条目过滤规则。
 *
 * NAS 的共享根目录里总混着一批系统自建项：fnOS 的 `.@#local`、群晖的 `@eaDir`、
 * 回收站 `$RECYCLE.BIN`、Windows 卷信息目录 `System Volume Information`、
 * macOS 的 `.DS_Store` / `._xxx` 等。它们既不是用户内容，也不可播放，
 * 直接列出来只会干扰选择，因此在解析阶段就丢弃（SMB 与 WebDAV 共用同一套规则）。
 */
export function isSystemHiddenName(rawName: string): boolean {
  const name: string = rawName.trim();
  if (name.length === 0) {
    return true;
  }
  if (name === '.' || name === '..') {
    return true;
  }
  // 点开头：.@#local / .DS_Store / ._资源分支 等隐藏项
  if (name.startsWith('.')) {
    return true;
  }
  // $ 开头：$RECYCLE.BIN（回收站）、$MFT 等 NTFS 元数据
  if (name.startsWith('$')) {
    return true;
  }
  // @ 开头：@eaDir（群晖缩略图）、@Recycle
  if (name.startsWith('@')) {
    return true;
  }
  const lower: string = name.toLowerCase();
  if (lower === 'system volume information') {
    return true;
  }
  if (lower === 'recycler' || lower === 'lost+found') {
    return true;
  }
  return false;
}
