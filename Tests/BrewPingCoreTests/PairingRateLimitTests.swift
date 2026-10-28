import XCTest
@testable import BrewPingCore

// ─── 配对码防暴力尝试的回归测试 ─────────────────────────────────────────────
//
// 全部走注入时钟 + 独立 `PairingStore` 实例：不读也不写 `~/.brewping`，不碰真实
// token / 配对码，因此可以在开发机上反复跑。HTTP 层只验证状态码映射（401 / 429 /
// 200）与 `Retry-After`，业务判定仍然由 `PairingStore` 负责。

final class PairingRateLimitTests: XCTestCase {

    private let fixedToken = String(repeating: "a", count: 64)

    // MARK: - 基础行为不能被限速破坏

    func testSuccessfulExchangeReturnsToken() {
        let (store, _) = makeStore()
        let code = store.issuePairingCode()
        XCTAssertEqual(store.exchange(code: code, source: "10.0.0.5"), .token(fixedToken))
    }

    func testWrongCodeRejected() {
        let (store, _) = makeStore()
        let code = store.issuePairingCode()
        XCTAssertEqual(store.exchange(code: wrong(code), source: "10.0.0.5"), .invalidCode)
    }

    func testExpiredCodeRejected() {
        let (store, clock) = makeStore()
        let code = store.issuePairingCode()
        clock.advance(601)
        XCTAssertEqual(store.exchange(code: code, source: "10.0.0.5"), .invalidCode)
    }

    func testCodeIsSingleUse() {
        let (store, _) = makeStore()
        let code = store.issuePairingCode()
        XCTAssertEqual(store.exchange(code: code, source: "10.0.0.5"), .token(fixedToken))
        // 配对成功后同一个码再用一次必须失败
        XCTAssertEqual(store.exchange(code: code, source: "10.0.0.5"), .invalidCode)
    }

    func testRegenerateInvalidatesPreviousCode() {
        let (store, _) = makeStore()
        let old = store.issuePairingCode()
        let fresh = store.regeneratePairingCode()
        XCTAssertNotEqual(old, fresh)
        XCTAssertEqual(store.exchange(code: old, source: "10.0.0.5"), .invalidCode)
        XCTAssertEqual(store.exchange(code: fresh, source: "10.0.0.5"), .token(fixedToken))
    }

    // MARK: - 单来源限速

    func testRepeatedFailuresTriggerCooldown() {
        let (store, _) = makeStore(policy: restrictivePolicy())
        let code = store.issuePairingCode()
        let bad = wrong(code)

        for attempt in 1...3 {
            XCTAssertEqual(
                store.exchange(code: bad, source: "192.0.2.10"), .invalidCode,
                "第 \(attempt) 次失败仍应回 401"
            )
        }
        // 达到阈值后进入冷却：连正确的码也先拒绝（否则限速可被「猜中即通过」绕过）
        guard case .rateLimited(let retryAfter) = store.exchange(code: code, source: "192.0.2.10") else {
            return XCTFail("达到阈值后应进入冷却")
        }
        XCTAssertGreaterThan(retryAfter, 0)
        XCTAssertLessThanOrEqual(retryAfter, 60)
    }

    func testCooldownExpiryRestoresNormalBehaviour() {
        let (store, clock) = makeStore(policy: restrictivePolicy())
        let code = store.issuePairingCode()
        let bad = wrong(code)

        for _ in 1...3 { _ = store.exchange(code: bad, source: "192.0.2.10") }
        guard case .rateLimited = store.exchange(code: bad, source: "192.0.2.10") else {
            return XCTFail("冷却期内应被限速")
        }

        clock.advance(61)
        // 冷却结束后：先恢复成「码错」而不是继续 429
        XCTAssertEqual(store.exchange(code: bad, source: "192.0.2.10"), .invalidCode)
        // 且正确的码可以正常配对（码本身还没过期）
        XCTAssertEqual(store.exchange(code: code, source: "192.0.2.10"), .token(fixedToken))
    }

    func testCooldownIsPerSource() {
        let (store, _) = makeStore(policy: restrictivePolicy())
        let code = store.issuePairingCode()
        let bad = wrong(code)

        for _ in 1...3 { _ = store.exchange(code: bad, source: "192.0.2.10") }
        // 另一个来源不受牵连
        XCTAssertEqual(store.exchange(code: bad, source: "192.0.2.11"), .invalidCode)
        XCTAssertEqual(store.exchange(code: code, source: "192.0.2.11"), .token(fixedToken))
    }

    func testSuccessfulPairingClearsFailureHistory() {
        let (store, _) = makeStore(policy: restrictivePolicy())
        let code = store.issuePairingCode()

        _ = store.exchange(code: wrong(code), source: "192.0.2.10")
        _ = store.exchange(code: wrong(code), source: "192.0.2.10")
        XCTAssertEqual(store.exchange(code: code, source: "192.0.2.10"), .token(fixedToken))
        XCTAssertEqual(store.trackedSourceCount, 0, "配对成功应清掉该来源的失败记录")
    }

    // MARK: - 全局兜底

    func testGlobalLimitStopsDistributedGuessing() {
        let (store, _) = makeStore()
        let code = store.issuePairingCode()
        let bad = wrong(code)

        // 6 个来源 × 5 次 = 30 次，正好触发全局阈值
        for index in 0..<6 {
            for _ in 1...5 {
                XCTAssertEqual(store.exchange(code: bad, source: "10.1.0.\(index)"), .invalidCode)
            }
        }

        // 换一个全新来源也拿不到尝试机会 —— 这就是「不只按来源限速」的意义
        guard case .rateLimited = store.exchange(code: code, source: "10.9.9.9") else {
            return XCTFail("全局阈值触发后，新来源也应被限速")
        }
    }

    // MARK: - 并发与状态有界

    func testConcurrentAttemptsCannotBypassCounter() {
        let (store, _) = makeStore()
        let code = store.issuePairingCode()
        let bad = wrong(code)
        let results = LockedBox<[PairingStore.ExchangeResult]>([])

        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            let result = store.exchange(code: bad, source: "192.0.2.77")
            results.with { $0.append(result) }
        }

        let invalid = results.value.filter { $0 == .invalidCode }.count
        let limited = results.value.filter {
            if case .rateLimited = $0 { return true }
            return false
        }.count

        XCTAssertEqual(invalid, 5, "只有前 5 次能真正参与比对")
        XCTAssertEqual(limited, 35, "其余并发请求必须被限速挡下")
    }

    func testRateLimitStateIsBounded() {
        var policy = PairingStore.RateLimitPolicy()
        policy.maxTrackedSources = 16
        policy.maxFailuresGlobal = 100_000   // 本用例只关心来源列表的增长
        let (store, _) = makeStore(policy: policy)
        let code = store.issuePairingCode()
        let bad = wrong(code)

        for index in 0..<200 {
            _ = store.exchange(code: bad, source: "10.2.\(index / 256).\(index % 256)")
        }
        XCTAssertLessThanOrEqual(store.trackedSourceCount, 16)
    }

    func testFailuresWithoutLiveCodeAreNotCounted() {
        // 没有展示中的配对码时，任何猜测都不可能成功 → 不记账，
        // 避免攻击者在用户还没打开配对页时就把全局冷却打满。
        let (store, _) = makeStore(policy: restrictivePolicy())
        for _ in 0..<20 {
            XCTAssertEqual(store.exchange(code: "123456", source: "192.0.2.99"), .invalidCode)
        }
        XCTAssertEqual(store.trackedSourceCount, 0)
    }

    func testMissingSourceFallsBackToSharedBucket() {
        // 中继隧道没有对端地址：归一到一个桶，仍然受限速保护
        let (store, _) = makeStore(policy: restrictivePolicy())
        let code = store.issuePairingCode()
        let bad = wrong(code)

        for _ in 1...3 { _ = store.exchange(code: bad, source: nil) }
        guard case .rateLimited = store.exchange(code: code, source: nil) else {
            return XCTFail("无来源的请求也必须被限速")
        }
    }

    // MARK: - HTTP 状态码映射

    func testPairEndpointReturnsTokenOnSuccess() throws {
        let store = PairingStore(token: fixedToken)
        let code = store.issuePairingCode()

        let response = HTTPAPI.pairResponse(
            pairRequest(code: code, remote: "192.0.2.10"),
            store: store,
            deviceInfo: { ("dev_test", "Mock Mac") }
        )

        XCTAssertEqual(response.status, 200)
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        )
        XCTAssertEqual(body["token"] as? String, fixedToken)
        XCTAssertEqual(body["deviceId"] as? String, "dev_test")
        XCTAssertEqual(body["deviceName"] as? String, "Mock Mac")
    }

    func testPairEndpointReturns401OnWrongCode() {
        let store = PairingStore(token: fixedToken)
        let code = store.issuePairingCode()
        let response = HTTPAPI.pairResponse(
            pairRequest(code: wrong(code), remote: "192.0.2.10"),
            store: store,
            deviceInfo: { ("dev_test", "Mock Mac") }
        )
        XCTAssertEqual(response.status, 401)
    }

    func testPairEndpointReturns429WithRetryAfter() {
        var policy = PairingStore.RateLimitPolicy()
        policy.maxFailuresPerSource = 3
        let store = PairingStore(token: fixedToken, policy: policy)
        let code = store.issuePairingCode()

        for _ in 1...3 {
            _ = HTTPAPI.pairResponse(
                pairRequest(code: wrong(code), remote: "192.0.2.10"),
                store: store,
                deviceInfo: { ("dev_test", "Mock Mac") }
            )
        }

        let blocked = HTTPAPI.pairResponse(
            pairRequest(code: code, remote: "192.0.2.10"),
            store: store,
            deviceInfo: { ("dev_test", "Mock Mac") }
        )
        XCTAssertEqual(blocked.status, 429)
        let retryAfter = Int(blocked.headers["Retry-After"] ?? "")
        XCTAssertNotNil(retryAfter)
        XCTAssertGreaterThanOrEqual(retryAfter ?? 0, 1)

        // 另一个来源仍可正常配对：限速是分来源 + 全局兜底，不是一刀切封锁
        let other = HTTPAPI.pairResponse(
            pairRequest(code: code, remote: "192.0.2.11"),
            store: store,
            deviceInfo: { ("dev_test", "Mock Mac") }
        )
        XCTAssertEqual(other.status, 200)
    }

    func testPairEndpointRejectsMalformedBody() {
        let store = PairingStore(token: fixedToken)
        let request = HTTPRequest(
            method: "POST", path: "/api/pair", query: nil,
            body: Data("not json".utf8), headers: [:]
        )
        XCTAssertEqual(HTTPAPI.pairResponse(request, store: store).status, 400)
    }

    func testPairEndpointRejectsMissingCodeField() {
        let store = PairingStore(token: fixedToken)
        let request = HTTPRequest(
            method: "POST", path: "/api/pair", query: nil,
            body: Data("{\"deviceName\":\"iPhone\"}".utf8), headers: [:]
        )
        XCTAssertEqual(HTTPAPI.pairResponse(request, store: store).status, 400)
    }

    // MARK: - Helpers

    private func makeStore(
        policy: PairingStore.RateLimitPolicy = PairingStore.RateLimitPolicy()
    ) -> (PairingStore, TestClock) {
        let clock = TestClock()
        let store = PairingStore(token: fixedToken, clock: { clock.now }, policy: policy)
        return (store, clock)
    }

    /// 阈值 3、冷却 60s：比生产默认值更紧，断言更短更确定。
    private func restrictivePolicy() -> PairingStore.RateLimitPolicy {
        var policy = PairingStore.RateLimitPolicy()
        policy.maxFailuresPerSource = 3
        policy.sourceCooldown = 60
        return policy
    }

    private func wrong(_ code: String) -> String {
        code == "000000" ? "111111" : "000000"
    }

    private func pairRequest(code: String, remote: String?) -> HTTPRequest {
        let body = Data("{\"code\":\"\(code)\",\"deviceName\":\"iPhone\"}".utf8)
        return HTTPRequest(
            method: "POST", path: "/api/pair", query: nil,
            body: body,
            headers: ["content-type": "application/json"],
            remoteAddress: remote
        )
    }
}

/// 可推进的测试时钟。闭包在 `PairingStore` 的锁内被调用，这里用独立的锁，
/// 不存在锁序环。
final class TestClock {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = start
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}
