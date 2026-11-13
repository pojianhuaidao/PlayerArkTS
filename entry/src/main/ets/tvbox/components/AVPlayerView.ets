/**
 * AVPlayerView - 基于 AVPlayer + XComponent 的视频播放组件
 * 替代 ArkUI Video 组件，支持自定义 HTTP Header
 * 解决 Video 组件无法设置 Referer/User-Agent 导致播放2秒停止的问题
 */
import { media } from '@kit.MediaKit';

/** 播放器回调接口 */
export interface AVPlayerCallback {
  onStart: () => void;
  onPause: () => void;
  onFinish: () => void;
  onError: (errorMsg: string) => void;
  onTimeUpdate: (currentTime: number) => void;
  onDurationUpdate: (duration: number) => void;
  onPrepared: () => void;
  onBuffering: (isBuffering: boolean) => void;
}

/** 播放速度映射 */
function speedToPlaybackSpeed(speed: number): media.PlaybackSpeed {
  switch (speed) {
    case 0.5: return media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
    case 0.75: return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    case 1.0: return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    case 1.25: return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    case 1.5: return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
    case 1.75: return media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    case 2.0: return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
    case 3.0: return media.PlaybackSpeed.SPEED_FORWARD_3_00_X;
    default: return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
  }
}

@Component
export struct AVPlayerView {
  @Prop videoSrc: string = '';
  @Prop videoHeaders: Map<string, string> = new Map();
  @Prop autoPlay: boolean = true;
  @Prop scaleType: number = 0;
  private xComponentController: XComponentController = new XComponentController();
  private avPlayer: media.AVPlayer | null = null;
  private surfaceId: string = '';
  private callback: AVPlayerCallback | null = null;
  @State private isPrepared: boolean = false;
  @State private hasError: boolean = false;
  private currentSpeed: number = 1.0;
  private pendingSeek: number = -1;

  aboutToAppear() {
    this.initPlayer();
  }

  aboutToDisappear() {
    this.releasePlayer();
  }

  /** 设置回调 */
  setCallback(cb: AVPlayerCallback): void {
    this.callback = cb;
  }

  /** 初始化 AVPlayer */
  private async initPlayer(): Promise<void> {
    try {
      this.avPlayer = await media.createAVPlayer();
      this.setupEventListeners();
    } catch (e) {
      console.error('[AVPlayerView] createAVPlayer failed: ' + (e as Error).message);
      if (this.callback) {
        this.callback.onError('创建播放器失败: ' + (e as Error).message);
      }
    }
  }

  /** 设置事件监听 */
  private setupEventListeners(): void {
    if (!this.avPlayer) return;
    const player = this.avPlayer;

    player.on('stateChange', (state: string, reason: media.StateChangeReason) => {
      console.info('[AVPlayerView] stateChange: ' + state + ', reason: ' + String(reason));
      switch (state) {
        case 'initialized':
          if (this.surfaceId.length > 0) {
            player.surfaceId = this.surfaceId;
          }
          player.prepare().then(() => {
            console.info('[AVPlayerView] prepare success');
          }).catch((err: Error) => {
            console.error('[AVPlayerView] prepare failed: ' + err.message);
            if (this.callback) {
              this.callback.onError('准备失败: ' + err.message);
            }
          });
          break;
        case 'prepared':
          this.isPrepared = true;
          this.hasError = false;
          if (this.pendingSeek >= 0) {
            player.seek(this.pendingSeek);
            this.pendingSeek = -1;
          }
          if (this.currentSpeed !== 1.0) {
            player.setSpeed(speedToPlaybackSpeed(this.currentSpeed));
          }
          if (this.callback) {
            this.callback.onPrepared();
          }
          if (this.autoPlay) {
            player.play().then(() => {
              console.info('[AVPlayerView] play success');
              if (this.callback) {
                this.callback.onStart();
              }
            }).catch((err: Error) => {
              console.error('[AVPlayerView] play failed: ' + err.message);
              if (this.callback) {
                this.callback.onError('播放失败: ' + err.message);
              }
            });
          }
          break;
        case 'playing':
          if (this.callback) {
            this.callback.onStart();
          }
          break;
        case 'paused':
          if (this.callback) {
            this.callback.onPause();
          }
          break;
        case 'completed':
          if (this.callback) {
            this.callback.onFinish();
          }
          break;
        case 'stopped':
          break;
        case 'released':
          break;
        case 'error':
          console.error('[AVPlayerView] player error state, reason: ' + reason);
          this.hasError = true;
          if (this.callback) {
            this.callback.onError('播放错误');
          }
          break;
        default:
          break;
      }
    });

    player.on('error', (err: Error) => {
      const errObj = err as Record<string, Object>;
      const code = errObj['code'] !== undefined ? String(errObj['code']) : '';
      const msg = errObj['message'] !== undefined ? String(errObj['message']) : err.message;
      console.error('[AVPlayerView] error: code=' + code + ' message=' + msg);
      this.hasError = true;
      if (this.callback) {
        this.callback.onError('播放错误: ' + msg);
      }
    });

    player.on('timeUpdate', (time: number) => {
      if (this.callback) {
        this.callback.onTimeUpdate(time);
      }
    });

    player.on('durationUpdate', (duration: number) => {
      if (this.callback) {
        this.callback.onDurationUpdate(duration);
      }
    });

    player.on('startRenderFrame', () => {
      console.info('[AVPlayerView] startRenderFrame');
    });

    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
      if (this.callback) {
        this.callback.onBuffering(infoType === media.BufferingInfoType.BUFFERING_START);
      }
    });
  }

  /** 加载视频源 - 支持自定义 Header */
  async loadSource(url: string, headers: Map<string, string>): Promise<void> {
    if (!this.avPlayer || url.length === 0) return;

    console.info('[AVPlayerView] loadSource: ' + url);
    console.info('[AVPlayerView] headers count: ' + headers.size);

    try {
      // 如果有自定义 header，使用 MediaSource
      if (headers.size > 0) {
        const headerRecord: Record<string, string> = {};
        headers.forEach((v: string, k: string) => {
          headerRecord[k] = v;
          console.info('[AVPlayerView] header: ' + k + '=' + v);
        });

        // 先重置到 idle 状态
        if (this.avPlayer.state !== 'idle') {
          await this.avPlayer.reset();
        }

        // 创建带 header 的 MediaSource
        const mediaSource: media.MediaSource = media.createMediaSourceWithUrl(url, headerRecord);

        // 设置 mimeType 为 m3u8（如果是 m3u8 链接）
        const lowerUrl: string = url.toLowerCase();
        if (lowerUrl.includes('.m3u8') || lowerUrl.includes('m3u8')) {
          mediaSource.setMimeType(media.AVMimeTypes.APPLICATION_M3U8);
        }

        // 使用 setMediaSource 设置源
        await this.avPlayer.setMediaSource(mediaSource);
      } else {
        // 无 header，直接设置 URL
        if (this.avPlayer.state !== 'idle') {
          await this.avPlayer.reset();
        }
        this.avPlayer.url = url;
      }
    } catch (e) {
      console.error('[AVPlayerView] loadSource failed: ' + (e as Error).message);
      // 降级：直接设置 URL
      try {
        if (this.avPlayer.state !== 'idle') {
          await this.avPlayer.reset();
        }
        this.avPlayer.url = url;
      } catch (e2) {
        if (this.callback) {
          this.callback.onError('加载视频失败: ' + (e2 as Error).message);
        }
      }
    }
  }

  /** 播放 */
  play(): void {
    if (this.avPlayer && this.isPrepared) {
      this.avPlayer.play().catch((err: Error) => {
        console.error('[AVPlayerView] play error: ' + err.message);
      });
    }
  }

  /** 暂停 */
  pause(): void {
    if (this.avPlayer && this.isPrepared) {
      this.avPlayer.pause().catch((err: Error) => {
        console.error('[AVPlayerView] pause error: ' + err.message);
      });
    }
  }

  /** 停止 */
  stop(): void {
    if (this.avPlayer) {
      this.avPlayer.stop().then(() => {
        console.info('[AVPlayerView] stop success');
      }).catch((err: Error) => {
        console.error('[AVPlayerView] stop error: ' + err.message);
      });
      this.isPrepared = false;
    }
  }

  /** 跳转 */
  seek(timeMs: number): void {
    if (this.avPlayer && this.isPrepared) {
      this.avPlayer.seek(timeMs);
    } else {
      this.pendingSeek = timeMs;
    }
  }

  /** 设置播放速度 */
  setSpeed(speed: number): void {
    this.currentSpeed = speed;
    if (this.avPlayer && this.isPrepared) {
      this.avPlayer.setSpeed(speedToPlaybackSpeed(speed));
    }
  }

  /** 设置音量 */
  setVolume(volume: number): void {
    if (this.avPlayer) {
      this.avPlayer.setVolume(volume);
    }
  }

  /** 释放播放器 */
  releasePlayer(): void {
    if (this.avPlayer) {
      try {
        this.avPlayer.release();
      } catch (_e) {}
      this.avPlayer = null;
    }
  }

  /** 重置播放器 */
  async reset(): Promise<void> {
    if (this.avPlayer) {
      try {
        await this.avPlayer.reset();
        this.isPrepared = false;
      } catch (e) {
        console.error('[AVPlayerView] reset error: ' + (e as Error).message);
      }
    }
  }

  /** 获取当前播放时间 */
  getCurrentTime(): number {
    if (this.avPlayer) {
      return this.avPlayer.currentTime;
    }
    return 0;
  }

  /** 获取总时长 */
  getDuration(): number {
    if (this.avPlayer) {
      return this.avPlayer.duration;
    }
    return 0;
  }

  /** XComponent 加载回调 */
  onXComponentLoad() {
    try {
      this.surfaceId = this.xComponentController.getXComponentSurfaceId();
      console.info('[AVPlayerView] surfaceId: ' + this.surfaceId);
      if (this.avPlayer && this.surfaceId.length > 0 && this.avPlayer.state === 'initialized') {
        this.avPlayer.surfaceId = this.surfaceId;
      }
    } catch (e) {
      console.error('[AVPlayerView] getXComponentSurfaceId failed: ' + (e as Error).message);
    }
  }

  build() {
    XComponent({
      id: 'avplayer_surface',
      type: XComponentType.SURFACE,
      controller: this.xComponentController
    })
      .onLoad(() => {
        this.onXComponentLoad();
      })
      .width('100%')
      .height('100%')
  }
}


