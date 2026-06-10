import Cocoa
import IOBluetooth

enum PermissionChecker {

    // MARK: - Input Monitoring (Accessibility / CGEventTap)

    static var hasInputMonitoringPermission: Bool {
        CGPreflightListenEventAccess()
    }

    static func requestInputMonitoringPermission() {
        CGRequestListenEventAccess()
    }

    static func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Accessibility (required for the consuming event tap in global forwarding)

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Bluetooth

    static var isBluetoothAvailable: Bool {
        IOBluetoothHostController.default() != nil
    }

    static var isBluetoothPoweredOn: Bool {
        guard let controller = IOBluetoothHostController.default() else {
            return false
        }
        return controller.powerState == kBluetoothHCIPowerStateON
    }

    static func openBluetoothSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
