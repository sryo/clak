import XCTest
@testable import Clak

final class CharacterComposerTests: XCTestCase {

    private let option: UInt8 = 0x04
    private let shift: UInt8 = 0x02

    func testPlainASCIIPassesThrough() {
        XCTAssertEqual(
            CharacterComposer.keystrokes(for: "a"),
            [.init(keyCode: 0x04, modifiers: 0x00)]
        )
        XCTAssertEqual(
            CharacterComposer.keystrokes(for: "A"),
            [.init(keyCode: 0x04, modifiers: shift)]
        )
        XCTAssertEqual(
            CharacterComposer.keystrokes(for: "?"),
            [.init(keyCode: 0x38, modifiers: shift)]
        )
    }

    func testAcuteAccentUsesDeadKey() {
        // é = Option+E (acute dead key), then e
        XCTAssertEqual(
            CharacterComposer.keystrokes(for: "é"),
            [.init(keyCode: 0x08, modifiers: option),
             .init(keyCode: 0x08, modifiers: 0x00)]
        )
    }

    func testDeadKeysCoverCommonAccents() {
        // ü = Option+U (diaeresis), then u
        XCTAssertEqual(
            CharacterComposer.keystrokes(for: "ü"),
            [.init(keyCode: 0x18, modifiers: option),
             .init(keyCode: 0x18, modifiers: 0x00)]
        )
        // ñ = Option+N (tilde), then n
        XCTAssertEqual(
            CharacterComposer.keystrokes(for: "ñ"),
            [.init(keyCode: 0x11, modifiers: option),
             .init(keyCode: 0x11, modifiers: 0x00)]
        )
        // à = Option+` (grave), then a
        XCTAssertEqual(
            CharacterComposer.keystrokes(for: "à"),
            [.init(keyCode: 0x35, modifiers: option),
             .init(keyCode: 0x04, modifiers: 0x00)]
        )
        // Ê = Option+I (circumflex), then Shift+E
        XCTAssertEqual(
            CharacterComposer.keystrokes(for: "Ê"),
            [.init(keyCode: 0x0C, modifiers: option),
             .init(keyCode: 0x08, modifiers: shift)]
        )
    }

    func testPrecomposedInputDecomposes() {
        // U+00E9 (precomposed) and U+0065 U+0301 (decomposed) are the same
        // Character and must produce the same sequence
        let precomposed = Character("\u{00E9}")
        let decomposed = Character("e\u{0301}")
        XCTAssertEqual(
            CharacterComposer.keystrokes(for: precomposed),
            CharacterComposer.keystrokes(for: decomposed)
        )
    }

    func testOptionLayerSymbols() {
        XCTAssertEqual(
            CharacterComposer.keystrokes(for: "ß"),
            [.init(keyCode: 0x16, modifiers: option)]
        )
        XCTAssertEqual(
            CharacterComposer.keystrokes(for: "€"),
            [.init(keyCode: 0x1F, modifiers: option | shift)]
        )
        XCTAssertEqual(
            CharacterComposer.keystrokes(for: "—"),
            [.init(keyCode: 0x2D, modifiers: option | shift)]
        )
        XCTAssertEqual(
            CharacterComposer.keystrokes(for: "ç"),
            [.init(keyCode: 0x06, modifiers: option)]
        )
    }

    func testUncomposableCharactersReturnNil() {
        XCTAssertNil(CharacterComposer.keystrokes(for: "😀"))
        XCTAssertNil(CharacterComposer.keystrokes(for: "漢"))
        XCTAssertNil(CharacterComposer.keystrokes(for: "ы"))
    }

    func testCafeExpandsToFiveStrokes() {
        let strokes = "café".compactMap(CharacterComposer.keystrokes(for:))
        XCTAssertEqual(strokes.count, 4, "every character of café is producible")
        XCTAssertEqual(strokes.flatMap { $0 }.count, 5, "é costs two strokes")
    }
}
