import Foundation
import Combine

enum MessageType {
    case status
    case command

    static func from(_ raw: String?) -> MessageType {
        raw == "command" ? .command : .status
    }
}

/// 命令提交阶段。既是提交引擎对外的状态出口，也是 iPhone UI 的展示状态。
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

/// 非 UI 通道（Watch 语音 / Watch 文本 / 后续的推送等）收到的命令，统一投递到这里。
final class CommandReceiver: ObservableObject {
    static let shared = CommandReceiver()

    @Published var lastCommandText: String?
    @Published var lastCommandReceivedAt: Date?
    @Published var lastCommandStatus: String = "received"
    @Published var lastCommandID = UUID()

    /// 命令进入系统后的唯一出口，由 `CommandSubmitter.bootstrap()` 挂接。
    ///
    /// 注意：绝不能把这条链路交给 SwiftUI 的 `.onChange(of:)`。
    /// WCSession 可以在 App 处于后台、界面尚未创建时唤醒进程投递音频，
    /// 那种情况下视图不会刷新，`.onChange` 永远不触发，
    /// 表现为"语音收到了、文字也识别出来了，但命令永远发不出去"。
    var onCommand: ((String) -> Void)?

    private init() {}

    func receive(type: MessageType, text: String) {
        print("CommandReceiver: received \(type) text=\(text)")
        guard type == .command, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.main.async {
            self.lastCommandText = text
            self.lastCommandReceivedAt = Date()
            self.lastCommandStatus = "received"
            self.lastCommandID = UUID()
            print("CommandReceiver: command stored: \(text) at \(self.lastCommandReceivedAt ?? Date())")
            self.onCommand?(text)
        }
    }
}

// MARK: - API Models（命令提交引擎专用）

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

// MARK: - CommandSubmitter

/// iPhone 端的命令提交引擎：POST 命令 → 轮询结果 → 回传 Watch。
///
/// 之所以做成单例而不是 `ContentView` 的方法，是因为命令执行必须与界面生命周期解耦：
/// - Watch 通过 `sendMessage` 发文本命令时，iOS App 会被在后台唤醒（不走前台 UI）；
/// - Watch 通过 `transferFile` 发语音时，App 可能根本还没创建界面。
/// 这两种情况下 SwiftUI 视图都不刷新，原来挂在 `ContentView.onChange` 上的提交逻辑
/// 永远不会执行，命令被静默丢弃、手表永远停在 "Sent / Waiting…"。
///
/// 单例存活于整个 App 进程，因此只要进程在，命令就一定会被执行。
@MainActor
final class CommandSubmitter: ObservableObject {
    static let shared = CommandSubmitter()

    @Published private(set) var phase: CommandPhase = .idle
    @Published private(set) var lastDuration: Double?
    @Published private(set) var lastFailureReason: String?
    @Published private(set) var lastModelId: String?

    private var pollTask: Task<Void, Never>?

    private init() {}

    /// App 启动时调用一次，且必须放在 `App.init()` 里。
    ///
    /// 后台唤醒不会经过任何 SwiftUI 视图的 `onAppear`，
    /// 所以 WCSession 的 delegate 注册和命令出口挂接都必须发生在这里，
    /// 否则 App 被唤醒时收不到任何来自 Watch 的数据。
    static func bootstrap() {
        // 触发单例构造 → 立即为 WCSession 装上 delegate 并 activate()。
        _ = WatchConnectivityManager.shared
        // 把非 UI 通道收到的命令直接接到提交引擎上。
        CommandReceiver.shared.onCommand = { text in
            Task { @MainActor in
                CommandSubmitter.shared.submit(text: text, fromWatch: true)
            }
        }
        print("CommandSubmitter: bootstrapped")
    }

    /// 取消当前轮询但保留已展示的结果（切换设备/会话时使用）。
    func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 取消轮询并清空结果展示。
    func reset() {
        cancelPolling()
        phase = .idle
        lastDuration = nil
        lastFailureReason = nil
        lastModelId = nil
    }

    /// 提交一条文本命令。
    ///
    /// - Parameters:
    ///   - text: 命令正文。
    ///   - fromWatch: 为 `true` 时表示命令来自手表，最终结果需要通过 WCSession 回传。
    func submit(text: String, fromWatch: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let base = DeviceStore.shared.activeDevice?.baseURL else {
            fail(with: "No device configured.", fromWatch: fromWatch)
            return
        }

        cancelPolling()
        phase = .sending
        lastDuration = nil
        lastFailureReason = nil
        lastModelId = nil

        let url = base.appendingPathComponent("api/message")
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.post(text: trimmed, to: url, base: base, fromWatch: fromWatch)
        }
    }

    // MARK: - Internals

    private func post(text: String, to url: URL, base: URL, fromWatch: Bool) async {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return }
            let decoded = try? JSONDecoder().decode(SubmitResponse.self, from: data)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200, let commandId = decoded?.commandId, !commandId.isEmpty else {
                fail(with: decoded?.error ?? "HTTP \(statusCode)", fromWatch: fromWatch)
                return
            }
            phase = .delivered
            await poll(commandId: commandId, base: base, fromWatch: fromWatch)
        } catch {
            guard !Task.isCancelled else { return }
            fail(with: error.localizedDescription, fromWatch: fromWatch)
        }
    }

    private func poll(commandId: String, base: URL, fromWatch: Bool) async {
        let url = base.appendingPathComponent("api/message/\(commandId)")
        var consecutiveErrors = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    consecutiveErrors += 1
                    if consecutiveErrors >= 10 {
                        fail(with: "Status poll failed.", fromWatch: fromWatch)
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
                    finish(decoded.response ?? "(empty response)", raw: false, decoded: decoded, fromWatch: fromWatch)
                    return
                case "completed_with_raw":
                    finish(decoded.rawOutput ?? "(empty raw output)", raw: true, decoded: decoded, fromWatch: fromWatch)
                    return
                case "failed":
                    lastFailureReason = decoded.failureReason
                    fail(with: decoded.error ?? "Unknown error.", decoded: decoded, fromWatch: fromWatch)
                    return
                default:
                    continue
                }
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= 10 {
                    fail(with: "Connection lost: \(error.localizedDescription)", fromWatch: fromWatch)
                    return
                }
            }
        }
    }

    private func finish(_ text: String, raw: Bool, decoded: CommandStatusResponse, fromWatch: Bool) {
        lastDuration = decoded.duration
        lastModelId = decoded.modelId
        phase = raw ? .completedRaw(text) : .completed(text)

        guard fromWatch else { return }
        // 结果无论走即时通道还是排队通道，都要保证能落到手表上。
        WatchConnectivityManager.shared.sendCommandResult(
            status: raw ? "completed_with_raw" : "completed",
            text: text,
            duration: decoded.duration
        )
    }

    private func fail(with message: String, decoded: CommandStatusResponse? = nil, fromWatch: Bool) {
        if let decoded {
            lastDuration = decoded.duration
            lastModelId = decoded.modelId
        }
        phase = .failed(message)

        guard fromWatch else { return }
        WatchConnectivityManager.shared.sendCommandResult(
            status: "failed",
            text: message,
            duration: decoded?.duration
        )
    }
}
