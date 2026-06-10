import Foundation
import CoreGraphics
import os

// MARK: - ModifierKeyTracker

/// Tracks the current state of modifier keys and converts them to HID modifier bytes.
///
/// This class maintains a running record of which modifier keys are currently pressed
/// by processing `CGEventFlags` from `flagsChanged` events. The stored modifier byte
/// follows the USB HID keyboard report format.
final class ModifierKeyTracker {

    // MARK: - Properties

    /// The current HID modifier byte reflecting which modifier keys are held.
    ///
    /// Bit layout:
    /// - Bit 0: Left Control
    /// - Bit 1: Left Shift
    /// - Bit 2: Left Alt/Option
    /// - Bit 3: Left GUI/Command
    /// - Bit 4: Right Control
    /// - Bit 5: Right Shift
    /// - Bit 6: Right Alt/Option
    /// - Bit 7: Right GUI/Command
    private(set) var currentModifiers: UInt8 = 0

    // MARK: - Update

    /// Update the tracked modifier state from CGEventFlags.
    ///
    /// - Parameter flags: The current `CGEventFlags` from a keyboard event.
    /// - Returns: The updated HID modifier byte.
    @discardableResult
    func update(with flags: CGEventFlags) -> UInt8 {
        let newModifiers = KeyCodeTranslator.modifierByte(from: flags)
        if newModifiers != currentModifiers {
            Log.keyboard.debug("Modifier state changed: 0x\(String(newModifiers, radix: 16)) (was 0x\(String(self.currentModifiers, radix: 16)))")
            currentModifiers = newModifiers
        }
        return currentModifiers
    }

    /// Reset all modifier state to zero (no modifiers pressed).
    func reset() {
        if currentModifiers != 0 {
            Log.keyboard.debug("Modifier state reset to 0x00")
        }
        currentModifiers = 0
    }

    // MARK: - Convenience Properties

    /// Whether any Shift key is currently pressed (left or right).
    var isShiftPressed: Bool {
        // Left Shift = bit 1 (0x02), Right Shift = bit 5 (0x20)
        currentModifiers & 0x22 != 0
    }

    /// Whether any Control key is currently pressed (left or right).
    var isControlPressed: Bool {
        // Left Control = bit 0 (0x01), Right Control = bit 4 (0x10)
        currentModifiers & 0x11 != 0
    }

    /// Whether any Alt/Option key is currently pressed (left or right).
    var isAltPressed: Bool {
        // Left Alt = bit 2 (0x04), Right Alt = bit 6 (0x40)
        currentModifiers & 0x44 != 0
    }

    /// Whether any Command/GUI key is currently pressed (left or right).
    var isCommandPressed: Bool {
        // Left GUI = bit 3 (0x08), Right GUI = bit 7 (0x80)
        currentModifiers & 0x88 != 0
    }
}
