import { router, promptAction, window, mediaquery } from '@kit.ArkUI';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { AppTheme, Palette } from '../common/AppTheme';
import { PlayerPrefs } from '../model/PlayerPrefs';

@Entry
@Component
struct SettingsPage {
  @StorageProp('isDark') isDark: boolean = true;
  @StorageProp('safeTop') safeTop: number = 0;
  @StorageProp('safeBottom') safeBottom: number = 0;

  @State gestureEnabled: boolean = true;
  @State autoPlayNext: boolean = true;
  @State backgroundPlay: boolean = false;
  @State defaultSpeed: number = 1.0;
  @State themeMode: string = AppTheme.THEME_SYSTEM;
  @State decodeMode: string = 'auto';
  @State subLang: string = 'zh-cn';
  @State subApiKey: string = '';
  @State isWide: boolean = false;

  private wideListener: mediaquery.MediaQueryListener =
    mediaquery.matchMediaSync('(min-width: 600vp)');

  pal(): Palette {
    return AppTheme.palette(this.isDark);
  }

  aboutToAppear(): void {
    this.isWide = this.wideListener.matches;
    this.wideListener.on('change', (r: mediaquery.MediaQueryResult) => {
      this.isWide = r.matches;
    });
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    PlayerPrefs.init(context).then(() => {
      this.gestureEnabled = PlayerPrefs.isGestureEnabled();
      this.autoPlayNext = PlayerPrefs.isAutoPlayNext();
      this.backgroundPlay = PlayerPrefs.isBackgroundPlay();
      this.defaultSpeed = PlayerPrefs.getDefaultSpeed();
      this.themeMode = PlayerPrefs.getThemeMode();
      this.decodeMode = PlayerPrefs.getDecodeMode();
      this.subLang = PlayerPrefs.getSubtitleLang();
      this.subApiKey = PlayerPrefs.getSubtitleApiKey();
    });
  }

  aboutToDisappear(): void {
    this.wideListener.off('change');
  }

  /** 切换主题：立即写 AppStorage 触达所有页面，并同步窗口底色避免切换瞬间闪白/闪黑 */
  private applyTheme(mode: string): void {
    this.themeMode = mode;
    PlayerPrefs.setThemeMode(mode);
    let dark: boolean = this.isDark;
    if (mode === AppTheme.THEME_DARK) {
      dark = true;
    } else if (mode === AppTheme.THEME_LIGHT) {
      dark = false;
    } else {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      dark = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    AppStorage.setOrCreate('isDark', dark);
    try {
      window.getLastWindow(getContext(this)).then((win: window.Window) => {
        win.setWindowBackgroundColor(dark ? AppTheme.DARK.bg : AppTheme.LIGHT.bg);
      }).catch(() => {
      });
    } catch (err) {
    }
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(12)
      .fontColor(this.pal().textTertiary)
      .width('100%')
      .padding({ left: AppTheme.pagePadding, top: 20, bottom: 8 })
  }

  build() {
    Column() {
      Row() {
        Text('‹')
          .fontSize(28)
          .fontColor(this.pal().textPrimary)
          .width(44)
          .height(48)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            router.back();
          })
        Text('设置')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().textPrimary)
          .layoutWeight(1)
      }
      .width('100%')
      .height(56 + this.safeTop)
      .padding({ right: AppTheme.pagePadding, top: this.safeTop })

      Scroll() {
        Column() {
          Column() {
            // ===== 外观 =====
            this.sectionTitle('外观')

            Row() {
              Column() {
                Text('深浅色')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text('跟随系统时，系统切换深色会自动同步')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 10 })

            Row() {
              this.themeChip('跟随系统', AppTheme.THEME_SYSTEM)
              this.themeChip('浅色', AppTheme.THEME_LIGHT)
              this.themeChip('深色', AppTheme.THEME_DARK)
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 12 })

            Divider().color(this.pal().divider).margin({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })

            // ===== 解码 =====
            this.sectionTitle('解码')

            Row() {
              Column() {
                Text('解码方式')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text('自动：交给系统（一般走硬解）；强制硬解：失败即报错；强制软解：自建 AVCodec 管线，兼容性优先但更耗电')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 10 })

            Row() {
              this.decodeChip('自动', 'auto')
              this.decodeChip('强制硬解', 'hw')
              this.decodeChip('强制软解', 'sw')
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 12 })

            Text('软解为实验性功能：部分机型/编码下可能初始化失败，播放页会自动回退硬解并提示。')
              .fontSize(11)
              .fontColor(this.pal().textTertiary)
              .width('100%')
              .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 8 })

            Divider().color(this.pal().divider).margin({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })

            // ===== 字幕 =====
            this.sectionTitle('字幕')

            Row() {
              Column() {
                Text('免 Key 字幕源（开箱即用）')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text('内置 射手网（伪）assrt.net 与 SubtitleCat，播放页字幕菜单里直接搜索下载，无需注册')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 4 })

            Row() {
              Column() {
                Text('搜索语言')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text('在线搜索时优先过滤该语言')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 10 })

            Row() {
              this.langChip('简体中文', 'zh-cn')
              this.langChip('繁體中文', 'zh-tw')
              this.langChip('English', 'en')
              this.langChip('日本語', 'ja')
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 12 })

            Row() {
              Column() {
                Text('OpenSubtitles Api-Key')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text('opensubtitles.com 免费注册后生成，仅保存在本机')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 8, bottom: 8 })

            Row() {
              TextInput({ text: this.subApiKey, placeholder: '粘贴 Api-Key' })
                .type(InputType.Password)
                .fontSize(13)
                .fontColor(this.pal().textPrimary)
                .placeholderColor(this.pal().textTertiary)
                .backgroundColor(this.pal().bgChip)
                .height(40)
                .layoutWeight(1)
                .onChange((v: string) => {
                  this.subApiKey = v;
                })
                .onSubmit(() => {
                  PlayerPrefs.setSubtitleApiKey(this.subApiKey.trim());
                  promptAction.showToast({ message: '已保存 Api-Key' });
                })
              Text('保存')
                .fontSize(13)
                .fontColor(Color.White)
                .backgroundColor(this.pal().primary)
                .borderRadius(14)
                .height(30)
                .padding({ left: 14, right: 14 })
                .margin({ left: 8 })
                .onClick(() => {
                  PlayerPrefs.setSubtitleApiKey(this.subApiKey.trim());
                  promptAction.showToast({ message: '已保存 Api-Key' });
                })
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, bottom: 12 })

            Divider().color(this.pal().divider).margin({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })

            // ===== 播放 =====
            this.sectionTitle('播放')

            Row() {
              Column() {
                Text('手势控制')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text('左滑右滑调进度，上下滑调音量/亮度，双击暂停，长按倍速')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.gestureEnabled })
                .selectedColor(this.pal().primary)
                .onChange((isOn: boolean) => {
                  this.gestureEnabled = isOn;
                  PlayerPrefs.setGestureEnabled(isOn);
                })
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 12, bottom: 12 })

            Divider().color(this.pal().divider).margin({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })

            Row() {
              Text('播完自动播放下一个')
                .fontSize(15)
                .fontColor(this.pal().textPrimary)
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.autoPlayNext })
                .selectedColor(this.pal().primary)
                .onChange((isOn: boolean) => {
                  this.autoPlayNext = isOn;
                  PlayerPrefs.setAutoPlayNext(isOn);
                })
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 12, bottom: 12 })

            Divider().color(this.pal().divider).margin({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })

            Row() {
              Column() {
                Text('后台播放')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text('离开播放页时不自动暂停')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.backgroundPlay })
                .selectedColor(this.pal().primary)
                .onChange((isOn: boolean) => {
                  this.backgroundPlay = isOn;
                  PlayerPrefs.setBackgroundPlay(isOn);
                })
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 12, bottom: 12 })

            this.sectionTitle('默认播放速度')

            Row() {
              ForEach([0.75, 1.0, 1.25, 1.5, 2.0], (s: number) => {
                Text(`${s.toFixed(2)}x`)
                  .fontSize(13)
                  .fontColor(this.defaultSpeed === s ? Color.White : this.pal().textSecondary)
                  .backgroundColor(this.defaultSpeed === s ? this.pal().primary : this.pal().bgChip)
                  .borderRadius(14)
                  .height(28)
                  .padding({ left: 12, right: 12 })
                  .margin({ right: 8 })
                  .textAlign(TextAlign.Center)
                  .onClick(() => {
                    this.defaultSpeed = s;
                    PlayerPrefs.setDefaultSpeed(s);
                  })
              }, (s: number) => `speed_${s}`)
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding })

            this.sectionTitle('关于')

            Row() {
              Column() {
                Text('多媒体')
                  .fontSize(15)
                  .fontColor(this.pal().textPrimary)
                  .width('100%')
                Text('版本 1.1.0 · HarmonyOS ArkTS 实现')
                  .fontSize(12)
                  .fontColor(this.pal().textSecondary)
                  .margin({ top: 4 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Text('详情')
                .fontSize(13)
                .fontColor(this.pal().primary)
                .onClick(() => {
                  promptAction.showDialog({
                    title: '关于',
                    message: '多媒体\n本地视频 / 音乐 / 网络播放器，基于 HarmonyOS AVPlayer / AVCodec 实现视频播放、手势控制、字幕与音轨切换，并支持局域网目录与 WebDAV 浏览。',
                    buttons: [{ text: '确定', color: this.pal().primary }]
                  });
                })
            }
            .width('100%')
            .padding({ left: AppTheme.pagePadding, right: AppTheme.pagePadding, top: 12, bottom: 32 })
          }
          .width('100%')
          .constraintSize({ maxWidth: this.isWide ? 720 : AppTheme.contentMaxWidth })
        }
        .width('100%')
        .padding({ bottom: this.safeBottom })
        .alignItems(HorizontalAlign.Center)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pal().bg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  themeChip(label: string, value: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.themeMode === value ? Color.White : this.pal().textSecondary)
      .backgroundColor(this.themeMode === value ? this.pal().primary : this.pal().bgChip)
      .borderRadius(14)
      .height(30)
      .padding({ left: 14, right: 14 })
      .margin({ right: 8 })
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.applyTheme(value);
      })
  }

  @Builder
  decodeChip(label: string, value: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.decodeMode === value ? Color.White : this.pal().textSecondary)
      .backgroundColor(this.decodeMode === value ? this.pal().primary : this.pal().bgChip)
      .borderRadius(14)
      .height(30)
      .padding({ left: 14, right: 14 })
      .margin({ right: 8 })
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.decodeMode = value;
        PlayerPrefs.setDecodeMode(value);
      })
  }

  @Builder
  langChip(label: string, value: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.subLang === value ? Color.White : this.pal().textSecondary)
      .backgroundColor(this.subLang === value ? this.pal().primary : this.pal().bgChip)
      .borderRadius(14)
      .height(30)
      .padding({ left: 12, right: 12 })
      .margin({ right: 8 })
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.subLang = value;
        PlayerPrefs.setSubtitleLang(value);
      })
  }
}
