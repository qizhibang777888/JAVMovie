import Foundation
import AppKit
import AVFoundation
import Combine

// MARK: - 扫描

enum Scanner {
    nonisolated(unsafe) static var lastError: String?

    nonisolated(unsafe) static var plainMode = false

    static func scan(root: URL, deep: Bool = false,
                     progress: (@MainActor @Sendable ([Movie]) -> Void)? = nil) async -> [Movie] {
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
                while let f = walker.nextObject() as? URL {
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

        // 多个视频经常共用一个文件夹（TX.json、FM.jpg）。不要为每个视频
        // 重复读取 JSON 和列举整个目录；USB 盘上这些小 I/O 延迟会被放大。
        struct FolderAssets {
            let tx: TxInfo?
            let imageNames: [String]
        }
        var folderCache: [String: FolderAssets] = [:]

        var movies: [Movie] = []
        for t in targets {
            let code = NameParser.code(from: t.file.lastPathComponent)
            let folderKey = t.folder.path
            let assets: FolderAssets
            if let cached = folderCache[folderKey] {
                assets = cached
            } else {
                let names = (try? fm.contentsOfDirectory(atPath: folderKey)) ?? []
                let loaded = FolderAssets(tx: plainMode ? nil : readTx(in: t.folder), imageNames: names)
                folderCache[folderKey] = loaded
                assets = loaded
            }
            let tx = assets.tx
            let stem = (t.file.lastPathComponent as NSString).deletingPathExtension
            let values = try? t.file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let bytes = Int64(values?.fileSize ?? 0)

            let cover: URL?
            if plainMode {
                cover = nil
            } else {
                let images = assets.imageNames.filter { NameParser.imageExts.contains(($0 as NSString).pathExtension.lowercased()) }
                let lower = images.map { ($0, $0.lowercased()) }
                func pick(_ target: String) -> URL? {
                    guard let hit = lower.first(where: { $0.1 == target.lowercased() })?.0 else { return nil }
                    return t.folder.appendingPathComponent(hit)
                }
                cover = pick("FM.jpg") ?? pick("FM.jpeg") ?? pick(stem + ".jpg")
                    ?? ((tx?.code ?? code).isEmpty ? nil : pick((tx?.code ?? code) + ".jpg"))
            }
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
            // 先把已完成的一批显示出来，不必等整个目录（尤其是 USB 盘）扫描完。
            if movies.count.isMultiple(of: 24), let progress {
                await progress(movies)
            }
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


/// AVFoundation 打不开的容器（MKV/HEVC 等）用 ffprobe 兜底读时长/分辨率
func ffprobeMeta(_ url: URL) -> (duration: Double?, resolution: String?) {
    let candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]
    guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        return (nil, nil)
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = ["-v", "error", "-show_entries", "format=duration",
                   "-show_entries", "stream=codec_type,height", "-of", "json", url.path]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (nil, nil) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
    var dur: Double?
    if let f = obj["format"] as? [String: Any], let d = f["duration"] as? String { dur = Double(d) }
    var res: String?
    if let streams = obj["streams"] as? [[String: Any]],
       let v = streams.first(where: { ($0["codec_type"] as? String) == "video" }),
       let h = v["height"] as? Int, h > 0 {
        res = "\(h)p"
    }
    return (dur, res)
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
            let publishProgress: @MainActor @Sendable ([Movie]) -> Void = { batch in
                guard token == self.loadToken else { return }
                self.movies = batch
            }
            let found = await Task.detached(priority: .userInitiated) {
                await Scanner.scan(root: dir, progress: publishProgress)
            }.value
            if ProcessInfo.processInfo.environment["ID_LOG"] != nil {
                for m in found.prefix(3) {
                    FileHandle.standardError.write("id=\(m.id) path=\(m.url.path)\n".data(using: .utf8)!)
                }
            }
            guard token == self.loadToken else { return }   // 已有更新的请求，丢弃这次结果
            self.lastError = Scanner.lastError
            self.movies = found
            let keys = Set(found.map(Self.favKey))
            self.favorites = self.favorites.filter { keys.contains($0) }
            self.carouselIndex = min(2, max(0, self.favorites.count - 1))
            self.isLoading = false
            await self.loadDurations()
        }
    }

    /// 时长/分辨率缓存：key = 路径，value = [mtime, 字节数, 时长, 分辨率]
    private struct Probe: Codable { var mtime: Double; var bytes: Double; var duration: Double?; var resolution: String? }

    private static let probeCacheURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("MovieShelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("probes.json")
    }()

    private static func readProbeCache() -> [String: Probe] {
        guard let data = try? Data(contentsOf: probeCacheURL),
              let map = try? JSONDecoder().decode([String: Probe].self, from: data) else { return [:] }
        return map
    }

    private static func writeProbeCache(_ map: [String: Probe]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: probeCacheURL, options: .atomic)
    }

    /// 补时长 / 分辨率。
    /// 以前是逐个 `movies[i].duration = ...`（每个都 publish → reloadAll → 重建 138 张卡），
    /// 现在：后台并发探测 → **分批**写回（每批 12 条）+ 结果落盘缓存，UI 只原地刷新文字。
    private func loadDurations() async {
        var snapshot = movies
        let cache = Self.readProbeCache()
        var map = cache
        var dirty = false

        // 1) 缓存命中先填（不 publish）
        for i in snapshot.indices {
            guard let c = cache[snapshot[i].url.path] else { continue }
            guard c.mtime == snapshot[i].modified.timeIntervalSince1970,
                  c.bytes == Double(snapshot[i].bytes) else { continue }
            if snapshot[i].duration == nil { snapshot[i].duration = c.duration }
            if snapshot[i].resolution == nil { snapshot[i].resolution = c.resolution }
        }

        // 2) 缺的按批探测（每批并发 4 个 AVAsset，避免 USB 盘排队过久）
        let pending = snapshot.indices.filter { snapshot[$0].duration == nil || snapshot[$0].resolution == nil }
        let batchSize = 12
        var cursor = 0
        while cursor < pending.count {
            let chunk = Array(pending[cursor..<min(cursor + batchSize, pending.count)])
            cursor += batchSize
            let jobs = chunk.map { (idx: $0, url: snapshot[$0].url,
                                    mtime: snapshot[$0].modified.timeIntervalSince1970,
                                    bytes: Double(snapshot[$0].bytes)) }
            let probed = await Task.detached(priority: .utility) { () -> [Int: Probe] in
                await withTaskGroup(of: (Int, Probe).self) { group in
                    var pendingJobs = jobs[...]
                    var out: [Int: Probe] = [:]
                    let limit = 4
                    func add(_ job: (idx: Int, url: URL, mtime: Double, bytes: Double)) {
                        group.addTask {
                            var p = Probe(mtime: job.mtime, bytes: job.bytes, duration: nil, resolution: nil)
                            let asset = AVURLAsset(url: job.url)
                            if let d = try? await asset.load(.duration) {
                                let secs = CMTimeGetSeconds(d)
                                if secs.isFinite && secs > 0 { p.duration = secs }
                            }
                            if let track = try? await asset.loadTracks(withMediaType: .video).first,
                               let size = try? await track.load(.naturalSize) {
                                p.resolution = "\(Int(abs(size.height)))p"
                            }
                            if p.duration == nil || p.resolution == nil {
                                let meta = ffprobeMeta(job.url)
                                if p.duration == nil { p.duration = meta.duration }
                                if p.resolution == nil { p.resolution = meta.resolution }
                            }
                            return (job.idx, p)
                        }
                    }
                    for _ in 0..<min(limit, pendingJobs.count) {
                        if let j = pendingJobs.first { pendingJobs.removeFirst(); add(j) }
                    }
                    while let (idx, p) = await group.next() {
                        out[idx] = p
                        if let j = pendingJobs.first { pendingJobs.removeFirst(); add(j) }
                    }
                    return out
                }
            }.value

            var changed = false
            for (i, p) in probed {
                if snapshot[i].duration == nil { snapshot[i].duration = p.duration; changed = true }
                if snapshot[i].resolution == nil { snapshot[i].resolution = p.resolution; changed = true }
                map[snapshot[i].url.path] = p
            }
            dirty = true
            if changed { movies = snapshot }     // 一批一次 publish（卡片原地刷新）
            Self.writeProbeCache(map)            // 每批落盘：中途退出也不白探
        }

        if snapshot != movies { movies = snapshot }
        if dirty { Self.writeProbeCache(map) }
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
