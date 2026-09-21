import Foundation

// ─── 服务端权威执行阶段（HTTP DTO 支撑，任务 §13）─────────────────────────────
//
// 目标：让手机 / 手表等 HTTP 客户端也能看到「真实执行状态」—— 与 Mac 桌面端
// `ConversationRun` 同一词表、同一阈值，但由**桌面端**权威推导（尤其 stalled）。
//
// 设计要点：
//  - `CommandStore.CommandInfo` 已承载 status / createdAt（终态还落盘）；
//  - 流式输出每秒多帧，**不能**逐帧写 CommandInfo（persist 会把磁盘写爆），
//    所以「最后输出时刻」放在这个内存字典里，容量受限；
//  - 二者在 `HTTPAPI.commandResponse` 合成 `run` 快照，老客户端可忽略。
//
// 🚨 阶段词表与 `ConversationRun.RunPhase` 对齐，不发明新状态：
//   `submitting` / `stopping` 是纯客户端阶段，服务端不产生。

/// 内存级「最后输出时刻」登记（流式回调高频写入，只读于轮询响应）。
public final class RunStatusTracker {
    public static let shared = RunStatusTracker()

    private let lock = NSLock()
    private var lastOutput: [String: Date] = [:]
    /// 容量上限：超过后整体清空。在飞命令数远小于该值，正常永不触发。
    private let capacity = 512

    public func recordOutput(commandId: String, at: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        if lastOutput.count >= capacity {
            lastOutput.removeAll()
        }
        lastOutput[commandId] = at
    }

    public func lastOutputAt(commandId: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastOutput[commandId]
    }
}

/// `run` 快照的阶段推导（纯函数，可 `swift test` 覆盖）。
public enum RunPhaseDTO {
    /// 与 `RunTiming.stallSeconds` 一致 —— 两端同一权威数值。
    public static let stallSeconds: TimeInterval = 30

    /// status 取 `CommandStatus.rawValue`（queued / sent / working / completed /
    /// completed_with_raw / failed）。
    ///
    /// `completedWithRaw` 也一并接受：那是 Swift 枚举的**case 名**，线上值仍是
    /// `completed_with_raw`。多认一个拼写是为了让漏走 `rawValue` 的调用方不至于
    /// 静默落进 `default` 变成 `idle`（状态解析错了比多一个 case 危险得多）。
    public static func derive(
        status: String,
        lastOutputAt: Date?,
        now: Date = Date()
    ) -> String {
        switch status {
        case "queued", "sent":
            return "queued"
        case "working":
            guard let last = lastOutputAt else { return "thinking" }
            return now.timeIntervalSince(last) >= stallSeconds ? "stalled" : "streaming"
        case "completed", "completed_with_raw", "completedWithRaw":
            return "completed"
        case "failed":
            return "failed"
        default:
            return "idle"
        }
    }
}
