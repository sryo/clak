import Foundation

/// Maps the Mac's media-key row to USB HID Consumer Page usages so it controls
/// brightness, search, dictation, playback and volume on the connected device.
/// (Hardware media-key presses arrive as NX_SYSDEFINED events, not key-downs;
/// capturing those is a follow-up — these mappings fire when the keys arrive
/// as plain F-keys, e.g. with Fn held or "Use F1, F2… as function keys" enabled.)
enum ConsumerKeyMapper {
    private static let usages: [UInt16: UInt16] = [
        122: 0x0070, // F1  → Display Brightness Decrement
        120: 0x006F, // F2  → Display Brightness Increment
        118: 0x0221, // F4  → AC Search (Spotlight)
        96:  0x00CF, // F5  → Voice Command (Dictation)
        177: 0x0221, // Spotlight key on newer Apple keyboards
        176: 0x00CF, // Dictation key on newer Apple keyboards
        98:  0x00B6, // F7  → Scan Previous Track
        100: 0x00CD, // F8  → Play/Pause
        101: 0x00B5, // F9  → Scan Next Track
        109: 0x00E2, // F10 → Mute
        103: 0x00EA, // F11 → Volume Down
        111: 0x00E9, // F12 → Volume Up
    ]

    /// AC Next Keyboard Layout Select: what a tap of the Globe key does on an
    /// iPad's own keyboard.
    static let globeUsage: UInt16 = 0x029D

    static func usage(for keyCode: UInt16) -> UInt16? {
        usages[keyCode]
    }
}
