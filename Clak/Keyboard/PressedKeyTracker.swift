import Foundation

/// Tracks currently pressed keys so every HID report carries the full key set (6-key rollover).
/// Keyed by macOS virtual keycode so key-up removal never depends on re-translating the usage.
final class PressedKeyTracker {
    private var pressed: [(keyCode: UInt16, usage: UInt8)] = []

    /// Current HID usages, in press order.
    var usages: [UInt8] { pressed.map(\.usage) }

    /// Register a key press. A 7th simultaneous key is ignored (6KRO).
    /// - Returns: the updated usage snapshot to send.
    @discardableResult
    func keyDown(keyCode: UInt16, usage: UInt8) -> [UInt8] {
        if let index = pressed.firstIndex(where: { $0.keyCode == keyCode }) {
            pressed[index].usage = usage
        } else if pressed.count < 6 {
            pressed.append((keyCode, usage))
        }
        return usages
    }

    /// Register a key release.
    /// - Returns: the updated usage snapshot to send.
    @discardableResult
    func keyUp(keyCode: UInt16) -> [UInt8] {
        pressed.removeAll { $0.keyCode == keyCode }
        return usages
    }

    /// Release a key only if its press was tracked.
    /// - Returns: the remaining usages to send, or nil if the key wasn't held.
    func release(keyCode: UInt16) -> [UInt8]? {
        guard pressed.contains(where: { $0.keyCode == keyCode }) else {
            return nil
        }
        return keyUp(keyCode: keyCode)
    }

    /// Clear all pressed keys (focus loss, disconnect, forwarding toggled off).
    func reset() {
        pressed.removeAll()
    }
}
