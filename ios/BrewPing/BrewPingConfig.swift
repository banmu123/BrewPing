import Foundation

/// 上架相关的对外常量集中在这里，方便统一替换。
enum BrewPingConfig {
    /// 隐私政策地址（App Store Connect 的 Privacy Policy URL 字段填同一个）。
    /// 托管在 GitHub Pages（源文件 `docs/privacy.html`），公网可访问，无需自建服务器。
    static let privacyPolicyURLString = "https://banmu123.github.io/BrewPing/privacy.html"

    /// 支持邮箱（App Review Notes 里也会引用）。
    static let supportEmail = "czkbanmu@163.com"

    /// Mac 端产品名。App 内说明文案统一引用它，避免各写各的。
    static let macAppName = "BrewPing Desktop"

    /// 仅供展示的版本号（与 Info.plist 的 CFBundleShortVersionString 保持一致）。
    static let displayVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"

    static var privacyPolicyURL: URL? {
        URL(string: privacyPolicyURLString)
    }

    static var supportURL: URL? {
        URL(string: "mailto:\(supportEmail)")
    }

    /// Agent 名称属于各自厂商的商标。界面上保留是为了说明"兼容哪些 CLI"，
    /// 但必须同时给出这行免责声明，否则容易触发 Guideline 5.2.1。
    static let trademarkDisclaimer = """
    Agent names are trademarks of their respective owners. \
    BrewPing is not affiliated with, endorsed by, or sponsored by them.
    """
}
