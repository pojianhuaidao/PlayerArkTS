/**
 * 收藏页
 * 展示收藏的影片，点击进入详情页，长按删除，支持清空
 */
import { router, promptAction } from '@kit.ArkUI';
import { CollectRecord, CollectRepository } from '../data/Database';
import { NetworkImage } from '../components/NetworkImage';
import { getTopSafeAreaVp, getTopSafeAreaSync, getBottomSafeAreaVp, getLeftSafeAreaVp, getRightSafeAreaVp, getBreakpoint, Breakpoint, BP_SM, isWide } from '../utils/ScreenAdapter';
import { DS } from '../utils/DesignSystem';
import { Palette } from '../utils/ThemeManager';
import { display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

interface ToastOptions {
  message: string;
  duration?: number;
}

@Entry
@Component
struct FavoritePage {
  @State records: CollectRecord[] = [];
  @State loading: boolean = true;
  @State topSafe: number = 0;
  @State bottomSafe: number = 0;
  @State leftSafe: number = 0;
  @State rightSafe: number = 0;
  @State bp: Breakpoint = BP_SM;
  @StorageProp('isDarkMode') isDark: boolean = true;
    private foldListener: (s: display.FoldStatus) => void = (_s: display.FoldStatus): void => { this.displayListener(0); };
  private displayListener: (id: number) => void = (_id: number): void => {
    this.bp = getBreakpoint();
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    getLeftSafeAreaVp(ctx).then((v: number): void => { this.leftSafe = v + DS.cornerInset(this.bp); });
    getRightSafeAreaVp(ctx).then((v: number): void => { this.rightSafe = v + DS.cornerInset(this.bp); });
  };

  aboutToAppear(): void {
    this.loadRecords();
    this.initSafeArea();
  }

  onPageShow(): void {
    this.loadRecords();
  }

  aboutToDisappear(): void {
    try { display.off('change', this.displayListener); display.off('foldStatusChange', this.foldListener); } catch (e) {}
  }

  private async initSafeArea(): Promise<void> {
    this.bp = getBreakpoint();
    try { display.on('change', this.displayListener); display.on('foldStatusChange', this.foldListener); } catch (e) {}
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.topSafe = await getTopSafeAreaVp(ctx);
    this.bottomSafe = await getBottomSafeAreaVp(ctx) + DS.cornerInset(this.bp);
    this.leftSafe = await getLeftSafeAreaVp(ctx) + DS.cornerInset(this.bp);
    this.rightSafe = await getRightSafeAreaVp(ctx) + DS.cornerInset(this.bp);
    try {
      const win: window.Window = await window.getLastWindow(ctx);
      win.on('avoidAreaChange', (data): void => {
        if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          const h: number = data.area.bottomRect.height;
          if (h > 0) { this.bottomSafe = px2vp(h) + DS.cornerInset(this.bp); }
        } else if (data.type === window.AvoidAreaType.TYPE_SYSTEM || data.type === window.AvoidAreaType.TYPE_CUTOUT) {
          const th: number = getTopSafeAreaSync(win);
          if (th > 0) { this.topSafe = th; }
        }
      });
    } catch (e) {
    }
  }

  private async loadRecords(): Promise<void> {
    this.loading = true;
    try {
      this.records = await CollectRepository.getAll();
    } catch (e) {
      this.records = [];
    } finally {
      this.loading = false;
    }
  }

  private async clearAll(): Promise<void> {
    try {
      await CollectRepository.clearAll();
      this.records = [];
      promptAction.showToast({ message: '已清空收藏' } as ToastOptions);
    } catch (e) {
    }
  }

  private async deleteOne(rec: CollectRecord): Promise<void> {
    try {
      await CollectRepository.remove(rec.vodId, rec.sourceKey);
      this.records = this.records.filter((r: CollectRecord): boolean => !(r.vodId === rec.vodId && r.sourceKey === rec.sourceKey));
    } catch (e) {
    }
  }

  private openDetail(rec: CollectRecord): void {
    router.pushUrl({
      url: 'tvbox/pages/DetailPage',
      params: {
        vodId: rec.vodId,
        sourceKey: rec.sourceKey,
        name: rec.name
      }
    });
  }

  build() {
    Column() {
      // 顶部栏
      Row() {
        Text('返回')
          .fontSize(DS.smallFont(this.bp) + 2)
          .fontColor(Palette.textPrimary(this.isDark))
          .padding({ left: 16, right: 8 })
          .onClick(() => router.back())

        Text('我的收藏')
          .fontSize(DS.bodyFont(this.bp) + 2)
          .fontColor(Palette.textPrimary(this.isDark))
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)

        Text('清空')
          .fontSize(DS.smallFont(this.bp) + 2)
          .fontColor(Palette.textPrimary(this.isDark))
          .padding({ left: 8, right: 16 })
          .onClick(() => this.clearAll())
      }
      .width('100%')
      .height(56 + this.topSafe)
      .padding({ top: this.topSafe })
      .backgroundColor(Palette.topBar(this.isDark))
      .backgroundBlurStyle(BlurStyle.Regular, { colorMode: this.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      .alignItems(VerticalAlign.Center)

      if (this.records.length > 0) {
        Grid() {
          ForEach(this.records, (rec: CollectRecord, index: number) => {
            GridItem() {
              Column() {
                Stack() {
                  if (rec.pic.length > 0) {
                    NetworkImage({ imageUrl: rec.pic, radius: 4, imageFit: ImageFit.Cover })
                  } else {
                    Column()
                      .width('100%')
                      .height('100%')
                      .backgroundColor(Palette.surface(this.isDark))
                      .borderRadius(4)
                  }
                }
                .width('100%')
                .aspectRatio(0.72)

                Text(rec.name)
                  .fontSize(13)
                  .fontColor(Palette.textPrimary(this.isDark))
                  .maxLines(1)
                  .textAlign(TextAlign.Center)
                  .textOverflow({ overflow: TextOverflow.MARQUEE })
                  .width('100%')
                  .margin({ top: 4 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
              .clickEffect({ level: ClickEffectLevel.MIDDLE, scale: 0.96 })
              .onClick(() => this.openDetail(rec))
              .gesture(
                LongPressGesture({ repeat: false, duration: 500 })
                  .onAction((): void => { this.deleteOne(rec); })
              )
            }
          }, (rec: CollectRecord, index: number): string => index + '_' + rec.vodId + '_' + rec.sourceKey)
        }
        .columnsTemplate(DS.gridTemplate(this.bp))
        .rowsGap(12)
        .columnsGap(10)
        .padding({ left: 12, right: 12, top: 12, bottom: 12 + this.bottomSafe })
        .edgeEffect(EdgeEffect.Spring)
        .layoutWeight(1)
        .width('100%')
      } else {
        Column() {
          Text(this.loading ? '加载中...' : '暂无收藏')
            .fontSize(16)
            .fontColor(Palette.textSecondary(this.isDark))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: this.leftSafe, right: this.rightSafe })
    .backgroundColor(Palette.bg(this.isDark))
  }
}
