import XCTest
@testable import BrewPingCore

// ─── 服务端权威执行阶段（HTTP run 快照）的推导不变量 ─────────────────────────
//
// 覆盖的都是任务 §13 的硬性要求：阶段词表来自 `ConversationRun.RunPhase`
//（不发明新状态）、stalled 由桌面端按 `RunTiming.stallSeconds` 权威判定、
// 全部注入固定时间保证确定性。

final class RunPhaseDTOTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(seconds)
    }

    // MARK: 排队 / 终态

    func testQueuedAndSentMapToQueued() {
        XCTAssertEqual(RunPhaseDTO.derive(status: "queued", lastOutputAt: nil, now: now), "queued")
        XCTAssertEqual(RunPhaseDTO.derive(status: "sent", lastOutputAt: nil, now: now), "queued")
    }

    func testTerminalStatusesMapToCompletedOrFailed() {
        XCTAssertEqual(RunPhaseDTO.derive(status: "completed", lastOutputAt: nil, now: now), "completed")
        // Windows 侧 rawValue 是 completed_with_raw，Mac 是 completedWithRaw —— 都映射
        XCTAssertEqual(RunPhaseDTO.derive(status: "completed_with_raw", lastOutputAt: nil, now: now), "completed")
        XCTAssertEqual(RunPhaseDTO.derive(status: "completedWithRaw", lastOutputAt: nil, now: now), "completed")
        XCTAssertEqual(RunPhaseDTO.derive(status: "failed", lastOutputAt: nil, now: now), "failed")
    }

    // MARK: working 的三态

    func testWorkingWithoutOutputIsThinking() {
        XCTAssertEqual(RunPhaseDTO.derive(status: "working", lastOutputAt: nil, now: now), "thinking")
    }

    func testWorkingWithFreshOutputIsStreaming() {
        XCTAssertEqual(RunPhaseDTO.derive(status: "working", lastOutputAt: at(-1), now: now), "streaming")
        // 阈值边界内（< 30s）仍是 streaming
        XCTAssertEqual(
            RunPhaseDTO.derive(status: "working", lastOutputAt: at(-29), now: now),
            "streaming"
        )
    }

    func testWorkingWithSilentOutputIsStalled_desktopAuthoritative() {
        // 阈值边界：>= 30s 无新增量 → stalled（由桌面端判定，不是客户端猜）
        XCTAssertEqual(
            RunPhaseDTO.derive(status: "working", lastOutputAt: at(-30), now: now),
            "stalled"
        )
        XCTAssertEqual(
            RunPhaseDTO.derive(status: "working", lastOutputAt: at(-3_600), now: now),
            "stalled"
        )
    }

    // MARK: 未知状态

    func testUnknownStatusMapsToIdle() {
        XCTAssertEqual(RunPhaseDTO.derive(status: "something_new", lastOutputAt: nil, now: now), "idle")
    }

    // MARK: RunStatusTracker（内存登记）

    func testTrackerRecordsAndReturnsLastOutput() {
        let tracker = RunStatusTracker()
        let at = Date(timeIntervalSince1970: 1_700_000_100)
        tracker.recordOutput(commandId: "cmd-t", at: at)
        XCTAssertEqual(tracker.lastOutputAt(commandId: "cmd-t"), at)
        XCTAssertNil(tracker.lastOutputAt(commandId: "cmd-never"))
    }
}
