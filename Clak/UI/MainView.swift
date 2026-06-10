import SwiftUI

struct MainView: View {
    var appState: AppState
    var bluetoothManager: BluetoothManager?

    @State private var idleOpacity: Double = 1.0
    @State private var idleFadeTimer: Timer?
    @State private var isWindowFocused = true
    @State private var showTrackpad = false

    private var contentOpacity: Double {
        isWindowFocused ? 1.0 : 0.6
    }

    private var trackpadVisible: Bool {
        showTrackpad && appState.isConnected && bluetoothManager != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Close button + status dot + caps lock
            HStack(spacing: 6) {
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isWindowFocused ? 1.0 : 0.0)

                statusDot
                    .opacity(contentOpacity)

                if appState.capsLockActive {
                    Image(systemName: "capslock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                if appState.isConnected && bluetoothManager != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showTrackpad.toggle()
                        }
                    } label: {
                        Image(systemName: "cursorarrow.motionlines")
                            .font(.system(size: 10))
                            .foregroundStyle(showTrackpad ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(isWindowFocused ? 1.0 : 0.0)
                    .help(showTrackpad ? "Hide trackpad" : "Show trackpad")
                }
            }
            .padding(.top, 8)

            // Typing area on top, trackpad expands beneath it
            VStack(alignment: .leading, spacing: 8) {
                if appState.isConnected && !appState.typedText.isEmpty {
                    Text(appState.typedText)
                        .font(.system(size: 24, weight: .regular, design: .monospaced))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(idleOpacity * contentOpacity)
                        .transition(.opacity)
                } else if appState.isConnected {
                    Text("Type to \(appState.connectedDeviceName ?? "device")...")
                        .font(.system(size: 24, weight: .light, design: .rounded))
                        .foregroundStyle(.quaternary)
                        .fixedSize()
                        .opacity(contentOpacity)
                        .transition(.opacity)
                } else {
                    Text("Searching...")
                        .font(.system(size: 24, weight: .light, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .breathingAnimation()
                        .opacity(contentOpacity)
                        .transition(.opacity)
                }

                if trackpadVisible, let bluetoothManager {
                    TrackpadPaneView(bluetoothManager: bluetoothManager)
                        .opacity(contentOpacity)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .fixedSize()
        .background(.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .modifier(HUDWindowModifier())
        // Re-clip after the glass background so the window's outer corners
        // stay rounded in every focus state
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.15), value: appState.typedText)
        .animation(.easeInOut(duration: 0.25), value: isWindowFocused)
        .animation(.easeInOut(duration: 0.2), value: appState.capsLockActive)
        .animation(.easeInOut(duration: 0.25), value: appState.isConnected)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isWindowFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            isWindowFocused = false
        }
        .onChange(of: appState.typedText) {
            handleTextChange()
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusDot: some View {
        if appState.isConnected {
            PulsingIndicatorDot(color: Color(red: 0.204, green: 0.780, blue: 0.349), isPulsing: false, size: 7)
        } else if appState.errorMessage != nil {
            PulsingIndicatorDot(color: Color(red: 1.0, green: 0.231, blue: 0.188), isPulsing: false, size: 7)
        } else {
            PulsingIndicatorDot(color: Color(red: 1.0, green: 0.624, blue: 0.039), isPulsing: true, size: 7)
        }
    }

    // MARK: - Idle Text Clearing

    private func handleTextChange() {
        guard !appState.typedText.isEmpty else {
            return
        }

        idleOpacity = 1.0
        idleFadeTimer?.invalidate()

        // 2s idle -> fade out and clear
        idleFadeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.3)) {
                idleOpacity = 0.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                appState.clearText()
                idleOpacity = 1.0
            }
        }
    }
}

// MARK: - Liquid Glass / Fallback Modifiers

struct HUDWindowModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Breathing Animation

// phaseAnimator instead of a repeatForever animation, which leaks into the
// view's removal transition and blinks the whole HUD after a state change
struct BreathingModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .phaseAnimator([1.0, 0.6]) { view, phase in
                view.opacity(phase)
            } animation: { _ in
                .easeInOut(duration: 2.0)
            }
    }
}

extension View {
    func breathingAnimation() -> some View {
        modifier(BreathingModifier())
    }
}

// MARK: - Previews

#Preview("Connected + Typing") {
    let state = AppState()
    state.isConnected = true
    state.connectedDeviceName = "iPhone de Mateo"
    state.typedText = "Hello World"

    return MainView(appState: state)
}

#Preview("Searching") {
    MainView(appState: AppState())
}

#Preview("Connected + Idle") {
    let state = AppState()
    state.isConnected = true
    state.connectedDeviceName = "iPhone de Mateo"

    return MainView(appState: state)
}
