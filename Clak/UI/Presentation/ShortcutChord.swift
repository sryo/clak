import AppKit
import Carbon.HIToolbox

/// A ShortcutBinding as the UI shows it: glyphs for the HUD, and an
/// NSMenuItem key equivalent for the menu bar.
struct ShortcutChord: Equatable {
    let keyCode: UInt16
    let flags: CGEventFlags

    init(_ binding: ShortcutBinding) {
        keyCode = binding.keyCode
        flags = CGEventFlags(rawValue: binding.modifiers)
    }

    static func binding(for action: ShortcutAction, in bindings: [ShortcutBinding]) -> ShortcutChord? {
        bindings.first { $0.action == action }.map(ShortcutChord.init)
    }

    /// "⇧⌘G", in the Apple menu order ⌃⌥⇧⌘.
    var display: String {
        formatShortcut(keyCode: keyCode, modifiers: flags)
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        return result
    }

    /// Empty when AppKit has no key equivalent for the key, so the item
    /// shows no chord rather than a wrong one.
    var menuKeyEquivalent: String {
        if let special = Self.specialKeyEquivalents[Int(keyCode)] {
            return UnicodeScalar(special).map { String($0) } ?? ""
        }
        let name = keyName(for: keyCode)
        guard name.count == 1 else {
            return ""
        }
        return name.lowercased()
    }

    private static let specialKeyEquivalents: [Int: Int] = [
        kVK_F1: NSF1FunctionKey, kVK_F2: NSF2FunctionKey, kVK_F3: NSF3FunctionKey,
        kVK_F4: NSF4FunctionKey, kVK_F5: NSF5FunctionKey, kVK_F6: NSF6FunctionKey,
        kVK_F7: NSF7FunctionKey, kVK_F8: NSF8FunctionKey, kVK_F9: NSF9FunctionKey,
        kVK_F10: NSF10FunctionKey, kVK_F11: NSF11FunctionKey, kVK_F12: NSF12FunctionKey,
        kVK_Return: 0x0D, kVK_Tab: 0x09, kVK_Space: 0x20, kVK_Delete: 0x08, kVK_Escape: 0x1B,
        kVK_ForwardDelete: NSDeleteFunctionKey,
        kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
        kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey,
        kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey,
        kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey,
    ]
}
