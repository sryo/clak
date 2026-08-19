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
    /// Shown beneath the delta while pulling ("steps", "skips").
    let unit: String

    init(
        axis: PullAxis,
        unit: String,
        onStep: @escaping (Int) -> Void,
        onTap: (() -> Void)? = nil,
        @ViewBuilder label: () -> Label
    ) {
        self.axis = axis
        self.unit = unit
        self.onStep = onStep
        self.onTap = onTap
        self.label = label()
    }

    @State private var steppedTranslation: CGFloat = 0
    @State private var steps = 0
    @State private var isPulling = false
    @Namespace private var glass

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        label
            .frame(maxWidth: .infinity, minHeight: ControlMetrics.keyHeight)
            .contentShape(Rectangle())
            .overlay(alignment: overlayAlignment) {
                if isPulling {
                    PullTrack(axis: axis, steps: steps, unit: unit)
                        .transition(.scale(scale: 0.2, anchor: trackAnchor).combined(with: .opacity))
                }
            }
            .gesture(pull)
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isPulling)
    }

    private var overlayAlignment: Alignment {
        axis == .vertical ? .bottom : .center
    }

    private var trackAnchor: UnitPoint {
        axis == .vertical ? .bottom : .center
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
    let unit: String

    private static let tickCount = 14

    var body: some View {
        Group {
            if axis == .vertical {
                VStack(spacing: 0) {
                    delta
                    Spacer(minLength: 14)
                    VStack(spacing: 7) {
                        ForEach(Array(ticks.reversed()), id: \.self) { index in
                            Capsule()
                                .fill(tint(for: index))
                                .frame(width: passed(index) ? 30 : 16, height: 2)
                        }
                    }
                    Spacer(minLength: 14)
                }
                .padding(.vertical, 18)
                .frame(width: 74, height: 396, alignment: .top)
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
                .frame(maxWidth: .infinity)
            }
        }
        .glassPanel(cornerRadius: axis == .vertical ? 37 : 30)
        .allowsHitTesting(false)
    }

    private var delta: some View {
        VStack(spacing: 5) {
            Text(steps > 0 ? "+\(steps)" : "\(steps)")
                .font(.system(size: 40, weight: .semibold))
                .monospacedDigit()
                .kerning(-1)
            Text(unit.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.tertiary)
        }
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
