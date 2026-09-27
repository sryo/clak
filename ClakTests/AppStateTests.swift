import XCTest
@testable import Clak

final class AppStateTests: XCTestCase {

    private var scheduler: ManualTickScheduler!

    override func setUp() {
        super.setUp()
        scheduler = ManualTickScheduler()
    }

    private func makeState() -> AppState {
        AppState(echoScheduler: scheduler)
    }

    func testFiftyAppendsInOneFramePublishOnce() {
        let state = makeState()
        for _ in 0..<50 { state.appendText("a") }
        XCTAssertEqual(state.typedText, "", "nothing published inside the frame")
        XCTAssertEqual(scheduler.scheduledCount, 1)
        scheduler.advance(by: AppState.echoFrameInterval)
        XCTAssertEqual(state.typedText, String(repeating: "a", count: 50))
    }

    func testAppendKeepsTheNewestTextWithinTheCap() {
        let state = makeState()
        state.appendText(String(repeating: "x", count: 4999))
        state.appendText("abc")
        scheduler.advance(by: 1)
        XCTAssertLessThanOrEqual(state.typedText.count, EchoBuffer.maxLength)
        XCTAssertTrue(state.typedText.hasSuffix("abc"))
    }

    func testRemoveLastCharacter() {
        let state = makeState()
        state.appendText("ab")
        state.removeLastCharacter()
        scheduler.advance(by: 1)
        XCTAssertEqual(state.typedText, "a")
        state.removeLastCharacter()
        state.removeLastCharacter() // empty — no-op
        scheduler.advance(by: 1)
        XCTAssertEqual(state.typedText, "")
    }

    func testClearTextIsImmediateAndBeatsAPendingPublish() {
        let state = makeState()
        state.appendText("hello")
        scheduler.advance(by: 1)
        state.appendText("!")
        state.clearText()
        XCTAssertEqual(state.typedText, "")
        scheduler.advance(by: 1)
        XCTAssertEqual(state.typedText, "")
    }
}
