import SwiftUI
import Carbon.HIToolbox

struct ShortcutRecorderView: View {
    let action: ShortcutAction
    let currentShortcut: ShortcutBinding?
    let onRecord: (UInt16, CGEventFlags) -> Bool

    @State private var isRecording = false
    @State private var conflictMessage: String?
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(spacing: 2) {
            if isRecording {
                Text("Press shortcut\u{2026}")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .modifier(KeyCapGlassModifier())
                    .onAppear { startRecording() }
                    .onDisappear { stopRecording() }
            } else {
                Button {
                    isRecording = true
                } label: {
                    Text(shortcutDisplayString)
                        .font(.system(.body, design: .rounded))
                        .fontWeight(.medium)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .modifier(KeyCapGlassModifier())
            }

            if let conflict = conflictMessage {
                Text(conflict)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var shortcutDisplayString: String {
        guard let shortcut = currentShortcut else {
            return "None"
        }
        return formatShortcut(keyCode: shortcut.keyCode, modifiers: CGEventFlags(rawValue: shortcut.modifiers))
    }

    private func startRecording() {
        conflictMessage = nil
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))

            // Escape cancels recording
            if keyCode == UInt16(kVK_Escape) {
                isRecording = false
                return nil
            }

            // Require at least one modifier
            let hasModifier = flags.contains(.maskCommand)
                || flags.contains(.maskControl)
                || flags.contains(.maskAlternate)
                || flags.contains(.maskShift)
            guard hasModifier else {
                return nil
            }

            if onRecord(keyCode, flags) {
                conflictMessage = nil
                isRecording = false
            } else {
                conflictMessage = "Already in use"
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

// MARK: - Formatting Helpers

func formatShortcut(keyCode: UInt16, modifiers: CGEventFlags) -> String {
    var symbols = ""
    if modifiers.contains(.maskControl)   { symbols += "\u{2303}" }
    if modifiers.contains(.maskAlternate) { symbols += "\u{2325}" }
    if modifiers.contains(.maskShift)     { symbols += "\u{21E7}" }
    if modifiers.contains(.maskCommand)   { symbols += "\u{2318}" }
    symbols += keyName(for: keyCode)
    return symbols
}

func keyName(for keyCode: UInt16) -> String {
    switch Int(keyCode) {
    case kVK_ANSI_A: return "A"
    case kVK_ANSI_B: return "B"
    case kVK_ANSI_C: return "C"
    case kVK_ANSI_D: return "D"
    case kVK_ANSI_E: return "E"
    case kVK_ANSI_F: return "F"
    case kVK_ANSI_G: return "G"
    case kVK_ANSI_H: return "H"
    case kVK_ANSI_I: return "I"
    case kVK_ANSI_J: return "J"
    case kVK_ANSI_K: return "K"
    case kVK_ANSI_L: return "L"
    case kVK_ANSI_M: return "M"
    case kVK_ANSI_N: return "N"
    case kVK_ANSI_O: return "O"
    case kVK_ANSI_P: return "P"
    case kVK_ANSI_Q: return "Q"
    case kVK_ANSI_R: return "R"
    case kVK_ANSI_S: return "S"
    case kVK_ANSI_T: return "T"
    case kVK_ANSI_U: return "U"
    case kVK_ANSI_V: return "V"
    case kVK_ANSI_W: return "W"
    case kVK_ANSI_X: return "X"
    case kVK_ANSI_Y: return "Y"
    case kVK_ANSI_Z: return "Z"
    case kVK_ANSI_0: return "0"
    case kVK_ANSI_1: return "1"
    case kVK_ANSI_2: return "2"
    case kVK_ANSI_3: return "3"
    case kVK_ANSI_4: return "4"
    case kVK_ANSI_5: return "5"
    case kVK_ANSI_6: return "6"
    case kVK_ANSI_7: return "7"
    case kVK_ANSI_8: return "8"
    case kVK_ANSI_9: return "9"
    case kVK_F1:  return "F1"
    case kVK_F2:  return "F2"
    case kVK_F3:  return "F3"
    case kVK_F4:  return "F4"
    case kVK_F5:  return "F5"
    case kVK_F6:  return "F6"
    case kVK_F7:  return "F7"
    case kVK_F8:  return "F8"
    case kVK_F9:  return "F9"
    case kVK_F10: return "F10"
    case kVK_F11: return "F11"
    case kVK_F12: return "F12"
    case kVK_Return:        return "\u{21A9}"
    case kVK_Tab:           return "\u{21E5}"
    case kVK_Space:         return "Space"
    case kVK_Delete:        return "\u{232B}"
    case kVK_ForwardDelete: return "\u{2326}"
    case kVK_Escape:        return "\u{238B}"
    case kVK_LeftArrow:     return "\u{2190}"
    case kVK_RightArrow:    return "\u{2192}"
    case kVK_UpArrow:       return "\u{2191}"
    case kVK_DownArrow:     return "\u{2193}"
    case kVK_Home:          return "\u{2196}"
    case kVK_End:           return "\u{2198}"
    case kVK_PageUp:        return "PgUp"
    case kVK_PageDown:      return "PgDn"
    case kVK_ANSI_Minus:    return "-"
    case kVK_ANSI_Equal:    return "="
    case kVK_ANSI_LeftBracket:  return "["
    case kVK_ANSI_RightBracket: return "]"
    case kVK_ANSI_Backslash:    return "\\"
    case kVK_ANSI_Semicolon:    return ";"
    case kVK_ANSI_Quote:        return "'"
    case kVK_ANSI_Grave:        return "`"
    case kVK_ANSI_Comma:        return ","
    case kVK_ANSI_Period:       return "."
    case kVK_ANSI_Slash:        return "/"
    default: return "Key\(keyCode)"
    }
}
