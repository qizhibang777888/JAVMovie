import AppKit
import AVFoundation

/// 「国产」独立页面：不碰 JAV 那套框架，只做“视频 → 卡片（首帧 + 文件名）”
final class GuochangPage: NSView {

    private let scroll = NSScrollView()
    private let canvas = FlippedView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var cards: [CardView] = []
    private var rootURL = URL(fileURLWithPath: "/")

    private let inset: CGFloat = 24
    private let gapX: CGFloat = 34
    private let gapY: CGFloat = 34
    private let columns = 4

    var onPlay: ((Movie, Bool) -> Void)?
    var onPreview: ((Movie) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .allowed
        scroll.documentView = canvas
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        emptyLabel.stringValue = "这个目录里还没找到视频"
        emptyLabel.font = Theme.font(15, .medium)
        emptyLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.42)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 载入

    func load(root: URL) {
        rootURL = root
        cards.forEach { $0.removeFromSuperview() }
        cards = []
        canvas.subviews.forEach { $0.removeFromSuperview() }
        emptyLabel.isHidden = true

        Task {
            Scanner.plainMode = true                       // 不读 TX.json / 不找封面
            let found = await Task.detached(priority: .userInitiated) {
                Scanner.scan(root: root, deep: true)       // 递归整棵树
            }.value
            Scanner.plainMode = false
            self.build(with: found)
        }
    }

    private func build(with movies: [Movie]) {
        guard !movies.isEmpty else {
            emptyLabel.isHidden = false
            canvas.frame = .zero
            return
        }
        emptyLabel.isHidden = true

        cards = movies.map { m in
            let card = CardView(movie: m, favorite: false, width: 326)
            card.plainTitle = Self.displayTitle(for: m, root: rootURL)
            card.plain = true
            card.onPlay = { [weak self] inApp in self?.onPlay?(m, inApp) }
            card.onPreview = { [weak self] in self?.onPreview?(m) }
            card.onDelete = { [weak self] in self?.confirmDelete(m) }
            canvas.addSubview(card)
            return card
        }
        canvas.needsLayout = true
        layoutCards()
    }

    /// 文件名没意义时（mp4_ (1).mp4 之类）改用「相对路径」，比单看上级目录名有用
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

        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var rel = m.url.path
        if rel.hasPrefix(prefix) { rel = String(rel.dropFirst(prefix.count)) }
        let noExt = (rel as NSString).deletingPathExtension
        return noExt.isEmpty ? m.displayName : noExt
    }

    // MARK: 删除

    private func confirmDelete(_ m: Movie) {
        let folder = m.folder
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除这个视频的文件夹？"
        alert.informativeText = "\(folder.lastPathComponent)\n\n会把整个文件夹移到废纸篓（可在废纸篓里还原）。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            guard let self else { return }
            var trashURL: NSURL?
            do {
                try FileManager.default.trashItem(at: folder, resultingItemURL: &trashURL)
                self.showToast("已移到废纸篓：\(folder.lastPathComponent)")
                self.load(root: self.rootURL)
            } catch {
                let fail = NSAlert()
                fail.messageText = "删除失败"
                fail.informativeText = error.localizedDescription
                if let window = self.window { fail.beginSheetModal(for: window) }
            }
        }
    }

    private func showToast(_ text: String) {
        let toast = NSTextField(labelWithString: "  \(text)  ")
        toast.font = Theme.font(12, .medium)
        toast.textColor = .white
        toast.wantsLayer = true
        toast.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        toast.layer?.cornerRadius = 10
        toast.sizeToFit()
        toast.frame.origin = NSPoint(x: bounds.midX - toast.frame.width / 2, y: bounds.maxY - 60)
        addSubview(toast)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            toast.removeFromSuperview()
        }
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        layoutCards()
    }

    private func layoutCards() {
        guard !cards.isEmpty else { return }
        let width = scroll.contentView.bounds.width > 0 ? scroll.contentView.bounds.width : bounds.width
        guard width > 0 else { return }

        let usable = max(200, width - inset * 2)
        let cols = min(columns, cards.count)
        let cardW = ((usable - CGFloat(cols - 1) * gapX) / CGFloat(cols)).rounded(.down)
        let cardH = CardView.height(forWidth: cardW)
        let rows = (cards.count + cols - 1) / cols
        let totalH = CGFloat(12) + CGFloat(rows) * cardH + CGFloat(max(0, rows - 1)) * gapY + 40

        if canvas.frame.size != NSSize(width: width, height: totalH) {
            canvas.frame = NSRect(x: 0, y: 0, width: width, height: totalH)
        }
        for (i, card) in cards.enumerated() {
            let c = i % cols, r = i / cols
            let frame = NSRect(x: inset + CGFloat(c) * (cardW + gapX),
                               y: CGFloat(12) + CGFloat(r) * (cardH + gapY),
                               width: cardW, height: cardH)
            if card.frame != frame { card.frame = frame }
        }
    }
}
