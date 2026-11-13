import { NetEntry } from './NetClient';

/**
 * 网络源浏览态内存快照。
 *
 * 背景：视频页在「上下半屏同屏（stacked）」与「整页 Swiper（paged）」两种形态间由
 * 内容高度自动切换，两种形态各挂一个 NetPanel 实例；形态一旦切换，ArkUI 会销毁旧实例
 * 并新建另一个，组件内部的 @State（协议、地址、当前目录、条目、状态文案）全部丢失，
 * 表现为：点进上一级/子目录后界面突然回到「待连接」，WebDAV 会话被清空。
 *
 * 这里把跨重建需要保留的字段放进进程内存快照：实例销毁前写入，重建时读回。
 */
export class NetNavSnapshot {
  valid: boolean = false;
  proto: number = 0;
  address: string = '';
  currentUrl: string = '';
  status: string = '';
  entries: NetEntry[] = [];
  davUser: string = '';
  davPass: string = '';
}

export class NetNavStore {
  private static snap: NetNavSnapshot = new NetNavSnapshot();

  static save(snap: NetNavSnapshot): void {
    NetNavStore.snap = snap;
  }

  static peek(): NetNavSnapshot {
    return NetNavStore.snap;
  }

  /** 主动退出浏览（回服务器列表）时清空，避免下次进页看到陈旧目录 */
  static clear(): void {
    NetNavStore.snap = new NetNavSnapshot();
  }
}
