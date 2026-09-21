import XCTest
@testable import BrewPingCore

// ─── 对话执行状态机的不变量测试 ───────────────────────────────────────────────
//
// 全部走纯逻辑、注入固定时间，不依赖真实命令执行，因此确定性可重复。
// 覆盖的都是**实际踩过或极易踩**的坑：流式回退、过时帧覆盖、把「还没收首字」
// 和「已经在生成」混为一谈、停止后状态卡住。

final class ConversationRunTests: XCTestCase {

    /// 固定基准时间（避免 Date() 造成的抖动）。
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRun(text: String = "hello") -> ConversationRun {
        ConversationRun(
            submitting: "cmd-1",
            conversationId: "conv-1",
            text: text,
            now: t0
        )
    }

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    // MARK: 初始态

    func testInitialPhaseIsSubmittingWithOptimisticUserText() {
        let run = makeRun()
        XCTAssertEqual(run.phase, .submitting)
        XCTAssertEqual(run.pendingUserText, "hello")
        XCTAssertEqual(run.commandId, "cmd-1")
        XCTAssertEqual(run.conversationId, "conv-1")
        XCTAssertTrue(run.phase.isActive)
        XCTAssertFalse(run.phase.isTerminal)
        XCTAssertNil(run.firstTokenAt)
        // 提交阶段不给「停止」：后端还没拿到命令，停了也无意义。
        XCTAssertFalse(run.indicator(now: t0).showsStop)
    }

    // MARK: 正常流转：submitting → queued → thinking → streaming

    func testHappyPathTransitions() {
        var run = makeRun()

        run.markQueued(now: at(0.3))
        XCTAssertEqual(run.phase, .queued)
        XCTAssertEqual(run.indicator(now: at(1)).kind, .queued)

        // queued 之后、首字之前 —— 语义上是 thinking（命令已启动、尚无输出）
        XCTAssertEqual(run.indicator(now: at(2)).kind, .queued)

        run.applyDelta("你", done: false, now: at(3))
        XCTAssertEqual(run.phase, .streaming)
        XCTAssertEqual(run.firstTokenAt, at(3))
        XCTAssertEqual(run.indicator(now: at(3)).kind, .streaming)

        run.applyDelta("你好", done: false, now: at(4))
        XCTAssertEqual(run.text, "你好")
        XCTAssertEqual(run.phase, .streaming)
        // 关键：已在 streaming 时继续收增量，绝不回退到 thinking。
        XCTAssertNotEqual(run.indicator(now: at(4)).kind, .thinking)
    }

    func testFirstTokenNeverRevertsToThinking() {
        var run = makeRun()
        run.markQueued(now: at(0.2))
        run.applyDelta("a", done: false, now: at(1))
        XCTAssertEqual(run.phase, .streaming)

        // 后续每一帧都保持 streaming
        for (i, s) in ["ab", "abc", "abcd"].enumerated() {
            run.applyDelta(s, done: false, now: at(Double(i) + 2))
            XCTAssertEqual(run.phase, .streaming, "第 \(i) 帧后阶段回退了")
        }
        XCTAssertEqual(run.text, "abcd")
    }

    // MARK: 重复 / 过时 / 乱序

    func testDuplicateDeltaIsIgnored() {
        var run = makeRun()
        run.applyDelta("你好", done: false, now: at(1))
        XCTAssertFalse(run.applyDelta("你好", done: false, now: at(2)))
        XCTAssertEqual(run.lastActivityAt, at(1), "重复帧不应刷新活动时间")
    }

    func testStalePrefixDeltaIsIgnored() {
        var run = makeRun()
        run.applyDelta("你好世界", done: false, now: at(1))
        // 更早的快照（当前文本的严格前缀）→ 必须丢弃，否则长回复会「倒退」
        XCTAssertFalse(run.applyDelta("你好", done: false, now: at(2)))
        XCTAssertEqual(run.text, "你好世界")
        XCTAssertEqual(run.lastActivityAt, at(1))
    }

    func testDoneFrameIsAlwaysAccepted() {
        var run = makeRun()
        run.applyDelta("部分", done: false, now: at(1))
        // 终态帧即使是「相同」或「更短」也必须接受：它就是权威全文
        XCTAssertTrue(run.applyDelta("部分", done: true, now: at(2)))
        XCTAssertTrue(run.applyDelta("最终完整全文", done: true, now: at(3)))
        XCTAssertEqual(run.text, "最终完整全文")
    }

    func testEmptyDeltaIsIgnored() {
        var run = makeRun()
        XCTAssertFalse(run.applyDelta("", done: false, now: at(1)))
        XCTAssertFalse(run.applyDelta("", done: true, now: at(2)))
    }

    // MARK: 卡住感：8s 仍无首字 / 30s 无新增量

    func testIndicatorBecomesWaitingLongAfter8Seconds() {
        var run = makeRun()
        run.markQueued(now: at(0.2))
        // queued 阶段（命令已入队、尚未启动执行）文案按「已排队」展示，不套用 8s 阈值
        XCTAssertEqual(run.indicator(now: at(7)).kind, .queued)
        // 走到 thinking（命令已启动）后，8s 阈值生效
        var thinking = makeRun()
        thinking.markQueued(now: at(0.1))
        thinking.phase = .thinking
        thinking.lastActivityAt = at(0.1)
        XCTAssertEqual(thinking.indicator(now: at(5)).kind, .thinking)
        XCTAssertEqual(thinking.indicator(now: at(9)).kind, .waitingLong)
        // 长等待阶段必须给出可执行出口
        XCTAssertTrue(thinking.indicator(now: at(9)).showsTerminal)
        XCTAssertTrue(thinking.indicator(now: at(9)).showsStop)
    }

    func testStallAfter30SecondsSilence() {
        var run = makeRun()
        run.markQueued(now: at(0.1))
        run.applyDelta("开始输出", done: false, now: at(1))

        // 29s 无增量：还没到阈值
        XCTAssertFalse(run.refreshStall(now: at(30)))
        XCTAssertEqual(run.phase, .streaming)

        // 31s 无增量：进入 stalled（后台命令仍未结束）
        XCTAssertTrue(run.refreshStall(now: at(32)))
        XCTAssertEqual(run.phase, .stalled)
        let ind = run.indicator(now: at(32))
        XCTAssertEqual(ind.kind, .stalled)
        XCTAssertTrue(ind.showsStop)
        XCTAssertTrue(ind.showsTerminal)
        XCTAssertEqual(ind.sinceLastOutputSeconds, 31)
    }

    func testStalledRecoversToStreamingOnNewDelta() {
        var run = makeRun()
        run.markQueued(now: at(0.1))
        run.applyDelta("部分", done: false, now: at(1))
        run.refreshStall(now: at(35))
        XCTAssertEqual(run.phase, .stalled)

        // 迟到的增量到达 → 必须能回到 streaming，而不是卡在 stalled
        run.applyDelta("部分+更多", done: false, now: at(36))
        XCTAssertEqual(run.phase, .streaming)
    }

    func testStallDetectionOnlyAppliesToActiveNonStoppingPhases() {
        var submitting = makeRun()
        XCTAssertFalse(submitting.refreshStall(now: at(100)), "提交阶段不应判为 stalled")

        var stopping = makeRun()
        stopping.markQueued(now: at(0.1))
        stopping.requestStop(now: at(1))
        XCTAssertFalse(stopping.refreshStall(now: at(100)), "停止请求阶段不应被 stalled 覆盖")
        XCTAssertEqual(stopping.phase, .stopping)
    }

    // MARK: 停止

    func testStoppingThenConfirmTimeout() {
        var run = makeRun()
        run.markQueued(now: at(0.1))
        run.applyDelta("输出中", done: false, now: at(1))

        run.requestStop(now: at(2))
        XCTAssertEqual(run.phase, .stopping)
        XCTAssertEqual(run.stopRequestedAt, at(2))

        let early = run.indicator(now: at(5))
        XCTAssertEqual(early.kind, .stopping)
        XCTAssertFalse(early.showsStop, "停止请求期间应禁用重复点击")

        let late = run.indicator(now: at(15))
        XCTAssertEqual(late.kind, .stopConfirmTimeout)
        XCTAssertTrue(late.showsStop, "超时未确认后应允许再次尝试停止")
    }

    func testRequestStopIsIdempotent() {
        var run = makeRun()
        run.markQueued(now: at(0.1))
        run.requestStop(now: at(2))
        run.requestStop(now: at(3))
        XCTAssertEqual(run.stopRequestedAt, at(2), "重复点击停止不应重置计时")
    }

    func testStoppingStillAcceptsStreamingDelta() {
        var run = makeRun()
        run.markQueued(now: at(0.1))
        run.applyDelta("第一段", done: false, now: at(1))
        run.requestStop(now: at(2))
        // 停止请求期间命令可能仍在吐字，内容要照收，但阶段保持 stopping
        XCTAssertTrue(run.applyDelta("第一段+尾段", done: false, now: at(3)))
        XCTAssertEqual(run.text, "第一段+尾段")
        XCTAssertEqual(run.phase, .stopping)
    }

    // MARK: 终态

    func testTerminalStatesRejectFurtherDelta() {
        for success in [true, false] {
            var run = makeRun()
            run.markQueued(now: at(0.1))
            run.applyDelta("输出", done: false, now: at(1))
            run.finish(success: success, now: at(2))
            XCTAssertEqual(run.phase, success ? .completed : .failed)
            XCTAssertTrue(run.phase.isTerminal)

            let before = run.text
            XCTAssertFalse(run.applyDelta("迟到的增量", done: false, now: at(3)))
            XCTAssertEqual(run.text, before, "终态后不得再改写文本")
        }
    }

    func testFinishFromTranscriptRoleMapping() {
        var ok = makeRun()
        ok.finishFromTranscript(role: "assistant", now: at(5))
        XCTAssertEqual(ok.phase, .completed)

        var bad = makeRun()
        bad.finishFromTranscript(role: "error", now: at(5))
        XCTAssertEqual(bad.phase, .failed)
    }

    func testMarkQueuedDoesNotOverrideTerminalPhase() {
        var run = makeRun()
        run.finish(success: true, now: at(1))
        run.markQueued(now: at(2))
        XCTAssertEqual(run.phase, .completed, "终态不应被迟到的 queued 事件改写")
    }

    // MARK: 时间派生

    func testElapsedAndSilence() {
        var run = makeRun()
        run.markQueued(now: at(0.5))
        run.applyDelta("首字", done: false, now: at(10))

        XCTAssertEqual(run.elapsedSeconds(now: at(25)), 25)
        XCTAssertEqual(run.sinceLastOutputSeconds(now: at(25)), 15)
        XCTAssertNil(makeRun().sinceLastOutputSeconds(now: at(5)), "尚无输出时不应给出「最后输出」时间")
    }
}
