import Cocoa
import Observation

final class AppDelegate: NSObject, NSApplicationDelegate, KeyboardEventCaptureDelegate {
    /// With @NSApplicationDelegateAdaptor, NSApp.delegate is SwiftUI's wrapper,
    /// so scripting commands reach the real delegate through this instead.
    private(set) static weak var shared: AppDelegate?

    let appState = AppState()
    let bluetoothManager = BluetoothManager()
    private let keyboardCapture = KeyboardEventCapture()
    private let modifierTracker = ModifierKeyTracker()
    private let pressedKeys = PressedKeyTracker()
    private var globeTap = GlobeKeyTapDetector()
    private let shortcutManager = KeyboardShortcutManager.shared
    private let menuBarController = MenuBarController()
    private lazy var keyRelease = KeyReleaseController(
        pressedKeys: pressedKeys,
        modifierTracker: modifierTracker,
        sendRelease: { [weak self] in self?.bluetoothManager.sendKeyUp() }
    )

    /// Decides consumption on the tap thread; the work lands in applyKeyEvent on main.
    private let keyTap = KeyTapRelay()

    private var isAppActive = false {
        didSet { refreshKeyGate() }
    }
    private var localKeyMonitor: Any?
    private var windowTopLeft: NSPoint?
    private var windowObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    /// Guard flag: true while we are programmatically correcting the window
    /// origin inside didResize, so that the didMove observer does not
    /// overwrite windowTopLeft with the intermediate (wrong) position.
    private var isCorrectingPosition = false

    // MARK: - Application Lifecycle

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Clak launching")

        // The layout map reads Text Input Sources, which belong on the main thread
        _ = KeyboardLayoutMapper.shared
        keyRelease.onWake = { [weak self] in
            self?.bluetoothManager.handleWake()
        }

        // Configure main window as floating compact HUD
        DispatchQueue.main.async { [weak self] in
            self?.configureMainWindow()
        }

        // Set up menu bar
        menuBarController.setup()
        menuBarController.inputProvider = { [weak self] in
            guard let self else { return HUDInput() }
            return HUDInput(self.appState)
        }
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
        keyTap.onRoute = { [weak self] event, route, snapshot in
            self?.applyKeyEvent(event, route: route, snapshot: snapshot)
        }
        shortcutManager.onChange = { [weak self] in
            self?.refreshKeyGate()
        }
        observeKeyGateInputs()
        keyboardCapture.delegate = self
        if keyboardCapture.startCapture() {
            appState.needsInputMonitoring = false
        }
        refreshKeyGate()
        refreshMenuBar()

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
            self?.refreshMenuBar()
        }
        bluetoothManager.onPairingStateChange = { [weak self] awaiting in
            self?.appState.isAwaitingPairingConfirmation = awaiting
            self?.refreshMenuBar()
        }

        // Auto-start advertising — BLE layer handles poweredOn callback
        bluetoothManager.startAdvertising()

        if AppPreferences.shared.trackpadScrollEnabled {
            ScrollEnhancer.shared.start()
        }

        // Suppress the system beep by consuming key events at the app level,
        // but only while keys are actually being forwarded by the CGEventTap —
        // returning nil here starves every later-installed local monitor (the
        // shortcut recorder) and all AppKit key handling (Cmd+Q, Cmd+,).
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self,
                  self.appState.isForwarding,
                  self.appState.isConnected,
                  !self.isRecordingShortcut else {
                return event
            }
            return nil
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
                refreshKeyGate()
                Log.app.info("Input Monitoring permission now granted, capture started")
            }
        }

        // Pick up Accessibility grants made while away (tap must be recreated to consume)
        if appState.needsAccessibility && PermissionChecker.hasAccessibilityPermission {
            appState.needsAccessibility = false
            keyboardCapture.restartCapture()
            refreshKeyGate()
            Log.app.info("Accessibility permission now granted")
        }

        if AppPreferences.shared.trackpadScrollEnabled && !ScrollEnhancer.shared.isRunning {
            ScrollEnhancer.shared.start()
        }
        refreshMenuBar()
    }

    /// Clicking the Dock icon brings back a hidden HUD.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            menuBarController.onShowMainWindow?()
        }
        return true
    }

    func applicationDidResignActive(_ notification: Notification) {
        isAppActive = false
        // In global mode losing focus is normal — keys stay held across app switches
        if !appState.isGlobalForwarding {
            releaseAllForwardedKeys()
        }
        Log.app.debug("App resigned active")
    }

    /// Stuck-key failsafe: clear the trackers and release everything on the device.
    private func releaseAllForwardedKeys() {
        keyRelease.releaseAll(reason: "forwarding interrupted")
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
        container.layer?.cornerRadius = HUDMetrics.cornerRadius

        // Inner effect view — clips to rounded corners
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = HUDMetrics.cornerRadius
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
        refreshKeyGate()
        if let availability = BluetoothManager.availability(for: state, failure: bluetoothManager.lastFailure),
           appState.bluetooth != availability {
            appState.bluetooth = availability
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

    // MARK: - Key Gate

    /// True while a recorder in the Shortcuts tab owns the keyboard. Gated on
    /// isAppActive so a recorder left open doesn't stall global forwarding —
    /// its local monitor only receives events while the app is frontmost.
    private var isRecordingShortcut: Bool {
        isAppActive && shortcutManager.isRecording
    }

    /// Publishes what the tap thread needs to decide consumption. Called on
    /// main after anything it reads changes.
    private func refreshKeyGate() {
        keyTap.publish(KeyGateSnapshot(
            isAppActive: isAppActive,
            isGlobalForwarding: appState.isGlobalForwarding,
            isForwarding: appState.isForwarding,
            isConnected: appState.isConnected,
            isRecording: shortcutManager.isRecording,
            isConsumeCapable: keyboardCapture.isConsumeCapable,
            shortcuts: shortcutManager.registeredShortcuts
        ))
    }

    /// Republishes whenever AppState's gating inputs change, whoever changes
    /// them (menu, AppleScript, Bluetooth callbacks).
    private func observeKeyGateInputs() {
        withObservationTracking {
            _ = appState.isGlobalForwarding
            _ = appState.isForwarding
            _ = appState.isConnected
        } onChange: {
            // onChange fires before the new value is stored
            DispatchQueue.main.async {
                AppDelegate.shared?.refreshKeyGate()
                AppDelegate.shared?.observeKeyGateInputs()
            }
        }
    }

    // MARK: - KeyboardEventCaptureDelegate (tap thread)

    func keyboardCapture(_ capture: KeyboardEventCapture, didCaptureKeyDown keyCode: UInt16, modifiers: CGEventFlags, isAutorepeat: Bool) -> Bool {
        keyTap.route(.keyDown(keyCode: keyCode, modifiers: modifiers, isAutorepeat: isAutorepeat))
    }

    func keyboardCapture(_ capture: KeyboardEventCapture, didCaptureKeyUp keyCode: UInt16, modifiers: CGEventFlags) -> Bool {
        keyTap.route(.keyUp(keyCode: keyCode, modifiers: modifiers))
    }

    func keyboardCapture(_ capture: KeyboardEventCapture, didCaptureModifierChange modifiers: CGEventFlags, keyCode: UInt16) -> Bool {
        // Whether this completes a Globe tap is known only on main, where
        // the detector lives; it changes the action, not the consumption
        keyTap.route(.modifiersChanged(keyCode: keyCode, modifiers: modifiers, globeTapped: false))
    }

    func keyboardCaptureDidDropEvents(_ capture: KeyboardEventCapture) {
        keyTap.deliver { [weak self] in
            self?.keyRelease.captureDidDropEvents()
        }
    }

    // MARK: - Key Events (main)

    /// The stateful half of a routed event: trackers always follow the
    /// physical keyboard, sends and echo only when the route says so.
    private func applyKeyEvent(_ event: KeyEventInput, route: KeyRoute, snapshot: KeyGateSnapshot) {
        switch event {
        case let .keyDown(keyCode, modifiers, _):
            let modifierByte = modifierTracker.update(with: modifiers)
            globeTap.otherInput()

            switch route.action {
            case .shortcut(let action):
                handleShortcutAction(action)
                refreshKeyGate()
            case .consumer(let usage):
                bluetoothManager.sendConsumerKey(usage: usage)
            case .key(let usage):
                // Send the full pressed-key set (6KRO) so chords don't drop keys
                let keys = pressedKeys.keyDown(keyCode: keyCode, usage: usage)
                bluetoothManager.sendKeyboardReport(modifiers: modifierByte, keyCodes: keys)
                echo(keyCode: keyCode, modifiers: modifiers)
            case .none, .sendPressedKeys, .globe:
                break
            }

        case let .keyUp(keyCode, modifiers):
            // Mirror the physical keyboard even when the gate is closed, so the
            // tracker can't hold keys whose release arrived while not forwarding
            // A key whose down was forwarded is always released, whatever the
            // gate says now: the down may have been applied after a release-all
            // or a gate change, and iOS would autorepeat it forever.
            let modifierByte = modifierTracker.update(with: modifiers)
            if let keys = pressedKeys.release(keyCode: keyCode) {
                // Release only this key — still-held keys and modifiers stay in the report
                bluetoothManager.sendKeyboardReport(modifiers: modifierByte, keyCodes: keys)
            }

        case let .modifiersChanged(keyCode, modifiers, _):
            // Track the Globe key even with the gate closed, so a tap can't be
            // half-seen when forwarding resumes
            let isGlobe = GlobeKeyTapDetector.keyCodes.contains(keyCode)
            var globeTapped = false
            if isGlobe {
                globeTapped = globeTap.globeChanged(isDown: modifiers.contains(.maskSecondaryFn))
            } else {
                globeTap.otherInput()
            }
            let modifierByte = modifierTracker.update(with: modifiers)

            let action = isGlobe
                ? KeyEventRouter.route(snapshot, .modifiersChanged(keyCode: keyCode, modifiers: modifiers, globeTapped: globeTapped)).action
                : route.action
            switch action {
            case .globe:
                // A Globe tap switches the device's keyboard layout, as on an iPad
                bluetoothManager.sendConsumerKey(usage: ConsumerKeyMapper.globeUsage)
            case .sendPressedKeys:
                // Modifier change must not release keys that are still held
                bluetoothManager.sendKeyboardReport(modifiers: modifierByte, keyCodes: pressedKeys.usages)
            case .none, .shortcut, .consumer, .key:
                break
            }
        }
    }

    private func echo(keyCode: UInt16, modifiers: CGEventFlags) {
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
            if let text = echoText(forKeyCode: keyCode, modifiers: modifiers) {
                appState.appendText(text)
            }
        }
    }

    // MARK: - Shortcut Handling

    private func toggleForwarding() {
        appState.isForwarding.toggle()
        refreshKeyGate()
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
                refreshMenuBar()
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
        refreshKeyGate()
        refreshMenuBar()
        Log.app.info("Global forwarding \(enabled ? "enabled" : "disabled")")
    }

    private func refreshMenuBar() {
        menuBarController.update(HUDInput(appState))
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

    /// The displayable text a keycode produces under a modifier state, for
    /// the echo area only — HID reports never depend on it.
    private func echoText(forKeyCode keyCode: UInt16, modifiers: CGEventFlags) -> String? {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else {
            return nil
        }
        event.flags = modifiers

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

        let text = EchoText.displayable(String(utf16CodeUnits: chars, count: length))
        return text.isEmpty ? nil : text
    }
}
