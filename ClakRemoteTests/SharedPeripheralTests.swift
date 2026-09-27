import XCTest
import CoreBluetooth
@testable import ClakRemote

/// The shared peripheral's lifecycle, compiled for iOS with Clak Remote's
/// options: radio loss must surface as a disconnect, the publishing watchdog
/// must fire, and the Mac-only low-latency request must stay off.
final class SharedPeripheralTests: XCTestCase {

    private final class Radio: PeripheralManaging {
        var state: CBManagerState = .poweredOn
        var added: [CBMutableService] = []
        var unconfirmed: [CBMutableService] = []
        var latencyRequests: [UUID] = []
        func add(_ service: CBMutableService) { added.append(service); unconfirmed.append(service) }
        func remove(_ service: CBMutableService) {}
        func removeAllServices() { unconfirmed.removeAll() }
        func startAdvertising(_ advertisementData: [String: Any]?) {}
        func stopAdvertising() {}
        func updateValue(_ value: Data, for characteristic: CBMutableCharacteristic,
                         onSubscribedCentrals centrals: [CBCentral]?) -> Bool { true }
        func requestLowConnectionLatency(for centralID: UUID, central: CBCentral?) { latencyRequests.append(centralID) }
    }

    private final class Recorder: BLEHIDPeripheralDelegate {
        var disconnected: [UUID] = []
        var failures: [BLEHIDPeripheralManager.Failure] = []
        func peripheralDidStartAdvertising() {}
        func peripheralDidStopAdvertising() {}
        func peripheralDidConnect(central: HIDCentral) {}
        func peripheralDidDisconnect(central: HIDCentral) { disconnected.append(central.id) }
        func peripheralDidFail(_ failure: BLEHIDPeripheralManager.Failure) { failures.append(failure) }
        func peripheralDidPowerOn() {}
        func peripheralDidReceiveLEDState(_ ledByte: UInt8) {}
    }

    private var pending: [(due: TimeInterval, work: DispatchWorkItem)] = []
    private var now: TimeInterval = 0
    private let radio = Radio()
    private let recorder = Recorder()
    private var peripheral: BLEHIDPeripheralManager!

    override func setUp() {
        super.setUp()
        let scheduler = DelayScheduler { [unowned self] delay, work in self.pending.append((self.now + delay, work)) }
        // Clak Remote's configuration, plus the test seams
        peripheral = BLEHIDPeripheralManager(localName: "Clak Remote",
                                             includeHorizontalScroll: true,
                                             highResolutionScroll: true,
                                             publishesGenericAttributeService: false,
                                             scheduler: scheduler,
                                             makePeripheralManager: { [radio] _ in radio })
        peripheral.delegate = recorder
        peripheral.handle(state: .poweredOn)
    }

    private func advance(by interval: TimeInterval) {
        let target = now + interval
        while let index = pending.indices.filter({ pending[$0].due <= target }).min(by: { pending[$0].due < pending[$1].due }) {
            let item = pending.remove(at: index)
            now = item.due
            if !item.work.isCancelled { item.work.perform() }
        }
        now = target
    }

    private func publish() {
        peripheral.startAdvertising()
        for _ in 0..<20 where !peripheral.areServicesPublished {
            advance(by: 0.5)
            let confirming = radio.unconfirmed
            radio.unconfirmed.removeAll()
            confirming.forEach { peripheral.handleDidAdd($0, error: nil) }
        }
    }

    private func keyboardInput() throws -> CBMutableCharacteristic {
        let hid = try XCTUnwrap(radio.added.last { $0.uuid == BLEHIDPeripheralManager.GATT.hidService })
        return try XCTUnwrap(hid.characteristics?.compactMap { $0 as? CBMutableCharacteristic }.first {
            $0.descriptors?.contains { ($0.value as? Data) == Data([0x01, 0x01]) } == true
        })
    }

    func testRadioResetReportsDisconnect() throws {
        publish()
        XCTAssertTrue(peripheral.areServicesPublished)
        let mac = HIDCentral(id: UUID())
        peripheral.handleSubscribe(mac, central: nil, to: try keyboardInput())
        XCTAssertTrue(peripheral.isConnected)

        peripheral.handle(state: .resetting)

        XCTAssertEqual(recorder.disconnected, [mac.id])
        XCTAssertFalse(peripheral.isConnected)
    }

    func testLowLatencyStaysOffForTheRemote() throws {
        publish()
        peripheral.handleSubscribe(HIDCentral(id: UUID()), central: nil, to: try keyboardInput())
        XCTAssertTrue(radio.latencyRequests.isEmpty)
    }

    func testPublishingWatchdogFires() {
        peripheral.startAdvertising()
        advance(by: 0.5)   // warm-up added, never confirmed
        advance(by: BLEHIDPeripheralManager.serviceAddTimeout)
        guard case .serviceSetupFailed = recorder.failures.last else {
            return XCTFail("expected a setup failure, got \(recorder.failures)")
        }
        XCTAssertFalse(peripheral.areServicesPublished)
    }

    func testNudgeDidAddAfterARepublishIsNotAPublishStep() {
        peripheral.databaseNudge = .trailingEmpty
        publish()
        XCTAssertTrue(peripheral.nudgeDatabaseChange(reason: "test"))
        let nudge = radio.added.last!

        peripheral.republish()
        advance(by: 0.5)                          // new chain's warm-up in flight
        let addsBefore = radio.added.count
        peripheral.handleDidAdd(nudge, error: nil)
        advance(by: 0.5)
        XCTAssertEqual(radio.added.count, addsBefore, "the nudge's didAdd must not start the next publish step")
    }

    func testLateDidAddFromThePreviousPublishIsIgnored() {
        peripheral.startAdvertising()
        advance(by: 0.5)
        let staleWarmup = radio.added.last!
        peripheral.republish()
        advance(by: 0.5)
        let addsBefore = radio.added.count
        peripheral.handleDidAdd(staleWarmup, error: nil)
        advance(by: 0.5)
        XCTAssertEqual(radio.added.count, addsBefore)
    }
}
