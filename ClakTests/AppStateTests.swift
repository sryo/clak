import XCTest
@testable import Clak

final class AppStateTests: XCTestCase {

    func testAppendTextTrimsToLast5000Characters() {
        let state = AppState()
        state.appendText(String(repeating: "x", count: 4999))
        state.appendText("abc")
        XCTAssertEqual(state.typedText.count, 5000)
        XCTAssertTrue(state.typedText.hasSuffix("abc"))
    }

    func testRemoveLastCharacter() {
        let state = AppState()
        state.appendText("ab")
        state.removeLastCharacter()
        XCTAssertEqual(state.typedText, "a")
        state.removeLastCharacter()
        state.removeLastCharacter() // empty — no-op
        XCTAssertEqual(state.typedText, "")
    }

    func testClearText() {
        let state = AppState()
        state.appendText("hello")
        state.clearText()
        XCTAssertEqual(state.typedText, "")
    }
}
