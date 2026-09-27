import XCTest
import CoreBluetooth
@testable import Clak

final class BLEHIDPeripheralManagerTests: XCTestCase {

    private var radio: FakePeripheralManager!
    private var clock: ManualScheduler!
    private var delegate: RecordingPeripheralDelegate!
    private var peripheral: BLEHIDPeripheralManager!
    private let phone = HIDCentral(id: UUID())

    private final class FixedBattery: BatteryLevelSource {
        var level: UInt8 = 80
        var onChange: ((UInt8) -> Void)?
    }

    private func makePeripheral(lowLatency: Bool = false, battery: BatteryLevelSource? = nil) {
        radio = FakePeripheralManager()
        clock = ManualScheduler()
        delegate = RecordingPeripheralDelegate()
        peripheral = BLEHIDPeripheralManager(batteryLevelSource: battery,
                                             requestsLowLatency: lowLatency,
                                             scheduler: clock.scheduler,
                                             makePeripheralManager: { [radio] _ in radio! })
        peripheral.delegate = delegate
        peripheral.handle(state: .poweredOn)
    }

    override func setUp() {
        super.setUp()
        makePeripheral()
    }

    /// Runs the service-add chain to completion, confirming each add.
    private func publish(file: StaticString = #filePath, line: UInt = #line) {
        peripheral.startAdvertising()
        for _ in 0..<20 where !peripheral.areServicesPublished {
            clock.advance(by: 0.5)
            radio.confirmAdds(to: peripheral)
        }
        XCTAssertTrue(peripheral.areServicesPublished, file: file, line: line)
    }

    private func connect(_ central: HIDCentral) throws {
        let keyboard = try XCTUnwrap(radio.inputReport(id: 0x01))
        peripheral.handleSubscribe(central, central: nil, to: keyboard)
    }

    // MARK: - Radio loss

    func testRadioResetReportsEveryConnectedCentralAsDisconnected() throws {
        publish()
        try connect(phone)
        let other = HIDCentral(id: UUID())
        try connect(other)
        XCTAssertTrue(peripheral.isConnected)

        peripheral.handle(state: .resetting)

        XCTAssertFalse(peripheral.isConnected)
        XCTAssertFalse(peripheral.hasCentral)
        let disconnected = delegate.events.compactMap { event -> UUID? in
            if case .disconnected(let id) = event { return id } else { return nil }
        }
        XCTAssertEqual(Set(disconnected), [phone.id, other.id])
        XCTAssertEqual(disconnected.count, 2)
    }

    func testPowerOffReportsDisconnectBeforeFailure() throws {
        publish()
        try connect(phone)
        radio.state = .poweredOff
        peripheral.handle(state: .poweredOff)
        XCTAssertEqual(Array(delegate.events.suffix(2)), [.disconnected(phone.id), .failed(.poweredOff)])
    }

    func testRadioLossWithoutCentralsReportsNoDisconnect() {
        publish()
        peripheral.handle(state: .unknown)
        XCTAssertFalse(delegate.events.contains { if case .disconnected = $0 { return true } else { return false } })
    }

    func testUnsubscribeReportsDisconnect() throws {
        publish()
        try connect(phone)
        peripheral.handleUnsubscribe(phone.id, from: try XCTUnwrap(radio.inputReport(id: 0x01)))
        XCTAssertEqual(delegate.events.last, .disconnected(phone.id))
        XCTAssertFalse(peripheral.isConnected)
    }

    // MARK: - Connection latency

    func testLowLatencyIsRequestedOnceWhenACentralFirstConnects() throws {
        makePeripheral(lowLatency: true)
        publish()
        try connect(phone)
        peripheral.handleSubscribe(phone, central: nil, to: try XCTUnwrap(radio.inputReport(id: 0x03)))
        XCTAssertEqual(radio.latencyRequests, [phone.id])
    }

    func testLowLatencyIsOffByDefault() throws {
        publish()
        try connect(phone)
        XCTAssertTrue(radio.latencyRequests.isEmpty)
    }

    // MARK: - Publishing watchdog

    func testMissingDidAddAbortsPublishingAndAllowsRetry() {
        peripheral.startAdvertising()
        clock.advance(by: 0.5)
        radio.confirmAdds(to: peripheral)         // warm-up
        clock.advance(by: 0.5)
        radio.confirmAdds(to: peripheral, except: BLEHIDPeripheralManager.GATT.genericAttributeService)
        clock.advance(by: BLEHIDPeripheralManager.serviceAddTimeout)

        guard case .failed(.serviceSetupFailed) = delegate.events.last else {
            return XCTFail("expected a service setup failure, got \(delegate.events)")
        }
        XCTAssertFalse(peripheral.areServicesPublished)

        let removesBefore = radio.removeAllCalls
        publish()
        XCTAssertGreaterThan(radio.removeAllCalls, removesBefore, "retry rebuilds the database")
    }

    func testStaleWatchdogCannotAbortANewerPublish() {
        peripheral.startAdvertising()
        clock.advance(by: 0.5)                   // warm-up add, never confirmed
        peripheral.republish()
        publish()
        clock.advance(by: BLEHIDPeripheralManager.serviceAddTimeout * 2)
        XCTAssertFalse(delegate.events.contains { if case .failed = $0 { return true } else { return false } })
        XCTAssertTrue(peripheral.areServicesPublished)
    }

    func testConfirmedAddsNeverTripTheWatchdog() {
        publish()
        clock.advance(by: 60)
        XCTAssertFalse(delegate.events.contains { if case .failed = $0 { return true } else { return false } })
    }

    // MARK: - Pending (pairing) centrals

    private func serviceChanged() throws -> CBMutableCharacteristic {
        let gatt = try XCTUnwrap(radio.added.last { $0.uuid == BLEHIDPeripheralManager.GATT.genericAttributeService })
        return try XCTUnwrap(gatt.characteristics?.first as? CBMutableCharacteristic)
    }

    func testCentralWithoutInputSubscriptionIsReportedPendingOnce() throws {
        publish()
        peripheral.handleSubscribe(phone, central: nil, to: try serviceChanged())
        peripheral.notePendingCentral(phone)
        XCTAssertEqual(delegate.events.filter { $0 == .pending(phone.id) }.count, 1)
        try connect(phone)
        XCTAssertEqual(delegate.events.last, .connected(phone.id))
    }

    func testConnectedCentralIsNeverPending() throws {
        publish()
        try connect(phone)
        peripheral.notePendingCentral(phone)
        XCTAssertFalse(delegate.events.contains(.pending(phone.id)))
    }

    func testCentralIsPendingAgainAfterItLeaves() throws {
        publish()
        peripheral.notePendingCentral(phone)
        try connect(phone)
        peripheral.handleUnsubscribe(phone.id, from: try XCTUnwrap(radio.inputReport(id: 0x01)))
        peripheral.notePendingCentral(phone)
        XCTAssertEqual(delegate.events.filter { $0 == .pending(phone.id) }.count, 2)
    }

    // MARK: - Stale didAdd

    private var failed: Bool {
        delegate.events.contains { if case .failed = $0 { return true } else { return false } }
    }

    func testLateDidAddFromThePreviousPublishDoesNotAdvanceTheNewChain() {
        peripheral.startAdvertising()
        clock.advance(by: 0.5)
        let staleWarmup = radio.added.last!
        peripheral.republish()
        clock.advance(by: 0.5)                   // new chain's warm-up in flight
        let addsBefore = radio.added.count

        peripheral.handleDidAdd(staleWarmup, error: nil)
        clock.advance(by: 0.5)
        XCTAssertEqual(radio.added.count, addsBefore, "a stale didAdd must not start another add")

        for _ in 0..<20 where !peripheral.areServicesPublished {
            radio.confirmAdds(to: peripheral)
            clock.advance(by: 0.5)
        }
        XCTAssertEqual(delegate.events.filter { $0 == .published }.count, 1)
        XCTAssertEqual(radio.advertisingStarts, 1)
        XCTAssertFalse(failed)
    }

    func testStaleDidAddDoesNotDisarmTheCurrentWatchdog() {
        peripheral.startAdvertising()
        clock.advance(by: 0.5)
        let staleWarmup = radio.added.last!
        peripheral.republish()
        clock.advance(by: 0.5)                   // new warm-up, never confirmed
        peripheral.handleDidAdd(staleWarmup, error: nil)
        clock.advance(by: BLEHIDPeripheralManager.serviceAddTimeout)
        guard case .failed(.serviceSetupFailed) = delegate.events.last else {
            return XCTFail("expected the watchdog to fire, got \(delegate.events)")
        }
    }

    // MARK: - Optional Battery service

    /// Runs the chain, answering the Battery add with `batteryError` or,
    /// when nil, never answering it.
    private func publishWithBattery(batteryError: Error?) {
        makePeripheral(battery: FixedBattery())
        peripheral.startAdvertising()
        for _ in 0..<20 where !peripheral.areServicesPublished && !failed {
            clock.advance(by: 0.5)
            if let battery = radio.unconfirmed.first(where: { $0.uuid == BLEHIDPeripheralManager.GATT.batteryService }) {
                radio.confirmAdds(to: peripheral, except: BLEHIDPeripheralManager.GATT.batteryService)
                if let batteryError {
                    peripheral.handleDidAdd(battery, error: batteryError)
                } else {
                    clock.advance(by: BLEHIDPeripheralManager.serviceAddTimeout)
                }
            } else {
                radio.confirmAdds(to: peripheral)
            }
        }
    }

    func testBatteryAddErrorPublishesWithoutBattery() {
        publishWithBattery(batteryError: NSError(domain: CBErrorDomain, code: CBError.Code.unknown.rawValue))
        XCTAssertTrue(radio.added.contains { $0.uuid == BLEHIDPeripheralManager.GATT.batteryService })
        XCTAssertFalse(failed, "\(delegate.events)")
        XCTAssertTrue(peripheral.areServicesPublished)
        XCTAssertEqual(delegate.events.filter { $0 == .published }.count, 1)
        XCTAssertEqual(radio.advertisingStarts, 1)
    }

    func testBatteryAddTimeoutPublishesWithoutBattery() {
        publishWithBattery(batteryError: nil)
        XCTAssertTrue(radio.added.contains { $0.uuid == BLEHIDPeripheralManager.GATT.batteryService })
        XCTAssertFalse(failed, "\(delegate.events)")
        XCTAssertTrue(peripheral.areServicesPublished)
        XCTAssertEqual(delegate.events.filter { $0 == .published }.count, 1)
        XCTAssertEqual(radio.advertisingStarts, 1)
    }

    func testHIDAddErrorStillAbortsPublishing() {
        makePeripheral(battery: FixedBattery())
        peripheral.startAdvertising()
        for _ in 0..<20 where !peripheral.areServicesPublished && !failed {
            clock.advance(by: 0.5)
            if let hid = radio.unconfirmed.first(where: { $0.uuid == BLEHIDPeripheralManager.GATT.hidService }) {
                peripheral.handleDidAdd(hid, error: NSError(domain: CBErrorDomain, code: CBError.Code.unknown.rawValue))
            } else {
                radio.confirmAdds(to: peripheral)
            }
        }
        guard case .failed(.serviceSetupFailed) = delegate.events.last else {
            return XCTFail("expected a setup failure, got \(delegate.events)")
        }
        XCTAssertFalse(peripheral.areServicesPublished)
    }

    // MARK: - Advertising intent

    func testStartAfterACancelledInFlightStartKeepsAdvertising() {
        publish()                                // start request now in flight
        XCTAssertEqual(radio.advertisingStarts, 1)
        peripheral.stopAdvertisingOnly()
        peripheral.startAdvertising()
        peripheral.handleDidStartAdvertising(error: nil)

        XCTAssertTrue(peripheral.isAdvertising)
        XCTAssertEqual(radio.advertisingStops, 0)
        XCTAssertEqual(delegate.events.last, .startedAdvertising)
    }

    func testCancelledInFlightStartIsStillHonoured() {
        publish()
        peripheral.stopAdvertisingOnly()
        peripheral.handleDidStartAdvertising(error: nil)
        XCTAssertFalse(peripheral.isAdvertising)
        XCTAssertEqual(radio.advertisingStops, 1)
    }
}
