import CoreGraphics
import XCTest
@testable import ClakRemote

/// Replays drag paths through the stepper. Translations are in points from
/// where the finger landed, in screen coordinates (y grows downward).
final class PullStepperTests: XCTestCase {
    private struct Drag {
        var stepper: PullStepper
        var position = CGPoint.zero
        /// Every step emitted, in order, as the key would call onStep.
        var emitted: [Int] = []

        init(axis: PullAxis) { stepper = PullStepper(axis: axis) }

        mutating func to(_ point: CGPoint) {
            position = point
            let delta = stepper.move(to: CGSize(width: point.x, height: point.y))
            emitted += Array(repeating: delta > 0 ? 1 : -1, count: abs(delta))
        }

        /// Straight line to `point` in 2pt samples, the way touches arrive.
        mutating func line(to point: CGPoint) {
            let dx = point.x - position.x, dy = point.y - position.y
            let count = max(1, Int((hypot(dx, dy) / 2).rounded(.up)))
            let start = position
            for i in 1...count {
                let t = CGFloat(i) / CGFloat(count)
                to(CGPoint(x: start.x + dx * t, y: start.y + dy * t))
            }
        }

        /// Sweeps `degrees` of arc of `radius`, starting from the current
        /// position with the finger heading `startHeading` (radians, screen
        /// coordinates). Positive degrees turn clockwise on screen.
        mutating func arc(radius: CGFloat, degrees: CGFloat, startHeading: CGFloat) {
            let turn: CGFloat = degrees >= 0 ? 1 : -1
            // The centre sits a quarter turn from the heading, on the side the
            // path bends toward.
            let toCentre = startHeading + turn * .pi / 2
            let centre = CGPoint(x: position.x + radius * cos(toCentre),
                                 y: position.y + radius * sin(toCentre))
            let startAngle = toCentre + .pi
            let sweep = degrees * .pi / 180
            let count = max(1, Int((abs(sweep) * radius / 2).rounded(.up)))
            for i in 1...count {
                let a = startAngle + sweep * CGFloat(i) / CGFloat(count)
                to(CGPoint(x: centre.x + radius * cos(a), y: centre.y + radius * sin(a)))
            }
        }

        var net: Int { emitted.reduce(0, +) }
    }

    private let up = -CGFloat.pi / 2
    private let right: CGFloat = 0

    private func steps(forArc degrees: CGFloat, radius: CGFloat) -> Int {
        Int(abs(degrees) * .pi / 180 * radius / ControlMetrics.pointsPerStep)
    }

    // MARK: - A straight pull, as the key has always behaved

    func testPullingUpStepsOncePerFourteenPoints() {
        var drag = Drag(axis: .vertical)
        drag.line(to: CGPoint(x: 0, y: -13))
        XCTAssertEqual(drag.net, 0)
        drag.line(to: CGPoint(x: 0, y: -42))
        XCTAssertEqual(drag.emitted, [1, 1, 1])
    }

    func testComingBackStepsDownFromWhereItGotTo() {
        var drag = Drag(axis: .vertical)
        drag.line(to: CGPoint(x: 0, y: -42))
        drag.line(to: CGPoint(x: 0, y: -28))
        XCTAssertEqual(drag.emitted, [1, 1, 1, -1])
        XCTAssertEqual(drag.stepper.steps, 2)
    }

    func testHorizontalStepsRightAsPositive() {
        var drag = Drag(axis: .horizontal)
        drag.line(to: CGPoint(x: 28, y: 0))
        XCTAssertEqual(drag.net, 2)
        drag.line(to: CGPoint(x: -28, y: 0))
        XCTAssertEqual(drag.net, -2)
    }

    func testMovementAcrossTheAxisIsIgnored() {
        var drag = Drag(axis: .vertical)
        drag.line(to: CGPoint(x: 120, y: 0))
        XCTAssertEqual(drag.emitted, [])
    }

    /// A hand trembles at around 10 Hz against touches arriving at 120, so a
    /// shaky pull sways every ten samples or so.
    func testATremblingPullStillCountsItsLength() {
        var drag = Drag(axis: .vertical)
        for i in 1...150 {
            let sway = 1.5 * sin(2 * .pi * CGFloat(i) / 10)
            drag.to(CGPoint(x: sway, y: -CGFloat(i) * 2))
        }
        XCTAssertEqual(drag.net, 21, accuracy: 2)
        XCTAssertFalse(drag.emitted.contains(-1))
    }

    /// Hunting for a level: out, back, out, back. Going back along the path
    /// is always down, however many times it turns around.
    func testScrubbingBackAndForthEndsWhereTheFingerIs() {
        var drag = Drag(axis: .horizontal)
        for _ in 0..<6 {
            drag.line(to: CGPoint(x: 60, y: 0))
            drag.line(to: CGPoint(x: -60, y: 0))
        }
        XCTAssertEqual(drag.net, -4, accuracy: 1)
    }

    // MARK: - A line is a circle with a very big radius

    /// A thumb pivots on its joint, so a long pull is an arc; all of it counts.
    func testAThumbArcCountsItsWholeLength() {
        var drag = Drag(axis: .vertical)
        drag.arc(radius: 160, degrees: 100, startHeading: up)
        XCTAssertEqual(drag.net, steps(forArc: 100, radius: 160), accuracy: 1)
        XCTAssertFalse(drag.emitted.contains(-1))
    }

    /// Curling a pull round, either way and at any size, keeps the value
    /// going the way it was going. Nothing switches, so nothing wobbles.
    func testCurlingIntoACircleNeverStepsBack() {
        for radius: CGFloat in [20, 60, 150] {
            for turn: CGFloat in [1, -1] {
                var drag = Drag(axis: .vertical)
                drag.arc(radius: radius, degrees: 540 * turn, startHeading: up)
                let label = "r=\(radius) turn=\(turn)"
                XCTAssertFalse(drag.emitted.contains(-1), label)
                XCTAssertEqual(drag.net, steps(forArc: 540, radius: radius), accuracy: 2, label)
            }
        }
    }

    func testTurningAroundOnACircleWindsBack() {
        var drag = Drag(axis: .horizontal)
        drag.arc(radius: 50, degrees: 720, startHeading: right)
        let atTop = drag.net
        // Turning around on a circle is a cusp, then the other way round.
        drag.arc(radius: 50, degrees: -360, startHeading: right + .pi)
        XCTAssertEqual(drag.net - atTop, -steps(forArc: 360, radius: 50), accuracy: 2)
    }

    /// A hand drifts while it circles. There is no centre to lose, so the
    /// count only follows the finger.
    func testADriftingCircleKeepsCounting() {
        var drag = Drag(axis: .vertical)
        drag.arc(radius: 50, degrees: 360, startHeading: up)
        let before = drag.emitted.count
        for lap in 0..<4 {
            drag.arc(radius: 50, degrees: 180, startHeading: up)
            drag.line(to: CGPoint(x: drag.position.x + 20, y: drag.position.y + 5))
            drag.arc(radius: 50 + CGFloat(lap) * 10, degrees: 180, startHeading: up + .pi)
        }
        XCTAssertFalse(drag.emitted[before...].contains(-1))
    }

    // MARK: - Curvature, for the track to take the gesture's shape

    func testCurvatureIsOneOverTheRadiusWhileCircling() {
        for radius: CGFloat in [30, 80] {
            var drag = Drag(axis: .vertical)
            drag.arc(radius: radius, degrees: 360, startHeading: up)
            XCTAssertEqual(drag.stepper.curvature, 1 / radius, accuracy: 0.3 / radius, "r=\(radius)")
        }
    }

    func testCurvatureIsSignedByWhichWayItBends() {
        var drag = Drag(axis: .vertical)
        drag.arc(radius: 50, degrees: -360, startHeading: up)
        XCTAssertLessThan(drag.stepper.curvature, 0)
    }

    func testCurvatureStraightensOutOnALine() {
        var drag = Drag(axis: .vertical)
        drag.arc(radius: 40, degrees: 360, startHeading: up)
        drag.line(to: CGPoint(x: drag.position.x + 80, y: drag.position.y))
        XCTAssertEqual(drag.stepper.curvature, 0, accuracy: 0.005)
    }

    func testResetForgetsEverything() {
        var drag = Drag(axis: .vertical)
        drag.arc(radius: 50, degrees: 720, startHeading: up)
        drag.stepper.reset()
        XCTAssertEqual(drag.stepper.steps, 0)
        XCTAssertEqual(drag.stepper.curvature, 0)
        drag.position = .zero
        drag.emitted = []
        drag.line(to: CGPoint(x: 0, y: -28))
        XCTAssertEqual(drag.net, 2)
    }
}
