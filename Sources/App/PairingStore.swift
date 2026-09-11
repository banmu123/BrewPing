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
final class PairingStore {
    static let shared = PairingStore()

    /// 鉴权结论。放在这里而不是抛错，是为了让 `HTTPAPI` 的调用点保持扁平。
    enum Decision {
        case allowed
        case denied(status: Int, error: String)
    }

    private let lock = NSLock()
    private let token: String
    private var pairingCode: String?
    private var pairingCodeIssuedAt: Date?

    /// 配对码有效期
    private let codeValidity: TimeInterval = 600
    /// 允许的客户端时钟偏移（同时也就是重放窗口）
    private let replayWindow: TimeInterval = 120
    /// nonce 记忆上限，防止长时间运行后无限增长
    private let maxNonces = 2048

    private var seenNonces: [String: Date] = [:]

    private init() {
        token = PairingStore.loadOrCreateToken()
    }

    // MARK: - Pairing code

    /// 生成（或复用未过期的）配对码，供菜单栏 UI 展示。
    func issuePairingCode() -> String {
        lock.lock(); defer { lock.unlock() }
        if let pairingCode, let issued = pairingCodeIssuedAt,
           Date().timeIntervalSince(issued) < codeValidity {
            return pairingCode
        }
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        pairingCode = code
        pairingCodeIssuedAt = Date()
        return code
    }

    /// 强制作废当前配对码并立刻生成一个新的。
    ///
    /// 与 `issuePairingCode()` 的区别：后者会复用未过期的码，前者无脑轮换。
    /// 用于菜单栏上的"Refresh"按钮 —— 用户想换码（比如怀疑泄露）时一键换。
    /// 旧的码立即失效，已经换过 token 的设备不受影响（token 与码无关）。
    @discardableResult
    func regeneratePairingCode() -> String {
        lock.lock(); defer { lock.unlock() }
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        pairingCode = code
        pairingCodeIssuedAt = Date()
        return code
    }

    var pairingCodeExpiry: Date? {
        lock.lock(); defer { lock.unlock() }
        guard let issued = pairingCodeIssuedAt else { return nil }
        return issued.addingTimeInterval(codeValidity)
    }

    /// 用配对码换 token。配对码一次性：换过立刻作废，避免被重复使用。
    func exchange(code input: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pairingCode, let issued = pairingCodeIssuedAt,
              Date().timeIntervalSince(issued) < codeValidity,
              PairingStore.constantTimeEquals(trimmed, pairingCode) else {
            return nil
        }
        self.pairingCode = nil
        self.pairingCodeIssuedAt = nil
        return token
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
