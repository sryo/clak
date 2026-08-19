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

    /// Set when the failure is Bluetooth permission — the UI offers a jump to Settings.
    private(set) var bluetoothPermissionDenied = false

    /// While backgrounded/locked, iOS strips the local name from our
    /// advertisement and moves the service UUID to the overflow area — the
    /// Mac's Bluetooth list can't see "Clak Remote" until we're foregrounded.
    private(set) var isBackgrounded = false

    /// Characters recently dropped because they can't be produced over HID
    /// (no US-layout Option composition). Cleared automatically; UI shows a note.
    private(set) var droppedCharacterCount = 0

    /// iOS suppresses the on-screen keyboard while ANY Bluetooth keyboard is
    /// connected to the phone — including a Mac running Clak.
    private(set) var hardwareKeyboardAttached = GCKeyboard.coalesced != nil

    /// HID modifier bits applied to (and cleared by) the next keystroke or click.
    private(set) var stickyModifiers: UInt8 = 0

    @ObservationIgnored
    private let peripheral = BLEHIDPeripheralManager(
        localName: "Clak Remote",
        includeHorizontalScroll: true,
        restoreIdentifier: "com.clak.remote.peripheral",
        publishesGenericAttributeService: false
    )

    /// One FIFO for every send with delivery-order semantics (keystrokes and
    /// consumer taps). Drained by BLE backpressure, not by timers: each send
    /// reports whether the notification queue accepted it immediately, and
    /// peripheralIsReadyToSend() resumes the drain after a bounce.
    private enum PendingSend {
        case keyboard(modifiers: UInt8, keyCode: UInt8?)
        case consumer(UInt16)
    }

    @ObservationIgnored
    private var sendQueue: [PendingSend] = []
    private let maxQueuedSends = 512
    private let maxQueuedConsumerTaps = 24

    @ObservationIgnored
    private var republishTask: DispatchWorkItem?
    /// Each unanswered round waits longer, so a phone left advertising near a
    /// Mac nobody is connecting to settles down instead of cycling forever.
    @ObservationIgnored
    private var republishCount = 0
    private let firstRepublishDelay: TimeInterval = 25
    private let maxRepublishDelay: TimeInterval = 600

    @ObservationIgnored
    private var droppedNoteClearTask: DispatchWorkItem?
    @ObservationIgnored
    private var keyboardObservers: [NSObjectProtocol] = []

    init() {
        peripheral.delegate = self

        keyboardObservers = [
            NotificationCenter.default.addObserver(
                forName: .GCKeyboardDidConnect, object: nil, queue: .main
            ) { [weak self] _ in
                self?.hardwareKeyboardAttached = true
            },
            NotificationCenter.default.addObserver(
                forName: .GCKeyboardDidDisconnect, object: nil, queue: .main
            ) { [weak self] _ in
                self?.hardwareKeyboardAttached = GCKeyboard.coalesced != nil
            },
        ]
    }

    deinit {
        keyboardObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Scene lifecycle

    func sceneDidBecomeActive() {
        isBackgrounded = false
        // Recover whatever discoverability iOS degraded while backgrounded
        if status != .connected {
            peripheral.startAdvertising()
        }
        syncRepublishTimer()
    }

    func sceneDidEnterBackground() {
        isBackgrounded = true
        syncRepublishTimer()
    }

    // MARK: - Stale-host recovery

    /// A Mac whose cached copy of this iPhone's services predates Clak Remote
    /// ignores the advertisement indefinitely — it answers from that cache
    /// instead of re-reading us. Republishing is what makes it look again,
    /// which is why closing and reopening the app fixes it by hand.
    ///
    /// Driven by the current state rather than by any one transition, so every
    /// route into advertising re-arms it and no caller has to remember to.
    /// Backgrounded advertising is degraded anyway (iOS strips the local name),
    /// so being ignored there says nothing about a stale cache.
    ///
    /// The Mac-side helper in `clak-remote-bootstrap.sh` watches for the same
    /// condition on a shorter fuse; keep this the slower of the two so its
    /// cheaper remedy gets first refusal.
    private func syncRepublishTimer() {
        republishTask?.cancel()
        republishTask = nil

        guard peripheral.isAdvertising, !isBackgrounded else { return }

        let delay = min(firstRepublishDelay * pow(2, Double(republishCount)), maxRepublishDelay)
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.peripheral.isAdvertising, !self.isBackgrounded else { return }
            self.republishCount += 1
            self.peripheral.republish()
        }
        republishTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    // MARK: - Keyboard

    func type(text: String) {
        noteEcho(text)
        var dropped = 0
        for character in text {
            guard let keystrokes = CharacterComposer.keystrokes(for: character) else {
                dropped += 1
                continue
            }
            let sticky = consumeStickyModifiers()
            for (index, stroke) in keystrokes.enumerated() {
                // Sticky modifiers ride the final stroke (the base character);
                // dead-key prefixes keep their own Option chord
                let extra = index == keystrokes.count - 1 ? sticky : 0
                enqueueKeystroke(keyCode: stroke.keyCode, modifiers: stroke.modifiers | extra)
            }
        }
        if dropped > 0 {
            registerDroppedCharacters(dropped)
        }
    }

    func deleteBackward() {
        pressKey(HIDKey.backspace)
    }

    /// Seek by one player step. Deliberately arrow keys rather than a consumer
    /// usage: every player binds these, and none agree on how many seconds a
    /// step is worth — which is why nothing in the UI claims seconds.
    func seek(_ direction: Int) {
        pressKey(direction > 0 ? HIDKey.rightArrow : HIDKey.leftArrow)
    }

    func toggleFullscreen() {
        type(text: "f")
    }

    func toggleCaptions() {
        type(text: "c")
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

    // MARK: - Echo

    /// The tail of what has been sent, so the on-screen keyboard can be used
    /// without watching the Mac. Only ever read while typing.
    private(set) var echo = ""

    @ObservationIgnored
    private var echoClearTask: DispatchWorkItem?
    private let maxEcho = 64

    private func noteEcho(_ text: String) {
        echo = String((echo + text).suffix(maxEcho))
        echoClearTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.echo = ""
        }
        echoClearTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: task)
    }

    func clearEcho() {
        echoClearTask?.cancel()
        echo = ""
    }

    private func registerDroppedCharacters(_ count: Int) {
        droppedCharacterCount += count
        droppedNoteClearTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.droppedCharacterCount = 0
        }
        droppedNoteClearTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: task)
    }

    // MARK: - Send queue

    private func enqueueKeystroke(keyCode: UInt8, modifiers: UInt8) {
        guard sendQueue.count + 2 <= maxQueuedSends else { return }
        sendQueue.append(.keyboard(modifiers: modifiers, keyCode: keyCode))
        sendQueue.append(.keyboard(modifiers: 0, keyCode: nil))
        drainSendQueue()
    }

    func tapConsumer(_ usage: UInt16) {
        let pendingTapEntries = sendQueue.reduce(0) { count, send in
            if case .consumer = send { return count + 1 }
            return count
        }
        guard pendingTapEntries < maxQueuedConsumerTaps * 2 else { return }
        sendQueue.append(.consumer(usage))
        sendQueue.append(.consumer(0))
        drainSendQueue()
    }

    private func drainSendQueue() {
        while !sendQueue.isEmpty {
            let acceptedImmediately: Bool
            switch sendQueue.removeFirst() {
            case .keyboard(let modifiers, let keyCode):
                acceptedImmediately = peripheral.sendKeyboardReport(
                    modifiers: modifiers,
                    keyCodes: keyCode.map { [$0] } ?? []
                )
            case .consumer(let usage):
                acceptedImmediately = peripheral.sendConsumerReport(usage: usage)
            }
            // false = the BLE layer queued it behind a full notification queue
            // (order preserved); stop pushing until peripheralIsReadyToSend()
            if !acceptedImmediately {
                break
            }
        }
    }

    // MARK: - Mouse

    func mouseMove(dx: Int8, dy: Int8) {
        peripheral.sendMouseReport(buttons: 0, dx: dx, dy: dy, wheel: 0)
    }

    func mouseScroll(wheel: Int8, pan: Int8 = 0) {
        peripheral.sendMouseReport(buttons: 0, dx: 0, dy: 0, wheel: wheel, pan: pan)
    }

    /// Clicks consume sticky modifiers and hold them across the click, so
    /// ⌘-click / Shift-click / Option-click work from the modifier row.
    func mouseClick(button: UInt8) {
        let modifiers = consumeStickyModifiers()
        if modifiers != 0 {
            peripheral.sendKeyboardReport(modifiers: modifiers, keyCodes: [])
        }
        peripheral.sendMouseReport(buttons: button, dx: 0, dy: 0, wheel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [peripheral] in
            peripheral.sendMouseReport(buttons: 0, dx: 0, dy: 0, wheel: 0)
            if modifiers != 0 {
                peripheral.sendKeyRelease()
            }
        }
    }
}

// MARK: - BLEHIDPeripheralDelegate

extension RemoteController: BLEHIDPeripheralDelegate {
    func peripheralDidPowerOn() {
        bluetoothPermissionDenied = false
        peripheral.startAdvertising()
    }

    func peripheralDidStartAdvertising() {
        status = .advertising
        syncRepublishTimer()
    }

    func peripheralDidStopAdvertising() {
        if status != .connected {
            status = .waitingForBluetooth
        }
    }

    func peripheralDidConnect(central: CBCentral) {
        status = .connected
        republishCount = 0
        syncRepublishTimer()
    }

    func peripheralDidDisconnect(central: CBCentral) {
        status = .waitingForBluetooth
        sendQueue.removeAll()
        stickyModifiers = 0
        capsLockOn = false
        peripheral.startAdvertising()
    }

    func peripheralDidFail(_ failure: BLEHIDPeripheralManager.Failure) {
        status = .error(failure.message)
        bluetoothPermissionDenied = failure == .unauthorized
    }

    func peripheralDidReceiveLEDState(_ ledByte: UInt8) {
        capsLockOn = ledByte & 0x02 != 0
    }

    func peripheralIsReadyToSend() {
        drainSendQueue()
    }
}
