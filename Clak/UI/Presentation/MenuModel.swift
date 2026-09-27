import AppKit

struct MenuItemSpec: Equatable {
    enum Command: Equatable {
        case none
        case separator
        case showWindow
        case toggleForwarding
        case toggleGlobalForwarding
        case reconnect
        case openSystemSettings(SettingsDestination)
        case showSettings
        case quit
    }

    var command: Command
    var title: String
    var keyEquivalent: String = ""
    var modifiers: NSEvent.ModifierFlags = []
    var isEnabled = true
    var isChecked = false
    var symbolName: String?

    static let separator = MenuItemSpec(command: .separator, title: "", isEnabled: false)
}

/// The status-item menu as data. Chords come from the user's bindings, so
/// the menu never advertises a shortcut that does something else.
enum MenuModel {
    static func items(_ input: HUDInput, bindings: [ShortcutBinding]) -> [MenuItemSpec] {
        let presentation = HUDPresentation.make(input, bindings: bindings)
        let connected = input.isConnected
        var items: [MenuItemSpec] = []

        items.append(MenuItemSpec(
            command: .none,
            title: presentation.status,
            isEnabled: false,
            symbolName: statusSymbol(presentation.tone)
        ))
        if let destination = presentation.settings {
            items.append(MenuItemSpec(
                command: .openSystemSettings(destination),
                title: destination.menuTitle,
                symbolName: "gearshape.2"
            ))
        }

        items.append(.separator)
        items.append(MenuItemSpec(command: .showWindow, title: "Show Clak", symbolName: "macwindow"))
        items.append(.separator)

        items.append(bound(
            MenuItemSpec(
                command: .toggleForwarding,
                title: input.isForwarding ? "Pause Forwarding" : "Resume Forwarding",
                isEnabled: connected,
                symbolName: input.isForwarding ? "pause.circle" : "play.circle"
            ),
            to: .toggleForwarding, bindings
        ))
        items.append(bound(
            MenuItemSpec(
                command: .toggleGlobalForwarding,
                title: "Global Forwarding",
                isEnabled: connected,
                isChecked: input.isGlobalForwarding,
                symbolName: "globe"
            ),
            to: .toggleGlobalForwarding, bindings
        ))
        items.append(bound(
            MenuItemSpec(
                command: .reconnect,
                title: "Reconnect",
                isEnabled: input.bluetooth == .on,
                symbolName: "arrow.triangle.2.circlepath"
            ),
            to: .disconnectDevice, bindings
        ))

        items.append(.separator)
        items.append(MenuItemSpec(
            command: .showSettings, title: "Settings\u{2026}",
            keyEquivalent: ",", modifiers: [.command], symbolName: "gearshape"
        ))
        items.append(.separator)
        items.append(MenuItemSpec(
            command: .quit, title: "Quit Clak",
            keyEquivalent: "q", modifiers: [.command], symbolName: "power"
        ))
        return items
    }

    private static func bound(_ item: MenuItemSpec, to action: ShortcutAction, _ bindings: [ShortcutBinding]) -> MenuItemSpec {
        guard let chord = ShortcutChord.binding(for: action, in: bindings) else {
            return item
        }
        var item = item
        item.keyEquivalent = chord.menuKeyEquivalent
        item.modifiers = item.keyEquivalent.isEmpty ? [] : chord.menuModifiers
        return item
    }

    private static func statusSymbol(_ tone: HUDPresentation.Tone) -> String {
        switch tone {
        case .ready, .global: "iphone.circle.fill"
        case .paused: "pause.circle"
        case .waiting: "antenna.radiowaves.left.and.right"
        case .attention: "exclamationmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }
}
