import Foundation
@testable import Clak

/// A clock that only moves when a test advances it; scheduled work runs in
/// deadline order as time passes it.
final class ManualTickScheduler: TickScheduler {
    private(set) var now: TimeInterval = 0
    private(set) var scheduledCount = 0
    private var jobs: [(at: TimeInterval, seq: Int, work: () -> Void)] = []

    var pendingCount: Int { jobs.count }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        scheduledCount += 1
        jobs.append((now + max(0, delay), scheduledCount, work))
    }

    func advance(to time: TimeInterval) {
        while let next = jobs.enumerated().min(by: { ($0.element.at, $0.element.seq) < ($1.element.at, $1.element.seq) }),
              next.element.at <= time {
            jobs.remove(at: next.offset)
            now = max(now, next.element.at)
            next.element.work()
        }
        now = max(now, time)
    }

    func advance(by delta: TimeInterval) {
        advance(to: now + delta)
    }
}
