/**
 * NetworkImage - 带自定义请求头(Referer/UA/Cookie)的网络图片组件
 * 优化：
 * - 无 header 走原生 Image(url) 系统 CDN 缓存
 * - 有 header 时走 http.request，并发限流 16
 * - Grid 复用响应式（@Prop + @Watch）
 * - 组件卸载时不再修改 state；每次 mount 立即重试（不会永远等 semaphore）
 */
import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN_IMG: number = 0x00A2;
const TAG_IMG: string = 'NetImg';

const MAX_CACHE: number = 300;
const MAX_CONCURRENCY: number = 16;
const pixelCache: Map<string, image.PixelMap> = new Map();
const inflight: Map<string, Promise<image.PixelMap | null>> = new Map();

class Semaphore {
  private running: number = 0;
  private queue: Array<() => void> = [];
  private limit: number = MAX_CONCURRENCY;

  async acquire(): Promise<void> {
    if (this.running < this.limit) {
      this.running++;
      return;
    }
    await new Promise<void>((resolve: () => void): void => { this.queue.push(resolve); });
    this.running++;
  }

  release(): void {
    this.running--;
    const next: (() => void) | undefined = this.queue.shift();
    if (next) { next(); }
  }
}
const httpSem: Semaphore = new Semaphore();

function putCache(key: string, pm: image.PixelMap): void {
  if (pixelCache.size >= MAX_CACHE) {
    const firstKey: string | undefined = pixelCache.keys().next().value as string | undefined;
    if (firstKey !== undefined) pixelCache.delete(firstKey);
  }
  pixelCache.set(key, pm);
}

@Component
export struct NetworkImage {
  @Prop @Watch('onImageUrlChange') imageUrl: string = '';
  referer: string = '';
  radius: number = 4;
  imageFit: ImageFit = ImageFit.Cover;
  @State pixel: image.PixelMap | null = null;
  @State failed: boolean = false;
  @State useNativeImage: boolean = false;
  private lastLoadedUrl: string = '';

  aboutToAppear(): void {
    this.lastLoadedUrl = this.imageUrl;
    this.decideLoadStrategy();
  }

  onImageUrlChange(): void {
    if (this.imageUrl === this.lastLoadedUrl) return;
    this.lastLoadedUrl = this.imageUrl;
    this.pixel = null;
    this.failed = false;
    this.useNativeImage = false;
    this.decideLoadStrategy();
  }

  private realUrl(raw: string): string {
    const at = raw.indexOf('@');
    if (at > 8) {
      return raw.substring(0, at);
    }
    return raw;
  }

  private needsCustomHeader(raw: string, url: string): boolean {
    if (raw.includes('@Referer=') || raw.includes('@User-Agent=') || raw.includes('@Cookie=')) return true;
    if (this.referer && this.referer.length > 0) return true;
    if (url.includes('doubanio.com') || url.includes('douban.com')) return true;
    return false;
  }

  private decideLoadStrategy(): void {
    const raw = this.imageUrl;
    if (!raw || raw.length === 0) { this.failed = true; return; }
    const url = this.realUrl(raw);
    if (!url.startsWith('http')) { this.failed = true; return; }

    const cached = pixelCache.get(raw);
    if (cached) { this.pixel = cached; hilog.info(DOMAIN_IMG, TAG_IMG, 'cache hit: %{public}s', url); return; }

    this.loadImageWithHeaders(raw, url);
  }

  private parseHeaders(raw: string, realUrl: string): Record<string, string> {
    const header: Record<string, string> = {
      'User-Agent': 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36'
    };
    if (raw.includes('@User-Agent=')) {
      header['User-Agent'] = raw.split('@User-Agent=')[1].split('@')[0];
    }
    if (raw.includes('@Cookie=')) {
      header['Cookie'] = raw.split('@Cookie=')[1].split('@')[0];
    }
    let ref: string = this.referer;
    if (raw.includes('@Referer=')) {
      ref = raw.split('@Referer=')[1].split('@')[0];
    } else if (ref.length === 0 && (realUrl.includes('doubanio.com') || realUrl.includes('douban.com'))) {
      ref = 'https://movie.douban.com/';
    }
    if (ref.length > 0) {
      header['Referer'] = ref;
    }
    return header;
  }

  private async loadImageWithHeaders(raw: string, url: string): Promise<void> {
    let promise: Promise<image.PixelMap | null> | undefined = inflight.get(raw);
    const fromInflight: boolean = promise !== undefined;
    if (!promise) {
      promise = this.doFetchWithSem(raw, url);
      inflight.set(raw, promise);
      promise.finally((): void => { inflight.delete(raw); });
    }
    const pm: image.PixelMap | null = await promise;
    if (raw !== this.imageUrl) return;
    if (pm) { this.pixel = pm; hilog.info(DOMAIN_IMG, TAG_IMG, 'loaded ok inflight=%{public}s: %{public}s', String(fromInflight), url); }
    else { this.useNativeImage = true; hilog.warn(DOMAIN_IMG, TAG_IMG, 'fetch null native fallback: %{public}s', url); }
  }

  private async doFetchWithSem(raw: string, url: string): Promise<image.PixelMap | null> {
    await httpSem.acquire();
    try {
      return await this.doFetch(raw, url);
    } finally {
      httpSem.release();
    }
  }

  private async doFetch(raw: string, url: string): Promise<image.PixelMap | null> {
    const request = http.createHttp();
    try {
      const header = this.parseHeaders(raw, url);
      const resp = await request.request(url, {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 8000,
        readTimeout: 8000,
        usingCache: true
      });
      if ((resp.responseCode === 200 || resp.responseCode === 206) && resp.result instanceof ArrayBuffer) {
        const buf = resp.result as ArrayBuffer;
        if (buf.byteLength > 0) {
          const imgSource = image.createImageSource(buf);
          const pm = await imgSource.createPixelMap();
          putCache(raw, pm);
          return pm;
        }
      } else {
        hilog.warn(DOMAIN_IMG, TAG_IMG, 'img http code=%{public}d url=%{public}s', resp.responseCode, url);
      }
    } catch (e) {
      hilog.warn(DOMAIN_IMG, TAG_IMG, 'img load fail: %{public}s', JSON.stringify(e));
    } finally {
      request.destroy();
    }
    return null;
  }

  build() {
    Stack() {
      if (this.pixel) {
        Image(this.pixel)
          .width('100%')
          .height('100%')
          .objectFit(this.imageFit)
          .borderRadius(this.radius)
          .syncLoad(true)
      } else if (this.useNativeImage) {
        Image(this.realUrl(this.imageUrl))
          .width('100%')
          .height('100%')
          .objectFit(this.imageFit)
          .borderRadius(this.radius)
          .backgroundColor('#1A1A1A')
          .syncLoad(false)
          .onError(() => { this.useNativeImage = false; })
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#1A1A1A')
          .borderRadius(this.radius)
      }
    }
    .width('100%')
    .height('100%')
    .onAppear(() => {
      if (!this.pixel && !this.failed) {
        const cached = pixelCache.get(this.imageUrl);
        if (cached) {
          this.pixel = cached;
          this.useNativeImage = false;
        }
      }
    })
  }
}

// ========== 预加载工具函数 ==========

function getRealUrl(raw: string): string {
  const at = raw.indexOf('@');
  if (at > 8) return raw.substring(0, at);
  return raw;
}

function needsHeaderFor(raw: string, url: string): boolean {
  if (raw.includes('@Referer=') || raw.includes('@User-Agent=') || raw.includes('@Cookie=')) return true;
  if (url.includes('doubanio.com') || url.includes('douban.com')) return true;
  return false;
}

function buildHeadersFor(raw: string, url: string): Record<string, string> {
  const header: Record<string, string> = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36'
  };
  if (raw.includes('@User-Agent=')) {
    header['User-Agent'] = raw.split('@User-Agent=')[1].split('@')[0];
  }
  if (raw.includes('@Cookie=')) {
    header['Cookie'] = raw.split('@Cookie=')[1].split('@')[0];
  }
  let ref: string = '';
  if (raw.includes('@Referer=')) {
    ref = raw.split('@Referer=')[1].split('@')[0];
  } else if (url.includes('doubanio.com') || url.includes('douban.com')) {
    ref = 'https://movie.douban.com/';
  }
  if (ref.length > 0) header['Referer'] = ref;
  return header;
}

async function fetchPixelMap(raw: string, url: string): Promise<image.PixelMap | null> {
  await httpSem.acquire();
  try {
    const request = http.createHttp();
    try {
      let header: Record<string, string>;
      if (needsHeaderFor(raw, url)) {
        header = buildHeadersFor(raw, url);
      } else {
        header = {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36'
        };
      }
      const resp = await request.request(url, {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 8000,
        readTimeout: 8000,
        usingCache: true
      });
      if ((resp.responseCode === 200 || resp.responseCode === 206) && resp.result instanceof ArrayBuffer) {
        const buf = resp.result as ArrayBuffer;
        if (buf.byteLength > 0) {
          const imgSource = image.createImageSource(buf);
          const pm = await imgSource.createPixelMap();
          putCache(raw, pm);
          return pm;
        }
      } else {
        hilog.warn(DOMAIN_IMG, TAG_IMG, 'preload http code=%{public}d url=%{public}s', resp.responseCode, url);
      }
    } catch (e) {
      hilog.warn(DOMAIN_IMG, TAG_IMG, 'preload img fail: %{public}s', JSON.stringify(e));
    } finally {
      request.destroy();
    }
    return null;
  } finally {
    httpSem.release();
  }
}

/**
 * 预加载图片到内存缓存，使滑动时封面无缝显示。
 * 对每个 URL：若已在 pixelCache 或 inflight 中则跳过，否则异步抓取并缓存。
 */
export function preloadImages(urls: string[]): void {
  let preloaded: number = 0;
  for (const raw of urls) {
    if (!raw || raw.length === 0) continue;
    const url = getRealUrl(raw);
    if (!url.startsWith('http')) continue;
    if (pixelCache.has(raw) || inflight.has(raw)) continue;
    const promise: Promise<image.PixelMap | null> = fetchPixelMap(raw, url);
    inflight.set(raw, promise);
    preloaded++;
    promise.finally((): void => { inflight.delete(raw); });
  }
  hilog.info(DOMAIN_IMG, TAG_IMG, 'preloadImages: %{public}d new / %{public}d total', preloaded, urls.length);
}