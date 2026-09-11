import Foundation
import Combine

/// App 内语言切换。
///
/// **为什么需要它**：系统自带的本地化只能在「设置 → 通用 → 语言与地区」里改，
/// 而且改完要重启 App。这里要做的是 App 内直接切、切完立刻生效。
///
/// **实现有两个独立通道**，缺一不可（这是踩过的坑）：
///
/// 1. **SwiftUI 的 `Text("字面量")`** —— 走 `LocalizedStringKey`，
///    由 environment 里的 `Locale` 决定查哪个 `.lproj`。
///    所以要在视图树的根上挂 `.environment(\.locale, ...)`。
///    *尝试过* 用 `object_setClass(Bundle.main, ...)` 覆盖 `localizedString(forKey:value:table:)`，
///    实测对 SwiftUI **无效**（SwiftUI 不走这条路径；中文能显示只是因为系统语言恰好是中文），
///    已放弃。
///
/// 2. **String 上下文**（状态变量、拼接、格式化）—— 由 `L(_:_:)` 走
///    `bundle.localizedString(forKey:value:table:)`，其中 bundle 是当前语言对应的
///    `.lproj` 包。这里必须显式指定 bundle，不能依赖 `Bundle.main` 的重定向。
enum AppLanguage: String, CaseIterable, Identifiable {
    /// 跟随系统（默认）。
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// 当前实际生效的 `.lproj` 代码。
    /// `.system` 时返回系统首选语言解析结果，用于给 SwiftUI 传 locale。
    var resolvedCode: String {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        }
    }

    /// 给 `.environment(\.locale, ...)` 用的 Locale。
    var locale: Locale { Locale(identifier: resolvedCode) }

    /// 列表里显示的名称。
    ///
    /// 语言名一律用**该语言自己的写法**（English / 简体中文），
    /// 这样不管当前界面是什么语言，用户都能一眼认出自己要选哪个；
    /// 「跟随系统」才需要跟着当前语言翻译。
    var displayName: String {
        switch self {
        case .system:            return L("Follow System")
        case .english:           return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

/// 当前语言的 `.lproj` bundle。
///
/// 做成**非隔离**的全局快照（带锁），而不是只放在 `LanguageManager` 里：
/// `L(_:_:)` 会在后台回调（网络返回、WCSession）里被调用，
/// 那里拿不到 `@MainActor` 的实例。
private let bundledLock = NSLock()
private var _currentBundle: Bundle = .main

/// 当前语言对应的 bundle；语言包缺失时回退 `Bundle.main`。
func currentLocalizedBundle() -> Bundle {
    bundledLock.lock()
    defer { bundledLock.unlock() }
    return _currentBundle
}

private func setCurrentLocalizedBundle(_ bundle: Bundle) {
    bundledLock.lock()
    _currentBundle = bundle
    bundledLock.unlock()
}

/// 语言偏好 + 当前语言的 bundle。
@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    /// 存 `AppLanguage.rawValue`。
    static let storageKey = "BrewPing.AppLanguage"
    /// 经 WCSession 同步给 Watch 的 key。
    static let syncKey = "language"

    @Published private(set) var current: AppLanguage

    /// 当前语言对应的 `.lproj` bundle（主线程读取用）。
    private(set) var bundle: Bundle = .main

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppLanguage.system.rawValue
        current = AppLanguage(rawValue: raw) ?? .system
        applyBundle(for: current)
    }

    /// 切换语言。写偏好 + 刷新 bundle，SwiftUI 侧由 `.environment(\.locale)` 重建。
    func set(_ language: AppLanguage) {
        guard language != current else { return }
        current = language
        UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
        applyBundle(for: language)
        // 顺手把手表也切过去，避免两端语言不一致。
        WatchConnectivityManager.shared.pushLanguage()
        BrewPingLog.app.info("App language changed to \(language.rawValue, privacy: .public)")
    }

    /// 应用来自外部（启动时 / Watch 反向同步）的语言偏好，不写回 UserDefaults。
    func applyExternal(_ raw: String) {
        let language = AppLanguage(rawValue: raw) ?? .system
        guard language != current else { return }
        current = language
        applyBundle(for: language)
    }

    /// 刷新实例与全局快照。**注意不能引用 `LanguageManager.shared`**：
    /// 本方法会在 `init` 里被调用，那时 `shared` 还没赋值。
    private func applyBundle(for language: AppLanguage) {
        let code = language.resolvedCode
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let localized = Bundle(path: path) {
            bundle = localized
            setCurrentLocalizedBundle(localized)
        } else {
            // 语言包不存在（例如工程没把 zh-Hans 配好）：
            // 退回 main bundle（系统默认），界面显示系统语言而不是空白。
            bundle = .main
            setCurrentLocalizedBundle(.main)
            BrewPingLog.app.error("Missing .lproj for \(code, privacy: .public); falling back to system")
        }
    }
}

/// 本地化一个字符串，用于 **String 上下文**。
///
/// `Text` / `Label` 这类接受 `LocalizedStringKey` 的地方不需要它（走 `.environment(\.locale)`）；
/// 但下面这些情况只能用它：
///   - 赋值给 `String` 状态变量（如 `sessionMessage`、`statusError`）；
///   - 还需要再拼接、参与 `String(format:)` 的错误信息；
///   - 后端返回的兜底文案。
/// 例如：`sessionMessage = L("Start failed: %@", reason)`。
///
/// 占位符统一用 `%@`（参数传 `String`）。**不要**用 `%lld` 传 `Int`：
/// `%@` + `String(值)` 在各种位宽下都安全。
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = currentLocalizedBundle().localizedString(forKey: key, value: nil, table: nil)
    guard !arguments.isEmpty else { return format }
    return String(format: format, arguments: arguments)
}
