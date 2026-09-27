import XCTest
import CoreGraphics
@testable import Clak

final class KeyboardEventCaptureTests: XCTestCase {

    private final class RecordingDelegate: KeyboardEventCaptureDelegate {
        var keyDowns: [(UInt16, Bool)] = []
        var keyUps: [UInt16] = []
        var modifierChanges = 0
        var drops = 0
        var consume = false

        func keyboardCapture(_ capture: KeyboardEventCapture, didCaptureKeyDown keyCode: UInt16, modifiers: CGEventFlags, isAutorepeat: Bool) -> Bool {
            keyDowns.append((keyCode, isAutorepeat))
            return consume
        }

        func keyboardCapture(_ capture: KeyboardEventCapture, didCaptureKeyUp keyCode: UInt16, modifiers: CGEventFlags) -> Bool {
            keyUps.append(keyCode)
            return consume
        }

        var modifierKeyCodes: [UInt16] = []

        func keyboardCapture(_ capture: KeyboardEventCapture, didCaptureModifierChange modifiers: CGEventFlags, keyCode: UInt16) -> Bool {
            modifierChanges += 1
            modifierKeyCodes.append(keyCode)
            return consume
        }

        func keyboardCaptureDidDropEvents(_ capture: KeyboardEventCapture) {
            drops += 1
        }
    }

    private var capture: KeyboardEventCapture!
    private var delegate: RecordingDelegate!

    override func setUp() {
        super.setUp()
        capture = KeyboardEventCapture()
        delegate = RecordingDelegate()
        capture.delegate = delegate
    }

    private func keyEvent(_ keyCode: UInt16, down: Bool) throws -> CGEvent {
        try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down))
    }

    func testKeyDownReachesDelegate() throws {
        let consumed = capture.handle(type: .keyDown, event: try keyEvent(0x00, down: true))
        XCTAssertFalse(consumed)
        XCTAssertEqual(delegate.keyDowns.map(\.0), [0x00])
        XCTAssertEqual(delegate.keyDowns.map(\.1), [false])
    }

    func testAutorepeatFlagIsPassedThrough() throws {
        let event = try keyEvent(0x00, down: true)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        capture.handle(type: .keyDown, event: event)
        XCTAssertEqual(delegate.keyDowns.map(\.1), [true])
    }

    func testKeyUpReachesDelegateAndConsumptionIsHonored() throws {
        delegate.consume = true
        XCTAssertTrue(capture.handle(type: .keyUp, event: try keyEvent(0x0C, down: false)))
        XCTAssertEqual(delegate.keyUps, [0x0C])
    }

    func testFlagsChangedReachesDelegate() throws {
        capture.handle(type: .flagsChanged, event: try keyEvent(0x38, down: true))
        XCTAssertEqual(delegate.modifierChanges, 1)
        XCTAssertEqual(delegate.modifierKeyCodes, [0x38])
    }

    /// A disabled tap lost every event while it was off, key-ups included —
    /// the delegate has to hear about it or a held key repeats on the host forever.
    func testTapDisabledByTimeoutReportsDroppedEvents() throws {
        let consumed = capture.handle(type: .tapDisabledByTimeout, event: try keyEvent(0, down: true))
        XCTAssertFalse(consumed)
        XCTAssertEqual(delegate.drops, 1)
        XCTAssertTrue(delegate.keyDowns.isEmpty)
    }

    func testTapDisabledByUserInputReportsDroppedEvents() throws {
        capture.handle(type: .tapDisabledByUserInput, event: try keyEvent(0, down: true))
        XCTAssertEqual(delegate.drops, 1)
    }

    func testOtherEventTypesAreIgnored() throws {
        XCTAssertFalse(capture.handle(type: .leftMouseDown, event: try keyEvent(0, down: true)))
        XCTAssertEqual(delegate.drops + delegate.keyDowns.count + delegate.keyUps.count + delegate.modifierChanges, 0)
    }
}
