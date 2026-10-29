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
