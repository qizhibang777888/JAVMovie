import Foundation

/// 功能开关
///
/// 有些功能先「停用」但代码保留：随时把开关拨回来，不用改任何逻辑。
/// 默认全关；临时想验证可以带环境变量启动，例如：
///   JAVMOVIE_SHOTS=1 JAVMOVIE_HOVER=1 open -n JAVMovie.app
enum FeatureFlags {

    /// 剧照（T-01.jpg … T-xx）展示：点封面弹出的剧照浏览器
    static let shotsEnabled = envBool("JAVMOVIE_SHOTS")

    /// 鼠标「停留」展示：封面悬停时播放键浮现、胶囊按钮悬停高亮
    static let hoverEnabled = envBool("JAVMOVIE_HOVER")

    private static func envBool(_ key: String) -> Bool {
        ProcessInfo.processInfo.environment[key] == "1"
    }
}
