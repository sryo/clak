import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, KeyboardEventCaptureDelegate {
    let appState = AppState()
    let bluetoothManager = BluetoothManager()
    private let keyboardCapture = KeyboardEventCapture()
    private let modifierTracker = ModifierKeyTracker()
    private let pressedKeys = PressedKeyTracker()
    private let shortcutManager = KeyboardShortcutManager.shared
    private let menuBarController = MenuBarController()

    private var isAppActive = false
    private var localKeyMonitor: Any?
    private var windowTopLeft: NSPoint?
    private var windowObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    /// Guard flag: true while we are programmatically correcting the window
    /// origin inside didResize, so that the didMove observer does not
    /// overwrite windowTopLeft with the intermediate (wrong) position.
    private var isCorrectingPosition = false

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Clak launching")

        // Configure main window as floating compact HUD
        DispatchQueue.main.async { [weak self] in
            self?.configureMainWindow()
        }

        // Set up menu bar
        menuBarController.setup()
        menuBarController.onShowMainWindow = {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.title == "Clak" || $0.isKeyWindow }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
        menuBarController.onShowPreferences = {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        menuBarController.onToggleForwarding = { [weak self] in
            self?.toggleForwarding()
        }
        menuBarController.onToggleGlobalForwarding = { [weak self] in
            self?.toggleGlobalForwarding()
        }
        menuBarController.onReconnect = { [weak self] in
            self?.bluetoothManager.disconnectAndReAdvertise()
        }
        menuBarController.onQuit = {
            NSApp.terminate(nil)
        }

        // Register default keyboard shortcuts
        shortcutManager.registerDefaults()

        // Request Input Monitoring permission
        if !PermissionChecker.hasInputMonitoringPermission {
            Log.app.warning("Input Monitoring permission not granted, requesting access")
            CGRequestListenEventAccess()
            appState.needsInputMonitoring = true
        }

        // Set up keyboard capture (will succeed only if permission was already granted)
        keyboardCapture.delegate = self
        if keyboardCapture.startCapture() {
            appState.needsInputMonitoring = false
        }

        // Persisted global mode is only honored if Accessibility is still granted
        if appState.isGlobalForwarding && !PermissionChecker.hasAccessibilityPermission {
            appState.isGlobalForwarding = false
            AppPreferences.shared.globalForwardingEnabled = false
            Log.app.warning("Global forwarding disabled — Accessibility permission missing")
        }

        // Wire instant state callback from BluetoothManager
        bluetoothManager.onStateChange = { [weak self] state in
            self?.handleBluetoothStateChange(state)
        }
        bluetoothManager.onLEDStateChange = { [weak self] capsLock in
            self?.appState.capsLockActive = capsLock
        }

        // Auto-start advertising — BLE layer handles poweredOn callback
        bluetoothManager.startAdvertising()

        if AppPreferences.shared.trackpadScrollEnabled {
            ScrollEnhancer.shared.start()
        }

        // Suppress system beep by consuming key events at the app level
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { _ in
            return nil  // Swallow all key events — they're handled by the CGEventTap
        }

        Log.app.info("Clak launch complete")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("Clak terminating")
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let obs = windowObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = moveObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        keyboardCapture.stopCapture()
        ScrollEnhancer.shared.stop()
        bluetoothManager.teardownCompletely()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        isAppActive = true
        Log.app.debug("App became active")

        // Re-attempt keyboard capture in case Input Monitoring was granted while away
        if appState.needsInputMonitoring && !keyboardCapture.isCapturing {
            if keyboardCapture.startCapture() {
                appState.needsInputMonitoring = false
                Log.app.info("Input Monitoring permission now granted, capture started")
            }
        }

        // Pick up Accessibility grants made while away (tap must be recreated to consume)
        if appState.needsAccessibility && PermissionChecker.hasAccessibilityPermission {
            appState.needsAccessibility = false
            keyboardCapture.restartCapture()
            Log.app.info("Accessibility permission now granted")
        }

        if AppPreferences.shared.trackpadScrollEnabled && !ScrollEnhancer.shared.isRunning {
            ScrollEnhancer.shared.start()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        isAppActive = false
        // In global mode losing focus is normal — keys stay held across app switches
        if !appState.isGlobalForwarding {
            releaseAllForwardedKeys()
        }
        Log.app.debug("App resigned active")
    }

    /// Stuck-key failsafe: clear the tracker and release everything on the device.
    private func releaseAllForwardedKeys() {
        pressedKeys.reset()
        bluetoothManager.sendKeyUp()
    }

    // MARK: - Window Configuration

    private func configureMainWindow() {
        guard let window = NSApp.windows.first(where: { $0.title == "Clak" }) else {
            return
        }

        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentMinSize = NSSize(width: 1, height: 1)
        if let screen = window.screen ?? NSScreen.main {
            window.contentMaxSize = NSSize(width: screen.visibleFrame.width - 40, height: screen.visibleFrame.height)
        }

        if #available(macOS 26, *) {
            // Liquid Glass: borderless transparent window, .glassEffect on content handles visuals
            window.styleMask = [.borderless]
            window.hasShadow = true
        } else {
            // Pre-Tahoe: borderless + NSVisualEffectView for HUD look
            window.styleMask = [.borderless, .fullSizeContentView]
            window.hasShadow = true
            applyLegacyHUDBackground(to: window)
        }

        // Pin top-left corner during resize so the window grows right/down.
        //
        // Root cause of the previous drift bug: didMoveNotification fires
        // when setFrameOrigin() is called inside the didResize handler,
        // which overwrites windowTopLeft with the intermediate (wrong)
        // position that SwiftUI's Window scene chose during its resize.
        // The isCorrectingPosition flag breaks this feedback loop.
        windowTopLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow,
                  let topLeft = self.windowTopLeft else { return }
            let newOrigin = NSPoint(x: topLeft.x, y: topLeft.y - window.frame.height)
            if window.frame.origin != newOrigin {
                self.isCorrectingPosition = true
                window.setFrameOrigin(newOrigin)
                self.isCorrectingPosition = false
            }
        }

        // Track when the user drags the window (but not programmatic moves).
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self] notification in
            guard let self, !self.isCorrectingPosition,
                  let window = notification.object as? NSWindow else { return }
            self.windowTopLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        }
    }

    /// Pre-macOS 26 fallback: wrap SwiftUI content in NSVisualEffectView with .hudWindow material.
    private func applyLegacyHUDBackground(to window: NSWindow) {
        guard let swiftUIView = window.contentView else { return }

        // Outer container — owns the shadow, no clipping
        let container = NSView()
        container.wantsLayer = true
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.4
        container.layer?.shadowRadius = 20
        container.layer?.shadowOffset = CGSize(width: 0, height: -4)
        container.layer?.cornerRadius = 16

        // Inner effect view — clips to rounded corners
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.appearance = NSAppearance(named: .darkAqua)
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 16
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        // Reparent: container > effectView > swiftUIView
        swiftUIView.removeFromSuperview()
        effectView.addSubview(swiftUIView)
        container.addSubview(effectView)

        swiftUIView.translatesAutoresizingMaskIntoConstraints = false
        effectView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: container.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            swiftUIView.topAnchor.constraint(equalTo: effectView.topAnchor),
            swiftUIView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            swiftUIView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            swiftUIView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
        ])
        window.contentView = container
    }

    // MARK: - State Synchronization

    private func handleBluetoothStateChange(_ state: BluetoothManager.ConnectionState) {
        let isConnected: Bool
        let deviceName: String?
        let errorMessage: String?

        switch state {
        case .connected(let device):
            isConnected = true
            deviceName = device.name
            errorMessage = nil
        case .error(let message):
            isConnected = false
            deviceName = nil
            errorMessage = message
        default:
            isConnected = false
            deviceName = nil
            errorMessage = nil
        }

        // Only update if changed to avoid unnecessary UI refreshes
        if appState.isConnected != isConnected {
            appState.isConnected = isConnected
            pressedKeys.reset()
        }
        if appState.connectedDeviceName != deviceName {
            appState.connectedDeviceName = deviceName
        }
        if appState.errorMessage != errorMessage {
            appState.errorMessage = errorMessage
        }

        // Update menu bar
        refreshMenuBar()
    }

    // MARK: - Copy/Paste

    func pasteFromClipboard() {
        guard appState.isConnected else {
            Log.app.warning("Cannot paste: not connected")
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            Log.app.info("Clipboard is empty or contains no text")
            return
        }
        Log.app.info("Pasting \(text.count) characters from clipboard")
        bluetoothManager.sendText(text)
    }

    // MARK: - KeyboardEventCaptureDelegate

    /// True when global forwarding should swallow events system-wide.
    private var isConsumingGlobally: Bool {
        appState.isGlobalForwarding && appState.isForwarding && appState.isConnected
            && keyboardCapture.isConsumeCapable
    }

    func keyboardCapture(_ capture: KeyboardEventCapture, didCaptureKeyDown keyCode: UInt16, modifiers: CGEventFlags, isAutorepeat: Bool) -> Bool {
        let modifierByte = modifierTracker.update(with: modifiers)

        guard isAppActive || appState.isGlobalForwarding, appState.isConnected else {
            return false
        }

        // Decide consumption up front so a chord that flips state (e.g. the
        // global-mode escape shortcut) is itself consumed under pre-toggle rules
        let consuming = isConsumingGlobally

        // Shortcuts run before everything — the escape chord must always work
        if !isAutorepeat, let action = shortcutManager.matchShortcut(keyCode: keyCode, modifiers: modifiers) {
            handleShortcutAction(action)
            return consuming
        }

        guard appState.isForwarding else {
            return false
        }

        // Swallow macOS autorepeats — the HID host (iOS) repeats held keys itself
        if isAutorepeat {
            return consuming
        }

        // Media keys: F7–F12 → consumer usages (play/pause, volume, ...)
        if let consumerUsage = ConsumerKeyMapper.usage(for: keyCode) {
            bluetoothManager.sendConsumerKey(usage: consumerUsage)
            return consuming
        }

        // Translate keycode to HID usage
        guard let hidUsage = KeyCodeTranslator.hidUsageCode(from: keyCode) else {
            Log.keyboard.debug("No HID mapping for keycode: \(keyCode)")
            return consuming
        }

        // Send the full pressed-key set (6KRO) so chords don't drop keys
        let snapshot = pressedKeys.keyDown(keyCode: keyCode, usage: hidUsage)
        bluetoothManager.sendKeyboardReport(modifiers: modifierByte, keyCodes: snapshot)

        // Update text echo area
        switch keyCode {
        case 51, 117: // Backspace, Forward Delete
            appState.removeLastCharacter()
        case 36, 76:  // Return, Numpad Enter
            appState.appendText("\n")
        case 48:      // Tab
            appState.appendText("    ")
        case 53, 126, 125, 123, 124: // Escape, arrows — ignore
            break
        default:
            if let character = characterForKeyCode(keyCode, modifiers: modifiers) {
                appState.appendText(String(character))
            }
        }

        return consuming
    }

    func keyboardCapture(_ capture: KeyboardEventCapture, didCaptureKeyUp keyCode: UInt16, modifiers: CGEventFlags) -> Bool {
        // Mirror the physical keyboard even when the gate is closed, so the
        // tracker can't hold keys whose release arrived while not forwarding
        let snapshot = pressedKeys.keyUp(keyCode: keyCode)
        let modifierByte = modifierTracker.update(with: modifiers)

        guard isAppActive || appState.isGlobalForwarding,
              appState.isForwarding, appState.isConnected else {
            return false
        }

        // Release only this key — still-held keys and modifiers stay in the report
        bluetoothManager.sendKeyboardReport(modifiers: modifierByte, keyCodes: snapshot)
        return isConsumingGlobally
    }

    func keyboardCapture(_ capture: KeyboardEventCapture, didCaptureModifierChange modifiers: CGEventFlags) -> Bool {
        guard isAppActive || appState.isGlobalForwarding,
              appState.isForwarding, appState.isConnected else {
            // Still track modifiers even when not forwarding so state is correct when we resume
            modifierTracker.update(with: modifiers)
            return false
        }

        let modifierByte = modifierTracker.update(with: modifiers)

        // Modifier change must not release keys that are still held
        bluetoothManager.sendKeyboardReport(modifiers: modifierByte, keyCodes: pressedKeys.usages)
        return isConsumingGlobally
    }

    // MARK: - Shortcut Handling

    private func toggleForwarding() {
        appState.isForwarding.toggle()
        if !appState.isForwarding {
            releaseAllForwardedKeys()
        }
        refreshMenuBar()
    }

    private func toggleGlobalForwarding() {
        if appState.isGlobalForwarding {
            setGlobalForwarding(false)
        } else {
            guard PermissionChecker.hasAccessibilityPermission else {
                appState.needsAccessibility = true
                PermissionChecker.requestAccessibilityPermission()
                Log.app.warning("Global forwarding requires Accessibility permission")
                return
            }
            setGlobalForwarding(true)
        }
    }

    private func setGlobalForwarding(_ enabled: Bool) {
        appState.isGlobalForwarding = enabled
        AppPreferences.shared.globalForwardingEnabled = enabled
        releaseAllForwardedKeys()
        // Recreate the tap so it reflects current Accessibility permission (.defaultTap vs listen-only)
        keyboardCapture.restartCapture()
        refreshMenuBar()
        Log.app.info("Global forwarding \(enabled ? "enabled" : "disabled")")
    }

    private func refreshMenuBar() {
        menuBarController.updateStatus(
            isConnected: appState.isConnected,
            deviceName: appState.connectedDeviceName,
            isForwarding: appState.isForwarding,
            isGlobalForwarding: appState.isGlobalForwarding
        )
    }

    private func handleShortcutAction(_ action: ShortcutAction) {
        Log.app.info("Executing shortcut action: \(action.rawValue)")

        switch action {
        case .toggleForwarding:
            toggleForwarding()
        case .toggleGlobalForwarding:
            toggleGlobalForwarding()
        case .pasteToDevice:
            pasteFromClipboard()
        case .disconnectDevice:
            bluetoothManager.disconnectAndReAdvertise()
        case .showPreferences:
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Character Resolution

    /// Attempt to resolve a displayable character from a keycode and modifier state.
    /// This is used for the text echo area, not for HID report generation.
    private func characterForKeyCode(_ keyCode: UInt16, modifiers: CGEventFlags) -> Character? {
        // Create a CGEvent to get the character representation
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else {
            return nil
        }

        // Apply current modifier flags
        event.flags = modifiers

        // Get the character from the event
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)

        guard length > 0 else {
            return nil
        }

        var chars = [UniChar](repeating: 0, count: length)
        event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &chars)

        guard length > 0 else {
            return nil
        }

        // Filter out non-printable characters except newline and tab
        guard let scalar = UnicodeScalar(chars[0]) else {
            return nil
        }
        let char = Character(scalar)

        if char.isNewline || char == "\t" || (scalar.value >= 0x20 && scalar.value < 0x7F) {
            return char
        }

        return nil
    }
}
