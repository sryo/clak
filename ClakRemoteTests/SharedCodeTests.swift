import XCTest
@testable import ClakRemote

/// Exercises the shared Clak sources in their iOS compilation — the
/// macOS-side ClakTests can't prove the `#if os` split behaves here.
final class SharedCodeTests: XCTestCase {

    private let option: UInt8 = 0x04
    private let shift: UInt8 = 0x02

    // MARK: - HIDReportMap (the 5-byte mouse report is iOS-only in production)

    func testRemoteReportMapIncludesACPan() {
        let map = HIDReportMap(includeHorizontalScroll: true)
        XCTAssertEqual(map.mouseReportSize, 5)
        XCTAssertEqual(map.descriptor.count, 174)
        // AC Pan usage (0x0C page, usage 0x0238) sits before the final End Collections
        let tail = Array(map.descriptor.suffix(17))
        XCTAssertEqual(Array(tail.prefix(5)), [0x05, 0x0C, 0x0A, 0x38, 0x02])
        XCTAssertEqual(Array(tail.suffix(2)), [0xC0, 0xC0])
    }

    func testMacReportMapStaysFourBytes() {
        // Clak (macOS) must keep the 4-byte report so existing bonds stay valid;
        // the split has to hold when this code is compiled for iOS too
        let map = HIDReportMap(includeHorizontalScroll: false)
        XCTAssertEqual(map.mouseReportSize, 4)
        XCTAssertEqual(map.descriptor.count, 159)
    }

    // MARK: - KeyCodeTranslator (character map used by RemoteController.type)

    func testCharacterMapWorksOnIOS() {
        XCTAssertEqual(KeyCodeTranslator.hidKeycode(for: "a")?.keyCode, 0x04)
        XCTAssertEqual(KeyCodeTranslator.hidKeycode(for: "A")?.modifiers, shift)
        XCTAssertEqual(KeyCodeTranslator.hidKeycode(for: " ")?.keyCode, 0x2C)
        XCTAssertEqual(KeyCodeTranslator.hidKeycode(for: "\n")?.keyCode, 0x28)
        XCTAssertNil(KeyCodeTranslator.hidKeycode(for: "é"))
    }

    // MARK: - CharacterComposer (fills the gap hidKeycode leaves)

    func testComposerCoversAccentedLatin() {
        XCTAssertEqual(
            CharacterComposer.keystrokes(for: "é"),
            [.init(keyCode: 0x08, modifiers: option),
             .init(keyCode: 0x08, modifiers: 0x00)]
        )
        XCTAssertEqual(
            CharacterComposer.keystrokes(for: "ñ"),
            [.init(keyCode: 0x11, modifiers: option),
             .init(keyCode: 0x11, modifiers: 0x00)]
        )
        XCTAssertEqual(
            CharacterComposer.keystrokes(for: "ß"),
            [.init(keyCode: 0x16, modifiers: option)]
        )
    }

    func testComposerReportsUnproducibleCharacters() {
        XCTAssertNil(CharacterComposer.keystrokes(for: "😀"))
        XCTAssertNil(CharacterComposer.keystrokes(for: "中"))
    }
}
