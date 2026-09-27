import Foundation
import CoreBluetooth

/// Supplies the Battery Level a host reads (0–100). Setting one on the
/// manager is what publishes the Battery Service.
protocol BatteryLevelSource: AnyObject {
    var level: UInt8 { get }
    var onChange: ((UInt8) -> Void)? { get set }
}

protocol BLEHIDPeripheralDelegate: AnyObject {
    func peripheralDidStartAdvertising()
    func peripheralDidStopAdvertising()
    func peripheralDidConnect(central: HIDCentral)
    func peripheralDidDisconnect(central: HIDCentral)
    func peripheralDidFail(_ failure: BLEHIDPeripheralManager.Failure)
    func peripheralDidPowerOn()
    func peripheralDidReceiveLEDState(_ ledByte: UInt8)
    /// The notification queue has drained — queued senders may push more reports.
    func peripheralIsReadyToSend()
    /// The GATT database is being rebuilt: nothing is published until
    /// peripheralDidPublishServices(). Fires on first start and every republish.
    func peripheralWillPublishServices()
    func peripheralDidPublishServices()
    /// A throwaway service was added or removed so the system GATT server
    /// indicates Service Changed. See `nudgeDatabaseChange`.
    func peripheralDidNudgeDatabase(reason: String, action: String)
    /// A central is talking to us without an input subscription yet — on a
    /// first connection that means pairing is in progress. Once per central
    /// until it connects or leaves.
    func peripheralDidSeePendingCentral(_ central: HIDCentral)
}

extension BLEHIDPeripheralDelegate {
    func peripheralIsReadyToSend() {}
    func peripheralWillPublishServices() {}
    func peripheralDidPublishServices() {}
    func peripheralDidNudgeDatabase(reason: String, action: String) {}
    func peripheralDidSeePendingCentral(_ central: HIDCentral) {}
}

/// How `nudgeDatabaseChange` alters the database. Which one a host honours
/// is measured on device; the losers get deleted.
enum DatabaseNudgeStyle: String {
    /// Add or remove an empty service after everything else.
    case trailingEmpty
    /// The same, with one read-only characteristic, in case an empty service
    /// doesn't count as a change.
    case trailingWithCharacteristic
    /// Remove or re-add the warm-up service, which sits before HID, so the
    /// changed range covers the HID handles.
    case warmupToggle
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

    private var peripheralManager: PeripheralManaging!
    private let scheduler: DelayScheduler

    /// Ask each newly connected central for the shortest connection
    /// interval, so a keystroke waits less for the next radio slot.
    let requestsLowLatency: Bool

    // Fires if a service add never gets its didAdd callback, so publishing
    // can't sit in .publishing forever
    private var publishWatchdog: DispatchWorkItem?
    static let serviceAddTimeout: TimeInterval = 5

    // The add the publish chain is waiting on. A didAdd for any other service
    // (a previous chain's, or a nudge's) must not advance the chain.
    private var serviceInFlight: CBMutableService?

    // Input Report characteristics, one per Report ID (keyboard / consumer / mouse)
    private var inputReportCharacteristic: CBMutableCharacteristic?
    private var consumerReportCharacteristic: CBMutableCharacteristic?
    private var mouseReportCharacteristic: CBMutableCharacteristic?
    // Report ID 4, only when the report map includes the absolute pointer
    private var absolutePointerCharacteristic: CBMutableCharacteristic?

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

    // Battery Level — dynamic, answered from batteryLevelSource
    private let batteryLevelSource: BatteryLevelSource?
    private var batteryLevelCharacteristic: CBMutableCharacteristic?
    private var pendingBatteryNotify = false

    // MARK: - Per-central sessions

    /// Everything we know about one central. "Connected" deliberately means
    /// "subscribed to at least one input report" — a central that only
    /// subscribed to Service Changed (2A05) cannot receive keystrokes, and
    /// reporting it as connected would silently swallow every report.
    private struct CentralSession {
        let info: HIDCentral
        /// Nil only when driven by tests, which can't construct a CBCentral.
        let central: CBCentral?
        var targets: [CBCentral] { central.map { [$0] } ?? [] }
        var subscriptions: Set<ObjectIdentifier> = []
        var inputSubscriptions: Set<ObjectIdentifier> = []
        var serviceChangedDelivered = false
        var isConnected: Bool { !inputSubscriptions.isEmpty }
    }

    private var sessions: [UUID: CentralSession] = [:]

    // Centrals already reported through peripheralDidSeePendingCentral
    private var pendingCentrals: Set<UUID> = []

    private var hasConnectedCentral: Bool {
        sessions.values.contains { $0.isConnected }
    }

    // Centrals whose Service Changed indication bounced off a full notify
    // queue — retried from peripheralManagerIsReady
    private var pendingServiceChangedCentrals: [UUID] = []

    // FIFO of reports awaiting notification-queue space (updateValue returned false).
    // All access happens on the main queue (CBPeripheralManager's queue).
    private var pendingReports = PendingReportQueue<CBMutableCharacteristic>(capacity: 64)

    // Zeroed reports owed to a central that just subscribed, retried when the
    // notify queue frees up. Keyed by central, then characteristic.
    private var pendingBaselines: [UUID: Set<ObjectIdentifier>] = [:]

    // Centrals whose last HID Control Point write was Suspend. Tracked apart
    // from sessions because iOS writes the Control Point before subscribing.
    private var suspendedCentrals: Set<UUID> = []

    // MARK: - Database nudge

    /// Where the host OS owns 0x1801 (iOS), any change to the database makes
    /// the system GATT server indicate Service Changed on our behalf. Nil
    /// disables it, as on macOS, where our own Service Changed does the job.
    var databaseNudge: DatabaseNudgeStyle?

    private static let nudgeServiceUUID = CBUUID(string: "C1A4C0DE-0000-4E00-9000-000000000001")
    private static let nudgeCharacteristicUUID = CBUUID(string: "C1A4C0DE-0000-4E00-9000-000000000002")

    private var warmupService: CBMutableService?
    private var nudgeService: CBMutableService?
    private var pendingNudgeService: CBMutableService?
    private var pendingNudgeReason = ""
    private var nudgeGeneration = 0
    // Once per central per publish, so a slow host isn't nudged repeatedly
    private var nudgedCentrals: Set<UUID> = []
    private var activityDebounce: [UUID: DispatchWorkItem] = [:]
    private(set) var nudgeCount = 0

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

    /// Whether a central can actually receive input right now. The authority
    /// on connectedness — a cached flag in a client can outlive the link.
    var isConnected: Bool { hasConnectedCentral }

    /// A central is present but may still be discovering or pairing. Distinct
    /// from isConnected, which needs an input-report subscription.
    var hasCentral: Bool { !sessions.isEmpty }
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

    static let warmupServiceUUID = CBUUID(string: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")

    // MARK: - GATT UUIDs (128-bit form to bypass CoreBluetooth restriction)

    enum GATT {
        // Service UUIDs — MUST use full 128-bit form
        static let hidService = CBUUID(string: "00001812-0000-1000-8000-00805F9B34FB")
        static let deviceInfoService = CBUUID(string: "0000180A-0000-1000-8000-00805F9B34FB")
        static let batteryService = CBUUID(string: "0000180F-0000-1000-8000-00805F9B34FB")
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
        static let batteryLevel = CBUUID(string: "2A19")
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
    ///   - batteryLevelSource: publishes a Battery Service (HOGP requires one)
    ///     answered from this source. Leave nil where the host OS already
    ///     publishes its own, as iOS does in the phone's shared GATT database.
    init(localName: String = Constants.appName,
         includeHorizontalScroll: Bool = false,
         highResolutionScroll: Bool = false,
         restoreIdentifier: String? = nil,
         publishesGenericAttributeService: Bool = true,
         batteryLevelSource: BatteryLevelSource? = nil,
         includeAbsolutePointer: Bool = false,
         requestsLowLatency: Bool = false,
         scheduler: DelayScheduler = .main,
         makePeripheralManager: ((CBPeripheralManagerDelegate) -> PeripheralManaging)? = nil) {
        self.localName = localName
        self.reportMap = HIDReportMap(includeHorizontalScroll: includeHorizontalScroll,
                                      highResolutionScroll: highResolutionScroll,
                                      includeAbsolutePointer: includeAbsolutePointer)
        self.publishesGenericAttributeService = publishesGenericAttributeService
        self.batteryLevelSource = batteryLevelSource
        self.requestsLowLatency = requestsLowLatency
        self.scheduler = scheduler
        super.init()

        batteryLevelSource?.onChange = { [weak self] level in
            self?.notifyBatteryLevel(level)
        }

        if let makePeripheralManager {
            peripheralManager = makePeripheralManager(self)
            return
        }

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
        serviceInFlight = nil
        wantsAdvertising = false
        advertisingRequestInFlight = false
        advertisingCancelledInFlight = false

        if lifecycle == .advertising {
            peripheralManager.stopAdvertising()
        }

        peripheralManager.removeAllServices()
        resetNudgeState()
        sessions.removeAll()
        pendingServiceChangedCentrals.removeAll()
        pendingBaselines.removeAll()
        suspendedCentrals.removeAll()
        pendingCentrals.removeAll()
        inputReportCharacteristic = nil
        consumerReportCharacteristic = nil
        mouseReportCharacteristic = nil
        absolutePointerCharacteristic = nil
        outputReportCharacteristic = nil
        protocolModeCharacteristic = nil
        serviceChangedCharacteristic = nil
        batteryLevelCharacteristic = nil
        pendingBatteryNotify = false
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

    /// Send an absolute pointer report: X and Y run 0...absolutePointerMax
    /// across the whole screen. Only when the map includes the absolute
    /// pointer and the host subscribed to it (a host on an older cached map
    /// never does).
    @discardableResult
    func sendAbsolutePointerReport(buttons: UInt8, x: UInt16, y: UInt16) -> Bool {
        guard let characteristic = absolutePointerCharacteristic,
              hasSubscriber(to: characteristic) else {
            return false
        }
        let x = min(x, HIDReportMap.absolutePointerMax), y = min(y, HIDReportMap.absolutePointerMax)
        let bytes: [UInt8] = [buttons, UInt8(x & 0xFF), UInt8(x >> 8), UInt8(y & 0xFF), UInt8(y >> 8), 0]
        return sendReport(Data(bytes), on: characteristic)
    }

    /// Whether a host picked up the absolute pointer from the current map.
    var hostSubscribedToAbsolutePointer: Bool {
        absolutePointerCharacteristic.map(hasSubscriber(to:)) ?? false
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
        let outcome = pendingReports.enqueue(data, on: characteristic, kind: reportKind(of: characteristic))
        if case .collapsed(let dropped) = outcome {
            Log.bluetooth.warning("BLE: Pending report queue full — collapsed to latest state, \(dropped, privacy: .public) superseded")
        }
    }

    private func reportKind(of characteristic: CBCharacteristic) -> PendingReportQueue<CBMutableCharacteristic>.Kind {
        if characteristic === inputReportCharacteristic { return .keyboard }
        if characteristic === consumerReportCharacteristic { return .consumer }
        if characteristic === mouseReportCharacteristic { return .mouse }
        if characteristic === absolutePointerCharacteristic { return .absolutePointer }
        return .other
    }

    /// An all-zero report of the right size, for reads and for the baseline
    /// sent on subscribe. Payloads exclude the Report ID per HOGP.
    private func zeroReport(for characteristic: CBCharacteristic) -> Data? {
        let size: Int
        switch reportKind(of: characteristic) {
        case .keyboard: size = HIDReportMap.keyboardReportSize
        case .consumer: size = HIDReportMap.consumerReportSize
        case .mouse: size = reportMap.mouseReportSize
        case .absolutePointer: size = HIDReportMap.absolutePointerReportSize
        case .other: return nil
        }
        return Data(count: size)
    }

    // MARK: - Publish GATT Services

    private var pendingServiceQueue: [(String, CBMutableService)] = []

    private func publishServices() {
        lifecycle = .publishing
        setupGeneration += 1
        let generation = setupGeneration
        delegate?.peripheralWillPublishServices()

        peripheralManager.removeAllServices()
        resetNudgeState()

        let (services, parts) = Self.makeServiceList(
            reportMap: reportMap,
            publishesGenericAttributeService: publishesGenericAttributeService,
            publishesBatteryService: batteryLevelSource != nil)
        serviceChangedCharacteristic = parts.serviceChanged
        batteryLevelCharacteristic = parts.batteryLevel
        pendingBatteryNotify = false
        warmupService = services.first { $0.1.uuid == Self.warmupServiceUUID }?.1
        protocolModeCharacteristic = parts.hid.protocolMode
        inputReportCharacteristic = parts.hid.keyboardInput
        consumerReportCharacteristic = parts.hid.consumerInput
        mouseReportCharacteristic = parts.hid.mouseInput
        absolutePointerCharacteristic = parts.hid.absolutePointerInput
        outputReportCharacteristic = parts.hid.outputReport

        pendingServiceQueue = services
        serviceInFlight = nil

        // Delay after removeAllServices
        scheduleNextServiceAdd(generation: generation)
    }

    private func scheduleNextServiceAdd(generation: Int) {
        scheduler.schedule(Self.serviceAddSettleDelay, DispatchWorkItem { [weak self] in
            guard let self, self.setupGeneration == generation else { return }
            self.addNextService(generation: generation)
        })
    }

    /// Generation-guarded: an abort, republish or radio loss bumps the
    /// generation, so a watchdog from an older chain can't abort a newer one.
    private func armPublishWatchdog(generation: Int, serviceName: String) {
        publishWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.setupGeneration == generation, self.lifecycle == .publishing else { return }
            let reason = "\(serviceName): no didAdd within \(Int(Self.serviceAddTimeout))s"
            if let service = self.serviceInFlight, Self.isOptional(service) {
                self.skipOptionalService(service, reason: reason)
            } else {
                self.abortPublishing(reason: reason)
            }
        }
        publishWatchdog = watchdog
        scheduler.schedule(Self.serviceAddTimeout, watchdog)
    }

    private func addNextService(generation: Int) {
        guard setupGeneration == generation, lifecycle == .publishing,
              !pendingServiceQueue.isEmpty else {
            return
        }

        let (name, service) = pendingServiceQueue.removeFirst()
        Log.bluetooth.info("BLE: Adding \(name) service")

        // Both set before add(): a didAdd may arrive before add() returns
        serviceInFlight = service
        armPublishWatchdog(generation: generation, serviceName: name)
        let exception = ObjCExceptionCatcher.`try` {
            self.peripheralManager.add(service)
        }
        if let exception {
            publishWatchdog?.cancel()
            publishWatchdog = nil
            serviceInFlight = nil
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
        serviceInFlight = nil
        wantsAdvertising = false
        lifecycle = .idle
        delegate?.peripheralDidFail(.serviceSetupFailed(reason))
    }

    /// Battery is the one service HID works without: a host that can't see
    /// it still types, so losing it must not cost the whole publish.
    private static func isOptional(_ service: CBService) -> Bool {
        service.uuid == GATT.batteryService
    }

    private func skipOptionalService(_ service: CBService, reason: String) {
        Log.bluetooth.error("BLE: Publishing without \(service.uuid.uuidString, privacy: .public) — \(reason, privacy: .public)")
        publishWatchdog?.cancel()
        publishWatchdog = nil
        serviceInFlight = nil
        if service.uuid == GATT.batteryService {
            batteryLevelCharacteristic = nil
            pendingBatteryNotify = false
        }
        continuePublishing()
    }

    private func continuePublishing() {
        if pendingServiceQueue.isEmpty {
            publishCompleted()
        } else {
            scheduleNextServiceAdd(generation: setupGeneration)
        }
    }

    private func publishCompleted() {
        lifecycle = .published
        Log.bluetooth.info("BLE: All services published")
        delegate?.peripheralDidPublishServices()

        if hasConnectedCentral {
            // A central subscribed mid-publish (bonded reconnect) — advertising
            // now would invite a second host while one is already connected
            wantsAdvertising = false
        } else if wantsAdvertising {
            wantsAdvertising = false
            beginAdvertising()
        }
    }

    /// The published services, in add order. Order sets the ATT handles a
    /// bonded host has cached, so GATTLayoutTests pins it.
    static func makeServiceList(reportMap: HIDReportMap,
                                publishesGenericAttributeService: Bool,
                                publishesBatteryService: Bool = false) -> (services: [(String, CBMutableService)], parts: ServiceParts) {
        var services: [(String, CBMutableService)] = []

        // CBPeripheralManager once threw NSInternalInconsistencyException on
        // the first add() after init/removeAllServices. A disposable "warm-up"
        // service goes first so a throw lands on something that doesn't matter.
        let warmup = CBMutableService(type: warmupServiceUUID, primary: false)
        warmup.characteristics = []
        services.append(("_warmup", warmup))

        var serviceChanged: CBMutableCharacteristic?
        if publishesGenericAttributeService {
            let gatt = buildGenericAttributeService()
            serviceChanged = gatt.serviceChanged
            services.append(("GATT", gatt.service))
        }
        let hid = buildHIDService(reportMap: reportMap)
        services.append(("HID", hid.service))
        services.append(("DeviceInfo", buildDeviceInfoService()))

        // Last, so adding it leaves every earlier handle where bonded hosts
        // cached it
        var batteryLevel: CBMutableCharacteristic?
        if publishesBatteryService {
            let battery = buildBatteryService()
            batteryLevel = battery.level
            services.append(("Battery", battery.service))
        }

        return (services, ServiceParts(hid: hid, serviceChanged: serviceChanged, batteryLevel: batteryLevel))
    }

    struct HIDServiceParts {
        let service: CBMutableService
        let protocolMode: CBMutableCharacteristic
        let keyboardInput: CBMutableCharacteristic
        let consumerInput: CBMutableCharacteristic
        let mouseInput: CBMutableCharacteristic
        let outputReport: CBMutableCharacteristic
        let absolutePointerInput: CBMutableCharacteristic?
    }

    struct ServiceParts {
        let hid: HIDServiceParts
        let serviceChanged: CBMutableCharacteristic?
        let batteryLevel: CBMutableCharacteristic?
    }

    private static func buildGenericAttributeService() -> (service: CBMutableService, serviceChanged: CBMutableCharacteristic) {
        let service = CBMutableService(type: GATT.genericAttributeService, primary: true)
        // Service Changed characteristic: indicate-only, dynamic (value: nil)
        // When a bonded central subscribes to indications, we send the handle range
        // that changed to force service re-discovery.
        let serviceChanged = CBMutableCharacteristic(
            type: GATT.serviceChanged, properties: .indicate,
            value: nil, permissions: .readable
        )
        service.characteristics = [serviceChanged]
        return (service, serviceChanged)
    }

    private static func buildHIDService(reportMap: HIDReportMap) -> HIDServiceParts {
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
        chars.append(keyboardInput)

        let consumerInput = CBMutableCharacteristic(
            type: GATT.report, properties: [.read, .notify],
            value: nil, permissions: .readEncryptionRequired
        )
        addReportReference(to: consumerInput, reportID: 0x02, type: 0x01, label: "consumer input")
        chars.append(consumerInput)

        let mouseInput = CBMutableCharacteristic(
            type: GATT.report, properties: [.read, .notify],
            value: nil, permissions: .readEncryptionRequired
        )
        addReportReference(to: mouseInput, reportID: 0x03, type: 0x01, label: "mouse input")
        chars.append(mouseInput)

        // Output Report — for LED state (Caps Lock, etc.) written by the host.
        let outputReport = CBMutableCharacteristic(
            type: GATT.report,
            properties: [.read, .write, .writeWithoutResponse],
            value: nil,
            permissions: [.readEncryptionRequired, .writeEncryptionRequired]
        )
        addReportReference(to: outputReport, reportID: 0x01, type: 0x02, label: "LED output")
        chars.append(outputReport)

        // HID Control Point: suspend/resume
        // HOGP spec requires encryption for HID Control Point writes
        chars.append(CBMutableCharacteristic(
            type: GATT.hidControlPoint, properties: .writeWithoutResponse,
            value: nil, permissions: .writeEncryptionRequired
        ))

        // Last, so every other characteristic keeps its handle
        var absolutePointerInput: CBMutableCharacteristic?
        if reportMap.includeAbsolutePointer {
            let absolute = CBMutableCharacteristic(
                type: GATT.report, properties: [.read, .notify],
                value: nil, permissions: .readEncryptionRequired
            )
            addReportReference(to: absolute, reportID: 0x04, type: 0x01, label: "absolute pointer input")
            chars.append(absolute)
            absolutePointerInput = absolute
        }

        service.characteristics = chars
        return HIDServiceParts(service: service, protocolMode: protocolMode,
                               keyboardInput: keyboardInput, consumerInput: consumerInput,
                               mouseInput: mouseInput, outputReport: outputReport,
                               absolutePointerInput: absolutePointerInput)
    }

    private static func addReportReference(to characteristic: CBMutableCharacteristic, reportID: UInt8, type: UInt8, label: String) {
        let exception = ObjCExceptionCatcher.`try` {
            let desc = CBMutableDescriptor(type: CBUUID(string: "2908"), value: Data([reportID, type]))
            characteristic.descriptors = (characteristic.descriptors ?? []) + [desc]
        }
        if let exception {
            Log.bluetooth.warning("BLE: Report Reference descriptor failed (\(label, privacy: .public)): \(exception.name.rawValue): \(exception.reason ?? "unknown")")
        }
    }

    /// Battery Level is dynamic (value nil): a cached value is only allowed
    /// on a read-only characteristic, and this one notifies. Encrypted to
    /// match the HID service, as HOGP recommends.
    private static func buildBatteryService() -> (service: CBMutableService, level: CBMutableCharacteristic) {
        let service = CBMutableService(type: GATT.batteryService, primary: true)
        let level = CBMutableCharacteristic(
            type: GATT.batteryLevel, properties: [.read, .notify],
            value: nil, permissions: .readEncryptionRequired
        )
        service.characteristics = [level]
        return (service, level)
    }

    private static func buildDeviceInfoService() -> CBMutableService {
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
        guard !advertisingRequestInFlight else {
            // The newest intent wins over a stop that raced the pending request
            advertisingCancelledInFlight = false
            return
        }
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
        // The links are gone with the radio, and no unsubscribe will say so
        let dropped = sessions.values.filter(\.isConnected).map(\.info)
        isPoweredOn = false
        resetNudgeState()
        setupGeneration += 1
        pendingServiceQueue.removeAll()
        serviceInFlight = nil
        lifecycle = .idle
        wantsAdvertising = false
        advertisingRequestInFlight = false
        advertisingCancelledInFlight = false
        sessions.removeAll()
        pendingServiceChangedCentrals.removeAll()
        pendingBaselines.removeAll()
        suspendedCentrals.removeAll()
        pendingCentrals.removeAll()
        pendingReports.removeAll()
        ledState = 0
        for central in dropped {
            delegate?.peripheralDidDisconnect(central: central)
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEHIDPeripheralManager: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        handle(state: peripheral.state)
    }

    func handle(state: CBManagerState) {
        switch state {
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
        handleDidStartAdvertising(error: error)
    }

    func handleDidStartAdvertising(error: Error?) {
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
                peripheralManager.stopAdvertising()
            }
            return
        }
        lifecycle = .advertising
        Log.bluetooth.info("BLE: Advertising started as '\(self.localName, privacy: .public)'")
        delegate?.peripheralDidStartAdvertising()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        handleDidAdd(service, error: error)
    }

    func handleDidAdd(_ service: CBService, error: Error?) {
        // A nudge adds after publishing finished, so it's handled before the
        // publishing guard below would discard it — and never touches the
        // publish watchdog
        if let pending = pendingNudgeService, service === pending {
            finishNudgeAdd(pending, error: error)
            return
        }

        guard lifecycle == .publishing, let inFlight = serviceInFlight, service === inFlight else {
            Log.bluetooth.warning("BLE: didAdd \(service.uuid.uuidString, privacy: .public) is not the add in flight — ignored")
            return
        }
        publishWatchdog?.cancel()
        publishWatchdog = nil
        serviceInFlight = nil

        if let error {
            let reason = "\(service.uuid.uuidString): \(error.localizedDescription)"
            if service.uuid == Self.warmupServiceUUID {
                Log.bluetooth.info("BLE: Warm-up service add failed (expected): \(error.localizedDescription)")
            } else if Self.isOptional(service) {
                skipOptionalService(service, reason: reason)
                return
            } else {
                abortPublishing(reason: reason)
                return
            }
        } else {
            Log.bluetooth.info("BLE: Service added successfully: \(service.uuid.uuidString, privacy: .public)")
        }

        continuePublishing()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        handleSubscribe(HIDCentral(id: central.identifier), central: central, to: characteristic)
    }

    func handleSubscribe(_ info: HIDCentral, central: CBCentral?, to characteristic: CBCharacteristic) {
        Log.bluetooth.info("BLE: Central \(info.id.uuidString, privacy: .public) subscribed to \(characteristic.uuid.uuidString, privacy: .public)")

        let centralID = info.id
        var session = sessions[centralID] ?? CentralSession(info: info, central: central)
        let charID = ObjectIdentifier(characteristic)
        let wasConnected = session.isConnected

        session.subscriptions.insert(charID)
        if isInputReport(characteristic) {
            session.inputSubscriptions.insert(charID)
        }
        sessions[centralID] = session

        // Some hosts hold off using a report until its first notification
        // arrives; a zeroed one also clears any state a previous link left.
        // Sent to this central only: broadcasting would release keys another
        // host is holding.
        if isInputReport(characteristic) {
            sendBaseline(on: characteristic, to: centralID)
        }

        if !session.isConnected {
            notePendingCentral(info)
        }
        guard !wasConnected, session.isConnected else { return }
        pendingCentrals.remove(centralID)

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

        if requestsLowLatency {
            peripheralManager.requestLowConnectionLatency(for: centralID, central: session.central)
        }

        delegate?.peripheralDidConnect(central: session.info)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        handleUnsubscribe(central.identifier, from: characteristic)
    }

    func handleUnsubscribe(_ centralID: UUID, from characteristic: CBCharacteristic) {
        Log.bluetooth.info("BLE: Central \(centralID.uuidString, privacy: .public) unsubscribed from \(characteristic.uuid.uuidString, privacy: .public)")

        guard var session = sessions[centralID] else { return }

        let charID = ObjectIdentifier(characteristic)
        let wasConnected = session.isConnected
        session.subscriptions.remove(charID)
        session.inputSubscriptions.remove(charID)

        pendingBaselines[centralID]?.remove(charID)
        if session.subscriptions.isEmpty {
            sessions.removeValue(forKey: centralID)
            pendingServiceChangedCentrals.removeAll { $0 == centralID }
            pendingBaselines.removeValue(forKey: centralID)
            suspendedCentrals.remove(centralID)
        } else {
            sessions[centralID] = session
        }

        if session.subscriptions.isEmpty {
            pendingCentrals.remove(centralID)
        }
        if wasConnected && !session.isConnected {
            if !hasConnectedCentral {
                pendingReports.removeAll()
                // The next host starts from its own lock state
                ledState = 0
            }
            delegate?.peripheralDidDisconnect(central: session.info)
        }
    }

    /// Reports a central that is present but can't receive input yet.
    func notePendingCentral(_ central: HIDCentral) {
        guard sessions[central.id]?.isConnected != true,
              pendingCentrals.insert(central.id).inserted else { return }
        Log.bluetooth.info("BLE: Central \(central.id.uuidString, privacy: .public) present without input subscription")
        delegate?.peripheralDidSeePendingCentral(central)
    }

    private func isInputReport(_ characteristic: CBCharacteristic) -> Bool {
        characteristic === inputReportCharacteristic
            || characteristic === consumerReportCharacteristic
            || characteristic === mouseReportCharacteristic
            || (absolutePointerCharacteristic != nil && characteristic === absolutePointerCharacteristic)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        noteCentralActivity(request.central)
        notePendingCentral(HIDCentral(id: request.central.identifier))
        let centralID = request.central.identifier.uuidString
        Log.bluetooth.info("BLE: Read from \(centralID, privacy: .public) char=\(request.characteristic.uuid.uuidString, privacy: .public) offset=\(request.offset, privacy: .public)")

        if let zero = zeroReport(for: request.characteristic) {
            // Zeros rather than the last report sent: a host that reads on
            // connect must never see a key as still held
            respond(to: request, with: zero, peripheral: peripheral)
        } else if request.characteristic === outputReportCharacteristic {
            respond(to: request, with: Data([ledState]), peripheral: peripheral)
        } else if request.characteristic === protocolModeCharacteristic {
            respond(to: request, with: Data([currentProtocolMode]), peripheral: peripheral)
        } else if request.characteristic === batteryLevelCharacteristic, let source = batteryLevelSource {
            respond(to: request, with: Data([source.level]), peripheral: peripheral)
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
        if let central = requests.first?.central {
            noteCentralActivity(central)
            notePendingCentral(HIDCentral(id: central.identifier))
        }
        // CoreBluetooth treats a batch as one unit: validate everything first,
        // and on any failure answer with that error and apply nothing
        var commands: [(CBATTRequest, WriteCommand)] = []
        for request in requests {
            let centralID = request.central.identifier.uuidString
            let charUUID = request.characteristic.uuid.uuidString
            let dataHex = request.value?.map { String(format: "%02X", $0) }.joined(separator: " ") ?? "nil"
            Log.bluetooth.info("BLE: Write from \(centralID, privacy: .public) char=\(charUUID, privacy: .public) data=[\(dataHex, privacy: .public)]")

            if request.characteristic.uuid == GATT.hidControlPoint {
                // Any Control Point write says the host thinks setup is done,
                // valid value or not — the stale-cache check keys on that
                nudgeStaleCentralIfNeeded(request.central)
            }

            switch parseWrite(request) {
            case .success(let command):
                commands.append((request, command))
            case .failure(let error):
                Log.bluetooth.warning("BLE: Rejected write to \(charUUID, privacy: .public): \(error.code.rawValue, privacy: .public)")
                if let first = requests.first {
                    peripheral.respond(to: first, withResult: error.code)
                }
                return
            }
        }

        for (request, command) in commands {
            apply(command, from: request.central)
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    enum ControlPointCommand: Equatable {
        case suspend, exitSuspend
    }

    private enum WriteCommand {
        case controlPoint(ControlPointCommand)
        case led(UInt8)
        case protocolMode(UInt8)
        case ignored
    }

    private func parseWrite(_ request: CBATTRequest) -> Result<WriteCommand, CBATTError> {
        if request.characteristic.uuid == GATT.hidControlPoint {
            return Self.parseControlPoint(request.value, offset: request.offset).map { .controlPoint($0) }
        } else if request.characteristic === outputReportCharacteristic {
            guard request.offset == 0 else { return .failure(CBATTError(.invalidOffset)) }
            guard let led = request.value?.first else { return .failure(CBATTError(.invalidAttributeValueLength)) }
            return .success(.led(led))
        } else if request.characteristic === protocolModeCharacteristic {
            return Self.validateProtocolMode(request.value, offset: request.offset).map { .protocolMode($0) }
        }
        return .success(.ignored)
    }

    /// HID Control Point: one byte, 0 = Suspend, 1 = Exit Suspend.
    static func parseControlPoint(_ value: Data?, offset: Int) -> Result<ControlPointCommand, CBATTError> {
        singleByte(value, offset: offset).flatMap { byte in
            switch byte {
            case 0x00: .success(.suspend)
            case 0x01: .success(.exitSuspend)
            default: .failure(CBATTError(.requestNotSupported))
            }
        }
    }

    /// Protocol Mode: one byte, 0 = Boot, 1 = Report.
    static func validateProtocolMode(_ value: Data?, offset: Int) -> Result<UInt8, CBATTError> {
        singleByte(value, offset: offset).flatMap { $0 <= 0x01 ? .success($0) : .failure(CBATTError(.requestNotSupported)) }
    }

    private static func singleByte(_ value: Data?, offset: Int) -> Result<UInt8, CBATTError> {
        guard offset == 0 else { return .failure(CBATTError(.invalidOffset)) }
        guard let value, value.count == 1, let byte = value.first else {
            return .failure(CBATTError(.invalidAttributeValueLength))
        }
        return .success(byte)
    }

    private func apply(_ command: WriteCommand, from central: CBCentral) {
        switch command {
        case .controlPoint(let cmd):
            Log.bluetooth.info("BLE: HID Control Point \(cmd == .suspend ? "Suspend" : "Exit Suspend", privacy: .public)")
            setSuspended(cmd == .suspend, central: central.identifier)
        case .led(let led):
            ledState = led
            let capsOn = led & 0x02 != 0
            Log.bluetooth.info("BLE: LED state received: 0x\(String(format: "%02X", led), privacy: .public) (Caps=\(capsOn ? "ON" : "OFF", privacy: .public))")
            delegate?.peripheralDidReceiveLEDState(led)
        case .protocolMode(let mode):
            currentProtocolMode = mode
            Log.bluetooth.info("BLE: Protocol Mode set to \(mode, privacy: .public) (\(mode == 0 ? "Boot" : "Report", privacy: .public))")
        case .ignored:
            break
        }
    }

    /// Sending continues while suspended: iOS writes Suspend then Exit Suspend
    /// on every connect, and gating on it would leave the keyboard dead the
    /// one time an Exit Suspend goes missing. Once every connected host is
    /// asleep, though, a backlog is only stale keystrokes that would replay on
    /// wake — keep just the final state.
    private func setSuspended(_ suspended: Bool, central: UUID) {
        if suspended {
            suspendedCentrals.insert(central)
        } else {
            suspendedCentrals.remove(central)
        }
        let connected = sessions.filter { $0.value.isConnected }.map(\.key)
        if suspended, !connected.isEmpty, connected.allSatisfy(suspendedCentrals.contains), !pendingReports.isEmpty {
            let before = pendingReports.count
            pendingReports.collapseToLatestState()
            Log.bluetooth.info("BLE: All hosts suspended — collapsed \(before, privacy: .public) queued reports to \(self.pendingReports.count, privacy: .public)")
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
        guard publishesGenericAttributeService else {
            let id = central.identifier
            if sessions[id]?.isConnected != true, !nudgedCentrals.contains(id),
               nudgeDatabaseChange(reason: "control-point-without-input-subscription") {
                nudgedCentrals.insert(id)
            }
            return
        }

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
        let sent = peripheralManager.updateValue(data, for: characteristic, onSubscribedCentrals: session.targets)
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

        retryPendingBaselines()
        if pendingBatteryNotify, let level = batteryLevelSource?.level {
            notifyBatteryLevel(level)
        }

        while let next = pendingReports.first {
            guard peripheral.updateValue(next.data, for: next.target, onSubscribedCentrals: nil) else { break }
            pendingReports.removeFirst()
        }

        if pendingReports.isEmpty {
            delegate?.peripheralIsReadyToSend()
        }
    }

    // MARK: - Baseline reports

    private func sendBaseline(on characteristic: CBCharacteristic, to centralID: UUID) {
        guard let session = sessions[centralID],
              let target = characteristic as? CBMutableCharacteristic,
              let zero = zeroReport(for: characteristic) else { return }
        let charID = ObjectIdentifier(characteristic)
        if peripheralManager.updateValue(zero, for: target, onSubscribedCentrals: session.targets) {
            pendingBaselines[centralID]?.remove(charID)
        } else {
            pendingBaselines[centralID, default: []].insert(charID)
        }
    }

    private func retryPendingBaselines() {
        let inputs = [inputReportCharacteristic, consumerReportCharacteristic,
                      mouseReportCharacteristic, absolutePointerCharacteristic].compactMap { $0 }
        for (centralID, charIDs) in pendingBaselines {
            for characteristic in inputs where charIDs.contains(ObjectIdentifier(characteristic)) {
                sendBaseline(on: characteristic, to: centralID)
            }
            if pendingBaselines[centralID]?.isEmpty == true {
                pendingBaselines.removeValue(forKey: centralID)
            }
        }
    }

    // MARK: - Battery

    /// Kept out of the report queue so collapsing it can never drop a level.
    private func notifyBatteryLevel(_ level: UInt8) {
        guard let characteristic = batteryLevelCharacteristic,
              sessions.values.contains(where: { $0.subscriptions.contains(ObjectIdentifier(characteristic)) }) else {
            pendingBatteryNotify = false
            return
        }
        pendingBatteryNotify = !peripheralManager.updateValue(Data([level]), for: characteristic, onSubscribedCentrals: nil)
    }

    // MARK: - Database nudge

    /// Changes the database without moving the HID handles, so the system
    /// GATT server (which owns 0x1801 on iOS) indicates Service Changed to
    /// bonded hosts. A cheaper nudge than republish(), which rebuilds
    /// everything and moves every handle.
    /// - Parameter force: nudge even while a host is connected (testing only).
    /// - Returns: whether a change was made or started.
    @discardableResult
    func nudgeDatabaseChange(reason: String, force: Bool = false) -> Bool {
        guard let style = databaseNudge, isPoweredOn,
              lifecycle == .published || lifecycle == .advertising,
              pendingNudgeService == nil,
              force || !hasConnectedCentral else {
            return false
        }

        let present = style == .warmupToggle ? warmupService : nudgeService
        if let present {
            // remove() has no callback: the change is made once it returns
            let exception = ObjCExceptionCatcher.`try` { self.peripheralManager.remove(present) }
            if let exception {
                Log.bluetooth.error("BLE: DB nudge remove failed: \(exception.name.rawValue)")
                return false
            }
            if style == .warmupToggle { warmupService = nil } else { nudgeService = nil }
            recordNudge(action: "removed \(style.rawValue)", reason: reason)
            return true
        }

        // A fresh instance each time: re-adding a service object throws
        let service = CBMutableService(
            type: style == .warmupToggle ? Self.warmupServiceUUID : Self.nudgeServiceUUID,
            primary: false)
        service.characteristics = style == .trailingWithCharacteristic
            ? [CBMutableCharacteristic(type: Self.nudgeCharacteristicUUID, properties: .read,
                                       value: Data([0]), permissions: .readable)]
            : []
        pendingNudgeService = service
        pendingNudgeReason = reason
        nudgeGeneration = setupGeneration
        let exception = ObjCExceptionCatcher.`try` { self.peripheralManager.add(service) }
        if let exception {
            pendingNudgeService = nil
            Log.bluetooth.error("BLE: DB nudge add failed: \(exception.name.rawValue)")
            return false
        }
        return true
    }

    private func finishNudgeAdd(_ service: CBMutableService, error: Error?) {
        pendingNudgeService = nil
        guard nudgeGeneration == setupGeneration else { return } // a republish wiped it
        if let error {
            Log.bluetooth.error("BLE: DB nudge add failed: \(error.localizedDescription)")
            return
        }
        if service.uuid == Self.warmupServiceUUID {
            warmupService = service
        } else {
            nudgeService = service
        }
        recordNudge(action: "added \(databaseNudge?.rawValue ?? "?")", reason: pendingNudgeReason)
    }

    private func recordNudge(action: String, reason: String) {
        nudgeCount += 1
        Log.bluetooth.notice("BLE: DB nudge \(action, privacy: .public) (\(reason, privacy: .public)) #\(self.nudgeCount, privacy: .public)")
        delegate?.peripheralDidNudgeDatabase(reason: reason, action: action)
    }

    /// A host that reads or writes and then goes quiet for 2 s without
    /// subscribing to input has probably given up on a stale copy of us.
    /// The window runs from its last request, so a host still discovering
    /// or pairing isn't interrupted.
    private func noteCentralActivity(_ central: CBCentral) {
        guard databaseNudge != nil, !publishesGenericAttributeService else { return }
        let id = central.identifier
        activityDebounce[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.activityDebounce[id] = nil
            guard self.sessions[id]?.isConnected != true, !self.nudgedCentrals.contains(id) else { return }
            if self.nudgeDatabaseChange(reason: "quiet-2s-without-subscribe") {
                self.nudgedCentrals.insert(id)
            }
        }
        activityDebounce[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func resetNudgeState() {
        warmupService = nil
        nudgeService = nil
        pendingNudgeService = nil
        nudgedCentrals.removeAll()
        activityDebounce.values.forEach { $0.cancel() }
        activityDebounce.removeAll()
    }
}

// MARK: - Seams

/// A central as the delegate sees it: CBCentral can't be built outside
/// CoreBluetooth, so tests and clients work with this instead.
struct HIDCentral: Hashable {
    let id: UUID
    /// CoreBluetooth never names a central; set only where a name is known.
    var name: String?
}

/// Runs work after a delay; tests substitute a manual clock.
struct DelayScheduler {
    let schedule: (TimeInterval, DispatchWorkItem) -> Void

    static let main = DelayScheduler { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// The CBPeripheralManager calls BLEHIDPeripheralManager makes, so tests can
/// stand in for the radio.
protocol PeripheralManaging: AnyObject {
    var state: CBManagerState { get }
    func add(_ service: CBMutableService)
    func remove(_ service: CBMutableService)
    func removeAllServices()
    func startAdvertising(_ advertisementData: [String: Any]?)
    func stopAdvertising()
    func updateValue(_ value: Data, for characteristic: CBMutableCharacteristic,
                     onSubscribedCentrals centrals: [CBCentral]?) -> Bool
    func requestLowConnectionLatency(for centralID: UUID, central: CBCentral?)
}

extension CBPeripheralManager: PeripheralManaging {
    func requestLowConnectionLatency(for centralID: UUID, central: CBCentral?) {
        guard let central else { return }
        setDesiredConnectionLatency(.low, for: central)
        Log.bluetooth.info("BLE: Requested low connection latency for \(centralID.uuidString, privacy: .public)")
    }
}
