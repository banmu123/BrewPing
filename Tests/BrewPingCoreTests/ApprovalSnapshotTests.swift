import XCTest
@testable import BrewPingCore

// ─── 审批状态的原子快照 / 决定响应 / 对话归属 ────────────────────────────────
//
// 这一组覆盖两个已识别的边界问题：
//  1. `GET /api/approvals/{id}` 早期先查终态、再查 pending —— 两次独立加锁。
//     另一台设备在两次读取之间批准/拒绝时，可能两边都查不到而错误返回 404。
//     现在由 `snapshot(id:)` 在一次锁区间内判定三种情形。
//  2. 手机直接批准成功那条路径只拿 commandId，不拿服务端保存的 conversationId，
//     导致（尤其 Watch 来源）的回执缺归属、对不上对话页。

final class ApprovalSnapshotTests: XCTestCase {

    // MARK: - 夹具

    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        tempFiles.removeAll()
        super.tearDown()
    }

    private func makeGate(
        pendingTTL: TimeInterval = 300,
        outcomeTTL: TimeInterval = 900
    ) -> ApprovalGate {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("brewping-snapshot-\(UUID().uuidString).json")
        tempFiles.append(url)
        return ApprovalGate(fileURL: url, pendingTTL: pendingTTL, outcomeTTL: outcomeTTL)
    }

    private func makePending(
        _ gate: ApprovalGate,
        text: String = "rm -rf /tmp/x",
        conversationID: String? = "conv_a"
    ) -> String {
        switch gate.check(text: text, mode: .safe, conversationID: conversationID) {
        case .pending(let approval):
            return approval.id
        case .allow:
            XCTFail("危险命令必须挂起：\(text)")
            return ""
        }
    }

    private func body(of response: HTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }

    /// 线程安全的布尔标记（并发用例只需「是否出现过」）。
    private final class Flag {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    // MARK: - 原子快照

    func testSnapshotReportsPending() {
        let gate = makeGate()
        let id = makePending(gate)

        guard case .pending(let approval) = gate.snapshot(id: id) else {
            return XCTFail("挂在队列里的审批必须报 pending")
        }
        XCTAssertEqual(approval.id, id)
    }

    func testSnapshotReportsResolvedWithCommandID() {
        let gate = makeGate()
        let id = makePending(gate, conversationID: "conv_s")
        _ = gate.decide(id: id, action: "approve")
        gate.attachCommand(id: id, commandID: "cmd_s", conversationID: "conv_s")

        guard case .resolved(let outcome) = gate.snapshot(id: id) else {
            return XCTFail("已批准的审批必须报 resolved")
        }
        XCTAssertEqual(outcome.status, .approved)
        XCTAssertEqual(outcome.commandID, "cmd_s")
    }

    func testSnapshotReportsUnknownForGhost() {
        let gate = makeGate()
        guard case .unknown = gate.snapshot(id: "apv_ghost") else {
            return XCTFail("不存在的审批必须是 unknown（端点据此回 404）")
        }
    }

    func testSnapshotReportsUnknownAfterOutcomeIsPruned() {
        let gate = makeGate(outcomeTTL: 0.05)
        let id = makePending(gate)
        _ = gate.decide(id: id, action: "deny")
        XCTAssertNotNil(gate.outcome(id: id))

        Thread.sleep(forTimeInterval: 0.12)
        guard case .unknown = gate.snapshot(id: id) else {
            return XCTFail("终态记录淘汰后必须是 unknown，而不是一直 denied")
        }
    }

    /// 过期 pending 在快照里直接变成 resolved(.expired)，不会出现"查不到"。
    func testSnapshotReportsExpiredInsteadOfUnknown() {
        let gate = makeGate(pendingTTL: 0.05)
        let id = makePending(gate)
        Thread.sleep(forTimeInterval: 0.12)

        guard case .resolved(let outcome) = gate.snapshot(id: id) else {
            return XCTFail("超时的审批必须报 resolved(.expired)，不能是 unknown")
        }
        XCTAssertEqual(outcome.status, .expired)
    }

    /// 竞态：另一台设备在不停查询的同时批准这条审批。
    ///
    /// 断言的是一个**不变量**（不是碰运气）：只要这条审批创建过，
    /// 任何时刻的快照都只能是 pending 或 resolved，绝不可能是 unknown ——
    /// 后者意味着「已从 pending 移出、终态又还没被看见」的中间态被外部观察到了。
    /// 旧实现（先查终态、再查 pending，两次加锁）在一次 8k 量级的交错里几乎必然命中。
    func testConcurrentApprovalNeverExposesUnknownState() {
        let iterations = 20
        for round in 0..<iterations {
            let gate = makeGate()
            let id = makePending(gate, text: "rm -rf /tmp/race\(round)")

            let sawUnknown = Flag()
            let group = DispatchGroup()

            for _ in 0..<4 {
                group.enter()
                DispatchQueue.global().async {
                    for _ in 0..<100 {
                        if case .unknown = gate.snapshot(id: id) { sawUnknown.set() }
                    }
                    group.leave()
                }
            }
            group.enter()
            DispatchQueue.global().async {
                // 另一台设备：批准 + 补 commandId（这正是真实的两步写入）
                _ = gate.decide(id: id, action: "approve")
                gate.attachCommand(id: id, commandID: "cmd_race\(round)", conversationID: "conv_race")
                group.leave()
            }
            group.wait()

            XCTAssertFalse(sawUnknown.isSet, "审批状态切换期间不得出现 404（unknown）")
            guard case .resolved(let outcome) = gate.snapshot(id: id) else {
                return XCTFail("竞态结束后必须能读到终态")
            }
            XCTAssertEqual(outcome.commandID, "cmd_race\(round)")
        }
    }

    /// 同样的并发交错，换成拒绝：终态必须是 denied，且查询不产生副作用。
    func testConcurrentDenialNeverExposesUnknownState() {
        let iterations = 20
        for round in 0..<iterations {
            let gate = makeGate()
            let id = makePending(gate, text: "git reset --hard HEAD~\(round)")

            let sawUnknown = Flag()
            let group = DispatchGroup()
            for _ in 0..<4 {
                group.enter()
                DispatchQueue.global().async {
                    for _ in 0..<100 {
                        if case .unknown = gate.snapshot(id: id) { sawUnknown.set() }
                    }
                    group.leave()
                }
            }
            group.enter()
            DispatchQueue.global().async {
                _ = gate.decide(id: id, action: "deny")
                group.leave()
            }
            group.wait()

            XCTAssertFalse(sawUnknown.isSet)
            guard case .resolved(let outcome) = gate.snapshot(id: id) else {
                return XCTFail("拒绝后必须能读到终态")
            }
            XCTAssertEqual(outcome.status, .denied)
            // 查询不得把审批复活
            XCTAssertNil(gate.pendingApproval(id: id))
        }
    }

    // MARK: - 端点语义（macOS 侧）

    func testStatusEndpointStateVocabulary() {
        let gate = makeGate()
        let pendingID = makePending(gate, text: "rm -rf /tmp/p")
        XCTAssertEqual(body(of: HTTPAPI.approvalStatusResponse(pendingID, gate: gate))["status"] as? String, "pending")

        let approved = makePending(gate, text: "rm -rf /tmp/a")
        _ = gate.decide(id: approved, action: "approve")
        gate.attachCommand(id: approved, commandID: "cmd_ap", conversationID: "conv_ap")
        let approvedJSON = body(of: HTTPAPI.approvalStatusResponse(approved, gate: gate))
        XCTAssertEqual(approvedJSON["status"] as? String, "approved")
        XCTAssertEqual(approvedJSON["commandId"] as? String, "cmd_ap")
        XCTAssertEqual(approvedJSON["conversationId"] as? String, "conv_ap")

        let denied = makePending(gate, text: "git push --force")
        _ = gate.decide(id: denied, action: "deny")
        XCTAssertEqual(body(of: HTTPAPI.approvalStatusResponse(denied, gate: gate))["status"] as? String, "denied")

        let failed = makePending(gate, text: "sudo reboot")
        _ = gate.decide(id: failed, action: "approve")
        gate.markFailed(id: failed, error: "conversation not found")
        let failedJSON = body(of: HTTPAPI.approvalStatusResponse(failed, gate: gate))
        XCTAssertEqual(failedJSON["status"] as? String, "failed")
        XCTAssertEqual(failedJSON["error"] as? String, "conversation not found")

        // 未知 → 404
        XCTAssertEqual(HTTPAPI.approvalStatusResponse("apv_ghost", gate: gate).status, 404)
    }

    /// 与 Windows `ApprovalOutcomeStatus::as_str()` 必须是同一套词表 —— 两端客户端共用。
    func testOutcomeStatusRawValuesMatchWindowsContract() {
        XCTAssertEqual(ApprovalOutcome.Status.approved.rawValue, "approved")
        XCTAssertEqual(ApprovalOutcome.Status.denied.rawValue, "denied")
        XCTAssertEqual(ApprovalOutcome.Status.expired.rawValue, "expired")
        XCTAssertEqual(ApprovalOutcome.Status.failed.rawValue, "failed")
    }

    // MARK: - 直接批准成功：conversationId 回填

    func testDecisionResponseWithoutConversationIsStillExecuted() {
        // 要求：拿不到 conversationId 不能让一条已受理的命令变成失败。
        XCTAssertEqual(
            ApprovalDecisionRules.decode(
                httpStatus: 200, status: "executed", commandID: "cmd_1",
                conversationID: nil, error: nil
            ),
            .executed(commandID: "cmd_1", conversationID: nil)
        )
        XCTAssertEqual(
            ApprovalDecisionRules.decode(
                httpStatus: 200, status: "executed", commandID: "cmd_1",
                conversationID: "", error: nil
            ),
            .executed(commandID: "cmd_1", conversationID: nil)
        )
    }

    func testDecisionResponseCarriesConversation() {
        XCTAssertEqual(
            ApprovalDecisionRules.decode(
                httpStatus: 200, status: "executed", commandID: "cmd_2",
                conversationID: "conv_2", error: nil
            ),
            .executed(commandID: "cmd_2", conversationID: "conv_2")
        )
    }

    func testDecisionResponseDeniedCarriesConversation() {
        XCTAssertEqual(
            ApprovalDecisionRules.decode(
                httpStatus: 200, status: "denied", commandID: nil,
                conversationID: "conv_d", error: nil
            ),
            .denied(conversationID: "conv_d")
        )
        XCTAssertEqual(
            ApprovalDecisionRules.decode(
                httpStatus: 200, status: "denied", commandID: nil,
                conversationID: nil, error: nil
            ),
            .denied(conversationID: nil)
        )
    }

    func testDecisionResponseUnresolvedAndFailed() {
        XCTAssertEqual(
            ApprovalDecisionRules.decode(
                httpStatus: 404, status: nil, commandID: nil, conversationID: nil, error: nil
            ),
            .unresolved
        )
        XCTAssertEqual(
            ApprovalDecisionRules.decode(
                httpStatus: 200, status: "executed", commandID: nil,
                conversationID: "conv_x", error: nil
            ),
            .failed("HTTP 200")
        )
        XCTAssertEqual(
            ApprovalDecisionRules.decode(
                httpStatus: 500, status: nil, commandID: nil, conversationID: nil, error: "boom"
            ),
            .failed("boom")
        )
    }

    func testAdoptConversationFillsOnlyWhenClientHasNone() {
        // 客户端没有 → 采用服务端的（Watch 语音路径）
        XCTAssertEqual(
            ApprovalDecisionRules.adoptConversation(current: nil, incoming: "conv_server"),
            "conv_server"
        )
        // 空字符串等同于没有
        XCTAssertEqual(
            ApprovalDecisionRules.adoptConversation(current: "", incoming: "conv_server"),
            "conv_server"
        )
        XCTAssertEqual(
            ApprovalDecisionRules.adoptConversation(current: "   ", incoming: "conv_server"),
            "conv_server"
        )
        // 已有有效归属 → 不覆盖（用户正在看的对话不能被远端改掉）
        XCTAssertEqual(
            ApprovalDecisionRules.adoptConversation(current: "conv_local", incoming: "conv_server"),
            "conv_local"
        )
        // 服务端没给 → 保留本地的
        XCTAssertEqual(
            ApprovalDecisionRules.adoptConversation(current: "conv_local", incoming: nil),
            "conv_local"
        )
        // 两边都没有 → 仍为 nil（旧行为）
        XCTAssertNil(ApprovalDecisionRules.adoptConversation(current: nil, incoming: nil))
        XCTAssertNil(ApprovalDecisionRules.adoptConversation(current: nil, incoming: ""))
    }

    /// Watch 回执用的是 `activeConversationId`。直接批准成功时它由这里回填：
    /// 本来为空 → 拿到服务端归属；本来有值 → 保持原样。
    func testWatchReceiptConversationAfterDirectApproval() {
        let serverConversation = "conv_from_server"
        // 场景：Watch 发命令，手机端没有显式对话
        XCTAssertEqual(
            ApprovalDecisionRules.adoptConversation(current: nil, incoming: serverConversation),
            serverConversation,
            "Watch 来源的审批获批后，回执必须带上服务端的对话归属"
        )
        // 场景：用户正在某个对话里发起的，归属不能被远端改掉
        XCTAssertEqual(
            ApprovalDecisionRules.adoptConversation(current: "conv_user_is_in", incoming: serverConversation),
            "conv_user_is_in"
        )
    }
}
