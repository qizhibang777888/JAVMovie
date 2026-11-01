import AppKit
import AVKit
import Combine

/// 把管道输出切成整行（跨线程安全）
final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func appendAndDrain(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [String] = []
        while let nl = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: 0..<nl.lowerBound)
            buffer.removeSubrange(0..<nl.upperBound)
            if let text = String(data: lineData, encoding: .utf8) { lines.append(text) }
        }
        return lines
    }
}

/// 元数据补全进度面板
final class SyncPanel: NSWindow {
    private let headline = NSTextField(labelWithString: "正在检查目录并补全元数据…")
    private let detail = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let logView = NSTextView()
    private let scroll = NSScrollView()
    private let actionButton = NSButton()
    private var finished = false
    var didHintCloudflare = false

    var onAction: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                   styleMask: [.titled], backing: .buffered, defer: false)
        title = "补全元数据"
        appearance = NSAppearance(named: .darkAqua)
        isReleasedWhenClosed = false

        let root = FlippedView()
        contentView = root

        headline.font = Theme.font(13, .semibold)
        headline.textColor = .white
        headline.frame = NSRect(x: 20, y: 16, width: 640, height: 18)
        root.addSubview(headline)

        detail.font = Theme.font(11.5)
        detail.textColor = Theme.dim
        detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: 20, y: 38, width: 640, height: 16)
        root.addSubview(detail)

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        progress.controlSize = .small
        progress.frame = NSRect(x: 20, y: 60, width: 640, height: 8)
        root.addSubview(progress)

        logView.isEditable = false
        logView.isSelectable = true
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        logView.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        logView.textContainerInset = NSSize(width: 8, height: 8)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        logView.textContainer?.widthTracksTextView = true
        logView.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.frame = NSRect(x: 20, y: 78, width: 640, height: 300)
        scroll.documentView = logView
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        root.addSubview(scroll)

        actionButton.title = "取消"
        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        actionButton.frame = NSRect(x: 580, y: 392, width: 80, height: 30)
        root.addSubview(actionButton)
    }

    func append(_ line: String) {
        let text = logView.string.isEmpty ? line : logView.string + "\n" + line
        logView.string = text
        logView.scrollToEndOfDocument(nil)
    }

    func setProgress(_ value: Double, total: Double, detail text: String) {
        progress.maxValue = max(1, total)
        progress.doubleValue = min(value, max(1, total))
        detail.stringValue = text
    }

    func finish(_ summary: String) {
        finished = true
        headline.stringValue = "完成"
        detail.stringValue = summary
        progress.doubleValue = progress.maxValue
        actionButton.title = "关闭"
    }

    @objc private func actionTapped() {
        if finished { onAction?() } else { onAction?() }
    }
}

@MainActor
final class AppController: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    let store = LibraryStore()
    var window: NSWindow!

    private let carousel = CarouselView()
    private let grid = GridView()
    private let contentScroll = NSScrollView()
    private var content: ContentDocumentView!

    private let favBadge = NSTextField(labelWithString: "")
    private let libBadge = NSTextField(labelWithString: "")
    private let dirButton = NSButton()
    private var tabBar: TabBar?
    private var javRoot = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "root") ?? "/Volumes/US202/jav")
    private var guochangRoot = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "rootGuochang") ?? "/Volumes/US202/guochang")
    private var activeTab: Int = UserDefaults.standard.integer(forKey: "activeTab")
    private let emptyHint = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let toast = NSTextField(labelWithString: "")
    private let bannerBar = NSView()
    private let bannerLabel = NSTextField(labelWithString: "")
    private lazy var guochangPage: GuochangPage = {
        let page = GuochangPage(frame: .zero)
        page.onPlay = { [weak self] movie, inApp in self?.play(movie, inApp: inApp) }
        page.onPreview = { [weak self] movie in self?.openShotViewer(movie) }
        return page
    }()
    private lazy var duanjuPage: WebPage = {
        let page = WebPage(url: URL(string: "https://huangguoai.com/ai-duanju/")!)
        page.isHidden = true
        return page
    }()
    private var shotViewer: ShotViewer?
    private var syncPanel: SyncPanel?
    private var syncProcess: Process?
    private var cookieWindow: CookieWindow?
    private var playerWindow: NSWindow?
    private var playerView: AVPlayerView?
    private var cancellables = Set<AnyCancellable>()

    // MARK: 窗口

    func showWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 940),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "JAVMovie · 本地影库"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false                      // 液态玻璃：窗口本身透明
        window.backgroundColor = .clear
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        window.minSize = NSSize(width: 1080, height: 720)
        window.contentView = buildRoot()
        window.center()
        window.makeKeyAndOrderFront(nil)
        bindStore()
        applyTabRoot()
        store.reload()
        reloadAll()

        if ProcessInfo.processInfo.environment["SHOT_DEMO"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let first = self.store.visibleMovies.first else { return }
                self.openShotViewer(first)
            }
        }


        // 回到前台自动重扫：在系统设置里给了权限、切回应用就会自己加载
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.store.movies.isEmpty else { return }
            self.store.reload()
        }
    }

    private func buildRoot() -> NSView {
        let root = RootView()

        // ── 液态玻璃底层：真正模糊窗口后面的内容 ──
        let glass = NSVisualEffectView()
        glass.material = .underWindowBackground   // 最通透的中性模糊
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.autoresizingMask = [.width, .height]
        root.addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false

        // 一层极薄白色薄雾：让玻璃更亮，但仍完全透明
        let veil = NSView()
        veil.wantsLayer = true
        // 偏暖的亮：奶油白，alpha 越大越亮
        // 保留一点暖调，但做到「几乎完全透明」
        veil.layer?.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.96, blue: 0.92, alpha: 0.05).cgColor
        root.addSubview(veil)
        veil.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            veil.topAnchor.constraint(equalTo: root.topAnchor),
            veil.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            veil.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            veil.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            glass.topAnchor.constraint(equalTo: root.topAnchor),
            glass.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        // ── 顶栏（固定，不随内容滚动）──
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.04).cgColor
        root.addSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false

        let brand = NSTextField(labelWithString: "🎬 JAVMovie")
        brand.font = Theme.font(13.5, .bold)
        brand.textColor = Theme.text

        dirButton.bezelStyle = .inline
        dirButton.isBordered = false
        dirButton.font = Theme.font(12, .medium)
        dirButton.contentTintColor = NSColor(calibratedWhite: 0.82, alpha: 1)
        dirButton.alignment = .left
        dirButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")
        dirButton.imagePosition = .imageLeading
        dirButton.target = self
        dirButton.action = #selector(showSettings)

        searchField.placeholderString = "搜索番号 / 文件名"
        searchField.font = Theme.font(12.5)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let tabs = TabBar(names: ["JAV", "国产", "短剧"])
        tabs.selected = activeTab
        tabs.onChange = { [weak self] index in
            guard let self else { return }
            self.activeTab = index
            UserDefaults.standard.set(index, forKey: "activeTab")
            self.applyTabRoot()
            self.reloadAll()
        }
        tabBar = tabs
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.heightAnchor.constraint(equalToConstant: 32).isActive = true
        tabs.widthAnchor.constraint(equalToConstant: tabs.preferredWidth).isActive = true

        let row = NSStackView(views: [brand, dirButton, tabs, NSView(), searchField])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(row)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 46),
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -18),
            row.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])

        // ── 一整页内容：精选 + 影库，一起滚 ──
        // 「我的最爱」那行标题栏按需求去掉，轮播直接顶到顶部
        let favHeader = NSView()
        favHeader.isHidden = true
        let libHeader = sectionRow(title: "影库", badge: libBadge, hint: "点击播放 · ★ 加入最爱")

        content = ContentDocumentView(favHeader: favHeader, libHeader: libHeader, carousel: carousel, grid: grid)
        carousel.onNeedPlay = { [weak self] movie, inApp in self?.play(movie, inApp: inApp) }
        carousel.onNeedToggle = { [weak self] movie in self?.toggle(movie) }
        grid.onNeedPlay = { [weak self] movie, inApp in self?.play(movie, inApp: inApp) }
        grid.onNeedToggle = { [weak self] movie in self?.toggle(movie) }
        grid.onNeedPreview = { [weak self] movie in self?.openShotViewer(movie) }
        grid.onNeedDelete = { [weak self] movie in self?.confirmDelete(movie) }
        carousel.onNeedPreview = { [weak self] movie in self?.openShotViewer(movie) }
        carousel.onNeedDelete = { [weak self] movie in self?.confirmDelete(movie) }

        contentScroll.documentView = content
        contentScroll.hasVerticalScroller = true
        contentScroll.autohidesScrollers = true
        contentScroll.drawsBackground = false
        contentScroll.verticalScrollElasticity = .allowed
        root.addSubview(contentScroll)

        guochangPage.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(guochangPage)
        guochangPage.isHidden = true

        duanjuPage.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(duanjuPage)
        duanjuPage.isHidden = true
        contentScroll.translatesAutoresizingMaskIntoConstraints = false

        // 读取不到目录时的提示条：红底容器 + 垂直居中的文字
        bannerBar.wantsLayer = true
        bannerBar.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.72).cgColor
        bannerBar.isHidden = true
        root.addSubview(bannerBar)
        bannerBar.translatesAutoresizingMaskIntoConstraints = false

        bannerLabel.stringValue = "⚠️  读不到影片"
        bannerLabel.font = Theme.font(11.5, .medium)
        bannerLabel.textColor = .white
        bannerLabel.alignment = .center
        bannerLabel.maximumNumberOfLines = 1
        bannerLabel.lineBreakMode = .byTruncatingTail
        bannerBar.addSubview(bannerLabel)
        bannerLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bannerLabel.leadingAnchor.constraint(equalTo: bannerBar.leadingAnchor, constant: 16),
            bannerLabel.trailingAnchor.constraint(equalTo: bannerBar.trailingAnchor, constant: -16),
            bannerLabel.centerYAnchor.constraint(equalTo: bannerBar.centerYAnchor),
        ])

        emptyHint.stringValue = "国产 · 暂无内容"
        emptyHint.font = Theme.font(15, .medium)
        emptyHint.textColor = NSColor(calibratedWhite: 1, alpha: 0.42)
        emptyHint.alignment = .center
        emptyHint.isHidden = true
        root.addSubview(emptyHint)
        emptyHint.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyHint.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyHint.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])

        toast.font = Theme.font(12.5, .medium)
        toast.textColor = .white
        toast.wantsLayer = true
        toast.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        toast.layer?.cornerRadius = 16
        toast.alignment = .center
        toast.alphaValue = 0
        root.addSubview(toast)
        toast.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            duanjuPage.topAnchor.constraint(equalTo: contentScroll.topAnchor),
            duanjuPage.bottomAnchor.constraint(equalTo: contentScroll.bottomAnchor),
            duanjuPage.leadingAnchor.constraint(equalTo: contentScroll.leadingAnchor),
            duanjuPage.trailingAnchor.constraint(equalTo: contentScroll.trailingAnchor),
            guochangPage.topAnchor.constraint(equalTo: contentScroll.topAnchor),
            guochangPage.bottomAnchor.constraint(equalTo: contentScroll.bottomAnchor),
            guochangPage.leadingAnchor.constraint(equalTo: contentScroll.leadingAnchor),
            guochangPage.trailingAnchor.constraint(equalTo: contentScroll.trailingAnchor),
            contentScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            contentScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            bannerBar.topAnchor.constraint(equalTo: header.bottomAnchor),
            bannerBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bannerBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bannerBar.heightAnchor.constraint(equalToConstant: 30),

            toast.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28),
            toast.heightAnchor.constraint(equalToConstant: 34),
            toast.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        return root
    }

    private func sectionRow(title: String, badge: NSTextField, hint: String) -> NSView {
        let row = PassThroughView()
        let t = NSTextField(labelWithString: title)
        t.font = Theme.font(11.5, .semibold)
        t.textColor = NSColor.white.withAlphaComponent(0.9)
        badge.font = Theme.font(10, .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = Theme.accentA.cgColor
        badge.layer?.cornerRadius = 8
        let h = NSTextField(labelWithString: hint)
        h.font = Theme.font(11)
        h.textColor = Theme.dim
        for v in [t, badge, h] { v.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(v) }
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            t.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: t.trailingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
            badge.heightAnchor.constraint(equalToConstant: 16),
            h.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            h.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    // MARK: 数据

    private func bindStore() {
        store.$movies
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reloadAll() }
            .store(in: &cancellables)
        store.$favorites
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reloadAll() }
            .store(in: &cancellables)
    }

    func reloadAll() {
        let favs = store.favoriteMovies
        let shown = store.visibleMovies

        dirButton.title = " 设置"

        carousel.reload(movies: favs, favorites: Set(store.favorites))
        carousel.focus(min(2, max(0, favs.count - 1)), animated: false)
        grid.reload(movies: shown, favorites: Set(store.favorites))

        libBadge.stringValue = " \(shown.count) "

        let tabEmpty = false
        emptyHint.isHidden = !tabEmpty
        emptyHint.stringValue = tabEmpty ? "国产 · 这个目录里还没找到视频文件" : ""

        let empty = store.movies.isEmpty
        if empty {
            let detail = store.lastError ?? "扫描结果为 0（目录可能是空的）"
            bannerLabel.stringValue = "⚠️  读不到影片：\(detail)   ·   系统设置 → 隐私与安全性 → 文件与文件夹 → 允许 JAVMovie 访问可移除宗卷，再点「刷新」"
        } else {
            bannerLabel.stringValue = ""
        }
        bannerBar.isHidden = !empty
        contentScroll.contentInsets = NSEdgeInsets(top: empty ? 32 : 0, left: 0, bottom: 0, right: 0)

        layoutContent()
    }

    private func layoutContent() {
        guard let content else { return }
        content.relayout(viewportWidth: contentScroll.contentSize.width,
                         viewportHeight: contentScroll.contentSize.height)
        carousel.needsLayout = true
        carousel.layoutSubtreeIfNeeded()
        grid.needsLayout = true
        grid.layoutSubtreeIfNeeded()
    }

    // MARK: 删除（移到废纸篓）

    func confirmDelete(_ movie: Movie) {
        let folder = movie.folder
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除这个视频的文件夹？"
        alert.informativeText = "\(folder.lastPathComponent)\n\n会把整个文件夹移到废纸篓（可在废纸篓里还原）。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            var trashURL: NSURL?
            do {
                try FileManager.default.trashItem(at: folder, resultingItemURL: &trashURL)
                self.showToast("已移到废纸篓：\(folder.lastPathComponent)")
                self.store.reload()
            } catch {
                let fail = NSAlert()
                fail.messageText = "删除失败"
                fail.informativeText = error.localizedDescription
                fail.beginSheetModal(for: self.window)
            }
        }
    }

    // MARK: 剧照浏览器（居中）

    private func openShotViewer(_ movie: Movie) {
        hideShotViewer()
        guard let root = window.contentView else { return }
        let viewer = ShotViewer(frame: root.bounds)
        viewer.autoresizingMask = [.width, .height]
        viewer.show(movie: movie, startingAt: 0)
        viewer.onClose = { [weak self] in self?.hideShotViewer() }
        root.addSubview(viewer)
        viewer.needsLayout = true
        viewer.layoutSubtreeIfNeeded()
        shotViewer = viewer
        window.makeFirstResponder(viewer)
        viewer.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            viewer.animator().alphaValue = 1
        }
    }

    private func hideShotViewer() {
        guard let viewer = shotViewer else { return }
        shotViewer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            viewer.animator().alphaValue = 0
        }, completionHandler: {
            viewer.removeFromSuperview()
            self.window.makeFirstResponder(nil)
        })
    }

    private func play(_ movie: Movie, inApp: Bool) {
        if inApp {
            openInternalPlayer(movie)
        } else {
            store.play(movie)
            showToast(store.message ?? "")
        }
    }

    private func toggle(_ movie: Movie) {
        store.toggleFavorite(movie)
        reloadAll()
    }

    private func showToast(_ text: String) {
        guard !text.isEmpty else { return }
        toast.stringValue = "  \(text)  "
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            toast.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                self.toast.animator().alphaValue = 0
            }
        }
    }

    // MARK: 内置播放器

    private func openInternalPlayer(_ movie: Movie) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "\(movie.code) · \(movie.title)"
        win.appearance = NSAppearance(named: .darkAqua)
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = AVPlayer(url: movie.url)
        win.contentView = view
        win.center()
        win.makeKeyAndOrderFront(nil)
        view.player?.play()
        playerWindow = win
        playerView = view
    }

    // MARK: 动作

    // MARK: 设置

    @objc func showSettings() {
        let panel = SettingsPanel(javPath: javRoot.path, guochangPath: guochangRoot.path)
        panel.onConfirm = { [weak self] javPath, guochangPath in
            guard let self else { return }
            if !javPath.isEmpty {
                self.javRoot = URL(fileURLWithPath: javPath)
                UserDefaults.standard.set(javPath, forKey: "root")
            }
            if !guochangPath.isEmpty {
                self.guochangRoot = URL(fileURLWithPath: guochangPath)
                UserDefaults.standard.set(guochangPath, forKey: "rootGuochang")
            }
            self.applyTabRoot()
            self.store.favorites = []
            self.store.reload()
            self.showToast("已切换数据源，正在校验…")
            // 校验 + 补全元数据（进度显示在弹窗里）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.runMetadataSync()
            }
        }
        window.beginSheet(panel)
    }

    /// 按当前 Tab 切换数据源目录
    private func applyTabRoot() {
        let tab = activeTab
        contentScroll.isHidden = tab != 0
        guochangPage.isHidden = tab != 1
        duanjuPage.isHidden = tab != 2

        switch tab {
        case 0:
            let target = javRoot
            if store.root.standardizedFileURL != target.standardizedFileURL {
                store.root = target
                store.reload()
            }
        case 1:
            guochangPage.load(root: guochangRoot)   // 独立页面，自己扫描自己渲染
        default:
            if duanjuPage.url == nil { duanjuPage.load() }   // 短剧：嵌入网页
        }
    }

    @objc func refreshFromMenu() { store.reload() }

    // MARK: 元数据检查 / 补全（后台跑 javdb.py，前台显示进度）

    private func javdbScriptPath() -> URL? {
        if let p = UserDefaults.standard.string(forKey: "javdbScript"), FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        let candidates = [
            "/Users/qizhibang/deepseekWork/javdb.py",
            FileManager.default.currentDirectoryPath + "/javdb.py",
            Bundle.main.bundlePath + "/../../javdb.py",
        ].map { URL(fileURLWithPath: $0).standardizedFileURL }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @objc func openCookieWindow() {
        let catcher = CookieWindow()
        catcher.onDone = { [weak self] jar, ua in
            guard let self else { return }
            UserDefaults.standard.set(jar, forKey: "javdbCookie")
            if !ua.isEmpty { UserDefaults.standard.set(ua, forKey: "javdbUA") }
            self.cookieWindow = nil
            self.showToast("已保存 JavDB Cookie（\(jar.count) 字节），开始补全…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.runMetadataSync() }
        }
        cookieWindow = catcher
        catcher.show(attachedTo: window)
    }

    @objc func runMetadataSync() {
        guard syncProcess == nil else { return }
        guard let script = javdbScriptPath() else {
            showToast("找不到 javdb.py，可用 defaults write local.javmovie.native javdbScript <路径> 指定")
            return
        }

        let panel = SyncPanel()
        panel.onAction = { [weak self] in
            guard let self else { return }
            if self.syncProcess != nil {
                self.syncProcess?.terminate()      // 取消
                panel.append("⏹ 已请求取消…")
            } else {
                self.window.endSheet(panel)
                self.syncPanel = nil
                self.store.reload()
            }
        }
        syncPanel = panel
        window.beginSheet(panel)
        panel.append("脚本: \(script.path)")
        panel.append("目录: \(store.root.path)")
        panel.append("")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var syncArgs = ["python3", "-u", script.path, store.root.path, "--concurrency", "2"]
        if let cookie = UserDefaults.standard.string(forKey: "javdbCookie"), !cookie.isEmpty {
            syncArgs += ["--cookie", cookie]
        }
        if let proxy = UserDefaults.standard.string(forKey: "javdbProxy"), !proxy.isEmpty {
            syncArgs += ["--proxy", proxy]
        }
        if let ua = UserDefaults.standard.string(forKey: "javdbUA"), !ua.isEmpty {
            syncArgs += ["--ua", ua]
        }
        proc.arguments = syncArgs
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        let lineBuffer = LineBuffer()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for raw in lineBuffer.appendAndDrain(data) {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                DispatchQueue.main.async {
                    panel.append(trimmed)
                    if trimmed.contains("403") && !panel.didHintCloudflare {
                        panel.didHintCloudflare = true
                        panel.append("💡 403 = Cloudflare 拦截。用浏览器打开 javdb.com 通过验证后，")
                        panel.append("   复制 Cookie 执行：defaults write local.javmovie.native javdbCookie \"cf_clearance=...\"")
                        panel.append("   然后按 ⌘M 重跑；或用代理：defaults write local.javmovie.native javdbProxy http://127.0.0.1:7890")
                    }
                    if let r = trimmed.range(of: #"\[(\d+)/(\d+)\]"#, options: .regularExpression) {
                        let nums = trimmed[r].dropFirst().dropLast().split(separator: "/")
                        if nums.count == 2, let cur = Double(nums[0]), let tot = Double(nums[1]) {
                            panel.setProgress(cur, total: tot, detail: "已处理 \(Int(cur)) / \(Int(tot)) 项")
                        }
                    }
                }
            }
        }

        proc.terminationHandler = { p in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.syncProcess = nil
                let ok = p.terminationStatus == 0
                panel.finish(ok ? "检查与补全结束，正在刷新影库…" : "进程退出码 \(p.terminationStatus)")
                panel.append("")
                panel.append(ok ? "✅ 全部完成" : "⚠️ 退出码 \(p.terminationStatus)")
                self.store.reload()
            }
        }

        do {
            try proc.run()
            syncProcess = proc
        } catch {
            panel.finish("启动失败: \(error.localizedDescription)")
        }
    }

    func setSort(_ mode: LibraryStore.SortMode) {
        store.sort = mode
        reloadAll()
    }

    func setPlayer(_ name: String) {
        store.playerName = name
        reloadAll()
    }

    func controlTextDidChange(_ obj: Notification) {
        store.query = searchField.stringValue
        grid.reload(movies: store.visibleMovies, favorites: Set(store.favorites))
        libBadge.stringValue = " \(store.visibleMovies.count) "
        layoutContent()
    }

    func windowDidResize(_ notification: Notification) {
        layoutContent()
    }
}

// MARK: - 背景与容器

final class RootView: NSView {
    // 背景由 NSVisualEffectView + GlassTintView 负责，这里保持完全透明
}

/// 不吞鼠标事件的透明容器
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
