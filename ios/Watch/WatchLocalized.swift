import Foundation

/// Watch 端本地化辅助：等同于 iPhone 端的 `L(_:_:)`。
/// 用当前语言对应的 `.lproj` bundle，可在任意线程调用。
func LW(_ key: String, _ arguments: CVarArg...) -> String {
    let format = currentWatchBundle().localizedString(forKey: key, value: nil, table: nil)
    guard !arguments.isEmpty else { return format }
    return String(format: format, arguments: arguments)
}
