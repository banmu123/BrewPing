import BrewPingCore
import SwiftUI

// ─── 设置页「模型供应商」──────────────────────────────────────────────────────
//
// 对齐 Windows 端 `components/settings/model-config-card.tsx`（P2 骨架）：
//   ① 状态摘要行（转发代理状态 + 端点）→ 展开「代理设置」（端口 / 故障转移）
//   ② Agent 归属 Tab 栏（通用 + 各 Agent；记忆上次 tab）
//   ③ 厂商面板（当前/通用徽章、设为当前、编辑、两步删除）
//   ④ 折叠收纳：CLI 接入 / Agent 模型偏好
//
// ⚠️ Phase 1 范围：供应商数据 + UI 已落地；**本地转发代理与 CLI 接管**属 Phase 2
//    （需要流式转发与协议转换），因此「代理状态」恒显示未运行、CLI 接入区标注
//    暂不支持 —— 不假装可用。配置项与交互顺序与 Windows 完全一致。

struct ModelProvidersView: View {
    @ObservedObject private var i18n = I18n()
    @State private var info: ModelProvidersInfo?
    @State private var catalog: [ProviderCatalogEntry] = []
    @State private var agents: [DesktopStatusAgent] = []
    @State private var busy = false
    @State private var error: String?

    // 表单 / 删除确认 / 端口草稿 / tab
    @State private var editing: ModelProviderConfig?
    @State private var confirmId: String?
    @State private var portDraft = ""
    @State private var activeTab: String = UserDefaults.standard.string(forKey: Self.tabKey) ?? ""
    @State private var proxyOpen = false
    @State private var cliOpen = false
    @State private var prefsOpen = false

    private static let tabKey = "brewping.modelTab"

    // 与 Windows `model-config-card.tsx` 同名同值的两个特性开关（2026-09-14 起 Windows 均为 false）：
    // ① 自有库厂商面板 —— 转发代理语义；macOS 转发代理未实现（Phase 2），同步隐藏保持两端一致。
    // ② CLI 接管 UI —— 依赖转发代理，Windows 已整体隐藏，macOS 同步隐藏。
    // 代码全部保留，置 true 即恢复。
    private static let showForwardProxySection = false
    private static let showTakeoverUI = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            summaryRow
            if proxyOpen { proxySettings }
            tabBar
            if Self.showForwardProxySection { providerPanel }
            cliProviderSection
            if Self.showTakeoverUI { cliSection }
            agentPrefsSection

            if let error {
                Text(verbatim: error)
                    .font(LatteFont.xs)
                    .foregroundStyle(Latte.destructive)
            }
        }
        .task { await reload() }
        .sheet(item: $editing) { draft in
            ModelProviderFormView(
                draft: draft,
                catalog: catalog,
                isNew: draft.id.isEmpty,
                onSave: { saved in Task { await save(saved) } },
                onCancel: { editing = nil }
            )
        }
    }

    // MARK: - 头部 / 摘要行

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(i18n.t(.mpTitle))
                    .font(LatteFont.sm.weight(.medium))
                    .foregroundStyle(Latte.foreground)
                Text(i18n.t(.mpHint))
                    .font(LatteFont.xs)
                    .foregroundStyle(Latte.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // Windows：面板被开关隐藏后仍保留「添加」入口（表单不受开关限制）
            Button {
                startAdd()
            } label: {
                Label(i18n.t(.mpAdd), systemImage: "plus").font(LatteFont.xs)
            }
            .buttonStyle(LatteButtonStyle(variant: .outline))
            .disabled(busy)
        }
    }

    private var summaryRow: some View {
        card {
            HStack(spacing: 8) {
                RuntimeDot(state: (info?.proxyRunning ?? false) ? "online" : "offline", size: 7)
                Text(i18n.t(.mpProxy))
                    .font(LatteFont.xs.weight(.medium))
                    .foregroundStyle(Latte.foreground)
                LatteBadge(
                    variant: (info?.proxyRunning ?? false) ? .success : .muted,
                    text: (info?.proxyRunning ?? false) ? i18n.t(.mpStateRunning) : i18n.t(.mpStateStopped)
                )
                Spacer(minLength: 0)
                Button(proxyOpen ? i18n.t(.mpProxyDetails) : i18n.t(.mpProxy)) {
                    proxyOpen.toggle()
                }
                .buttonStyle(LatteButtonStyle(variant: .ghost))
                .font(LatteFont.xs)
            }
            HStack(spacing: 6) {
                Text(verbatim: endpointText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Latte.mutedForeground)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button((info?.proxyEnabled ?? false) ? i18n.t(.mpDisable) : i18n.t(.mpEnable)) {
                    Task { await toggleProxy() }
                }
                .buttonStyle(LatteButtonStyle(variant: .outline))
                .font(LatteFont.xs)
                .disabled(busy)
            }
            Text(i18n.t(.mpEndpointHint, ["port": String(info?.proxyPort ?? 15721)]))
                .font(LatteFont.xs)
                .foregroundStyle(Latte.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var endpointText: String {
        "http://127.0.0.1:\(info?.proxyPort ?? 15721)"
    }

    private var proxySettings: some View {
        card {
            HStack(spacing: 8) {
                Text(i18n.t(.mpPort))
                    .font(LatteFont.xs)
                    .foregroundStyle(Latte.mutedForeground)
                TextField("15721", text: $portDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(LatteFont.xs)
                    .frame(width: 72)
                    .onSubmit { Task { await applyPort() } }
                Spacer(minLength: 0)
            }
            Toggle(isOn: Binding(
                get: { info?.failoverEnabled ?? false },
                set: { value in Task { await setFailover(value) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(i18n.t(.mpFailover))
                        .font(LatteFont.xs)
                    Text(i18n.t(.mpFailoverHint))
                        .font(LatteFont.xs)
                        .foregroundStyle(Latte.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(busy)
        }
    }

    // MARK: - Agent tab 栏

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tabButton(id: "", label: i18n.t(.mpTabGeneral))
                ForEach(agents, id: \.id) { agent in
                    tabButton(id: agent.id, label: agent.name)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func tabButton(id: String, label: String) -> some View {
        Button {
            activeTab = id
            confirmId = nil
            UserDefaults.standard.set(id, forKey: Self.tabKey)
        } label: {
            Text(verbatim: label)
                .font(LatteFont.xs.weight(activeTab == id ? .semibold : .regular))
                .foregroundStyle(activeTab == id ? Latte.primaryForeground : Latte.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(activeTab == id ? Latte.primary : Latte.muted)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 厂商面板

    /// 该 tab 下可见的厂商：专属（agentId == tab） + 通用（agentId == ""）。
    private var visibleProviders: [ModelProviderView] {
        (info?.providers ?? []).filter { activeTab.isEmpty ? $0.agentId.isEmpty : ($0.agentId == activeTab || $0.agentId.isEmpty) }
    }

    private var currentIdForTab: String? {
        guard let info else { return nil }
        if !activeTab.isEmpty, let slot = info.currentByAgent[activeTab] { return slot }
        return info.currentId
    }

    private var providerPanel: some View {
        let providers = visibleProviders
        return VStack(alignment: .leading, spacing: 6) {
            if providers.isEmpty {
                card {
                    VStack(spacing: 4) {
                        Text(i18n.t(.mpTabEmpty))
                            .font(LatteFont.xs)
                            .foregroundStyle(Latte.mutedForeground)
                        Text(i18n.t(.mpTabEmptyHint))
                            .font(LatteFont.xs)
                            .foregroundStyle(Latte.mutedForeground.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            startAdd()
                        } label: {
                            Label(i18n.t(.mpAdd), systemImage: "plus")
                                .font(LatteFont.xs)
                        }
                        .buttonStyle(LatteButtonStyle(variant: .outline))
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(providers) { provider in
                    providerCard(provider)
                }
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        startAdd()
                    } label: {
                        Label(i18n.t(.mpAdd), systemImage: "plus")
                            .font(LatteFont.xs)
                    }
                    .buttonStyle(LatteButtonStyle(variant: .outline))
                    .disabled(busy)
                }
            }
        }
    }

    private func providerCard(_ provider: ModelProviderView) -> some View {
        let isCurrent = currentIdForTab == provider.id
        // 通用厂商在专属 tab 下仅可「设为当前」；编辑/删除回通用 tab 操作
        let isSharedHere = !activeTab.isEmpty && provider.agentId.isEmpty
        let canManage = !isSharedHere
        return card {
            HStack(spacing: 6) {
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Latte.primary)
                }
                Text(verbatim: provider.name)
                    .font(LatteFont.sm.weight(.medium))
                    .foregroundStyle(Latte.foreground)
                    .lineLimit(1)
                if isCurrent {
                    LatteBadge(variant: .success, text: i18n.t(.mpCurrent))
                }
                if isSharedHere {
                    LatteBadge(variant: .muted, text: i18n.t(.mpGenericBadge))
                }
                Spacer(minLength: 0)
                if !isCurrent {
                    Button(i18n.t(.mpSetCurrent)) {
                        Task { await setCurrent(provider.id) }
                    }
                    .buttonStyle(LatteButtonStyle(variant: .ghost))
                    .font(LatteFont.xs)
                    .disabled(busy)
                }
                if canManage {
                    Button {
                        editing = Self.draft(from: provider)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(LatteButtonStyle(variant: .ghost))
                    .help(i18n.t(.mpEdit))
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
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(LatteButtonStyle(variant: .ghost))
                        .help(i18n.t(.mpDelete))
                        .disabled(busy)
                    }
                }
            }
            HStack(spacing: 6) {
                Text(verbatim: Self.hostOf(provider.baseUrl))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Latte.mutedForeground)
                    .lineLimit(1)
                LatteBadge(variant: .muted, text: formatLabel(provider.apiFormat))
                LatteBadge(
                    variant: provider.hasKey ? .success : .muted,
                    text: provider.hasKey ? i18n.t(.mpKeySet) : i18n.t(.mpKeyMissing)
                )
                if let model = provider.model, !model.isEmpty {
                    Text(verbatim: model)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Latte.mutedForeground.opacity(0.8))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func formatLabel(_ format: String) -> String {
        switch format {
        case "openai_chat": return i18n.t(.mpFormatOpenaiChat)
        case "openai_responses": return i18n.t(.mpFormatOpenaiResponses)
        default: return i18n.t(.mpFormatAnthropic)
        }
    }

    private static func hostOf(_ baseUrl: String) -> String {
        baseUrl.replacingOccurrences(of: "^https?://", with: "", options: [.regularExpression, .caseInsensitive])
    }

    private static func draft(from view: ModelProviderView) -> ModelProviderConfig {
        ModelProviderConfig(
            id: view.id, agentId: view.agentId, name: view.name, baseUrl: view.baseUrl,
            // 编辑时把掩码放进表单：与 Windows 一致 —— 提交掩码 = 保留原 Key
            apiKey: view.apiKeyMasked, apiFormat: view.apiFormat, authStyle: view.authStyle,
            isFullUrl: view.isFullUrl, model: view.model, notes: view.notes,
            createdAtMs: view.createdAtMs, sortIndex: view.sortIndex
        )
    }

    // MARK: - CLI 原生厂商面板（对齐 Windows 各 `*-provider-panel.tsx`）
    //
    // 与上方「厂商面板」的**根本区别**：那个只读写 BrewPing 自有的供应商库
    // （服务转发链路）；这里是**直接读写用户真实的 CLI 配置文件**
    // （`~/.claude/settings.json` / `~/.codex/config.toml` / `~/.pi/agent/*` /
    // `~/.config/opencode/opencode.json`），让 CLI 自己就能用上你的中转站。
    // 与 Windows 相同：**只在对应 Agent tab 下渲染**。

    @ViewBuilder
    private var cliProviderSection: some View {
        switch activeTab {
        case "claude-code": ClaudeProviderPanel()
        case "codex":       CodexProviderPanel()
        case "pi":          PiProviderPanel()
        case "opencode":    OpenCodeProviderPanel()
        default:            EmptyView()
        }
    }

    // MARK: - CLI 接入（Phase 2）

    private var cliSection: some View {
        card {
            Button {
                cliOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: cliOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Latte.mutedForeground)
                    Text(i18n.t(.mpTakeover))
                        .font(LatteFont.xs.weight(.medium))
                        .foregroundStyle(Latte.foreground)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if cliOpen {
                Text(i18n.t(.mpTakeoverHint, ["port": String(info?.proxyPort ?? 15721)]))
                    .font(LatteFont.xs)
                    .foregroundStyle(Latte.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                // Phase 1：转发代理未实现 → 明确标注"暂不支持接入"，绝不假装可用
                Text(i18n.t(.mpTakeoverUnsupported))
                    .font(LatteFont.xs)
                    .foregroundStyle(Latte.warning)
            }
        }
    }

    // MARK: - Agent 模型偏好

    // 对齐 Windows「Agent 模型偏好」折叠区：每个 Agent 一张卡（摘要行 = 名称 +
    // 生效模型 + 偏好/跟随徽章 + 失效警告），展开 = 按 provider 分组的模型 chips
    // 点选 +「清除偏好」。语义 = 用户偏好 → 回落 CLI 当前模型。

    @State private var agentModels: [String: AgentModelsInfo] = [:]
    @State private var expandedAgent: String?
    @State private var agentBusy: String?

    private var agentPrefsSection: some View {
        card {
            Button {
                prefsOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: prefsOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Latte.mutedForeground)
                    Text(i18n.t(.mpAgentModels))
                        .font(LatteFont.xs.weight(.medium))
                        .foregroundStyle(Latte.foreground)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if prefsOpen {
                Text(i18n.t(.mpAgentModelsHint))
                    .font(LatteFont.xs)
                    .foregroundStyle(Latte.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(agents, id: \.id) { agent in
                        agentPrefCard(agent)
                    }
                    if agents.isEmpty {
                        Text(i18n.t(.mpAgentModelsEmpty))
                            .font(LatteFont.font10)
                            .foregroundStyle(Latte.mutedForeground)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        // id 带上 agents.count：父级 reload 完成前本任务可能先跑（此时 agents 还是空），
        // 等 agents 就绪后自动重拉一次（幂等，代价是 4 次本地读）。
        .task(id: "\(prefsOpen)|\(agents.count)") {
            guard prefsOpen, !agents.isEmpty else { return }
            await reloadAgentModels()
        }
    }

    /// 单个 Agent 的偏好卡。
    private func agentPrefCard(_ agent: DesktopStatusAgent) -> some View {
        let info = agentModels[agent.id]
        let expanded = expandedAgent == agent.id
        let preferred = info?.preferredModelId ?? nil
        let effective = preferred ?? info?.activeModelId ?? nil
        // preferredStillValid 的客户端等价：偏好是否仍属于某个已发现的 provider
        let stillValid = preferred == nil || (info?.providers.contains { provider in
            provider.models.contains { $0.id == preferred }
        } ?? true)
        let modelCount = (info?.providers.reduce(0) { $0 + $1.models.count }) ?? 0

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                expandedAgent = expanded ? nil : agent.id
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Latte.mutedForeground)
                    Text(verbatim: agent.name)
                        .font(LatteFont.xs.weight(.medium))
                        .foregroundStyle(Latte.foreground)
                        .lineLimit(1)
                    if agentBusy == agent.id {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    if preferred != nil, !stillValid {
                        LatteBadge(variant: .warning, text: i18n.t(.mpAgentModelInvalid))
                    }
                    Spacer(minLength: 8)
                    Text(verbatim: effective ?? "—")
                        .font(LatteFont.monoXS)
                        .foregroundStyle(Latte.mutedForeground)
                        .lineLimit(1)
                    if effective != nil {
                        LatteBadge(
                            variant: preferred != nil ? .success : .muted,
                            text: preferred != nil ? i18n.t(.mpAgentPrefBadge) : i18n.t(.mpAgentFollowBadge)
                        )
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if expanded {
                Rectangle()
                    .fill(Latte.border)
                    .frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    if info == nil || modelCount == 0 {
                        Text(i18n.t(.mpAgentModelsEmpty))
                            .font(LatteFont.font10)
                            .foregroundStyle(Latte.mutedForeground)
                    } else {
                        ForEach(info?.providers ?? [], id: \.id) { provider in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: provider.name)
                                    .font(LatteFont.font10)
                                    .foregroundStyle(Latte.mutedForeground)
                                FlowRow(spacing: 4) {
                                    ForEach(provider.models, id: \.id) { model in
                                        modelChip(agent.id, provider.id, model)
                                    }
                                }
                            }
                        }
                        if preferred != nil {
                            HStack {
                                Spacer(minLength: 0)
                                Button(i18n.t(.mpAgentModelClear)) {
                                    Task { await clearAgentModel(agent.id) }
                                }
                                .buttonStyle(LatteButtonStyle(variant: .ghost))
                                .font(LatteFont.xs)
                                .disabled(agentBusy == agent.id)
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Latte.card.opacity(0.7)))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Latte.border, lineWidth: 1)
        }
    }

    /// 模型 chip：选中 = 实心主色；不可用半透明。显示名优先，悬停显示 id。
    private func modelChip(_ agentId: String, _ providerId: String, _ model: ProviderModel) -> some View {
        let selected = model.isDefault
        return Button {
            Task { await pickAgentModel(agentId, modelId: model.id, providerId: providerId) }
        } label: {
            Text(verbatim: model.name.isEmpty ? model.id : model.name)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Latte.primary : Latte.background)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(selected ? Latte.primary : Latte.border, lineWidth: 1)
                }
                .foregroundStyle(selected ? Latte.primaryForeground : Latte.foreground)
        }
        .buttonStyle(.plain)
        .opacity(model.available || selected ? 1 : 0.5)
        .help(model.id)
    }

    private func reloadAgentModels() async {
        var snapshot: [String: AgentModelsInfo] = [:]
        for agent in agents {
            snapshot[agent.id] = await offMain { try? DesktopCommands.getAgentModels(agent.id) }
        }
        agentModels = snapshot
    }

    private func pickAgentModel(_ agentId: String, modelId: String, providerId: String) async {
        agentBusy = agentId
        defer { agentBusy = nil }
        await offMain { DesktopCommands.setDefaultModel(agentId, modelId: modelId, providerId: providerId) }
        await reloadAgentModels()
        // 偏好变了 → composer 的模型下拉重新拉取（与保存厂商后同效）
        DesktopEventBus.shared.post(.conversationsChanged, payload: [:])
    }

    private func clearAgentModel(_ agentId: String) async {
        agentBusy = agentId
        defer { agentBusy = nil }
        await offMain { DesktopCommands.setDefaultModel(agentId, modelId: nil, providerId: nil) }
        await reloadAgentModels()
        DesktopEventBus.shared.post(.conversationsChanged, payload: [:])
    }

    // MARK: - 数据动作

    private func reload() async {
        busy = true
        defer { busy = false }
        let snapshot = await offMainLoad()
        info = snapshot
        portDraft = String(snapshot.proxyPort)
        catalog = DesktopCommands.providerCatalog()
        agents = DesktopCommands.getAgents()
        if !activeTab.isEmpty, !agents.contains(where: { $0.id == activeTab }) {
            activeTab = ""   // tab 失效（Agent 卸载）→ 回落通用
        }
    }

    private func offMainLoad() async -> ModelProvidersInfo {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: DesktopCommands.modelProviders())
            }
        }
    }

    private func startAdd() {
        editing = ModelProviderConfig(agentId: activeTab)
    }

    private func save(_ draft: ModelProviderConfig) async {
        busy = true
        defer { busy = false }
        do {
            let next = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try DesktopCommands.saveModelProvider(draft)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            info = next
            editing = nil
            error = nil
            // 配置变了 → 让 composer 的模型下拉重新拉取（与 Windows 指纹 effect 同效）
            DesktopEventBus.shared.post(.conversationsChanged, payload: [:])
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ id: String) async {
        confirmId = nil
        busy = true
        defer { busy = false }
        let next = await offMain { DesktopCommands.deleteModelProvider(id: id) }
        info = next
        DesktopEventBus.shared.post(.conversationsChanged, payload: [:])
    }

    private func setCurrent(_ id: String) async {
        busy = true
        defer { busy = false }
        let next = await offMain { DesktopCommands.switchModelProvider(id: id, agentId: activeTab) }
        info = next
    }

    private func toggleProxy() async {
        busy = true
        defer { busy = false }
        let enabled = !(info?.proxyEnabled ?? false)
        let port = Int(portDraft) ?? info?.proxyPort ?? 15721
        let next = await offMain { DesktopCommands.setModelProxy(enabled: enabled, port: port) }
        info = next
    }

    private func applyPort() async {
        guard let port = Int(portDraft), port > 0, port != info?.proxyPort else { return }
        busy = true
        defer { busy = false }
        let next = await offMain {
            DesktopCommands.setModelProxy(enabled: info?.proxyEnabled ?? false, port: port)
        }
        info = next
    }

    private func setFailover(_ enabled: Bool) async {
        busy = true
        defer { busy = false }
        let next = await offMain { DesktopCommands.setModelFailover(enabled: enabled) }
        info = next
    }

    private func offMain<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    // MARK: - 卡片容器

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Latte.card)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Latte.border, lineWidth: 1)
            }
    }
}
