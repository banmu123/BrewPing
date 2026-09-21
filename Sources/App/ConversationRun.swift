import Foundation

// ─── 对话命令执行状态机 ───────────────────────────────────────────────────────
//
// 目标：让「用户不知道是否卡住」不再可能 —— 每一个阶段都是**明确的、可判读的**，
// 而不是把若干种不同语义糊成一个「正在思考」。
//
// 🚨 两条硬约束（来自实际 bug）：
//   1. 状态必须绑定 `commandId` + `conversationId`。用 Agent 全局状态会导致
//      「同一 Agent 的另一条对话被误伤」——TerminalState 按 Agent 归属，
//      而 UI 想知道的是「这条对话的这条命令」现在处于什么阶段。
//   2. 只反映**真实执行状态**，不展示、不伪造模型的隐藏思维链。
//
// 本文件是**纯逻辑**（无 SwiftUI / 无 IO），因此放在 BrewPingCore 路径内，
// 可被 `swift test` 直接覆盖。

/// 一次命令执行的阶段。
public enum RunPhase: String, Equatable, Sendable {
    /// 空闲：没有在飞的命令。
    case idle
    /// 已点发送，等后端确认（对话创建 / 命令落库）。**纯客户端阶段**。
    case submitting
    /// 后端已接受（`queued`），命令已入队但尚未开始执行。
    case queued
    /// 命令已启动，但**尚未收到首字**。
    case thinking
    /// 已收到增量，正在生成。
    case streaming
    /// 用户点了停止，等终态确认。
    case stopping
    /// 命令长时间无首字 / 无新增量，但后台仍**未结束**。
    case stalled
    /// 已成功完成。
    case completed
    /// 已失败（含被用户停止）。
    case failed

    /// 是否仍在「命令在飞」的活跃阶段（决定是否轮询 / 显示停止按钮）。
    public var isActive: Bool {
        switch self {
        case .submitting, .queued, .thinking, .streaming, .stopping, .stalled:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }

    /// 是否已到达终态（不再接受任何 delta）。
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed: return true
        default: return false
        }
    }
}

/// 全部阈值集中在此，UI 与状态机共用同一份来源（避免两处各写一个魔法数）。
public enum RunTiming {
    /// 超过该时长仍未收到首字 → 文案降级为「仍在处理中」。
    public static let firstTokenNoticeSeconds: TimeInterval = 8
    /// 超过该时长无任何新增量（且命令未结束）→ 进入 `stalled`。
    public static let stallSeconds: TimeInterval = 30
    /// 请求停止后多久仍未收到终态 → 提示用户「停止请求尚未确认」。
    public static let stopConfirmTimeoutSeconds: TimeInterval = 10
    /// UI 合并刷新间隔：把高频事件与 SwiftUI 渲染频率解耦。
    public static let uiFlushIntervalSeconds: TimeInterval = 0.1
}

/// 指示器种类 —— UI 只需把 kind 映射到文案，不需要自己推断阶段组合。
public enum RunIndicatorKind: String, Equatable, Sendable {
    case submitting
    case queued
    case thinking
    /// 超过 `firstTokenNoticeSeconds` 仍无首字。
    case waitingLong
    case streaming
    case stalled
    case stopping
    /// 停止请求超时未确认。
    case stopConfirmTimeout
}

/// UI 展示所需的派生描述（纯数据）。
public struct RunIndicator: Equatable, Sendable {
    public var kind: RunIndicatorKind
    /// 从提交到现在的秒数。
    public var elapsedSeconds: Int
    /// 距最后一次收到输出的秒数（尚无输出时为 nil）。
    public var sinceLastOutputSeconds: Int?
    /// 是否提供「停止」操作。
    public var showsStop: Bool
    /// 是否提供「查看终端」操作。
    public var showsTerminal: Bool

    public init(
        kind: RunIndicatorKind,
        elapsedSeconds: Int,
        sinceLastOutputSeconds: Int?,
        showsStop: Bool,
        showsTerminal: Bool
    ) {
        self.kind = kind
        self.elapsedSeconds = elapsedSeconds
        self.sinceLastOutputSeconds = sinceLastOutputSeconds
        self.showsStop = showsStop
        self.showsTerminal = showsTerminal
    }
}

/// 一次命令执行的完整状态。所有时间点由调用方注入 `now`，便于测试确定性。
public struct ConversationRun: Equatable, Sendable {
    public var conversationId: String
    public var commandId: String
    public var phase: RunPhase
    /// 已收到的**累积全文**（后端推的就是累积值）。绝不做字符截断。
    public var text: String
    /// 提交时刻（算总耗时）。
    public var startedAt: Date
    /// 最后一次「有进展」的时刻（收到增量或阶段推进）。
    public var lastActivityAt: Date
    /// 首字到达时刻（nil = 尚未收到任何增量）。
    public var firstTokenAt: Date?
    /// 用户点击停止的时刻（nil = 未请求停止）。
    public var stopRequestedAt: Date?
    /// 尚未落库的乐观用户消息文本（提交期间显示，后端确认后清空）。
    public var pendingUserText: String?

    public init(
        conversationId: String,
        commandId: String,
        phase: RunPhase,
        text: String = "",
        startedAt: Date,
        lastActivityAt: Date,
        firstTokenAt: Date? = nil,
        stopRequestedAt: Date? = nil,
        pendingUserText: String? = nil
    ) {
        self.conversationId = conversationId
        self.commandId = commandId
        self.phase = phase
        self.text = text
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.firstTokenAt = firstTokenAt
        self.stopRequestedAt = stopRequestedAt
        self.pendingUserText = pendingUserText
    }

    /// 客户端乐观占位：conversationId 允许为空（新对话尚未物化）。
    public init(submitting commandId: String, conversationId: String, text: String, now: Date) {
        self.init(
            conversationId: conversationId,
            commandId: commandId,
            phase: .submitting,
            text: "",
            startedAt: now,
            lastActivityAt: now,
            pendingUserText: text
        )
    }
}

// ─── 转移与派生（纯函数）─────────────────────────────────────────────────────

public extension ConversationRun {

    // MARK: 时间派生

    func elapsedSeconds(now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(startedAt).rounded(.down)))
    }

    /// 距最后一次收到输出的秒数（从未收到输出 → nil）。
    func sinceLastOutputSeconds(now: Date) -> Int? {
        guard let first = firstTokenAt else { return nil }
        // 有输出之后，lastActivityAt 就是最后一次增量时刻。
        return max(0, Int(now.timeIntervalSince(max(lastActivityAt, first)).rounded(.down)))
    }

    /// 距最后一次「任何进展」的秒数（用于 stalled 判定）。
    func silentSeconds(now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(lastActivityAt).rounded(.down)))
    }

    // MARK: 转移

    /// 后端已确认命令（拿到 commandId 之后进入 queued）。
    mutating func markQueued(now: Date) {
        guard !phase.isTerminal else { return }
        if phase == .submitting || phase == .idle {
            phase = .queued
        }
        lastActivityAt = now
    }

    /// 收到一帧增量。返回是否被接受（false = 重复 / 过时 / 乱序 / 终态后被丢弃）。
    ///
    /// 后端推的是**累积全文**，因此可以用「前缀关系」判定过时帧，不需要序号：
    /// - 与当前文本相同 → 重复帧，丢弃；
    /// - 是当前文本的严格前缀 → 过时帧（更早的快照），丢弃；
    /// - `done == true` 的终态帧一律接受（它就是最终全文）。
    @discardableResult
    mutating func applyDelta(_ incoming: String, done: Bool, now: Date) -> Bool {
        guard !phase.isTerminal else { return false }
        guard !incoming.isEmpty else { return false }

        if !done {
            if incoming == text { return false }
            if text.count > incoming.count && text.hasPrefix(incoming) { return false }
        }

        text = incoming
        if firstTokenAt == nil { firstTokenAt = now }
        lastActivityAt = now
        // 首字到达后原地进入 streaming —— 不回退、不闪回「思考中」。
        if phase == .submitting || phase == .queued || phase == .thinking || phase == .stalled {
            phase = .streaming
        }
        // 停止请求已发出（stopping）时不改阶段：仍等待终态确认。
        return true
    }

    /// 用户点击停止。
    mutating func requestStop(now: Date) {
        guard phase.isActive, phase != .stopping else { return }
        phase = .stopping
        stopRequestedAt = now
        lastActivityAt = now
    }

    /// 周期评估是否「长时间无进展」。由 app 层 tick 调用。
    /// - Returns: 是否发生了阶段变化。
    @discardableResult
    mutating func refreshStall(now: Date) -> Bool {
        guard phase == .queued || phase == .thinking || phase == .streaming else { return false }
        guard silentSeconds(now: now) >= Int(RunTiming.stallSeconds) else { return false }
        phase = .stalled
        return true
    }

    /// 收到终态（转录落库 / 命令失败）。
    mutating func finish(success: Bool, now: Date) {
        phase = success ? .completed : .failed
        lastActivityAt = now
    }

    /// 命令已被其它路径结束（例如转录里出现了该 commandId 的 assistant/error 条目）。
    mutating func finishFromTranscript(role: String, now: Date) {
        finish(success: role == "assistant", now: now)
    }

    // MARK: UI 派生

    /// 当前应展示的指示器。纯函数：同一 (run, now) 必得同一结果。
    func indicator(now: Date) -> RunIndicator {
        let elapsed = elapsedSeconds(now: now)
        let silent = sinceLastOutputSeconds(now: now)

        switch phase {
        case .submitting:
            return RunIndicator(
                kind: .submitting, elapsedSeconds: elapsed, sinceLastOutputSeconds: silent,
                showsStop: false, showsTerminal: false
            )

        case .queued:
            return RunIndicator(
                kind: .queued, elapsedSeconds: elapsed, sinceLastOutputSeconds: silent,
                showsStop: true, showsTerminal: false
            )

        case .thinking:
            let kind: RunIndicatorKind = elapsed >= Int(RunTiming.firstTokenNoticeSeconds)
                ? .waitingLong
                : .thinking
            return RunIndicator(
                kind: kind, elapsedSeconds: elapsed, sinceLastOutputSeconds: silent,
                showsStop: true, showsTerminal: true
            )

        case .streaming:
            return RunIndicator(
                kind: .streaming, elapsedSeconds: elapsed, sinceLastOutputSeconds: silent,
                showsStop: true, showsTerminal: true
            )

        case .stalled:
            return RunIndicator(
                kind: .stalled, elapsedSeconds: elapsed, sinceLastOutputSeconds: silent,
                showsStop: true, showsTerminal: true
            )

        case .stopping:
            let since = stopRequestedAt.map { max(0, Int(now.timeIntervalSince($0).rounded(.down))) } ?? 0
            let kind: RunIndicatorKind = since >= Int(RunTiming.stopConfirmTimeoutSeconds)
                ? .stopConfirmTimeout
                : .stopping
            return RunIndicator(
                kind: kind, elapsedSeconds: elapsed, sinceLastOutputSeconds: silent,
                // 停止请求超时后允许再次尝试停止（后台可能仍在跑）。
                showsStop: kind == .stopConfirmTimeout, showsTerminal: true
            )

        case .idle, .completed, .failed:
            return RunIndicator(
                kind: .streaming, elapsedSeconds: elapsed, sinceLastOutputSeconds: silent,
                showsStop: false, showsTerminal: false
            )
        }
    }
}
