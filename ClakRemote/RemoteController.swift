import CoreBluetooth
import Foundation
import GameController
import Observation

enum HIDKey {
    static let returnKey: UInt8 = 0x28
    static let escape: UInt8 = 0x29
    static let backspace: UInt8 = 0x2A
    static let tab: UInt8 = 0x2B
    static let space: UInt8 = 0x2C
    static let rightArrow: UInt8 = 0x4F
    static let leftArrow: UInt8 = 0x50
    static let downArrow: UInt8 = 0x51
    static let upArrow: UInt8 = 0x52
}

enum HIDModifier {
    static let control: UInt8 = 0x01
    static let shift: UInt8 = 0x02
    static let option: UInt8 = 0x04
    static let command: UInt8 = 0x08
}

enum ConsumerUsage {
    static let playPause: UInt16 = 0x00CD
    static let next: UInt16 = 0x00B5
    static let previous: UInt16 = 0x00B6
    static let volumeUp: UInt16 = 0x00E9
    static let volumeDown: UInt16 = 0x00EA
    static let mute: UInt16 = 0x00E2
    static let brightnessUp: UInt16 = 0x006F
    static let brightnessDown: UInt16 = 0x0070
    // QMK/Keychron-proven Mac mappings
    static let missionControl: UInt16 = 0x029F // AC Desktop Show All Windows
    static let spotlight: UInt16 = 0x0221      // AC Search
}

@Observable
final class RemoteController {
    enum Status: Equatable {
        case waitingForBluetooth
        case advertising
        case connected
        case error(String)

        var label: String {
            switch self {
            case .waitingForBluetooth: "Waiting for Bluetooth…"
            case .advertising: "Advertising as “Clak Remote”"
            case .connected: "Connected"
            case .error(let message): message
            }
        }
    }

    private(set) var status: Status = .waitingForBluetooth
    private(set) var capsLockOn = false

    /// iOS suppresses the on-screen keyboard while ANY Bluetooth keyboard is
    /// connected to the phone — including a Mac running Clak.
    private(set) var hardwareKeyboardAttached = GCKeyboard.coalesced != nil

    /// HID modifier bits applied to (and cleared by) the next keystroke.
    private(set) var stickyModifiers: UInt8 = 0

    @ObservationIgnored
    private let peripheral = BLEHIDPeripheralManager()

    // Keystroke FIFO: each entry is one keyboard report. nil keyCode = release.
    @ObservationIgnored
    private var keystrokeQueue: [(modifiers: UInt8, keyCode: UInt8?)] = []
    @ObservationIgnored
    private var drainTimer: Timer?

    init() {
        peripheral.localName = "Clak Remote"
        peripheral.includeHorizontalScroll = true
        peripheral.delegate = self

        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hardwareKeyboardAttached = true
        }
        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hardwareKeyboardAttached = GCKeyboard.coalesced != nil
        }
    }

    // MARK: - Keyboard

    func type(text: String) {
        for character in text {
            guard let (keyCode, modifiers) = KeyCodeTranslator.hidKeycode(for: character) else {
                continue
            }
            enqueueKeystroke(keyCode: keyCode, modifiers: modifiers | consumeStickyModifiers())
        }
    }

    func deleteBackward() {
        pressKey(HIDKey.backspace)
    }

    func pressKey(_ keyCode: UInt8) {
        enqueueKeystroke(keyCode: keyCode, modifiers: consumeStickyModifiers())
    }

    func toggleModifier(_ bit: UInt8) {
        stickyModifiers ^= bit
    }

    func isModifierActive(_ bit: UInt8) -> Bool {
        stickyModifiers & bit != 0
    }

    private func consumeStickyModifiers() -> UInt8 {
        let modifiers = stickyModifiers
        stickyModifiers = 0
        return modifiers
    }

    private func enqueueKeystroke(keyCode: UInt8, modifiers: UInt8) {
        keystrokeQueue.append((modifiers, keyCode))
        keystrokeQueue.append((0, nil))
        drainQueueIfIdle()
    }

    /// Paces keyboard reports so bursts (autocomplete words, fast typing) don't
    /// overflow the BLE notification queue. First report goes out immediately.
    private func drainQueueIfIdle() {
        guard drainTimer == nil else { return }
        sendNextKeystroke()
        guard !keystrokeQueue.isEmpty else { return }
        drainTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.AutoConnect.pasteKeystrokeDelay, repeats: true
        ) { [weak self] _ in
            self?.sendNextKeystroke()
        }
    }

    private func sendNextKeystroke() {
        guard !keystrokeQueue.isEmpty else {
            drainTimer?.invalidate()
            drainTimer = nil
            return
        }
        let (modifiers, keyCode) = keystrokeQueue.removeFirst()
        if let keyCode {
            peripheral.sendKeyboardReport(modifiers: modifiers, keyCodes: [keyCode])
        } else {
            peripheral.sendKeyboardReport(modifiers: modifiers, keyCodes: [])
        }
    }

    // MARK: - Consumer Control

    // Serialized press/release FIFO so rapid taps (drag-to-adjust volume or
    // brightness) never interleave presses without a release between them.
    @ObservationIgnored
    private var consumerQueue: [UInt16] = []
    @ObservationIgnored
    private var consumerTimer: Timer?
    private let maxQueuedConsumerTaps = 24

    func tapConsumer(_ usage: UInt16) {
        guard consumerQueue.count < maxQueuedConsumerTaps * 2 else { return }
        consumerQueue.append(usage)
        consumerQueue.append(0)
        guard consumerTimer == nil else { return }
        sendNextConsumer()
        guard !consumerQueue.isEmpty else { return }
        consumerTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            self?.sendNextConsumer()
        }
    }

    private func sendNextConsumer() {
        guard !consumerQueue.isEmpty else {
            consumerTimer?.invalidate()
            consumerTimer = nil
            return
        }
        peripheral.sendConsumerReport(usage: consumerQueue.removeFirst())
    }

    // MARK: - Mouse

    func mouseMove(dx: Int8, dy: Int8) {
        peripheral.sendMouseReport(buttons: 0, dx: dx, dy: dy, wheel: 0)
    }

    func mouseScroll(wheel: Int8, pan: Int8 = 0) {
        peripheral.sendMouseReport(buttons: 0, dx: 0, dy: 0, wheel: wheel, pan: pan)
    }

    func mouseClick(button: UInt8) {
        peripheral.sendMouseReport(buttons: button, dx: 0, dy: 0, wheel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [peripheral] in
            peripheral.sendMouseReport(buttons: 0, dx: 0, dy: 0, wheel: 0)
        }
    }
}

// MARK: - BLEHIDPeripheralDelegate

extension RemoteController: BLEHIDPeripheralDelegate {
    func peripheralDidPowerOn() {
        peripheral.startAdvertising()
    }

    func peripheralDidStartAdvertising() {
        status = .advertising
    }

    func peripheralDidStopAdvertising() {
        if status != .connected {
            status = .waitingForBluetooth
        }
    }

    func peripheralDidConnect(central: CBCentral) {
        status = .connected
    }

    func peripheralDidDisconnect(central: CBCentral) {
        status = .waitingForBluetooth
        keystrokeQueue.removeAll()
        stickyModifiers = 0
        peripheral.startAdvertising()
    }

    func peripheralDidFailWithError(_ message: String) {
        status = .error(message)
    }

    func peripheralDidReceiveLEDState(_ ledByte: UInt8) {
        capsLockOn = ledByte & 0x02 != 0
    }
}
