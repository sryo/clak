import SwiftUI
import UIKit

enum ControlLayer {
    case media
    case keys
}

/// The control layer: one piece of glass floating over the trackpad.
///
/// The grammar is one rule — touch a key and you get the key, touch the
/// handle and you get the panel. So every gesture that moves the panel lives
/// on the grabber, and every gesture that produces input lives on a key. They
/// can't compete for the same touch.
struct ControlBar: View {
    let controller: RemoteController
    @Binding var layer: ControlLayer
    @Binding var isExpanded: Bool
    let isTyping: Bool
    let onToggleKeyboard: () -> Void

    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        VStack(spacing: 5) {
            grabber

            if isTyping {
                typingComplement
            } else {
                if isExpanded {
                    expandedRow
                    Divider().overlay(Color.white.opacity(0.08)).padding(.horizontal, 12)
                }
                mainRow
            }
        }
        .padding(.top, 9)
        .padding(.bottom, 6)
        .padding(.horizontal, 8)
        .glassPanel(cornerRadius: ControlMetrics.barRadius)
        .glassGroup()
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: isExpanded)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: layer)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: isTyping)
    }

    // MARK: - Handle

    private var grabber: some View {
        Capsule()
            .fill(Color.white.opacity(0.30))
            .frame(width: ControlMetrics.grabberWidth, height: ControlMetrics.grabberHeight)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(panelGesture)
            .accessibilityElement()
            .accessibilityLabel("Control panel")
            .accessibilityValue(layer == .media ? "Media layer" : "Keys layer")
            .accessibilityHint("Swipe up for more controls, left or right to change layer")
            // Gesture-only switching would strand VoiceOver, so the same two
            // moves are reachable as actions.
            .accessibilityAction(named: isExpanded ? "Collapse" : "Expand") {
                isExpanded.toggle()
            }
            .accessibilityAction(named: layer == .media ? "Switch to keys" : "Switch to media") {
                layer = layer == .media ? .keys : .media
            }
    }

    private var panelGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height

                if abs(horizontal) > abs(vertical) {
                    guard abs(horizontal) > 24 else { return }
                    layer = layer == .media ? .keys : .media
                    isExpanded = false
                } else {
                    guard abs(vertical) > 20 else { return }
                    isExpanded = vertical < 0
                }
                haptic.impactOccurred()
            }
    }

    // MARK: - Rows

    @ViewBuilder
    private var mainRow: some View {
        switch layer {
        case .media: mediaRow
        case .keys: keysRow
        }
    }

    @ViewBuilder
    private var expandedRow: some View {
        switch layer {
        case .media: mediaExtras
        case .keys: keysExtras
        }
    }

    private var mediaRow: some View {
        HStack(spacing: 0) {
            key("backward.fill", size: 28) { controller.tapConsumer(ConsumerUsage.previous) }

            // Tap plays or pauses; pulled sideways it becomes the scrubber.
            PullKey(axis: .horizontal, unit: "skips") { step in
                controller.seek(step)
            } onTap: {
                controller.tapConsumer(ConsumerUsage.playPause)
            } label: {
                Image(systemName: "playpause.fill").font(.system(size: 34))
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Play or pause")
            .accessibilityHint("Drag sideways to seek")

            key("forward.fill", size: 28) { controller.tapConsumer(ConsumerUsage.next) }

            separator

            PullKey(axis: .vertical, unit: "steps") { step in
                controller.tapConsumer(step > 0 ? ConsumerUsage.brightnessUp : ConsumerUsage.brightnessDown)
            } label: {
                Image(systemName: "sun.max").font(.system(size: 27))
            }
            .accessibilityLabel("Brightness")
            .accessibilityHint("Drag up or down to change")

            PullKey(axis: .vertical, unit: "steps") { step in
                controller.tapConsumer(step > 0 ? ConsumerUsage.volumeUp : ConsumerUsage.volumeDown)
            } onTap: {
                controller.tapConsumer(ConsumerUsage.mute)
            } label: {
                Image(systemName: "speaker.wave.2").font(.system(size: 27))
            }
            .accessibilityLabel("Volume")
            .accessibilityHint("Drag up or down to change, tap to mute")
        }
    }

    private var mediaExtras: some View {
        HStack(spacing: 0) {
            word("esc") { controller.pressKey(HIDKey.escape) }
            key("arrow.up.left.and.arrow.down.right", size: 24) { controller.toggleFullscreen() }
            key("captions.bubble", size: 24) { controller.toggleCaptions() }
            separator
            key("arrow.left", size: 24) { controller.seek(-1) }
            key("arrow.right", size: 24) { controller.seek(1) }
        }
    }

    private var keysRow: some View {
        HStack(spacing: 0) {
            modifier("shift", HIDModifier.shift)
            modifier("control", HIDModifier.control)
            modifier("option", HIDModifier.option)
            modifier("command", HIDModifier.command)
            key("delete.backward", size: 27) { controller.deleteBackward() }
            // Drawn rather than lettered: the legends are keys the Mac
            // receives, this is the one control that acts on this phone.
            key("keyboard.chevron.compact.down", size: 27, action: onToggleKeyboard)
                .disabled(controller.hardwareKeyboardAttached)
        }
    }

    private var keysExtras: some View {
        HStack(spacing: 0) {
            word("esc") { controller.pressKey(HIDKey.escape) }
            word("tab") { controller.pressKey(HIDKey.tab) }
            key("return", size: 24) { controller.pressKey(HIDKey.returnKey) }
            separator
            key("arrow.left", size: 24) { controller.pressKey(HIDKey.leftArrow) }
            key("arrow.down", size: 24) { controller.pressKey(HIDKey.downArrow) }
            key("arrow.up", size: 24) { controller.pressKey(HIDKey.upArrow) }
            key("arrow.right", size: 24) { controller.pressKey(HIDKey.rightArrow) }
        }
    }

    /// What the system keyboard doesn't have. iOS gives you letters and
    /// nothing else — no modifiers, no escape, no arrows — so this is the
    /// exact complement, and the reason the bar earns its space while typing.
    private var typingComplement: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                word("esc", height: ControlMetrics.compactKeyHeight) { controller.pressKey(HIDKey.escape) }
                key("arrow.left", size: 24, height: ControlMetrics.compactKeyHeight) { controller.pressKey(HIDKey.leftArrow) }
                key("arrow.down", size: 24, height: ControlMetrics.compactKeyHeight) { controller.pressKey(HIDKey.downArrow) }
                key("arrow.up", size: 24, height: ControlMetrics.compactKeyHeight) { controller.pressKey(HIDKey.upArrow) }
                key("arrow.right", size: 24, height: ControlMetrics.compactKeyHeight) { controller.pressKey(HIDKey.rightArrow) }
                key("keyboard.chevron.compact.down", size: 25, height: ControlMetrics.compactKeyHeight,
                    tint: .accentColor, action: onToggleKeyboard)
            }

            Divider().overlay(Color.white.opacity(0.08)).padding(.horizontal, 12)

            HStack(spacing: 0) {
                modifier("shift", HIDModifier.shift, height: ControlMetrics.compactKeyHeight)
                modifier("control", HIDModifier.control, height: ControlMetrics.compactKeyHeight)
                modifier("option", HIDModifier.option, height: ControlMetrics.compactKeyHeight)
                modifier("command", HIDModifier.command, height: ControlMetrics.compactKeyHeight)
                word("tab", height: ControlMetrics.compactKeyHeight) { controller.pressKey(HIDKey.tab) }
            }
        }
    }

    // MARK: - Building blocks

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.09))
            .frame(width: 1, height: 26)
    }

    private func key(
        _ systemName: String,
        size: CGFloat,
        height: CGFloat = ControlMetrics.keyHeight,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size))
                .frame(maxWidth: .infinity, minHeight: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? .primary)
    }

    private func word(
        _ text: String,
        height: CGFloat = ControlMetrics.keyHeight,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 19, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    /// Held modifiers are the one place colour appears in the keys layer.
    private func modifier(
        _ systemName: String,
        _ bit: UInt8,
        height: CGFloat = ControlMetrics.keyHeight
    ) -> some View {
        let active = controller.isModifierActive(bit)
        return Button {
            controller.toggleModifier(bit)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 27))
                .frame(maxWidth: .infinity, minHeight: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}
