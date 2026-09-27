import Foundation

/// Delay before each retry: `firstDelay`, doubling per unanswered attempt up
/// to `maxDelay`. Same curve as Clak Remote's republish rounds (8 s → 120 s),
/// so a Mac left with a failing radio settles down instead of spinning.
struct RetryBackoff: Equatable {
    let firstDelay: TimeInterval
    let maxDelay: TimeInterval
    /// Retries already scheduled since the last reset.
    private(set) var attempts = 0

    init(firstDelay: TimeInterval = 8, maxDelay: TimeInterval = 120) {
        self.firstDelay = firstDelay
        self.maxDelay = maxDelay
    }

    func delay(afterAttempts attempts: Int) -> TimeInterval {
        // Clamp the exponent so a long-running session can't overflow to inf
        min(firstDelay * pow(2, Double(min(attempts, 32))), maxDelay)
    }

    /// The delay for the next retry, counting it as scheduled.
    mutating func nextDelay() -> TimeInterval {
        defer { attempts += 1 }
        return delay(afterAttempts: attempts)
    }

    mutating func reset() {
        attempts = 0
    }
}
