import Foundation

/// What BluetoothManager needs from the BLE peripheral. BLEHIDPeripheralManager
/// is the only production conformer; tests drive BluetoothManager with a fake.
protocol HIDPeripheralLink: AnyObject {
    var delegate: BLEHIDPeripheralDelegate? { get set }
    /// Live: a central is subscribed to an input report right now.
    var isConnected: Bool { get }
    /// A central is present, possibly still discovering or pairing.
    var hasCentral: Bool { get }
    var areServicesPublished: Bool { get }

    func startAdvertising()
    func stopAdvertisingOnly()
    func republish()
    func teardownCompletely()

    @discardableResult func sendKeyboardReport(modifiers: UInt8, keyCodes: [UInt8]) -> Bool
    @discardableResult func sendKeyRelease() -> Bool
    @discardableResult func sendConsumerReport(usage: UInt16) -> Bool
    @discardableResult func sendMouseReport(buttons: UInt8, dx: Int8, dy: Int8, wheel: Int8, pan: Int8) -> Bool
}

extension BLEHIDPeripheralManager: HIDPeripheralLink {}
