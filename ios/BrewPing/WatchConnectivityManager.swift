import Foundation
import WatchConnectivity
import Combine
import Speech
import AVFoundation

final class WatchConnectivityManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchConnectivityManager()

    @Published var lastReceivedText: String?
    @Published var lastReceivedType: String?
    var currentOnline: Bool?
    var currentSessionState: String?
    var currentAgentName: String = "OpenCode"
    var currentAgentMode: String = "session"
    var currentAgentID: String = "opencode"
    var knownAgents: [[String: String]] = [
        ["id": "opencode", "name": "OpenCode"],
        ["id": "claude-code", "name": "Claude"],
        ["id": "codex", "name": "Codex"]
    ]
    var knownDevices: [[String: String]] = []
    var activeDeviceID: String = ""
    /// 当前 Agent 的可切换模型（由 ContentView 从 ModelStore 同步过来）。
    /// 与 agents 走同一条通道，手表不自己发请求。
    var knownModels: [[String: String]] = []
    var activeModelID: String = ""
    /// `knownModels` 对应的 Agent id。
    /// 手表据此判断"这份模型列表是否属于我当前选的 Agent" —— 模型是 per-Agent 的配置
    /// （Mac 端 `GET /api/agents/<agentId>/models`），切 Agent 后必须整份换掉，
    /// 否则会显示上一个 Agent 的模型。
    var knownModelsAgent: String = ""

    /// App 是否在前台（由 ContentView 按 `scenePhase` 维护）。
    /// 用于决定"收到手表语音后要不要在本机回放一遍"：
    /// 后台被唤醒时用户并不在看界面，突然外放只会让人困惑。
    var appIsActive = false

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func pushStatus(online: Bool, sessionStateRaw: String, agentName: String? = nil, agentMode: String? = nil) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        let activated = session.activationState == .activated
        let paired = session.isPaired
        let name = agentName ?? currentAgentName
        let mode = agentMode ?? currentAgentMode
        guard activated, paired else { return }
        do {
            var context: [String: Any] = [
                "macConnected": online,
                "sessionState": sessionStateRaw,
                "agentName": name,
                "agentMode": mode,
                "agents": knownAgents,
                "activeAgent": currentAgentID,
                "devices": knownDevices,
                "activeDevice": activeDeviceID,
                "models": knownModels,
                "activeModelId": activeModelID,
                "modelsAgent": knownModelsAgent,
                // 语言偏好：手表照抄 iPhone 的设置，避免两端各维护一份。
                LanguageManager.syncKey: UserDefaults.standard
                    .string(forKey: LanguageManager.storageKey) ?? AppLanguage.system.rawValue
            ]
            // 状态推送会整体覆盖 context —— 把最近命令结果（截断版）合并回去，
            // 否则手表端靠 applicationContext 恢复结果的兜底就失效了。
            if let result = truncatedResult() {
                context["lastCommandResult"] = result
            }
            try session.updateApplicationContext(context)
        } catch {
            BrewPingLog.watch.error("Status push failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// 用户刚在 iPhone 上换了语言时立刻推一次，不必等下一轮状态轮询。
    func pushLanguage() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired else { return }
        let value = UserDefaults.standard.string(forKey: LanguageManager.storageKey)
            ?? AppLanguage.system.rawValue
        do {
            var context = session.applicationContext
            context["macConnected"] = session.applicationContext["macConnected"] ?? false
            context[LanguageManager.syncKey] = value
            try session.updateApplicationContext(context)
        } catch {
            BrewPingLog.watch.error("Language push failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// 最近一条命令结果。applicationContext 兜底用：
    /// 手表 App 被杀 / session 未激活时，结果随 context 在手表下次激活时恢复。
    private var lastCommandResult: [String: Any]?

    func sendCommandResult(status: String, text: String, duration: Double? = nil, conversationId: String? = nil) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        var message: [String: Any] = [
            "type": "commandResult",
            "status": status,
            "text": text,
            // 手表用它判断"这条结果属于哪个对话"，只有匹配的对话页才自动刷新
            "ts": Date().timeIntervalSince1970
        ]
        if let duration { message["duration"] = duration }
        if let conversationId, !conversationId.isEmpty { message["conversationId"] = conversationId }
        lastCommandResult = message

        // Watch App 不在前台时 sendMessage 必然失败 → transferUserInfo 排队。
        // applicationContext 单键覆盖（"最后一条结果"语义），手表重启也能恢复 + 去重。
        guard session.isReachable else {
            session.transferUserInfo(message)
            pushResultContext(session)
            BrewPingLog.watch.info("Watch not reachable, queued command result: \(status, privacy: .public)")
            return
        }
        session.sendMessage(message, replyHandler: nil) { [weak self] error in
            BrewPingLog.watch.error("Command result push failed (\(error.localizedDescription, privacy: .private)), queuing instead")
            session.transferUserInfo(message)
        }
        pushResultContext(session)
    }

    /// 🚨 applicationContext 的结果副本**必须截断正文**：
    ///    context 上限约 65KB，长回复会让 updateApplicationContext 抛错，
    ///    连带 pushStatus 整体失败 → 手表拿不到 devices。
    private func truncatedResult() -> [String: Any]? {
        guard var result = lastCommandResult else { return nil }
        if let text = result["text"] as? String, text.count > 200 {
            result["text"] = String(text.prefix(200))
        }
        return result
    }

    /// 把最近结果合并进 applicationContext（保留状态推送的其它键）。
    private func pushResultContext(_ session: WCSession) {
        guard session.activationState == .activated, session.isPaired, let result = truncatedResult() else { return }
        var context = session.applicationContext
        context["lastCommandResult"] = result
        try? session.updateApplicationContext(context)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // session 刚激活：applicationContext 里可能还留着未送达的命令结果，
        // 这里补写一次（手表端 applyContext 会在激活时消费并去重）。
        if activationState == .activated { pushResultContext(session) }
        if let error {
            BrewPingLog.watch.error("WCSession activation error: \(error.localizedDescription, privacy: .private)")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        // 按 Apple 契约：这里只做会话状态转移，重新 activate 留给
        // sessionDidDeactivate（否则多 Watch 切换场景可能激活失败）。
    }

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleWatchMessage(message, replyHandler: nil)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handleWatchMessage(message, replyHandler: replyHandler)
    }

    /// Watch 在 `isReachable == false` 时改用 transferUserInfo 排队投递，这里接收。
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleWatchMessage(userInfo, replyHandler: nil)
    }

    /// 收到 Watch 传来的音频文件。
    ///
    /// 关键约束：`file.fileURL` 指向系统的临时位置，
    /// **本方法返回后系统就会删除该文件**，所以必须在这里同步搬走，
    /// 不能把 fileURL 直接交给异步的语音识别流程（否则识别必然失败）。
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        let type = metadata["type"] as? String ?? ""
        guard type == "audioCommand" else {
            BrewPingLog.watch.error("Ignoring unexpected file transfer type=\(type, privacy: .public)")
            return
        }

        let ext = file.fileURL.pathExtension.isEmpty ? "m4a" : file.fileURL.pathExtension
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch_audio_\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: file.fileURL, to: localURL)
        } catch {
            BrewPingLog.watch.error("Failed to persist incoming audio: \(error.localizedDescription, privacy: .private)")
            sendCommandResult(status: "failed", text: "Audio save failed")
            return
        }

        let agentId = metadata["agentId"] as? String
        let conversationId = metadata["conversationId"] as? String
        let localeId = metadata["locale"] as? String
        let sourceName = metadata["fileName"] as? String ?? file.fileURL.lastPathComponent
        let size = (try? localURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        BrewPingLog.watch.info("Audio file received \(sourceName, privacy: .private) (\(size, privacy: .public) bytes)")

        // 前台时把收到的语音原样回放一遍：
        // 这是用户唯一能"听到"录音确实完整送达的方式（识别结果只是文字）。
        // 后台唤醒不回放，避免用户看不到界面却突然外放。
        if appIsActive {
            WatchAudioPlayback.shared.play(localURL, label: sourceName)
        }

        transcribeAndForward(audioURL: localURL, agentId: agentId, localeIdentifier: localeId, conversationId: conversationId)
    }

    private func handleWatchMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?) {
        let type = message["type"] as? String ?? "unknown"
        if type == "switchDevice" {
            guard let deviceId = message["deviceId"] as? String else {
                replyHandler?(["ok": false, "error": "missing deviceId"])
                return
            }
            BrewPingLog.watch.info("Watch switching to device \(deviceId, privacy: .private)")
            DispatchQueue.main.async {
                DeviceStore.shared.setActive(deviceId)
            }
            replyHandler?(["ok": true, "type": "ack"])
            return
        }
        if type == "requestStatus" {
            BrewPingLog.watch.debug("Watch requested status")
            replyHandler?([
                "macConnected": currentOnline ?? false,
                "sessionState": currentSessionState ?? "",
                "agentName": currentAgentName,
                "agentMode": currentAgentMode,
                "agents": currentAgentList(),
                "activeAgent": currentActiveAgentID,
                "devices": knownDevices,
                "activeDevice": activeDeviceID,
                "models": knownModels,
                "activeModelId": activeModelID,
                "modelsAgent": knownModelsAgent,
                LanguageManager.syncKey: UserDefaults.standard
                    .string(forKey: LanguageManager.storageKey) ?? AppLanguage.system.rawValue
            ])
            return
        }
        if type == "requestConversations" {
            // WCSession 的 replyHandler 是可选的：没有就没人接结果，直接不取。
            guard let replyHandler else { return }
            fetchConversationsForWatch(replyHandler: replyHandler)
            return
        }
        if type == "requestConversation" {
            guard let conversationId = message["conversationId"] as? String, !conversationId.isEmpty else {
                replyHandler?(["ok": false, "error": "missing conversationId"])
                return
            }
            guard let replyHandler else { return }
            fetchConversationDetailForWatch(conversationId: conversationId, replyHandler: replyHandler)
            return
        }
        if type == "switchAgent" {
            guard let agentId = message["agentId"] as? String else {
                replyHandler?(["ok": false, "error": "missing agentId"])
                return
            }
            BrewPingLog.watch.info("Watch switching to agent \(agentId, privacy: .public)")
            replyHandler?(["ok": true, "type": "ack"])
            switchMacAgent(to: agentId)
            return
        }
        if type == "switchModel" {
            guard let modelId = message["modelId"] as? String else {
                replyHandler?(["ok": false, "error": "missing modelId"])
                return
            }
            // agentId 可省略：手表切换的是"当前 Agent 的模型"，缺省用当前值。
            let agentId = (message["agentId"] as? String) ?? currentAgentID
            BrewPingLog.watch.info("Watch switching model to \(modelId, privacy: .public)")
            replyHandler?(["ok": true, "type": "ack"])
            switchMacModel(to: modelId, agentId: agentId)
            return
        }
        if type == "command" {
            let text = (message["text"] as? String) ?? (message["content"] as? String) ?? ""
            let agentId = message["agentId"] as? String
            // 新版手表从**对话详情页**发送：带 conversationId 直达该对话，
            // 且不带 agentId（对话自带 Agent，切换 Mac 的 active Agent 是副作用）。
            let conversationId = message["conversationId"] as? String
            BrewPingLog.command.info("Command received from Watch, agent=\(agentId ?? "default", privacy: .public) conv=\(conversationId ?? "auto", privacy: .public)")
            replyHandler?(["ok": true, "type": "ack"])
            ensureAgentThenForward(text: text, agentId: agentId, conversationId: conversationId)
            return
        }
        if type == "audioCommand" {
            // 兼容旧版 Watch：把音频塞进 sendMessage 的字典里。
            // 该通道载荷上限约 65 KB，稍长的录音就会被系统拒绝，
            // 因此新版本已改用 transferFile（见 session(_:didReceive:)）。
            guard let audioData = message["audio"] as? Data, !audioData.isEmpty else {
                BrewPingLog.watch.error("audioCommand missing audio data (payload dropped or too large)")
                replyHandler?(["ok": false, "error": "no audio data"])
                sendCommandResult(status: "failed", text: "Audio payload missing or too large")
                return
            }
            let agentId = message["agentId"] as? String
            let conversationId = message["conversationId"] as? String
            BrewPingLog.watch.info("Legacy inline audio command (\(audioData.count, privacy: .public) bytes)")
            let localURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("watch_audio_\(UUID().uuidString).m4a")
            do {
                try audioData.write(to: localURL)
            } catch {
                BrewPingLog.watch.error("Failed to write audio: \(error.localizedDescription, privacy: .private)")
                replyHandler?(["ok": false, "error": "cannot persist audio"])
                sendCommandResult(status: "failed", text: "Audio save failed")
                return
            }
            replyHandler?(["ok": true, "type": "ack"])
            transcribeAndForward(audioURL: localURL, agentId: agentId, conversationId: conversationId)
            return
        }
        let text = message["text"] as? String ?? ""
        BrewPingLog.watch.debug("Received from Watch: \(text, privacy: .private)")
        CommandReceiver.shared.receive(type: .status, text: text)
        DispatchQueue.main.async {
            self.lastReceivedType = type
            self.lastReceivedText = text
        }
        replyHandler?(["ok": true, "type": "ack"])
    }

    // MARK: - Watch 对话浏览（手表只发意图，抓取由 iPhone 代劳）

    /// Watch 端载荷上限约 65 KB，转发的目录/转录都要先做裁剪。
    /// 目录**只取最近一次对话**（用户指定）；转录最多取最近 20 条、每条 800 字。
    private static let watchConversationLimit = 1
    private static let watchMessageLimit = 20
    private static let watchMessageTextLimit = 800

    /// 当前生效设备的对话目录。
    /// `replyHandler` 在 HTTP 返回后才调用 —— WCSession 的回复通道容忍数秒延迟，
    /// 手表侧另挂 10s 看门狗兜底。
    private func fetchConversationsForWatch(replyHandler: @escaping ([String: Any]) -> Void) {
        onMainWithActiveDevice { device in
            guard let device,
                  var request = BrewPingHTTP.request(device: device, path: "/api/conversations", timeout: 10) else {
                BrewPingLog.watch.info("Watch requested conversations but no active device")
                replyHandler(["ok": false, "error": "no device"])
                return
            }

            Task {
                do {
                    let (data, response) = try await BrewPingHTTP.session.data(for: request)
                    if BrewPingHTTP.isUnauthorized(response) {
                        replyHandler(["ok": false, "error": "not paired"])
                        return
                    }
                    guard (response as? HTTPURLResponse)?.statusCode == 200,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let list = json["conversations"] as? [[String: Any]] else {
                        replyHandler(["ok": false, "error": "unavailable"])
                        return
                    }

                    // 只保留手表要显示的字段：payload 越小越不容易撞 65 KB 上限。
                    // 归档对话不在手表目录里展示（小屏保持列表干净，与桌面端主列表一致）。
                    let active = list
                        .filter { ($0["archived"] as? Bool) != true }
                        .sorted { ($0["updatedAtMs"] as? Double ?? 0) > ($1["updatedAtMs"] as? Double ?? 0) }
                    let compact = active.prefix(Self.watchConversationLimit).map { item -> [String: Any] in
                        [
                            "id": item["id"] as? String ?? "",
                            "title": item["title"] as? String ?? "",
                            "agentId": item["agentId"] as? String ?? "",
                            "messageCount": item["messageCount"] as? Int ?? 0,
                            "updatedAtMs": item["updatedAtMs"] as? Double ?? 0,
                            "isPinned": item["isPinned"] as? Bool ?? false
                        ]
                    }
                    BrewPingLog.watch.info("Conversations for Watch: \(compact.count, privacy: .public) of \(active.count, privacy: .public)")
                    replyHandler(["ok": true, "conversations": compact])
                } catch {
                    BrewPingLog.watch.error("Conversations for Watch failed: \(error.localizedDescription, privacy: .private)")
                    replyHandler(["ok": false, "error": "network"])
                }
            }
        }
    }

    /// 单条对话的转录（手表迷你对话页）。
    private func fetchConversationDetailForWatch(conversationId: String, replyHandler: @escaping ([String: Any]) -> Void) {
        onMainWithActiveDevice { device in
            guard let device,
                  var request = BrewPingHTTP.request(
                    device: device,
                    path: "/api/conversations/\(conversationId)",
                    timeout: 10
                  ) else {
                replyHandler(["ok": false, "error": "no device"])
                return
            }

            Task {
                do {
                    let (data, response) = try await BrewPingHTTP.session.data(for: request)
                    if BrewPingHTTP.isUnauthorized(response) {
                        replyHandler(["ok": false, "error": "not paired"])
                        return
                    }
                    guard (response as? HTTPURLResponse)?.statusCode == 200,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          // 注意：响应体是 `{ "success":…, "conversation": {…} }`，
                          // 转录在 `conversation` 里，不在顶层。
                          let conversation = json["conversation"] as? [String: Any],
                          let messages = conversation["messages"] as? [[String: Any]] else {
                        replyHandler(["ok": false, "error": "unavailable"])
                        return
                    }

                    // 最近 N 条 + 每条截断：手表小屏看不了长文，也控住 payload 体积。
                    let tail = messages.suffix(Self.watchMessageLimit)
                    let compact = tail.map { item -> [String: Any] in
                        let text = item["text"] as? String ?? ""
                        return [
                            "role": item["role"] as? String ?? "assistant",
                            "text": String(text.prefix(Self.watchMessageTextLimit)),
                            "createdAtMs": item["createdAtMs"] as? Double ?? 0
                        ]
                    }
                    BrewPingLog.watch.info("Conversation for Watch: \(compact.count, privacy: .public) messages")
                    replyHandler([
                        "ok": true,
                        "id": conversationId,
                        "title": conversation["title"] as? String ?? "",
                        "messages": compact,
                        "truncated": messages.count > tail.count
                    ])
                } catch {
                    BrewPingLog.watch.error("Conversation for Watch failed: \(error.localizedDescription, privacy: .private)")
                    replyHandler(["ok": false, "error": "network"])
                }
            }
        }
    }

    // MARK: - Active Device Resolution

    /// 在主线程读取当前生效设备。
    /// Watch 回调来自 WCSession 的后台队列，而 DeviceStore 是 @MainActor，
    /// 因此所有对 DeviceStore 的读取都统一切回主线程。
    private func onMainWithActiveDevice(_ body: @escaping (ManagedDevice?) -> Void) {
        Task { @MainActor in
            body(DeviceStore.shared.activeDevice)
        }
    }

    /// 切换 Mac 端的 active Agent
    private func switchMacAgent(to agentId: String) {
        onMainWithActiveDevice { device in
            guard let device,
                  var request = BrewPingHTTP.request(
                    device: device,
                    path: "/api/agents/\(agentId)/switch",
                    method: "POST",
                    timeout: 10
                  ) else {
                BrewPingLog.watch.info("No active device, skip switch to \(agentId, privacy: .public)")
                return
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            Task { [weak self] in
                do {
                    let (data, response) = try await BrewPingHTTP.session.data(for: request)
                    if BrewPingHTTP.isUnauthorized(response) {
                        BrewPingLog.watch.error("Agent switch rejected: device is not paired")
                        return
                    }
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let success = json?["success"] as? Bool ?? false
                    BrewPingLog.watch.info("Switch to \(agentId, privacy: .public) -> \(success ? "OK" : "failed", privacy: .public)")
                    if success {
                        // 模型是 per-Agent 的配置：Agent 一换，模型列表必须整份跟着换。
                        // 这里立刻拉取新 Agent 的模型并推给手表，否则手表会继续显示
                        // 上一个 Agent 的模型，直到下一轮 2s 轮询才（可能）纠正。
                        await self?.refreshModelsAndPush(for: agentId, device: device)
                    }
                } catch {
                    BrewPingLog.watch.error("Switch agent error: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }

    /// Agent 切换成功后，立刻拉取该 Agent 的模型列表并推给手表。
    ///
    /// `ModelStore.refresh` 内部按 `device/agentID` 去重，所以这里必然会真正发请求；
    /// 拉完立即走 `pushStatus` 推送，把手表的模型区从"上一个 Agent 的"换成"当前 Agent 的"。
    ///
    /// 标 `@MainActor`：`ModelStore` 是 `@MainActor` 隔离的，属性只能在主线程读。
    @MainActor
    private func refreshModelsAndPush(for agentId: String, device: ManagedDevice) async {
        // 关键：先把本地"当前 Agent"同步成新值，再推送。
        // `currentAgentID` 平时只在 2s 轮询的 `refreshStatus()` 里更新，
        // 所以刚切完时它还是**旧值**；直接 pushStatus 会把旧 activeAgent 推给手表，
        // 手表刚切过去就被弹回上一个 Agent（2026-09-11 实际踩到）。
        currentAgentID = agentId
        if let name = knownAgents.first(where: { $0["id"] == agentId })?["name"] {
            currentAgentName = name
        }
        currentAgentMode = (agentId == "opencode") ? "session" : "headless"

        await ModelStore.shared.refresh(device: device, agentID: agentId)
        knownModels = ModelStore.shared.models.map { ["id": $0.id, "name": $0.name] }
        activeModelID = ModelStore.shared.activeModelID ?? ""
        knownModelsAgent = agentId
        pushStatus(online: currentOnline ?? false, sessionStateRaw: currentSessionState ?? "")

        // 通知 iPhone 界面立即刷新 Agent 列表（刷新列表里的 "Default" 标记）。
        // App 在后台时监听不生效，由 5s 状态轮询的变化检测兜底。
        NotificationCenter.default.post(name: .watchDidSwitchAgent, object: nil)
    }

    /// 切换 Mac 端当前 Agent 的默认模型（`POST /api/agents/models/default`）。
    /// 走的是与 Agent 切换同一条通道：手表只发意图，真正落地由 iPhone 转给 Mac。
    private func switchMacModel(to modelId: String, agentId: String) {
        onMainWithActiveDevice { device in
            guard let device,
                  var request = BrewPingHTTP.request(
                    device: device,
                    path: "/api/agents/models/default",
                    method: "POST",
                    timeout: 10
                  ) else {
                BrewPingLog.watch.info("No active device, skip model switch")
                return
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "agentId": agentId,
                "modelId": modelId
            ])

            Task {
                do {
                    let (data, response) = try await BrewPingHTTP.session.data(for: request)
                    if BrewPingHTTP.isUnauthorized(response) {
                        BrewPingLog.watch.error("Model switch rejected: device is not paired")
                        return
                    }
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let success = json?["success"] as? Bool ?? false
                    BrewPingLog.watch.info("Model switch to \(modelId, privacy: .public) -> \(success ? "OK" : "failed", privacy: .public)")
                    // 让 iPhone 界面与手表同步：ModelStore 重新拉一次以刷新高亮。
                    await ModelStore.shared.refresh(device: device, agentID: agentId, force: true)
                } catch {
                    BrewPingLog.watch.error("Switch model error: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }

    /// 确保 Mac 端 active Agent 匹配后再发命令
    private func ensureAgentThenForward(text: String, agentId: String?, conversationId: String? = nil) {
        let forward = {
            DispatchQueue.main.async {
                CommandReceiver.shared.receive(type: .command, text: text, conversationId: conversationId)
            }
        }

        // 指定了对话（手表对话页发送）时不做 Agent 预切：
        // 对话自带 Agent，切换 Mac 的 activeAgent 对用户是意外的副作用。
        if conversationId != nil {
            forward()
            return
        }

        onMainWithActiveDevice { device in
            guard let agentId, let device,
                  var switchReq = BrewPingHTTP.request(
                    device: device,
                    path: "/api/agents/\(agentId)/switch",
                    method: "POST",
                    timeout: 10
                  ) else {
                // 未指定 Agent 或没有可用设备：仍然转发，由上层决定如何提示
                forward()
                return
            }
            switchReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

            Task {
                do {
                    let _ = try await BrewPingHTTP.session.data(for: switchReq)
                } catch {
                    BrewPingLog.watch.error("Pre-switch failed: \(error.localizedDescription, privacy: .private)")
                }
                // 无论切换是否成功，都转发命令
                forward()
            }
        }
    }

    /// 当前 agent 列表（同步到 Watch）
    private func currentAgentList() -> [[String: String]] {
        return knownAgents
    }

    private var currentActiveAgentID: String {
        return currentAgentID
    }

    // MARK: - Speech Permission

    /// 语音识别权限必须在**前台**拿到。
    ///
    /// App 被 WCSession 在后台唤醒时代理不了系统授权弹窗，
    /// 若此时 `authorizationStatus` 还是 `.notDetermined`，
    /// `recognitionTask` 会立刻失败 —— 手表只会看到 "Recognition failed"，无从排查。
    /// 因此在前台启动时主动请求一次，把权限提前确定下来。
    func requestSpeechAuthorizationIfNeeded() {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else {
            BrewPingLog.audio.debug("Speech authorization already = \(status.rawValue, privacy: .public)")
            return
        }
        SFSpeechRecognizer.requestAuthorization { newStatus in
            BrewPingLog.audio.info("Speech authorization request -> \(newStatus.rawValue, privacy: .public)")
        }
    }

    // MARK: - Speech Recognition

    /// 一轮识别所需的全部对象。
    /// 必须保持强引用：`SFSpeechRecognizer` / `SFSpeechRecognitionTask`
    /// 若在识别过程中被释放，识别会被静默取消，
    /// 表现为"文件已送达但永远没有结果"。
    private final class RecognitionSession {
        let recognizer: SFSpeechRecognizer
        let request: SFSpeechURLRecognitionRequest
        var task: SFSpeechRecognitionTask?

        init(recognizer: SFSpeechRecognizer, request: SFSpeechURLRecognitionRequest) {
            self.recognizer = recognizer
            self.request = request
        }
    }

    /// 按轮次（token）保存，而不是单槽位保存：
    /// 连续模式下多段录音可能并发识别，单槽位会让先结束的那轮
    /// 把仍在识别中的 recognizer 一起释放掉。
    private var activeRecognitions: [UUID: RecognitionSession] = [:]

    /// 把 Watch 传来的 `locale`（如 `zh-Hant-TW`）对到 `SFSpeechRecognizer` 真正支持的 locale 上。
    ///
    /// 为什么不能直接 `SFSpeechRecognizer(locale: Locale(identifier: raw))`：
    ///  1. Watch 端 `Locale.current.identifier` 常带脚本子标签（`zh-Hans-CN`），
    ///     而 `supportedLocales()` 里只有 `zh-CN`，直接构造返回 nil，
    ///     旧代码于是静默回退 `en-US` —— 中文用户说完只会得到 "No speech detected"；
    ///  2. `supportedLocales()` 是 `Set`，`first(where:)` 的取用顺序不确定，
    ///     同一段语音在不同运行里可能被送进不同语言的模型。
    /// 所以这里改成「先排序、再打分」：结果确定，且优先挑区域 / 文字系统一致的候选。
    ///
    /// 子标签全部手工拆解，不用 `Locale.languageCode/script/region`：
    /// 那套新 API 的可用性在各平台不一致，而这里的需求用字符串拆解就够了，且可离线实测。
    private func makeRecognizer(preferredIdentifier: String?) -> SFSpeechRecognizer? {
        // 排序消除 Set 遍历顺序的不确定性
        let supported = SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }

        func bestMatch(_ rawIdentifier: String) -> SFSpeechRecognizer? {
            let normalized = normalizeLocaleIdentifier(rawIdentifier)
            let wanted = localeSubtags(of: normalized)
            guard !wanted.language.isEmpty else { return nil }
            let wantedScript = effectiveScript(language: wanted.language, script: wanted.script, region: wanted.region)

            var best: (score: Int, locale: Locale)?
            for candidate in supported {
                let id = candidate.identifier.lowercased()
                let info = localeSubtags(of: id)
                guard info.language == wanted.language else { continue }
                var score = 10                                                          // 同语言即可用
                if id == normalized { score += 100 }                                    // 完全一致
                if let wantedRegion = wanted.region, info.region == wantedRegion { score += 40 }  // 同区域
                if let wantedScript,
                   effectiveScript(language: info.language, script: info.script, region: info.region) == wantedScript {
                    score += 20                                                         // 同文字系统
                }
                if best == nil || score > best!.score { best = (score, candidate) }
            }
            // candidate 来自 supportedLocales()，构造必然成功；用 flatMap 避免强解包
            return best.flatMap { SFSpeechRecognizer(locale: $0.locale) }
        }

        if let preferredIdentifier, let recognizer = bestMatch(preferredIdentifier) {
            return recognizer
        }
        // 请求的语言没有对应模型时退化到设备语言，而不是无脑 en-US。
        for language in Locale.preferredLanguages {
            if let recognizer = bestMatch(language) { return recognizer }
        }
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// `zh_Hans_CN` → `zh-hans-cn`
    private func normalizeLocaleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// 拆 BCP-47 子标签。语言码 2~3 位；脚本 4 位字母；区域 2 位字母或 3 位数字。
    private func localeSubtags(of identifier: String) -> (language: String, script: String?, region: String?) {
        let parts = normalizeLocaleIdentifier(identifier).split(separator: "-").map(String.init)
        guard let language = parts.first, !language.isEmpty else { return ("", nil, nil) }
        // 首段是 4 位纯字母说明标识符本身就畸形（如 `hans-CN`），不要拿它当语言
        if language.count == 4, language.allSatisfy({ $0.isLetter }) { return ("", nil, nil) }

        var script: String?
        var region: String?
        for part in parts.dropFirst() {
            if part.count == 4, part.allSatisfy({ $0.isLetter }) {
                if script == nil { script = part }
            } else if (part.count == 2 && part.allSatisfy({ $0.isLetter }))
                        || (part.count == 3 && part.allSatisfy({ $0.isNumber })) {
                if region == nil { region = part }
            }
        }
        return (language, script, region)
    }

    /// 有效文字系统：标识符里显式写了就用显式的，否则按语言 + 区域补一个。
    /// `zh-TW` / `zh-HK` / `zh-MO` 都不带脚本子标签，但它们实际是繁体 ——
    /// 不补这一步，繁体用户会被配到简体模型 `zh-CN` 上。
    private func effectiveScript(language: String, script: String?, region: String?) -> String? {
        if let script { return script }
        guard language == "zh" else { return nil }
        switch region {
        case "tw", "hk", "mo": return "hant"
        default: return nil
        }
    }

    /// 将 Watch 发来的音频文件转为文字，然后走已有的 command 链路。
    /// `audioURL` 必须是已经落在本 App 临时目录、不会被系统回收的文件。
    private func transcribeAndForward(audioURL: URL, agentId: String?, localeIdentifier: String? = nil, conversationId: String? = nil) {
        // 权限先行：否则后台唤醒时识别必然失败，且错误信息没有指向性。
        //
        // 🚨 权限**未决**时在这里按需请求，而不是 App 启动时（旧行为）：语音指令本身就是
        // 用户的直接动作，此刻弹窗有上下文；放在启动期会与「进设备页的本地网络弹窗」
        // 「点扫码的相机弹窗」连成三连弹。仅前台可弹窗，后台唤醒只能照旧失败。
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined, appIsActive {
            requestSpeechAuthorizationIfNeeded()
            BrewPingLog.audio.info("Speech authorization requested on demand")
            try? FileManager.default.removeItem(at: audioURL)
            sendCommandResult(status: "failed", text: "Speech recognition permission requested — please allow it, then try again.")
            return
        }
        guard speechStatus == .authorized else {
            BrewPingLog.audio.error("Speech recognition not authorized (status=\(speechStatus.rawValue, privacy: .public))")
            try? FileManager.default.removeItem(at: audioURL)
            sendCommandResult(status: "failed", text: "Speech recognition not authorized")
            return
        }

        guard let recognizer = makeRecognizer(preferredIdentifier: localeIdentifier) else {
            BrewPingLog.audio.error("No speech recognizer available for locale \(localeIdentifier ?? "auto", privacy: .private)")
            try? FileManager.default.removeItem(at: audioURL)
            sendCommandResult(status: "failed", text: "Speech recognition not available")
            return
        }
        guard recognizer.isAvailable else {
            BrewPingLog.audio.error("Speech recognizer not currently available (locale=\(recognizer.locale.identifier, privacy: .public))")
            try? FileManager.default.removeItem(at: audioURL)
            sendCommandResult(status: "failed", text: "Speech recognition not available")
            return
        }
        BrewPingLog.audio.info("Recognizer locale = \(recognizer.locale.identifier, privacy: .public)")

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.taskHint = .dictation
        request.shouldReportPartialResults = false

        let recognition = RecognitionSession(recognizer: recognizer, request: request)
        let token = UUID()
        activeRecognitions[token] = recognition

        let started = Date()
        recognition.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let error {
                BrewPingLog.audio.error("Speech recognition error: \(error.localizedDescription, privacy: .private)")
                self.activeRecognitions.removeValue(forKey: token)
                try? FileManager.default.removeItem(at: audioURL)
                self.sendCommandResult(status: "failed", text: "Recognition failed: \(error.localizedDescription)")
                return
            }

            guard let result, result.isFinal else { return }

            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            let elapsed = Date().timeIntervalSince(started)
            // 转写结果属于用户内容，标记 .private。
            BrewPingLog.audio.info("Recognized in \(String(format: "%.1f", elapsed), privacy: .public)s: \(text, privacy: .private)")

            self.activeRecognitions.removeValue(forKey: token)
            try? FileManager.default.removeItem(at: audioURL)

            guard !text.isEmpty else {
                self.sendCommandResult(status: "failed", text: "No speech detected")
                return
            }

            // 确保 Agent 匹配后转发命令（对话页来的命令直达该对话）
            DispatchQueue.main.async {
                self.ensureAgentThenForward(text: text, agentId: agentId, conversationId: conversationId)
            }
        }
    }
}

// MARK: - WatchAudioPlayback

/// 把 Watch 传来的录音在本机回放一次。
///
/// 目的很窄：让用户能"听见"录音确实完整送达了。
/// 识别结果只是文字，无法反映"录到了什么"，音量太小、录串了都看不出来。
///
/// 只在 App 前台播放（由调用方判断），后台唤醒不出声。
/// 播放器持有已打开的 file descriptor，因此识别流程随后删除该文件
/// 不会打断播放（POSIX 下 unlink 已打开的文件是安全的）。
final class WatchAudioPlayback: NSObject, AVAudioPlayerDelegate {
    static let shared = WatchAudioPlayback()

    private var player: AVAudioPlayer?

    private override init() {
        super.init()
    }

    func play(_ url: URL, label: String) {
        do {
            // .ambient：与其他 App 音频共存、跟随静音开关，不会打断用户正在听的东西。
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default)
            try session.setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            self.player = player          // 必须强引用，否则播放会被立刻中断
            player.play()
            BrewPingLog.audio.debug("Playing back watch audio \(label, privacy: .private)")
        } catch {
            BrewPingLog.audio.error("Audio playback skipped: \(error.localizedDescription, privacy: .private)")
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        BrewPingLog.audio.debug("Audio playback finished (ok=\(flag, privacy: .public))")
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        BrewPingLog.audio.error("Audio playback decode error: \(error?.localizedDescription ?? "unknown", privacy: .private)")
    }
}

extension Notification.Name {
    /// 手表切换了 Mac 端 Agent。iPhone 界面据此**立即**刷新 Agent 列表，
    /// 让列表里的 "Default" 标记跟上（否则要等下一轮 5s 轮询）。
    static let watchDidSwitchAgent = Notification.Name("BrewPing.WatchDidSwitchAgent")
}
