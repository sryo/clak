import SwiftUI

struct MainView: View {
    var appState: AppState
    var bluetoothManager: BluetoothManager?

    @State private var idleOpacity: Double = 1.0
    @State private var idleFadeTimer: Timer?
    @State private var isWindowFocused = true
    @State private var showTrackpad = false
    @State private var hostWindow = WindowBox()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: HUDPresentation {
        HUDPresentation.make(
            HUDInput(appState),
            bindings: KeyboardShortcutManager.shared.registeredShortcuts
        )
    }

    private var contentOpacity: Double {
        isWindowFocused || presentation.staysOpaqueWhenInactive ? 1.0 : 0.6
    }

    private var trackpadVisible: Bool {
        showTrackpad && appState.isConnected && bluetoothManager != nil
    }

    var body: some View {
        let presentation = self.presentation

        HStack(alignment: .top, spacing: 8) {
            // Close button + status dot + caps lock
            HStack(spacing: 6) {
                Button {
                    hideWindow()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide Clak")
                .accessibilityLabel("Hide Clak")
                .opacity(isWindowFocused ? 1.0 : 0.0)
                .allowsHitTesting(isWindowFocused)

                HUDStatusDot(presentation: presentation)
                    .opacity(contentOpacity)

                if appState.capsLockActive {
                    Image(systemName: "capslock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Caps Lock is on")
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
                    .allowsHitTesting(isWindowFocused)
                    .help(showTrackpad ? "Hide trackpad" : "Show trackpad")
                    .accessibilityLabel(showTrackpad ? "Hide trackpad" : "Show trackpad")
                }
            }
            .padding(.top, 8)

            // Typing area on top, trackpad expands beneath it
            VStack(alignment: .leading, spacing: 8) {
                if presentation.showsEcho && !appState.typedText.isEmpty {
                    Text(appState.typedText)
                        .font(.system(size: 24, weight: .regular, design: .monospaced))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(idleOpacity * contentOpacity)
                        .transition(.opacity)
                } else {
                    message(presentation)
                        .opacity(contentOpacity)
                        .transition(.opacity)
                }

                if presentation.hint != nil || presentation.settings != nil {
                    GlassChipGroup {
                        if let hint = presentation.hint {
                            HintChip(hint: hint)
                        }
                        if let destination = presentation.settings {
                            Button("Open Settings") {
                                PermissionChecker.open(destination)
                            }
                            .modifier(ChipButtonStyle())
                        }
                    }
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
        .background(HostingWindowReader(box: hostWindow))
        .clipShape(RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius))
        .modifier(HUDWindowModifier())
        // Re-clip after the glass background so the window's outer corners
        // stay rounded in every focus state
        .clipShape(RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius))
        // Keyed on emptiness, not the text: the swap between echo and message
        // animates, but each keystroke doesn't restart a window-size animation
        .animation(.easeInOut(duration: 0.15), value: appState.typedText.isEmpty)
        .animation(.easeInOut(duration: 0.25), value: isWindowFocused)
        .animation(.easeInOut(duration: 0.2), value: appState.capsLockActive)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: presentation)
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

    // MARK: - Message

    private func message(_ presentation: HUDPresentation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(presentation.headline)
                .font(.system(size: 24, weight: .light, design: .rounded))
                .foregroundStyle(headlineStyle(presentation.tone))
                .fixedSize()
                .breathingAnimation(presentation.isPulsing)

            if let line = presentation.line {
                Text(line)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .help(presentation.detail ?? "")
        .accessibilityElement(children: .combine)
    }

    private func headlineStyle(_ tone: HUDPresentation.Tone) -> HierarchicalShapeStyle {
        switch tone {
        case .ready, .global: .quaternary
        case .waiting: .tertiary
        case .paused, .attention, .error: .secondary
        }
    }

    // MARK: - Hide

    /// Hides rather than quits: Clak keeps its menu bar item and its
    /// connection, and "Show Clak" in the menu brings the HUD back.
    private func hideWindow() {
        hostWindow.window?.orderOut(nil)
        let othersVisible = NSApp.windows.contains {
            $0 !== hostWindow.window && $0.isVisible && $0.styleMask.contains(.titled)
        }
        if !othersVisible {
            // Hand focus back so keys stop going to the device unseen
            NSApp.hide(nil)
        }
    }

    // MARK: - Idle Text Clearing

    private static let idleFadeDelay: TimeInterval = 2.0

    private func handleTextChange() {
        guard !appState.typedText.isEmpty else {
            return
        }

        if idleOpacity != 1.0 {
            idleOpacity = 1.0
        }

        // 2s idle -> fade out and clear. Typing only pushes the deadline back
        if let timer = idleFadeTimer, timer.isValid {
            timer.fireDate = Date(timeIntervalSinceNow: Self.idleFadeDelay)
            return
        }
        idleFadeTimer = Timer.scheduledTimer(withTimeInterval: Self.idleFadeDelay, repeats: false) { _ in
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
                .glassEffect(.regular, in: .rect(cornerRadius: HUDMetrics.cornerRadius))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius))
        }
    }
}

// MARK: - Chips

/// "⇧⌘G to stop": the chord in a key cap, then what it does.
struct HintChip: View {
    let hint: HUDPresentation.Hint

    var body: some View {
        HStack(spacing: 6) {
            if let keys = hint.keys {
                Text(keys)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .modifier(KeyCapGlassModifier())
            }
            Text(hint.text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

struct ChipButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .buttonStyle(.glass)
                .controlSize(.small)
        } else {
            content
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

// MARK: - Hosting Window

final class WindowBox {
    weak var window: NSWindow?
}

/// Gives SwiftUI a handle on the NSWindow it lives in.
struct HostingWindowReader: NSViewRepresentable {
    let box: WindowBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            box.window = view?.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            box.window = window
        }
    }
}

// MARK: - Breathing Animation

// phaseAnimator instead of a repeatForever animation, which leaks into the
// view's removal transition and blinks the whole HUD after a state change
struct BreathingModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .phaseAnimator([1.0, 0.6]) { view, phase in
                    view.opacity(phase)
                } animation: { _ in
                    .easeInOut(duration: 2.0)
                }
        }
    }
}

extension View {
    @ViewBuilder
    func breathingAnimation(_ isActive: Bool = true) -> some View {
        if isActive {
            modifier(BreathingModifier())
        } else {
            self
        }
    }
}

// MARK: - Previews

#Preview("Connected + Typing") {
    let state = AppState()
    state.isConnected = true
    state.connectedDeviceName = "iPhone de Mateo"
    state.appendText("Hello World")

    return MainView(appState: state)
}

#Preview("Waiting") {
    MainView(appState: AppState())
}

#Preview("Global") {
    let state = AppState()
    state.isConnected = true
    state.isGlobalForwarding = true
    state.connectedDeviceName = "iPhone de Mateo"

    return MainView(appState: state)
}

#Preview("Paused") {
    let state = AppState()
    state.isConnected = true
    state.isForwarding = false
    state.connectedDeviceName = "iPhone de Mateo"

    return MainView(appState: state)
}

#Preview("Input Monitoring") {
    let state = AppState()
    state.needsInputMonitoring = true

    return MainView(appState: state)
}

#Preview("Connected + Idle") {
    let state = AppState()
    state.isConnected = true
    state.connectedDeviceName = "iPhone de Mateo"

    return MainView(appState: state)
}
