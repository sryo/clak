import Foundation
import CoreBluetooth
@testable import Clak

/// Stands in for CBPeripheralManager: records calls, confirms adds on demand.
final class FakePeripheralManager: PeripheralManaging {
    var state: CBManagerState = .poweredOn
    private(set) var added: [CBMutableService] = []
    private(set) var unconfirmed: [CBMutableService] = []
    private(set) var removeAllCalls = 0
    private(set) var advertisingStarts = 0
    private(set) var advertisingStops = 0
    private(set) var latencyRequests: [UUID] = []
    var acceptsUpdates = true

    func add(_ service: CBMutableService) {
        added.append(service)
        unconfirmed.append(service)
    }
    func remove(_ service: CBMutableService) {
        added.removeAll { $0 === service }
    }
    func removeAllServices() {
        removeAllCalls += 1
        unconfirmed.removeAll()
    }
    func startAdvertising(_ advertisementData: [String: Any]?) { advertisingStarts += 1 }
    func stopAdvertising() { advertisingStops += 1 }
    func updateValue(_ value: Data, for characteristic: CBMutableCharacteristic,
                     onSubscribedCentrals centrals: [CBCentral]?) -> Bool {
        acceptsUpdates
    }
    func requestLowConnectionLatency(for centralID: UUID, central: CBCentral?) {
        latencyRequests.append(centralID)
    }

    /// Delivers didAdd for every add so far, as CoreBluetooth would.
    func confirmAdds(to peripheral: BLEHIDPeripheralManager, except skipped: CBUUID? = nil) {
        let pending = unconfirmed
        unconfirmed.removeAll()
        for service in pending where service.uuid != skipped {
            peripheral.handleDidAdd(service, error: nil)
        }
    }

    /// The input Report characteristic carrying `reportID` in its Report Reference.
    func inputReport(id reportID: UInt8) -> CBMutableCharacteristic? {
        let hid = added.last { $0.uuid == BLEHIDPeripheralManager.GATT.hidService }
        return hid?.characteristics?.compactMap { $0 as? CBMutableCharacteristic }.first { characteristic in
            characteristic.descriptors?.contains {
                $0.uuid == CBUUID(string: "2908") && ($0.value as? Data) == Data([reportID, 0x01])
            } == true
        }
    }
}

final class RecordingPeripheralDelegate: BLEHIDPeripheralDelegate {
    enum Event: Equatable {
        case startedAdvertising, stoppedAdvertising, poweredOn
        case connected(UUID), disconnected(UUID)
        case failed(BLEHIDPeripheralManager.Failure)
        case published
        case pending(UUID)
    }
    private(set) var events: [Event] = []

    func peripheralDidStartAdvertising() { events.append(.startedAdvertising) }
    func peripheralDidStopAdvertising() { events.append(.stoppedAdvertising) }
    func peripheralDidConnect(central: HIDCentral) { events.append(.connected(central.id)) }
    func peripheralDidDisconnect(central: HIDCentral) { events.append(.disconnected(central.id)) }
    func peripheralDidFail(_ failure: BLEHIDPeripheralManager.Failure) { events.append(.failed(failure)) }
    func peripheralDidPowerOn() { events.append(.poweredOn) }
    func peripheralDidReceiveLEDState(_ ledByte: UInt8) {}
    func peripheralDidPublishServices() { events.append(.published) }
    func peripheralDidSeePendingCentral(_ central: HIDCentral) { events.append(.pending(central.id)) }
}
