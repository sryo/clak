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

/// Waiting to be picked up. Built like the setup screens iOS shows for the
/// same job: a title, a plain sentence saying what to do, and a spinner that
/// says it's still looking. No illustration, no invented step chrome.
private struct PairingView: View {
    let controller: RemoteController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ready to Pair")
                .font(.largeTitle.bold())

            Text("On your Mac, open Settings ▸ Bluetooth and connect to Clak Remote, then confirm the request that appears here.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            status
                .padding(.top, 4)

            Text("Keep this screen open — iOS hides Clak Remote from your Mac while the app is in the background.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            if controller.bluetoothPermissionDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var status: some View {
        switch controller.status {
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(.green)
        case .advertising, .waitingForBluetooth:
            HStack(spacing: 10) {
                ProgressView()
                Text(controller.status == .advertising ? "Waiting for your Mac…" : "Starting up…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

