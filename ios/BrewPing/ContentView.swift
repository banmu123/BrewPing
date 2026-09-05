import SwiftUI

struct StatusResponse: Decodable {
    let status: String?
    let host: String?
    let session: SessionBrief?
}

struct SessionBrief: Decodable {
    let id: String?
    let agent: String?
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
    let error: String?
}

struct LifecycleResponse: Decodable {
    let success: Bool?
    let sessionId: String?
    let status: String?
    let error: String?
}

struct AgentsResponse: Decodable {
    let agents: [AgentEntry]?
}

struct AgentEntry: Decodable, Identifiable {
    let id: String
    let name: String
    let installed: Bool
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
    @State private var messageText = ""
    @State private var online = false
    @State private var hostName = ""
    @State private var sessionState: SessionState = .offline
    @State private var sessionID = ""
    @State private var sessionMessage = ""
    @State private var phase: CommandPhase = .idle
    @State private var lifecycleBusy = false
    @State private var agents: [AgentEntry] = []
    @State private var pollTask: Task<Void, Never>?

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
                            Text(agent.name)
                                .font(.callout)
                            Text(agent.installed ? (agent.version ?? "Installed") : "Not Installed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var deviceCard: some View {
        Section("Mac") {
            TextField("Mac Address (e.g. 192.168.3.94)", text: $macAddress)
                .keyboardType(.decimalPad)
                .autocorrectionDisabled()
            TextField("Port", text: $port)
                .keyboardType(.numberPad)
            HStack(spacing: 8) {
                Circle()
                    .fill(online ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(online ? "Connected" : "Offline")
                    .font(.callout)
                Spacer()
                Button("Check") {
                    Task {
                        await refreshStatus()
                        await refreshAgents()
                    }
                }
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
        Section("Current Session") {
            HStack(spacing: 8) {
                Text("OpenCode")
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
            actionButton
        }
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
                    Text("Completed").font(.callout).fontWeight(.medium)
                }
                Text("OpenCode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(response)
                    .font(.body)
                    .textSelection(.enabled)
            }
        case .completedRaw(let raw):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Completed").font(.callout).fontWeight(.medium)
                }
                Text("OpenCode (raw screen output)")
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
                    Text("Failed").font(.callout).fontWeight(.medium)
                }
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
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
            let serverStatus = decoded.session?.status ?? ""
            if !lifecycleBusy {
                sessionState = (serverStatus == "running") ? .running : .offline
            }
        } catch {
            online = false
            hostName = ""
            if !lifecycleBusy {
                sessionState = .offline
                sessionID = ""
            }
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
        Task {
            await refreshStatus()
            await submit(text, url: url)
        }
    }

    private func submit(_ text: String, url: URL) async {
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
                messageText = ""
                phase = .delivered
                pollTask = Task { await poll(commandId: commandId) }
                return
            }
            phase = .failed(decoded?.error ?? "HTTP \(statusCode)")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func poll(commandId: String) async {
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
                    phase = .completed(decoded.response ?? "(empty response)")
                    return
                case "completed_with_raw":
                    phase = .completedRaw(decoded.rawOutput ?? "(empty raw output)")
                    return
                case "failed":
                    phase = .failed(decoded.error ?? "Unknown error.")
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
