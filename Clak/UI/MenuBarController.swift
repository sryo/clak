import Cocoa

final class MenuBarController {
    private var statusItem: NSStatusItem?

    var onShowMainWindow: (() -> Void)?
    var onShowPreferences: (() -> Void)?
    var onToggleForwarding: (() -> Void)?
    var onToggleGlobalForwarding: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onQuit: (() -> Void)?

    private var currentIsConnected = false
    private var currentDeviceName: String?
    private var currentIsForwarding = true
    private var currentIsGlobalForwarding = false

    // MARK: - Setup

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "keyboard",
                accessibilityDescription: "Clak"
            )
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = image?.withSymbolConfiguration(config)
            button.toolTip = "Clak"
        }

        item.menu = buildMenu()
        statusItem = item

        updateButtonAppearance(isConnected: false)
    }

    // MARK: - Status Update

    func updateStatus(isConnected: Bool, deviceName: String?, isForwarding: Bool = true, isGlobalForwarding: Bool = false) {
        currentIsConnected = isConnected
        currentDeviceName = deviceName
        currentIsForwarding = isForwarding
        currentIsGlobalForwarding = isGlobalForwarding

        // Rebuild the menu to reflect new state
        statusItem?.menu = buildMenu()
        updateButtonAppearance(isConnected: isConnected)
    }

    // MARK: - Private

    private func updateButtonAppearance(isConnected: Bool) {
        guard let button = statusItem?.button else {
            return
        }

        let symbolName = isConnected ? "keyboard.badge.ellipsis" : "keyboard"
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: isConnected ? "Clak - Connected" : "Clak"
        )
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.image = image?.withSymbolConfiguration(config)

        if isConnected {
            button.contentTintColor = .controlAccentColor
        } else {
            button.contentTintColor = nil
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Show Clak
        let showItem = NSMenuItem(
            title: "Show Clak",
            action: #selector(handleShowMainWindow),
            keyEquivalent: ""
        )
        showItem.target = self
        showItem.image = NSImage(
            systemSymbolName: "macwindow",
            accessibilityDescription: "Show main window"
        )
        menu.addItem(showItem)

        menu.addItem(.separator())

        // Connection info
        if currentIsConnected, let name = currentDeviceName {
            let deviceItem = NSMenuItem(
                title: name,
                action: nil,
                keyEquivalent: ""
            )
            deviceItem.isEnabled = false
            deviceItem.image = NSImage(
                systemSymbolName: "iphone.circle.fill",
                accessibilityDescription: "Connected device"
            )
            menu.addItem(deviceItem)

            // Toggle Forwarding
            let forwardingItem = NSMenuItem(
                title: currentIsForwarding ? "Pause Forwarding" : "Resume Forwarding",
                action: #selector(handleToggleForwarding),
                keyEquivalent: "f"
            )
            forwardingItem.target = self
            forwardingItem.keyEquivalentModifierMask = [.command, .shift]
            forwardingItem.image = NSImage(
                systemSymbolName: currentIsForwarding ? "pause.circle" : "play.circle",
                accessibilityDescription: currentIsForwarding ? "Pause forwarding" : "Resume forwarding"
            )
            menu.addItem(forwardingItem)

            // Global Forwarding (type without keeping Clak focused)
            let globalItem = NSMenuItem(
                title: "Global Forwarding",
                action: #selector(handleToggleGlobalForwarding),
                keyEquivalent: "g"
            )
            globalItem.target = self
            globalItem.keyEquivalentModifierMask = [.command, .shift]
            globalItem.state = currentIsGlobalForwarding ? .on : .off
            globalItem.image = NSImage(
                systemSymbolName: "globe",
                accessibilityDescription: "Toggle global forwarding"
            )
            menu.addItem(globalItem)

            let reconnectItem = NSMenuItem(
                title: "Reconnect",
                action: #selector(handleReconnect),
                keyEquivalent: "r"
            )
            reconnectItem.target = self
            reconnectItem.keyEquivalentModifierMask = [.command, .shift]
            reconnectItem.image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: "Reconnect"
            )
            menu.addItem(reconnectItem)
        } else {
            let searchingItem = NSMenuItem(
                title: "Searching...",
                action: nil,
                keyEquivalent: ""
            )
            searchingItem.isEnabled = false
            searchingItem.image = NSImage(
                systemSymbolName: "antenna.radiowaves.left.and.right",
                accessibilityDescription: "Searching for device"
            )
            menu.addItem(searchingItem)
        }

        menu.addItem(.separator())

        // Preferences
        let prefsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(handleShowPreferences),
            keyEquivalent: ","
        )
        prefsItem.target = self
        prefsItem.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "Open settings"
        )
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit Clak",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.image = NSImage(
            systemSymbolName: "power",
            accessibilityDescription: "Quit application"
        )
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Actions

    @objc private func handleShowMainWindow() {
        onShowMainWindow?()
    }

    @objc private func handleShowPreferences() {
        onShowPreferences?()
    }

    @objc private func handleToggleForwarding() {
        onToggleForwarding?()
    }

    @objc private func handleToggleGlobalForwarding() {
        onToggleGlobalForwarding?()
    }

    @objc private func handleReconnect() {
        onReconnect?()
    }

    @objc private func handleQuit() {
        onQuit?()
    }
}
