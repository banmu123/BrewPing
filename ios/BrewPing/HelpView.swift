import SwiftUI

/// Help / About 页。
///
/// 审核侧要求每个 App 都能在**站内**找到：
///   - 使用说明（尤其是"需要配套 Mac 端"这件事）
///   - 隐私政策入口
///   - 支持联系方式
///   - 第三方商标免责声明
/// 缺这些会在 2.1 / 5.1.2 / 5.2.1 上被追问。
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = LanguageManager.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Language") {
                    Picker("Language", selection: Binding(
                        get: { language.current },
                        set: { language.set($0) }
                    )) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    Text("App-internal switch. Changes take effect immediately — no need to restart or change iOS system language.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("How BrewPing works") {
                    Text("BrewPing lets you monitor and control coding-agent sessions running on **your own Mac** — from your iPhone and Apple Watch, over your local network.")
                    Label("The iPhone app is the remote control.", systemImage: "iphone")
                    Label("A Mac running \(BrewPingConfig.macAppName) does the actual work.", systemImage: "desktopcomputer")
                }

                Section("Set up your Mac") {
                    numberedStep(1, "Install and open \(BrewPingConfig.macAppName) on your Mac.")
                    numberedStep(2, "Keep the Mac and this iPhone on the same Wi-Fi network.")
                    numberedStep(3, "In \(BrewPingConfig.macAppName), tap “Pairing Code” to reveal a 6-digit code.")
                    numberedStep(4, "In this app, tap + in the device bar, enter the code, and save.")
                    Text("No account is required. The pairing code is exchanged once for a key that is stored in the iOS Keychain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Try it without a Mac") {
                    Text("Add a Demo device to walk through the whole flow — no Mac and no hardware needed. The Demo device simulates status, agents, session control and command results locally.")
                    Button {
                        DeviceStore.shared.addDemoDevice()
                        dismiss()
                    } label: {
                        Label("Add Demo Device", systemImage: "sparkles")
                    }
                }

                Section("Privacy") {
                    if let url = BrewPingConfig.privacyPolicyURL {
                        Link(destination: url) {
                            Label("Privacy Policy", systemImage: "hand.raised")
                        }
                    }
                    Text("BrewPing has no account, no analytics, and no third-party SDKs. Commands, agent output and voice audio stay on your iPhone and your own Mac. They are sent only to the Mac you configured, on your local network.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Support") {
                    if let url = BrewPingConfig.supportURL {
                        Link(destination: url) {
                            Label(BrewPingConfig.supportEmail, systemImage: "envelope")
                        }
                    }
                }

                Section("Legal") {
                    Text(LocalizedStringKey(BrewPingConfig.trademarkDisclaimer))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Version", value: BrewPingConfig.displayVersion)
                }
            }
            .navigationTitle("Help & About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// `text` 用 `LocalizedStringKey` 而不是 `String`：
    /// `Text(String)` 走 verbatim 重载不翻译，调用处传字符串字面量时会自动走这条重载。
    private func numberedStep(_ index: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(index).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(text)
        }
    }
}
