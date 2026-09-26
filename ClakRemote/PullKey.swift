import SwiftUI
import UIKit

enum PullAxis {
    case vertical
    case horizontal
}

/// A key that also holds a value you can pull out of it.
///
/// Tap fires the discrete action; dragging along `axis` steps the value, one
/// step and one haptic tick per `pointsPerStep` of travel. Both live on the
/// same control with no mode to be in — the finger holds the state, so it
/// can't be left switched on by accident.
///
/// A pull that runs out of room can keep going by curling round, in a circle
/// of any size; the track bends to follow (see `PullStepper`).
///
/// While it's being pulled the key opens a track along the axis it was pulled —
/// a column out of the key for vertical, a strip above it for horizontal —
/// showing how far you've come. That readout is deliberately a DELTA:
/// the Mac never reports its brightness, volume or playback position, and it
/// draws its own HUD for the first two, so an absolute level would be invented.
struct PullKey<Label: View>: View {
    let axis: PullAxis
    let label: Label
    /// Positive = up / right.
    let onStep: (Int) -> Void
    let onTap: (() -> Void)?
    /// Offset applied by a hint, to show that this key gives when pulled.
    let tug: CGFloat
    /// Where the grown track hangs from. A key at the edge of the bar anchors
    /// its column to that edge, since a centred one would be cut off by the
    /// pager's clip.
    let trackAlignment: Alignment

    init(
        axis: PullAxis,
        tug: CGFloat = 0,
        trackAlignment: Alignment = .bottom,
        onStep: @escaping (Int) -> Void,
        onTap: (() -> Void)? = nil,
        @ViewBuilder label: () -> Label
    ) {
        self.axis = axis
        self._stepper = State(initialValue: PullStepper(axis: axis))
        self.tug = tug
        self.trackAlignment = trackAlignment
        self.onStep = onStep
        self.onTap = onTap
        self.label = label()
    }

    @State private var stepper: PullStepper
    @State private var isPulling = false
    /// @GestureState reverts on its own when a gesture is cancelled, which is
    /// the only reliable signal that an interrupted drag has ended.
    @GestureState private var isDragging = false
    /// Distance from the top of the screen to the top of this key — how much
    /// room a column has to grow into. Measured rather than assumed, because
    /// in landscape the whole screen is shorter than a portrait column.
    @State private var roomAbove: CGFloat = 400
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion


    var body: some View {
        HStack(spacing: 2) {
            label
            // A pull key behaves unlike a plain one, and saying so is
            // information rather than clutter — the mark iOS puts on a
            // stepper. Unlike the coach's hints, it never retires.
            Image(systemName: axis == .vertical ? "chevron.up.chevron.down" : "chevron.left.chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
            .offset(x: axis == .horizontal ? tug : 0, y: axis == .vertical ? tug : 0)
            .frame(maxWidth: .infinity, minHeight: keyHeight)
            .contentShape(Rectangle())
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { roomAbove = geo.frame(in: .global).minY }
                        .onChange(of: geo.frame(in: .global).minY) { _, top in
                            if abs(top - roomAbove) > 1 { roomAbove = top }
                        }
                }
            )
            // Both tracks rise clear of the key rather than sitting on it: a
            // key is only ~70pt wide, so anything drawn inside one is squeezed
            // and clipped. The vertical column grows out of the key; the
            // horizontal one floats just above it, still over the bar.
            .overlay(alignment: trackAlignment) {
                if isPulling {
                    PullTrack(axis: axis, steps: stepper.steps, curvature: stepper.curvature, columnHeight: columnHeight)
                        .offset(y: axis == .horizontal ? -(keyHeight + 14) : 0)
                        .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
                }
            }
            .gesture(pull)
            .onChange(of: isDragging) { _, dragging in
                if !dragging { endPull() }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78), value: isPulling)
            // The step callbacks are exactly the shape an adjustable action
            // wants, so the value is reachable without performing the drag.
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(onTap == nil ? [] : .isButton)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onStep(1)
                case .decrement: onStep(-1)
                @unknown default: break
                }
            }
            .accessibilityAction { onTap?() }
    }

    private var isCompact: Bool { verticalSizeClass == .compact }
    private var keyHeight: CGFloat { ControlMetrics.keyHeight(compact: isCompact) }

    /// Never taller than the space above the key, so rotating to landscape
    /// shortens the column instead of running it off the screen. The floor is
    /// what the readout needs to stay legible; the ceiling is a portrait
    /// column's full height, and 24 keeps it clear of the status bar.
    private var columnHeight: CGFloat {
        min(ControlMetrics.maxPullReach, max(150, roomAbove - 24))
    }

    /// Everything a pull accumulates, cleared on any ending — normal or not.
    private func endPull() {
        stepper.reset()
        isPulling = false
    }

    private var pull: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                let delta = stepper.move(to: value.translation)
                for _ in 0..<abs(delta) {
                    onStep(delta > 0 ? 1 : -1)
                }
                if delta != 0 {
                    Haptics.light.impactOccurred()
                }

                // Opens on the first step rather than the first movement:
                // between tapSlop and pointsPerStep it would otherwise sit on
                // screen reading 0 with nothing lit.
                if !isPulling, stepper.steps != 0 {
                    isPulling = true
                }
            }
            .onEnded { value in
                if let onTap,
                   abs(value.translation.height) < ControlMetrics.tapSlop,
                   abs(value.translation.width) < ControlMetrics.tapSlop {
                    onTap()
                    Haptics.light.impactOccurred()
                }
                endPull()
            }
    }
}

/// The grown form of a pulled key: a tube of ticks with the delta spelled out
/// big enough to read at arm's length.
///
/// The tube is laid along an arc of the gesture's own curvature. Straight, it
/// is the column or strip a pull has always opened; curl the pull round and
/// it bends with you, closing into a ring on a tight circle. One shape the
/// whole way, so there is nothing to switch between.
private struct PullTrack: View {
    let axis: PullAxis
    let steps: Int
    let curvature: CGFloat
    let columnHeight: CGFloat

    var body: some View {
        let track = TrackGeometry(axis: axis, curvature: curvature, columnHeight: columnHeight)
        ZStack(alignment: .topLeading) {
            Color.clear
                .glassPanel(in: TubeShape(centreline: track.centreline, width: track.width))
            ForEach(track.ticks, id: \.self) { index in
                let place = track.tick(index)
                Capsule()
                    .fill(tint(for: index))
                    .frame(width: index == 0 ? 3 : 2, height: extent(index))
                    .rotationEffect(.radians(place.angle))
                    .position(place.point)
            }
            Text(steps > 0 ? "+\(steps)" : "\(steps)")
                .font(.system(size: 40, weight: .semibold))
                .monospacedDigit()
                .kerning(-1)
                .fixedSize()
                .position(track.label)
        }
        .frame(width: track.size.width, height: track.size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Ticks

    /// Past the end of the track the lit run starts over, like an odometer;
    /// the number carries the total.
    private var shown: Int {
        let count = axis == .vertical ? TrackGeometry.columnTicks.upperBound : TrackGeometry.scrubTicks.upperBound
        guard steps != 0 else { return 0 }
        let wrapped = (abs(steps) - 1) % count + 1
        return steps > 0 ? wrapped : -wrapped
    }

    /// Ticks read out from the centre, so pulling one way looks unlike pulling
    /// the other — direction is the whole point of a delta.
    private func filled(_ index: Int) -> Bool {
        shown >= 0 ? (index > 0 && index <= shown) : (index < 0 && index >= shown)
    }

    private func tint(for index: Int) -> Color {
        if index == 0 { return Color.white.opacity(0.85) }
        return filled(index) ? .accentColor : Color.white.opacity(0.35)
    }

    private func extent(_ index: Int) -> CGFloat {
        let (zero, lit, rest): (CGFloat, CGFloat, CGFloat) = axis == .vertical ? (34, 30, 16) : (26, 18, 10)
        if index == 0 { return zero }
        return filled(index) ? lit : rest
    }
}

/// Where everything on a bent track goes. The centreline is an arc starting
/// along the key's axis: s·t for a straight track, and for curvature κ
/// t·sin(κs)/κ + n·(1 − cos(κs))/κ, with t the axis and n a quarter turn
/// clockwise from it.
private struct TrackGeometry {
    static let columnTicks = -7...7
    static let scrubTicks = -10...10
    private static let scrubSpacing: CGFloat = 9
    /// A column curls nearly into a ring, stopping short of its ends meeting.
    /// The scrub strip is too short to make a legible ring, so it only arches.
    private static let columnMaxTurn: CGFloat = 2 * .pi * 0.88
    private static let stripMaxTurn: CGFloat = 2 * .pi * 0.6
    /// Below this the finger is pulling straight, however its thumb pivots,
    /// and the track stays straight.
    private static let straightCurvature: CGFloat = 1 / 300

    let axis: PullAxis
    let width: CGFloat
    let length: CGFloat
    let ticks: ClosedRange<Int>
    private let kappa: CGFloat
    private let tangent: CGVector
    private let normal: CGVector
    private let shift: CGPoint
    let size: CGSize
    let centreline: [CGPoint]
    let label: CGPoint

    init(axis: PullAxis, curvature: CGFloat, columnHeight: CGFloat) {
        self.axis = axis
        let vertical = axis == .vertical
        width = vertical ? 74 : 44
        ticks = vertical ? Self.columnTicks : Self.scrubTicks
        length = vertical ? columnHeight : CGFloat(Self.scrubTicks.count) * Self.scrubSpacing + 36
        let tangent = vertical ? CGVector(dx: 0, dy: -1) : CGVector(dx: 1, dy: 0)
        let normal = CGVector(dx: -tangent.dy, dy: tangent.dx)
        self.tangent = tangent
        self.normal = normal

        let bend = max(0, abs(curvature) - Self.straightCurvature)
        let maxTurn = vertical ? Self.columnMaxTurn : Self.stripMaxTurn
        let kappa = min(bend, maxTurn / length) * (curvature < 0 ? -1 : 1)
        self.kappa = kappa
        let length = length
        let raw = { (s: CGFloat) in
            TrackGeometry.arcPoint(s, kappa: kappa, tangent: tangent, normal: normal)
        }

        // Unshifted layout first, then everything moved so the bounding box
        // starts at the origin.
        let span = vertical ? 0...length : -length / 2...length / 2
        let line = (0...48).map { i in
            raw(span.lowerBound + (span.upperBound - span.lowerBound) * CGFloat(i) / 48)
        }
        let rest = vertical
            ? raw(length - 32)
            : CGPoint(x: -normal.dx * (width / 2 + 28), y: -normal.dy * (width / 2 + 28))
        // A column's number rides the top of the tube, then settles into the
        // middle of the ring as it closes; squared, so it stays on the tube
        // through a gentle bend. The weighted centre, t/κ, stays finite as κ
        // goes to zero. The strip's number sits beside its arch throughout.
        let closing = vertical ? pow(min(1, abs(kappa) * length / (2 * .pi)), 2) : 0
        let reach = kappa == 0 ? 0 : closing / kappa
        let rawLabel = CGPoint(x: rest.x * (1 - closing) + normal.dx * reach,
                               y: rest.y * (1 - closing) + normal.dy * reach)

        var box = CGRect(origin: line[0], size: .zero)
        for point in line { box = box.union(CGRect(origin: point, size: .zero)) }
        box = box.insetBy(dx: -width / 2, dy: -width / 2)
        box = box.union(CGRect(x: rawLabel.x - 44, y: rawLabel.y - 26, width: 88, height: 52))

        let offset = CGPoint(x: -box.minX, y: -box.minY)
        shift = offset
        size = box.size
        centreline = line.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
        label = CGPoint(x: rawLabel.x + offset.x, y: rawLabel.y + offset.y)
    }

    /// Position of a tick and the angle that stands it across the track.
    func tick(_ index: Int) -> (point: CGPoint, angle: CGFloat) {
        let s: CGFloat
        if axis == .vertical {
            // The top of the column is left for the number.
            let count = CGFloat(ticks.count - 1)
            s = 18 + CGFloat(index - ticks.lowerBound) / count * (length - 88)
        } else {
            s = CGFloat(index) * Self.scrubSpacing
        }
        let p = Self.arcPoint(s, kappa: kappa, tangent: tangent, normal: normal)
        return (CGPoint(x: p.x + shift.x, y: p.y + shift.y),
                atan2(tangent.dy, tangent.dx) + kappa * s)
    }

    private static func arcPoint(_ s: CGFloat, kappa: CGFloat, tangent: CGVector, normal: CGVector) -> CGPoint {
        let along: CGFloat, across: CGFloat
        if abs(kappa * s) < 1e-4 {
            along = s
            across = 0
        } else {
            along = sin(kappa * s) / kappa
            across = (1 - cos(kappa * s)) / kappa
        }
        return CGPoint(x: tangent.dx * along + normal.dx * across,
                       y: tangent.dy * along + normal.dy * across)
    }
}

/// The track's centreline drawn as a tube with round ends.
private struct TubeShape: Shape {
    let centreline: [CGPoint]
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        var line = Path()
        line.addLines(centreline)
        return line.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}
