import Foundation

/// Sums pointer motion and hands it out in report-sized chunks: whole counts
/// within the report's ±127, with the fraction and any overflow kept for the
/// next chunk, so no motion is lost.
struct PadPointerAccumulator {
    private var pendingX: Double = 0
    private var pendingY: Double = 0

    mutating func add(dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite else { return }
        pendingX += dx
        pendingY += dy
    }

    mutating func take() -> (dx: Int8, dy: Int8)? {
        let x = Self.chunk(pendingX), y = Self.chunk(pendingY)
        guard x != 0 || y != 0 else { return nil }
        pendingX -= x
        pendingY -= y
        return (Int8(x), Int8(y))
    }

    private static func chunk(_ value: Double) -> Double {
        max(-127, min(127, value.rounded(.towardZero)))
    }
}

/// Sends pad motion at most once per tick. When the link refuses a report
/// (it was queued rather than sent), motion keeps accumulating and the next
/// attempt waits for `busyRetryInterval` instead of stacking more reports
/// behind it. BLEHIDPeripheralManager's queue also merges consecutive mouse
/// reports, so this only keeps the queue from growing, it isn't what saves
/// the motion.
final class PadPointerSender {
    static let tickInterval = Constants.Trackpad.moveReportInterval
    /// About two connection events at iOS's 15 ms interval.
    static let busyRetryInterval: TimeInterval = 0.03

    private var accumulator = PadPointerAccumulator()
    private let send: (Int8, Int8) -> Bool
    private var linkBusy = false
    private var tick: TickThrottle!
    private var retry: TickThrottle!

    /// - Parameter send: returns false when the report had to be queued.
    init(scheduler: TickScheduler, send: @escaping (Int8, Int8) -> Bool) {
        self.send = send
        tick = TickThrottle(interval: Self.tickInterval, leading: true, scheduler: scheduler) { [weak self] in
            self?.drain()
        }
        retry = TickThrottle(interval: Self.busyRetryInterval, leading: false, scheduler: scheduler) { [weak self] in
            self?.linkBusy = false
            self?.drain()
        }
    }

    func move(dx: Double, dy: Double) {
        accumulator.add(dx: dx, dy: dy)
        if linkBusy {
            retry.request()
        } else {
            tick.request()
        }
    }

    /// Sends everything now, busy or not: a click must follow all the
    /// motion before it.
    func flush() {
        while let chunk = accumulator.take() {
            linkBusy = !send(chunk.dx, chunk.dy)
        }
    }

    /// Drop unsent motion, e.g. when a new drag starts.
    func reset() {
        accumulator = PadPointerAccumulator()
    }

    private func drain() {
        while !linkBusy, let chunk = accumulator.take() {
            linkBusy = !send(chunk.dx, chunk.dy)
        }
        if linkBusy {
            retry.request()
        }
    }
}
