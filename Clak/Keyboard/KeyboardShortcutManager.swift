import Cocoa
import Carbon.HIToolbox
import os

// MARK: - ShortcutAction

/// Actions that can be triggered by keyboard shortcuts.
enum ShortcutAction: String, Codable, CaseIterable {
    case pasteToDevice
    case toggleForwarding
    case toggleGlobalForwarding
    case disconnectDevice
    case showPreferences

    var displayName: String {
        switch self {
        case .pasteToDevice: return "Paste to Device"
        case .toggleForwarding: return "Toggle Forwarding"
        case .toggleGlobalForwarding: return "Toggle Global Forwarding"
        case .disconnectDevice: return "Reconnect"
        case .showPreferences: return "Show Preferences"
        }
    }

    var displayDescription: String {
        switch self {
        case .pasteToDevice: return "Paste clipboard text to the connected device"
        case .toggleForwarding: return "Toggle keystroke forwarding on/off"
        case .toggleGlobalForwarding: return "Type to the device without keeping Clak focused"
        case .disconnectDevice: return "Disconnect and reconnect to the device"
        case .showPreferences: return "Open the preferences window"
        }
    }
}

// MARK: - ShortcutBinding

/// A keyboard shortcut binding: a keycode + modifier combination mapped to an action.
struct ShortcutBinding: Codable, Hashable {

    /// The macOS virtual keycode for the shortcut key.
    let keyCode: UInt16

    /// The raw value of CGEventFlags representing the modifier keys.
    let modifiers: CGEventFlags.RawValue

    /// The action to perform when this shortcut is triggered.
    let action: ShortcutAction
}

// MARK: - KeyboardShortcutManager

/// Manages keyboard shortcut registration and matching.
///
/// Provides a default set of shortcuts and allows updating individual bindings.
/// Shortcut configurations are persisted to UserDefaults.
final class KeyboardShortcutManager {

    // MARK: - Singleton

    static let shared = KeyboardShortcutManager()

    // MARK: - Properties

    private var shortcuts: [ShortcutBinding] = []

    /// UserDefaults key for persisted shortcut data.
    private static let shortcutsDefaultsKey = "keyboardShortcuts"

    // MARK: - Initialization

    private init() {
        loadShortcuts()
    }

    // MARK: - Default Registration

    /// Register default bindings for any actions that don't have one yet —
    /// existing user customizations are preserved when new actions are added.
    ///
    /// Default shortcuts:
    /// - Cmd+Shift+V: Paste to device
    /// - Cmd+Shift+K: Toggle forwarding
    /// - Cmd+Shift+G: Toggle global forwarding
    /// - Cmd+Shift+D: Disconnect device
    func registerDefaults() {
        let cmdShiftFlags = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue

        let defaults = [
            ShortcutBinding(keyCode: UInt16(kVK_ANSI_V), modifiers: cmdShiftFlags, action: .pasteToDevice),
            ShortcutBinding(keyCode: UInt16(kVK_ANSI_K), modifiers: cmdShiftFlags, action: .toggleForwarding),
            ShortcutBinding(keyCode: UInt16(kVK_ANSI_G), modifiers: cmdShiftFlags, action: .toggleGlobalForwarding),
            ShortcutBinding(keyCode: UInt16(kVK_ANSI_D), modifiers: cmdShiftFlags, action: .disconnectDevice),
        ]

        var added = false
        for binding in defaults where !shortcuts.contains(where: { $0.action == binding.action }) {
            shortcuts.append(binding)
            added = true
        }

        guard added else {
            Log.keyboard.debug("Shortcuts already registered, skipping defaults")
            return
        }

        saveShortcuts()
        Log.keyboard.info("Registered default keyboard shortcuts")
    }

    // MARK: - Matching

    /// Check whether a key event matches any registered shortcut.
    ///
    /// Only the modifier flags relevant to shortcuts (Command, Shift, Control, Option)
    /// are considered when matching.
    ///
    /// - Parameters:
    ///   - keyCode: The macOS virtual keycode from the key event.
    ///   - modifiers: The CGEventFlags from the key event.
    /// - Returns: The matching `ShortcutAction`, or `nil` if no shortcut matches.
    func matchShortcut(keyCode: UInt16, modifiers: CGEventFlags) -> ShortcutAction? {
        let maskedModifiers = modifiers.rawValue & Self.modifierMask

        for shortcut in shortcuts {
            let shortcutModifiers = shortcut.modifiers & Self.modifierMask
            if shortcut.keyCode == keyCode && shortcutModifiers == maskedModifiers {
                Log.keyboard.info("Matched shortcut: \(shortcut.action.rawValue)")
                return shortcut.action
            }
        }

        return nil
    }

    // MARK: - Update

    /// Update the key binding for a given action.
    ///
    /// If a shortcut for the given action already exists, it is replaced.
    /// Otherwise a new entry is added.
    ///
    /// - Parameters:
    ///   - action: The action whose binding should change.
    ///   - keyCode: The new macOS virtual keycode.
    ///   - modifiers: The new modifier flags.
    func updateShortcut(action: ShortcutAction, keyCode: UInt16, modifiers: CGEventFlags) {
        let newShortcut = ShortcutBinding(
            keyCode: keyCode,
            modifiers: modifiers.rawValue,
            action: action
        )

        if let index = shortcuts.firstIndex(where: { $0.action == action }) {
            shortcuts[index] = newShortcut
        } else {
            shortcuts.append(newShortcut)
        }

        saveShortcuts()
        Log.keyboard.info("Updated shortcut for \(action.rawValue): keyCode=\(keyCode), modifiers=0x\(String(modifiers.rawValue, radix: 16))")
    }

    /// All currently registered shortcuts.
    var registeredShortcuts: [ShortcutBinding] {
        shortcuts
    }

    /// Reset all shortcuts to defaults.
    func resetToDefaults() {
        shortcuts = []
        UserDefaults.standard.removeObject(forKey: Self.shortcutsDefaultsKey)
        registerDefaults()
        Log.keyboard.info("Shortcuts reset to defaults")
    }

    /// Check if a key combination conflicts with an existing shortcut (excluding one action).
    func conflictingAction(keyCode: UInt16, modifiers: CGEventFlags, excluding: ShortcutAction) -> ShortcutAction? {
        let maskedModifiers = modifiers.rawValue & Self.modifierMask
        for shortcut in shortcuts where shortcut.action != excluding {
            let shortcutModifiers = shortcut.modifiers & Self.modifierMask
            if shortcut.keyCode == keyCode && shortcutModifiers == maskedModifiers {
                return shortcut.action
            }
        }
        return nil
    }

    // MARK: - Persistence

    /// Mask to isolate the modifier flags we care about when matching shortcuts.
    /// This strips device-dependent bits and keeps only Command, Shift, Control, Option.
    private static let modifierMask: UInt64 =
        CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue

    /// Load shortcuts from UserDefaults. Falls back to registering defaults if none are stored.
    private func loadShortcuts() {
        guard let data = UserDefaults.standard.data(forKey: Self.shortcutsDefaultsKey) else {
            Log.keyboard.debug("No persisted shortcuts found, will register defaults")
            registerDefaults()
            return
        }

        do {
            shortcuts = try JSONDecoder().decode([ShortcutBinding].self, from: data)
            Log.keyboard.info("Loaded \(self.shortcuts.count) keyboard shortcuts from defaults")
        } catch {
            Log.keyboard.error("Failed to decode persisted shortcuts: \(error.localizedDescription)")
            shortcuts = []
            registerDefaults()
        }
    }

    /// Save the current shortcuts to UserDefaults.
    private func saveShortcuts() {
        do {
            let data = try JSONEncoder().encode(shortcuts)
            UserDefaults.standard.set(data, forKey: Self.shortcutsDefaultsKey)
        } catch {
            Log.keyboard.error("Failed to encode shortcuts for persistence: \(error.localizedDescription)")
        }
    }
}
