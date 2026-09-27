import Foundation
import CoreBluetooth

@Observable
final class BluetoothManager: NSObject, BLEHIDPeripheralDelegate {

    enum ConnectionState: Equatable {
        case poweredOff
        case advertising
        case connected(ConnectedDevice)
        case error(String)

        static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
            switch (lhs, rhs) {
            case (.poweredOff, .poweredOff): return true
            case (.advertising, .advertising): return true
            case (.connected(let a), .connected(let b)): return a.id == b.id
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    private(set) var connectionState: ConnectionState = .poweredOff {
        didSet {
            if case .error = connectionState {} else { lastFailure = nil }
            notifyStateChange()
        }
    }
    private(set) var connectedDevices: [ConnectedDevice] = []
    private(set) var capsLockActive: Bool = false
    /// The failure behind the current .error state, if any.
    private(set) var lastFailure: BLEHIDPeripheralManager.Failure?
    /// A host is mid-pairing: the Mac shows the Numeric Comparison dialog.
    private(set) var isAwaitingPairingConfirmation = false {
        didSet {
            if oldValue != isAwaitingPairingConfirmation {
                onPairingStateChange?(isAwaitingPairingConfirmation)
            }
        }
    }

    /// Called on every connectionState change. AppDelegate wires this to update AppState + MenuBar.
    var onStateChange: ((ConnectionState) -> Void)?
    /// Called when LED state (e.g. Caps Lock) changes from the connected device.
    var onLEDStateChange: ((Bool) -> Void)?
    /// Called when isAwaitingPairingConfirmation changes.
    var onPairingStateChange: ((Bool) -> Void)?

    private let blePeripheral: HIDPeripheralLink
    private let scheduler: DelayScheduler
    private let keystrokeResolver: (String) -> [CharacterComposer.Keystroke]
    private let deviceManager = DeviceConnectionManager()
    // Serial queue so overlapping paste/AppleScript sends don't interleave keystrokes
    private let textSendQueue = DispatchQueue(label: "com.clak.app.textsend", qos: .userInitiated)

    private func notifyStateChange() {
        onStateChange?(connectionState)
    }

    /// Transient failures retry on this curve; a connect resets it.
    private var retryBackoff = RetryBackoff()
    private var retryWorkItem: DispatchWorkItem?
    private var readvertiseWorkItem: DispatchWorkItem?
    private var wakeWindowWorkItem: DispatchWorkItem?

    /// How long to advertise after wake while a pre-sleep link still looks
    /// alive: long enough for a host that really dropped to reconnect.
    static let wakeAdvertisingWindow: TimeInterval = 30

    /// A bonded host reads before it subscribes (measured ~1.1 s); only a
    /// central still unsubscribed after this is treated as pairing.
    static let pairingPromptGrace: TimeInterval = 1.5
    /// SMP gives up after about 30 s without confirmation.
    static let pairingConfirmationTimeout: TimeInterval = 30
    private var pairingWorkItems: [DispatchWorkItem] = []

    /// What the connection state says about the radio, or nil when it says
    /// nothing new: the launch state and transient failures keep the last
    /// known availability, so "Bluetooth is off" never flashes at launch.
    static func availability(for state: ConnectionState,
                             failure: BLEHIDPeripheralManager.Failure?) -> BluetoothAvailability? {
        switch state {
        case .advertising, .connected:
            return .on
        case .poweredOff:
            return nil
        case .error:
            switch failure {
            case .poweredOff: return .off
            case .unauthorized: return .unauthorized
            case .unsupported: return .unsupported
            default: return nil
            }
        }
    }

    init(link: HIDPeripheralLink? = nil,
         scheduler: DelayScheduler = .main,
         keystrokeResolver: ((String) -> [CharacterComposer.Keystroke])? = nil) {
        self.blePeripheral = link ?? BLEHIDPeripheralManager(batteryLevelSource: MacBatteryMonitor(),
                                                             requestsLowLatency: true)
        self.scheduler = scheduler
        self.keystrokeResolver = keystrokeResolver ?? { KeyboardLayoutMapper.shared.keystrokes(for: $0) }
        super.init()
        blePeripheral.delegate = self
    }

    // MARK: - Advertising

    func startAdvertising() {
        blePeripheral.startAdvertising()
        Log.bluetooth.info("BLE HID keyboard advertising requested")
    }

    /// Full teardown — only for app termination.
    func teardownCompletely() {
        blePeripheral.teardownCompletely()
        deviceManager.removeAllDevices()
        connectedDevices = []
        Log.bluetooth.info("BLE torn down completely")
    }

    /// Menu "Reconnect". A BLE peripheral cannot force-disconnect a central,
    /// so devices that are still subscribed stay connected and stay listed —
    /// clearing them here would freeze the UI on "Searching…" while the phone
    /// still shows a live keyboard. With a central present, only discovery is
    /// restarted. With none, the GATT database is rebuilt as well: a host
    /// whose cached copy of our services is stale ignores a plain re-advertise.
    func disconnectAndReAdvertise() {
        readvertiseWorkItem?.cancel()
        readvertiseWorkItem = nil

        guard blePeripheral.hasCentral else {
            Log.bluetooth.info("Reconnect: no central — republishing")
            blePeripheral.republish()
            return
        }

        blePeripheral.stopAdvertisingOnly()
        Log.bluetooth.info("Cycling advertising")
        let resume = DispatchWorkItem { [weak self] in
            self?.readvertiseWorkItem = nil
            self?.blePeripheral.startAdvertising()
        }
        readvertiseWorkItem = resume
        scheduler.schedule(0.5, resume)
    }

    /// After sleep: whatever was held is released by the caller; here the
    /// link is checked. A link that died in sleep often sends no unsubscribe,
    /// so even one that still looks alive advertises for a bounded window.
    func handleWake() {
        guard blePeripheral.isConnected else {
            Log.bluetooth.info("Wake: not connected — advertising")
            startAdvertising()
            return
        }

        Log.bluetooth.info("Wake: link claims connected — advertising for \(Self.wakeAdvertisingWindow, privacy: .public)s")
        wakeWindowWorkItem?.cancel()
        blePeripheral.startAdvertising()
        let close = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wakeWindowWorkItem = nil
            // Still connected: the old link was real, stop inviting others.
            // Otherwise the disconnect path owns advertising.
            if self.blePeripheral.isConnected {
                self.blePeripheral.stopAdvertisingOnly()
            }
        }
        wakeWindowWorkItem = close
        scheduler.schedule(Self.wakeAdvertisingWindow, close)
    }

    // MARK: - Send HID Reports

    /// Send a keyboard report carrying the full current state (modifiers + all pressed keys).
    func sendKeyboardReport(modifiers: UInt8, keyCodes: [UInt8]) {
        blePeripheral.sendKeyboardReport(modifiers: modifiers, keyCodes: keyCodes)
    }

    /// Release everything — modifiers and keys.
    func sendKeyUp() {
        blePeripheral.sendKeyRelease()
    }

    private var consumerReleaseWorkItem: DispatchWorkItem?

    /// Press-and-release a consumer (media) key. A rapid second press cancels the
    /// first press's pending release so it can't cut the new key short.
    func sendConsumerKey(usage: UInt16) {
        consumerReleaseWorkItem?.cancel()
        blePeripheral.sendConsumerReport(usage: usage)

        let release = DispatchWorkItem { [weak self] in
            self?.blePeripheral.sendConsumerReport(usage: 0x0000)
        }
        consumerReleaseWorkItem = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: release)
    }

    /// Send a mouse report (relative deltas, button bitmask, wheel).
    func sendMouse(buttons: UInt8 = 0, dx: Int8 = 0, dy: Int8 = 0, wheel: Int8 = 0) {
        blePeripheral.sendMouseReport(buttons: buttons, dx: dx, dy: dy, wheel: wheel, pan: 0)
    }

    /// Call on the main thread: the layout map is resolved here, before the
    /// paced sends move to the text queue.
    func sendText(_ text: String) {
        let delay = Constants.AutoConnect.pasteKeystrokeDelay
        let strokes = keystrokeResolver(text)

        textSendQueue.async { [weak self] in
            guard let self else {
                return
            }

            for mapping in strokes {
                // BLE state (peripheral + pending FIFO) lives on the main queue;
                // only the inter-keystroke sleeps stay on this background queue
                self.sendPaced { $0.sendKeyboardReport(modifiers: mapping.modifiers, keyCodes: [mapping.keyCode]) }
                Thread.sleep(forTimeInterval: delay / 2)
                self.sendPaced { $0.sendKeyRelease() }
                Thread.sleep(forTimeInterval: delay)
            }
        }
    }

    // Signalled from peripheralIsReadyToSend while a paste waits for room
    private let notifyQueueRoom = DispatchSemaphore(value: 0)
    private var pasteWaitingForRoom = false

    /// Sends from the text queue, then waits while the report sits in the
    /// pending FIFO, so a long paste never outruns the radio and overflows it.
    /// The timeout keeps a stalled link from hanging the paste forever.
    private func sendPaced(_ send: @escaping (HIDPeripheralLink) -> Bool) {
        let mustWait = DispatchQueue.main.sync {
            let sent = send(self.blePeripheral)
            self.pasteWaitingForRoom = !sent && self.blePeripheral.isConnected
            return self.pasteWaitingForRoom
        }
        if mustWait {
            _ = notifyQueueRoom.wait(timeout: .now() + 1)
        }
    }

    // MARK: - BLEHIDPeripheralDelegate

    func peripheralDidPowerOn() {
        Log.bluetooth.info("BLE powered on — auto-starting advertising")
        startAdvertising()
    }

    func peripheralDidStartAdvertising() {
        // The live link decides: a remembered device can outlive a radio
        // reset that dropped it without an unsubscribe
        if blePeripheral.isConnected, let primary = deviceManager.primaryDevice {
            connectionState = .connected(primary)
            Log.bluetooth.info("BLE HID keyboard advertising (already connected)")
        } else {
            clearDevices()
            connectionState = .advertising
            Log.bluetooth.info("BLE HID keyboard now advertising as 'Clak'")
        }
    }

    func peripheralDidStopAdvertising() {
        // Only reset to poweredOff if we truly tore down
        if !blePeripheral.areServicesPublished {
            connectionState = .poweredOff
        }
    }

    func peripheralDidSeePendingCentral(_ central: HIDCentral) {
        endPairingWait()
        let show = DispatchWorkItem { [weak self] in
            self?.isAwaitingPairingConfirmation = true
        }
        let expire = DispatchWorkItem { [weak self] in
            self?.isAwaitingPairingConfirmation = false
        }
        pairingWorkItems = [show, expire]
        scheduler.schedule(Self.pairingPromptGrace, show)
        scheduler.schedule(Self.pairingPromptGrace + Self.pairingConfirmationTimeout, expire)
    }

    private func endPairingWait() {
        pairingWorkItems.forEach { $0.cancel() }
        pairingWorkItems = []
        isAwaitingPairingConfirmation = false
    }

    func peripheralDidConnect(central: HIDCentral) {
        endPairingWait()
        cancelRetry()
        retryBackoff.reset()
        wakeWindowWorkItem?.cancel()
        wakeWindowWorkItem = nil

        let connected = deviceManager.addConnectedDevice(ConnectedDevice(central: central))
        connectedDevices = deviceManager.allDevices
        connectionState = .connected(connected)
        Log.bluetooth.info("BLE device connected: \(central.id.uuidString)")
    }

    func peripheralDidDisconnect(central: HIDCentral) {
        endPairingWait()
        deviceManager.removeDevice(id: central.id.uuidString)
        connectedDevices = deviceManager.allDevices

        if blePeripheral.isConnected, let primary = deviceManager.primaryDevice {
            connectionState = .connected(primary)
        } else {
            clearDevices()
            // Auto-reconnect: immediately resume advertising
            connectionState = .advertising
            Log.bluetooth.info("BLE device disconnected, resuming advertising")
            blePeripheral.startAdvertising()
        }
    }

    func peripheralDidFail(_ failure: BLEHIDPeripheralManager.Failure) {
        Log.bluetooth.error("BLE error: \(failure.message)")

        // Power-off and permission failures need user/system action, not a retry
        guard failure.isRetryable else {
            cancelRetry()
            endPairingWait()
            clearDevices()
            lastFailure = failure
            connectionState = .error(failure.message)
            return
        }

        // A failed re-advertise doesn't break a link that is carrying input
        if blePeripheral.isConnected {
            Log.bluetooth.info("BLE: \(failure.message) — link still live, not retrying")
            return
        }

        lastFailure = failure
        connectionState = .error(failure.message)
        scheduleRetry()
    }

    /// One pending retry at a time; each unanswered failure waits longer.
    private func scheduleRetry() {
        cancelRetry()
        let delay = retryBackoff.nextDelay()
        let retry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItem = nil
            guard !self.blePeripheral.isConnected else { return }
            Log.bluetooth.info("BLE: Auto-recovery — retrying advertising")
            self.startAdvertising()
        }
        retryWorkItem = retry
        Log.bluetooth.info("BLE: Retrying in \(delay, privacy: .public)s")
        scheduler.schedule(delay, retry)
    }

    private func cancelRetry() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
    }

    /// Nothing is connected: forget every device and the last host's LEDs.
    private func clearDevices() {
        deviceManager.removeAllDevices()
        if !connectedDevices.isEmpty {
            connectedDevices = []
        }
        if capsLockActive {
            capsLockActive = false
            onLEDStateChange?(false)
        }
    }

    func peripheralDidReceiveLEDState(_ ledByte: UInt8) {
        let newCapsLock = ledByte & 0x02 != 0
        if capsLockActive != newCapsLock {
            capsLockActive = newCapsLock
            onLEDStateChange?(capsLockActive)
        }
    }

    func peripheralIsReadyToSend() {
        if pasteWaitingForRoom {
            pasteWaitingForRoom = false
            notifyQueueRoom.signal()
        }
    }
}
