import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        let c = AppController()
        c.showWindow()
        controller = c
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { c.reloadAll() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 极简菜单：隐私设置直达 + 退出
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 JAVMovie", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())

        let cookieItem = NSMenuItem(title: "获取 JavDB Cookie（过验证）…", action: #selector(doCookie), keyEquivalent: "k")
        cookieItem.target = self
        appMenu.addItem(cookieItem)

        let syncItem = NSMenuItem(title: "检查并补全元数据…", action: #selector(doSync), keyEquivalent: "m")
        syncItem.target = self
        appMenu.addItem(syncItem)

        let refreshItem = NSMenuItem(title: "刷新", action: #selector(doRefresh), keyEquivalent: "r")
        refreshItem.target = self
        appMenu.addItem(refreshItem)

        // 排序
        let sortItem = NSMenuItem(title: "排序", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu(title: "排序")
        for mode in LibraryStore.SortMode.allCases {
            let it = NSMenuItem(title: mode.rawValue, action: #selector(doSort(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode.rawValue
            sortMenu.addItem(it)
        }
        sortItem.submenu = sortMenu
        appMenu.addItem(sortItem)

        // 播放器
        let playerItem = NSMenuItem(title: "播放器", action: nil, keyEquivalent: "")
        let playerMenu = NSMenu(title: "播放器")
        for name in ["IINA", "VLC"] {
            let it = NSMenuItem(title: name, action: #selector(doPlayer(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = name
            playerMenu.addItem(it)
        }
        playerItem.submenu = playerMenu
        appMenu.addItem(playerItem)

        appMenu.addItem(.separator())
        let privacy = NSMenuItem(title: "打开「文件与文件夹」授权…",
                                 action: #selector(openPrivacy), keyEquivalent: ",")
        privacy.target = self
        appMenu.addItem(privacy)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 JAVMovie",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    @objc private func doRefresh() { controller?.refreshFromMenu() }

    @objc private func doSync() { controller?.runMetadataSync() }

    @objc private func doCookie() { controller?.openCookieWindow() }

    @objc private func doSort(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = LibraryStore.SortMode(rawValue: raw) else { return }
        controller?.setSort(mode)
    }

    @objc private func doPlayer(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        controller?.setPlayer(name)
    }

    @objc private func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
