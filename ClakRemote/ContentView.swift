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

    private var isConnected: Bool {
        #if DEBUG
        // The simulator can't be a BLE peripheral; this puts the surface up
        // anyway so touch handling can be driven there.
        if ProcessInfo.processInfo.arguments.contains("-ShowTrackpadUnconnected") { return true }
        #endif
        return controller.status == .connected
    }

    @State private var idleClock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    /// Trails isConnected on the way up, so the galaxy can collapse and burst
    /// over the surface before the trackpad is swapped in under it.
    @State private var showsTrackpad = false
    @State private var connectedAt: Date?
    /// Where the waiting screen left room for the galaxy, in surface space.
    @State private var galaxyOrigin: CGPoint?
    /// Off once the burst has faded from the connected surface.
    @State private var galaxyActive = true

    private static let surfaceSpace = "surface"

    var body: some View {
        VStack(spacing: isCompact ? 8 : 10) {
            // No trackpad while typing in landscape: the keyboard leaves too
            // little height for the surface to be worth anything, and forcing
            // it in pushes the bar off the bottom of the screen.
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
            .opacity(showsTrackpad ? 1 : 0.55)
            .animation(.easeInOut(duration: 0.35), value: showsTrackpad)
        }
        .padding(.horizontal, ControlMetrics.barInset)
        .padding(.top, 10)
        .padding(.bottom, keyboardFocus.isVisible ? 8 : ControlMetrics.barBottom(compact: isCompact))
        .background(Color.black)
        .dialOverlay()
        .preferredColorScheme(.dark)
        .overlay {
            // Barely rendered rather than hidden: a field at zero opacity, or
            // behind .hidden(), can't reliably hold first responder, and this
            // one is what turns the system keyboard into keystrokes.
            KeyInputView(controller: controller, focus: keyboardFocus)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onChange(of: isConnected, initial: true) { old, connected in
            guard connected else {
                showsTrackpad = false
                connectedAt = nil
                galaxyActive = true
                return
            }
            // Already up at launch: nothing to play
            guard old != connected else {
                showsTrackpad = true
                galaxyActive = false
                return
            }
            let now = Date()
            connectedAt = now
            let covered = reduceMotion ? ConnectingGalaxyView.reducedMotionCrossfade : ConnectingGalaxyView.coveredAfter
            DispatchQueue.main.asyncAfter(deadline: .now() + covered) {
                guard connectedAt == now else { return }
                withAnimation(.easeInOut(duration: reduceMotion ? 0.25 : 0.2)) { showsTrackpad = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + ConnectingGalaxyView.finishedAfter) {
                guard connectedAt == now else { return }
                galaxyActive = false
            }
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
            default: coach.cancel()
            }
        }
        .onReceive(idleClock) { _ in
            guard isConnected, !keyboardFocus.isVisible else { return }
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
            if showsTrackpad {
                TrackpadView(controller: controller)
                    .transition(.opacity)
            } else {
                // Scrolls only when it must, in a short landscape surface;
                // otherwise it sits centred.
                GeometryReader { geo in
                    ScrollView {
                        WaitingView(controller: controller, galaxyOrigin: $galaxyOrigin, surfaceSpace: Self.surfaceSpace)
                            .frame(maxWidth: 420)
                            .padding(.horizontal, 26)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .overlay(alignment: .bottom) {
                    if controller.status == .advertising {
                        Text("Keep this screen open while connecting")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 18)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: controller.status == .advertising)
                .transition(.opacity)
            }

            if galaxyActive, !isErrorStatus {
                ConnectingGalaxyView(
                    origin: galaxyOrigin,
                    connectedAt: connectedAt,
                    isDimmed: controller.bluetoothPermissionDenied
                )
            }
        }
        .coordinateSpace(.named(Self.surfaceSpace))
        .frame(maxHeight: .infinity)
        .clipShape(surfaceShape)
        .glassPanel(in: surfaceShape)
    }

    private var isErrorStatus: Bool {
        if case .error = controller.status { return true }
        return false
    }

    private var surfaceShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ControlMetrics.surfaceRadius, style: .continuous)
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

/// Shown inside the surface while no Mac has picked us up: room for the
/// galaxy, a headline and at most one line. The galaxy itself is drawn over
/// the whole surface so its burst can cover it; this only says where it goes.
private struct WaitingView: View {
    let controller: RemoteController
    @Binding var galaxyOrigin: CGPoint?
    let surfaceSpace: String

    /// A device that already knows us subscribes about a second into the
    /// first round, so a round that ran out means it isn't listening.
    private var isRetrying: Bool { (controller.retryWindow?.attempt ?? 0) > 0 }

    var body: some View {
        VStack(spacing: 16) {
            if case .error(let message) = controller.status {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
            } else {
                Color.clear
                    .frame(width: ConnectingGalaxyView.footprint, height: ConnectingGalaxyView.footprint)
                    .onGeometryChange(for: CGPoint.self) { proxy in
                        let frame = proxy.frame(in: .named(surfaceSpace))
                        return CGPoint(x: frame.midX, y: frame.midY)
                    } action: { galaxyOrigin = $0 }
                Text(headline)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                // Always two lines tall, empty or not, so the ring above never
                // shifts as the state changes; only the words fade.
                Text(line ?? " ")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: 260)
                    .opacity(line == nil ? 0 : 1)
                    .contentTransition(.opacity)
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
        .animation(.easeInOut(duration: 0.3), value: headline)
        .animation(.easeInOut(duration: 0.3), value: line)
    }

    private var headline: String {
        if controller.bluetoothPermissionDenied { return "Bluetooth access is off" }
        switch controller.status {
        case .connected: return "Connected"
        case .advertising: return isRetrying ? "Still waiting to connect" : "Waiting to connect"
        default: return "Starting up"
        }
    }

    private var line: String? {
        if controller.bluetoothPermissionDenied { return "Clak Remote needs Bluetooth to connect." }
        if controller.status == .advertising { return "Connect to Clak Remote in the other device\u{2019}s Bluetooth settings." }
        return nil
    }
}
