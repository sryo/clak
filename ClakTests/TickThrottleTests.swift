import XCTest
@testable import Clak

final class TickThrottleTests: XCTestCase {

    func testTrailingThrottleFiresOncePerInterval() {
        let scheduler = ManualTickScheduler()
        var fires: [TimeInterval] = []
        let throttle = TickThrottle(interval: 0.016, leading: false, scheduler: scheduler) {
            fires.append(scheduler.now)
        }
        for _ in 0..<50 { throttle.request() }
        XCTAssertEqual(fires, [], "trailing: nothing fires inside the frame")
        scheduler.advance(by: 0.016)
        XCTAssertEqual(fires.count, 1)
    }

    func testLeadingThrottleFiresImmediatelyThenSpacesFires() {
        let scheduler = ManualTickScheduler()
        var fires: [TimeInterval] = []
        let throttle = TickThrottle(interval: 0.015, leading: true, scheduler: scheduler) {
            fires.append(scheduler.now)
        }
        throttle.request()
        XCTAssertEqual(fires, [0])
        throttle.request()
        throttle.request()
        XCTAssertEqual(fires.count, 1)
        scheduler.advance(by: 0.1)
        XCTAssertEqual(fires.count, 2)
        XCTAssertEqual(fires.last ?? -1, 0.015, accuracy: 1e-9)
    }

    func testFlushRunsNowAndDropsThePendingFire() {
        let scheduler = ManualTickScheduler()
        var fires = 0
        let throttle = TickThrottle(interval: 0.016, leading: false, scheduler: scheduler) { fires += 1 }
        throttle.request()
        throttle.flush()
        XCTAssertEqual(fires, 1)
        scheduler.advance(by: 1)
        XCTAssertEqual(fires, 1)
    }
}
