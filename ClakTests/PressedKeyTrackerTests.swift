import XCTest
@testable import Clak

final class PressedKeyTrackerTests: XCTestCase {

    private var tracker: PressedKeyTracker!

    override func setUp() {
        super.setUp()
        tracker = PressedKeyTracker()
    }

    func testKeyDownAddsUsage() {
        XCTAssertEqual(tracker.keyDown(keyCode: 0, usage: 0x04), [0x04])
    }

    func testChordKeepsHeldKeys() {
        _ = tracker.keyDown(keyCode: 0, usage: 0x04)                            // A down
        XCTAssertEqual(tracker.keyDown(keyCode: 1, usage: 0x16), [0x04, 0x16])  // S down, A held
        XCTAssertEqual(tracker.keyUp(keyCode: 0), [0x16])                       // A up, S still held
        XCTAssertEqual(tracker.keyUp(keyCode: 1), [])
    }

    func testDuplicateKeyDownDoesNotDuplicate() {
        _ = tracker.keyDown(keyCode: 0, usage: 0x04)
        XCTAssertEqual(tracker.keyDown(keyCode: 0, usage: 0x04), [0x04])
    }

    func testSeventhSimultaneousKeyIsIgnored() {
        for i in 0..<6 {
            _ = tracker.keyDown(keyCode: UInt16(i), usage: UInt8(0x04 + i))
        }
        let snapshot = tracker.keyDown(keyCode: 6, usage: 0x0A)
        XCTAssertEqual(snapshot.count, 6)
        XCTAssertFalse(snapshot.contains(0x0A))
    }

    func testKeyUpForUnknownKeyCodeIsNoop() {
        _ = tracker.keyDown(keyCode: 0, usage: 0x04)
        XCTAssertEqual(tracker.keyUp(keyCode: 99), [0x04])
    }

    func testReset() {
        _ = tracker.keyDown(keyCode: 0, usage: 0x04)
        _ = tracker.keyDown(keyCode: 1, usage: 0x16)
        tracker.reset()
        XCTAssertEqual(tracker.usages, [])
    }
}
