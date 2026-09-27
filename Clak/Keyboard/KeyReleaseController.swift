import AppKit

/// Releases every forwarded key when the Mac stops delivering key events
/// reliably: sleep, display sleep, screen lock, fast user switching, and a
/// disabled event tap. The iOS host autorepeats a held key until it sees the
/// key-up, so a key-up lost to any of these would repeat forever.
final class KeyReleaseController {

    /// Posted to the distributed center when the login screen locks.
    static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")

    private let pressedKeys: PressedKeyTracker
    private let modifierTracker: ModifierKeyTracker
    private let sendRelease: () -> Void
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []

    /// Runs after the wake release, for reconnect work.
    var onWake: (() -> Void)?

    init(pressedKeys: PressedKeyTracker,
         modifierTracker: ModifierKeyTracker,
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributedCenter: NotificationCenter? = DistributedNotificationCenter.default(),
         sendRelease: @escaping () -> Void) {
        self.pressedKeys = pressedKeys
        self.modifierTracker = modifierTracker
        self.sendRelease = sendRelease

        let releasing: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        for name in releasing {
            observe(workspaceCenter, name) { $0.releaseAll(reason: name.rawValue) }
        }
        observe(workspaceCenter, NSWorkspace.didWakeNotification) { controller in
            controller.releaseAll(reason: "wake")
            controller.onWake?()
        }
        if let distributedCenter {
            observe(distributedCenter, Self.screenLockedNotification) { $0.releaseAll(reason: "screen locked") }
        }
    }

    deinit {
        for (center, token) in observations {
            center.removeObserver(token)
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping (KeyReleaseController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            if Thread.isMainThread {
                action(self)
            } else {
                DispatchQueue.main.async { action(self) }
            }
        }
        observations.append((center, token))
    }

    func captureDidDropEvents() {
        releaseAll(reason: "event tap disabled")
    }

    /// Clears the local trackers and sends an all-released report.
    func releaseAll(reason: String) {
        Log.keyboard.info("Releasing all forwarded keys (\(reason, privacy: .public))")
        pressedKeys.reset()
        modifierTracker.reset()
        sendRelease()
    }
}
