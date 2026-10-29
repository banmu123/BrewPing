import Foundation

// ─── 命令生命周期（iOS 客户端侧）─────────────────────────────────────────────
//
// 为什么放在 `Sources/Protocol`：它是**纯状态机**，不依赖 UIKit / URLSession，
// 因此既能被 iOS app 直接编译（工程里已有 `../Sources/Protocol` 分组），
// 又能被 SwiftPM 的 `BrewPingCoreTests` 覆盖 —— 不需要为了测试再造一个 Xcode
// test target。桌面端不引用它。

/// 一条命令在**手机这一侧**的跟踪阶段。
///
/// 与桌面端的 `CommandStatus`（queued / sent / working / completed…）不是一回事：
/// 这里描述的是客户端对一条命令的跟踪状态，决定 UI 展示与提交通道是否被占用。
///
/// 不变量：**只要没进终态，通道就占用**。早期实现把"等待审批"写成了 `.idle`，
/// 于是等待期间还能再发一条，后到者会把先到的那条从轮询里挤掉（Mac 端仍在挂起，
/// 手机端却再也拿不到结果）。`.awaitingApproval` / `.trackingApproval` 正是为此而加。
public enum CommandPhase: Equatable {
    /// 没有在跟踪的命令。
    case idle
    /// 已发出 POST，等桌面端受理。
    case sending
    /// 桌面端已挂起、等用户确认（确认弹窗可能仍开着）。
    case awaitingApproval
    /// 用户关掉了确认弹窗，命令仍挂在桌面端 —— 继续跟踪，通道仍被占用。
    case trackingApproval
    /// 已拿到 commandId，等桌面端拾取。
    case delivered
    /// 桌面端正在执行。
    case working
    case completed(String)
    case completedRaw(String)
    case failed(String)

    /// 终态：通道可以释放，允许下一条命令。
    ///
    /// 注意 `.idle` 也算终态 —— 它表示"没有在跟踪的命令"。
    public var isTerminal: Bool {
        switch self {
        case .idle, .completed, .completedRaw, .failed:
            return true
        default:
            return false
        }
    }

    /// 仍在跟踪中（发送 / 审批 / 执行）。UI 用它决定按钮忙碌态。
    public var inFlight: Bool { !isTerminal }

    /// 与审批相关（弹窗开着或已关窗但仍在等桌面端结论）。
    public var isAwaitingDecision: Bool {
        self == .awaitingApproval || self == .trackingApproval
    }
}

/// 提交通道 + 当前命令的跟踪状态。
///
/// 唯一的并发闸门：`begin()` 只有在通道空闲时才返回 token，调用方拿不到 token
/// 就必须放弃本次提交。**不允许**用 UI 的按钮禁用代替这里的判定 ——
/// iPhone、Apple Watch、深链等入口最终都汇到这一处。
///
/// `runToken` 解决另一类问题：切换设备 / 重置后，仍在飞的异步回调必须能被识别为
/// 过期，不能把旧命令的结果写进新设备（或新对话）的界面。
public struct CommandChannel: Equatable {
    /// 当前跟踪阶段。
    public private(set) var phase: CommandPhase = .idle
    /// 桌面端返回的命令 id（审批挂起时可能还没有）。
    public private(set) var commandID: String?
    /// 审批请求 id（`POST /api/approvals/{id}` 用它）。
    public private(set) var approvalID: String?
    /// 本次跟踪的世代标识；`reset()` 会换一个新的。
    public private(set) var runToken = UUID()

    public init() {}

    /// 通道是否被占用。为 true 时任何新提交都必须被拒绝并给出反馈。
    public var isBusy: Bool { phase.inFlight }
    public var acceptsNewCommand: Bool { !isBusy }

    /// 尝试占用通道开始一次提交。返回本次的 token；通道忙时返回 nil。
    ///
    /// 用 token（而不是 Bool）是为了让调用方在异步回调里能判断自己是否仍然有效。
    public mutating func begin() -> UUID? {
        guard acceptsNewCommand else { return nil }
        runToken = UUID()
        phase = .sending
        commandID = nil
        approvalID = nil
        return runToken
    }

    /// 该 token 是否仍是当前这次跟踪（未被 reset / 被新命令取代）。
    public func isCurrent(_ token: UUID) -> Bool { token == runToken }

    /// 桌面端挂起了命令，等用户确认。
    ///
    /// 从弹窗关闭状态（`.trackingApproval`）也能回到这里（例如用户重新打开弹窗）。
    public mutating func markAwaitingApproval(approvalID: String?) {
        guard phase.inFlight else { return }
        self.approvalID = approvalID
        phase = .awaitingApproval
    }

    /// 用户关掉确认弹窗：不批准也不拒绝，继续等桌面端的结论。
    /// 只有确实在等审批时才生效，避免把执行中的命令误标成审批态。
    public mutating func markTrackingApproval() {
        guard phase == .awaitingApproval else { return }
        phase = .trackingApproval
    }

    /// 已拿到 commandId，进入轮询。
    public mutating func markDelivered(commandID: String) {
        guard phase.inFlight else { return }
        self.commandID = commandID
        self.approvalID = nil
        phase = .delivered
    }

    /// 桌面端已开始执行。
    public mutating func markWorking() {
        guard phase.inFlight else { return }
        phase = .working
    }

    /// 终态：完成。
    public mutating func finish(_ text: String, raw: Bool) {
        approvalID = nil
        phase = raw ? .completedRaw(text) : .completed(text)
    }

    /// 终态：失败（含拒绝、超时、网络放弃）。
    public mutating func fail(_ message: String) {
        approvalID = nil
        phase = .failed(message)
    }

    /// 释放通道并清空关联 id。切换设备 / 用户主动重置时调用。
    public mutating func reset() {
        runToken = UUID()
        phase = .idle
        commandID = nil
        approvalID = nil
    }
}

// MARK: - 轮询结果的纯判定

/// 一次 `GET /api/message/{id}` 应该如何推进状态。
///
/// 抽成纯函数的原因：这段判定里有四个容易写错的边界 ——
/// 404 是**终态**（桌面端重启后不认识这条命令，重试没有意义）、
/// 非 200 是**瞬时**（要计数后退避重试）、
/// `completed_with_raw` 要保留原始输出、未知状态要**继续等**而不是当成失败。
public enum CommandPollDecision: Equatable {
    /// 仍在排队 / 执行中，继续轮询。
    case keepWaiting
    /// 桌面端开始执行。
    case markWorking
    /// 终态成功。`raw` 决定展示原始输出还是提炼后的回复。
    case finish(String, raw: Bool)
    /// 终态失败。
    case fail(String)
    /// 桌面端不认识这条 commandId（404）—— 终态，立即收敛。
    case unknownCommand
    /// 非 200：当作瞬时错误，由调用方计数。
    case transient
}

public enum CommandPollRules {
    /// 依据 HTTP 状态码与响应体判定下一步。
    public static func decide(
        httpStatus: Int,
        status: String?,
        response: String?,
        rawOutput: String?,
        error: String?
    ) -> CommandPollDecision {
        if httpStatus == 404 { return .unknownCommand }
        guard httpStatus == 200 else { return .transient }
        switch status {
        case "queued", "sent":
            return .keepWaiting
        case "working":
            return .markWorking
        case "completed":
            return .finish(response ?? "", raw: false)
        case "completed_with_raw":
            return .finish(rawOutput ?? "", raw: true)
        case "failed":
            return .fail(error ?? "")
        default:
            // 未知状态（老/新桌面端字段漂移）→ 继续等，绝不擅自判失败。
            return .keepWaiting
        }
    }

    /// 拾取看门狗：命令已投递但桌面端迟迟不拾取，多久算失败。
    ///
    /// 只对 `.delivered` 生效 —— 一旦进入 `.working`，执行耗时由 agent 决定，
    /// 不能再用这个阈值催它。
    public static let pickupStallTimeout: TimeInterval = 90

    public static func shouldAbandonPickup(
        phase: CommandPhase,
        deliveredSince: Date,
        now: Date
    ) -> Bool {
        guard phase == .delivered else { return false }
        return now.timeIntervalSince(deliveredSince) > pickupStallTimeout
    }
}

// MARK: - 审批终态的纯判定

/// 一次 `GET /api/approvals/{id}` 的解读结果。
///
/// 关掉确认弹窗后，客户端唯一需要回答的问题是「那条命令到底执行了没有、
/// 对应的 commandId 是哪个」。服务端把 `approvalID → 终态 + commandId` 记下来，
/// 这里负责把响应翻译成可执行的下一步。
public enum ApprovalProbe: Equatable {
    /// 还没有结论（仍挂起，或已批准但 commandId 尚未挂上）。继续等。
    case pending
    /// 已批准，且拿到了**实际执行**产生的 commandId。转入普通命令轮询。
    case approved(commandID: String, conversationID: String?)
    /// 用户明确拒绝了。
    case denied
    /// 超过 TTL 没人处理，服务端自动作废。
    case expired
    /// 批准了但执行没起来（原因见 message）。
    case failed(String)
    /// 服务端不认识这条审批：可能重启过、记录已淘汰，也可能它根本没有这个端点
    ///（旧版桌面端）。调用方需要用「审批是否还挂在列表里」再区分一次。
    case unavailable
    /// 网络错误 / 5xx：瞬时问题，继续等。
    case transient
}

public enum ApprovalOutcomeRules {
    /// 依据 HTTP 状态码与响应体判定下一步。
    ///
    /// 关键取舍：`approved` 但没带 commandId 时**不判失败**，而是当作 `pending`
    /// 继续等 —— 服务端是先记「已批准」再补 commandId 的，中间有毫秒级窗口；
    /// 这时报错会让一次成功的审批被显示成失败。
    public static func decode(
        httpStatus: Int,
        status: String?,
        commandID: String?,
        conversationID: String?,
        error: String?
    ) -> ApprovalProbe {
        if httpStatus == 404 { return .unavailable }
        guard httpStatus == 200 else { return .transient }
        switch status {
        case "pending":
            return .pending
        case "approved":
            guard let commandID, !commandID.isEmpty else { return .pending }
            let conversation = (conversationID?.isEmpty == false) ? conversationID : nil
            return .approved(commandID: commandID, conversationID: conversation)
        case "denied":
            return .denied
        case "expired":
            return .expired
        case "failed":
            return .failed(error ?? "")
        default:
            // 未知状态（老/新桌面端字段漂移）→ 继续等，绝不擅自判失败。
            return .pending
        }
    }
}

// MARK: - 审批决定（POST /api/approvals/{id}）的纯判定

/// 一次「我对这条审批做了决定」的结果。
public enum ApprovalDecisionProbe: Equatable {
    /// 已批准并已派发。`commandID` 用来继续普通命令轮询（**不重新提交**）。
    case executed(commandID: String, conversationID: String?)
    /// 明确拒绝。也可能带归属：拒绝回执同样要落到正确的对话页。
    case denied(conversationID: String?)
    /// 404：这条审批已经被电脑本身 / 另一台设备处理掉了 —— 去查终态，别当失败。
    case unresolved
    /// 其余失败（含 200 却没有 commandId）。
    case failed(String)
}

public enum ApprovalDecisionRules {
    public static func decode(
        httpStatus: Int,
        status: String?,
        commandID: String?,
        conversationID: String?,
        error: String?
    ) -> ApprovalDecisionProbe {
        if httpStatus == 404 { return .unresolved }
        // 拒绝是明确终态，优先于状态码判断（与既有客户端行为一致）。
        if status == "denied" {
            return .denied(conversationID: normalized(conversationID))
        }
        guard httpStatus == 200, let commandID, !commandID.isEmpty else {
            return .failed(error ?? "HTTP \(httpStatus)")
        }
        // 缺 conversationId **不算失败**：命令已经受理，只是不知道归属而已。
        // 已有 activeConversationId 的客户端本来就不需要它。
        return .executed(commandID: commandID, conversationID: normalized(conversationID))
    }

    /// 服务端给出的归该如何落到客户端。
    ///
    /// 规则：客户端**已有**有效归属就保留（用户正在看的对话不能被远端改掉）；
    /// 只有本来就没有时才采用服务端的值。两边都没有 → nil（沿用旧行为）。
    public static func adoptConversation(current: String?, incoming: String?) -> String? {
        if let current, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return current
        }
        return normalized(incoming)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
