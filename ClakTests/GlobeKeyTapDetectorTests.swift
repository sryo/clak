import XCTest
@testable import Clak

final class GlobeKeyTapDetectorTests: XCTestCase {

    func testPressAndReleaseIsATap() {
        var detector = GlobeKeyTapDetector()
        XCTAssertFalse(detector.globeChanged(isDown: true))
        XCTAssertTrue(detector.globeChanged(isDown: false))
    }

    func testKeyWhileHeldIsNotATap() {
        var detector = GlobeKeyTapDetector()
        _ = detector.globeChanged(isDown: true)
        detector.otherInput() // fn+arrow
        XCTAssertFalse(detector.globeChanged(isDown: false))
    }

    func testReleaseWithoutPressIsNotATap() {
        var detector = GlobeKeyTapDetector()
        XCTAssertFalse(detector.globeChanged(isDown: false))
    }

    func testTapAfterASpoiledOne() {
        var detector = GlobeKeyTapDetector()
        _ = detector.globeChanged(isDown: true)
        detector.otherInput()
        _ = detector.globeChanged(isDown: false)
        _ = detector.globeChanged(isDown: true)
        XCTAssertTrue(detector.globeChanged(isDown: false))
    }
}
