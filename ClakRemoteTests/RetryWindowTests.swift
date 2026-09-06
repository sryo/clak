import XCTest
@testable import ClakRemote

final class RetryWindowTests: XCTestCase {

    func testRepublishDelayDoublesToACeiling() {
        XCTAssertEqual(RemoteController.republishDelay(afterAttempts: 0), 8)
        XCTAssertEqual(RemoteController.republishDelay(afterAttempts: 1), 16)
        XCTAssertEqual(RemoteController.republishDelay(afterAttempts: 2), 32)
        XCTAssertEqual(RemoteController.republishDelay(afterAttempts: 3), 64)
        XCTAssertEqual(RemoteController.republishDelay(afterAttempts: 4), 120)
        XCTAssertEqual(RemoteController.republishDelay(afterAttempts: 9), 120)
    }

    func testProgressRunsFromStartToFullAndClamps() {
        let start = Date()
        let window = RemoteController.RetryWindow(start: start, duration: 8, attempt: 0)
        XCTAssertEqual(window.progress(at: start), 0)
        XCTAssertEqual(window.progress(at: start.addingTimeInterval(4)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(window.progress(at: start.addingTimeInterval(8)), 1)
        XCTAssertEqual(window.progress(at: start.addingTimeInterval(20)), 1)
        XCTAssertEqual(window.progress(at: start.addingTimeInterval(-3)), 0)
    }

    func testZeroDurationWindowIsAlreadyFull() {
        let window = RemoteController.RetryWindow(start: Date(), duration: 0, attempt: 2)
        XCTAssertEqual(window.progress(at: Date()), 1)
    }
}
