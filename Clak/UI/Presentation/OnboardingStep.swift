import Foundation

enum BluetoothAvailability: Equatable {
    case on
    case off
    case unauthorized
    case unsupported

    init(isAuthorized: Bool, isPoweredOn: Bool) {
        if !isAuthorized {
            self = .unauthorized
        } else {
            self = isPoweredOn ? .on : .off
        }
    }
}

enum SettingsDestination: Equatable {
    case bluetooth
    case bluetoothPrivacy
    case inputMonitoring
    case accessibility

    var menuTitle: String {
        switch self {
        case .bluetooth: "Open Bluetooth Settings\u{2026}"
        case .bluetoothPrivacy: "Open Bluetooth Privacy Settings\u{2026}"
        case .inputMonitoring: "Open Input Monitoring Settings\u{2026}"
        case .accessibility: "Open Accessibility Settings\u{2026}"
        }
    }
}

/// Everything the HUD and menu read, as plain values so presentation can be
/// tested without an AppState, a window or a radio.
struct HUDInput: Equatable {
    var bluetooth: BluetoothAvailability = .on
    var needsInputMonitoring = false
    var needsAccessibility = false
    /// A central is connected and SMP pairing is waiting on the Mac's
    /// Numeric Comparison dialog, which times out after about 30 seconds.
    var isAwaitingPairingConfirmation = false
    var isConnected = false
    var deviceName: String?
    var isForwarding = true
    var isGlobalForwarding = false
    var capsLockActive = false
    var errorMessage: String?
}

extension HUDInput {
    init(_ state: AppState) {
        self.init(
            bluetooth: state.bluetooth,
            needsInputMonitoring: state.needsInputMonitoring,
            needsAccessibility: state.needsAccessibility,
            isAwaitingPairingConfirmation: state.isAwaitingPairingConfirmation,
            isConnected: state.isConnected,
            deviceName: state.connectedDeviceName,
            isForwarding: state.isForwarding,
            isGlobalForwarding: state.isGlobalForwarding,
            capsLockActive: state.capsLockActive,
            errorMessage: state.errorMessage
        )
    }
}

/// The one thing standing between the user and typing on their device.
enum OnboardingStep: Equatable {
    case bluetoothUnsupported
    case allowBluetooth
    case turnOnBluetooth
    case confirmPairingCode
    case allowInputMonitoring
    case pairFromDevice
    case allowAccessibility
    case ready

    /// Bluetooth gates come first because nothing else can happen without
    /// the radio. The pairing code outranks Input Monitoring: the dialog
    /// expires in ~30s, the permission can wait. Accessibility only matters
    /// once there is a device to type to.
    static func current(_ input: HUDInput) -> OnboardingStep {
        switch input.bluetooth {
        case .unsupported: return .bluetoothUnsupported
        case .unauthorized: return .allowBluetooth
        case .off: return .turnOnBluetooth
        case .on: break
        }
        if input.isAwaitingPairingConfirmation && !input.isConnected {
            return .confirmPairingCode
        }
        if input.needsInputMonitoring {
            return .allowInputMonitoring
        }
        if !input.isConnected {
            return .pairFromDevice
        }
        if input.needsAccessibility {
            return .allowAccessibility
        }
        return .ready
    }

    var settings: SettingsDestination? {
        switch self {
        case .allowBluetooth: .bluetoothPrivacy
        case .turnOnBluetooth: .bluetooth
        case .allowInputMonitoring: .inputMonitoring
        case .allowAccessibility: .accessibility
        case .bluetoothUnsupported, .confirmPairingCode, .pairFromDevice, .ready: nil
        }
    }
}
