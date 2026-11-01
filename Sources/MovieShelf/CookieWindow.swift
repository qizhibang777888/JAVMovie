import AppKit
import WebKit

/// 打开一个内嵌浏览器窗口，让用户过掉 Cloudflare 验证，
/// 然后把 javdb.com 的 Cookie（含 HttpOnly 的 cf_clearance）和 UA 交给抓取脚本。
final class CookieWindow: NSObject, WKNavigationDelegate {

    private let window: NSWindow
    private let webView: WKWebView
    private let status = NSTextField(labelWithString: "请在弹出的网页里完成人机验证…")
    private let useButton = NSButton()
    private let reloadButton = NSButton()
    private var pollTimer: Timer?

    var onDone: ((String, String) -> Void)?      // (cookie 字符串, UA)

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "JavDB 验证（通过后点右下角按钮）"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false

        super.init()

        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 960, height: 720))
        window.contentView = root

        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webView)

        status.font = Theme.font(12)
        status.textColor = Theme.dim
        status.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(status)

        useButton.title = "已通过验证，使用当前 Cookie"
        useButton.bezelStyle = .rounded
        useButton.keyEquivalent = "\r"
        useButton.target = self
        useButton.action = #selector(useCookie)
        useButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(useButton)

        reloadButton.title = "重新加载"
        reloadButton.bezelStyle = .rounded
        reloadButton.target = self
        reloadButton.action = #selector(reload)
        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(reloadButton)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -52),

            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            status.centerYAnchor.constraint(equalTo: reloadButton.centerYAnchor),

            useButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            useButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            useButton.widthAnchor.constraint(equalToConstant: 250),

            reloadButton.trailingAnchor.constraint(equalTo: useButton.leadingAnchor, constant: -10),
            reloadButton.centerYAnchor.constraint(equalTo: useButton.centerYAnchor),
        ])
    }

    func show(attachedTo parent: NSWindow?) {
        webView.load(URLRequest(url: URL(string: "https://javdb.com/")!))
        if let parent {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    @objc private func reload() {
        status.stringValue = "重新加载中…"
        webView.reload()
    }

    private func check() {
        webView.evaluateJavaScript("document.title") { [weak self] value, _ in
            guard let self, let title = value as? String else { return }
            if title.contains("Just a moment") || title.isEmpty {
                self.status.stringValue = "等待人机验证…（在网页里点一下复选框）"
            } else {
                self.status.stringValue = "页面已加载：\(title.prefix(40))   · 可以点右下角按钮了"
            }
        }
    }

    @objc private func useCookie() {
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
            guard let self else { return }
            let ua = (value as? String) ?? ""
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let jar = cookies
                    .filter { $0.domain.contains("javdb") }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                DispatchQueue.main.async {
                    guard !jar.isEmpty else {
                        self.status.stringValue = "没读到 javdb 的 Cookie，先等页面加载完再点一次"
                        return
                    }
                    self.pollTimer?.invalidate()
                    if let parent = self.window.sheetParent {
                        parent.endSheet(self.window)
                    } else {
                        self.window.close()
                    }
                    self.onDone?(jar, ua)
                }
            }
        }
    }
}
