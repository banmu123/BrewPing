import AppKit
import BrewPingCore
import CoreImage
import SwiftUI

// ─── 设置与配对（对齐 App.tsx 的 SettingsView）────────────────────────────────
//
// 模态覆盖层：点遮罩 / Esc / 右上角 ✕ 关闭。
// 双栏布局：左侧分类导航（w-36 / 144pt），右侧标题行 + 内容列（max-w-md）。

struct SettingsView: View {
    @EnvironmentObject private var i18n: I18n
    @EnvironmentObject private var app: DesktopAppState

    var body: some View {
        ZStack {
            // 遮罩：点击空白关闭
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { app.settingsOpen = false }

            HStack(spacing: 0) {
                nav
                contentColumn
            }
            .frame(width: 780)
            .frame(maxHeight: 720)
            .frame(height: 620)
            .background(Latte.background)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Latte.border, lineWidth: 1)
            }
            .latteShadow(LatteShadow.panel)
        }
        .onExitCommand { app.settingsOpen = false }
    }

    // MARK: 左侧分类导航

    private var nav: some View {
        VStack(spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    app.settingsSection = section
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon(section))
                            .font(.system(size: 11))
                            .foregroundStyle(Latte.mutedForeground)
                            .frame(width: 14)
                        Text(label(section))
                            .font(LatteFont.xs)
                            .foregroundStyle(Latte.foreground)
                            .fontWeight(app.settingsSection == section ? .medium : .regular)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight()
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(app.settingsSection == section ? Latte.accent : .clear)
                )
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 144)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Latte.card)
    }

    private func icon(_ section: SettingsSection) -> String {
        switch section {
        case .general: return "globe"
        case .machine: return "info.circle"
        case .environment: return "cpu"
        case .pairing: return "qrcode"
        }
    }

    private func label(_ section: SettingsSection) -> String {
        switch section {
        case .general: return i18n.t(.setNavGeneral)
        case .machine: return i18n.t(.setNavMachine)
        case .environment: return i18n.t(.setNavEnvironment)
        case .pairing: return i18n.t(.setNavPairing)
        }
    }

    // MARK: 右侧内容

    private var contentColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(label(app.settingsSection))
                    .font(LatteFont.sm.weight(.medium))
                    .foregroundStyle(Latte.foreground)
                Spacer(minLength: 0)
                Button {
                    app.settingsOpen = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13))
                        .foregroundStyle(Latte.mutedForeground)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight()
                .help(i18n.t(.setClose))
            }
            .padding(.horizontal, 16)
            .frame(height: 48)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    switch app.settingsSection {
                    case .general: languageSection
                    case .machine: machineSection
                    case .environment: EnvironmentCardView()
                    case .pairing: pairingSection
                    }
                }
                .frame(maxWidth: 448, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 语言

    private var languageSection: some View {
        settingsCard(title: i18n.t(.langTitle)) {
            VStack(spacing: 2) {
                languageRow(
                    mode: .system,
                    label: i18n.t(.langSystem),
                    desc: i18n.t(.langCurrent,
                                 ["name": i18n.locale == .zh ? i18n.t(.langZh) : i18n.t(.langEn)])
                )
                languageRow(
                    mode: .zh,
                    label: i18n.t(.langZh),
                    desc: i18n.locale == .zh ? i18n.t(.langCurrent, ["name": i18n.t(.langZh)]) : ""
                )
                languageRow(
                    mode: .en,
                    label: i18n.t(.langEn),
                    desc: i18n.locale == .en ? i18n.t(.langCurrent, ["name": i18n.t(.langEn)]) : ""
                )
            }
        }
    }

    private func languageRow(mode: LangMode, label: String, desc: String) -> some View {
        let selected = i18n.langMode == mode
        return Button {
            i18n.langMode = mode
        } label: {
            HStack(spacing: 8) {
                Text(label)
                    .font(LatteFont.xs)
                    .foregroundStyle(Latte.foreground)
                    .fontWeight(selected ? .medium : .regular)
                Spacer(minLength: 0)
                if !desc.isEmpty {
                    Text(desc)
                        .font(LatteFont.font10)
                        .foregroundStyle(Latte.mutedForeground.opacity(0.7))
                        .lineLimit(1)
                }
                if selected {
                    Text("✓").font(LatteFont.font10).foregroundStyle(Latte.primary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Latte.accent : .clear)
        )
        .help(desc.isEmpty ? label : desc)
    }

    // MARK: 本机信息

    private var machineSection: some View {
        settingsCard(title: i18n.t(.setMachine)) {
            VStack(alignment: .leading, spacing: 6) {
                infoRow(i18n.t(.setDeviceName), app.status?.host ?? "—")
                infoRow(i18n.t(.setDeviceId), app.status?.deviceId ?? "—", mono: true)
                infoRow(i18n.t(.setPlatform),
                        "\(app.status?.platform ?? "—") · v\(app.status?.version ?? "—")")
                infoRow(i18n.t(.setService), i18n.t(serviceStateKey))

                // 局域网提示（iPhone / Apple Watch 通过同一局域网访问）
                VStack(alignment: .leading, spacing: 2) {
                    Text(i18n.t(.setLanAddr))
                        .font(LatteFont.font10)
                        .foregroundStyle(Latte.mutedForeground)
                    Text(lanAddressText)
                        .font(LatteFont.xs)
                        .foregroundStyle(Latte.foreground)
                        .textSelection(.enabled)
                }
                .padding(.top, 4)

                Text(i18n.t(.setLanHint))
                    .font(LatteFont.font10)
                    .foregroundStyle(Latte.mutedForeground.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    RuntimeDot(state: app.runtimeState, size: 6)
                    Text("mDNS: " + (app.status?.mdnsRunning == true ? i18n.t(.setMdnsOn) : i18n.t(.setMdnsOff)))
                        .font(LatteFont.font10)
                        .foregroundStyle(Latte.mutedForeground)
                }
                .padding(.top, 2)
            }
        }
    }

    private var serviceStateKey: LKey {
        switch app.runtimeState {
        case "online": return .stateOnline
        case "starting": return .stateStarting
        case "offline": return .stateOffline
        default: return .stateIdle
        }
    }

    private var lanAddressText: String {
        guard let status = app.status else { return "—" }
        let ip = status.lanIp ?? "—"
        return "http://\(ip):\(status.port)"
    }

    private func infoRow(_ key: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(LatteFont.xs)
                .foregroundStyle(Latte.mutedForeground)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(mono ? LatteFont.mono11 : LatteFont.xs)
                .foregroundStyle(Latte.foreground)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    // MARK: 配对

    private var pairingSection: some View {
        settingsCard(title: i18n.t(.setPairing)) {
            VStack(alignment: .leading, spacing: 8) {
                if let code = app.pairing?.code {
                    HStack(spacing: 8) {
                        Text(code)
                            .font(LatteFont.xl)
                            .tracking(3)
                            .foregroundStyle(Latte.foreground)
                            .textSelection(.enabled)

                        Button {
                            Task { await app.copyPairingCode() }
                        } label: {
                            Text(app.copied ? i18n.t(.commonCopied) : i18n.t(.commonCopy))
                                .font(LatteFont.xs)
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(LatteButtonStyle(variant: .outline))

                        Button {
                            Task { await app.regeneratePairing() }
                        } label: {
                            Text(i18n.t(.commonRefresh))
                                .font(LatteFont.xs)
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(LatteButtonStyle(variant: .outline))
                        .help(i18n.t(.commonRefresh))

                        Spacer(minLength: 0)
                    }

                    if let expiry = expiryText {
                        Text(i18n.t(.setExpiry, ["time": expiry]))
                            .font(LatteFont.font10)
                            .foregroundStyle(Latte.mutedForeground)
                    }

                    if let url = app.pairing?.url {
                        VStack(spacing: 6) {
                            QRCodeView(text: url, size: 148)
                                .padding(8)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Latte.border, lineWidth: 1)
                                }
                            Text(i18n.t(.setScanHint))
                                .font(LatteFont.font10)
                                .foregroundStyle(Latte.mutedForeground)
                            Text(url)
                                .font(LatteFont.font10)
                                .foregroundStyle(Latte.mutedForeground.opacity(0.65))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    } else {
                        Text(i18n.t(.setWaitingNet))
                            .font(LatteFont.font10)
                            .foregroundStyle(Latte.mutedForeground)
                    }

                    Text(i18n.t(.setManualCode))
                        .font(LatteFont.font10)
                        .foregroundStyle(Latte.mutedForeground.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button {
                        Task { await app.revealPairing() }
                    } label: {
                        Text(i18n.t(.setShowCode))
                            .font(LatteFont.sm)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(LatteButtonStyle(variant: .primary))

                    Text(i18n.t(.setCodeHint))
                        .font(LatteFont.font10)
                        .foregroundStyle(Latte.mutedForeground.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var expiryText: String? {
        guard let raw = app.pairing?.expiresAt else { return nil }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: raw) else { return nil }
        return DesktopDateFormat.expiry(date, locale: i18n.locale)
    }

    // MARK: 卡片外壳

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(LatteFont.font10.weight(.semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Latte.mutedForeground)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Latte.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Latte.border, lineWidth: 1)
        }
    }
}

// MARK: - 二维码

/// 用 CoreImage 的 `CIQRCodeGenerator` 生成二维码（等价于 Windows 的 react-qr-code）。
struct QRCodeView: NSViewRepresentable {
    var text: String
    var size: CGFloat
    /// 前景色（Windows 用 `#4A3B2D` 暖咖）
    var foreground: NSColor = NSColor(Latte.outputNormal)
    var background: NSColor = .white

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = Self.render(text: text, size: size, foreground: foreground, background: background)
    }

    static func render(text: String, size: CGFloat, foreground: NSColor, background: NSColor) -> NSImage? {
        let data = Data(text.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // 着色：把黑白码染成拿铁暖咖（与 Windows 的 fgColor 一致）
        let colored = scaled.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(color: foreground) ?? CIColor.black,
            "inputColor1": CIColor(color: background) ?? CIColor.white,
        ])

        let context = CIContext()
        guard let cgImage = context.createCGImage(colored, from: colored.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}
