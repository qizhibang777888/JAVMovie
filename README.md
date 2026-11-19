# JAVMovie（macOS 原生版）

原生 AppKit 应用：**不用网页、不用 Electron**，一个 952KB 的 `.app`。
读的是 `javdb.py` 抓好的 `FM.jpg` / `T-*.jpg` / `TX.json`，和之前的网页版共用同一套本地数据。

## 需要装 Xcode 吗？

**不需要。** 现在的 Command Line Tools 就能编译这个 App。

| | 说明 |
|---|---|
| Xcode | Apple 官方 IDE，带完整 SDK、SwiftUI 宏插件、Interface Builder、SwiftUI 预览器。App Store 下载约 12GB，装完占 20–30GB |
| 只有 Command Line Tools（你现在就是） | 能编译 **AppKit**（本项目用的就是这套），能 `swift build`、`codesign`、`swiftc`；**SwiftUI 的 `@State` 等宏插件缺失**，写 SwiftUI 会报 `SwiftUIMacros not found` |
| 什么时候才要装 | 想用 SwiftUI / Interface Builder / 预览器 / 上架签名公证时 |

装法（可选，随时反悔）：

```bash
# App Store 搜 Xcode 安装，然后切换工具链
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
swift build -c release        # 之后 SwiftUI 也能编
```

## 编译 / 打包

```bash
cd native
./build.sh          # swift build -c release + 组装 JAVMovie.app + 本机自签
open JAVMovie.app                    # 开发版（项目里）
./build.sh --install                 # 编译 + 装到 /Applications/JAVMovie.app（日常用这个）
```

产物：`native/JAVMovie.app`（960KB，Intel/Apple Silicon 用本机 arch，当前 arm64）。
想换图标就把任意 `AppIcon.icns` 放进 `Contents/Resources/`。

## 功能

| 区域 | 行为 |
|---|---|
| 顶栏 | 🎬 JAVMovie + 📁 目录按钮 + 两个 Tab（JAV / 国产）+ 搜索框；排序 / 播放器选择 / 刷新 在菜单栏 **JAVMovie** 菜单里（刷新 ⌘R） |
| 我的最爱 | **默认不收藏任何影片；只有手动点击星标才会加入收藏**。**无标题栏**，轮播直接顶在顶栏下面：焦点卡居中满尺寸，两侧按距离缩小 + 叠黑色遮罩压暗（`alpha 1 → 0.54 → 0.10`，遮罩 `0 → 0.58 → 0.76`）；一次滑动/拖拽只切一张；点卡片用 IINA 播放（⌥ 用内置播放器） |
| 影库 | 自适应列数（最小 326pt，当前窗口 4 列），间距 34（列）/44（行）；卡片上常显 **紫色播放键**、右上 **金色收藏**、左下 **红色删除**、番号 **靛蓝色徽标**（各 30/24pt，带阴影）；**点番号徽标 → 用默认浏览器打开该片的 JavDB 页面**（没有 TX 时退回站内搜索） |
| 滚动 | **整页一个 NSScrollView**：我的最爱 + 影库 在同一个 documentView 里，向下滚时精选区一起滑出视野（不固定）；顶栏吸住不动 |
| 数据 | 同目录优先 `FM.jpg` 当封面；`TX.json` 里的番号/标题/发行/评分/演员都用上；缺 TX 则从文件名解析番号 |
| 元数据 | 用 AVFoundation 读时长与分辨率，卡片副行显示 `发行 · ★评分 · 体积 · 1080p · 时长` |
| 持久化 | 目录、收藏、播放器选择存 `UserDefaults`；收藏满 10 个后新收藏顶掉最早的 |

### 为什么必须有「编辑」菜单

AppKit 的 `⌘X / ⌘C / ⌘V / ⌘A` 不是输入框自己处理的，而是由**菜单项的 key equivalent** 分发到 first responder。
早先这个 App 只有「应用菜单 + 窗口菜单」，所以链接框里按 ⌘V 完全没反应（不是控件不可编辑，也不是剪贴板权限）。

`main.swift` 里已补上标准「编辑」菜单（撤销 / 重做 / 剪切 / 拷贝 / 粘贴 / 全选，target = nil 走 first responder），
弹窗打开时还会自动聚焦链接框并全选，直接 ⌘V 覆盖。


## 已停用（代码保留）

`FeatureFlags.swift` 里两个开关，默认都关：

| 开关 | 关掉后 |
|---|---|
| `shotsEnabled` | 剧照（`T-01.jpg…`）浏览器不弹；点封面 = 直接播放 |
| `hoverEnabled` | 鼠标停留不再浮现播放键，胶囊按钮也不再有悬停高亮 |

逻辑代码一行没删，只是想恢复时不用改代码：

```bash
JAVMOVIE_SHOTS=1 JAVMOVIE_HOVER=1 open -n JAVMovie.app
```

## 整页一起滚的实现要点

```swift
contentScroll.documentView = ContentDocumentView(favHeader:libHeader:carousel:grid:)
// documentView 内部自上而下：我的最爱标题 → 轮播(≈34% 窗口高) → 分割线 → 影库标题 → 网格
```

两处容易踩的坑，都属于"看起来像固定"：

1. 精选区如果放在 scrollView **外面**，就永远不动 → 必须放进 documentView。
2. 轮播视图若把 `scrollWheel` 全部吃掉，纵向滚动就传不到外层 → 现在只在**横向/按住 Shift** 时切卡片，纵向一律 `super.scrollWheel(...)` 交给整页滚动。

## 一个必须知道的一次性授权

首次运行会弹：

> “JAVMovie.app” 想访问可移除宗卷上的文件。

**必须点「允许」**，否则扫不到 `/Volumes/US202/...` 里的东西（这是 macOS 的 TCC 保护，不是代码问题）。
点错或想改：系统设置 → 隐私与安全性 → 文件与文件夹 → JAVMovie。

## 代码结构

```
native/
├── Package.swift               SwiftPM 清单（macOS 14+，可执行 target）
├── Sources/MovieShelf/
│   ├── Model.swift             Movie 结构、番号解析、路径哈希、体积格式化
│   ├── Library.swift           目录扫描（含一层子目录）、TX.json/FM.jpg 查找、AVFoundation 取时长、LibraryStore（@MainActor ObservableObject）
│   ├── UI.swift                CardView / CarouselView / GridView / 主题与封面缓存
│   ├── AppUI.swift             AppController：窗口、顶栏控件、布局约束、内置播放器、Toast
│   ├── GuochangPage.swift      国产：收藏/全部 + 文件夹树 + 右侧播放 + 行内删除
│   ├── FeatureFlags.swift      停用开关（剧照展示 / 鼠标停留展示）
│   ├── CookieWindow.swift      抓 JavDB Cookie 的小窗
│   ├── SettingsPanel.swift     设置面板（目录 / 播放器）
│   └── main.swift              NSApplication 入口 + AppDelegate
├── AppIcon.icns                应用图标（build.sh 打包时用）
├── README.md
└── build.sh                    编译打包脚本
```

## 和网页版的关系

| | 网页版（movieshelf/） | 原生版（native/） |
|---|---|---|
| 运行方式 | `node server.mjs` + 浏览器 | 双击 `.app` |
| 依赖 | Node 24 + 浏览器 | 无（系统自带 AppKit/AVKit） |
| 封面/剧照/元数据 | 读同一批 `FM.jpg` `T-*.jpg` `TX.json` | 同 |
| 播放 | `open -a IINA`（服务端执行） | `NSWorkspace.open(withApplicationAt:)`（客户端直接调） |
| 体积 | 源码 + 13 个文件 | 单个 952KB 应用 |

两套可以并存；网页版适合远程/多设备，原生版日常双击最省事。

## 装好 Xcode 之后（2026-11 更新）

Xcode 27.2 已装，`DEVELOPER_DIR` 指过去就能用完整工具链（无需 `sudo xcode-select`）：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build.sh
```

三种影响：

1. **SwiftUI 现在能编了**：宏插件在
   `Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib`，
   用 CLT 单独编 SwiftUI 会报 `SwiftUIMacros not found`。SwiftUI 试验版在 `native-swiftui/`。
2. **重建会重置磁盘权限**：ad-hoc 签名每次重建都会换签名身份，TCC 里「可移除宗卷」的授权随之失效，
   界面会显示红色提示条。重新授权：系统设置 → 隐私与安全性 → 文件与文件夹 → JAVMovie → 打开「可移除宗卷」，
   回来点「刷新」即可。
3. **`open` 有时报 -600**：同路径 bundle 的二进制被替换后，LaunchServices 会拒绝启动。
   `build.sh` 已改成每次生成新 bundle（`JAVMovie-1.app`、`MovieShelf-2.app`…）并留一个 `JAVMovie.app` 软链；
   实在打不开就用 `open -n JAVMovie-N.app`。

## 纯玻璃背景

窗口 `isOpaque = false` + 透明底色，内容层最底下只有一层系统模糊，**没有任何染色/光晕/背景图**：

```swift
window.isOpaque = false
window.backgroundColor = .clear

let glass = NSVisualEffectView()
glass.material = .underWindowBackground   // 想更深可换 .hudWindow
glass.blendingMode = .behindWindow        // 模糊窗口后面的桌面
glass.state = .active

// 更亮：玻璃之上再盖一层极薄白雾（仍然完全透明）
veil.layer?.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.96, blue: 0.92, alpha: 0.05).cgColor  // 暖调 5%，几乎全透明
```

卡片与文字直接浮在玻璃上；因为封面本身不透明，桌面颜色从卡片间隙、顶栏和留白处透出来。

## 两个 Tab

| Tab | 内容 |
|---|---|
| JAV | 本地影库（封面 + 元数据 + 我的最爱） |
| 国产 | 独立页面：**左侧「收藏 / 全部」两个 Tab**（全部 = 文件夹树，收藏 = 点过 ☆ 的视频）+ 右侧内嵌播放器；每行**文件名前** ☆ 收藏（`UserDefaults.guochangFavorites`），另有 🗑 删除：**视频行只删该视频文件，文件夹行删整个文件夹（含全部内容）**，都走废纸篓 |

## JAV / 国产 的差异

| | Tab1 JAV | Tab2 国产 |
|---|---|---|
| 数据源 | 设置里的「JAV 数据目录」 | 设置里的「国产 数据目录」 |
| 扫描深度 | 根目录 + 1 层子目录 | **递归整棵树**（自动跳过 `._` 资源分叉文件） |
| 展示 | 卡片网格 + 轮播 | **左侧文件夹树（NSTableView）**，选中文件右侧 AVPlayer 播放 |
| 元数据 | 读 `TX.json` / JavDB 补全 | 不读、不抓 |
| 删除 | 卡片左上角 🗑 → 确认框 → 整个文件夹移到废纸篓 |
| 缩略图 | `FM.jpg` | 用 `AVAssetImageGenerator` 抽**视频 30% 处**的帧（`VideoThumb.Position.middle`），内存缓存 |

## 剧照浏览器（点封面）—— 目前停用

> 这块功能先关掉了（见上面「已停用」）。下面的交互保留在代码里，`JAVMOVIE_SHOTS=1` 启动即可恢复。

面板上方的整条区域显示 `TX.json` 的元信息：番号、标题、日期、时长、发行、导演、评分（人数）、类别、演员，右上角可点「在 JavDB 打开 ↗」。

点任意封面 → 窗口**正中**弹出一个占屏 **50% × 50%** 的面板（左右各留 25%、上下各留 25%），**从第一张（T-01）开始**：

| 操作 | 效果 |
|---|---|
| 左右/上下滑动 | 上一张 / 下一张 |
| 滚轮（横或纵） | 逐张切换（0.18s 节流） |
| `←` `→` `↑` `↓` | 逐张切换 |
| 两侧 `‹` `›` 按钮 | 逐张切换 |
| `Esc` / 点空白 / 右上角 `✕` | 关闭 |

播放改为点封面上的圆形播放键（⌥ 用内置播放器，按钮现在常显，不再依赖鼠标停留）；点封面本体只打开剧照（该功能目前停用）。

## 轮播参数（`CarouselView`）

```swift
let cardH = max(150, bounds.height - 62)
let cardW = cardH * 1.5
let gap   = max(16, cardW * 0.075)
// 焦点卡：alpha 1、scale 1、无遮罩
// 第 n 档：alpha = max(0.10, 1 - 0.46n)、scale = max(0.86, 1 - 0.055n)
//         黑色遮罩 = min(0.88, 0.58 + (n-1) * 0.18)   ← 这就是“两侧更昏暗”的部分
```

> 试过两版花式效果（圆弧轮盘、3D cover-flow），最后按需求回到这版平铺：最稳、信息密度最高。

### 一次手势只切一张

之前触控板一次滑动（含惯性十几个事件）会连跳好几张，现在做了两层限制：

```swift
// 滚轮/触控板：一次手势只认第一个事件，0.3 秒内没有新事件才算新手势
if now - lastWheelAt > 0.30 { wheelConsumed = false }
lastWheelAt = now
guard !wheelConsumed else { return }
wheelConsumed = true
focus(index + (delta < 0 ? 1 : -1), animated: true)

// 拖拽：位移超过 24px 就走一张，与拖拽距离无关
if dx < -24 { focus(index + 1, animated: true) }
else if dx > 24 { focus(index - 1, animated: true) }
```

实测：模拟一次含 10 个惯性事件的滑动 → 只前进 1 张（NPJS-268 → ROE-506）。

## 影库封面尺寸

`GridView.metrics` 里的最小宽度决定列数：

```swift
var cols = max(1, Int(((usable + gapX) / (250 + gapX)).rounded()))   // 1440 宽 → 5 列
```

想更大改 326（4 列），想更小改 210（6 列）。
