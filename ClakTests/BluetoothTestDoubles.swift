import Foundation
@testable import Clak

/// Runs scheduled work only when the test advances time.
final class ManualScheduler {
    private(set) var now: TimeInterval = 0
    private var items: [(due: TimeInterval, seq: Int, work: DispatchWorkItem)] = []
    private var seq = 0

    var scheduler: DelayScheduler {
        DelayScheduler { [unowned self] delay, work in
            self.seq += 1
            self.items.append((self.now + delay, self.seq, work))
        }
    }

    /// Delays of work still waiting to run, relative to now.
    var pendingDelays: [TimeInterval] {
        items.filter { !$0.work.isCancelled }.sorted { ($0.due, $0.seq) < ($1.due, $1.seq) }.map { $0.due - now }
    }

    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let next = items.filter({ $0.due <= target }).min(by: { ($0.due, $0.seq) < ($1.due, $1.seq) }) {
            items.removeAll { $0.seq == next.seq }
            now = next.due
            if !next.work.isCancelled {
                next.work.perform()
            }
        }
        now = target
    }
}

final class FakeHIDPeripheralLink: HIDPeripheralLink {
    weak var delegate: BLEHIDPeripheralDelegate?
    var isConnected = false
    var hasCentral = false
    var areServicesPublished = true

    private(set) var startAdvertisingCalls = 0
    private(set) var stopAdvertisingCalls = 0
    private(set) var republishCalls = 0
    private(set) var teardownCalls = 0
    private(set) var keyboardReports: [(modifiers: UInt8, keyCodes: [UInt8])] = []

    func startAdvertising() { startAdvertisingCalls += 1 }
    func stopAdvertisingOnly() { stopAdvertisingCalls += 1 }
    func republish() { republishCalls += 1 }
    func teardownCompletely() { teardownCalls += 1 }

    func sendKeyboardReport(modifiers: UInt8, keyCodes: [UInt8]) -> Bool {
        keyboardReports.append((modifiers, keyCodes))
        return true
    }
    func sendKeyRelease() -> Bool { sendKeyboardReport(modifiers: 0, keyCodes: []) }
    func sendConsumerReport(usage: UInt16) -> Bool { true }
    func sendMouseReport(buttons: UInt8, dx: Int8, dy: Int8, wheel: Int8, pan: Int8) -> Bool { true }

    // MARK: - Driving the delegate the way the real peripheral does

    func connect(_ central: HIDCentral) {
        isConnected = true
        hasCentral = true
        delegate?.peripheralDidConnect(central: central)
    }

    func seePending(_ central: HIDCentral) {
        hasCentral = true
        delegate?.peripheralDidSeePendingCentral(central)
    }

    func disconnect(_ central: HIDCentral, othersRemain: Bool = false) {
        isConnected = othersRemain
        hasCentral = othersRemain
        delegate?.peripheralDidDisconnect(central: central)
    }
}
