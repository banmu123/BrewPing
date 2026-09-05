import SwiftUI

struct StatusResponse: Decodable {
    let status: String?
    let session: SessionBrief?
}

struct SessionBrief: Decodable {
    let id: String?
    let agent: String?
    let status: String?
}

struct MessageResponse: Decodable {
    let success: Bool?
    let error: String?
}

struct ContentView: View {
    @AppStorage("brewping.macAddress") private var macAddress = ""
    @AppStorage("brewping.port") private var port = "8787"
    @State private var messageText = ""
    @State private var online = false
    @State private var sessionStatus = ""
    @State private var sessionID = ""
    @State private var resultText = ""
    @State private var busy = false

    private var baseURL: URL? {
        let host = macAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let portValue = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !portValue.isEmpty else { return nil }
        return URL(string: "http://\(host):\(portValue)")
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Mac") {
                    TextField("Mac Address (e.g. 192.168.3.94)", text: $macAddress)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    HStack {
                        Circle()
                            .fill(online ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(online ? "Online" : "Offline")
                        Spacer()
                        Button("Check") {
                            Task { await refreshStatus() }
                        }
                        .disabled(busy)
                    }
                    if !sessionStatus.isEmpty {
                        Text(sessionID.isEmpty
                            ? "Session: none (\(sessionStatus))"
                            : "Session: \(sessionID.prefix(8)) ... (\(sessionStatus))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Message") {
                    TextField("Hello from iPhone", text: $messageText, axis: .vertical)
                        .lineLimit(3...5)
                        .autocorrectionDisabled()
                    Button {
                        Task { await send() }
                    } label: {
                        if busy {
                            HStack { ProgressView(); Text("Sending...") }
                        } else {
                            Text("Send")
                        }
                    }
                    .disabled(busy || messageText.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !resultText.isEmpty {
                        Text(resultText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Dev use only: the Mac Agent must run on the same local network. This API has no authentication.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("BrewPing")
            .task { await refreshStatus() }
        }
    }

    private func refreshStatus() async {
        guard let url = baseURL?.appendingPathComponent("api/status") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(StatusResponse.self, from: data)
            online = decoded.status == "online"
            sessionStatus = decoded.session?.status ?? "no session"
            sessionID = decoded.session?.id ?? ""
        } catch {
            online = false
            sessionStatus = ""
            sessionID = ""
        }
    }

    private func send() async {
        guard let url = baseURL?.appendingPathComponent("api/message") else { return }
        busy = true
        defer { busy = false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": messageText])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let decoded = try? JSONDecoder().decode(MessageResponse.self, from: data)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode == 200, decoded?.success == true {
                resultText = "Message sent (\(messageText.prefix(24)))"
                messageText = ""
            } else {
                resultText = "Failed: \(decoded?.error ?? "HTTP \(statusCode)")"
            }
        } catch {
            resultText = "Failed: \(error.localizedDescription)"
        }
        await refreshStatus()
    }
}
