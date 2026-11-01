import Foundation
import AppKit
import AVFoundation
import Combine

// MARK: - 扫描

enum Scanner {
    nonisolated(unsafe) static var lastError: String?

    nonisolated(unsafe) static var plainMode = false

    static func scan(root: URL, deep: Bool = false) -> [Movie] {
        lastError = nil
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: root,
                                                 includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])
        } catch {
            let ns = error as NSError
            lastError = "\(ns.localizedDescription)（\(ns.domain) \(ns.code)）· \(root.path)"
            FileHandle.standardError.write("scan failed: \(lastError!)\n".data(using: .utf8)!)
            return []
        }
        FileHandle.standardError.write("scan \(root.path) -> \(entries.count) entries\n".data(using: .utf8)!)

        var targets: [(folder: URL, file: URL)] = []
        if deep {
            // 递归：把整棵目录树下所有视频都收进来（国产那边常常嵌套好几层）
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
            if let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let f as URL in walker {
                    let name = f.lastPathComponent
                    if name.hasPrefix(".") || name.hasPrefix("._") { continue }
                    let isDir = (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir { continue }
                    guard NameParser.videoExts.contains(f.pathExtension.lowercased()) else { continue }
                    targets.append((f.deletingLastPathComponent(), f))
                }
            }
        } else {
            for e in entries {
                if e.lastPathComponent.hasPrefix(".") { continue }
                let isDir = (try? e.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    let sub = (try? fm.contentsOfDirectory(at: e, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    for f in sub where NameParser.videoExts.contains(f.pathExtension.lowercased()) {
                        if f.lastPathComponent.hasPrefix("._") { continue }
                        targets.append((e, f))
                    }
                } else if NameParser.videoExts.contains(e.pathExtension.lowercased()) {
                    targets.append((root, e))
                }
            }
        }

        var movies: [Movie] = []
        for t in targets {
            let code = NameParser.code(from: t.file.lastPathComponent)
            let tx = plainMode ? nil : readTx(in: t.folder)
            let stem = (t.file.lastPathComponent as NSString).deletingPathExtension
            let values = try? t.file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let bytes = Int64(values?.fileSize ?? 0)

            let cover = plainMode ? nil : findCover(in: t.folder, stem: stem, code: tx?.code ?? code)
            let shots = (tx?.shots ?? []).compactMap { name -> URL? in
                let u = t.folder.appendingPathComponent(name)
                return fm.fileExists(atPath: u.path) ? u : nil
            }

            movies.append(Movie(
                id: NameParser.id(for: t.file),
                url: t.file,
                folder: t.folder,
                code: tx?.code?.isEmpty == false ? tx!.code! : code,
                title: tx?.title?.isEmpty == false ? tx!.title! : (NameParser.clean(t.file.lastPathComponent)),
                displayName: NameParser.clean(t.file.lastPathComponent),
                sizeText: NameParser.humanSize(bytes),
                bytes: bytes,
                modified: values?.contentModificationDate ?? .distantPast,
                duration: nil,
                resolution: nil,
                maker: tx?.maker,
                publisher: tx?.publisher,
                series: tx?.series,
                director: tx?.director,
                releaseDate: tx?.date,
                score: tx?.score,
                votes: tx?.votes,
                actors: tx?.actors ?? [],
                categories: tx?.categories ?? [],
                jdvbURL: tx?.page.flatMap(URL.init(string:)),
                cover: cover,
                shots: shots
            ))
        }
        return movies.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    static func readTx(in folder: URL) -> TxInfo? {
        for name in ["TX.json", "tx.json"] {
            let u = folder.appendingPathComponent(name)
            if let data = try? Data(contentsOf: u),
               let info = try? JSONDecoder().decode(TxInfo.self, from: data) {
                return info
            }
        }
        return nil
    }

    /// 同目录优先 FM.jpg，其次 <视频名>.jpg、<番号>.jpg
    static func findCover(in folder: URL, stem: String, code: String) -> URL? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
        let images = names.filter { NameParser.imageExts.contains(($0 as NSString).pathExtension.lowercased()) }
        let lower = images.map { ($0, $0.lowercased()) }
        func pick(_ target: String) -> URL? {
            guard let hit = lower.first(where: { $0.1 == target.lowercased() })?.0 else { return nil }
            return folder.appendingPathComponent(hit)
        }
        return pick("FM.jpg") ?? pick("FM.jpeg") ?? pick(stem + ".jpg")
            ?? (code.isEmpty ? nil : pick(code + ".jpg"))
    }
}

// MARK: - 播放

enum Player {
    static let apps: [(name: String, path: String)] = [
        ("IINA", "/Applications/IINA.app"),
        ("VLC", "/Applications/VLC.app"),
    ]

    /// 用外部播放器打开；找不到就交给系统默认
    static func open(url: URL, prefer: String) {
        var candidates = apps
        if let i = candidates.firstIndex(where: { $0.name == prefer }) {
            let first = candidates.remove(at: i)
            candidates.insert(first, at: 0)
        }
        for app in candidates where FileManager.default.fileExists(atPath: app.path) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: app.path),
                                    configuration: config) { _, error in
                if error != nil { NSWorkspace.shared.open(url) }
            }
            return
        }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 状态

@MainActor
final class LibraryStore: ObservableObject {
    @Published var root: URL
    @Published var movies: [Movie] = []
    @Published var favorites: [String] = []
    @Published var query: String = ""
    @Published var sort: SortMode = .name
    @Published var carouselIndex: Int = 2
    @Published var playingInApp: Movie?
    @Published var isLoading = false
    @Published var message: String?
    @Published var lastError: String?

    var favoriteLimit = 10
    var playerName: String {
        get { UserDefaults.standard.string(forKey: "player") ?? "IINA" }
        set { UserDefaults.standard.set(newValue, forKey: "player"); objectWillChange.send() }
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case name = "文件名", modified = "更新时间", size = "体积"
        var id: String { rawValue }
    }

    init() {
        // 从 MovieShelf 改名过来：第一次启动把旧偏好搬过来
        let new = UserDefaults.standard
        let legacy = UserDefaults(suiteName: "local.movieshelf.native")
        let savedPath = new.string(forKey: "root")
            ?? legacy?.string(forKey: "root")
            ?? "/Volumes/US202/1101"
        root = URL(fileURLWithPath: savedPath)
        // 旧版本用「路径 SHA256 前 16 位」当收藏 id，目录一改名就全部失效；
        // 这里检测到全是 16 位 hex 就直接丢弃，让下面按番号重新回填
        let storedFavs = new.stringArray(forKey: "favorites") ?? []
        let looksLikePathHash = !storedFavs.isEmpty && storedFavs.allSatisfy {
            $0.count == 16 && $0.allSatisfy { "0123456789abcdef".contains($0) }
        }
        favorites = looksLikePathHash ? [] : storedFavs
        if new.string(forKey: "player") == nil, let p = legacy?.string(forKey: "player") {
            new.set(p, forKey: "player")
        }
        new.set(savedPath, forKey: "root")
        new.set(favorites, forKey: "favorites")
    }

    // MARK: 载入
    private var loadToken = 0

    func reload() {
        isLoading = true
        loadToken += 1
        let token = loadToken
        let dir = root
        Task {
            // 先做一次主线程的轻量访问：让 macOS 有机会弹出「可移除宗卷」授权
            _ = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
            let found = await Task.detached(priority: .userInitiated) {
                Scanner.scan(root: dir)
            }.value
            if ProcessInfo.processInfo.environment["ID_LOG"] != nil {
                for m in found.prefix(3) {
                    FileHandle.standardError.write("id=\(m.id) path=\(m.url.path)\n".data(using: .utf8)!)
                }
            }
            guard token == self.loadToken else { return }   // 已有更新的请求，丢弃这次结果
            self.lastError = Scanner.lastError
            self.movies = found
            if self.favorites.isEmpty {
                self.favorites = Array(found.prefix(self.favoriteLimit).map(Self.favKey))
                self.saveFavorites()
            }
            let keys = Set(found.map(Self.favKey))
            self.favorites = self.favorites.filter { keys.contains($0) }
            self.carouselIndex = min(2, max(0, self.favorites.count - 1))
            self.isLoading = false
            await self.loadDurations()
        }
    }

    /// 补时长 / 分辨率（AVFoundation，只看头部，很快）
    private func loadDurations() async {
        for i in movies.indices where movies[i].duration == nil {
            let asset = AVURLAsset(url: movies[i].url)
            if let d = try? await asset.load(.duration) {
                let secs = CMTimeGetSeconds(d)
                if secs.isFinite && secs > 0 { movies[i].duration = secs }
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                movies[i].resolution = "\(Int(abs(size.height)))p"
            }
        }
    }

    // MARK: 列表
    var visibleMovies: [Movie] {
        var list = movies
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { ($0.title + " " + $0.code + " " + $0.url.lastPathComponent).lowercased().contains(q) }
        }
        switch sort {
        case .name: list.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        case .modified: list.sort { $0.modified > $1.modified }
        case .size: list.sort { $0.bytes > $1.bytes }
        }
        return list
    }

    var favoriteMovies: [Movie] {
        movies.filter { favorites.contains(Self.favKey($0)) }
    }

    // MARK: 收藏
    /// 收藏用稳定标识：优先番号，没有番号就用文件名 —— 目录改名/搬家都不会丢
    static func favKey(_ m: Movie) -> String {
        m.code.isEmpty ? m.displayName : m.code
    }

    func isFavorite(_ m: Movie) -> Bool { favorites.contains(Self.favKey(m)) }

    func toggleFavorite(_ m: Movie) {
        let key = Self.favKey(m)
        if let i = favorites.firstIndex(of: key) {
            favorites.remove(at: i)
        } else {
            if favorites.count >= favoriteLimit { favorites.removeFirst() }
            favorites.append(key)
        }
        saveFavorites()
    }

    private func saveFavorites() {
        UserDefaults.standard.set(favorites, forKey: "favorites")
    }

    // MARK: 目录
    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        if panel.runModal() == .OK, let url = panel.url {
            root = url
            UserDefaults.standard.set(url.path, forKey: "root")
            favorites = []
            reload()
        }
    }

    // MARK: 播放
    @discardableResult
    func play(_ m: Movie, inApp: Bool = false) -> Movie? {
        if inApp {
            playingInApp = m
            return m
        }
        Player.open(url: m.url, prefer: playerName)
        show(message: "\(playerName) 已开始播放 · \(m.code)")
        return nil
    }

    func show(message text: String) {
        message = text
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            if self.message == text { self.message = nil }
        }
    }

    func refresh() { reload() }
}
