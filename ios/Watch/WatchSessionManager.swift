import Foundation
import WatchConnectivity
import WatchKit
import Combine

enum CommandSendState: Equatable {
    case idle
    case sending
    case sent(String)
    case completed(String)
    case failed(String)
}

struct WatchAgent: Identifiable, Equatable {
    let id: String
    let name: String
}

/// 一个可切换的模型。与 `WatchAgent` 一样由 iPhone 同步过来 ——
/// 手表不直连 Mac，也不自己解析配置文件。模型名是用户配置的数据，不本地化。
struct WatchModel: Identifiable, Equatable {
    let id: String
    let name: String
}

struct WatchDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let osType: String  // "mac", "windows", "linux"

    var icon: String {
        switch osType {
        case "windows": return "pc"
        case "linux":   return "terminal"
        default:        return "desktopcomputer"
        }
    }

    var osLabel: String {
        switch osType {
        case "windows": return "Win"
        case "linux":   return "Linux"
        default:        return "Mac"
        }
    }
}

/// 对话目录里的一条（由 iPhone 从 Mac 端 `GET /api/conversations` 转发，
/// 只带展示要用的字段）。
struct WatchConversation: Identifiable, Equatable {
    let id: String
    let title: String
    let agentId: String
    let messageCount: Int
    let updatedAtMs: Double
    let isPinned: Bool
}

/// 迷你对话页里的一条消息。手表不做 Markdown 渲染，纯文本展示。
struct WatchChatMessage: Identifiable, Equatable {
    let id: String
    /// "user" | "assistant" | "error" | "system"
    let role: String
    let text: String
    let createdAtMs: Double
}

/// 一条对话的转录（iPhone 端裁剪过的最近若干条）。
struct WatchConversationDetail: Equatable {
    let id: String
    let title: String
    let messages: [WatchChatMessage]
    /// iPhone 端只转发了最近的若干条时为 true —— 提示用户「上面还有更早的」。
    let truncated: Bool
}

final class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    @Published var reachable = false
    @Published var activationState: WCSessionActivationState = .notActivated
    @Published var lastSentText: String?
    @Published var lastError: String?
    @Published var macConnected: Bool?
    @Published var sessionState: String?
    @Published var agentName: String = "OpenCode"
    @Published var agentMode: String = "session"
    @Published var commandState: CommandSendState = .idle
    @Published var lastCommandDuration: Double?

    // MARK: - Multi-Agent
    @Published var agents: [WatchAgent] = [
        WatchAgent(id: "opencode", name: "OpenCode"),
        WatchAgent(id: "claude-code", name: "Claude"),
        WatchAgent(id: "codex", name: "Codex")
    ]
    @Published var activeAgentIndex: Int = 0

    // MARK: - Multi-Model
    /// 当前 Agent 的可切换模型。空 = 还没同步到（或该 Agent 没有可选模型）。
    @Published var models: [WatchModel] = []
    @Published var activeModelIndex: Int = 0

    // MARK: - Multi-Device
    @Published var devices: [WatchDevice] = []
    @Published var activeDeviceIndex: Int = 0

    // MARK: - Conversations（对话目录 / 迷你对话）
    @Published var conversations: [WatchConversation] = []
    @Published var conversationsLoading = false
    @Published var conversationsError: String?
    @Published var conversationDetail: WatchConversationDetail?
    @Published var detailLoading = false
    @Published var detailError: String?

    /// 有得选才展示切换入口：0 个（没同步到）或 1 个（没得选）时隐藏。
    var canSwitchModel: Bool { models.count > 1 }

    /// 当前生效模型名；越界时返回空串（同步过程中数组可能短暂收缩）。
    var activeModelName: String {
        guard activeModelIndex < models.count else { return "" }
        return models[activeModelIndex].name
    }

    /// 左右切换一格（手表小屏用按钮比 TabView 手势更可控）。
    func stepModel(by delta: Int) {
        guard !models.isEmpty else { return }
        let count = models.count
        let next = ((activeModelIndex + delta) % count + count) % count
        switchToModel(index: next)
    }

    /// 左右切换一格设备（与 `stepModel` 同一套交互）。
    func stepDevice(by delta: Int) {
        guard !devices.isEmpty else { return }
        let count = devices.count
        let next = ((activeDeviceIndex + delta) % count + count) % count
        switchToDevice(index: next)
    }

    var activeAgentID: String {
        guard activeAgentIndex < agents.count else { return "opencode" }
        return agents[activeAgentIndex].id
    }

    var activeDeviceID: String {
        guard activeDeviceIndex < devices.count else { return "" }
        return devices[activeDeviceIndex].id
    }

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    private var stateTimer: Timer?
    private var requestedStatus = false
    private var statusRequestTicks = 0

    /// 正在排队的音频文件传输。`transferFile` 没有回复回调，
    /// 完成/失败只能从 `session(_:didFinish:)` 得知，
    /// 因此需要按文件名跟踪，避免把别的传输结果算到当前命令上。
    private var audioTransfers: [WCSessionFileTransfer] = []
    private var pendingAudioFileNames: Set<String> = []

    /// 用户刚在手表上切过的 Agent（等待 iPhone / Mac 确认）。
    ///
    /// 服务端切换需要时间往返，这期间 iPhone 推回的 `activeAgent` 可能还是旧值；
    /// 用它挡住覆盖，避免"切过去又被弹回来"。
    private var pendingAgentSwitch: String?
    private var pendingAgentSwitchAt: Date?

    func activate() {
        guard let session else { return }
        // 🚨 无论如何都要先挂 delegate：如果 WCSession 在 delegate 挂上之前
        //    就被系统提前激活（重装/恢复场景会出现），原实现的 guard 会直接
        //    return —— delegate 永远挂不上，activationDidCompleteWith 等
        //    回调全部丢失，UI 卡死在"正在连接"。
        session.delegate = self

        if session.activationState == .activated {
            // 会话早已激活、回调不会再来了：手动补齐状态（自愈）。
            DispatchQueue.main.async {
                self.activationState = .activated
                self.reachable = session.isReachable
                self.applyContext(session.receivedApplicationContext)
                self.requestStatusSync()
            }
            startStateTimer()
            return
        }

        session.activate()
        startStateTimer()
        applyContext(session.receivedApplicationContext)
    }

    private func applyContext(_ context: [String: Any]) {
        // applicationContext 兜底：iPhone 把最近命令结果合并进了 context，
        // 手表 App 被杀 / 消息通道未送达时，下次激活在这里恢复（内部有去重）。
        if let result = context["lastCommandResult"] as? [String: Any] {
            applyCommandResult(result)
        }
        DispatchQueue.main.async {
            if let mac = context["macConnected"] as? Bool {
                self.macConnected = mac
            }
            if let state = context["sessionState"] as? String, !state.isEmpty {
                self.sessionState = state
            }
            if let name = context["agentName"] as? String, !name.isEmpty {
                self.agentName = name
            }
            if let mode = context["agentMode"] as? String, !mode.isEmpty {
                self.agentMode = mode
            }
            // 同步 Agent 列表
            if let agentList = context["agents"] as? [[String: String]] {
                let parsed = agentList.compactMap { dict -> WatchAgent? in
                    guard let id = dict["id"], let name = dict["name"] else { return nil }
                    return WatchAgent(id: id, name: name)
                }
                if !parsed.isEmpty {
                    self.agents = parsed
                }
            }
            if let activeId = context["activeAgent"] as? String,
               let idx = self.agents.firstIndex(where: { $0.id == activeId }) {
                if let pending = self.pendingAgentSwitch, pending != activeId {
                    // 用户刚切过 Agent、服务端尚未确认：忽略这个滞后的旧值。
                    // 超过 5 秒仍未确认则放弃保护（说明切换大概失败了，接受服务端状态）。
                    if let t = self.pendingAgentSwitchAt,
                       Date().timeIntervalSince(t) < 5 {
                        // 保持本地选择
                    } else {
                        self.pendingAgentSwitch = nil
                        self.activeAgentIndex = idx
                    }
                } else {
                    // 没有待确认切换，或服务端已确认到目标 Agent：接受并解除保护。
                    self.pendingAgentSwitch = nil
                    self.activeAgentIndex = idx
                }
            }
            // 同步设备列表
            if let deviceList = context["devices"] as? [[String: String]] {
                let parsed = deviceList.compactMap { dict -> WatchDevice? in
                    guard let id = dict["id"], let name = dict["name"] else { return nil }
                    return WatchDevice(id: id, name: name, osType: dict["os"] ?? "mac")
                }
                if !parsed.isEmpty {
                    self.devices = parsed
                }
            }
            if let activeDevId = context["activeDevice"] as? String,
               let idx = self.devices.firstIndex(where: { $0.id == activeDevId }) {
                self.activeDeviceIndex = idx
            }
            // 同步模型列表 + 当前生效模型（iPhone 从 Mac 端拿到后转发）
            self.applyModels(from: context)
            // 语言偏好由 iPhone 同步过来，手表不单独维护。
            if let lang = context[WatchLanguageManager.syncKey] as? String {
                WatchLanguageManager.shared.setLanguageFromPhone(lang)
            }
        }
    }

    /// 解析 iPhone 同步过来的模型列表。
    ///
    /// 模型是 **per-Agent** 的配置（Mac 端 `GET /api/agents/<agentId>/models`），
    /// 所以必须校验这份列表属于哪个 Agent：
    ///  - 属于当前 Agent → 正常应用；
    ///  - 属于**别的** Agent → 整份清空，绝不把上一个 Agent 的模型留在界面上。
    ///
    /// 而 `list` 为空时**保留**上一次结果 —— iPhone 可能只是这一轮没拉到，
    /// 不该让手表上已经显示的选项凭空消失；"属于别的 Agent"是另一回事，必须清空。
    private func applyModels(from context: [String: Any]) {
        guard let list = context["models"] as? [[String: String]] else { return }

        // 归属校验：列表对应的 Agent 与手表当前选的 Agent 不一致 → 清空。
        // `activeAgentID` 在 `switchToAgent` 里是**立即**更新的，
        // 所以切 Agent 的瞬间就会命中这里，不会短暂显示错位的模型。
        if let modelsAgent = context["modelsAgent"] as? String,
           !modelsAgent.isEmpty,
           modelsAgent != activeAgentID {
            models = []
            activeModelIndex = 0
            return
        }

        let parsed = list.compactMap { dict -> WatchModel? in
            guard let id = dict["id"], let name = dict["name"] else { return nil }
            return WatchModel(id: id, name: name)
        }
        guard !parsed.isEmpty else { return }
        models = parsed
        if let activeId = context["activeModelId"] as? String,
           let idx = parsed.firstIndex(where: { $0.id == activeId }) {
            activeModelIndex = idx
        } else if activeModelIndex >= parsed.count {
            activeModelIndex = 0
        }
    }

    // MARK: - Model Switching

    func switchToModel(index: Int) {
        guard index >= 0, index < models.count else { return }
        let model = models[index]
        activeModelIndex = index

        guard let session, session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(
            ["type": "switchModel", "agentId": activeAgentID, "modelId": model.id],
            replyHandler: nil,
            errorHandler: { error in
                WatchLog.session.error("switchModel failed: \(error.localizedDescription, privacy: .private)")
            }
        )
    }

    // MARK: - Agent Switching

    func switchToAgent(index: Int) {
        guard index >= 0, index < agents.count else { return }
        activeAgentIndex = index
        let agent = agents[index]
        let agentId = agent.id
        agentName = agent.name
        // 记下本地意图，在收到服务端确认前不让滞后的回推覆盖（见 applyContext）。
        pendingAgentSwitch = agentId
        pendingAgentSwitchAt = Date()

        guard let session, session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(
            ["type": "switchAgent", "agentId": agentId],
            replyHandler: { [weak self] reply in
                DispatchQueue.main.async {
                    self?.requestStatusSync()
                }
            },
            errorHandler: { error in
                WatchLog.session.error("switchAgent failed: \(error.localizedDescription, privacy: .private)")
            }
        )
    }

    func nextAgent() {
        let next = (activeAgentIndex + 1) % agents.count
        switchToAgent(index: next)
    }

    func previousAgent() {
        let prev = (activeAgentIndex - 1 + agents.count) % agents.count
        switchToAgent(index: prev)
    }

    // MARK: - Device Switching

    func switchToDevice(index: Int) {
        guard index >= 0, index < devices.count else { return }
        activeDeviceIndex = index
        let deviceId = devices[index].id

        // 换设备 = 换一台 Mac，目录与详情都是旧设备的，立刻清掉，
        // 避免切过去的那一瞬间还显示上一台 Mac 的对话。
        conversations = []
        conversationDetail = nil
        conversationsError = nil
        detailError = nil
        requestedDetailId = nil

        guard let session, session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(
            ["type": "switchDevice", "deviceId": deviceId],
            replyHandler: { [weak self] reply in
                DispatchQueue.main.async {
                    self?.requestStatusSync()
                }
            },
            errorHandler: { error in
                WatchLog.session.error("switchDevice failed: \(error.localizedDescription, privacy: .private)")
            }
        )
    }

    // MARK: - State Refresh

    /// 带看门狗的请求。WCSession 的 replyHandler 没有文档化超时，
    /// iPhone 端无响应时手表会永远等下去，所以自己挂 10s 兜底。
    /// `onReply` / `onTimeout` 都已切回主线程。
    private func sendWatchRequest(
        _ payload: [String: Any],
        timeout seconds: TimeInterval = 10,
        onReply: @escaping ([String: Any]) -> Void,
        onTimeout: @escaping () -> Void
    ) {
        guard let session, session.activationState == .activated, session.isReachable else {
            DispatchQueue.main.async { onTimeout() }
            return
        }
        let lock = NSLock()
        var settled = false
        func settle(_ reply: [String: Any]?) {
            lock.lock()
            let first = !settled
            settled = true
            lock.unlock()
            guard first else { return }
            DispatchQueue.main.async {
                if let reply { onReply(reply) } else { onTimeout() }
            }
        }
        session.sendMessage(
            payload,
            replyHandler: { reply in settle(reply) },
            errorHandler: { _ in settle(nil) }
        )
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { settle(nil) }
    }

    /// 拉取当前设备的对话目录。
    func requestConversations() {
        DispatchQueue.main.async {
            self.conversationsLoading = true
            self.conversationsError = nil
        }
        sendWatchRequest(["type": "requestConversations"]) { [weak self] reply in
            self?.applyConversations(reply)
        } onTimeout: { [weak self] in
            self?.conversationsLoading = false
            self?.conversationsError = LW("iPhone Not Connected")
        }
    }

    private func applyConversations(_ reply: [String: Any]) {
        DispatchQueue.main.async {
            self.conversationsLoading = false
            guard reply["ok"] as? Bool == true,
                  let list = reply["conversations"] as? [[String: Any]] else {
                self.conversationsError = LW("Can't load conversations")
                return
            }
            self.conversations = list.compactMap { item in
                guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                let rawTitle = item["title"] as? String ?? ""
                return WatchConversation(
                    id: id,
                    title: rawTitle.isEmpty ? LW("(untitled)") : rawTitle,
                    agentId: item["agentId"] as? String ?? "",
                    messageCount: item["messageCount"] as? Int ?? 0,
                    updatedAtMs: item["updatedAtMs"] as? Double ?? 0,
                    isPinned: item["isPinned"] as? Bool ?? false
                )
            }
        }
    }

    /// 拉取一条对话的转录（迷你对话页）。
    func requestConversation(id: String) {
        DispatchQueue.main.async {
            self.requestedDetailId = id
            // 换了一条对话就先清掉上一条的内容，避免先闪一下旧转录
            if self.conversationDetail?.id != id { self.conversationDetail = nil }
            self.detailLoading = true
            self.detailError = nil
        }
        sendWatchRequest(["type": "requestConversation", "conversationId": id]) { [weak self] reply in
            self?.applyConversationDetail(reply)
        } onTimeout: { [weak self] in
            self?.detailLoading = false
            self?.detailError = LW("iPhone Not Connected")
        }
    }

    /// 当前正在请求的对话 id。迟到的旧响应据此丢弃 ——
    /// 否则用户从 A 退回目录再点进 B，A 的转录可能后到，把 B 的内容覆盖掉。
    private var requestedDetailId: String?

    private func applyConversationDetail(_ reply: [String: Any]) {
        DispatchQueue.main.async {
            self.detailLoading = false
            guard reply["ok"] as? Bool == true,
                  let list = reply["messages"] as? [[String: Any]] else {
                self.detailError = LW("Can't open conversation")
                return
            }
            let detailId = reply["id"] as? String ?? ""
            if let requested = self.requestedDetailId, detailId != requested { return }

            let messages = list.enumerated().map { index, item in
                WatchChatMessage(
                    id: "\(index)",
                    role: item["role"] as? String ?? "assistant",
                    text: item["text"] as? String ?? "",
                    createdAtMs: item["createdAtMs"] as? Double ?? 0
                )
            }
            self.conversationDetail = WatchConversationDetail(
                id: detailId,
                title: reply["title"] as? String ?? "",
                messages: messages,
                truncated: reply["truncated"] as? Bool ?? false
            )
        }
    }

    private func startStateTimer() {
        guard stateTimer == nil else { return }
        stateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
    }

    func refreshState() {
        guard let session else { return }
        DispatchQueue.main.async {
            let reachable = session.isReachable
            if self.reachable != reachable {
                if reachable { self.requestedStatus = false }
            }
            self.reachable = reachable
            self.activationState = session.activationState
            self.statusRequestTicks += 1
            let needsStatus = self.macConnected == nil
            let periodicRefresh = self.statusRequestTicks % 8 == 0
            if session.activationState == .activated, reachable, needsStatus || periodicRefresh {
                self.requestStatusSync()
            }
        }
    }

    func requestStatusSync() {
        guard let session, session.activationState == .activated, session.isReachable else {
            requestedStatus = false
            return
        }
        guard !requestedStatus else { return }
        requestedStatus = true
        session.sendMessage(["type": "requestStatus"], replyHandler: { [weak self] reply in
            DispatchQueue.main.async {
                guard let self else { return }
                if let mac = reply["macConnected"] as? Bool { self.macConnected = mac }
                if let state = reply["sessionState"] as? String { self.sessionState = state.isEmpty ? nil : state }
                if let name = reply["agentName"] as? String, !name.isEmpty { self.agentName = name }
                if let mode = reply["agentMode"] as? String, !mode.isEmpty { self.agentMode = mode }
                if let agentList = reply["agents"] as? [[String: String]] {
                    let parsed = agentList.compactMap { dict -> WatchAgent? in
                        guard let id = dict["id"], let name = dict["name"] else { return nil }
                        return WatchAgent(id: id, name: name)
                    }
                    if !parsed.isEmpty { self.agents = parsed }
                }
                if let activeId = reply["activeAgent"] as? String,
                   let idx = self.agents.firstIndex(where: { $0.id == activeId }) {
                    self.activeAgentIndex = idx
                }
                // 同步设备列表
                if let deviceList = reply["devices"] as? [[String: String]] {
                    let parsed = deviceList.compactMap { dict -> WatchDevice? in
                        guard let id = dict["id"], let name = dict["name"] else { return nil }
                        return WatchDevice(id: id, name: name, osType: dict["os"] ?? "mac")
                    }
                    if !parsed.isEmpty { self.devices = parsed }
                }
                if let activeDevId = reply["activeDevice"] as? String,
                   let idx = self.devices.firstIndex(where: { $0.id == activeDevId }) {
                    self.activeDeviceIndex = idx
                }
                self.applyModels(from: reply)
                if let lang = reply[WatchLanguageManager.syncKey] as? String {
                    WatchLanguageManager.shared.setLanguageFromPhone(lang)
                }
            }
        }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                self?.requestedStatus = false
            }
        })
    }

    // MARK: - Commands

    /// 发送文本命令。
    /// - Parameter conversationId: 指定对话（对话详情页发送时传入）。
    ///   带对话 id 时**不携带 agentId**——对话自带 Agent，
    ///   让 iPhone 端切换 Mac 的 activeAgent 是意外副作用；`nil` 保持旧行为。
    func sendCommand(_ text: String, conversationId: String? = nil) {
        guard let session else {
            DispatchQueue.main.async { self.commandState = .failed(LW("WatchConnectivity unsupported")) }
            return
        }
        guard session.activationState == .activated else {
            DispatchQueue.main.async { self.commandState = .failed(LW("iPhone App Not Connected")) }
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DispatchQueue.main.async { self.commandState = .failed(LW("Empty command")) }
            return
        }
        var payload: [String: Any] = [
            "type": "command",
            "text": trimmed,
            "content": trimmed
        ]
        if let conversationId, !conversationId.isEmpty {
            payload["conversationId"] = conversationId
        } else {
            payload["agentId"] = activeAgentID
        }
        DispatchQueue.main.async { self.commandState = .sending }

        // sendMessage 只在 iPhone App 处于前台时可用；
        // 不可达时退回 transferUserInfo（排队投递，会在 App 下次运行时送达）。
        guard session.isReachable else {
            session.transferUserInfo(payload)
            DispatchQueue.main.async { self.commandState = .sent(trimmed) }
            return
        }

        session.sendMessage(payload, replyHandler: { [weak self] _ in
            DispatchQueue.main.async {
                self?.commandState = .sent(trimmed)
                self?.lastError = nil
            }
        }, errorHandler: { [weak self] error in
            WatchLog.session.error("sendMessage failed, falling back to transferUserInfo: \(error.localizedDescription, privacy: .private)")
            session.transferUserInfo(payload)
            DispatchQueue.main.async {
                self?.commandState = .sent(trimmed)
            }
        })
    }

    // MARK: - WCSession Delegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.activationState = activationState
            self.reachable = session.isReachable
        }
        applyContext(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        applyContext(applicationContext)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.reachable = session.isReachable
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        applyCommandResult(message)
    }

    /// iPhone 在不可达时会用 transferUserInfo 排队回传结果，
    /// 由系统在 Watch App 下次运行时投递。
    /// 注意：不要给参数写默认值，`WCSessionDelegate` 是 @objc 协议，
    /// 带默认值的方法在见证协议要求时会有歧义。
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        applyCommandResult(userInfo)
    }

    /// 音频文件传输结束（成功或失败）。此时才能安全删除本地录音文件。
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let name = fileTransfer.file.fileURL.lastPathComponent
        guard pendingAudioFileNames.contains(name) else { return }
        pendingAudioFileNames.remove(name)
        audioTransfers.removeAll { $0 === fileTransfer }
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)

        DispatchQueue.main.async {
            if let error {
                WatchLog.audio.error("Audio transfer failed: \(error.localizedDescription, privacy: .private)")
                self.commandState = .failed(LW("Send failed: %@", error.localizedDescription))
            } else if case .sent = self.commandState {
                // 只在仍处于"已送出"时更新文案，
                // 避免覆盖已经到达的 commandResult 结果。
                self.commandState = .sent(LW("Audio delivered"))
            }
        }
    }

    /// 已处理命令结果的时间戳（UserDefaults 持久化）。
    /// applicationContext 会在每次会话激活时重放"最后一条结果"，
    /// 没有去重的话每次打开 App 都会震一下、刷一次。
    private static let lastResultTsKey = "BrewPing.Watch.lastCommandResultTs"

    /// 最近一条结果所属的对话。对话页用它判断"该不该由我来刷新"。
    @Published var lastResultConversationId: String?

    private func applyCommandResult(_ message: [String: Any]) {
        guard message["type"] as? String == "commandResult" else { return }
        let status = message["status"] as? String ?? ""
        let text = message["text"] as? String ?? ""
        let duration = message["duration"] as? Double
        let conversationId = message["conversationId"] as? String
        let ts = message["ts"] as? Double ?? 0

        // 去重：老结果（<= 已处理的最大时间戳）不再应用
        let seen = UserDefaults.standard.double(forKey: Self.lastResultTsKey)
        if ts > 0, ts <= seen { return }
        if ts > 0 {
            UserDefaults.standard.set(ts, forKey: Self.lastResultTsKey)
        }

        DispatchQueue.main.async {
            self.lastCommandDuration = duration
            self.lastResultConversationId = conversationId
            if status == "completed" || status == "completed_with_raw" {
                self.commandState = .completed(text)
                // 🎉 回复到了，无论用户停在哪个页面都给触觉反馈
                WKInterfaceDevice.current().play(.success)
            } else {
                self.commandState = .failed(text.isEmpty ? LW("Command failed") : text)
                WKInterfaceDevice.current().play(.notification)
            }
        }
    }

    // MARK: - Audio Commands

    /// 把录音文件发送到 iPhone 做语音识别。
    ///
    /// 使用 `transferFile` 而不是 `sendMessage`，原因有二：
    ///  1. `sendMessage` 的载荷上限约 65 KB，一段 10s+ 的 AAC 录音随时会超限
    ///     并返回 WCErrorCodePayloadTooLarge；
    ///  2. `sendMessage` 要求 iPhone App 正在前台（`isReachable`），
    ///     而"用手表发语音"的典型场景恰恰是手机在口袋里。
    ///     `transferFile` 会排队并在后台投递。
    /// 因此这里只要求会话已激活，不再要求 reachable。
    /// - Parameter conversationId: 指定对话；带对话时不携带 agentId（同 sendCommand）。
    func sendAudioCommand(fileURL: URL, duration: TimeInterval? = nil, conversationId: String? = nil) {
        guard let session else {
            try? FileManager.default.removeItem(at: fileURL)
            DispatchQueue.main.async { self.commandState = .failed(LW("WatchConnectivity unsupported")) }
            return
        }
        guard session.activationState == .activated else {
            try? FileManager.default.removeItem(at: fileURL)
            DispatchQueue.main.async { self.commandState = .failed(LW("iPhone App Not Connected")) }
            return
        }

        var metadata: [String: Any] = [
            "type": "audioCommand",
            "fileName": fileURL.lastPathComponent,
            "createdAt": Date().timeIntervalSince1970,
            "locale": Locale.current.identifier
        ]
        if let conversationId, !conversationId.isEmpty {
            metadata["conversationId"] = conversationId
        } else {
            metadata["agentId"] = activeAgentID
        }
        if let duration { metadata["duration"] = duration }

        let transfer = session.transferFile(fileURL, metadata: metadata)
        audioTransfers.append(transfer)
        pendingAudioFileNames.insert(fileURL.lastPathComponent)

        WatchLog.audio.info("Queued audio transfer \(fileURL.lastPathComponent, privacy: .private) reachable=\(session.isReachable, privacy: .public)")
        // 排队成功即视为已送出：transferFile 是排队式投递，
        // 若一直停在 .sending，手机长时间离线时 UI 会永久卡住。
        // 真正的失败在 session(_:didFinish:) 里降级为 .failed。
        DispatchQueue.main.async { self.commandState = .sent(LW("Audio sent")) }
    }

    // MARK: - Legacy

    func sendTest(text: String = "Hello from Watch") {
        guard let session else { return }
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["type": "test", "text": text], replyHandler: nil, errorHandler: nil)
        DispatchQueue.main.async { self.lastSentText = text }
    }
}
