import AppKit
import WebKit

/// 把一个网页嵌进 App 里的页面（带前进/后退/刷新/外部打开）
final class WebPage: NSView, WKNavigationDelegate {

    private let webView: WKWebView
    private let bar = NSView()
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!
    private var openButton: NSButton!
    private var homeButton: NSButton!
    private let titleLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var observation: NSKeyValueObservation?
    private let homeURL: URL

    init(url: URL) {
        homeURL = url
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // 关键：允许网页元素全屏（视频右下角的⛶按钮就是走这个能力）
        if #available(macOS 12.0, *) {
            config.preferences.isElementFullscreenEnabled = true
        }
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: config)

        super.init(frame: .zero)
        wantsLayer = true

        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.05).cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)

        func tool(_ symbol: String, _ action: Selector, tip: String) -> NSButton {
            let b = NSButton()
            b.isBordered = false
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
            b.contentTintColor = NSColor(calibratedWhite: 0.85, alpha: 1)
            b.target = self
            b.action = action
            b.toolTip = tip
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }

        backButton = tool("chevron.left", #selector(goBack), tip: "后退")
        forwardButton = tool("chevron.right", #selector(goForward), tip: "前进")
        reloadButton = tool("arrow.clockwise", #selector(reloadPage), tip: "刷新")
        openButton = tool("safari", #selector(openInBrowser), tip: "用浏览器打开")
        homeButton = tool("house", #selector(goHome), tip: "回到短剧首页")
        backButton.isEnabled = false
        forwardButton.isEnabled = false

        titleLabel.font = Theme.font(11.5, .medium)
        titleLabel.textColor = Theme.dim
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        progress.isIndeterminate = false
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        progress.translatesAutoresizingMaskIntoConstraints = false

        for v in [homeButton!, backButton!, forwardButton!, reloadButton!, openButton!, titleLabel, progress] {
            bar.addSubview(v)
        }

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 30),

            homeButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            homeButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            homeButton.widthAnchor.constraint(equalToConstant: 22),

            backButton.leadingAnchor.constraint(equalTo: homeButton.trailingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 22),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 6),
            forwardButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 22),

            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 6),
            reloadButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: progress.leadingAnchor, constant: -12),

            progress.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -12),
            progress.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 120),

            openButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            openButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            openButton.widthAnchor.constraint(equalToConstant: 22),

            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        observation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in
            guard let self else { return }
            self.progress.doubleValue = web.estimatedProgress
            self.progress.isHidden = web.estimatedProgress >= 1
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var url: URL? { webView.url }

    func load() {
        webView.load(URLRequest(url: homeURL))
    }

    @objc private func goHome() { webView.load(URLRequest(url: homeURL)) }

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func reloadPage() { webView.reload() }
    @objc private func openInBrowser() {
        if let url = webView.url { NSWorkspace.shared.open(url) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if ProcessInfo.processInfo.environment["DUANJU_FS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let js = "(function(){"
                    + "var fsEnabled=!!(document.webkitFullscreenEnabled||document.fullscreenEnabled);"
                    + "var videos=document.querySelectorAll('video').length;"
                    + "var iframes=document.querySelectorAll('iframe').length;"
                    + "var v=document.querySelector('video');"
                    + "var canVideo=!!(v&&(v.webkitEnterFullscreen||v.webkitEnterFullScreen));"
                    + "if(v&&canVideo){v.webkitEnterFullscreen&&v.webkitEnterFullscreen();}"
                    + "return JSON.stringify({fsEnabled:fsEnabled,videos:videos,iframes:iframes,canVideo:canVideo});"
                    + "})()"
                webView.evaluateJavaScript(js) { value, error in
                    FileHandle.standardError.write(
                        "fullscreen try: \(String(describing: value)) err=\(String(describing: error))\n"
                            .data(using: .utf8)!)
                }
            }
        }
        titleLabel.stringValue = webView.title ?? ""
        backButton?.isEnabled = webView.canGoBack
        forwardButton?.isEnabled = webView.canGoForward
        progress.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        titleLabel.stringValue = "加载失败：\(error.localizedDescription)"
    }
}
