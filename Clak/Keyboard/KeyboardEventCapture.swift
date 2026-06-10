import Cocoa
import os

// MARK: - KeyboardEventCaptureDelegate

/// Delegate protocol for receiving keyboard event notifications.
///
/// Each method returns whether the event should be CONSUMED (swallowed system-wide).
/// Consumption only takes effect when the tap was created as `.defaultTap`
/// (requires Accessibility permission); listen-only taps ignore the return value.
protocol KeyboardEventCaptureDelegate: AnyObject {
    /// Called when a key-down event is captured.
    /// `isAutorepeat` is true for macOS-generated repeats of a held key.
    /// - Returns: true to consume the event.
    func keyboardCapture(_ capture: KeyboardEventCapture, didCaptureKeyDown keyCode: UInt16, modifiers: CGEventFlags, isAutorepeat: Bool) -> Bool

    /// Called when a key-up event is captured.
    /// - Returns: true to consume the event.
    func keyboardCapture(_ capture: KeyboardEventCapture, didCaptureKeyUp keyCode: UInt16, modifiers: CGEventFlags) -> Bool

    /// Called when modifier keys change state.
    /// - Returns: true to consume the event.
    func keyboardCapture(_ capture: KeyboardEventCapture, didCaptureModifierChange modifiers: CGEventFlags) -> Bool
}

// MARK: - KeyboardEventCapture

/// Captures keyboard events using a CGEventTap and forwards them to a delegate.
///
/// This class creates a session-level event tap in listen-only mode, meaning it
/// observes keyboard events without consuming them. Events are dispatched to the
/// delegate for key-down, key-up, and modifier-change events.
///
/// Input Monitoring (Accessibility) permission is required. Use the static
/// `hasPermission` and `requestPermission()` methods to check and request access.
final class KeyboardEventCapture {

    // MARK: - Properties

    /// The delegate that receives captured keyboard events.
    weak var delegate: KeyboardEventCaptureDelegate?

    /// The CGEventTap Mach port, if currently capturing.
    private var eventTap: CFMachPort?

    /// The run loop source for the event tap.
    private var runLoopSource: CFRunLoopSource?

    /// Whether event capture is currently active.
    private(set) var isCapturing = false

    /// Whether the tap can consume events (.defaultTap, requires Accessibility permission).
    private(set) var isConsumeCapable = false

    // MARK: - Permissions

    /// Whether the app currently has Input Monitoring (Accessibility) permission.
    static var hasPermission: Bool {
        CGPreflightListenEventAccess()
    }

    /// Request Input Monitoring permission from the user.
    /// This will show a system dialog prompting the user to grant access.
    static func requestPermission() {
        CGRequestListenEventAccess()
    }

    // MARK: - Capture Control

    /// Start capturing keyboard events.
    ///
    /// Creates a CGEventTap listening for key-down, key-up, and flags-changed events.
    /// The tap is installed on the current run loop.
    ///
    /// - Returns: `true` if capture started successfully, `false` if the event tap
    ///   could not be created (e.g., missing permissions or already capturing).
    func startCapture() -> Bool {
        guard !isCapturing else {
            Log.keyboard.warning("Capture already active, ignoring startCapture call")
            return true
        }

        guard Self.hasPermission else {
            Log.keyboard.error("Input Monitoring permission not granted, cannot start capture")
            return false
        }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        // Pass `self` as userInfo via Unmanaged so the C callback can reach us.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // A consuming tap (.defaultTap) requires Accessibility; without it,
        // fall back to listen-only (global forwarding then can't consume events)
        isConsumeCapable = AXIsProcessTrusted()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: isConsumeCapable ? .defaultTap : .listenOnly,
            eventsOfInterest: eventMask,
            callback: KeyboardEventCapture.eventTapCallback,
            userInfo: userInfo
        ) else {
            Log.keyboard.error("Failed to create CGEvent tap")
            return false
        }
        Log.keyboard.info("Event tap created (\(self.isConsumeCapable ? "consuming" : "listen-only", privacy: .public))")

        eventTap = tap

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            Log.keyboard.error("Failed to create run loop source from event tap")
            eventTap = nil
            return false
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        isCapturing = true
        Log.keyboard.info("Keyboard event capture started")
        return true
    }

    /// Stop capturing keyboard events.
    ///
    /// Removes the event tap from the run loop and invalidates it.
    func stopCapture() {
        guard isCapturing else {
            return
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }

        runLoopSource = nil
        eventTap = nil
        isCapturing = false
        Log.keyboard.info("Keyboard event capture stopped")
    }

    /// Recreate the tap — e.g., after Accessibility permission changes which tap type is available.
    @discardableResult
    func restartCapture() -> Bool {
        stopCapture()
        return startCapture()
    }

    // MARK: - Event Tap Callback

    /// The C-compatible callback function for the CGEventTap.
    ///
    /// This function recovers the `KeyboardEventCapture` instance from `userInfo`
    /// and dispatches events to the delegate on the main thread.
    private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        guard let userInfo = userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let capture = Unmanaged<KeyboardEventCapture>.fromOpaque(userInfo).takeUnretainedValue()
        var consume = false

        switch type {
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let flags = event.flags
            Log.keyboard.debug("Key down: keyCode=\(keyCode), flags=0x\(String(flags.rawValue, radix: 16))")
            consume = capture.delegate?.keyboardCapture(
                capture, didCaptureKeyDown: keyCode, modifiers: flags, isAutorepeat: isAutorepeat
            ) ?? false

        case .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            Log.keyboard.debug("Key up: keyCode=\(keyCode), flags=0x\(String(flags.rawValue, radix: 16))")
            consume = capture.delegate?.keyboardCapture(capture, didCaptureKeyUp: keyCode, modifiers: flags) ?? false

        case .flagsChanged:
            let flags = event.flags
            consume = capture.delegate?.keyboardCapture(capture, didCaptureModifierChange: flags) ?? false

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disabled our event tap (timeout or user input). Re-enable —
            // critical for a consuming tap, where a dead tap blocks system-wide typing.
            Log.keyboard.warning("Event tap disabled, re-enabling")
            if let tap = capture.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }

        default:
            break
        }

        // Returning nil consumes the event (only effective for .defaultTap)
        return consume ? nil : Unmanaged.passUnretained(event)
    }

    // MARK: - Cleanup

    deinit {
        stopCapture()
    }
}
