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

    func testNonMediaKeysReturnNil() {
        XCTAssertNil(ConsumerKeyMapper.usage(for: 0))   // A
        XCTAssertNil(ConsumerKeyMapper.usage(for: 36))  // Return
        XCTAssertNil(ConsumerKeyMapper.usage(for: 122)) // F1
    }
}
