import XCTest
import Carbon.HIToolbox
@testable import Clak

final class HUDPresentationTests: XCTestCase {

    private let cmdShift = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
    private let ctrlOpt = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue

    private var defaultBindings: [ShortcutBinding] {
        [
            ShortcutBinding(keyCode: UInt16(kVK_ANSI_K), modifiers: cmdShift, action: .toggleForwarding),
            ShortcutBinding(keyCode: UInt16(kVK_ANSI_G), modifiers: cmdShift, action: .toggleGlobalForwarding),
            ShortcutBinding(keyCode: UInt16(kVK_ANSI_D), modifiers: cmdShift, action: .disconnectDevice),
        ]
    }

    private func make(_ bindings: [ShortcutBinding]? = nil, _ configure: (inout HUDInput) -> Void) -> HUDPresentation {
        var input = HUDInput()
        configure(&input)
        return HUDPresentation.make(input, bindings: bindings ?? defaultBindings)
    }

    private func connected(_ input: inout HUDInput) {
        input.isConnected = true
        input.deviceName = "iPhone"
    }

    // MARK: - Table

    func testHeadlineToneAndPulseTable() {
        let cases: [(String, (inout HUDInput) -> Void, String, String?, HUDPresentation.Tone, Bool)] = [
            ("typing", { self.connected(&$0) },
             "Type to iPhone\u{2026}", nil, .ready, false),
            ("unnamed device", { $0.isConnected = true },
             "Type to your device\u{2026}", nil, .ready, false),
            ("global", { self.connected(&$0); $0.isGlobalForwarding = true },
             "Type to iPhone\u{2026}", "From any app.", .global, false),
            ("paused", { self.connected(&$0); $0.isForwarding = false },
             "Paused", "Your keys stay on this Mac.", .paused, false),
            ("paused wins over global", { self.connected(&$0); $0.isForwarding = false; $0.isGlobalForwarding = true },
             "Paused", "Your keys stay on this Mac.", .paused, false),
            ("waiting", { _ in },
             "Waiting to connect", "Choose Clak in your device\u{2019}s Bluetooth settings.", .waiting, true),
            ("pairing", { $0.isAwaitingPairingConfirmation = true },
             "Confirm the code on your Mac", "It should match the one on your device.", .waiting, true),
            ("bluetooth off", { $0.bluetooth = .off },
             "Bluetooth is off", "Turn it on to connect.", .attention, false),
            ("bluetooth denied", { $0.bluetooth = .unauthorized },
             "Bluetooth access is off", "Clak needs Bluetooth to connect.", .attention, false),
            ("input monitoring", { $0.needsInputMonitoring = true },
             "Allow Input Monitoring", "Clak needs it to read your keys.", .attention, false),
            ("accessibility", { self.connected(&$0); $0.needsAccessibility = true },
             "Type to iPhone\u{2026}", "Allow Accessibility to type from any app.", .attention, false),
            ("error", { $0.errorMessage = "BLE advertising failed: x" },
             "Can\u{2019}t connect right now", "Press \u{21E7}\u{2318}D to try again.", .error, false),
        ]

        for (name, configure, headline, line, tone, pulsing) in cases {
            let p = make(nil, configure)
            XCTAssertEqual(p.headline, headline, name)
            XCTAssertEqual(p.line, line, name)
            XCTAssertEqual(p.tone, tone, name)
            XCTAssertEqual(p.isPulsing, pulsing, name)
        }
    }

    // MARK: - Hints come from the real binding

    func testGlobalShowsEscapeHintFromDefaultBinding() {
        let p = make { connected(&$0); $0.isGlobalForwarding = true }
        XCTAssertEqual(p.hint, HUDPresentation.Hint(keys: "\u{21E7}\u{2318}G", text: "to stop"))
        XCTAssertTrue(p.staysOpaqueWhenInactive)
    }

    func testGlobalHintFollowsReboundChord() {
        let rebound = [ShortcutBinding(keyCode: UInt16(kVK_ANSI_E), modifiers: ctrlOpt, action: .toggleGlobalForwarding)]
        let p = make(rebound) { connected(&$0); $0.isGlobalForwarding = true }
        XCTAssertEqual(p.hint?.keys, "\u{2303}\u{2325}E")
    }

    func testGlobalWithoutBindingPointsAtMenuBar() {
        let p = make([]) { connected(&$0); $0.isGlobalForwarding = true }
        XCTAssertEqual(p.hint, HUDPresentation.Hint(keys: nil, text: "Stop it from the menu bar"))
    }

    func testPausedShowsResumeHint() {
        let p = make { connected(&$0); $0.isForwarding = false }
        XCTAssertEqual(p.hint, HUDPresentation.Hint(keys: "\u{21E7}\u{2318}K", text: "to resume"))
        XCTAssertFalse(p.showsEcho)
        XCTAssertFalse(p.staysOpaqueWhenInactive)
    }

    func testPlainTypingHasNoHint() {
        let p = make { connected(&$0) }
        XCTAssertNil(p.hint)
        XCTAssertTrue(p.showsEcho)
        XCTAssertFalse(p.staysOpaqueWhenInactive)
    }

    func testErrorWithoutReconnectBinding() {
        let p = make([]) { $0.errorMessage = "boom" }
        XCTAssertEqual(p.line, "Reconnect from the menu bar.")
        XCTAssertEqual(p.detail, "boom")
    }

    func testBluetoothStepBeatsItsOwnErrorMessage() {
        let p = make { $0.bluetooth = .off; $0.errorMessage = "Bluetooth is powered off" }
        XCTAssertEqual(p.headline, "Bluetooth is off")
        XCTAssertEqual(p.settings, .bluetooth)
    }

    // MARK: - Status and accessibility

    func testStatusAndAccessibilityLabel() {
        XCTAssertEqual(make { connected(&$0) }.status, "Connected to iPhone")
        XCTAssertEqual(make { connected(&$0); $0.isForwarding = false }.status, "Paused")
        XCTAssertEqual(make { connected(&$0); $0.isGlobalForwarding = true }.status, "Typing to iPhone from any app")
        XCTAssertEqual(make { _ in }.status, "Waiting to connect")

        let caps = make { connected(&$0); $0.capsLockActive = true }
        XCTAssertEqual(caps.accessibilityLabel, "Connected to iPhone. Caps Lock is on.")
        XCTAssertEqual(make { connected(&$0) }.accessibilityLabel, "Connected to iPhone.")
    }

    func testShowsEchoOnlyWhileKeysFlow() {
        XCTAssertTrue(make { connected(&$0); $0.isGlobalForwarding = true }.showsEcho)
        XCTAssertFalse(make { _ in }.showsEcho)
        XCTAssertFalse(make { connected(&$0); $0.needsInputMonitoring = true }.showsEcho)
    }
}
