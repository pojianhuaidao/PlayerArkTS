/**
 * 解析配置
 * type: 0=嗅探 1=json 2=Json扩展 3=聚合 4=超级解析
 */
export interface ParseBean {
  name: string;
  url: string;
  ext: string;
  type: number;
  isDefault: boolean;
}

export function createParseBean(): ParseBean {
  return { name: '', url: '', ext: '', type: 0, isDefault: false };
}
