import XCTest
@testable import Clak

final class PadPointerAccumulatorTests: XCTestCase {

    func testFractionsCarryUntilWholeCounts() {
        var acc = PadPointerAccumulator()
        acc.add(dx: 0.6, dy: -0.6)
        XCTAssertNil(acc.take())
        acc.add(dx: 0.6, dy: -0.6)
        let chunk = acc.take()
        XCTAssertEqual(chunk?.dx, 1)
        XCTAssertEqual(chunk?.dy, -1)
    }

    func testOverflowSplitsWithoutLosingMotion() {
        var acc = PadPointerAccumulator()
        acc.add(dx: 300, dy: -130)
        var sumX = 0, sumY = 0
        while let chunk = acc.take() {
            XCTAssertTrue((-127...127).contains(Int(chunk.dx)))
            XCTAssertTrue((-127...127).contains(Int(chunk.dy)))
            sumX += Int(chunk.dx)
            sumY += Int(chunk.dy)
        }
        XCTAssertEqual(sumX, 300)
        XCTAssertEqual(sumY, -130)
    }

    /// Models BLEHIDPeripheralManager + PendingReportQueue: one report goes
    /// out per connection event; anything sent while the link is busy is
    /// queued (merged with a queued mouse report) and the call returns false.
    func testThousandMovesOnASlowLinkKeepAtMostOneQueuedReportAndLoseNoMotion() {
        let scheduler = ManualTickScheduler()
        var busy = false
        var queued: (dx: Int, dy: Int)?
        var queuedReportsSinceDrain = 0
        var worstQueued = 0
        var deliveredX = 0, deliveredY = 0
        let sender = PadPointerSender(scheduler: scheduler) { dx, dy in
            guard busy else {
                busy = true
                deliveredX += Int(dx)
                deliveredY += Int(dy)
                return true
            }
            queued = ((queued?.dx ?? 0) + Int(dx), (queued?.dy ?? 0) + Int(dy))
            queuedReportsSinceDrain += 1
            worstQueued = max(worstQueued, queuedReportsSinceDrain)
            return false
        }
        func drain() {
            if let q = queued {
                deliveredX += q.dx
                deliveredY += q.dy
                queued = nil
            }
            busy = false
            queuedReportsSinceDrain = 0
        }

        var inputX = 0.0, inputY = 0.0
        for i in 0..<1000 {
            scheduler.advance(to: Double(i) * 0.001)
            if i % 25 == 0 { drain() } // a congested link: one slot per 25 ms
            let dx = Double(i % 7) - 2.5, dy = 1.25
            inputX += dx
            inputY += dy
            sender.move(dx: dx, dy: dy)
        }
        drain()
        sender.flush()
        drain()

        XCTAssertLessThanOrEqual(worstQueued, 1, "a busy link gets at most one queued report")
        XCTAssertLessThan(abs(Double(deliveredX) - inputX), 1, "only a sub-count remainder is held back")
        XCTAssertLessThan(abs(Double(deliveredY) - inputY), 1)
    }

    func testFlushSendsEverythingAtOnce() {
        let scheduler = ManualTickScheduler()
        var sent: [Int8] = []
        let sender = PadPointerSender(scheduler: scheduler) { dx, _ in
            sent.append(dx)
            return true
        }
        sender.move(dx: 5, dy: 0)
        sender.move(dx: 200, dy: 0)
        sender.flush()
        XCTAssertEqual(sent.map(Int.init).reduce(0, +), 205)
    }
}
