import Foundation
import CoreBluetooth

protocol BLEHIDPeripheralDelegate: AnyObject {
    func peripheralDidStartAdvertising()
    func peripheralDidStopAdvertising()
    func peripheralDidConnect(central: CBCentral)
    func peripheralDidDisconnect(central: CBCentral)
    func peripheralDidFail(_ failure: BLEHIDPeripheralManager.Failure)
    func peripheralDidPowerOn()
    func peripheralDidReceiveLEDState(_ ledByte: UInt8)
    /// The notification queue has drained — queued senders may push more reports.
    func peripheralIsReadyToSend()
}

extension BLEHIDPeripheralDelegate {
    func peripheralIsReadyToSend() {}
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
/// payloads EXCLUDE the report ID byte. Report layouts live in HIDReportMap.
///
/// NOTE: After changing the HID descriptor, paired devices must be
/// "forgotten" and re-paired to pick up the new report map.
final class BLEHIDPeripheralManager: NSObject {

    enum Failure: Equatable {
        case poweredOff
        case unauthorized
        case unsupported
        case advertisingFailed(String)
        case serviceSetupFailed(String)

        var message: String {
            switch self {
            case .poweredOff: "Bluetooth is powered off"
            case .unauthorized: "Bluetooth access not authorized"
            case .unsupported: "Bluetooth LE is not supported on this hardware"
            case .advertisingFailed(let reason): "BLE advertising failed: \(reason)"
            case .serviceSetupFailed(let reason): "BLE service setup failed: \(reason)"
            }
        }

        /// Whether retrying can help. Power/permission failures need
        /// user or system action instead.
        var isRetryable: Bool {
            switch self {
            case .poweredOff, .unauthorized, .unsupported: false
            case .advertisingFailed, .serviceSetupFailed: true
            }
        }
    }

    weak var delegate: BLEHIDPeripheralDelegate?

    /// Name shown in the host's Bluetooth UI.
    let localName: String

    /// Report layout, frozen at init: the published report map and the payload
    /// sizes sent later can never disagree.
    let reportMap: HIDReportMap

    /// Whether our own Generic Attribute service (0x1801) joins the database.
    let publishesGenericAttributeService: Bool

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

    // MARK: - Per-central sessions

    /// Everything we know about one central. "Connected" deliberately means
    /// "subscribed to at least one input report" — a central that only
    /// subscribed to Service Changed (2A05) cannot receive keystrokes, and
    /// reporting it as connected would silently swallow every report.
    private struct CentralSession {
        let central: CBCentral
        var subscriptions: Set<ObjectIdentifier> = []
        var inputSubscriptions: Set<ObjectIdentifier> = []
        var serviceChangedDelivered = false
        var isConnected: Bool { !inputSubscriptions.isEmpty }
    }

    private var sessions: [UUID: CentralSession] = [:]

    private var hasConnectedCentral: Bool {
        sessions.values.contains { $0.isConnected }
    }

    // Centrals whose Service Changed indication bounced off a full notify
    // queue — retried from peripheralManagerIsReady
    private var pendingServiceChangedCentrals: [UUID] = []

    // FIFO of reports awaiting notification-queue space (updateValue returned false).
    // All access happens on the main queue (CBPeripheralManager's queue).
    private var pendingReports: [(data: Data, characteristic: CBMutableCharacteristic)] = []
    private let maxPendingReports = 64

    // MARK: - Lifecycle state

    /// Single source of truth for the publish/advertise state machine.
    /// Every deferred continuation checks `setupGeneration` so a stale timer
    /// from a cancelled setup can never mutate a newer one.
    private enum Lifecycle: Equatable {
        case idle          // no services in the GATT database
        case publishing    // service-add chain in flight
        case published     // services live, not advertising
        case advertising
    }

    private var lifecycle: Lifecycle = .idle
    private var wantsAdvertising = false
    private var setupGeneration = 0
    private var advertisingRequestInFlight = false
    private var advertisingCancelledInFlight = false

    private(set) var isPoweredOn = false

    var isAdvertising: Bool { lifecycle == .advertising }
    var areServicesPublished: Bool { lifecycle == .published || lifecycle == .advertising }

    /// Delay between service adds. macOS CoreBluetooth needs generous settling
    /// around removeAllServices/add; iOS only gets a token hop so publishing
    /// doesn't gate advertising behind a second of dead time.
    private static let serviceAddSettleDelay: TimeInterval = {
        #if os(macOS)
        return 0.3
        #else
        return 0.05
        #endif
    }()

    private static let warmupServiceUUID = CBUUID(string: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")

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

    /// - Parameters:
    ///   - restoreIdentifier: iOS only — opts into CoreBluetooth state
    ///     restoration so the system relaunches the app when a bonded central
    ///     acts on our services after the app was jettisoned. Ignored on macOS
    ///     (unsupported there).
    ///   - publishesGenericAttributeService: false where the host OS already
    ///     runs a shared GATT server owning 0x1801. A second, app-owned Service
    ///     Changed dies with the process, and a central that subscribed to it
    ///     loses its re-discovery signal — so on iOS the system's copy is left
    ///     to do the job alone. With this off, the Service Changed nudge below
    ///     is inert: there is no characteristic of ours to indicate on.
    init(localName: String = Constants.appName,
         includeHorizontalScroll: Bool = false,
         restoreIdentifier: String? = nil,
         publishesGenericAttributeService: Bool = true) {
        self.localName = localName
        self.reportMap = HIDReportMap(includeHorizontalScroll: includeHorizontalScroll)
        self.publishesGenericAttributeService = publishesGenericAttributeService
        super.init()

        #if os(iOS)
        var options: [String: Any] = [:]
        if let restoreIdentifier {
            options[CBPeripheralManagerOptionRestoreIdentifierKey] = restoreIdentifier
        }
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main, options: options)
        #else
        _ = restoreIdentifier
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
        #endif
    }

    // MARK: - Start / Stop

    /// Start advertising, publishing services first if needed. Safe to call in
    /// any state: while publishing it just records the intent, before power-on
    /// it defers until the state callback arrives.
    func startAdvertising() {
        guard isPoweredOn else {
            switch peripheralManager.state {
            case .poweredOff:
                Log.bluetooth.error("BLE: Cannot advertise — Bluetooth powered off")
                delegate?.peripheralDidFail(.poweredOff)
            case .unauthorized:
                delegate?.peripheralDidFail(.unauthorized)
            case .unsupported:
                delegate?.peripheralDidFail(.unsupported)
            default:
                // .unknown/.resetting at cold launch — the poweredOn callback
                // re-enters via the delegate, so no error flash in the meantime
                Log.bluetooth.info("BLE: Advertising deferred until power on")
                wantsAdvertising = true
            }
            return
        }

        switch lifecycle {
        case .advertising:
            Log.bluetooth.info("BLE: Already advertising")
        case .publishing:
            wantsAdvertising = true
        case .published:
            beginAdvertising()
        case .idle:
            wantsAdvertising = true
            publishServices()
        }
    }

    /// Compatibility alias — startAdvertising() now handles every state.
    func resumeAdvertising() {
        startAdvertising()
    }

    /// Rebuild the GATT database and advertise again, as a fresh launch would.
    /// A host whose cached copy of our services predates them ignores the
    /// advertisement indefinitely; re-publishing is what makes it look again.
    /// Unlike teardownCompletely() this keeps the manager live, so it is safe
    /// to call on a running session.
    func republish() {
        guard isPoweredOn else { return }
        wantsAdvertising = true
        if lifecycle == .advertising {
            peripheralManager.stopAdvertising()
        }
        publishServices()
    }

    /// Stops advertising but keeps GATT services intact for fast reconnection.
    /// If a publish is in flight it completes, but advertising won't auto-start.
    func stopAdvertisingOnly() {
        wantsAdvertising = false
        if advertisingRequestInFlight {
            advertisingCancelledInFlight = true
        }
        if lifecycle == .advertising {
            peripheralManager.stopAdvertising()
            lifecycle = .published
            Log.bluetooth.info("BLE: Stopped advertising (services retained)")
        }
    }

    /// Full teardown — removes all services. Only for app termination.
    func teardownCompletely() {
        setupGeneration += 1
        pendingServiceQueue.removeAll()
        wantsAdvertising = false
        advertisingRequestInFlight = false
        advertisingCancelledInFlight = false

        if lifecycle == .advertising {
            peripheralManager.stopAdvertising()
        }

        peripheralManager.removeAllServices()
        sessions.removeAll()
        pendingServiceChangedCentrals.removeAll()
        inputReportCharacteristic = nil
        consumerReportCharacteristic = nil
        mouseReportCharacteristic = nil
        outputReportCharacteristic = nil
        protocolModeCharacteristic = nil
        serviceChangedCharacteristic = nil
        currentProtocolMode = 0x01
        ledState = 0
        pendingReports.removeAll()
        lifecycle = .idle

        Log.bluetooth.info("BLE: Torn down completely")
        delegate?.peripheralDidStopAdvertising()
    }

    // MARK: - Send Reports

    /// Send a keyboard input report via BLE notification.
    /// Format (no Report ID): [modifiers, 0x00, k1, k2, k3, k4, k5, k6] = 8 bytes
    /// - Returns: true if the report went out immediately; false if it was
    ///   queued (or no central is subscribed). Queued senders should wait for
    ///   peripheralIsReadyToSend() before pushing more.
    @discardableResult
    func sendKeyboardReport(modifiers: UInt8, keyCodes: [UInt8]) -> Bool {
        guard let characteristic = inputReportCharacteristic,
              hasSubscriber(to: characteristic) else {
            return false
        }

        var reportBytes = [UInt8](repeating: 0, count: HIDReportMap.keyboardReportSize)
        reportBytes[0] = modifiers
        // reportBytes[1] = 0x00 (reserved)
        for i in 0..<min(keyCodes.count, 6) {
            reportBytes[2 + i] = keyCodes[i]
        }

        return sendReport(Data(reportBytes), on: characteristic)
    }

    @discardableResult
    func sendKeyRelease() -> Bool {
        sendKeyboardReport(modifiers: 0, keyCodes: [])
    }

    /// Send a consumer control report (16-bit usage, little-endian). Usage 0 = release.
    @discardableResult
    func sendConsumerReport(usage: UInt16) -> Bool {
        guard let characteristic = consumerReportCharacteristic,
              hasSubscriber(to: characteristic) else {
            return false
        }
        return sendReport(Data([UInt8(usage & 0xFF), UInt8(usage >> 8)]), on: characteristic)
    }

    /// Send a mouse report: [buttons, dx, dy, wheel] (+ pan when enabled).
    @discardableResult
    func sendMouseReport(buttons: UInt8, dx: Int8, dy: Int8, wheel: Int8, pan: Int8 = 0) -> Bool {
        guard let characteristic = mouseReportCharacteristic,
              hasSubscriber(to: characteristic) else {
            return false
        }
        var bytes: [UInt8] = [
            buttons,
            UInt8(bitPattern: dx), UInt8(bitPattern: dy),
            UInt8(bitPattern: wheel),
        ]
        if reportMap.includeHorizontalScroll {
            bytes.append(UInt8(bitPattern: pan))
        }
        return sendReport(Data(bytes), on: characteristic)
    }

    private func hasSubscriber(to characteristic: CBMutableCharacteristic) -> Bool {
        let id = ObjectIdentifier(characteristic)
        return sessions.values.contains { $0.subscriptions.contains(id) }
    }

    /// Send via notification, preserving order: if reports are already queued,
    /// new ones join the back of the FIFO instead of jumping ahead.
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

    // MARK: - Publish GATT Services

    private var pendingServiceQueue: [(String, CBMutableService)] = []

    private func publishServices() {
        lifecycle = .publishing
        setupGeneration += 1
        let generation = setupGeneration

        peripheralManager.removeAllServices()

        var services: [(String, CBMutableService)] = []

        // CBPeripheralManager can throw NSInternalInconsistencyException on the
        // first add() call after init/removeAllServices. A disposable "warm-up"
        // service absorbs it so the real services add cleanly. Only proven
        // necessary on macOS, but kept on iOS too until on-device testing shows
        // the first add is safe there — a thrown add now aborts publishing.
        let warmup = CBMutableService(type: Self.warmupServiceUUID, primary: false)
        warmup.characteristics = []
        services.append(("_warmup", warmup))

        if publishesGenericAttributeService {
            services.append(("GATT", buildGenericAttributeService()))
        }
        services.append(("HID", buildHIDService()))
        services.append(("DeviceInfo", buildDeviceInfoService()))

        pendingServiceQueue = services

        // Delay after removeAllServices
        scheduleNextServiceAdd(generation: generation)
    }

    private func scheduleNextServiceAdd(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.serviceAddSettleDelay) { [weak self] in
            guard let self, self.setupGeneration == generation else { return }
            self.addNextService(generation: generation)
        }
    }

    private func addNextService(generation: Int) {
        guard setupGeneration == generation, lifecycle == .publishing,
              !pendingServiceQueue.isEmpty else {
            return
        }

        let (name, service) = pendingServiceQueue.removeFirst()
        Log.bluetooth.info("BLE: Adding \(name) service")

        let exception = ObjCExceptionCatcher.`try` {
            self.peripheralManager.add(service)
        }
        if let exception {
            if service.uuid == Self.warmupServiceUUID {
                // Expected: the warm-up service exists to absorb this. No didAdd
                // callback will come, so continue the chain from here.
                Log.bluetooth.info("BLE: Warm-up service absorbed \(exception.name.rawValue)")
                scheduleNextServiceAdd(generation: generation)
            } else {
                abortPublishing(reason: "\(name): \(exception.name.rawValue): \(exception.reason ?? "unknown")")
            }
        }
        // If no exception, wait for the didAdd delegate callback
    }

    /// A real service failed to add: report it instead of advertising a GATT
    /// database with holes (an HID advertisement without an HID service is
    /// discoverable but unpairable).
    private func abortPublishing(reason: String) {
        Log.bluetooth.error("BLE: Service setup failed — \(reason, privacy: .public)")
        setupGeneration += 1
        pendingServiceQueue.removeAll()
        wantsAdvertising = false
        lifecycle = .idle
        delegate?.peripheralDidFail(.serviceSetupFailed(reason))
    }

    private func publishCompleted() {
        lifecycle = .published
        Log.bluetooth.info("BLE: All services published")

        if hasConnectedCentral {
            // A central subscribed mid-publish (bonded reconnect) — advertising
            // now would invite a second host while one is already connected
            wantsAdvertising = false
        } else if wantsAdvertising {
            wantsAdvertising = false
            beginAdvertising()
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

        // Report Map: the HID report descriptor
        // HOGP spec requires Security Mode 1, Level 2 (encryption) for Report Map
        chars.append(CBMutableCharacteristic(
            type: GATT.reportMap, properties: .read,
            value: Data(reportMap.descriptor), permissions: .readEncryptionRequired
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
        guard !advertisingRequestInFlight else { return }
        advertisingRequestInFlight = true

        // Advertise with the 16-bit HID service UUID for compact advertisement packets.
        // The service was registered using the 128-bit form (to bypass CoreBluetooth's
        // add restriction), but we advertise the 16-bit equivalent so the packet fits
        // within BLE's 31-byte advertisement limit and iOS can discover us as an HID device.
        let advertisementData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "1812")],
        ]

        peripheralManager.startAdvertising(advertisementData)
        Log.bluetooth.info("BLE: Requesting advertising start")
    }

    /// Radio went away (.poweredOff/.resetting/.unknown): CoreBluetooth drops
    /// published services and connections, so every layer of live state resets
    /// and the next advertise does a full re-publish.
    private func resetForRadioLoss() {
        isPoweredOn = false
        setupGeneration += 1
        pendingServiceQueue.removeAll()
        lifecycle = .idle
        wantsAdvertising = false
        advertisingRequestInFlight = false
        advertisingCancelledInFlight = false
        sessions.removeAll()
        pendingServiceChangedCentrals.removeAll()
        pendingReports.removeAll()
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
            resetForRadioLoss()
            Log.bluetooth.warning("BLE: Bluetooth powered off")
            delegate?.peripheralDidFail(.poweredOff)
        case .unauthorized:
            isPoweredOn = false
            Log.bluetooth.error("BLE: Bluetooth unauthorized")
            delegate?.peripheralDidFail(.unauthorized)
        case .unsupported:
            isPoweredOn = false
            Log.bluetooth.error("BLE: BLE not supported")
            delegate?.peripheralDidFail(.unsupported)
        case .resetting, .unknown:
            // bluetoothd restarting — hold everything until the next .poweredOn
            resetForRadioLoss()
            Log.bluetooth.warning("BLE: Bluetooth resetting")
        @unknown default:
            break
        }
    }

    #if os(iOS)
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        // The system relaunched us for a bonded central. Restored services are
        // rebuilt from scratch on the next startAdvertising() — the bond
        // survives, and Service Changed covers any handle movement.
        let restoredServices = (dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService]) ?? []

        // The system may also have been advertising on our behalf. Since the
        // GATT database is rebuilt from scratch, that advertisement is stale:
        // it points at handles about to be torn down, and leaving it up makes
        // the next start request fail as a duplicate.
        if dict[CBPeripheralManagerRestoredStateAdvertisementDataKey] != nil {
            peripheral.stopAdvertising()
            Log.bluetooth.info("BLE: Dropped restored advertisement before re-publishing")
        }

        Log.bluetooth.info("BLE: Restored by system (\(restoredServices.count) services) — will re-publish")
    }
    #endif

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        advertisingRequestInFlight = false

        if let error {
            // "Advertising has already started" reports the state we asked for,
            // so it takes the success path — surfacing it would replace a
            // working "Advertising" status with a failure no one can act on.
            guard (error as? CBError)?.code == .alreadyAdvertising else {
                advertisingCancelledInFlight = false
                Log.bluetooth.error("BLE: Advertising failed: \(error.localizedDescription)")
                delegate?.peripheralDidFail(.advertisingFailed(error.localizedDescription))
                return
            }
            Log.bluetooth.info("BLE: Advertising was already running — adopting it")
        }

        // stopAdvertisingOnly() (or a mid-publish subscription) raced the
        // confirmation — honor the stop
        guard !advertisingCancelledInFlight, lifecycle == .published else {
            advertisingCancelledInFlight = false
            if lifecycle != .advertising {
                peripheral.stopAdvertising()
            }
            return
        }
        lifecycle = .advertising
        Log.bluetooth.info("BLE: Advertising started as '\(self.localName, privacy: .public)'")
        delegate?.peripheralDidStartAdvertising()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard lifecycle == .publishing else {
            Log.bluetooth.warning("BLE: didAdd \(service.uuid.uuidString, privacy: .public) outside publishing — ignored")
            return
        }

        if let error {
            if service.uuid == Self.warmupServiceUUID {
                Log.bluetooth.info("BLE: Warm-up service add failed (expected): \(error.localizedDescription)")
            } else {
                abortPublishing(reason: "\(service.uuid.uuidString): \(error.localizedDescription)")
                return
            }
        } else {
            Log.bluetooth.info("BLE: Service added successfully: \(service.uuid.uuidString, privacy: .public)")
        }

        if pendingServiceQueue.isEmpty {
            publishCompleted()
        } else {
            scheduleNextServiceAdd(generation: setupGeneration)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        Log.bluetooth.info("BLE: Central \(central.identifier.uuidString, privacy: .public) subscribed to \(characteristic.uuid.uuidString, privacy: .public)")

        let centralID = central.identifier
        var session = sessions[centralID] ?? CentralSession(central: central)
        let charID = ObjectIdentifier(characteristic)
        let wasConnected = session.isConnected

        session.subscriptions.insert(charID)
        if isInputReport(characteristic) {
            session.inputSubscriptions.insert(charID)
        }
        sessions[centralID] = session

        guard !wasConnected, session.isConnected else { return }

        // Stop advertising once a central can actually receive input — saves
        // power and avoids inviting a second host mid-session
        wantsAdvertising = false
        if advertisingRequestInFlight {
            advertisingCancelledInFlight = true
        }
        if lifecycle == .advertising {
            peripheralManager.stopAdvertising()
            lifecycle = .published
            Log.bluetooth.info("BLE: Stopped advertising (device connected)")
        }

        delegate?.peripheralDidConnect(central: central)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        Log.bluetooth.info("BLE: Central \(central.identifier.uuidString, privacy: .public) unsubscribed from \(characteristic.uuid.uuidString, privacy: .public)")

        let centralID = central.identifier
        guard var session = sessions[centralID] else { return }

        let charID = ObjectIdentifier(characteristic)
        let wasConnected = session.isConnected
        session.subscriptions.remove(charID)
        session.inputSubscriptions.remove(charID)

        if session.subscriptions.isEmpty {
            sessions.removeValue(forKey: centralID)
            pendingServiceChangedCentrals.removeAll { $0 == centralID }
        } else {
            sessions[centralID] = session
        }

        if wasConnected && !session.isConnected {
            if !hasConnectedCentral {
                pendingReports.removeAll()
            }
            delegate?.peripheralDidDisconnect(central: central)
        }
    }

    private func isInputReport(_ characteristic: CBCharacteristic) -> Bool {
        characteristic === inputReportCharacteristic
            || characteristic === consumerReportCharacteristic
            || characteristic === mouseReportCharacteristic
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let centralID = request.central.identifier.uuidString
        Log.bluetooth.info("BLE: Read from \(centralID, privacy: .public) char=\(request.characteristic.uuid.uuidString, privacy: .public) offset=\(request.offset, privacy: .public)")

        if request.characteristic === inputReportCharacteristic
            || request.characteristic === consumerReportCharacteristic
            || request.characteristic === mouseReportCharacteristic {
            // Return an empty report sized for the characteristic's report type
            // (payloads exclude the Report ID per HOGP)
            let size = request.characteristic === inputReportCharacteristic ? HIDReportMap.keyboardReportSize
                : request.characteristic === mouseReportCharacteristic ? reportMap.mouseReportSize
                : HIDReportMap.consumerReportSize
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
    /// Offset == length answers a final ATT Read Blob with a zero-length
    /// success, as the spec requires; only offset beyond that is an error.
    private func respond(to request: CBATTRequest, with data: Data, peripheral: CBPeripheralManager) {
        if request.offset > data.count {
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
                    nudgeStaleCentralIfNeeded(request.central)
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

    // MARK: - Service Changed

    /// A central writing HID Control Point believes HID setup is finished. If
    /// it still hasn't subscribed to any input report, its GATT cache is stale
    /// (it can't see our Report characteristics) — indicate Service Changed so
    /// it re-discovers, instead of leaving typing silently dead until the user
    /// does "Forget This Device".
    private func nudgeStaleCentralIfNeeded(_ central: CBCentral) {
        // Without our own Generic Attribute service there is nothing to
        // indicate on: the host's system-owned 2A05 is the only one, and it
        // isn't ours to send. Not a fault — see publishesGenericAttributeService.
        guard publishesGenericAttributeService else { return }

        let centralID = central.identifier
        guard let session = sessions[centralID],
              !session.isConnected,
              !session.serviceChangedDelivered else {
            return
        }
        guard let characteristic = serviceChangedCharacteristic,
              session.subscriptions.contains(ObjectIdentifier(characteristic)) else {
            Log.bluetooth.warning("BLE: Central looks stale but isn't subscribed to Service Changed — can't nudge")
            return
        }
        deliverServiceChanged(to: centralID)
    }

    /// Marks delivery only when updateValue actually accepted the indication;
    /// a bounce (full notify queue) is retried from peripheralManagerIsReady.
    private func deliverServiceChanged(to centralID: UUID) {
        guard let characteristic = serviceChangedCharacteristic,
              let session = sessions[centralID] else {
            return
        }

        // Service Changed value: [start_handle_lo, start_handle_hi, end_handle_lo, end_handle_hi]
        // 0x0010 to 0xFFFF = excludes GATT service handles (~0x0001-0x000F) — iOS
        // marks GATT invalid and ignores all future indications if the range includes it
        let data = Data([0x10, 0x00, 0xFF, 0xFF])
        let sent = peripheralManager.updateValue(data, for: characteristic, onSubscribedCentrals: [session.central])
        Log.bluetooth.info("BLE: Service Changed indication sent=\(sent, privacy: .public)")

        if sent {
            sessions[centralID]?.serviceChangedDelivered = true
            pendingServiceChangedCentrals.removeAll { $0 == centralID }
        } else if !pendingServiceChangedCentrals.contains(centralID) {
            pendingServiceChangedCentrals.append(centralID)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // Indications first: an undelivered Service Changed means a stale
        // central that's ignoring the reports queued behind it anyway
        for centralID in pendingServiceChangedCentrals {
            deliverServiceChanged(to: centralID)
        }

        while !pendingReports.isEmpty {
            let (data, characteristic) = pendingReports.removeFirst()
            if !peripheral.updateValue(data, for: characteristic, onSubscribedCentrals: nil) {
                pendingReports.insert((data, characteristic), at: 0)
                break
            }
        }

        if pendingReports.isEmpty {
            delegate?.peripheralIsReadyToSend()
        }
    }
}
