/**
 * 应用内运行日志（内存环形）
 *
 * 供「设置 → 关于 → 运行日志」查看与复制：手机上不方便接 logcat 时，
 * 用户可以直接在 App 里把最近的关键事件（播放开始/失败、音源请求发起/成功/失败、
 * 页面切换等）复制出来反馈。最多保留 MAX_LINES 条，超出后丢弃最旧的。
 *
 * 设计：纯静态、无任何外部依赖（不依赖页面/能力/设置），任何模块都能直接
 * AppLog.info/warn/error 写入；只进内存不落盘，进程被杀即清空。
 */
const MAX_LINES: number = 200;

/** 时间戳 + 级别 + 来源 tag + 消息，展示时拼成一行 */
interface LogEntry {
  time: string;
  level: string;
  tag: string;
  message: string;
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

function pad3(n: number): string {
  if (n < 10) {
    return `00${n}`;
  }
  if (n < 100) {
    return `0${n}`;
  }
  return `${n}`;
}

/** 本地时间 HH:mm:ss.SSS（不带日期，环形日志只关心最近几十分钟） */
function nowTime(): string {
  const d = new Date();
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}.${pad3(d.getMilliseconds())}`;
}

export class AppLog {
  private static lines: LogEntry[] = [];

  private static append(level: string, tag: string, message: string): void {
    const entry: LogEntry = { time: nowTime(), level: level, tag: tag, message: message };
    AppLog.lines.push(entry);
    if (AppLog.lines.length > MAX_LINES) {
      AppLog.lines.splice(0, AppLog.lines.length - MAX_LINES);
    }
  }

  static info(tag: string, message: string): void {
    AppLog.append('I', tag, message);
  }

  static warn(tag: string, message: string): void {
    AppLog.append('W', tag, message);
  }

  static error(tag: string, message: string): void {
    AppLog.append('E', tag, message);
  }

  /** 全部日志文本（最旧在前、最新在后），供关于页展示与复制 */
  static dump(): string {
    const out: string[] = [];
    for (const e of AppLog.lines) {
      out.push(`${e.time} [${e.level}] ${e.tag} ${e.message}`);
    }
    return out.join('\n');
  }

  static count(): number {
    return AppLog.lines.length;
  }

  static clear(): void {
    AppLog.lines = [];
  }
}
