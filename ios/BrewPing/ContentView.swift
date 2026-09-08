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

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var deviceStore = DeviceStore.shared
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

    // 添加设备 Sheet
    @State private var showAddDevice = false
    @State private var editingDevice: ManagedDevice?
    @State private var editName = ""
    @State private var editHost = ""
    @State private var editPort = "8787"
    @State private var editOS: DeviceOSType = .mac

    private var baseURL: URL? {
        deviceStore.activeDevice?.baseURL
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 设备 Tab 栏
                deviceTabBar

                Form {
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
                }
            }
            .navigationTitle("BrewPing")
            .sheet(isPresented: $showAddDevice) {
                deviceFormSheet(isNew: true)
            }
            .sheet(item: $editingDevice) { device in
                deviceFormSheet(isNew: false, existing: device)
            }
            .task {
                await refreshStatus()
                await refreshAgents()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await refreshStatus()
                }
            }
            .onChange(of: deviceStore.activeDeviceID) { _ in
                Task {
                    resetState()
                    await refreshStatus()
                    await refreshAgents()
                }
            }
            .onChange(of: commandReceiver.lastCommandID) { _ in
                guard let text = commandReceiver.lastCommandText, !text.isEmpty else { return }
                submitWatchCommand(text)
            }
            .onDisappear { pollTask?.cancel() }
        }
    }

    // MARK: - 设备 Tab 栏

    private var deviceTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(deviceStore.devices) { device in
                    deviceTab(device)
                }

                // 添加按钮
                Button {
                    editName = ""
                    editHost = ""
                    editPort = "8787"
                    editOS = .mac
                    showAddDevice = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.blue)
                }
                .padding(.leading, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func deviceTab(_ device: ManagedDevice) -> some View {
        let isActive = device.id == deviceStore.activeDeviceID
        return Button {
            deviceStore.setActive(device.id)
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: device.osType.icon)
                        .font(.system(size: 11))
                    Text(device.name.isEmpty ? device.host : device.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                Circle()
                    .fill(isActive && online ? Color.green : (isActive ? Color.orange : Color.gray))
                    .frame(width: 5, height: 5)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.blue.opacity(0.15) : Color(.tertiarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Color.blue.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                editName = device.name
                editHost = device.host
                editPort = device.port
                editOS = device.osType
                editingDevice = device
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deviceStore.removeDevice(id: device.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - 添加/编辑设备 Sheet

    private func deviceFormSheet(isNew: Bool, existing: ManagedDevice? = nil) -> some View {
        NavigationView {
            Form {
                Section("Device Info") {
                    TextField("Name (e.g. Chenzk)", text: $editName)
                        .autocorrectionDisabled()
                    TextField("Host (IP or hostname)", text: $editHost)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $editPort)
                        .keyboardType(.numberPad)
                    Picker("System", selection: $editOS) {
                        ForEach(DeviceOSType.allCases, id: \.self) { os in
                            Label(os.label, systemImage: os.icon).tag(os)
                        }
                    }
                }

                Section {
                    Button(bonjour.isSearching ? "Searching..." : "Auto Discover") {
                        Task { await discoverForSheet() }
                    }
                    .disabled(bonjour.isSearching)
                    if !discoveryMessage.isEmpty {
                        Text(discoveryMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(isNew ? "Add Device" : "Edit Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showAddDevice = false
                        editingDevice = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") {
                        let trimmedHost = editHost.trimmingCharacters(in: .whitespaces)
                        let trimmedName = editName.trimmingCharacters(in: .whitespaces)
                        guard !trimmedHost.isEmpty else { return }

                        if isNew {
                            let device = ManagedDevice.new(
                                name: trimmedName.isEmpty ? editOS.label : trimmedName,
                                host: trimmedHost,
                                port: editPort,
                                osType: editOS
                            )
                            deviceStore.addDevice(device)
                        } else if var device = existing {
                            device.name = trimmedName
                            device.host = trimmedHost
                            device.port = editPort
                            device.osType = editOS
                            deviceStore.updateDevice(device)
                        }
                        showAddDevice = false
                        editingDevice = nil
                    }
                    .disabled(editHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func discoverForSheet() async {
        bonjour.startSearching()
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !bonjour.discoveredHosts.isEmpty || !bonjour.isSearching { break }
        }
        if let host = bonjour.discoveredHosts.first {
            let resolved = host.name.components(separatedBy: ".").first ?? host.name
            editHost = resolved.hasSuffix(".local") ? resolved : resolved + ".local"
            editPort = host.port > 0 ? String(host.port) : "8787"
            editName = resolved.replacingOccurrences(of: ".local", with: "")
            discoveryMessage = "Found: \(host.name)"
        } else {
            discoveryMessage = "No BrewPing agent found"
        }
    }

    // MARK: - Agent List

    private var agentListCard: some View {
        Section("AI Agents") {
            if agents.isEmpty {
                Text(online ? "Detecting agents..." : "Connect to detect agents.")
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

    // MARK: - Session Card

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
                HStack(spacing: 6) {
                    Image(systemName: "bolt.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    Text("Ready — type a command below to send")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var activeAgentID: String { sessionAgentIDFromStatus }
    private var activeAgentName: String { sessionAgentNameFromStatus }

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

    // MARK: - Result View

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
        case "quota_exceeded":         return "Quota exceeded"
        case "authentication_failed":  return "Authentication failed"
        case "rate_limited":           return "Rate limited"
        case "network_error":          return "Network error"
        case "model_unavailable":      return "Model unavailable"
        case "provider_error":         return "Provider error"
        case "timeout":                return "Timeout"
        case "process_exited":         return "Process exited"
        default:                       return reason
        }
    }

    // MARK: - State Reset

    private func resetState() {
        online = false
        hostName = ""
        sessionState = .offline
        sessionID = ""
        sessionAgentIDFromStatus = "opencode"
        sessionAgentNameFromStatus = "OpenCode"
        sessionMessage = ""
        phase = .idle
        agents = []
    }

    // MARK: - Networking

    private func refreshStatus() async {
        guard let url = baseURL?.appendingPathComponent("api/status") else {
            online = false
            hostName = ""
            return
        }
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
            watchBridge.currentAgentID = sessionAgentIDFromStatus
            if !agents.isEmpty {
                watchBridge.knownAgents = agents.map { ["id": $0.id, "name": $0.name] }
            }
            // 同步设备列表到 Watch
            watchBridge.knownDevices = deviceStore.devices.map { d in
                ["id": d.id, "name": d.displayName, "os": d.osType.rawValue]
            }
            watchBridge.activeDeviceID = deviceStore.activeDeviceID
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
            watchBridge.currentAgentID = "opencode"
            watchBridge.pushStatus(online: false, sessionStateRaw: "")
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

    // MARK: - Session Lifecycle

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

    // MARK: - Send

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
            phase = .failed("No device configured.")
            watchBridge.sendCommandResult(status: "failed", text: "No device configured")
            return
        }
        guard sessionState == .running else {
            phase = .failed("Session is unavailable.")
            watchBridge.sendCommandResult(status: "failed", text: "Session is unavailable")
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
                        phase = .failed("Status poll failed.")
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
                    phase = .failed("Connection lost: \(error.localizedDescription)")
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
