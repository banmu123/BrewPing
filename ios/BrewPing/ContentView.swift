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

// SubmitResponse / CommandStatusResponse 已随命令提交引擎移到 CommandReceiver.swift。

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

// CommandPhase 已随命令提交引擎一起移到 CommandReceiver.swift。

// MARK: - ContentView

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var deviceStore = DeviceStore.shared
    @StateObject private var watchBridge = WatchConnectivityManager.shared
    @StateObject private var submitter = CommandSubmitter.shared
    @StateObject private var bonjour = BonjourDiscovery()
    @State private var messageText = ""
    @State private var clearDraftWhenDelivered = false
    @State private var online = false
    @State private var hostName = ""
    @State private var sessionState: SessionState = .offline
    @State private var sessionID = ""
    @State private var sessionAgentIDFromStatus = "opencode"
    @State private var sessionAgentNameFromStatus = "OpenCode"
    @State private var sessionMessage = ""
    @State private var lifecycleBusy = false
    @State private var agents: [AgentEntry] = []
    @State private var discoveryRunning = false
    @State private var discoveryMessage = ""

    // 命令的提交与轮询统一由 CommandSubmitter 负责（见 CommandReceiver.swift），
    // 视图只是它的观察者。这样即使界面没被创建，Watch 来的命令也能照常执行。
    private var phase: CommandPhase { submitter.phase }
    private var lastDuration: Double? { submitter.lastDuration }
    private var lastFailureReason: String? { submitter.lastFailureReason }
    private var lastModelId: String? { submitter.lastModelId }

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
                // 语音识别权限只能在前台弹窗，先在这里定下来，
                // 否则手表在后台发来的语音会因为权限未决而识别失败。
                watchBridge.requestSpeechAuthorizationIfNeeded()
                watchBridge.appIsActive = (scenePhase == .active)
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
            .onChange(of: scenePhase) { newPhase in
                // 让 WCSession 知道 App 是否在前台：
                // 决定收到手表语音后要不要在本机回放（后台唤醒时不出声）。
                watchBridge.appIsActive = (newPhase == .active)
            }
            .onChange(of: submitter.phase) { newPhase in
                // 手动发送成功投递后才清空输入框（与旧行为一致），
                // 失败时保留草稿，方便用户重试。
                if newPhase == .delivered, clearDraftWhenDelivered {
                    messageText = ""
                    clearDraftWhenDelivered = false
                }
            }
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
        // 等到「发现 + 解析」都结束（最多 10 秒）
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !bonjour.discoveredHosts.isEmpty { break }
            if !bonjour.isSearching && !bonjour.isResolving { break }
        }
        if let host = bonjour.discoveredHosts.first {
            editHost = host.host
            editPort = String(host.port)
            editName = host.name
            discoveryMessage = "Found: \(host.name) (\(host.host):\(host.port))"
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
        submitter.reset()
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
        submitter.cancelPolling()
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
                    submitter.reset()
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
        submitter.reset()
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

    /// 手动发送（输入框 + Send 按钮）。
    /// 这里只做 UI 侧的前置校验，真正的提交与轮询统一交给 CommandSubmitter，
    /// 与 Watch 语音链路共用同一套实现，避免两条路径逻辑漂移。
    private func send() {
        guard let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              sessionState == .running else { return }
        clearDraftWhenDelivered = true
        Task {
            await refreshStatus()
            submitter.submit(text: text, fromWatch: false)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
