---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: 67425aee6b41b6be2f991b4754092804_2d9d7e08de6911f19232525400248c00
    ReservedCode1: gGKNF6/VihLfNkKLaCRNlGWFPMoeRG+R35loDe9NKdf++p5FGof8lndIQ90HMKcYRIlbyxYnrS+Y+irnCAblHdqbt5n8wpX+9kWljr5AS5dA4W5s9hmR9B532NrKyldsK1X5fmnv9Elqa2V/AZf/LYIomHhNETqwSsWJr9lbCpcKVjXOTbg1408OOGs=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: 67425aee6b41b6be2f991b4754092804_2d9d7e08de6911f19232525400248c00
    ReservedCode2: gGKNF6/VihLfNkKLaCRNlGWFPMoeRG+R35loDe9NKdf++p5FGof8lndIQ90HMKcYRIlbyxYnrS+Y+irnCAblHdqbt5n8wpX+9kWljr5AS5dA4W5s9hmR9B532NrKyldsK1X5fmnv9Elqa2V/AZf/LYIomHhNETqwSsWJr9lbCpcKVjXOTbg1408OOGs=
---

# 多媒体（tv.hm.o）

面向 HarmonyOS NEXT 的一体化媒体播放应用：**本地视频 + 局域网共享 + DLNA 网络媒体 + 在线影视/直播 + 音乐与下载**，全部收敛在同一个应用内，不依赖外部播放器或第三方软解库。

---

## 一、项目简介与定位

| 项 | 说明 |
| --- | --- |
| 产品定位 | 本地 + 局域网 + DLNA 网络媒体一体化播放器 |
| 核心场景 | 手机/平板/2in1 上播放本机视频、局域网 NAS 与共享目录里的片源、DLNA 服务器上的媒体，以及在线影视与直播源 |
| 技术栈 | HarmonyOS NEXT，ArkTS / ArkUI 声明式 UI，播放基于 `AVPlayer` + `AVSession`，软解渲染基于 Native `OH_AVCodec`（`libsoftplayer.so`） |
| 设计取向 | 单页签壳 + 沉浸式播放页；深色/浅色双主题；玻璃质感悬浮控件；手势优先，尽量不打断播放 |

工程为单模块（`entry`）结构，`deviceTypes` 覆盖 `phone / tablet / 2in1`，屏幕方向不锁定（`orientation: unspecified`），横竖屏由系统与用户决定。

---

## 二、当前版本与身份信息

| 项 | 值 | 落点 |
| --- | --- | --- |
| 应用显示名 | 多媒体 | `AppScope/resources/base/element/string.json` → `app_name` |
| 桌面/启动标签 | 多媒体 | `entry/src/main/resources/base/element/string.json` → `EntryAbility_label` / `app_title` |
| 英文名 | Media Player | `entry/src/main/resources/en_US/element/string.json` |
| 包名（bundleName） | `tv.hm.o` | `AppScope/app.json5` |
| APP ID | `917619014743214665` | 华为 AGC 应用标识，记录于 `AppScope/app.json5` 注释 |
| 当前版本名 | `1.1112.02` | `AppScope/app.json5` → `versionName` |
| 当前版本号 | `1111202` | `AppScope/app.json5` → `versionCode` / `buildVersion` |
| 构建版本号 | `1111202` | 与 `versionCode` 保持一致 |
| SDK | `compatibleSdkVersion = 6.1.0(23)`，`targetSdkVersion = 26.0.0`，`minAPIVersion = 23`，`targetAPIVersion = 24` | `build-profile.json5` / `AppScope/app.json5` |

> 版本字段统一只在 `AppScope/app.json5` 维护，`entry/src/main/module.json5` 不承载 `versionName` / `versionCode`，因此不存在两处版本冲突的风险；改版本只改 `AppScope/app.json5` 一处即可，`build.ps1` 会从该文件解析 `versionName` 决定产物文件名。

---

## 三、功能清单

### 3.1 本地媒体

- 视频列表：首帧缩略图（`AVImageGenerator`）、标题、时长/大小/分辨率两行元信息，支持按时间/名称/大小/时长排序与名称实时过滤。
- 双视图：视频列表（`pages/Index.ets`）与本地目录视图（`pages/LocalListPage.ets`）。
- 导入入口：媒体库选择器、系统文件选择器、系统「下载」目录直扫（受限权限场景，见第七节）。
- 本地独立播放页：`pages/LocalPlayerPage.ets`，从列表进入即以沉浸态打开，退出即回列表。
- 多选与移除：长按进入多选，仅从播放列表剔除，不动本机文件。
- 播放进度记忆：每 5 秒与切后台/退出时落盘，重进同一媒体自动续播（进度 > 5s 才恢复，距结尾 < 3s 视为看完）；本地与网络源分别记忆、分别清除。
- 列表持久化：`preferences` 保存已添加条目，重启后恢复。

### 3.2 局域网与网络来源

网络页（`view/NetPanel.ets`）以协议芯片切换四类来源：

| 协议 | 实现 | 能力 |
| --- | --- | --- |
| HTTP / HTTPS | `model/NetClient.ets` | 目录浏览（解析 HTML/JSON 列表）、直链判定与播放、地址归一化与历史持久化 |
| WebDAV | `NetClient.davList()` / `parseDav()` | `PROPFIND`（Depth: 1 + Basic 认证）列目录，凭据不进流地址（走请求头），可用 `net_history` / `dav_*` 记忆 |
| SMB | `model/smb/Smb2Client.ets`、`SmbBrowser.ets`、`SmbProxy.ets` | SMB2 会话与列目录、共享路径按段下钻，`files/logs/smb_*.log` 落诊断日志 |
| FTP | `model/ftp/FtpProto.ets`、`FtpConnection.ets`、`FtpBrowser.ets`、`FtpProxy.ets` | 主动/被动模式、匿名与账号登录、目录浏览与本地代理取流 |
| DLNA / UPnP | `model/upnp/UpnpProto.ets`、`UpnpClient.ets`、`DlnaBrowser.ets` | SSDP 发现局域网媒体服务器，浏览 ContentDirectory 目录，取 http 直链播放，支持「上级」回溯 |

- 网络页首次进入即扫描本机网段常见端口，发现的服务器可一键加入地址簿。
- 局域网源全部支持播放进度记忆与「清除网络记录」（同时清理进度与最近连接）。

### 3.3 播放内核

- 主播放链路：`AVPlayer` 负责解封装、音频与时钟，画面渲染到 `XComponent`（SURFACE）。
- 软硬解切换：`view/PlayerCore.ets` → `utils/SoftPipeline.ets` → Native `entry/src/main/cpp/softplayer.cpp`（`OH_AVCodec` 软件解码器）。软解模式下 `AVPlayer` 只承担解封装与音频，视频帧由软解器按外部推送的播放时钟渲染到 surface；软解器初始化失败自动回退硬解并提示。
- 手势：单击显隐控制层、双击播放/暂停、长按 2.0x 倍速、水平滑动 seek 预览、左半屏上下滑亮度、右半屏上下滑音量。
- 画面比例：适应屏幕 / 裁剪铺满 / 原始比例。
- 播放能力：0.5x–2.0x 倍速（含默认倍速设置）、音轨列举与切换、屏幕锁定、单曲循环、自动下一集。
- 后台播放：`KEEP_BACKGROUND_RUNNING` + `audioPlayback` 后台模式。

### 3.4 字幕

- 外挂字幕：SRT / WebVTT / ASS / SSA 四类统一解析为 `SubtitleCue`（`utils/Subtitle.ets`），ASS/SSA 支持内联覆盖标签切分多 run 渲染。
- 本地字幕：播放页字幕菜单 → 文件选择器载入。
- 在线字幕：`utils/SubtitleFinder.ets`，内置免 Key 源（射手网(伪) assrt.net、SubtitleCat），OpenSubtitles 作为可填 Api-Key 的补充；下载结果统一转 UTF-8 SRT 落到沙箱 `filesDir/subtitles/` 后立即载入。
- 直链导入：任意 http(s) 的 srt/vtt/zip 地址可直接粘贴使用。
- 内嵌字幕轨：`getTrackDescription()` 列举并可切换。

标签级支持范围见第五节。

### 3.5 投屏

- 系统投屏：`AVCastPicker` + `CastSessionHelper`（AVSession），播放页投屏按钮回显连接状态。
- DLNA 投屏（自研发送端）：`model/upnp/DlnaCast.ets`，支持 `AVTransport` / `RenderingControl` 的 SetAVTransportURI、Play、Pause、Stop、Seek、音量与播放进度回读，设备列表由 SSDP 实时发现。

### 3.6 音乐与下载

- 音乐页（`view/MusicPanel.ets`）：推荐界面、歌单与榜单、平台切换与搜索、本地音乐入口、迷你歌词条（`view/MiniLyricBar.ets`）与底部播放栏；歌曲详情页 `pages/SongDetailPage.ets` 提供歌词展示。
- 音乐内核（`ets/lx/`）：`core/music`（搜索、歌单、歌词、音质、封面）、`core/player`（播放会话、播放服务、收藏、随机播放袋）、`core/source`（音源引擎与元数据）、`core/local`（本地音乐与歌词匹配）、`core/download`（下载管理、下载索引、自动下载）、`core/webdav`（WebDAV 音乐库）。
- 下载落盘位置：应用沙箱 `files/Download`（`DownloadManager.DIR_NAME`），下载索引 `downloads.json`，支持删除单条/批量、清理已完成、下载标签汇总。
- 缓存与清理：`utils/CacheCleaner.ets` 提供缓存统计与一键清理。

### 3.7 TV 影视与直播

- 入口：网络页「TV」卡片与设置页「TV 设置」分区。
- 模块目录：`ets/tvbox/`（`api / components / data / model / pages / util / utils / viewmodel`，共 67 个 `.ets`）。
- 页面：首页、搜索、详情、播放、直播播放、历史、收藏、网盘配置、网盘登录、TV 设置（已在 `main_pages.json` 注册）。
- 资源：`resources/base/rawfile` 下内置默认配置 `config_default.json`、示例 `config_sample.json` 与直播源 `live_default.m3u`；`resources/base/profile/network_config.json` 挂为 `network_config` metadata。
- 缓存：`utils/TvCacheStore.ets` 负责 TV 侧数据缓存与清理粒度控制。

### 3.8 界面与交互规范

- 单壳多页签：`Tabs` 原生 bar 隐藏（`barHeight(0)`），自绘**底部胶囊悬浮页签**（视频 / 音乐 / 网络 / 设置），`layoutWeight(1)` 四等分，选中项主题色实心胶囊。
- 玻璃质感：胶囊底色按主题取 `#B81C1C1E`（深）/ `#B8F4F4F7`（浅），72% 不透明度 + 外描边 + 阴影；关键浮层使用 `backgroundBlurStyle` 做背景模糊。
- 不遮挡内容：内容区底部统一让出 `112vp + safeBottom`；胶囊下留 `14vp + safeBottom`，其上为一行状态文字（视频数 / 文件夹数 / 已记忆进度条数 + 清除按钮）；胶囊 `hitTestBehavior(HitTestMode.Transparent)`，空白处事件穿透给列表。
- 覆盖层约束：禁止全屏透明容器压在 `Tabs` 之上；悬浮按钮以 `Stack({ alignContent: Alignment.BottomEnd })` 条件渲染，避免吞掉整屏触摸。
- 深浅色：`common/AppTheme.ets` 提供 `AppTheme.palette(isDark)` 双色板，页面用 `@StorageProp('isDark')` 驱动刷新。
- 主题色 `#3C8CF0`，深色底 `#121212`、卡片 `#1C1C1C`、次级文字 `#9E9E9E`；列表缩略图 128×72vp、页边距 16vp。
- 安全区：所有页面统一读取 `safeTop/safeBottom`（`@StorageProp`），顶栏加高 + `expandSafeArea` 做状态栏与挖孔避让。
- 图标：`AppScope/resources/base/media/icon_app.png` 与 `entry/src/main/resources/base/media/icon_app.png` 双份同源，另有 216×216 备案图。

---

## 四、媒体格式支持范围

### 4.1 支持

以下常见容器与编码依赖**系统媒体能力（硬解）**，在系统支持的情况下可直接播放：

| 类型 | 容器/协议 | 常见编码 |
| --- | --- | --- |
| 视频容器 | MP4、MKV、TS、M3U8（HLS）、FLV、WebM、MOV | H.264 / AVC、H.265 / HEVC、AV1（视设备）、VP9 |
| 音频容器 | MP3、AAC/M4A、FLAC、WAV、OGG | MP3、AAC、FLAC、PCM、Vorbis |
| 网络协议 | HTTP/HTTPS、HLS、WebDAV、SMB、FTP、DLNA/UPnP | — |
| 字幕 | SRT、WebVTT、ASS、SSA | — |

### 4.2 不支持

**不支持 RMVB / RM / AVI / WMV / ASF 等老旧容器与编码，本项目未集成 FFmpeg 等第三方软解库，此类文件的解码由系统能力决定，若系统不支持则无法播放。**

- 列表仍可正常添加这类文件，播放时由系统解码器给出错误，应用会提示播放失败并回退提示。
- 「软解开关」指的是本工程自带的 Native `OH_AVCodec` 软件**渲染**管线，它复用系统已安装的解码器，**不是**通用格式软解，因此不能扩大容器/编码的覆盖面。

**替代建议**：把 RMVB/RM/AVI/WMV/ASF 等片源转码为 **H.264 或 H.265 封装的 MP4**（必要时封装为 MKV/TS）后再导入播放；音轨建议 AAC，字幕转 SRT/ASS 外挂加载。

---

## 五、字幕标签支持与降级清单

ASS/SSA 内联覆盖标签按「可渲染则生效、不可渲染则降级为当前样式纯文本」处理，降级标签只在日志里上报一次（`unsupported ass tag`），不影响其余字幕显示。

### 5.1 生效标签

| 类别 | 标签 |
| --- | --- |
| 定位/对齐 | `\an`、`\pos`、`\move` |
| 淡入淡出 | `\fad`、`\fade` |
| 字号 | `\fs`（含 `+/-` 相对值） |
| 颜色 | `\c` / `\1c`（主色）、`\3c`（描边色） |
| 透明度 | `\alpha` / `\1a` |
| 字形 | `\b`（粗体）、`\i`（斜体）、`\u`（下划线） |
| 描边/阴影 | `\bord`（宽度）、`\shad`（距离） |
| 旋转 | `\frz` |
| 样式重置 | `\r`（重置为默认样式或当前样式） |
| 动画 | `\t(...)`（按时间区间对颜色、字号、透明度、描边、阴影做线性插值） |

同时解析 ASS 的 `[Script Info]`（`PlayResX/PlayResY` 用于归一化）、`[V4+ Styles]` 主色/描边/背色/字号/粗斜体等样式字段。

### 5.2 降级标签（识别但不渲染，按当前样式纯文本显示）

`\fn`、`\clip`、`\iclip`、`\k`、`\K`、`\kf`、`\ko`、`\p`、`\org`、`\blur`、`\be`、`\fscx`、`\fscy`、`\fax`、`\fay`、`\frx`、`\fry`、`\xbord`、`\ybord`、`\xshad`、`\yshad`、`\q`、`\fe`、`\2c`、`\4c`、`\2a`、`\3a`、`\4a`

> 降级原因：字体名无法替换内置字体族（`\fn`）、矢量裁剪与绘图指令（`\clip` / `\iclip` / `\p`）、卡拉 OK 计时（`\k` 系列）、横向缩放与倾斜/3D 透视（`\fscx` / `\fscy` / `\fax` / `\fay` / `\frx` / `\fry`）、特效滤镜（`\blur` / `\be` / `\fe`）、副色与描边/阴影分轴参数。

SRT 与 WebVTT 整条字幕退化为单 run，跟随播放器默认字号与配色。

---

## 六、工程结构与关键目录

```
D:\Player\PlayerArkTS\
├─ AppScope\
│  ├─ app.json5                       # 包名、版本、应用级图标与名称（版本唯一维护点）
│  └─ resources\base\element\string.json
├─ entry\
│  ├─ build-profile.json5             # 模块级构建配置
│  └─ src\main\
│     ├─ module.json5                 # 设备类型、入口 Ability、权限声明、network_config metadata
│     ├─ cpp\
│     │  ├─ CMakeLists.txt            # Native 软解模块构建（CMAKE_LIBRARY_OUTPUT_DIRECTORY 已重定向到当前构建目录）
│     │  ├─ softplayer.cpp            # OH_AVCodec 软解 + surface 渲染 + 时钟同步（导出 libsoftplayer.so）
│     │  └─ types\libsoftplayer\      # NAPI 类型声明
│     ├─ ets\
│     │  ├─ entryability\EntryAbility.ets     # 入口；注入 preferences Context、初始化安全区/主题
│     │  ├─ common\                            # AppTheme（双主题色板）、PlayIcons / PlayIconSet（播放控件图标）
│     │  ├─ model\
│     │  │  ├─ VideoItem.ets                   # 媒体条目模型 + 时长/大小/分辨率格式化
│     │  │  ├─ MediaRepository.ets             # 选择器取媒体、元信息探测、下载目录直扫与权限诊断
│     │  │  ├─ NetClient.ets / NetPrefs.ets    # HTTP/WebDAV 客户端与地址历史
│     │  │  ├─ NetScan.ets / NetServer.ets     # 网段扫描与服务器条目
│     │  │  ├─ PlayerPrefs.ets                 # 设置项、播放进度、列表持久化
│     │  │  ├─ ftp\                            # FTP 协议、连接、浏览、本地代理
│     │  │  ├─ smb\                            # SMB2 客户端、浏览、本地代理、加密与日志
│     │  │  └─ upnp\                           # SSDP/SOAP 协议、DLNA 浏览、DLNA 投屏
│     │  ├─ utils\
│     │  │  ├─ Subtitle.ets                    # SRT/VTT/ASS/SSA 解析与当前字幕二分查找
│     │  │  ├─ SubtitleFinder.ets              # 在线字幕检索与下载
│     │  │  ├─ ThumbnailLoader.ets             # 首帧缩略图
│     │  │  ├─ SoftPipeline.ets                # Native 软解管线封装
│     │  │  ├─ CacheCleaner.ets / TvCacheStore.ets  # 缓存统计与清理
│     │  ├─ view\                              # 页签与功能面板（NetPanel / MusicPanel / SettingsPanel / PlayerCore / MiniLyricBar …）
│     │  ├─ pages\                             # 路由页面（17 个，含 tvbox 10 个）
│     │  ├─ lx\                                # 音乐与下载内核（core\music、core\player、core\source、core\download、core\local、core\webdav、core\settings、core\book）
│     │  └─ tvbox\                             # 在线影视 / 直播 / 网盘模块（67 个 .ets）
│     └─ resources\
│        ├─ base\element\                      # 中文文案与颜色
│        ├─ base\media\                        # 应用图标
│        ├─ base\profile\                      # main_pages.json（路由表）、network_config.json
│        ├─ base\rawfile\                      # TV 默认配置与直播源
│        └─ en_US\element\                     # 英文文案
├─ hvigor\                            # hvigor 配置
├─ key\                               # 签名材料（video.p12 / 视频.cer / 视频Release.p7b / 视频Debug.p7b）
├─ output\                            # 构建产物与核对报告
├─ docs\                              # 工程文档
├─ build.ps1                          # 主出包脚本（signed.app + unsigned.hap）
├─ build_tv.ps1                       # TV 模块专用副本构建
├─ build-profile.json5                # 应用级构建配置与 signingConfigs
├─ oh-package.json5 / hvigorfile.ts
└─ README.md
```

关键约定：

- `entry/src/main/resources/base/profile/main_pages.json` 是唯一路由表，新增页面必须在此注册，否则 `router.pushUrl` 静默失败。
- `ets/view/*` 为面板/组件（无独立路由），`ets/pages/*` 为可路由页面；设置页内容已抽为 `view/SettingsPanel.ets` 内嵌第四页签，`pages/SettingsPage.ets` 保留注册但不再作为入口。
- Native 侧只有 `libsoftplayer.so` 一个模块，无第三方解码库依赖。

---

## 七、权限与 ACL

`entry/src/main/module.json5` 声明的权限：

| 权限 | 类型 | 用途 |
| --- | --- | --- |
| `ohos.permission.INTERNET` | 普通 | 影视数据抓取、在线播放、局域网目录、WebDAV |
| `ohos.permission.GET_NETWORK_INFO` | 普通 | 判断网络状态与网段扫描 |
| `ohos.permission.MODIFY_AUDIO_SETTINGS` | 普通 | 播放音量与音频输出控制 |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | 普通 | 后台播放（配合 `audioPlayback` 后台模式） |
| `ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY` | **受限（ACL）** | 仅服务「系统下载目录直扫导入视频」一个场景 |

说明：

1. **`READ_WRITE_DOWNLOAD_DIRECTORY` 是受限权限**，需在 AGC 申请并在签名 profile 的 `allowed-acls` 中带同名条目，否则 ACL 一致性校验不通过、安装或运行期授权失败。本工程已申请通过并保持 `module.json5` 声明与 profile 一致。
2. **侧载限制**：带 ACL 受限权限的包必须使用**与该申请一致**的签名材料（本工程 `key/` 目录内的证书与 profile）。用其它证书重签会丢失 ACL 授权，直扫下载目录的能力随之失效。
3. **`ohos.permission.FILE_ACCESS_PERSIST` 已移除**：音乐下载自 1.1111.06 起只写应用沙箱 `files/Download`，不再需要跨重启保留目录 uri 授权；该权限不在 profile 的 `allowed-acls` 内，继续声明会导致 AGC 的 ACL 一致性校验失败。需要对外交付文件时走「导出到系统文件」。
4. 常规取片（`PhotoViewPicker` / `DocumentViewPicker`）不需要额外授权，走系统选择器即可，安装后即用，不做全盘常驻扫描。
5. 亮度手势作用于窗口亮度；音量手势作用于播放器音量，不改系统媒体音量（系统媒体音量需要 `ohos.permission.MANAGE_AUDIO`，本工程不申请）。

---

## 八、构建与出包

### 8.1 环境

- DevEco Studio（含 HarmonyOS SDK，`minAPIVersion 23` 以上）与 hvigor。
- 必须显式设置 `DEVECO_SDK_HOME`，否则 hvigor 报 `00303217`。
- 工程路径含中文时，hvigor 的规范校验会失败，因此构建统一在**纯 ASCII 副本目录**中进行（`build.ps1` 自动完成）。

### 8.2 一条命令出包

```powershell
powershell -ExecutionPolicy Bypass -File D:\Player\PlayerArkTS\build.ps1
```

脚本行为：

1. `robocopy` 把 `entry`、`AppScope`、`key`、`hvigor` 与 `build-profile.json5` / `oh-package.json5` / `hvigorfile.ts` 镜像到 `C:\hb_pl_build`（排除 `build` 与 `*.log`）。
2. 从 `AppScope/app.json5` 解析 `versionName` / `versionCode` 并打印，产物文件名与包内版本号强一致。
3. `assembleApp`（release）→ 输出**已签名 `.app`**，供 AGC 上架/分发。
4. `assembleHap`（debug）→ 输出**未签名 `.hap`**，供侧载/后续重签。
5. 两个产物复制进 `output\`，临时副本目录由外部清理。

### 8.3 产物命名

| 产物 | 路径 | 用途 |
| --- | --- | --- |
| 已签名应用包 | `output\多媒体_<versionName>_signed.app` | AGC 上传、分发 |
| 未签名 HAP | `output\多媒体_<versionName>_unsigned.hap` | 侧载（需用匹配设备 UDID 的 profile 重签） |

### 8.4 debug HAP 与设备侧载

- debug 包必须使用**在 AGC 绑定目标设备 UDID 的调试 Profile**（`key/视频Debug.p7b`），profile 的 `bundle-name` 必须为 `tv.hm.o`，否则重签失败或安装被拒。
- 为不改动主 `build-profile.json5`（它指向 Release profile 与 AGC 用途），debug 签名在**独立副本目录** `C:\hb_pl_build_dbg` 中进行，只把该副本的 profile 换成 `key/视频Debug.p7b`。
- 侧载命令：

```powershell
hdc list targets
hdc uninstall tv.hm.o                                   # 已安装旧版时先卸载，避免签名冲突
hdc install -r .\output\多媒体_<versionName>_debug.hap
hdc shell aa start -a EntryAbility -b tv.hm.o
```

### 8.5 签名材料

`build-profile.json5` 的 `signingConfigs.default` 直接引用工程内 `key/` 目录：`storeFile = key/video.p12`（别名 `shipin`，`SHA256withECDSA`）、`certpath = key/视频.cer`、`profile = key/视频Release.p7b`。更换证书或换绑设备时只需替换这三份文件与 `key/视频Debug.p7b`，无需改代码。

---

## 九、版本号规则

- 规则：`versionName = 1.<MMDD>.<当天版次>`，例：`1.1112.02` = 11 月 12 日当天第 2 版。
- `versionCode` = `versionName` 去掉小数点后拼接，例：`1.1112.02` → `1111202`；`buildVersion` 与 `versionCode` 同值。
- 每次改动必须同时更新 `AppScope/app.json5` 中 `versionName` / `versionCode` / `buildVersion` 三处，保持一一对应；`build.ps1` 用 `versionName` 命名产物，三者不一致会直接导致产物名与包内版本号错位。
- 同一天多次出包版次递增（`.01` → `.02` → …），跨天则 `MMDD` 跟随日期变化。

---

## 十、目录与产物说明

| 目录 | 内容 | 说明 |
| --- | --- | --- |
| `output\` | `多媒体_<versionName>_signed.app`、`多媒体_<versionName>_unsigned.hap`、`多媒体_<versionName>_debug.hap`、接口/问题核对类 Markdown | 全部构建交付物集中于此，按版本名区分 |
| `key\` | `video.p12`、`视频.cer`、`视频Release.p7b`、`视频Debug.p7b`、`video.csr`、`README.md`、历史材料 `_archive\` | 签名材料，禁止删除或外发 |
| `docs\` | 工程说明与交互实现文档 | 与源码同步维护 |
| `E:\开发\` | `PlayerArkTS_<versionName>_<YYYYMMDD>.zip` | 版本归档包，顶层目录 `PlayerArkTS_<versionName>_arch`，含源码（排除 `.git`、`build`、`.hvigor`、`node_modules`、`oh_modules`、`.cxx` 等构建中间产物）+ `key\` + `output\` + `README.md` |

归档后仅清理构建缓存与本版之外的多余临时产物；`key\` 目录与历史版本产物不参与清理。

---

## 十一、常见问题

| 现象 | 原因与处理 |
| --- | --- |
| 编译报 `00303217` | 未设置 `DEVECO_SDK_HOME`，指向 DevEco Studio 自带 `sdk` 目录 |
| 中文路径导致规范校验失败 | 使用 `build.ps1` 在 `C:\hb_pl_build` 纯 ASCII 副本中编译 |
| `copyfile ENOENT ... libsoftplayer.so` | DevEco 升级后 hvigor 传入 `-DCMAKE_LIBRARY_OUTPUT_DIRECTORY` 指向最终产物目录，与「外部构建产物硬链到同一路径」冲突；已在 `entry/src/main/cpp/CMakeLists.txt` 把 `CMAKE_LIBRARY_OUTPUT_DIRECTORY(_DEBUG/_RELEASE)` 重置为 `${CMAKE_CURRENT_BINARY_DIR}`。若仍出现，删除副本的 `entry/.cxx` 与 `entry/build` 后重跑 |
| 重签后安装报签名冲突 | 设备上已有同包名不同签名的旧版，先 `hdc uninstall tv.hm.o` 再装 |
| debug 包安装被拒（801 / 9568289） | 调试 Profile 未绑定该设备 UDID，需在 AGC 重新生成并下载 `视频Debug.p7b` |
| AGC 报 ACL 一致性校验失败 | `module.json5` 声明了 profile `allowed-acls` 中不存在的权限（典型是 `FILE_ACCESS_PERSIST`），删除该声明 |
| 老旧格式（RMVB/AVI/WMV 等）提示播放失败 | 系统不支持该容器/编码，本工程未集成 FFmpeg，按第 4.2 节转码为 H.264/H.265 MP4 再播放 |
| 字体名、裁剪、卡拉 OK 等 ASS 特效不生效 | 属第五节列出的降级标签，按当前样式纯文本渲染，属预期行为 |
| 界面「点啥都没用」 | 检查是否存在压在 `Tabs` 之上的全屏透明容器；覆盖层必须 `hitTestBehavior(HitTestMode.Transparent)`，悬浮按钮改为 `Stack(BottomEnd)` 条件渲染 |

---

## 十二、许可与声明

本项目为自有工程，源码、资源与签名材料由项目所有者维护；`key/` 内证书与 profile 仅限本应用使用，请勿外发或用于其它包名。
*（内容由AI生成，仅供参考）*
