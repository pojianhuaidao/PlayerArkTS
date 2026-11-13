/**
 * IJK 解码配置
 */
export interface IJKCode {
  name: string;
  options: Map<string, string>;
}

export function createIJKCode(name: string): IJKCode {
  return { name, options: new Map() };
}
