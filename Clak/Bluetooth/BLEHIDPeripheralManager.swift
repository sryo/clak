import Foundation
import CoreBluetooth

protocol BLEHIDPeripheralDelegate: AnyObject {
    func peripheralDidStartAdvertising()
    func peripheralDidStopAdvertising()
    func peripheralDidConnect(central: CBCentral)
    func peripheralDidDisconnect(central: CBCentral)
    func peripheralDidFailWithError(_ message: String)
    func peripheralDidPowerOn()
    func peripheralDidReceiveLEDState(_ ledByte: UInt8)
}

/// BLE GATT peripheral implementing HID over GATT Profile (HOGP).
///
/// Uses the full 128-bit form of Bluetooth SIG UUIDs to bypass CoreBluetooth's
/// restriction on 16-bit reserved UUIDs. The 128-bit form
/// `00001812-0000-1000-8000-00805F9B34FB` passes the addService: validation
/// while the 16-bit form `0x1812` is blocked.
///
/// Exposes three input reports, each on its own characteristic whose Report
/// Reference descriptor (0x2908) carries the Report ID — per HOGP, notification
/// payloads EXCLUDE the report ID byte:
/// - ID 1 Keyboard: [modifiers(1), reserved(1), keycodes(6)] = 8 bytes
/// - ID 2 Consumer: [usage_lo, usage_hi] = 2 bytes
/// - ID 3 Mouse:    [buttons, dx, dy, wheel] = 4 bytes
///                  (+ pan byte when includeHorizontalScroll is set)
///
/// NOTE: After changing the HID descriptor, paired devices must be
/// "forgotten" and re-paired to pick up the new report map.
final class BLEHIDPeripheralManager: NSObject {
    weak var delegate: BLEHIDPeripheralDelegate?

    /// Name shown in the host's Bluetooth UI. Set before startAdvertising().
    var localName: String = Constants.appName

    /// Adds AC Pan (horizontal scroll) to the mouse report, making it 5 bytes.
    /// ClakRemote (iOS) opts in; Clak (macOS) keeps the original 4-byte report
    /// so existing bonds stay valid. Set before startAdvertising().
    var includeHorizontalScroll = false

    private var peripheralManager: CBPeripheralManager!

    // Input Report characteristics, one per Report ID (keyboard / consumer / mouse)
    private var inputReportCharacteristic: CBMutableCharacteristic?
    private var consumerReportCharacteristic: CBMutableCharacteristic?
    private var mouseReportCharacteristic: CBMutableCharacteristic?

    // Output Report characteristic for LED state from host (Caps Lock, etc.)
    private var outputReportCharacteristic: CBMutableCharacteristic?

    /// Current LED state byte received from the host.
    /// Bit 0=Num Lock, Bit 1=Caps Lock, Bit 2=Scroll Lock, Bit 3=Compose, Bit 4=Kana
    private(set) var ledState: UInt8 = 0

    // Protocol Mode characteristic (dynamic for read/write callbacks)
    private var protocolModeCharacteristic: CBMutableCharacteristic?
    private var currentProtocolMode: UInt8 = 0x01 // 0x00=Boot, 0x01=Report

    // Service Changed characteristic — used to signal bonded devices to re-discover GATT
    private var serviceChangedCharacteristic: CBMutableCharacteristic?

    // Centrals that we've sent a Service Changed indication to
    private var serviceChangedSent: Set<UUID> = []

    // Track subscribed centrals, and which characteristics each is subscribed to —
    // with three notify characteristics, unsubscribing from ONE must not be
    // mistaken for a device disconnect
    private var subscribedCentrals: [UUID: CBCentral] = [:]
    private var subscriptionsByCentral: [UUID: Set<ObjectIdentifier>] = [:]

    // FIFO of reports awaiting notification-queue space (updateValue returned false).
    // All access happens on the main queue (CBPeripheralManager's queue).
    private var pendingReports: [(data: Data, characteristic: CBMutableCharacteristic)] = []
    private let maxPendingReports = 64

    private(set) var isAdvertising = false
    private(set) var isPoweredOn = false

    /// Whether GATT services have been published at least once.
    /// Once true, subsequent startAdvertising() calls skip service setup.
    private(set) var areServicesPublished = false

    // Track service addition to start advertising only after all services are added
    private var servicesAdded = 0
    private var totalServices = 0
    private var pendingAdvertisingStart = false

    // MARK: - HID Report Descriptor

    /// Combo HID report descriptor: keyboard (ID 1), consumer control (ID 2), mouse (ID 3).
    ///
    /// Notification payloads exclude the report ID — the per-characteristic
    /// Report Reference descriptor maps each characteristic to its ID.
    private static let hidReportDescriptor: [UInt8] = [
        // ---- Keyboard (Report ID 1) ----
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x06,       // Usage (Keyboard)
        0xA1, 0x01,       // Collection (Application)
        0x85, 0x01,       //   Report ID (1)
        // Modifier keys (8 bits)
        0x05, 0x07,       //   Usage Page (Keyboard/Keypad)
        0x19, 0xE0,       //   Usage Minimum (Left Control)
        0x29, 0xE7,       //   Usage Maximum (Right GUI)
        0x15, 0x00,       //   Logical Minimum (0)
        0x25, 0x01,       //   Logical Maximum (1)
        0x75, 0x01,       //   Report Size (1)
        0x95, 0x08,       //   Report Count (8)
        0x81, 0x02,       //   Input (Data, Variable, Absolute)
        // Reserved byte
        0x95, 0x01,       //   Report Count (1)
        0x75, 0x08,       //   Report Size (8)
        0x81, 0x01,       //   Input (Constant)
        // Key codes (6 bytes)
        0x05, 0x07,       //   Usage Page (Keyboard/Keypad)
        0x19, 0x00,       //   Usage Minimum (0)
        0x29, 0xE7,       //   Usage Maximum (231)
        0x15, 0x00,       //   Logical Minimum (0)
        0x26, 0xE7, 0x00, //   Logical Maximum (231)
        0x75, 0x08,       //   Report Size (8)
        0x95, 0x06,       //   Report Count (6)
        0x81, 0x00,       //   Input (Data, Array)
        // LED Output Report (5 LEDs + 3 padding bits = 1 byte)
        0x05, 0x08,       //   Usage Page (LEDs)
        0x19, 0x01,       //   Usage Minimum (Num Lock)
        0x29, 0x05,       //   Usage Maximum (Kana)
        0x15, 0x00,       //   Logical Minimum (0)
        0x25, 0x01,       //   Logical Maximum (1)
        0x75, 0x01,       //   Report Size (1)
        0x95, 0x05,       //   Report Count (5)
        0x91, 0x02,       //   Output (Data, Variable, Absolute)
        // Padding (3 bits)
        0x75, 0x03,       //   Report Size (3)
        0x95, 0x01,       //   Report Count (1)
        0x91, 0x01,       //   Output (Constant)
        0xC0,             // End Collection

        // ---- Consumer Control (Report ID 2) ----
        0x05, 0x0C,       // Usage Page (Consumer)
        0x09, 0x01,       // Usage (Consumer Control)
        0xA1, 0x01,       // Collection (Application)
        0x85, 0x02,       //   Report ID (2)
        0x15, 0x00,       //   Logical Minimum (0)
        0x26, 0xFF, 0x03, //   Logical Maximum (0x03FF)
        0x19, 0x00,       //   Usage Minimum (0)
        0x2A, 0xFF, 0x03, //   Usage Maximum (0x03FF)
        0x75, 0x10,       //   Report Size (16)
        0x95, 0x01,       //   Report Count (1)
        0x81, 0x00,       //   Input (Data, Array)
        0xC0,             // End Collection

        // ---- Mouse (Report ID 3) ----
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x02,       // Usage (Mouse)
        0xA1, 0x01,       // Collection (Application)
        0x85, 0x03,       //   Report ID (3)
        0x09, 0x01,       //   Usage (Pointer)
        0xA1, 0x00,       //   Collection (Physical)
        // Buttons 1-3
        0x05, 0x09,       //     Usage Page (Buttons)
        0x19, 0x01,       //     Usage Minimum (Button 1)
        0x29, 0x03,       //     Usage Maximum (Button 3)
        0x15, 0x00,       //     Logical Minimum (0)
        0x25, 0x01,       //     Logical Maximum (1)
        0x95, 0x03,       //     Report Count (3)
        0x75, 0x01,       //     Report Size (1)
        0x81, 0x02,       //     Input (Data, Variable, Absolute)
        // Padding (5 bits)
        0x95, 0x01,       //     Report Count (1)
        0x75, 0x05,       //     Report Size (5)
        0x81, 0x01,       //     Input (Constant)
        // X, Y (relative, -127..127)
        0x05, 0x01,       //     Usage Page (Generic Desktop)
        0x09, 0x30,       //     Usage (X)
        0x09, 0x31,       //     Usage (Y)
        0x15, 0x81,       //     Logical Minimum (-127)
        0x25, 0x7F,       //     Logical Maximum (127)
        0x75, 0x08,       //     Report Size (8)
        0x95, 0x02,       //     Report Count (2)
        0x81, 0x06,       //     Input (Data, Variable, Relative)
        // Wheel (relative, -127..127)
        0x09, 0x38,       //     Usage (Wheel)
        0x15, 0x81,       //     Logical Minimum (-127)
        0x25, 0x7F,       //     Logical Maximum (127)
        0x75, 0x08,       //     Report Size (8)
        0x95, 0x01,       //     Report Count (1)
        0x81, 0x06,       //     Input (Data, Variable, Relative)
    ]

    /// Optional AC Pan block spliced into the mouse collection when
    /// includeHorizontalScroll is set — macOS maps it to horizontal wheel
    /// on generic mice (tilt-wheel convention).
    private static let acPanDescriptorBlock: [UInt8] = [
        0x05, 0x0C,       //     Usage Page (Consumer)
        0x0A, 0x38, 0x02, //     Usage (AC Pan)
        0x15, 0x81,       //     Logical Minimum (-127)
        0x25, 0x7F,       //     Logical Maximum (127)
        0x75, 0x08,       //     Report Size (8)
        0x95, 0x01,       //     Report Count (1)
        0x81, 0x06,       //     Input (Data, Variable, Relative)
    ]

    private static let descriptorEnd: [UInt8] = [
        0xC0,             //   End Collection
        0xC0              // End Collection
    ]

    private var reportDescriptor: [UInt8] {
        Self.hidReportDescriptor
            + (includeHorizontalScroll ? Self.acPanDescriptorBlock : [])
            + Self.descriptorEnd
    }

    private var mouseReportSize: Int {
        includeHorizontalScroll ? 5 : 4
    }

    // MARK: - GATT UUIDs (128-bit form to bypass CoreBluetooth restriction)

    private enum GATT {
        // Service UUIDs — MUST use full 128-bit form
        static let hidService = CBUUID(string: "00001812-0000-1000-8000-00805F9B34FB")
        static let deviceInfoService = CBUUID(string: "0000180A-0000-1000-8000-00805F9B34FB")
        // Generic Attribute Profile service — needed for Service Changed
        static let genericAttributeService = CBUUID(string: "00001801-0000-1000-8000-00805F9B34FB")
        // Characteristic UUIDs — 16-bit form works fine for characteristics
        static let hidInformation = CBUUID(string: "2A4A")
        static let reportMap = CBUUID(string: "2A4B")
        static let hidControlPoint = CBUUID(string: "2A4C")
        static let report = CBUUID(string: "2A4D")
        static let protocolMode = CBUUID(string: "2A4E")
        // Service Changed characteristic (indicate-only)
        static let serviceChanged = CBUUID(string: "2A05")

        static let manufacturerName = CBUUID(string: "2A29")
        static let modelNumber = CBUUID(string: "2A24")
        static let pnpID = CBUUID(string: "2A50")
    }

    // MARK: - Init

    override init() {
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
    }

    // MARK: - Start / Stop

    /// Start advertising. If services are already published, just resumes advertising.
    func startAdvertising() {
        guard isPoweredOn else {
            Log.bluetooth.error("BLE: Cannot advertise — Bluetooth not powered on")
            delegate?.peripheralDidFailWithError("Bluetooth is powered off")
            return
        }
        guard !isAdvertising else {
            Log.bluetooth.info("BLE: Already advertising")
            return
        }

        if areServicesPublished {
            resumeAdvertising()
        } else {
            servicesAdded = 0
            pendingAdvertisingStart = true
            setupServices()
        }
    }

    /// Lightweight resume — just starts advertising without rebuilding services.
    func resumeAdvertising() {
        guard isPoweredOn, !isAdvertising else {
            return
        }
        beginAdvertising()
    }

    /// Stops advertising but keeps GATT services intact for fast reconnection.
    func stopAdvertisingOnly() {
        pendingAdvertisingStart = false
        if isAdvertising {
            peripheralManager.stopAdvertising()
            isAdvertising = false
            Log.bluetooth.info("BLE: Stopped advertising (services retained)")
        }
    }

    /// Full teardown — removes all services. Only for app termination.
    func teardownCompletely() {
        pendingAdvertisingStart = false

        if isAdvertising {
            peripheralManager.stopAdvertising()
        }

        peripheralManager.removeAllServices()
        subscribedCentrals.removeAll()
        subscriptionsByCentral.removeAll()
        serviceChangedSent.removeAll()
        inputReportCharacteristic = nil
        consumerReportCharacteristic = nil
        mouseReportCharacteristic = nil
        outputReportCharacteristic = nil
        protocolModeCharacteristic = nil
        serviceChangedCharacteristic = nil
        currentProtocolMode = 0x01
        ledState = 0
        pendingReports.removeAll()
        isAdvertising = false
        areServicesPublished = false

        Log.bluetooth.info("BLE: Torn down completely")
        delegate?.peripheralDidStopAdvertising()
    }

    // MARK: - Send Reports

    /// Send a keyboard input report via BLE notification.
    /// Format (no Report ID): [modifiers, 0x00, k1, k2, k3, k4, k5, k6] = 8 bytes
    @discardableResult
    func sendKeyboardReport(modifiers: UInt8, keyCodes: [UInt8]) -> Bool {
        guard let characteristic = inputReportCharacteristic else {
            return false
        }
        guard !subscribedCentrals.isEmpty else {
            return false
        }

        var reportBytes = [UInt8](repeating: 0, count: 8)
        reportBytes[0] = modifiers
        // reportBytes[1] = 0x00 (reserved)
        for i in 0..<min(keyCodes.count, 6) {
            reportBytes[2 + i] = keyCodes[i]
        }

        return sendReport(Data(reportBytes), on: characteristic)
    }

    /// Send via notification, preserving order: if reports are already queued,
    /// new ones join the back of the FIFO instead of jumping ahead.
    @discardableResult
    private func sendReport(_ data: Data, on characteristic: CBMutableCharacteristic) -> Bool {
        guard pendingReports.isEmpty else {
            enqueuePendingReport(data, on: characteristic)
            return false
        }
        let sent = peripheralManager.updateValue(data, for: characteristic, onSubscribedCentrals: nil)
        if !sent {
            enqueuePendingReport(data, on: characteristic)
        }
        return sent
    }

    private func enqueuePendingReport(_ data: Data, on characteristic: CBMutableCharacteristic) {
        if pendingReports.count >= maxPendingReports {
            pendingReports.removeFirst()
            Log.bluetooth.warning("BLE: Pending report queue full — dropping oldest report")
        }
        pendingReports.append((data, characteristic))
    }

    @discardableResult
    func sendKeyRelease() -> Bool {
        sendKeyboardReport(modifiers: 0, keyCodes: [])
    }

    /// Send a consumer control report (16-bit usage, little-endian). Usage 0 = release.
    @discardableResult
    func sendConsumerReport(usage: UInt16) -> Bool {
        guard let characteristic = consumerReportCharacteristic, !subscribedCentrals.isEmpty else {
            return false
        }
        return sendReport(Data([UInt8(usage & 0xFF), UInt8(usage >> 8)]), on: characteristic)
    }

    /// Send a mouse report: [buttons, dx, dy, wheel] (+ pan when enabled).
    @discardableResult
    func sendMouseReport(buttons: UInt8, dx: Int8, dy: Int8, wheel: Int8, pan: Int8 = 0) -> Bool {
        guard let characteristic = mouseReportCharacteristic, !subscribedCentrals.isEmpty else {
            return false
        }
        var bytes: [UInt8] = [
            buttons,
            UInt8(bitPattern: dx), UInt8(bitPattern: dy),
            UInt8(bitPattern: wheel),
        ]
        if includeHorizontalScroll {
            bytes.append(UInt8(bitPattern: pan))
        }
        return sendReport(Data(bytes), on: characteristic)
    }

    // MARK: - Build GATT Services

    private func setupServices() {
        peripheralManager.removeAllServices()

        // CBPeripheralManager throws NSInternalInconsistencyException on the first
        // add() call. Work around this by adding a disposable "warm-up" service first,
        // then adding the real services after the callback.
        let warmupUUID = CBUUID(string: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        let warmup = CBMutableService(type: warmupUUID, primary: false)
        warmup.characteristics = []

        let services: [(String, CBMutableService)] = [
            ("_warmup", warmup),
            ("GATT", buildGenericAttributeService()),
            ("HID", buildHIDService()),
            ("DeviceInfo", buildDeviceInfoService()),
        ]

        totalServices = services.count
        pendingServiceQueue = services

        // Delay after removeAllServices
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.addNextService()
        }
    }

    private var pendingServiceQueue: [(String, CBMutableService)] = []

    private func addNextService() {
        guard !pendingServiceQueue.isEmpty else {
            return
        }

        let (name, service) = pendingServiceQueue.removeFirst()
        Log.bluetooth.info("BLE: Adding \(name) service")

        let exception = ObjCExceptionCatcher.`try` {
            self.peripheralManager.add(service)
        }
        if let exception {
            Log.bluetooth.error("BLE: Exception adding \(name) service: \(exception.name.rawValue): \(exception.reason ?? "unknown")")
            serviceAddCompleted()
        }
        // If no exception, wait for didAdd delegate callback which calls serviceAddCompleted
    }

    /// Advance the service-add queue: start advertising once all services are in,
    /// otherwise schedule the next add after a small delay to let CoreBluetooth settle.
    private func serviceAddCompleted() {
        servicesAdded += 1

        if servicesAdded >= totalServices && pendingAdvertisingStart {
            pendingAdvertisingStart = false
            areServicesPublished = true
            beginAdvertising()
        } else if !pendingServiceQueue.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.addNextService()
            }
        }
    }

    private func buildGenericAttributeService() -> CBMutableService {
        let service = CBMutableService(type: GATT.genericAttributeService, primary: true)
        // Service Changed characteristic: indicate-only, dynamic (value: nil)
        // When a bonded central subscribes to indications, we send the handle range
        // that changed to force service re-discovery.
        let serviceChanged = CBMutableCharacteristic(
            type: GATT.serviceChanged, properties: .indicate,
            value: nil, permissions: .readable
        )
        self.serviceChangedCharacteristic = serviceChanged
        service.characteristics = [serviceChanged]
        return service
    }

    private func buildHIDService() -> CBMutableService {
        let service = CBMutableService(type: GATT.hidService, primary: true)
        var chars: [CBMutableCharacteristic] = []

        // HID Information: bcdHID=1.1, country=0, flags=0x02 (normally connectable)
        chars.append(CBMutableCharacteristic(
            type: GATT.hidInformation, properties: .read,
            value: Data([0x11, 0x01, 0x00, 0x02]), permissions: .readable
        ))

        // Report Map: the HID report descriptor (keyboard only)
        // HOGP spec requires Security Mode 1, Level 2 (encryption) for Report Map
        chars.append(CBMutableCharacteristic(
            type: GATT.reportMap, properties: .read,
            value: Data(reportDescriptor), permissions: .readEncryptionRequired
        ))

        // Protocol Mode: Report Protocol (0x01)
        // Per HOGP spec, must support Read and WriteWithoutResponse
        let protocolMode = CBMutableCharacteristic(
            type: GATT.protocolMode, properties: [.read, .writeWithoutResponse],
            value: nil, permissions: [.readable, .writeable]
        )
        self.protocolModeCharacteristic = protocolMode
        chars.append(protocolMode)

        // Input Report characteristics — dynamic (value: nil) for notifications.
        // HOGP spec requires encryption for Report characteristic access.
        // Each gets a Report Reference descriptor (0x2908) carrying [Report ID, Type].
        // Apple docs claim CBMutableDescriptor supports only 0x2901/0x2904, but
        // 0x2908 works in practice — and iOS requires it to subscribe at all.
        let keyboardInput = CBMutableCharacteristic(
            type: GATT.report, properties: [.read, .notify],
            value: nil, permissions: .readEncryptionRequired
        )
        addReportReference(to: keyboardInput, reportID: 0x01, type: 0x01, label: "keyboard input")
        self.inputReportCharacteristic = keyboardInput
        chars.append(keyboardInput)

        let consumerInput = CBMutableCharacteristic(
            type: GATT.report, properties: [.read, .notify],
            value: nil, permissions: .readEncryptionRequired
        )
        addReportReference(to: consumerInput, reportID: 0x02, type: 0x01, label: "consumer input")
        self.consumerReportCharacteristic = consumerInput
        chars.append(consumerInput)

        let mouseInput = CBMutableCharacteristic(
            type: GATT.report, properties: [.read, .notify],
            value: nil, permissions: .readEncryptionRequired
        )
        addReportReference(to: mouseInput, reportID: 0x03, type: 0x01, label: "mouse input")
        self.mouseReportCharacteristic = mouseInput
        chars.append(mouseInput)

        // Output Report — for LED state (Caps Lock, etc.) written by the host.
        let outputReport = CBMutableCharacteristic(
            type: GATT.report,
            properties: [.read, .write, .writeWithoutResponse],
            value: nil,
            permissions: [.readEncryptionRequired, .writeEncryptionRequired]
        )
        addReportReference(to: outputReport, reportID: 0x01, type: 0x02, label: "LED output")
        self.outputReportCharacteristic = outputReport
        chars.append(outputReport)

        // HID Control Point: suspend/resume
        // HOGP spec requires encryption for HID Control Point writes
        chars.append(CBMutableCharacteristic(
            type: GATT.hidControlPoint, properties: .writeWithoutResponse,
            value: nil, permissions: .writeEncryptionRequired
        ))

        service.characteristics = chars
        return service
    }

    private func addReportReference(to characteristic: CBMutableCharacteristic, reportID: UInt8, type: UInt8, label: String) {
        let exception = ObjCExceptionCatcher.`try` {
            let desc = CBMutableDescriptor(type: CBUUID(string: "2908"), value: Data([reportID, type]))
            characteristic.descriptors = (characteristic.descriptors ?? []) + [desc]
            Log.bluetooth.info("BLE: Report Reference descriptor added (\(label, privacy: .public))")
        }
        if let exception {
            Log.bluetooth.warning("BLE: Report Reference descriptor failed (\(label, privacy: .public)): \(exception.name.rawValue): \(exception.reason ?? "unknown")")
        }
    }

    private func buildDeviceInfoService() -> CBMutableService {
        let service = CBMutableService(type: GATT.deviceInfoService, primary: true)
        service.characteristics = [
            CBMutableCharacteristic(type: GATT.manufacturerName, properties: .read,
                value: "Clak".data(using: .utf8), permissions: .readable),
            CBMutableCharacteristic(type: GATT.modelNumber, properties: .read,
                value: "Virtual Keyboard".data(using: .utf8), permissions: .readable),
            // PnP ID: source 0x02 (USB), VID 0xFFFF (unassigned), PID 0x0100, version 1.0
            CBMutableCharacteristic(type: GATT.pnpID, properties: .read,
                value: Data([0x02, 0xFF, 0xFF, 0x00, 0x01, 0x00, 0x01]), permissions: .readable),
        ]
        return service
    }


    private func beginAdvertising() {
        // Advertise with the 16-bit HID service UUID for compact advertisement packets.
        // The service was registered using the 128-bit form (to bypass CoreBluetooth's
        // add restriction), but we advertise the 16-bit equivalent so the packet fits
        // within BLE's 31-byte advertisement limit and iOS can discover us as an HID device.
        let advertisementData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "1812")],
        ]

        peripheralManager.startAdvertising(advertisementData)
        Log.bluetooth.info("BLE: Requesting advertising start (services published: \(self.areServicesPublished))")
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEHIDPeripheralManager: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            isPoweredOn = true
            Log.bluetooth.info("BLE: Bluetooth powered on")
            delegate?.peripheralDidPowerOn()
        case .poweredOff:
            isPoweredOn = false
            isAdvertising = false
            subscribedCentrals.removeAll()
            subscriptionsByCentral.removeAll()
            // Forget who got Service Changed — after a power cycle the GATT db is
            // rebuilt and reconnecting centrals must be told to re-discover
            serviceChangedSent.removeAll()
            // CoreBluetooth drops published services on power-off — force a full
            // re-publish on the next advertise instead of resuming with an empty GATT db
            areServicesPublished = false
            pendingServiceQueue.removeAll()
            servicesAdded = 0
            totalServices = 0
            pendingAdvertisingStart = false
            pendingReports.removeAll()
            Log.bluetooth.warning("BLE: Bluetooth powered off")
            delegate?.peripheralDidFailWithError("Bluetooth is powered off")
        case .unauthorized:
            isPoweredOn = false
            Log.bluetooth.error("BLE: Bluetooth unauthorized")
            delegate?.peripheralDidFailWithError("Bluetooth access not authorized")
        case .unsupported:
            isPoweredOn = false
            Log.bluetooth.error("BLE: BLE not supported")
            delegate?.peripheralDidFailWithError("Bluetooth LE is not supported on this hardware")
        default:
            break
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            Log.bluetooth.error("BLE: Advertising failed: \(error.localizedDescription)")
            isAdvertising = false
            delegate?.peripheralDidFailWithError("BLE advertising failed: \(error.localizedDescription)")
            return
        }

        isAdvertising = true
        Log.bluetooth.info("BLE: Advertising started — visible as 'Clak' HID keyboard")
        delegate?.peripheralDidStartAdvertising()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        let uuid = service.uuid.uuidString

        if let error {
            Log.bluetooth.error("BLE: Failed to add service \(uuid, privacy: .public): \(error.localizedDescription, privacy: .public)")
        } else {
            Log.bluetooth.info("BLE: Service added successfully: \(uuid, privacy: .public)")
        }

        serviceAddCompleted()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        Log.bluetooth.info("BLE: Central \(central.identifier.uuidString, privacy: .public) subscribed to \(characteristic.uuid.uuidString, privacy: .public)")

        let wasEmpty = subscribedCentrals.isEmpty
        subscribedCentrals[central.identifier] = central
        subscriptionsByCentral[central.identifier, default: []].insert(ObjectIdentifier(characteristic))

        // Stop advertising once connected — saves power
        if isAdvertising {
            peripheralManager.stopAdvertising()
            isAdvertising = false
            Log.bluetooth.info("BLE: Stopped advertising (device connected)")
        }

        if wasEmpty {
            delegate?.peripheralDidConnect(central: central)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        Log.bluetooth.info("BLE: Central \(central.identifier.uuidString, privacy: .public) unsubscribed from \(characteristic.uuid.uuidString, privacy: .public)")

        let centralID = central.identifier
        subscriptionsByCentral[centralID]?.remove(ObjectIdentifier(characteristic))

        // Only a central with no remaining subscriptions has disconnected
        guard subscriptionsByCentral[centralID]?.isEmpty ?? true else {
            return
        }
        subscriptionsByCentral.removeValue(forKey: centralID)
        subscribedCentrals.removeValue(forKey: centralID)

        if subscribedCentrals.isEmpty {
            pendingReports.removeAll()
            serviceChangedSent.removeAll()
            delegate?.peripheralDidDisconnect(central: central)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let centralID = request.central.identifier.uuidString
        Log.bluetooth.info("BLE: Read from \(centralID, privacy: .public) char=\(request.characteristic.uuid.uuidString, privacy: .public) offset=\(request.offset, privacy: .public)")

        if request.characteristic === inputReportCharacteristic
            || request.characteristic === consumerReportCharacteristic
            || request.characteristic === mouseReportCharacteristic {
            // Return an empty report sized for the characteristic's report type
            // (payloads exclude the Report ID per HOGP)
            let size = request.characteristic === inputReportCharacteristic ? 8
                : request.characteristic === mouseReportCharacteristic ? mouseReportSize
                : 2
            respond(to: request, with: Data([UInt8](repeating: 0, count: size)), peripheral: peripheral)
        } else if request.characteristic === outputReportCharacteristic {
            respond(to: request, with: Data([ledState]), peripheral: peripheral)
        } else if request.characteristic === protocolModeCharacteristic {
            respond(to: request, with: Data([currentProtocolMode]), peripheral: peripheral)
        } else if let value = request.characteristic.value {
            respond(to: request, with: value, peripheral: peripheral)
        } else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
        }
    }

    /// Answer a read request with `data`, honoring the requested offset.
    private func respond(to request: CBATTRequest, with data: Data, peripheral: CBPeripheralManager) {
        if request.offset >= data.count {
            peripheral.respond(to: request, withResult: .invalidOffset)
        } else {
            request.value = data.subdata(in: request.offset..<data.count)
            peripheral.respond(to: request, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let centralID = request.central.identifier.uuidString
            let charUUID = request.characteristic.uuid.uuidString
            let dataHex = request.value?.map { String(format: "%02X", $0) }.joined(separator: " ") ?? "nil"
            Log.bluetooth.info("BLE: Write from \(centralID, privacy: .public) char=\(charUUID, privacy: .public) data=[\(dataHex, privacy: .public)]")

            if request.characteristic.uuid == GATT.hidControlPoint {
                if let data = request.value, let cmd = data.first {
                    Log.bluetooth.info("BLE: HID Control Point cmd=\(cmd, privacy: .public) (\(cmd == 0 ? "Suspend" : "Exit Suspend", privacy: .public))")

                    // If this central hasn't subscribed to Report and we haven't sent
                    // Service Changed yet, send it to force GATT re-discovery
                    let centralID = request.central.identifier
                    if subscribedCentrals[centralID] == nil && !serviceChangedSent.contains(centralID) {
                        serviceChangedSent.insert(centralID)
                        sendServiceChangedIndication()
                    }
                }
            } else if request.characteristic === outputReportCharacteristic {
                if let data = request.value, let led = data.first {
                    ledState = led
                    let capsOn = led & 0x02 != 0
                    Log.bluetooth.info("BLE: LED state received: 0x\(String(format: "%02X", led), privacy: .public) (Caps=\(capsOn ? "ON" : "OFF", privacy: .public))")
                    delegate?.peripheralDidReceiveLEDState(led)
                }
            } else if request.characteristic === protocolModeCharacteristic {
                if let data = request.value, let mode = data.first {
                    currentProtocolMode = mode
                    Log.bluetooth.info("BLE: Protocol Mode set to \(mode, privacy: .public) (\(mode == 0 ? "Boot" : "Report", privacy: .public))")
                }
            }
        }

        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    /// Send a Service Changed indication to force bonded centrals to re-discover GATT services.
    /// The handle range starts at 0x0010 to exclude the GATT service itself (handles ~0x0001-0x000F).
    /// iOS marks GATT as invalid and ignores all future Service Changed if the range includes it.
    private func sendServiceChangedIndication() {
        guard let characteristic = serviceChangedCharacteristic else {
            Log.bluetooth.error("BLE: Service Changed characteristic not available")
            return
        }

        // Service Changed value: [start_handle_lo, start_handle_hi, end_handle_lo, end_handle_hi]
        // 0x0010 to 0xFFFF = excludes GATT service handles to avoid iOS caching bug
        let data = Data([0x10, 0x00, 0xFF, 0xFF])
        let sent = peripheralManager.updateValue(data, for: characteristic, onSubscribedCentrals: nil)
        Log.bluetooth.info("BLE: Service Changed indication sent=\(sent, privacy: .public)")
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        while !pendingReports.isEmpty {
            let (data, characteristic) = pendingReports.removeFirst()
            if !peripheral.updateValue(data, for: characteristic, onSubscribedCentrals: nil) {
                pendingReports.insert((data, characteristic), at: 0)
                break
            }
        }
    }
}
