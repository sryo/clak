import SwiftUI
import UIKit

/// Touch surface driving the Mac: the Mac trackpad's gestures, recognized by
/// `TrackpadGestureRecognizer` and sent as pointer, button and wheel reports,
/// or as the shortcut macOS binds to the gesture when HID has no way to say it.
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

    private var recognizer = TrackpadGestureRecognizer()
    private var activeTouches: Set<UITouch> = []
    private var deadlineWork: DispatchWorkItem?

    // Pointer
    private var pendingDelta: CGSize = .zero
    private var lastMoveSend: TimeInterval = 0
    private var lastPointerTimestamp: TimeInterval = 0

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

    private let dragHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let dropHaptic = UIImpactFeedbackGenerator(style: .light)
    private let gestureHaptic = UIImpactFeedbackGenerator(style: .rigid)
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
        dragHaptic.prepare()
        dropHaptic.prepare()
        configureAccessibility()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        recognizer.surfaceWidth = bounds.width
    }

    /// Without this the surface is invisible to VoiceOver: nothing else lives
    /// in the connected view, so the screen reads as empty. `allowsDirectInteraction`
    /// is what lets raw touches through — otherwise VoiceOver eats them and the
    /// pointer never moves. The clicks are also offered as actions, since
    /// direct interaction is a hard gesture to discover.
    private func configureAccessibility() {
        isAccessibilityElement = true
        accessibilityLabel = "Trackpad"
        accessibilityHint = "Drag to move the pointer on your Mac. Tap to click, two fingers to scroll or pinch, three fingers to switch Spaces."
        accessibilityTraits = [.allowsDirectInteraction]
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Click") { [weak self] _ in
                self?.controller?.mouseClick(button: MouseButton.left)
                return true
            },
            UIAccessibilityCustomAction(name: "Right click") { [weak self] _ in
                self?.controller?.mouseClick(button: MouseButton.right)
                return true
            },
            UIAccessibilityCustomAction(name: "Start drag") { [weak self] _ in
                self?.controller?.mouseDown(button: MouseButton.left)
                return true
            },
            UIAccessibilityCustomAction(name: "Drop") { [weak self] _ in
                self?.controller?.mouseUp()
                return true
            },
        ]
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        switch direction {
        case .up: controller?.mouseScroll(wheel: -3)
        case .down: controller?.mouseScroll(wheel: 3)
        case .left: controller?.mouseScroll(wheel: 0, pan: -3)
        case .right: controller?.mouseScroll(wheel: 0, pan: 3)
        default: return false
        }
        return true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            cancelMomentum()
            activeTouches = []
            apply(recognizer.reset())
            // Also covers a drag started from the VoiceOver action, which the
            // recognizer never saw.
            controller?.mouseUp()
        }
    }

    // MARK: - Touches

    private static func id(of touch: UITouch) -> Int {
        ObjectIdentifier(touch).hashValue
    }

    private func samples(_ touches: Set<UITouch>) -> [Int: CGPoint] {
        Dictionary(uniqueKeysWithValues: touches.map { (Self.id(of: $0), $0.location(in: self)) })
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let caughtFling = momentumLink != nil
        cancelMomentum()
        let timestamp = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        if activeTouches.isEmpty {
            pendingDelta = .zero
            scrollAccX = 0
            scrollAccY = 0
            scrollVelocityX = 0
            scrollVelocityY = 0
            lastPointerTimestamp = timestamp
            lastScrollTimestamp = timestamp
        }
        activeTouches.formUnion(touches)
        apply(recognizer.touchesBegan(samples(touches), at: timestamp, interruptsMomentum: caughtFling))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let timestamp = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        // Every finger down, not just the ones that moved: a finger held
        // still is half of a pinch.
        apply(recognizer.touchesMoved(samples(activeTouches), at: timestamp), at: timestamp)

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMoveSend >= Constants.Trackpad.moveReportInterval else { return }
        lastMoveSend = now
        flushPending()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        let timestamp = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        if activeTouches.isEmpty {
            flushPending()
        }
        apply(recognizer.touchesEnded(touches.map(Self.id(of:)), at: timestamp), at: timestamp)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        let timestamp = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        apply(recognizer.touchesCancelled(touches.map(Self.id(of:)), at: timestamp))
        if activeTouches.isEmpty {
            pendingDelta = .zero
            scrollAccX = 0
            scrollAccY = 0
        }
    }

    // MARK: - Actions

    private func apply(_ actions: [TrackpadGestureRecognizer.Action], at timestamp: TimeInterval = 0) {
        for action in actions {
            apply(action, at: timestamp)
        }
        scheduleDeadline()
    }

    private func apply(_ action: TrackpadGestureRecognizer.Action, at timestamp: TimeInterval) {
        switch action {
        case .pointer, .scroll: break
        default: Log.hid.debug("Trackpad gesture: \(String(describing: action), privacy: .public)")
        }
        guard let controller else { return }
        switch action {
        case .pointer(let dx, let dy):
            let dt = max(timestamp - lastPointerTimestamp, 0.004)
            lastPointerTimestamp = timestamp
            let speed = hypot(dx, dy) / CGFloat(dt)
            let normalized = min(speed / Self.accelMaxSpeed, 1)
            let gain = Self.accelMinGain
                + (Self.accelMaxGain - Self.accelMinGain) * pow(normalized, Self.accelExponent)
            pendingDelta.width += dx * Constants.Trackpad.sensitivity * gain
            pendingDelta.height += dy * Constants.Trackpad.sensitivity * gain

        case .scroll(let dx, let dy):
            // Natural scrolling: fingers up = content moves up = wheel down
            let dt = max(timestamp - lastScrollTimestamp, 0.004)
            lastScrollTimestamp = timestamp
            scrollAccX += -dx / Self.pointsPerScrollLine
            scrollAccY += -dy / Self.pointsPerScrollLine
            scrollVelocityX = 0.8 * (-dx / CGFloat(dt)) + 0.2 * scrollVelocityX
            scrollVelocityY = 0.8 * (-dy / CGFloat(dt)) + 0.2 * scrollVelocityY

        case .scrollEnded:
            startMomentumIfFlung(liftTimestamp: timestamp)

        case .click(let button):
            controller.mouseClick(button: button == .left ? MouseButton.left : MouseButton.right)

        case .doubleClick:
            controller.mouseDoubleClick()

        case .buttonDown:
            controller.mouseDown(button: MouseButton.left)
            dragHaptic.impactOccurred()

        case .buttonUp:
            controller.mouseUp()
            dropHaptic.impactOccurred()

        case .swipe(_, let direction):
            // Content follows the fingers, as on the Mac: swiping left brings
            // in the Space to the right.
            switch direction {
            case .left: controller.sendShortcut(HIDKey.rightArrow, modifiers: HIDModifier.control)
            case .right: controller.sendShortcut(HIDKey.leftArrow, modifiers: HIDModifier.control)
            case .up: controller.tapConsumer(ConsumerUsage.missionControl)
            case .down: controller.sendShortcut(HIDKey.downArrow, modifiers: HIDModifier.control)
            }
            gestureHaptic.impactOccurred()

        case .zoom(let step):
            controller.sendShortcut(step > 0 ? HIDKey.equal : HIDKey.minus, modifiers: HIDModifier.command)
            gestureHaptic.impactOccurred(intensity: 0.6)

        case .rotate(let step):
            // Preview's and Photos' rotate commands.
            controller.sendShortcut(step > 0 ? HIDKey.r : HIDKey.l, modifiers: HIDModifier.command)
            gestureHaptic.impactOccurred()

        case .lookUp:
            controller.sendShortcut(HIDKey.d, modifiers: HIDModifier.control | HIDModifier.command)
            gestureHaptic.impactOccurred()

        case .gatherAll:
            controller.tapConsumer(ConsumerUsage.launchpad)
            gestureHaptic.impactOccurred()

        case .spreadAll:
            // Show Desktop's default shortcut. A third-party keyboard's F11
            // arrives as a real F11, never as a media key.
            controller.sendShortcut(HIDKey.f11, modifiers: 0)
            gestureHaptic.impactOccurred()

        case .edgeSwipeFromRight:
            controller.sendGlobeShortcut(HIDKey.n)
            gestureHaptic.impactOccurred()
        }
    }

    /// The drag's clutch grace runs out on the recognizer's clock, so wake
    /// it when the deadline passes.
    private func scheduleDeadline() {
        deadlineWork?.cancel()
        deadlineWork = nil
        guard let deadline = recognizer.nextDeadline else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.apply(self.recognizer.tick(at: ProcessInfo.processInfo.systemUptime))
        }
        deadlineWork = work
        let delay = max(deadline - ProcessInfo.processInfo.systemUptime, 0) + 0.005
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
