import XCTest
import Carbon.HIToolbox
@testable import Clak

final class MenuModelTests: XCTestCase {

    private let cmdShift = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
    private let ctrlOpt = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue

    private var defaultBindings: [ShortcutBinding] {
        [
            ShortcutBinding(keyCode: UInt16(kVK_ANSI_K), modifiers: cmdShift, action: .toggleForwarding),
            ShortcutBinding(keyCode: UInt16(kVK_ANSI_G), modifiers: cmdShift, action: .toggleGlobalForwarding),
            ShortcutBinding(keyCode: UInt16(kVK_ANSI_D), modifiers: cmdShift, action: .disconnectDevice),
        ]
    }

    private var connectedInput: HUDInput {
        var input = HUDInput()
        input.isConnected = true
        input.deviceName = "iPad"
        return input
    }

    private func item(_ command: MenuItemSpec.Command, in items: [MenuItemSpec]) -> MenuItemSpec? {
        items.first { $0.command == command }
    }

    func testEquivalentsComeFromDefaultBindings() {
        let items = MenuModel.items(connectedInput, bindings: defaultBindings)

        let pause = item(.toggleForwarding, in: items)
        XCTAssertEqual(pause?.title, "Pause Forwarding")
        XCTAssertEqual(pause?.keyEquivalent, "k")
        XCTAssertEqual(pause?.modifiers, [.command, .shift])

        XCTAssertEqual(item(.toggleGlobalForwarding, in: items)?.keyEquivalent, "g")
        XCTAssertEqual(item(.reconnect, in: items)?.keyEquivalent, "d")
    }

    func testReboundChordChangesEquivalent() {
        let rebound = [ShortcutBinding(keyCode: UInt16(kVK_ANSI_P), modifiers: ctrlOpt, action: .toggleForwarding)]
        let pause = item(.toggleForwarding, in: MenuModel.items(connectedInput, bindings: rebound))
        XCTAssertEqual(pause?.keyEquivalent, "p")
        XCTAssertEqual(pause?.modifiers, [.control, .option])
    }

    func testUnboundActionHasNoEquivalent() {
        let items = MenuModel.items(connectedInput, bindings: [])
        XCTAssertEqual(item(.reconnect, in: items)?.keyEquivalent, "")
        XCTAssertEqual(item(.reconnect, in: items)?.modifiers, [])
    }

    func testFunctionKeyEquivalent() {
        let f5 = [ShortcutBinding(keyCode: UInt16(kVK_F5), modifiers: CGEventFlags.maskCommand.rawValue, action: .toggleForwarding)]
        let pause = item(.toggleForwarding, in: MenuModel.items(connectedInput, bindings: f5))
        XCTAssertEqual(pause?.keyEquivalent, String(UnicodeScalar(NSF5FunctionKey)!))
    }

    func testPauseAndGlobalStayVisibleButDisabledWhenDisconnected() {
        let items = MenuModel.items(HUDInput(), bindings: defaultBindings)
        let pause = item(.toggleForwarding, in: items)
        let global = item(.toggleGlobalForwarding, in: items)
        XCTAssertNotNil(pause)
        XCTAssertNotNil(global)
        XCTAssertEqual(pause?.isEnabled, false)
        XCTAssertEqual(global?.isEnabled, false)
        XCTAssertEqual(item(.reconnect, in: items)?.isEnabled, true)
    }

    func testPausedAndGlobalStates() {
        var input = connectedInput
        input.isForwarding = false
        input.isGlobalForwarding = true
        let items = MenuModel.items(input, bindings: defaultBindings)
        XCTAssertEqual(item(.toggleForwarding, in: items)?.title, "Resume Forwarding")
        XCTAssertEqual(item(.toggleGlobalForwarding, in: items)?.isChecked, true)
        XCTAssertEqual(item(.toggleForwarding, in: items)?.isEnabled, true)
    }

    func testStatusLineLeadsTheMenu() {
        let items = MenuModel.items(connectedInput, bindings: defaultBindings)
        XCTAssertEqual(items.first?.command, MenuItemSpec.Command.none)
        XCTAssertEqual(items.first?.title, "Connected to iPad")
        XCTAssertEqual(items.first?.isEnabled, false)
    }

    func testBlockedStepOffersItsSettings() {
        var input = HUDInput()
        input.needsInputMonitoring = true
        let items = MenuModel.items(input, bindings: defaultBindings)
        let open = item(.openSystemSettings(.inputMonitoring), in: items)
        XCTAssertEqual(open?.title, "Open Input Monitoring Settings\u{2026}")
        XCTAssertNil(item(.openSystemSettings(.inputMonitoring), in: MenuModel.items(connectedInput, bindings: defaultBindings)))
    }

    func testReconnectDisabledWithoutBluetooth() {
        var input = HUDInput()
        input.bluetooth = .off
        XCTAssertEqual(item(.reconnect, in: MenuModel.items(input, bindings: defaultBindings))?.isEnabled, false)
    }

    func testFixedItems() {
        let items = MenuModel.items(connectedInput, bindings: defaultBindings)
        XCTAssertEqual(item(.showWindow, in: items)?.title, "Show Clak")
        XCTAssertEqual(item(.showSettings, in: items)?.keyEquivalent, ",")
        XCTAssertEqual(item(.quit, in: items)?.keyEquivalent, "q")
        XCTAssertEqual(items.last?.command, .quit)
    }
}
