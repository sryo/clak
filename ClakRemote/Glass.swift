import SwiftUI
import UIKit

/// Liquid Glass where the OS has it, a plain translucent material where it
/// doesn't. Everything in the control layer goes through here so the two paths
/// can never drift apart.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }

    /// The same glass on any shape, for panels that aren't rectangles.
    /// Interactive glass lights up under a touch; the fallback has no
    /// equivalent and stays still.
    @ViewBuilder
    func glassPanel<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
    }

    /// Groups nearby glass so it blends and morphs as one shape instead of
    /// animating as separate pieces. A no-op before iOS 26.
    @ViewBuilder
    func glassGroup() -> some View {
        if #available(iOS 26, *) {
            GlassEffectContainer { self }
        } else {
            self
        }
    }
}

// MARK: - Layout constants

/// One place for the numbers the control layer shares, so a change to key
/// height or bar inset can't leave the two layers disagreeing.
enum ControlMetrics {
    static let barInset: CGFloat = 16
    /// Space under the bar, which sits just above the home indicator, clear of
    /// the system's own swipe.
    static let barBottom: CGFloat = 12
    // Landscape leaves a phone about 400pt of height for everything, so the
    // compact variants below buy that back: 66pt keys are affordable in
    // portrait and not here.
    static let barRadius: CGFloat = 34
    static let surfaceRadius: CGFloat = 30
    static func keyHeight(compact: Bool) -> CGFloat {
        compact ? 48 : 66
    }

    /// 44 is Apple's minimum touch target — a floor, not a preference.
    static func typingKeyHeight(compact: Bool) -> CGFloat {
        compact ? 44 : 58
    }
    static let grabberWidth: CGFloat = 40
    static let grabberHeight: CGFloat = 5

    /// Movement under this in both axes is a tap, not a turn.
    static let tapSlop: CGFloat = 6
}

/// Shared because a struct View is re-initialised on every parent body pass:
/// a generator stored on one is discarded before it can warm up, so the first
/// tick of a gesture — the one that most needs to be on time — arrives late.
enum Haptics {
    static let light = UIImpactFeedbackGenerator(style: .light)
    static let medium = UIImpactFeedbackGenerator(style: .medium)

    static func prepare() {
        light.prepare()
        medium.prepare()
    }
}

/// Every key on the bar presses the same way: a brief dim and shrink. Also
/// carries the disabled appearance, since a plain button style leaves a
/// disabled key looking identical to a live one.
struct KeyPress: ButtonStyle {
    /// Applied inside the style, so it wins over any foregroundStyle the
    /// caller puts outside the button.
    var tint: AnyShapeStyle?
    @Environment(\.isEnabled) private var isEnabled

    /// Shared with keys that aren't buttons, so every key presses alike.
    static let pressedOpacity: Double = 0.45
    static let pressedScale: CGFloat = 0.92
    static let animation = Animation.spring(response: 0.22, dampingFraction: 0.7)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint ?? AnyShapeStyle(.primary))
            .opacity(isEnabled ? (configuration.isPressed ? Self.pressedOpacity : 1) : 0.3)
            .scaleEffect(configuration.isPressed ? Self.pressedScale : 1)
            .animation(Self.animation, value: configuration.isPressed)
    }
}
