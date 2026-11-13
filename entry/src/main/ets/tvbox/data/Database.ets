/**
 * 数据库层 - 基于 @ohos.data.relationalStore
 * 
 * 历史记录、收藏管理
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const DB_NAME = 'kandianshi.db';

const SQL_CREATE_HISTORY = `CREATE TABLE IF NOT EXISTS history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  vodId TEXT NOT NULL,
  sourceKey TEXT NOT NULL,
  name TEXT,
  pic TEXT,
  epName TEXT,
  epIndex INTEGER DEFAULT 0,
  flag TEXT,
  updateTime INTEGER,
  duration INTEGER DEFAULT 0,
  position INTEGER DEFAULT 0,
  watchedEps TEXT DEFAULT '',
  epProgress TEXT DEFAULT '',
  UNIQUE(vodId, sourceKey)
)`;

// 老库缺失字段时自动追加
const SQL_MIGRATE_HISTORY_WATCHED = `ALTER TABLE history ADD COLUMN watchedEps TEXT DEFAULT ''`;
const SQL_MIGRATE_HISTORY_EPPROG = `ALTER TABLE history ADD COLUMN epProgress TEXT DEFAULT ''`;

const SQL_CREATE_COLLECT = `CREATE TABLE IF NOT EXISTS collect (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  vodId TEXT NOT NULL,
  sourceKey TEXT NOT NULL,
  name TEXT,
  pic TEXT,
  updateTime INTEGER,
  UNIQUE(vodId, sourceKey)
)`;

let rdbStore: relationalStore.RdbStore | null = null;

async function getStore(): Promise<relationalStore.RdbStore> {
  if (rdbStore) return rdbStore;
  const context = getContext() as common.UIAbilityContext;
  const config: relationalStore.StoreConfig = {
    name: DB_NAME,
    securityLevel: relationalStore.SecurityLevel.S1
  };
  rdbStore = await relationalStore.getRdbStore(context, config);
  await rdbStore.execute(SQL_CREATE_HISTORY);
  await rdbStore.execute(SQL_CREATE_COLLECT);
  try { await rdbStore.execute(SQL_MIGRATE_HISTORY_WATCHED); } catch (_e) {}
  try { await rdbStore.execute(SQL_MIGRATE_HISTORY_EPPROG); } catch (_e) {}
  return rdbStore;
}

export interface HistoryRecord {
  id?: number;
  vodId: string;
  sourceKey: string;
  name: string;
  pic: string;
  epName: string;
  epIndex: number;
  flag: string;
  updateTime: number;
  duration: number;
  position: number;
  watchedEps?: string;
  epProgress?: string;
}

export interface CollectRecord {
  id?: number;
  vodId: string;
  sourceKey: string;
  name: string;
  pic: string;
  updateTime: number;
}

export class HistoryRepository {
  static async save(record: HistoryRecord): Promise<void> {
    const store = await getStore();
    const now = Date.now();
    const values: relationalStore.ValuesBucket = {
      vodId: record.vodId,
      sourceKey: record.sourceKey,
      name: record.name,
      pic: record.pic,
      epName: record.epName,
      epIndex: record.epIndex,
      flag: record.flag,
      updateTime: record.updateTime || now,
      duration: record.duration,
      position: record.position,
      watchedEps: record.watchedEps ?? '',
      epProgress: record.epProgress ?? ''
    };
    const predicates = new relationalStore.RdbPredicates('history');
    predicates.equalTo('vodId', record.vodId);
    predicates.equalTo('sourceKey', record.sourceKey);
    const rows = await store.update(values, predicates);
    if (rows === 0) {
      await store.insert('history', values);
    }
  }

  static async getAll(limit: number = 50): Promise<HistoryRecord[]> {
    const store = await getStore();
    const predicates = new relationalStore.RdbPredicates('history');
    predicates.orderByDesc('updateTime');
    predicates.limitAs(limit);
    const resultSet = await store.query(predicates, [
      'id', 'vodId', 'sourceKey', 'name', 'pic', 'epName', 'epIndex', 'flag', 'updateTime', 'duration', 'position', 'watchedEps', 'epProgress'
    ]);
    const list: HistoryRecord[] = [];
    while (resultSet.goToNextRow()) {
      list.push({
        id: resultSet.getLong(resultSet.getColumnIndex('id')),
        vodId: resultSet.getString(resultSet.getColumnIndex('vodId')),
        sourceKey: resultSet.getString(resultSet.getColumnIndex('sourceKey')),
        name: resultSet.getString(resultSet.getColumnIndex('name')),
        pic: resultSet.getString(resultSet.getColumnIndex('pic')),
        epName: resultSet.getString(resultSet.getColumnIndex('epName')),
        epIndex: resultSet.getLong(resultSet.getColumnIndex('epIndex')),
        flag: resultSet.getString(resultSet.getColumnIndex('flag')),
        updateTime: resultSet.getLong(resultSet.getColumnIndex('updateTime')),
        duration: resultSet.getLong(resultSet.getColumnIndex('duration')),
        position: resultSet.getLong(resultSet.getColumnIndex('position')),
        watchedEps: resultSet.getString(resultSet.getColumnIndex('watchedEps')),
        epProgress: resultSet.getString(resultSet.getColumnIndex('epProgress'))
      });
    }
    resultSet.close();
    return list;
  }

  static async get(vodId: string, sourceKey: string): Promise<HistoryRecord | null> {
    const store = await getStore();
    const predicates = new relationalStore.RdbPredicates('history');
    predicates.equalTo('vodId', vodId);
    predicates.equalTo('sourceKey', sourceKey);
    const resultSet = await store.query(predicates, [
      'id', 'vodId', 'sourceKey', 'name', 'pic', 'epName', 'epIndex', 'flag', 'updateTime', 'duration', 'position', 'watchedEps', 'epProgress'
    ]);
    let record: HistoryRecord | null = null;
    if (resultSet.goToNextRow()) {
      record = {
        id: resultSet.getLong(resultSet.getColumnIndex('id')),
        vodId: resultSet.getString(resultSet.getColumnIndex('vodId')),
        sourceKey: resultSet.getString(resultSet.getColumnIndex('sourceKey')),
        name: resultSet.getString(resultSet.getColumnIndex('name')),
        pic: resultSet.getString(resultSet.getColumnIndex('pic')),
        epName: resultSet.getString(resultSet.getColumnIndex('epName')),
        epIndex: resultSet.getLong(resultSet.getColumnIndex('epIndex')),
        flag: resultSet.getString(resultSet.getColumnIndex('flag')),
        updateTime: resultSet.getLong(resultSet.getColumnIndex('updateTime')),
        duration: resultSet.getLong(resultSet.getColumnIndex('duration')),
        position: resultSet.getLong(resultSet.getColumnIndex('position')),
        watchedEps: resultSet.getString(resultSet.getColumnIndex('watchedEps')),
        epProgress: resultSet.getString(resultSet.getColumnIndex('epProgress'))
      };
    }
    resultSet.close();
    return record;
  }

  static async delete(vodId: string, sourceKey: string): Promise<void> {
    const store = await getStore();
    const predicates = new relationalStore.RdbPredicates('history');
    predicates.equalTo('vodId', vodId);
    predicates.equalTo('sourceKey', sourceKey);
    await store.delete(predicates);
  }

  static async clearAll(): Promise<void> {
    const store = await getStore();
    await store.delete(new relationalStore.RdbPredicates('history'));
  }

  static async updateProgress(vodId: string, sourceKey: string, position: number, duration: number): Promise<void> {
    const store = await getStore();
    const values: relationalStore.ValuesBucket = {
      position: position,
      duration: duration,
      updateTime: Date.now()
    };
    const predicates = new relationalStore.RdbPredicates('history');
    predicates.equalTo('vodId', vodId);
    predicates.equalTo('sourceKey', sourceKey);
    await store.update(values, predicates);
  }
}

export class CollectRepository {
  static async add(record: CollectRecord): Promise<void> {
    const store = await getStore();
    const values: relationalStore.ValuesBucket = {
      vodId: record.vodId,
      sourceKey: record.sourceKey,
      name: record.name,
      pic: record.pic,
      updateTime: record.updateTime || Date.now()
    };
    const predicates = new relationalStore.RdbPredicates('collect');
    predicates.equalTo('vodId', record.vodId);
    predicates.equalTo('sourceKey', record.sourceKey);
    const rows = await store.update(values, predicates);
    if (rows === 0) {
      await store.insert('collect', values);
    }
  }

  static async remove(vodId: string, sourceKey: string): Promise<void> {
    const store = await getStore();
    const predicates = new relationalStore.RdbPredicates('collect');
    predicates.equalTo('vodId', vodId);
    predicates.equalTo('sourceKey', sourceKey);
    await store.delete(predicates);
  }

  static async getAll(): Promise<CollectRecord[]> {
    const store = await getStore();
    const predicates = new relationalStore.RdbPredicates('collect');
    predicates.orderByDesc('updateTime');
    const resultSet = await store.query(predicates, ['id', 'vodId', 'sourceKey', 'name', 'pic', 'updateTime']);
    const list: CollectRecord[] = [];
    while (resultSet.goToNextRow()) {
      list.push({
        id: resultSet.getLong(resultSet.getColumnIndex('id')),
        vodId: resultSet.getString(resultSet.getColumnIndex('vodId')),
        sourceKey: resultSet.getString(resultSet.getColumnIndex('sourceKey')),
        name: resultSet.getString(resultSet.getColumnIndex('name')),
        pic: resultSet.getString(resultSet.getColumnIndex('pic')),
        updateTime: resultSet.getLong(resultSet.getColumnIndex('updateTime'))
      });
    }
    resultSet.close();
    return list;
  }

  static async has(vodId: string, sourceKey: string): Promise<boolean> {
    const store = await getStore();
    const predicates = new relationalStore.RdbPredicates('collect');
    predicates.equalTo('vodId', vodId);
    predicates.equalTo('sourceKey', sourceKey);
    const resultSet = await store.query(predicates, ['id']);
    const has = resultSet.goToNextRow();
    resultSet.close();
    return has;
  }

  static async clearAll(): Promise<void> {
    const store = await getStore();
    await store.delete(new relationalStore.RdbPredicates('collect'));
  }
}