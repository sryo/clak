import SwiftUI

// MARK: - Pulsing Indicator Dot

struct PulsingIndicatorDot: View {
    let color: Color
    let isPulsing: Bool
    var size: CGFloat = 7

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: size, height: size)

            if isPulsing {
                // phaseAnimator instead of withAnimation(.repeatForever):
                // repeatForever in a global transaction leaks into unrelated
                // view changes (the connect crossfade), blinking the whole HUD
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .phaseAnimator([false, true]) { view, expanded in
                        view
                            .scaleEffect(expanded ? 2.5 : 1.0)
                            .opacity(expanded ? 0.0 : 0.6)
                    } animation: { expanding in
                        expanding ? .easeOut(duration: 1.5) : .linear(duration: 0.001)
                    }
            }
        }
    }
}
