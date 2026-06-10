import Foundation

final class DeviceConnectionManager {
    private(set) var connectedDevices: [String: ConnectedDevice] = [:]

    /// Add a device to the connected list.
    @discardableResult
    func addConnectedDevice(_ device: ConnectedDevice) -> ConnectedDevice {
        connectedDevices[device.id] = device
        Log.bluetooth.info("Device added: \(device.name) (\(device.id))")
        return device
    }

    /// Remove a device from the connected list.
    func removeDevice(id: String) {
        if let device = connectedDevices.removeValue(forKey: id) {
            Log.bluetooth.info("Device removed: \(device.name) (\(id))")
        }
    }

    /// The primary (first) connected device, or nil if none.
    var primaryDevice: ConnectedDevice? {
        connectedDevices.values.first
    }

    /// All connected devices as an array.
    var allDevices: [ConnectedDevice] {
        Array(connectedDevices.values)
    }

    /// Remove all connected devices.
    func removeAllDevices() {
        connectedDevices.removeAll()
    }
}
