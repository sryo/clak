#if os(macOS)
import Carbon.HIToolbox
import CoreGraphics
#endif

// MARK: - KeyCodeTranslator

/// Translates macOS virtual keycodes and CGEventFlags to USB HID usage codes.
/// The character-to-HID mapping is platform-neutral and shared with ClakRemote (iOS).
///
/// Virtual keycodes come from Carbon.HIToolbox/Events.h (kVK_* constants).
/// HID usage codes come from the USB HID Usage Tables, Keyboard/Keypad page (0x07).
enum KeyCodeTranslator {

    #if os(macOS)
    // MARK: - Virtual Keycode to HID Usage Code

    /// Translate a macOS virtual keycode to its corresponding USB HID usage code.
    /// - Parameter virtualKeyCode: The macOS virtual keycode (e.g. `kVK_ANSI_A`).
    /// - Returns: The USB HID usage code, or `nil` if the keycode is not mapped.
    static func hidUsageCode(from virtualKeyCode: UInt16) -> UInt8? {
        virtualKeyToHID[virtualKeyCode]
    }

    // MARK: - CGEventFlags to HID Modifier Byte

    /// Translate CGEventFlags to the HID modifier byte used in keyboard reports.
    ///
    /// The HID modifier byte layout:
    /// - Bit 0: Left Control
    /// - Bit 1: Left Shift
    /// - Bit 2: Left Alt/Option
    /// - Bit 3: Left GUI/Command
    /// - Bit 4: Right Control
    /// - Bit 5: Right Shift
    /// - Bit 6: Right Alt/Option
    /// - Bit 7: Right GUI/Command
    ///
    /// - Parameter flags: The CGEventFlags from a keyboard event.
    /// - Returns: The HID modifier byte.
    static func modifierByte(from flags: CGEventFlags) -> UInt8 {
        var result: UInt8 = 0

        let raw = flags.rawValue

        // Device-specific right modifier masks from IOKit (NX_DEVICE* constants).
        // These are the raw bitmask values used in CGEventFlags.rawValue.
        let nxDeviceRightControlMask:  UInt64 = 0x0000_2000
        let nxDeviceRightShiftMask:    UInt64 = 0x0000_0004
        let nxDeviceRightAlternateMask: UInt64 = 0x0000_0040
        let nxDeviceRightCommandMask:  UInt64 = 0x0000_0010

        let nxDeviceLeftControlMask:   UInt64 = 0x0000_0001
        let nxDeviceLeftShiftMask:     UInt64 = 0x0000_0002
        let nxDeviceLeftAlternateMask: UInt64 = 0x0000_0020
        let nxDeviceLeftCommandMask:   UInt64 = 0x0000_0008

        // Check left modifiers. If the generic flag is set but no device-specific
        // right flag is set, treat it as a left modifier press.
        if flags.contains(.maskControl) {
            if raw & nxDeviceRightControlMask != 0 {
                result |= 0x10 // Right Control
            }
            if raw & nxDeviceLeftControlMask != 0 || raw & nxDeviceRightControlMask == 0 {
                result |= 0x01 // Left Control
            }
        }

        if flags.contains(.maskShift) {
            if raw & nxDeviceRightShiftMask != 0 {
                result |= 0x20 // Right Shift
            }
            if raw & nxDeviceLeftShiftMask != 0 || raw & nxDeviceRightShiftMask == 0 {
                result |= 0x02 // Left Shift
            }
        }

        if flags.contains(.maskAlternate) {
            if raw & nxDeviceRightAlternateMask != 0 {
                result |= 0x40 // Right Alt
            }
            if raw & nxDeviceLeftAlternateMask != 0 || raw & nxDeviceRightAlternateMask == 0 {
                result |= 0x04 // Left Alt
            }
        }

        if flags.contains(.maskCommand) {
            if raw & nxDeviceRightCommandMask != 0 {
                result |= 0x80 // Right GUI
            }
            if raw & nxDeviceLeftCommandMask != 0 || raw & nxDeviceRightCommandMask == 0 {
                result |= 0x08 // Left GUI
            }
        }

        return result
    }
    #endif

    // MARK: - Character to HID Keycode

    /// Convert an ASCII character to its HID keycode and required modifier byte.
    ///
    /// This supports the US keyboard layout:
    /// - Lowercase and uppercase letters
    /// - Digits and their shifted symbols
    /// - Common punctuation and special characters
    ///
    /// - Parameter character: The character to translate.
    /// - Returns: A tuple of (HID keycode, HID modifier byte), or `nil` if unsupported.
    static func hidKeycode(for character: Character) -> (keyCode: UInt8, modifiers: UInt8)? {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else {
            return nil
        }
        return characterToHID[scalar]
    }

    // MARK: - Mapping Tables

    #if os(macOS)
    // swiftlint:disable comma

    /// Complete mapping from macOS virtual keycodes to USB HID usage codes.
    private static let virtualKeyToHID: [UInt16: UInt8] = [
        // Letters (ANSI layout)
        UInt16(kVK_ANSI_A):              0x04, // a
        UInt16(kVK_ANSI_B):              0x05, // b
        UInt16(kVK_ANSI_C):              0x06, // c
        UInt16(kVK_ANSI_D):              0x07, // d
        UInt16(kVK_ANSI_E):              0x08, // e
        UInt16(kVK_ANSI_F):              0x09, // f
        UInt16(kVK_ANSI_G):              0x0A, // g
        UInt16(kVK_ANSI_H):              0x0B, // h
        UInt16(kVK_ANSI_I):              0x0C, // i
        UInt16(kVK_ANSI_J):              0x0D, // j
        UInt16(kVK_ANSI_K):              0x0E, // k
        UInt16(kVK_ANSI_L):              0x0F, // l
        UInt16(kVK_ANSI_M):              0x10, // m
        UInt16(kVK_ANSI_N):              0x11, // n
        UInt16(kVK_ANSI_O):              0x12, // o
        UInt16(kVK_ANSI_P):              0x13, // p
        UInt16(kVK_ANSI_Q):              0x14, // q
        UInt16(kVK_ANSI_R):              0x15, // r
        UInt16(kVK_ANSI_S):              0x16, // s
        UInt16(kVK_ANSI_T):              0x17, // t
        UInt16(kVK_ANSI_U):              0x18, // u
        UInt16(kVK_ANSI_V):              0x19, // v
        UInt16(kVK_ANSI_W):              0x1A, // w
        UInt16(kVK_ANSI_X):              0x1B, // x
        UInt16(kVK_ANSI_Y):              0x1C, // y
        UInt16(kVK_ANSI_Z):              0x1D, // z

        // Numbers (top row)
        UInt16(kVK_ANSI_0):              0x27, // 0
        UInt16(kVK_ANSI_1):              0x1E, // 1
        UInt16(kVK_ANSI_2):              0x1F, // 2
        UInt16(kVK_ANSI_3):              0x20, // 3
        UInt16(kVK_ANSI_4):              0x21, // 4
        UInt16(kVK_ANSI_5):              0x22, // 5
        UInt16(kVK_ANSI_6):              0x23, // 6
        UInt16(kVK_ANSI_7):              0x24, // 7
        UInt16(kVK_ANSI_8):              0x25, // 8
        UInt16(kVK_ANSI_9):              0x26, // 9

        // Punctuation and symbols
        UInt16(kVK_ANSI_Minus):          0x2D, // -
        UInt16(kVK_ANSI_Equal):          0x2E, // =
        UInt16(kVK_ANSI_LeftBracket):    0x2F, // [
        UInt16(kVK_ANSI_RightBracket):   0x30, // ]
        UInt16(kVK_ANSI_Backslash):      0x31, // backslash
        UInt16(kVK_ANSI_Semicolon):      0x33, // ;
        UInt16(kVK_ANSI_Quote):          0x34, // '
        UInt16(kVK_ANSI_Grave):          0x35, // `
        UInt16(kVK_ANSI_Comma):          0x36, // ,
        UInt16(kVK_ANSI_Period):         0x37, // .
        UInt16(kVK_ANSI_Slash):          0x38, // /

        // Function keys
        UInt16(kVK_F1):                  0x3A,
        UInt16(kVK_F2):                  0x3B,
        UInt16(kVK_F3):                  0x3C,
        UInt16(kVK_F4):                  0x3D,
        UInt16(kVK_F5):                  0x3E,
        UInt16(kVK_F6):                  0x3F,
        UInt16(kVK_F7):                  0x40,
        UInt16(kVK_F8):                  0x41,
        UInt16(kVK_F9):                  0x42,
        UInt16(kVK_F10):                 0x43,
        UInt16(kVK_F11):                 0x44,
        UInt16(kVK_F12):                 0x45,

        // Special keys
        UInt16(kVK_Return):              0x28, // Return/Enter
        UInt16(kVK_Tab):                 0x2B, // Tab
        UInt16(kVK_Space):               0x2C, // Space
        UInt16(kVK_Delete):              0x2A, // Backspace (Delete on Mac)
        UInt16(kVK_ForwardDelete):       0x4C, // Forward Delete
        UInt16(kVK_Escape):              0x29, // Escape
        UInt16(kVK_CapsLock):            0x39, // Caps Lock

        // Arrow keys
        UInt16(kVK_LeftArrow):           0x50,
        UInt16(kVK_RightArrow):          0x4F,
        UInt16(kVK_UpArrow):             0x52,
        UInt16(kVK_DownArrow):           0x51,

        // Navigation
        UInt16(kVK_Home):                0x4A,
        UInt16(kVK_End):                 0x4D,
        UInt16(kVK_PageUp):              0x4B,
        UInt16(kVK_PageDown):            0x4E,

        // Modifier keys (included for completeness; typically handled via modifierByte)
        UInt16(kVK_Shift):               0xE1, // Left Shift
        UInt16(kVK_RightShift):          0xE5, // Right Shift
        UInt16(kVK_Control):             0xE0, // Left Control
        UInt16(kVK_RightControl):        0xE4, // Right Control
        UInt16(kVK_Option):              0xE2, // Left Alt/Option
        UInt16(kVK_RightOption):         0xE6, // Right Alt/Option
        UInt16(kVK_Command):             0xE3, // Left GUI/Command
        UInt16(kVK_RightCommand):        0xE7, // Right GUI/Command

        // Numpad digits
        UInt16(kVK_ANSI_Keypad0):        0x62,
        UInt16(kVK_ANSI_Keypad1):        0x59,
        UInt16(kVK_ANSI_Keypad2):        0x5A,
        UInt16(kVK_ANSI_Keypad3):        0x5B,
        UInt16(kVK_ANSI_Keypad4):        0x5C,
        UInt16(kVK_ANSI_Keypad5):        0x5D,
        UInt16(kVK_ANSI_Keypad6):        0x5E,
        UInt16(kVK_ANSI_Keypad7):        0x5F,
        UInt16(kVK_ANSI_Keypad8):        0x60,
        UInt16(kVK_ANSI_Keypad9):        0x61,

        // Numpad operations
        UInt16(kVK_ANSI_KeypadDecimal):  0x63, // Keypad .
        UInt16(kVK_ANSI_KeypadMultiply): 0x55, // Keypad *
        UInt16(kVK_ANSI_KeypadPlus):     0x57, // Keypad +
        UInt16(kVK_ANSI_KeypadMinus):    0x56, // Keypad -
        UInt16(kVK_ANSI_KeypadDivide):   0x54, // Keypad /
        UInt16(kVK_ANSI_KeypadEnter):    0x58, // Keypad Enter
        UInt16(kVK_ANSI_KeypadEquals):   0x67, // Keypad =
        UInt16(kVK_ANSI_KeypadClear):    0x53, // Num Lock / Clear
    ]

    // swiftlint:enable comma
    #endif

    // MARK: - Character Mapping (US Layout)

    /// Shift modifier constant for building the character map.
    private static let shift: UInt8 = 0x02

    /// Mapping from Unicode scalars to (HID keycode, modifier byte) for US keyboard layout.
    private static let characterToHID: [Unicode.Scalar: (keyCode: UInt8, modifiers: UInt8)] = {
        var map = [Unicode.Scalar: (keyCode: UInt8, modifiers: UInt8)]()

        // Lowercase letters: a-z -> HID 0x04-0x1D
        for i: UInt8 in 0...25 {
            let scalar = Unicode.Scalar(UInt8(ascii: "a") + i)
            map[scalar] = (keyCode: 0x04 + i, modifiers: 0x00)
        }

        // Uppercase letters: A-Z -> HID 0x04-0x1D with Shift
        for i: UInt8 in 0...25 {
            let scalar = Unicode.Scalar(UInt8(ascii: "A") + i)
            map[scalar] = (keyCode: 0x04 + i, modifiers: shift)
        }

        // Digits: 1-9 -> HID 0x1E-0x26, 0 -> HID 0x27
        for i: UInt8 in 1...9 {
            let scalar = Unicode.Scalar(UInt8(ascii: "0") + i)
            map[scalar] = (keyCode: 0x1D + i, modifiers: 0x00)
        }
        map[Unicode.Scalar(UInt8(ascii: "0"))] = (keyCode: 0x27, modifiers: 0x00)

        // Shifted digit symbols: ! @ # $ % ^ & * ( )
        let shiftedDigitSymbols: [(Character, UInt8)] = [
            ("!", 0x1E), // Shift+1
            ("@", 0x1F), // Shift+2
            ("#", 0x20), // Shift+3
            ("$", 0x21), // Shift+4
            ("%", 0x22), // Shift+5
            ("^", 0x23), // Shift+6
            ("&", 0x24), // Shift+7
            ("*", 0x25), // Shift+8
            ("(", 0x26), // Shift+9
            (")", 0x27), // Shift+0
        ]
        for (char, code) in shiftedDigitSymbols {
            guard let scalar = char.unicodeScalars.first else {
                continue
            }
            map[scalar] = (keyCode: code, modifiers: shift)
        }

        // Unshifted punctuation
        let unshiftedPunctuation: [(Character, UInt8)] = [
            ("-", 0x2D),  // Minus
            ("=", 0x2E),  // Equal
            ("[", 0x2F),  // Left Bracket
            ("]", 0x30),  // Right Bracket
            ("\\", 0x31), // Backslash
            (";", 0x33),  // Semicolon
            ("'", 0x34),  // Quote
            ("`", 0x35),  // Grave Accent
            (",", 0x36),  // Comma
            (".", 0x37),  // Period
            ("/", 0x38),  // Slash
        ]
        for (char, code) in unshiftedPunctuation {
            guard let scalar = char.unicodeScalars.first else {
                continue
            }
            map[scalar] = (keyCode: code, modifiers: 0x00)
        }

        // Shifted punctuation
        let shiftedPunctuation: [(Character, UInt8)] = [
            ("_", 0x2D),  // Shift+Minus
            ("+", 0x2E),  // Shift+Equal
            ("{", 0x2F),  // Shift+Left Bracket
            ("}", 0x30),  // Shift+Right Bracket
            ("|", 0x31),  // Shift+Backslash
            (":", 0x33),  // Shift+Semicolon
            ("\"", 0x34), // Shift+Quote
            ("~", 0x35),  // Shift+Grave
            ("<", 0x36),  // Shift+Comma
            (">", 0x37),  // Shift+Period
            ("?", 0x38),  // Shift+Slash
        ]
        for (char, code) in shiftedPunctuation {
            guard let scalar = char.unicodeScalars.first else {
                continue
            }
            map[scalar] = (keyCode: code, modifiers: shift)
        }

        // Whitespace and control
        map[Unicode.Scalar(UInt8(ascii: " "))] = (keyCode: 0x2C, modifiers: 0x00)   // Space
        map[Unicode.Scalar(0x0A)] = (keyCode: 0x28, modifiers: 0x00)                // Newline -> Return
        map[Unicode.Scalar(0x0D)] = (keyCode: 0x28, modifiers: 0x00)                // Carriage Return -> Return
        map[Unicode.Scalar(0x09)] = (keyCode: 0x2B, modifiers: 0x00)                // Tab

        return map
    }()
}
