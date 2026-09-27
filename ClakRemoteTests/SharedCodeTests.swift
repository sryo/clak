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

    /// A high-resolution wheel: the wheel and pan declare a physical size, so
    /// the Mac counts 1270 per inch instead of assuming 9, and each count is a
    /// small fraction of a line. The physical items wrap both, and are reset
    /// after, so nothing else inherits them.
    func testHighResolutionScrollDeclaresItsPhysicalSize() throws {
        let plain = HIDReportMap(includeHorizontalScroll: true)
        let fine = HIDReportMap(includeHorizontalScroll: true, highResolutionScroll: true)
        let size: [UInt8] = [0x35, 0xF6, 0x45, 0x0A, 0x65, 0x13, 0x55, 0x0E]
        let reset: [UInt8] = [0x35, 0x00, 0x45, 0x00, 0x65, 0x00, 0x55, 0x00]
        XCTAssertEqual(fine.mouseReportSize, 5)
        XCTAssertEqual(fine.descriptor.count, plain.descriptor.count + size.count + reset.count)

        let wheel: [UInt8] = [0x09, 0x38]
        let sizeAt = try XCTUnwrap(fine.descriptor.firstRange(of: size))
        let wheelAt = try XCTUnwrap(fine.descriptor.firstRange(of: wheel))
        XCTAssertEqual(sizeAt.upperBound, wheelAt.lowerBound, "declared right before the wheel")
        XCTAssertEqual(Array(fine.descriptor.suffix(reset.count + 2)), reset + [0xC0, 0xC0], "reset after the pan")
        // Apple's formula: (logical range × 10^-exponent) / physical range.
        XCTAssertEqual(254 * 100 / 20, HIDReportMap.highResolutionScrollCountsPerInch)
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
