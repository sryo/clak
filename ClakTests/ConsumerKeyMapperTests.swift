import XCTest
@testable import Clak

final class ConsumerKeyMapperTests: XCTestCase {

    func testMediaKeyMappings() {
        XCTAssertEqual(ConsumerKeyMapper.usage(for: 98), 0x00B6)   // F7 → previous track
        XCTAssertEqual(ConsumerKeyMapper.usage(for: 100), 0x00CD)  // F8 → play/pause
        XCTAssertEqual(ConsumerKeyMapper.usage(for: 101), 0x00B5)  // F9 → next track
        XCTAssertEqual(ConsumerKeyMapper.usage(for: 109), 0x00E2)  // F10 → mute
        XCTAssertEqual(ConsumerKeyMapper.usage(for: 103), 0x00EA)  // F11 → volume down
        XCTAssertEqual(ConsumerKeyMapper.usage(for: 111), 0x00E9)  // F12 → volume up
    }

    func testSystemKeyMappings() {
        XCTAssertEqual(ConsumerKeyMapper.usage(for: 122), 0x0070)  // F1 → brightness down
        XCTAssertEqual(ConsumerKeyMapper.usage(for: 120), 0x006F)  // F2 → brightness up
        XCTAssertEqual(ConsumerKeyMapper.usage(for: 118), 0x0221)  // F4 → search
        XCTAssertEqual(ConsumerKeyMapper.usage(for: 96), 0x00CF)   // F5 → dictation
        XCTAssertEqual(ConsumerKeyMapper.usage(for: 177), 0x0221)  // Spotlight key
        XCTAssertEqual(ConsumerKeyMapper.usage(for: 176), 0x00CF)  // Dictation key
    }

    /// The consumer report's logical range stops at 0x3FF
    func testEveryUsageFitsTheReportMap() {
        for keyCode in UInt16(0)...255 {
            if let usage = ConsumerKeyMapper.usage(for: keyCode) {
                XCTAssertLessThanOrEqual(usage, 0x3FF, "keycode \(keyCode)")
            }
        }
        XCTAssertLessThanOrEqual(ConsumerKeyMapper.globeUsage, 0x3FF)
    }

    func testNonMediaKeysReturnNil() {
        XCTAssertNil(ConsumerKeyMapper.usage(for: 0))   // A
        XCTAssertNil(ConsumerKeyMapper.usage(for: 36))  // Return
        XCTAssertNil(ConsumerKeyMapper.usage(for: 99))  // F3 (Mission Control stays local)
        XCTAssertNil(ConsumerKeyMapper.usage(for: 97))  // F6
    }
}
