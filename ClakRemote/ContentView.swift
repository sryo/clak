import SwiftUI

struct ContentView: View {
    let controller: RemoteController
    @State private var keyboardFocus = KeyboardFocus()
    @State private var layer: ControlLayer = .media
    @State private var isExpanded = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Content layer: the trackpad is the screen. No frame, no hint
            // text, no status row — a working keyboard is its own signal.
            if controller.status == .connected {
                TrackpadView(controller: controller)
                    .ignoresSafeArea()
            } else {
                PairingView(controller: controller)
            }

            if controller.status == .connected {
                VStack(spacing: 14) {
                    if keyboardFocus.isVisible, !controller.echo.isEmpty {
                        echo
                    }

                    ControlBar(
                        controller: controller,
                        layer: $layer,
                        isExpanded: $isExpanded,
                        isTyping: keyboardFocus.isVisible,
                        onToggleKeyboard: { keyboardFocus.toggle() }
                    )
                    .padding(.horizontal, ControlMetrics.barInset)
                }
                .padding(.bottom, keyboardFocus.isVisible ? 8 : ControlMetrics.barBottom)
            }

            KeyInputView(controller: controller, focus: keyboardFocus)
                .frame(width: 1, height: 1)
                .opacity(0.01)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onChange(of: keyboardFocus.isVisible) { _, visible in
            if !visible { controller.clearEcho() }
        }
    }

    /// What has gone out, so the phone can be typed on without watching the
    /// Mac. Exists only while the system keyboard is up.
    private var echo: some View {
        Text(controller.echo)
            .font(.system(size: 20))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 26)
            .transition(.opacity)
    }
}

/// Waiting to be picked up. A real Large Title, two steps, and the caveats
/// only where they apply.
private struct PairingView: View {
    let controller: RemoteController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ready to pair")
                .font(.largeTitle.bold())
            Text("Your Mac can see this iPhone as a keyboard.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            Spacer()

            AdvertisingMark()
                .frame(maxWidth: .infinity)

            Spacer()

            VStack(alignment: .leading, spacing: 20) {
                step(1, "On the Mac, open Settings ▸ Bluetooth and connect to Clak Remote.")
                step(2, "Confirm the request that appears here.")
            }

            Text("Keep this screen open — iOS hides Clak Remote from the Mac while the app is in the background.")
                .font(.footnote)
                .foregroundStyle(.quaternary)
                .padding(.top, 28)

            if controller.bluetoothPermissionDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 20)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(.tint)
            Text(text)
                .font(.body)
        }
    }
}

/// Concentric arcs standing in for the advertisement going out.
private struct AdvertisingMark: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { ring in
                Arcs(inset: CGFloat(ring))
                    .stroke(Color.accentColor.opacity(opacity(ring)), style: .init(lineWidth: 3 - CGFloat(ring) * 0.2, lineCap: .round))
                    .scaleEffect(pulse ? 1.02 : 0.98)
                    .animation(
                        .easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(Double(ring) * 0.18),
                        value: pulse
                    )
            }
            Circle()
                .fill(Color.accentColor)
                .frame(width: 14, height: 14)
        }
        .frame(width: 150, height: 150)
        .onAppear { pulse = true }
    }

    private func opacity(_ ring: Int) -> Double {
        [1.0, 0.5, 0.18][ring]
    }

    private struct Arcs: Shape {
        let inset: CGFloat

        func path(in rect: CGRect) -> Path {
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            let radius = 25 + inset * 20
            var path = Path()
            for start in [Angle(degrees: 120), Angle(degrees: -60)] {
                path.addArc(
                    center: centre, radius: radius,
                    startAngle: start, endAngle: start + .degrees(120),
                    clockwise: false
                )
                path.move(to: .zero)
            }
            return path
        }
    }
}
