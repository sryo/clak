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
    /// Finger movement in, mouse reports out, shaped so the Mac's pointer
    /// moves as its Magic Trackpad would.
    private var pointer = PointerAccelerator()
    private var lastMoveSend: TimeInterval = 0
    private var lastPointerTimestamp: TimeInterval = 0

    // Scroll: finger movement in, wheel ticks out, one axis each, shaped so
    // the Mac scrolls as its trackpad would.
    private var scrollX = ScrollAccelerator()
    private var scrollY = ScrollAccelerator()
    /// Touch movement paced out as one report per Bluetooth connection event.
    private var pacerX = ScrollPacer()
    private var pacerY = ScrollPacer()
    private var scrollVelocityX: CGFloat = 0 // pt/s, low-passed
    private var scrollVelocityY: CGFloat = 0
    private var lastScrollTimestamp: TimeInterval = 0

    /// Sends scroll at 120 Hz while fingers scroll and while a fling runs.
    private var scrollLink: CADisplayLink?
    private var lastScrollTick: TimeInterval = 0

    // Momentum (fling) — ariya/kinetic-style exponential decay
    private var momentumVX: CGFloat = 0
    private var momentumVY: CGFloat = 0
    private var isFlinging: Bool { momentumVX != 0 || momentumVY != 0 }

    private let dragHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let dropHaptic = UIImpactFeedbackGenerator(style: .light)
    private let gestureHaptic = UIImpactFeedbackGenerator(style: .rigid)

    // Momentum constants (τ from ariya/kinetic 325ms / iOS ~500ms; velocity
    // low-pass 0.8/0.2 per sample; fling only if the last sample is fresh)
    private static let momentumTimeConstant: CGFloat = 0.42
    private static let flingMinVelocity: CGFloat = 120   // pt/s
    private static let flingMaxVelocity: CGFloat = 4500  // pt/s
    // Stop while ticks are still dense (~10/s). Ending the client tail early
    // keeps it stutter-free, and hands off cleanly when Clak's ScrollEnhancer
    // runs on the Mac: it sees the stream stop at meaningful velocity and
    // continues the slow part of the tail with pixel-smooth momentum events.
    private static let momentumStopVelocity: CGFloat = 100 // pt/s
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
        accessibilityHint = "Drag to move the pointer. Tap to click, two fingers to scroll or pinch."
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
        let caughtFling = isFlinging
        cancelMomentum()
        let timestamp = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        if activeTouches.isEmpty {
            pointer.reset()
            scrollX.reset()
            scrollY.reset()
            scrollVelocityX = 0
            scrollVelocityY = 0
            lastPointerTimestamp = timestamp
            lastScrollTimestamp = timestamp
        }
        activeTouches.formUnion(touches)
        pointAtScreenIfNeeded()
        apply(recognizer.touchesBegan(samples(touches), at: timestamp, interruptsMomentum: caughtFling))
    }

    /// Absolute pointing (experiment): one finger places the cursor where it
    /// touches, instead of nudging it.
    private func pointAtScreenIfNeeded() {
        guard let controller, controller.isPointingAtScreen,
              activeTouches.count == 1, let touch = activeTouches.first,
              bounds.width > 0, bounds.height > 0 else { return }
        let location = touch.location(in: self)
        controller.pointAt(fractionX: location.x / bounds.width, fractionY: location.y / bounds.height)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let timestamp = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        // Every finger down, not just the ones that moved: a finger held
        // still is half of a pinch.
        apply(recognizer.touchesMoved(samples(activeTouches), at: timestamp), at: timestamp)

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMoveSend >= Constants.Trackpad.moveReportInterval else { return }
        lastMoveSend = now
        pointAtScreenIfNeeded()
        flushPending()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        let timestamp = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        if activeTouches.isEmpty {
            flushPending(draining: true)
        }
        apply(recognizer.touchesEnded(touches.map(Self.id(of:)), at: timestamp), at: timestamp)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        let timestamp = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        apply(recognizer.touchesCancelled(touches.map(Self.id(of:)), at: timestamp))
        if activeTouches.isEmpty {
            pointer.reset()
            cancelMomentum()
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
            // Absolute pointing already placed the cursor
            guard !controller.isPointingAtScreen else { break }
            pointer.finger(moved: CGVector(dx: dx, dy: dy), over: timestamp - lastPointerTimestamp)
            lastPointerTimestamp = timestamp

        case .scroll(let dx, let dy):
            // Natural scrolling: fingers up = content moves up = wheel down
            let dt = max(timestamp - lastScrollTimestamp, 0.004)
            lastScrollTimestamp = timestamp
            pacerX.finger(moved: -dx, over: dt)
            pacerY.finger(moved: -dy, over: dt)
            startScrollLink()
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
        startScrollLink()
    }

    private func startScrollLink() {
        guard scrollLink == nil else { return }
        lastScrollTick = CACurrentMediaTime()
        // Weak proxy target: CADisplayLink retains its target, so a direct
        // `self` would keep a dead view alive and scrolling after removal.
        let proxy = DisplayLinkProxy()
        proxy.onTick = { [weak self] link in
            guard let self else {
                link.invalidate()
                return
            }
            self.scrollTick(link)
        }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        // Ticks finer than touches, so sends can follow the link's own
        // schedule (see ScrollPacer).
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        scrollLink = link
    }

    private func scrollTick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = min(now - lastScrollTick, 0.1)
        lastScrollTick = now

        if isFlinging {
            // The fling keeps the fingers' last speed going, decaying,
            // through the same shaping as the scroll itself.
            let decay = exp(-CGFloat(dt) / Self.momentumTimeConstant)
            momentumVX *= decay
            momentumVY *= decay
            pacerX.fling(speed: momentumVX, over: dt)
            pacerY.fling(speed: momentumVY, over: dt)
            if abs(momentumVX) < Self.momentumStopVelocity && abs(momentumVY) < Self.momentumStopVelocity {
                momentumVX = 0
                momentumVY = 0
            }
        }

        let pan = pacerX.take(at: now)
        let wheel = pacerY.take(at: now)
        if pan != nil || wheel != nil {
            let pans = scrollX.reports(forFingerMoved: pan ?? 0, over: ScrollPacer.interval)
            let wheels = scrollY.reports(forFingerMoved: wheel ?? 0, over: ScrollPacer.interval)
            for i in 0..<max(pans.count, wheels.count) {
                sendScroll(pan: i < pans.count ? pans[i] : 0, wheel: i < wheels.count ? wheels[i] : 0)
            }
        }

        if !isFlinging, pacerX.isSettled, pacerY.isSettled {
            stopScrollLink()
        }
    }

    private func stopScrollLink() {
        scrollLink?.invalidate()
        scrollLink = nil
    }

    private func cancelMomentum() {
        momentumVX = 0
        momentumVY = 0
        pacerX.reset()
        pacerY.reset()
        scrollX.reset()
        scrollY.reset()
        stopScrollLink()
    }

    // MARK: - Sending

    /// One pointer report per call while moving; on lifting, whatever is
    /// still owed goes out too, rather than waiting for a next touch. Scroll
    /// goes out as each touch arrives instead (see ScrollAccelerator).
    private func flushPending(draining: Bool = false) {
        var reports = 0
        while reports < (draining ? 4 : 1), let report = pointer.nextReport() {
            controller?.mouseMove(dx: report.dx, dy: report.dy)
            reports += 1
        }
    }

    private func sendScroll(pan: Int, wheel: Int) {
        if wheel != 0 || pan != 0 {
            controller?.mouseScroll(wheel: Int8(wheel), pan: Int8(pan))
        }
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
