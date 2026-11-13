/**
 * 视频源配置
 * type: 0=XML  1=JSON  3=Spider(JS/JAR/PY)  4=remote
 */
export interface SourceBean {
  key: string;
  name: string;
  api: string;
  type: number;
  searchable: number;
  quickSearch: number;
  filterable: number;
  playerUrl: string;
  ext: string;
  jar: string;
  categories: string[] | null;
  playerType: number;
  timeout: number;
  clickSelector: string;
  style: string;
}

export function emptySource(): SourceBean {
  return {
    key: '', name: '', api: '', type: 0,
    searchable: 0, quickSearch: 0, filterable: 0,
    playerUrl: '', ext: '', jar: '',
    categories: null, playerType: -1, timeout: 0,
    clickSelector: '', style: ''
  };
}

export function isSearchable(s: SourceBean): boolean {
  return s.searchable !== 0;
}

export function isQuickSearch(s: SourceBean): boolean {
  return s.quickSearch !== 0;
}

export function getPlayTimeoutSeconds(s: SourceBean): number {
  return s.timeout > 0 ? Math.max(5, Math.min(60, s.timeout)) : 15;
}
