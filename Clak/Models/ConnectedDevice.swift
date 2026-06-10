import Foundation
import IOBluetooth
import CoreBluetooth

struct ConnectedDevice: Identifiable, Hashable {
    let id: String // BLE central UUID
    let name: String

    init(central: CBCentral) {
        self.id = central.identifier.uuidString
        self.name = Self.resolveDeviceName(for: id)
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// Try to resolve a friendly name from IOBluetooth paired devices, fall back to "iPhone".
    private static func resolveDeviceName(for uuid: String) -> String {
        // Check recently paired devices — the iPhone may appear here after BLE pairing
        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            // Find the most recently seen iOS device
            for device in paired {
                guard let name = device.name else { continue }
                let lowerName = name.lowercased()
                if lowerName.contains("iphone") || lowerName.contains("ipad") || lowerName.contains("ipod") {
                    return name
                }
            }
        }
        return "iPhone"
    }
}
