import Foundation
import OSLog

/// Watch 端统一日志出口。
///
/// 与主 App 的 `BrewPingLog` 分开，是因为 Watch 是独立 target、独立进程，
/// 共用同一个文件会需要跨 target 引用；分成两个小文件更省事也更好读。
/// 规则一致：涉及用户内容（录音文件名、转写文本）的插值一律 `privacy: .private`。
enum WatchLog {
    private static let subsystem = "com.brewping.ios.watchkitapp"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let audio = Logger(subsystem: subsystem, category: "audio")
}
