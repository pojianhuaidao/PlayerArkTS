import { fileIo as fs } from '@kit.CoreFileKit';
import softNative from 'libsoftplayer.so';

/**
 * 视频软件解码管线（native OH_AVCodec 实现）。
 * 音频与播放时钟由 AVPlayer 负责，本管线的职责是：用软件解码器解视频帧、
 * 按外部推送的播放时钟把帧渲染到 XComponent 的 surface 上。
 */
export class SoftPipeline {
  private id: number = -1;
  private codecDesc: string = '';

  /**
   * @param file 独立打开的视频文件句柄（不要与 AVPlayer 共用同一个 fd）
   * @param surfaceId XComponent 的 surfaceId
   * @param preferSoftware true 时优先选择软件解码器，无软解器时退回系统默认
   * @returns 解码器描述，例如 "OH.Media.Codec.Decoder.Video.AVC|video/avc"
   */
  start(file: fs.File, length: number, surfaceId: string, preferSoftware: boolean): string {
    this.release();
    const id: number = softNative.create(surfaceId, file.fd, 0, length, preferSoftware);
    this.id = id;
    this.codecDesc = softNative.info(id);
    return this.codecDesc;
  }

  isRunning(): boolean {
    return this.id >= 0;
  }

  describe(): string {
    return this.codecDesc;
  }

  setClock(ms: number): void {
    if (this.id >= 0) {
      softNative.setClock(this.id, Math.floor(ms));
    }
  }

  setPaused(paused: boolean): void {
    if (this.id >= 0) {
      softNative.setPaused(this.id, paused);
    }
  }

  seekTo(ms: number): void {
    if (this.id >= 0) {
      softNative.seek(this.id, Math.floor(ms));
    }
  }

  release(): void {
    if (this.id >= 0) {
      softNative.release(this.id);
      this.id = -1;
      this.codecDesc = '';
    }
  }
}
