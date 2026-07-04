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
        didSet { notifyStateChange() }
    }
    private(set) var connectedDevices: [ConnectedDevice] = []
    private(set) var capsLockActive: Bool = false

    /// Called on every connectionState change. AppDelegate wires this to update AppState + MenuBar.
    var onStateChange: ((ConnectionState) -> Void)?
    /// Called when LED state (e.g. Caps Lock) changes from the connected device.
    var onLEDStateChange: ((Bool) -> Void)?

    private let blePeripheral = BLEHIDPeripheralManager()
    private let deviceManager = DeviceConnectionManager()
    // Serial queue so overlapping paste/AppleScript sends don't interleave keystrokes
    private let textSendQueue = DispatchQueue(label: "com.clak.app.textsend", qos: .userInitiated)

    private func notifyStateChange() {
        onStateChange?(connectionState)
    }

    override init() {
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

    /// Cycle advertising. A BLE peripheral cannot force-disconnect a central,
    /// so devices that are still subscribed stay connected and stay listed —
    /// clearing them here would freeze the UI on "Searching…" while the phone
    /// still shows a live keyboard. This only restarts discovery for new hosts.
    func disconnectAndReAdvertise() {
        blePeripheral.stopAdvertisingOnly()
        Log.bluetooth.info("Cycling advertising")

        // Brief pause then resume
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.blePeripheral.startAdvertising()
        }
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
        blePeripheral.sendMouseReport(buttons: buttons, dx: dx, dy: dy, wheel: wheel)
    }

    func sendText(_ text: String) {
        let delay = Constants.AutoConnect.pasteKeystrokeDelay

        textSendQueue.async { [weak self] in
            guard let self else {
                return
            }

            for character in text {
                guard let mapping = KeyboardLayoutMapper.shared.hidKeycode(for: character) else {
                    Log.hid.debug("No HID mapping for character: \(character)")
                    continue
                }

                // BLE state (peripheral + pending FIFO) lives on the main queue;
                // only the inter-keystroke sleeps stay on this background queue
                DispatchQueue.main.sync {
                    self.sendKeyboardReport(modifiers: mapping.modifiers, keyCodes: [mapping.keyCode])
                }
                Thread.sleep(forTimeInterval: delay / 2)
                DispatchQueue.main.sync {
                    self.sendKeyUp()
                }
                Thread.sleep(forTimeInterval: delay)
            }
        }
    }

    // MARK: - BLEHIDPeripheralDelegate

    func peripheralDidPowerOn() {
        Log.bluetooth.info("BLE powered on — auto-starting advertising")
        startAdvertising()
    }

    func peripheralDidStartAdvertising() {
        // Don't overwrite .connected state — iPhone may subscribe before services finish
        if case .connected = connectionState {
            Log.bluetooth.info("BLE HID keyboard advertising (already connected)")
        } else {
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

    func peripheralDidConnect(central: CBCentral) {
        let connected = deviceManager.addConnectedDevice(ConnectedDevice(central: central))
        connectedDevices = deviceManager.allDevices
        connectionState = .connected(connected)
        Log.bluetooth.info("BLE device connected: \(central.identifier.uuidString)")
    }

    func peripheralDidDisconnect(central: CBCentral) {
        deviceManager.removeDevice(id: central.identifier.uuidString)
        connectedDevices = deviceManager.allDevices

        if let primary = deviceManager.primaryDevice {
            connectionState = .connected(primary)
        } else {
            // Auto-reconnect: immediately resume advertising
            connectionState = .advertising
            Log.bluetooth.info("BLE device disconnected, resuming advertising")
            blePeripheral.resumeAdvertising()
        }
    }

    func peripheralDidFail(_ failure: BLEHIDPeripheralManager.Failure) {
        connectionState = .error(failure.message)
        Log.bluetooth.error("BLE error: \(failure.message)")

        // Power-off and permission failures need user/system action, not a retry
        guard failure.isRetryable else {
            return
        }

        // Auto-recovery: retry after 3s for transient errors
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            if case .error = self.connectionState {
                Log.bluetooth.info("BLE: Auto-recovery — retrying advertising")
                self.startAdvertising()
            }
        }
    }

    func peripheralDidReceiveLEDState(_ ledByte: UInt8) {
        let newCapsLock = ledByte & 0x02 != 0
        if capsLockActive != newCapsLock {
            capsLockActive = newCapsLock
            onLEDStateChange?(capsLockActive)
        }
    }
}
