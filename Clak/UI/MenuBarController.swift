import Cocoa

final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    var onShowMainWindow: (() -> Void)?
    var onShowPreferences: (() -> Void)?
    var onToggleForwarding: (() -> Void)?
    var onToggleGlobalForwarding: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onQuit: (() -> Void)?

    /// Read each time the menu opens, so it reflects the current state and
    /// the current shortcut bindings. Falls back to the last pushed status.
    var inputProvider: (() -> HUDInput)?

    private var lastInput = HUDInput()

    // MARK: - Setup

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.toolTip = "Clak"

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item

        rebuild(menu)
        updateButtonAppearance()
    }

    // MARK: - Status Update

    func update(_ input: HUDInput) {
        lastInput = input
        if let menu = statusItem?.menu {
            rebuild(menu)
        }
        updateButtonAppearance()
    }

    func updateStatus(isConnected: Bool, deviceName: String?, isForwarding: Bool = true, isGlobalForwarding: Bool = false) {
        var input = inputProvider?() ?? lastInput
        input.isConnected = isConnected
        input.deviceName = deviceName
        input.isForwarding = isForwarding
        input.isGlobalForwarding = isGlobalForwarding
        update(input)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let inputProvider {
            lastInput = inputProvider()
        }
        rebuild(menu)
    }

    // MARK: - Private

    private func updateButtonAppearance() {
        guard let button = statusItem?.button else {
            return
        }

        let presentation = HUDPresentation.make(lastInput, bindings: KeyboardShortcutManager.shared.registeredShortcuts)
        let isConnected = lastInput.isConnected
        let symbolName = isConnected ? "keyboard.badge.ellipsis" : "keyboard"
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Clak, \(presentation.status)"
        )
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.image = image?.withSymbolConfiguration(config)
        button.contentTintColor = isConnected && lastInput.isForwarding ? .controlAccentColor : nil
        button.toolTip = "Clak: \(presentation.status)"
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let specs = MenuModel.items(lastInput, bindings: KeyboardShortcutManager.shared.registeredShortcuts)
        for spec in specs {
            menu.addItem(makeItem(spec))
        }
    }

    private func makeItem(_ spec: MenuItemSpec) -> NSMenuItem {
        if spec.command == .separator {
            return .separator()
        }

        let item = NSMenuItem(title: spec.title, action: nil, keyEquivalent: spec.keyEquivalent)
        item.keyEquivalentModifierMask = spec.modifiers
        item.isEnabled = spec.isEnabled
        item.state = spec.isChecked ? .on : .off
        item.representedObject = CommandBox(spec.command)
        if spec.command != .none {
            item.target = self
            item.action = #selector(handleMenuItem(_:))
        }
        if let symbolName = spec.symbolName {
            item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        }
        return item
    }

    @objc private func handleMenuItem(_ sender: NSMenuItem) {
        guard let command = (sender.representedObject as? CommandBox)?.command else {
            return
        }
        switch command {
        case .none, .separator: break
        case .showWindow: onShowMainWindow?()
        case .toggleForwarding: onToggleForwarding?()
        case .toggleGlobalForwarding: onToggleGlobalForwarding?()
        case .reconnect: onReconnect?()
        case .openSystemSettings(let destination): PermissionChecker.open(destination)
        case .showSettings: onShowPreferences?()
        case .quit: onQuit?()
        }
    }
}

private final class CommandBox {
    let command: MenuItemSpec.Command
    init(_ command: MenuItemSpec.Command) { self.command = command }
}
