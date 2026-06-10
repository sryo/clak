import XCTest
@testable import Clak

final class KeyboardLayoutMapperTests: XCTestCase {

    func testLowercaseAndUppercaseShareKeycode() throws {
        guard let lower = KeyboardLayoutMapper.shared.hidKeycode(for: "a"),
              let upper = KeyboardLayoutMapper.shared.hidKeycode(for: "A") else {
            throw XCTSkip("No keyboard layout data available (headless session)")
        }

        XCTAssertEqual(lower.keyCode, upper.keyCode)
        XCTAssertEqual(lower.modifiers, 0)
        // Uppercase requires a Shift modifier (left 0x02 or right 0x20)
        XCTAssertNotEqual(upper.modifiers & 0x22, 0)
    }

    func testSpaceMapsWithoutModifiers() throws {
        guard let space = KeyboardLayoutMapper.shared.hidKeycode(for: " ") else {
            throw XCTSkip("No keyboard layout data available (headless session)")
        }
        XCTAssertEqual(space.keyCode, 0x2C)
        XCTAssertEqual(space.modifiers, 0)
    }
}
