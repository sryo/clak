import SwiftUI

struct ContentView: View {
    let controller: RemoteController
    @State private var keyboardFocus = KeyboardFocus()

    var body: some View {
        VStack(spacing: 12) {
            statusBar

            if controller.status == .connected {
                trackpad
                functionRow
                specialKeysRow
                bottomRow
                if controller.droppedCharacterCount > 0 {
                    Label(
                        "\(controller.droppedCharacterCount) character\(controller.droppedCharacterCount == 1 ? "" : "s") couldn't be sent — only text typeable on a US-layout keyboard reaches the Mac.",
                        systemImage: "character.cursor.ibeam"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
                if controller.hardwareKeyboardAttached {
                    Label(
                        "iOS hides the on-screen keyboard while a Bluetooth keyboard is connected to this iPhone — disconnect it (e.g. Clak) in Settings → Bluetooth.",
                        systemImage: "keyboard.badge.ellipsis"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            } else {
                Spacer()
                pairingHint
                Spacer()
            }

            KeyInputView(controller: controller, focus: keyboardFocus)
                .frame(width: 1, height: 1)
                .opacity(0.01)
        }
        .padding()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    // MARK: - Sections

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
            Text(controller.status.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if controller.capsLockOn {
                Image(systemName: "capslock.fill")
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 4)
    }

    private var pairingHint: some View {
        VStack(spacing: 16) {
            Image(systemName: statusSymbol)
                .font(.system(size: 44))
                .foregroundStyle(statusColor)
            Text("On your Mac: System Settings → Bluetooth → connect to “Clak Remote”, then confirm the pairing request here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Text("Keep this screen open while pairing — iOS hides “Clak Remote” from the Mac's Bluetooth list while the app is in the background or the phone is locked.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if controller.bluetoothPermissionDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var trackpad: some View {
        TrackpadView(controller: controller)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                Text("drag · tap · 2-finger scroll")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
    }

    private var specialKeysRow: some View {
        HStack(spacing: 8) {
            keyButton("escape") { controller.pressKey(HIDKey.escape) }
            keyButton("arrow.right.to.line") { controller.pressKey(HIDKey.tab) }
            keyButton("return") { controller.pressKey(HIDKey.returnKey) }
            keyButton("arrow.left") { controller.pressKey(HIDKey.leftArrow) }
            keyButton("arrow.down") { controller.pressKey(HIDKey.downArrow) }
            keyButton("arrow.up") { controller.pressKey(HIDKey.upArrow) }
            keyButton("arrow.right") { controller.pressKey(HIDKey.rightArrow) }
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 8) {
            modifierToggle("shift", HIDModifier.shift)
            modifierToggle("control", HIDModifier.control)
            modifierToggle("option", HIDModifier.option)
            modifierToggle("command", HIDModifier.command)
            keyButton("delete.backward") { controller.deleteBackward() }
            keyboardToggle
        }
    }

    /// Mac-keyboard-style function row. Brightness and volume are drag-keys:
    /// drag up/down to step; tap on volume = mute.
    private var functionRow: some View {
        HStack(spacing: 4) {
            DragStepKey(
                systemName: "sun.max.fill",
                onStepUp: { controller.tapConsumer(ConsumerUsage.brightnessUp) },
                onStepDown: { controller.tapConsumer(ConsumerUsage.brightnessDown) },
                onTap: nil
            )
            functionKey("rectangle.3.group") { controller.tapConsumer(ConsumerUsage.missionControl) }
            functionKey("magnifyingglass") { controller.tapConsumer(ConsumerUsage.spotlight) }
            functionKey("backward.fill") { controller.tapConsumer(ConsumerUsage.previous) }
            functionKey("playpause.fill") { controller.tapConsumer(ConsumerUsage.playPause) }
            functionKey("forward.fill") { controller.tapConsumer(ConsumerUsage.next) }
            DragStepKey(
                systemName: "speaker.wave.2.fill",
                onStepUp: { controller.tapConsumer(ConsumerUsage.volumeUp) },
                onStepDown: { controller.tapConsumer(ConsumerUsage.volumeDown) },
                onTap: { controller.tapConsumer(ConsumerUsage.mute) }
            )
        }
    }

    private func functionKey(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.footnote)
        }
        .buttonStyle(KeyCapStyle(minHeight: 32))
    }

    private var keyboardToggle: some View {
        Button {
            keyboardFocus.toggle()
        } label: {
            Image(systemName: keyboardFocus.isVisible ? "keyboard.chevron.compact.down" : "keyboard")
        }
        .buttonStyle(KeyCapStyle(prominent: true))
        // iOS won't show the on-screen keyboard while a Bluetooth keyboard is attached
        .disabled(controller.hardwareKeyboardAttached)
    }

    // MARK: - Building blocks

    private func keyButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(KeyCapStyle())
    }

    private func modifierToggle(_ systemName: String, _ bit: UInt8) -> some View {
        Button {
            controller.toggleModifier(bit)
        } label: {
            Image(systemName: systemName)
        }
        .buttonStyle(KeyCapStyle(isOn: controller.isModifierActive(bit)))
    }

    private var statusSymbol: String {
        switch controller.status {
        case .waitingForBluetooth: "antenna.radiowaves.left.and.right.slash"
        case .advertising: "antenna.radiowaves.left.and.right"
        case .connected: "keyboard.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .waitingForBluetooth: .secondary
        case .advertising: .blue
        case .connected: .green
        case .error: .red
        }
    }
}

/// Single visual language for every keycap: same radius and fills across
/// plain keys, sticky modifiers (isOn), and the prominent keyboard button.
private struct KeyCapStyle: ButtonStyle {
    var minHeight: CGFloat = 40
    var isOn = false
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            .background(
                background(pressed: configuration.isPressed),
                in: RoundedRectangle(cornerRadius: 8)
            )
    }

    private func background(pressed: Bool) -> Color {
        if prominent {
            return Color.accentColor.opacity(pressed ? 0.7 : 1)
        }
        if isOn {
            return Color.accentColor.opacity(pressed ? 0.45 : 0.3)
        }
        return Color(uiColor: pressed ? .systemFill : .secondarySystemFill)
    }
}

/// A function-row key that steps a value by vertical drag (up = increase),
/// with a haptic tick per step. An optional plain tap fires `onTap`.
private struct DragStepKey: View {
    let systemName: String
    let onStepUp: () -> Void
    let onStepDown: () -> Void
    let onTap: (() -> Void)?

    private static let pointsPerStep: CGFloat = 14
    private static let tapSlop: CGFloat = 6

    @State private var steppedTranslation: CGFloat = 0
    @State private var isActive = false
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: systemName)
                .font(.footnote)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 32)
        .foregroundStyle(.tint)
        .background(
            Color(uiColor: isActive ? .systemFill : .secondarySystemFill),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isActive = true
                    // Drag up = negative height = step up
                    while value.translation.height - steppedTranslation <= -Self.pointsPerStep {
                        steppedTranslation -= Self.pointsPerStep
                        onStepUp()
                        haptic.impactOccurred()
                    }
                    while value.translation.height - steppedTranslation >= Self.pointsPerStep {
                        steppedTranslation += Self.pointsPerStep
                        onStepDown()
                        haptic.impactOccurred()
                    }
                }
                .onEnded { value in
                    isActive = false
                    if abs(value.translation.height) < Self.tapSlop,
                       abs(value.translation.width) < Self.tapSlop {
                        onTap?()
                        haptic.impactOccurred()
                    }
                    steppedTranslation = 0
                }
        )
    }
}
