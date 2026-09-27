import XCTest
@testable import Clak

final class PadScrollAccumulatorTests: XCTestCase {

    func testPreciseDeltasBecomeLinesWithRemainderCarried() {
        var acc = PadScrollAccumulator()
        acc.add(deltaY: 7, isPrecise: true, phase: .changed)
        XCTAssertEqual(acc.takeLines(), 0, "7 px is under a line")
        acc.add(deltaY: 7, isPrecise: true, phase: .changed)
        XCTAssertEqual(acc.takeLines(), 1)
        acc.add(deltaY: 6, isPrecise: true, phase: .changed)
        XCTAssertEqual(acc.takeLines(), 1, "4 px carried + 6 px = one more line")
        XCTAssertEqual(acc.takeLines(), 0)
    }

    func testNegativeDeltasCarryTowardZero() {
        var acc = PadScrollAccumulator()
        acc.add(deltaY: -25, isPrecise: true, phase: .changed)
        XCTAssertEqual(acc.takeLines(), -2)
        acc.add(deltaY: -5, isPrecise: true, phase: .changed)
        XCTAssertEqual(acc.takeLines(), -1)
    }

    func testNonPreciseDeltasAreAlreadyLines() {
        var acc = PadScrollAccumulator()
        acc.add(deltaY: 3, isPrecise: false, phase: .other)
        XCTAssertEqual(acc.takeLines(), 3)
    }

    func testLargeBacklogSplitsAcrossReportsWithinInt8() {
        var acc = PadScrollAccumulator()
        acc.add(deltaY: 200, isPrecise: false, phase: .other)
        XCTAssertEqual(acc.takeLines(), 127)
        XCTAssertEqual(acc.takeLines(), 73)
    }

    func testMomentumIsForwarded() {
        var acc = PadScrollAccumulator()
        acc.add(deltaY: 30, isPrecise: true, phase: .momentum)
        XCTAssertEqual(acc.takeLines(), 3)
    }

    /// A finger landing on the pad stops the Mac's coast; unsent lines from
    /// that coast must not keep scrolling the device.
    func testNewTouchDropsUnsentBacklog() {
        var acc = PadScrollAccumulator()
        acc.add(deltaY: 95, isPrecise: true, phase: .momentum)
        acc.add(deltaY: 0, isPrecise: true, phase: .began)
        XCTAssertEqual(acc.takeLines(), 0)
        acc.add(deltaY: 10, isPrecise: true, phase: .changed)
        XCTAssertEqual(acc.takeLines(), 1, "no stale remainder from before the touch")
    }

    func testHundredSmallEventsOverOneSecondSendThirtyLinesAtMostOnePerTick() {
        let scheduler = ManualTickScheduler()
        var reports: [(time: TimeInterval, wheel: Int8)] = []
        let sender = PadScrollSender(scheduler: scheduler) { wheel in
            reports.append((scheduler.now, wheel))
        }

        for i in 0..<100 {
            scheduler.advance(to: Double(i) * 0.01)
            sender.scroll(deltaY: 3, isPrecise: true, phase: .changed)
        }
        scheduler.advance(by: 1)

        XCTAssertEqual(reports.reduce(0) { $0 + Int($1.wheel) }, 30)
        XCTAssertFalse(reports.contains { $0.wheel == 0 }, "no empty reports")
        for (a, b) in zip(reports, reports.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.time - a.time, PadScrollSender.tickInterval - 1e-9)
        }
    }
}
