import CoreGraphics
import XCTest
@testable import ClakRemote

/// Replays synthetic touch sequences through the recognizer. Times are in
/// seconds, positions in points, on a 390 pt wide surface.
final class TrackpadGestureRecognizerTests: XCTestCase {
    typealias Action = TrackpadGestureRecognizer.Action

    /// Tracks which fingers are down so every move reports all of them, the way
    /// the view does.
    private struct Pad {
        var recognizer = TrackpadGestureRecognizer()
        var fingers: [Int: CGPoint] = [:]
        var log: [Action] = []

        init() { recognizer.surfaceWidth = 390 }

        @discardableResult
        mutating func down(_ touches: [Int: CGPoint], at time: TimeInterval, catching: Bool = false) -> [Action] {
            fingers.merge(touches) { $1 }
            return record(recognizer.touchesBegan(touches, at: time, interruptsMomentum: catching))
        }

        @discardableResult
        mutating func move(_ updates: [Int: CGPoint], at time: TimeInterval) -> [Action] {
            fingers.merge(updates) { $1 }
            return record(recognizer.touchesMoved(fingers, at: time))
        }

        /// Moves the given fingers by the same offset.
        @discardableResult
        mutating func shift(_ ids: [Int], dx: CGFloat, dy: CGFloat, at time: TimeInterval) -> [Action] {
            var updates: [Int: CGPoint] = [:]
            for id in ids { updates[id] = CGPoint(x: fingers[id]!.x + dx, y: fingers[id]!.y + dy) }
            return move(updates, at: time)
        }

        /// Moves the given fingers by `(dx, dy)` per step, `steps` times, 10 ms apart.
        @discardableResult
        mutating func slide(_ ids: [Int], dx: CGFloat, dy: CGFloat, steps: Int, from start: TimeInterval) -> [Action] {
            var actions: [Action] = []
            for step in 1...steps {
                actions += shift(ids, dx: dx, dy: dy, at: start + Double(step) * 0.01)
            }
            return actions
        }

        @discardableResult
        mutating func up(_ ids: [Int], at time: TimeInterval) -> [Action] {
            for id in ids { fingers[id] = nil }
            return record(recognizer.touchesEnded(ids, at: time))
        }

        @discardableResult
        mutating func cancel(_ ids: [Int], at time: TimeInterval) -> [Action] {
            for id in ids { fingers[id] = nil }
            return record(recognizer.touchesCancelled(ids, at: time))
        }

        @discardableResult
        mutating func tick(at time: TimeInterval) -> [Action] {
            record(recognizer.tick(at: time))
        }

        @discardableResult
        mutating func reset() -> [Action] {
            fingers = [:]
            return record(recognizer.reset())
        }

        /// A still, quick single-finger tap.
        @discardableResult
        mutating func tap(at time: TimeInterval, _ point: CGPoint = CGPoint(x: 200, y: 400)) -> [Action] {
            down([1: point], at: time) + up([1], at: time + 0.08)
        }

        private mutating func record(_ actions: [Action]) -> [Action] {
            log += actions
            return actions
        }
    }

    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private func isScroll(_ action: Action) -> Bool {
        if case .scroll = action { return true }
        return false
    }

    private func isPointer(_ action: Action) -> Bool {
        if case .pointer = action { return true }
        return false
    }

    private func isClick(_ action: Action) -> Bool {
        if case .click = action { return true }
        return false
    }

    // MARK: - One finger

    func testOneFingerTapClicksOnceTheDragWindowPasses() {
        var pad = Pad()
        XCTAssertEqual(pad.tap(at: 1), [])
        XCTAssertEqual(pad.recognizer.nextDeadline ?? 0, 1.33, accuracy: 1e-9)
        XCTAssertEqual(pad.tick(at: 1.2), [])
        XCTAssertEqual(pad.tick(at: 1.34), [.click(.left)])
        XCTAssertNil(pad.recognizer.nextDeadline)
    }

    func testLateTouchFlushesHeldBackClick() {
        // The timer lagged: a touch after the window still gets the click first.
        var pad = Pad()
        pad.tap(at: 1)
        XCTAssertEqual(pad.down([1: p(200, 400)], at: 1.5), [.click(.left)])
        XCTAssertEqual(pad.slide([1], dx: 3, dy: 0, steps: 2, from: 1.5).contains(.buttonDown), false)
    }

    func testSecondFingerAfterTapFlushesClick() {
        var pad = Pad()
        pad.tap(at: 1)
        pad.down([1: p(170, 400)], at: 1.15)
        XCTAssertEqual(pad.down([2: p(230, 400)], at: 1.17), [.click(.left)])
    }

    func testSlowPressDoesNotClick() {
        var pad = Pad()
        pad.down([1: p(200, 400)], at: 1)
        XCTAssertEqual(pad.up([1], at: 1.4), [])
        XCTAssertEqual(pad.log, [])
    }

    func testFirstPointerMoveIsEmittedEvenWhenTiny() {
        var pad = Pad()
        pad.down([1: p(200, 400)], at: 1)
        XCTAssertEqual(pad.shift([1], dx: 1, dy: 0, at: 1.01), [.pointer(dx: 1, dy: 0)])
        XCTAssertEqual(pad.shift([1], dx: 2, dy: -1, at: 1.02), [.pointer(dx: 2, dy: -1)])
    }

    func testPointerMovesKeepFlowing() {
        var pad = Pad()
        pad.down([1: p(200, 400)], at: 1)
        pad.shift([1], dx: 1, dy: 0, at: 1.01)
        XCTAssertEqual(pad.shift([1], dx: 3, dy: 4, at: 1.02), [.pointer(dx: 3, dy: 4)])
        XCTAssertEqual(pad.shift([1], dx: -2, dy: 0, at: 1.03), [.pointer(dx: -2, dy: 0)])
    }

    func testMovePastSingleFingerSlopIsNotATap() {
        var pad = Pad()
        pad.down([1: p(200, 400)], at: 1)
        pad.slide([1], dx: 2, dy: 0, steps: 3, from: 1)
        XCTAssertEqual(pad.up([1], at: 1.1), [])
        XCTAssertFalse(pad.log.contains(where: isClick))
    }

    // MARK: - Multi-finger taps

    func testTwoFingerTapWithUnevenLandingAndLiftRightClicks() {
        var pad = Pad()
        pad.down([1: p(180, 400)], at: 1)
        pad.shift([1], dx: 1, dy: 0, at: 1.02)
        pad.down([2: p(230, 400)], at: 1.03)
        pad.up([1], at: 1.10)
        XCTAssertEqual(pad.up([2], at: 1.16), [.click(.right)])
        XCTAssertEqual(pad.log.filter(isClick), [.click(.right)])
    }

    func testPointerNudgeThenGrazingSecondFingerDoesNotRightClick() {
        var pad = Pad()
        pad.down([1: p(180, 400)], at: 1)
        pad.shift([1], dx: 7, dy: 0, at: 1.05)
        pad.down([2: p(230, 400)], at: 1.1)
        pad.up([2], at: 1.15)
        pad.up([1], at: 1.2)
        XCTAssertEqual(pad.log.filter(isClick), [])
    }

    func testThreeFingerTapLooksUp() {
        var pad = Pad()
        pad.down([1: p(150, 400), 2: p(200, 400)], at: 1)
        pad.down([3: p(250, 400)], at: 1.02)
        pad.up([1, 2], at: 1.1)
        XCTAssertEqual(pad.up([3], at: 1.12), [.lookUp])
    }

    func testFourFingerTapDoesNothing() {
        var pad = Pad()
        pad.down([1: p(100, 400), 2: p(150, 400), 3: p(200, 400), 4: p(250, 400)], at: 1)
        XCTAssertEqual(pad.up([1, 2, 3, 4], at: 1.1), [])
        XCTAssertEqual(pad.log, [])
    }

    // MARK: - Pinch

    func testQuickPinchOutZoomsInStepsAndDoesNotClick() {
        var pad = Pad()
        pad.down([1: p(150, 400), 2: p(240, 400)], at: 1) // span 90
        // Spread 5 pt per finger per step: span 90 -> 150.
        var t = 1.0
        for _ in 0..<6 {
            t += 0.01
            pad.move([1: p(pad.fingers[1]!.x - 5, 400), 2: p(pad.fingers[2]!.x + 5, 400)], at: t)
        }
        pad.up([1, 2], at: t + 0.02)
        // 90 * 1.25 = 112.5, * 1.25 = 140.6: two steps by span ~155.
        XCTAssertEqual(pad.log, [.zoom(1), .zoom(1)])
    }

    func testCoarseQuickPinchStillZooms() {
        // A fast pinch can cross both the commit distance and a zoom step in
        // one sample; that step must not be lost.
        var pad = Pad()
        pad.down([1: p(150, 400), 2: p(240, 400)], at: 1) // span 90
        pad.move([1: p(135, 400), 2: p(255, 400)], at: 1.03) // span 120 (1.33x)
        pad.up([1, 2], at: 1.08)
        XCTAssertEqual(pad.log, [.zoom(1)])
    }

    func testPinchInZoomsOut() {
        var pad = Pad()
        pad.down([1: p(120, 400), 2: p(270, 400)], at: 1) // span 150
        var t = 1.0
        for _ in 0..<5 { // span 150 -> 100
            t += 0.01
            pad.move([1: p(pad.fingers[1]!.x + 5, 400), 2: p(pad.fingers[2]!.x - 5, 400)], at: t)
        }
        pad.up([1, 2], at: t + 0.02)
        XCTAssertEqual(pad.log, [.zoom(-1)])
    }

    // MARK: - Scroll

    func testTwoFingerScrollThenEnded() {
        var pad = Pad()
        pad.down([1: p(170, 400), 2: p(230, 400)], at: 1)
        XCTAssertEqual(pad.slide([1, 2], dx: 0, dy: -4, steps: 2, from: 1), [])
        XCTAssertEqual(pad.shift([1, 2], dx: 0, dy: -4, at: 1.03), [.scroll(dx: 0, dy: -12)])
        XCTAssertEqual(pad.shift([1, 2], dx: 0, dy: -4, at: 1.04), [.scroll(dx: 0, dy: -4)])
        XCTAssertEqual(pad.shift([1, 2], dx: 3, dy: 0, at: 1.05), [.scroll(dx: 3, dy: 0)])
        pad.up([1], at: 1.1)
        XCTAssertEqual(pad.up([2], at: 1.11), [.scrollEnded])
        XCTAssertFalse(pad.log.contains(where: isClick))
    }

    func testFingerLiftingMidScrollDoesNotJump() {
        var pad = Pad()
        pad.down([1: p(170, 400), 2: p(230, 400)], at: 1)
        pad.slide([1, 2], dx: 0, dy: -5, steps: 3, from: 1)
        XCTAssertTrue(pad.log.contains(where: isScroll))
        XCTAssertEqual(pad.up([2], at: 1.05), [])
        XCTAssertEqual(pad.shift([1], dx: 0, dy: -5, at: 1.06), [.scroll(dx: 0, dy: -5)])
        XCTAssertEqual(pad.up([1], at: 1.08), [.scrollEnded])
    }

    func testScrollThatBecomesAPinchReclassifiesToZoom() {
        var pad = Pad()
        pad.down([1: p(165, 400), 2: p(225, 400)], at: 1) // span 60
        pad.slide([1, 2], dx: 0, dy: -4, steps: 3, from: 1) // commits scroll at 1.03
        XCTAssertTrue(pad.log.contains(where: isScroll))
        let scrolls = pad.log.count
        var t = 1.03
        for _ in 0..<3 { // spread: span 60 -> 120
            t += 0.02
            pad.move([1: p(pad.fingers[1]!.x - 10, pad.fingers[1]!.y), 2: p(pad.fingers[2]!.x + 10, pad.fingers[2]!.y)], at: t)
        }
        XCTAssertLessThan(t - 1.03, TrackpadGestureRecognizer.scrollReclassifyWindow)
        let after = Array(pad.log.dropFirst(scrolls))
        XCTAssertFalse(after.contains(where: isScroll), "\(after)")
        XCTAssertTrue(after.contains(.zoom(1)), "\(after)")
    }

    func testScrollWithLeadingFingerDoesNotZoom() {
        // Fingers on a diagonal; the lower one starts first, so the span
        // changes as much as the centroid travels.
        var pad = Pad()
        pad.down([1: p(170, 380), 2: p(230, 440)], at: 1)
        pad.shift([2], dx: 0, dy: -12, at: 1.02)
        pad.slide([1, 2], dx: 0, dy: -10, steps: 12, from: 1.03)
        pad.up([1, 2], at: 1.2)
        XCTAssertFalse(pad.log.contains { if case .zoom = $0 { return true }; return false })
        XCTAssertTrue(pad.log.contains { if case .scroll = $0 { return true }; return false })
    }

    func testScrollWithFingersDriftingApartDoesNotZoom() {
        var pad = Pad()
        pad.down([1: p(180, 500), 2: p(240, 500)], at: 1)
        var t = 1.0
        for step in 1...15 {
            t += 0.01
            let spread = CGFloat(step) * 2
            let rise = CGFloat(step) * 8
            pad.move([1: p(180 - spread, 500 - rise), 2: p(240 + spread, 500 - rise)], at: t)
        }
        pad.up([1, 2], at: t + 0.01)
        XCTAssertFalse(pad.log.contains { if case .zoom = $0 { return true }; return false })
    }

    func testAnchoredPinchStillZooms() {
        var pad = Pad()
        pad.down([1: p(150, 400), 2: p(230, 400)], at: 1)
        pad.slide([2], dx: 5, dy: 0, steps: 6, from: 1.01)
        pad.up([1, 2], at: 1.2)
        XCTAssertEqual(pad.log.filter { if case .zoom = $0 { return true }; return false }, [.zoom(1)])
    }

    // MARK: - Rotate

    private func twist(clockwise: Bool) -> Pad {
        var pad = Pad()
        let center = p(195, 400)
        let radius: CGFloat = 40
        func pair(_ degrees: CGFloat) -> [Int: CGPoint] {
            let a = degrees * .pi / 180
            let offset = CGPoint(x: cos(a) * radius, y: sin(a) * radius)
            return [1: p(center.x - offset.x, center.y - offset.y), 2: p(center.x + offset.x, center.y + offset.y)]
        }
        pad.down(pair(0), at: 1)
        var t = 1.0
        for step in 1...9 { // up to 90 degrees
            t += 0.01
            pad.move(pair(CGFloat(step) * 10 * (clockwise ? 1 : -1)), at: t)
        }
        pad.up([1, 2], at: t + 0.02)
        return pad
    }

    func testClockwiseTwistRotatesOnce() {
        XCTAssertEqual(twist(clockwise: true).log, [.rotate(1)])
    }

    func testCounterclockwiseTwistRotatesOnce() {
        XCTAssertEqual(twist(clockwise: false).log, [.rotate(-1)])
    }

    // MARK: - Swipes

    private func swipe(fingers count: Int, dx: CGFloat, dy: CGFloat, steps: Int = 8) -> [Action] {
        var pad = Pad()
        var touches: [Int: CGPoint] = [:]
        for id in 1...count { touches[id] = p(90 + CGFloat(id) * 50, 400) }
        pad.down(touches, at: 1)
        pad.slide(Array(1...count), dx: dx, dy: dy, steps: steps, from: 1)
        pad.up(Array(1...count), at: 1.2)
        return pad.log
    }

    func testThreeFingerSwipesInEachDirection() {
        XCTAssertEqual(swipe(fingers: 3, dx: -10, dy: 1), [.swipe(fingers: 3, .left)])
        XCTAssertEqual(swipe(fingers: 3, dx: 10, dy: -1), [.swipe(fingers: 3, .right)])
        XCTAssertEqual(swipe(fingers: 3, dx: 1, dy: -10), [.swipe(fingers: 3, .up)])
        XCTAssertEqual(swipe(fingers: 3, dx: -1, dy: 10), [.swipe(fingers: 3, .down)])
    }

    func testDiagonalThreeFingerSwipeDoesNothing() {
        XCTAssertEqual(swipe(fingers: 3, dx: -10, dy: -10), [])
    }

    func testFourFingerSwipeReportsFourFingers() {
        XCTAssertEqual(swipe(fingers: 4, dx: -10, dy: 0), [.swipe(fingers: 4, .left)])
    }

    func testThirdFingerLandingJustAfterScrollCommitBecomesASwipe() {
        var pad = Pad()
        pad.down([1: p(170, 400), 2: p(230, 400)], at: 1)
        pad.slide([1, 2], dx: -5, dy: 0, steps: 3, from: 1) // scroll commits at 1.02
        XCTAssertTrue(pad.log.contains(where: isScroll))
        pad.down([3: p(290, 400)], at: 1.08)
        let after = pad.slide([1, 2, 3], dx: -10, dy: 0, steps: 7, from: 1.08)
        XCTAssertFalse(after.contains(where: isScroll), "\(after)")
        XCTAssertEqual(after, [.swipe(fingers: 3, .left)])
    }

    // MARK: - Four-finger pinch

    private func fourFingers(radiusStep: CGFloat, steps: Int, radius: CGFloat) -> [Action] {
        var pad = Pad()
        let c = p(195, 400)
        func ring(_ r: CGFloat) -> [Int: CGPoint] {
            [1: p(c.x, c.y - r), 2: p(c.x + r, c.y), 3: p(c.x, c.y + r), 4: p(c.x - r, c.y)]
        }
        pad.down(ring(radius), at: 1)
        var r = radius
        for step in 1...steps {
            r += radiusStep
            pad.move(ring(r), at: 1 + Double(step) * 0.01)
        }
        pad.up([1, 2, 3, 4], at: 1.2)
        return pad.log
    }

    func testFourFingersGatheringShowsDesktop() {
        XCTAssertEqual(fourFingers(radiusStep: -8, steps: 5, radius: 80), [.gatherAll])
    }

    func testFourFingersSpreadingOpensLaunchpad() {
        XCTAssertEqual(fourFingers(radiusStep: 8, steps: 5, radius: 60), [.spreadAll])
    }

    // MARK: - Edge swipe

    func testTwoFingerSwipeFromRightEdge() {
        var pad = Pad()
        pad.down([1: p(378, 300), 2: p(378, 360)], at: 1)
        pad.slide([1, 2], dx: -4, dy: 0, steps: 10, from: 1)
        pad.up([1, 2], at: 1.2)
        XCTAssertEqual(pad.log, [.edgeSwipeFromRight])
    }

    func testSameSwipeMidSurfaceScrolls() {
        var pad = Pad()
        pad.down([1: p(195, 300), 2: p(195, 360)], at: 1)
        pad.slide([1, 2], dx: -4, dy: 0, steps: 10, from: 1)
        pad.up([1, 2], at: 1.2)
        XCTAssertFalse(pad.log.contains(.edgeSwipeFromRight))
        XCTAssertTrue(pad.log.contains(where: isScroll))
        XCTAssertEqual(pad.log.last, .scrollEnded)
    }

    // MARK: - Tap-and-a-half drag

    /// Tap, then press and drag; leaves the finger down with the button held.
    private func startDrag() -> Pad {
        var pad = Pad()
        pad.tap(at: 1)
        pad.down([1: p(200, 400)], at: 1.25)
        return pad
    }

    func testTapAndAHalfDragsAndDropsAfterGrace() {
        var pad = startDrag()
        XCTAssertEqual(pad.shift([1], dx: 2, dy: 0, at: 1.27), [])
        XCTAssertEqual(pad.shift([1], dx: 2, dy: 0, at: 1.28), [.buttonDown, .pointer(dx: 2, dy: 0)])
        XCTAssertEqual(pad.shift([1], dx: 5, dy: 1, at: 1.29), [.pointer(dx: 5, dy: 1)])
        XCTAssertTrue(pad.recognizer.isButtonHeld)

        XCTAssertEqual(pad.up([1], at: 2), [])
        XCTAssertEqual(pad.recognizer.nextDeadline ?? 0, 2.4, accuracy: 1e-9)
        XCTAssertEqual(pad.tick(at: 2.3), [])
        XCTAssertEqual(pad.tick(at: 2.41), [.buttonUp])
        XCTAssertNil(pad.recognizer.nextDeadline)
        XCTAssertFalse(pad.recognizer.isButtonHeld)
        // One held press: no click first, so the Mac never sees a double-click.
        XCTAssertEqual(pad.log.filter { !isPointer($0) }, [.buttonDown, .buttonUp])
    }

    func testRetouchWithinGraceKeepsDragging() {
        var pad = startDrag()
        pad.slide([1], dx: 4, dy: 0, steps: 2, from: 1.25)
        pad.up([1], at: 2)
        pad.down([1: p(100, 500)], at: 2.2)
        XCTAssertNil(pad.recognizer.nextDeadline)
        XCTAssertEqual(pad.shift([1], dx: 1, dy: 0, at: 2.21), [.pointer(dx: 1, dy: 0)])
        XCTAssertEqual(pad.tick(at: 2.5), [])
        XCTAssertEqual(pad.log.filter { $0 == .buttonDown }.count, 1)
        XCTAssertTrue(pad.recognizer.isButtonHeld)
    }

    func testQuickTapDuringGraceDrops() {
        var pad = startDrag()
        pad.slide([1], dx: 4, dy: 0, steps: 2, from: 1.25)
        pad.up([1], at: 2)
        XCTAssertEqual(pad.tap(at: 2.1), [.buttonUp])
        XCTAssertFalse(pad.recognizer.isButtonHeld)
        XCTAssertEqual(pad.tick(at: 3), [])
    }

    func testDoubleTapClicksTwiceWithoutDragging() {
        var pad = Pad()
        pad.tap(at: 1)
        pad.tap(at: 1.2)
        XCTAssertEqual(pad.log, [.doubleClick])
        XCTAssertNil(pad.recognizer.nextDeadline)
    }

    func testPressAfterDoubleClickDoesNotArmDrag() {
        var pad = Pad()
        pad.tap(at: 1)
        pad.tap(at: 1.2)
        pad.down([1: p(200, 400)], at: 1.35)
        let moved = pad.slide([1], dx: 3, dy: 0, steps: 3, from: 1.35)
        XCTAssertFalse(moved.contains(.buttonDown), "\(moved)")
        XCTAssertTrue(moved.contains(where: isPointer), "\(moved)")
        XCTAssertEqual(pad.up([1], at: 1.5), [])
    }

    func testTapThenTwoFingerScrollDoesNotDrag() {
        var pad = Pad()
        pad.tap(at: 1)
        pad.down([1: p(170, 400)], at: 1.2)
        pad.shift([1], dx: 0, dy: -1, at: 1.21)
        pad.down([2: p(230, 400)], at: 1.23)
        pad.slide([1, 2], dx: 0, dy: -5, steps: 4, from: 1.23)
        pad.up([1, 2], at: 1.4)
        XCTAssertFalse(pad.log.contains(.buttonDown))
        XCTAssertTrue(pad.log.contains(where: isScroll))
        XCTAssertEqual(pad.log.last, .scrollEnded)
    }

    // MARK: - Cancellation

    func testCancelWhileDraggingReleasesButton() {
        var pad = startDrag()
        pad.slide([1], dx: 4, dy: 0, steps: 2, from: 1.25)
        XCTAssertTrue(pad.recognizer.isButtonHeld)
        XCTAssertEqual(pad.cancel([1], at: 1.4), [.buttonUp])
        XCTAssertFalse(pad.recognizer.isButtonHeld)
    }

    func testResetWhileButtonHeldReleasesButton() {
        var pad = startDrag()
        pad.slide([1], dx: 4, dy: 0, steps: 2, from: 1.25)
        XCTAssertEqual(pad.reset(), [.buttonUp])
        XCTAssertEqual(pad.reset(), [])
    }

    func testResetDuringClutchGraceReleasesButton() {
        var pad = startDrag()
        pad.slide([1], dx: 4, dy: 0, steps: 2, from: 1.25)
        pad.up([1], at: 2)
        XCTAssertEqual(pad.reset(), [.buttonUp])
        XCTAssertNil(pad.recognizer.nextDeadline)
    }

    // MARK: - Momentum

    func testTouchThatCatchesAFlingDoesNotClick() {
        var pad = Pad()
        pad.down([1: p(200, 400)], at: 1, catching: true)
        XCTAssertEqual(pad.up([1], at: 1.08), [])
    }
}
