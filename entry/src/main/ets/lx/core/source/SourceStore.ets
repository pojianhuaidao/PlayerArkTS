import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SourceInfo } from './LxTypes';
import { storageRootDir } from '../common/StoragePaths';

const DOMAIN: number = 0x0001;
const TAG: string = 'SourceStore';

const STORE_DIR: string = 'lx_sources';
const INDEX_FILE: string = 'sources.json';
/** 上次成功加载的音源（重启后自动恢复，省得每次都去音源设置里点一次） */
const ACTIVE_FILE: string = 'active_source.json';

export interface ActiveSource {
  id: string;
  /** 加载时用的沙箱环境（mobile / desktop），恢复时要按同一个来 */
  env: string;
  loadedAt: number;
}

/** 音源备份包：索引 + 每个源的脚本正文 + 上次加载的源（用于华为云端备份 / 恢复） */
export interface SourceBundle {
  sources: SourceInfo[];
  scripts: Record<string, string>;
  active: ActiveSource | null;
}

/**
 * 音源持久化
 *
 * 对应上游的 utils/data.ts：
 *   - userApis 列表 + 每个源的脚本体，分别存储
 *
 * 差异：HarmonyOS 的 preferences 对字符串长度有限制，而源脚本可能达到数 MB，
 * 因此这里把「脚本正文」落到应用沙箱文件，索引仍然是一个 JSON 文件。
 */
export class SourceStore {
  private dir: string = '';
  private indexFile: string = '';
  private ready: boolean = false;

  init(context: common.Context): void {
    this.dir = `${storageRootDir(context)}/${STORE_DIR}`;
    this.indexFile = `${this.dir}/${INDEX_FILE}`;
    try {
      if (!fs.accessSync(this.dir)) {
        fs.mkdirSync(this.dir);
      }
      this.ready = true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'failed to create store dir: %{public}s', JSON.stringify(e));
      this.ready = false;
    }
  }

  isReady(): boolean {
    return this.ready;
  }

  private scriptPath(id: string): string {
    return `${this.dir}/script_${id}.js`;
  }

  list(): SourceInfo[] {
    if (!this.ready || !fs.accessSync(this.indexFile)) {
      return [];
    }
    try {
      const text: string = fs.readTextSync(this.indexFile);
      return JSON.parse(text) as SourceInfo[];
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'failed to read source index: %{public}s', JSON.stringify(e));
      return [];
    }
  }

  find(id: string): SourceInfo | null {
    const list: SourceInfo[] = this.list();
    for (const item of list) {
      if (item.id === id) {
        return item;
      }
    }
    return null;
  }

  private saveIndex(list: SourceInfo[]): void {
    if (!this.ready) {
      throw new Error('音源存储未初始化');
    }
    const file = fs.openSync(this.indexFile, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify(list));
    } finally {
      fs.closeSync(file);
    }
  }

  /** 保存脚本正文 */
  private saveScript(id: string, script: string): void {
    const file = fs.openSync(this.scriptPath(id), fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, script);
    } finally {
      fs.closeSync(file);
    }
  }

  getScript(id: string): string {
    const path: string = this.scriptPath(id);
    if (!fs.accessSync(path)) {
      throw new Error(`音源脚本不存在: ${id}`);
    }
    return fs.readTextSync(path);
  }

  /** 脚本是否存在（去重时读旧脚本做比对，文件不在就当内容不同） */
  hasScript(id: string): boolean {
    try {
      return fs.accessSync(this.scriptPath(id));
    } catch (e) {
      return false;
    }
  }

  add(info: SourceInfo, script: string): SourceInfo {
    const list: SourceInfo[] = this.list();
    list.push(info);
    this.saveScript(info.id, script);
    this.saveIndex(list);
    return info;
  }

  /**
   * 覆盖更新一个已存在的源：id 不变（播放列表/已加载引用不会失效），
   * 脚本正文与元信息都用新的，importedAt 刷新。
   */
  replace(id: string, info: SourceInfo, script: string): SourceInfo {
    const list: SourceInfo[] = this.list();
    const next: SourceInfo[] = [];
    let updated: SourceInfo = info;
    for (const item of list) {
      if (item.id === id) {
        updated = {
          id: id,
          name: info.name,
          description: info.description,
          version: info.version,
          author: info.author,
          homepage: info.homepage,
          allowShowUpdateAlert: info.allowShowUpdateAlert,
          importedAt: Date.now(),
        };
        next.push(updated);
      } else {
        next.push(item);
      }
    }
    this.saveScript(id, script);
    this.saveIndex(next);
    return updated;
  }

  remove(ids: string[]): SourceInfo[] {
    const list: SourceInfo[] = this.list();
    const remains: SourceInfo[] = [];
    for (const item of list) {
      if (ids.includes(item.id)) {
        const path: string = this.scriptPath(item.id);
        try {
          if (fs.accessSync(path)) {
            fs.unlinkSync(path);
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'failed to delete script %{public}s', item.id);
        }
      } else {
        remains.push(item);
      }
    }
    this.saveIndex(remains);
    return remains;
  }

  // ------------------------------------------------------------ 上次加载的音源

  private activePath(): string {
    return `${this.dir}/${ACTIVE_FILE}`;
  }

  /** 记下「这次用的是哪个源」；写失败只记日志，不影响加载本身 */
  saveActive(id: string, env: string): void {
    if (!this.ready) {
      return;
    }
    const active: ActiveSource = { id: id, env: env, loadedAt: Date.now() };
    try {
      const path: string = this.activePath();
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(active));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to save active source: %{public}s', JSON.stringify(e));
    }
  }

  loadActive(): ActiveSource | null {
    if (!this.ready) {
      return null;
    }
    try {
      const path: string = this.activePath();
      if (!fs.accessSync(path)) {
        return null;
      }
      return JSON.parse(fs.readTextSync(path)) as ActiveSource;
    } catch (e) {
      return null;
    }
  }

  clearActive(): void {
    if (!this.ready) {
      return;
    }
    try {
      const path: string = this.activePath();
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to clear active source: %{public}s', JSON.stringify(e));
    }
  }

  // ------------------------------------------------------------ 备份 / 恢复

  /** 导出全部音源（索引 + 每个源的脚本正文 + 上次加载的源），用于云端备份 */
  exportBundle(): SourceBundle {
    const sources: SourceInfo[] = this.list();
    const scripts: Record<string, string> = {};
    for (let i = 0; i < sources.length; i++) {
      const id: string = sources[i].id;
      try {
        scripts[id] = this.getScript(id);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'export script failed: %{public}s', id);
      }
    }
    let active: ActiveSource | null = null;
    try {
      active = this.loadActive();
    } catch (e) {
      active = null;
    }
    return { sources: sources, scripts: scripts, active: active };
  }

  /**
   * 导入音源备份：逐源覆盖写入（已有同 id 覆盖，没有则新增），
   * 并恢复「上次加载的源」记录；@returns 恢复的源数量
   */
  importBundle(bundle: SourceBundle): number {
    const sources: SourceInfo[] = bundle.sources !== undefined && bundle.sources !== null ? bundle.sources : [];
    let count: number = 0;
    for (let i = 0; i < sources.length; i++) {
      const info: SourceInfo = sources[i];
      const script: string = bundle.scripts[info.id];
      if (script === undefined || script === null || script.length === 0) {
        continue;
      }
      try {
        if (this.find(info.id) !== null) {
          this.replace(info.id, info, script);
        } else {
          this.add(info, script);
        }
        count++;
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'import source failed: %{public}s', info.id);
      }
    }
    if (bundle.active !== null && bundle.active !== undefined) {
      this.saveActive(bundle.active.id, bundle.active.env);
    }
    return count;
  }
}
