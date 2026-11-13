/**
 * PanResolver - 网盘直链统一入口
 * 用法：
 *   const res = await PanResolver.resolve(rawUrl);
 *   if (res.items.length > 0) 用 res.items[0].url / headers 起播
 *
 * URL 前缀路由：
 *   ali:// / alipan.com/s / aliyundrive.com/s -> AliClient
 *   quark:// / pan.quark.cn/s                -> QuarkClient(quark)
 *   uc://   / drive.uc.cn/s                  -> QuarkClient(uc)
 *   115://  / 115.com/s                      -> S115Client
 *   baidu:// / pan.baidu.com/s               -> BaiduClient
 */
import { PanClient, PanResolveResult, emptyResolveResult } from './PanTypes';
import { AliClient } from './AliClient';
import { QuarkClient } from './QuarkClient';
import { S115Client } from './S115Client';
import { BaiduClient } from './BaiduClient';

let clientsCache: PanClient[] | null = null;

function getClients(): PanClient[] {
  if (clientsCache !== null) return clientsCache;
  const list: PanClient[] = [];
  list.push(new AliClient());
  list.push(new QuarkClient('quark'));
  list.push(new QuarkClient('uc'));
  list.push(new S115Client());
  list.push(new BaiduClient());
  clientsCache = list;
  return list;
}

export class PanResolver {
  /** 是否为受支持的网盘 URL（判定路由，不发起网络请求） */
  static isPanUrl(rawUrl: string): boolean {
    if (rawUrl.length === 0) return false;
    const list = getClients();
    for (const c of list) {
      if (c.match(rawUrl)) return true;
    }
    return false;
  }

  /** 解析出可播放的直链；识别不到时返回 error */
  static async resolve(rawUrl: string): Promise<PanResolveResult> {
    if (rawUrl.length === 0) return emptyResolveResult('empty url');
    const list = getClients();
    for (const c of list) {
      if (c.match(rawUrl)) {
        try {
          return await c.resolve(rawUrl);
        } catch (e) {
          return emptyResolveResult((e as Error).message);
        }
      }
    }
    return emptyResolveResult('未识别的网盘链接：' + rawUrl);
  }
}