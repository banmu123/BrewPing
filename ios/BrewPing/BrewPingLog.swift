import Foundation
import OSLog

/// 统一日志出口。
///
/// 为什么不再用 `print()`：
///  1. 用户内容（命令原文、语音转写结果）不允许以明文进入系统日志 ——
///     凡涉及用户内容的插值统一使用 `privacy: .private`，Release 下由系统抹除；
///  2. `print` 直接写 stdout，绕过系统日志的级别与持久化策略，也不便于现场排查。
///
/// 注意：`Logger` 的插值只接受系统支持的类型，
/// 因此 `\(error)` 必须先转成 `error.localizedDescription`，
/// 否则编译期就会失败（这是从 `print` 迁移时最常见的坑）。
enum BrewPingLog {
    private static let subsystem = "com.brewping.ios"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let net = Logger(subsystem: subsystem, category: "network")
    static let discovery = Logger(subsystem: subsystem, category: "discovery")
    static let command = Logger(subsystem: subsystem, category: "command")
    static let watch = Logger(subsystem: subsystem, category: "watch")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let demo = Logger(subsystem: subsystem, category: "demo")
}
