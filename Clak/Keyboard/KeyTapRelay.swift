import Foundation

/// The tap thread's side of the key gate. `route` answers the tap at once
/// (consume or not) from the last published snapshot, then hands the event,
/// its route and that snapshot to `onRoute` through `deliver` (main, in
/// order), where the stateful work (trackers, BLE sends, echo) happens.
final class KeyTapRelay {
    /// Runs on whatever `deliver` targets; main in the app.
    var onRoute: ((KeyEventInput, KeyRoute, KeyGateSnapshot) -> Void)?

    private let deliverer: (@escaping () -> Void) -> Void
    private let lock = NSLock()
    private var snapshot = KeyGateSnapshot.closed

    init(deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.deliverer = deliver
    }

    func publish(_ snapshot: KeyGateSnapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    var current: KeyGateSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// - Returns: whether the tap should consume the event.
    @discardableResult
    func route(_ event: KeyEventInput) -> Bool {
        let snapshot = current
        let route = KeyEventRouter.route(snapshot, event)
        deliverer { [weak self] in
            self?.onRoute?(event, route, snapshot)
        }
        return route.consume
    }

    /// Hands other tap-thread news (e.g. dropped events) to the same queue,
    /// behind any events already routed.
    func deliver(_ work: @escaping () -> Void) {
        deliverer(work)
    }
}

extension KeyGateSnapshot {
    /// Before the first publish: nothing forwards, nothing is consumed.
    static let closed = KeyGateSnapshot(
        isAppActive: false, isGlobalForwarding: false, isForwarding: false,
        isConnected: false, isRecording: false, isConsumeCapable: false, shortcuts: []
    )
}
