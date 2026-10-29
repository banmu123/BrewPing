import XCTest
@testable import BrewPingCore

// ─── 审批结果的确定性关联 ───────────────────────────────────────────────────
//
// 要解决的两个具体问题：
//  1. 客户端关掉确认弹窗后，即使**没有 conversationID** 也必须能拿到结果；
//  2. 不允许用「对话转录里最新出现的 commandId」猜命令归属 —— 同一对话里
//     别的设备发一条命令就会把结果认错。
//
// 做法：桌面端按 `approvalID` 记住终态与**实际执行产生的** commandId，
// 客户端查 `GET /api/approvals/{id}`。这里覆盖服务端记录侧与客户端判定侧两个半场。
//
// 测试全部走独立临时文件 + 注入 TTL，不触碰开发机真实的 `~/.brewping/approval.json`，
// 也不需要等真实的 5 分钟超时。

final class ApprovalOutcomeTests: XCTestCase {

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
            .appendingPathComponent("brewping-approval-\(UUID().uuidString).json")
        tempFiles.append(url)
        return ApprovalGate(fileURL: url, pendingTTL: pendingTTL, outcomeTTL: outcomeTTL)
    }

    /// 造一条挂起的审批，返回 (gate, approvalID)。
    private func makePending(
        _ gate: ApprovalGate,
        text: String = "rm -rf /tmp/x",
        conversationID: String? = "conv_a"
    ) -> String {
        switch gate.check(text: text, mode: .safe, conversationID: conversationID) {
        case .pending(let approval):
            return approval.id
        case .allow:
            XCTFail("危险命令必须挂起，实际放行了：\(text)")
            return ""
        }
    }

    // MARK: - 服务端：终态记录

    func testPendingApprovalHasNoOutcomeYet() {
        let gate = makeGate()
        let id = makePending(gate)

        // 还挂着：没有终态记录，但能查到 pending 本身。
        XCTAssertNil(gate.outcome(id: id))
        XCTAssertNotNil(gate.pendingApproval(id: id))
    }

    func testApproveRecordsOutcomeWithoutCommandIDUntilAttached() {
        let gate = makeGate()
        let id = makePending(gate)

        XCTAssertNotNil(gate.decide(id: id, action: "approve"))
        // 已批准 → 立刻有终态，但 commandId 要等执行真正起来才挂上。
        let afterDecide = gate.outcome(id: id)
        XCTAssertEqual(afterDecide?.status, .approved)
        XCTAssertNil(afterDecide?.commandID)
        XCTAssertEqual(afterDecide?.conversationID, "conv_a")

        gate.attachCommand(id: id, commandID: "cmd_42", conversationID: "conv_a")
        let attached = gate.outcome(id: id)
        XCTAssertEqual(attached?.status, .approved)
        XCTAssertEqual(attached?.commandID, "cmd_42")
    }

    func testDenyRecordsDeniedOutcome() {
        let gate = makeGate()
        let id = makePending(gate)

        XCTAssertNotNil(gate.decide(id: id, action: "deny"))
        XCTAssertEqual(gate.outcome(id: id)?.status, .denied)
        XCTAssertNil(gate.outcome(id: id)?.commandID)
        XCTAssertNil(gate.pendingApproval(id: id))
    }

    func testAlwaysApproveRecordsApprovedOutcome() {
        let gate = makeGate()
        let id = makePending(gate, text: "sudo reboot")

        XCTAssertNotNil(gate.decide(id: id, action: "always_approve"))
        XCTAssertEqual(gate.outcome(id: id)?.status, .approved)
    }

    func testUnknownActionConsumesPendingButRecordsFailure() {
        let gate = makeGate()
        let id = makePending(gate)

        // 未知 action 不执行任何东西，但 pending 会被消费（与旧实现 / Windows 端一致）。
        XCTAssertNil(gate.decide(id: id, action: "banana"))
        XCTAssertEqual(gate.outcome(id: id)?.status, .failed)
        XCTAssertTrue(gate.outcome(id: id)?.error?.contains("banana") ?? false)
        XCTAssertNil(gate.pendingApproval(id: id), "不能留下一条永远挂着、却再也点不动的审批")
    }

    func testApprovedButExecutionFailedIsRecordedAsFailed() {
        let gate = makeGate()
        let id = makePending(gate)

        _ = gate.decide(id: id, action: "approve")
        gate.markFailed(id: id, error: "conversation not found")

        XCTAssertEqual(gate.outcome(id: id)?.status, .failed)
        XCTAssertEqual(gate.outcome(id: id)?.error, "conversation not found")
        XCTAssertNil(gate.outcome(id: id)?.commandID)
    }

    func testAttachDoesNotResurrectUnknownApproval() {
        let gate = makeGate()
        gate.attachCommand(id: "apv_never_existed", commandID: "cmd_x", conversationID: nil)
        XCTAssertNil(gate.outcome(id: "apv_never_existed"), "不得为不存在的审批凭空造记录")
    }

    func testExpiredApprovalIsRecordedAndCanNoLongerBeApproved() {
        let gate = makeGate(pendingTTL: 0.05)
        let id = makePending(gate)

        // 超过 TTL：缺席不表态 ≠ 默认放行，也不能再被事后批准。
        Thread.sleep(forTimeInterval: 0.12)
        XCTAssertNil(gate.decide(id: id, action: "approve"), "过期审批不得被执行")
        XCTAssertEqual(gate.outcome(id: id)?.status, .expired)
        XCTAssertNil(gate.pendingApproval(id: id))
    }

    func testOutcomeIsPrunedAfterItsTTL() {
        let gate = makeGate(outcomeTTL: 0.05)
        let id = makePending(gate)
        _ = gate.decide(id: id, action: "deny")
        XCTAssertNotNil(gate.outcome(id: id))

        Thread.sleep(forTimeInterval: 0.12)
        XCTAssertNil(gate.outcome(id: id), "终态记录必须有生命周期，不能无限增长")
    }

    /// 同一时间存在多条待处理审批时，结果必须各自独立。
    func testConcurrentApprovalsKeepIndependentOutcomes() {
        let gate = makeGate()
        let first = makePending(gate, text: "rm -rf /tmp/a", conversationID: "conv_a")
        let second = makePending(gate, text: "sudo reboot", conversationID: "conv_b")
        let third = makePending(gate, text: "git reset --hard HEAD~1", conversationID: nil)
        XCTAssertEqual(Set([first, second, third]).count, 3)

        _ = gate.decide(id: first, action: "approve")
        gate.attachCommand(id: first, commandID: "cmd_first", conversationID: "conv_a")
        _ = gate.decide(id: second, action: "deny")
        _ = gate.decide(id: third, action: "approve")
        gate.attachCommand(id: third, commandID: "cmd_third", conversationID: nil)

        XCTAssertEqual(gate.outcome(id: first)?.commandID, "cmd_first")
        XCTAssertEqual(gate.outcome(id: first)?.status, .approved)
        XCTAssertEqual(gate.outcome(id: second)?.status, .denied)
        XCTAssertNil(gate.outcome(id: second)?.commandID, "拒绝的审批不得带上别人的 commandId")
        XCTAssertEqual(gate.outcome(id: third)?.commandID, "cmd_third")
    }

    /// 同一对话里"另一台设备"也发了命令：它有自己的 approvalID，与本条互不干扰。
    func testAnotherDeviceCommandInSameConversationDoesNotLeakIntoOutcome() {
        let gate = makeGate()
        let mine = makePending(gate, text: "rm -rf /tmp/a", conversationID: "conv_shared")
        let theirs = makePending(gate, text: "rm -rf /tmp/b", conversationID: "conv_shared")

        // 对方的命令先获批并执行
        _ = gate.decide(id: theirs, action: "approve")
        gate.attachCommand(id: theirs, commandID: "cmd_theirs", conversationID: "conv_shared")

        // 我这条还没结论 —— 绝不能因为"同一个对话里出现了新 commandId"就被认领
        XCTAssertEqual(gate.outcome(id: mine), nil)
        XCTAssertNotNil(gate.pendingApproval(id: mine))
        XCTAssertEqual(gate.outcome(id: theirs)?.commandID, "cmd_theirs")
    }

    // MARK: - HTTP 层：GET /api/approvals/{id}

    private func body(of response: HTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }

    func testStatusEndpointReportsPending() {
        let gate = makeGate()
        let id = makePending(gate)

        let response = HTTPAPI.approvalStatusResponse(id, gate: gate)
        XCTAssertEqual(response.status, 200)
        let json = body(of: response)
        XCTAssertEqual(json["status"] as? String, "pending")
        let approval = json["approval"] as? [String: Any]
        XCTAssertEqual(approval?["id"] as? String, id)
    }

    func testStatusEndpointReportsApprovedWithCommandID() {
        let gate = makeGate()
        let id = makePending(gate, conversationID: "conv_z")
        _ = gate.decide(id: id, action: "approve")
        gate.attachCommand(id: id, commandID: "cmd_z", conversationID: "conv_z")

        let response = HTTPAPI.approvalStatusResponse(id, gate: gate)
        XCTAssertEqual(response.status, 200)
        let json = body(of: response)
        XCTAssertEqual(json["status"] as? String, "approved")
        XCTAssertEqual(json["commandId"] as? String, "cmd_z")
        // 没有 conversationID 的客户端也能知道命令落在哪个对话（手表结果回传要用）。
        XCTAssertEqual(json["conversationId"] as? String, "conv_z")
    }

    func testStatusEndpointReportsApprovedEvenBeforeCommandIDIsAttached() {
        let gate = makeGate()
        let id = makePending(gate)
        _ = gate.decide(id: id, action: "approve")

        let json = body(of: HTTPAPI.approvalStatusResponse(id, gate: gate))
        XCTAssertEqual(json["status"] as? String, "approved")
        XCTAssertNil(json["commandId"], "还没挂上 commandId 时不能瞎给一个")
    }

    func testStatusEndpointReportsDeniedAndExpired() {
        let gate = makeGate(pendingTTL: 0.05)
        let denied = makePending(gate, text: "rm -rf /tmp/a")
        _ = gate.decide(id: denied, action: "deny")
        XCTAssertEqual(body(of: HTTPAPI.approvalStatusResponse(denied, gate: gate))["status"] as? String, "denied")

        let expiring = makePending(gate, text: "sudo reboot")
        Thread.sleep(forTimeInterval: 0.12)
        let json = body(of: HTTPAPI.approvalStatusResponse(expiring, gate: gate))
        XCTAssertEqual(json["status"] as? String, "expired")
    }

    func testStatusEndpointReturns404ForUnknownApproval() {
        let gate = makeGate()
        let response = HTTPAPI.approvalStatusResponse("apv_does_not_exist", gate: gate)
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(body(of: response)["error"] as? String, "unknown or expired approval")
    }

    /// 路由优先级：`/api/approvals/mode` 不能被当成一个 approval id。
    func testStatusEndpointRefusesModePath() {
        let gate = makeGate()
        XCTAssertEqual(HTTPAPI.approvalStatusResponse("mode", gate: gate).status, 404)
        XCTAssertEqual(HTTPAPI.approvalStatusResponse("", gate: gate).status, 404)
    }

    /// 幂等：断线重连后重复查询同一 approvalID 必须拿到同一个答案，且不产生副作用，
    /// 也不会让命令被重复执行。
    func testStatusQueryIsIdempotentAcrossReconnects() {
        let gate = makeGate()
        let id = makePending(gate)
        _ = gate.decide(id: id, action: "approve")
        gate.attachCommand(id: id, commandID: "cmd_once", conversationID: nil)

        for _ in 0..<5 {
            let json = body(of: HTTPAPI.approvalStatusResponse(id, gate: gate))
            XCTAssertEqual(json["status"] as? String, "approved")
            XCTAssertEqual(json["commandId"] as? String, "cmd_once")
        }
        // 查询不会把审批"复活"回 pending 队列
        XCTAssertNil(gate.pendingApproval(id: id))
    }

    // MARK: - 客户端判定表

    func testDecodePending() {
        XCTAssertEqual(
            ApprovalOutcomeRules.decode(
                httpStatus: 200, status: "pending", commandID: nil, conversationID: nil, error: nil
            ),
            .pending
        )
    }

    func testDecodeApprovedCarriesCommandIDAndConversation() {
        XCTAssertEqual(
            ApprovalOutcomeRules.decode(
                httpStatus: 200, status: "approved", commandID: "cmd_9",
                conversationID: "conv_9", error: nil
            ),
            .approved(commandID: "cmd_9", conversationID: "conv_9")
        )
    }

    /// 「已批准但 commandId 还没挂上」是毫秒级窗口，必须继续等而不是报失败。
    func testDecodeApprovedWithoutCommandIDKeepsWaiting() {
        XCTAssertEqual(
            ApprovalOutcomeRules.decode(
                httpStatus: 200, status: "approved", commandID: nil, conversationID: nil, error: nil
            ),
            .pending
        )
        XCTAssertEqual(
            ApprovalOutcomeRules.decode(
                httpStatus: 200, status: "approved", commandID: "", conversationID: nil, error: nil
            ),
            .pending
        )
    }

    func testDecodeTerminalStates() {
        XCTAssertEqual(
            ApprovalOutcomeRules.decode(httpStatus: 200, status: "denied", commandID: nil, conversationID: nil, error: nil),
            .denied
        )
        XCTAssertEqual(
            ApprovalOutcomeRules.decode(httpStatus: 200, status: "expired", commandID: nil, conversationID: nil, error: nil),
            .expired
        )
        XCTAssertEqual(
            ApprovalOutcomeRules.decode(httpStatus: 200, status: "failed", commandID: nil, conversationID: nil, error: "boom"),
            .failed("boom")
        )
        XCTAssertEqual(
            ApprovalOutcomeRules.decode(httpStatus: 200, status: "failed", commandID: nil, conversationID: nil, error: nil),
            .failed("")
        )
    }

    func testDecodeUnavailableAndTransient() {
        XCTAssertEqual(
            ApprovalOutcomeRules.decode(httpStatus: 404, status: nil, commandID: nil, conversationID: nil, error: nil),
            .unavailable
        )
        XCTAssertEqual(
            ApprovalOutcomeRules.decode(httpStatus: 500, status: nil, commandID: nil, conversationID: nil, error: nil),
            .transient
        )
        XCTAssertEqual(
            ApprovalOutcomeRules.decode(httpStatus: 0, status: nil, commandID: nil, conversationID: nil, error: nil),
            .transient
        )
    }

    /// 未知 status（新/老桌面端字段漂移）不能擅自判失败。
    func testDecodeUnknownStatusKeepsWaiting() {
        XCTAssertEqual(
            ApprovalOutcomeRules.decode(
                httpStatus: 200, status: "something_new", commandID: "cmd_1",
                conversationID: nil, error: nil
            ),
            .pending
        )
    }

    func testDecodeEmptyConversationIsNormalizedToNil() {
        XCTAssertEqual(
            ApprovalOutcomeRules.decode(
                httpStatus: 200, status: "approved", commandID: "cmd_1",
                conversationID: "", error: nil
            ),
            .approved(commandID: "cmd_1", conversationID: nil)
        )
    }
}
