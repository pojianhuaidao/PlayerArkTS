/**
 * 视频卡片组件 - 用于首页、分类、搜索等网格展示
 * 封面在上（仅保留"更新至XX集"角标），标题+年份/语言在封面下方
 */
import { VodItem } from '../model/Movie';
import { NetworkImage } from './NetworkImage';
import { Breakpoint, BP_SM } from '../utils/ScreenAdapter';
import { DS } from '../utils/DesignSystem';
import { Palette } from '../utils/ThemeManager';

@Component
export struct VodCard {
  @Prop item: VodItem = {
    id: '', tid: 0, name: '', type: '', pic: '', lang: '',
    area: '', year: 0, state: '', note: '', actor: '',
    director: '', des: '', sourceKey: '', tag: '', action: '', last: ''
  };
  focused: boolean = false;
  bp: Breakpoint = BP_SM;
  @StorageProp('isDarkMode') isDark: boolean = true;
  onItemClick: (item: VodItem) => void = () => {};

  private metaText(): string {
    const parts: string[] = [];
    if (this.item.year > 0) { parts.push(String(this.item.year)); }
    if (this.item.area.length > 0) { parts.push(this.item.area); }
    if (this.item.lang.length > 0) { parts.push(this.item.lang); }
    return parts.join(' · ');
  }

  build() {
    Column() {
      // 封面
      Stack({ alignContent: Alignment.BottomStart }) {
        if (this.item.pic.length > 0) {
          NetworkImage({ imageUrl: this.item.pic, radius: DS.cardRadius(this.bp), imageFit: ImageFit.Cover })
        } else {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(Palette.surface(this.isDark))
            .borderRadius(DS.cardRadius(this.bp))
        }

        // 仅保留"更新至XX集"角标
        if (this.item.note.length > 0) {
          Text(this.item.note)
            .fontSize(DS.cardBadgeFont(this.bp))
            .fontColor('#FFFFFF')
            .backgroundColor('#CC000000')
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .borderRadius(4)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: 5, bottom: 5 })
        }
      }
      .width('100%')
      .aspectRatio(0.72)
      .borderRadius(DS.cardRadius(this.bp))
      .border({ width: this.focused ? 2 : 0, color: Palette.accent(), radius: DS.cardRadius(this.bp) })

      // 标题：居中；超出封面宽度时跑马灯滚动显示
      Text(this.item.name)
        .fontSize(DS.cardTitleFont(this.bp))
        .fontColor(Palette.textPrimary(this.isDark))
        .maxLines(1)
        .textAlign(TextAlign.Center)
        .textOverflow({ overflow: TextOverflow.MARQUEE })
        .width('100%')
        .margin({ top: 6 })

      // 元信息：年份 · 地区 · 语言
      if (this.metaText().length > 0) {
        Text(this.metaText())
          .fontSize(DS.cardBadgeFont(this.bp))
          .fontColor(Palette.textSecondary(this.isDark))
          .maxLines(1)
          .textAlign(TextAlign.Center)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .clickEffect({ level: ClickEffectLevel.MIDDLE, scale: 0.96 })
    .onClick(() => this.onItemClick(this.item))
  }
}
