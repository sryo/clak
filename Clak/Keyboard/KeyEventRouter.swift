import CoreGraphics

/// Everything the key gate reads, captured at once so the decision can be
/// made off the main thread without touching AppState.
struct KeyGateSnapshot: Equatable {
    var isAppActive: Bool
    var isGlobalForwarding: Bool
    var isForwarding: Bool
    var isConnected: Bool
    /// A shortcut recorder is open (whether or not Clak is frontmost).
    var isRecording: Bool
    /// The tap was created as `.defaultTap`, so returning "consume" works.
    var isConsumeCapable: Bool
    var shortcuts: [ShortcutBinding]

    /// Global forwarding swallows events system-wide.
    var isConsumingGlobally: Bool {
        isGlobalForwarding && isForwarding && isConnected && isConsumeCapable
    }

    /// Clak is frontmost or keys go to the device from anywhere.
    var isListening: Bool {
        (isAppActive || isGlobalForwarding) && isConnected
    }

    /// The recorder's local monitor only sees keys while Clak is frontmost,
    /// so one left open in the background must not stall global forwarding.
    var recorderOwnsKeys: Bool {
        isAppActive && isRecording
    }

    func shortcut(keyCode: UInt16, modifiers: CGEventFlags) -> ShortcutAction? {
        shortcuts.first { $0.matches(keyCode: keyCode, modifiers: modifiers) }?.action
    }
}

enum KeyEventInput: Equatable {
    case keyDown(keyCode: UInt16, modifiers: CGEventFlags, isAutorepeat: Bool)
    case keyUp(keyCode: UInt16, modifiers: CGEventFlags)
    /// `globeTapped` comes from GlobeKeyTapDetector, which must see every
    /// Globe change whether or not the gate is open. It only changes the
    /// action, never whether the event is consumed.
    case modifiersChanged(keyCode: UInt16, modifiers: CGEventFlags, globeTapped: Bool)
}

enum KeyRouteAction: Equatable {
    case none
    case shortcut(ShortcutAction)
    case consumer(usage: UInt16)
    /// Add to the pressed set, send it, and echo the key.
    case key(usage: UInt8)
    /// Send the current pressed set with the new modifiers.
    case sendPressedKeys
    case globe
}

struct KeyRoute: Equatable {
    let consume: Bool
    let action: KeyRouteAction

    static let pass = KeyRoute(consume: false, action: .none)
}

/// The key gate: whether an event goes to the device, runs a shortcut, or
/// stays on the Mac, and whether the tap swallows it. Tracker updates that
/// must happen regardless (modifiers, key-ups, Globe) stay with the caller.
enum KeyEventRouter {

    static func route(_ s: KeyGateSnapshot, _ event: KeyEventInput) -> KeyRoute {
        guard s.isListening, !s.recorderOwnsKeys else {
            return .pass
        }
        // Decided up front so a chord that flips state (the global-mode
        // escape shortcut) is itself consumed under the rules it was pressed in
        let consume = s.isConsumingGlobally

        switch event {
        case let .keyDown(keyCode, modifiers, isAutorepeat):
            // Shortcuts run before the forwarding check: the escape chord must always work
            if !isAutorepeat, let action = s.shortcut(keyCode: keyCode, modifiers: modifiers) {
                return KeyRoute(consume: consume, action: .shortcut(action))
            }
            guard s.isForwarding else {
                return .pass
            }
            // The HID host repeats held keys itself
            if isAutorepeat {
                return KeyRoute(consume: consume, action: .none)
            }
            if let usage = ConsumerKeyMapper.usage(for: keyCode) {
                return KeyRoute(consume: consume, action: .consumer(usage: usage))
            }
            guard let usage = KeyCodeTranslator.hidUsageCode(from: keyCode) else {
                return KeyRoute(consume: consume, action: .none)
            }
            return KeyRoute(consume: consume, action: .key(usage: usage))

        case .keyUp:
            guard s.isForwarding else {
                return .pass
            }
            return KeyRoute(consume: consume, action: .sendPressedKeys)

        case let .modifiersChanged(keyCode, _, globeTapped):
            guard s.isForwarding else {
                return .pass
            }
            // fn isn't in the HID modifier byte: a Globe change sends no
            // keyboard report, and a tap switches the device's layout
            if GlobeKeyTapDetector.keyCodes.contains(keyCode) {
                return KeyRoute(consume: consume, action: globeTapped ? .globe : .none)
            }
            return KeyRoute(consume: consume, action: .sendPressedKeys)
        }
    }
}

extension ShortcutBinding {
    /// Only Command, Shift, Control and Option take part in matching, as in
    /// KeyboardShortcutManager.matchShortcut.
    static let matchedModifiers: UInt64 =
        CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue

    func matches(keyCode: UInt16, modifiers: CGEventFlags) -> Bool {
        self.keyCode == keyCode
            && self.modifiers & Self.matchedModifiers == modifiers.rawValue & Self.matchedModifiers
    }
}
