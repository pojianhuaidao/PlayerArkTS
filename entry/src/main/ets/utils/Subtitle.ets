import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'Subtitle';
const DOMAIN: number = 0x0001;

/** 已上报过的「不支持标签」：同一进程内每个标签只记一次，避免逐帧刷日志 */
const reportedTags: Set<string> = new Set<string>();

/**
 * 一条字幕里的一段带样式文本。
 * SRT/VTT 整条字幕退化成单个 run（fontSizeRatio=0 表示用播放器默认字号）；
 * ASS/SSA 则由内联覆盖标签切出多段。
 */
export class SubtitleRun {
  text: string = '';
  /** '#RRGGBB'，空串表示跟随默认白 */
  color: string = '';
  /** 描边颜色 '#RRGGBB' */
  outlineColor: string = '#000000';
  /** 透明度 0~1（\fad / \alpha / \t 计算后的结果） */
  alpha: number = 1;
  /** 字号相对 PlayResY 的比例，0 表示用默认字号 */
  fontSizeRatio: number = 0;
  bold: boolean = false;
  italic: boolean = false;
  underline: boolean = false;
  /** 描边宽度相对 PlayResY 的比例 */
  outlineRatio: number = 0;
  /** 阴影距离相对 PlayResY 的比例 */
  shadowRatio: number = 0;
  /** \t 插值目标；渲染时按当前播放位置线性插值 */
  transitions: AssTransition[] = [];

  constructor(text: string) {
    this.text = text;
  }
}

/** \t(...) 过渡：只记录我们真正能渲染的属性 */
export class AssTransition {
  startMs: number = 0;
  endMs: number = 0;
  /** 目标颜色，空串表示不改 */
  color: string = '';
  /** 目标字号比例，0 表示不改 */
  fontSizeRatio: number = 0;
  /** 目标透明度，-1 表示不改 */
  alpha: number = -1;
  outlineRatio: number = -1;
  shadowRatio: number = -1;
}

/**
 * 统一字幕条目：SRT / WebVTT / ASS / SSA 共用。
 * ASS 专属字段在 SRT/VTT 下保持默认值（runs 为空、isAss=false）。
 */
export class SubtitleCue {
  startMs: number;
  endMs: number;
  /** 纯文本（已剥离所有覆盖标签），供 cueAt 与检索使用 */
  text: string;
  runs: SubtitleRun[] = [];
  isAss: boolean = false;
  /** \an1~\an9，默认 2（底部居中） */
  align: number = 2;
  /** \pos / \move 归一化到 0~1，-1 表示没有绝对定位 */
  posX: number = -1;
  posY: number = -1;
  moveX1: number = -1;
  moveY1: number = -1;
  moveX2: number = -1;
  moveY2: number = -1;
  moveStartMs: number = 0;
  moveEndMs: number = 0;
  /** \fad 淡入淡出时长 */
  fadeInMs: number = 0;
  fadeOutMs: number = 0;
  /** \frz 旋转角度 */
  rotate: number = 0;

  constructor(startMs: number, endMs: number, text: string) {
    this.startMs = startMs;
    this.endMs = endMs;
    this.text = text;
  }
}

/** 某一时刻解析好的字幕帧（交给渲染层直接画） */
export class SubtitleFrame {
  runs: SubtitleRun[] = [];
  opacity: number = 1;
  /** -1 表示无绝对定位 */
  xRatio: number = -1;
  yRatio: number = -1;
  align: number = 2;
  rotate: number = 0;
}

/** ASS 样式表里的一条样式（内部使用，字段已做归一化） */
class AssStyleDef {
  fontSizeRatio: number = 0.06;
  primaryColor: string = '#FFFFFF';
  outlineColor: string = '#000000';
  backColor: string = '#000000';
  bold: boolean = false;
  italic: boolean = false;
  underline: boolean = false;
  alignment: number = 2;
  marginL: number = 0;
  marginR: number = 0;
  marginV: number = 0;
  borderStyle: number = 1;
  outlineRatio: number = 0;
  shadowRatio: number = 0;
  scaleX: number = 100;
  scaleY: number = 100;
  spacing: number = 0;
  angle: number = 0;
  fontName: string = '';
}

/**
 * 字幕解析：SRT / WebVTT / ASS / SSA。
 * 解析入口统一走 parseText，按内容自动识别格式，多字幕源优先级保持不变。
 */
export class SubtitleParser {
  // ---------------- SRT / VTT ----------------

  static parseSrt(content: string): SubtitleCue[] {
    const cues: SubtitleCue[] = [];
    const blocks: string[] = content.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n\n');
    for (let i = 0; i < blocks.length; i++) {
      const lines: string[] = blocks[i].split('\n').filter((s: string) => s.trim().length > 0);
      if (lines.length < 2) {
        continue;
      }
      let timeIdx: number = -1;
      for (let j = 0; j < lines.length; j++) {
        if (lines[j].indexOf('-->') >= 0) {
          timeIdx = j;
          break;
        }
      }
      if (timeIdx < 0) {
        continue;
      }
      const range: string[] = lines[timeIdx].split('-->');
      if (range.length < 2) {
        continue;
      }
      const start: number = SubtitleParser.timeToMs(range[0].trim());
      const end: number = SubtitleParser.timeToMs(range[1].trim().split(' ')[0]);
      if (start < 0 || end <= start) {
        continue;
      }
      const textLines: string[] = [];
      for (let k = timeIdx + 1; k < lines.length; k++) {
        textLines.push(lines[k].replace(/<[^>]+>/g, '').replace(/\{[^}]+\}/g, ''));
      }
      const plain: string = textLines.join('\n');
      const cue: SubtitleCue = new SubtitleCue(start, end, plain);
      const run: SubtitleRun = new SubtitleRun(plain);
      cue.runs = [run];
      cues.push(cue);
    }
    cues.sort((a: SubtitleCue, b: SubtitleCue) => a.startMs - b.startMs);
    return cues;
  }

  static timeToMs(t: string): number {
    // 00:00:01,000 或 00:00:01.000 或 0:00:01.00
    const norm: string = t.replace(',', '.');
    const parts: string[] = norm.split(':');
    if (parts.length < 3) {
      return -1;
    }
    const h: number = Number(parts[0]);
    const m: number = Number(parts[1]);
    const secParts: string[] = parts[2].split('.');
    const s: number = Number(secParts[0]);
    const ms: number = secParts.length > 1 ? Number((secParts[1] + '000').substring(0, 3)) : 0;
    if (!isFinite(h) || !isFinite(m) || !isFinite(s) || !isFinite(ms)) {
      return -1;
    }
    return ((h * 3600 + m * 60 + s) * 1000) + ms;
  }

  /** 从沙箱/公共路径读取字幕：先 UTF-8，含替换符或为空时回退 GB18030（国内字幕站多为 GBK） */
  static async loadFromPath(path: string): Promise<SubtitleCue[]> {
    try {
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const size: number = fs.statSync(file.fd).size;
      const buf: ArrayBuffer = new ArrayBuffer(size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      const bytes: Uint8Array = new Uint8Array(buf);
      let content: string = '';
      try {
        content = util.TextDecoder.create('utf-8').decodeToString(bytes);
      } catch (err) {
        content = '';
      }
      if (content.length === 0 || content.indexOf('\uFFFD') >= 0) {
        try {
          content = util.TextDecoder.create('gb18030').decodeToString(bytes);
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'gb18030 decode unsupported');
        }
      }
      return SubtitleParser.parseText(content);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'read subtitle path failed');
      return [];
    }
  }

  /** 统一入口：自动识别 ASS/SSA 与 WebVTT，其余按 SRT 处理 */
  static parseText(raw: string): SubtitleCue[] {
    let content: string = raw;
    if (content.length === 0) {
      return [];
    }
    if (content.charCodeAt(0) === 0xFEFF) {
      content = content.substring(1);
    }
    if (SubtitleParser.isAss(content)) {
      return SubtitleParser.parseAss(content);
    }
    if (content.indexOf('WEBVTT') === 0) {
      content = content.replace(/^WEBVTT[^\n]*\n/, '');
      content = content.replace(/NOTE[\s\S]*?\n\n/g, '');
    }
    return SubtitleParser.parseSrt(content);
  }

  static async loadFromUri(uri: string): Promise<SubtitleCue[]> {
    try {
      const content: string = fs.readTextSync(uri);
      return SubtitleParser.parseText(content);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'read subtitle failed');
      return [];
    }
  }

  /** ASS/SSA 特征段：Script Info / V4+ Styles / V4 Styles / Events */
  static isAss(raw: string): boolean {
    return raw.indexOf('[Script Info]') >= 0 || raw.indexOf('[Events]') >= 0 ||
      raw.indexOf('[V4+ Styles]') >= 0 || raw.indexOf('[V4 Styles]') >= 0;
  }

  // ---------------- ASS / SSA ----------------

  private static defaultStyle(): AssStyleDef {
    const s: AssStyleDef = new AssStyleDef();
    s.fontSizeRatio = 0.06;
    s.primaryColor = '#FFFFFF';
    s.outlineColor = '#000000';
    s.alignment = 2;
    s.outlineRatio = 0.002;
    s.shadowRatio = 0;
    return s;
  }

  /** ASS 时间 0:00:01.23 / 1:02:03.45 */
  private static assTimeToMs(t: string): number {
    const s: string = t.trim();
    const parts: string[] = s.split(':');
    if (parts.length < 3) {
      return -1;
    }
    const h: number = Number(parts[0]);
    const m: number = Number(parts[1]);
    const secParts: string[] = parts[2].split('.');
    const sec: number = Number(secParts[0]);
    let cs: number = 0;
    if (secParts.length > 1) {
      cs = Number((secParts[1] + '00').substring(0, 2));
    }
    if (!isFinite(h) || !isFinite(m) || !isFinite(sec) || !isFinite(cs)) {
      return -1;
    }
    return ((h * 3600 + m * 60 + sec) * 1000) + cs * 10;
  }

  /** &HAABBGGRR / &HBBGGRR& / 十进制 BGR → '#RRGGBB' */
  private static assColor(raw: string): string {
    const src: string = raw.trim();
    if (src.length === 0) {
      return '';
    }
    let hex: string = src.replace(/&/g, '').replace(/[hH]/g, '');
    const isHex: boolean = /^[0-9a-fA-F]+$/.test(hex);
    if (!isHex) {
      const dec: number = Number(src);
      if (!isFinite(dec) || dec < 0) {
        return '';
      }
      hex = Math.floor(dec).toString(16);
    }
    while (hex.length < 6) {
      hex = '0' + hex;
    }
    if (hex.length > 8) {
      hex = hex.substring(hex.length - 8);
    }
    let bgr: string = hex;
    if (hex.length === 8) {
      // AABBGGRR：丢掉 AA
      bgr = hex.substring(2);
    }
    const bb: string = bgr.substring(0, 2);
    const gg: string = bgr.substring(2, 4);
    const rr: string = bgr.substring(4, 6);
    return `#${rr}${gg}${bb}`.toUpperCase();
  }

  /** &HAA& 透明度（AA 为「不透明度取反」） → 0~1 可见度 */
  private static assAlpha(raw: string): number {
    let hex: string = raw.replace(/&/g, '').replace(/[hH]/g, '');
    if (hex.length === 0) {
      return 1;
    }
    const v: number = parseInt(hex, 16);
    if (!isFinite(v)) {
      return 1;
    }
    return 1 - (v / 255);
  }

  static parseAss(raw: string): SubtitleCue[] {
    const content: string = raw.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    const lines: string[] = content.split('\n');
    const styles: Map<string, AssStyleDef> = new Map<string, AssStyleDef>();
    const cues: SubtitleCue[] = [];
    let playResX: number = 384;
    let playResY: number = 288;
    let section: string = '';
    let styleFields: string[] = [];
    let eventFields: string[] = [];

    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      if (line.charAt(0) === '[') {
        section = line.toLowerCase();
        continue;
      }
      const colon: number = line.indexOf(':');
      if (colon < 0) {
        continue;
      }
      const key: string = line.substring(0, colon).trim().toLowerCase();
      const payload: string = line.substring(colon + 1).trim();

      if (section === '[script info]') {
        if (key === 'playresx') {
          const v: number = Number(payload);
          if (isFinite(v) && v > 0) {
            playResX = v;
          }
        } else if (key === 'playresy') {
          const v: number = Number(payload);
          if (isFinite(v) && v > 0) {
            playResY = v;
          }
        }
        continue;
      }

      if (section === '[v4+ styles]' || section === '[v4 styles]') {
        if (key === 'format') {
          styleFields = SubtitleParser.splitFields(payload);
        } else if (key === 'style') {
          const style: AssStyleDef | undefined =
            SubtitleParser.parseStyleLine(payload, styleFields, playResX, playResY);
          if (style !== undefined) {
            const nameField: string = SubtitleParser.fieldOf(payload, styleFields, 'name', 'Default');
            styles.set(nameField.toLowerCase(), style);
          }
        }
        continue;
      }

      if (section === '[events]') {
        if (key === 'format') {
          eventFields = SubtitleParser.splitFields(payload);
        } else if (key === 'dialogue') {
          const cue: SubtitleCue | undefined =
            SubtitleParser.parseDialogueLine(payload, eventFields, styles, playResX, playResY);
          if (cue !== undefined) {
            cues.push(cue);
          }
        }
        continue;
      }
    }
    cues.sort((a: SubtitleCue, b: SubtitleCue) => {
      if (a.startMs !== b.startMs) {
        return a.startMs - b.startMs;
      }
      return a.startMs - b.startMs;
    });
    hilog.info(DOMAIN, TAG, 'ass parsed cues=%{public}d styles=%{public}d res=%{public}dx%{public}d',
      cues.length, styles.size, playResX, playResY);
    return cues;
  }

  private static splitFields(payload: string): string[] {
    const arr: string[] = payload.split(',');
    const out: string[] = [];
    for (let i = 0; i < arr.length; i++) {
      out.push(arr[i].trim().toLowerCase());
    }
    return out;
  }

  /** 按 Format 里的字段名取值（字段缺失时返回兜底值） */
  private static fieldOf(payload: string, fields: string[], name: string, fallback: string): string {
    const idx: number = fields.indexOf(name);
    if (idx < 0) {
      return fallback;
    }
    const parts: string[] = payload.split(',');
    if (idx >= parts.length) {
      return fallback;
    }
    return parts[idx].trim();
  }

  private static numOf(payload: string, fields: string[], name: string, fallback: number): number {
    const raw: string = SubtitleParser.fieldOf(payload, fields, name, '');
    if (raw.length === 0) {
      return fallback;
    }
    const v: number = Number(raw);
    return isFinite(v) ? v : fallback;
  }

  private static parseStyleLine(payload: string, fields: string[], playResX: number,
    playResY: number): AssStyleDef | undefined {
    if (fields.length === 0) {
      return undefined;
    }
    const style: AssStyleDef = SubtitleParser.defaultStyle();
    style.fontName = SubtitleParser.fieldOf(payload, fields, 'fontname', '');
    const size: number = SubtitleParser.numOf(payload, fields, 'fontsize', 0);
    if (size > 0) {
      style.fontSizeRatio = size / playResY;
    }
    const primary: string =
      SubtitleParser.assColor(SubtitleParser.fieldOf(payload, fields, 'primarycolour', '#FFFFFF'));
    if (primary.length > 0) {
      style.primaryColor = primary;
    }
    const outlineColor: string =
      SubtitleParser.assColor(SubtitleParser.fieldOf(payload, fields, 'outlinecolour', ''));
    if (outlineColor.length > 0) {
      style.outlineColor = outlineColor;
    }
    const backColor: string = SubtitleParser.assColor(SubtitleParser.fieldOf(payload, fields, 'backcolour', ''));
    if (backColor.length > 0) {
      style.backColor = backColor;
    }
    style.bold = SubtitleParser.numOf(payload, fields, 'bold', 0) !== 0;
    style.italic = SubtitleParser.numOf(payload, fields, 'italic', 0) !== 0;
    style.underline = SubtitleParser.numOf(payload, fields, 'underline', 0) !== 0;
    style.alignment = SubtitleParser.numOf(payload, fields, 'alignment', 2);
    style.marginL = SubtitleParser.numOf(payload, fields, 'marginl', 0);
    style.marginR = SubtitleParser.numOf(payload, fields, 'marginr', 0);
    style.marginV = SubtitleParser.numOf(payload, fields, 'marginv', 0);
    style.borderStyle = SubtitleParser.numOf(payload, fields, 'borderstyle', 1);
    const outline: number = SubtitleParser.numOf(payload, fields, 'outline', 0);
    if (outline > 0) {
      style.outlineRatio = outline / playResY;
    }
    const shadow: number = SubtitleParser.numOf(payload, fields, 'shadow', 0);
    if (shadow > 0) {
      style.shadowRatio = shadow / playResY;
    }
    style.scaleX = SubtitleParser.numOf(payload, fields, 'scalex', 100);
    style.scaleY = SubtitleParser.numOf(payload, fields, 'scaley', 100);
    style.spacing = SubtitleParser.numOf(payload, fields, 'spacing', 0);
    style.angle = SubtitleParser.numOf(payload, fields, 'angle', 0);
    // 归一化用不到 playResX，这里显式保留参数以便后续做 \pos 校验
    if (playResX <= 0) {
      hilog.warn(DOMAIN, TAG, 'invalid playresx');
    }
    return style;
  }

  private static parseDialogueLine(payload: string, fields: string[],
    styles: Map<string, AssStyleDef>, playResX: number, playResY: number): SubtitleCue | undefined {
    if (fields.length === 0) {
      return undefined;
    }
    const parts: string[] = payload.split(',');
    const textIdx: number = fields.indexOf('text');
    const startStr: string = SubtitleParser.fieldOf(payload, fields, 'start', '');
    const endStr: string = SubtitleParser.fieldOf(payload, fields, 'end', '');
    const startMs: number = SubtitleParser.assTimeToMs(startStr);
    const endMs: number = SubtitleParser.assTimeToMs(endStr);
    if (startMs < 0 || endMs <= startMs) {
      return undefined;
    }
    const styleName: string = SubtitleParser.fieldOf(payload, fields, 'style', 'Default');
    let style: AssStyleDef | undefined = styles.get(styleName.toLowerCase());
    if (style === undefined) {
      style = SubtitleParser.defaultStyle();
    }
    let rawText: string = '';
    if (textIdx >= 0 && textIdx < parts.length) {
      const slice: string[] = parts.slice(textIdx);
      rawText = slice.join(',');
    }
    const cue: SubtitleCue = new SubtitleCue(startMs, endMs, '');
    cue.isAss = true;
    cue.align = style.alignment;
    const build: SubtitleCue = cue;
    SubtitleParser.buildRuns(build, rawText, style, playResX, playResY);
    return cue;
  }

  /** 把 ASS 事件文本切成「带样式的 run 序列」，同时产出纯文本 */
  private static buildRuns(cue: SubtitleCue, rawText: string, style: AssStyleDef,
    playResX: number, playResY: number): void {
    const runs: SubtitleRun[] = [];
    let current: SubtitleRun = SubtitleParser.newRun(style);
    let plain: string = '';
    let i: number = 0;
    const text: string = rawText;
    while (i < text.length) {
      const ch: string = text.charAt(i);
      if (ch === '{') {
        const end: number = text.indexOf('}', i);
        if (end < 0) {
          const tail: string = SubtitleParser.cleanText(text.substring(i));
          current.text += tail;
          plain += tail;
          break;
        }
        const block: string = text.substring(i + 1, end);
        if (current.text.length > 0) {
          runs.push(current);
          current = SubtitleParser.newRun(style);
          SubtitleParser.copyStyle(runs[runs.length - 1], current);
        }
        SubtitleParser.applyTagBlock(cue, current, block, style, playResX, playResY);
        i = end + 1;
      } else {
        let next: number = text.indexOf('{', i);
        if (next < 0) {
          next = text.length;
        }
        const chunk: string = SubtitleParser.cleanText(text.substring(i, next));
        current.text += chunk;
        plain += chunk;
        i = next;
      }
    }
    if (current.text.length > 0) {
      runs.push(current);
    }
    if (runs.length === 0) {
      runs.push(SubtitleParser.newRun(style));
    }
    cue.runs = runs;
    cue.text = plain;
  }

  private static cleanText(src: string): string {
    return src.replace(/\\N/g, '\n').replace(/\\n/g, ' ').replace(/\\h/g, ' ');
  }

  private static newRun(style: AssStyleDef): SubtitleRun {
    const run: SubtitleRun = new SubtitleRun('');
    run.color = style.primaryColor;
    run.outlineColor = style.outlineColor;
    run.fontSizeRatio = style.fontSizeRatio;
    run.bold = style.bold;
    run.italic = style.italic;
    run.underline = style.underline;
    run.outlineRatio = style.outlineRatio;
    run.shadowRatio = style.shadowRatio;
    return run;
  }

  private static copyStyle(from: SubtitleRun, to: SubtitleRun): void {
    to.color = from.color;
    to.outlineColor = from.outlineColor;
    to.alpha = from.alpha;
    to.fontSizeRatio = from.fontSizeRatio;
    to.bold = from.bold;
    to.italic = from.italic;
    to.underline = from.underline;
    to.outlineRatio = from.outlineRatio;
    to.shadowRatio = from.shadowRatio;
  }

  private static cloneRun(from: SubtitleRun): SubtitleRun {
    const run: SubtitleRun = new SubtitleRun(from.text);
    SubtitleParser.copyStyle(from, run);
    run.transitions = from.transitions;
    return run;
  }

  private static reportUnsupported(tag: string): void {
    if (reportedTags.has(tag)) {
      return;
    }
    reportedTags.add(tag);
    hilog.info(DOMAIN, TAG,
      'unsupported ass tag %{public}s -> 降级为当前样式纯文本', tag);
  }

  /** 拆出 {\...} 里的单条标签（按反斜杠切，括号内不切） */
  private static splitTags(block: string): string[] {
    const out: string[] = [];
    let depth: number = 0;
    let start: number = -1;
    for (let i = 0; i < block.length; i++) {
      const ch: string = block.charAt(i);
      if (ch === '\\') {
        if (depth === 0) {
          if (start >= 0) {
            out.push(block.substring(start, i));
          }
          start = i + 1;
        }
        continue;
      }
      if (ch === '(') {
        depth++;
      } else if (ch === ')') {
        if (depth > 0) {
          depth--;
        }
      }
    }
    if (start >= 0 && start <= block.length) {
      out.push(block.substring(start));
    }
    const cleaned: string[] = [];
    for (let i = 0; i < out.length; i++) {
      const one: string = out[i].trim();
      if (one.length > 0) {
        cleaned.push(one);
      }
    }
    return cleaned;
  }

  private static tagName(tag: string): string {
    let i: number = 0;
    while (i < tag.length) {
      const ch: string = tag.charAt(i);
      const isAlpha: boolean = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
      if (!isAlpha) {
        break;
      }
      i++;
    }
    return tag.substring(0, i).toLowerCase();
  }

  private static parenContent(tag: string): string {
    const l: number = tag.indexOf('(');
    const r: number = tag.lastIndexOf(')');
    if (l < 0 || r <= l) {
      return '';
    }
    return tag.substring(l + 1, r);
  }

  private static applyTagBlock(cue: SubtitleCue, run: SubtitleRun, block: string,
    style: AssStyleDef, playResX: number, playResY: number): void {
    const tags: string[] = SubtitleParser.splitTags(block);
    for (let i = 0; i < tags.length; i++) {
      SubtitleParser.applyTag(cue, run, tags[i], style, playResX, playResY);
    }
  }

  private static applyTag(cue: SubtitleCue, run: SubtitleRun, tag: string, style: AssStyleDef,
    playResX: number, playResY: number): void {
    const name: string = SubtitleParser.tagName(tag);
    const rest: string = tag.substring(name.length).trim();
    switch (name) {
      case 'an': {
        const v: number = Number(rest);
        if (isFinite(v) && v >= 1 && v <= 9) {
          cue.align = Math.floor(v);
        }
        break;
      }
      case 'pos': {
        const nums: number[] = SubtitleParser.numbers(SubtitleParser.parenContent(tag));
        if (nums.length >= 2) {
          cue.posX = SubtitleParser.ratio(nums[0], playResX);
          cue.posY = SubtitleParser.ratio(nums[1], playResY);
        }
        break;
      }
      case 'move': {
        const nums: number[] = SubtitleParser.numbers(SubtitleParser.parenContent(tag));
        if (nums.length >= 4) {
          cue.moveX1 = SubtitleParser.ratio(nums[0], playResX);
          cue.moveY1 = SubtitleParser.ratio(nums[1], playResY);
          cue.moveX2 = SubtitleParser.ratio(nums[2], playResX);
          cue.moveY2 = SubtitleParser.ratio(nums[3], playResY);
          cue.moveStartMs = nums.length >= 6 ? nums[4] : 0;
          cue.moveEndMs = nums.length >= 6 ? nums[5] : (cue.endMs - cue.startMs);
        }
        break;
      }
      case 'fad': {
        const nums: number[] = SubtitleParser.numbers(SubtitleParser.parenContent(tag));
        if (nums.length >= 2) {
          cue.fadeInMs = nums[0];
          cue.fadeOutMs = nums[1];
        }
        break;
      }
      case 'fade': {
        const nums: number[] = SubtitleParser.numbers(SubtitleParser.parenContent(tag));
        if (nums.length >= 7) {
          cue.fadeInMs = nums[3];
          cue.fadeOutMs = Math.max(0, nums[6] - nums[5]);
        }
        break;
      }
      case 'fs': {
        if (rest.length > 0) {
          const rel: boolean = rest.charAt(0) === '+' || rest.charAt(0) === '-';
          const v: number = Number(rest);
          if (isFinite(v)) {
            const basePx: number = (rel ? run.fontSizeRatio * playResY : 0) + v;
            if (basePx > 0) {
              run.fontSizeRatio = basePx / playResY;
            }
          }
        }
        break;
      }
      case 'c':
      case '1c': {
        const color: string = SubtitleParser.assColor(rest);
        if (color.length > 0) {
          run.color = color;
        }
        break;
      }
      case '3c': {
        const color: string = SubtitleParser.assColor(rest);
        if (color.length > 0) {
          run.outlineColor = color;
        }
        break;
      }
      case 'alpha':
      case '1a': {
        run.alpha = SubtitleParser.assAlpha(rest);
        break;
      }
      case 'b': {
        const v: number = Number(rest);
        run.bold = isFinite(v) ? v !== 0 : true;
        break;
      }
      case 'i': {
        const v: number = Number(rest);
        run.italic = isFinite(v) ? v !== 0 : true;
        break;
      }
      case 'u': {
        const v: number = Number(rest);
        run.underline = isFinite(v) ? v !== 0 : true;
        break;
      }
      case 'bord': {
        const v: number = Number(rest);
        if (isFinite(v) && v >= 0) {
          run.outlineRatio = v / playResY;
        }
        break;
      }
      case 'shad': {
        const v: number = Number(rest);
        if (isFinite(v) && v >= 0) {
          run.shadowRatio = v / playResY;
        }
        break;
      }
      case 'frz': {
        const v: number = Number(rest);
        if (isFinite(v)) {
          cue.rotate = v;
        }
        break;
      }
      case 'r': {
        const target: string = rest.trim();
        const base: AssStyleDef = SubtitleParser.defaultStyle();
        const reset: SubtitleRun = SubtitleParser.newRun(base);
        if (target.length === 0) {
          const styled: SubtitleRun = SubtitleParser.newRun(style);
          SubtitleParser.copyStyle(styled, run);
        } else {
          SubtitleParser.copyStyle(reset, run);
        }
        break;
      }
      case 't': {
        SubtitleParser.applyTransition(run, SubtitleParser.parenContent(tag), playResY);
        break;
      }
      case 'fn': {
        // 字体名无法在当前渲染层替换内置字体族，按降级处理
        SubtitleParser.reportUnsupported('\\fn');
        break;
      }
      case 'clip':
      case 'iclip':
      case 'k':
      case 'K':
      case 'kf':
      case 'ko':
      case 'p':
      case 'org':
      case 'blur':
      case 'be':
      case 'fscx':
      case 'fscy':
      case 'fax':
      case 'fay':
      case 'frx':
      case 'fry':
      case 'xbord':
      case 'ybord':
      case 'xshad':
      case 'yshad':
      case 'q':
      case 'fe':
      case '2c':
      case '4c':
      case '2a':
      case '3a':
      case '4a': {
        SubtitleParser.reportUnsupported(`\\${name}`);
        break;
      }
      default: {
        if (name.length > 0) {
          SubtitleParser.reportUnsupported(`\\${name}`);
        }
        break;
      }
    }
  }

  private static ratiosInTransition(tagsRaw: string, playResY: number): number[] {
    const nums: number[] = SubtitleParser.numbers(tagsRaw);
    const out: number[] = [];
    for (let i = 0; i < nums.length; i++) {
      out.push(nums[i] / playResY);
    }
    return out;
  }

  /** \t([t1,t2,]accel,tags...)：只解析我们能插值的属性 */
  private static applyTransition(run: SubtitleRun, content: string, playResY: number): void {
    if (content.length === 0) {
      return;
    }
    let rest: string = content;
    let startMs: number = 0;
    let endMs: number = 0;
    // 前导数字（t1,t2,accel）与标签以第一个反斜杠为界
    const slash: number = content.indexOf('\\');
    let head: string = slash >= 0 ? content.substring(0, slash) : content;
    rest = slash >= 0 ? content.substring(slash) : '';
    head = head.replace(/[()]/g, '');
    const nums: number[] = SubtitleParser.numbers(head);
    if (nums.length >= 2) {
      startMs = nums[0];
      endMs = nums[1];
    } else if (nums.length === 1) {
      // 只给了 accel，没有时间区间：整条字幕内插值
      startMs = 0;
      endMs = 0;
    }
    const tr: AssTransition = new AssTransition();
    tr.startMs = startMs;
    tr.endMs = endMs;
    const tags: string[] = SubtitleParser.splitTags(rest);
    for (let i = 0; i < tags.length; i++) {
      const tag: string = tags[i];
      const name: string = SubtitleParser.tagName(tag);
      const value: string = tag.substring(name.length).trim();
      if (name === 'c' || name === '1c') {
        const color: string = SubtitleParser.assColor(value);
        if (color.length > 0) {
          tr.color = color;
        }
      } else if (name === 'fs') {
        const v: number = Number(value);
        if (isFinite(v) && v > 0) {
          tr.fontSizeRatio = v / playResY;
        }
      } else if (name === 'alpha' || name === '1a') {
        tr.alpha = SubtitleParser.assAlpha(value);
      } else if (name === 'bord') {
        const v: number = Number(value);
        if (isFinite(v) && v >= 0) {
          tr.outlineRatio = v / playResY;
        }
      } else if (name === 'shad') {
        const v: number = Number(value);
        if (isFinite(v) && v >= 0) {
          tr.shadowRatio = v / playResY;
        }
      } else if (name.length > 0) {
        SubtitleParser.reportUnsupported(`\\t(\\${name})`);
      }
    }
    run.transitions = run.transitions.concat([tr]);
  }

  private static ratio(value: number, total: number): number {
    if (!isFinite(value) || total <= 0) {
      return -1;
    }
    return value / total;
  }

  /** 抓取一串数字（用于 \pos(x,y) / \fad(a,b) / \t(...) 等） */
  private static numbers(src: string): number[] {
    const out: number[] = [];
    let buf: string = '';
    for (let i = 0; i < src.length; i++) {
      const ch: string = src.charAt(i);
      const isNum: boolean = (ch >= '0' && ch <= '9') || ch === '-' || ch === '+' || ch === '.';
      if (isNum) {
        buf += ch;
      } else if (buf.length > 0) {
        const v: number = Number(buf);
        if (isFinite(v)) {
          out.push(v);
        }
        buf = '';
      }
    }
    if (buf.length > 0) {
      const v: number = Number(buf);
      if (isFinite(v)) {
        out.push(v);
      }
    }
    return out;
  }

  // ---------------- 查询与渲染快照 ----------------

  /** 找到当前时刻命中的字幕条目（二分），供需要样式的渲染层使用 */
  static cueObjectAt(cues: SubtitleCue[], positionMs: number): SubtitleCue | undefined {
    if (cues.length === 0) {
      return undefined;
    }
    let lo: number = 0;
    let hi: number = cues.length - 1;
    let hit: number = -1;
    while (lo <= hi) {
      const mid: number = (lo + hi) >> 1;
      if (cues[mid].startMs <= positionMs) {
        hit = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (hit < 0) {
      return undefined;
    }
    const c: SubtitleCue = cues[hit];
    return positionMs <= c.endMs ? c : undefined;
  }

  /** 按当前播放位置把 \t / \fad / \move 解成可直接渲染的一帧 */
  static frameAt(cue: SubtitleCue, positionMs: number): SubtitleFrame {
    const frame: SubtitleFrame = new SubtitleFrame();
    const t: number = positionMs - cue.startMs;
    let opacity: number = 1;
    if (cue.fadeInMs > 0 && t < cue.fadeInMs) {
      opacity = Math.max(0, t / cue.fadeInMs);
    }
    const tail: number = cue.endMs - positionMs;
    if (cue.fadeOutMs > 0 && tail < cue.fadeOutMs) {
      opacity = Math.min(opacity, Math.max(0, tail / cue.fadeOutMs));
    }
    frame.opacity = Math.min(1, Math.max(0, opacity));
    frame.align = cue.align;
    frame.rotate = cue.rotate;
    if (cue.posX >= 0) {
      frame.xRatio = cue.posX;
      frame.yRatio = cue.posY;
    } else if (cue.moveX1 >= 0) {
      const span: number = cue.moveEndMs > cue.moveStartMs ? cue.moveEndMs - cue.moveStartMs : 0;
      let p: number = 1;
      if (span > 0) {
        p = Math.min(1, Math.max(0, (t - cue.moveStartMs) / span));
      }
      frame.xRatio = cue.moveX1 + (cue.moveX2 - cue.moveX1) * p;
      frame.yRatio = cue.moveY1 + (cue.moveY2 - cue.moveY1) * p;
    }
    const runs: SubtitleRun[] = [];
    for (let i = 0; i < cue.runs.length; i++) {
      runs.push(SubtitleParser.resolveRun(cue.runs[i], t));
    }
    frame.runs = runs;
    return frame;
  }

  private static resolveRun(run: SubtitleRun, tMs: number): SubtitleRun {
    const out: SubtitleRun = SubtitleParser.cloneRun(run);
    for (let i = 0; i < run.transitions.length; i++) {
      const tr: AssTransition = run.transitions[i];
      if (tMs < tr.startMs) {
        continue;
      }
      const span: number = tr.endMs > tr.startMs ? tr.endMs - tr.startMs : 0;
      const p: number = span > 0 ? Math.min(1, Math.max(0, (tMs - tr.startMs) / span)) : 1;
      if (tr.color.length > 0) {
        out.color = SubtitleParser.mixColor(out.color, tr.color, p);
      }
      if (tr.fontSizeRatio > 0) {
        out.fontSizeRatio = out.fontSizeRatio + (tr.fontSizeRatio - out.fontSizeRatio) * p;
      }
      if (tr.alpha >= 0) {
        out.alpha = out.alpha + (tr.alpha - out.alpha) * p;
      }
      if (tr.outlineRatio >= 0) {
        out.outlineRatio = out.outlineRatio + (tr.outlineRatio - out.outlineRatio) * p;
      }
      if (tr.shadowRatio >= 0) {
        out.shadowRatio = out.shadowRatio + (tr.shadowRatio - out.shadowRatio) * p;
      }
    }
    return out;
  }

  private static mixColor(from: string, to: string, p: number): string {
    if (from.length !== 7 || to.length !== 7) {
      return to;
    }
    const fr: number = parseInt(from.substring(1, 3), 16);
    const fg: number = parseInt(from.substring(3, 5), 16);
    const fb: number = parseInt(from.substring(5, 7), 16);
    const tr: number = parseInt(to.substring(1, 3), 16);
    const tg: number = parseInt(to.substring(3, 5), 16);
    const tb: number = parseInt(to.substring(5, 7), 16);
    if (!isFinite(fr) || !isFinite(tr)) {
      return to;
    }
    const r: number = Math.round(fr + (tr - fr) * p);
    const g: number = Math.round(fg + (tg - fg) * p);
    const b: number = Math.round(fb + (tb - fb) * p);
    return `#${SubtitleParser.hex2(r)}${SubtitleParser.hex2(g)}${SubtitleParser.hex2(b)}`;
  }

  /** 单通道转两位大写十六进制 */
  private static hex2(c: number): string {
    const s: string = c.toString(16).toUpperCase();
    return s.length < 2 ? `0${s}` : s;
  }

  /** 按当前播放位置查字幕文本，二分查找（纯文本，SRT/VTT/ASS 通用） */
  static cueAt(cues: SubtitleCue[], positionMs: number): string {
    const c: SubtitleCue | undefined = SubtitleParser.cueObjectAt(cues, positionMs);
    return c !== undefined ? c.text : '';
  }
}
