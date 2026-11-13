import { media } from '@kit.MediaKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'ThumbnailLoader';
const DOMAIN: number = 0x0001;

/**
 * 视频首帧缩略图加载器，对应 MX 列表左侧的封面。
 * 失败时不抛错，界面回落为占位图标。
 */
export class ThumbnailLoader {
  private static cache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private static failed: Set<string> = new Set<string>();

  static get(uri: string): image.PixelMap | undefined {
    return ThumbnailLoader.cache.get(uri);
  }

  static isFailed(uri: string): boolean {
    return ThumbnailLoader.failed.has(uri);
  }

  static async load(uri: string): Promise<image.PixelMap | undefined> {
    const hit: image.PixelMap | undefined = ThumbnailLoader.cache.get(uri);
    if (hit !== undefined) {
      return hit;
    }
    if (ThumbnailLoader.failed.has(uri)) {
      return undefined;
    }
    let generator: media.AVImageGenerator | undefined = undefined;
    let file: fs.File | undefined = undefined;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const size: number = fs.statSync(file.fd).size;
      generator = await media.createAVImageGenerator();
      const fdSrc: media.AVFileDescriptor = { fd: file.fd, offset: 0, length: size };
      generator.fdSrc = fdSrc;
      const options: media.PixelMapParams = { width: 320, height: 180 };
      const pm: image.PixelMap = await generator.fetchFrameByTime(0,
        media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST_SYNC, options);
      ThumbnailLoader.cache.set(uri, pm);
      return pm;
    } catch (err) {
      ThumbnailLoader.failed.add(uri);
      hilog.warn(DOMAIN, TAG, 'load thumb failed');
      return undefined;
    } finally {
      if (generator !== undefined) {
        try {
          await generator.release();
        } catch (err) {
        }
      }
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (err) {
        }
      }
    }
  }

  static clear(): void {
    ThumbnailLoader.cache.forEach((pm: image.PixelMap) => {
      pm.release();
    });
    ThumbnailLoader.cache.clear();
    ThumbnailLoader.failed.clear();
  }
}
