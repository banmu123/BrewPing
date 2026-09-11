import Foundation

/// 上架相关的对外常量集中在这里，方便统一替换。
///
/// ⚠️ 提交前必须把下面两个占位值换成真实信息：
///   - `privacyPolicyURLString`：必须在公网可访问（App Store Connect 也会校验）
///   - `supportEmail`：审核员联系用的邮箱
enum BrewPingConfig {
    /// 隐私政策地址（App Store Connect 的 Privacy Policy URL 字段填同一个）。
    static let privacyPolicyURLString = "https://brewping.app/privacy"

    /// 支持邮箱（App Review Notes 里也会引用）。
    static let supportEmail = "support@brewping.app"

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
