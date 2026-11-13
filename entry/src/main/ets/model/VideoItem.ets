/**
 * 媒体条目模型。承载列表与播放页需要的展示信息：
 * 缩略图、标题、时长、大小、分辨率、所在文件夹。
 */
import { util } from '@kit.ArkTS';

/** %XX 串按字节还原：先严格按 UTF-8，失败再按 GB18030（国内文件管理器给的多为 GBK 编码） */
function decodePercentBytes(raw: string): string {
  const bytes: number[] = [];
  for (let i = 0; i < raw.length; i++) {
    const ch: string = raw.charAt(i);
    if (ch === '%' && i + 2 < raw.length) {
      const v: number = parseInt(raw.substring(i + 1, i + 3), 16);
      if (!isNaN(v) && v >= 0) {
        bytes.push(v);
        i += 2;
        continue;
      }
    }
    const code: number = raw.charCodeAt(i);
    bytes.push(code < 256 ? code : 63);
  }
  const arr: Uint8Array = new Uint8Array(bytes);
  try {
    const utf8: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: true });
    const text: string = utf8.decodeToString(arr);
    if (text.indexOf('\uFFFD') < 0) {
      return text;
    }
  } catch (err) {
  }
  try {
    const gbk: util.TextDecoder = util.TextDecoder.create('gb18030');
    const text2: string = gbk.decodeToString(arr);
    if (text2.indexOf('\uFFFD') < 0) {
      return text2;
    }
  } catch (err) {
  }
  return raw;
}

/** UTF-8 字节被当成 latin1 显示的经典乱码（"ä¸­æ–‡"）还原 */
function decodeLatin1Utf8(raw: string): string {
  const bytes: number[] = [];
  for (let i = 0; i < raw.length; i++) {
    bytes.push(raw.charCodeAt(i) & 0xFF);
  }
  try {
    const dec: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: true });
    return dec.decodeToString(new Uint8Array(bytes));
  } catch (err) {
    return raw;
  }
}

export class VideoItem {
  uri: string;
  title: string;
  durationMs: number;
  sizeBytes: number;
  width: number;
  height: number;
  folder: string;
  mimeType: string;
  addedAt: number;
  /** 网络源附加请求头（如 WebDAV 的 Authorization），本地文件为空对象 */
  headers: Record<string, string>;

  constructor(uri: string, title: string, durationMs: number, sizeBytes: number,
    width: number, height: number, folder: string, mimeType: string, addedAt: number,
    headers?: Record<string, string>) {
    this.uri = uri;
    this.title = title;
    this.durationMs = durationMs;
    this.sizeBytes = sizeBytes;
    this.width = width;
    this.height = height;
    this.folder = folder;
    this.mimeType = mimeType;
    this.addedAt = addedAt;
    this.headers = headers !== undefined ? headers : {};
  }

  /** 列表副信息的时长格式：hh:mm:ss / mm:ss */
  durationText(): string {
    return formatDuration(this.durationMs);
  }

  sizeText(): string {
    return formatSize(this.sizeBytes);
  }

  resolutionText(): string {
    if (this.width > 0 && this.height > 0) {
      return `${this.width}×${this.height}`;
    }
    return '';
  }

  /** 列表第二行的元信息：时长 · 大小 · 分辨率 */
  metaLine(): string {
    const parts: string[] = [this.durationText()];
    if (this.sizeBytes > 0) {
      parts.push(this.sizeText());
    }
    const res: string = this.resolutionText();
    if (res.length > 0) {
      parts.push(res);
    }
    return parts.join(' · ');
  }
}

export function formatDuration(ms: number): string {
  if (ms <= 0 || !isFinite(ms)) {
    return '--:--';
  }
  const total: number = Math.floor(ms / 1000);
  const h: number = Math.floor(total / 3600);
  const m: number = Math.floor((total % 3600) / 60);
  const s: number = total % 60;
  const mm: string = m < 10 ? `0${m}` : `${m}`;
  const ss: string = s < 10 ? `0${s}` : `${s}`;
  if (h > 0) {
    const hh: string = h < 10 ? `0${h}` : `${h}`;
    return `${hh}:${mm}:${ss}`;
  }
  return `${mm}:${ss}`;
}

export function formatSize(bytes: number): string {
  if (bytes <= 0) {
    return '0 B';
  }
  const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];
  let value: number = bytes;
  let idx: number = 0;
  while (value >= 1024 && idx < units.length - 1) {
    value = value / 1024;
    idx++;
  }
  const fixed: string = value >= 100 ? value.toFixed(0) : value.toFixed(1);
  return `${fixed} ${units[idx]}`;
}

/**
 * uri 里的名字是 URL 转义过的（%E8%A7%86...），直接展示就是乱码。
 * 这里统一做一次安全解码：解不出（本身就是普通中文或非法转义）就原样返回。
 */
export function decodeName(raw: string): string {
  let name: string = raw;
  if (name.indexOf('%') >= 0) {
    let decoded: string = '';
    try {
      decoded = decodeURIComponent(name);
    } catch (err) {
      // 非法 UTF-8 转义（GBK 百分号串）→ 按字节还原
      decoded = decodePercentBytes(name);
    }
    name = decoded.length > 0 ? decoded : raw;
  }
  // 兜底：UTF-8 字节被当 latin1 显示的乱码
  if (/[\u00C0-\u00FF]{2,}/.test(name)) {
    const fixed: string = decodeLatin1Utf8(name);
    if (fixed.length > 0 && fixed.indexOf('\uFFFD') < 0) {
      name = fixed;
    }
  }
  return name;
}

/** 从 uri 或路径中截取上层目录名，用于"文件夹"分组标题 */
export function folderNameOf(path: string): string {
  const clean: string = decodeName(path.split('?')[0]);
  // 导入到应用沙箱的片子统一归到「本地导入」，不暴露 filesDir 的内部目录名
  if (clean.indexOf('/files/videos/') >= 0) {
    return '本地导入';
  }
  const idx: number = clean.lastIndexOf('/');
  if (idx <= 0) {
    return '根目录';
  }
  const dir: string = clean.substring(0, idx);
  const idx2: number = dir.lastIndexOf('/');
  const name: string = idx2 >= 0 ? dir.substring(idx2 + 1) : dir;
  return name.length > 0 ? name : '根目录';
}

/** 从路径取文件名（去掉扩展名由调用方决定） */
export function fileNameOf(path: string): string {
  const clean: string = decodeName(path.split('?')[0]);
  const segs: string[] = clean.split('/');
  let name: string = segs.length > 0 ? segs[segs.length - 1] : clean;
  // 媒体库 uri 形如 file://media/Photo/123/名字.mp4/名字.mp4，也有只到 file://media/Photo/123 的
  if (segs.length > 1 && (name.length === 0 || name.lastIndexOf('.') <= 0)) {
    const prev: string = segs[segs.length - 2];
    if (prev.length > 0 && prev.lastIndexOf('.') > 0) {
      name = prev;
    }
  }
  return name;
}

export function stripExt(name: string): string {
  const idx: number = name.lastIndexOf('.');
  return idx > 0 ? name.substring(0, idx) : name;
}
