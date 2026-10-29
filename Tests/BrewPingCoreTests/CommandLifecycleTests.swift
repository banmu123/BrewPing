import XCTest
@testable import BrewPingCore

// ─── 命令生命周期（iOS 提交通道）的回归测试 ─────────────────────────────────
//
// 覆盖的是本次修复的核心不变量：
//  **一条命令没进终态，通道就占用** —— 发送中、等审批、关窗后跟踪、执行中都不允许
//  新命令把旧命令从跟踪里挤掉。
//
// 状态机放在 `Sources/Protocol/CommandLifecycle.swift`（纯逻辑、无 UIKit），
// 所以这里能直接覆盖 iPhone 与 Apple Watch 共用的那条闸门，
// 不需要真实网络、真实 Agent，也不需要额外的 Xcode test target。

final class CommandLifecycleTests: XCTestCase {

    // MARK: - 正常路径

    func testFullLifecycleEndsTerminal() {
        var channel = CommandChannel()
        XCTAssertEqual(channel.phase, .idle)
        XCTAssertTrue(channel.acceptsNewCommand)

        let token = channel.begin()
        XCTAssertNotNil(token)
        XCTAssertEqual(channel.phase, .sending)
        XCTAssertTrue(channel.isBusy)

        channel.markDelivered(commandID: "cmd_1")
        XCTAssertEqual(channel.phase, .delivered)
        XCTAssertEqual(channel.commandID, "cmd_1")

        channel.markWorking()
        XCTAssertEqual(channel.phase, .working)

        channel.finish("done", raw: false)
        XCTAssertEqual(channel.phase, .completed("done"))
        XCTAssertTrue(channel.phase.isTerminal)
        XCTAssertFalse(channel.isBusy)
        XCTAssertTrue(channel.acceptsNewCommand)
    }

    func testRawCompletionIsTerminal() {
        var channel = CommandChannel()
        _ = channel.begin()
        channel.finish("raw output", raw: true)
        XCTAssertEqual(channel.phase, .completedRaw("raw output"))
        XCTAssertTrue(channel.phase.isTerminal)
    }

    func testFailureIsTerminalAndFreesChannel() {
        var channel = CommandChannel()
        _ = channel.begin()
        channel.fail("network down")
        XCTAssertEqual(channel.phase, .failed("network down"))
        XCTAssertFalse(channel.isBusy)
        XCTAssertTrue(channel.acceptsNewCommand)
    }

    // MARK: - 并发：执行中 / 审批中都不许插队

    func testSecondSubmitRejectedWhileSending() {
        var channel = CommandChannel()
        _ = channel.begin()
        XCTAssertNil(channel.begin(), "发送中再次提交必须被拒绝")
        XCTAssertEqual(channel.phase, .sending, "被拒绝的提交不能改动阶段")
    }

    func testSecondSubmitRejectedWhileWorking() {
        var channel = CommandChannel()
        _ = channel.begin()
        channel.markDelivered(commandID: "cmd_1")
        channel.markWorking()
        XCTAssertNil(channel.begin())
    }

    func testSubmitRejectedWhileAwaitingApproval() {
        var channel = CommandChannel()
        _ = channel.begin()
        channel.markAwaitingApproval(approvalID: "apv_1")
        XCTAssertEqual(channel.phase, .awaitingApproval)
        XCTAssertTrue(channel.isBusy)
        XCTAssertNil(channel.begin(), "等审批期间不能再发（原先被误设成 idle）")
    }

    func testClosingApprovalSheetKeepsChannelBusy() {
        var channel = CommandChannel()
        _ = channel.begin()
        channel.markAwaitingApproval(approvalID: "apv_1")

        // 用户关掉确认弹窗：不批准也不拒绝，继续跟踪。
        channel.markTrackingApproval()
        XCTAssertEqual(channel.phase, .trackingApproval)
        XCTAssertTrue(channel.isBusy, "关窗后仍要占用通道，否则旧命令会变成孤儿")
        XCTAssertNil(channel.begin())
    }

    func testTrackingApprovalOnlyFromAwaitingApproval() {
        var channel = CommandChannel()
        _ = channel.begin()
        channel.markDelivered(commandID: "cmd_1")
        channel.markTrackingApproval()
        XCTAssertEqual(channel.phase, .delivered, "执行中不能被误标成审批态")
    }

    func testApprovalResolvedToCommandKeepsTracking() {
        var channel = CommandChannel()
        _ = channel.begin()
        channel.markAwaitingApproval(approvalID: "apv_1")
        channel.markTrackingApproval()
        // 关窗后审批在电脑上被通过：拿到 commandId，继续按命令轮询。
        channel.markDelivered(commandID: "cmd_9")
        XCTAssertEqual(channel.phase, .delivered)
        XCTAssertNil(channel.approvalID)
        XCTAssertEqual(channel.commandID, "cmd_9")
    }

    func testApprovalWithoutResultFreesChannel() {
        var channel = CommandChannel()
        _ = channel.begin()
        channel.markAwaitingApproval(approvalID: "apv_1")
        channel.markTrackingApproval()
        channel.fail("approval ended without a result")
        XCTAssertTrue(channel.phase.isTerminal)
        XCTAssertTrue(channel.acceptsNewCommand)
    }

    // MARK: - 多入口竞争（iPhone + Watch）

    func testOnlyOneOfManySimultaneousSubmissionsWins() {
        var channel = CommandChannel()
        var accepted = 0
        // 模拟两个入口连续抢通道：只有第一次能拿到 token。
        for _ in 0..<20 where channel.begin() != nil {
            accepted += 1
        }
        XCTAssertEqual(accepted, 1, "并发提交只能有一条进入通道")
    }

    func testChannelRecoversAfterEachTerminalState() {
        var channel = CommandChannel()

        _ = channel.begin()
        channel.finish("ok", raw: false)
        XCTAssertNotNil(channel.begin(), "完成后应能继续发下一条")

        channel.fail("boom")
        XCTAssertNotNil(channel.begin(), "失败后应能继续发下一条")
    }

    // MARK: - 切换设备 / 取消轮询：过期回调不能写回

    func testResetInvalidatesInFlightToken() {
        var channel = CommandChannel()
        let old = channel.begin()
        XCTAssertNotNil(old)

        channel.reset()
        XCTAssertEqual(channel.phase, .idle)
        XCTAssertFalse(channel.isCurrent(old!), "reset 之后旧 token 必须失效")
        XCTAssertTrue(channel.acceptsNewCommand)
    }

    func testNewCommandInvalidatesPreviousToken() {
        var channel = CommandChannel()
        let first = channel.begin()!
        channel.finish("ok", raw: false)
        let second = channel.begin()!

        XCTAssertFalse(channel.isCurrent(first), "旧命令的回调不能覆盖新命令状态")
        XCTAssertTrue(channel.isCurrent(second))
    }

    func testStaleCallbackCannotOverwriteAfterDeviceSwitch() {
        var channel = CommandChannel()
        let old = channel.begin()!
        // 切设备：reset 后立刻开始新命令。
        channel.reset()
        let new = channel.begin()!

        // 旧请求此时才回来 —— 调用方看到 isCurrent(old) == false 就应丢弃。
        XCTAssertFalse(channel.isCurrent(old))
        XCTAssertTrue(channel.isCurrent(new))
        XCTAssertEqual(channel.phase, .sending)
    }

    // MARK: - 终态后的迟到事件

    func testLateStatusUpdatesIgnoredAfterTerminal() {
        var channel = CommandChannel()
        _ = channel.begin()
        channel.finish("done", raw: false)

        // 迟到的 working / delivered 不应把已完成的状态改回去。
        channel.markWorking()
        channel.markDelivered(commandID: "late")
        XCTAssertEqual(channel.phase, .completed("done"))
    }

    func testFinishClearsApprovalIdentifier() {
        var channel = CommandChannel()
        _ = channel.begin()
        channel.markAwaitingApproval(approvalID: "apv_1")
        XCTAssertEqual(channel.approvalID, "apv_1")

        channel.finish("approved & executed", raw: false)
        XCTAssertNil(channel.approvalID)
    }

    // MARK: - 轮询判定（HTTP 状态 / 命令状态 → 下一步）

    func testQueuedAndSentKeepWaiting() {
        XCTAssertEqual(decide(status: "queued"), .keepWaiting)
        XCTAssertEqual(decide(status: "sent"), .keepWaiting)
    }

    func testWorkingMarksWorking() {
        XCTAssertEqual(decide(status: "working"), .markWorking)
    }

    func testCompletedVariantsCarryText() {
        XCTAssertEqual(
            CommandPollRules.decide(
                httpStatus: 200, status: "completed",
                response: "all good", rawOutput: nil, error: nil
            ),
            .finish("all good", raw: false)
        )
        XCTAssertEqual(
            CommandPollRules.decide(
                httpStatus: 200, status: "completed_with_raw",
                response: nil, rawOutput: "raw body", error: nil
            ),
            .finish("raw body", raw: true)
        )
    }

    func testFailedCarriesError() {
        XCTAssertEqual(
            CommandPollRules.decide(
                httpStatus: 200, status: "failed",
                response: nil, rawOutput: nil, error: "boom"
            ),
            .fail("boom")
        )
    }

    func testUnknownCommandIdIsTerminalNotTransient() {
        // 桌面端重启后 /api/message/{id} 回 404：必须收敛，不能无限重试。
        XCTAssertEqual(
            CommandPollRules.decide(
                httpStatus: 404, status: "working",
                response: nil, rawOutput: nil, error: nil
            ),
            .unknownCommand
        )
    }

    func testServerErrorsAreTransient() {
        XCTAssertEqual(decide(status: nil, http: 500), .transient)
        XCTAssertEqual(decide(status: nil, http: 401), .transient)
    }

    func testUnknownCommandStatusKeepsWaiting() {
        // 桌面端加了新状态而客户端还不认识：继续等，不擅自判失败。
        XCTAssertEqual(decide(status: "queued_v2"), .keepWaiting)
        XCTAssertEqual(decide(status: nil), .keepWaiting)
    }

    // MARK: - 拾取看门狗

    func testPickupWatchdogTriggersOnlyWhileDelivered() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let later = start.addingTimeInterval(CommandPollRules.pickupStallTimeout + 1)

        XCTAssertTrue(
            CommandPollRules.shouldAbandonPickup(phase: .delivered, deliveredSince: start, now: later),
            "投递后长期不被拾取 → 判定失败"
        )
        XCTAssertFalse(
            CommandPollRules.shouldAbandonPickup(
                phase: .working, deliveredSince: start,
                now: start.addingTimeInterval(600)
            ),
            "已开始执行就不再受拾取阈值约束（执行耗时由 agent 决定）"
        )
        XCTAssertFalse(
            CommandPollRules.shouldAbandonPickup(phase: .delivered, deliveredSince: start, now: start.addingTimeInterval(30)),
            "阈值内继续等"
        )
    }

    private func decide(
        status: String?,
        http: Int = 200
    ) -> CommandPollDecision {
        CommandPollRules.decide(
            httpStatus: http, status: status,
            response: nil, rawOutput: nil, error: nil
        )
    }
}
