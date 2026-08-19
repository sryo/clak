import SwiftUI
import UIKit

enum ControlLayer {
    case media
    case keys
}

/// Clips the layer pager horizontally while leaving it open above, so the
/// neighbouring layer stays hidden but a pulled key can still grow out of the
/// bar.
private struct SidewaysClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - 1200, width: rect.width, height: rect.height + 1200))
    }
}

/// The control layer: one piece of glass floating over the trackpad.
///
/// The grammar is one rule — touch a key and you get the key, touch the
/// handle and you get the panel. So every gesture that moves the panel lives
/// on the grabber, and every gesture that produces input lives on a key. They
/// can't compete for the same touch.
struct ControlBar: View {
    let controller: RemoteController
    let coach: HintCoach
    @Binding var layer: ControlLayer
    @Binding var isExpanded: Bool
    let isTyping: Bool
    let onToggleKeyboard: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Travel added by a peek, alongside the finger's own.
    @State private var peekOffset: CGFloat = 0
    @State private var peekBump: CGFloat = 0
    @State private var pullTug: CGFloat = 0

    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    /// Live horizontal travel of the layer pager while the handle is dragged.
    @State private var dragOffset: CGFloat = 0
    @State private var barWidth: CGFloat = 0
    /// Locked on the first meaningful movement so one drag can't both switch
    /// layer and expand the panel.
    @State private var gestureAxis: PullAxis?
    /// Reverts by itself when a drag is cancelled — the only signal SwiftUI
    /// gives, since onEnded isn't delivered for an interrupted gesture.
    @GestureState private var isDraggingHandle = false

    /// Vertical gap the expanded row adds: two 5pt VStack spacings and the
    /// divider between them.
    private static let expandedGap: CGFloat = 11

    /// One curve for every panel-sized motion, so the pager and the handle
    /// that drives it can't land at different times.
    private var panelSpring: Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.84)
    }

    private var tap: UIImpactFeedbackGenerator { Self.tapHaptic }
    private static let tapHaptic = UIImpactFeedbackGenerator(style: .light)

    private var isCompact: Bool { verticalSizeClass == .compact }
    private var keyHeight: CGFloat { ControlMetrics.keyHeight(compact: isCompact) }
    private var typingKeyHeight: CGFloat { ControlMetrics.typingKeyHeight(compact: isCompact) }

    var body: some View {
        VStack(spacing: 5) {
            grabber

            if isTyping {
                typingComplement
            } else {
                layerPager
            }
        }
        .padding(.top, 9)
        .padding(.bottom, 6)
        .padding(.horizontal, 8)
        .glassPanel(cornerRadius: ControlMetrics.barRadius)
        .glassGroup()
        .animation(panelSpring, value: isExpanded)
        .animation(panelSpring, value: isTyping)
        .onChange(of: coach.current) { _, hint in
            guard let hint, hint.style == .peek, !reduceMotion else { return }
            demonstrate(hint.affordance)
        }
    }

    // MARK: - Hints

    /// Moves the thing in the direction it wants to be moved. A peek of the
    /// neighbouring layer teaches both that it exists and which way it lives,
    /// which a nudging handle on its own can't.
    private func demonstrate(_ affordance: Affordance) {
        let out = Animation.spring(response: 0.26, dampingFraction: 0.62)
        let back = Animation.spring(response: 0.44, dampingFraction: 0.74)

        switch affordance {
        case .layerSwipe:
            withAnimation(out) { peekOffset = layer == .media ? -26 : 26 }
            after(0.34) { withAnimation(back) { peekOffset = 0 } }
        case .panelExpand:
            withAnimation(out) { peekBump = 12 }
            after(0.34) { withAnimation(back) { peekBump = 0 } }
        case .pullKey:
            withAnimation(out) { pullTug = -8 }
            after(0.30) { withAnimation(back) { pullTug = 0 } }
        }
    }

    private func after(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private var wordsHint: Hint? {
        guard let hint = coach.current else { return nil }
        return (hint.style == .words || reduceMotion) ? hint : nil
    }

    // MARK: - Layer pager

    /// Both layers sit side by side and travel under the thumb, so a swipe
    /// reveals where it is going and can be walked back before it commits.
    private var layerPager: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                layerStack(.media).frame(width: geo.size.width)
                layerStack(.keys).frame(width: geo.size.width)
            }
            .offset(x: -layerIndex * geo.size.width + dragOffset + peekOffset)
            .onAppear { barWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, width in barWidth = width }
        }
        .frame(height: pagerHeight + peekBump)
        // Clips sideways only: a pulled key grows far above the bar and must
        // not be cut off by the pager's bounds.
        .clipShape(SidewaysClip())
    }

    private var layerIndex: CGFloat {
        layer == .media ? 0 : 1
    }

    private var pagerHeight: CGFloat {
        isExpanded ? keyHeight * 2 + Self.expandedGap : keyHeight
    }

    private func layerStack(_ which: ControlLayer) -> some View {
        VStack(spacing: 5) {
            if isExpanded {
                extras(for: which)
                Divider().overlay(Color.white.opacity(0.08)).padding(.horizontal, 12)
            }
            main(for: which)
        }
    }

    // MARK: - Handle

    private var grabber: some View {
        handleTarget
            .onChange(of: isDraggingHandle) { _, dragging in
                guard !dragging else { return }
                gestureAxis = nil
                if dragOffset != 0 {
                    withAnimation(panelSpring) { dragOffset = 0 }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Control panel"))
            .accessibilityValue(Text(layerName))
            .accessibilityHint(Text("Actions available to change layer or show more controls"))
            .accessibilityAction(named: Text(expandActionName)) { isExpanded.toggle() }
            .accessibilityAction(named: Text(switchActionName)) { toggleLayer() }
    }

    private var layerName: String { layer == .media ? "Media layer" : "Keys layer" }
    private var expandActionName: String { isExpanded ? "Collapse" : "Expand" }
    private var switchActionName: String { layer == .media ? "Switch to keys" : "Switch to media" }

    private func toggleLayer() {
        layer = layer == .media ? .keys : .media
    }

    private var handleTarget: some View {
        handleContent
            .frame(height: ControlMetrics.grabberHeight)
            .animation(.easeInOut(duration: 0.22), value: wordsHint)
            .animation(panelSpring, value: layer)
            .padding(.vertical, 8)
            // 21pt was the target for the two gestures that reach half the app.
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .gesture(panelGesture)
    }

    @ViewBuilder
    private var handleContent: some View {
        Group {
            if let hint = wordsHint {
                // Said where the control is, rather than in a bubble pointing
                // at it.
                HStack(spacing: 6) {
                    Image(systemName: hint.affordance.glyph)
                        .font(.system(size: 12, weight: .semibold))
                    Text(hint.affordance.words)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .transition(.opacity)
            } else if isTyping {
                Capsule()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: ControlMetrics.grabberWidth, height: ControlMetrics.grabberHeight)
                    .transition(.opacity)
            } else {
                // The handle says which layer this is and that there is
                // another — a page indicator that is still a grabber, so the
                // second layer is permanently visible without painting
                // anything or spending a line of space on it.
                HStack(spacing: 4) {
                    segment(active: layer == .media)
                    segment(active: layer == .keys)
                }
                .transition(.opacity)
            }
        }
    }

    private func segment(active: Bool) -> some View {
        Capsule()
            .fill(Color.white.opacity(active ? 0.6 : 0.4))
            .frame(width: active ? 24 : 10, height: ControlMetrics.grabberHeight)
    }

    private var panelGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($isDraggingHandle) { _, dragging, _ in dragging = true }
            .onChanged { value in
                coach.cancel()
                if gestureAxis == nil {
                    gestureAxis = abs(value.translation.width) > abs(value.translation.height)
                        ? .horizontal : .vertical
                }
                if gestureAxis == .horizontal {
                    dragOffset = resisted(value.translation.width)
                }
            }
            .onEnded { value in
                defer { gestureAxis = nil }

                if isTyping {
                    // The handle reads as a sheet grabber, so make it behave
                    // like one: pulling down puts the keyboard away.
                    if gestureAxis == .vertical, value.translation.height > 20 {
                        onToggleKeyboard()
                        haptic.impactOccurred()
                    }
                    return
                }

                if gestureAxis == .horizontal {
                    // Judge on where the flick was heading, not where it
                    // stopped, so a fast short swipe still commits.
                    let projected = value.predictedEndTranslation.width
                    let target: ControlLayer? = projected < 0 ? .keys : .media
                    withAnimation(panelSpring) {
                        if abs(projected) > min(max(barWidth * 0.3, 40), 120), let target, target != layer {
                            layer = target
                            isExpanded = false
                            coach.markDiscovered(.layerSwipe)
                            haptic.impactOccurred()
                        }
                        dragOffset = 0
                    }
                } else {
                    guard abs(value.translation.height) > 20 else { return }
                    isExpanded = value.translation.height < 0
                    if isExpanded { coach.markDiscovered(.panelExpand) }
                    haptic.impactOccurred()
                }
            }
    }

    /// Pulling past the first or last layer meets resistance rather than empty
    /// space, so the end of the set is felt instead of guessed at.
    private func resisted(_ travel: CGFloat) -> CGFloat {
        let pullingPastStart = layer == .media && travel > 0
        let pullingPastEnd = layer == .keys && travel < 0
        return (pullingPastStart || pullingPastEnd) ? travel / 3 : travel
    }

    // MARK: - Rows

    @ViewBuilder
    private func main(for which: ControlLayer) -> some View {
        switch which {
        case .media: mediaRow
        case .keys: keysRow
        }
    }

    @ViewBuilder
    private func extras(for which: ControlLayer) -> some View {
        switch which {
        case .media: mediaExtras
        case .keys: keysExtras
        }
    }

    private var mediaRow: some View {
        HStack(spacing: 0) {
            key("backward.fill", "Previous", size: 28) { controller.tapConsumer(ConsumerUsage.previous) }

            // Tap plays or pauses; pulled sideways it becomes the scrubber.
            PullKey(axis: .horizontal, tug: pullTug) { step in
                coach.markDiscovered(.pullKey)
                controller.seek(step)
            } onTap: {
                controller.tapConsumer(ConsumerUsage.playPause)
            } label: {
                Image(systemName: "playpause.fill").font(.system(size: 34))
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Play or pause")
            .accessibilityHint("Drag sideways to seek")

            key("forward.fill", "Next", size: 28) { controller.tapConsumer(ConsumerUsage.next) }

            separator

            PullKey(axis: .vertical, tug: pullTug) { step in
                coach.markDiscovered(.pullKey)
                controller.tapConsumer(step > 0 ? ConsumerUsage.brightnessUp : ConsumerUsage.brightnessDown)
            } label: {
                Image(systemName: "sun.max").font(.system(size: 27))
            }
            .accessibilityLabel("Brightness")
            .accessibilityHint("Drag up or down to change")

            PullKey(axis: .vertical, tug: pullTug, trackAlignment: .bottomTrailing) { step in
                coach.markDiscovered(.pullKey)
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

    /// The Mac's function row. The main row holds what the Mac keyboard puts
    /// on F1–F2 and F7–F12 (brightness, transport, volume); this holds the
    /// rest of it — F3 Mission Control, F4 Spotlight, F5 dictation — plus
    /// escape and fullscreen.
    private var mediaExtras: some View {
        HStack(spacing: 0) {
            word("esc", "Escape") { controller.pressKey(HIDKey.escape) }
            key("arrow.up.left.and.arrow.down.right", "Full screen", size: 24) { controller.toggleFullscreen() }
            key("rectangle.3.group", "Mission Control", size: 24) { controller.tapConsumer(ConsumerUsage.missionControl) }
            key("magnifyingglass", "Spotlight", size: 24) { controller.tapConsumer(ConsumerUsage.spotlight) }
            key("mic", "Dictation", size: 24) { controller.tapConsumer(ConsumerUsage.voiceCommand) }
        }
    }

    private var keysRow: some View {
        HStack(spacing: 0) {
            modifier("shift", "Shift", HIDModifier.shift)
            modifier("control", "Control", HIDModifier.control)
            modifier("option", "Option", HIDModifier.option)
            modifier("command", "Command", HIDModifier.command)
            key("delete.backward", "Delete", size: 27) { controller.deleteBackward() }
            // Drawn rather than lettered: the legends are keys the Mac
            // receives, this is the one control that acts on this phone.
            key("keyboard", "Show keyboard", size: 27, action: onToggleKeyboard)
                .disabled(controller.hardwareKeyboardAttached)
        }
    }

    private var keysExtras: some View {
        HStack(spacing: 0) {
            word("esc", "Escape") { controller.pressKey(HIDKey.escape) }
            word("tab", "Tab") { controller.pressKey(HIDKey.tab) }
            key("return", "Return", size: 24) { controller.pressKey(HIDKey.returnKey) }
            separator
            key("arrow.left", "Left arrow", size: 24) { controller.pressKey(HIDKey.leftArrow) }
            key("arrow.down", "Down arrow", size: 24) { controller.pressKey(HIDKey.downArrow) }
            key("arrow.up", "Up arrow", size: 24) { controller.pressKey(HIDKey.upArrow) }
            key("arrow.right", "Right arrow", size: 24) { controller.pressKey(HIDKey.rightArrow) }
        }
    }

    /// What the system keyboard doesn't have. iOS gives you letters and
    /// nothing else — no modifiers, no escape, no arrows — so this is the
    /// exact complement, and the reason the bar earns its space while typing.
    private var typingComplement: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                word("esc", "Escape", height: typingKeyHeight) { controller.pressKey(HIDKey.escape) }
                key("arrow.left", "Left arrow", size: 24, height: typingKeyHeight) { controller.pressKey(HIDKey.leftArrow) }
                key("arrow.down", "Down arrow", size: 24, height: typingKeyHeight) { controller.pressKey(HIDKey.downArrow) }
                key("arrow.up", "Up arrow", size: 24, height: typingKeyHeight) { controller.pressKey(HIDKey.upArrow) }
                key("arrow.right", "Right arrow", size: 24, height: typingKeyHeight) { controller.pressKey(HIDKey.rightArrow) }
                key("keyboard.chevron.compact.down", "Hide keyboard", size: 27, height: typingKeyHeight,
                    tint: .accentColor, action: onToggleKeyboard)
            }

            Divider().overlay(Color.white.opacity(0.08)).padding(.horizontal, 12)

            HStack(spacing: 0) {
                modifier("shift", "Shift", HIDModifier.shift, height: typingKeyHeight)
                modifier("control", "Control", HIDModifier.control, height: typingKeyHeight)
                modifier("option", "Option", HIDModifier.option, height: typingKeyHeight)
                modifier("command", "Command", HIDModifier.command, height: typingKeyHeight)
                word("tab", "Tab", height: typingKeyHeight) { controller.pressKey(HIDKey.tab) }
            }
        }
    }

    // MARK: - Building blocks

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.09))
            .frame(width: 1, height: keyHeight * 0.4)
    }

    private func key(
        _ systemName: String,
        _ label: String,
        size: CGFloat,
        height: CGFloat? = nil,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            tap.impactOccurred()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: size))
                .frame(maxWidth: .infinity, minHeight: height ?? keyHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyPress(tint: tint))
        .accessibilityLabel(label)
    }

    private func word(
        _ text: String,
        _ label: String,
        height: CGFloat? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            tap.impactOccurred()
            action()
        } label: {
            Text(text)
                .font(.system(size: 19, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: height ?? keyHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyPress(tint: nil))
        .accessibilityLabel(label)
    }

    /// Held modifiers are the one place colour appears in the keys layer.
    /// A held modifier is filled, not merely tinted. Colour alone would fail
    /// anyone who can't resolve the hue — and the tint is DIMMER than the
    /// resting white, so latching Shift would otherwise read as disabling it.
    private func modifier(
        _ systemName: String,
        _ label: String,
        _ bit: UInt8,
        height: CGFloat? = nil
    ) -> some View {
        let active = controller.isModifierActive(bit)
        return Button {
            tap.impactOccurred()
            controller.toggleModifier(bit)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 27))
                .frame(maxWidth: .infinity, minHeight: height ?? keyHeight)
                .background(
                    Capsule()
                        .fill(active ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear))
                        .padding(.vertical, 6)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyPress(tint: active ? .black : nil))
        .accessibilityLabel(label)
        .accessibilityValue(active ? "On" : "Off")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}
