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
        self.tug = tug
        self.trackAlignment = trackAlignment
        self.onStep = onStep
        self.onTap = onTap
        self.label = label()
    }

    @State private var steppedTranslation: CGFloat = 0
    @State private var steps = 0
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
                    PullTrack(axis: axis, steps: steps, columnHeight: columnHeight)
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
        steppedTranslation = 0
        steps = 0
        isPulling = false
    }

    private var pull: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                let travel = axis == .vertical ? value.translation.height : value.translation.width
                // Up and right are positive; on screen, up is negative height.
                let sign: CGFloat = axis == .vertical ? -1 : 1

                while (travel - steppedTranslation) * sign >= ControlMetrics.pointsPerStep {
                    steppedTranslation += ControlMetrics.pointsPerStep * sign
                    steps += 1
                    onStep(1)
                    Haptics.light.impactOccurred()
                }
                while (travel - steppedTranslation) * sign <= -ControlMetrics.pointsPerStep {
                    steppedTranslation -= ControlMetrics.pointsPerStep * sign
                    steps -= 1
                    onStep(-1)
                    Haptics.light.impactOccurred()
                }

                // Opens on the first step rather than the first movement:
                // between tapSlop and pointsPerStep it would otherwise sit on
                // screen reading 0 with nothing lit.
                if !isPulling, steps != 0 {
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

/// The grown form of a pulled key: a column or a bar of ticks, with the delta
/// spelled out big enough to read at arm's length.
private struct PullTrack: View {
    let axis: PullAxis
    let steps: Int
    let columnHeight: CGFloat

    var body: some View {
        Group {
            if axis == .vertical {
                VStack(spacing: 0) {
                    delta
                    // Spacers between the ticks rather than fixed gaps, so the
                    // strip fills whatever height it is given.
                    ForEach(Self.columnTicks.reversed(), id: \.self) { index in
                        Spacer(minLength: 3)
                        Capsule()
                            .fill(tint(for: index))
                            .frame(width: extent(index, zero: 34, filledSize: 30, rest: 16), height: index == 0 ? 3 : 2)
                    }
                    Spacer(minLength: 3)
                }
                .padding(.vertical, 18)
                .frame(width: 74, height: columnHeight, alignment: .top)
            } else {
                VStack(spacing: 10) {
                    delta
                    HStack(spacing: 5) {
                        ForEach(Self.scrubTicks, id: \.self) { index in
                            Capsule()
                                .fill(tint(for: index))
                                .frame(width: 2, height: extent(index, zero: 26, filledSize: 18, rest: 10))
                        }
                    }
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 18)
                // Sized by its ticks, not by the key it came out of.
                .fixedSize()
            }
        }
        .glassPanel(cornerRadius: axis == .vertical ? 37 : 30)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var delta: some View {
        Text(steps > 0 ? "+\(steps)" : "\(steps)")
            .font(.system(size: 40, weight: .semibold))
            .monospacedDigit()
            .kerning(-1)
    }

    // MARK: Ticks

    /// Both tracks read out from the centre, so pulling one way looks unlike
    /// pulling the other — direction is the whole point of a delta.
    private static let columnTicks = -7...7
    private static let scrubTicks = -10...10

    private func filled(_ index: Int) -> Bool {
        steps >= 0 ? (index > 0 && index <= steps) : (index < 0 && index >= steps)
    }

    private func tint(for index: Int) -> Color {
        if index == 0 { return Color.white.opacity(0.85) }
        return filled(index) ? .accentColor : Color.white.opacity(0.35)
    }

    private func extent(_ index: Int, zero: CGFloat, filledSize: CGFloat, rest: CGFloat) -> CGFloat {
        if index == 0 { return zero }
        return filled(index) ? filledSize : rest
    }
}
