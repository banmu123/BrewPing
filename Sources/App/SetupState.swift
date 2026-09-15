import Foundation

// ─── 首次启动 Setup Wizard 的核心层（不依赖 SwiftUI，可单测）───────────────────
//
// 职责边界：
//   · SetupState      —— setupCompleted / skipped 持久化 + 最近一次扫描快照；
//   · AgentInstallInfo —— 各 agent 官方文档链接的统一配置 + 安装命令解析；
//   · SetupWizardModel —— 纯函数决策：EnvironmentStatus → 向导阶段。
//
// 检测与安装命令**复用** `EnvironmentSetup`（其 `installMethods` 是安装命令的
// 唯一权威来源），这里绝不重复维护一份命令清单，也绝不自动执行任何安装命令。

// MARK: - 持久化

/// 首次启动向导的持久化状态（UserDefaults；无敏感信息，不含命令输出）。
public enum SetupState {

    private static let completedKey = "brewping.setup.completed"
    private static let skippedKey = "brewping.setup.skipped"
    private static let snapshotKey = "brewping.setup.snapshot"

    /// 用户走完向导（Start BrewPing）。
    public static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    /// 用户在向导里主动跳过 —— 不再自动弹出（主界面留轻量入口）。
    public static var isSkipped: Bool {
        UserDefaults.standard.bool(forKey: skippedKey)
    }

    public static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
    }

    public static func markSkipped() {
        UserDefaults.standard.set(true, forKey: skippedKey)
    }

    /// 首次启动判定：既没完成也没跳过 → 弹向导。
    public static var shouldShowOnLaunch: Bool {
        !isCompleted && !isSkipped
    }

    // MARK: 最近一次扫描快照（§13：存结果，不存完整输出/敏感信息）

    public struct Snapshot: Codable, Equatable {
        public var nodeVersion: String?
        public var nodePath: String?
        public var npmVersion: String?
        public var nvmDetected: Bool
        public var installedAgents: [String]
        /// 快照时间（ms）——便于在设置页显示「上次检测」。
        public var checkedAtMs: Double

        public init(
            nodeVersion: String?, nodePath: String?, npmVersion: String?,
            nvmDetected: Bool, installedAgents: [String], checkedAtMs: Double
        ) {
            self.nodeVersion = nodeVersion
            self.nodePath = nodePath
            self.npmVersion = npmVersion
            self.nvmDetected = nvmDetected
            self.installedAgents = installedAgents
            self.checkedAtMs = checkedAtMs
        }
    }

    /// 从检测结果提取快照并落盘。
    public static func saveSnapshot(_ status: EnvironmentSetup.EnvironmentStatus) {
        let snap = Snapshot(
            nodeVersion: status.node.installed ? status.node.version : nil,
            nodePath: status.node.installed ? status.node.path : nil,
            npmVersion: status.npm.installed ? status.npm.version : nil,
            nvmDetected: status.nvm.installed,
            installedAgents: status.agents.filter { $0.installed }.map { $0.id },
            checkedAtMs: Date().timeIntervalSince1970 * 1000
        )
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: snapshotKey)
        }
    }

    public static var snapshot: Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// 单测辅助：清空全部持久化痕迹。
    public static func resetForTesting() {
        for key in [completedKey, skippedKey, snapshotKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

// MARK: - Agent 安装指引（统一配置）

/// 各 agent 的官方文档链接（统一一张表，不散落 UI）。
/// 安装命令**不在这里配**：唯一来源是 `EnvironmentSetup.installMethods` 的
/// `display`（官方通道，随环境即时计算 blocked），向导只负责展示与复制。
public struct AgentInstallInfo {
    public let id: String
    public let name: String
    public let documentationURL: URL

    public static let table: [String: AgentInstallInfo] = [
        "opencode": AgentInstallInfo(
            id: "opencode", name: "OpenCode",
            documentationURL: URL(string: "https://opencode.ai/docs")!
        ),
        "claude-code": AgentInstallInfo(
            id: "claude-code", name: "Claude Code",
            documentationURL: URL(string: "https://docs.anthropic.com/en/docs/claude-code")!
        ),
        "codex": AgentInstallInfo(
            id: "codex", name: "Codex CLI",
            documentationURL: URL(string: "https://github.com/openai/codex")!
        ),
        "pi": AgentInstallInfo(
            id: "pi", name: "pi",
            documentationURL: URL(
                string: "https://www.npmjs.com/package/@earendil-works/pi-coding-agent"
            )!
        ),
    ]

    public static func get(_ id: String) -> AgentInstallInfo? {
        table[id]
    }

    /// 推荐安装命令：从检测结果的 InstallMethod 里取 recommended 优先的一条的
    /// `display`（与「设置 → 环境」卡片展示的命令同源）。
    public static func recommendedCommand(for agent: EnvironmentSetup.AgentCliStatus) -> String? {
        let method = agent.methods.first(where: { $0.recommended }) ?? agent.methods.first
        return method?.display
    }
}

// MARK: - 向导决策（纯函数，可单测）

public enum SetupWizardModel {

    /// 扫描后的去向：缺 Node（或版本过旧）→ 先配 Node；Node 可用但无 agent →
    /// 引导装 agent；齐了 → ready。
    public enum Phase: Equatable {
        case needNode
        case needAgents
        case ready
    }

    public static func evaluate(_ status: EnvironmentSetup.EnvironmentStatus) -> Phase {
        let nodeOK = status.node.installed && status.node.compatible
        if !nodeOK { return .needNode }
        return status.agents.contains { $0.installed } ? .ready : .needAgents
    }
}
