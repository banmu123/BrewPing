import BrewPingCore
import SwiftUI

// ─── 设置页「xxx 厂商 · <文件名>」面板（对齐 Windows 各 `*-provider-panel.tsx`）──
//
// 与 Windows 的分工一致：**只在对应 Agent tab 下渲染**（Codex tab → Codex 面板，
// 以此类推）。这些面板直接读写用户真实的 CLI 配置文件，与上方「BrewPing 自有
// 供应商库」是两套东西 —— 后者服务转发链路，这里服务"让 CLI 自己用上你的中转站"。

// MARK: - 共享容器

/// 面板外框（与 Windows 的 `rounded-lg border` 卡片同构）。
private func cliCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6, content: content)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Latte.card)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Latte.border, lineWidth: 1)
        }
}

/// 面板标题行：标题 + 「文件名」徽章 + 右侧操作按钮。
private func cliPanelHeader(
    title: String, fileBadge: String, addTitle: String, disabled: Bool, onAdd: @escaping () -> Void
) -> some View {
    HStack(spacing: 6) {
        Text(verbatim: title)
            .font(LatteFont.sm.weight(.medium))
            .foregroundStyle(Latte.foreground)
        LatteBadge(variant: .muted, text: fileBadge)
        Spacer(minLength: 0)
        Button {
            onAdd()
        } label: {
            Label(addTitle, systemImage: "plus").font(LatteFont.xs)
        }
        .buttonStyle(LatteButtonStyle(variant: .outline))
        .disabled(disabled)
    }
}

/// 文件路径行（让用户知道东西写到哪了）。
private func cliFilePath(_ path: String, exists: Bool, missingLabel: String) -> some View {
    HStack(spacing: 4) {
        Image(systemName: "doc.text")
            .font(.system(size: 10))
            .foregroundStyle(Latte.mutedForeground)
        Text(verbatim: path)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Latte.mutedForeground)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        if !exists {
            LatteBadge(variant: .warning, text: missingLabel)
        }
        Spacer(minLength: 0)
    }
}

/// 两行式内联错误提示。
private func cliError(_ message: String?) -> some View {
    Group {
        if let message {
            Text(verbatim: message)
                .font(LatteFont.xs)
                .foregroundStyle(Latte.destructive)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 只读信息行（用于「会保留哪些顶层键」这类提示）。
private func cliInfoLine(_ text: String) -> some View {
    Text(verbatim: text)
        .font(LatteFont.xs)
        .foregroundStyle(Latte.mutedForeground)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - OpenCode 面板

extension OpenCodeProviderEntry: Identifiable {}

struct OpenCodeProviderPanel: View {
    @ObservedObject private var i18n = I18n()
    @State private var info: OpenCodeProvidersInfo?
    @State private var editing: OpenCodeProviderEntry?
    @State private var confirmId: String?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        cliCard {
            cliPanelHeader(
                title: i18n.t(.ocTitle), fileBadge: "opencode.json",
                addTitle: i18n.t(.ocAddTitle), disabled: busy
            ) { editing = OpenCodeProviderEntry() }
            cliInfoLine(i18n.t(.ocSubtitle))
            cliFilePath(info?.configFile ?? "", exists: info?.exists ?? false,
                        missingLabel: i18n.t(.ocNotCreated))
            cliError(error)

            let providers = info?.providers ?? []
            if providers.isEmpty {
                cliInfoLine(i18n.t(.ocEmptyHint))
            } else {
                ForEach(providers) { provider in
                    providerRow(provider)
                }
            }
        }
        .task { await reload() }
        .sheet(item: $editing) { draft in
            OpenCodeProviderForm(
                draft: draft,
                packages: info?.npmPackages ?? OpenCodeProviderConfigStore.npmPackages,
                isNew: draft.id.isEmpty,
                onSave: { entry in Task { await save(entry) } },
                onCancel: { editing = nil }
            )
        }
    }

    private func providerRow(_ provider: OpenCodeProviderEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: provider.name)
                    .font(LatteFont.sm.weight(.medium))
                    .foregroundStyle(Latte.foreground)
                    .lineLimit(1)
                LatteBadge(variant: .muted, text: provider.id)
                Spacer(minLength: 0)
                Button {
                    editing = provider
                } label: {
                    Image(systemName: "pencil").font(.system(size: 11))
                }
                .buttonStyle(LatteButtonStyle(variant: .ghost))
                .disabled(busy)

                if confirmId == provider.id {
                    Button(i18n.t(.mpConfirmDelete)) {
                        Task { await delete(provider.id) }
                    }
                    .buttonStyle(LatteButtonStyle(variant: .primary))
                    .font(LatteFont.xs)
                    .disabled(busy)
                } else {
                    Button {
                        confirmId = provider.id
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11))
                    }
                    .buttonStyle(LatteButtonStyle(variant: .ghost))
                    .disabled(busy)
                }
            }
            HStack(spacing: 6) {
                Text(verbatim: provider.baseURL)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Latte.mutedForeground)
                    .lineLimit(1)
                LatteBadge(variant: .muted, text: provider.npm)
                LatteBadge(
                    variant: provider.apiKey.isEmpty ? .muted : .success,
                    text: provider.apiKey.isEmpty ? i18n.t(.mpKeyMissing) : i18n.t(.mpKeySet)
                )
                Text(verbatim: i18n.t(.ocModelCount, ["n": String(provider.models.count)]))
                    .font(LatteFont.xs)
                    .foregroundStyle(Latte.mutedForeground)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
    }

    private func reload() async {
        let next = await offMainLoad { DesktopCommands.openCodeProviders() }
        info = next
    }

    private func save(_ entry: OpenCodeProviderEntry) async {
        busy = true
        defer { busy = false }
        do {
            let next = try await offMainThrowing { try DesktopCommands.saveOpenCodeProvider(entry) }
            info = next
            editing = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ id: String) async {
        confirmId = nil
        busy = true
        defer { busy = false }
        do {
            info = try await offMainThrowing { try DesktopCommands.deleteOpenCodeProvider(id: id) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Claude 面板（单例）

struct ClaudeProviderPanel: View {
    @ObservedObject private var i18n = I18n()
    @State private var info: ClaudeProvidersInfo?
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        cliCard {
            cliPanelHeader(
                title: i18n.t(.clTitle), fileBadge: "settings.json",
                addTitle: i18n.t(.clConfigure), disabled: busy
            ) { confirmDelete = false; editing = true }
            cliInfoLine(i18n.t(.clSubtitle))
            cliFilePath(info?.configFile ?? "", exists: info?.exists ?? false,
                        missingLabel: i18n.t(.ocNotCreated))
            cliError(error)

            let provider = info?.provider ?? ClaudeProviderEntry()
            if !(info?.configured ?? false) {
                cliInfoLine(i18n.t(.clEmpty))
                cliInfoLine(i18n.t(.clEmptyHint))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(verbatim: provider.baseURL)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Latte.foreground)
                            .lineLimit(1)
                        LatteBadge(
                            variant: provider.apiKey.isEmpty ? .muted : .success,
                            text: provider.apiKey.isEmpty ? i18n.t(.mpKeyMissing) : i18n.t(.mpKeySet)
                        )
                        Spacer(minLength: 0)
                        if confirmDelete {
                            Button(i18n.t(.mpConfirmDelete)) {
                                Task { await deleteProvider() }
                            }
                            .buttonStyle(LatteButtonStyle(variant: .primary))
                            .font(LatteFont.xs)
                            .disabled(busy)
                        } else {
                            Button(i18n.t(.mpDelete)) { confirmDelete = true }
                                .buttonStyle(LatteButtonStyle(variant: .ghost))
                                .font(LatteFont.xs)
                                .disabled(busy)
                        }
                    }
                    ForEach(provider.tiers, id: \.tier) { tier in
                        HStack(spacing: 6) {
                            LatteBadge(variant: .muted, text: tier.tier)
                            Text(verbatim: tier.model)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Latte.mutedForeground)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    if !provider.otherKeys.isEmpty {
                        cliInfoLine(i18n.t(.clOtherKeysHint))
                        cliInfoLine(provider.otherKeys.joined(separator: " · "))
                    } else {
                        cliInfoLine(i18n.t(.clOtherKeysNone))
                    }
                }
            }
        }
        .task { await reload() }
        .sheet(isPresented: $editing) {
            ClaudeProviderForm(
                draft: info?.provider ?? ClaudeProviderEntry(),
                onSave: { entry in Task { await save(entry) } },
                onCancel: { editing = false }
            )
        }
    }

    private func reload() async {
        info = await offMainLoad { DesktopCommands.claudeProvider() }
    }

    private func save(_ entry: ClaudeProviderEntry) async {
        busy = true
        defer { busy = false }
        do {
            info = try await offMainThrowing { try DesktopCommands.saveClaudeProvider(entry) }
            editing = false
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteProvider() async {
        confirmDelete = false
        busy = true
        defer { busy = false }
        do {
            info = try await offMainThrowing { try DesktopCommands.deleteClaudeProvider() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Codex 面板

extension CodexProviderEntry: Identifiable {}

struct CodexProviderPanel: View {
    @ObservedObject private var i18n = I18n()
    @State private var info: CodexProvidersInfo?
    @State private var editing: CodexProviderEntry?
    @State private var confirmId: String?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        cliCard {
            cliPanelHeader(
                title: i18n.t(.cxTitle), fileBadge: "config.toml",
                addTitle: i18n.t(.cxAddTitle), disabled: busy
            ) { editing = CodexProviderEntry() }
            cliInfoLine(i18n.t(.cxSubtitle))
            cliFilePath(info?.configFile ?? "", exists: info?.exists ?? false,
                        missingLabel: i18n.t(.ocNotCreated))
            cliError(error)

            let providers = info?.providers ?? []
            if providers.isEmpty {
                cliInfoLine(i18n.t(.cxEmptyHint))
            } else {
                ForEach(providers) { provider in
                    providerRow(provider)
                }
            }
        }
        .task { await reload() }
        .sheet(item: $editing) { draft in
            CodexProviderForm(
                draft: draft,
                wireApis: info?.wireApis ?? CodexProviderConfigStore.wireApis,
                isNew: draft.id.isEmpty,
                onSave: { entry in Task { await save(entry) } },
                onCancel: { editing = nil }
            )
        }
    }

    private func providerRow(_ provider: CodexProviderEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if provider.active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Latte.primary)
                }
                Text(verbatim: provider.id)
                    .font(LatteFont.sm.weight(.medium))
                    .foregroundStyle(Latte.foreground)
                    .lineLimit(1)
                if provider.active {
                    LatteBadge(variant: .success, text: i18n.t(.cxActive))
                }
                Spacer(minLength: 0)
                if !provider.active {
                    Button(i18n.t(.cxActivate)) {
                        Task { await activate(provider.id) }
                    }
                    .buttonStyle(LatteButtonStyle(variant: .ghost))
                    .font(LatteFont.xs)
                    .disabled(busy)
                }
                Button {
                    editing = provider
                } label: {
                    Image(systemName: "pencil").font(.system(size: 11))
                }
                .buttonStyle(LatteButtonStyle(variant: .ghost))
                .disabled(busy)
                if confirmId == provider.id {
                    Button(i18n.t(.mpConfirmDelete)) {
                        Task { await delete(provider.id) }
                    }
                    .buttonStyle(LatteButtonStyle(variant: .primary))
                    .font(LatteFont.xs)
                    .disabled(busy)
                } else {
                    Button {
                        confirmId = provider.id
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11))
                    }
                    .buttonStyle(LatteButtonStyle(variant: .ghost))
                    .disabled(busy)
                }
            }
            HStack(spacing: 6) {
                Text(verbatim: provider.baseURL.isEmpty ? "—" : provider.baseURL)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Latte.mutedForeground)
                    .lineLimit(1)
                LatteBadge(variant: .muted, text: provider.wireApi)
                LatteBadge(
                    variant: provider.apiKey.isEmpty ? .muted : .success,
                    text: provider.apiKey.isEmpty ? i18n.t(.mpKeyMissing) : i18n.t(.mpKeySet)
                )
                if !provider.model.isEmpty {
                    Text(verbatim: provider.model)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Latte.mutedForeground.opacity(0.8))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
    }

    private func reload() async {
        info = await offMainLoad { DesktopCommands.codexProviders() }
    }

    private func save(_ entry: CodexProviderEntry) async {
        busy = true
        defer { busy = false }
        do {
            info = try await offMainThrowing { try DesktopCommands.saveCodexProvider(entry) }
            editing = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ id: String) async {
        confirmId = nil
        busy = true
        defer { busy = false }
        do {
            info = try await offMainThrowing { try DesktopCommands.deleteCodexProvider(id: id) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func activate(_ id: String) async {
        busy = true
        defer { busy = false }
        do {
            info = try await offMainThrowing { try DesktopCommands.activateCodexProvider(id: id) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - pi 面板

extension PiProviderEntry: Identifiable {}

struct PiProviderPanel: View {
    @ObservedObject private var i18n = I18n()
    @State private var info: PiProvidersInfo?
    @State private var editing: PiProviderEntry?
    @State private var confirmId: String?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        cliCard {
            cliPanelHeader(
                title: i18n.t(.piTitle), fileBadge: "models.json",
                addTitle: i18n.t(.piAddTitle), disabled: busy
            ) { editing = PiProviderEntry() }
            cliInfoLine(i18n.t(.piSubtitle))
            cliFilePath(info?.configFile ?? "", exists: info?.exists ?? false,
                        missingLabel: i18n.t(.ocNotCreated))
            cliError(error)

            let providers = info?.providers ?? []
            if providers.isEmpty {
                cliInfoLine(i18n.t(.piEmptyHint))
            } else {
                ForEach(providers) { provider in
                    providerRow(provider)
                }
            }
        }
        .task { await reload() }
        .sheet(item: $editing) { draft in
            PiProviderForm(
                draft: draft,
                apis: info?.apis ?? PiProviderConfigStore.apis,
                isNew: draft.id.isEmpty,
                onSave: { entry in Task { await save(entry) } },
                onCancel: { editing = nil }
            )
        }
    }

    private func providerRow(_ provider: PiProviderEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if provider.isDefault {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Latte.primary)
                }
                Text(verbatim: provider.id)
                    .font(LatteFont.sm.weight(.medium))
                    .foregroundStyle(Latte.foreground)
                    .lineLimit(1)
                if provider.isDefault {
                    LatteBadge(variant: .success, text: i18n.t(.piDefault))
                }
                Spacer(minLength: 0)
                if !provider.isDefault {
                    Button(i18n.t(.piSetDefault)) {
                        Task { await activate(provider.id) }
                    }
                    .buttonStyle(LatteButtonStyle(variant: .ghost))
                    .font(LatteFont.xs)
                    .disabled(busy)
                }
                Button {
                    editing = provider
                } label: {
                    Image(systemName: "pencil").font(.system(size: 11))
                }
                .buttonStyle(LatteButtonStyle(variant: .ghost))
                .disabled(busy)
                if confirmId == provider.id {
                    Button(i18n.t(.mpConfirmDelete)) {
                        Task { await delete(provider.id) }
                    }
                    .buttonStyle(LatteButtonStyle(variant: .primary))
                    .font(LatteFont.xs)
                    .disabled(busy)
                } else {
                    Button {
                        confirmId = provider.id
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11))
                    }
                    .buttonStyle(LatteButtonStyle(variant: .ghost))
                    .disabled(busy)
                }
            }
            HStack(spacing: 6) {
                Text(verbatim: provider.baseURL.isEmpty ? "—" : provider.baseURL)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Latte.mutedForeground)
                    .lineLimit(1)
                LatteBadge(variant: .muted, text: provider.api)
                Text(verbatim: i18n.t(.piModelCount, ["n": String(provider.models.count)]))
                    .font(LatteFont.xs)
                    .foregroundStyle(Latte.mutedForeground)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
    }

    private func reload() async {
        info = await offMainLoad { DesktopCommands.piProviders() }
    }

    private func save(_ entry: PiProviderEntry) async {
        busy = true
        defer { busy = false }
        do {
            info = try await offMainThrowing { try DesktopCommands.savePiProvider(entry) }
            editing = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ id: String) async {
        confirmId = nil
        busy = true
        defer { busy = false }
        do {
            info = try await offMainThrowing { try DesktopCommands.deletePiProvider(id: id) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func activate(_ id: String) async {
        busy = true
        defer { busy = false }
        do {
            info = try await offMainThrowing {
                try DesktopCommands.activatePiProvider(id: id, model: nil)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 后台执行助手（避免阻塞主线程）

func offMainLoad<T>(_ work: @escaping () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: work())
        }
    }
}

func offMainThrowing<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do { continuation.resume(returning: try work()) }
            catch { continuation.resume(throwing: error) }
        }
    }
}

// MARK: - 表单共享件

private func formField<Content: View>(
    _ label: String, @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(verbatim: label)
            .font(LatteFont.xs.weight(.medium))
            .foregroundStyle(Latte.mutedForeground)
        content()
    }
}

private func formHint(_ text: String) -> some View {
    Text(verbatim: text)
        .font(LatteFont.xs)
        .foregroundStyle(Latte.mutedForeground)
        .fixedSize(horizontal: false, vertical: true)
}

/// 模型行编辑器（opencode / pi 共用）。
private struct ModelRowsEditor: View {
    @Binding var models: [String]      // "id\u{1}name"
    var idPlaceholder: String
    var namePlaceholder: String
    var addTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(models.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    TextField(idPlaceholder, text: binding(index: index, namePart: false))
                        .textFieldStyle(.roundedBorder)
                        .font(LatteFont.xs)
                    TextField(namePlaceholder, text: binding(index: index, namePart: true))
                        .textFieldStyle(.roundedBorder)
                        .font(LatteFont.xs)
                    Button {
                        if models.indices.contains(index) { models.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Latte.mutedForeground)
                }
            }
            Button {
                models.append("\u{1}")
            } label: {
                Label(addTitle, systemImage: "plus").font(LatteFont.xs)
            }
            .buttonStyle(LatteButtonStyle(variant: .outline))
        }
    }

    /// 以 `id\u{1}name` 编码存两列，避免为每种模型类型各写一个 @State。
    private func binding(index: Int, namePart: Bool) -> Binding<String> {
        Binding(
            get: {
                guard models.indices.contains(index) else { return "" }
                let parts = models[index].components(separatedBy: "\u{1}")
                return namePart ? (parts.count > 1 ? parts[1] : "") : (parts.first ?? "")
            },
            set: { newValue in
                guard models.indices.contains(index) else { return }
                let parts = models[index].components(separatedBy: "\u{1}")
                let id = namePart ? (parts.first ?? "") : newValue
                let name = namePart ? newValue : (parts.count > 1 ? parts[1] : "")
                models[index] = id + "\u{1}" + name
            }
        )
    }

    static func encode(_ models: [OpenCodeModelEntry]) -> [String] {
        models.map { $0.id + "\u{1}" + $0.name }
    }
    static func decode(_ encoded: [String]) -> [OpenCodeModelEntry] {
        encoded.compactMap { row in
            let parts = row.components(separatedBy: "\u{1}")
            let id = parts.first ?? ""
            return id.isEmpty ? nil : OpenCodeModelEntry(id: id, name: parts.count > 1 ? parts[1] : "")
        }
    }
    static func decodePi(_ encoded: [String]) -> [PiModelEntry] {
        encoded.compactMap { row in
            let parts = row.components(separatedBy: "\u{1}")
            let id = parts.first ?? ""
            return id.isEmpty ? nil : PiModelEntry(id: id, name: parts.count > 1 ? parts[1] : "")
        }
    }
    static func encodePi(_ models: [PiModelEntry]) -> [String] {
        models.map { $0.id + "\u{1}" + $0.name }
    }
}

private func formScaffold<Content: View>(
    title: String,
    cancelTitle: String,
    saveTitle: String,
    error: String?,
    busy: Bool,
    onCancel: @escaping () -> Void,
    onSave: @escaping () -> Void,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        Text(verbatim: title)
            .font(LatteFont.sm.weight(.medium))
            .foregroundStyle(Latte.foreground)
            .padding(12)
        Divider()
        ScrollView {
            VStack(alignment: .leading, spacing: 10, content: content)
                .padding(12)
        }
        Divider()
        HStack(spacing: 8) {
            cliError(error)
            Spacer(minLength: 0)
            Button(cancelTitle) { onCancel() }
                .buttonStyle(LatteButtonStyle(variant: .outline))
                .font(LatteFont.xs)
            Button(saveTitle) { onSave() }
                .buttonStyle(LatteButtonStyle(variant: .primary))
                .font(LatteFont.xs)
                .disabled(busy)
        }
        .padding(12)
    }
    .frame(width: 520, height: 560)
}

// MARK: - OpenCode 表单

struct OpenCodeProviderForm: View {
    @ObservedObject private var i18n = I18n()
    let packages: [NpmPackageOption]
    let isNew: Bool
    let onSave: (OpenCodeProviderEntry) -> Void
    let onCancel: () -> Void

    @State private var draft: OpenCodeProviderEntry
    @State private var rows: [String]
    @State private var error: String?

    init(
        draft: OpenCodeProviderEntry, packages: [NpmPackageOption], isNew: Bool,
        onSave: @escaping (OpenCodeProviderEntry) -> Void, onCancel: @escaping () -> Void
    ) {
        self.packages = packages
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: draft)
        _rows = State(initialValue: ModelRowsEditor.encode(draft.models))
    }

    var body: some View {
        formScaffold(
            title: isNew ? i18n.t(.ocAddTitle) : i18n.t(.ocEditTitle),
            cancelTitle: i18n.t(.mpCancel), saveTitle: i18n.t(.mpSave),
            error: error, busy: false, onCancel: onCancel, onSave: submit
        ) {
            formField(i18n.t(.ocKey)) {
                TextField(i18n.t(.ocKeyPlaceholder), text: $draft.id)
                    .textFieldStyle(.roundedBorder)
                    .font(LatteFont.xs)
                    .disabled(!isNew)      // 改 key = 新建，编辑时锁定
            }
            formHint(i18n.t(.ocKeyHint))
            formField(i18n.t(.mpName)) {
                TextField(i18n.t(.ocNamePlaceholder), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .font(LatteFont.xs)
            }
            formField(i18n.t(.mpBaseUrl)) {
                TextField(i18n.t(.mpBaseUrlPlaceholder), text: $draft.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(LatteFont.xs)
            }
            formField(i18n.t(.ocNpm)) {
                Picker("", selection: $draft.npm) {
                    ForEach(packages, id: \.value) { option in
                        Text(verbatim: option.label).tag(option.value)
                    }
                }
                .labelsHidden()
            }
            formField(i18n.t(.mpApiKey)) {
                SecureField("sk-…", text: $draft.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(LatteFont.xs)
            }
            formField(i18n.t(.ocModels)) {
                ModelRowsEditor(
                    models: $rows, idPlaceholder: i18n.t(.ocModelIdPlaceholder),
                    namePlaceholder: i18n.t(.ocModelNamePlaceholder),
                    addTitle: i18n.t(.ocAddModel)
                )
            }
            formHint(i18n.t(.ocFormHint))
            formHint(i18n.t(.ocHeadersHint))
        }
    }

    private func submit() {
        var entry = draft
        entry.id = draft.id.trimmingCharacters(in: .whitespaces).lowercased()
        entry.name = draft.name.trimmingCharacters(in: .whitespaces)
        entry.baseURL = draft.baseURL.trimmingCharacters(in: .whitespaces)
        entry.apiKey = draft.apiKey.trimmingCharacters(in: .whitespaces)
        entry.models = ModelRowsEditor.decode(rows)

        if entry.id.isEmpty { error = i18n.t(.ocErrKeyRequired); return }
        if !OpenCodeProviderConfigStore.isValidProviderKey(entry.id) {
            error = i18n.t(.ocErrKeyFormat); return
        }
        if entry.baseURL.isEmpty { error = i18n.t(.ocErrBaseRequired); return }
        if !(entry.baseURL.hasPrefix("http://") || entry.baseURL.hasPrefix("https://")) {
            error = i18n.t(.ocErrBaseScheme); return
        }
        if entry.models.isEmpty { error = i18n.t(.ocErrModelsRequired); return }
        error = nil
        onSave(entry)
    }
}

// MARK: - Claude 表单

struct ClaudeProviderForm: View {
    @ObservedObject private var i18n = I18n()
    let onSave: (ClaudeProviderEntry) -> Void
    let onCancel: () -> Void

    @State private var draft: ClaudeProviderEntry
    @State private var tiers: [String: String]   // tier → model
    @State private var tierNames: [String: String]
    @State private var error: String?

    private static let tierKeys = ["sonnet", "opus", "haiku"]

    init(
        draft: ClaudeProviderEntry,
        onSave: @escaping (ClaudeProviderEntry) -> Void, onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: draft)
        var models: [String: String] = [:]
        var names: [String: String] = [:]
        for key in Self.tierKeys { models[key] = ""; names[key] = "" }
        for tier in draft.tiers {
            models[tier.tier] = tier.model
            names[tier.tier] = tier.name
        }
        _tiers = State(initialValue: models)
        _tierNames = State(initialValue: names)
    }

    var body: some View {
        formScaffold(
            title: i18n.t(.clEditTitle),
            cancelTitle: i18n.t(.mpCancel), saveTitle: i18n.t(.mpSave),
            error: error, busy: false, onCancel: onCancel, onSave: submit
        ) {
            formField(i18n.t(.clProviderName)) {
                TextField("", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .font(LatteFont.xs)
            }
            formField(i18n.t(.mpBaseUrl)) {
                TextField(i18n.t(.clBaseUrlPlaceholder), text: $draft.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(LatteFont.xs)
            }
            formField(i18n.t(.mpApiKey)) {
                SecureField("sk-…", text: $draft.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(LatteFont.xs)
            }
            formField(i18n.t(.clTiers)) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Self.tierKeys, id: \.self) { key in
                        HStack(spacing: 4) {
                            LatteBadge(variant: .muted, text: label(for: key))
                                .frame(width: 64, alignment: .leading)
                            TextField(i18n.t(.ocModelIdPlaceholder), text: tierBinding(key, namePart: false))
                                .textFieldStyle(.roundedBorder)
                                .font(LatteFont.xs)
                            TextField(i18n.t(.ocModelNamePlaceholder), text: tierBinding(key, namePart: true))
                                .textFieldStyle(.roundedBorder)
                                .font(LatteFont.xs)
                        }
                    }
                }
            }
            formHint(i18n.t(.clTiersHint))
            formHint(i18n.t(.clFormHint))
        }
    }

    private func label(for key: String) -> String {
        switch key {
        case "sonnet": return i18n.t(.clSonnet)
        case "opus":   return i18n.t(.clOpus)
        default:       return i18n.t(.clHaiku)
        }
    }

    /// `@State` 字典不能用 `inout` 逃逸进闭包 —— 返回按 key 读写的 Binding。
    private func tierBinding(_ key: String, namePart: Bool) -> Binding<String> {
        Binding(
            get: { namePart ? (tierNames[key] ?? "") : (tiers[key] ?? "") },
            set: { newValue in
                if namePart { tierNames[key] = newValue } else { tiers[key] = newValue }
            }
        )
    }

    private func submit() {
        var entry = draft
        entry.baseURL = draft.baseURL.trimmingCharacters(in: .whitespaces)
        entry.apiKey = draft.apiKey.trimmingCharacters(in: .whitespaces)
        if entry.baseURL.isEmpty { error = i18n.t(.ocErrBaseRequired); return }
        if !(entry.baseURL.hasPrefix("http://") || entry.baseURL.hasPrefix("https://")) {
            error = i18n.t(.ocErrBaseScheme); return
        }
        // 🚨 三档全部提交（未填的传空串）—— 契约是"空串 = 删除该档的键"。
        entry.tiers = Self.tierKeys.map {
            ClaudeTierEntry(
                tier: $0,
                model: (tiers[$0] ?? "").trimmingCharacters(in: .whitespaces),
                name: (tierNames[$0] ?? "").trimmingCharacters(in: .whitespaces)
            )
        }
        error = nil
        onSave(entry)
    }
}

// MARK: - Codex 表单

struct CodexProviderForm: View {
    @ObservedObject private var i18n = I18n()
    let wireApis: [WireApiOption]
    let isNew: Bool
    let onSave: (CodexProviderEntry) -> Void
    let onCancel: () -> Void

    @State private var draft: CodexProviderEntry
    @State private var error: String?

    init(
        draft: CodexProviderEntry, wireApis: [WireApiOption], isNew: Bool,
        onSave: @escaping (CodexProviderEntry) -> Void, onCancel: @escaping () -> Void
    ) {
        self.wireApis = wireApis
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        var initial = draft
        if initial.wireApi.isEmpty { initial.wireApi = "chat" }
        _draft = State(initialValue: initial)
    }

    var body: some View {
        formScaffold(
            title: isNew ? i18n.t(.cxAddTitle) : i18n.t(.cxEditTitle),
            cancelTitle: i18n.t(.mpCancel), saveTitle: i18n.t(.mpSave),
            error: error, busy: false, onCancel: onCancel, onSave: submit
        ) {
            formField(i18n.t(.ocKey)) {
                TextField(i18n.t(.cxKeyPlaceholder), text: $draft.id)
                    .textFieldStyle(.roundedBorder)
                    .font(LatteFont.xs)
                    .disabled(!isNew)
            }
            formHint(i18n.t(.ocKeyHint))
            formField(i18n.t(.mpName)) {
                TextField("", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .font(LatteFont.xs)
            }
            formField(i18n.t(.cxWireApi)) {
                Picker("", selection: $draft.wireApi) {
                    ForEach(wireApis, id: \.value) { option in
                        Text(verbatim: option.label).tag(option.value)
                    }
                }
                .labelsHidden()
            }
            formHint(i18n.t(.cxWireApiHint))
            formField(i18n.t(.mpBaseUrl)) {
                TextField(i18n.t(.cxBaseUrlPlaceholder), text: $draft.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(LatteFont.xs)
            }
            formField(i18n.t(.mpApiKey)) {
                SecureField("sk-…", text: $draft.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(LatteFont.xs)
            }
            formHint(i18n.t(.cxApiKeyHint))
            formField(i18n.t(.cxModel)) {
                TextField(i18n.t(.cxModelPlaceholder), text: $draft.model)
                    .textFieldStyle(.roundedBorder)
                    .font(LatteFont.xs)
            }
            formHint(i18n.t(.cxModelHint))
            formHint(i18n.t(.cxFormHint))
            formHint(i18n.t(.cxAdvancedHint))
        }
    }

    private func submit() {
        var entry = draft
        entry.id = draft.id.trimmingCharacters(in: .whitespaces).lowercased()
        entry.name = draft.name.trimmingCharacters(in: .whitespaces)
        entry.baseURL = draft.baseURL.trimmingCharacters(in: .whitespaces)
        entry.apiKey = draft.apiKey.trimmingCharacters(in: .whitespaces)
        entry.model = draft.model.trimmingCharacters(in: .whitespaces)

        if entry.id.isEmpty { error = i18n.t(.ocErrKeyRequired); return }
        if CodexProviderConfigStore.isReservedProviderKey(entry.id) {
            error = i18n.t(.cxErrKeyReserved); return
        }
        if !CodexProviderConfigStore.isValidProviderKey(entry.id) {
            error = i18n.t(.ocErrKeyFormat); return
        }
        if entry.baseURL.isEmpty { error = i18n.t(.ocErrBaseRequired); return }
        if !(entry.baseURL.hasPrefix("http://") || entry.baseURL.hasPrefix("https://")) {
            error = i18n.t(.ocErrBaseScheme); return
        }
        error = nil
        onSave(entry)
    }
}

// MARK: - pi 表单

struct PiProviderForm: View {
    @ObservedObject private var i18n = I18n()
    let apis: [PiApiOption]
    let isNew: Bool
    let onSave: (PiProviderEntry) -> Void
    let onCancel: () -> Void

    @State private var draft: PiProviderEntry
    @State private var rows: [String]
    @State private var error: String?

    init(
        draft: PiProviderEntry, apis: [PiApiOption], isNew: Bool,
        onSave: @escaping (PiProviderEntry) -> Void, onCancel: @escaping () -> Void
    ) {
        self.apis = apis
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        var initial = draft
        if initial.api.isEmpty { initial.api = "anthropic-messages" }
        _draft = State(initialValue: initial)
        _rows = State(initialValue: ModelRowsEditor.encodePi(draft.models))
    }

    var body: some View {
        formScaffold(
            title: isNew ? i18n.t(.piAddTitle) : i18n.t(.piEditTitle),
            cancelTitle: i18n.t(.mpCancel), saveTitle: i18n.t(.mpSave),
            error: error, busy: false, onCancel: onCancel, onSave: submit
        ) {
            formField(i18n.t(.ocKey)) {
                TextField(i18n.t(.piKeyPlaceholder), text: $draft.id)
                    .textFieldStyle(.roundedBorder)
                    .font(LatteFont.xs)
                    .disabled(!isNew)
            }
            if isNew {
                formHint(i18n.t(.ocKeyHint))
            } else {
                formHint(i18n.t(.piKeyLockedHint))
            }
            formField(i18n.t(.mpName)) {
                TextField("", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .font(LatteFont.xs)
            }
            formField(i18n.t(.piApi)) {
                Picker("", selection: $draft.api) {
                    ForEach(apis, id: \.value) { option in
                        Text(verbatim: option.label).tag(option.value)
                    }
                }
                .labelsHidden()
            }
            formHint(i18n.t(.piApiHint))
            formField(i18n.t(.mpBaseUrl)) {
                TextField(i18n.t(.piBaseUrlPlaceholder), text: $draft.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(LatteFont.xs)
            }
            formField(i18n.t(.mpApiKey)) {
                SecureField("sk-…", text: $draft.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(LatteFont.xs)
            }
            formHint(i18n.t(.piApiKeyHint))
            formField(i18n.t(.piModels)) {
                ModelRowsEditor(
                    models: $rows, idPlaceholder: i18n.t(.piModelIdPlaceholder),
                    namePlaceholder: i18n.t(.ocModelNamePlaceholder),
                    addTitle: i18n.t(.ocAddModel)
                )
            }
            formHint(i18n.t(.piModelsHint))
            formHint(i18n.t(.piFormHint))
            formHint(i18n.t(.piAdvancedHint))
        }
    }

    private func submit() {
        var entry = draft
        entry.id = draft.id.trimmingCharacters(in: .whitespaces).lowercased()
        entry.name = draft.name.trimmingCharacters(in: .whitespaces)
        entry.baseURL = draft.baseURL.trimmingCharacters(in: .whitespaces)
        entry.apiKey = draft.apiKey.trimmingCharacters(in: .whitespaces)
        entry.models = ModelRowsEditor.decodePi(rows)

        if entry.id.isEmpty { error = i18n.t(.ocErrKeyRequired); return }
        if !PiProviderConfigStore.isValidProviderKey(entry.id) {
            error = i18n.t(.ocErrKeyFormat); return
        }
        if entry.baseURL.isEmpty { error = i18n.t(.ocErrBaseRequired); return }
        if !(entry.baseURL.hasPrefix("http://") || entry.baseURL.hasPrefix("https://")) {
            error = i18n.t(.ocErrBaseScheme); return
        }
        if entry.models.isEmpty { error = i18n.t(.piErrModelsRequired); return }
        error = nil
        onSave(entry)
    }
}
