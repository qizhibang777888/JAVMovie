import AppKit
import AVFoundation

// MARK: - 主题

enum Theme {
    static let bg = NSColor(calibratedRed: 0.035, green: 0.040, blue: 0.055, alpha: 1)
    static let panel = NSColor(calibratedWhite: 1, alpha: 0.05)
    static let line = NSColor(calibratedWhite: 1, alpha: 0.09)
    static let text = NSColor(calibratedRed: 0.92, green: 0.94, blue: 0.98, alpha: 1)
    static let dim = NSColor(calibratedRed: 0.58, green: 0.62, blue: 0.71, alpha: 1)
    static let accentA = NSColor(calibratedRed: 0.486, green: 0.361, blue: 1.0, alpha: 1)
    static let accentB = NSColor(calibratedRed: 1.0, green: 0.361, blue: 0.478, alpha: 1)
    static let gold = NSColor(calibratedRed: 1.0, green: 0.784, blue: 0.341, alpha: 1)

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
    static func gradient(_ layer: CAGradientLayer, _ a: NSColor, _ b: NSColor) {
        layer.colors = [a.cgColor, b.cgColor]
        layer.startPoint = CGPoint(x: 0, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 0.5)
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 封面加载

enum CoverLoader {
    nonisolated(unsafe) static let cache = NSCache<NSURL, NSImage>()

    /// 同步读图（有 NSCache，30 张量级开销可忽略）
    static func image(_ url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let img = NSImage(contentsOf: url) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }

    static func apply(_ url: URL?, to view: NSView) {
        guard let img = image(url) else { return }
        view.layer?.contents = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

// MARK: - 卡片

final class CardView: NSView {
    let movie: Movie
    private let coverView = NSView()
    private let shineLayer = CAGradientLayer()
    private let codeBadge = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let starButton = NSButton()
    private let playButton = NSButton()
    private let dimOverlay = NSView()
    private let deleteButton = NSButton()
    private var trackingAreaRef: NSTrackingArea?

    var onPlay: ((_ inApp: Bool) -> Void)?      // 点圆形播放键
    var onPreview: (() -> Void)?                 // 点封面本体 → 看剧照
    var onToggleFavorite: (() -> Void)?
    var onDelete: (() -> Void)?
    /// 在轮播里设为 true：鼠标事件上抛给 CarouselView（支持从封面开始拖拽）
    var forwardsMouseToSuperview = false
    var plain = false { didSet { applyPlain() } }
    /// 纯视频模式下显示的名字（国产那边文件名常常是 mp4_ (1).mp4 这种，用上级目录名更好认）
    var plainTitle: String?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var isFlipped: Bool { true }

    static func height(forWidth w: CGFloat) -> CGFloat { (w * 2 / 3).rounded() + 46 }

    init(movie: Movie, favorite: Bool, width: CGFloat) {
        self.movie = movie
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height(forWidth: width)))
        wantsLayer = true
        layer?.masksToBounds = false
        build()
        setFavorite(favorite)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyPlain() {
        guard plain else { return }
        codeBadge.isHidden = true
        subLabel.isHidden = true
        titleLabel.stringValue = plainTitle ?? movie.displayName
        // 没有封面就用视频首帧当缩略图
        if movie.cover == nil {
            VideoThumb.load(movie.url, position: .middle) { [weak self] image in
                guard let self, let image else { return }
                var rect = CGRect(origin: .zero, size: image.size)
                if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                    self.coverView.layer?.contents = cg
                }
            }
        }
    }

    private func build() {
        coverView.wantsLayer = true
        coverView.layer?.cornerRadius = 12
        coverView.layer?.masksToBounds = true
        coverView.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1).cgColor
        coverView.layer?.borderWidth = 1
        coverView.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.07).cgColor
        addSubview(coverView)
        CoverLoader.apply(movie.cover, to: coverView)

        shineLayer.colors = [NSColor.black.withAlphaComponent(0).cgColor,
                             NSColor.black.withAlphaComponent(0.55).cgColor]
        shineLayer.startPoint = CGPoint(x: 0.5, y: 0.45)
        shineLayer.endPoint = CGPoint(x: 0.5, y: 1)
        coverView.layer?.addSublayer(shineLayer)

        codeBadge.stringValue = movie.code.isEmpty ? movie.url.pathExtension.uppercased() : movie.code
        codeBadge.font = Theme.mono(11, .semibold)
        codeBadge.textColor = .white
        codeBadge.wantsLayer = true
        codeBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        codeBadge.layer?.cornerRadius = 6
        codeBadge.alignment = .center
        addSubview(codeBadge)

        deleteButton.isBordered = false
        deleteButton.bezelStyle = .regularSquare
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        deleteButton.contentTintColor = NSColor(calibratedWhite: 1, alpha: 0.9)
        deleteButton.wantsLayer = true
        deleteButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        deleteButton.layer?.cornerRadius = 13
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        addSubview(deleteButton)

        starButton.isBordered = false
        starButton.imagePosition = .imageOnly
        starButton.contentTintColor = Theme.dim
        starButton.target = self
        starButton.action = #selector(toggleFavorite)
        addSubview(starButton)

        playButton.isBordered = false
        playButton.bezelStyle = .regularSquare
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "播放")
        playButton.contentTintColor = .white
        playButton.wantsLayer = true
        playButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        playButton.layer?.cornerRadius = 30
        playButton.layer?.borderWidth = 1
        playButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        playButton.imageScaling = .scaleProportionallyDown
        playButton.alphaValue = 0
        playButton.target = self
        playButton.action = #selector(activate)
        addSubview(playButton)

        dimOverlay.wantsLayer = true
        dimOverlay.layer?.backgroundColor = NSColor.black.cgColor
        dimOverlay.alphaValue = 0
        addSubview(dimOverlay)

        titleLabel.stringValue = movie.title
        titleLabel.font = Theme.font(12.5)
        titleLabel.textColor = Theme.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)

        subLabel.stringValue = subtitle
        subLabel.font = Theme.font(11)
        subLabel.textColor = Theme.dim
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.maximumNumberOfLines = 1
        addSubview(subLabel)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let maker = movie.maker, !maker.isEmpty { parts.append(maker) }
        if let score = movie.score { parts.append(String(format: "★%.2f", score)) }
        parts.append(movie.sizeText)
        if let res = movie.resolution { parts.append(res) }
        if let d = movie.duration {
            let t = Int(d.rounded()), h = t / 3600, m = (t % 3600) / 60, s = t % 60
            parts.append(h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s))
        }
        return parts.joined(separator: " · ")
    }

    func setLabelsVisible(_ visible: Bool) {
        titleLabel.isHidden = !visible
        subLabel.isHidden = !visible
    }

    func setFavorite(_ on: Bool) {
        let name = on ? "star.fill" : "star"
        starButton.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        starButton.contentTintColor = on ? Theme.gold : NSColor.white.withAlphaComponent(0.65)
    }

    /// 0 = 原样，1 = 全黑
    func setDim(_ level: CGFloat) {
        dimOverlay.alphaValue = max(0, min(1, level))
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let coverH = (w * 2 / 3).rounded()
        coverView.frame = NSRect(x: 0, y: 0, width: w, height: coverH)
        shineLayer.frame = coverView.bounds
        deleteButton.frame = NSRect(x: 8, y: coverH - 8 - 26, width: 26, height: 26)
        codeBadge.sizeToFit()
        let badgeSize = NSSize(width: codeBadge.frame.width + 12, height: 20)
        codeBadge.frame = NSRect(x: deleteButton.frame.maxX + 6, y: coverH - 10 - badgeSize.height,
                                 width: badgeSize.width, height: badgeSize.height)
        starButton.frame = NSRect(x: w - 38, y: 10, width: 28, height: 22)

        playButton.frame = NSRect(x: (w - 60) / 2, y: (coverH - 60) / 2, width: 60, height: 60)
        dimOverlay.frame = NSRect(x: 0, y: 0, width: w, height: coverH)
        titleLabel.frame = NSRect(x: 2, y: coverH + 8, width: w - 4, height: 17)
        subLabel.frame = NSRect(x: 2, y: coverH + 26, width: w - 4, height: 15)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            playButton.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            playButton.animator().alphaValue = 0
        }
    }

    override func mouseDown(with event: NSEvent) {
        if forwardsMouseToSuperview {
            superview?.mouseDown(with: event)
            return
        }
        // 点封面本体 → 打开剧照浏览器
        onPreview?()
    }

    override func mouseDragged(with event: NSEvent) {
        if forwardsMouseToSuperview { superview?.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if forwardsMouseToSuperview { superview?.mouseUp(with: event) }
    }

    @objc private func deleteTapped() { onDelete?() }

    @objc private func activate() {
        onPlay?(NSEvent.modifierFlags.contains(.option))
    }

    @objc private func toggleFavorite() { onToggleFavorite?() }
}

// MARK: - 顶部轮播：平铺一行，焦点卡居中、两侧缩小压暗（最初的版本）

final class CarouselView: NSView {
    private var cards: [CardView] = []
    private var index = 2
    private var dragStartX: CGFloat = 0
    private var dragging = false
    private var dragDx: CGFloat = 0
    private var lastWheelAt: TimeInterval = 0
    private var wheelConsumed = false       // 一次手势只切换一张
    private var wheelAcc: CGFloat = 0

    var onNeedPlay: ((Movie, Bool) -> Void)?
    var onNeedToggle: ((Movie) -> Void)?
    var onNeedPreview: ((Movie) -> Void)?
    var onNeedDelete: ((Movie) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // 首次点击就能拖

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload(movies: [Movie], favorites: Set<String>) {
        if ProcessInfo.processInfo.environment["CARR_LOG"] != nil {
            FileHandle.standardError.write("carousel reload \(movies.count) movies, bounds=\(bounds)\n".data(using: .utf8)!)
        }
        cards.forEach { $0.removeFromSuperview() }
        cards = movies.map { m in
            let cardH = max(150, bounds.height - 62)
            let card = CardView(movie: m, favorite: favorites.contains(m.id), width: cardH * 1.5)
            card.forwardsMouseToSuperview = true
            card.onPlay = { [weak self] inApp in self?.onNeedPlay?(m, inApp) }
            card.onPreview = { [weak self] in self?.onNeedPreview?(m) }
            card.onToggleFavorite = { [weak self] in self?.onNeedToggle?(m) }
            card.onDelete = { [weak self] in self?.onNeedDelete?(m) }
            addSubview(card)
            return card
        }
        index = min(index, max(0, cards.count - 1))
        needsLayout = true
    }

    func focus(_ i: Int, animated: Bool) {
        index = min(max(0, i), max(0, cards.count - 1))
        layoutCards(animated: animated)
    }

    override func layout() {
        super.layout()
        layoutCards(animated: false)
    }

    private func layoutCards(animated: Bool, dx: CGFloat = 0) {
        if ProcessInfo.processInfo.environment["CARR_LOG"] != nil {
            FileHandle.standardError.write("carousel layout cards=\(cards.count) bounds=\(bounds) index=\(index)\n".data(using: .utf8)!)
        }
        guard !cards.isEmpty else { return }
        if animated { _ = dx }
        let cardH = max(150, bounds.height - 62)
        let cardW = cardH * 1.5
        let gap = max(16, cardW * 0.075)
        let step = cardW + gap
        let centerX = bounds.midX - cardW / 2

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.42 : 0
            ctx.allowsImplicitAnimation = animated
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (i, card) in cards.enumerated() {
                let d = i - index
                let frame = NSRect(x: centerX + CGFloat(d) * step + dx, y: 12,
                                   width: cardW, height: CardView.height(forWidth: cardW))
                if animated {
                    card.animator().frame = frame
                } else {
                    card.frame = frame
                }
                let ad = CGFloat(abs(d))
                // 两侧不再压到全黑：仍比中间暗，但封面清晰可见
                card.animator().alphaValue = d == 0 ? 1 : max(0.45, 1 - ad * 0.22)
                card.setDim(d == 0 ? 0 : min(0.45, 0.20 + (ad - 1) * 0.10))
                let scale = d == 0 ? 1 : max(0.86, 1 - CGFloat(abs(d)) * 0.055)
                card.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
                card.layer?.zPosition = CGFloat(200 - abs(d) * 10)
            }
        }
    }

    // MARK: 拖拽 / 滚轮 / 键盘

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        dragging = false
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = event.locationInWindow.x - dragStartX
        if abs(dx) > 4 { dragging = true }
        dragDx = dx
        layoutCards(animated: false, dx: dx)     // 跟手，不再等到松手才动
    }

    override func mouseUp(with event: NSEvent) {
        let dx = dragDx
        dragging = false
        dragDx = 0

        if abs(dx) < 6 {
            // 视为点击：点焦点卡播放，点两侧切换
            let p = convert(event.locationInWindow, from: nil)
            let cardH = max(150, bounds.height - 62)
            let stepX = cardH * 1.5 * 1.075
            if abs(p.x - bounds.midX) > stepX / 2 {
                focus(index + (p.x > bounds.midX ? 1 : -1), animated: true)
            } else if cards.indices.contains(index) {
                onNeedPreview?(cards[index].movie)
            }
            return
        }

        // 一次拖拽最多走一张
        if dx < -12 { focus(index + 1, animated: true) }
        else if dx > 12 { focus(index - 1, animated: true) }
        else { layoutCards(animated: true) }
    }

    override func scrollWheel(with event: NSEvent) {
        // 纵向滚动交给整页，横向才切卡片
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || event.modifierFlags.contains(.shift)
        if !horizontal { super.scrollWheel(with: event); return }

        if ProcessInfo.processInfo.environment["UI_LOG"] != nil {
            FileHandle.standardError.write(
                "wheel dx=\(event.scrollingDeltaX) dy=\(event.scrollingDeltaY) phase=\(event.phase.rawValue) m=\(event.momentumPhase.rawValue) consumed=\(wheelConsumed)\n"
                    .data(using: .utf8)!)
        }

        // 触控板手势自带 phase：靠它判断“新手势”，比时间阈值可靠得多
        if event.phase == .began || event.momentumPhase == .began {
            wheelConsumed = false
            wheelAcc = 0
        }
        if event.phase == .ended || event.phase == .cancelled
            || event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            wheelConsumed = false
            wheelAcc = 0
            lastWheelAt = 0
            return
        }

        // 传统鼠标滚轮没有 phase，用 0.3s 静默判定新手势
        let now = Date().timeIntervalSince1970
        if event.phase == [] && event.momentumPhase == [] && now - lastWheelAt > 0.30 {
            wheelConsumed = false
            wheelAcc = 0
        }
        lastWheelAt = now

        guard !wheelConsumed else { return }

        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        wheelAcc += delta
        guard abs(wheelAcc) >= 8 else { return }      // 累积到 8pt 就走一张（第一下很容易达标）
        wheelConsumed = true
        wheelAcc = 0
        focus(index + (delta < 0 ? 1 : -1), animated: true)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: focus(index - 1, animated: true)
        case 124: focus(index + 1, animated: true)
        default: super.keyDown(with: event)
        }
    }
}

/// 胶囊形状的链接按钮（带图标 + 悬停高亮）
final class PillLinkButton: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hovering = false
    private var tracking: NSTrackingArea?

    var onClick: (() -> Void)?
    var title: String = "" {
        didSet {
            label.stringValue = title
            needsLayout = true
        }
    }

    var preferredWidth: CGFloat {
        let w = (title as NSString).size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: 13.5)]).width
        return ceil(w) + 64
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.18).cgColor
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor

        icon.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .bold))
        icon.contentTintColor = NSColor(calibratedRed: 0.72, green: 0.66, blue: 1, alpha: 1)
        addSubview(icon)

        label.font = Theme.font(13.5, .semibold)
        label.textColor = NSColor(calibratedWhite: 1, alpha: 0.92)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let size = (title as NSString).size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: 13.5)])
        let iconW: CGFloat = 17
        let gap: CGFloat = 8
        let totalW = iconW + gap + size.width
        let startX = (bounds.width - totalW) / 2
        icon.frame = NSRect(x: startX, y: (bounds.height - 17) / 2, width: iconW, height: 17)
        label.frame = NSRect(x: startX + iconW + gap, y: (bounds.height - size.height) / 2,
                             width: size.width, height: size.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        hovering = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: on ? 0.20 : 0.10).cgColor
            layer?.borderColor = NSColor(calibratedWhite: 1, alpha: on ? 0.34 : 0.18).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// 一个信息胶囊：上面小标签，下面大数值
final class MetaChip: NSView {
    private let caption = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")

    var chipWidth: CGFloat {
        func w(_ tf: NSTextField) -> CGFloat {
            (tf.stringValue as NSString).size(withAttributes: [.font: tf.font ?? NSFont.systemFont(ofSize: 13)]).width
        }
        return ceil(max(w(caption), w(value))) + 28
    }

    init(captionText: String, valueText: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.07).cgColor
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.08).cgColor

        caption.stringValue = captionText
        caption.font = Theme.font(10.5, .medium)
        caption.textColor = NSColor(calibratedWhite: 1, alpha: 0.48)
        addSubview(caption)

        value.stringValue = valueText
        value.font = Theme.font(14, .semibold)
        value.textColor = .white
        value.lineBreakMode = .byTruncatingTail
        addSubview(value)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        caption.frame = NSRect(x: 12, y: 7, width: bounds.width - 24, height: 14)
        value.frame = NSRect(x: 12, y: 22, width: bounds.width - 24, height: 20)
    }
}

/// 类别 / 演员 用药丸标签
final class TagPill: NSView {
    private let label = NSTextField(labelWithString: "")

    var pillWidth: CGFloat {
        let w = (label.stringValue as NSString)
            .size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: 12)]).width
        return ceil(w) + 24
    }

    init(text: String, tint: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = tint.withAlphaComponent(0.18).cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = tint.withAlphaComponent(0.35).cgColor
        label.stringValue = text
        label.font = Theme.font(12, .medium)
        label.textColor = tint.blended(withFraction: 0.35, of: .white) ?? tint
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let size = (label.stringValue as NSString)
            .size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: 12)])
        label.frame = NSRect(x: 12, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
}

// MARK: - 视频首帧缩略图

enum VideoThumb {
    enum Position { case first, middle, last }

    nonisolated(unsafe) private static let cacheFirst = NSCache<NSURL, NSImage>()
    nonisolated(unsafe) private static let cacheMiddle = NSCache<NSURL, NSImage>()
    nonisolated(unsafe) private static let cacheLast = NSCache<NSURL, NSImage>()

    static func load(_ url: URL, position: Position = .first,
                     completion: @Sendable @escaping (NSImage?) -> Void) {
        let cache: NSCache<NSURL, NSImage>
        switch position {
        case .first: cache = cacheFirst
        case .middle: cache = cacheMiddle
        case .last: cache = cacheLast
        }
        if let hit = cache.object(forKey: url as NSURL) {
            completion(hit)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 720, height: 720)
            let duration = asset.duration.seconds
            let seconds: Double
            switch position {
            case .first:
                seconds = max(1, min(30, duration * 0.1))
            case .middle:
                seconds = max(0, duration * 0.30)     // 中间段 30% 处
            case .last:
                seconds = max(0, duration - 0.6)
            }
            let time = CMTime(seconds: seconds.isFinite ? seconds : 3, preferredTimescale: 600)
            var image: NSImage?
            if let cg = try? gen.copyCGImage(at: time, actualTime: nil) {
                image = NSImage(cgImage: cg, size: .zero)
                if let image { cache.setObject(image, forKey: url as NSURL) }
            }
            DispatchQueue.main.async { completion(image) }
        }
    }
}

// MARK: - 顶栏 Tab（JAV / 国产）

final class TabBar: NSView {
    private final class Segment: NSView {
        let label = NSTextField(labelWithString: "")
        var onClick: (() -> Void)?
        override var isFlipped: Bool { true }
        override func mouseDown(with event: NSEvent) { onClick?() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }

    private var segments: [Segment] = []
    private let names: [String]
    private let segmentWidth: CGFloat = 76

    var selected = 0 { didSet { refresh() } }
    var onChange: ((Int) -> Void)?

    var preferredWidth: CGFloat { CGFloat(names.count) * segmentWidth + 8 }

    init(names: [String]) {
        self.names = names
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.07).cgColor
        layer?.cornerRadius = 11
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.08).cgColor

        for (i, name) in names.enumerated() {
            let seg = Segment()
            seg.wantsLayer = true
            seg.layer?.cornerRadius = 8
            seg.label.stringValue = name
            seg.label.font = Theme.font(12, .semibold)
            seg.label.alignment = .center
            seg.addSubview(seg.label)
            seg.onClick = { [weak self] in
                guard let self, self.selected != i else { return }
                self.selected = i
                self.onChange?(i)
            }
            addSubview(seg)
            segments.append(seg)
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        var x: CGFloat = 4
        for seg in segments {
            seg.frame = NSRect(x: x, y: 4, width: segmentWidth, height: bounds.height - 8)
            seg.label.frame = NSRect(x: 0, y: (seg.bounds.height - 16) / 2, width: seg.bounds.width, height: 16)
            x += segmentWidth
        }
    }

    private func refresh() {
        for (i, seg) in segments.enumerated() {
            let on = i == selected
            seg.layer?.backgroundColor = on
                ? NSColor(calibratedRed: 0.49, green: 0.36, blue: 1, alpha: 0.95).cgColor
                : NSColor.clear.cgColor
            seg.label.textColor = on ? .white : NSColor(calibratedWhite: 1, alpha: 0.55)
            seg.label.font = Theme.font(12, on ? .semibold : .medium)
        }
        needsLayout = true
    }
}

// MARK: - 剧照浏览器（点击封面后居中弹出，滑动/滚轮/方向键切换）

final class ShotViewer: NSView {
    private let backdrop = NSView()
    private let panel = FlippedView()   // 和 viewer 同向的坐标系（y 从上往下）
    private let imageView = NSImageView()
    private let codeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let chipsRow = NSStackView()
    private let tagsRow = NSStackView()
    private let urlButton = PillLinkButton()
    private var jdvbURL: URL?
    private let counterLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "滑动 / 滚轮 / ← → 切换 · Esc 关闭")
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()
    private let prevCircle = CALayer()
    private let nextCircle = CALayer()
    private let closeCircle = CALayer()

    private var movie: Movie?
    private var images: [NSImage] = []
    private var index = 0
    private var dragStart: NSPoint = .zero
    private var dragging = false
    private var lastWheel: TimeInterval = 0

    var onClose: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        addSubview(backdrop)

        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 0.98).cgColor
        panel.layer?.cornerRadius = 16
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.55
        panel.layer?.shadowRadius = 26
        panel.layer?.shadowOffset = CGSize(width: 0, height: 10)
        addSubview(panel)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        panel.addSubview(imageView)

        for label in [codeLabel, titleLabel] {
            label.textColor = .white
            label.alignment = .left
            addSubview(label)          // 顶部信息区：面板之外
        }
        for label in [counterLabel, hintLabel] {
            label.textColor = .white
            label.alignment = .center
            panel.addSubview(label)
        }
        for stack in [chipsRow, tagsRow] {
            stack.orientation = .horizontal
            stack.spacing = 10
            stack.alignment = .top
            addSubview(stack)
        }

        urlButton.onClick = { [weak self] in self?.openJavdb() }
        urlButton.isHidden = true
        addSubview(urlButton)

        codeLabel.font = Theme.mono(12, .bold)
        codeLabel.wantsLayer = true
        codeLabel.layer?.backgroundColor = NSColor(calibratedRed: 0.49, green: 0.36, blue: 1, alpha: 1).cgColor
        codeLabel.layer?.cornerRadius = 5
        titleLabel.font = Theme.font(12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        counterLabel.font = Theme.font(12, .medium)
        hintLabel.font = Theme.font(10.5)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.45)

        for (button, symbol, action, circle) in [
            (prevButton, "chevron.left", #selector(goPrev), prevCircle),
            (nextButton, "chevron.right", #selector(goNext), nextCircle),
            (closeButton, "xmark", #selector(close), closeCircle),
        ] {
            button.isBordered = false
            button.bezelStyle = .regularSquare
            let pointSize: CGFloat = symbol == "xmark" ? 32 : 48
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = NSColor.white.withAlphaComponent(0.92)
            button.target = self
            button.action = action
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor.clear.cgColor
            // 圆形底只是视觉层，CALayer 不参与命中测试 → 整个大按钮都是有效点击区
            circle.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
            circle.cornerRadius = symbol == "xmark" ? 27 : 18
            button.layer?.addSublayer(circle)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 展示

    func show(movie: Movie, startingAt start: Int = 0) {
        self.movie = movie
        images = movie.shots.compactMap { CoverLoader.image($0) }
        index = min(max(0, start), max(0, images.count - 1))
        codeLabel.stringValue = "  \(movie.code)  "
        titleLabel.stringValue = movie.title
        jdvbURL = movie.jdvbURL

        // 元信息胶囊
        chipsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var chips: [(String, String)] = []
        if let d = movie.releaseDate, !d.isEmpty { chips.append(("日期", d)) }
        if let dur = movie.duration, dur > 0 {
            let t = Int(dur.rounded()), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
            chips.append(("時長", h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)))
        }
        if let maker = movie.maker, !maker.isEmpty { chips.append(("發行", maker)) }
        if let series = movie.series, !series.isEmpty { chips.append(("系列", series)) }
        if let director = movie.director, !director.isEmpty { chips.append(("導演", director)) }
        if let score = movie.score {
            let votes = movie.votes.map { "（\($0) 人）" } ?? ""
            chips.append(("評分", String(format: "★ %.2f", score) + votes))
        }
        if let size = Optional(movie.sizeText), !size.isEmpty { chips.append(("體積", size + (movie.resolution.map { " · \($0)" } ?? ""))) }
        for (caption, value) in chips {
            let chip = MetaChip(captionText: caption, valueText: value)
            chip.translatesAutoresizingMaskIntoConstraints = false
            chip.heightAnchor.constraint(equalToConstant: 50).isActive = true
            chip.widthAnchor.constraint(equalToConstant: chip.chipWidth).isActive = true
            chipsRow.addArrangedSubview(chip)
        }

        // 类别 / 演员
        tagsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let accent = NSColor(calibratedRed: 0.62, green: 0.56, blue: 1, alpha: 1)
        let warm = NSColor(calibratedRed: 1, green: 0.62, blue: 0.62, alpha: 1)
        for c in movie.categories.prefix(6) { addPill(TagPill(text: c, tint: accent), to: tagsRow) }
        for a in movie.actors.prefix(4) { addPill(TagPill(text: a, tint: warm), to: tagsRow) }

        urlButton.title = " 在 JavDB 打开 "
        urlButton.isHidden = movie.jdvbURL == nil

        hasImages = !images.isEmpty
        updateImage()
    }

    private var hasImages = true

    private func addPill(_ pill: TagPill, to stack: NSStackView) {
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.heightAnchor.constraint(equalToConstant: 26).isActive = true
        pill.widthAnchor.constraint(equalToConstant: pill.pillWidth).isActive = true
        stack.addArrangedSubview(pill)
    }

    private func updateImage() {
        guard !images.isEmpty else {
            imageView.image = nil
            counterLabel.stringValue = "这部没有剧照"
            return
        }
        imageView.image = images[index]
        counterLabel.stringValue = "\(index + 1) / \(images.count)"
        needsLayout = true
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        backdrop.frame = bounds

        // 面板占窗口的一半：左右各留 25%，上下各留 25%
        let panelW = (bounds.width * 0.5).rounded()
        let panelH = (bounds.height * 0.5).rounded()
        let panelFrame = NSRect(x: (bounds.width - panelW) / 2,
                                y: (bounds.height - panelH) / 2,
                                width: panelW, height: panelH)
        panel.frame = panelFrame

        // 大热区：整个侧边条都能点，圆只是视觉
        let closeSize: CGFloat = 54                       // 原 18pt 圆的 3 倍
        closeButton.frame = NSRect(x: bounds.maxX - closeSize - 24, y: 12,
                                   width: closeSize + 24, height: closeSize + 24)
        closeCircle.frame = CGRect(x: (closeButton.frame.width - closeSize) / 2,
                                   y: (closeButton.frame.height - closeSize) / 2,
                                   width: closeSize, height: closeSize)

        // 左右按钮：与面板同高的竖长条，贴在面板外侧，不压到图片框
        let gutterW: CGFloat = 96
        let gutterGap: CGFloat = 14
        let gutterH = panelFrame.height
        prevButton.frame = NSRect(x: panelFrame.minX - gutterW - gutterGap, y: panelFrame.minY,
                                  width: gutterW, height: gutterH)
        nextButton.frame = NSRect(x: panelFrame.maxX + gutterGap, y: panelFrame.minY,
                                  width: gutterW, height: gutterH)
        prevCircle.frame = CGRect(x: 0, y: 0, width: gutterW, height: gutterH)
        nextCircle.frame = CGRect(x: 0, y: 0, width: gutterW, height: gutterH)

        let innerTop: CGFloat = 42
        let innerBottom: CGFloat = 46
        // 顶部信息区：面板上方整条区域
        let leftInset: CGFloat = 40
        let stripW = bounds.width - leftInset * 2
        let top: CGFloat = 34

        codeLabel.sizeToFit()
        codeLabel.frame = NSRect(x: leftInset, y: top, width: codeLabel.frame.width + 4, height: 24)
        let titleX = codeLabel.frame.maxX + 12
        titleLabel.frame = NSRect(x: titleX, y: top + 2,
                                  width: max(200, bounds.width - titleX - 120), height: 20)

        chipsRow.frame = NSRect(x: leftInset, y: top + 34, width: stripW, height: 50)
        chipsRow.needsLayout = true
        tagsRow.frame = NSRect(x: leftInset, y: top + 94, width: stripW, height: 26)
        tagsRow.needsLayout = true

        let linkW = urlButton.preferredWidth
        let linkH: CGFloat = 44
        urlButton.frame = NSRect(x: bounds.width - linkW - 104,
                                 y: chipsRow.frame.midY - linkH / 2,
                                 width: linkW, height: linkH)

        counterLabel.frame = NSRect(x: 0, y: panelH - 40, width: panelW, height: 16)
        hintLabel.frame = NSRect(x: 0, y: panelH - 22, width: panelW, height: 14)

        guard images.indices.contains(index) else { imageView.frame = .zero; return }
        let img = images[index]
        let availW = max(40, panelW - 28)
        let availH = max(40, panelH - innerTop - innerBottom)
        let ratio = img.size.width / max(1, img.size.height)
        var w = availW, h = w / ratio
        if h > availH { h = availH; w = h * ratio }
        imageView.frame = NSRect(x: (panelW - w) / 2, y: innerTop + (availH - h) / 2, width: w, height: h)
    }

    // MARK: 切换

    @objc private func goPrev() { step(-1) }
    @objc private func goNext() { step(1) }
    @objc private func close() { onClose?() }

    @objc private func openJavdb() {
        if let url = jdvbURL { NSWorkspace.shared.open(url) }
    }

    private func step(_ delta: Int) {
        guard !images.isEmpty else { return }
        index = (index + delta + images.count) % images.count
        updateImage()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            imageView.animator().alphaValue = 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        dragging = false
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = event.locationInWindow.x - dragStart.x
        let dy = event.locationInWindow.y - dragStart.y
        if abs(dx) > 6 || abs(dy) > 6 { dragging = true }
    }

    override func mouseUp(with event: NSEvent) {
        let dx = event.locationInWindow.x - dragStart.x
        let dy = event.locationInWindow.y - dragStart.y
        if dragging {
            // 左右滑或上下滑都算切换
            if abs(dx) >= abs(dy) {
                if dx < -30 { step(1) } else if dx > 30 { step(-1) }
            } else {
                if dy < -30 { step(1) } else if dy > 30 { step(-1) }
            }
        } else {
            // 点空白处关闭
            let p = convert(event.locationInWindow, from: nil)
            if !panel.frame.insetBy(dx: -16, dy: -16).contains(p) { onClose?() }
        }
        dragging = false
    }

    override func scrollWheel(with event: NSEvent) {
        let now = Date().timeIntervalSince1970
        guard now - lastWheel > 0.18 else { return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        guard abs(delta) > 4 else { return }
        lastWheel = now
        step(delta < 0 ? 1 : -1)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: step(-1)          // ←
        case 124: step(1)           // →
        case 125: step(1)           // ↓
        case 126: step(-1)          // ↑
        case 53: onClose?()         // Esc
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - 影库网格（放得进整页滚动）

final class GridView: FlippedView {
    private var cards: [CardView] = []
    var onNeedPlay: ((Movie, Bool) -> Void)?
    var onNeedToggle: ((Movie) -> Void)?
    var onNeedPreview: ((Movie) -> Void)?
    var onNeedDelete: ((Movie) -> Void)?

    private let inset: CGFloat = 24
    private let gapX: CGFloat = 34
    private let gapY: CGFloat = 38

    func reload(movies: [Movie], favorites: Set<String>) {
        if ProcessInfo.processInfo.environment["CARR_LOG"] != nil {
            FileHandle.standardError.write("carousel reload \(movies.count) movies, bounds=\(bounds)\n".data(using: .utf8)!)
        }
        cards.forEach { $0.removeFromSuperview() }
        cards = movies.map { m in
            let card = CardView(movie: m, favorite: favorites.contains(m.id), width: 326)
            card.onPlay = { [weak self] inApp in self?.onNeedPlay?(m, inApp) }
            card.onPreview = { [weak self] in self?.onNeedPreview?(m) }
            card.onToggleFavorite = { [weak self] in self?.onNeedToggle?(m) }
            card.onDelete = { [weak self] in self?.onNeedDelete?(m) }
            addSubview(card)
            return card
        }
        needsLayout = true
    }

    private func metrics(for width: CGFloat) -> (cols: Int, cardW: CGFloat, cardH: CGFloat, height: CGFloat) {
        guard !cards.isEmpty else { return (1, 326, 0, 0) }
        let usable = max(200, width - inset * 2)
        let cols = min(4, cards.count)        // 影库固定每行 4 部
        let cardW = ((usable - CGFloat(cols - 1) * gapX) / CGFloat(cols)).rounded(.down)
        let cardH = CardView.height(forWidth: cardW)
        let rows = (cards.count + cols - 1) / cols
        let height = CGFloat(10) + CGFloat(rows) * cardH + CGFloat(max(0, rows - 1)) * gapY + 40
        return (cols, cardW, cardH, height)
    }

    func fittingHeight(for width: CGFloat) -> CGFloat { metrics(for: width).height }

    override func layout() {
        super.layout()
        guard !cards.isEmpty else { return }
        let m = metrics(for: bounds.width)
        for (i, card) in cards.enumerated() {
            let c = i % m.cols, r = i / m.cols
            let x = inset + CGFloat(c) * (m.cardW + gapX)
            let y = CGFloat(10) + CGFloat(r) * (m.cardH + gapY)
            if card.frame.width != m.cardW {
                card.frame = NSRect(x: x, y: y, width: m.cardW, height: m.cardH)
            } else {
                card.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
    }
}

// MARK: - 整页滚动容器：精选 + 影库 一起滚

final class ContentDocumentView: FlippedView {
    let favHeader: NSView
    let libHeader: NSView
    let carousel: CarouselView
    let grid: GridView
    private let divider = NSView()

    var favHeight: CGFloat = 320

    override var isFlipped: Bool { true }

    init(favHeader: NSView, libHeader: NSView, carousel: CarouselView, grid: GridView) {
        self.favHeader = favHeader
        self.libHeader = libHeader
        self.carousel = carousel
        self.grid = grid
        super.init(frame: .zero)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.line.cgColor
        for v in [favHeader, carousel, divider, libHeader, grid] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func relayout(viewportWidth: CGFloat, viewportHeight: CGFloat) {
        let width = max(600, viewportWidth)
        setFrameSize(NSSize(width: width, height: frame.height))
        favHeight = max(260, min(360, viewportHeight * 0.34))

        var y: CGFloat = favHeader.isHidden ? 6 : 6
        if !favHeader.isHidden {
            favHeader.frame = NSRect(x: 18, y: y, width: width - 36, height: 22)
            y += 24
        }
        carousel.frame = NSRect(x: 0, y: y, width: width, height: favHeight); y += favHeight + 6
        divider.frame = NSRect(x: 0, y: y, width: width, height: 1); y += 9
        libHeader.frame = NSRect(x: 18, y: y, width: width - 36, height: 22); y += 24

        let gridH = grid.fittingHeight(for: width)
        grid.frame = NSRect(x: 0, y: y, width: width, height: gridH)
        y += gridH

        setFrameSize(NSSize(width: width, height: max(y, viewportHeight)))
        needsLayout = true
        carousel.needsLayout = true
        grid.needsLayout = true
    }

    override func layout() {
        super.layout()
        for v in subviews where v !== divider { v.layoutSubtreeIfNeeded() }
    }
}

// 点哪都能拖动滚动，不误触卡片
final class PassthroughScrollView: NSScrollView {
    override func mouseDown(with event: NSEvent) {
        guard let doc = documentView else { return super.mouseDown(with: event) }
        let point = doc.convert(event.locationInWindow, from: nil)
        let hit = doc.hitTest(point)
        if hit is CardView || hit?.superview is CardView || hit?.superview?.superview is CardView {
            super.mouseDown(with: event)
        } else {
            nextResponder?.mouseDown(with: event)
        }
    }
}

// MARK: - 小控件

final class PillButton: NSButton {
    init(title: String, symbol: String? = nil, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.title = title
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        imagePosition = symbol == nil ? .noImage : .imageLeading
        font = Theme.font(12, .medium)
        contentTintColor = Theme.text
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.06).cgColor
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = Theme.line.cgColor
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }
}
