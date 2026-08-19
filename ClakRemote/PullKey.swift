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
/// While it's being pulled the key grows along the axis it was pulled, into a
/// track showing how far you've come. That readout is deliberately a DELTA:
/// the Mac never reports its brightness, volume or playback position, and it
/// draws its own HUD for the first two, so an absolute level would be invented.
struct PullKey<Label: View>: View {
    let axis: PullAxis
    let label: Label
    /// Positive = up / right.
    let onStep: (Int) -> Void
    let onTap: (() -> Void)?
    /// Offset applied by a hint, to show that this key gives when pulled.
    var tug: CGFloat = 0
    /// Where the grown track hangs from. A key at the edge of the bar anchors
    /// its column to that edge, since a centred one would be cut off by the
    /// pager's clip.
    var trackAlignment: Alignment = .bottom

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
    /// Distance from the top of the screen to the top of this key — how much
    /// room a column has to grow into. Measured rather than assumed, because
    /// in landscape the whole screen is shorter than a portrait column.
    @State private var roomAbove: CGFloat = 400
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        HStack(spacing: 2) {
            label
            // These two keys behave unlike every other key on the bar, and
            // marking that is information rather than clutter — the same mark
            // iOS puts on a stepper. Unlike the hints, it never retires.
            Image(systemName: axis == .vertical ? "chevron.up.chevron.down" : "chevron.left.chevron.right")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
            .offset(x: axis == .horizontal ? tug : 0, y: axis == .vertical ? tug : 0)
            .frame(maxWidth: .infinity, minHeight: ControlMetrics.keyHeight(compact: isCompact))
            .contentShape(Rectangle())
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { roomAbove = geo.frame(in: .global).minY }
                        .onChange(of: geo.frame(in: .global).minY) { _, top in roomAbove = top }
                }
            )
            // Both tracks rise clear of the key rather than sitting on it: a
            // key is only ~70pt wide, so anything drawn inside one is squeezed
            // and clipped. The vertical column grows out of the key; the
            // horizontal one floats just above it, still over the bar.
            .overlay(alignment: trackAlignment) {
                if isPulling {
                    PullTrack(axis: axis, steps: steps, columnHeight: columnHeight)
                        .offset(y: axis == .horizontal ? -(ControlMetrics.keyHeight(compact: isCompact) + 14) : 0)
                        .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
                }
            }
            .gesture(pull)
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isPulling)
    }

    private var isCompact: Bool { verticalSizeClass == .compact }

    /// Never taller than the space above the key, so rotating to landscape
    /// shortens the column instead of running it off the screen.
    private var columnHeight: CGFloat {
        min(396, max(150, roomAbove - 24))
    }

    private var pull: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let travel = axis == .vertical ? value.translation.height : value.translation.width
                // Up and right are positive; on screen, up is negative height.
                let sign: CGFloat = axis == .vertical ? -1 : 1

                while (travel - steppedTranslation) * sign >= ControlMetrics.pointsPerStep {
                    steppedTranslation += ControlMetrics.pointsPerStep * sign
                    steps += 1
                    onStep(1)
                    haptic.impactOccurred()
                }
                while (travel - steppedTranslation) * sign <= -ControlMetrics.pointsPerStep {
                    steppedTranslation -= ControlMetrics.pointsPerStep * sign
                    steps -= 1
                    onStep(-1)
                    haptic.impactOccurred()
                }

                // Only claim the pull once it has actually moved, so a tap
                // never flashes the track open on its way past.
                if !isPulling, abs(travel) >= ControlMetrics.tapSlop {
                    isPulling = true
                }
            }
            .onEnded { value in
                if abs(value.translation.height) < ControlMetrics.tapSlop,
                   abs(value.translation.width) < ControlMetrics.tapSlop {
                    onTap?()
                    haptic.impactOccurred()
                }
                steppedTranslation = 0
                steps = 0
                isPulling = false
            }
    }
}

/// The grown form of a pulled key: a column or a bar of ticks, with the delta
/// spelled out big enough to read at arm's length.
private struct PullTrack: View {
    let axis: PullAxis
    let steps: Int
    var columnHeight: CGFloat = 396

    private static let tickCount = 14

    var body: some View {
        Group {
            if axis == .vertical {
                VStack(spacing: 0) {
                    delta
                    // Spacers between the ticks rather than fixed gaps, so the
                    // strip fills whatever height it is given.
                    ForEach(Array(ticks.reversed()), id: \.self) { index in
                        Spacer(minLength: 3)
                        Capsule()
                            .fill(tint(for: index))
                            .frame(width: passed(index) ? 30 : 16, height: 2)
                    }
                    Spacer(minLength: 3)
                }
                .padding(.vertical, 18)
                .frame(width: 74, height: columnHeight, alignment: .top)
            } else {
                VStack(spacing: 10) {
                    delta
                    HStack(spacing: 5) {
                        ForEach(scrubTicks, id: \.self) { index in
                            Capsule()
                                .fill(scrubTint(for: index))
                                .frame(width: 2, height: scrubHeight(for: index))
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
    }

    private var delta: some View {
        Text(steps > 0 ? "+\(steps)" : "\(steps)")
            .font(.system(size: 40, weight: .semibold))
            .monospacedDigit()
            .kerning(-1)
    }

    // MARK: Vertical ticks

    private var ticks: [Int] { Array(0..<Self.tickCount) }

    private func passed(_ index: Int) -> Bool { index < abs(steps) }

    private func tint(for index: Int) -> Color {
        passed(index) ? .accentColor : Color.white.opacity(0.16)
    }

    // MARK: Horizontal ticks — centred on where the drag began

    private var scrubTicks: [Int] { Array(-10...10) }

    private func scrubHeight(for index: Int) -> CGFloat {
        if index == 0 { return 26 }
        return inScrubRange(index) ? 18 : 10
    }

    private func scrubTint(for index: Int) -> Color {
        if index == 0 { return Color.white.opacity(0.85) }
        return inScrubRange(index) ? .accentColor : Color.white.opacity(0.16)
    }

    private func inScrubRange(_ index: Int) -> Bool {
        steps >= 0 ? (index > 0 && index <= steps) : (index < 0 && index >= steps)
    }
}
