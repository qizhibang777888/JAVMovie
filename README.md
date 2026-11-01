# JAVMovie

macOS 本地影片库 App（纯 AppKit），带三套独立页面：

| Tab | 内容 |
|---|---|
| **JAV** | 本地影库：封面墙 + 「我的最爱」轮播 + 剧照浏览器 + JavDB 元数据 |
| **国产** | 独立页面：递归扫描目录，只显示视频首帧（视频 30% 处）缩略图 + 文件名 |
| **短剧** | 内嵌网页 `https://huangguoai.com/ai-duanju/`（WKWebView，支持网页全屏） |

## 功能

- 液态玻璃（`NSVisualEffectView` + 薄白雾，可调亮度/透明度）
- 影库每行 4 部，封面悬停出现播放键，点击封面打开居中剧照浏览器（滑动/滚轮/方向键切换）
- 「我的最爱」平铺轮播：焦点居中、两侧按距离压暗，一次滑动只切一张
- 设置面板：分别配置 **JAV** 与 **国产** 数据目录，确定后自动切换数据源 + 校验 + 补全元数据
- 元数据补全：调用 `javdb.py`，进度弹窗实时显示；支持浏览器 Cookie / 代理 / 自定义 UA 绕过 Cloudflare
- 每张封面左下角 🗑 → 二次确认 → 整个文件夹移到废纸篓（可还原）

## 构建

```bash
cd native
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
./build.sh            # 产出 JAVMovie.app
./build.sh --install  # 复制并签名到 /Applications/JAVMovie.app
```

> 需要 macOS 14+ 与 Xcode（SwiftUI/宏依赖 Xcode 工具链；本工程是纯 AppKit，CLT 也能编译）。

## 首次运行

App 需要读取外接卷里的影片目录，请授予：

`系统设置 → 隐私与安全性 → 完全磁盘访问权限 → ＋ → /Applications/JAVMovie.app`

（macOS 在无权限时会返回空目录且不报错，App 顶部会显示红色提示条。）

## 抓取工具

```bash
python3 javdb.py /Volumes/US202/jav                 # 番号 → 短链 → 封面 + 剧照 + TX.json
python3 javdb.py /path --cookie "cf_clearance=..."  # 过 Cloudflare
python3 javdb.py /path --proxy http://127.0.0.1:7890
python3 javdb_id_map.py SONE-811                     # 番号 ↔ javdb 短 ID
```

产出：`FM.jpg`、`T-01…jpg`、`TX.json`、`javdb_links_out/links.{md,csv,json}`。

## 目录

```
native/Sources/MovieShelf/
  main.swift            应用入口 + 菜单
  AppUI.swift           窗口、顶栏、三页面切换、进度/删除/剧照浮层
  UI.swift              主题、卡片、轮播、网格、剧照浏览器、Tab、缩略图
  GuochangPage.swift    国产页（递归扫描 + 纯视频卡片）
  WebPage.swift         短剧页（WKWebView 封装）
  SettingsPanel.swift   设置面板（两个数据目录）
  CookieWindow.swift    内嵌浏览器取 JavDB Cookie
  Library.swift         扫描 / 播放 / 收藏 / 元数据读取
  Model.swift           Movie / TxInfo / 名称解析
build.sh                打包成 .app 并签名
javdb.py                JavDB 抓取（封面 / 剧照 / 元数据）
javdb_id_map.py         番号 ↔ 短 ID 解析
```
