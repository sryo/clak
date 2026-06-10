import XCTest
@testable import Clak

final class ModifierKeyTrackerTests: XCTestCase {

    var tracker: ModifierKeyTracker!

    override func setUp() {
        super.setUp()
        tracker = ModifierKeyTracker()
    }

    func testInitialState() {
        XCTAssertEqual(tracker.currentModifiers, 0x00)
        XCTAssertFalse(tracker.isShiftPressed)
        XCTAssertFalse(tracker.isControlPressed)
        XCTAssertFalse(tracker.isAltPressed)
        XCTAssertFalse(tracker.isCommandPressed)
    }

    func testShiftPressed() {
        let result = tracker.update(with: .maskShift)
        XCTAssertTrue(result & 0x22 != 0, "Shift bit should be set")
        XCTAssertTrue(tracker.isShiftPressed)
    }

    func testControlPressed() {
        let result = tracker.update(with: .maskControl)
        XCTAssertTrue(result & 0x11 != 0, "Control bit should be set")
        XCTAssertTrue(tracker.isControlPressed)
    }

    func testAltPressed() {
        let result = tracker.update(with: .maskAlternate)
        XCTAssertTrue(result & 0x44 != 0, "Alt bit should be set")
        XCTAssertTrue(tracker.isAltPressed)
    }

    func testCommandPressed() {
        let result = tracker.update(with: .maskCommand)
        XCTAssertTrue(result & 0x88 != 0, "Command bit should be set")
        XCTAssertTrue(tracker.isCommandPressed)
    }

    func testReset() {
        tracker.update(with: [.maskShift, .maskCommand])
        XCTAssertNotEqual(tracker.currentModifiers, 0x00)

        tracker.reset()
        XCTAssertEqual(tracker.currentModifiers, 0x00)
        XCTAssertFalse(tracker.isShiftPressed)
        XCTAssertFalse(tracker.isCommandPressed)
    }

    func testNoModifiers() {
        let result = tracker.update(with: [])
        XCTAssertEqual(result, 0x00)
    }

    func testMultipleModifiers() {
        let result = tracker.update(with: [.maskShift, .maskControl])
        XCTAssertTrue(tracker.isShiftPressed)
        XCTAssertTrue(tracker.isControlPressed)
        XCTAssertFalse(tracker.isAltPressed)
        XCTAssertFalse(tracker.isCommandPressed)
        XCTAssertNotEqual(result, 0x00)
    }
}
