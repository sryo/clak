import CoreGraphics
import XCTest
@testable import ClakRemote

/// The pointer is aimed at the Magic Trackpad's feel through the Mac's own
/// mouse acceleration. Reference values come from Apple's IOHIDFamily
/// (IOHIDParametricAcceleration, IOHIDPointerAccelerator) evaluated on the
/// curves a Mac publishes for its trackpad and for Clak Remote.
final class PointerAcceleratorTests: XCTestCase {
    // MARK: - Apple's curves, reproduced

    func testTheMouseCurveMatchesApples() {
        let mouse = MacPointer.mouseCurve
        XCTAssertEqual(mouse(0.05), 0.048261, accuracy: 1e-5)
        XCTAssertEqual(mouse(0.5), 0.596245, accuracy: 1e-5)
        XCTAssertEqual(mouse(2), 3.910265, accuracy: 1e-5)
        XCTAssertEqual(mouse(5), 17.518724, accuracy: 1e-4)
        XCTAssertEqual(mouse(20), 155.130170, accuracy: 1e-3)
    }

    func testTheTrackpadCurveMatchesApples() {
        let trackpad = MacPointer.trackpadCurve
        XCTAssertEqual(trackpad(0.05), 0.048258, accuracy: 1e-5)
        XCTAssertEqual(trackpad(0.5), 0.957351, accuracy: 1e-5)
        XCTAssertEqual(trackpad(2), 10.240565, accuracy: 1e-5)
        XCTAssertEqual(trackpad(5), 58.590400, accuracy: 1e-4)
        XCTAssertEqual(trackpad(20), 497.567906, accuracy: 1e-3)
    }

    /// How far the Mac moves the pointer for one mouse report: it takes the
    /// report's size as the speed, since Clak Remote declares no report rate.
    func testTheMacsMouseMovement() {
        XCTAssertEqual(MacPointer.pixels(forCounts: 1), 0.2459, accuracy: 1e-3)
        XCTAssertEqual(MacPointer.pixels(forCounts: 10), 4.2942, accuracy: 1e-3)
        XCTAssertEqual(MacPointer.pixels(forCounts: 127), 236.5844, accuracy: 1e-2)
    }

    func testTheTrackpadTarget() {
        XCTAssertEqual(MacPointer.trackpadPixelsPerSecond(fingerInchesPerSecond: 1), 195.6673, accuracy: 1e-2)
        XCTAssertEqual(MacPointer.trackpadPixelsPerSecond(fingerInchesPerSecond: 5), 3281.855, accuracy: 0.1)
    }

    // MARK: - The phone's side

    /// Drags a finger at a steady speed for a while, the way touches arrive
    /// (120 Hz), sending a report every 8 ms, and returns where the Mac's
    /// pointer ends up after its own mouse acceleration.
    private func macTravel(
        fingerPointsPerSecond speed: CGFloat,
        direction: CGVector = CGVector(dx: 1, dy: 0),
        seconds: Double = 1,
        accelerator: inout PointerAccelerator
    ) -> CGVector {
        let touchInterval = 1.0 / 120
        let reportInterval = 0.008
        var travel = CGVector.zero
        var nextReport = reportInterval
        var t = 0.0
        let length = hypot(direction.dx, direction.dy)
        while t < seconds {
            t += touchInterval
            let step = speed * CGFloat(touchInterval)
            accelerator.finger(moved: CGVector(dx: direction.dx / length * step, dy: direction.dy / length * step),
                               over: touchInterval)
            while nextReport <= t {
                nextReport += reportInterval
                if let report = accelerator.nextReport() {
                    let moved = MacPointer.pixels(forReport: report)
                    travel.dx += moved.dx
                    travel.dy += moved.dy
                }
            }
        }
        // Let what is still queued out, as the reports keep going.
        for _ in 0..<8 {
            if let report = accelerator.nextReport() {
                let moved = MacPointer.pixels(forReport: report)
                travel.dx += moved.dx
                travel.dy += moved.dy
            }
        }
        return travel
    }

    /// The whole point: whatever the finger speed, the Mac's pointer covers
    /// what a Magic Trackpad would have for the same finger movement.
    func testTheMacMovesAsItsTrackpadWould() {
        for speed: CGFloat in [20, 60, 200, 700, 1500] {
            var accelerator = PointerAccelerator()
            let travel = macTravel(fingerPointsPerSecond: speed, accelerator: &accelerator)
            let inches = Double(speed / PointerAccelerator.pointsPerInch)
            let target = MacPointer.trackpadPixelsPerSecond(fingerInchesPerSecond: inches)
            XCTAssertEqual(Double(travel.dx), target, accuracy: target * 0.03, "\(speed) pt/s")
        }
    }

    /// A finger creeping along still moves the pointer: remainders carry
    /// rather than rounding away.
    func testASlowCreepIsNotLost() {
        var accelerator = PointerAccelerator()
        let speed: CGFloat = 5
        let travel = macTravel(fingerPointsPerSecond: speed, seconds: 2, accelerator: &accelerator)
        let target = 2 * MacPointer.trackpadPixelsPerSecond(fingerInchesPerSecond: Double(speed / PointerAccelerator.pointsPerInch))
        XCTAssertGreaterThan(target, 1)
        XCTAssertEqual(Double(travel.dx), target, accuracy: max(0.5, target * 0.05))
    }

    func testTheDirectionIsKept() {
        var accelerator = PointerAccelerator()
        let travel = macTravel(fingerPointsPerSecond: 300, direction: CGVector(dx: 3, dy: -4), accelerator: &accelerator)
        XCTAssertEqual(Double(travel.dy / travel.dx), -4.0 / 3.0, accuracy: 0.03)
    }

    /// A flick faster than reports can carry must not leave the pointer
    /// drifting on long after the finger has stopped.
    func testAFlickDoesNotRunOnAfterwards() {
        var accelerator = PointerAccelerator()
        _ = macTravel(fingerPointsPerSecond: 4000, seconds: 0.2, accelerator: &accelerator)
        var extra = 0
        while accelerator.nextReport() != nil { extra += 1 }
        XCTAssertLessThanOrEqual(extra, 2)
    }

    func testResetDropsWhatIsQueued() {
        var accelerator = PointerAccelerator()
        accelerator.finger(moved: CGVector(dx: 40, dy: 0), over: 0.01)
        accelerator.reset()
        XCTAssertNil(accelerator.nextReport())
    }
}
