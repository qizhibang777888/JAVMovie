import AppKit

/// 设置面板：两个数据源目录 + 确定后切换数据库
final class SettingsPanel: NSWindow {

    private let javField = NSTextField()
    private let guochangField = NSTextField()
    private var javPath: String
    private var guochangPath: String

    var onConfirm: ((String, String) -> Void)?

    init(javPath: String, guochangPath: String) {
        self.javPath = javPath
        self.guochangPath = guochangPath
        super.init(contentRect: NSRect(x: 0, y: 0, width: 620, height: 250),
                   styleMask: [.titled], backing: .buffered, defer: false)
        title = "设置"
        appearance = NSAppearance(named: .darkAqua)
        isReleasedWhenClosed = false

        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 620, height: 250))
        contentView = root

        let headline = NSTextField(labelWithString: "数据来源")
        headline.font = Theme.font(13, .semibold)
        headline.textColor = .white
        headline.frame = NSRect(x: 24, y: 18, width: 400, height: 18)
        root.addSubview(headline)

        addRow(in: root, y: 56, title: "JAV 数据目录", field: javField,
               path: javPath, action: #selector(pickJav))
        addRow(in: root, y: 112, title: "国产 数据目录", field: guochangField,
               path: guochangPath, action: #selector(pickGuochang))

        let hint = NSTextField(labelWithString: "确定后会切换到对应目录、重新扫描并校验数据（必要时补全元数据）")
        hint.font = Theme.font(11)
        hint.textColor = Theme.dim
        hint.frame = NSRect(x: 24, y: 168, width: 570, height: 16)
        root.addSubview(hint)

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 424, y: 200, width: 80, height: 30)
        root.addSubview(cancel)

        let confirm = NSButton(title: "确定", target: self, action: #selector(confirmTapped))
        confirm.bezelStyle = .rounded
        confirm.keyEquivalent = "\r"
        confirm.frame = NSRect(x: 514, y: 200, width: 88, height: 30)
        root.addSubview(confirm)
    }

    private func addRow(in root: NSView, y: CGFloat, title: String,
                        field: NSTextField, path: String, action: Selector) {
        let label = NSTextField(labelWithString: title)
        label.font = Theme.font(11.5, .medium)
        label.textColor = Theme.dim
        label.frame = NSRect(x: 24, y: y, width: 200, height: 15)
        root.addSubview(label)

        field.stringValue = path
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        field.isEditable = false
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.frame = NSRect(x: 24, y: y + 20, width: 480, height: 26)
        root.addSubview(field)

        let button = NSButton(title: "选择…", target: self, action: action)
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 514, y: y + 18, width: 88, height: 30)
        root.addSubview(button)
    }

    @objc private func pickJav() {
        if let p = chooseFolder(start: javPath) {
            javPath = p
            javField.stringValue = p
        }
    }

    @objc private func pickGuochang() {
        if let p = chooseFolder(start: guochangPath) {
            guochangPath = p
            guochangField.stringValue = p
        }
    }

    private func chooseFolder(start: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !start.isEmpty { panel.directoryURL = URL(fileURLWithPath: start) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    @objc private func confirmTapped() {
        let jav = javField.stringValue.trimmingCharacters(in: .whitespaces)
        let guo = guochangField.stringValue.trimmingCharacters(in: .whitespaces)
        if let parent = sheetParent {
            parent.endSheet(self)
        } else {
            close()
        }
        onConfirm?(jav, guo)
    }

    @objc private func cancelTapped() {
        if let parent = sheetParent {
            parent.endSheet(self)
        } else {
            close()
        }
    }
}
