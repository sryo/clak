import CoreGraphics
import XCTest
@testable import ClakRemote

/// Scrolling aimed at the Magic Trackpad's feel through the Mac's own wheel
/// acceleration. The wheel model follows IOHIDFamily's IOHIDScrollAccelerator
/// with the default acceleration table, and is checked against wheel ticks
/// recorded from Clak Remote on a Mac.
final class ScrollAcceleratorTests: XCTestCase {
    // MARK: - The Mac's wheel, reproduced

    /// Ticks as they reached a Mac (ms, recorded) and the lines it scrolled
    /// for each: the first barely moves, and within a few ticks each one is
    /// worth nine lines.
    func testTheMacsWheelRampMatchesARecording() {
        let recorded: [(ms: Double, lines: Double)] = [
            (0.0, 0.1), (29.7, 0.863), (32.0, 3.988), (59.6, 5.497), (60.8, 6.454),
            (89.4, 7.012), (121.3, 7.494), (122.4, 8.195), (156.5, 9.0), (156.7, 9.176),
        ]
        // Recorded before the wheel declared its resolution: the Mac's default of 9.
        var wheel = MacWheel(resolution: 9)
        for tick in recorded {
            let lines = wheel.tick(counts: 1, at: 100 + tick.ms / 1000)
            XCTAssertEqual(lines, tick.lines, accuracy: max(0.06, tick.lines * 0.06), "at \(tick.ms) ms")
        }
    }

    func testTheTrackpadTarget() {
        XCTAssertEqual(MacScroll.trackpadPixelsPerSecond(fingerInchesPerSecond: 1), 143, accuracy: 3)
        XCTAssertEqual(MacScroll.trackpadPixelsPerSecond(fingerInchesPerSecond: 4), 1219, accuracy: 15)
    }

    // MARK: - The phone's side

    /// The whole path as the app runs it: touches at 60 Hz into the pacer, a
    /// 120 Hz timer taking a send each connection event, the reports sized
    /// for it, and a link delivering at most two reports every 30.1 ms, as
    /// measured. The finger ramps up over 0.15 s then holds. Returns how far
    /// the Mac scrolled for each delivery: when, and how many pixels.
    private func macScrollDeliveries(fingerPointsPerSecond speed: CGFloat, seconds: Double = 1.5) -> [(time: Double, pixels: Double)] {
        var pacer = ScrollPacer()
        var accelerator = ScrollAccelerator()
        var wheel = MacWheel()
        let tick = 1.0 / 120
        let link = 0.0301
        // The pacer can't see when connection events fall. Started here, they
        // land clear of the 8 ms the timer rounds sends by, as they did on a
        // phone (about 1.1 reports an event); in the one start in four that
        // lands inside it, events alternate between none and two.
        var nextDelivery = 0.032
        var queued: [Int] = []
        var deliveries: [(Double, Double)] = []
        var ticks = 0
        while Double(ticks) * tick < seconds {
            ticks += 1
            let t = Double(ticks) * tick
            if ticks.isMultiple(of: 2) {
                let fingerSpeed = speed * CGFloat(min(1, t / 0.15))
                pacer.finger(moved: fingerSpeed * CGFloat(2 * tick), over: 2 * tick)
            }
            if let amount = pacer.take(at: t) {
                queued += accelerator.reports(forFingerMoved: amount, over: ScrollPacer.interval)
            }
            while nextDelivery <= t {
                // Reports sharing a delivery reach the Mac a moment apart.
                let batch = queued.prefix(2)
                queued.removeFirst(batch.count)
                let lines = batch.enumerated().reduce(0.0) { sum, report in
                    sum + wheel.tick(counts: report.element, at: nextDelivery + Double(report.offset) * 0.0005)
                }
                deliveries.append((nextDelivery, lines * MacScroll.pixelsPerLine))
                nextDelivery += link
            }
        }
        return deliveries
    }

    /// Pixels per second once the finger speed has held for a while.
    private func steadyScroll(fingerPointsPerSecond speed: CGFloat) -> Double {
        let steady = macScrollDeliveries(fingerPointsPerSecond: speed).filter { $0.time > 0.4 }
        let span = steady.last!.time - steady.first!.time + 0.0301
        return steady.reduce(0) { $0 + $1.pixels } / span
    }

    func testTheMacScrollsAsItsTrackpadWould() {
        for speed: CGFloat in [80, 155, 310, 620] {
            let inches = Double(speed / PointerAccelerator.pointsPerInch)
            let target = MacScroll.trackpadPixelsPerSecond(fingerInchesPerSecond: inches)
            XCTAssertEqual(steadyScroll(fingerPointsPerSecond: speed), target, accuracy: target * 0.08, "\(speed) pt/s")
        }
    }

    /// A flick fast enough that one report can't carry it goes out as two in
    /// the same connection event. Recorded before: flicks stuck at 79 pixels
    /// an event, about 2,600 a second, whatever the finger did.
    func testAFastFlickIsNotCapped() {
        for speed: CGFloat in [1200, 1600] {
            let inches = Double(speed / PointerAccelerator.pointsPerInch)
            let target = MacScroll.trackpadPixelsPerSecond(fingerInchesPerSecond: inches)
            XCTAssertGreaterThan(target, 3000)
            XCTAssertEqual(steadyScroll(fingerPointsPerSecond: speed), target, accuracy: target * 0.1, "\(speed) pt/s")
        }
    }

    /// Recorded at nine pixels of page for every point of finger; a trackpad
    /// is nearer one.
    func testAModerateScrollIsNoLongerManyTimesTheFinger() {
        XCTAssertLessThan(steadyScroll(fingerPointsPerSecond: 300) / 300, 2)
    }

    /// Every connection event moves the page, by an even amount.
    func testScrollingGlidesEvenly() {
        for speed: CGFloat in [155, 310, 620, 1200] {
            let pixels = macScrollDeliveries(fingerPointsPerSecond: speed).filter { $0.time > 0.4 }.map(\.pixels)
            XCTAssertFalse(pixels.contains { $0 < 0.5 }, "\(speed) pt/s: an empty delivery")
            let mean = pixels.reduce(0, +) / Double(pixels.count)
            let spread = (pixels.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(pixels.count)).squareRoot()
            XCTAssertLessThan(spread / mean, 0.2, "\(speed) pt/s")
        }
    }

    func testScrollingUpScrollsUp() {
        var accelerator = ScrollAccelerator()
        XCTAssertLessThan(accelerator.reports(forFingerMoved: -40, over: 0.03).first ?? 0, 0)
    }

    func testStillFingersSendNothing() {
        var accelerator = ScrollAccelerator()
        XCTAssertEqual(accelerator.reports(forFingerMoved: 0, over: 0.03), [])
    }

    /// A tiny drift leaves a fraction of a count behind; reset drops it.
    func testResetDropsTheCarriedFraction() {
        var accelerator = ScrollAccelerator()
        var sent = 0
        for _ in 0..<5 { sent += accelerator.reports(forFingerMoved: 0.02, over: 0.03).reduce(0, +) }
        accelerator.reset()
        XCTAssertEqual(sent + accelerator.reports(forFingerMoved: 0, over: 0.03).reduce(0, +), sent)
    }
}

/// The link carries about two reports per connection event and the Mac
/// updates on each, so scroll goes out as one report per event, the same
/// size each time at a steady finger speed. The pacer turns touches arriving
/// in 60 Hz chunks into that.
final class ScrollPacerTests: XCTestCase {
    private let tick = 1.0 / 120

    /// Drives the pacer with touches at 60 Hz and ticks at 120 Hz, and
    /// returns what it sent: when, and how much.
    private func run(pointsPerSecond speed: CGFloat, seconds: Double, stopAfter: Double = .infinity) -> [(time: Double, amount: CGFloat)] {
        var pacer = ScrollPacer()
        var sent: [(Double, CGFloat)] = []
        var t = 0.0
        var ticks = 0
        while t < seconds {
            ticks += 1
            t = Double(ticks) * tick
            if ticks.isMultiple(of: 2), t <= stopAfter {
                pacer.finger(moved: speed * CGFloat(2 * tick), over: 2 * tick)
            }
            if let amount = pacer.take(at: t) { sent.append((t, amount)) }
        }
        return sent
    }

    func testItSendsOncePerConnectionEvent() {
        let sent = run(pointsPerSecond: 300, seconds: 2).filter { $0.time > 0.3 }
        let gaps = zip(sent.dropFirst(), sent).map { $0.time - $1.time }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        XCTAssertEqual(mean, ScrollPacer.interval, accuracy: 0.0005)
    }

    /// Touches come in two per send one time and one the next; each send
    /// must still carry the same amount, or the page halves its step.
    func testEachSendCarriesTheSameAmount() {
        let sent = run(pointsPerSecond: 300, seconds: 2).filter { $0.time > 0.4 }.map(\.amount)
        let expected = 300 * CGFloat(ScrollPacer.interval)
        for amount in sent {
            XCTAssertEqual(amount, expected, accuracy: expected * 0.08)
        }
    }

    /// Nothing is lost: once the fingers stop, all of it has gone out.
    func testEverythingMovedIsSent() throws {
        let sent = run(pointsPerSecond: 200, seconds: 2, stopAfter: 0.5)
        XCTAssertEqual(sent.reduce(0) { $0 + $1.amount }, 100, accuracy: 0.2)
        XCTAssertLessThan(try XCTUnwrap(sent.last).time, 1.2, "and it settles")
    }

    func testAFlingKeepsSendingAtItsSpeed() throws {
        var pacer = ScrollPacer()
        var amounts: [CGFloat] = []
        for i in 1...60 {
            pacer.fling(speed: -500, over: tick)
            if let amount = pacer.take(at: Double(i) * tick) { amounts.append(amount) }
        }
        let expected = -500 * CGFloat(ScrollPacer.interval)
        XCTAssertEqual(try XCTUnwrap(amounts.last), expected, accuracy: abs(expected) * 0.08)
    }

    func testResetStops() {
        var pacer = ScrollPacer()
        pacer.finger(moved: 10, over: tick)
        pacer.reset()
        XCTAssertTrue(pacer.isSettled)
        XCTAssertNil(pacer.take(at: 1))
    }
}
