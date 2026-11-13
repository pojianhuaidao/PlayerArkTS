/**
 * 直播频道数据模型
 */

/** 弹幕/catchup 配置 */
export interface CatchupConfig {
  type: string;
  source: string;
  replace: string;
}

/** 直播频道项 */
export class LiveChannelItem {
  channelIndex: number = 0;
  channelNum: number = 0;
  channelName: string = '';
  channelLogo: string = '';
  channelEpg: string = '';
  channelUa: string = '';
  channelClick: string = '';
  channelFormat: string = '';
  channelOrigin: string = '';
  channelReferer: string = '';
  channelTvgId: string = '';
  channelTvgName: string = '';
  channelCatchup: CatchupConfig | null = null;
  channelHeader: Map<string, string> = new Map();
  channelParse: number = 0;
  channelSourceNames: string[] = [];
  channelUrls: string[] = [];
  sourceIndex: number = 0;
  sourceNum: number = 0;
  includeBack: boolean = false;

  getUrl(): string {
    if (this.channelUrls.length > 0 && this.sourceIndex >= 0 && this.sourceIndex < this.channelUrls.length) {
      return this.channelUrls[this.sourceIndex];
    }
    return '';
  }

  nextSource(): void {
    this.sourceIndex++;
    if (this.sourceIndex >= this.sourceNum) {
      this.sourceIndex = 0;
    }
  }

  prevSource(): void {
    this.sourceIndex--;
    if (this.sourceIndex < 0) {
      this.sourceIndex = this.sourceNum - 1;
    }
  }

  getSourceName(): string {
    if (this.channelSourceNames.length > 0 && this.sourceIndex >= 0 && this.sourceIndex < this.channelSourceNames.length) {
      return this.channelSourceNames[this.sourceIndex];
    }
    return '';
  }

  isEmptyCatchup(): boolean {
    return this.channelCatchup === null;
  }
}

/** 直播频道分组 */
export class LiveChannelGroup {
  groupIndex: number = 0;
  groupName: string = '';
  groupPassword: string = '';
  liveChannelItems: LiveChannelItem[] = [];

  getLiveChannels(): LiveChannelItem[] {
    return this.liveChannelItems;
  }
}

/** 直播设置分组 */
export class LiveSettingGroup {
  groupIndex: number = 0;
  groupName: string = '';
  liveSettingItems: LiveSettingItem[] = [];
}

/** 直播设置项 */
export class LiveSettingItem {
  itemIndex: number = 0;
  itemName: string = '';
  itemSelected: boolean = false;
}

/** EPG 日期 */
export class LiveEpgDate {
  index: number = 0;
  datePresented: string = '';
  dateParamVal: number = 0;
}

/** EPG 节目信息 */
export interface EpgInfo {
  title: string;
  start: number;
  end: number;
  startStr: string;
  endStr: string;
}

/** 中间解析结构: 一个频道在 JSON 数组中的表示 */
export interface ParsedChannel {
  name: string;
  urls: string[];
  logo: string;
  epg: string;
  ua: string;
  click: string;
  format: string;
  origin: string;
  referer: string;
  tvgId: string;
  tvgName: string;
  tvgChno: string;
  parse: number;
  header: Record<string, string> | null;
  catchup: CatchupConfig | null;
}

/** 中间解析结构: 一个分组在 JSON 数组中的表示 */
export interface ParsedGroup {
  group: string;
  channels: ParsedChannel[];
}
