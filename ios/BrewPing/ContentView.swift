import SwiftUI

struct StatusResponse: Decodable {
    let status: String?
    let host: String?
    let session: SessionBrief?
}

struct SessionBrief: Decodable {
    let id: String?
    let agent: String?
    let agentName: String?
    let status: String?
}

struct SubmitResponse: Decodable {
    let success: Bool?
    let commandId: String?
    let sessionId: String?
    let error: String?
}

struct CommandStatusResponse: Decodable {
    let commandId: String?
    let status: String?
    let response: String?
    let rawOutput: String?
    let duration: Double?
    let error: String?
    let failureReason: String?
    let modelId: String?
}

struct LifecycleResponse: Decodable {
    let success: Bool?
    let sessionId: String?
    let status: String?
    let error: String?
}

struct AgentsResponse: Decodable {
    let agents: [AgentEntry]?
    let defaultAgent: String?
}

struct AgentEntry: Decodable, Identifiable {
    let id: String
    let name: String
    let installed: Bool
    let active: Bool?
    let executable: Bool?
    let version: String?
}

enum SessionState: Equatable {
    case offline
    case starting
    case running
    case stopping
}

enum CommandPhase: Equatable {
    case idle
    case sending
    case delivered
    case working
    case completed(String)
    case completedRaw(String)
    case failed(String)

    var inFlight: Bool {
        switch self {
        case .idle, .completed, .completedRaw, .failed: return false
        default: return true
        }
    }
}

struct ContentView: View {
    @AppStorage("brewping.macAddress") private var macAddress = ""
    @AppStorage("brewping.port") private var port = "8787"
    @StateObject private var watchBridge = WatchConnectivityManager.shared
    @StateObject private var commandReceiver = CommandReceiver.shared
    @StateObject private var bonjour = BonjourDiscovery()
    @State private var messageText = ""
    @State private var online = false
    @State private var hostName = ""
    @State private var sessionState: SessionState = .offline
    @State private var sessionID = ""
    @State private var sessionAgentIDFromStatus = "opencode"
    @State private var sessionAgentNameFromStatus = "OpenCode"
    @State private var sessionMessage = ""
    @State private var phase: CommandPhase = .idle
    @State private var lastDuration: Double?
    @State private var lastFailureReason: String?
    @State private var lastModelId: String?
    @State private var lifecycleBusy = false
    @State private var agents: [AgentEntry] = []
    @State private var pollTask: Task<Void, Never>?
    @State private var discoveryRunning = false
    @State private var discoveryMessage = ""

    private var discoveryStatusColor: Color {
        discoveryMessage.contains("failed") || discoveryMessage.contains("Failed") ? .red : .secondary
    }

    private var baseURL: URL? {
        let host = macAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let portValue = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !portValue.isEmpty else { return nil }
        return URL(string: "http://\(host):\(portValue)")
    }

    var body: some View {
        NavigationView {
            Form {
                deviceCard
                agentListCard
                sessionCard
                Section("Message") {
                    TextField("Hello from iPhone", text: $messageText, axis: .vertical)
                        .lineLimit(3...5)
                        .autocorrectionDisabled()
                        .disabled(sessionState != .running)
                    Button {
                        send()
                    } label: {
                        if phase.inFlight {
                            HStack { ProgressView(); Text("Sending...") }
                        } else {
                            Text("Send")
                        }
                    }
                    .disabled(sessionState != .running || phase.inFlight || messageText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section("Result") {
                    resultView
                }
                Section {
                    Text("Dev use only: the Mac Agent must run on the same local network. This API has no authentication.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("BrewPing")
            .task {
                await refreshStatus()
                await refreshAgents()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await refreshStatus()
                }
            }
            .onChange(of: commandReceiver.lastCommandID) { _ in
                guard let text = commandReceiver.lastCommandText, !text.isEmpty else { return }
                submitWatchCommand(text)
            }
            .onDisappear { pollTask?.cancel() }
        }
    }

    private var agentListCard: some View {
        Section("Available AI Agents") {
            if agents.isEmpty {
                Text(online ? "Detecting agents..." : "Connect to the Mac to detect agents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(agents) { agent in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(agent.installed ? Color.green : Color.gray.opacity(0.5))
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(agent.name)
                                    .font(.callout)
                                if agent.active == true {
                                    Text("Default")
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.green.opacity(0.15)))
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(agent.installed ? (agent.version ?? "Installed") : "Not Installed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if agent.active != true, agent.installed, agent.executable == true {
                            Button("Set Default") {
                                setDefaultAgent(agent.id)
                            }
                            .font(.caption)
                            .disabled(lifecycleBusy)
                        }
                    }
                }
            }
        }
    }

    private func setDefaultAgent(_ id: String) {
        guard let url = baseURL?.appendingPathComponent("api/agents/default") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["agent": id])
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode != 200 {
                    let decoded = try? JSONDecoder().decode(LifecycleResponse.self, from: data)
                    sessionMessage = decoded?.error ?? "Switch failed (HTTP \(statusCode))"
                }
            } catch {
                sessionMessage = "Switch failed: \(error.localizedDescription)"
            }
            await refreshStatus()
            await refreshAgents()
        }
    }

    private var deviceCard: some View {
        Section("Mac") {
            TextField("Mac Address (e.g. 192.168.3.94)", text: $macAddress)
                .keyboardType(.decimalPad)
                .autocorrectionDisabled()
            HStack {
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                Spacer()
                Button(bonjour.isSearching ? "Searching..." : "Auto") {
                    Task { await discoverMac() }
                }
                .font(.caption)
                .disabled(bonjour.isSearching)
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(online ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(online ? "Connected" : "Offline")
                    .font(.callout)
                Spacer()
                Button(discoveryRunning ? "Checking..." : "Check") {
                    Task { await fullRefresh() }
                }
                .disabled(discoveryRunning)
            }
            if !hostName.isEmpty && online {
                Text(hostName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !discoveryMessage.isEmpty {
                Text(discoveryMessage)
                    .font(.caption2)
                    .foregroundStyle(discoveryStatusColor)
            }
            if !hostName.isEmpty && online {
                Text(hostName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let watchText = watchBridge.lastReceivedText {
                Text("Watch: \(watchText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sessionCard: some View {
        Section("Active Agent") {
            HStack(spacing: 8) {
                Text(activeAgentName)
                    .font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(sessionDotColor)
                        .frame(width: 10, height: 10)
                    Text(sessionStateText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if !sessionID.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session ID")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(sessionID.prefix(12)) + "...")
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            if !sessionMessage.isEmpty {
                Text(sessionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if activeAgentID == "opencode" {
                actionButton
            } else {
                Text("This agent runs commands on demand — no persistent session to manage.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activeAgentID: String {
        sessionAgentIDFromStatus
    }

    private var activeAgentName: String {
        sessionAgentNameFromStatus
    }

    private var actionButton: some View {
        Button {
            switch sessionState {
            case .running: stopSession()
            case .offline: newSession()
            default: break
            }
        } label: {
            HStack {
                Spacer()
                switch sessionState {
                case .running:
                    Label("Stop Session", systemImage: "stop.fill")
                case .offline:
                    Label("Start Session", systemImage: "play.fill")
                case .starting:
                    HStack(spacing: 8) { ProgressView(); Text("Starting...") }
                case .stopping:
                    HStack(spacing: 8) { ProgressView(); Text("Stopping...") }
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .tint(sessionState == .running ? .red : .green)
        .disabled(lifecycleBusy || sessionState == .starting || sessionState == .stopping)
    }

    private var sessionDotColor: Color {
        switch sessionState {
        case .running: return .green
        case .starting: return .orange
        case .stopping: return .orange
        case .offline: return online ? .gray : .red
        }
    }

    private var sessionStateText: String {
        switch sessionState {
        case .running: return "Running"
        case .starting: return "Starting..."
        case .stopping: return "Stopping..."
        case .offline: return "Offline"
        }
    }

    @ViewBuilder
    private var resultView: some View {
        switch phase {
        case .idle:
            Text("No message sent yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .sending:
            HStack(spacing: 8) {
                ProgressView()
                Text("Sending...")
                    .font(.callout)
            }
        case .delivered:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Delivered")
                    .font(.callout)
                Spacer()
                ProgressView()
            }
        case .working:
            HStack(spacing: 8) {
                Circle().fill(Color.orange).frame(width: 10, height: 10)
                Text("Working")
                    .font(.callout)
                Spacer()
                ProgressView()
            }
        case .completed(let response):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(durationSuffix("Completed")).font(.callout).fontWeight(.medium)
                }
                agentModelLine
                Text(response)
                    .font(.body)
                    .textSelection(.enabled)
            }
        case .completedRaw(let raw):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(durationSuffix("Completed")).font(.callout).fontWeight(.medium)
                }
                agentModelLine
                Text("Raw screen output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(raw)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .failed(let error):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(durationSuffix("Failed")).font(.callout).fontWeight(.medium)
                }
                agentModelLine
                if let reason = lastFailureReason {
                    Text(failureReasonLabel(reason))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.red)
                }
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func durationSuffix(_ base: String) -> String {
        guard let d = lastDuration else { return base }
        return String(format: "%@ · %.1fs", base, d)
    }

    private var agentModelLine: some View {
        HStack(spacing: 12) {
            if !sessionAgentNameFromStatus.isEmpty {
                Text(sessionAgentNameFromStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let model = lastModelId {
                Text(model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func failureReasonLabel(_ reason: String) -> String {
        switch reason {
        case "quota_exceeded":      return "Quota exceeded"
        case "authentication_failed": return "Authentication failed"
        case "rate_limited":        return "Rate limited"
        case "network_error":       return "Network error"
        case "model_unavailable":   return "Model unavailable"
        case "provider_error":      return "Provider error"
        case "timeout":             return "Timeout"
        case "process_exited":      return "Process exited"
        default:                    return reason
        }
    }

    private func refreshStatus() async {
        guard let url = baseURL?.appendingPathComponent("api/status") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(StatusResponse.self, from: data)
            online = decoded.status == "online"
            hostName = decoded.host ?? ""
            sessionID = decoded.session?.id ?? ""
            sessionAgentIDFromStatus = decoded.session?.agent ?? "opencode"
            sessionAgentNameFromStatus = decoded.session?.agentName ?? "OpenCode"
            let serverStatus = decoded.session?.status ?? ""
            if !lifecycleBusy {
                sessionState = (serverStatus == "running") ? .running : .offline
            }
            watchBridge.currentOnline = online
            watchBridge.currentSessionState = serverStatus
            watchBridge.currentAgentName = sessionAgentNameFromStatus
            watchBridge.currentAgentMode = sessionAgentIDFromStatus == "opencode" ? "session" : "headless"
            watchBridge.pushStatus(online: online, sessionStateRaw: serverStatus)
        } catch {
            online = false
            hostName = ""
            if !lifecycleBusy {
                sessionState = .offline
                sessionID = ""
            }
            sessionAgentIDFromStatus = "opencode"
            sessionAgentNameFromStatus = "OpenCode"
            watchBridge.currentOnline = false
            watchBridge.currentSessionState = ""
            watchBridge.currentAgentName = "OpenCode"
            watchBridge.currentAgentMode = "session"
            watchBridge.pushStatus(online: false, sessionStateRaw: "")
        }
    }

    /// Bonjour 自动发现：扫描局域网上的 BrewPing Mac Agent，找到后自动填充地址。
    private func discoverMac() async {
        bonjour.startSearching()
        // 等待搜索完成（最多 5 秒，由 BonjourDiscovery 内部计时器控制）
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !bonjour.discoveredHosts.isEmpty || !bonjour.isSearching { break }
        }
        if let host = bonjour.discoveredHosts.first {
            let resolvedHost = host.name.components(separatedBy: ".").first ?? host.name
            let resolved = resolvedHost + ".local"
            macAddress = resolved
            port = host.port > 0 ? String(host.port) : "8787"
            // 验证连接
            await refreshStatus()
            if online {
                discoveryMessage = "Found: \(host.name)"
            } else {
                discoveryMessage = "Found host but connection failed"
            }
        } else if !bonjour.isSearching {
            discoveryMessage = "No BrewPing agent found on this network"
        }
    }

    private func refreshAgents() async {
        guard let url = baseURL?.appendingPathComponent("api/agents") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(AgentsResponse.self, from: data)
            agents = decoded.agents ?? []
        } catch {
            agents = []
        }
    }

    private func fullRefresh() async {
        guard let url = baseURL else { return }
        discoveryRunning = true
        discoveryMessage = "Checking agents..."
        // 1. 触发 Mac 端完整重新发现（force refresh，读取真实配置文件）
        do {
            var request = URLRequest(url: url.appendingPathComponent("api/discovery/refresh"))
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let success = json?["success"] as? Bool ?? false
            let status = json?["status"] as? String ?? ""
            if success {
                if let errors = json?["errors"] as? [String], !errors.isEmpty {
                    discoveryMessage = "Updated (\(errors.count) warning)"
                } else {
                    discoveryMessage = "Updated"
                }
            } else {
                discoveryMessage = "Discovery failed"
            }
        } catch {
            discoveryMessage = "Check failed: \(error.localizedDescription)"
        }
        // 2. 拉取最新状态和 Agent 列表
        await refreshStatus()
        await refreshAgents()
        discoveryRunning = false
        // 5 秒后清除提示
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !discoveryRunning { discoveryMessage = "" }
        }
    }

    private func stopSession() {
        guard let url = baseURL?.appendingPathComponent("api/session/stop") else { return }
        pollTask?.cancel()
        lifecycleBusy = true
        sessionState = .stopping
        sessionMessage = ""
        Task {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let decoded = try? JSONDecoder().decode(LifecycleResponse.self, from: data)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode == 200, decoded?.success == true {
                    sessionMessage = "Session stopped"
                    phase = .idle
                } else {
                    sessionMessage = "Stop failed: \(decoded?.error ?? "HTTP \(statusCode)")"
                }
            } catch {
                sessionMessage = "Stop failed: \(error.localizedDescription)"
            }
            lifecycleBusy = false
            await refreshStatus()
            if sessionState == .stopping { sessionState = .offline }
        }
    }

    private func newSession() {
        guard let url = baseURL?.appendingPathComponent("api/session/start") else { return }
        pollTask?.cancel()
        phase = .idle
        lifecycleBusy = true
        sessionState = .starting
        sessionMessage = ""
        Task {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let decoded = try? JSONDecoder().decode(LifecycleResponse.self, from: data)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode == 200, decoded?.success == true {
                    sessionMessage = ""
                } else {
                    sessionMessage = "Start failed: \(decoded?.error ?? "HTTP \(statusCode)")"
                }
            } catch {
                sessionMessage = "Start failed: \(error.localizedDescription)"
            }
            lifecycleBusy = false
            await refreshStatus()
            if sessionState == .starting && !online { sessionState = .offline }
        }
    }

    private func send() {
        guard let url = baseURL?.appendingPathComponent("api/message"),
              let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              sessionState == .running else { return }
        pollTask?.cancel()
        phase = .sending
        lastDuration = nil
        lastFailureReason = nil
        lastModelId = nil
        Task {
            await refreshStatus()
            await submit(text, url: url)
        }
    }

    private func submitWatchCommand(_ text: String) {
        guard let url = baseURL?.appendingPathComponent("api/message") else {
            phase = .failed("No Mac address configured on iPhone.")
            watchBridge.sendCommandResult(status: "failed", text: "iPhone has no Mac address configured")
            return
        }
        guard sessionState == .running else {
            phase = .failed("OpenCode session is unavailable.")
            watchBridge.sendCommandResult(status: "failed", text: "OpenCode session is unavailable")
            return
        }
        pollTask?.cancel()
        phase = .sending
        lastDuration = nil
        lastFailureReason = nil
        lastModelId = nil
        Task {
            await submit(text, url: url, clearsDraft: false, fromWatch: true)
        }
    }

    private func submit(_ text: String, url: URL, clearsDraft: Bool = true, fromWatch: Bool = false) async {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let decoded = try? JSONDecoder().decode(SubmitResponse.self, from: data)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode == 200, let commandId = decoded?.commandId, !commandId.isEmpty {
                if clearsDraft { messageText = "" }
                phase = .delivered
                pollTask = Task { await poll(commandId: commandId, fromWatch: fromWatch) }
                return
            }
            phase = .failed(decoded?.error ?? "HTTP \(statusCode)")
            if fromWatch {
                watchBridge.sendCommandResult(status: "failed", text: decoded?.error ?? "HTTP \(statusCode)")
            }
        } catch {
            phase = .failed(error.localizedDescription)
            if fromWatch {
                watchBridge.sendCommandResult(status: "failed", text: error.localizedDescription)
            }
        }
    }

    private func poll(commandId: String, fromWatch: Bool = false) async {
        guard let base = baseURL else { return }
        let url = base.appendingPathComponent("api/message/\(commandId)")
        var consecutiveErrors = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    consecutiveErrors += 1
                    if consecutiveErrors >= 10 {
                        phase = .failed("Status poll failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
                        return
                    }
                    continue
                }
                let decoded = try JSONDecoder().decode(CommandStatusResponse.self, from: data)
                consecutiveErrors = 0
                switch decoded.status {
                case "queued", "sent":
                    phase = .delivered
                case "working":
                    phase = .working
                case "completed":
                    let text = decoded.response ?? "(empty response)"
                    lastDuration = decoded.duration
                    lastModelId = decoded.modelId
                    phase = .completed(text)
                    if fromWatch {
                        watchBridge.sendCommandResult(status: "completed", text: text, duration: decoded.duration)
                    }
                    return
                case "completed_with_raw":
                    let text = decoded.rawOutput ?? "(empty raw output)"
                    lastDuration = decoded.duration
                    lastModelId = decoded.modelId
                    phase = .completedRaw(text)
                    if fromWatch {
                        watchBridge.sendCommandResult(status: "completed_with_raw", text: text, duration: decoded.duration)
                    }
                    return
                case "failed":
                    let text = decoded.error ?? "Unknown error."
                    lastDuration = decoded.duration
                    lastFailureReason = decoded.failureReason
                    lastModelId = decoded.modelId
                    phase = .failed(text)
                    if fromWatch {
                        watchBridge.sendCommandResult(status: "failed", text: text, duration: decoded.duration)
                    }
                    return
                default:
                    continue
                }
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= 10 {
                    phase = .failed("Connection lost while polling: \(error.localizedDescription)")
                    return
                }
            }
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
