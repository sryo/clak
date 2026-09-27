import Cocoa
import CoreBluetooth
import IOBluetooth

enum PermissionChecker {

    // MARK: - Input Monitoring (Accessibility / CGEventTap)

    static var hasInputMonitoringPermission: Bool {
        CGPreflightListenEventAccess()
    }

    static func requestInputMonitoringPermission() {
        CGRequestListenEventAccess()
    }

    /// Asks first: the app only appears in the Input Monitoring list once it
    /// has requested access, so opening the pane alone shows nothing to turn on.
    static func openInputMonitoringSettings() {
        if !hasInputMonitoringPermission {
            requestInputMonitoringPermission()
        }
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

    /// Same gap as Input Monitoring: only the prompting trust check adds the
    /// app to the Accessibility list, so ask before opening the pane.
    static func openAccessibilitySettings() {
        if !hasAccessibilityPermission {
            requestAccessibilityPermission()
        }
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

    /// App-level Bluetooth permission. `.notDetermined` counts as granted:
    /// the system asks on first use and the user hasn't said no.
    static var isBluetoothAuthorized: Bool {
        switch CBManager.authorization {
        case .allowedAlways, .notDetermined: true
        case .denied, .restricted: false
        @unknown default: true
        }
    }

    static func openBluetoothSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func openBluetoothPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func open(_ destination: SettingsDestination) {
        switch destination {
        case .bluetooth: openBluetoothSettings()
        case .bluetoothPrivacy: openBluetoothPrivacySettings()
        case .inputMonitoring: openInputMonitoringSettings()
        case .accessibility: openAccessibilitySettings()
        }
    }
}
