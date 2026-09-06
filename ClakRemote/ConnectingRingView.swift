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
struct ConnectingRingView: View {
    let completedSteps: Int
    let retryWindow: RemoteController.RetryWindow?
    let symbol: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let diameter: CGFloat = 64
    private static let lineWidth: CGFloat = 4
    /// Fraction of the circle left empty between segments
    private static let gap: CGFloat = 0.04

    var body: some View {
        // Ticks only while a round is running; Reduce Motion gets one step a second
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : nil, paused: retryWindow == nil)) { context in
            let creep = retryWindow.map { $0.progress(at: context.date) } ?? 0
            ZStack {
                ForEach(0..<BringUp.stepCount, id: \.self) { index in
                    segment(index, fill: 1)
                        .stroke(Color.primary.opacity(0.12), style: strokeStyle)
                    let fill = fill(for: index, creep: creep)
                    if fill > 0 {
                        segment(index, fill: fill)
                            .stroke(
                                index < completedSteps ? Color.accentColor : Color.accentColor.opacity(0.55),
                                style: strokeStyle
                            )
                    }
                }
            }
            .rotationEffect(.degrees(-90))
            .animation(.easeInOut(duration: 0.3), value: completedSteps)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .overlay {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection progress")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var value = "\(completedSteps) of \(BringUp.stepCount) steps"
        if let window = retryWindow {
            let remaining = Int((1 - window.progress(at: Date())) * window.duration)
            value += ", \(remaining) seconds until the next try"
        }
        return value
    }

    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
    }

    private func fill(for index: Int, creep: Double) -> CGFloat {
        if index < completedSteps { return 1 }
        if index == completedSteps { return CGFloat(creep) }
        return 0
    }

    private func segment(_ index: Int, fill: CGFloat) -> some Shape {
        let span = 1 / CGFloat(BringUp.stepCount)
        let start = CGFloat(index) * span + Self.gap / 2
        let length = (span - Self.gap) * fill
        return Circle().trim(from: start, to: start + length)
    }
}

#Preview {
    VStack(spacing: 24) {
        ConnectingRingView(completedSteps: 1, retryWindow: nil, symbol: "laptopcomputer")
        ConnectingRingView(
            completedSteps: 3,
            retryWindow: .init(start: Date().addingTimeInterval(-3), duration: 8, attempt: 0),
            symbol: "laptopcomputer"
        )
        ConnectingRingView(completedSteps: 4, retryWindow: nil, symbol: "laptopcomputer")
    }
    .padding()
}
