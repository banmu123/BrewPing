import SwiftUI
import Combine
import BrewPingCore

/// Terminal ViewModel：桥接 AgentManager（BrewPingCore）与 SwiftUI（Desktop UI）
@MainActor
final class TerminalViewModel: ObservableObject {
    @Published var activeAgentID: String = AgentManager.shared.activeAgentID
    @Published var registeredAgents: [AgentInfo] = AgentManager.shared.registeredAgents

    private var cancellables = Set<AnyCancellable>()

    init() {
        // 监听 activeAgent 变化（来自 HTTP API 或本地切换）
        NotificationCenter.default.publisher(for: .activeAgentDidChange)
            .compactMap { $0.userInfo?["agentId"] as? String }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] agentId in
                self?.activeAgentID = agentId
            }
            .store(in: &cancellables)

        // 初始状态同步
        syncFromManager()
    }

    /// 从 AgentManager 同步状态
    func syncFromManager() {
        let manager = AgentManager.shared
        activeAgentID = manager.activeAgentID
        registeredAgents = manager.registeredAgents
    }

    /// 获取当前活跃 Agent 的终端状态
    var currentTerminalState: AgentTerminalState? {
        AgentManager.shared.terminalState(for: activeAgentID)
    }

    /// 获取指定 Agent 的终端状态
    func terminalState(for agentId: String) -> AgentTerminalState? {
        AgentManager.shared.terminalState(for: agentId)
    }

    /// 切换活跃 Agent
    func switchToAgent(_ agentId: String) {
        guard agentId != activeAgentID else { return }
        AgentManager.shared.switchActiveAgent(agentId)
        activeAgentID = agentId
    }

    /// 向当前活跃 Agent 发送消息
    func sendInput(_ text: String) {
        let manager = AgentManager.shared
        let agentId = activeAgentID

        guard let state = manager.terminalState(for: agentId) else { return }

        // 显示用户输入
        state.appendLine("> \(text)", type: .system)

        // 如果是 OpenCode（session agent），走 SessionManager
        if agentId == AgentManager.sessionAgentID {
            let resp = SessionManager.shared.sendMessage(text)
            if resp.ok {
                state.appendLine("Message sent to \(manager.agentName(for: agentId))", type: .system)
            } else {
                state.appendLine("Error: \(resp.error ?? "send failed")", type: .error)
            }
            return
        }

        // 其他 Agent：使用 headless CLI provider
        guard let provider = manager.provider(for: agentId) else {
            state.appendLine("Error: agent '\(agentId)' not available", type: .error)
            return
        }

        state.setStatus(.running)
        let detected = AgentDiscovery.shared.discover().first { $0.id == agentId }

        DispatchQueue.global(qos: .userInitiated).async { [weak state] in
            guard let executablePath = detected?.path else {
                DispatchQueue.main.async {
                    state?.appendLine("Error: executable not found for \(agentId)", type: .error)
                    state?.setStatus(.error)
                }
                return
            }

            let result = SystemCommand.run(
                executablePath: executablePath,
                arguments: [text],
                timeoutSeconds: 120,
                additionalPATHEntries: SystemCommand.conventionalSearchPaths()
            )

            DispatchQueue.main.async {
                if let result {
                    if result.exitCode == 0 {
                        let lines = result.output.split(separator: "\n", omittingEmptySubsequences: false)
                        for line in lines {
                            state?.appendLine(String(line))
                        }
                        if result.output.isEmpty {
                            state?.appendLine("(no output)", type: .system)
                        }
                    } else {
                        state?.appendLine("Exit code: \(result.exitCode)", type: .error)
                        if !result.output.isEmpty {
                            state?.appendLine(result.output, type: .error)
                        }
                    }
                } else {
                    state?.appendLine("Error: command timed out or failed to start", type: .error)
                }
                state?.setStatus(.idle)
            }
        }
    }

    /// 清除当前 Agent 输出
    func clearCurrentOutput() {
        AgentManager.shared.terminalState(for: activeAgentID)?.clearOutput()
    }
}
