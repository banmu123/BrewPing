import Foundation
import Combine

enum MessageType {
    case status
    case command

    static func from(_ raw: String?) -> MessageType {
        raw == "command" ? .command : .status
    }
}

// `CommandPhase` 与 `CommandChannel` 已抽到 `Sources/Protocol/CommandLifecycle.swift`：
// 纯状态机，iOS app 直接编译，SwiftPM 侧有单测覆盖（见 CommandLifecycleTests）。

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
    /// `conversationId` 为 `nil` = 不指定对话（沿桌面端三层回落），旧行为不变。
    var onCommand: ((String, String?) -> Void)?

    private init() {}

    func receive(type: MessageType, text: String, conversationId: String? = nil) {
        // 命令正文属于用户内容，一律标记 .private（Release 下由系统抹除）。
        BrewPingLog.command.debug("Received \(String(describing: type), privacy: .public) text=\(text, privacy: .private)")
        guard type == .command, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.main.async {
            self.lastCommandText = text
            self.lastCommandReceivedAt = Date()
            self.lastCommandStatus = "received"
            self.lastCommandID = UUID()
            BrewPingLog.command.debug("Command stored at \(self.lastCommandReceivedAt ?? Date(), privacy: .public)")
            self.onCommand?(text, conversationId)
        }
    }
}

// MARK: - API Models（命令提交引擎专用）

struct SubmitResponse: Decodable {
    let success: Bool?
    let commandId: String?
    let sessionId: String?
    let status: String?
    let approval: PendingApprovalInfo?
    let error: String?
}

/// 一条危险命中的机器可读标识 + 命中的原始片段。
/// `code` 用于本地化文案，`detail` 给用户看具体上下文。
struct ApprovalReasonInfo: Decodable, Hashable {
    let code: String?
    let detail: String?
}

/// 一条等待用户确认的命令（Mac 端挂起，iOS 端弹窗）。
struct PendingApprovalInfo: Decodable, Identifiable {
    let id: String?
    let text: String?
    let reasons: [ApprovalReasonInfo]?

    /// 用户可读的危险原因文案。按 code 本地化，未知 code 兜底显示 detail。
    func localizedReasons() -> [String] {
        guard let reasons else { return [] }
        return reasons.compactMap { reason in
            guard let code = reason.code else { return reason.detail }
            let localized = L("danger.\(code)")
            // L 查不到 key 时原样返回 key 本身，此时退回 detail。
            if localized == "danger.\(code)" {
                return reason.detail ?? code
            }
            return localized
        }
    }
}

/// `POST /api/approvals/:id` 的响应。
struct ApprovalDecisionResponse: Decodable {
    let success: Bool?
    let status: String?
    let commandId: String?
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

/// `GET /api/approvals` 的最小解码：只关心还有哪些审批在挂起。
private struct PendingApprovalsResponse: Decodable {
    struct Item: Decodable {
        let id: String?
    }
    let approvals: [Item]?
}

/// `GET /api/approvals/{id}` 的解码：一条审批的终态，含实际执行产生的 commandId。
///
/// 这是「审批 → 命令」的**确定性**关联来源。旧实现靠对话转录里最新出现的
/// commandId 推断归属，同一对话里别的设备发一条命令就会认错。
private struct ApprovalOutcomeResponse: Decodable {
    let status: String?
    let commandId: String?
    let conversationId: String?
    let error: String?
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
///
/// 并发规则集中在 `CommandChannel`（`Sources/Protocol/CommandLifecycle.swift`）：
/// **一条命令没进终态，通道就占用**，iPhone 与 Watch 走同一道闸门。
@MainActor
final class CommandSubmitter: ObservableObject {
    static let shared = CommandSubmitter()

    /// 提交通道 + 当前命令的跟踪状态。用 `@Published` 让 SwiftUI 跟随变化。
    @Published private var channel = CommandChannel()
    @Published private(set) var lastDuration: Double?
    @Published private(set) var lastFailureReason: String?
    @Published private(set) var lastModelId: String?
    /// 当前等待用户确认的命令（Mac 端挂起）。非 nil 时 iPhone 弹确认窗。
    @Published private(set) var pendingApproval: PendingApprovalInfo?
    /// 关窗后仍保留的审批内容：用户误关时可以从提示条重新打开，不必去电脑上处理。
    private var trackedApproval: PendingApprovalInfo?
    /// 正在提交审批决定（防止连点重复 POST）。
    @Published private(set) var isDeciding = false

    /// 对外只读的阶段（UI 与 `.onChange` 都用它）。
    var phase: CommandPhase { channel.phase }
    /// 通道是否被占用：任何提交入口都必须先看它。
    var isBusy: Bool { channel.isBusy }

    private var pollTask: Task<Void, Never>?
    /// 挂起的命令是否来自 Watch：决定批准执行后的结果要不要回传手表。
    private var pendingFromWatch = false
    /// 当前提交的目标对话（Watch 端用它判断"这条结果是不是我这个对话的"）。
    private var activeConversationId: String?
    /// 进入 pending_approval 时桌面端返回的 commandId（当前服务端**不返回**，
    /// 保留是为了兼容将来可能返回值的老/新实现）。
    private var pendingCommandId: String?

    /// 关窗后跟踪审批的上限。桌面端 `ApprovalGate` 的 TTL 是 300s，这里留 30s 余量。
    private static let approvalTrackTimeout: TimeInterval = 330
    /// 关窗后查询审批终态的间隔。这个轮询只在「用户关掉了确认窗」时运行，
    /// 用户可能正在电脑上点批准，所以取 3s 让结果尽快回流。
    private static let approvalTrackInterval: UInt64 = 3_000_000_000

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
        CommandReceiver.shared.onCommand = { text, conversationId in
            Task { @MainActor in
                // 返回值忽略：手表来源被拒绝时 submit 内部会回一条失败终态。
                _ = CommandSubmitter.shared.submit(text: text, fromWatch: true, conversationId: conversationId)
            }
        }
        BrewPingLog.command.info("CommandSubmitter bootstrapped")
    }

    /// 取消当前轮询但保留已展示的结果（切换设备/会话时使用）。
    func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 取消轮询并清空结果展示。
    ///
    /// 会换掉 `runToken`：仍在飞的异步回调发现自己过期后不会再写 UI，
    /// 这是"切设备后旧请求返回不能覆盖新设备状态"的保证。
    func reset() {
        cancelPolling()
        channel.reset()
        lastDuration = nil
        lastFailureReason = nil
        lastModelId = nil
        pendingApproval = nil
        trackedApproval = nil
        pendingCommandId = nil
        isDeciding = false
    }

    /// 提交一条文本命令。
    ///
    /// - Returns: 是否**被通道接受**。`false` 表示有命令在飞（或没有可用设备），
    ///   调用方必须保留输入草稿并给出反馈，不能静默丢弃。
    /// - Parameters:
    ///   - text: 命令正文。
    ///   - fromWatch: 为 `true` 时表示命令来自手表，最终结果需要通过 WCSession 回传。
    ///   - conversationId: 目标对话 id（对话详情页发送时传入）。`nil` = 沿用桌面端
    ///     三层回落（显式对话 → agent → 当前 active），**旧行为完全不变**
    ///     （桌面端 `MessageBody.conversationId` 是 `#[serde(default)]`）。
    @discardableResult
    func submit(text: String, fromWatch: Bool, conversationId: String? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // 🚨 唯一的并发闸门：通道被占用（发送中 / 等审批 / 执行中）时拒绝新命令。
        // 不能只靠 UI 禁用按钮 —— Watch、深链、双击都可能绕过界面。
        // Watch 来源被拒绝时必须回一条终态，否则手表会永远停在 Sent。
        guard let token = channel.begin() else {
            BrewPingLog.command.info("Submit dropped: another command is in flight")
            if fromWatch {
                WatchConnectivityManager.shared.sendCommandResult(
                    status: "failed",
                    text: L("Another command is still running. Try again after it finishes."),
                    duration: nil,
                    conversationId: conversationId
                )
            }
            return false
        }

        guard let device = DeviceStore.shared.activeDevice, device.baseURL != nil else {
            fail(with: L("No Mac connected. Add a device first."), fromWatch: fromWatch)
            return false
        }

        cancelPolling()
        lastDuration = nil
        lastFailureReason = nil
        lastModelId = nil
        pendingApproval = nil
        trackedApproval = nil
        pendingCommandId = nil
        pendingFromWatch = fromWatch
        activeConversationId = conversationId

        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.post(
                text: trimmed,
                device: device,
                fromWatch: fromWatch,
                conversationId: conversationId,
                token: token
            )
        }
        return true
    }

    /// 用户对挂起的命令做出决定。`action` 取 `approve` / `deny` / `always_approve`。
    func decide(action: String) {
        guard !isDeciding,
              let approval = pendingApproval, let id = approval.id, !id.isEmpty else { return }
        let fromWatch = pendingFromWatch
        guard let device = DeviceStore.shared.activeDevice, device.baseURL != nil else {
            pendingApproval = nil
            fail(with: L("No Mac connected. Add a device first."), fromWatch: fromWatch)
            return
        }
        isDeciding = true
        let token = channel.runToken
        // 🚨 decision 之后的轮询必须挂在 pollTask 上 —— 否则 reset()/cancelPolling()
        // 取消不掉，会和下一条命令的轮询并存、交替写状态。
        pollTask = Task { [weak self] in
            await self?.postDecision(
                id: id, action: action, device: device,
                fromWatch: fromWatch, token: token
            )
        }
    }

    /// 用户手动关闭确认窗（不点任何按钮）：命令继续在 Mac 端挂起，直到服务端超时。
    /// 不自动 deny、也不自动执行 —— 缺席不表态，留给服务端兜底。
    ///
    /// 🚨 关窗**不等于**命令结束：通道仍被这次跟踪占用（`.trackingApproval`），
    /// 直到服务端给出结论或审批超时。否则新命令会把旧命令变成孤儿：
    /// ① Watch 端永远停在 Sent；② 服务端超时后 UI 也无感知。
    func clearPendingApproval() {
        // 留住审批内容：误关弹窗时还能从输入框上方的提示条重新打开。
        if let approval = pendingApproval { trackedApproval = approval }
        pendingApproval = nil
        // 正在提交决定时不要抢：等 postDecision 收敛。
        guard !isDeciding, channel.phase == .awaitingApproval else { return }

        channel.markTrackingApproval()
        let token = channel.runToken
        let fromWatch = pendingFromWatch
        let approvalID = channel.approvalID

        guard let device = DeviceStore.shared.activeDevice, device.baseURL != nil else {
            fail(with: L("No Mac connected. Add a device first."), fromWatch: fromWatch)
            return
        }

        if let commandId = pendingCommandId, !commandId.isEmpty {
            // 兼容：某些实现会在 pending 响应里带 commandId，有就直接轮询它。
            pollTask = Task { [weak self] in
                await self?.poll(commandId: commandId, device: device, fromWatch: fromWatch, token: token)
            }
        } else if let approvalID, !approvalID.isEmpty {
            pollTask = Task { [weak self] in
                await self?.trackApprovalResolution(
                    approvalID: approvalID,
                    device: device,
                    fromWatch: fromWatch,
                    token: token
                )
            }
        } else {
            // 既没有 commandId 也没有审批 id：无法跟踪，明确收敛而不是留着转圈。
            fail(with: L("Approval ended without a result. Check the conversation on your Mac."), fromWatch: fromWatch)
        }
    }

    /// 关窗后重新打开确认弹窗。
    ///
    /// 命令仍挂在桌面端，通道也仍被占用 —— 这里只是把决定权交回用户，
    /// 不改变任何服务端状态。
    func reopenPendingApproval() {
        guard channel.phase == .trackingApproval, let approval = trackedApproval else { return }
        cancelPolling()   // 暂停"等审批被解决"的轮询，改由用户决定
        pendingApproval = approval
        channel.markAwaitingApproval(approvalID: approval.id)
    }

    // MARK: - Internals

    private func postDecision(
        id: String, action: String, device: ManagedDevice,
        fromWatch: Bool, token: UUID
    ) async {
        defer { isDeciding = false }
        guard channel.isCurrent(token) else { return }
        guard var request = BrewPingHTTP.request(device: device, path: "/api/approvals/\(id)", method: "POST", timeout: 30) else {
            pendingApproval = nil
            fail(with: L("No Mac connected. Add a device first."), fromWatch: fromWatch)
            return
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["action": action])

        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            guard channel.isCurrent(token), !Task.isCancelled else { return }
            let decoded = try? JSONDecoder().decode(ApprovalDecisionResponse.self, from: data)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if decoded?.status == "denied" {
                pendingApproval = nil
                // 拒绝是明确的终态：释放通道，允许下一条。
                // 用 failed 而不是 completed —— 否则 UI 会把"被拒绝"渲染成绿色的完成态。
                channel.fail(L("Command was denied."))
                if fromWatch {
                    WatchConnectivityManager.shared.sendCommandResult(
                        status: "failed", text: L("Command was denied."), duration: nil
                    )
                }
                return
            }
            guard statusCode == 200, let commandId = decoded?.commandId, !commandId.isEmpty else {
                if statusCode == 404 {
                    // 这条审批已经不在队列里：可能被电脑本身 / 另一台设备批准或拒绝，
                    // 也可能已超时。查终态把结果认领回来 —— 别把 404 当成"命令失败"。
                    await adoptResolvedApproval(
                        approvalID: id, device: device, fromWatch: fromWatch, token: token
                    )
                    return
                }
                pendingApproval = nil
                fail(with: decoded?.error ?? "HTTP \(statusCode)", fromWatch: fromWatch)
                return
            }
            pendingApproval = nil
            channel.markDelivered(commandID: commandId)
            await poll(commandId: commandId, device: device, fromWatch: fromWatch, token: token)
        } catch {
            guard channel.isCurrent(token), !Task.isCancelled else { return }
            pendingApproval = nil
            fail(with: error.localizedDescription, fromWatch: fromWatch)
        }
    }

    /// 提交决定时发现审批已被处理（404）：查终态，按真实结果收敛。
    ///
    /// 场景：确认弹窗还开着，用户已经在电脑上（或另一台手机）批准 / 拒绝了。
    /// 旧实现会把 404 直接显示成一条错误，用户以为命令没执行 —— 其实它跑得好好的。
    /// 这里用同一个终态端点把 commandId 认领回来，继续轮询结果。
    private func adoptResolvedApproval(
        approvalID: String,
        device: ManagedDevice,
        fromWatch: Bool,
        token: UUID
    ) async {
        guard !Task.isCancelled, channel.isCurrent(token) else { return }
        switch await fetchApprovalOutcome(approvalID: approvalID, device: device) {
        case .approved(let commandID, let conversationID):
            if activeConversationId == nil, let conversationID {
                activeConversationId = conversationID
            }
            pendingApproval = nil
            trackedApproval = nil
            channel.markDelivered(commandID: commandID)
            await poll(commandId: commandID, device: device, fromWatch: fromWatch, token: token)
        case .denied:
            pendingApproval = nil
            fail(with: L("Command was denied."), fromWatch: fromWatch)
        case .expired:
            pendingApproval = nil
            fail(with: L("Approval timed out. Check the conversation on your Mac."), fromWatch: fromWatch)
        case .failed(let message):
            pendingApproval = nil
            fail(with: message.isEmpty ? L("Unknown error.") : message, fromWatch: fromWatch)
        case .pending, .transient, .unavailable:
            // 确实查不到结论：明确收敛，别让通道一直占着转圈。
            pendingApproval = nil
            fail(
                with: L("Approval ended without a result. Check the conversation on your Mac."),
                fromWatch: fromWatch
            )
        }
    }

    private func post(
        text: String,
        device: ManagedDevice,
        fromWatch: Bool,
        conversationId: String? = nil,
        token: UUID
    ) async {
        guard channel.isCurrent(token) else { return }
        guard var request = BrewPingHTTP.request(device: device, path: "/api/message", method: "POST", timeout: 30) else {
            fail(with: L("No Mac connected. Add a device first."), fromWatch: fromWatch)
            return
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": text]
        // 指定对话时透传；不带 = 桌面端按「显式对话 → agent → active」三层回落（旧行为）
        if let conversationId, !conversationId.isEmpty {
            body["conversationId"] = conversationId
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            guard channel.isCurrent(token), !Task.isCancelled else { return }
            // 401 单独翻译：审核与真实用户都需要知道"不是网络问题，是没配对"。
            if BrewPingHTTP.isUnauthorized(response) {
                fail(with: L("Not paired with this Mac. Enter the pairing code in this device's settings."), fromWatch: fromWatch)
                return
            }
            let decoded = try? JSONDecoder().decode(SubmitResponse.self, from: data)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 授权门卫：Mac 端判定该命令需要用户确认（safe 命中危险 / askAll）。
            if let approval = decoded?.approval, decoded?.status == "pending_approval" {
                pendingApproval = approval
                // 记下 commandId（当前服务端不返回；留着兼容未来实现）
                pendingCommandId = decoded?.commandId
                // 🚨 关键：进入审批等待仍然**占用通道**。早期这里写 `.idle`，
                // 于是等待期间还能再发一条，把这条从跟踪里挤掉。
                channel.markAwaitingApproval(approvalID: approval.id)
                return
            }

            guard statusCode == 200, let commandId = decoded?.commandId, !commandId.isEmpty else {
                fail(with: decoded?.error ?? "HTTP \(statusCode)", fromWatch: fromWatch)
                return
            }
            channel.markDelivered(commandID: commandId)
            await poll(commandId: commandId, device: device, fromWatch: fromWatch, token: token)
        } catch {
            guard channel.isCurrent(token), !Task.isCancelled else { return }
            fail(with: error.localizedDescription, fromWatch: fromWatch)
        }
    }

    private func poll(commandId: String, device: ManagedDevice, fromWatch: Bool, token: UUID) async {
        var consecutiveErrors = 0
        // delivered（queued/sent）开始计时；进入 working 后解除。
        // 桌面端活着却永远不拾取命令（bug）时，UI 不能永久转圈挡住发送。
        var deliveredSince = Date()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, channel.isCurrent(token) else { return }
            if CommandPollRules.shouldAbandonPickup(
                phase: phase, deliveredSince: deliveredSince, now: Date()
            ) {
                fail(with: L("Command was never picked up by the desktop."), fromWatch: fromWatch)
                return
            }
            guard let request = BrewPingHTTP.request(device: device, path: "/api/message/\(commandId)", timeout: 15) else {
                fail(with: L("No Mac connected. Add a device first."), fromWatch: fromWatch)
                return
            }
            do {
                let (data, response) = try await BrewPingHTTP.session.data(for: request)
                guard !Task.isCancelled, channel.isCurrent(token) else { return }
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

                // 404 = 桌面端已不认识这条 commandId（重启清空内存队列 / id 打错）。
                // 这是终态，不是网络抖动：立即失败收敛，不做无谓重试
                //（与 Windows / Android 端「未知 commandId → 404 终态」契约一致）。
                // 判定规则集中在 `CommandPollRules`（纯逻辑，有单测覆盖）。
                if statusCode != 200 {
                    let decision = CommandPollRules.decide(
                        httpStatus: statusCode, status: nil, response: nil, rawOutput: nil, error: nil
                    )
                    if decision == .unknownCommand {
                        fail(with: L("Unknown command. The desktop may have restarted."), fromWatch: fromWatch)
                        return
                    }
                    consecutiveErrors += 1
                    if consecutiveErrors >= 10 {
                        fail(with: L("Status poll failed."), fromWatch: fromWatch)
                        return
                    }
                    continue
                }

                let decoded = try JSONDecoder().decode(CommandStatusResponse.self, from: data)
                consecutiveErrors = 0
                switch CommandPollRules.decide(
                    httpStatus: 200,
                    status: decoded.status,
                    response: decoded.response,
                    rawOutput: decoded.rawOutput,
                    error: decoded.error
                ) {
                case .keepWaiting:
                    channel.markDelivered(commandID: commandId)
                case .markWorking:
                    channel.markWorking()
                    deliveredSince = Date()   // 进入 working：解除拾取停滞计时
                case .finish(let text, let raw):
                    let body = text.isEmpty
                        ? L(raw ? "(empty raw output)" : "(empty response)")
                        : text
                    finish(body, raw: raw, decoded: decoded, fromWatch: fromWatch)
                    return
                case .fail(let message):
                    lastFailureReason = decoded.failureReason
                    fail(
                        with: message.isEmpty ? L("Unknown error.") : message,
                        decoded: decoded,
                        fromWatch: fromWatch
                    )
                    return
                case .unknownCommand, .transient:
                    continue
                }
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= 10 {
                    fail(with: L("Connection lost: %@", error.localizedDescription), fromWatch: fromWatch)
                    return
                }
            }
        }
    }

    /// 关窗后继续跟踪：直接问桌面端「这条审批（approvalID）现在什么状态」。
    ///
    /// 为什么不能只轮询 `GET /api/approvals` 看「还在不在」：挂起的命令在批准之前
    /// **没有 commandId**（commandId 是真正执行时才生成的），「消失了」只说明有结论，
    /// 分不清是批准、拒绝还是超时。早期实现拿对话转录里「提交之后最新出现的
    /// commandId」当答案 —— 同一对话里别的设备发一条命令就会把结果认错。
    ///
    /// 现在改由 `GET /api/approvals/{id}` 给出 `approvalID → 终态 + 实际 commandId`：
    /// - 不需要客户端传 conversationID（服务端在挂起时就记住了归属）；
    /// - 多条审批并存时各自独立，互不影响；
    /// - 断线重连后只要还在有效期内，重查同一个 approvalID 就能续上，不需要重发命令。
    ///
    /// 旧版桌面端没有这个端点（404）：回落到「审批是否仍挂在列表里」——
    /// 仍在挂起就继续等，真的消失了才收敛为「结果不可用」，仍然不猜。
    private func trackApprovalResolution(
        approvalID: String,
        device: ManagedDevice,
        fromWatch: Bool,
        token: UUID
    ) async {
        let deadline = Date().addingTimeInterval(Self.approvalTrackTimeout)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.approvalTrackInterval)
            guard !Task.isCancelled, channel.isCurrent(token) else { return }
            if Date() > deadline {
                fail(with: L("Approval timed out. Check the conversation on your Mac."), fromWatch: fromWatch)
                return
            }

            let probe = await fetchApprovalOutcome(approvalID: approvalID, device: device)
            guard !Task.isCancelled, channel.isCurrent(token) else { return }

            switch probe {
            case .approved(let commandID, let conversationID):
                // 服务端给出了确定的关联：直接轮询这条命令。
                // 客户端没显式对话时（Watch 路径）采用服务端记下的归属，
                // 结果回传手表才能对上正确的对话页。
                if activeConversationId == nil, let conversationID {
                    activeConversationId = conversationID
                }
                // 已有结论：提示条上的"重新打开确认窗"不该再提供。
                pendingApproval = nil
                trackedApproval = nil
                channel.markDelivered(commandID: commandID)
                await poll(commandId: commandID, device: device, fromWatch: fromWatch, token: token)
                return
            case .denied:
                fail(with: L("Command was denied."), fromWatch: fromWatch)
                return
            case .expired:
                fail(with: L("Approval timed out. Check the conversation on your Mac."), fromWatch: fromWatch)
                return
            case .failed(let message):
                fail(with: message.isEmpty ? L("Unknown error.") : message, fromWatch: fromWatch)
                return
            case .pending, .transient:
                continue
            case .unavailable:
                // ① 旧桌面端没有这个查询端点（审批可能还挂着）→ 继续等；
                // ② 桌面端重启过 / 终态记录已淘汰 → 结果确实拿不到，明确收敛。
                if await isApprovalStillPending(approvalID: approvalID, device: device) ?? true {
                    continue
                }
                fail(
                    with: L("Approval ended without a result. Check the conversation on your Mac."),
                    fromWatch: fromWatch
                )
                return
            }
        }
    }

    /// 一条审批的当前处境。判定规则集中在 `ApprovalOutcomeRules`（纯逻辑，有单测覆盖）。
    private func fetchApprovalOutcome(approvalID: String, device: ManagedDevice) async -> ApprovalProbe {
        guard let request = BrewPingHTTP.request(
            device: device, path: "/api/approvals/\(approvalID)", timeout: 10
        ) else {
            return .transient
        }
        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let decoded = try? JSONDecoder().decode(ApprovalOutcomeResponse.self, from: data)
            return ApprovalOutcomeRules.decode(
                httpStatus: statusCode,
                status: decoded?.status,
                commandID: decoded?.commandId,
                conversationID: decoded?.conversationId,
                error: decoded?.error
            )
        } catch {
            return .transient
        }
    }

    /// 还有哪些审批在挂起。返回 nil = 本次请求失败（当作瞬时抖动，继续等）。
    private func fetchPendingApprovalIDs(device: ManagedDevice) async -> Set<String>? {
        guard let request = BrewPingHTTP.request(device: device, path: "/api/approvals", timeout: 10) else {
            return nil
        }
        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(PendingApprovalsResponse.self, from: data) else {
                return nil
            }
            return Set((decoded.approvals ?? []).compactMap { $0.id })
        } catch {
            return nil
        }
    }

    /// 审批是否仍挂起。nil = 查不到（网络问题 / 该桌面端没有这个端点）。
    private func isApprovalStillPending(approvalID: String, device: ManagedDevice) async -> Bool? {
        guard let pending = await fetchPendingApprovalIDs(device: device) else { return nil }
        return pending.contains(approvalID)
    }

    private func finish(_ text: String, raw: Bool, decoded: CommandStatusResponse, fromWatch: Bool) {
        lastDuration = decoded.duration
        lastModelId = decoded.modelId
        channel.finish(text, raw: raw)
        pendingApproval = nil
        trackedApproval = nil
        pendingCommandId = nil

        guard fromWatch else { return }
        // 结果无论走即时通道还是排队通道，都要保证能落到手表上。
        WatchConnectivityManager.shared.sendCommandResult(
            status: raw ? "completed_with_raw" : "completed",
            text: text,
            duration: decoded.duration,
            conversationId: activeConversationId
        )
    }

    private func fail(with message: String, decoded: CommandStatusResponse? = nil, fromWatch: Bool) {
        if let decoded {
            lastDuration = decoded.duration
            lastModelId = decoded.modelId
        }
        channel.fail(message)
        pendingApproval = nil
        trackedApproval = nil
        pendingCommandId = nil

        guard fromWatch else { return }
        WatchConnectivityManager.shared.sendCommandResult(
            status: "failed",
            text: message,
            duration: decoded?.duration,
            conversationId: activeConversationId
        )
    }
}
