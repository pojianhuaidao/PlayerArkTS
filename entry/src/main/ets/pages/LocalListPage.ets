import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppTheme, Palette } from '../common/AppTheme';
import { VideoItem } from '../model/VideoItem';
import { MediaRepository } from '../model/MediaRepository';
import { PlayerPrefs, PlaylistHolder } from '../model/PlayerPrefs';

const TAG: string = 'LocalListPage';
const DOMAIN: number = 0x0001;

/**
 * 本地视频「查看全部」页。
 * 视频页只放 2~3 行预览，超量条目在这里用虚拟化 List 承载，避免视频页嵌套滚动。
 * 点播跳本地播放页；返回沿用路由栈出栈。
 */
@Entry
@Component
struct LocalListPage {
  @StorageProp('isDark') isDark: boolean = true;
  @StorageProp('safeTop') safeTop: number = 0;

  @State items: VideoItem[] = [];
  @State loading: boolean = true;

  pal(): Palette {
    return AppTheme.palette(this.isDark);
  }

  aboutToAppear(): void {
    this.loadItems();
  }

  private async loadItems(): Promise<void> {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      await PlayerPrefs.init(context);
      const uris: string[] = PlayerPrefs.getPlaylistUris();
      if (uris.length === 0) {
        this.items = [];
      } else {
        const probed: VideoItem[] = await MediaRepository.probeAll(uris);
        this.items = probed.filter((it: VideoItem) => it !== undefined && it.uri.length > 0);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'load items failed');
    } finally {
      this.loading = false;
    }
  }

  private play(index: number): void {
    if (this.items.length === 0) {
      return;
    }
    PlaylistHolder.set(this.items, index < 0 ? 0 : index);
    router.pushUrl({ url: 'pages/LocalPlayerPage' }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'push LocalPlayerPage failed code=%{public}d', err.code);
    });
  }

  build() {
    Column() {
      Row() {
        Text('›')
          .fontSize(22)
          .fontColor(this.pal().textPrimary)
          .rotate({ angle: 180 })
          .width(36)
          .height(36)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            router.back();
          })
        Text('本地视频')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().textPrimary)
          .layoutWeight(1)
          .margin({ left: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`共 ${this.items.length} 个`)
          .fontSize(12)
          .fontColor(this.pal().textTertiary)
      }
      .width('100%')
      .height(AppTheme.toolbarHeight)
      .padding({ left: 8, right: AppTheme.pagePadding })

      if (!this.loading && this.items.length === 0) {
        Column() {
          Text('还没有本地视频')
            .fontSize(14)
            .fontColor(this.pal().textSecondary)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 0 }) {
          ForEach(this.items, (item: VideoItem, index: number) => {
            ListItem() {
              this.videoRow(item, index)
            }
          }, (item: VideoItem) => `${item.uri}_${item.durationMs}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .padding({ left: AppTheme.pagePadding, right: 4 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pal().bg)
  }

  @Builder
  videoRow(item: VideoItem, index: number) {
    Row() {
      Column() {
        Text(item.title)
          .fontSize(15)
          .fontColor(this.pal().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(item.metaLine())
          .fontSize(12)
          .fontColor(this.pal().textSecondary)
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(index + 1 < 10 ? `0${index + 1}` : `${index + 1}`)
        .fontSize(12)
        .fontColor(this.pal().textTertiary)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .borderRadius(AppTheme.radius)
    .onClick(() => {
      this.play(index);
    })
  }
}
