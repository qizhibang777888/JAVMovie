import Foundation
import CryptoKit

/// 一部影片
struct Movie: Identifiable, Hashable, Sendable {
    let id: String              // 路径哈希
    let url: URL                // 视频文件
    let folder: URL             // 所在文件夹
    var code: String            // 番号
    var title: String           // 标题（优先 TX.json 的 標題）
    let displayName: String     // 去掉站名前缀的文件名
    let sizeText: String
    let bytes: Int64
    let modified: Date
    var duration: Double?       // 秒
    var resolution: String?     // "1080p"
    var maker: String?          // 發行
    var publisher: String?      // 片商
    var series: String?
    var director: String?
    var releaseDate: String?
    var score: Double?
    var votes: Int?
    var actors: [String] = []
    var categories: [String] = []
    var jdvbURL: URL?
    var cover: URL?             // 本地 FM.jpg
    var shots: [URL] = []       // 本地 T-01.jpg…
}

/// javdb 抓下来的 TX.json
struct TxInfo: Decodable, Sendable {
    let code: String?
    let title: String?
    let date: String?
    let duration: String?
    let maker: String?
    let publisher: String?
    let series: String?
    let director: String?
    let score: Double?
    let votes: Int?
    let actors: [String]?
    let categories: [String]?
    let page: String?
    let coverName: String?
    let shots: [String]?

    enum CodingKeys: String, CodingKey {
        case code = "番號"
        case title = "標題"
        case date = "日期"
        case duration = "時長"
        case maker = "發行"
        case publisher = "片商"
        case series = "系列"
        case director = "導演"
        case score = "評分"
        case votes = "評分人數"
        case actors = "演員"
        case categories = "類別"
        case page = "页面地址"
        case coverName = "封面文件"
        case shots = "預覽圖文件"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        duration = try c.decodeIfPresent(String.self, forKey: .duration)
        maker = try c.decodeIfPresent(String.self, forKey: .maker)
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        series = try c.decodeIfPresent(String.self, forKey: .series)
        director = try c.decodeIfPresent(String.self, forKey: .director)
        score = try c.decodeIfPresent(Double.self, forKey: .score)
        votes = try c.decodeIfPresent(Int.self, forKey: .votes)
        actors = try c.decodeIfPresent([String].self, forKey: .actors)
        categories = try c.decodeIfPresent([String].self, forKey: .categories)
        page = try c.decodeIfPresent(String.self, forKey: .page)
        coverName = try c.decodeIfPresent(String.self, forKey: .coverName)
        shots = try c.decodeIfPresent([String].self, forKey: .shots)
    }
}

enum NameParser {
    static let videoExts: Set<String> = ["mp4", "mkv", "avi", "mov", "wmv", "ts", "m4v", "webm", "flv", "iso", "rmvb"]
    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp"]

    /// 去掉站名前缀 / 副本标记
    static func clean(_ name: String) -> String {
        var s = (name as NSString).deletingPathExtension
        if let r = s.range(of: #"^\[[^\]]*\]\s*"#, options: .regularExpression) { s.removeSubrange(r) }
        if let r = s.range(of: #"^[^@\s]*(\.com|\.net|\.tv|\.org|\.cc)@\s*"#,
                           options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) }
        if let r = s.range(of: #"^(hhd800|www)\.?[^@\s]*-"#,
                           options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) }
        if let r = s.range(of: #"\s*\(\d+\)$"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 从名字里抠番号
    static func code(from name: String) -> String {
        let work = clean(name)
        guard let re = try? NSRegularExpression(pattern: #"([A-Za-z]{2,6})[-_ ]?(\d{2,5})(?!\d)"#) else { return "" }
        let ns = work as NSString
        guard let m = re.firstMatch(in: work, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 3 else { return "" }
        let letters = ns.substring(with: m.range(at: 1)).uppercased()
        let digits = ns.substring(with: m.range(at: 2))
        return "\(letters)-\(digits)"
    }

    static func id(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.path.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    static func humanSize(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(bytes), i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: v >= 100 || i < 2 ? "%.0f%@" : "%.1f%@", v, units[i])
    }
}
