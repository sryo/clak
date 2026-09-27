import SwiftUI

// MARK: - Tokens

enum HUDMetrics {
    /// The HUD's outer corner. The pre-macOS 26 NSVisualEffectView fallback
    /// in AppDelegate must use the same value or the shadow and clip disagree.
    static let cornerRadius: CGFloat = 12
    static let keyCapCornerRadius: CGFloat = 6
}

// MARK: - Key Cap Glass

struct KeyCapGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: HUDMetrics.keyCapCornerRadius))
        } else {
            content
                .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: HUDMetrics.keyCapCornerRadius))
        }
    }
}

// MARK: - Chip Group

/// Groups neighbouring glass chips so they blend as one surface on macOS 26.
struct GlassChipGroup<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) {
                HStack(spacing: spacing) { content }
            }
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}
