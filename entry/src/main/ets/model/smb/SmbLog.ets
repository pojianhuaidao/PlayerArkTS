import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'SmbLog';

/**
 * SMB 诊断日志（1.1111.07 引入）
 *
 * 目的：SMB 连接失败时应用只拿得到「服务器关闭了连接」这种笼统文案，而 NAS 侧
 * 又没有任何登录记录，无法判断报文到底停在哪一步。这里把每一次请求/响应的
 * 阶段、长度、SMB2 Status、以及（截断的）原始字节落到沙箱文件里，用
 *   hdc file recv /data/app/el2/100/base/<包名>/haps/entry/files/logs/smb_YYYYMMDD.log
 * 取回即可看见协商/认证到底走完了多少字节。
 *
 * 开关：默认开；`SmbLog.setEnabled(false)` 可整体关掉（只影响文件写入与字节转储，
 * 关键阶段仍走 hilog）。
 * 落盘位置：`<filesDir>/logs/smb_YYYYMMDD.log`，单文件上限 2MB，超出后本次运行
 * 不再写入（避免把用户存储写满），仅保留 hilog。
 */
export class SmbLog {
  /** 是否写文件/转储字节 */
  private static enabled: boolean = true;
  /** 单文件上限 2MB */
  private static readonly MAX_BYTES: number = 2 * 1024 * 1024;
  /** 单次字节转储上限（避免长报文把日志撑爆） */
  private static readonly HEX_CAP: number = 256;
  private static baseDir: string = '';
  private static filePath: string = '';
  private static full: boolean = false;

  /** 由 UI 层调用：传入 context.filesDir，日志落到沙箱 files/logs 下 */
  static setBaseDir(filesDir: string): void {
    if (filesDir.length === 0) {
      return;
    }
    SmbLog.baseDir = filesDir;
    const dir: string = `${filesDir}/logs`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
    } catch (err) {
      // 目录已存在（Access 抛错）时忽略
    }
    SmbLog.filePath = `${dir}/smb_${SmbLog.dayStr()}.log`;
    SmbLog.full = false;
  }

  static setEnabled(on: boolean): void {
    SmbLog.enabled = on;
  }

  static isEnabled(): boolean {
    return SmbLog.enabled;
  }

  /** 日志文件绝对路径（未初始化时为空串，供 UI 提示用户去哪取） */
  static currentFilePath(): string {
    return SmbLog.filePath;
  }

  static info(tag: string, msg: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s %{public}s', tag, msg);
    SmbLog.append(tag, msg);
  }

  static warn(tag: string, msg: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s %{public}s', tag, msg);
    SmbLog.append(tag, `WARN ${msg}`);
  }

  /** 字节转储：前 HEX_CAP 字节的十六进制 + 总长度 */
  static dump(tag: string, label: string, data: Uint8Array): void {
    if (!SmbLog.enabled || data.length === 0) {
      return;
    }
    const n: number = data.length < SmbLog.HEX_CAP ? data.length : SmbLog.HEX_CAP;
    let hex: string = '';
    for (let i = 0; i < n; i++) {
      const v: number = data[i] & 0xff;
      hex += (v < 16 ? '0' : '') + v.toString(16);
      if ((i & 1) === 1) {
        hex += ' ';
      }
    }
    const tail: string = data.length > n ? ` ...(+${data.length - n}B)` : '';
    SmbLog.append(tag, `BUF ${label} len=${data.length} ${hex}${tail}`);
  }

  private static append(tag: string, msg: string): void {
    if (!SmbLog.enabled || SmbLog.full || SmbLog.filePath.length === 0) {
      return;
    }
    const line: string = `${SmbLog.nowStr()} [${tag}] ${msg}\n`;
    try {
      const st: fs.Stat = fs.statSync(SmbLog.filePath);
      if (st.size > SmbLog.MAX_BYTES) {
        SmbLog.full = true;
        return;
      }
    } catch (err) {
      // 文件还不存在：继续走创建分支
    }
    let file: fs.File | undefined = undefined;
    try {
      file = fs.openSync(SmbLog.filePath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      fs.writeSync(file.fd, line);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'write log failed');
    } finally {
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (err) {
        }
      }
    }
  }

  private static pad2(v: number): string {
    return v < 10 ? `0${v}` : `${v}`;
  }

  private static dayStr(): string {
    const d: Date = new Date();
    return `${d.getFullYear()}${SmbLog.pad2(d.getMonth() + 1)}${SmbLog.pad2(d.getDate())}`;
  }

  private static nowStr(): string {
    const d: Date = new Date();
    const ms: number = d.getMilliseconds();
    return `${d.getFullYear()}-${SmbLog.pad2(d.getMonth() + 1)}-${SmbLog.pad2(d.getDate())} ` +
      `${SmbLog.pad2(d.getHours())}:${SmbLog.pad2(d.getMinutes())}:${SmbLog.pad2(d.getSeconds())}.` +
      `${ms < 100 ? (ms < 10 ? '00' : '0') : ''}${ms}`;
  }
}
