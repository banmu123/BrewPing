import Foundation

/// 配对与请求鉴权。
///
/// 背景：命令通道原来是**完全无鉴权**的明文 HTTP ——
/// 同一 Wi-Fi 下任何设备都能 POST `/api/message` 在用户 Mac 上执行命令。
/// 这既是真实安全漏洞，也容易被审核侧读成"可被滥用的远程控制工具"。
///
/// 现在的模型：
///  1. **配对**：Mac 端生成 6 位配对码（10 分钟有效、一次性），
///     iPhone 输入后由 `POST /api/pair` 换取长期 token；
///  2. **鉴权**：除 `/api/pair` 与 `/api/status`（只读健康检查）外，
///     所有接口都要求 `Authorization: Bearer <token>`；
///  3. **防重放**：写操作额外要求 `X-BrewPing-Timestamp` + `X-BrewPing-Nonce`，
///     时间窗 120 秒，nonce 不可重复使用。
///
/// token 是 32 字节系统随机数，落在 `~/.brewping/pairing.json`（权限 0600）。
/// 没有引入任何自研加密算法，因此 `ITSAppUsesNonExemptEncryption = false` 仍然成立。
public final class PairingStore {
    public static let shared = PairingStore()

    /// 设备配对成功通知（`POST /api/pair` 换取 token 成功后发出，主线程无关）。
    /// UI 层（Setup Wizard 终步）监听它：配对成功 → 显示成功态并自动进入主界面。
    public static let devicePairedNotification = Notification.Name("brewping.device.paired")

    /// 鉴权结论。放在这里而不是抛错，是为了让 `HTTPAPI` 的调用点保持扁平。
    enum Decision {
        case allowed
        case denied(status: Int, error: String)
    }

    /// 配对码兑换结论。必须把「码错」和「被限速」分开，HTTP 层才能分别回 401 / 429。
    enum ExchangeResult: Equatable {
        case token(String)
        case invalidCode
        case rateLimited(retryAfter: TimeInterval)
    }

    /// 配对码防暴力尝试策略。
    ///
    /// 两个维度：
    ///  - **按来源**：窗口内失败到阈值 → 该来源冷却一段时间；
    ///  - **全局**：所有来源的失败累计到阈值 → 全体冷却，防「换源绕过」。
    ///
    /// 数量级校验：6 位码 = 100 万种，码有效期 10 分钟。单来源 5 次/5 分钟、
    /// 全局 30 次/5 分钟，命中概率可以忽略；代价是攻击者能让合法用户在冷却期内
    /// 暂时配对不上（见 SECURITY.md 的边界说明）。
    struct RateLimitPolicy {
        /// 失败计数窗口
        var window: TimeInterval = 300
        /// 单来源窗口内允许的失败次数，达到即冷却
        var maxFailuresPerSource = 5
        /// 单来源冷却时长
        var sourceCooldown: TimeInterval = 60
        /// 全局窗口内允许的失败次数（所有来源求和）
        var maxFailuresGlobal = 30
        /// 全局冷却时长
        var globalCooldown: TimeInterval = 60
        /// 同时在册的来源上限，超出按「最久未活动」淘汰
        var maxTrackedSources = 256
    }

    private let lock = NSLock()
    private let token: String
    private let clock: () -> Date
    private let policy: RateLimitPolicy
    private var pairingCode: String?
    private var pairingCodeIssuedAt: Date?

    /// 配对码有效期
    private let codeValidity: TimeInterval = 600
    /// 允许的客户端时钟偏移（同时也就是重放窗口）
    private let replayWindow: TimeInterval = 120
    /// nonce 记忆上限，防止长时间运行后无限增长
    private let maxNonces = 2048

    private var seenNonces: [String: Date] = [:]

    /// 某个来源的失败记录。
    private struct FailureRecord {
        var failures: [Date] = []
        var blockedUntil: Date?
        var lastSeen: Date
    }

    private var failuresBySource: [String: FailureRecord] = [:]
    private var globalFailures: [Date] = []
    private var globalBlockedUntil: Date?

    private convenience init() {
        self.init(token: PairingStore.loadOrCreateToken())
    }

    /// 测试专用初始化：直接注入 token / 时钟 / 策略，**不读也不写** `~/.brewping`。
    /// 内部可见即可（`@testable import` 能用），不对外暴露。
    init(
        token: String,
        clock: @escaping () -> Date = { Date() },
        policy: RateLimitPolicy = RateLimitPolicy()
    ) {
        self.token = token
        self.clock = clock
        self.policy = policy
    }

    // MARK: - Pairing code

    /// 生成（或复用未过期的）配对码，供菜单栏 UI 展示。
    public func issuePairingCode() -> String {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        if let pairingCode, let issued = pairingCodeIssuedAt,
           now.timeIntervalSince(issued) < codeValidity {
            return pairingCode
        }
        return issueCodeLocked(now: now)
    }

    /// 强制作废当前配对码并立刻生成一个新的。
    ///
    /// 与 `issuePairingCode()` 的区别：后者会复用未过期的码，前者无脑轮换。
    /// 用于菜单栏上的"Refresh"按钮 —— 用户想换码（比如怀疑泄露）时一键换。
    /// 旧的码立即失效，已经换过 token 的设备不受影响（token 与码无关）。
    @discardableResult
    public func regeneratePairingCode() -> String {
        lock.lock(); defer { lock.unlock() }
        return issueCodeLocked(now: clock())
    }

    public var pairingCodeExpiry: Date? {
        lock.lock(); defer { lock.unlock() }
        guard let issued = pairingCodeIssuedAt else { return nil }
        return issued.addingTimeInterval(codeValidity)
    }

    private func issueCodeLocked(now: Date) -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        pairingCode = code
        pairingCodeIssuedAt = now
        return code
    }

    /// 用配对码换 token。配对码一次性：换过立刻作废，避免被重复使用。
    ///
    /// - Parameter source: 对端地址（内核提供的连接信息，非请求头）。用于失败限速分桶；
    ///   传 nil 时所有无来源的请求（如中继隧道）共用同一个桶。
    func exchange(code input: String, source: String? = nil) -> ExchangeResult {
        lock.lock(); defer { lock.unlock() }
        let now = clock()

        // 限速判定必须在比对之前：被冷却的来源连"试"的机会都没有，
        // 也就不会推进任何计数。
        if let retryAfter = cooldownRemainingLocked(source: source, now: now) {
            return .rateLimited(retryAfter: retryAfter)
        }

        // 没有可兑换的码（未生成 / 已过期 / 已被消费）时直接失败，且**不计数**：
        // 猜一个不存在的目标不可能成功，计次只会让攻击者更容易把合法用户锁在门外。
        guard let pairingCode, let issued = pairingCodeIssuedAt,
              now.timeIntervalSince(issued) < codeValidity else {
            return .invalidCode
        }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PairingStore.constantTimeEquals(trimmed, pairingCode) else {
            recordFailureLocked(source: source, now: now)
            return .invalidCode
        }

        self.pairingCode = nil
        self.pairingCodeIssuedAt = nil
        // 配对成功即清掉该来源的失败记录：正常用户偶尔手滑不该带着惩罚。
        failuresBySource.removeValue(forKey: Self.sourceKey(source))
        return .token(token)
    }

    // MARK: - Rate limiting

    /// 所有来源键归一：nil 走同一个 "unknown" 桶，避免「没地址就不限速」的缺口。
    private static func sourceKey(_ source: String?) -> String {
        guard let source, !source.isEmpty else { return "unknown" }
        return source
    }

    /// 返回剩余冷却秒数；无冷却返回 nil。顺带清理已过期的冷却标记。
    private func cooldownRemainingLocked(source: String?, now: Date) -> TimeInterval? {
        if let until = globalBlockedUntil {
            if until > now { return until.timeIntervalSince(now) }
            globalBlockedUntil = nil
        }
        let key = Self.sourceKey(source)
        guard var record = failuresBySource[key], let until = record.blockedUntil else {
            return nil
        }
        if until > now { return until.timeIntervalSince(now) }
        record.blockedUntil = nil
        failuresBySource[key] = record
        return nil
    }

    private func recordFailureLocked(source: String?, now: Date) {
        let cutoff = now.addingTimeInterval(-policy.window)
        let key = Self.sourceKey(source)

        var record = failuresBySource[key] ?? FailureRecord(lastSeen: now)
        record.failures = record.failures.filter { $0 > cutoff }
        record.failures.append(now)
        record.lastSeen = now
        if record.failures.count >= policy.maxFailuresPerSource {
            record.blockedUntil = now.addingTimeInterval(policy.sourceCooldown)
            // 触发后清空窗口：冷却结束就是一轮新的配额，不会「一解封立刻再封」。
            record.failures.removeAll()
        }
        failuresBySource[key] = record

        globalFailures = globalFailures.filter { $0 > cutoff }
        globalFailures.append(now)
        if globalFailures.count >= policy.maxFailuresGlobal {
            globalBlockedUntil = now.addingTimeInterval(policy.globalCooldown)
            globalFailures.removeAll()
        }

        pruneLocked(now: now)
    }

    /// 限速状态的有界性：清掉「窗口已过且无冷却」的条目，再按上限淘汰最久未活动的。
    private func pruneLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-policy.window)
        for key in Array(failuresBySource.keys) {
            guard let record = failuresBySource[key] else { continue }
            let blockExpired = (record.blockedUntil ?? .distantPast) <= now
            if blockExpired, record.failures.allSatisfy({ $0 <= cutoff }) {
                failuresBySource.removeValue(forKey: key)
            }
        }

        guard failuresBySource.count > policy.maxTrackedSources else { return }
        let overflow = failuresBySource.count - policy.maxTrackedSources
        let ordered = failuresBySource.sorted { lhs, rhs in
            let lhsBlocked = (lhs.value.blockedUntil ?? .distantPast) > now
            let rhsBlocked = (rhs.value.blockedUntil ?? .distantPast) > now
            // 先淘汰没在冷却里的（冷却中的条目是正在生效的防护，留到最后）
            if lhsBlocked != rhsBlocked { return !lhsBlocked }
            return lhs.value.lastSeen < rhs.value.lastSeen
        }
        for entry in ordered.prefix(overflow) {
            failuresBySource.removeValue(forKey: entry.key)
        }
    }

    /// 仅用于测试断言「限速状态不会无限增长」；不参与任何运行时逻辑。
    var trackedSourceCount: Int {
        lock.lock(); defer { lock.unlock() }
        return failuresBySource.count
    }

    // MARK: - Authorization

    func authorize(_ request: HTTPRequest) -> Decision {
        let header = request.headers["authorization"] ?? ""
        guard header.count > "Bearer ".count,
              header.lowercased().hasPrefix("bearer ") else {
            return .denied(status: 401, error: "missing bearer token")
        }
        let presented = String(header.dropFirst("Bearer ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard PairingStore.constantTimeEquals(presented, token) else {
            return .denied(status: 401, error: "invalid token")
        }

        // 只读请求不校验时间戳/nonce：GET 不产生副作用，重放无害，
        // 而 iOS 侧的 Watch 链路会频繁轮询状态，加 nonce 只会徒增开销。
        guard request.method != "GET" else { return .allowed }

        guard let rawTimestamp = request.headers["x-brewping-timestamp"],
              let timestamp = TimeInterval(rawTimestamp),
              let nonce = request.headers["x-brewping-nonce"],
              !nonce.isEmpty else {
            return .denied(status: 401, error: "missing timestamp/nonce")
        }

        let skew = abs(Date().timeIntervalSince1970 - timestamp)
        guard skew <= replayWindow else {
            return .denied(status: 401, error: "stale request")
        }

        lock.lock()
        pruneNoncesLocked()
        let replayed = seenNonces[nonce] != nil
        if !replayed {
            seenNonces[nonce] = Date()
        }
        lock.unlock()

        return replayed ? .denied(status: 401, error: "replayed nonce") : .allowed
    }

    private func pruneNoncesLocked() {
        // 过期 nonce 直接清掉；若仍超过上限，按时间淘汰最旧的一半。
        let cutoff = Date().addingTimeInterval(-replayWindow)
        seenNonces = seenNonces.filter { $0.value > cutoff }
        guard seenNonces.count > maxNonces else { return }
        let ordered = seenNonces.sorted { $0.value < $1.value }
        for entry in ordered.prefix(ordered.count / 2) {
            seenNonces.removeValue(forKey: entry.key)
        }
    }

    // MARK: - Token persistence

    private struct Stored: Codable {
        var token: String
        var createdAt: Date
    }

    private static var fileURL: URL {
        SessionManager.shared.directory.appendingPathComponent("pairing.json")
    }

    private static func loadOrCreateToken() -> String {
        let url = fileURL
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           stored.token.count >= 32 {
            return stored.token
        }
        let token = randomToken()
        let stored = Stored(token: token, createdAt: Date())
        if let data = try? JSONEncoder().encode(stored) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: [.atomic])
            // 只有当前用户可读：token 等价于这台 Mac 的命令执行权限。
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
        return token
    }

    /// 32 字节系统随机数（`UInt8.random` 走系统 CSPRNG）。
    private static func randomToken() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// 定长比较，避免按字节提前返回泄露 token 前缀。
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard !a.isEmpty, a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in 0..<a.count {
            diff |= a[index] ^ b[index]
        }
        return diff == 0
    }
}
