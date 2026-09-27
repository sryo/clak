import Carbon
import Cocoa

/// Dynamically maps characters to HID keycodes using the current keyboard input source.
/// Falls back to the static US layout in `KeyCodeTranslator` when no dynamic mapping is available.
final class KeyboardLayoutMapper {

    static let shared = KeyboardLayoutMapper()

    /// Maps a Unicode scalar to (virtual keycode, modifier combo index).
    /// Modifier combo: 0=none, 1=shift, 2=option, 3=shift+option
    private var charMap: [Unicode.Scalar: (virtualKeyCode: UInt16, modifierCombo: Int)] = [:]

    private var currentInputSourceID: String?

    private init() {
        rebuildMap()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )
    }

    @objc private func inputSourceChanged(_ notification: Notification) {
        if Thread.isMainThread {
            rebuildMap()
        } else {
            DispatchQueue.main.async { [weak self] in self?.rebuildMap() }
        }
    }

    /// Rebuild the character map from the active keyboard input source.
    /// Main thread only: Text Input Sources aren't thread-safe, and charMap
    /// is read there without a lock.
    func rebuildMap() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutDataRef = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            Log.keyboard.warning("KeyboardLayoutMapper: Could not get keyboard layout data")
            return
        }

        let sourceID: String
        if let rawID = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID) {
            sourceID = Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String
        } else {
            sourceID = "unknown"
        }
        guard sourceID != currentInputSourceID else {
            return // No change
        }
        currentInputSourceID = sourceID

        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self) as Data
        var newMap: [Unicode.Scalar: (virtualKeyCode: UInt16, modifierCombo: Int)] = [:]

        layoutData.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }

            // Modifier combos: [none, shift, option, shift+option]
            let modifierStates: [UInt32] = [0, shiftBit, optionBit, shiftBit | optionBit]

            for keyCode: UInt16 in 0..<128 {
                for (comboIndex, modifierKeyState) in modifierStates.enumerated() {
                    var deadKeyState: UInt32 = 0
                    var length: Int = 0
                    var chars = [UniChar](repeating: 0, count: 4)

                    let status = UCKeyTranslate(
                        ptr,
                        keyCode,
                        UInt16(kUCKeyActionDown),
                        modifierKeyState,
                        UInt32(LMGetKbdType()),
                        UInt32(kUCKeyTranslateNoDeadKeysMask),
                        &deadKeyState,
                        4,
                        &length,
                        &chars
                    )

                    guard status == noErr, length > 0 else {
                        continue
                    }

                    // Only map single-scalar characters
                    guard length == 1 else {
                        continue
                    }
                    let scalar = Unicode.Scalar(chars[0])
                    guard let scalar else {
                        continue
                    }

                    // Don't overwrite a simpler modifier combo
                    if let existing = newMap[scalar], existing.modifierCombo <= comboIndex {
                        continue
                    }
                    newMap[scalar] = (virtualKeyCode: keyCode, modifierCombo: comboIndex)
                }
            }
        }

        charMap = newMap
        Log.keyboard.info("KeyboardLayoutMapper: Rebuilt map for '\(sourceID, privacy: .public)' — \(newMap.count) entries")
    }

    /// Look up the HID keycode and modifier byte for a character.
    /// Uses the dynamic layout map, falling back to KeyCodeTranslator's static US map.
    func hidKeycode(for character: Character) -> (keyCode: UInt8, modifiers: UInt8)? {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else {
            return KeyCodeTranslator.hidKeycode(for: character)
        }

        // Try dynamic map first
        if let mapping = charMap[scalar] {
            guard let hidCode = KeyCodeTranslator.hidUsageCode(from: mapping.virtualKeyCode) else {
                return KeyCodeTranslator.hidKeycode(for: character)
            }
            let modifiers = hidModifierByte(for: mapping.modifierCombo)
            return (keyCode: hidCode, modifiers: modifiers)
        }

        // Fall back to static US map
        return KeyCodeTranslator.hidKeycode(for: character)
    }

    /// The keystrokes that type `text`, resolved against the live layout.
    /// Main thread only (see rebuildMap); resolve here, then pace the sends
    /// from any queue.
    func keystrokes(for text: String) -> [CharacterComposer.Keystroke] {
        dispatchPrecondition(condition: .onQueue(.main))
        return Self.keystrokes(for: text, mapper: hidKeycode(for:))
    }

    /// One keystroke per character `mapper` can produce, in order. Characters
    /// it can't produce are skipped.
    static func keystrokes(for text: String,
                           mapper: (Character) -> (keyCode: UInt8, modifiers: UInt8)?) -> [CharacterComposer.Keystroke] {
        text.compactMap { character in
            guard let mapping = mapper(character) else {
                Log.hid.debug("No HID mapping for character: \(String(character), privacy: .private)")
                return nil
            }
            return CharacterComposer.Keystroke(keyCode: mapping.keyCode, modifiers: mapping.modifiers)
        }
    }

    /// Convert modifier combo index to HID modifier byte.
    /// 0=none, 1=Left Shift(0x02), 2=Left Alt(0x04), 3=Left Shift+Left Alt(0x06)
    private func hidModifierByte(for combo: Int) -> UInt8 {
        switch combo {
        case 1:  return 0x02 // Left Shift
        case 2:  return 0x04 // Left Alt/Option
        case 3:  return 0x06 // Left Shift + Left Alt
        default: return 0x00 // No modifiers
        }
    }

    // UCKeyTranslate modifier bits (from Carbon)
    private static let shiftBit: UInt32 = (1 << 1) // shiftKey >> 8
    private static let optionBit: UInt32 = (1 << 3) // optionKey >> 8
    private var shiftBit: UInt32 { Self.shiftBit }
    private var optionBit: UInt32 { Self.optionBit }
}
