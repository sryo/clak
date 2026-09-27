import XCTest
@testable import Clak

final class EchoTextTests: XCTestCase {

    func testKeepsAscii() {
        XCTAssertEqual(EchoText.displayable("a"), "a")
        XCTAssertEqual(EchoText.displayable(" "), " ")
    }

    func testKeepsAccentedAndNonLatin() {
        XCTAssertEqual(EchoText.displayable("é"), "é")
        XCTAssertEqual(EchoText.displayable("ñ"), "ñ")
        XCTAssertEqual(EchoText.displayable("ß"), "ß")
        XCTAssertEqual(EchoText.displayable("ж"), "ж")
        XCTAssertEqual(EchoText.displayable("´"), "´")
    }

    func testKeepsCharactersOutsideTheBMP() {
        XCTAssertEqual(EchoText.displayable("😀"), "😀")
    }

    func testDropsControls() {
        XCTAssertEqual(EchoText.displayable("\u{1B}"), "")
        XCTAssertEqual(EchoText.displayable("\u{7F}"), "")
        XCTAssertEqual(EchoText.displayable("\u{08}"), "")
        XCTAssertEqual(EchoText.displayable("\r"), "")
    }

    // AppKit reports arrows, F-keys, Home/End as private-use scalars (U+F700…)
    func testDropsFunctionKeyPrivateUseScalars() {
        XCTAssertEqual(EchoText.displayable("\u{F700}"), "")
        XCTAssertEqual(EchoText.displayable("\u{F708}"), "")
    }

    func testFiltersWithinAString() {
        XCTAssertEqual(EchoText.displayable("a\u{1B}é"), "aé")
    }
}
