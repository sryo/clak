import CoreGraphics
import Foundation

/// Converts line ticks into trackpad-grade scrolling: a 120Hz animator
/// interpolates toward the accumulated pixel target (Mos-style smoothing),
/// posting continuous CGEvents with gesture phases; on input silence a
/// drag-curve momentum tail (Mac Mouse Fix constants: v' = -a·v^b) posts
/// momentumPhase events so apps get real coasting and rubber-banding.
final class GestureScrollEngine {

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
    private let momentumStopVelocity: Double = 1 // px/s (MMF stopSpeed)
    private let dragCoefficient: Double = 30     // MMF "emulate trackpad"
    private let dragExponent = 0.7

    private var state: State = .idle
    private var timer: DispatchSourceTimer?

    private var bufferX: Double = 0
    private var bufferY: Double = 0
    private var velocityX: Double = 0
    private var velocityY: Double = 0
    private var lastInputTime: TimeInterval = 0
    private var lastFrameTime: TimeInterval = 0

    // Carries so integer event fields lose no sub-pixel/sub-line motion
    private var pixelCarryX: Double = 0
    private var pixelCarryY: Double = 0
    private var lineCarryX: Double = 0
    private var lineCarryY: Double = 0

    /// Feed raw line ticks from the BLE mouse (already direction-adjusted by macOS).
    func feed(linesY: Int, linesX: Int) {
        lastInputTime = ProcessInfo.processInfo.systemUptime

        if state == .momentum {
            post(dy: 0, dx: 0, scrollPhase: 0, momentumPhase: Phase.momentumEnd)
            state = .idle
        }

        bufferY += Double(linesY) * pixelsPerLine
        bufferX += Double(linesX) * pixelsPerLine

        if state == .idle {
            startGesture()
        }
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
        pixelCarryX = 0
        pixelCarryY = 0
        lineCarryX = 0
        lineCarryY = 0
    }

    // MARK: - State machine

    private func startGesture() {
        state = .gesture
        velocityX = 0
        velocityY = 0
        lastFrameTime = ProcessInfo.processInfo.systemUptime
        post(dy: 0, dx: 0, scrollPhase: Phase.began, momentumPhase: 0)
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + frameInterval, repeating: frameInterval)
        source.setEventHandler { [weak self] in self?.frame() }
        source.resume()
        timer = source
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func frame() {
        let now = ProcessInfo.processInfo.systemUptime
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
        let outY = bufferY * smoothing
        let outX = bufferX * smoothing
        bufferY -= outY
        bufferX -= outX

        if abs(outY) > 0.01 || abs(outX) > 0.01 {
            velocityY = 0.8 * (outY / dt) + 0.2 * velocityY
            velocityX = 0.8 * (outX / dt) + 0.2 * velocityX
            post(dy: outY, dx: outX, scrollPhase: Phase.changed, momentumPhase: 0)
            return
        }

        // Buffer drained — end the gesture once input has gone quiet
        guard now - lastInputTime > gestureEndTimeout else { return }

        post(dy: 0, dx: 0, scrollPhase: Phase.ended, momentumPhase: 0)
        if max(abs(velocityY), abs(velocityX)) > momentumMinVelocity {
            state = .momentum
            post(dy: velocityY * dt, dx: velocityX * dt, scrollPhase: 0, momentumPhase: Phase.momentumBegin)
        } else {
            state = .idle
            stopTimer()
        }
    }

    private func momentumFrame(dt: Double) {
        velocityY = Self.decay(velocityY, dt: dt, a: dragCoefficient, b: dragExponent)
        velocityX = Self.decay(velocityX, dt: dt, a: dragCoefficient, b: dragExponent)

        if max(abs(velocityY), abs(velocityX)) <= momentumStopVelocity {
            post(dy: 0, dx: 0, scrollPhase: 0, momentumPhase: Phase.momentumEnd)
            state = .idle
            stopTimer()
            return
        }
        post(dy: velocityY * dt, dx: velocityX * dt, scrollPhase: 0, momentumPhase: Phase.momentumContinue)
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
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: 0, wheel2: 0, wheel3: 0
        ) else { return }

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

        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: lineY)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lineX)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: intY)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: intX)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)

        event.post(tap: .cgSessionEventTap)
    }
}
