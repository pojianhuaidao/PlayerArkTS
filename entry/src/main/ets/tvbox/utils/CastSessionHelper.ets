/**
 * CastSessionHelper - 鸿蒙官方投播(AVSessionKit)会话管理
 * 使用 AVSession + AVCastPicker 实现设备投屏，支持 DLNA、华为 Cast+ 等协议。
 */
import { avSession } from '@kit.AVSessionKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'CastSessionHelper';

export class CastSessionHelper {
  private session: avSession.AVSession | null = null;
  private castController: avSession.AVCastController | null = null;
  private queueItem: avSession.AVQueueItem | null = null;

  /** 投播是否活跃（设备已连接且正在投屏） */
  isCasting: boolean = false;

  onCastStateChange: ((state: string) => void) | null = null;

  /** 创建并激活 AVSession（已创建则跳过） */
  async ensure(context: common.UIAbilityContext): Promise<void> {
    if (this.session) {
      this.checkCurrentDevice();
      return;
    }
    try {
      this.session = await avSession.createAVSession(context, 'video_cast', 'video');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'createAVSession failed, try getAVSession: %{public}s', (e as Error).message);
      try {
        this.session = await avSession.getAVSession(context);
      } catch (e2) {
        hilog.error(DOMAIN, TAG, 'getAVSession also failed: %{public}s', (e2 as Error).message);
        return;
      }
    }
    try {
      await this.session.activate();
    } catch (_e) {}
    // 声明投播能力，使系统能发现 DLNA 等 url-cast 设备
    try {
      await this.session.setExtras({ requireAbilityList: ['url-cast'] });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setExtras failed: %{public}s', (e as Error).message);
    }
    // 设置启动 Ability，投屏时系统可拉起本应用
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      await this.session.setLaunchAbility(agent);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setLaunchAbility failed: %{public}s', (e as Error).message);
    }
    // 注册设备变更监听（两条路径统一注册）
    try {
      this.session.on('outputDeviceChange', (state: avSession.ConnectionState, device: avSession.OutputDeviceInfo): void => {
        const count = device.devices ? device.devices.length : 0;
        hilog.info(DOMAIN, TAG, 'outputDeviceChange state=%{public}d deviceCount=%{public}d', state, count);
        if (state === avSession.ConnectionState.STATE_CONNECTED) {
          this.isCasting = true;
          AppStorage.setOrCreate('isCasting', true);
          this.onCastStateChange?.('connected');
          this.startCast().catch((e: Object): void => { hilog.error(DOMAIN, TAG, 'startCast in listener failed: %{public}s', (e as Error).message); });
        } else {
          this.isCasting = false;
          AppStorage.setOrCreate('isCasting', false);
          this.setPlaying(false).catch((e: Object): void => { hilog.warn(DOMAIN, TAG, 'outputDeviceChange setPlaying(false) failed: %{public}s', (e as Error).message); });
          this.castController = null;
          this.onCastStateChange?.('disconnected');
        }
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'register outputDeviceChange failed: %{public}s', (e as Error).message);
    }
    // 检查是否已有设备连接（页面重建场景）
    this.checkCurrentDevice();
    hilog.info(DOMAIN, TAG, 'AVSession ready, isCasting=%{public}s', this.isCasting.toString());
  }

  /** 检查当前输出设备，若已连接则标记 isCasting */
  private async checkCurrentDevice(): Promise<void> {
    if (!this.session) return;
    try {
      const info = await this.session.getOutputDevice();
      if (info.devices && info.devices.length > 0) {
        this.isCasting = true;
        AppStorage.setOrCreate('isCasting', true);
        hilog.info(DOMAIN, TAG, 'checkCurrentDevice: already connected to %{public}d device(s)', info.devices.length);
        if (!this.castController) {
          this.startCast().catch((e: Object): void => { hilog.error(DOMAIN, TAG, 'startCast in check failed: %{public}s', (e as Error).message); });
        }
      }
    } catch (_e) {}
  }

  /** 更新媒体元数据（标题 + 封面 + 播放地址），投屏时使用 */
  async updateMetadata(title: string, mediaImage: string, subtitle: string, mediaUri: string): Promise<void> {
    if (!this.session) return;
    try {
      const metadata: avSession.AVMetadata = {
        assetId: '1',
        title: title,
        subtitle: subtitle,
        mediaImage: mediaImage,
        filter: avSession.ProtocolType.TYPE_DLNA
      };
      await this.session.setAVMetadata(metadata);
      await this.session.setAVQueueTitle(title);
      const description: avSession.AVMediaDescription = {
        assetId: '1',
        title: title,
        subtitle: subtitle,
        mediaImage: mediaImage,
        mediaUri: mediaUri,
        mediaType: 'VIDEO',
        startPosition: 0
      };
      this.queueItem = { itemId: 0, description: description };
      await this.session.setAVQueueItems([this.queueItem]);
      hilog.info(DOMAIN, TAG, 'updateMetadata ok uri=%{public}s', mediaUri);
      if (this.castController) {
        await this.startCast();
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'updateMetadata failed: %{public}s', (e as Error).message);
    }
  }

  /** 设备连接后获取 AVCastController 并发起投播 */
  private async startCast(): Promise<void> {
    if (!this.session || !this.queueItem) return;
    try {
      if (!this.castController) {
        this.castController = await this.session.getAVCastController();
        hilog.info(DOMAIN, TAG, 'getAVCastController ok');
      }
      await this.castController.prepare(this.queueItem);
      hilog.info(DOMAIN, TAG, 'castController.prepare ok');
      await this.castController.start(this.queueItem);
      hilog.info(DOMAIN, TAG, 'castController.start ok');
      await this.setPlaying(true);
      hilog.info(DOMAIN, TAG, 'startCast setPlaying(true) ok');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'startCast failed: %{public}s', (e as Error).message);
    }
  }

  /** 更新播放状态 */
  async setPlaying(playing: boolean): Promise<void> {
    if (!this.session) return;
    try {
      const state: avSession.AVPlaybackState = {
        state: playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE
      };
      await this.session.setAVPlaybackState(state);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'setPlaying failed: %{public}s', (e as Error).message);
    }
  }

  /** 释放资源（停止投屏、反激活、销毁会话） */
  async release(): Promise<void> {
    if (this.session) {
      try { await this.setPlaying(false); } catch (_e) {}
      hilog.info(DOMAIN, TAG, 'release: setPlaying(false) ok');
      try { await this.session.stopCasting(); } catch (_e) {}
      try { await this.session.deactivate(); } catch (_e) {}
      try { this.session.off('outputDeviceChange'); } catch (_e) {}
      try { await this.session.destroy(); } catch (_e) {}
      this.session = null;
      this.castController = null;
    }
    this.isCasting = false;
    AppStorage.setOrCreate('isCasting', false);
  }
}