import Foundation

/// Expands characters beyond KeyCodeTranslator's US-ASCII map into HID
/// keystroke sequences using the US layout's Option layer — Option dead keys
/// for accents (Option+E then E → é) and direct Option symbols (Option+S → ß).
///
/// The host must use a US-style layout for these to produce the right glyphs;
/// that matches the assumption KeyCodeTranslator's character map already makes.
enum CharacterComposer {

    struct Keystroke: Equatable {
        let keyCode: UInt8
        let modifiers: UInt8
    }

    private static let shift: UInt8 = 0x02
    private static let option: UInt8 = 0x04

    /// The keystroke sequence that produces `character`, or nil when it can't
    /// be composed over HID (caller should count and surface the drop).
    static func keystrokes(for character: Character) -> [Keystroke]? {
        if let direct = KeyCodeTranslator.hidKeycode(for: character) {
            return [Keystroke(keyCode: direct.keyCode, modifiers: direct.modifiers)]
        }

        if character.unicodeScalars.count == 1,
           let scalar = character.unicodeScalars.first,
           let mapped = optionLayer[scalar] {
            return [mapped]
        }

        return deadKeySequence(for: character)
    }

    /// NFD-decompose and drive the accent through its Option dead key:
    /// é → [Option+E, e]. Only single-combining-mark characters whose base is
    /// directly typeable are composable.
    private static func deadKeySequence(for character: Character) -> [Keystroke]? {
        let decomposed = String(character).decomposedStringWithCanonicalMapping
        let scalars = Array(decomposed.unicodeScalars)
        guard scalars.count == 2,
              let deadKey = combiningMarkDeadKeys[scalars[1]],
              let base = KeyCodeTranslator.hidKeycode(for: Character(scalars[0])) else {
            return nil
        }
        return [deadKey, Keystroke(keyCode: base.keyCode, modifiers: base.modifiers)]
    }

    /// Combining mark → the US-layout Option dead key that types it.
    private static let combiningMarkDeadKeys: [Unicode.Scalar: Keystroke] = [
        "\u{0300}": Keystroke(keyCode: 0x35, modifiers: option),  // grave      Option+`
        "\u{0301}": Keystroke(keyCode: 0x08, modifiers: option),  // acute      Option+E
        "\u{0302}": Keystroke(keyCode: 0x0C, modifiers: option),  // circumflex Option+I
        "\u{0303}": Keystroke(keyCode: 0x11, modifiers: option),  // tilde      Option+N
        "\u{0308}": Keystroke(keyCode: 0x18, modifiers: option),  // diaeresis  Option+U
        "\u{030A}": Keystroke(keyCode: 0x0E, modifiers: option),  // ring       Option+K
    ]

    /// Directly typeable Option-layer symbols on the US layout.
    private static let optionLayer: [Unicode.Scalar: Keystroke] = [
        // Latin letters with no decomposition
        "ß": Keystroke(keyCode: 0x16, modifiers: option),          // Option+S
        "ç": Keystroke(keyCode: 0x06, modifiers: option),          // Option+C
        "Ç": Keystroke(keyCode: 0x06, modifiers: option | shift),
        "æ": Keystroke(keyCode: 0x34, modifiers: option),          // Option+'
        "Æ": Keystroke(keyCode: 0x34, modifiers: option | shift),
        "ø": Keystroke(keyCode: 0x12, modifiers: option),          // Option+O
        "Ø": Keystroke(keyCode: 0x12, modifiers: option | shift),
        "œ": Keystroke(keyCode: 0x14, modifiers: option),          // Option+Q
        "Œ": Keystroke(keyCode: 0x14, modifiers: option | shift),

        // Currency and legal
        "€": Keystroke(keyCode: 0x1F, modifiers: option | shift),  // Option+Shift+2
        "£": Keystroke(keyCode: 0x20, modifiers: option),          // Option+3
        "¥": Keystroke(keyCode: 0x1C, modifiers: option),          // Option+Y
        "¢": Keystroke(keyCode: 0x21, modifiers: option),          // Option+4
        "©": Keystroke(keyCode: 0x0A, modifiers: option),          // Option+G
        "®": Keystroke(keyCode: 0x15, modifiers: option),          // Option+R
        "™": Keystroke(keyCode: 0x1F, modifiers: option),          // Option+2

        // Punctuation and typography
        "¡": Keystroke(keyCode: 0x1E, modifiers: option),          // Option+1
        "¿": Keystroke(keyCode: 0x38, modifiers: option | shift),  // Option+Shift+/
        "–": Keystroke(keyCode: 0x2D, modifiers: option),          // en dash
        "—": Keystroke(keyCode: 0x2D, modifiers: option | shift),  // em dash
        "…": Keystroke(keyCode: 0x33, modifiers: option),          // Option+;
        "\u{201C}": Keystroke(keyCode: 0x2F, modifiers: option),           // “ Option+[
        "\u{201D}": Keystroke(keyCode: 0x2F, modifiers: option | shift),   // ” Option+Shift+[
        "\u{2018}": Keystroke(keyCode: 0x30, modifiers: option),           // ‘ Option+]
        "\u{2019}": Keystroke(keyCode: 0x30, modifiers: option | shift),   // ’ Option+Shift+]
        "«": Keystroke(keyCode: 0x31, modifiers: option),          // Option+\
        "»": Keystroke(keyCode: 0x31, modifiers: option | shift),
        "‹": Keystroke(keyCode: 0x20, modifiers: option | shift),  // Option+Shift+3
        "›": Keystroke(keyCode: 0x21, modifiers: option | shift),  // Option+Shift+4
        "†": Keystroke(keyCode: 0x17, modifiers: option),          // Option+T
        "‡": Keystroke(keyCode: 0x24, modifiers: option | shift),  // Option+Shift+7
        "•": Keystroke(keyCode: 0x25, modifiers: option),          // Option+8
        "¶": Keystroke(keyCode: 0x24, modifiers: option),          // Option+7
        "§": Keystroke(keyCode: 0x23, modifiers: option),          // Option+6
        "ª": Keystroke(keyCode: 0x26, modifiers: option),          // Option+9
        "º": Keystroke(keyCode: 0x27, modifiers: option),          // Option+0
        "‰": Keystroke(keyCode: 0x15, modifiers: option | shift),  // Option+Shift+R
        "⁄": Keystroke(keyCode: 0x1E, modifiers: option | shift),  // Option+Shift+1

        // Math and science
        "°": Keystroke(keyCode: 0x25, modifiers: option | shift),  // Option+Shift+8
        "÷": Keystroke(keyCode: 0x38, modifiers: option),          // Option+/
        "≠": Keystroke(keyCode: 0x2E, modifiers: option),          // Option+=
        "±": Keystroke(keyCode: 0x2E, modifiers: option | shift),
        "≤": Keystroke(keyCode: 0x36, modifiers: option),          // Option+,
        "≥": Keystroke(keyCode: 0x37, modifiers: option),          // Option+.
        "µ": Keystroke(keyCode: 0x10, modifiers: option),          // Option+M
        "π": Keystroke(keyCode: 0x13, modifiers: option),          // Option+P
        "∏": Keystroke(keyCode: 0x13, modifiers: option | shift),
        "Ω": Keystroke(keyCode: 0x1D, modifiers: option),          // Option+Z
        "≈": Keystroke(keyCode: 0x1B, modifiers: option),          // Option+X
        "∆": Keystroke(keyCode: 0x0D, modifiers: option),          // Option+J
        "√": Keystroke(keyCode: 0x19, modifiers: option),          // Option+V
        "∫": Keystroke(keyCode: 0x05, modifiers: option),          // Option+B
        "¬": Keystroke(keyCode: 0x0F, modifiers: option),          // Option+L
        "∂": Keystroke(keyCode: 0x07, modifiers: option),          // Option+D
        "ƒ": Keystroke(keyCode: 0x09, modifiers: option),          // Option+F
    ]
}
