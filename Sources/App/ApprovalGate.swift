import Foundation

/// 一条等待用户确认的命令。
struct PendingApproval: Codable {
    var id: String
    var text: String
    var reasons: [DangerHit]
    var createdAt: Date
}

/// 授权门卫：在命令进入 agent 之前判定「放行」还是「挂起等确认」。
///
/// 职责单一 —— 只管**判定与队列**，不执行命令。执行动作由调用方
/// （`HTTPAPI` 拿到 decide 结果后调 `router.route(.submit(...))`）完成，
/// 这样门卫不反向依赖 CommandRouter，避免循环引用。
final class ApprovalGate {
    static let shared = ApprovalGate()

    /// 判定结果。
    enum Decision {
        /// 放行（auto 模式，或 safe 模式下未命中危险、或命中项已被"总是允许"）。
        case allow
        /// 挂起，等用户确认。
        case pending(PendingApproval)
    }

    /// 用户对某条 pending 做出的决定。
    struct Resolution {
        var action: String          // "approve" | "deny" | "always_approve"
        var text: String?           // approve/always_approve 时为挂起的命令正文
        var reasonCodes: [String]   // 用于 always_approve 时记入白名单
    }

    private let lock = NSLock()
    private var mode: ApprovalMode
    private var alwaysAllowCodes: Set<String>
    private var pending: [String: PendingApproval] = [:]

    /// pending 有效期：超过后自动作废，避免"挂起没人管"的命令永久占坑。
    private let pendingTTL: TimeInterval = 300

    private init() {
        let stored = ApprovalGate.loadStored()
        mode = stored.mode
        alwaysAllowCodes = stored.alwaysAllowCodes
    }

    // MARK: - Mode

    var currentMode: ApprovalMode {
        lock.lock(); defer { lock.unlock() }
        return mode
    }

    func setMode(_ newMode: ApprovalMode) {
        lock.lock(); defer { lock.unlock() }
        mode = newMode
        persistLocked()
    }

    // MARK: - Check

    func check(text: String) -> Decision {
        lock.lock(); defer { lock.unlock() }
        switch mode {
        case .auto:
            return .allow
        case .askAll:
            return .pending(makeApprovalLocked(text: text, reasons: [DangerHit(code: "ask_all", detail: "")]))
        case .safe:
            let hits = DangerPattern.detect(in: text).filter { !alwaysAllowCodes.contains($0.code) }
            guard !hits.isEmpty else { return .allow }
            return .pending(makeApprovalLocked(text: text, reasons: hits))
        }
    }

    // MARK: - Pending queue

    func pendingApprovals() -> [PendingApproval] {
        lock.lock(); defer { lock.unlock() }
        pruneExpiredLocked()
        return pending.values.sorted { $0.createdAt < $1.createdAt }
    }

    func pendingApproval(id: String) -> PendingApproval? {
        lock.lock(); defer { lock.unlock() }
        return pending[id]
    }

    // MARK: - Decide

    /// 用户对某条 pending 做出决定。返回 `Resolution`，由调用方决定是否执行正文。
    /// 未知 id / 已过期 / 已处理 返回 nil。
    func decide(id: String, action: String) -> Resolution? {
        lock.lock(); defer { lock.unlock() }
        guard let approval = pending[id] else { return nil }
        pending.removeValue(forKey: id)

        switch action {
        case "deny":
            return Resolution(action: "deny", text: nil, reasonCodes: approval.reasons.map { $0.code })
        case "approve":
            return Resolution(action: "approve", text: approval.text, reasonCodes: approval.reasons.map { $0.code })
        case "always_approve":
            // 只白名单化"已知的" danger code，拒绝未知 code 注入持久化。
            for reason in approval.reasons where DangerPattern.knownCodes.contains(reason.code) {
                alwaysAllowCodes.insert(reason.code)
            }
            persistLocked()
            return Resolution(action: "always_approve", text: approval.text, reasonCodes: approval.reasons.map { $0.code })
        default:
            return nil
        }
    }

    // MARK: - Internals

    private func makeApprovalLocked(text: String, reasons: [DangerHit]) -> PendingApproval {
        let approval = PendingApproval(
            id: "apv_" + UUID().uuidString,
            text: text,
            reasons: reasons,
            createdAt: Date()
        )
        pending[approval.id] = approval
        return approval
    }

    private func pruneExpiredLocked() {
        let cutoff = Date().addingTimeInterval(-pendingTTL)
        pending = pending.filter { $0.value.createdAt > cutoff }
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var mode: ApprovalMode
        var alwaysAllowCodes: Set<String>
    }

    private static var fileURL: URL {
        SessionManager.shared.directory.appendingPathComponent("approval.json")
    }

    private static func loadStored() -> Stored {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return Stored(mode: .safe, alwaysAllowCodes: [])
        }
        // 白名单只保留仍然存在的已知 code，防止规则表变更后残留失效项。
        let valid = stored.alwaysAllowCodes.filter { DangerPattern.knownCodes.contains($0) }
        return Stored(mode: stored.mode, alwaysAllowCodes: Set(valid))
    }

    private func persistLocked() {
        let stored = Stored(mode: mode, alwaysAllowCodes: alwaysAllowCodes)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: Self.fileURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: Self.fileURL.path
        )
    }
}
