import CoreGraphics
import XCTest
@testable import ClakRemote

/// Replays drag paths through the dial. Translations are in points from where
/// the finger landed, which is the dial's centre, in screen coordinates (y
/// grows downward, so an angle that increases is clockwise as seen).
final class PullStepperTests: XCTestCase {
    typealias Step = PullStepper.Step

    private struct Drag {
        var stepper: PullStepper
        var position = CGPoint.zero
        /// Every step emitted, in order, as the key would send them.
        var emitted: [Step] = []

        init(allowsFine: Bool = true) { stepper = PullStepper(allowsFine: allowsFine) }

        mutating func to(_ point: CGPoint) {
            position = point
            emitted += stepper.move(to: CGSize(width: point.x, height: point.y))
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

        /// Goes round the centre from the finger's current angle, keeping its
        /// distance. Positive degrees are clockwise on screen.
        mutating func turn(_ degrees: CGFloat) {
            let radius = hypot(position.x, position.y)
            let from = atan2(position.y, position.x)
            let sweep = degrees * .pi / 180
            let count = max(1, Int((abs(sweep) * radius / 2).rounded(.up)))
            for i in 1...count {
                let a = from + sweep * CGFloat(i) / CGFloat(count)
                to(CGPoint(x: radius * cos(a), y: radius * sin(a)))
            }
        }

        /// Straight out or in to `radius`, keeping the finger's angle.
        mutating func reach(_ radius: CGFloat) {
            let a = atan2(position.y, position.x)
            line(to: CGPoint(x: radius * cos(a), y: radius * sin(a)))
        }

        var quarters: Int { stepper.quarters }
        var sentQuarters: Int { emitted.reduce(0) { $0 + $1.direction * ($1.isQuarter ? 1 : 4) } }
    }

    private let up = Step(direction: 1, isQuarter: false)
    private let down = Step(direction: -1, isQuarter: false)
    private let quarterUp = Step(direction: 1, isQuarter: true)
    private let quarterDown = Step(direction: -1, isQuarter: true)

    /// Degrees of turn for a number of quarter steps.
    private func degrees(quarters: CGFloat) -> CGFloat {
        quarters * PullStepper.quarterAngle * 180 / .pi
    }

    // MARK: - Pulling out only sizes the dial

    func testPullingStraightOutChangesNothing() {
        for end in [CGPoint(x: 0, y: -250), CGPoint(x: 180, y: 0), CGPoint(x: -120, y: -120)] {
            var drag = Drag()
            drag.line(to: end)
            XCTAssertEqual(drag.emitted, [], "to \(end)")
            XCTAssertEqual(drag.stepper.radius, hypot(end.x, end.y), accuracy: 0.001)
        }
    }

    /// Close to the centre an angle swings wildly for a tiny movement, so
    /// there it counts for nothing.
    func testTheMiddleIsDead() {
        var drag = Drag()
        drag.line(to: CGPoint(x: PullStepper.deadZone - 4, y: 0))
        drag.turn(720)
        XCTAssertEqual(drag.emitted, [])
        XCTAssertNil(drag.stepper.angle)
    }

    // MARK: - Turning near the key

    /// Out to the left, then over the top of the key to the right: the whole
    /// of the Mac's volume or brightness range.
    func testAHalfTurnOverTheTopIsSixteenSteps() {
        var drag = Drag()
        drag.line(to: CGPoint(x: -80, y: 0))
        drag.turn(180)
        XCTAssertEqual(drag.emitted, Array(repeating: up, count: 16))
        XCTAssertEqual(drag.quarters, 64)
    }

    func testCounterclockwiseLowers() {
        var drag = Drag()
        drag.line(to: CGPoint(x: 80, y: 0))
        drag.turn(-180)
        XCTAssertEqual(drag.emitted, Array(repeating: down, count: 16))
    }

    func testTurningBackWindsBack() {
        var drag = Drag()
        drag.line(to: CGPoint(x: -80, y: 0))
        drag.turn(180)
        drag.turn(-90)
        XCTAssertEqual(drag.quarters, 32)
        XCTAssertEqual(drag.emitted.suffix(8), Array(repeating: down, count: 8))
    }

    /// Past a full turn it keeps counting: the dial has no end stops.
    func testLapsKeepCounting() {
        var drag = Drag()
        drag.line(to: CGPoint(x: 0, y: -70))
        drag.turn(720)
        XCTAssertEqual(drag.quarters, 64 * 4)
    }

    /// Straight across the key passes through the middle, and must not read
    /// as the half turn that its two ends are apart.
    func testCrossingThroughTheMiddleIsNotATurn() {
        var drag = Drag()
        drag.line(to: CGPoint(x: -80, y: 0))
        drag.line(to: CGPoint(x: 80, y: 0))
        XCTAssertEqual(drag.emitted, [])
    }

    /// Swiping sideways off the key is a pull out, not a turn: it once
    /// raised the volume by twelve.
    func testASidewaysSwipeThatDriftsDoesNothing() {
        var drag = Drag()
        drag.line(to: CGPoint(x: -36, y: -4))
        drag.line(to: CGPoint(x: -52, y: -7))
        drag.line(to: CGPoint(x: -200, y: -7))
        XCTAssertEqual(drag.emitted, [])
    }

    // MARK: - Far out, the dial subdivides

    /// The same turn is the same amount at any distance; far out it just
    /// lands on every quarter on the way.
    func testFarOutTheSameTurnLandsOnEveryQuarter() {
        var drag = Drag()
        drag.line(to: CGPoint(x: -160, y: 0))
        drag.turn(180)
        XCTAssertTrue(drag.stepper.isFine)
        XCTAssertEqual(drag.quarters, 64)
        XCTAssertEqual(drag.emitted, Array(repeating: quarterUp, count: 64))
    }

    func testTheValueFollowsTheAngleAtAnyDistance() {
        for radius: CGFloat in [40, 90, 220] {
            var drag = Drag()
            drag.line(to: CGPoint(x: 0, y: -radius))
            drag.turn(90)
            XCTAssertEqual(drag.quarters, 32, "r=\(radius)")
            XCTAssertEqual(drag.sentQuarters, 32, "r=\(radius)")
        }
    }

    /// A finger hovering at the edge of the fine zone must not flicker in
    /// and out of it.
    func testTheFineZoneHoldsNearItsEdge() {
        let edge = PullStepper.fineRadius
        var drag = Drag()
        drag.line(to: CGPoint(x: 0, y: -(edge - 5)))
        XCTAssertFalse(drag.stepper.isFine, "not yet in")
        drag.line(to: CGPoint(x: 0, y: -(edge + 1)))
        XCTAssertTrue(drag.stepper.isFine)
        drag.line(to: CGPoint(x: 0, y: -(edge - 5)))
        XCTAssertTrue(drag.stepper.isFine, "held through the overlap")
        drag.line(to: CGPoint(x: 0, y: -(edge - 15)))
        XCTAssertFalse(drag.stepper.isFine)
    }

    /// Near the key the value trails the finger by up to three quarters,
    /// waiting for the next whole step. Moving out must not pay those
    /// quarters out at once: pulling out never changes the value.
    func testMovingOutPartWayToAStepChangesNothing() {
        var drag = Drag()
        drag.line(to: CGPoint(x: -80, y: 0))
        drag.turn(degrees(quarters: 7))
        XCTAssertEqual(drag.quarters, 4)
        let before = drag.emitted.count
        drag.reach(200)
        XCTAssertTrue(drag.stepper.isFine)
        XCTAssertEqual(drag.emitted.count, before)
        drag.turn(degrees(quarters: 2))
        XCTAssertEqual(Array(drag.emitted[before...]), [quarterUp, quarterUp])
    }

    /// Coming back in at +3¼, the dial is back on whole steps and the
    /// quarter is not carried: the next tick up lands on +4, sent as the
    /// three quarters that close the gap.
    func testComingBackInLandsTheNextStepOnAWhole() {
        var drag = Drag()
        drag.line(to: CGPoint(x: -160, y: 0))
        drag.turn(degrees(quarters: 13.5))
        XCTAssertEqual(drag.quarters, 13)
        drag.reach(80)
        let before = drag.emitted.count
        drag.turn(degrees(quarters: 3))
        XCTAssertEqual(drag.quarters, 16)
        XCTAssertEqual(Array(drag.emitted[before...]), [quarterUp, quarterUp, quarterUp])
        drag.turn(degrees(quarters: 4))
        XCTAssertEqual(drag.quarters, 20)
        XCTAssertEqual(drag.emitted.last, up)
    }

    func testComingBackInAndDownDropsTheQuarter() {
        var drag = Drag()
        drag.line(to: CGPoint(x: -160, y: 0))
        drag.turn(degrees(quarters: 13.5))
        drag.reach(80)
        let before = drag.emitted.count
        drag.turn(-degrees(quarters: 2))
        XCTAssertEqual(drag.quarters, 12)
        XCTAssertEqual(Array(drag.emitted[before...]), [quarterDown])
    }

    /// Seeking has no quarter step, so the scrubber never subdivides.
    func testAKeyWithoutFineStepsStaysWhole() {
        var drag = Drag(allowsFine: false)
        drag.line(to: CGPoint(x: -200, y: 0))
        drag.turn(90)
        XCTAssertFalse(drag.stepper.isFine)
        XCTAssertEqual(drag.emitted, Array(repeating: up, count: 8))
    }

    func testTheReadoutCountsWholeStepsAndQuarters() {
        let cases: [(Int, String)] = [
            (0, "0"), (4, "+1"), (13, "+3¼"), (2, "+½"), (3, "+¾"),
            (-1, "-¼"), (-10, "-2½"), (-64, "-16"),
        ]
        for (quarters, text) in cases {
            XCTAssertEqual(PullStepper.readout(quarters: quarters), text, "\(quarters)")
        }
    }

    // MARK: - What the ring shows

    /// The start of the scale is where the finger's angle was when it began,
    /// carried round by the net turn: it stays put on screen while the
    /// finger goes round.
    func testTheStartStaysWhereTheTurnBegan() throws {
        var drag = Drag()
        drag.line(to: CGPoint(x: -80, y: 0))
        drag.turn(135)
        let start = try XCTUnwrap(drag.stepper.startAngle)
        XCTAssertEqual(cos(start), -1, accuracy: 1e-6)
        XCTAssertEqual(drag.stepper.turned, 135 * .pi / 180, accuracy: 1e-6)
    }

    func testResetForgetsEverything() {
        var drag = Drag()
        drag.line(to: CGPoint(x: -80, y: 0))
        drag.turn(270)
        drag.stepper.reset()
        XCTAssertEqual(drag.quarters, 0)
        XCTAssertEqual(drag.stepper.turned, 0)
        XCTAssertNil(drag.stepper.angle)
        drag.position = .zero
        drag.emitted = []
        drag.line(to: CGPoint(x: 0, y: -80))
        drag.turn(45)
        XCTAssertEqual(drag.emitted, Array(repeating: up, count: 4))
    }
}
