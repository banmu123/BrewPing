import Combine
import Foundation

// ─── 轻量 i18n（对齐 Windows `src/i18n/index.tsx`）────────────────────────────
//
// - `LangMode`（system / zh / en）= 用户选择，持久化后重启仍保持；
// - `locale` = 解析后的实际语言（system → 系统语言探测，非中英 → 回落英文）；
// - 切换 = 改 `@Published` → SwiftUI 全树重渲染，实时生效，无需重启（与
//   Windows 的 Context 重渲染等价）。**不依赖系统语言设置、不需要重启 App**。

/// 用户选择的语言模式。
public enum LangMode: String, CaseIterable, Identifiable {
    case system
    case zh
    case en

    public var id: String { rawValue }
}

/// 受支持的具体语言（system 的探测结果必须落在这个集合里）。
public enum AppLocale: String {
    case zh
    case en

    /// `Intl.DateTimeFormat` 用的 locale 标签（对齐 `intlLocale()`）。
    public var intlTag: String {
        self == .zh ? "zh-CN" : "en-US"
    }

    public var foundationLocale: Locale { Locale(identifier: intlTag) }
}

@MainActor
public final class I18n: ObservableObject {
    private static let storageKey = "brewping.langMode"

    @Published public var langMode: LangMode {
        didSet {
            guard langMode != oldValue else { return }
            UserDefaults.standard.set(langMode.rawValue, forKey: Self.storageKey)
        }
    }

    /// 系统语言只在装载时探测一次（运行中改系统语言本就需重启应用才一致 —— 与
    /// Windows `useMemo(detectSystemLang, [])` 的语义相同）。
    private let systemLang: AppLocale

    public init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        langMode = stored.flatMap(LangMode.init(rawValue:)) ?? .system
        systemLang = Self.detectSystemLang()
    }

    /// 解析后的实际语言（词典 / 日期格式化都用它）。
    public var locale: AppLocale {
        switch langMode {
        case .system: return systemLang
        case .zh: return .zh
        case .en: return .en
        }
    }

    /// 系统语言探测：`zh*` 前缀 → 中文，其余（含未识别）一律英文。
    private static func detectSystemLang() -> AppLocale {
        let raw = (Locale.preferredLanguages.first ?? "en").lowercased()
        for candidate in [AppLocale.zh, AppLocale.en] {
            if raw == candidate.rawValue
                || raw.hasPrefix("\(candidate.rawValue)-")
                || raw.hasPrefix("\(candidate.rawValue)_") {
                return candidate
            }
        }
        return .en
    }

    /// 取文案；支持 `{name}` 插值。
    public func t(_ key: LKey, _ params: [String: String] = [:]) -> String {
        let dict = locale == .zh ? DesktopStrings.zh : DesktopStrings.en
        var s = dict[key] ?? DesktopStrings.zh[key] ?? key.rawValue
        for (k, v) in params {
            s = s.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return s
    }

    /// 便捷：单个插值。
    public func t(_ key: LKey, _ name: String, _ value: String) -> String {
        t(key, [name: value])
    }
}

public extension LKey {
    /// 常见插值键的常量（避免到处写裸字符串）。
    static let pAgent = "agent"
    static let pPath = "path"
    static let pN = "n"
    static let pName = "name"
    static let pVersion = "version"
    static let pTime = "time"
    static let pLabel = "label"
}

// ─── 日期 / 时间格式（对齐 Windows 的 toLocaleString 调用）────────────────────

public enum DesktopDateFormat {
    /// 消息时间戳：`星期五 20:48` / `Friday 20:48`
    public static func messageTime(_ ms: Double, locale: AppLocale) -> String {
        guard ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: ms / 1000)
        let formatter = DateFormatter()
        formatter.locale = locale.foundationLocale
        formatter.dateFormat = "EEEE HH:mm"
        return formatter.string(from: date)
    }

    /// 侧栏元信息行的时间：24 小时制 `20:48`
    public static func clockTime(_ ms: Double, locale: AppLocale) -> String {
        guard ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: ms / 1000)
        let formatter = DateFormatter()
        formatter.locale = locale.foundationLocale
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 配对码过期时间：完整本地化时间（对齐 `toLocaleTimeString`）。
    public static func expiry(_ date: Date, locale: AppLocale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale.foundationLocale
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
