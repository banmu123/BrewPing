import Foundation

/// 一条等待用户确认的命令。
struct PendingApproval: Codable {
    var id: String
    var text: String
    var reasons: [DangerHit]
    var createdAt: Date
    /// 挂起时所属的对话（授权是**对话级**设置；批准后回同一条对话执行）。
    var conversationID: String?
}

/// 一条审批的**终态**记录：审批从 pending 队列消失之后，客户端还能问「它到底怎么了」。
///
/// 为什么需要它：挂起的命令在批准之前**没有 commandId**（commandId 是真正执行时才生成的）。
/// 只凭「审批不见了」无法区分 批准执行 / 拒绝 / 超时，客户端早期只能拿对话转录里
/// 最新出现的 commandId 去猜 —— 同一对话里别的设备发一条命令就会认错。
/// 这里把 `approvalID → 终态 + 实际 commandId` 固定下来，关联就变成确定的。
struct ApprovalOutcome: Equatable {
    enum Status: String, Equatable {
        /// 已批准，且已派发执行。`commandID` 此刻可能有值（执行成功）或还没挂上（毫秒级窗口）。
        case approved
        case denied
        /// 超过 TTL 没人处理，自动作废（缺席不表态 ≠ 默认放行）。
        case expired
        /// 已批准但执行没起来（对话不存在 / Agent 拒绝等）。`error` 说明原因。
        case failed
    }

    var approvalID: String
    var status: Status
    /// 批准后**实际**执行产生的命令 id —— 与审批一一对应，不靠时间/顺序猜。
    var commandID: String?
    var conversationID: String?
    var error: String?
    var resolvedAt: Date
}

/// 授权门卫：在命令进入 agent 之前判定「放行」还是「挂起等确认」。
///
/// 职责单一 —— 只管**判定与队列**，不执行命令。执行动作由调用方
/// （`HTTPAPI` 拿到 decide 结果后调 `router.route(.submit(...))`）完成，
/// 这样门卫不反向依赖 CommandRouter，避免循环引用。
public final class ApprovalGate {
    public static let shared = ApprovalGate()

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
        /// pending 所属的对话（授权是对话级设置，批准后沿同一条对话执行）。
        var conversationID: String?
    }

    private let lock = NSLock()
    private var mode: ApprovalMode
    private var alwaysAllowCodes: Set<String>
    private var pending: [String: PendingApproval] = [:]
    /// 已出队的审批终态，按 approvalID 索引。**只放内存**：审批队列本身也是内存态，
    /// 桌面端重启后 pending 与 outcome 一起消失，客户端拿到 404 后按「结果不可用」收敛。
    private var outcomes: [String: ApprovalOutcome] = [:]
    /// 状态文件位置（`approval.json`）。`shared` 用真实路径；测试注入临时路径。
    private let fileURL: URL

    /// pending 有效期：超过后自动作废，避免"挂起没人管"的命令永久占坑。
    private let pendingTTL: TimeInterval
    /// 终态记录保留时长：客户端关掉弹窗后最多跟踪 330s，这里留足余量。
    private let outcomeTTL: TimeInterval
    /// 终态记录上限，防止长时间运行后无限增长。
    private let maxOutcomes = 256

    private init() {
        let stored = ApprovalGate.loadStored(fileURL: ApprovalGate.defaultFileURL)
        mode = stored.mode
        alwaysAllowCodes = stored.alwaysAllowCodes
        fileURL = ApprovalGate.defaultFileURL
        pendingTTL = 300
        outcomeTTL = 900
    }

    /// 测试 / 多环境隔离：显式指定审批状态文件与 TTL，避免读写开发机真实的
    /// `~/.brewping/approval.json`，也不必为了等超时真的睡 5 分钟。
    init(fileURL: URL, pendingTTL: TimeInterval = 300, outcomeTTL: TimeInterval = 900) {
        let stored = ApprovalGate.loadStored(fileURL: fileURL)
        mode = stored.mode
        alwaysAllowCodes = stored.alwaysAllowCodes
        self.fileURL = fileURL
        self.pendingTTL = pendingTTL
        self.outcomeTTL = outcomeTTL
    }

    // MARK: - Mode

    public var currentMode: ApprovalMode {
        lock.lock(); defer { lock.unlock() }
        return mode
    }

    public func setMode(_ newMode: ApprovalMode) {
        lock.lock(); defer { lock.unlock() }
        mode = newMode
        persistLocked()
    }

    // MARK: - Check

    /// 按指定档位判定。授权档位是**对话级**设置：`mode` 传该对话固化的档位
    /// （nil = 全局默认）；`conversationID` 随 pending 记住，批准后回同一条对话执行。
    /// 「总是允许」白名单保持全局 —— 它描述的是这台机器允许哪些危险模式。
    func check(text: String, mode: ApprovalMode? = nil, conversationID: String? = nil) -> Decision {
        lock.lock(); defer { lock.unlock() }
        switch mode ?? self.mode {
        case .auto:
            return .allow
        case .askAll:
            return .pending(makeApprovalLocked(
                text: text,
                reasons: [DangerHit(code: "ask_all", detail: "")],
                conversationID: conversationID
            ))
        case .safe:
            let hits = DangerPattern.detect(in: text).filter { !alwaysAllowCodes.contains($0.code) }
            guard !hits.isEmpty else { return .allow }
            return .pending(makeApprovalLocked(text: text, reasons: hits, conversationID: conversationID))
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

    // MARK: - Outcome（审批终态）

    /// 这条审批现在的处境。`nil` = 服务端不认识它（从未见过 / 记录已过期 / 进程重启过）。
    ///
    /// 会顺带清理过期 pending —— 一条挂起到 TTL 之外的审批在这里被记为 `expired`，
    /// 客户端因此能收到「超时」这个明确终态，而不是干等她自己的看门狗。
    func outcome(id: String) -> ApprovalOutcome? {
        lock.lock(); defer { lock.unlock() }
        pruneExpiredLocked()
        return outcomes[id]
    }

    /// 批准后命令真正派发成功：把**实际** commandId 补进终态记录。
    ///
    /// 这是「审批 → 命令」关联的唯一权威来源。客户端拿到它就直接轮询该 commandId，
    /// 不再靠「对话里最新出现的 commandId」猜（同一对话多设备并发时会认错）。
    func attachCommand(id: String, commandID: String, conversationID: String?) {
        lock.lock(); defer { lock.unlock() }
        guard var record = outcomes[id] else { return }
        record.commandID = commandID
        if let conversationID, !conversationID.isEmpty {
            record.conversationID = conversationID
        }
        record.resolvedAt = Date()
        outcomes[id] = record
    }

    /// 批准了但执行没起来：明确记成 `failed`，别让客户端一直等到看门狗超时。
    func markFailed(id: String, error: String) {
        lock.lock(); defer { lock.unlock() }
        guard var record = outcomes[id] else { return }
        record.status = .failed
        record.error = error
        record.resolvedAt = Date()
        outcomes[id] = record
    }

    // MARK: - Decide

    /// 用户对某条 pending 做出决定。返回 `Resolution`，由调用方决定是否执行正文。
    /// 未知 id / 已过期 / 已处理 返回 nil。
    ///
    /// 无论走到哪个分支，都会留下一条终态记录 —— 这样「弹窗被关掉」的客户端
    /// 仍能靠 `approvalID` 查到确定的结论，而不是靠猜。
    func decide(id: String, action: String) -> Resolution? {
        lock.lock(); defer { lock.unlock() }
        // 先清理过期项：TTL 之外本来就不该再被执行（早期实现的 TTL 只在列表查询时生效）。
        pruneExpiredLocked()
        guard let approval = pending[id] else { return nil }
        pending.removeValue(forKey: id)

        switch action {
        case "deny":
            recordLocked(approval, status: .denied)
            return Resolution(action: "deny", text: nil, reasonCodes: approval.reasons.map { $0.code }, conversationID: approval.conversationID)
        case "approve":
            recordLocked(approval, status: .approved)
            return Resolution(action: "approve", text: approval.text, reasonCodes: approval.reasons.map { $0.code }, conversationID: approval.conversationID)
        case "always_approve":
            // 只白名单化"已知的" danger code，拒绝未知 code 注入持久化。
            for reason in approval.reasons where DangerPattern.knownCodes.contains(reason.code) {
                alwaysAllowCodes.insert(reason.code)
            }
            persistLocked()
            recordLocked(approval, status: .approved)
            return Resolution(action: "always_approve", text: approval.text, reasonCodes: approval.reasons.map { $0.code }, conversationID: approval.conversationID)
        default:
            // 未知 action 会消费掉 pending（与旧实现 / Windows 端一致），
            // 但它没有产生任何执行 —— 记成 failed，客户端才不会误以为"批准了"。
            recordLocked(approval, status: .failed, error: "unknown action: \(action)")
            return nil
        }
    }

    // MARK: - Internals

    private func makeApprovalLocked(text: String, reasons: [DangerHit], conversationID: String? = nil) -> PendingApproval {
        let approval = PendingApproval(
            id: "apv_" + UUID().uuidString,
            text: text,
            reasons: reasons,
            createdAt: Date(),
            conversationID: conversationID
        )
        pending[approval.id] = approval
        return approval
    }

    private func recordLocked(
        _ approval: PendingApproval,
        status: ApprovalOutcome.Status,
        error: String? = nil
    ) {
        insertOutcomeLocked(ApprovalOutcome(
            approvalID: approval.id,
            status: status,
            commandID: nil,
            conversationID: approval.conversationID,
            error: error,
            resolvedAt: Date()
        ))
    }

    private func insertOutcomeLocked(_ record: ApprovalOutcome) {
        outcomes[record.approvalID] = record
    }

    private func pruneExpiredLocked() {
        let now = Date()
        // 1) 过期 pending → 记为 expired（这一步让超时对客户端可见）
        let cutoff = now.addingTimeInterval(-pendingTTL)
        let expired = pending.filter { $0.value.createdAt <= cutoff }
        for (id, approval) in expired {
            pending.removeValue(forKey: id)
            insertOutcomeLocked(ApprovalOutcome(
                approvalID: id,
                status: .expired,
                commandID: nil,
                conversationID: approval.conversationID,
                error: nil,
                resolvedAt: now
            ))
        }
        // 2) 终态记录按时间淘汰，避免长时间运行后无限增长
        let outcomeCutoff = now.addingTimeInterval(-outcomeTTL)
        if outcomes.contains(where: { $0.value.resolvedAt <= outcomeCutoff }) {
            outcomes = outcomes.filter { $0.value.resolvedAt > outcomeCutoff }
        }
        if outcomes.count > maxOutcomes {
            let keep = outcomes
                .sorted { $0.value.resolvedAt > $1.value.resolvedAt }
                .prefix(maxOutcomes)
            outcomes = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var mode: ApprovalMode
        var alwaysAllowCodes: Set<String>
    }

    static var defaultFileURL: URL {
        SessionManager.shared.directory.appendingPathComponent("approval.json")
    }

    private static func loadStored(fileURL: URL) -> Stored {
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
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
