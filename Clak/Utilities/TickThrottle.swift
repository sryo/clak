import Foundation

/// A clock plus deferred work, so rate limits can be tested without waiting.
protocol TickScheduler: AnyObject {
    var now: TimeInterval { get }
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void)
}

final class MainQueueTickScheduler: TickScheduler {
    static let shared = MainQueueTickScheduler()

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// Runs `action` at most once per `interval`, however often it's requested.
/// Leading: the first request in a quiet period runs at once, later ones
/// collapse into one run at the end of the interval. Trailing: every run
/// waits for the end of the interval, so a burst inside one frame is one run.
final class TickThrottle {
    private let interval: TimeInterval
    private let leading: Bool
    private let scheduler: TickScheduler
    private let action: () -> Void

    private var lastFire: TimeInterval = -.infinity
    /// Bumped to orphan a scheduled run that flush() already covered.
    private var generation = 0
    private(set) var isScheduled = false

    init(interval: TimeInterval, leading: Bool, scheduler: TickScheduler, action: @escaping () -> Void) {
        self.interval = interval
        self.leading = leading
        self.scheduler = scheduler
        self.action = action
    }

    func request() {
        guard !isScheduled else { return }
        let wait = leading ? lastFire + interval - scheduler.now : interval
        if wait <= 0 {
            fire()
            return
        }
        isScheduled = true
        let expected = generation
        scheduler.schedule(after: wait) { [weak self] in
            guard let self, self.generation == expected else { return }
            self.fire()
        }
    }

    /// Runs now and cancels any scheduled run.
    func flush() {
        fire()
    }

    private func fire() {
        generation &+= 1
        isScheduled = false
        lastFire = scheduler.now
        action()
    }
}
