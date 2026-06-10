import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

/// Upgrades scrolling from the Clak Remote BLE mouse into trackpad-grade
/// phase-based scroll events (pixel-smooth, with momentum).
///
/// An active CGEventTap intercepts line-based scroll events, identifies the
/// sender via the event's HID registry ID (private field 87), swallows events
/// from Clak Remote (VID 0xFFFF / PID 0x0100 from our DIS PnP ID), and feeds
/// them to GestureScrollEngine which re-posts continuous events with
/// scroll/momentum phases. All other devices pass through untouched, as do
/// continuous events (real trackpads and our own re-posts) — so this cannot
/// interfere with normal input or the keyboard-forwarding path.
final class ScrollEnhancer {
    static let shared = ScrollEnhancer()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let engine = GestureScrollEngine()

    private var senderVerdicts: [UInt64: Bool] = [:]

    private(set) var isRunning = false

    private init() {}

    func start() {
        guard !isRunning else { return }
        guard PermissionChecker.hasAccessibilityPermission else {
            Log.app.warning("ScrollEnhancer: Accessibility permission missing")
            return
        }

        let mask: CGEventMask = 1 << CGEventType.scrollWheel.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let enhancer = Unmanaged<ScrollEnhancer>.fromOpaque(refcon!).takeUnretainedValue()
                return enhancer.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.app.error("ScrollEnhancer: failed to create event tap")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        Log.app.info("ScrollEnhancer: started")
    }

    func stop() {
        guard isRunning else { return }
        engine.reset()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        senderVerdicts.removeAll()
        isRunning = false
        Log.app.info("ScrollEnhancer: stopped")
    }

    // MARK: - Tap callback

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else {
            return Unmanaged.passUnretained(event)
        }

        // Continuous events are trackpads or our own re-posts — never touch
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else {
            return Unmanaged.passUnretained(event)
        }

        let senderID = UInt64(bitPattern: event.getIntegerValueField(Self.senderIDField))
        guard isClakRemote(senderID: senderID) else {
            return Unmanaged.passUnretained(event)
        }

        let linesY = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let linesX = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        engine.feed(linesY: linesY, linesX: linesX)
        return nil // swallow the raw tick
    }

    /// Private CGEvent field carrying the sending HID service's registry entry ID.
    private static let senderIDField = CGEventField(rawValue: 87)!

    private func isClakRemote(senderID: UInt64) -> Bool {
        if let verdict = senderVerdicts[senderID] {
            return verdict
        }
        let verdict = Self.resolveIsClakRemote(senderID: senderID)
        senderVerdicts[senderID] = verdict
        Log.app.info("ScrollEnhancer: sender \(senderID) → Clak Remote: \(verdict)")
        return verdict
    }

    /// Walk the IORegistry upward from the sending service looking for our
    /// device's identity (VID/PID set via the DIS PnP ID characteristic).
    private static func resolveIsClakRemote(senderID: UInt64) -> Bool {
        guard senderID != 0 else { return false }
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IORegistryEntryIDMatching(senderID)
        )
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        func property(_ key: String) -> AnyObject? {
            IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            )
        }

        let vendorID = (property(kIOHIDVendorIDKey) as? NSNumber)?.intValue
        let productID = (property(kIOHIDProductIDKey) as? NSNumber)?.intValue
        if vendorID == 0xFFFF, productID == 0x0100 {
            return true
        }
        let product = property(kIOHIDProductKey) as? String
        return product == "Clak Remote"
    }
}
