import CoreGraphics
import Foundation

/// Converts line ticks into trackpad-grade scrolling: a 120Hz animator
/// interpolates toward the accumulated pixel target (Mos-style smoothing),
/// posting continuous CGEvents with gesture phases. When a quick burst of
/// ticks stops, a drag-curve momentum tail (Mac Mouse Fix constants:
/// v' = -a·v^b) takes over at the wheel's speed and posts momentumPhase
/// events so apps get real coasting and rubber-banding.
final class GestureScrollEngine {

    /// One synthesized scroll event's fields.
    struct Post: Equatable {
        var lineDeltaY: Int64
        var lineDeltaX: Int64
        var pointDeltaY: Int64
        var pointDeltaX: Int64
        var fixedDeltaY: Double
        var fixedDeltaX: Double
        var scrollPhase: Int64
        var momentumPhase: Int64
    }

    private let clock: () -> TimeInterval
    private let sink: (Post) -> Void
    private let ticker: FrameTicker

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sink: @escaping (Post) -> Void = GestureScrollEngine.postCGEvent,
         ticker: FrameTicker = DispatchFrameTicker()) {
        self.clock = clock
        self.sink = sink
        self.ticker = ticker
    }

    private enum Phase {
        // IOHIDEventPhaseBits / CGMomentumScrollPhase values
        static let began: Int64 = 1
        static let changed: Int64 = 2
        static let ended: Int64 = 4
        static let momentumBegin: Int64 = 1
        static let momentumContinue: Int64 = 2
        static let momentumEnd: Int64 = 3
    }

    private enum State {
        case idle
        case gesture
        case momentum
    }

    // Tunables
    private let pixelsPerLine: Double = 30
    private let frameInterval: TimeInterval = 1.0 / 120.0
    private let smoothing = 0.25            // fraction of buffer emitted per frame
    private let gestureEndTimeout: TimeInterval = 0.12
    private let momentumMinVelocity: Double = 80 // px/s to start coasting
    /// A flick is a burst: two tick intervals, so a double notch stays precise.
    private let momentumMinIntervals = 2
    /// Hand over to momentum once the wheel has been quiet for this many of
    /// its recent tick intervals, bounded so the coast neither stutters on
    /// jittery ticks nor waits on the smoothing tail.
    private let handoffIntervals = 2.0
    private let minHandoffDelay: TimeInterval = 0.04
    /// A free-spinning wheel can tick every few ms; no further than a hard
    /// trackpad flick.
    private let momentumMaxVelocity: Double = 6_000 // px/s
    /// Below ~10 px/s a 120 Hz frame moves under 0.1 px: the coast has
    /// visibly stopped, and further frames would only post empty events.
    private let momentumStopVelocity: Double = 10 // px/s
    /// Lets the system batch frame wakeups with other timers.
    private let frameLeeway: TimeInterval = 0.001
    private let dragCoefficient: Double = 30     // MMF "emulate trackpad"
    private let dragExponent = 0.7

    private var state: State = .idle
    private var isTicking = false

    private var bufferX: Double = 0
    private var bufferY: Double = 0
    private var velocityX: Double = 0
    private var velocityY: Double = 0
    private var lastInputTime: TimeInterval = 0
    private var lastFrameTime: TimeInterval = 0

    // Wheel speed measured from tick arrivals, not from the smoothed output,
    // which has already decayed to a trickle by the time input stops
    private var inputVelocityX: Double = 0
    private var inputVelocityY: Double = 0
    private var inputInterval: TimeInterval = 0
    private var inputIntervals = 0

    // Carries so integer event fields lose no sub-pixel/sub-line motion
    private var pixelCarryX: Double = 0
    private var pixelCarryY: Double = 0
    private var lineCarryX: Double = 0
    private var lineCarryY: Double = 0
    /// Momentum motion too small to move a whole pixel yet, held for a later frame.
    private var heldMomentumX: Double = 0
    private var heldMomentumY: Double = 0

    /// Feed raw line ticks from the BLE mouse (already direction-adjusted by macOS).
    func feed(linesY: Int, linesX: Int) {
        let now = clock()
        let pixelsY = Double(linesY) * pixelsPerLine
        let pixelsX = Double(linesX) * pixelsPerLine

        if state == .momentum {
            post(dy: 0, dx: 0, scrollPhase: 0, momentumPhase: Phase.momentumEnd)
            state = .idle
            heldMomentumX = 0
            heldMomentumY = 0
        }

        if state == .gesture {
            sampleInput(pixelsY: pixelsY, pixelsX: pixelsX, interval: now - lastInputTime)
        }
        lastInputTime = now

        bufferY += pixelsY
        bufferX += pixelsX

        if state == .idle {
            startGesture()
        }
    }

    private func sampleInput(pixelsY: Double, pixelsX: Double, interval: TimeInterval) {
        let interval = max(interval, 0.001)
        let first = inputIntervals == 0
        inputVelocityY = Self.smoothed(inputVelocityY, sample: pixelsY / interval, restart: first)
        inputVelocityX = Self.smoothed(inputVelocityX, sample: pixelsX / interval, restart: first)
        inputInterval = first ? interval : 0.5 * interval + 0.5 * inputInterval
        inputIntervals += 1
    }

    /// Averages over recent ticks, but follows a reversal at once so the
    /// coast never runs against the latest direction.
    private static func smoothed(_ current: Double, sample: Double, restart: Bool) -> Double {
        if restart || current * sample < 0 {
            return sample
        }
        return 0.5 * sample + 0.5 * current
    }

    func reset() {
        switch state {
        case .gesture:
            post(dy: 0, dx: 0, scrollPhase: Phase.ended, momentumPhase: 0)
        case .momentum:
            post(dy: 0, dx: 0, scrollPhase: 0, momentumPhase: Phase.momentumEnd)
        case .idle:
            break
        }
        stopTimer()
        state = .idle
        bufferX = 0
        bufferY = 0
        velocityX = 0
        velocityY = 0
        resetInputSpeed()
        pixelCarryX = 0
        pixelCarryY = 0
        lineCarryX = 0
        lineCarryY = 0
        heldMomentumX = 0
        heldMomentumY = 0
    }

    // MARK: - State machine

    private func resetInputSpeed() {
        inputVelocityX = 0
        inputVelocityY = 0
        inputInterval = 0
        inputIntervals = 0
    }

    private func startGesture() {
        state = .gesture
        velocityX = 0
        velocityY = 0
        resetInputSpeed()
        lastFrameTime = clock()
        post(dy: 0, dx: 0, scrollPhase: Phase.began, momentumPhase: 0)
        startTimer()
    }

    private func startTimer() {
        guard !isTicking else { return }
        isTicking = true
        ticker.start(interval: frameInterval, leeway: frameLeeway) { [weak self] in self?.frame() }
    }

    private func stopTimer() {
        guard isTicking else { return }
        isTicking = false
        ticker.stop()
    }

    private func frame() {
        let now = clock()
        let dt = min(max(now - lastFrameTime, 0.001), 0.1)
        lastFrameTime = now

        switch state {
        case .gesture:
            gestureFrame(now: now, dt: dt)
        case .momentum:
            momentumFrame(dt: dt)
        case .idle:
            stopTimer()
        }
    }

    private func gestureFrame(now: TimeInterval, dt: Double) {
        let quiet = now - lastInputTime
        if isFlick, quiet > handoffDelay {
            // The rest of the buffer keeps draining under the coast
            post(dy: 0, dx: 0, scrollPhase: Phase.ended, momentumPhase: 0)
            let scale = min(1, momentumMaxVelocity / max(abs(inputVelocityY), abs(inputVelocityX)))
            beginMomentum(velocityY: inputVelocityY * scale, velocityX: inputVelocityX * scale, dt: dt)
            return
        }

        let (outY, outX) = drainBuffer()
        if abs(outY) > 0.01 || abs(outX) > 0.01 {
            post(dy: outY, dx: outX, scrollPhase: Phase.changed, momentumPhase: 0)
            return
        }

        // Buffer drained — end the gesture once input has gone quiet
        guard quiet > gestureEndTimeout else { return }

        post(dy: 0, dx: 0, scrollPhase: Phase.ended, momentumPhase: 0)
        state = .idle
        stopTimer()
    }

    private var isFlick: Bool {
        inputIntervals >= momentumMinIntervals
            && max(abs(inputVelocityY), abs(inputVelocityX)) > momentumMinVelocity
    }

    private var handoffDelay: TimeInterval {
        min(max(handoffIntervals * inputInterval, minHandoffDelay), gestureEndTimeout)
    }

    private func drainBuffer() -> (y: Double, x: Double) {
        let outY = bufferY * smoothing
        let outX = bufferX * smoothing
        bufferY -= outY
        bufferX -= outX
        return (outY, outX)
    }

    /// Starts coasting at the given velocity (px/s).
    func beginMomentum(velocityY: Double, velocityX: Double, dt: Double = 1.0 / 120.0) {
        self.velocityY = velocityY
        self.velocityX = velocityX
        lastFrameTime = clock()
        state = .momentum
        post(dy: velocityY * dt, dx: velocityX * dt, scrollPhase: 0, momentumPhase: Phase.momentumBegin)
        startTimer()
    }

    private func momentumFrame(dt: Double) {
        velocityY = Self.decay(velocityY, dt: dt, a: dragCoefficient, b: dragExponent)
        velocityX = Self.decay(velocityX, dt: dt, a: dragCoefficient, b: dragExponent)

        let (outY, outX) = drainBuffer()

        if max(abs(velocityY), abs(velocityX)) <= momentumStopVelocity {
            // Whatever is left of the buffer and held sub-pixels lands with the end
            post(dy: heldMomentumY + outY + bufferY, dx: heldMomentumX + outX + bufferX,
                 scrollPhase: 0, momentumPhase: Phase.momentumEnd)
            state = .idle
            stopTimer()
            bufferY = 0
            bufferX = 0
            heldMomentumX = 0
            heldMomentumY = 0
            return
        }

        let dy = velocityY * dt + heldMomentumY + outY
        let dx = velocityX * dt + heldMomentumX + outX
        if abs(pixelCarryY + dy) < 1, abs(pixelCarryX + dx) < 1 {
            heldMomentumY = dy
            heldMomentumX = dx
            return
        }
        heldMomentumY = 0
        heldMomentumX = 0
        post(dy: dy, dx: dx, scrollPhase: 0, momentumPhase: Phase.momentumContinue)
    }

    /// One explicit-Euler step of the drag ODE v' = -a·v^b (120Hz is plenty).
    private static func decay(_ velocity: Double, dt: Double, a: Double, b: Double) -> Double {
        guard velocity != 0 else { return 0 }
        let sign: Double = velocity < 0 ? -1 : 1
        let magnitude = abs(velocity)
        let next = magnitude - a * pow(magnitude, b) * dt
        return next > 0 ? sign * next : 0
    }

    // MARK: - Event posting

    private func post(dy: Double, dx: Double, scrollPhase: Int64, momentumPhase: Int64) {
        pixelCarryY += dy
        pixelCarryX += dx
        let intY = Int64(pixelCarryY.rounded(.towardZero))
        let intX = Int64(pixelCarryX.rounded(.towardZero))
        pixelCarryY -= Double(intY)
        pixelCarryX -= Double(intX)

        // Continuous events carry ~10px per "line" for legacy line-based readers
        lineCarryY += dy / 10
        lineCarryX += dx / 10
        let lineY = Int64(lineCarryY.rounded(.towardZero))
        let lineX = Int64(lineCarryX.rounded(.towardZero))
        lineCarryY -= Double(lineY)
        lineCarryX -= Double(lineX)

        sink(Post(
            lineDeltaY: lineY, lineDeltaX: lineX,
            pointDeltaY: intY, pointDeltaX: intX,
            fixedDeltaY: dy, fixedDeltaX: dx,
            scrollPhase: scrollPhase, momentumPhase: momentumPhase
        ))
    }

    static func postCGEvent(_ post: Post) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: 0, wheel2: 0, wheel3: 0
        ) else { return }
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: post.lineDeltaY)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: post.lineDeltaX)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: post.pointDeltaY)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: post.pointDeltaX)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: post.fixedDeltaY)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: post.fixedDeltaX)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: post.scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: post.momentumPhase)
        event.post(tap: .cgSessionEventTap)
    }
}

/// A repeating frame clock; injectable so tests can step frames by hand.
protocol FrameTicker: AnyObject {
    func start(interval: TimeInterval, leeway: TimeInterval, _ handler: @escaping () -> Void)
    func stop()
}

final class DispatchFrameTicker: FrameTicker {
    private var source: DispatchSourceTimer?

    func start(interval: TimeInterval, leeway: TimeInterval, _ handler: @escaping () -> Void) {
        stop()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + interval, repeating: interval,
                        leeway: .nanoseconds(Int(leeway * 1_000_000_000)))
        source.setEventHandler(handler: handler)
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
