import Foundation

/// What the HUD says, derived only from values: one headline, at most one
/// line under it, a dot, and the chord that gets you out of the current mode.
struct HUDPresentation: Equatable {
    enum Tone: Equatable {
        case ready
        case global
        case paused
        case waiting
        case attention
        case error
    }

    struct Hint: Equatable {
        /// The chord glyphs, or nil when the action has no binding.
        var keys: String?
        var text: String
    }

    var step: OnboardingStep
    var headline: String
    var line: String?
    var tone: Tone
    var isPulsing: Bool
    var hint: Hint?
    /// Short state for the menu bar and VoiceOver.
    var status: String
    var accessibilityLabel: String
    /// Show the typed-text echo instead of the headline once text arrives.
    var showsEcho: Bool
    /// Global mode: the HUD is the only sign keys are leaving this Mac,
    /// so it must not dim when Clak loses focus.
    var staysOpaqueWhenInactive: Bool
    var settings: SettingsDestination?
    /// The raw failure, for a tooltip; the headline stays human.
    var detail: String?

    static func make(_ input: HUDInput, bindings: [ShortcutBinding]) -> HUDPresentation {
        let step = OnboardingStep.current(input)
        let device = input.deviceName ?? "your device"

        var p = HUDPresentation(
            step: step, headline: "", line: nil, tone: .waiting, isPulsing: false,
            hint: nil, status: "", accessibilityLabel: "", showsEcho: false,
            staysOpaqueWhenInactive: false, settings: step.settings, detail: nil
        )

        switch step {
        case .bluetoothUnsupported:
            p.headline = "Bluetooth LE isn\u{2019}t available"
            p.line = "This Mac can\u{2019}t act as a keyboard."
            p.tone = .error
            p.status = "Bluetooth LE isn\u{2019}t available"
            p.detail = input.errorMessage
        case .allowBluetooth:
            p.headline = "Bluetooth access is off"
            p.line = "Clak needs Bluetooth to connect."
            p.tone = .attention
            p.status = p.headline
        case .turnOnBluetooth:
            p.headline = "Bluetooth is off"
            p.line = "Turn it on to connect."
            p.tone = .attention
            p.status = p.headline
        case .confirmPairingCode:
            p.headline = "Confirm the code on your Mac"
            p.line = "It should match the one on your device."
            p.isPulsing = true
            p.status = "Pairing"
        case .allowInputMonitoring:
            p.headline = "Allow Input Monitoring"
            p.line = "Clak needs it to read your keys."
            p.tone = .attention
            p.status = "Needs Input Monitoring"
        case .pairFromDevice:
            if let error = input.errorMessage {
                p.headline = "Can\u{2019}t connect right now"
                p.line = chord(.disconnectDevice, bindings)
                    .map { "Press \($0.display) to try again." } ?? "Reconnect from the menu bar."
                p.tone = .error
                p.status = "Can\u{2019}t connect"
                p.detail = error
            } else {
                p.headline = "Waiting to connect"
                p.line = "Choose Clak in your device\u{2019}s Bluetooth settings."
                p.isPulsing = true
                p.status = p.headline
            }
        case .allowAccessibility, .ready:
            p.showsEcho = input.isForwarding
            if !input.isForwarding {
                p.headline = "Paused"
                p.line = "Your keys stay on this Mac."
                p.tone = .paused
                p.status = "Paused"
                p.hint = hint(.toggleForwarding, "to resume", "Resume it from the menu bar", bindings)
            } else if step == .allowAccessibility {
                p.headline = "Type to \(device)\u{2026}"
                p.line = "Allow Accessibility to type from any app."
                p.tone = .attention
                p.status = "Connected to \(device)"
            } else if input.isGlobalForwarding {
                p.headline = "Type to \(device)\u{2026}"
                p.line = "From any app."
                p.tone = .global
                p.status = "Typing to \(device) from any app"
                p.hint = hint(.toggleGlobalForwarding, "to stop", "Stop it from the menu bar", bindings)
                p.staysOpaqueWhenInactive = true
            } else {
                p.headline = "Type to \(device)\u{2026}"
                p.tone = .ready
                p.status = "Connected to \(device)"
            }
        }

        var label = p.status + "."
        if input.isConnected && input.capsLockActive {
            label += " Caps Lock is on."
        }
        p.accessibilityLabel = label
        return p
    }

    private static func chord(_ action: ShortcutAction, _ bindings: [ShortcutBinding]) -> ShortcutChord? {
        ShortcutChord.binding(for: action, in: bindings)
    }

    private static func hint(_ action: ShortcutAction, _ text: String, _ unbound: String, _ bindings: [ShortcutBinding]) -> Hint {
        if let chord = chord(action, bindings) {
            return Hint(keys: chord.display, text: text)
        }
        return Hint(keys: nil, text: unbound)
    }
}
