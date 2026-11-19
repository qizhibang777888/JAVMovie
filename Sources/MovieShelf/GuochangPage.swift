import AppKit
import AVFoundation
import AVKit

/// 「国产」页面：左边文件夹树/收藏列表，右边内嵌播放
final class GuochangPage: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {

    private enum Mode { case favorites, all }

    private final class Node: NSObject {
        let url: URL
        let name: String
        let isFolder: Bool
        var children: [Node] = []
        var movie: Movie?

        init(url: URL, name: String, isFolder: Bool, movie: Movie? = nil) {
            self.url = url
            self.name = name
            self.isFolder = isFolder
            self.movie = movie
        }
    }

    /// 列表行：图标 + 名称 + 右侧收藏星
    private final class FileCell: NSTableCellView {
        let starButton = NSButton()
        let deleteButton = NSButton()
        var onStar: (() -> Void)?
        var onDelete: (() -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let icon = NSImageView()
            let label = NSTextField(labelWithString: "")
            label.font = Theme.font(12)
            label.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
            label.lineBreakMode = .byTruncatingMiddle
            addSubview(icon)
            addSubview(label)
            imageView = icon
            textField = label

            starButton.isBordered = false
            starButton.imagePosition = .imageOnly
            starButton.imageScaling = .scaleProportionallyDown
            starButton.target = self
            starButton.action = #selector(starTapped)
            starButton.toolTip = "收藏 / 取消收藏"
            addSubview(starButton)

            deleteButton.isBordered = false
            deleteButton.imagePosition = .imageOnly
            deleteButton.imageScaling = .scaleProportionallyDown
            deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
            deleteButton.contentTintColor = NSColor(calibratedRed: 1, green: 0.45, blue: 0.45, alpha: 0.95)
            deleteButton.target = self
            deleteButton.action = #selector(deleteTapped)
            addSubview(deleteButton)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            let h = bounds.height
            imageView?.frame = NSRect(x: 2, y: (h - 16) / 2, width: 16, height: 16)
            let deleteW: CGFloat = 24
            let starW: CGFloat = starButton.isHidden ? 0 : 22
            starButton.frame = NSRect(x: 24, y: (h - 20) / 2, width: 20, height: 20)
            deleteButton.frame = NSRect(x: bounds.width - deleteW, y: (h - 20) / 2, width: 20, height: 20)
            let labelX = 24 + starW
            textField?.frame = NSRect(x: labelX, y: (h - 16) / 2,
                                      width: bounds.width - labelX - deleteW - 4, height: 16)
        }

        @objc private func starTapped() { onStar?() }
        @objc private func deleteTapped() { onDelete?() }
    }

    private let split = NSSplitView()
    private let sidebar = NSView()
    private let modeControl = NSSegmentedControl(labels: ["收藏", "全部"],
                                                 trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let outline = NSOutlineView()
    private let sidebarScroll = NSScrollView()
    private let listEmpty = NSTextField(labelWithString: "")
    private let playerPanel = NSView()

    private let titleLabel = NSTextField(labelWithString: "从左边选择一个视频")
    private let detailLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private let player = AVPlayerView()
    private let hintLabel = NSTextField(labelWithString: "左侧列表选视频 · 直接在这里播放")

    private var mode: Mode = .all
    private var rootNode: Node?
    private var rootURL = URL(fileURLWithPath: "/")
    private var allMovies: [Movie] = []
    private var favorites: Set<String> = []
    private var currentMovie: Movie?

    /// 仍然保留给「用 IINA 打开」用
    var onPlay: ((Movie, Bool) -> Void)?
    var onPreview: ((Movie) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        favorites = Set(UserDefaults.standard.stringArray(forKey: "guochangFavorites") ?? [])
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(split)

        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // ── 左侧 ──
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.03).cgColor
        split.addArrangedSubview(sidebar)

        modeControl.selectedSegment = 1
        modeControl.segmentStyle = .rounded
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(modeControl)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "名称"
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 26
        outline.indentationPerLevel = 14
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.autoresizingMask = [.width]

        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.documentView = outline
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarScroll)

        listEmpty.stringValue = "还没有收藏，在「全部」里点 ☆"
        listEmpty.font = Theme.font(12)
        listEmpty.textColor = Theme.dim
        listEmpty.alignment = .center
        listEmpty.isHidden = true
        listEmpty.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(listEmpty)

        NSLayoutConstraint.activate([
            modeControl.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 12),
            modeControl.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            modeControl.widthAnchor.constraint(equalToConstant: 150),

            sidebarScroll.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 8),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),

            listEmpty.centerXAnchor.constraint(equalTo: sidebarScroll.centerXAnchor),
            listEmpty.topAnchor.constraint(equalTo: sidebarScroll.topAnchor, constant: 40),

            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
        let width = sidebar.widthAnchor.constraint(equalToConstant: 320)
        width.priority = .defaultHigh
        width.isActive = true

        // ── 右侧：播放器 ──
        playerPanel.wantsLayer = true
        playerPanel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        split.addArrangedSubview(playerPanel)

        titleLabel.font = Theme.font(13.5, .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        playerPanel.addSubview(titleLabel)

        detailLabel.font = Theme.font(11)
        detailLabel.textColor = Theme.dim
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        playerPanel.addSubview(detailLabel)

        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.font = Theme.font(11.5, .medium)
        openButton.translatesAutoresizingMaskIntoConstraints = false
        playerPanel.addSubview(openButton)
        openButton.title = "用 IINA 打开"
        openButton.target = self
        openButton.action = #selector(openExternal)
        openButton.isEnabled = false

        player.controlsStyle = .floating
        player.videoGravity = .resizeAspect
        player.wantsLayer = true
        player.layer?.backgroundColor = NSColor.black.cgColor
        player.isHidden = true
        player.translatesAutoresizingMaskIntoConstraints = false
        playerPanel.addSubview(player)

        hintLabel.font = Theme.font(12.5)
        hintLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.4)
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        playerPanel.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: playerPanel.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: playerPanel.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -12),

            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -12),

            openButton.trailingAnchor.constraint(equalTo: playerPanel.trailingAnchor, constant: -16),
            openButton.topAnchor.constraint(equalTo: playerPanel.topAnchor, constant: 12),

            player.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 10),
            player.leadingAnchor.constraint(equalTo: playerPanel.leadingAnchor, constant: 12),
            player.trailingAnchor.constraint(equalTo: playerPanel.trailingAnchor, constant: -12),
            player.bottomAnchor.constraint(equalTo: playerPanel.bottomAnchor, constant: -12),

            hintLabel.centerXAnchor.constraint(equalTo: player.centerXAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: player.centerYAnchor),
        ])
    }

    // MARK: - 载入

    func load(root: URL) {
        rootURL = root
        stopPlayback()
        titleLabel.stringValue = "从左边选择一个视频"
        detailLabel.stringValue = ""
        openButton.isEnabled = false

        Task {
            Scanner.plainMode = true                       // 不读 TX.json / 不找封面
            let found = await Task.detached(priority: .userInitiated) {
                await Scanner.scan(root: root, deep: true) // 递归整棵树
            }.value
            Scanner.plainMode = false
            self.allMovies = found
            self.pruneFavorites()
            self.rebuild()
        }
    }

    private func pruneFavorites() {
        let ids = Set(allMovies.map(\.id))
        let kept = favorites.intersection(ids)
        if kept != favorites {
            favorites = kept
            saveFavorites()
        }
    }

    private func saveFavorites() {
        UserDefaults.standard.set(Array(favorites), forKey: "guochangFavorites")
    }

    @objc private func modeChanged() {
        mode = modeControl.selectedSegment == 0 ? .favorites : .all
        rebuild()
    }

    private func rebuild() {
        let builder = Node(url: rootURL, name: rootURL.lastPathComponent, isFolder: true)

        switch mode {
        case .all:
            var folders: [String: Node] = [rootURL.path: builder]
            for movie in allMovies.sorted(by: { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }) {
                let rel = relativePath(movie.url.path, root: rootURL.path)
                let parts = rel.split(separator: "/").map(String.init)
                guard !parts.isEmpty else { continue }

                var parent = builder
                var walked = rootURL.path
                for folder in parts.dropLast() {
                    walked += "/" + folder
                    if let hit = folders[walked] {
                        parent = hit
                    } else {
                        let node = Node(url: URL(fileURLWithPath: walked), name: folder, isFolder: true)
                        parent.children.append(node)
                        folders[walked] = node
                        parent = node
                    }
                }
                parent.children.append(Node(url: movie.url,
                                            name: Self.displayTitle(for: movie, root: rootURL),
                                            isFolder: false, movie: movie))
            }
            sortChildren(builder)

        case .favorites:
            let picked = allMovies.filter { favorites.contains($0.id) }
                .sorted { Self.displayTitle(for: $0, root: rootURL)
                    .localizedStandardCompare(Self.displayTitle(for: $1, root: rootURL)) == .orderedAscending }
            for movie in picked {
                let title = Self.displayTitle(for: movie, root: rootURL)
                let node = Node(url: movie.url,
                                name: title,
                                isFolder: false, movie: movie)
                builder.children.append(node)
            }
        }

        rootNode = builder
        outline.reloadData()
        if mode == .all {
            for child in builder.children where child.isFolder { outline.expandItem(child) }
        }
        listEmpty.isHidden = !builder.children.isEmpty || mode == .all
        hintLabel.isHidden = false
        player.isHidden = true
    }

    private func sortChildren(_ node: Node) {
        node.children.sort { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        for child in node.children where child.isFolder { sortChildren(child) }
    }

    private func relativePath(_ path: String, root: String) -> String {
        var base = root
        if !base.hasSuffix("/") { base += "/" }
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    // MARK: - 播放

    private func play(_ node: Node) {
        guard let movie = node.movie else { return }
        titleLabel.stringValue = node.name
        detailLabel.stringValue = movie.url.deletingLastPathComponent().path
        openButton.isEnabled = true
        hintLabel.isHidden = true
        player.isHidden = false

        player.player?.pause()
        player.player = AVPlayer(playerItem: AVPlayerItem(url: movie.url))
        player.player?.play()
    }

    func stopPlayback() {
        player.player?.pause()
        player.player = nil
        player.isHidden = true
        hintLabel.isHidden = false
        titleLabel.stringValue = "从左边选择一个视频"
        detailLabel.stringValue = ""
    }

    @objc private func openExternal() {
        guard let movie = currentMovieForAction() else { return }
        onPlay?(movie, false)
    }

    private func currentMovieForAction() -> Movie? {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return nil }
        return node.movie
    }

    // MARK: - 删除（文件 / 文件夹）

    private func confirmDeleteFile(_ movie: Movie) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除这个视频文件？"
        alert.informativeText = "\(movie.url.lastPathComponent)\n\n只会把这个视频文件移到废纸篓（可在废纸篓里还原），文件夹和其它文件不受影响。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            var trashURL: NSURL?
            do {
                try FileManager.default.trashItem(at: movie.url, resultingItemURL: &trashURL)
                if self.currentMovieForAction()?.id == movie.id { self.stopPlayback() }
                self.load(root: self.rootURL)
            } catch {
                self.showDeleteError(error)
            }
        }
    }

    private func confirmDeleteFolder(_ url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除这个文件夹？"
        alert.informativeText = "\(url.lastPathComponent)\n\n文件夹和里面的所有内容都会一起移到废纸篓（可在废纸篓里还原）。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            var trashURL: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
                self.stopPlayback()
                self.load(root: self.rootURL)
            } catch {
                self.showDeleteError(error)
            }
        }
    }

    private func showDeleteError(_ error: Error) {
        let fail = NSAlert()
        fail.messageText = "删除失败"
        fail.informativeText = error.localizedDescription
        if let window { fail.beginSheetModal(for: window) }
    }

    // MARK: - 收藏

    private func toggleFavorite(_ movie: Movie) {
        if favorites.contains(movie.id) {
            favorites.remove(movie.id)
        } else {
            favorites.insert(movie.id)
        }
        saveFavorites()
        rebuild()
    }

    // MARK: - 列表数据

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? Node { return node.children.count }
        return rootNode?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? Node { return node.children[index] }
        return rootNode!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return node.isFolder && !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("fileCell")
        let cell: FileCell
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? FileCell {
            cell = reused
        } else {
            cell = FileCell()
            cell.identifier = id
        }

        cell.textField?.stringValue = node.name
        cell.textField?.toolTip = node.url.path

        cell.deleteButton.isHidden = false
        if node.isFolder {
            cell.imageView?.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            cell.imageView?.contentTintColor = NSColor(calibratedRed: 0.62, green: 0.75, blue: 1, alpha: 1)
            cell.starButton.isHidden = true
            cell.onStar = nil
            cell.deleteButton.toolTip = "删除文件夹（含全部内容）"
            cell.onDelete = { [weak self] in self?.confirmDeleteFolder(node.url) }
        } else {
            cell.imageView?.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
            cell.imageView?.contentTintColor = NSColor(calibratedWhite: 0.75, alpha: 1)
            cell.starButton.isHidden = false
            let saved = node.movie.map { favorites.contains($0.id) } ?? false
            cell.starButton.image = NSImage(systemSymbolName: saved ? "star.fill" : "star",
                                            accessibilityDescription: "收藏")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
            cell.starButton.contentTintColor = saved
                ? Theme.gold
                : NSColor(calibratedWhite: 0.55, alpha: 1)
            cell.onStar = { [weak self] in
                guard let self, let movie = node.movie else { return }
                self.toggleFavorite(movie)
            }
            cell.deleteButton.toolTip = "删除这个视频文件"
            cell.onDelete = { [weak self] in
                guard let self, let movie = node.movie else { return }
                self.confirmDeleteFile(movie)
            }
        }
        cell.needsLayout = true
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let selected = outline.selectedRow
        guard selected >= 0, let node = outline.item(atRow: selected) as? Node else { return }
        if !node.isFolder { play(node) }
    }

    /// 文件名没意义时（mp4_ (1).mp4 之类）改用相对路径
    static func displayTitle(for m: Movie, root: URL) -> String {
        let raw = m.displayName.trimmingCharacters(in: .whitespaces)
        let lower = raw.lowercased()
        let generic = raw.count < 5
            || lower.hasPrefix("mp4")
            || lower.hasPrefix("video")
            || lower.hasPrefix("movie")
            || lower.hasPrefix("vlc")
            || raw.allSatisfy { $0.isNumber || $0 == "_" || $0 == "-" || $0 == " " }
        guard generic else { return raw }
        var base = root.path
        if !base.hasSuffix("/") { base += "/" }
        var rel = m.url.path
        if rel.hasPrefix(base) { rel = String(rel.dropFirst(base.count)) }
        return rel.isEmpty ? m.displayName : rel
    }
}
