import BrewPingCore
import SwiftUI

// ─── 设置页「xxx 厂商 · <文件名>」面板（对齐 Windows 各 `*-provider-panel.tsx`）──
//
// 与 Windows 的分工一致：**只在对应 Agent tab 下渲染**（Codex tab → Codex 面板，
// 以此类推）。这些面板直接读写用户真实的 CLI 配置文件，与上方「BrewPing 自有
// 供应商库」是两套东西 —— 后者服务转发链路，这里服务"让 CLI 自己用上你的中转站"。
//
// ── 视觉层级 ─────────────────────────────────────────────────────────────────
// 旧版把所有元素都用同一个 6pt 间距平铺，标题/副标题/路径/正文/hint 全挤成一片，
// 看不出分组。现在明确分三层，并靠"块间 > 块内"的间距差制造层次：
//
//   L1 面板     `cliCard`      淡主色底 + 主色描边（与"自有库"的中性卡片区分）
//   L2 内容块   `cliRowCard`   一条厂商一个描边块（当前项高亮）
//               `cliInset`     一段只读清单（三档模型映射这类）
//   L3 行内元素 `cliLabelValue` / 徽章 / 图标按钮
//
// 间距节奏：块内 4–6pt，块间 8pt，组间 12pt。

// MARK: - L1 面板外框

/// 淡主色底 + 主色描边（对齐 Windows `border-primary/25 bg-primary/[0.03]`）。
/// 刻意与「BrewPing 自有供应商库」卡片（`Latte.card` + `Latte.border`）不同 ——
/// 两者读写的是完全不同的东西，长得一样会让人误以为在编辑同一个列表。
private func cliCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12, content: content)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Latte.primary.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Latte.primary.opacity(0.22), lineWidth: 1)
        }
}

/// 标题区：标题行（标题 + 文件名徽章 + 右侧操作）→ 副标题 → 文件路径。
/// 内部 8pt / 4pt 递进，与下方内容的 12pt 拉开：先读到"这是什么"，再读到内容。
private func cliPanelHeader(
    title: String,
    fileBadge: String,
    subtitle: String,
    path: String,
    pathExists: Bool,
    missingLabel: String,
    addTitle: String,
    disabled: Bool,
    onAdd: @escaping () -> Void
) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
            Text(verbatim: title)
                .font(LatteFont.sm.weight(.semibold))
                .foregroundStyle(Latte.foreground)
            LatteBadge(variant: .muted, text: fileBadge)
            Spacer(minLength: 8)
            Button {
                onAdd()
            } label: {
                Label(addTitle, systemImage: "plus").font(LatteFont.xs)
            }
            .buttonStyle(LatteButtonStyle(variant: .outline))
            .disabled(disabled)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: subtitle)
                .font(LatteFont.xs)
                .foregroundStyle(Latte.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            if !path.isEmpty {
                cliFilePath(path, exists: pathExists, missingLabel: missingLabel)
            }
        }
    }
}

// MARK: - L2 内容块

/// 一条厂商 = 一个描边块（对齐 Windows `rounded-md border px-2.5 py-1.5`）。
/// `active` = 当前生效项：主色描边 + 主色淡底，扫一眼就知道哪条在用。
private func cliRowCard<Content: View>(
    active: Bool = false, @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 6, content: content)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active ? Latte.primary.opacity(0.07) : Latte.card)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(active ? Latte.primary.opacity(0.35) : Latte.border, lineWidth: 1)
        }
}

/// 一段只读清单（三档模型映射这类），用凹陷面与厂商行区分。
private func cliInset<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6, content: content)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Latte.muted.opacity(0.55))
        )
}

/// 空态块：一句标题 + 一句说明，居中。
private func cliEmpty(title: String, hint: String) -> some View {
    cliInset {
        VStack(spacing: 4) {
            Text(verbatim: title)
                .font(LatteFont.xs.weight(.medium))
                .foregroundStyle(Latte.foreground.opacity(0.85))
            Text(verbatim: hint)
                .font(LatteFont.font10)
                .foregroundStyle(Latte.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

/// 页脚：一条分隔线 + 若干行元信息（"哪些东西会被一起保留"这类）。
private func cliFooter<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Rectangle()
            .fill(Latte.border)
            .frame(height: 1)
        content()
    }
}

// MARK: - L3 行内元素

/// 「标签 + 值」行（等宽）：标签定宽，多行时左边界对齐、不随值长短抖动。
private func cliLabelValue(label: String, value: String, placeholder: String = "—") -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(verbatim: label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Latte.mutedForeground)
            .frame(width: 58, alignment: .leading)
        Text(verbatim: value.isEmpty ? placeholder : value)
            .font(LatteFont.mono11)
            .foregroundStyle(value.isEmpty ? Latte.mutedForeground.opacity(0.5) : Latte.foreground)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        Spacer(minLength: 0)
    }
}

/// 文件路径行（等宽 + 可选中，方便复制去终端核对）。
private func cliFilePath(_ path: String, exists: Bool, missingLabel: String) -> some View {
    HStack(spacing: 6) {
        Image(systemName: "doc.text")
            .font(.system(size: 10))
            .foregroundStyle(Latte.mutedForeground.opacity(0.8))
        Text(verbatim: path)
            .font(LatteFont.monoXS)
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

/// 说明性文字。
private func cliInfoLine(_ text: String) -> some View {
    Text(verbatim: text)
        .font(LatteFont.xs)
        .foregroundStyle(Latte.mutedForeground)
        .fixedSize(horizontal: false, vertical: true)
}

/// 错误提示（带底色的一块，不再是一行飘着的红字）。
@ViewBuilder
private func cliError(_ message: String?) -> some View {
    if let message, !message.isEmpty {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Latte.destructive)
            Text(verbatim: message)
                .font(LatteFont.xs)
                .foregroundStyle(Latte.destructive)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Latte.destructive.opacity(0.07))
        )
    }
}

/// 行首「当前项」勾选标记；未选中时留等宽占位，保证多条厂商左边界对齐。
@ViewBuilder
private func rowMark(_ active: Bool) -> some View {
    if active {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Latte.primary)
            .frame(width: 12, alignment: .leading)
    } else {
        Color.clear.frame(width: 12, height: 1)
    }
}

/// 行内图标按钮（ghost，统一 22×22 命中区）。
private func rowIconButton(
    _ systemName: String, help: String, disabled: Bool, action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Image(systemName: systemName).font(.system(size: 11))
    }
    .buttonStyle(LatteButtonStyle(variant: .ghost))
    .help(help)
    .disabled(disabled)
    .frame(width: 22, height: 22)
}

/// 两步删除：未确认 = 垃圾桶图标；已确认 = 实心「确认删除」。
@ViewBuilder
private func rowDeleteButton(
    confirming: Bool, deleteTitle: String, confirmTitle: String, disabled: Bool,
    onAsk: @escaping () -> Void, onConfirm: @escaping () -> Void
) -> some View {
    if confirming {
        Button(confirmTitle) { onConfirm() }
            .buttonStyle(LatteButtonStyle(variant: .primary))
            .font(LatteFont.xs)
            .disabled(disabled)
    } else {
        rowIconButton("trash", help: deleteTitle, disabled: disabled, action: onAsk)
    }
}

/// API Key 状态徽章。`fixedSize`：徽章永不压缩，宁可截断 URL（中部截断会保住 host 与尾段）。
/// 这条策略与 Windows 一致（那边徽章是 `shrink-0`，URL 是 `min-w-0 flex-1 truncate`）。
private func keyBadge(_ hasKey: Bool, set: String, missing: String) -> some View {
    LatteBadge(variant: hasKey ? .success : .muted, text: hasKey ? set : missing)
        .fixedSize()
}

/// 厂商行的第二行：这里放"它在哪 + 长什么样"，与第一行的身份信息分开。
private func rowMeta(_ baseURL: String, hasKey: Bool, keySet: String, keyMissing: String,
                     model: String?) -> some View {
    HStack(spacing: 8) {
        Text(verbatim: baseURL.isEmpty ? "—" : baseURL)
            .font(LatteFont.monoXS)
            .foregroundStyle(Latte.mutedForeground)
            .lineLimit(1)
            .truncationMode(.middle)

        keyBadge(hasKey, set: keySet, missing: keyMissing)
        if let model, !model.isEmpty {
            Text(verbatim: model)
                .font(LatteFont.monoXS)
                .foregroundStyle(Latte.mutedForeground.opacity(0.8))
                .lineLimit(1)
        }
        Spacer(minLength: 0)
    }
}

/// 厂商行标题：有名字用名字，没名字回落 id（避免整行只有一串 key）。
private func rowTitle(_ name: String, _ id: String) -> String {
    name.isEmpty ? id : name
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
                subtitle: i18n.t(.ocSubtitle),
                path: info?.configFile ?? "", pathExists: info?.exists ?? true,
                missingLabel: i18n.t(.ocNotCreated),
                addTitle: i18n.t(.ocAddTitle), disabled: busy
            ) { editing = OpenCodeProviderEntry() }

            cliError(error)

            let providers = info?.providers ?? []
            if providers.isEmpty {
                cliEmpty(title: i18n.t(.ocEmpty), hint: i18n.t(.ocEmptyHint))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(providers) { provider in
                        providerRow(provider)
                    }
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
        cliRowCard {
            HStack(spacing: 8) {
                Text(verbatim: rowTitle(provider.name, provider.id))
                    .font(LatteFont.sm.weight(.medium))
                    .foregroundStyle(Latte.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                LatteBadge(variant: .muted, text: provider.id)
                Spacer(minLength: 8)
                rowIconButton("pencil", help: i18n.t(.mpEdit), disabled: busy) {
                    editing = provider
                }
                rowDeleteButton(
                    confirming: confirmId == provider.id,
                    deleteTitle: i18n.t(.mpDelete), confirmTitle: i18n.t(.mpConfirmDelete),
                    disabled: busy,
                    onAsk: { confirmId = provider.id },
                    onConfirm: { Task { await delete(provider.id) } }
                )
            }
            HStack(spacing: 8) {
                Text(verbatim: provider.baseURL.isEmpty ? "—" : provider.baseURL)
                    .font(LatteFont.monoXS)
                    .foregroundStyle(Latte.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                LatteBadge(variant: .muted, text: provider.npm).fixedSize()
                keyBadge(!provider.apiKey.isEmpty,
                         set: i18n.t(.mpKeySet), missing: i18n.t(.mpKeyMissing))
                Text(verbatim: i18n.t(.ocModelCount, ["n": String(provider.models.count)]))
                    .font(LatteFont.font10)
                    .foregroundStyle(Latte.mutedForeground)
                    .fixedSize()
            }
        }
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
                subtitle: i18n.t(.clSubtitle),
                path: info?.configFile ?? "", pathExists: info?.exists ?? true,
                missingLabel: i18n.t(.ocNotCreated),
                addTitle: i18n.t(.clConfigure), disabled: busy
            ) { confirmDelete = false; editing = true }

            cliError(error)

            let provider = info?.provider ?? ClaudeProviderEntry()
            if !(info?.configured ?? false) {
                cliEmpty(title: i18n.t(.clEmpty), hint: i18n.t(.clEmptyHint))
            } else {
                cliRowCard(active: true) {
                    HStack(spacing: 8) {
                        rowMark(true)
                        Text(verbatim: claudeDisplayName(provider))
                            .font(LatteFont.sm.weight(.medium))
                            .foregroundStyle(Latte.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        Spacer(minLength: 8)
                        rowIconButton("pencil", help: i18n.t(.mpEdit), disabled: busy) {
                            confirmDelete = false; editing = true
                        }
                        rowDeleteButton(
                            confirming: confirmDelete,
                            deleteTitle: i18n.t(.mpDelete), confirmTitle: i18n.t(.mpConfirmDelete),
                            disabled: busy,
                            onAsk: { confirmDelete = true },
                            onConfirm: { Task { await deleteProvider() } }
                        )
                    }
                    rowMeta(
                        provider.baseURL, hasKey: !provider.apiKey.isEmpty,
                        keySet: i18n.t(.mpKeySet), keyMissing: i18n.t(.mpKeyMissing), model: nil
                    )
                }

                // 三档模型映射：**三档恒列出**（空档显示 —），一眼看出哪档没配。
                cliInset {
                    Text(verbatim: i18n.t(.clTiers))
                        .font(LatteFont.font10.weight(.medium))
                        .foregroundStyle(Latte.mutedForeground)
                    ForEach(allTiers(provider), id: \.tier) { tier in
                        cliLabelValue(label: tier.tier.uppercased(), value: tier.model)
                    }
                }

                // 页脚：写入时会"一起带上"的顶层键 —— 让用户放心，不是黑盒覆盖。
                cliFooter {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 10))
                            .foregroundStyle(Latte.mutedForeground)
                        VStack(alignment: .leading, spacing: 4) {
                            cliInfoLine(provider.otherKeys.isEmpty
                                        ? i18n.t(.clOtherKeysNone)
                                        : i18n.t(.clOtherKeysHint))
                            if !provider.otherKeys.isEmpty {
                                Text(verbatim: provider.otherKeys.joined(separator: "  ·  "))
                                    .font(LatteFont.monoXS)
                                    .foregroundStyle(Latte.mutedForeground.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
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

    /// Claude Code 的 settings.json **没有厂商名字段**（读回来 name 恒为空），
    /// 所以标题回落到 baseURL 的 host —— 比复读面板标题有用。
    private func claudeDisplayName(_ provider: ClaudeProviderEntry) -> String {
        if !provider.name.isEmpty { return provider.name }
        let host = provider.baseURL
            .replacingOccurrences(of: "^https?://", with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: "/").first ?? ""
        return host.isEmpty ? i18n.t(.clTitle) : host
    }

    /// 三档恒返回（缺的补空 entry），保证 UI 顺序稳定。
    private func allTiers(_ provider: ClaudeProviderEntry) -> [ClaudeTierEntry] {
        ClaudeConfigStore.tierEnvKeys.map { key in
            provider.tiers.first { $0.tier == key.tier }
                ?? ClaudeTierEntry(tier: key.tier, model: "", name: "")
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
                subtitle: i18n.t(.cxSubtitle),
                path: info?.configFile ?? "", pathExists: info?.exists ?? true,
                missingLabel: i18n.t(.ocNotCreated),
                addTitle: i18n.t(.cxAddTitle), disabled: busy
            ) { editing = CodexProviderEntry() }

            cliError(error)

            let providers = info?.providers ?? []
            if providers.isEmpty {
                cliEmpty(title: i18n.t(.ocEmpty), hint: i18n.t(.cxEmptyHint))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(providers) { provider in
                        providerRow(provider)
                    }
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
        cliRowCard(active: provider.active) {
            HStack(spacing: 8) {
                rowMark(provider.active)
                Text(verbatim: rowTitle(provider.name, provider.id))
                    .font(LatteFont.sm.weight(.medium))
                    .foregroundStyle(Latte.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                LatteBadge(variant: .muted, text: provider.id)
                if provider.active {
                    LatteBadge(variant: .success, text: i18n.t(.cxActive))
                }
                Spacer(minLength: 8)
                if !provider.active {
                    Button(i18n.t(.cxActivate)) {
                        Task { await activate(provider.id) }
                    }
                    .buttonStyle(LatteButtonStyle(variant: .ghost))
                    .font(LatteFont.xs)
                    .disabled(busy)
                }
                rowIconButton("pencil", help: i18n.t(.mpEdit), disabled: busy) {
                    editing = provider
                }
                rowDeleteButton(
                    confirming: confirmId == provider.id,
                    deleteTitle: i18n.t(.mpDelete), confirmTitle: i18n.t(.mpConfirmDelete),
                    disabled: busy,
                    onAsk: { confirmId = provider.id },
                    onConfirm: { Task { await delete(provider.id) } }
                )
            }
            HStack(spacing: 8) {
                Text(verbatim: provider.baseURL.isEmpty ? "—" : provider.baseURL)
                    .font(LatteFont.monoXS)
                    .foregroundStyle(Latte.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                LatteBadge(variant: .muted, text: provider.wireApi).fixedSize()
                keyBadge(!provider.apiKey.isEmpty,
                         set: i18n.t(.mpKeySet), missing: i18n.t(.mpKeyMissing))
                if !provider.model.isEmpty {
                    Text(verbatim: provider.model)
                        .font(LatteFont.monoXS)
                        .foregroundStyle(Latte.mutedForeground.opacity(0.8))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
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
                subtitle: i18n.t(.piSubtitle),
                path: info?.configFile ?? "", pathExists: info?.exists ?? true,
                missingLabel: i18n.t(.ocNotCreated),
                addTitle: i18n.t(.piAddTitle), disabled: busy
            ) { editing = PiProviderEntry() }

            cliError(error)

            let providers = info?.providers ?? []
            if providers.isEmpty {
                cliEmpty(title: i18n.t(.ocEmpty), hint: i18n.t(.piEmptyHint))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(providers) { provider in
                        providerRow(provider)
                    }
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
        cliRowCard(active: provider.isDefault) {
            HStack(spacing: 8) {
                rowMark(provider.isDefault)
                Text(verbatim: rowTitle(provider.name, provider.id))
                    .font(LatteFont.sm.weight(.medium))
                    .foregroundStyle(Latte.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                LatteBadge(variant: .muted, text: provider.id)
                if provider.isDefault {
                    LatteBadge(variant: .success, text: i18n.t(.piDefault))
                }
                Spacer(minLength: 8)
                if !provider.isDefault {
                    Button(i18n.t(.piSetDefault)) {
                        Task { await activate(provider.id) }
                    }
                    .buttonStyle(LatteButtonStyle(variant: .ghost))
                    .font(LatteFont.xs)
                    .disabled(busy)
                }
                rowIconButton("pencil", help: i18n.t(.mpEdit), disabled: busy) {
                    editing = provider
                }
                rowDeleteButton(
                    confirming: confirmId == provider.id,
                    deleteTitle: i18n.t(.mpDelete), confirmTitle: i18n.t(.mpConfirmDelete),
                    disabled: busy,
                    onAsk: { confirmId = provider.id },
                    onConfirm: { Task { await delete(provider.id) } }
                )
            }
            HStack(spacing: 8) {
                Text(verbatim: provider.baseURL.isEmpty ? "—" : provider.baseURL)
                    .font(LatteFont.monoXS)
                    .foregroundStyle(Latte.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                LatteBadge(variant: .muted, text: provider.api).fixedSize()
                Text(verbatim: i18n.t(.piModelCount, ["n": String(provider.models.count)]))
                    .font(LatteFont.font10)
                    .foregroundStyle(Latte.mutedForeground)
                    .fixedSize()
            }
        }
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

/// 一个字段 = 标签 + 控件 +（可选）说明，**作为一个整体**。
/// 旧版把 hint 当成独立元素排，导致"上一字段的说明"和"下一字段"等距 —— 分不清归属。
private func formField<Content: View>(
    _ label: String, hint: String? = nil, @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(verbatim: label)
            .font(LatteFont.xs.weight(.medium))
            .foregroundStyle(Latte.foreground.opacity(0.75))
        content()
        if let hint { formHint(hint) }
    }
}

private func formHint(_ text: String) -> some View {
    Text(verbatim: text)
        .font(LatteFont.font10)
        .foregroundStyle(Latte.mutedForeground)
        .fixedSize(horizontal: false, vertical: true)
}

/// 表单顶部的说明块（对齐 Windows 的 `bg-muted/60` 提示条）。
private func formNote(_ text: String) -> some View {
    Text(verbatim: text)
        .font(LatteFont.font10)
        .foregroundStyle(Latte.mutedForeground)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Latte.muted.opacity(0.5))
        )
}

/// 输入框统一样式（与 Windows `h-7 text-xs` 对齐高度，避免一行里高矮不齐）。
private extension View {
    func cliInput() -> some View {
        self.textFieldStyle(.roundedBorder)
            .font(LatteFont.xs)
            .controlSize(.large)
    }
}

/// 模型行编辑器（opencode / pi 共用）。
private struct ModelRowsEditor: View {
    @Binding var models: [String]      // "id\u{1}name"
    var idPlaceholder: String
    var namePlaceholder: String
    var addTitle: String
    var removeHelp: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(models.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField(idPlaceholder, text: binding(index: index, namePart: false))
                        .cliInput()
                    TextField(namePlaceholder, text: binding(index: index, namePart: true))
                        .cliInput()
                    Button {
                        if models.indices.contains(index) { models.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Latte.mutedForeground)
                    .help(removeHelp)
                }
            }
            Button {
                models.append("\u{1}")
            } label: {
                Label(addTitle, systemImage: "plus").font(LatteFont.xs)
            }
            .buttonStyle(LatteButtonStyle(variant: .outline))
            .padding(.top, 2)
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
            .font(LatteFont.sm.weight(.semibold))
            .foregroundStyle(Latte.foreground)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        Divider()
        ScrollView {
            VStack(alignment: .leading, spacing: 16, content: content)
                .padding(16)
        }
        Divider()
        HStack(alignment: .center, spacing: 10) {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    .frame(width: 560, height: 620)
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
            formNote(i18n.t(.ocFormHint))
            formField(i18n.t(.ocKey), hint: i18n.t(.ocKeyHint)) {
                TextField(i18n.t(.ocKeyPlaceholder), text: $draft.id)
                    .cliInput()
                    .disabled(!isNew)      // 改 key = 新建，编辑时锁定
            }
            formField(i18n.t(.mpName)) {
                TextField(i18n.t(.ocNamePlaceholder), text: $draft.name)
                    .cliInput()
            }
            formField(i18n.t(.mpBaseUrl)) {
                TextField(i18n.t(.mpBaseUrlPlaceholder), text: $draft.baseURL)
                    .cliInput()
            }
            formField(i18n.t(.ocNpm)) {
                Picker("", selection: $draft.npm) {
                    ForEach(packages, id: \.value) { option in
                        Text(verbatim: option.label).tag(option.value)
                    }
                }
                .labelsHidden()
                .controlSize(.large)
            }
            formField(i18n.t(.mpApiKey)) {
                SecureField("sk-…", text: $draft.apiKey)
                    .cliInput()
            }
            formField(i18n.t(.ocModels)) {
                ModelRowsEditor(
                    models: $rows, idPlaceholder: i18n.t(.ocModelIdPlaceholder),
                    namePlaceholder: i18n.t(.ocModelNamePlaceholder),
                    addTitle: i18n.t(.ocAddModel), removeHelp: i18n.t(.mpDelete)
                )
            }
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

/// 三档固定顺序 + 各档占位示例（与 Windows `TIERS` 逐条对齐）。
private struct ClaudeTierSpec: Identifiable {
    let key: String
    let label: LKey
    let placeholder: String
    var id: String { key }
}

struct ClaudeProviderForm: View {
    @ObservedObject private var i18n = I18n()
    let onSave: (ClaudeProviderEntry) -> Void
    let onCancel: () -> Void

    @State private var draft: ClaudeProviderEntry
    @State private var tiers: [String: String]   // tier → model
    @State private var tierNames: [String: String]
    @State private var advancedOpen = false
    @State private var error: String?

    private static let tierSpecs: [ClaudeTierSpec] = [
        ClaudeTierSpec(key: "sonnet", label: .clSonnet, placeholder: "claude-sonnet-4-6"),
        ClaudeTierSpec(key: "opus",   label: .clOpus,   placeholder: "claude-opus-4-6"),
        ClaudeTierSpec(key: "haiku",  label: .clHaiku,  placeholder: "claude-haiku-4-5"),
    ]

    init(
        draft: ClaudeProviderEntry,
        onSave: @escaping (ClaudeProviderEntry) -> Void, onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: draft)
        var models: [String: String] = [:]
        var names: [String: String] = [:]
        for spec in Self.tierSpecs { models[spec.key] = ""; names[spec.key] = "" }
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
            formNote(i18n.t(.clFormHint))
            formField(i18n.t(.clProviderName)) {
                TextField(i18n.t(.ocNamePlaceholder), text: $draft.name)
                    .cliInput()
            }
            formField(i18n.t(.mpBaseUrl)) {
                TextField(i18n.t(.clBaseUrlPlaceholder), text: $draft.baseURL)
                    .cliInput()
            }
            formField(i18n.t(.mpApiKey)) {
                SecureField("sk-…", text: $draft.apiKey)
                    .cliInput()
            }
            formField(i18n.t(.clTiers), hint: i18n.t(.clTiersHint)) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.tierSpecs) { spec in
                        HStack(spacing: 6) {
                            Text(verbatim: i18n.t(spec.label))
                                .font(LatteFont.font10.weight(.medium))
                                .foregroundStyle(Latte.mutedForeground)
                                .frame(width: 54, alignment: .leading)
                            TextField(spec.placeholder, text: tierBinding(spec.key, namePart: false))
                                .cliInput()
                            TextField(i18n.t(.ocModelNamePlaceholder),
                                      text: tierBinding(spec.key, namePart: true))
                                .cliInput()
                        }
                    }
                }
            }
            advancedSection
        }
    }

    /// 「高级选项」：与 Windows 一致地把 otherKeys 收在这里，不再占面板篇幅。
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(Latte.border)
                .frame(height: 1)
            Button {
                advancedOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: advancedOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Latte.mutedForeground)
                    Text(i18n.t(.mpAdvanced))
                        .font(LatteFont.xs)
                        .foregroundStyle(Latte.mutedForeground)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if advancedOpen {
                if draft.otherKeys.isEmpty {
                    formHint(i18n.t(.clOtherKeysNone))
                } else {
                    formHint(i18n.t(.clOtherKeysHint))
                    Text(verbatim: draft.otherKeys.joined(separator: "  ·  "))
                        .font(LatteFont.monoXS)
                        .foregroundStyle(Latte.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
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
        entry.tiers = Self.tierSpecs.map { spec in
            ClaudeTierEntry(
                tier: spec.key,
                model: (tiers[spec.key] ?? "").trimmingCharacters(in: .whitespaces),
                name: (tierNames[spec.key] ?? "").trimmingCharacters(in: .whitespaces)
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
            formNote(i18n.t(.cxFormHint))
            formField(i18n.t(.ocKey), hint: i18n.t(.ocKeyHint)) {
                TextField(i18n.t(.cxKeyPlaceholder), text: $draft.id)
                    .cliInput()
                    .disabled(!isNew)
            }
            formField(i18n.t(.mpName)) {
                TextField(i18n.t(.ocNamePlaceholder), text: $draft.name)
                    .cliInput()
            }
            formField(i18n.t(.cxWireApi), hint: i18n.t(.cxWireApiHint)) {
                Picker("", selection: $draft.wireApi) {
                    ForEach(wireApis, id: \.value) { option in
                        Text(verbatim: option.label).tag(option.value)
                    }
                }
                .labelsHidden()
                .controlSize(.large)
            }
            formField(i18n.t(.mpBaseUrl)) {
                TextField(i18n.t(.cxBaseUrlPlaceholder), text: $draft.baseURL)
                    .cliInput()
            }
            formField(i18n.t(.mpApiKey), hint: i18n.t(.cxApiKeyHint)) {
                SecureField("sk-…", text: $draft.apiKey)
                    .cliInput()
            }
            formField(i18n.t(.cxModel), hint: i18n.t(.cxModelHint)) {
                TextField(i18n.t(.cxModelPlaceholder), text: $draft.model)
                    .cliInput()
            }
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
            formNote(i18n.t(.piFormHint))
            formField(i18n.t(.ocKey),
                      hint: isNew ? i18n.t(.ocKeyHint) : i18n.t(.piKeyLockedHint)) {
                TextField(i18n.t(.piKeyPlaceholder), text: $draft.id)
                    .cliInput()
                    .disabled(!isNew)
            }
            formField(i18n.t(.mpName)) {
                TextField(i18n.t(.ocNamePlaceholder), text: $draft.name)
                    .cliInput()
            }
            formField(i18n.t(.piApi), hint: i18n.t(.piApiHint)) {
                Picker("", selection: $draft.api) {
                    ForEach(apis, id: \.value) { option in
                        Text(verbatim: option.label).tag(option.value)
                    }
                }
                .labelsHidden()
                .controlSize(.large)
            }
            formField(i18n.t(.mpBaseUrl)) {
                TextField(i18n.t(.piBaseUrlPlaceholder), text: $draft.baseURL)
                    .cliInput()
            }
            formField(i18n.t(.mpApiKey), hint: i18n.t(.piApiKeyHint)) {
                SecureField("sk-…", text: $draft.apiKey)
                    .cliInput()
            }
            formField(i18n.t(.piModels), hint: i18n.t(.piModelsHint)) {
                ModelRowsEditor(
                    models: $rows, idPlaceholder: i18n.t(.piModelIdPlaceholder),
                    namePlaceholder: i18n.t(.ocModelNamePlaceholder),
                    addTitle: i18n.t(.ocAddModel), removeHelp: i18n.t(.mpDelete)
                )
            }
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
