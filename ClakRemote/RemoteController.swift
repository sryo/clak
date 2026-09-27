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
    static let d: UInt8 = 0x07
    static let l: UInt8 = 0x0F
    static let n: UInt8 = 0x11
    static let r: UInt8 = 0x15
    static let minus: UInt8 = 0x2D
    static let equal: UInt8 = 0x2E
    static let f11: UInt8 = 0x44
}

enum MouseButton {
    static let left: UInt8 = 0x01
    static let right: UInt8 = 0x02
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
    static let launchpad: UInt16 = 0x02A0      // Keychron-proven; opens Apps on macOS 26
    /// AC Next Keyboard Layout Select, which macOS reads as the Globe key
    /// from any device that declares it (our 0x000–0x3FF range does).
    static let globe: UInt16 = 0x029D
    /// F5 on a Mac keyboard. Apple's own key is on its vendor page (0xFF01),
    /// which macOS has filtered by vendor ID since Big Sur, so a third-party
    /// keyboard can't send it. This is the standard Consumer equivalent and
    /// needs no report-map change — our consumer report already covers
    /// 0x000–0x3FF.
    static let voiceCommand: UInt16 = 0x00CF
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

    /// The two bring-up milestones `status` doesn't carry, so the connecting
    /// ring can show the app getting ready before the Mac has anything to see.
    private(set) var bluetoothOn = false
    private(set) var servicesPublished = false

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

    /// One round of waiting for a host before the app re-announces itself.
    /// A bonded Mac subscribes about a second into the first round (measured
    /// 1.1 s), so a round that runs out is the signal that something is off.
    struct RetryWindow: Equatable {
        let start: Date
        let duration: TimeInterval
        /// Republishes already done this session; 0 is the first wait.
        let attempt: Int

        /// How far through the round `date` is, 0 to 1.
        func progress(at date: Date) -> Double {
            guard duration > 0 else { return 1 }
            return min(max(date.timeIntervalSince(start) / duration, 0), 1)
        }
    }

    /// The round currently running, so the UI can show how long until the
    /// next re-announce. Nil while nothing is armed: not advertising,
    /// backgrounded, or connected.
    private(set) var retryWindow: RetryWindow?

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
    private static let firstRepublishDelay: TimeInterval = 8
    private static let maxRepublishDelay: TimeInterval = 120

    /// 8 s, then doubling to a 120 s ceiling.
    static func republishDelay(afterAttempts attempts: Int) -> TimeInterval {
        min(firstRepublishDelay * pow(2, Double(attempts)), maxRepublishDelay)
    }

    @ObservationIgnored
    private var advertisingStartedAt: Date?

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
        // Otherwise the idle clock counts the whole time spent away and a hint
        // fires a second after returning, mid-reengagement.
        noteInteraction()

        // Ask the peripheral rather than trusting `status`: a link dropped
        // while the app was suspended doesn't always arrive as an unsubscribe,
        // and a stale "connected" would skip advertising entirely — the app
        // then sits looking connected until it is force-quit.
        if !peripheral.isConnected {
            if status == .connected {
                status = .waitingForBluetooth
            }
            // Opening the app is a fresh attempt, so recovery starts prompt
            // again instead of inheriting a previous session's backoff.
            republishCount = 0
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
    /// Measured: the Mac-side helper's forced service read does not make macOS
    /// claim the keyboard — it succeeded five times running while the host
    /// still ignored us. Republishing is what works, so this leads rather than
    /// waiting for the helper, and retries quickly enough to beat a person
    /// reaching to force-quit.
    private func syncRepublishTimer() {
        republishTask?.cancel()
        republishTask = nil

        guard peripheral.isAdvertising, !isBackgrounded else {
            retryWindow = nil
            return
        }

        let delay = Self.republishDelay(afterAttempts: republishCount)
        retryWindow = RetryWindow(start: Date(), duration: delay, attempt: republishCount)
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.peripheral.isAdvertising, !self.isBackgrounded else { return }
            self.republishCount += 1
            Log.bluetooth.notice("Remote: no host after \(delay, format: .fixed(precision: 0), privacy: .public)s — republish #\(self.republishCount, privacy: .public)")
            // A host part-way through discovery or pairing would be broken by
            // the database going out from under it; give it another round.
            if self.peripheral.hasCentral {
                self.syncRepublishTimer()
            } else {
                self.peripheral.republish()
            }
        }
        republishTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func secondsSinceAdvertising() -> String {
        guard let start = advertisingStartedAt else { return "before advertising" }
        return String(format: "+%.1fs since advertising", Date().timeIntervalSince(start))
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

    /// The letter every streaming player agrees on. Not a system shortcut —
    /// ⌃⌘F would fullscreen the browser window rather than the video.
    func toggleFullscreen() {
        type(text: "f")
    }

    func pressKey(_ keyCode: UInt8) {
        enqueueKeystroke(keyCode: keyCode, modifiers: consumeStickyModifiers())
    }

    /// A fixed system shortcut, sent as is. Sticky modifiers are left for
    /// the key they were latched for.
    func sendShortcut(_ keyCode: UInt8, modifiers: UInt8) {
        enqueueKeystroke(keyCode: keyCode, modifiers: modifiers)
    }

    /// A Globe-key shortcut (Globe+N and friends): Globe is a consumer
    /// usage, so it's held across the keystroke in the other report.
    func sendGlobeShortcut(_ keyCode: UInt8) {
        noteInteraction()
        guard sendQueue.count + 4 <= maxQueuedSends else { return }
        sendQueue.append(.consumer(ConsumerUsage.globe))
        sendQueue.append(.keyboard(modifiers: 0, keyCode: keyCode))
        sendQueue.append(.keyboard(modifiers: 0, keyCode: nil))
        sendQueue.append(.consumer(0))
        drainSendQueue()
    }

    func toggleModifier(_ bit: UInt8) {
        noteInteraction()
        stickyModifiers ^= bit
    }

    func isModifierActive(_ bit: UInt8) -> Bool {
        stickyModifiers & bit != 0
    }

    private func consumeStickyModifiers() -> UInt8 {
        guard stickyModifiers != 0 else { return 0 }
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
        noteInteraction()
        guard sendQueue.count + 2 <= maxQueuedSends else { return }
        sendQueue.append(.keyboard(modifiers: modifiers, keyCode: keyCode))
        sendQueue.append(.keyboard(modifiers: 0, keyCode: nil))
        drainSendQueue()
    }

    /// A media key tap. `fine` holds Shift+Option around it, which macOS
    /// reads as a quarter step for its volume and brightness keys.
    func tapConsumer(_ usage: UInt16, fine: Bool = false) {
        noteInteraction()
        let pendingTapEntries = sendQueue.reduce(0) { count, send in
            if case .consumer = send { return count + 1 }
            return count
        }
        guard pendingTapEntries < maxQueuedConsumerTaps * 2 else { return }
        if fine {
            sendQueue.append(.keyboard(modifiers: HIDModifier.shift | HIDModifier.option, keyCode: nil))
        }
        sendQueue.append(.consumer(usage))
        sendQueue.append(.consumer(0))
        if fine {
            sendQueue.append(.keyboard(modifiers: 0, keyCode: nil))
        }
        drainSendQueue()
    }

    /// When something was last sent, in any form. Read by the hint coach to
    /// find a lull; deliberately not observable, since every keystroke would
    /// otherwise invalidate the whole view tree.
    @ObservationIgnored
    private(set) var lastInteraction = Date()

    private func noteInteraction() {
        lastInteraction = Date()
    }

    private func drainSendQueue() {
        while !sendQueue.isEmpty {
            let acceptedImmediately: Bool
            switch sendQueue.removeFirst() {
            case .keyboard(let modifiers, let keyCode):
                // A keystroke mid-drag must not let go of the drag's modifiers.
                acceptedImmediately = peripheral.sendKeyboardReport(
                    modifiers: modifiers | dragModifiers,
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

    /// Buttons currently held down, so every move made during a drag carries
    /// them. Without this the button could only ever be tapped, which is why
    /// dragging a file was impossible.
    @ObservationIgnored
    private var heldMouseButtons: UInt8 = 0
    /// Sticky modifiers a drag picked up, held until it drops, so an
    /// Option-drag copies and a Command-drag moves without switching Spaces.
    @ObservationIgnored
    private var dragModifiers: UInt8 = 0

    func mouseMove(dx: Int8, dy: Int8) {
        noteInteraction()
        peripheral.sendMouseReport(buttons: heldMouseButtons, dx: dx, dy: dy, wheel: 0)
    }

    func mouseDown(button: UInt8) {
        noteInteraction()
        if heldMouseButtons == 0 {
            dragModifiers = consumeStickyModifiers()
            if dragModifiers != 0 {
                peripheral.sendKeyboardReport(modifiers: dragModifiers, keyCodes: [])
            }
        }
        heldMouseButtons |= button
        peripheral.sendMouseReport(buttons: heldMouseButtons, dx: 0, dy: 0, wheel: 0)
    }

    func mouseUp() {
        guard heldMouseButtons != 0 else { return }
        noteInteraction()
        heldMouseButtons = 0
        peripheral.sendMouseReport(buttons: 0, dx: 0, dy: 0, wheel: 0)
        if dragModifiers != 0 {
            dragModifiers = 0
            peripheral.sendKeyRelease()
        }
    }

    func mouseScroll(wheel: Int8, pan: Int8 = 0) {
        noteInteraction()
        peripheral.sendMouseReport(buttons: heldMouseButtons, dx: 0, dy: 0, wheel: wheel, pan: pan)
    }

    /// Two clicks far enough apart that the Mac sees two presses, and close
    /// enough to count as one double-click.
    func mouseDoubleClick() {
        mouseClick(button: MouseButton.left)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.mouseClick(button: MouseButton.left)
        }
    }

    /// Clicks consume sticky modifiers and hold them across the click, so
    /// ⌘-click / Shift-click / Option-click work from the modifier row.
    func mouseClick(button: UInt8) {
        noteInteraction()
        let modifiers = consumeStickyModifiers()
        if modifiers != 0 {
            peripheral.sendKeyboardReport(modifiers: modifiers, keyCodes: [])
        }
        // Clicked on top of whatever is held, so a click mid-drag (the
        // VoiceOver action) doesn't drop it.
        peripheral.sendMouseReport(buttons: heldMouseButtons | button, dx: 0, dy: 0, wheel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, peripheral] in
            peripheral.sendMouseReport(buttons: self?.heldMouseButtons ?? 0, dx: 0, dy: 0, wheel: 0)
            if modifiers != 0 {
                peripheral.sendKeyRelease()
            }
        }
    }
}

// MARK: - BLEHIDPeripheralDelegate

extension RemoteController: BLEHIDPeripheralDelegate {
    func peripheralDidPowerOn() {
        bluetoothOn = true
        bluetoothPermissionDenied = false
        peripheral.startAdvertising()
    }

    func peripheralWillPublishServices() {
        servicesPublished = false
    }

    func peripheralDidPublishServices() {
        servicesPublished = true
    }

    func peripheralDidStartAdvertising() {
        advertisingStartedAt = Date()
        status = .advertising
        syncRepublishTimer()
    }

    func peripheralDidStopAdvertising() {
        if status != .connected {
            status = .waitingForBluetooth
        }
        syncRepublishTimer()
    }

    func peripheralDidConnect(central: CBCentral) {
        Log.bluetooth.notice("Remote: connected \(self.secondsSinceAdvertising(), privacy: .public)")
        status = .connected
        republishCount = 0
        syncRepublishTimer()
    }

    func peripheralDidDisconnect(central: CBCentral) {
        status = .waitingForBluetooth
        heldMouseButtons = 0
        sendQueue.removeAll()
        stickyModifiers = 0
        capsLockOn = false
        peripheral.startAdvertising()
        syncRepublishTimer()
    }

    func peripheralDidFail(_ failure: BLEHIDPeripheralManager.Failure) {
        if !failure.isRetryable {
            // Radio or permission gone: the peripheral has dropped its database
            bluetoothOn = false
            servicesPublished = false
        }
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
