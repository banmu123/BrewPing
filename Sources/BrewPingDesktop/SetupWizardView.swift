import BrewPingCore
import SwiftUI

// ─── 首次启动 Setup Wizard（桌面端体验优化）────────────────────────────────────
//
// 流程：Welcome → Environment Check →（缺 Node 时）Node 指引 → Agents → Ready。
// 原则：
//   · 检测复用 `DesktopCommands.checkEnvironment()`（与「设置 → 环境」同源，不重写
//     Agent Discovery）；安装命令来自 `EnvironmentSetup.installMethods` 的统一配置；
//   · 绝不自动执行安装 —— 只提供官方链接 + 命令复制，装完由用户点「重新检测」；
//   · Check Again 必须真正重新扫描（重新跑 checkEnvironment，不是改 UI 状态）；
//   · 任何一步都可 Skip；跳过后主界面只留轻量横幅，不弹窗骚扰。

struct SetupWizardView: View {
    @EnvironmentObject private var i18n: I18n
    @EnvironmentObject private var app: DesktopAppState
    @Environment(\.openURL) private var openURL

    enum Step { case welcome, check, node, agents, models, done }

    @State private var step: Step = .welcome
    @State private var env: EnvironmentSetup.EnvironmentStatus?
    @State private var checking = false
    @State private var copiedAgentId: String?
    /// 本机已装 Node 版本（Node 步的切换清单）
    @State private var nodeVersions: [EnvironmentSetup.NodeInstallOption] = []
    /// agentId → 是否已配置可用模型（providers 非空）
    @State private var modelStatus: [String: Bool] = [:]
    @State private var switchingVersion: String?
    @State private var switchError: String?
    /// 手机配对成功（终步显示成功态并自动完成向导）
    @State private var pairSucceeded = false

    var body: some View {
        ZStack {
            Latte.background.ignoresSafeArea()
            content
        }
        // 直达 check 步（Run Setup Again / 预览）时也自动扫描
        .task {
            if step != .welcome, env == nil, !checking {
                await scan()
            }
        }
        // 用户从设置页（去配置模型 / 配对设置）回来 → 重扫以刷新模型配置状态
        .onChange(of: app.settingsOpen) { open in
            if !open, step == .models, !checking {
                Task { await scan() }
            }
        }
        // 终步的扫码配对：pairing.url 需 reveal 才生成（与设置页配对区同语义）
        .task(id: step) {
            if step == .done {
                if app.pairingSuccessCount > 0, !pairSucceeded {
                    // 配对发生在到达终步之前（如在 models 步时扫码）→ 直接进成功态
                    markPairedAndEnter()
                } else if app.pairing?.url == nil {
                    await app.revealPairing()
                }
            }
        }
        // 手机扫码 / 手动输码成功（HTTPAPI pair 处理器 → AppState 计数 +1）
        .onChange(of: app.pairingSuccessCount) { count in
            if count > 0, step == .done {
                markPairedAndEnter()
            }
        }
    }

    // MARK: - 各步骤

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .check: checkStep
        case .node: nodeStep
        case .agents: agentsStep
        case .models: modelsStep
        case .done: doneStep
        }
    }

    // MARK: Welcome（§2）

    private var welcomeStep: some View {
        column {
            VStack(spacing: 14) {
                Text("☕").font(.system(size: 40))
                Text(i18n.t(.swWelcomeTitle))
                    .font(LatteFont.xl)
                    .foregroundStyle(Latte.foreground)
                    .multilineTextAlignment(.center)
                Text(i18n.t(.swWelcomeSubtitle))
                    .font(LatteFont.sm)
                    .foregroundStyle(Latte.mutedForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    Button {
                        step = .check
                        Task { await scan() }
                    } label: {
                        Text(i18n.t(.swGetStarted))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(LatteButtonStyle(variant: .primary))
                    .controlSize(.large)

                    Button(i18n.t(.swSkipForNow)) { app.skipSetup() }
                        .buttonStyle(LatteButtonStyle(variant: .ghost))
                        .font(LatteFont.xs)
                }
                .padding(.top, 10)
                .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Environment Check（§3-5）

    private var checkStep: some View {
        column {
            stepHeader(
                title: i18n.t(.swStepCheck),
                subtitle: checking ? i18n.t(.swChecking) : nil
            )

            if let env {
                VStack(alignment: .leading, spacing: 0) {
                    statusRow(
                        title: i18n.t(.swRowOS), state: .ready,
                        detail: osSummary, why: nil
                    )
                    nodeRows(env)
                    npmRow(env)
                    nvmRow(env)
                    statusRow(
                        title: i18n.t(.swRowBrewping), state: .ready,
                        detail: i18n.t(.swServiceReadyDetail), why: nil
                    )
                    agentsSummaryRow(env)
                }
                .padding(.top, 14)
            } else if checking {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 24)
            }

            Spacer(minLength: 0)
            footer(
                back: nil,
                secondary: (i18n.t(.swCheckAgain), { Task { await scan() } }, checking),
                primary: (i18n.t(.swContinue), continueFromCheck, checking || env == nil),
                skip: true
            )
        }
    }

    private func continueFromCheck() {
        guard let env else { return }
        step = SetupWizardModel.evaluate(env) == .needNode ? .node : .agents
    }

    /// Node 行（状态语义：✓ Ready / ⚠ Needs Setup（过旧）/ ✕ Unavailable（未装）+ 原因）。
    private func nodeRows(_ env: EnvironmentSetup.EnvironmentStatus) -> some View {
        Group {
            if env.node.installed, let version = env.node.version, env.node.compatible {
                statusRow(
                    title: i18n.t(.swRowNode), state: .ready,
                    detail: detailWithSource(version: version, path: env.node.path, source: env.node.source),
                    why: nil
                )
            } else if env.node.installed, let version = env.node.version {
                statusRow(
                    title: i18n.t(.swRowNode), state: .needsSetup,
                    detail: version,
                    why: i18n.t(.swWhyNodeOld, [
                        "version": version,
                        "n": String(EnvironmentSetup.minNodeMajor),
                    ])
                )
            } else {
                statusRow(
                    title: i18n.t(.swRowNode), state: .unavailable,
                    detail: nil, why: i18n.t(.swWhyNodeMissing)
                )
            }
        }
    }

    private func npmRow(_ env: EnvironmentSetup.EnvironmentStatus) -> some View {
        statusRow(
            title: i18n.t(.swRowNpm),
            state: env.npm.installed ? .ready : .unavailable,
            detail: env.npm.installed ? env.npm.version : nil,
            why: env.npm.installed ? nil : i18n.t(.swWhyNpmMissing)
        )
    }

    /// NVM 行（§5）：Node 已可用时 NVM 只是可选，不阻塞。
    private func nvmRow(_ env: EnvironmentSetup.EnvironmentStatus) -> some View {
        let nodeOK = env.node.installed && env.node.compatible
        if env.nvm.installed {
            return statusRow(
                title: i18n.t(.swRowNvm), state: .ready,
                detail: env.nvm.version ?? env.nvm.path, why: nil
            )
        }
        return statusRow(
            title: i18n.t(.swRowNvm),
            state: nodeOK ? .optional : .needsSetup,
            detail: nil,
            why: nodeOK ? i18n.t(.swNvmOptionalHint) : i18n.t(.swWhyNvmMissing)
        )
    }

    private func agentsSummaryRow(_ env: EnvironmentSetup.EnvironmentStatus) -> some View {
        let installed = env.agents.filter { $0.installed }.count
        return statusRow(
            title: i18n.t(.swRowAgents),
            state: installed > 0 ? .ready : .needsSetup,
            detail: i18n.t(.swAgentsSummary, ["n": String(installed), "total": String(env.agents.count)]),
            why: nil
        )
    }

    private func detailWithSource(version: String, path: String?, source: String?) -> String {
        var parts = [version]
        if let path { parts.append(path) }
        if source == "nvm" { parts.append(i18n.t(.swViaNvm)) }
        else if source != nil { parts.append(i18n.t(.swViaSystem)) }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Node 指引（§6，只在缺/旧 Node 时进入）

    /// Node 步标题随场景变化：已装但过旧 =「升级」，完全没装 =「配置」。
    private var nodeStepTitle: String {
        if let env, env.node.installed, !env.node.compatible {
            return i18n.t(.swNodeUpdateTitle)
        }
        return i18n.t(.swNodeStepTitle)
    }

    /// 是否存在「已装、兼容、可一键切换」的版本 —— 有则切换是本步的主操作。
    private var hasSwitchableNewer: Bool {
        nodeVersions.contains { $0.compatible && $0.source == "nvm" && !$0.isDefault }
    }

    private var nodeStep: some View {
        column {
            stepHeader(
                title: nodeStepTitle,
                subtitle: checking ? i18n.t(.swChecking) : nil
            )

            if let env {
                if env.node.installed, let version = env.node.version, env.node.compatible {
                    // 已就绪（切换成功 / 返回本步）：显示成功态而不是误报「未安装」
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                            Text(verbatim: "\(i18n.t(.swRowNode)) \(version)")
                                .font(LatteFont.xs.weight(.medium))
                            LatteBadge(variant: .success, text: i18n.t(.swStatusReady)).fixedSize()
                        }
                        .foregroundStyle(Latte.success)
                        Text(i18n.t(.swReadySubtitle))
                            .font(LatteFont.font10)
                            .foregroundStyle(Latte.mutedForeground)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Latte.success.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Latte.success.opacity(0.35), lineWidth: 1)
                    }
                    .padding(.top, 8)
                } else if env.node.installed, let version = env.node.version {
                    problemBox(
                        state: .needsSetup,
                        title: "\(i18n.t(.swRowNode)) \(version)",
                        why: i18n.t(.swWhyNodeOld, [
                            "version": version,
                            "n": String(EnvironmentSetup.minNodeMajor),
                        ])
                    )
                } else {
                    problemBox(
                        state: .unavailable,
                        title: "\(i18n.t(.swRowNode)) · \(i18n.t(.swAgentNotInstalled))",
                        why: i18n.t(.swWhyNodeMissing)
                    )
                }

                // 🚀 信息层级：有可一键切换的新版本时，切换是主操作，
                // 「打开官网安装」降级为次分区（避免误导已装好环境的用户）。
                if hasSwitchableNewer {
                    Text(i18n.t(.swNodeSwitchIntro))
                        .font(LatteFont.xs)
                        .foregroundStyle(Latte.foreground.opacity(0.85))
                        .padding(.top, 10)
                }
                nodeVersionsSection

                if !nodeVersions.isEmpty {
                    Text(i18n.t(.swManualInstall))
                        .font(LatteFont.font11.weight(.medium))
                        .foregroundStyle(Latte.foreground.opacity(0.85))
                        .padding(.top, 16)
                }
                Text(i18n.t(.swNodeStepHint))
                    .font(LatteFont.xs)
                    .foregroundStyle(Latte.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                VStack(spacing: 8) {
                    wizardLinkButton(
                        title: i18n.t(.swOpenNvmGuide),
                        url: URL(string: "https://github.com/nvm-sh/nvm?tab=readme-ov-file#installing--updating")!
                    )
                    wizardLinkButton(
                        title: i18n.t(.swOpenNodeDownload),
                        url: URL(string: "https://nodejs.org/en/download")!
                    )
                }
                .padding(.top, 12)
                .frame(maxWidth: 320)
            }

            Spacer(minLength: 0)
            nodeFooter
        }
    }

    /// 本机已装 Node 版本清单 + 切换（用户主动点「使用」= 设 nvm default）。
    @ViewBuilder
    private var nodeVersionsSection: some View {
        if !nodeVersions.isEmpty {
            Text(i18n.t(.swNodeVersionsTitle))
                .font(LatteFont.font11.weight(.medium))
                .foregroundStyle(Latte.foreground.opacity(0.85))
                .padding(.top, 16)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(nodeVersions, id: \.path) { option in
                    nodeVersionRow(option)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Latte.border, lineWidth: 1)
            }
            .padding(.top, 8)

            Text(i18n.t(.swSwitchHint))
                .font(LatteFont.font10)
                .foregroundStyle(Latte.mutedForeground.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            if let switchError {
                Text(verbatim: switchError)
                    .font(LatteFont.font10)
                    .foregroundStyle(Latte.destructive)
                    .padding(.top, 4)
            }
        }
    }

    private func nodeVersionRow(_ option: EnvironmentSetup.NodeInstallOption) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "v\(option.version)")
                .font(LatteFont.mono11)
                .foregroundStyle(option.isActive ? Latte.primary : Latte.foreground)
            if option.isDefault {
                LatteBadge(variant: .muted, text: i18n.t(.swNodeDefaultBadge)).fixedSize()
            }
            if option.isActive {
                LatteBadge(variant: .success, text: i18n.t(.swNodeActiveBadge)).fixedSize()
            }
            if !option.compatible {
                LatteBadge(variant: .warning, text: i18n.t(.swStatusNeedsSetup)).fixedSize()
            }
            Spacer(minLength: 6)
            Text(verbatim: sourceLabel(option.source))
                .font(LatteFont.font9)
                .foregroundStyle(Latte.mutedForeground.opacity(0.7))
            if switchingVersion == option.version {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                    Text(i18n.t(.swSwitching)).font(LatteFont.font10)
                }
                .foregroundStyle(Latte.mutedForeground)
                .fixedSize()
            } else if option.source == "nvm", !option.isDefault {
                Button {
                    switchNode(option.version)
                } label: {
                    Text(i18n.t(.swNodeUse)).font(LatteFont.font10)
                }
                .buttonStyle(LatteButtonStyle(variant: .outline))
                .disabled(switchingVersion != nil)
            } else if option.isDefault {
                Text(i18n.t(.swNodeInUse))
                    .font(LatteFont.font10)
                    .foregroundStyle(Latte.mutedForeground)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { LatteDivider(opacity: 0.35) }
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "nvm": return "nvm"
        case "homebrew": return i18n.t(.swSourceHomebrew)
        default: return i18n.t(.swSourceSystem)
        }
    }

    private func switchNode(_ version: String) {
        guard switchingVersion == nil else { return }
        switchingVersion = version
        switchError = nil
        Task {
            let ok = await DesktopCommands.switchNodeDefault(version)
            switchingVersion = nil
            if ok {
                await scan()
            } else {
                switchError = i18n.t(.swSwitchFailed)
            }
        }
    }

    /// Node 步的动态 footer：装好后出现「继续」；否则只有 Back / Check Again / Skip。
    @ViewBuilder
    private var nodeFooter: some View {
        if let env, env.node.installed, env.node.compatible {
            footer(
                back: { step = .check },
                secondary: (i18n.t(.swCheckAgain), { Task { await scan() } }, checking),
                primary: (i18n.t(.swContinue), { step = .agents }, checking),
                skip: true
            )
        } else {
            footer(
                back: { step = .check },
                secondary: (i18n.t(.swCheckAgain), { Task { await scan() } }, checking),
                primary: nil,
                skip: true
            )
        }
    }

    // MARK: Agents（§7-8）

    private var agentsStep: some View {
        column {
            stepHeader(
                title: i18n.t(.swAgentsStepTitle),
                subtitle: checking ? i18n.t(.swChecking) : i18n.t(.swAgentsStepHint)
            )

            if let env {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(env.agents, id: \.id) { agent in
                        agentCard(agent)
                    }
                }
                .padding(.top, 14)
            } else if checking {
                ProgressView().controlSize(.small).padding(.top, 24)
            }

            Spacer(minLength: 0)
            footer(
                back: { step = .check },
                secondary: (i18n.t(.swCheckAgain), { Task { await scan() } }, checking),
                primary: (i18n.t(.swContinue), {
                    step = (env?.agents.contains { $0.installed } ?? false) ? .models : .done
                }, checking || env == nil),
                skip: true
            )
        }
    }

    // MARK: 配置模型（§新增：至少为一个 agent 配好模型才算配置落地）

    private var modelsStep: some View {
        column {
            stepHeader(
                title: i18n.t(.swModelsStepTitle),
                subtitle: checking ? i18n.t(.swChecking) : i18n.t(.swModelsStepHint)
            )

            if let env {
                let installed = env.agents.filter { $0.installed }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(installed, id: \.id) { agent in
                        modelStatusRow(agent)
                    }
                    if installed.isEmpty {
                        Text(i18n.t(.swNoAgentsTitle))
                            .font(LatteFont.xs)
                            .foregroundStyle(Latte.mutedForeground)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.top, 14)
            } else if checking {
                ProgressView().controlSize(.small).padding(.top, 24)
            }

            Spacer(minLength: 0)
            footer(
                back: { step = .agents },
                secondary: (i18n.t(.swCheckAgain), { Task { await scan() } }, checking),
                primary: (i18n.t(.swContinue), { step = .done }, checking || configuredAgentCount == 0),
                skip: true
            )
        }
    }

    /// 单个已装 agent 的模型配置状态行：已有模型 ✓ / 尚未配置 + 「去配置」。
    private func modelStatusRow(_ agent: EnvironmentSetup.AgentCliStatus) -> some View {
        let configured = modelStatus[agent.id] ?? false
        return HStack(spacing: 8) {
            Text(verbatim: agent.name)
                .font(LatteFont.xs.weight(.medium))
                .foregroundStyle(Latte.foreground)
                .lineLimit(1)
            Spacer(minLength: 6)
            if configured {
                LatteBadge(variant: .success, text: i18n.t(.swModelConfigured)).fixedSize()
            } else {
                LatteBadge(variant: .warning, text: i18n.t(.swModelMissing)).fixedSize()
                Button {
                    // 打开设置页并定位到该 agent 的模型配置 tab；
                    // 设置关闭后向导自动回来（DesktopRootView 的让位逻辑）。
                    UserDefaults.standard.set(agent.id, forKey: "brewping.modelTab")
                    app.settingsOpen = true
                    app.settingsSection = .models
                } label: {
                    Text(i18n.t(.swGoConfigure)).font(LatteFont.font10)
                }
                .buttonStyle(LatteButtonStyle(variant: .outline))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { LatteDivider(opacity: 0.35) }
    }

    private func agentCard(_ agent: EnvironmentSetup.AgentCliStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(agent.name)
                    .font(LatteFont.xs.weight(.medium))
                    .foregroundStyle(Latte.foreground)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if agent.installed {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                        if let version = agent.version {
                            Text(version).font(LatteFont.mono11)
                        }
                    }
                    .foregroundStyle(Latte.success)
                    .fixedSize()
                } else {
                    LatteBadge(variant: .muted, text: i18n.t(.swAgentNotInstalled))
                }
            }

            if let path = agent.path, agent.installed {
                Text(verbatim: path)
                    .font(LatteFont.mono11)
                    .foregroundStyle(Latte.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !agent.installed, let info = AgentInstallInfo.get(agent.id) {
                agentInstallGuide(agent, info)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Latte.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Latte.border, lineWidth: 1)
        }
    }

    /// 单个 agent 的安装指引：命令（复制）+ 官方文档。**只展示，绝不代跑**（§18）。
    private func agentInstallGuide(
        _ agent: EnvironmentSetup.AgentCliStatus, _ info: AgentInstallInfo
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let command = AgentInstallInfo.recommendedCommand(for: agent) {
                HStack(spacing: 8) {
                    Text(verbatim: command)
                        .font(LatteFont.mono11)
                        .foregroundStyle(Latte.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copiedAgentId = agent.id
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            if copiedAgentId == agent.id { copiedAgentId = nil }
                        }
                    } label: {
                        Label(
                            copiedAgentId == agent.id ? i18n.t(.swCopied) : i18n.t(.swCopyCommand),
                            systemImage: copiedAgentId == agent.id ? "checkmark" : "doc.on.doc"
                        )
                        .font(LatteFont.font10)
                    }
                    .buttonStyle(LatteButtonStyle(variant: .outline))
                    .fixedSize()
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Latte.background)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Latte.border.opacity(0.6), lineWidth: 1)
                }
            }

            Button {
                openURL(info.documentationURL)
            } label: {
                Label(i18n.t(.swOpenDocs), systemImage: "safari")
                    .font(LatteFont.font10)
            }
            .buttonStyle(LatteButtonStyle(variant: .ghost))
        }
    }

    // MARK: Ready / No agents（§10-11）

    /// 配对成功：切换成功态，短暂停留让用户看到反馈后自动完成向导（直接进入主界面）。
    private func markPairedAndEnter() {
        guard !pairSucceeded else { return }
        pairSucceeded = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            app.completeSetup()
        }
    }

    private var doneStep: some View {
        column {
            if let env, SetupWizardModel.evaluate(env) == .ready {
                let installed = env.agents.filter { $0.installed }
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Latte.success)
                    Text(i18n.t(.swReadyTitle))
                        .font(LatteFont.xl)
                        .foregroundStyle(Latte.foreground)
                    Text(i18n.t(.swReadySubtitle))
                        .font(LatteFont.sm)
                        .foregroundStyle(Latte.mutedForeground)

                    VStack(alignment: .leading, spacing: 6) {
                        checklistRow("✓", i18n.t(.swRowNode), env.node.version)
                        checklistRow("✓", i18n.t(.swRowNpm), env.npm.version)
                        checklistRow("✓", i18n.t(.swRowBrewping), nil)
                        ForEach(installed, id: \.id) { agent in
                            checklistRow("✓", agent.name, agent.version)
                        }
                    }
                    .padding(.top, 8)

                    // 配对提醒（§最后一步：用手机扫码配对）。成功 → 成功态 + 自动进入。
                    if pairSucceeded {
                        VStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(Latte.success)
                            Text(i18n.t(.swPairSuccessTitle))
                                .font(LatteFont.xs.weight(.medium))
                                .foregroundStyle(Latte.foreground)
                            Text(i18n.t(.swPairSuccessHint))
                                .font(LatteFont.font10)
                                .foregroundStyle(Latte.mutedForeground)
                        }
                        .padding(.top, 10)
                    } else {
                        VStack(spacing: 6) {
                            Text(i18n.t(.swPairStepTitle))
                                .font(LatteFont.xs.weight(.medium))
                                .foregroundStyle(Latte.foreground)
                            Text(i18n.t(.swPairStepHint))
                                .font(LatteFont.font10)
                                .foregroundStyle(Latte.mutedForeground)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            if let url = app.pairing?.url {
                                QRCodeView(text: url, size: 120)
                                    .padding(6)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(Latte.border, lineWidth: 1)
                                    }
                            } else {
                                ProgressView().controlSize(.small)
                            }
                            // 连接地址 + 配对码兜底：扫码不通时可肉眼核对网段 / 手动输码
                            if let pairing = app.pairing {
                                Text(verbatim: "http://\(pairing.host):\(pairing.port)")
                                    .font(LatteFont.mono11)
                                    .foregroundStyle(Latte.mutedForeground)
                                if let code = pairing.code {
                                    Text(verbatim: "\(i18n.t(.swPairCodeFallback)) \(code)")
                                        .font(LatteFont.mono11)
                                        .foregroundStyle(Latte.mutedForeground)
                                }
                                Text(i18n.t(.swPairAddrHint))
                                    .font(LatteFont.font9)
                                    .foregroundStyle(Latte.mutedForeground.opacity(0.8))
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 24)
                            }
                            Button {
                                app.settingsOpen = true
                                app.settingsSection = .pairing
                            } label: {
                                Text(i18n.t(.swOpenPairSettings)).font(LatteFont.font10)
                            }
                            .buttonStyle(LatteButtonStyle(variant: .ghost))
                        }
                        .padding(.top, 10)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                footer(
                    back: { step = .agents },
                    secondary: nil,
                    primary: (i18n.t(.swStartBrewping), { app.completeSetup() }, false),
                    skip: false
                )
            } else {
                VStack(spacing: 12) {
                    Text("○")
                        .font(.system(size: 30))
                        .foregroundStyle(Latte.mutedForeground)
                    Text(i18n.t(.swNoAgentsTitle))
                        .font(LatteFont.xl)
                        .foregroundStyle(Latte.foreground)
                    Text(i18n.t(.swNoAgentsSubtitle))
                        .font(LatteFont.sm)
                        .foregroundStyle(Latte.mutedForeground)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                footer(
                    back: nil,
                    secondary: (i18n.t(.swInstallAgent), { step = .agents }, false),
                    primary: nil,
                    skip: true,
                    skipAction: { app.skipSetup() }
                )
            }
        }
    }

    private func checklistRow(_ mark: String, _ label: String, _ version: String?) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: mark)
                .font(LatteFont.xs.weight(.semibold))
                .foregroundStyle(Latte.success)
            Text(verbatim: label)
                .font(LatteFont.xs)
                .foregroundStyle(Latte.foreground)
            if let version {
                Text(verbatim: version)
                    .font(LatteFont.mono11)
                    .foregroundStyle(Latte.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var osSummary: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    // MARK: - 共享小件

    private func column(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
    }

    private func stepHeader(title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(LatteFont.sm.weight(.semibold))
                .foregroundStyle(Latte.foreground)
            if let subtitle {
                Text(verbatim: subtitle)
                    .font(LatteFont.xs)
                    .foregroundStyle(Latte.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
    }

    /// 环境检查行：标题 + 状态徽章 + 明细 + 「为什么」解释。
    private func statusRow(
        title: String, state: RowState, detail: String?, why: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(verbatim: title)
                    .font(LatteFont.xs)
                    .foregroundStyle(Latte.foreground)
                Spacer(minLength: 8)
                stateBadge(state)
                if let detail {
                    Text(verbatim: detail)
                        .font(LatteFont.mono11)
                        .foregroundStyle(Latte.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 280, alignment: .trailing)
                }
            }
            if let why {
                Text(verbatim: why)
                    .font(LatteFont.font10)
                    .foregroundStyle(Latte.mutedForeground.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 0)
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { LatteDivider(opacity: 0.4) }
    }

    private enum RowState { case ready, needsSetup, unavailable, optional }

    @ViewBuilder
    private func stateBadge(_ state: RowState) -> some View {
        switch state {
        case .ready:
            LatteBadge(variant: .success, text: i18n.t(.swStatusReady)).fixedSize()
        case .needsSetup:
            LatteBadge(variant: .warning, text: i18n.t(.swStatusNeedsSetup)).fixedSize()
        case .unavailable:
            LatteBadge(variant: .muted, text: i18n.t(.swStatusUnavailable)).fixedSize()
        case .optional:
            LatteBadge(variant: .muted, text: i18n.t(.swStatusOptional)).fixedSize()
        }
    }

    private func problemBox(state: RowState, title: String, why: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: state == .needsSetup ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                    .font(.system(size: 12))
                Text(verbatim: title)
                    .font(LatteFont.xs.weight(.medium))
            }
            .foregroundStyle(state == .needsSetup ? Latte.warning : Latte.destructive)
            Text(verbatim: why)
                .font(LatteFont.font10)
                .foregroundStyle(Latte.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Latte.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Latte.warning.opacity(0.35), lineWidth: 1)
        }
        .padding(.top, 8)
    }

    private func wizardLinkButton(title: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            Label(title, systemImage: "arrow.up.forward.app")
                .font(LatteFont.xs)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(LatteButtonStyle(variant: .outline))
    }

    /// 步骤 footer：Back（可选）/ Check Again 等次按钮（可选）/ 主按钮（可选）/ Skip（可选）。
    private func footer(
        back: (() -> Void)?,
        secondary: (title: String, action: () -> Void, disabled: Bool)?,
        primary: (title: String, action: () -> Void, disabled: Bool)?,
        skip: Bool,
        skipAction: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            if let back {
                Button(i18n.t(.swBack), action: back)
                    .buttonStyle(LatteButtonStyle(variant: .ghost))
                    .font(LatteFont.xs)
            }
            Spacer(minLength: 0)
            if skip {
                Button(i18n.t(.swSkipForNow), action: skipAction ?? { app.skipSetup() })
                    .buttonStyle(LatteButtonStyle(variant: .ghost))
                    .font(LatteFont.xs)
            }
            if let secondary {
                Button(secondary.title, action: secondary.action)
                    .buttonStyle(LatteButtonStyle(variant: .outline))
                    .font(LatteFont.xs)
                    .disabled(secondary.disabled)
            }
            if let primary {
                Button(primary.title, action: primary.action)
                    .buttonStyle(LatteButtonStyle(variant: .primary))
                    .font(LatteFont.xs)
                    .disabled(primary.disabled)
            }
        }
        .padding(.top, 14)
    }

    // MARK: - 数据

    /// §9：真正重新扫描（重跑 checkEnvironment 并刷新快照），不是只改 UI。
    private func scan() async {
        checking = true
        let status = await DesktopCommands.checkEnvironment()
        env = status
        nodeVersions = await DesktopCommands.installedNodeVersions(activeNodePath: status.node.path)

        // 各已装 agent 是否已配置可用模型（providers 非空）
        var statuses: [String: Bool] = [:]
        for agent in status.agents where agent.installed {
            let info = await Task.detached(priority: .userInitiated) {
                try? DesktopCommands.getAgentModels(agent.id)
            }.value
            statuses[agent.id] = !(info?.providers.isEmpty ?? true)
        }
        modelStatus = statuses

        SetupState.saveSnapshot(status)
        checking = false
    }

    /// 已配置模型的 agent 数（models 步的「继续」门槛）。
    private var configuredAgentCount: Int {
        modelStatus.values.filter { $0 }.count
    }
}

