import Foundation

/// Turns the pad's scroll events into HID wheel lines.
///
/// Precise (trackpad) deltas arrive in pixels; macOS itself reports a line
/// wheel click as ~10 px of scrollingDelta, so dividing by 10 sends the
/// device the line count the Mac would have produced for the same motion.
/// Non-precise deltas are already lines. Remainders carry to the next event.
///
/// Momentum is forwarded: the device's wheel handling has no coasting of its
/// own, so dropping it would end every flick dead. A new touch (`.began`)
/// drops whatever hasn't been sent yet, since a finger landing on the pad
/// is how the user stops a coast.
struct PadScrollAccumulator {
    enum Phase {
        case began, changed, momentum, other
    }

    static let pixelsPerLine: Double = 10

    private var pendingPixels: Double = 0

    var hasWholeLine: Bool { abs(pendingPixels) >= Self.pixelsPerLine }

    mutating func add(deltaY: Double, isPrecise: Bool, phase: Phase) {
        guard deltaY.isFinite else { return }
        if phase == .began {
            pendingPixels = 0
        }
        pendingPixels += isPrecise ? deltaY : deltaY * Self.pixelsPerLine
    }

    /// Whole lines owed, within the report's Int8 range; the rest stays.
    mutating func takeLines() -> Int8 {
        let lines = max(-127, min(127, (pendingPixels / Self.pixelsPerLine).rounded(.towardZero)))
        pendingPixels -= lines * Self.pixelsPerLine
        return Int8(lines)
    }
}

/// Sends the accumulated lines at most once per tick.
final class PadScrollSender {
    /// iOS's shortest BLE connection interval: one wheel report per
    /// connection event is as fast as the host can take them.
    static let tickInterval: TimeInterval = 0.015

    private var accumulator = PadScrollAccumulator()
    private let send: (Int8) -> Void
    private var throttle: TickThrottle!

    init(scheduler: TickScheduler, send: @escaping (Int8) -> Void) {
        self.send = send
        throttle = TickThrottle(interval: Self.tickInterval, leading: true, scheduler: scheduler) { [weak self] in
            self?.tick()
        }
    }

    func scroll(deltaY: Double, isPrecise: Bool, phase: PadScrollAccumulator.Phase) {
        accumulator.add(deltaY: deltaY, isPrecise: isPrecise, phase: phase)
        if accumulator.hasWholeLine {
            throttle.request()
        }
    }

    private func tick() {
        let lines = accumulator.takeLines()
        if lines != 0 {
            send(lines)
        }
        if accumulator.hasWholeLine {
            throttle.request()
        }
    }
}
