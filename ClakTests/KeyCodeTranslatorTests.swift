import XCTest
import Carbon.HIToolbox
@testable import Clak

final class KeyCodeTranslatorTests: XCTestCase {

    // MARK: - Virtual Keycode → HID Usage

    func testLetterKeys() {
        // kVK_ANSI_A = 0x00 → HID 0x04 (a)
        XCTAssertEqual(KeyCodeTranslator.hidUsageCode(from: UInt16(kVK_ANSI_A)), 0x04)
        // kVK_ANSI_S = 0x01 → HID 0x16 (s)
        XCTAssertEqual(KeyCodeTranslator.hidUsageCode(from: UInt16(kVK_ANSI_S)), 0x16)
        // kVK_ANSI_Z = 0x06 → HID 0x1D (z)
        XCTAssertEqual(KeyCodeTranslator.hidUsageCode(from: UInt16(kVK_ANSI_Z)), 0x1D)
    }

    func testNumberKeys() {
        XCTAssertEqual(KeyCodeTranslator.hidUsageCode(from: UInt16(kVK_ANSI_1)), 0x1E)
        XCTAssertEqual(KeyCodeTranslator.hidUsageCode(from: UInt16(kVK_ANSI_0)), 0x27)
    }

    func testSpecialKeys() {
        XCTAssertEqual(KeyCodeTranslator.hidUsageCode(from: UInt16(kVK_Return)), 0x28)
        XCTAssertEqual(KeyCodeTranslator.hidUsageCode(from: UInt16(kVK_Tab)), 0x2B)
        XCTAssertEqual(KeyCodeTranslator.hidUsageCode(from: UInt16(kVK_Space)), 0x2C)
        XCTAssertEqual(KeyCodeTranslator.hidUsageCode(from: UInt16(kVK_Delete)), 0x2A) // Backspace
        XCTAssertEqual(KeyCodeTranslator.hidUsageCode(from: UInt16(kVK_Escape)), 0x29)
    }

    func testArrowKeys() {
        XCTAssertEqual(KeyCodeTranslator.hidUsageCode(from: UInt16(kVK_LeftArrow)), 0x50)
        XCTAssertEqual(KeyCodeTranslator.hidUsageCode(from: UInt16(kVK_RightArrow)), 0x4F)
        XCTAssertEqual(KeyCodeTranslator.hidUsageCode(from: UInt16(kVK_UpArrow)), 0x52)
        XCTAssertEqual(KeyCodeTranslator.hidUsageCode(from: UInt16(kVK_DownArrow)), 0x51)
    }

    func testFunctionKeys() {
        XCTAssertEqual(KeyCodeTranslator.hidUsageCode(from: UInt16(kVK_F1)), 0x3A)
        XCTAssertEqual(KeyCodeTranslator.hidUsageCode(from: UInt16(kVK_F12)), 0x45)
    }

    func testUnknownKeycode() {
        // An invalid virtual keycode should return nil
        XCTAssertNil(KeyCodeTranslator.hidUsageCode(from: 0xFFFF))
    }

    // MARK: - Character → HID Keycode

    func testLowercaseCharacter() {
        let result = KeyCodeTranslator.hidKeycode(for: "a")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.keyCode, 0x04)
        XCTAssertEqual(result?.modifiers, 0x00)
    }

    func testUppercaseCharacter() {
        let result = KeyCodeTranslator.hidKeycode(for: "A")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.keyCode, 0x04)
        XCTAssertEqual(result?.modifiers, 0x02) // Left Shift
    }

    func testDigitCharacter() {
        let result = KeyCodeTranslator.hidKeycode(for: "5")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.keyCode, 0x22)
        XCTAssertEqual(result?.modifiers, 0x00)
    }

    func testShiftedSymbol() {
        let result = KeyCodeTranslator.hidKeycode(for: "!")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.keyCode, 0x1E) // Same as '1'
        XCTAssertEqual(result?.modifiers, 0x02) // Left Shift
    }

    func testSpaceCharacter() {
        let result = KeyCodeTranslator.hidKeycode(for: " ")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.keyCode, 0x2C)
        XCTAssertEqual(result?.modifiers, 0x00)
    }

    func testNewlineCharacter() {
        let result = KeyCodeTranslator.hidKeycode(for: "\n")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.keyCode, 0x28) // Return
    }

    // MARK: - Modifier Byte

    func testShiftModifier() {
        let flags = CGEventFlags.maskShift
        let byte = KeyCodeTranslator.modifierByte(from: flags)
        XCTAssertTrue(byte & 0x02 != 0, "Left Shift bit should be set")
    }

    func testCommandModifier() {
        let flags = CGEventFlags.maskCommand
        let byte = KeyCodeTranslator.modifierByte(from: flags)
        XCTAssertTrue(byte & 0x08 != 0, "Left Command bit should be set")
    }

    func testCombinedModifiers() {
        let flags: CGEventFlags = [.maskShift, .maskCommand]
        let byte = KeyCodeTranslator.modifierByte(from: flags)
        XCTAssertTrue(byte & 0x02 != 0, "Left Shift bit should be set")
        XCTAssertTrue(byte & 0x08 != 0, "Left Command bit should be set")
    }
}
