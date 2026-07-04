import SwiftUI
import UIKit

/// Touch surface driving the Mac cursor: 1-finger drag moves, tap clicks,
/// 2-finger drag scrolls (with fling momentum), 2-finger tap right-clicks.
struct TrackpadView: UIViewRepresentable {
    let controller: RemoteController

    func makeUIView(context: Context) -> TrackpadUIView {
        let view = TrackpadUIView()
        view.controller = controller
        return view
    }

    func updateUIView(_ uiView: TrackpadUIView, context: Context) {
        uiView.controller = controller
    }
}

final class TrackpadUIView: UIView {
    weak var controller: RemoteController?

    private var activeTouches: Set<UITouch> = []
    private var sessionMaxTouches = 0
    private var sessionStart: TimeInterval = 0
    private var dragDistance: CGFloat = 0

    // Pointer
    private var pendingDelta: CGSize = .zero
    private var lastMoveSend: TimeInterval = 0
    private var lastTouchTimestamp: TimeInterval = 0

    // Scroll — accumulated in LINE units; whole ±1 ticks are sent because macOS
    // multiplies multi-line wheel deltas into jumps (its accel curve is rate-based)
    private var scrollAccX: CGFloat = 0
    private var scrollAccY: CGFloat = 0
    private var scrollVelocityX: CGFloat = 0 // pt/s, low-passed
    private var scrollVelocityY: CGFloat = 0
    private var lastScrollTimestamp: TimeInterval = 0

    // Momentum (fling) — ariya/kinetic-style exponential decay
    private var momentumLink: CADisplayLink?
    private var momentumVX: CGFloat = 0
    private var momentumVY: CGFloat = 0
    private var momentumAccX: CGFloat = 0
    private var momentumAccY: CGFloat = 0
    private var lastMomentumTimestamp: TimeInterval = 0

    private static let tapMaxDuration: TimeInterval = 0.3
    private static let pointsPerScrollLine: CGFloat = 10

    // Velocity-based pointer acceleration: slow strokes get sub-1x gain for
    // precision, fast flicks ramp toward maxGain so the cursor can cross the
    // screen without repeated swipes.
    private static let accelMinGain: CGFloat = 0.5
    private static let accelMaxGain: CGFloat = 4.5
    private static let accelMaxSpeed: CGFloat = 1400 // pts/sec where gain saturates
    private static let accelExponent: CGFloat = 1.4

    // Momentum constants (τ from ariya/kinetic 325ms / iOS ~500ms; velocity
    // low-pass 0.8/0.2 per sample; fling only if the last sample is fresh)
    private static let momentumTimeConstant: CGFloat = 0.42
    private static let flingMinVelocity: CGFloat = 120   // pt/s
    private static let flingMaxVelocity: CGFloat = 4500  // pt/s
    // Stop while ticks are still dense (~10/s). Ending the client tail early
    // keeps it stutter-free, and hands off cleanly when Clak's ScrollEnhancer
    // runs on the Mac: it sees the stream stop at meaningful velocity and
    // continues the slow part of the tail with pixel-smooth momentum events.
    private static let momentumStopVelocity: CGFloat = 100 // pt/s = 10 ticks/s
    private static let flingMaxSampleAge: TimeInterval = 0.1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            cancelMomentum()
        }
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelMomentum()
        if activeTouches.isEmpty {
            sessionMaxTouches = 0
            sessionStart = ProcessInfo.processInfo.systemUptime
            dragDistance = 0
            pendingDelta = .zero
            scrollAccX = 0
            scrollAccY = 0
            lastTouchTimestamp = touches.first?.timestamp ?? 0
        }
        activeTouches.formUnion(touches)
        if activeTouches.count >= 2, sessionMaxTouches < 2 {
            scrollVelocityX = 0
            scrollVelocityY = 0
            lastScrollTimestamp = touches.first?.timestamp ?? 0
        }
        sessionMaxTouches = max(sessionMaxTouches, activeTouches.count)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let deltas = touches.map { touch -> CGPoint in
            let current = touch.location(in: self)
            let previous = touch.previousLocation(in: self)
            return CGPoint(x: current.x - previous.x, y: current.y - previous.y)
        }
        guard !deltas.isEmpty else { return }
        let avgX = deltas.map(\.x).reduce(0, +) / CGFloat(deltas.count)
        let avgY = deltas.map(\.y).reduce(0, +) / CGFloat(deltas.count)
        dragDistance += abs(avgX) + abs(avgY)

        let timestamp = touches.first?.timestamp ?? 0

        // Branch on the session max, not the live count: fingers lift
        // non-simultaneously, so a scroll session must never fall through to
        // the pointer branch when only the last finger remains.
        if sessionMaxTouches >= 2 {
            // Natural scrolling: fingers up = content moves up = wheel down
            let dt = max(timestamp - lastScrollTimestamp, 0.004)
            lastScrollTimestamp = timestamp
            scrollAccX += -avgX / Self.pointsPerScrollLine
            scrollAccY += -avgY / Self.pointsPerScrollLine
            scrollVelocityX = 0.8 * (-avgX / CGFloat(dt)) + 0.2 * scrollVelocityX
            scrollVelocityY = 0.8 * (-avgY / CGFloat(dt)) + 0.2 * scrollVelocityY
        } else {
            let dt = max(timestamp - lastTouchTimestamp, 0.004)
            lastTouchTimestamp = timestamp
            let speed = hypot(avgX, avgY) / CGFloat(dt)
            let normalized = min(speed / Self.accelMaxSpeed, 1)
            let gain = Self.accelMinGain
                + (Self.accelMaxGain - Self.accelMinGain) * pow(normalized, Self.accelExponent)
            pendingDelta.width += avgX * Constants.Trackpad.sensitivity * gain
            pendingDelta.height += avgY * Constants.Trackpad.sensitivity * gain
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMoveSend >= Constants.Trackpad.moveReportInterval else { return }
        lastMoveSend = now
        flushPending()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        guard activeTouches.isEmpty else { return }
        flushPending()

        let duration = ProcessInfo.processInfo.systemUptime - sessionStart
        if dragDistance < Constants.Trackpad.tapThreshold && duration < Self.tapMaxDuration {
            // 1-finger tap = left click, 2-finger tap = right click
            controller?.mouseClick(button: sessionMaxTouches >= 2 ? 0x02 : 0x01)
            return
        }

        if sessionMaxTouches >= 2 {
            startMomentumIfFlung(liftTimestamp: touches.first?.timestamp ?? 0)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        if activeTouches.isEmpty {
            pendingDelta = .zero
            scrollAccX = 0
            scrollAccY = 0
        }
    }

    // MARK: - Momentum

    private func startMomentumIfFlung(liftTimestamp: TimeInterval) {
        // A pause before lifting means "stop", not "fling"
        guard liftTimestamp - lastScrollTimestamp < Self.flingMaxSampleAge else { return }
        guard max(abs(scrollVelocityX), abs(scrollVelocityY)) > Self.flingMinVelocity else { return }

        momentumVX = scrollVelocityX.clamped(to: Self.flingMaxVelocity)
        momentumVY = scrollVelocityY.clamped(to: Self.flingMaxVelocity)
        momentumAccX = 0
        momentumAccY = 0
        lastMomentumTimestamp = CACurrentMediaTime()

        // Weak proxy target: CADisplayLink retains its target, so a direct
        // `self` would keep a dead view alive and scrolling after removal.
        let proxy = DisplayLinkProxy()
        proxy.onTick = { [weak self] link in
            guard let self else {
                link.invalidate()
                return
            }
            self.momentumTick(link)
        }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    private func momentumTick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = CGFloat(min(now - lastMomentumTimestamp, 0.1))
        lastMomentumTimestamp = now

        let decay = exp(-dt / Self.momentumTimeConstant)
        momentumVX *= decay
        momentumVY *= decay

        momentumAccX += momentumVX * dt / Self.pointsPerScrollLine
        momentumAccY += momentumVY * dt / Self.pointsPerScrollLine
        let pan = Self.takeTick(&momentumAccX)
        let wheel = Self.takeTick(&momentumAccY)
        if wheel != 0 || pan != 0 {
            controller?.mouseScroll(wheel: wheel, pan: pan)
        }

        if abs(momentumVX) < Self.momentumStopVelocity && abs(momentumVY) < Self.momentumStopVelocity {
            cancelMomentum()
        }
    }

    private func cancelMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
        momentumVX = 0
        momentumVY = 0
        momentumAccX = 0
        momentumAccY = 0
    }

    // MARK: - Sending

    private func flushPending() {
        let dx = Self.clamp(pendingDelta.width)
        let dy = Self.clamp(pendingDelta.height)
        if dx != 0 || dy != 0 {
            pendingDelta.width -= CGFloat(dx)
            pendingDelta.height -= CGFloat(dy)
            controller?.mouseMove(dx: dx, dy: dy)
        }

        let pan = Self.takeTick(&scrollAccX)
        let wheel = Self.takeTick(&scrollAccY)
        if wheel != 0 || pan != 0 {
            controller?.mouseScroll(wheel: wheel, pan: pan)
        }
    }

    /// Pop at most one whole ±1 line tick, capping the leftover backlog so a
    /// fast drag doesn't keep scrolling long after the gesture.
    private static func takeTick(_ accumulator: inout CGFloat) -> Int8 {
        if accumulator >= 1 {
            accumulator = min(accumulator - 1, 2)
            return 1
        }
        if accumulator <= -1 {
            accumulator = max(accumulator + 1, -2)
            return -1
        }
        return 0
    }

    private static func clamp(_ value: CGFloat) -> Int8 {
        Int8(max(-127, min(127, value.rounded())))
    }
}

private final class DisplayLinkProxy: NSObject {
    var onTick: ((CADisplayLink) -> Void)?

    @objc func tick(_ link: CADisplayLink) {
        onTick?(link)
    }
}

private extension CGFloat {
    func clamped(to limit: CGFloat) -> CGFloat {
        Swift.max(-limit, Swift.min(limit, self))
    }
}
