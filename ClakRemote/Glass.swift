import SwiftUI

/// Liquid Glass where the OS has it, a plain translucent material where it
/// doesn't. Everything in the control layer goes through here so the two paths
/// can never drift apart.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 34

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
    func glassPanel(cornerRadius: CGFloat = 34) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
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
    static let barBottom: CGFloat = 44
    static let barRadius: CGFloat = 34
    /// Landscape on a phone leaves about 400pt of height for everything, so
    /// keys give some back rather than crowding out the trackpad.
    static func keyHeight(compact: Bool) -> CGFloat {
        compact ? 48 : 66
    }

    static func typingKeyHeight(compact: Bool) -> CGFloat {
        compact ? 42 : 58
    }
    static let grabberWidth: CGFloat = 40
    static let grabberHeight: CGFloat = 5

    /// The travel one step of a pulled key costs, matched to the haptic tick.
    static let pointsPerStep: CGFloat = 14
    /// Movement under this in both axes is a tap, not a pull.
    static let tapSlop: CGFloat = 6
}
