import Foundation

final class DeviceConnectionManager {
    /// Most recently connected first.
    private var devices: [ConnectedDevice] = []

    /// Add a device to the connected list, or move it to the front if it
    /// is already there (a reconnect makes it the newest).
    @discardableResult
    func addConnectedDevice(_ device: ConnectedDevice) -> ConnectedDevice {
        devices.removeAll { $0.id == device.id }
        devices.insert(device, at: 0)
        Log.bluetooth.info("Device added: \(device.name) (\(device.id))")
        return device
    }

    /// Remove a device from the connected list.
    func removeDevice(id: String) {
        if let index = devices.firstIndex(where: { $0.id == id }) {
            let device = devices.remove(at: index)
            Log.bluetooth.info("Device removed: \(device.name) (\(id))")
        }
    }

    /// The most recently connected device, or nil if none.
    var primaryDevice: ConnectedDevice? {
        devices.first
    }

    /// All connected devices, most recently connected first.
    var allDevices: [ConnectedDevice] {
        devices
    }

    /// Remove all connected devices.
    func removeAllDevices() {
        devices.removeAll()
    }
}
