import SwiftUI

/// The connect flow as the phone can actually see it. A bonded Mac's side of
/// it is invisible until the moment it subscribes (measured: nothing arrives
/// before that), so the steps are the app's own bring-up plus that last one.
enum BringUp {
    /// Bluetooth on, keyboard published, visible to the Mac, connected.
    static let stepCount = 4

    static func stepsDone(
        status: RemoteController.Status, bluetoothOn: Bool, servicesPublished: Bool
    ) -> Int {
        switch status {
        case .connected:
            return stepCount
        case .advertising:
            // A republish in flight has taken the keyboard down for a moment
            return servicesPublished ? 3 : 1
        case .waitingForBluetooth, .error:
            return servicesPublished ? 2 : (bluetoothOn ? 1 : 0)
        }
    }
}

/// Segmented ring, one segment per bring-up step. The segment after the last
/// completed one creeps over the current retry round when there is one, so
/// the wait for the Mac reads as bounded: when it closes the app re-announces
/// itself and the segment starts over. Clock-driven rather than animated so a
/// round that restarts mid-fill stays honest.
///
/// The motion is springy on purpose: a step that completes pops in past full
/// and settles, the creeping segment breathes, a round that runs out springs
/// back as the finished steps pulse with the re-announce, and on connecting
/// the gaps close so the four segments become one ring.
struct ConnectingRingView: View {
    let completedSteps: Int
    let retryWindow: RemoteController.RetryWindow?
    let symbol: String
    /// Nothing can happen until the person acts, as with Bluetooth denied.
    var isDimmed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The step that just completed, and how far through its pop it is.
    @State private var poppedIndex: Int?
    @State private var pop: CGFloat = 0
    /// The finished steps' pulse as a round runs out and the app re-announces.
    @State private var pulse: CGFloat = 0
    /// The creeping segment springing back to empty at the end of a round.
    @State private var retract: CGFloat = 0
    @State private var swell: CGFloat = 1

    private static let diameter: CGFloat = 96
    private static let radius: CGFloat = 38
    private static let lineWidth: CGFloat = 6
    /// Fraction of the circle left empty between segments
    private static let gap: CGFloat = 0.06

    private var isJoined: Bool { completedSteps >= BringUp.stepCount }
    private var gap: CGFloat { isJoined ? 0 : Self.gap }
    private var span: CGFloat { 1 / CGFloat(BringUp.stepCount) - gap }

    var body: some View {
        // Ticks only while a round is running; Reduce Motion gets one step a second
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : nil, paused: retryWindow == nil)) { context in
            let creep = retryWindow.map { CGFloat($0.progress(at: context.date)) } ?? 0
            let breath = reduceMotion ? 0 : 0.2 * sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.6)
            ZStack {
                ForEach(0..<BringUp.stepCount, id: \.self) { index in
                    ArcBand(start: start(index), end: start(index) + span, radius: Self.radius, width: Self.lineWidth)
                        .fill(Color.primary.opacity(0.12))
                    if !isDimmed {
                        ArcBand(
                            start: start(index),
                            end: start(index) + span * (index < completedSteps ? 1 : 0),
                            radius: Self.radius,
                            width: Self.lineWidth * (1 + 0.5 * (index == poppedIndex ? pop : 0) + 0.4 * pulse)
                        )
                        .fill(Color.accentColor)
                        if index == completedSteps {
                            ArcBand(
                                start: start(index),
                                end: start(index) + span * max(creep, retract),
                                radius: Self.radius,
                                width: Self.lineWidth * (1 + breath)
                            )
                            .fill(Color.accentColor.opacity(0.55))
                        }
                    }
                }
            }
            .scaleEffect(swell)
            .animation(.spring(response: 0.5, dampingFraction: 0.5), value: completedSteps)
            .animation(.spring(response: 0.55, dampingFraction: 0.7), value: isJoined)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .overlay {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(isJoined ? AnyShapeStyle(.primary) : AnyShapeStyle(isDimmed ? .tertiary : .secondary))
                .animation(.easeInOut(duration: 0.3), value: isJoined)
        }
        .onChange(of: completedSteps) { old, new in
            guard new > old, !reduceMotion else { return }
            poppedIndex = new - 1
            bounce { pop = $0 }
            if new >= BringUp.stepCount {
                withAnimation(.easeOut(duration: 0.14)) { swell = 1.1 } completion: {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.45)) { swell = 1 }
                }
            }
        }
        .onChange(of: retryWindow?.start) { old, new in
            // A round that ran out, not the first one starting.
            guard old != nil, new != nil, !reduceMotion else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { retract = 1 }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { retract = 0 }
            bounce { pulse = $0 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection progress")
        .accessibilityValue(accessibilityValue)
    }

    /// Out quickly, then back on a spring that overshoots.
    private func bounce(_ set: @escaping (CGFloat) -> Void) {
        withAnimation(.easeOut(duration: 0.12)) { set(1) } completion: {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.45)) { set(0) }
        }
    }

    private var accessibilityValue: String {
        var value = "\(completedSteps) of \(BringUp.stepCount) steps"
        if let window = retryWindow {
            let remaining = Int((1 - window.progress(at: Date())) * window.duration)
            value += ", \(remaining) seconds until the next try"
        }
        return value
    }

    private func start(_ index: Int) -> CGFloat {
        CGFloat(index) / CGFloat(BringUp.stepCount) + gap / 2
    }
}

/// A round-capped band along part of a circle, from 12 o'clock clockwise, as
/// fractions of the whole turn. Animatable end to end, width included, so a
/// segment can spring past full and swell.
private struct ArcBand: Shape {
    var start: CGFloat
    var end: CGFloat
    let radius: CGFloat
    var width: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(start, end), width) }
        set {
            start = newValue.first.first
            end = newValue.first.second
            width = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let from = max(0, start), to = min(1, end)
        // A zero-length stroke with round caps still paints a dot.
        guard to - from > 0.002 else { return Path() }
        let circle = Path(ellipseIn: CGRect(x: rect.midX - radius, y: rect.midY - radius, width: 2 * radius, height: 2 * radius))
        let toTop = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: -.pi / 2)
            .translatedBy(x: -rect.midX, y: -rect.midY)
        return circle.trimmedPath(from: from, to: to)
            .applying(toTop)
            .strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

#Preview {
    VStack(spacing: 24) {
        ConnectingRingView(completedSteps: 1, retryWindow: nil, symbol: "dot.radiowaves.left.and.right")
        ConnectingRingView(
            completedSteps: 3,
            retryWindow: .init(start: Date().addingTimeInterval(-3), duration: 8, attempt: 0),
            symbol: "dot.radiowaves.left.and.right"
        )
        ConnectingRingView(completedSteps: 4, retryWindow: nil, symbol: "dot.radiowaves.left.and.right")
    }
    .padding()
}
