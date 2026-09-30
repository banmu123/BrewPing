import SwiftUI

/// Help / About 页。
///
/// 审核侧要求每个 App 都能在**站内**找到：
///   - 使用说明（"需要配套电脑端"——Mac / Windows 都支持）
///   - 隐私政策入口
///   - 支持联系方式
///   - 第三方商标免责声明
/// 缺这些会在 2.1 / 5.1.2 / 5.2.1 上被追问。
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = LanguageManager.shared
    @StateObject private var deviceStore = DeviceStore.shared
    /// 远程访问（实验）的开关与中继地址。它是单例，用 `@ObservedObject` 观察其状态。
    @ObservedObject private var remote = RemoteAccess.shared

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
                    Text("BrewPing lets you monitor and control coding-agent sessions running on **your own computer (Mac or Windows PC)** — from your iPhone and Apple Watch, over your local network.")
                    Label("The iPhone app is the remote control.", systemImage: "iphone")
                    Label("A Mac or Windows PC running \(BrewPingConfig.macAppName) does the actual work.", systemImage: "desktopcomputer")
                }

                Section("Set up your computer") {
                    numberedStep(1, "Install and open \(BrewPingConfig.macAppName) on your Mac or Windows PC.")
                    numberedStep(2, "Keep the computer and this iPhone on the same Wi-Fi network.")
                    numberedStep(3, "In \(BrewPingConfig.macAppName), tap “Pairing Code” to reveal a 6-digit code.")
                    numberedStep(4, "In this app, tap + in the device bar, enter the code, and save.")
                    Text("No account is required. The pairing code is exchanged once for a key that is stored in the iOS Keychain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Remote Access (Experimental)") {
                    Toggle("Remote Access", isOn: $remote.isEnabled)
                        .onChange(of: remote.isEnabled) { _, _ in remote.applyChanges() }

                    if remote.isEnabled {
                        TextField("Relay server", text: $remote.relayURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit { remote.applyChanges() }
                        TextField("Relay token (optional)", text: $remote.token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { remote.applyChanges() }
                        LabeledContent("Status", value: remoteStatusText)
                    }

                    Text("BrewPing normally talks to your computer over the local network. With Remote Access on, this iPhone sends its requests through the relay server you enter here, so you can reach a computer that is on another network. Pairing must still be done once on the same Wi-Fi, and requests fall back to the local network whenever the relay is unavailable. The relay only forwards messages — it does not keep their contents.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Experimental: this path is off by default, is not encrypted by BrewPing itself, and BrewPing does not operate any relay server. Run your own, or use a VPN instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Try it without a computer") {
                    Text("Add a Demo device to walk through the whole flow — no computer and no hardware needed. The Demo device simulates status, agents, session control and command results locally.")
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
                    Text("BrewPing has no account, no analytics, and no third-party SDKs. Commands and agent output travel only between your iPhone and the Mac or Windows PC you configured, on your local network. Voice recorded on Apple Watch is transferred to your iPhone and transcribed with Apple's Speech framework — BrewPing does not require on-device-only recognition, so transcription may be performed by Apple's servers. The audio file is deleted afterwards.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("If you turn on Remote Access (experimental), requests travel through the relay server you configured instead of your local network. The relay forwards them without keeping their contents, and BrewPing does not operate any relay server itself.")
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

    /// 远程访问的连接状态文案（本地化）。不直接展示底层错误原文，
    /// 统一为「未连接（自动重试中）」，避免中英混排、也避免泄露内部细节。
    private var remoteStatusText: String {
        switch remote.state {
        case .off:        return L("Off")
        case .connecting: return L("Connecting…")
        case .connected:  return L("Connected")
        case .failed:     return L("Not connected — retrying")
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
