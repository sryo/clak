import SwiftUI
import UIKit

/// A key that also holds a value you can turn.
///
/// Tap fires the discrete action. Drag off it and the key is a dial centred
/// where the finger landed: going round clockwise raises the value and
/// counterclockwise lowers it, one step and one haptic tick per
/// `PullStepper.stepAngle`. How far out the finger is sets the dial's size and
/// with it the gearing: close in is quick, and past `PullStepper.fineRadius`
/// each tick is a quarter step. Pulling straight out or back in only resizes
/// it. There is no mode to be in; the finger holds
/// the state, so it can't be left switched on by accident.
///
/// While it turns, a ring of ticks is drawn round the centre at the finger's
/// distance, lit from where the turn began to where the finger is. Its hub
/// shows what is being turned and which way, never a number: the Mac never
/// reports its brightness, volume or playback position, and a count of keys
/// sent reads as a level however it is signed. The Mac's own HUD shows the
/// level; the ring only says how far this turn has gone.
///
/// The ring is drawn by `dialOverlay()` at the top of the view tree rather than
/// on the key, because a dial is wider than the bar and the bar's pager clips.
struct PullKey<Label: View>: View {
    let label: Label
    let symbols: DialSymbols
    /// Positive = clockwise; the flag is true for a quarter step.
    let onStep: (Int, Bool) -> Void
    let onTap: (() -> Void)?
    /// Rotation applied by a hint, to show that this key turns.
    let twist: Angle
    /// When a turn ends, however it ends.
    let onEnd: (() -> Void)?

    init(
        allowsFine: Bool = true,
        symbols: DialSymbols,
        twist: Angle = .zero,
        onStep: @escaping (Int, Bool) -> Void,
        onTap: (() -> Void)? = nil,
        onEnd: (() -> Void)? = nil,
        @ViewBuilder label: () -> Label
    ) {
        self.onEnd = onEnd
        self.symbols = symbols
        self._stepper = State(initialValue: PullStepper(allowsFine: allowsFine))
        self.twist = twist
        self.onStep = onStep
        self.onTap = onTap
        self.label = label()
    }

    @State private var stepper: PullStepper
    /// Which way the latest step went, +1 or -1.
    @State private var lastDirection = 0
    /// Movements that stepped the value, each one a haptic tick.
    @State private var ticks = 0
    /// Where the finger landed, in global coordinates: the dial's centre.
    @State private var centre: CGPoint?
    /// @GestureState reverts on its own when a gesture is cancelled, which is
    /// the only reliable signal that an interrupted drag has ended.
    @GestureState private var isDragging = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            label
            // A turning key behaves unlike a plain one, and saying so is
            // information rather than clutter. Unlike the coach's hints, it
            // never retires.
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
            // Pressed like any other key while the finger is down on it: a
            // gesture, not a button, so KeyPress can't do it.
            .opacity(isPressed ? KeyPress.pressedOpacity : 1)
            .scaleEffect(isPressed ? KeyPress.pressedScale : 1)
            .animation(KeyPress.animation, value: isPressed)
            // The key is the dial's hub while it turns, and the delta is read
            // over it, so its own icon steps aside.
            .opacity(reading == nil ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: reading == nil)
            .rotationEffect(twist)
            .frame(maxWidth: .infinity, minHeight: ControlMetrics.keyHeight(compact: verticalSizeClass == .compact))
            .contentShape(Rectangle())
            .gesture(turn)
            .onChange(of: isDragging) { _, dragging in
                if !dragging { endTurn() }
            }
            .preference(key: DialPreference.self, value: reading)
            // The step callbacks are exactly the shape an adjustable action
            // wants, so the value is reachable without performing the drag.
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(onTap == nil ? [] : .isButton)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onStep(1, false)
                case .decrement: onStep(-1, false)
                @unknown default: break
                }
            }
            .accessibilityAction { onTap?() }
    }

    private var isPressed: Bool { isDragging && reading == nil }

    /// Shown once the finger is out of the dead middle, where there is a dial
    /// to see.
    private var reading: DialReading? {
        guard let centre, let angle = stepper.angle, let start = stepper.startAngle else { return nil }
        return DialReading(centre: centre, radius: stepper.radius, angle: angle, startAngle: start,
                           quarters: stepper.quarters, isFine: stepper.isFine,
                           symbol: symbols.symbol(forQuarters: stepper.quarters),
                           lastDirection: lastDirection, ticks: ticks)
    }

    /// Everything a turn accumulates, cleared on any ending — normal or not.
    private func endTurn() {
        #if DEBUG
        PullRecorder.finish()
        #endif
        stepper.reset()
        centre = nil
        onEnd?()
    }

    private var turn: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                if centre == nil { centre = value.startLocation }
                let steps = stepper.move(to: value.translation)
                #if DEBUG
                PullRecorder.record(value.translation, steps: stepper.quarters)
                #endif
                for step in steps {
                    onStep(step.direction, step.isQuarter)
                }
                if let last = steps.last {
                    lastDirection = last.direction
                    ticks += 1
                    Haptics.light.impactOccurred()
                }
            }
            .onEnded { value in
                if let onTap,
                   abs(value.translation.height) < ControlMetrics.tapSlop,
                   abs(value.translation.width) < ControlMetrics.tapSlop {
                    onTap()
                    Haptics.light.impactOccurred()
                }
                endTurn()
            }
    }
}

// MARK: - The ring

/// SF Symbols for the dial's hub: what is being turned, at rest and on
/// either side of where the turn began.
struct DialSymbols: Equatable {
    var rest: String
    var up: String
    var down: String

    func symbol(forQuarters quarters: Int) -> String {
        quarters > 0 ? up : quarters < 0 ? down : rest
    }
}

/// What a turning key hands up the tree for the ring to be drawn from. Angles
/// are in radians, screen coordinates, so increasing is clockwise.
struct DialReading: Equatable {
    var centre: CGPoint
    var radius: CGFloat
    var angle: CGFloat
    var startAngle: CGFloat
    /// The value in quarter steps.
    var quarters: Int
    /// Whether the dial is landing on quarters, which shows as the lines
    /// between the whole steps.
    var isFine: Bool
    /// The hub's SF Symbol.
    var symbol: String
    /// Which way the latest step went, +1 or -1: the way a swap animates.
    var lastDirection: Int
    /// Changes on every haptic tick, to bounce the symbol in time with it.
    var ticks: Int
}

struct DialPreference: PreferenceKey {
    static let defaultValue: DialReading? = nil

    static func reduce(value: inout DialReading?, nextValue: () -> DialReading?) {
        // Only one key turns at a time.
        value = value ?? nextValue()
    }
}

extension View {
    /// Draws the ring of whichever key is being turned, over everything.
    /// Applied once, high enough to span the screen.
    func dialOverlay() -> some View {
        overlayPreferenceValue(DialPreference.self) { reading in
            GeometryReader { geo in
                if let reading {
                    let origin = geo.frame(in: .global).origin
                    DialRing(reading: reading)
                        .position(x: reading.centre.x - origin.x, y: reading.centre.y - origin.y)
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: reading == nil)
        }
    }
}

/// A ring of lines round the dial's centre, one per whole step, lit from
/// where the turn began to where the value has got to, with what is being
/// turned, and which way, in the middle. Far out, where the dial lands on
/// quarters too, the quarter lines between the whole ones appear; the whole
/// ones stay where they were.
private struct DialRing: View {
    let reading: DialReading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let width: CGFloat = 44
    /// Small enough to stay under a finger turning close in, big enough for
    /// the symbol to sit clear of the ticks.
    private static let minRadius: CGFloat = 56
    private static let quartersPerLap = Int((2 * .pi / PullStepper.quarterAngle).rounded())

    var body: some View {
        let radius = max(reading.radius, Self.minRadius)
        let side = 2 * radius + Self.width
        ZStack {
            // A steady backing for the symbol, whatever is under the dial.
            Circle()
                .fill(Color.black.opacity(0.7))
                .frame(width: 2 * radius - Self.width, height: 2 * radius - Self.width)
            Color.clear
                .glassPanel(in: RingShape(radius: radius, width: Self.width))
            ForEach(lines, id: \.self) { index in
                let angle = reading.startAngle + CGFloat(index) * PullStepper.quarterAngle
                Capsule()
                    .fill(tint(index))
                    .frame(width: index == here || index == 0 ? 3 : 2, height: length(index))
                    .rotationEffect(.radians(angle + .pi / 2))
                    .position(x: side / 2 + radius * cos(angle), y: side / 2 + radius * sin(angle))
            }
            // Keyed by name, so each swap is a transition. The new symbol
            // settles the way the value went: down from larger when it fell,
            // up from smaller when it rose. SF Symbols' own replace always
            // grows the incoming symbol, which reads as rising either way.
            ZStack {
                Image(systemName: reading.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .id(reading.symbol)
                    .transition(.asymmetric(
                        insertion: .scale(scale: reading.lastDirection < 0 ? 1.35 : 0.65).combined(with: .opacity),
                        removal: .opacity))
            }
            .animation(.spring(duration: 0.3, bounce: 0.3), value: reading.symbol)
            // Each tick lands on the symbol like the haptic does: bouncing
            // out when the value rises, in when it falls. Every tick starts
            // from rest, so a fast turn still beats once per tick rather than
            // hovering at the peak. The hit leaves at full speed and slows
            // into its peak, then a spring rings back.
            .keyframeAnimator(initialValue: 1.0, trigger: reading.ticks) { symbol, scale in
                symbol.scaleEffect(scale)
            } keyframes: { _ in
                let sign: CGFloat = reading.lastDirection < 0 ? -1 : 1
                MoveKeyframe(1.0)
                CubicKeyframe(1 + sign * (reduceMotion ? 0 : 0.32), duration: 0.045,
                              startVelocity: sign * (reduceMotion ? 0 : 20), endVelocity: 0)
                SpringKeyframe(1.0, duration: 0.28, spring: Spring(duration: 0.28, bounce: 0.4))
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    /// Every quarter round the lap far out; near the key, the whole steps and
    /// wherever the value sits between them.
    private var lines: [Int] {
        (0..<Self.quartersPerLap).filter { reading.isFine || $0 % 4 == 0 || $0 == here }
    }

    /// The line the value has reached, counted round from the start.
    private var here: Int {
        ((reading.quarters % Self.quartersPerLap) + Self.quartersPerLap) % Self.quartersPerLap
    }

    /// Between the start and where the value is now, the way it turned. A
    /// whole lap or more lights the lot.
    private func isLit(_ index: Int) -> Bool {
        let quarters = reading.quarters
        if abs(quarters) >= Self.quartersPerLap { return true }
        if quarters > 0 { return index >= 1 && index <= quarters }
        if quarters < 0 { return index != 0 && index >= Self.quartersPerLap + quarters }
        return false
    }

    private func tint(_ index: Int) -> Color {
        if index == 0 { return Color.white.opacity(0.85) }
        return isLit(index) ? .accentColor : Color.white.opacity(0.35)
    }

    /// Quarter lines are drawn shorter than the whole steps they divide.
    private func length(_ index: Int) -> CGFloat {
        if index == here, reading.quarters != 0 { return 26 }
        if index == 0 { return 22 }
        let full: CGFloat = isLit(index) ? 18 : 10
        return index % 4 == 0 ? full : full * 0.55
    }
}

/// A band of the given width round a circle of the given radius, centred in
/// its frame.
private struct RingShape: Shape {
    let radius: CGFloat
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: CGRect(x: rect.midX - radius, y: rect.midY - radius, width: 2 * radius, height: 2 * radius))
            .strokedPath(StrokeStyle(lineWidth: width))
    }
}
