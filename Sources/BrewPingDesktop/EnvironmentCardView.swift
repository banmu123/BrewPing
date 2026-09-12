import BrewPingCore
import SwiftUI

// ─── 设置页「环境与 AI CLI」卡片（对齐 environment-card.tsx）────────────────────
//
// 自包含数据源（出现时 checkEnvironment + getNodeVersions），不依赖 App 传参。
// 安装任务的运行态与日志放在**模块级**存储：设置页是条件渲染，用户安装中途切走
// 再回来会重建视图，闭包与 @State 都会丢；模块级存储让重挂后仍能还原
// 「正在安装」与已有日志。安装本身在后台线程，不受影响。
// 检测结果同样缓存：切走再切回不重复探测，点「重新检测」才真正跑一轮。

@MainActor
enum EnvCardStore {
    /// taskID → 运行态（"nvm" | "node" | "cli:<agentId>" | "cli-upd:<agentId>"）
    static var taskRunning: [String: Bool] = [:]
    static var taskOK: [String: Bool] = [:]
    /// 安装日志环形缓冲（含命令行与逐行输出，上限 300 行）
    static var log: [String] = []
    static let logCap = 300
    static var envCache: EnvironmentSetup.EnvironmentStatus?
    static var versionsCache: [EnvironmentSetup.NodeVersionOption]?

    static func push(_ line: String) {
        log.append(line)
        if log.count > logCap { log.removeFirst(log.count - logCap) }
    }

    static func isBusy() -> Bool { taskRunning.values.contains(true) }
}

struct EnvironmentCardView: View {
    @EnvironmentObject private var i18n: I18n

    @State private var env: EnvironmentSetup.EnvironmentStatus?
    @State private var checking = true
    @State private var versions: [EnvironmentSetup.NodeVersionOption] = []
    @State private var verSel = ""
    @State private var customVer = ""
    @State private var logOpen = false
    /// 非响应式字典的快照计数值（完成/启动时 bump 触发重算 busy）
    @State private var taskTick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            environmentRows
            nodeHints
            nvmSection
            nodeInstallSection
            cliSection
            logSection
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Latte.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Latte.border, lineWidth: 1)
        }
        .task { await loadIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .desktopEvent)) { note in
            handle(note)
        }
    }

    private var busy: Bool { _ = taskTick; return EnvCardStore.isBusy() }

    // MARK: 标题行

    private var header: some View {
        HStack(spacing: 0) {
            Text(i18n.t(.envTitle))
                .font(LatteFont.font10.weight(.semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Latte.mutedForeground)
            Spacer(minLength: 0)

            Button {
                Task { await refresh() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: checking ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.system(size: 10))
                    Text(checking ? i18n.t(.envChecking) : i18n.t(.envRefresh))
                        .font(LatteFont.font10)
                }
                .foregroundStyle(Latte.foreground)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 6)
            .disabled(checking || busy)
        }
        .padding(.bottom, 8)
    }

    // MARK: 环境状态四行

    private var environmentRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            toolRow(i18n.t(.envNode)) {
                HStack(spacing: 6) {
                    if let node = env?.node, node.installed {
                        Text(node.version ?? "—")
                            .font(LatteFont.mono11)
                            .foregroundStyle(Latte.foreground)
                        if node.source == "nvm" {
                            Text("(\(i18n.t(.envNodeSourceNvm)))")
                                .font(LatteFont.font9)
                                .foregroundStyle(Latte.mutedForeground)
                        }
                        LatteBadge(
                            variant: node.compatible ? .success : .warning,
                            text: node.compatible ? i18n.t(.envNodeCompatible) : i18n.t(.envNodeTooOld)
                        )
                    } else {
                        LatteBadge(variant: .warning, text: i18n.t(.envNotInstalled))
                    }
                    Spacer(minLength: 0)
                }
            }
            toolRow(i18n.t(.envNpm)) {
                toolValue(env?.npm.version, installed: env?.npm.installed == true)
            }
            toolRow(i18n.t(.envNvm)) {
                toolValue(env?.nvm.version, installed: env?.nvm.installed == true)
            }
            toolRow(i18n.t(.envPython)) {
                toolValue(env?.python.version, installed: env?.python.installed == true)
            }
        }
    }

    private func toolRow<Content: View>(_ label: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(LatteFont.xs)
                .foregroundStyle(Latte.mutedForeground)
                .frame(width: 84, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func toolValue(_ version: String?, installed: Bool) -> some View {
        if installed, let version {
            Text(version)
                .font(LatteFont.mono11)
                .foregroundStyle(Latte.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(i18n.t(.envNotInstalled))
                .font(LatteFont.xs)
                .foregroundStyle(Latte.mutedForeground)
        }
    }

    // MARK: Node 引导提示

    @ViewBuilder
    private var nodeHints: some View {
        if let node = env?.node, !node.installed {
            warningBox(i18n.t(.envNodeMinHint, ["n": String(EnvironmentSetup.minNodeMajor)]))
        } else if let node = env?.node, node.installed, !node.compatible, let version = node.version {
            warningBox(i18n.t(.envNodeOldHint, [
                "n": String(EnvironmentSetup.minNodeMajor),
                "version": version,
            ]))
        }
    }

    private func warningBox(_ text: String) -> some View {
        Text(text)
            .font(LatteFont.font10)
            .foregroundStyle(Latte.warning)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Latte.warning.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.top, 8)
    }

    // MARK: 第一步：安装 NVM

    @ViewBuilder
    private var nvmSection: some View {
        if let env, !env.nvm.installed {
            sectionDivider
            Text(i18n.t(.envNvmSection))
                .font(LatteFont.font11.weight(.medium))
                .foregroundStyle(Latte.foreground.opacity(0.85))
            Text(i18n.t(.envNvmHint))
                .font(LatteFont.font10)
                .foregroundStyle(Latte.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            actionButton(
                title: EnvCardStore.taskRunning["nvm"] == true ? i18n.t(.envInstalling) : i18n.t(.envInstallNvm),
                icon: "arrow.down.circle",
                variant: .outline,
                spinning: EnvCardStore.taskRunning["nvm"] == true,
                disabled: busy
            ) {
                Task { await runTask("nvm") { await DesktopCommands.installNvm() } }
            }
            .padding(.top, 6)
        }
    }

    // MARK: 第二步：经 NVM 安装 Node

    private var nodeInstallSection: some View {
        Group {
            sectionDivider
            Text(i18n.t(.envNodeSection))
                .font(LatteFont.font11.weight(.medium))
                .foregroundStyle(Latte.foreground.opacity(0.85))

            FlowRow(spacing: 4) {
                ForEach(verChips, id: \.version) { option in
                    versionChip(option)
                }
                Button {
                    verSel = "custom"
                } label: {
                    Text(i18n.t(.envVersionCustom))
                        .font(LatteFont.font10)
                        .foregroundStyle(customActive ? Latte.primary : Latte.mutedForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(customActive ? Latte.primary.opacity(0.10) : .clear)
                        .clipShape(Capsule())
                        .overlay {
                            Capsule().strokeBorder(
                                customActive ? Latte.primary.opacity(0.4) : Latte.border, lineWidth: 1
                            )
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)

            if customActive {
                TextField(i18n.t(.envVersionCustomPlaceholder), text: $customVer)
                    .textFieldStyle(.plain)
                    .font(LatteFont.mono11)
                    .foregroundStyle(Latte.foreground)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Latte.background)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Latte.border, lineWidth: 1)
                    }
                    .onSubmit { installNode() }
                    .padding(.top, 6)
            }

            actionButton(
                title: EnvCardStore.taskRunning["node"] == true ? i18n.t(.envInstalling) : i18n.t(.envInstallNode),
                icon: "arrow.down.circle",
                variant: .primary,
                spinning: EnvCardStore.taskRunning["node"] == true,
                disabled: busy || nvmMissing || (customActive && customVer.trimmingCharacters(in: .whitespaces).isEmpty)
            ) {
                installNode()
            }
            .padding(.top, 6)
        }
    }

    private var verChips: [EnvironmentSetup.NodeVersionOption] {
        Array(versions.prefix(6))
    }

    private var customActive: Bool { verSel == "custom" }

    private var nvmMissing: Bool {
        guard let env else { return false }
        return !env.nvm.installed
    }

    private func versionChip(_ option: EnvironmentSetup.NodeVersionOption) -> some View {
        let selected = verSel == option.version
        let label = option.major != nil ? "v\(option.version)\(option.lts ? " LTS" : "")" : option.version
        return Button {
            verSel = option.version
        } label: {
            Text(label)
                .font(LatteFont.font10.monospaced())
                .foregroundStyle(selected ? Latte.primary : Latte.mutedForeground)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(selected ? Latte.primary.opacity(0.10) : .clear)
                .clipShape(Capsule())
                .overlay {
                    Capsule().strokeBorder(
                        selected ? Latte.primary.opacity(0.4) : Latte.border, lineWidth: 1
                    )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(option.ltsName.map { "\(i18n.t(.envVersionLts)) · \($0)" } ?? option.version)
    }

    // MARK: AI 智能体 CLI

    private var cliSection: some View {
        Group {
            sectionDivider
            Text(i18n.t(.envCliSection))
                .font(LatteFont.font11.weight(.medium))
                .foregroundStyle(Latte.foreground.opacity(0.85))
            Text(i18n.t(.envCliHint))
                .font(LatteFont.font10)
                .foregroundStyle(Latte.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(env?.agents ?? [], id: \.id) { agent in
                    agentRow(agent)
                }
            }
            .padding(.top, 6)
        }
    }

    private func agentRow(_ agent: EnvironmentSetup.AgentCliStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(agent.name)
                    .font(LatteFont.xs.weight(.medium))
                    .foregroundStyle(Latte.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)

                if agent.installed {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").font(.system(size: 10))
                        Text(i18n.t(.envInstalled)).font(LatteFont.font10)
                        if let version = agent.version {
                            Text(version)
                                .font(LatteFont.mono11)
                                .foregroundStyle(Latte.mutedForeground)
                        }
                    }
                    .foregroundStyle(Latte.success)

                    actionButton(
                        title: EnvCardStore.taskRunning["cli-upd:\(agent.id)"] == true
                            ? i18n.t(.envInstalling) : i18n.t(.envUpdate),
                        icon: "arrow.up.circle",
                        variant: .ghost,
                        spinning: EnvCardStore.taskRunning["cli-upd:\(agent.id)"] == true,
                        disabled: busy
                    ) {
                        Task { await runTask("cli-upd:\(agent.id)") { _ = await DesktopCommands.updateAgentCli(agentId: agent.id) } }
                    }
                    .help(i18n.t(.envUpdateTitle))
                }
            }

            if !agent.installed {
                ForEach(agent.methods, id: \.id) { method in
                    methodRow(agent: agent, method: method)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Latte.background)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Latte.border.opacity(0.6), lineWidth: 1)
        }
    }

    private func methodRow(
        agent: EnvironmentSetup.AgentCliStatus, method: EnvironmentSetup.InstallMethod
    ) -> some View {
        let blocked = blockedText(method)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(methodLabel(method.id))
                        .font(LatteFont.font11)
                        .foregroundStyle(Latte.foreground.opacity(0.85))
                        .lineLimit(1)
                    if method.recommended {
                        Text("★")
                            .font(LatteFont.font9)
                            .foregroundStyle(Latte.primary)
                            .padding(.horizontal, 6)
                            .background(Latte.primary.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }
                Text(blocked ?? methodDescription(method.id))
                    .font(LatteFont.font9)
                    .foregroundStyle(Latte.mutedForeground.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            actionButton(
                title: EnvCardStore.taskRunning["cli:\(agent.id)"] == true
                    ? i18n.t(.envInstalling) : i18n.t(.envCliInstall),
                icon: "arrow.down.circle",
                variant: .outline,
                spinning: EnvCardStore.taskRunning["cli:\(agent.id)"] == true,
                disabled: busy || blocked != nil
            ) {
                Task {
                    await runTask("cli:\(agent.id)") {
                        _ = await DesktopCommands.installAgentCli(agentId: agent.id, methodId: method.id)
                    }
                }
            }
            .help(blocked ?? method.display)
        }
        .padding(.top, 6)
    }

    private func blockedText(_ method: EnvironmentSetup.InstallMethod) -> String? {
        switch method.blocked {
        case "node": return i18n.t(.envBlockNode)
        case "node-version": return i18n.t(.envBlockNodeVersion, ["n": String(method.minNodeMajor)])
        case "python": return i18n.t(.envBlockPython)
        default: return nil
        }
    }

    private func methodLabel(_ id: String) -> String {
        switch id {
        case "native": return i18n.t(.envCliMethodNative)
        case "npm": return i18n.t(.envCliMethodNpm)
        default: return i18n.t(.envCliMethodPip)
        }
    }

    private func methodDescription(_ id: String) -> String {
        switch id {
        case "native": return i18n.t(.envCliMethodNativeDesc)
        case "npm": return i18n.t(.envCliMethodNpmDesc)
        default: return i18n.t(.envCliMethodPipDesc)
        }
    }

    // MARK: 安装日志

    @ViewBuilder
    private var logSection: some View {
        if !EnvCardStore.log.isEmpty {
            sectionDivider
            Button {
                logOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(i18n.t(.envLog))
                        .font(LatteFont.font10.weight(.medium))
                        .foregroundStyle(Latte.mutedForeground)
                    Spacer(minLength: 0)
                    Text(logOpen ? "−" : "+")
                        .font(LatteFont.font10)
                        .foregroundStyle(Latte.mutedForeground)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if logOpen {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(EnvCardStore.log.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(color(for: line))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(height: 1).id("logBottom")
                        }
                    }
                    .frame(maxHeight: 160)
                    .padding(8)
                    .background(Latte.background)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Latte.border.opacity(0.6), lineWidth: 1)
                    }
                    .padding(.top, 4)
                    .onAppear { proxy.scrollTo("logBottom", anchor: .bottom) }
                    .onChange(of: EnvCardStore.log.count) { _ in
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.contains("✓") { return Latte.success }
        if line.contains("✗") { return Latte.destructive }
        return Latte.mutedForeground
    }

    // MARK: 通用小件

    private var sectionDivider: some View {
        LatteDivider()
            .padding(.top, 12)
            .padding(.bottom, 10)
    }

    private func actionButton(
        title: String,
        icon: String,
        variant: LatteButtonStyle.Variant,
        spinning: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if spinning {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: icon).font(.system(size: 10))
                }
                Text(title).font(LatteFont.font10)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(LatteButtonStyle(variant: variant))
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    // MARK: 数据加载 / 事件

    private func loadIfNeeded() async {
        if let cached = EnvCardStore.envCache {
            env = cached
            checking = false
        } else {
            await refresh()
        }

        if let cached = EnvCardStore.versionsCache {
            versions = cached
            verSel = cached.first(where: { $0.recommended })?.version ?? cached.first?.version ?? "custom"
        } else {
            // 有缓存直接展示（切分类回来不重复探测），没有才首测
            let list = await DesktopCommands.getNodeVersions()
            EnvCardStore.versionsCache = list
            versions = list
            verSel = list.first(where: { $0.recommended })?.version ?? list.first?.version ?? "custom"
        }
        taskTick += 1
    }

    private func refresh() async {
        checking = true
        let status = await DesktopCommands.checkEnvironment()
        EnvCardStore.envCache = status
        env = status
        checking = false
    }

    private func handle(_ note: Notification) {
        guard let raw = note.userInfo?["event"] as? String,
              let event = DesktopEvent(rawValue: raw) else { return }

        switch event {
        case .envSetupLog:
            guard let payload = note.userInfo?["payload"] as? [String: Any],
                  let task = payload["task"] as? String,
                  let line = payload["line"] as? String else { return }
            EnvCardStore.push("[\(task)] \(line)")
            taskTick += 1

        case .envSetupDone:
            guard let payload = note.userInfo?["payload"] as? [String: Any],
                  let task = payload["task"] as? String else { return }
            let ok = payload["ok"] as? Bool ?? false
            EnvCardStore.taskRunning[task] = false
            EnvCardStore.taskOK[task] = ok
            logOpen = true
            taskTick += 1

        default:
            break
        }
    }

    /// 执行一个安装任务：置运行态 → 等命令返回 → 无论成败都重新检测。
    private func runTask(_ taskID: String, _ action: @escaping () async -> Void) async {
        guard EnvCardStore.taskRunning[taskID] != true else { return }
        EnvCardStore.taskRunning[taskID] = true
        logOpen = true
        taskTick += 1

        await action()

        // 无输出（例如 installAgentCli 返回 false，没派发脚本）也要收敛运行态
        if EnvCardStore.taskRunning[taskID] != false {
            EnvCardStore.taskRunning[taskID] = false
        }
        await refresh()
        taskTick += 1
    }

    private func installNode() {
        let version = customActive ? customVer.trimmingCharacters(in: .whitespaces) : verSel
        guard !version.isEmpty else { return }
        Task {
            await runTask("node") { await DesktopCommands.installNode(version) }
        }
    }
}
