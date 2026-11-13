/**
 * PanTypes - 网盘直链解析统一契约
 *
 * 所有 Pan Client 都实现 PanClient 接口：给一个"识别 URL"，返回一个可播放的直链 + Header。
 * PanResolver.resolve(rawUrl) 会按前缀路由到对应 Client。
 */

/** 单个可播放清晰度/线路 */
export interface PanPlayItem {
  /** 展示名，如 "原画 4K"、"1080P"、"标清" */
  label: string;
  /** 直链（含短时签名） */
  url: string;
  /** 起播需要携带的 header（Referer / UA / Cookie 等） */
  headers: Map<string, string>;
}

/** 解析结果：一个网盘文件可能返回多路清晰度 */
export interface PanResolveResult {
  items: PanPlayItem[];
  /** 出错时的可读信息；items 为空且 error 非空视为失败 */
  error: string;
}

export function emptyResolveResult(err: string): PanResolveResult {
  return { items: [], error: err };
}

export function singleResolveResult(url: string, headers: Map<string, string>, label: string): PanResolveResult {
  const item: PanPlayItem = { label: label.length > 0 ? label : '原画', url, headers };
  return { items: [item], error: '' };
}

/** Pan Client 通用契约 */
export interface PanClient {
  /**
   * 判断给定 URL 是否属于本 Client。
   * 例：AliClient 匹配 aliyundrive://xxx / https://www.alipan.com/s/xxx 等
   */
  match(rawUrl: string): boolean;

  /** 解析出可播直链 */
  resolve(rawUrl: string): Promise<PanResolveResult>;
}
