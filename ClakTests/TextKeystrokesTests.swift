import XCTest
@testable import Clak

final class TextKeystrokesTests: XCTestCase {

    private let table: [Character: (keyCode: UInt8, modifiers: UInt8)] = [
        "a": (0x04, 0x00), "A": (0x04, 0x02), " ": (0x2C, 0x00),
    ]

    func testResolvesEveryMappedCharacterInOrder() {
        let strokes = KeyboardLayoutMapper.keystrokes(for: "aA a") { self.table[$0] }
        XCTAssertEqual(strokes, [
            .init(keyCode: 0x04, modifiers: 0x00),
            .init(keyCode: 0x04, modifiers: 0x02),
            .init(keyCode: 0x2C, modifiers: 0x00),
            .init(keyCode: 0x04, modifiers: 0x00),
        ])
    }

    func testSkipsUnmappedCharacters() {
        let strokes = KeyboardLayoutMapper.keystrokes(for: "a😀a") { self.table[$0] }
        XCTAssertEqual(strokes.count, 2)
    }

    func testEmptyTextHasNoStrokes() {
        XCTAssertTrue(KeyboardLayoutMapper.keystrokes(for: "") { self.table[$0] }.isEmpty)
    }

    /// The instance form reads the live layout map, which only the main
    /// thread may touch; it must agree with single-character lookups.
    func testInstanceFormMatchesPerCharacterLookup() throws {
        let mapper = KeyboardLayoutMapper.shared
        guard let a = mapper.hidKeycode(for: "a") else {
            throw XCTSkip("No keyboard layout data available (headless session)")
        }
        XCTAssertEqual(mapper.keystrokes(for: "aa"),
                       [.init(keyCode: a.keyCode, modifiers: a.modifiers),
                        .init(keyCode: a.keyCode, modifiers: a.modifiers)])
    }
}
