/**
 * 分类数据模型
 */
import { AbsXml } from './Movie';

export interface SortFilter {
  key: string;
  name: string;
  values: Map<string, string>;
  init: string;
}

export interface SortData {
  id: string;
  name: string;
  sort: number;
  select: boolean;
  filters: SortFilter[];
  filterSelect: Map<string, string>;
  flag: string;
}

export interface MovieSort {
  sortList: SortData[];
}

export function createMovieSort(): MovieSort {
  return { sortList: [] };
}

export function createSortData(id: string, name: string): SortData {
  return {
    id, name, sort: -1, select: false,
    filters: [], filterSelect: new Map(), flag: ''
  };
}

export function filterSelectCount(sd: SortData): number {
  let count = 0;
  sd.filterSelect.forEach((v: string) => {
    if (v && v.length > 0) count++;
  });
  return count;
}

/** 根据源配置的分类排序 */
export function applyCategoryOrder(sort: MovieSort, categories: string[]): void {
  for (const sd of sort.sortList) {
    const idx = categories.indexOf(sd.name);
    sd.sort = idx >= 0 ? idx : 999;
  }
  sort.sortList.sort((a: SortData, b: SortData) => a.sort - b.sort);
}

/** 首页分类自定义排序：按保存的 id 顺序重排（未列出的保持原相对顺序，排在后面） */
export function applyCustomOrder(sortList: SortData[], orderIds: string[]): SortData[] {
  if (!orderIds || orderIds.length === 0) {
    return sortList;
  }
  const indexOfId = (id: string): number => {
    const i = orderIds.indexOf(id);
    return i >= 0 ? i : 999;
  };
  const copy: SortData[] = sortList.slice();
  copy.sort((a: SortData, b: SortData): number => {
    const ia = indexOfId(a.id);
    const ib = indexOfId(b.id);
    if (ia !== ib) {
      return ia - ib;
    }
    return sortList.indexOf(a) - sortList.indexOf(b);
  });
  return copy;
}
