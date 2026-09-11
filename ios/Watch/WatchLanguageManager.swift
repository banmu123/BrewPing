import Foundation
import Combine

/// App 内语言切换：watchOS 版本。
///
/// 与 iPhone 端 `LanguageManager` 同构，两个通道：
///  1. SwiftUI 的 `Text("字面量")` → 靠 `.environment(\.locale, ...)`，挂在 Watch 的根视图上。
///  2. String 上下文 → `LW(_:_:)`，读全局的当前语言 bundle 快照。
///
/// iPhone App 通过 WCSession 把语言选择同步过来，避免手表重复维护一份 UI。
final class WatchLanguageManager: ObservableObject {
    static let shared = WatchLanguageManager()

    static let languageDidChange = Notification.Name("WatchLanguageManager.languageDidChange")
    static let syncKey = "language"
    static let storageKey = "WatchLanguageManager.preferredLanguage"

    /// "system" / "zh-Hans" / "en"。
    @Published var preferredLanguage: String {
        didSet {
            UserDefaults.standard.set(preferredLanguage, forKey: Self.storageKey)
            if preferredLanguage != oldValue { applyLanguage() }
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.storageKey) ?? "system"
        self.preferredLanguage = saved
        applyBundle()
    }

    /// 当前实际生效的语言代码。
    var currentLanguageID: String {
        switch preferredLanguage {
        case "system":
            let id = Locale.preferredLanguages.first ?? "en"
            return id.lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
        default:
            return preferredLanguage
        }
    }

    /// 给 `.environment(\.locale, ...)` 用。
    var locale: Locale { Locale(identifier: currentLanguageID) }

    func applyLanguage() {
        applyBundle()
        NotificationCenter.default.post(name: Self.languageDidChange, object: nil)
    }

    /// 由 iPhone 经 WCSession 同步过来的偏好落地。
    func setLanguageFromPhone(_ value: String?) {
        guard let value, ["system", "zh-Hans", "en"].contains(value) else { return }
        if preferredLanguage != value { preferredLanguage = value }
    }

    private func applyBundle() {
        let code = currentLanguageID
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let localized = Bundle(path: path) {
            setCurrentWatchBundle(localized)
        } else {
            setCurrentWatchBundle(Bundle.main)
            WatchLog.app.error("Watch .lproj missing: \(code, privacy: .public)")
        }
    }
}

// MARK: - 全局 bundle 快照（供 `LW(_:_:)` 在任意线程使用）

private let watchBundleLock = NSLock()
private var _currentWatchBundle: Bundle = .main

func currentWatchBundle() -> Bundle {
    watchBundleLock.lock()
    defer { watchBundleLock.unlock() }
    return _currentWatchBundle
}

private func setCurrentWatchBundle(_ bundle: Bundle) {
    watchBundleLock.lock()
    _currentWatchBundle = bundle
    watchBundleLock.unlock()
}
