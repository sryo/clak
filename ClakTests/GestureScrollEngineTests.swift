import XCTest
@testable import Clak

final class GestureScrollEngineTests: XCTestCase {

    private final class ManualTicker: FrameTicker {
        var handler: (() -> Void)?
        var leeway: TimeInterval?
        func start(interval: TimeInterval, leeway: TimeInterval, _ handler: @escaping () -> Void) {
            self.leeway = leeway
            self.handler = handler
        }
        func stop() { handler = nil }
    }

    private var now: TimeInterval = 0
    private var posts: [GestureScrollEngine.Post] = []
    private let ticker = ManualTicker()

    private func makeEngine() -> GestureScrollEngine {
        GestureScrollEngine(
            clock: { [unowned self] in self.now },
            sink: { [unowned self] in self.posts.append($0) },
            ticker: ticker
        )
    }

    /// Runs frames at 120 Hz until the engine stops its ticker.
    private func runUntilIdle(maxFrames: Int = 5_000) {
        var frames = 0
        while let handler = ticker.handler, frames < maxFrames {
            now += 1.0 / 120
            handler()
            frames += 1
        }
        XCTAssertNil(ticker.handler, "engine went idle")
    }

    func testMomentumTailPostsNoZeroDeltaEvents() {
        let engine = makeEngine()
        engine.beginMomentum(velocityY: 1_500, velocityX: -200)
        runUntilIdle()

        let tail = posts.filter { $0.momentumPhase == 2 }
        XCTAssertFalse(tail.isEmpty)
        XCTAssertFalse(tail.contains { $0.pointDeltaY == 0 && $0.pointDeltaX == 0 },
                       "every momentum-continue event moves at least a pixel")
        XCTAssertEqual(posts.last?.momentumPhase, 3)
    }

    func testMomentumTotalIsNotLostBySkippingSubPixelFrames() {
        let engine = makeEngine()
        engine.beginMomentum(velocityY: 1_500, velocityX: -200)
        runUntilIdle()
        let fixed = posts.reduce(0.0) { $0 + $1.fixedDeltaY }
        let points = posts.reduce(0) { $0 + Int($1.pointDeltaY) }
        XCTAssertEqual(Double(points), fixed.rounded(.towardZero), accuracy: 1)
    }

    func testTimerGetsLeeway() {
        let engine = makeEngine()
        engine.feed(linesY: 1, linesX: 0)
        XCTAssertGreaterThan(ticker.leeway ?? 0, 0)
    }

    // MARK: - Momentum from real wheel input

    /// Feeds `ticks` wheel ticks `interval` apart, running 120 Hz frames in between.
    private func feedTicks(_ engine: GestureScrollEngine, ticks: Int, interval: TimeInterval, lines: Int = 1) {
        for tick in 0..<ticks {
            engine.feed(linesY: lines, linesX: 0)
            guard tick < ticks - 1 else { break }
            let next = now + interval
            while now + 1.0 / 120 <= next, let handler = ticker.handler {
                now += 1.0 / 120
                handler()
            }
            now = next
        }
    }

    private var momentumBegin: GestureScrollEngine.Post? { posts.first { $0.momentumPhase == 1 } }

    func testFastTickBurstCoasts() {
        let engine = makeEngine()
        feedTicks(engine, ticks: 10, interval: 0.03)
        runUntilIdle()
        XCTAssertNotNil(momentumBegin, "a quick flick of the wheel coasts")
        XCTAssertTrue(posts.contains { $0.momentumPhase == 2 })
        XCTAssertEqual(posts.last?.momentumPhase, 3)
    }

    /// 30 px every 30 ms is 1000 px/s: momentum carries on at the wheel's speed,
    /// not at the leftover trickle of the smoothing buffer.
    func testMomentumStartsNearTheWheelSpeed() throws {
        let engine = makeEngine()
        feedTicks(engine, ticks: 10, interval: 0.03)
        runUntilIdle()
        let begin = try XCTUnwrap(momentumBegin)
        XCTAssertEqual(begin.fixedDeltaY * 120, 1_000, accuracy: 400)
    }

    /// No stall between the last tick and the coast: momentum takes over
    /// within a few intervals of the wheel stopping.
    func testMomentumBeginsSoonAfterTheLastTick() throws {
        let engine = makeEngine()
        feedTicks(engine, ticks: 10, interval: 0.03)
        let lastTick = now
        var beganAt: TimeInterval?
        while let handler = ticker.handler, beganAt == nil {
            now += 1.0 / 120
            handler()
            if momentumBegin != nil { beganAt = now }
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(beganAt) - lastTick, 0.1)
    }

    func testSingleTickDoesNotCoast() {
        let engine = makeEngine()
        engine.feed(linesY: 1, linesX: 0)
        runUntilIdle()
        XCTAssertNil(momentumBegin)
        XCTAssertEqual(posts.last?.scrollPhase, 4)
    }

    /// Deliberate notch-by-notch scrolling stays precise.
    func testSlowTicksDoNotCoast() {
        let engine = makeEngine()
        feedTicks(engine, ticks: 5, interval: 0.4)
        runUntilIdle()
        XCTAssertNil(momentumBegin)
    }

    /// Every fed pixel is still delivered; momentum only adds distance.
    func testHandoffLosesNoFedPixels() {
        let engine = makeEngine()
        feedTicks(engine, ticks: 10, interval: 0.03)
        runUntilIdle()
        let delivered = posts.reduce(0) { $0 + Int($1.pointDeltaY) }
        XCTAssertGreaterThan(delivered, 10 * 30)
    }

    func testReversalCoastsInTheNewDirection() throws {
        let engine = makeEngine()
        feedTicks(engine, ticks: 6, interval: 0.03, lines: 1)
        now += 0.03
        feedTicks(engine, ticks: 6, interval: 0.03, lines: -1)
        runUntilIdle()
        let begin = try XCTUnwrap(posts.last { $0.momentumPhase == 1 })
        XCTAssertLessThan(begin.fixedDeltaY, 0)
    }

    func testFreeSpinningWheelCoastIsCapped() throws {
        let engine = makeEngine()
        feedTicks(engine, ticks: 40, interval: 0.002)
        runUntilIdle()
        let begin = try XCTUnwrap(momentumBegin)
        XCTAssertLessThanOrEqual(abs(begin.fixedDeltaY) * 120, 6_000 + 1)
    }
}
