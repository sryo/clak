import Foundation

/// Maps F7–F12 virtual keycodes to USB HID Consumer Page usages so the standard
/// Mac media-key row controls playback/volume on the connected device.
/// (Hardware media-key presses arrive as NX_SYSDEFINED events, not key-downs;
/// capturing those is a follow-up — these mappings fire when the keys arrive
/// as plain F-keys, e.g. with Fn held or "Use F1, F2… as function keys" enabled.)
enum ConsumerKeyMapper {
    private static let usages: [UInt16: UInt16] = [
        98:  0x00B6, // F7  → Scan Previous Track
        100: 0x00CD, // F8  → Play/Pause
        101: 0x00B5, // F9  → Scan Next Track
        109: 0x00E2, // F10 → Mute
        103: 0x00EA, // F11 → Volume Down
        111: 0x00E9, // F12 → Volume Up
    ]

    static func usage(for keyCode: UInt16) -> UInt16? {
        usages[keyCode]
    }
}
