import CoreGraphics
import Foundation

/// The trackpad's gesture vocabulary as a pure state machine: touch samples
/// and timestamps in, actions out. No UIKit and no clock of its own, so every
/// gesture can be replayed in a unit test.
///
/// A generic HID device has no way to send macOS a real trackpad gesture, so
/// everything beyond pointing, clicking and scrolling comes out as a discrete
/// action the view turns into the shortcut macOS binds to that gesture.
///
/// Classification follows libinput's touchpad model: fingers stay undecided
/// until one of them travels past a commit distance, and the gesture is chosen
/// by what the fingers did together (translate, spread, twist), not by the
/// order they happened to land in.
struct TrackpadGestureRecognizer {
    enum Direction: Equatable {
        case left, right, up, down
    }

    enum Button: Equatable {
        case left, right
    }

    enum Action: Equatable {
        /// Finger travel in points, before pointer acceleration.
        case pointer(dx: CGFloat, dy: CGFloat)
        /// Finger travel in points; direction is the fingers', not the content's.
        case scroll(dx: CGFloat, dy: CGFloat)
        /// All fingers left a scroll; the view decides whether it was a fling.
        case scrollEnded
        case click(Button)
        case doubleClick
        case buttonDown
        case buttonUp
        /// Three or more fingers, fired once per gesture in the fingers' direction.
        case swipe(fingers: Int, Direction)
        /// +1 per pinch-out step, -1 per pinch-in step.
        case zoom(Int)
        /// +1 clockwise, -1 counterclockwise. At most one per gesture.
        case rotate(Int)
        /// Three-finger tap.
        case lookUp
        /// Thumb and three fingers pinched together.
        case gatherAll
        /// Thumb and three fingers spread apart.
        case spreadAll
        /// Two fingers swiped in from the right edge.
        case edgeSwipeFromRight
    }

    // Distances in points (an iPhone is about 6 pt/mm).
    static let tapSlop: CGFloat = 10
    /// Stricter for one finger, whose moves reach the pointer at once: a
    /// quick nudge must not also click.
    static let singleFingerTapSlop: CGFloat = 5
    static let tapMaxDuration: TimeInterval = 0.3
    /// Travel before a multi-finger gesture commits to a kind.
    static let commitDistance: CGFloat = 10
    /// A finger that lands this soon after a gesture committed re-opens it, so
    /// uneven landings aren't locked in as the lower finger count.
    static let fingerSettleWindow: TimeInterval = 0.15
    /// How long a scroll can still turn out to be a pinch or a twist.
    static let scrollReclassifyWindow: TimeInterval = 0.3
    /// How much a pinch or twist has to outweigh the fingers' shared travel.
    static let pinchDominance: CGFloat = 1.5
    /// Travel each finger needs before their directions are compared.
    static let opposingMinTravel: CGFloat = 4
    /// A finger moving less than this counts as the anchor of a pinch.
    static let anchorMaxTravel: CGFloat = 3
    /// The moving finger's path must stay within ~25° of the line to the anchor.
    static let anchoredRadialCosine: CGFloat = 0.9
    static let swipeDistance: CGFloat = 50
    /// The swipe's main axis has to beat the other one by this much.
    static let swipeAxisDominance: CGFloat = 1.5
    static let zoomStepRatio: CGFloat = 1.25
    /// Deliberately large: rotate is ⌘R, which elsewhere reloads a page.
    static let rotateStepAngle: CGFloat = .pi / 3
    /// Span ratio past which four fingers count as gathering or spreading.
    static let fourFingerPinchRatio: CGFloat = 0.7
    static let edgeWidth: CGFloat = 24
    /// How soon after a tap a press counts as the drag half of it. A
    /// one-finger tap's click is held back this long, as a Mac trackpad
    /// does with dragging on: sent at once, it would make the drag's press
    /// the second half of a double-click, and Finder opens a file on that
    /// instead of dragging it.
    static let dragArmWindow: TimeInterval = 0.25
    /// A drag survives lifts shorter than this, so the finger can be
    /// repositioned: the phone's surface is far smaller than the screen.
    static let dragClutchGrace: TimeInterval = 0.4
    /// Travel that turns an armed press into a drag.
    static let dragStartDistance: CGFloat = 3

    private enum Mode: Equatable {
        case idle
        case undecided
        case pointer
        case drag
        case scroll
        case zoom
        case rotate
        case swipe
        case fourFingerPinch
        /// Finished its one discrete action; waits for every finger to lift.
        case spent
    }

    private var mode: Mode = .idle
    private var positions: [Int: CGPoint] = [:]
    private var origins: [Int: CGPoint] = [:]
    private var sessionStart: TimeInterval = 0
    private var committedAt: TimeInterval = 0
    private var maxFingers = 0
    private var maxTravel: CGFloat = 0
    private var tapAllowed = true
    private var startedAtRightEdge = false

    /// When a held-back one-finger tap click goes out, unless a press
    /// arrives first and turns it into a drag or a double-click.
    private var pendingClickDeadline: TimeInterval?
    private var dragArmed = false
    private var buttonHeld = false
    private var dropDeadline: TimeInterval?

    private var zoomReferenceSpan: CGFloat = 0
    private var rotateReferenceAngle: CGFloat = 0

    /// Width of the touch surface, for the edge swipe.
    var surfaceWidth: CGFloat = 0

    /// When `tick(at:)` next has work to do, if ever.
    var nextDeadline: TimeInterval? {
        [dropDeadline, pendingClickDeadline].compactMap { $0 }.min()
    }

    var isButtonHeld: Bool { buttonHeld }

    // MARK: - Input

    /// `interruptsMomentum`: the touch stopped a fling in flight, so it's a
    /// catch, not a tap.
    mutating func touchesBegan(
        _ touches: [Int: CGPoint], at time: TimeInterval, interruptsMomentum: Bool = false
    ) -> [Action] {
        var actions: [Action] = []
        if positions.isEmpty {
            actions += startSession(at: time, interruptsMomentum: interruptsMomentum)
        }
        for (id, point) in touches {
            positions[id] = point
            origins[id] = point
        }
        if maxFingers == 0 {
            startedAtRightEdge = surfaceWidth > 0
                && touches.values.contains { $0.x >= surfaceWidth - Self.edgeWidth }
        }
        maxFingers = max(maxFingers, positions.count)

        if positions.count > 1 {
            if dragArmed {
                // A second finger: it wasn't the drag half after all.
                actions += flushPendingClick()
            }
            dragArmed = false
            switch mode {
            case .pointer:
                // Travel the pointer already made still counts, but against
                // the looser multi-finger slop a nudge would read as a tap.
                if maxTravel >= Self.singleFingerTapSlop {
                    tapAllowed = false
                }
                reopen(at: time)
            case .scroll, .zoom, .rotate, .swipe, .fourFingerPinch:
                if time - committedAt < Self.fingerSettleWindow {
                    reopen(at: time)
                }
            default:
                break
            }
        }
        return actions
    }

    /// `touches` holds every finger still down, moved or not: a finger held
    /// still is as much a part of a pinch as the one that moves.
    mutating func touchesMoved(_ touches: [Int: CGPoint], at time: TimeInterval) -> [Action] {
        let previous = positions
        for (id, point) in touches where positions[id] != nil {
            positions[id] = point
        }
        let step = Self.meanDelta(from: previous, to: positions)
        for (id, point) in positions {
            if let origin = origins[id] {
                maxTravel = max(maxTravel, Self.distance(origin, point))
            }
        }

        switch mode {
        case .idle, .spent:
            return []
        case .pointer:
            return [.pointer(dx: step.dx, dy: step.dy)]
        case .drag:
            return [.pointer(dx: step.dx, dy: step.dy)]
        case .undecided:
            return classify(at: time, step: step)
        case .scroll:
            if time - committedAt < Self.scrollReclassifyWindow,
               positions.count == 2,
               let twoFinger = twoFingerMotion(),
               twoFinger.fingersOppose,
               twoFinger.pinch >= 2 * Self.commitDistance,
               twoFinger.pinch > Self.pinchDominance * twoFinger.translation {
                // Only ever into a zoom: a scroll turning into a rotate would
                // fire ⌘R from what the user meant as a scroll.
                return commitPinch(twoFinger, at: time)
            }
            guard step != .zero else { return [] }
            return [.scroll(dx: step.dx, dy: step.dy)]
        case .zoom:
            return zoomSteps()
        case .rotate:
            return rotateStep()
        case .swipe:
            return swipeIfFar()
        case .fourFingerPinch:
            return fourFingerPinchIfFar()
        }
    }

    mutating func touchesEnded(_ ids: [Int], at time: TimeInterval) -> [Action] {
        for id in ids {
            positions[id] = nil
        }
        guard positions.isEmpty else { return [] }
        return endSession(at: time, cancelled: false)
    }

    mutating func touchesCancelled(_ ids: [Int], at time: TimeInterval) -> [Action] {
        for id in ids {
            positions[id] = nil
        }
        guard positions.isEmpty else { return [] }
        return endSession(at: time, cancelled: true)
    }

    /// Fires whatever was waiting on `nextDeadline`.
    mutating func tick(at time: TimeInterval) -> [Action] {
        var actions: [Action] = []
        if let deadline = pendingClickDeadline, time >= deadline, positions.isEmpty {
            actions += flushPendingClick()
        }
        if let deadline = dropDeadline, time >= deadline, positions.isEmpty {
            actions += releaseButton()
        }
        return actions
    }

    /// Lets go of everything: the view is leaving the screen.
    mutating func reset() -> [Action] {
        let actions = releaseButton()
        positions = [:]
        origins = [:]
        mode = .idle
        dragArmed = false
        pendingClickDeadline = nil
        return actions
    }

    // MARK: - Session

    private mutating func startSession(at time: TimeInterval, interruptsMomentum: Bool) -> [Action] {
        sessionStart = time
        committedAt = time
        maxFingers = 0
        maxTravel = 0
        origins = [:]
        tapAllowed = !interruptsMomentum
        startedAtRightEdge = false
        dragArmed = false

        var actions: [Action] = []
        if let deadline = pendingClickDeadline {
            if time < deadline {
                dragArmed = true
            } else {
                // The timer hasn't caught up; the tap was just a click.
                actions += flushPendingClick()
            }
        }

        if buttonHeld {
            // Back within the clutch grace: the drag carries on.
            dropDeadline = nil
            mode = .drag
        } else {
            mode = .undecided
        }
        return actions
    }

    private mutating func endSession(at time: TimeInterval, cancelled: Bool) -> [Action] {
        let wasMode = mode
        mode = .idle
        origins = [:]

        if cancelled {
            return flushPendingClick() + releaseButton()
        }

        let isTap = tapAllowed
            && maxTravel < (maxFingers == 1 ? Self.singleFingerTapSlop : Self.tapSlop)
            && time - sessionStart <= Self.tapMaxDuration

        if wasMode == .drag {
            if isTap, maxFingers == 1 {
                // A tap while the button is held drops what's being dragged.
                return releaseButton()
            }
            dropDeadline = time + Self.dragClutchGrace
            return []
        }

        switch wasMode {
        case .scroll:
            return [.scrollEnded]
        case .undecided, .pointer:
            guard isTap || (dragArmed && maxFingers == 1) else { return [] }
            switch maxFingers {
            case 1:
                if dragArmed {
                    // Pressed again without moving: the second click of a
                    // double-click. It doesn't arm another drag.
                    pendingClickDeadline = nil
                    return [.doubleClick]
                }
                pendingClickDeadline = time + Self.dragArmWindow
                return []
            case 2:
                return [.click(.right)]
            case 3:
                return [.lookUp]
            default:
                return []
            }
        default:
            return []
        }
    }

    private mutating func reopen(at time: TimeInterval) {
        mode = .undecided
        committedAt = time
        for (id, point) in positions {
            origins[id] = point
        }
    }

    private mutating func commit(_ newMode: Mode, at time: TimeInterval) {
        mode = newMode
        committedAt = time
        tapAllowed = false
        dragArmed = false
    }

    private mutating func flushPendingClick() -> [Action] {
        guard pendingClickDeadline != nil else { return [] }
        pendingClickDeadline = nil
        return [.click(.left)]
    }

    private mutating func releaseButton() -> [Action] {
        dropDeadline = nil
        guard buttonHeld else { return [] }
        buttonHeld = false
        return [.buttonUp]
    }

    // MARK: - Classification

    private mutating func classify(at time: TimeInterval, step: CGVector) -> [Action] {
        switch positions.count {
        case 0:
            return []
        case 1:
            if dragArmed {
                guard maxTravel >= Self.dragStartDistance else { return [] }
                commit(.drag, at: time)
                // The tap and this press are one held click, not two.
                pendingClickDeadline = nil
                buttonHeld = true
                return [.buttonDown, .pointer(dx: step.dx, dy: step.dy)]
            }
            guard maxTravel > 0 else { return [] }
            // One finger moves the pointer at once; waiting for a commit
            // distance would eat precise small moves. A tap stays possible
            // while travel is under the tap slop.
            mode = .pointer
            committedAt = time
            return [.pointer(dx: step.dx, dy: step.dy)]
        case 2:
            guard let motion = twoFingerMotion(),
                  max(motion.translation, motion.pinch, motion.twist) >= Self.commitDistance
            else { return [] }
            // Scroll unless the fingers clearly work against each other:
            // while scrolling, the span drifts nearly as much as the fingers
            // travel, so comparing sizes alone reads scrolls as pinches.
            if !motion.fingersOppose
                || max(motion.pinch, motion.twist) < Self.pinchDominance * motion.translation {
                if startedAtRightEdge, motion.dx < 0, abs(motion.dx) > 2 * abs(motion.dy) {
                    commit(.spent, at: time)
                    return [.edgeSwipeFromRight]
                }
                commit(.scroll, at: time)
                return [.scroll(dx: motion.dx, dy: motion.dy)]
            }
            return commitPinch(motion, at: time)
        default:
            let motion = groupMotion()
            guard max(motion.translation, motion.spread) >= Self.commitDistance else { return [] }
            if positions.count >= 4, motion.spread > motion.translation {
                commit(.fourFingerPinch, at: time)
                return fourFingerPinchIfFar()
            }
            commit(.swipe, at: time)
            return swipeIfFar()
        }
    }

    /// Commits and immediately takes any step the committing sample already
    /// reached: a quick pinch may deliver only a sample or two.
    private mutating func commitPinch(_ motion: TwoFingerMotion, at time: TimeInterval) -> [Action] {
        if motion.pinch >= motion.twist {
            commit(.zoom, at: time)
            zoomReferenceSpan = motion.originSpan
            return zoomSteps()
        }
        commit(.rotate, at: time)
        rotateReferenceAngle = motion.originAngle
        return rotateStep()
    }

    private mutating func zoomSteps() -> [Action] {
        guard let span = currentTwoFingerGeometry()?.span, zoomReferenceSpan > 0 else { return [] }
        var actions: [Action] = []
        while span >= zoomReferenceSpan * Self.zoomStepRatio {
            zoomReferenceSpan *= Self.zoomStepRatio
            actions.append(.zoom(1))
        }
        while span <= zoomReferenceSpan / Self.zoomStepRatio {
            zoomReferenceSpan /= Self.zoomStepRatio
            actions.append(.zoom(-1))
        }
        return actions
    }

    private mutating func rotateStep() -> [Action] {
        guard let angle = currentTwoFingerGeometry()?.angle else { return [] }
        let turned = Self.wrapped(angle - rotateReferenceAngle)
        guard abs(turned) >= Self.rotateStepAngle else { return [] }
        mode = .spent
        // Screen y grows downward, so a growing angle turns clockwise.
        return [.rotate(turned > 0 ? 1 : -1)]
    }

    private mutating func swipeIfFar() -> [Action] {
        let motion = groupMotion()
        let horizontal = abs(motion.dx)
        let vertical = abs(motion.dy)
        let direction: Direction
        if horizontal >= Self.swipeDistance, horizontal >= Self.swipeAxisDominance * vertical {
            direction = motion.dx < 0 ? .left : .right
        } else if vertical >= Self.swipeDistance, vertical >= Self.swipeAxisDominance * horizontal {
            direction = motion.dy < 0 ? .up : .down
        } else {
            return []
        }
        mode = .spent
        return [.swipe(fingers: min(positions.count, 4), direction)]
    }

    private mutating func fourFingerPinchIfFar() -> [Action] {
        let ratio = groupMotion().spreadRatio
        if ratio <= Self.fourFingerPinchRatio {
            mode = .spent
            return [.gatherAll]
        }
        if ratio >= 1 / Self.fourFingerPinchRatio {
            mode = .spent
            return [.spreadAll]
        }
        return []
    }

    // MARK: - Geometry

    private struct TwoFingerMotion {
        var dx: CGFloat
        var dy: CGFloat
        /// Centroid travel.
        var translation: CGFloat
        /// Change in the distance between the fingers.
        var pinch: CGFloat
        /// Arc each finger swept around the centroid, so a twist is weighed
        /// in the same points as the other two.
        var twist: CGFloat
        var originSpan: CGFloat
        var originAngle: CGFloat
        /// Both fingers moving apart in direction, or one held still while
        /// the other moves straight toward or away from it. Fingers that
        /// scroll together never do either.
        var fingersOppose: Bool
    }

    private func sortedPair(_ points: [Int: CGPoint]) -> (CGPoint, CGPoint)? {
        let ids = positions.keys.sorted()
        guard ids.count == 2, let a = points[ids[0]], let b = points[ids[1]] else { return nil }
        return (a, b)
    }

    private func currentTwoFingerGeometry() -> (span: CGFloat, angle: CGFloat)? {
        guard let (a, b) = sortedPair(positions) else { return nil }
        return (Self.distance(a, b), atan2(b.y - a.y, b.x - a.x))
    }

    private func twoFingerMotion() -> TwoFingerMotion? {
        guard let (a0, b0) = sortedPair(origins), let (a, b) = sortedPair(positions) else { return nil }
        let dx = ((a.x + b.x) - (a0.x + b0.x)) / 2
        let dy = ((a.y + b.y) - (a0.y + b0.y)) / 2
        let originSpan = Self.distance(a0, b0)
        let span = Self.distance(a, b)
        let originAngle = atan2(b0.y - a0.y, b0.x - a0.x)
        let angle = atan2(b.y - a.y, b.x - a.x)
        let moveA = CGVector(dx: a.x - a0.x, dy: a.y - a0.y)
        let moveB = CGVector(dx: b.x - b0.x, dy: b.y - b0.y)
        let axis = CGVector(dx: b0.x - a0.x, dy: b0.y - a0.y)
        let travelA = hypot(moveA.dx, moveA.dy)
        let travelB = hypot(moveB.dx, moveB.dy)
        let opposing = min(travelA, travelB) >= Self.opposingMinTravel
            && Self.cosine(moveA, moveB) < 0
        let anchored: Bool
        if min(travelA, travelB) < Self.anchorMaxTravel, max(travelA, travelB) >= Self.commitDistance {
            let moving = travelA > travelB ? moveA : moveB
            anchored = abs(Self.cosine(moving, axis)) >= Self.anchoredRadialCosine
        } else {
            anchored = false
        }
        return TwoFingerMotion(
            dx: dx,
            dy: dy,
            translation: hypot(dx, dy),
            pinch: abs(span - originSpan),
            twist: abs(Self.wrapped(angle - originAngle)) * min(originSpan, span) / 2,
            originSpan: originSpan,
            originAngle: originAngle,
            fingersOppose: opposing || anchored
        )
    }

    private struct GroupMotion {
        var dx: CGFloat
        var dy: CGFloat
        var translation: CGFloat
        /// Change in mean distance from the centroid, in points.
        var spread: CGFloat
        var spreadRatio: CGFloat
    }

    private func groupMotion() -> GroupMotion {
        let ids = positions.keys.filter { origins[$0] != nil }
        guard !ids.isEmpty else { return GroupMotion(dx: 0, dy: 0, translation: 0, spread: 0, spreadRatio: 1) }
        let start = ids.compactMap { origins[$0] }
        let now = ids.compactMap { positions[$0] }
        let startCenter = Self.centroid(start)
        let center = Self.centroid(now)
        let startRadius = start.map { Self.distance($0, startCenter) }.reduce(0, +) / CGFloat(start.count)
        let radius = now.map { Self.distance($0, center) }.reduce(0, +) / CGFloat(now.count)
        let dx = center.x - startCenter.x
        let dy = center.y - startCenter.y
        return GroupMotion(
            dx: dx,
            dy: dy,
            translation: hypot(dx, dy),
            spread: abs(radius - startRadius),
            spreadRatio: startRadius > 0 ? radius / startRadius : 1
        )
    }

    /// Mean step of the fingers present in both samples, so a finger landing
    /// or lifting never reads as a jump of the centroid.
    private static func meanDelta(from previous: [Int: CGPoint], to current: [Int: CGPoint]) -> CGVector {
        var sum = CGVector.zero
        var count = 0
        for (id, point) in current {
            guard let before = previous[id] else { continue }
            sum.dx += point.x - before.x
            sum.dy += point.y - before.y
            count += 1
        }
        guard count > 0 else { return .zero }
        return CGVector(dx: sum.dx / CGFloat(count), dy: sum.dy / CGFloat(count))
    }

    private static func cosine(_ a: CGVector, _ b: CGVector) -> CGFloat {
        let lengths = hypot(a.dx, a.dy) * hypot(b.dx, b.dy)
        guard lengths > 0 else { return 0 }
        return (a.dx * b.dx + a.dy * b.dy) / lengths
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    /// An angle difference folded into -π...π.
    private static func wrapped(_ angle: CGFloat) -> CGFloat {
        var value = angle
        while value > .pi { value -= 2 * .pi }
        while value < -.pi { value += 2 * .pi }
        return value
    }
}
