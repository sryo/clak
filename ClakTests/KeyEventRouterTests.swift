import CoreGraphics
import XCTest
@testable import Clak

final class KeyEventRouterTests: XCTestCase {

    private typealias S = KeyGateSnapshot

    private static let pasteChord = ShortcutBinding(
        keyCode: 9, modifiers: CGEventFlags([.maskCommand, .maskShift]).rawValue, action: .pasteToDevice
    )

    /// Frontmost, connected, forwarding, not global.
    private static let local = S(
        isAppActive: true, isGlobalForwarding: false, isForwarding: true,
        isConnected: true, isRecording: false, isConsumeCapable: true,
        shortcuts: [pasteChord]
    )

    /// Global forwarding from another app, with a consuming tap.
    private static let global: S = {
        var s = local
        s.isAppActive = false
        s.isGlobalForwarding = true
        return s
    }()

    private let keyA: UInt16 = 0      // HID 0x04
    private let keyF8: UInt16 = 100   // play/pause
    private let unmapped: UInt16 = 0xFF

    private func down(_ keyCode: UInt16, _ flags: CGEventFlags = [], repeat: Bool = false) -> KeyEventInput {
        .keyDown(keyCode: keyCode, modifiers: flags, isAutorepeat: `repeat`)
    }

    private func with(_ base: S, _ edit: (inout S) -> Void) -> S {
        var s = base
        edit(&s)
        return s
    }

    // MARK: - Key down

    func testLocalKeyDownSendsWithoutConsuming() {
        XCTAssertEqual(KeyEventRouter.route(Self.local, down(keyA)), KeyRoute(consume: false, action: .key(usage: 0x04)))
    }

    func testGlobalKeyDownSendsAndConsumes() {
        XCTAssertEqual(KeyEventRouter.route(Self.global, down(keyA)), KeyRoute(consume: true, action: .key(usage: 0x04)))
    }

    func testGlobalWithoutConsumeCapableTapSendsButCannotConsume() {
        let s = with(Self.global) { $0.isConsumeCapable = false }
        XCTAssertEqual(KeyEventRouter.route(s, down(keyA)), KeyRoute(consume: false, action: .key(usage: 0x04)))
    }

    func testBackgroundNonGlobalIgnores() {
        let s = with(Self.local) { $0.isAppActive = false }
        XCTAssertEqual(KeyEventRouter.route(s, down(keyA)), .pass)
        XCTAssertEqual(KeyEventRouter.route(s, down(9, [.maskCommand, .maskShift])), .pass,
                       "shortcuts don't fire from other apps outside global mode")
    }

    func testDisconnectedIgnoresEvenShortcuts() {
        let s = with(Self.global) { $0.isConnected = false }
        XCTAssertEqual(KeyEventRouter.route(s, down(9, [.maskCommand, .maskShift])), .pass)
    }

    func testRecordingWhileFrontmostPassesEverything() {
        let s = with(Self.local) { $0.isRecording = true }
        XCTAssertEqual(KeyEventRouter.route(s, down(keyA)), .pass)
        XCTAssertEqual(KeyEventRouter.route(s, down(9, [.maskCommand, .maskShift])), .pass)
        XCTAssertEqual(KeyEventRouter.route(s, .keyUp(keyCode: keyA, modifiers: [])), .pass)
    }

    /// A recorder left open in Settings must not stall global forwarding.
    func testRecordingInTheBackgroundDoesNotBlockGlobal() {
        let s = with(Self.global) { $0.isRecording = true }
        XCTAssertEqual(KeyEventRouter.route(s, down(keyA)), KeyRoute(consume: true, action: .key(usage: 0x04)))
    }

    func testShortcutRunsEvenWhilePaused() {
        let s = with(Self.local) { $0.isForwarding = false }
        XCTAssertEqual(KeyEventRouter.route(s, down(9, [.maskCommand, .maskShift])),
                       KeyRoute(consume: false, action: .shortcut(.pasteToDevice)))
    }

    /// The escape chord that turns global mode off is consumed under the
    /// rules in force when it was pressed.
    func testGlobalShortcutIsConsumed() {
        XCTAssertEqual(KeyEventRouter.route(Self.global, down(9, [.maskCommand, .maskShift])),
                       KeyRoute(consume: true, action: .shortcut(.pasteToDevice)))
    }

    func testShortcutMatchIgnoresNonShortcutFlags() {
        let flags: CGEventFlags = [.maskCommand, .maskShift, .maskAlphaShift, .maskNonCoalesced]
        XCTAssertEqual(KeyEventRouter.route(Self.local, down(9, flags)).action, .shortcut(.pasteToDevice))
        XCTAssertEqual(KeyEventRouter.route(Self.local, down(9, [.maskCommand])).action, .key(usage: 0x19),
                       "a different modifier set is an ordinary key")
    }

    func testAutorepeatNeverFiresShortcutsOrSends() {
        XCTAssertEqual(KeyEventRouter.route(Self.global, down(9, [.maskCommand, .maskShift], repeat: true)),
                       KeyRoute(consume: true, action: .none))
        XCTAssertEqual(KeyEventRouter.route(Self.local, down(keyA, repeat: true)), KeyRoute(consume: false, action: .none))
    }

    func testPausedPassesKeys() {
        let s = with(Self.global) { $0.isForwarding = false }
        XCTAssertEqual(KeyEventRouter.route(s, down(keyA)), .pass)
    }

    func testMediaKeyGoesToConsumerPage() {
        XCTAssertEqual(KeyEventRouter.route(Self.global, down(keyF8)),
                       KeyRoute(consume: true, action: .consumer(usage: ConsumerKeyMapper.usage(for: keyF8)!)))
    }

    func testUnmappedKeyIsSwallowedInGlobalButNotSent() {
        XCTAssertNil(KeyCodeTranslator.hidUsageCode(from: unmapped))
        XCTAssertEqual(KeyEventRouter.route(Self.global, down(unmapped)), KeyRoute(consume: true, action: .none))
    }

    // MARK: - Key up

    func testKeyUpSendsPressedSet() {
        XCTAssertEqual(KeyEventRouter.route(Self.local, .keyUp(keyCode: keyA, modifiers: [])), KeyRoute(consume: false, action: .sendPressedKeys))
        XCTAssertEqual(KeyEventRouter.route(Self.global, .keyUp(keyCode: keyA, modifiers: [])), KeyRoute(consume: true, action: .sendPressedKeys))
    }

    func testKeyUpNeedsForwarding() {
        let s = with(Self.global) { $0.isForwarding = false }
        XCTAssertEqual(KeyEventRouter.route(s, .keyUp(keyCode: keyA, modifiers: [])), .pass)
    }

    // MARK: - Modifiers

    func testModifierChangeSendsPressedSet() {
        XCTAssertEqual(KeyEventRouter.route(Self.global, .modifiersChanged(keyCode: 56, modifiers: [], globeTapped: false)),
                       KeyRoute(consume: true, action: .sendPressedKeys))
    }

    func testGlobeTapSendsGlobeUsageAndHalfTapSendsNothing() {
        XCTAssertEqual(KeyEventRouter.route(Self.global, .modifiersChanged(keyCode: 63, modifiers: [], globeTapped: true)),
                       KeyRoute(consume: true, action: .globe))
        XCTAssertEqual(KeyEventRouter.route(Self.global, .modifiersChanged(keyCode: 63, modifiers: [], globeTapped: false)),
                       KeyRoute(consume: true, action: .none))
    }

    func testModifierChangeClosedGatePasses() {
        let s = with(Self.local) { $0.isConnected = false }
        XCTAssertEqual(KeyEventRouter.route(s, .modifiersChanged(keyCode: 56, modifiers: [], globeTapped: false)), .pass)
    }

    // MARK: - Invariants over every snapshot

    private static var allSnapshots: [S] {
        (0..<64).map { bits in
            S(isAppActive: bits & 1 != 0, isGlobalForwarding: bits & 2 != 0, isForwarding: bits & 4 != 0,
              isConnected: bits & 8 != 0, isRecording: bits & 16 != 0, isConsumeCapable: bits & 32 != 0,
              shortcuts: [pasteChord])
        }
    }

    private var allEvents: [KeyEventInput] {
        [down(keyA), down(keyA, repeat: true), down(keyF8), down(unmapped),
         down(9, [.maskCommand, .maskShift]), down(9, [.maskCommand, .maskShift], repeat: true),
         .keyUp(keyCode: keyA, modifiers: []), .modifiersChanged(keyCode: 56, modifiers: [], globeTapped: false),
         .modifiersChanged(keyCode: 63, modifiers: [], globeTapped: true), .modifiersChanged(keyCode: 63, modifiers: [], globeTapped: false)]
    }

    func testConsumesOnlyWhenGloballyForwardingWithAConsumingTap() {
        for s in Self.allSnapshots {
            let consuming = s.isGlobalForwarding && s.isForwarding && s.isConnected && s.isConsumeCapable
            for event in allEvents where KeyEventRouter.route(s, event).consume {
                XCTAssertTrue(consuming, "\(s) consumed \(event)")
            }
        }
    }

    func testNothingIsSentWhenDisconnectedOrInTheBackgroundOutsideGlobal() {
        for s in Self.allSnapshots where !s.isConnected || (!s.isAppActive && !s.isGlobalForwarding) {
            for event in allEvents {
                XCTAssertEqual(KeyEventRouter.route(s, event), .pass, "\(s) \(event)")
            }
        }
    }

    func testOnlyShortcutsActWhilePaused() {
        for s in Self.allSnapshots where !s.isForwarding {
            for event in allEvents {
                switch KeyEventRouter.route(s, event).action {
                case .none, .shortcut: break
                case let other: XCTFail("\(s) \(event) → \(other)")
                }
            }
        }
    }

    func testRecordingFrontmostNeverActsOrConsumes() {
        for s in Self.allSnapshots where s.isRecording && s.isAppActive {
            for event in allEvents {
                XCTAssertEqual(KeyEventRouter.route(s, event), .pass)
            }
        }
    }
}
