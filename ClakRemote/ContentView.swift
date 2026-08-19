import Combine
import SwiftUI

struct ContentView: View {
    let controller: RemoteController
    @State private var keyboardFocus = KeyboardFocus()
    @State private var layer: ControlLayer = .media
    @State private var isExpanded = false
    @State private var coach = HintCoach()

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isCompact: Bool { verticalSizeClass == .compact }

    private var isConnected: Bool { controller.status == .connected }

    @State private var idleClock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: isCompact ? 8 : 10) {
            // In landscape the keyboard leaves about 200pt, which the bar and
            // the echo already spend. Keeping the surface would give it a
            // negative height and push the bar off the bottom.
            if !(keyboardFocus.isVisible && isCompact) {
                surface
            }

            if keyboardFocus.isVisible, !controller.echo.isEmpty {
                echo
            }

            // Always present, inert until there's something to send: the
            // layout never jumps, so where things live is learned during the
            // wait rather than at the moment of connecting.
            ControlBar(
                controller: controller,
                coach: coach,
                layer: $layer,
                isExpanded: $isExpanded,
                isTyping: keyboardFocus.isVisible,
                onToggleKeyboard: { keyboardFocus.toggle() }
            )
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .disabled(!isConnected)
            .opacity(isConnected ? 1 : 0.55)
            .animation(.easeInOut(duration: 0.28), value: isConnected)
        }
        .padding(.horizontal, ControlMetrics.barInset)
        .padding(.top, 10)
        .padding(.bottom, keyboardFocus.isVisible ? 8 : ControlMetrics.barBottom(compact: isCompact))
        .background(Color.black)
        .preferredColorScheme(.dark)
        .overlay {
            KeyInputView(controller: controller, focus: keyboardFocus)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onChange(of: keyboardFocus.isVisible) { _, visible in
            if !visible { controller.clearEcho() }
            coach.cancel()
        }
        .onChange(of: controller.hardwareKeyboardAttached) { _, attached in
            if attached, keyboardFocus.isVisible { keyboardFocus.dismiss() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: coach.sessionBegan()
            case .background: coach.sessionEnded()
            default: coach.cancel()
            }
        }
        .onReceive(idleClock) { _ in
            guard isConnected, !keyboardFocus.isVisible, coach.hasUnlearned else { return }
            coach.tick(
                idleFor: Date().timeIntervalSince(controller.lastInteraction),
                reduceMotion: reduceMotion
            )
        }
    }

    /// The touch surface, bounded so it reads as somewhere to put a thumb.
    /// While there's nothing to touch it carries the connection status
    /// instead — empty means ready.
    private var surface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))

            if isConnected {
                TrackpadView(controller: controller)
            } else {
                ScrollView {
                    WaitingView(controller: controller)
                        .frame(maxWidth: 420)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 20)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    /// What has gone out, so the phone can be typed on without watching the
    /// Mac. Exists only while the system keyboard is up.
    private var echo: some View {
        Text(controller.echo)
            .font(.system(size: 20))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity)
            .transition(.opacity)
    }
}

/// Shown inside the surface while no Mac has picked us up.
private struct WaitingView: View {
    let controller: RemoteController

    var body: some View {
        VStack(spacing: 14) {
            switch controller.status {
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
            default:
                ProgressView()
                Text(controller.status == .advertising ? "Waiting for your Mac" : "Starting up")
                    .font(.title3.weight(.semibold))
                Text("On your Mac, open Settings ▸ Bluetooth and connect to Clak Remote, then confirm the request that appears here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Keep this screen open — iOS hides Clak Remote from your Mac while the app is in the background.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            if controller.bluetoothPermissionDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
            }
        }
    }
}
